#!/bin/bash
set -e

# Check if the required parameters are provided
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <namespace> <version>"
    exit 1
fi

namespace="$1"
version="$2"
github=0 # by default don't use the Github repo unless the chart doesn't exist in the OCI registry

# Resolve the latest Quay tag matching ^<prefix>(-|$). Uses filter_tag_name so we
# don't drown in attestation digests; paginates while has_additional is true.
_quay_latest_tag() {
    local repo="$1" prefix="$2"
    local page=1 names="" resp page_names
    while true; do
        resp=$(curl -sG "https://quay.io/api/v1/repository/${repo}/tag/" \
            --data-urlencode "onlyActiveTags=true" \
            --data-urlencode "limit=100" \
            --data-urlencode "page=${page}" \
            --data-urlencode "filter_tag_name=like:${prefix}")
        page_names=$(echo "${resp}" | jq -r '.tags[]?.name // empty')
        names+="${page_names}"$'\n'
        [[ "$(echo "${resp}" | jq -r '.has_additional // false')" == "true" ]] || break
        page=$((page + 1))
        [[ ${page} -gt 50 ]] && break
    done
    echo "${names}" | grep -E "^${prefix}(-|$)" | sort -V | tail -n 1
}

# Validate version and determine chart version
if [[ "$version" =~ ^([0-9]+(\.[0-9]+)?)$ ]]; then
    # Resolve e.g. 2.1 -> latest 2.1-*-CI / 2.1.* tag on Quay
    CV=$(_quay_latest_tag "rhdh/chart" "${version}")
elif [[ "$version" == "next" ]]; then
    # 'next' is an OCI tag alias for the latest CI build; resolve to actual chart version
    CONFIG_DIGEST=$(curl -s -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        "https://quay.io/v2/rhdh/chart/manifests/next" | jq -r '.config.digest')
    CV=$(curl -sL "https://quay.io/v2/rhdh/chart/blobs/$CONFIG_DIGEST" | jq -r '.version')
    echo "Resolved 'next' to chart version: ${CV}"
elif [[ "$version" =~ CI$ ]]; then
    CV=$version
else
    echo "Error: Invalid helm chart version: $version"
    [[ "$OPENSHIFT_CI" == "true" ]] && gh_comment "❌ **Error: Invalid helm chart version** 🚫\n\n📝 **Provided version:** \`$version\`\n\nPlease check your version and try again! 🔄"
    exit 1
fi

if [[ -z "${CV}" || "${CV}" == "null" ]]; then
    echo "Error: Could not resolve Helm chart version for '${version}'."
    echo "Check available tags: https://quay.io/repository/rhdh/chart?tab=tags"
    echo "Examples: VERSION=2.1  VERSION=2.1-128-CI  VERSION=next"
    exit 1
fi

echo "Using Helm chart version: ${CV}"

# Catalog index tag defaults to the major.minor version, or "next" for next
if [[ "$version" == "next" ]]; then
    CATALOG_INDEX_TAG="${CATALOG_INDEX_TAG:-next}"
else
    CATALOG_INDEX_TAG="${CATALOG_INDEX_TAG:-$(echo "$version" | grep -oE '^[0-9]+\.[0-9]+')}"
fi
echo "Using catalog index tag: ${CATALOG_INDEX_TAG}"

CHART_URL="oci://quay.io/rhdh/chart"
if ! helm show chart $CHART_URL --version $CV &> /dev/null; then github=1; fi
if [[ $github -eq 1 ]]; then
    CHART_URL="https://github.com/rhdh-bot/openshift-helm-charts/raw/redhat-developer-hub-${CV}/charts/redhat/redhat/redhat-developer-hub/${CV}/redhat-developer-hub-${CV}.tgz"
    oc apply -f "https://github.com/rhdh-bot/openshift-helm-charts/raw/redhat-developer-hub-${CV}/installation/rhdh-next-ci-repo.yaml"
fi

echo "Using ${CHART_URL} to install Helm chart"

