#!/bin/bash
set -eo pipefail

# Deploy an RHDH 2.1 instance using the current Backstage API.
namespace="${1:?Usage: deploy.sh <namespace> <version>}"
version="${2:?Usage: deploy.sh <namespace> <version>}"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/deployment-common.sh"
validate_rhdh_version "$version"
resolve_catalog_image
prepare_deploy_workdir

# Never select an arbitrary served version or fall back to an older API.
if ! oc get crd backstages.rhdh.redhat.com -o json \
    | jq -e '.spec.versions[] | select(.name == "v1alpha5" and .served)' >/dev/null; then
    echo "Error: The operator must serve rhdh.redhat.com/v1alpha5. Run make install-operator VERSION=2.1." >&2
    exit 1
fi

if [[ "${WITH_ORCHESTRATOR:-0}" == "1" ]]; then
    echo "Installing Orchestrator infrastructure from release-2.1..."
    curl -fsSL "https://raw.githubusercontent.com/redhat-developer/rhdh-operator/release-2.1/config/profile/rhdh/plugin-infra/plugin-infra.sh" \
        -o "${DEPLOY_WORKDIR}/plugin-infra.sh"
    bash "${DEPLOY_WORKDIR}/plugin-infra.sh" apply --branch release-2.1
    wait_for_crd sonataflowplatforms.sonataflow.org
fi

# Component plugin refs merge with the flavour defaults by package name.
# The Orchestrator flavour creates SonataFlow dependencies and NetworkPolicies.
export WITH_NFS WITH_ORCHESTRATOR WITH_LIGHTSPEED
export LIGHTSPEED_HAS_PROVIDER="${LIGHTSPEED_HAS_PROVIDER:-false}"
bash "${DEPLOY_ROOT}/operator/render-cr.sh" "$namespace" "$version" > "${DEPLOY_WORKDIR}/backstage.json"
oc apply --validate=strict -f "${DEPLOY_WORKDIR}/backstage.json" -n "$namespace"
oc wait --for=condition=Deployed backstage/developer-hub -n "$namespace" --timeout=500s
