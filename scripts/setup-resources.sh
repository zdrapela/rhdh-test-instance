#!/bin/bash

# =============================================================================
# setup-resources.sh — Cluster resource provisioning for RHDH test instances
#
# Applies resources that are always present regardless of which plugins are
# enabled. Running this before plugin configuration ensures:
#   - The catalog is populated from the start (not empty on first login)
#   - Image streams are pre-imported to avoid Docker Hub rate limits
#   - RBAC policies and demo resources are in place before RHDH starts
#
# Catalog entities are registered unconditionally. Even when a backing
# plugin/service is not deployed, having its entities present keeps the
# catalog usable for browsing, RBAC testing, and demo purposes. Plugin
# scripts are responsible for their own infrastructure (deployments, secrets,
# scans) but should not own catalog metadata — that lives here.
#
# Usage (from deploy.sh):  source scripts/setup-resources.sh; setup_resources
# Usage (standalone):      NAMESPACE=rhdh ./scripts/setup-resources.sh
# =============================================================================

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$(dirname "$DIR")"

# =============================================================================
# RHDH Secrets
#
# Create (or idempotently update) the rhdh-secrets Secret with the base URL
# that is known at deploy time. Plugin scripts patch in their own keys later
# (e.g. KEYCLOAK_* from config-keycloak-plugin.sh, LIGHTHOUSE_URL from
# config-lighthouse-plugin.sh) using `oc patch secret rhdh-secrets`.
#
# All keys from the full secret schema are initialised here so that the
# Secret always has a consistent shape. Empty values are replaced by plugin
# scripts as they configure their respective services.
# =============================================================================
create_rhdh_secrets() {
  echo ""
  echo "Creating rhdh-secrets Secret..."

  : "${RHDH_BASE_URL:?RHDH_BASE_URL must be set before setup-resources.sh runs}"

  if oc get secret rhdh-secrets --namespace="${NAMESPACE}" &>/dev/null; then
    # Secret already exists — refresh RHDH_BASE_URL and ensure MCP_TOKEN /
    # BACKEND_SECRET are non-empty (backend.auth.externalAccess requires them).
    local mcp_token="${MCP_TOKEN:-}"
    if [[ -z "${mcp_token}" ]]; then
      mcp_token=$(oc get secret rhdh-secrets -n "${NAMESPACE}" -o jsonpath='{.data.MCP_TOKEN}' 2>/dev/null \
        | (base64 -d 2>/dev/null || true))
    fi
    : "${mcp_token:=mcp-test-token}"
    local backend_secret
    backend_secret=$(oc get secret rhdh-secrets -n "${NAMESPACE}" -o jsonpath='{.data.BACKEND_SECRET}' 2>/dev/null \
      | (base64 -d 2>/dev/null || true))
    if [[ -z "${backend_secret}" ]]; then
      backend_secret=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    fi
    oc patch secret rhdh-secrets -n "${NAMESPACE}" --type=merge \
      -p "{\"stringData\":{\"RHDH_BASE_URL\":\"${RHDH_BASE_URL}\",\"MCP_TOKEN\":\"${mcp_token}\",\"BACKEND_SECRET\":\"${backend_secret}\"}}"
    echo "rhdh-secrets already exists — updated RHDH_BASE_URL / MCP_TOKEN / BACKEND_SECRET."
  else
    # Generate random secrets at deploy time so they are never hardcoded.
    local session_secret backend_secret
    session_secret=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    backend_secret=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)

    oc create secret generic rhdh-secrets \
      --from-literal=RHDH_BASE_URL="${RHDH_BASE_URL}" \
      --from-literal=SESSION_SECRET="${session_secret}" \
      --from-literal=BACKEND_SECRET="${backend_secret}" \
      --from-literal=KEYCLOAK_BASE_URL="${KEYCLOAK_BASE_URL:-}" \
      --from-literal=KEYCLOAK_METADATA_URL="${KEYCLOAK_METADATA_URL:-}" \
      --from-literal=KEYCLOAK_LOGIN_REALM="${KEYCLOAK_LOGIN_REALM:-}" \
      --from-literal=KEYCLOAK_REALM="${KEYCLOAK_REALM:-}" \
      --from-literal=KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-}" \
      --from-literal=KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-}" \
      --from-literal=LIGHTHOUSE_URL="${LIGHTHOUSE_URL:-}" \
      --from-literal=LIGHTHOUSE_SVC_URL="${LIGHTHOUSE_SVC_URL:-}" \
      --from-literal=MCP_TOKEN="${MCP_TOKEN:-mcp-test-token}" \
      --namespace="${NAMESPACE}"

    echo "rhdh-secrets created!"
  fi
}

