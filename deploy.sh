#!/usr/bin/env bash
set -e

# Default values
namespace="rhdh"
installation_method=""
WITH_ORCHESTRATOR=0
WITH_NFS=0
WITH_LIGHTSPEED=0
WITH_SCORECARD=0
WITH_RBAC=0

# Available components for --with flag
AVAILABLE_COMPONENTS="nfs, lightspeed, scorecard, orchestrator, rbac (or 'all')"

# Parse arguments
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <installation-method> <version> [--namespace <ns>] [--with <components>] [--without <components>] [--plugins <list>]"
    echo "Installation methods: helm, operator"
    echo "Options:"
    echo "  --namespace <ns>         Deploy to specified namespace (default: rhdh)"
    echo "  --with <components>      Comma-separated list of optional components to enable"
    echo "                           Available: ${AVAILABLE_COMPONENTS}"
    echo "  --without <components>   Comma-separated list of components to exclude (use with --with all)"
    echo "  --plugins <list>         Infrastructure plugins (default: keycloak is always included)"
    echo "Examples:"
    echo "  $0 helm 2.1"
    echo "  $0 helm 2.1 --with nfs,lightspeed"
    echo "  $0 helm 2.1 --with all"
    echo "  $0 helm 2.1 --with all --without orchestrator,lightspeed"
    echo "  $0 helm 2.1 --namespace my-test --with nfs,scorecard"
    echo "  $0 operator 2.1 --with orchestrator"
    exit 1
fi

installation_method="$1"
version="$2"
shift 2

_enable_component() {
    case "$1" in
        all)
            WITH_ORCHESTRATOR=1; WITH_NFS=1; WITH_LIGHTSPEED=1; WITH_SCORECARD=1; WITH_RBAC=1
            ;;
        nfs)           WITH_NFS=1 ;;
        lightspeed)    WITH_LIGHTSPEED=1 ;;
        scorecard)     WITH_SCORECARD=1 ;;
        orchestrator)  WITH_ORCHESTRATOR=1 ;;
        rbac)          WITH_RBAC=1 ;;
        *)
            echo "Warning: Unknown component '$1'. Available: ${AVAILABLE_COMPONENTS}"
            ;;
    esac
}

_disable_component() {
    case "$1" in
        nfs)           WITH_NFS=0 ;;
        lightspeed)    WITH_LIGHTSPEED=0 ;;
        scorecard)     WITH_SCORECARD=0 ;;
        orchestrator)  WITH_ORCHESTRATOR=0 ;;
        rbac)          WITH_RBAC=0 ;;
        *)
            echo "Warning: Unknown component '$1'. Available: ${AVAILABLE_COMPONENTS}"
            ;;
    esac
}

# Parse optional flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)
            namespace="$2"
            shift 2
            ;;
        --with)
            IFS=',' read -ra _components <<< "$2"
            for _comp in "${_components[@]}"; do
                _enable_component "$_comp"
            done
            shift 2
            ;;
        --without)
            IFS=',' read -ra _components <<< "$2"
            for _comp in "${_components[@]}"; do
                _disable_component "$_comp"
            done
            shift 2
            ;;
        --plugins)
            PLUGINS="$2"
            shift 2
            ;;
        *)
            echo "Error: Unknown option: $1"
            echo "Usage: $0 <installation-method> <version> [--namespace <ns>] [--with <components>] [--without <components>] [--plugins <list>]"
            exit 1
            ;;
    esac
done

