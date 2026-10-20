#!/usr/bin/env bash

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

validate_rhdh_version() {
    if [[ ! "$1" =~ ^2\.1(\.[0-9]+|-[0-9]+-CI)?$ ]]; then
        echo "Error: Unsupported RHDH version '$1'. Use 2.1, a 2.1 patch release, or 2.1-<build>-CI." >&2
        return 1
    fi
}

prepare_deploy_workdir() {
    if [[ -z "${DEPLOY_WORKDIR:-}" ]]; then
        DEPLOY_WORKDIR=$(mktemp -d "${TMPDIR:-${PWD}}/rhdh-deploy.XXXXXX")
        trap 'rm -rf "${DEPLOY_WORKDIR}"' EXIT
    fi
}

wait_for_crd() {
    local name="$1" deadline=$((SECONDS + 300))
    until oc get "crd/${name}" >/dev/null 2>&1; do
        if ((SECONDS >= deadline)); then
            echo "Error: Timed out waiting for CRD ${name}." >&2
            return 1
        fi
        sleep 5
    done
    oc wait --for=condition=Established "crd/${name}" --timeout=300s
}

resolve_catalog_image() {
    export CATALOG_INDEX_TAG="${CATALOG_INDEX_TAG:-}"
    export CATALOG_INDEX_IMAGE="${CATALOG_INDEX_IMAGE:-}"
    if [[ -z "$CATALOG_INDEX_IMAGE" && -n "$CATALOG_INDEX_TAG" ]]; then
        CATALOG_INDEX_IMAGE="quay.io/rhdh/plugin-catalog-index:${CATALOG_INDEX_TAG}"
    fi
    CATALOG_INDEX_IMAGE="${CATALOG_INDEX_IMAGE#oci://}"
}

resolve_helm_chart_version() {
    if [[ "$1" == "2.1" ]]; then
        quay_latest_tag "rhdh/chart" "$1"
    else
        printf '%s\n' "$1"
    fi
}