# Install orchestrator infrastructure if requested
if [[ "${WITH_ORCHESTRATOR}" == "1" ]]; then
    echo "Installing orchestrator infrastructure chart..."
    # Check if operators are already installed on the cluster (cluster-scoped, shared across namespaces)
    if oc get pods -n openshift-serverless --no-headers 2>/dev/null | grep -q . && \
       oc get pods -n openshift-serverless-logic --no-headers 2>/dev/null | grep -q .; then
        echo "Serverless operators already running on cluster, skipping infra chart."
    else
        # Infra chart tags lag the main RHDH chart (e.g. chart 2.1-129-CI vs infra 2.1-97-CI).
        # Resolve an available tag: exact match -> latest same major.minor -> next.
        INFRA_MM=$(echo "$CV" | grep -oE '^[0-9]+\.[0-9]+' || true)
        INFRA_CV=""
        if helm show chart oci://quay.io/rhdh/orchestrator-infra-chart --version "$CV" &>/dev/null; then
            INFRA_CV="$CV"
        elif [[ -n "${INFRA_MM}" ]]; then
            INFRA_CV=$(_quay_latest_tag "rhdh/orchestrator-infra-chart" "${INFRA_MM}")
        fi
        if [[ -z "${INFRA_CV}" || "${INFRA_CV}" == "null" ]]; then
            INFRA_CV="next"
        fi
        if [[ "${INFRA_CV}" != "${CV}" ]]; then
            echo "Orchestrator infra chart '${CV}' not found; using '${INFRA_CV}' instead."
        else
            echo "Using orchestrator infra chart version: ${INFRA_CV}"
        fi

        INFRA_ARGS=(--version "$INFRA_CV" --namespace "$namespace"
            --wait --timeout=5m
            --set serverlessLogicOperator.subscription.spec.installPlanApproval=Automatic
            --set serverlessOperator.subscription.spec.installPlanApproval=Automatic)
        # Skip CRDs if they already exist (e.g. installed by OLM)
        if oc get crd knativeservings.operator.knative.dev &>/dev/null; then
            INFRA_ARGS+=(--skip-crds)
        fi
        helm upgrade --install orchestrator-infra oci://quay.io/rhdh/orchestrator-infra-chart "${INFRA_ARGS[@]}"
        echo "Orchestrator infrastructure chart installed successfully."
    fi

    # Wait for operator pods to appear
    echo "Waiting for serverless operator pods..."
    until [[ "$(oc get pods -n openshift-serverless --no-headers 2>/dev/null | wc -l)" -gt 0 ]]; do sleep 5; done
    until [[ "$(oc get pods -n openshift-serverless-logic --no-headers 2>/dev/null | wc -l)" -gt 0 ]]; do sleep 5; done
    echo "Serverless operator pods are running."
fi

# Build dynamic plugins value file for the 2.1+ chart (`dynamicPlugins`).
# Read from the cluster ConfigMap seeded in deploy.sh and augmented by any
# plugin setup scripts. Fall back to config/dynamic-plugins.yaml if the
# ConfigMap is not available (e.g. standalone helm/deploy.sh execution).
DYNAMIC_PLUGINS_FILE=$(mktemp)
trap "rm -f $DYNAMIC_PLUGINS_FILE" EXIT
echo "dynamicPlugins:" > "$DYNAMIC_PLUGINS_FILE"
# Escape {{inherit}} for Helm's Go template engine: {{inherit}} -> {{ "{{inherit}}" }}
if oc get configmap dynamic-plugins --namespace "$namespace" &>/dev/null; then
    oc get configmap dynamic-plugins \
        --namespace "$namespace" \
        -o jsonpath='{.data.dynamic-plugins\.yaml}' \
        | sed -e 's/^/  /' -e 's/{{inherit}}/{{ "{{inherit}}" }}/g' \
        >> "$DYNAMIC_PLUGINS_FILE"
else
    sed -e 's/^/  /' -e 's/{{inherit}}/{{ "{{inherit}}" }}/g' \
        config/dynamic-plugins.yaml >> "$DYNAMIC_PLUGINS_FILE"
fi

# Build extraAppConfig array dynamically based on enabled components
EXTRA_APP_CONFIGS='[{"configMapRef":"app-config-rhdh","filename":"app-config-rhdh.yaml"}'
[[ "${WITH_NFS}" == "1" ]] && EXTRA_APP_CONFIGS+=',{"configMapRef":"app-config-nfs","filename":"nfs-app-config.yaml"}'
[[ "${WITH_ORCHESTRATOR}" == "1" ]] && EXTRA_APP_CONFIGS+=',{"configMapRef":"app-config-orchestrator","filename":"orchestrator-app-config.yaml"}'
EXTRA_APP_CONFIGS+=']'

