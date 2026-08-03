#!/usr/bin/env bash
#
# Lightspeed Core Service (LCS) setup for RHDH
#
# Creates the ConfigMaps and Secret required by the LCS sidecar, then
# patches the RHDH deployment to include the sidecar container.
#
# If no LLM provider credentials are configured, the LCS sidecar is
# skipped entirely — only the dynamic plugins are loaded (the UI will
# show "Could not load models" until credentials are added).
#
# Required env vars: NAMESPACE
# Optional env vars (from .env): ENABLE_OPENAI, OPENAI_API_KEY, ENABLE_VLLM,
#   VLLM_URL, VLLM_API_KEY, etc.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LCS_RESOURCES="${ROOT_DIR}/resources/lightspeed"

LCS_IMAGE="registry.redhat.io/lightspeed-core/lightspeed-stack-rhel9@sha256:a1ad27dee55d8c655d6ef218ad7c252e4bc33ab7aa7ac514161264773575c77e"

# Set to true by has_lightspeed_provider; checked by deploy.sh
LIGHTSPEED_HAS_PROVIDER=false

has_lightspeed_provider() {
    LIGHTSPEED_HAS_PROVIDER=false
    if [[ "${ENABLE_OPENAI:-}" == "true" && -n "${OPENAI_API_KEY:-}" ]]; then LIGHTSPEED_HAS_PROVIDER=true; fi
    if [[ "${ENABLE_VLLM:-}" == "true" && -n "${VLLM_URL:-}" ]]; then LIGHTSPEED_HAS_PROVIDER=true; fi
    if [[ "${ENABLE_OLLAMA:-}" == "true" && -n "${OLLAMA_URL:-}" ]]; then LIGHTSPEED_HAS_PROVIDER=true; fi
    if [[ "${ENABLE_VERTEX_AI:-}" == "true" && -n "${VERTEX_AI_PROJECT:-}" ]]; then LIGHTSPEED_HAS_PROVIDER=true; fi
}

setup_lightspeed_resources() {
    echo ""
    echo "=============================================="
    echo "Lightspeed Core Service — Setup"
    echo "=============================================="

    has_lightspeed_provider

    if [[ "${LIGHTSPEED_HAS_PROVIDER}" == "false" ]]; then
        echo ""
        echo "  No LLM provider credentials found. Skipping LCS sidecar deployment."
        echo "  The Intelligent Assistant UI will load but cannot connect to an LLM."
        echo ""
        echo "  To enable later, add credentials to .env and redeploy, or run:"
        echo ""
        echo "  1. Create the secret:"
        echo "     oc create secret generic lightspeed-secret -n ${NAMESPACE} \\"
        echo "       --from-literal=ENABLE_OPENAI=true \\"
        echo "       --from-literal=OPENAI_API_KEY=sk-..."
        echo ""
        echo "  2. Then run the LCS setup:"
        echo "     WITH_LIGHTSPEED=1 NAMESPACE=${NAMESPACE} source scripts/setup-lightspeed.sh"
        echo "     setup_lightspeed_resources  # will detect credentials this time"
        echo "     patch_lightspeed_sidecar"
        echo ""
        return 0
    fi

    echo "LLM provider detected. Setting up LCS resources..."

    # ConfigMaps (no envsubst needed — these use ${env.*} syntax resolved by LCS at runtime)
    for cm in lightspeed-stack lightspeed-config lightspeed-rhdh-profile; do
        oc apply -f "${LCS_RESOURCES}/${cm}.yaml" --namespace="${NAMESPACE}"
    done

    # Secret (uses envsubst to inject values from .env / environment)
    envsubst < "${LCS_RESOURCES}/lightspeed-secret.yaml" \
        | oc apply -f - --namespace="${NAMESPACE}"

    echo "Lightspeed resources created in ${NAMESPACE}."
}

