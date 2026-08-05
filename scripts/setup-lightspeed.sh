#!/usr/bin/env bash
#
# Lightspeed setup for RHDH
#
# Detects configured LLM providers and creates the Secret needed by the
# Helm chart's built-in LCS sidecar (global.lightspeed.enabled=true).
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

# Patch the Helm-generated app-config ConfigMap to include MCP static token auth.
# The Helm chart creates `redhat-developer-hub-app-config` which sets
# backend.auth.externalAccess with only the legacy type. Since Backstage replaces
# arrays (does not merge), this overwrites our custom backend.auth entries in
# app-config-rhdh.yaml. We patch the Helm ConfigMap post-install to add both the
# legacy entry AND the static MCP token entry.
patch_helm_appconfig_for_mcp() {
    echo ""
    echo "=============================================="
    echo "MCP — Patching Helm app-config for static token auth"
    echo "=============================================="

    local cm_name="redhat-developer-hub-app-config"
    if ! oc get configmap "${cm_name}" -n "${NAMESPACE}" &>/dev/null; then
        echo "Warning: ConfigMap ${cm_name} not found. Skipping MCP patch."
        return 0
    fi

    # The Helm chart stores config under "app-config.yaml" (dots in key name
    # break jsonpath, so use python to extract)
    local existing_yaml
    existing_yaml=$(oc get configmap "${cm_name}" -n "${NAMESPACE}" \
        -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['data'].get('app-config.yaml',''))")

    local patch_file
    patch_file=$(mktemp)

    # Replace the backend.auth section using Python string manipulation (stdlib only)
    echo "${existing_yaml}" \
      | python3 -c "
import sys, re

content = sys.stdin.read()

auth_replacement = '''  auth:
    keys:
      - secret: '\${BACKEND_SECRET}'
    externalAccess:
      - type: legacy
        options:
          secret: '\${BACKEND_SECRET}'
          subject: legacy-default-config
      - type: static
        options:
          token: '\${MCP_TOKEN}'
          subject: mcp-clients'''

# Match the auth: block under backend: up to the next peer-level key
pattern = r'(  auth:\n(?:    .*\n)*)'
match = re.search(pattern, content)
if match:
    content = content[:match.start()] + auth_replacement + '\n' + content[match.end():]
else:
    content = content.replace('backend:\n', 'backend:\n' + auth_replacement + '\n', 1)

sys.stdout.write(content)
" > "${patch_file}"

    # Preserve the default-app-config.yaml key if it exists
    local default_config_file
    default_config_file=$(mktemp)
    oc get configmap "${cm_name}" -n "${NAMESPACE}" \
        -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['data'].get('default-app-config.yaml',''))" \
        > "${default_config_file}" 2>/dev/null || true

    local from_file_args=("--from-file=app-config.yaml=${patch_file}")
    if [[ -s "${default_config_file}" ]]; then
        from_file_args+=("--from-file=default-app-config.yaml=${default_config_file}")
    fi

    oc create configmap "${cm_name}" \
        "${from_file_args[@]}" \
        --namespace="${NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f - --namespace="${NAMESPACE}"

    rm -f "${patch_file}" "${default_config_file}"
    echo "Helm app-config patched with MCP static token auth."
}

# Patch the LCS config to restrict visible OpenAI models
patch_lcs_allowed_models() {
    echo ""
    echo "=============================================="
    echo "LCS — Patching allowed_models for OpenAI"
    echo "=============================================="

    local cm_name="redhat-developer-hub-lightspeed-config"
    if ! oc get configmap "${cm_name}" -n "${NAMESPACE}" &>/dev/null; then
        echo "LCS config ConfigMap not found. Skipping allowed_models patch."
        return 0
    fi

    if [[ "${ENABLE_OPENAI:-}" != "true" ]]; then
        echo "OpenAI not enabled. Skipping allowed_models patch."
        return 0
    fi

    local config_yaml
    config_yaml=$(oc get configmap "${cm_name}" -n "${NAMESPACE}" \
        -o jsonpath='{.data.config\.yaml}')

    # Only patch if allowed_models is not already set
    if echo "${config_yaml}" | grep -q "allowed_models"; then
        echo "allowed_models already configured. Skipping."
        return 0
    fi

    local patch_file
    patch_file=$(mktemp)

    # Add allowed_models under the OpenAI provider's config block (stdlib only)
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
        --from-file="config.yaml=${patch_file}" \
        --namespace="${NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f - --namespace="${NAMESPACE}"

    rm -f "${patch_file}"
    echo "LCS config patched with allowed_models."
}
