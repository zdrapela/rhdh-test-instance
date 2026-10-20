#!/bin/bash
set -eo pipefail

# Installs the RHDH operator on the cluster (one-time setup).
# The operator is installed in a dedicated namespace (default: rhdh-operator-system)
# so that deleting RHDH deployment namespaces does not uninstall the operator.
# Usage: ./operator/install-operator.sh <version>

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-rhdh-operator-system}"

version="${1:-2.1}"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/deployment-common.sh"
validate_rhdh_version "$version"
prepare_deploy_workdir

branch="release-2.1"

SCRIPT_URL="https://raw.githubusercontent.com/redhat-developer/rhdh-operator/refs/heads/${branch}/.rhdh/scripts/install-rhdh-catalog-source.sh"
echo "Using operator branch: ${branch}, release line: 2.1"

# OLM v0 uses a CSV; OLM v1 uses a cluster-scoped ClusterExtension instead.
if oc get crd/backstages.rhdh.redhat.com -o json 2>/dev/null | jq -e '.spec.versions[] | select(.name == "v1alpha5" and .served)' >/dev/null && \
    { oc get csv -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -q rhdh-operator || \
      oc get clusterextension rhdh -o json 2>/dev/null | jq -e --arg ns "$OPERATOR_NAMESPACE" \
        '.spec.namespace == $ns and any(.status.conditions[]?; .type == "Installed" and .status == "True")' >/dev/null; }; then
    echo "RHDH operator is already installed in namespace ${OPERATOR_NAMESPACE}. Skipping."
    exit 0
fi

# Downloads and runs install script for CatalogSource
installer="${DEPLOY_WORKDIR}/install-rhdh-catalog-source.sh"
curl -fsSL "$SCRIPT_URL" -o "${installer}.upstream"

# Fix hardcoded 'kubeadmin' username — on ARO clusters the admin user is
# 'kube:admin' and the colon breaks HTTP Basic Auth in skopeo/docker-registry.
# Use a dummy username since the internal registry validates the OAuth token, not the username.
# Override the hardcoded namespace so the operator lives in a dedicated namespace
# that won't be deleted when RHDH deployment namespaces are removed.
sed -e 's/login -u kubeadmin/login -u openshift/g' \
    -e 's/--docker-username=kubeadmin/--docker-username=openshift/g' \
    -e 's/kubeadmin:${token}/openshift:${token}/g' \
    -e "s/NAMESPACE_SUBSCRIPTION=\"rhdh-operator\"/NAMESPACE_SUBSCRIPTION=\"${OPERATOR_NAMESPACE}\"/" \
    "${installer}.upstream" > "$installer"

bash "$installer" -v 2.1 --install-operator rhdh

# Wait for the CRD to be available (macOS lacks GNU timeout, use a manual loop)
WAIT_ELAPSED=0
while ! oc get crd/backstages.rhdh.redhat.com -o json 2>/dev/null \
    | jq -e '.spec.versions[] | select(.name == "v1alpha5" and .served)' >/dev/null; do
    if [[ $WAIT_ELAPSED -ge 300 ]]; then
        echo "Error: Timed out waiting for the Backstage v1alpha5 API."
        exit 1
    fi
    echo "Waiting for the Backstage v1alpha5 API..."
    sleep 20
    WAIT_ELAPSED=$((WAIT_ELAPSED + 20))
done
oc wait --for=condition=Established crd/backstages.rhdh.redhat.com --timeout=60s

echo "RHDH operator installed successfully."