# GitHub metrics use public access. Only an explicitly supplied SonarQube key
# is merged; inherited GitHub credentials are never copied into the cluster.
configure_scorecard_credentials() {
  [[ "${WITH_SCORECARD:-0}" == "1" ]] || return 0
  local sonarqube_key="${SONARQUBE_API_KEY:-}"
  [[ -n "$sonarqube_key" ]] || return 0
  jq -n --arg sonarqube "$sonarqube_key" '{stringData: {SONARQUBE_API_KEY: $sonarqube}}' |
    oc patch secret rhdh-secrets --namespace="${NAMESPACE}" --type=merge --patch-file=/dev/stdin
}

# =============================================================================
# Catalog Entities
#
# Apply all catalog entity ConfigMaps unconditionally so the catalog is
# populated regardless of which plugins are enabled. All files in
# resources/catalog-entities/ are pre-wrapped ConfigMaps and applied directly.
#
# Entities are organised by Backstage kind, not by plugin:
#   components.yaml — Component entities (services, websites, etc.)
#   operators.yaml  — operator/infrastructure Resource entities
#   resources.yaml  — general Resource entities (storage, etc.)
#   plugins.yaml    — Location entities pointing at upstream plugin catalog-info
#
# Adding entities for a new plugin means adding them to the appropriate file
# for their Backstage kind rather than creating a new per-plugin ConfigMap.
# =============================================================================
apply_catalog_entities() {
  echo ""
  echo "Applying catalog entity ConfigMaps..."

  local catalog_dir="${ROOT_DIR}/resources/catalog-entities"

  # Always apply: plugins.yaml (lightweight Location references)
  for f in plugins.yaml; do
    if [[ -f "${catalog_dir}/${f}" ]]; then
      echo "  Applying: ${f}"
      envsubst '${RHDH_BASE_URL} ${NAMESPACE}' < "${catalog_dir}/${f}" | oc apply -f - --namespace="${NAMESPACE}"
    fi
  done

  # Conditional: components.yaml, resources.yaml — only if lighthouse plugin is explicitly enabled
  if [[ "${PLUGINS:-}" == *"lighthouse"* ]]; then
    for f in components.yaml resources.yaml; do
      if [[ -f "${catalog_dir}/${f}" ]]; then
        echo "  Applying: ${f}"
        envsubst '${RHDH_BASE_URL} ${NAMESPACE}' < "${catalog_dir}/${f}" | oc apply -f - --namespace="${NAMESPACE}"
      fi
    done
  else
    echo "  Skipping: components.yaml, resources.yaml (lighthouse plugin not enabled)"
  fi

  # Conditional: operators.yaml — only if orchestrator is enabled
  if [[ "${WITH_ORCHESTRATOR:-0}" == "1" ]]; then
    if [[ -f "${catalog_dir}/operators.yaml" ]]; then
      echo "  Applying: operators.yaml"
      envsubst '${RHDH_BASE_URL} ${NAMESPACE}' < "${catalog_dir}/operators.yaml" | oc apply -f - --namespace="${NAMESPACE}"
    fi
  else
    echo "  Skipping: operators.yaml (orchestrator not enabled)"
  fi

  echo "Catalog entities applied!"
}

