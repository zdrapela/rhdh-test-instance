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
    export CATALOG_INDEX_TAG="${CATALOG_INDEX_TAG:-2.1}"
    export CATALOG_INDEX_IMAGE="${CATALOG_INDEX_IMAGE:-quay.io/rhdh/plugin-catalog-index:${CATALOG_INDEX_TAG}}"
    CATALOG_INDEX_IMAGE="${CATALOG_INDEX_IMAGE#oci://}"
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
    prepare_deploy_workdir
    mkdir -p "${DEPLOY_WORKDIR}/catalog"
    skopeo --override-os linux --override-arch amd64 copy \
        "docker://${CATALOG_INDEX_IMAGE}" "dir:${DEPLOY_WORKDIR}/catalog" >&2 || return 1
    while IFS= read -r digest; do
        layer="${DEPLOY_WORKDIR}/catalog/${digest#sha256:}"
        for member in dynamic-plugins.default.yaml ./dynamic-plugins.default.yaml; do
            if tar -xOf "$layer" "$member" > "$destination" 2>/dev/null; then
                return 0
            fi
        done
    done < <(jq -r '.layers | reverse | .[].digest' "${DEPLOY_WORKDIR}/catalog/manifest.json")
    echo "Error: ${CATALOG_INDEX_IMAGE} does not supply dynamic-plugins.default.yaml." >&2
    return 1
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
