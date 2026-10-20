#!/bin/bash
set -e

# Installs the RHDH operator on the cluster (one-time setup).
# The operator is installed in a dedicated namespace (default: rhdh-operator-system)
# so that deleting RHDH deployment namespaces does not uninstall the operator.
# Usage: ./operator/install-operator.sh <version>

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-rhdh-operator-system}"

version="$1"

if [[ -z "$version" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 1.9"
    echo "         $0 next"
    exit 1
fi

# Determine branch and version argument based on version type
if [[ "$version" =~ ^([0-9]+\.[0-9]+)$ ]]; then
    branch="release-${version}"
    version_arg="-v ${version}"
elif [[ "$version" =~ ^([0-9]+\.[0-9]+)-[0-9]+-CI$ ]]; then
    branch="release-${BASH_REMATCH[1]}"
    version_arg="-v ${BASH_REMATCH[1]}"
elif [[ "$version" == "next" ]]; then
    branch="main"
    version_arg="--next"
else
    echo "Error: Invalid version '${version}'. Use semantic version (e.g., '1.9'), CI version (e.g., '1.10-114-CI'), or 'next'."
    exit 1
fi

# Fall back to main if the release branch doesn't exist in the operator repo
SCRIPT_URL="https://raw.githubusercontent.com/redhat-developer/rhdh-operator/refs/heads/${branch}/.rhdh/scripts/install-rhdh-catalog-source.sh"
if ! curl -sfI "$SCRIPT_URL" >/dev/null 2>&1; then
    echo "Branch '${branch}' not found in rhdh-operator repo, falling back to 'main'..."
    branch="main"
    SCRIPT_URL="https://raw.githubusercontent.com/redhat-developer/rhdh-operator/refs/heads/${branch}/.rhdh/scripts/install-rhdh-catalog-source.sh"
fi

echo "Using operator branch: ${branch}, version arg: ${version_arg}"

# Check if RHDH operator is already installed (CRD exists AND operator CSV is present)
if oc get crd/backstages.rhdh.redhat.com &>/dev/null && oc get csv -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -q rhdh-operator; then
    echo "RHDH operator is already installed in namespace ${OPERATOR_NAMESPACE}. Skipping."
    exit 0
fi

# Workaround for pushing to ARO cluster registries: https://access.redhat.com/solutions/6022011
# TODO: remove this when this is done by the install-rhdh-catalog-source.sh script
oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"disableRedirect":true}}' --type=merge

# Downloads and runs install script for CatalogSource
curl -LO "$SCRIPT_URL"
chmod +x install-rhdh-catalog-source.sh

# Fix hardcoded 'kubeadmin' username — on ARO clusters the admin user is
# 'kube:admin' and the colon breaks HTTP Basic Auth in skopeo/docker-registry.
# Use a dummy username since the internal registry validates the OAuth token, not the username.
CURRENT_USER=$(oc whoami)
if [[ "$CURRENT_USER" != "kubeadmin" ]]; then
    echo "Patching install script for non-kubeadmin cluster (user: ${CURRENT_USER})..."
    sed -i -e 's/skopeo login -u kubeadmin/skopeo login -u openshift/g' install-rhdh-catalog-source.sh
    sed -i -e 's/--docker-username=kubeadmin/--docker-username=openshift/g' install-rhdh-catalog-source.sh
    chmod +x install-rhdh-catalog-source.sh
fi

# Override the hardcoded namespace so the operator lives in a dedicated namespace
# that won't be deleted when RHDH deployment namespaces are removed.
sed -i "s/NAMESPACE_SUBSCRIPTION=\"rhdh-operator\"/NAMESPACE_SUBSCRIPTION=\"${OPERATOR_NAMESPACE}\"/" install-rhdh-catalog-source.sh

./install-rhdh-catalog-source.sh ${version_arg} --install-operator rhdh
# rm install-rhdh-catalog-source.sh

# Wait for the CRD to be available (macOS lacks GNU timeout, use a manual loop)
WAIT_ELAPSED=0
while ! oc get crd/backstages.rhdh.redhat.com >/dev/null 2>&1; do
    if [[ $WAIT_ELAPSED -ge 300 ]]; then
        echo "Error: Timed out waiting for Backstage CRD creation."
        break
    fi
    echo "Waiting for Backstage CRD to be created..."
    sleep 20
    WAIT_ELAPSED=$((WAIT_ELAPSED + 20))
done
if oc get crd/backstages.rhdh.redhat.com >/dev/null 2>&1; then
    echo "Backstage CRD is created."
fi

echo "RHDH operator installed successfully."