# =============================================================================
# RHDH ConfigMaps
#
# Create (or idempotently update) the app-config-rhdh and dynamic-plugins
# ConfigMaps from their source files in config/. These must exist before
# plugin scripts run since _append_plugin_dynamic_config reads dynamic-plugins.
# =============================================================================
apply_rhdh_configmaps() {
  echo ""
  echo "Applying RHDH ConfigMaps..."

  # Keep conditional catalog locations aligned with the ConfigMaps being mounted.
  local app_config
  app_config=$(WITH_ORCHESTRATOR="${WITH_ORCHESTRATOR:-0}" PLUGINS="${PLUGINS:-}" \
    yq '.catalog.locations |= map(select(
      (.target != "./catalog-entities/operators.yaml" or strenv(WITH_ORCHESTRATOR) == "1") and
      ((.target != "./catalog-entities/components.yaml" and .target != "./catalog-entities/resources.yaml") or
        (strenv(PLUGINS) | contains("lighthouse")))
    ))' "${ROOT_DIR}/config/app-config-rhdh.yaml")
  oc create configmap app-config-rhdh \
    --from-file=app-config-rhdh.yaml=<(printf '%s\n' "$app_config") \
    --namespace="${NAMESPACE}" \
    --dry-run=client -o yaml | oc apply -f - --namespace="${NAMESPACE}"

  # Force-replace dynamic-plugins to ensure a clean slate before plugin
  # scripts append their entries (oc apply merges, which causes duplicates
  # on repeated deploys).
  oc create configmap dynamic-plugins \
    --from-file="${ROOT_DIR}/config/dynamic-plugins.yaml" \
    --namespace="${NAMESPACE}" \
    --dry-run=client -o yaml | oc replace --force -f - --namespace="${NAMESPACE}"

  # Orchestrator app-config (dataIndexService URL) — only when orchestrator is enabled
  if [[ "${WITH_ORCHESTRATOR:-0}" == "1" ]]; then
    echo "Applying orchestrator app-config ConfigMap..."
    local orch_config="${ROOT_DIR}/config/orchestrator-app-config.yaml"
    envsubst '${NAMESPACE}' < "${orch_config}" | \
      oc create configmap app-config-orchestrator \
        --from-file=orchestrator-app-config.yaml=/dev/stdin \
        --namespace="${NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f - --namespace="${NAMESPACE}"
  fi

  echo "RHDH ConfigMaps applied!"
}

# =============================================================================
# RBAC Policies
#
# Apply the RBAC policy ConfigMap that ships with the repo. This is always
# applied so that test users and roles are available from the first login,
# independent of which plugins are enabled.
# =============================================================================
apply_rbac_policies() {
  echo ""
  echo "Applying RBAC policies..."

  oc apply -f "${ROOT_DIR}/config/rbac-policies.yaml" \
    --namespace="${NAMESPACE}"

  echo "RBAC policies applied!"
}