patch_lightspeed_sidecar() {
    echo ""
    echo "=============================================="
    echo "Lightspeed Core Service — Patching Deployment"
    echo "=============================================="

    local deployment_name
    deployment_name=$(oc get deployment -n "${NAMESPACE}" \
        -l 'app.kubernetes.io/instance in (redhat-developer-hub,developer-hub)' \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -z "${deployment_name}" ]]; then
        echo "Error: No RHDH deployment found in ${NAMESPACE}. Skipping LCS sidecar patch."
        return 1
    fi

    # Check if sidecar is already present
    if oc get deployment "${deployment_name}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[*].name}' | grep -q 'lightspeed-core'; then
        echo "LCS sidecar already present in ${deployment_name}, skipping patch."
        return 0
    fi

    echo "Patching deployment ${deployment_name} with lightspeed-core sidecar..."

    # Scale down first to avoid two pods competing for the same database
    # (the patch changes the pod template, triggering a new ReplicaSet)
    echo "Scaling down ${deployment_name} before patch..."
    oc scale deployment "${deployment_name}" -n "${NAMESPACE}" --replicas=0
    oc wait --for=delete pod -l "app.kubernetes.io/instance in (redhat-developer-hub,developer-hub),app.kubernetes.io/name!=postgresql" \
        -n "${NAMESPACE}" --timeout=120s 2>/dev/null || true

    local patch_json
    patch_json=$(cat <<PATCH
[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/-",
    "value": {
      "name": "lightspeed-core",
      "image": "${LCS_IMAGE}",
      "imagePullPolicy": "IfNotPresent",
      "securityContext": {
        "allowPrivilegeEscalation": false,
        "capabilities": {"drop": ["ALL"]},
        "readOnlyRootFilesystem": false,
        "runAsNonRoot": true,
        "seccompProfile": {"type": "RuntimeDefault"}
      },
      "ports": [
        {"name": "http-lightspeed", "containerPort": 8080, "protocol": "TCP"}
      ],
      "envFrom": [
        {"secretRef": {"name": "lightspeed-secret", "optional": false}}
      ],
      "resources": {
        "limits": {"cpu": "1000m", "memory": "2Gi"},
        "requests": {"cpu": "100m", "memory": "512Mi"}
      },
      "volumeMounts": [
        {"name": "lightspeed-data", "mountPath": "/tmp"},
        {"name": "lightspeed-rag", "mountPath": "/rag-content"},
        {"name": "lightspeed-config-stack", "mountPath": "/app-root/lightspeed-stack.yaml", "subPath": "lightspeed-stack.yaml", "readOnly": true},
        {"name": "lightspeed-config-config", "mountPath": "/app-root/config.yaml", "subPath": "config.yaml", "readOnly": true},
        {"name": "lightspeed-config-rhdh-profile", "mountPath": "/app-root/rhdh-profile.py", "subPath": "rhdh-profile.py", "readOnly": true},
        {"name": "lightspeed-llama-data", "mountPath": "/opt/app-root/src/.llama"}
      ]
    }
  },
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "lightspeed-data", "emptyDir": {}}},
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "lightspeed-rag", "emptyDir": {}}},
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "lightspeed-config-stack", "configMap": {"name": "lightspeed-stack", "optional": false}}},
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "lightspeed-config-config", "configMap": {"name": "lightspeed-config", "optional": false}}},
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "lightspeed-config-rhdh-profile", "configMap": {"name": "lightspeed-rhdh-profile", "optional": false}}},
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "lightspeed-llama-data", "emptyDir": {}}}
]
PATCH
)

    oc patch deployment "${deployment_name}" -n "${NAMESPACE}" --type='json' -p "${patch_json}"

    echo "LCS sidecar patched into ${deployment_name}."

    # Scale back up and wait for the single pod to become ready
    echo "Scaling up ${deployment_name}..."
    oc scale deployment "${deployment_name}" -n "${NAMESPACE}" --replicas=1
    oc rollout status deployment "${deployment_name}" -n "${NAMESPACE}" --timeout=300s
}