# Inspect the selected release's defaults without overriding its runtime catalog.
resolve_deployment_catalog_image() {
    local method="$1" version="$2"
    resolve_catalog_image
    RESOLVED_CATALOG_INDEX_IMAGE="$CATALOG_INDEX_IMAGE"
    if [[ "$method" == "helm" ]]; then
        export RESOLVED_HELM_CHART_VERSION
        RESOLVED_HELM_CHART_VERSION=$(resolve_helm_chart_version "$version") || return 1
        if [[ -z "$RESOLVED_CATALOG_INDEX_IMAGE" ]]; then
            RESOLVED_CATALOG_INDEX_IMAGE=$(helm show values oci://quay.io/rhdh/chart \
                --version "$RESOLVED_HELM_CHART_VERSION" | yq -o=json '.' | jq -er '
                .catalogIndex.image | .registry + "/" + .repository +
                (if (.digest // "") != "" then "@" + .digest else ":" + .tag end)') || return 1
        fi
    elif [[ -z "$RESOLVED_CATALOG_INDEX_IMAGE" ]]; then
        RESOLVED_CATALOG_INDEX_IMAGE=$(oc get configmap rhdh-default-config \
            -n "${OPERATOR_NAMESPACE:-rhdh-operator-system}" -o json \
            | jq -er '.data["deployment.yaml"]' | yq -o=json '.' | jq -er '
            .spec.template.spec.initContainers[] | select(.name == "install-dynamic-plugins") |
            .env[] | select(.name == "CATALOG_INDEX_IMAGE") | .value') || {
            echo "Error: Cannot read the Operator's bundled catalog. Run make install-operator VERSION=2.1 first." >&2
            return 1
        }
    fi
    [[ -n "$RESOLVED_CATALOG_INDEX_IMAGE" ]] || return 1
    export RESOLVED_CATALOG_INDEX_IMAGE
    echo "Validating bundled/selected catalog: ${RESOLVED_CATALOG_INDEX_IMAGE}" >&2
}

# Translate a full image reference into the chart's image values, including
# registry ports and digest overrides. This never chooses a plugin version.
image_values() {
    local image="$1" name tag="" digest=""
    if [[ "$image" != */* ]]; then
        echo "Error: Use a full registry/repository image reference: $image" >&2
        return 1
    fi
    name="${image%@*}"
    if [[ "$image" == *@* ]]; then
        digest="${image##*@}"
        if [[ "${name##*/}" == *:* ]]; then name="${name%:*}"; fi
    elif [[ "${name##*/}" == *:* ]]; then
        tag="${name##*:}"
        name="${name%:*}"
    else
        tag="latest"
    fi
    jq -n --arg registry "${name%%/*}" --arg repository "${name#*/}" \
        --arg tag "$tag" --arg digest "$digest" \
        '{registry: $registry, repository: $repository, tag: $tag, digest: $digest}'
}

# Resolve only tags on the 2.1 line, excluding attestations and other releases.
quay_latest_tag() {
    local repo="$1" prefix="$2" page=1 names="" response
    while true; do
        response=$(curl -fsSG "https://quay.io/api/v1/repository/${repo}/tag/" \
            --data-urlencode "onlyActiveTags=true" --data-urlencode "limit=100" \
            --data-urlencode "page=${page}" --data-urlencode "filter_tag_name=like:${prefix}") || return 1
        names+="$(jq -r '.tags[]?.name // empty' <<< "$response")"$'\n'
        [[ "$(jq -r '.has_additional // false' <<< "$response")" == "true" ]] || break
        page=$((page + 1))
    done
    jq -nr --arg names "$names" --arg prefix "$prefix" \
        '$names | split("\n")[] | select(startswith($prefix)) |
        select(ltrimstr($prefix) | test("^(-[0-9]+-CI|\\.[0-9]+)?$"))' \
        | sort -V | tail -n 1
}

# Read the supplied catalog, rather than generating defaults or pinning packages
# locally. Read layers newest-first in case the index was rebuilt as an overlay.
fetch_catalog_defaults() {
    local destination="$1" digest layer member
    local catalog_image="${RESOLVED_CATALOG_INDEX_IMAGE:-${CATALOG_INDEX_IMAGE:-}}"
    prepare_deploy_workdir
    mkdir -p "${DEPLOY_WORKDIR}/catalog"
    if ! skopeo --override-os linux --override-arch amd64 copy \
        "docker://${catalog_image}" "dir:${DEPLOY_WORKDIR}/catalog" >&2; then
        # RC bundles can precede publication to registry.access.redhat.com.
        # Use the public mirror of that exact bundled digest for validation and runtime.
        if [[ -n "${CATALOG_INDEX_IMAGE:-}" || \
            "$catalog_image" != registry.access.redhat.com/rhdh/plugin-catalog-index@sha256:* ]]; then
            return 1
        fi
        catalog_image="quay.io/rhdh/plugin-catalog-index@${catalog_image##*@}"
        echo "Using Quay mirror of the bundled catalog: ${catalog_image}" >&2
        skopeo --override-os linux --override-arch amd64 copy \
            "docker://${catalog_image}" "dir:${DEPLOY_WORKDIR}/catalog" >&2 || return 1
        export CATALOG_INDEX_IMAGE="$catalog_image" RESOLVED_CATALOG_INDEX_IMAGE="$catalog_image"
    fi
    while IFS= read -r digest; do
        layer="${DEPLOY_WORKDIR}/catalog/${digest#sha256:}"
        for member in dynamic-plugins.default.yaml ./dynamic-plugins.default.yaml; do
            if tar -xOf "$layer" "$member" > "$destination" 2>/dev/null; then
                return 0
            fi
        done
    done < <(jq -r '.layers | reverse | .[].digest' "${DEPLOY_WORKDIR}/catalog/manifest.json")
    echo "Error: ${catalog_image} does not supply dynamic-plugins.default.yaml." >&2
    return 1
}

# The older chart's Homepage 1.x extends Backstage's home plugin. Homepage 3.x
# in the newer Operator provides its own page:homepage instead.
render_nfs_app_config() {
    if [[ "${RESOLVED_HELM_CHART_VERSION:-}" == "2.1-119-CI" ]]; then
        yq '.app.extensions |= map(select(has("page:homepage") | not) |
            with_entries(.key |= sub(":homepage/", ":home/"))) |
            (.app.extensions[] | select(has("page:home")))."page:home" = {"config": {"path": "/"}}' \
            "${DEPLOY_ROOT}/config/nfs-app-config.yaml"
    else
        yq '.' "${DEPLOY_ROOT}/config/nfs-app-config.yaml"
    fi
}

# Check the installed RC before using its defaults or changing an instance.
# Optional expectations are per-run checks, never replacements for bundled images.
verify_operator_installation() {
    local namespace="${OPERATOR_NAMESPACE:-rhdh-operator-system}" csv deployment defaults images
    csv=$(oc get subscriptions.operators.coreos.com rhdh -n "$namespace" \
        -o jsonpath='{.status.installedCSV}') || return 1
    [[ -n "$csv" ]] || { echo "Error: No installed RHDH Operator CSV in ${namespace}." >&2; return 1; }
    oc get clusterserviceversion "$csv" -n "$namespace" -o json | jq -e '
        .status.phase == "Succeeded" and (.spec.version | test("^2\\.1\\."))' >/dev/null || {
        echo "Error: The installed RHDH Operator must be a successful 2.1 release." >&2
        return 1
    }
    deployment=$(oc get deployment rhdh-operator -n "$namespace" -o json) || return 1
    jq -e '.status.availableReplicas >= 1' <<< "$deployment" >/dev/null || {
        echo "Error: The RHDH Operator deployment is not available." >&2
        return 1
    }
    oc get crd backstages.rhdh.redhat.com -o json | jq -e '
        any(.spec.versions[]; .name == "v1alpha5" and .served)' >/dev/null || return 1
    defaults=$(oc get configmap rhdh-default-config -n "$namespace" -o json \
        | jq -er '.data["deployment.yaml"]' | yq -o=json '.') || return 1
    images=$(jq -n --argjson deployment "$deployment" --argjson defaults "$defaults" '{
        manager: ($deployment.spec.template.spec.containers[] | select(.name == "manager") | .image),
        app: ($defaults.spec.template.spec.containers[] | select(.name == "backstage-backend") | .image),
        catalog: ($defaults.spec.template.spec.initContainers[] | select(.name == "install-dynamic-plugins") |
            .env[] | select(.name == "CATALOG_INDEX_IMAGE") | .value)
    }') || return 1
    jq -e --arg manager "${OPERATOR_EXPECTED_IMAGE:-}" --arg app "${OPERATOR_EXPECTED_RHDH_IMAGE:-}" \
        --arg catalog "${OPERATOR_EXPECTED_CATALOG_IMAGE:-}" '
        def matches($expected): $expected == "" or . == $expected or
            (contains("@sha256:") and ($expected | contains("@sha256:")) and
             split("@")[1] == ($expected | split("@")[1]));
        (.manager | matches($manager)) and (.app | matches($app)) and (.catalog | matches($catalog))
    ' <<< "$images" >/dev/null || {
        echo "Error: Installed Operator images do not match the requested RC:" >&2
        jq . <<< "$images" >&2
        return 1
    }
    echo "Verified installed RHDH Operator ${csv}:" >&2
    jq . <<< "$images" >&2
}

plugin_config_files() {
    echo "${DEPLOY_ROOT}/config/dynamic-plugins.yaml"
    echo "${DEPLOY_ROOT}/resources/keycloak/dynamic-plugins.yaml"
    local component flag
    for component in nfs orchestrator lightspeed scorecard rbac; do
        flag="WITH_$(tr '[:lower:]' '[:upper:]' <<< "$component")"
        if [[ "${!flag:-0}" == "1" ]]; then
            echo "${DEPLOY_ROOT}/config/${component}-dynamic-plugins.yaml"
            if [[ "$component" == lightspeed ]]; then
                echo "${DEPLOY_ROOT}/config/mcp-dynamic-plugins.yaml"
            fi
        fi
    done
    local plugins
    plugins=$(tr '[:upper:]' '[:lower:]' <<< "${PLUGINS:-}" | tr -d '[:space:]')
    case ",$plugins," in
        *,lighthouse,*) echo "${DEPLOY_ROOT}/resources/lighthouse/dynamic-plugins.yaml" ;;
    esac
}
