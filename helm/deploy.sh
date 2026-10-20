#!/bin/bash
set -eo pipefail

# Check if the required parameters are provided
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <namespace> <version>"
    exit 1
fi

namespace="$1"
version="$2"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/deployment-common.sh"
validate_rhdh_version "$version"
resolve_catalog_image
prepare_deploy_workdir

# Validate version and determine chart version
CV="${RESOLVED_HELM_CHART_VERSION:-$(resolve_helm_chart_version "$version")}"

if [[ -z "${CV}" || "${CV}" == "null" ]]; then
    echo "Error: Could not resolve Helm chart version for '${version}'."
    echo "Check available tags: https://quay.io/repository/rhdh/chart?tab=tags"
    echo "Examples: VERSION=2.1  VERSION=2.1-128-CI"
    exit 1
fi

echo "Using Helm chart version: ${CV}"

echo "Using catalog index: ${RESOLVED_CATALOG_INDEX_IMAGE:-${CATALOG_INDEX_IMAGE:-chart default}}"

CHART_URL="oci://quay.io/rhdh/chart"
helm show chart "$CHART_URL" --version "$CV" >/dev/null

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
        # Resolve an available tag on the same release line.
        INFRA_CV=""
        if helm show chart oci://quay.io/rhdh/orchestrator-infra-chart --version "$CV" &>/dev/null; then
            INFRA_CV="$CV"
        else
            INFRA_CV=$(quay_latest_tag "rhdh/orchestrator-infra-chart" "2.1")
        fi
        if [[ -z "${INFRA_CV}" || "${INFRA_CV}" == "null" ]]; then
            echo "Error: No RHDH 2.1 orchestrator infrastructure chart is available." >&2
            exit 1
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

    echo "Waiting for the serverless APIs..."
    wait_for_crd sonataflowplatforms.sonataflow.org
    wait_for_crd knativeservings.operator.knative.dev
fi

# Build dynamic plugins values for the 2.1 chart (`dynamicPlugins`).
# Read from the cluster ConfigMap seeded in deploy.sh and augmented by any
# plugin setup scripts. Fall back to config/dynamic-plugins.yaml if the
# ConfigMap is not available (e.g. standalone helm/deploy.sh execution).
DYNAMIC_PLUGINS_FILE="${DEPLOY_WORKDIR}/helm-dynamic-plugins.json"
if oc get configmap dynamic-plugins --namespace "$namespace" &>/dev/null; then
    oc get configmap dynamic-plugins \
        --namespace "$namespace" \
        -o jsonpath='{.data.dynamic-plugins\.yaml}' \
        | yq -o=json '{"dynamicPlugins": .}' > "$DYNAMIC_PLUGINS_FILE"
else
    yq -o=json '{"dynamicPlugins": .}' config/dynamic-plugins.yaml > "$DYNAMIC_PLUGINS_FILE"
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
    --set-json "extraAppConfig=${EXTRA_APP_CONFIGS}"
    --namespace "$namespace"
)

if [[ -n "$CATALOG_INDEX_IMAGE" ]]; then
    HELM_ARGS+=(--set-json "catalogIndex.image=$(image_values "$CATALOG_INDEX_IMAGE")")
fi

# Component refs are already in dynamicPlugins.plugins. Do not append them twice.
if [[ "${WITH_ORCHESTRATOR}" == "1" ]]; then
    HELM_ARGS+=(
        --set orchestrator.enabled=true
        --set-json 'orchestrator.plugins=[]'
    )
fi

# Intelligent Assistant / Lightspeed Core sidecar (2.1 chart API).
# Keep the UI available without credentials; start the sidecar when configured.
if [[ "${WITH_LIGHTSPEED}" == "1" ]]; then
    HELM_ARGS+=(
        --set "intelligentAssistant.enabled=${LIGHTSPEED_HAS_PROVIDER:-false}"
        --set-json 'intelligentAssistant.plugins=[]'
    )
    if [[ "${LIGHTSPEED_HAS_PROVIDER:-false}" == "true" ]]; then
        echo "Enabling Lightspeed Core Service sidecar via Helm chart..."
        HELM_ARGS+=(
            --set intelligentAssistant.existingSecret=lightspeed-secret
            --set intelligentAssistant.config.stack.existingConfigMap.name=lightspeed-stack
            --set intelligentAssistant.config.stack.existingConfigMap.key=lightspeed-stack.yaml
        )
    fi
else
    HELM_ARGS+=(--set intelligentAssistant.enabled=false)
fi

# Override RHDH container image if RHDH_IMAGE is set (e.g. quay.io/rhdh-community/rhdh:pr-1234)
if [[ -n "${RHDH_IMAGE}" ]]; then
    HELM_ARGS+=(--set-json "image=$(image_values "$RHDH_IMAGE")")
fi

# Install or upgrade Helm chart
helm upgrade --install redhat-developer-hub "${CHART_URL}" --version "$CV" "${HELM_ARGS[@]}"
