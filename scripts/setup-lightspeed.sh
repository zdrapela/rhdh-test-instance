#!/usr/bin/env bash
#
# Lightspeed setup for RHDH
#
# Detects configured LLM providers and creates the Secret needed by the
# Helm chart's built-in LCS sidecar (intelligentAssistant.existingSecret).
#
# The sidecar itself is deployed by the Helm chart — no custom patching needed.
#
# Required env vars: NAMESPACE
# Optional env vars (from .env): ENABLE_OPENAI, OPENAI_API_KEY, ENABLE_VLLM,
#   VLLM_URL, VLLM_API_KEY, etc.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LCS_RESOURCES="${ROOT_DIR}/resources/lightspeed"

LIGHTSPEED_HAS_PROVIDER=false

has_lightspeed_provider() {
    LIGHTSPEED_HAS_PROVIDER=false
    if [[ "${ENABLE_OPENAI:-}" == "true" && -n "${OPENAI_API_KEY:-}" ]]; then LIGHTSPEED_HAS_PROVIDER=true; fi
    if [[ "${ENABLE_VLLM:-}" == "true" && -n "${VLLM_URL:-}" ]]; then LIGHTSPEED_HAS_PROVIDER=true; fi
    if [[ "${ENABLE_OLLAMA:-}" == "true" && -n "${OLLAMA_URL:-}" ]]; then LIGHTSPEED_HAS_PROVIDER=true; fi
    if [[ "${ENABLE_VERTEX_AI:-}" == "true" && -n "${VERTEX_AI_PROJECT:-}" ]]; then LIGHTSPEED_HAS_PROVIDER=true; fi
}

setup_lightspeed_secret() {
    echo ""
    echo "=============================================="
    echo "Lightspeed — Secret Setup"
    echo "=============================================="

    has_lightspeed_provider

    if [[ "${LIGHTSPEED_HAS_PROVIDER}" == "false" ]]; then
        echo ""
        echo "  No LLM provider credentials found."
        echo "  The Intelligent Assistant UI will load but cannot connect to an LLM."
        echo "  Add credentials to .env and redeploy to enable."
        echo ""
        return 0
    fi

    echo "LLM provider detected. Creating lightspeed-secret..."

    envsubst < "${LCS_RESOURCES}/lightspeed-secret.yaml" \
        | oc apply -f - --namespace="${NAMESPACE}"

    echo "Lightspeed secret created in ${NAMESPACE}."

    # Ensure MCP_TOKEN is in rhdh-secrets (patch if secret already exists)
    if [[ -n "${MCP_TOKEN:-}" ]]; then
        echo "Patching rhdh-secrets with MCP_TOKEN..."
        oc patch secret rhdh-secrets -n "${NAMESPACE}" --type=merge \
            -p "{\"stringData\":{\"MCP_TOKEN\":\"${MCP_TOKEN}\"}}"
    fi
}

# MCP static token auth lives in config/app-config-rhdh.yaml (extraAppConfig).
# Do not kubectl-patch the Helm app-config ConfigMap — that fights Helm SSA.

# Patch the LCS / IA stack config to restrict visible OpenAI models (when present).
# RHDH 2.1 chart names the ConfigMap *-ia-stack with key lightspeed-stack.yaml;
# older charts used *-lightspeed-config / config.yaml.
patch_lcs_allowed_models() {
    echo ""
    echo "=============================================="
    echo "LCS — Patching allowed_models for OpenAI"
    echo "=============================================="

    if [[ "${ENABLE_OPENAI:-}" != "true" ]]; then
        echo "OpenAI not enabled. Skipping allowed_models patch."
        return 0
    fi

    local cm_name="" data_key=""
    for candidate in \
        "redhat-developer-hub-ia-stack:lightspeed-stack.yaml" \
        "redhat-developer-hub-lightspeed-config:config.yaml"; do
        local name="${candidate%%:*}" key="${candidate##*:}"
        if oc get configmap "${name}" -n "${NAMESPACE}" &>/dev/null; then
            cm_name="${name}"
            data_key="${key}"
            break
        fi
    done

    if [[ -z "${cm_name}" ]]; then
        echo "LCS/IA stack ConfigMap not found. Skipping allowed_models patch."
        return 0
    fi

    local config_yaml
    config_yaml=$(oc get configmap "${cm_name}" -n "${NAMESPACE}" -o json \
        | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d.get('${data_key}',''))")

    if [[ -z "${config_yaml}" ]]; then
        echo "ConfigMap ${cm_name} has no key ${data_key}. Skipping."
        return 0
    fi

    # Only patch if allowed_models is not already set and the legacy remote::openai
    # block exists (2.1 default stack uses api_key_env and may omit this block).
    if echo "${config_yaml}" | grep -q "allowed_models"; then
        echo "allowed_models already configured. Skipping."
        return 0
    fi
    if ! echo "${config_yaml}" | grep -q "provider_type: remote::openai"; then
        echo "No remote::openai provider block in ${cm_name}. Skipping allowed_models patch."
        return 0
    fi

    local patch_file
    patch_file=$(mktemp)

    echo "${config_yaml}" \
      | python3 -c "
import sys, re

content = sys.stdin.read()

pattern = r'(provider_type: remote::openai\s*\n\s*config:\s*\n\s*api_key:[^\n]*)'
match = re.search(pattern, content)
if match:
    content = content[:match.end()] + '''
        allowed_models:
          - gpt-4o-mini
          - gpt-4.1-mini
          - gpt-4.1-nano
          - gpt-4o''' + content[match.end():]

sys.stdout.write(content)
" > "${patch_file}"

    oc create configmap "${cm_name}" \
        --from-file="${data_key}=${patch_file}" \
        --namespace="${NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f - --namespace="${NAMESPACE}"

    rm -f "${patch_file}"
    echo "LCS config patched with allowed_models."
}