# Print enabled components
_enabled=()
[[ "${WITH_NFS}" == "1" ]] && _enabled+=("nfs")
[[ "${WITH_ORCHESTRATOR}" == "1" ]] && _enabled+=("orchestrator")
[[ "${WITH_LIGHTSPEED}" == "1" ]] && _enabled+=("lightspeed")
[[ "${WITH_SCORECARD}" == "1" ]] && _enabled+=("scorecard")
[[ "${WITH_RBAC}" == "1" ]] && _enabled+=("rbac")
if [[ ${#_enabled[@]} -gt 0 ]]; then
    echo "Enabled components: ${_enabled[*]}"
fi

export WITH_ORCHESTRATOR
export WITH_NFS
export WITH_LIGHTSPEED
export WITH_SCORECARD
export WITH_RBAC

# Validate installation method
if [[ "$installation_method" != "helm" && "$installation_method" != "operator" ]]; then
    echo "Error: Installation method must be either 'helm' or 'operator'"
    echo "Usage: $0 <installation-method> <version>"
    [[ "$OPENSHIFT_CI" == "true" ]] && gh_comment "❌ **Error: Invalid installation method** 🚫\n\n📝 **Provided installation method:** \`$installation_method\`\n\nInstallation method must be either 'helm' or 'operator' 🔄"
    exit 1
fi

[[ "${OPENSHIFT_CI}" != "true" ]] && source .env
source scripts/deployment-common.sh
validate_rhdh_version "$version"
resolve_catalog_image
prepare_deploy_workdir

# Resolve every requested ref before creating or changing any cluster resources.
for tool in jq yq skopeo; do
    command -v "$tool" >/dev/null || { echo "Error: Required tool '$tool' is not installed." >&2; exit 1; }
done
fetch_catalog_defaults "${DEPLOY_WORKDIR}/dynamic-plugins.default.yaml"
mapfile -t PLUGIN_CONFIG_FILES < <(plugin_config_files)
bash scripts/check-plugin-refs.sh "${DEPLOY_WORKDIR}/dynamic-plugins.default.yaml" "${PLUGIN_CONFIG_FILES[@]}"

# Create or switch to the specified namespace
oc new-project "$namespace" || oc project "$namespace"

# Resolve cluster router base and RHDH URL early so setup-resources.sh and
# plugin scripts have them available (e.g. for creating the rhdh-secrets Secret).
export CLUSTER_ROUTER_BASE
CLUSTER_ROUTER_BASE=$(oc get route console -n openshift-console -o=jsonpath='{.spec.host}' | sed 's/^[^.]*\.//')
if oc get route console -n openshift-console -o=jsonpath='{.spec.tls.termination}' 2>/dev/null | grep -q .; then
    RHDH_PROTOCOL="https"
else
    RHDH_PROTOCOL="http"
fi
if [[ "$installation_method" == "helm" ]]; then
    export RHDH_BASE_URL="${RHDH_PROTOCOL}://redhat-developer-hub-${namespace}.${CLUSTER_ROUTER_BASE}"
else
    export RHDH_BASE_URL="${RHDH_PROTOCOL}://backstage-developer-hub-${namespace}.${CLUSTER_ROUTER_BASE}"
fi
echo "RHDH URL: ${RHDH_BASE_URL}"

# Apply cluster resources that are always present (catalog entities, RBAC
# policies, app-config and dynamic-plugins ConfigMaps, image stream pre-imports,
# demo workloads). Run before plugin scripts so all base config exists before
# plugins append to it.
export NAMESPACE="$namespace"
source scripts/setup-resources.sh
setup_resources

# ── Shared Keycloak (always) ──────────────────────────────────────────────────
# Keycloak OIDC is core auth, not an optional plugin. Call its setup functions
# directly instead of going through the PLUGINS infrastructure system.
source scripts/config-plugins.sh

deploy_keycloak
create_users_and_groups_keycloak
register_keycloak_client
config_secrets_for_keycloak_plugins
apply_keycloak_labels

# Optional infrastructure plugins (lighthouse, etc.) — only if explicitly requested
if [[ -n "${PLUGINS:-}" ]]; then
    main "$PLUGINS"
fi

if [[ "${WITH_NFS}" == "1" ]]; then
    _append_plugin_dynamic_config "${PWD}/config/nfs-dynamic-plugins.yaml" "NFS"
    oc create configmap app-config-nfs \
        --from-file=nfs-app-config.yaml="${PWD}/config/nfs-app-config.yaml" \
        --namespace="${NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f - --namespace="${NAMESPACE}"
fi

if [[ "${WITH_ORCHESTRATOR}" == "1" ]]; then
    _append_plugin_dynamic_config "${PWD}/config/orchestrator-dynamic-plugins.yaml" "Orchestrator"
fi

if [[ "${WITH_LIGHTSPEED}" == "1" ]]; then
    _append_plugin_dynamic_config "${PWD}/config/lightspeed-dynamic-plugins.yaml" "Lightspeed"
    _append_plugin_dynamic_config "${PWD}/config/mcp-dynamic-plugins.yaml" "MCP"
    source scripts/setup-lightspeed.sh
    setup_lightspeed
fi

if [[ "${WITH_SCORECARD}" == "1" ]]; then
    _append_plugin_dynamic_config "${PWD}/config/scorecard-dynamic-plugins.yaml" "Scorecard"
fi

if [[ "${WITH_RBAC}" == "1" ]]; then
    _append_plugin_dynamic_config "${PWD}/config/rbac-dynamic-plugins.yaml" "RBAC"
fi

if [[ "$installation_method" == "helm" ]]; then
    source helm/deploy.sh "$namespace" "$version"
else
    # In CI, auto-install the operator if not already present (CI has Linux tools available)
    # TODO(RHIDP-12127): move operator install and orchestrator support to CI step registry script
    if [[ "${OPENSHIFT_CI}" == "true" ]] && ! oc get crd/backstages.rhdh.redhat.com &>/dev/null; then
        echo "Operator not found, installing automatically (CI mode)..."
        source operator/install-operator.sh "$version"
    fi
    source operator/deploy.sh "$namespace" "$version"
fi

# Wait for the deployment to be ready
if [[ "$installation_method" == "helm" ]]; then
    deployment_name=redhat-developer-hub
else
    deployment_name=backstage-developer-hub
fi
oc rollout status "deployment/${deployment_name}" -n "$namespace" --timeout=500s

echo "
RHDH_BASE_URL : 
$RHDH_BASE_URL
"