# Build helm install arguments (RHDH 2.1+ top-level values schema)
HELM_ARGS=(
    -f "helm/value_file.yaml"
    -f "$DYNAMIC_PLUGINS_FILE"
    --set "openshift.clusterRouterBase=${CLUSTER_ROUTER_BASE}"
    --set catalogIndex.image.registry="quay.io"
    --set catalogIndex.image.repository="rhdh/plugin-catalog-index"
    --set catalogIndex.image.tag="${CATALOG_INDEX_TAG}"
    --set-json "extraAppConfig=${EXTRA_APP_CONFIGS}"
    --namespace "$namespace"
)

# Orchestrator: enable chart infra/CR wiring, but use our GHCR overlays from
# dynamicPlugins.plugins (avoid duplicating chart default ref:// plugins).
if [[ "${WITH_ORCHESTRATOR}" == "1" ]]; then
    HELM_ARGS+=(
        --set orchestrator.enabled=true
        --set-json 'orchestrator.plugins=[]'
    )
fi

# NFS on RHDH 2.1+: default `app` is already the New Frontend System — do not
# set APP_CONFIG_app_packageName=app-next. NFS plugins/app-config are wired via
# dynamicPlugins + extraAppConfig; SMF/debug env lives in helm/value_file.yaml.

# Intelligent Assistant / Lightspeed Core sidecar (2.1 chart API).
# Plugins come from our dynamicPlugins overlays; clear chart defaults to avoid dupes.
if [[ "${WITH_LIGHTSPEED}" == "1" ]]; then
    HELM_ARGS+=(
        --set intelligentAssistant.enabled=true
        --set-json 'intelligentAssistant.plugins=[]'
    )
    if [[ "${LIGHTSPEED_HAS_PROVIDER:-false}" == "true" ]]; then
        echo "Enabling Lightspeed Core Service sidecar via Helm chart..."
        HELM_ARGS+=(
            --set intelligentAssistant.existingSecret=lightspeed-secret
            --set-json 'intelligentAssistant.core.extraEnv=[{"name":"SERVICE_HOST","value":"0.0.0.0"}]'
        )
    fi
else
    HELM_ARGS+=(--set intelligentAssistant.enabled=false)
fi

# Override RHDH container image if RHDH_IMAGE is set (e.g. quay.io/rhdh-community/rhdh:pr-1234)
if [[ -n "${RHDH_IMAGE}" ]]; then
    IMAGE_TAG="${RHDH_IMAGE##*:}"
    IMAGE_WITHOUT_TAG="${RHDH_IMAGE%:*}"
    IMAGE_REGISTRY="${IMAGE_WITHOUT_TAG%%/*}"
    IMAGE_REPOSITORY="${IMAGE_WITHOUT_TAG#*/}"
    echo "Overriding RHDH image: registry=${IMAGE_REGISTRY} repository=${IMAGE_REPOSITORY} tag=${IMAGE_TAG}"
    HELM_ARGS+=(
        --set image.registry="${IMAGE_REGISTRY}"
        --set image.repository="${IMAGE_REPOSITORY}"
        --set image.tag="${IMAGE_TAG}"
    )
fi

# Drop any prior kubectl-patched Helm ConfigMap so server-side apply does not
# conflict (field manager: kubectl-client-side-apply vs helm).
oc delete configmap redhat-developer-hub-app-config -n "$namespace" --ignore-not-found >/dev/null 2>&1 || true

# Install or upgrade Helm chart
helm upgrade --install redhat-developer-hub "${CHART_URL}" --version "$CV" "${HELM_ARGS[@]}"


# Scale down, apply any post-Helm ConfigMap patches while pods are stopped,
# then scale back up — single restart cycle to avoid competing ReplicaSets.
oc scale deployment -l 'app.kubernetes.io/instance in (redhat-developer-hub,developer-hub)' --replicas=0 -n "$namespace"
oc wait --for=delete pod -l 'app.kubernetes.io/instance in (redhat-developer-hub,developer-hub),app.kubernetes.io/name!=postgresql' -n "$namespace" --timeout=120s || true

# MCP static token lives in app-config-rhdh (extraAppConfig, loaded last) — do
# not kubectl-patch the Helm app-config ConfigMap (causes SSA field-manager
# conflicts on the next upgrade). Only patch LCS allowed_models when needed.
if [[ "${WITH_LIGHTSPEED}" == "1" ]] && type -t patch_lcs_allowed_models &>/dev/null; then
    patch_lcs_allowed_models
fi

oc scale deployment -l 'app.kubernetes.io/instance in (redhat-developer-hub,developer-hub)' --replicas=1 -n "$namespace"