# =============================================================================
# Image Stream Imports
#
# Pre-import container images from external registries to avoid rate-limit
# failures during plugin deployment. Applied before plugin scripts run so the
# images are cached in the cluster registry by the time they are needed.
# =============================================================================
apply_image_stream_imports() {
  echo ""
  echo "Applying image stream imports..."

  local image_stream_dir="${ROOT_DIR}/resources/image-stream-imports"

  if [[ ! -d "$image_stream_dir" ]] || [[ -z "$(ls -A "$image_stream_dir" 2>/dev/null)" ]]; then
    echo "  No image stream imports found — skipping."
    return 0
  fi

  for yaml_file in "${image_stream_dir}"/*.yaml; do
    local name
    name=$(basename "$yaml_file")

    # lighthouse images only needed when lighthouse plugin is enabled
    if [[ "${name}" == "lighthouse-import.yaml" && "${PLUGINS:-}" != *"lighthouse"* ]]; then
      echo "  Skipping: ${name} (lighthouse plugin not enabled)"
      continue
    fi

    echo "  Applying: ${name}"
    oc apply -f "${yaml_file}" --namespace="${NAMESPACE}" || \
      echo "  Warning: Failed to apply ${name} — continuing."
  done

  echo "Image stream imports applied!"
}

# =============================================================================
# Demo Resources
#
# Deploy lightweight example workloads that populate the Topology and
# Kubernetes plugin views. These are applied with graceful error handling
# since they are non-critical and some may depend on images that are still
# being imported (e.g. internal-alpine).
# =============================================================================
apply_demo_resources() {
  echo ""
  echo "Applying demo resources..."

  local examples_dir="${ROOT_DIR}/resources/rhdh-script-examples"

  if [[ ! -d "$examples_dir" ]] || [[ -z "$(ls -A "$examples_dir" 2>/dev/null)" ]]; then
    echo "  No demo resources found — skipping."
    return 0
  fi

  for yaml_file in "${examples_dir}"/*.yaml; do
    local name
    name=$(basename "$yaml_file")
    echo "  Applying: ${name}"
    oc apply -f "${yaml_file}" --namespace="${NAMESPACE}" || \
      echo "  Warning: Failed to apply ${name} — continuing."
  done

  echo "Demo resources applied!"
}

# =============================================================================
# Kubernetes Plugin RBAC
#
# Grant the RHDH service account read access to cluster resources so the
# Kubernetes and Topology plugins can query pods, deployments, services, etc.
# Uses a ClusterRoleBinding so the plugin can read across namespaces.
# =============================================================================
apply_kubernetes_rbac() {
  echo ""
  echo "Applying Kubernetes plugin RBAC..."

  local binding_name="rhdh-kubernetes-plugin-${NAMESPACE}"
  if oc get clusterrolebinding "${binding_name}" &>/dev/null; then
    echo "  ClusterRoleBinding ${binding_name} already exists — skipping."
  else
    oc create clusterrolebinding "${binding_name}" \
      --clusterrole=view \
      --serviceaccount="${NAMESPACE}:default"
    echo "  Created ClusterRoleBinding: ${binding_name}"
  fi

  echo "Kubernetes plugin RBAC applied!"
}

# =============================================================================
# Teardown
#
# Removes all resources created by setup_resources. Called during cleanup.
# =============================================================================
teardown_resources() {
  echo ""
  echo "=============================================="
  echo "Resource Teardown"
  echo "=============================================="

  local catalog_dir="${ROOT_DIR}/resources/catalog-entities"

  echo "Removing rhdh-secrets Secret..."
  oc delete secret rhdh-secrets --namespace="${NAMESPACE}" 2>/dev/null || true

  echo "Removing RHDH ConfigMaps..."
  oc delete configmap app-config-rhdh app-config-nfs app-config-orchestrator dynamic-plugins lightspeed-stack \
    --namespace="${NAMESPACE}" 2>/dev/null || true

  echo "Removing catalog entity ConfigMaps..."
  for yaml_file in "${catalog_dir}"/*.yaml; do
    oc delete -f "${yaml_file}" --namespace="${NAMESPACE}" 2>/dev/null || true
  done

  echo "Removing RBAC policy ConfigMap..."
  oc delete -f "${ROOT_DIR}/config/rbac-policies.yaml" \
    --namespace="${NAMESPACE}" 2>/dev/null || true

  oc delete secret lightspeed-secret --namespace="${NAMESPACE}" --ignore-not-found
  oc delete networkpolicy rhdh-lighthouse-egress rhdh-llm-egress \
    --namespace="${NAMESPACE}" --ignore-not-found


  echo "Removing Kubernetes plugin RBAC..."
  oc delete clusterrolebinding "rhdh-kubernetes-plugin-${NAMESPACE}" 2>/dev/null || true

  echo "Removing demo resources..."
  local examples_dir="${ROOT_DIR}/resources/rhdh-script-examples"
  if [[ -d "$examples_dir" ]]; then
    for yaml_file in "${examples_dir}"/*.yaml; do
      oc delete -f "${yaml_file}" --namespace="${NAMESPACE}" 2>/dev/null || true
    done
  fi

  echo ""
  echo "=============================================="
  echo "Resource teardown complete."
  echo "=============================================="
}

# =============================================================================
# Main Entry Point
# =============================================================================
setup_resources() {
  echo ""
  echo "=============================================="
  echo "Resource Setup"
  echo "=============================================="

  create_rhdh_secrets
  configure_scorecard_credentials
  apply_rhdh_configmaps
  apply_catalog_entities
  apply_rbac_policies
  apply_image_stream_imports
  apply_demo_resources
  apply_kubernetes_rbac
  if [[ "${PLUGINS:-}" == *"lighthouse"* ]]; then
    oc apply -f "${ROOT_DIR}/resources/lighthouse/network-policy.yaml" --namespace="${NAMESPACE}"
  fi

  echo ""
  echo "=============================================="
  echo "Resource setup complete."
  echo "=============================================="
}

main() {
  : "${NAMESPACE:?NAMESPACE must be set. Export it or pass it: NAMESPACE=rhdh ./scripts/setup-resources.sh}"

  if [[ "${TEARDOWN:-false}" == "true" ]]; then
    teardown_resources
  else
    setup_resources
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
