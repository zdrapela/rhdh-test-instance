#!/bin/bash
set -eo pipefail

# Install a published RHDH 2.1 IIB directly through OLM. Never rebuild bundles
# or catalogs. OPERATOR_IIB_IMAGE can select an immutable, previously recorded RC.
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-rhdh-operator-system}"
version="${1:-2.1}"
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/deployment-common.sh"
validate_rhdh_version "$version"

subscription=$(oc get subscriptions.operators.coreos.com rhdh -n "$OPERATOR_NAMESPACE" -o json 2>/dev/null || true)
if [[ -n "$subscription" && -z "${OPERATOR_IIB_IMAGE:-}" ]]; then
    verify_operator_installation
    exit 0
fi

oc get crd subscriptions.operators.coreos.com >/dev/null
if [[ -z "${OPERATOR_IIB_IMAGE:-}" ]]; then
    ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
    architecture=$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')
    [[ "$architecture" != amd64 ]] || architecture=x86_64
    OPERATOR_IIB_IMAGE="quay.io/rhdh/iib:2.1-v${ocp_version%.*}-${architecture}"
fi
digest=$(skopeo --override-os linux --override-arch amd64 inspect --no-tags \
    --format '{{.Digest}}' "docker://${OPERATOR_IIB_IMAGE}")
OPERATOR_IIB_IMAGE="${OPERATOR_IIB_IMAGE%@*}"
if [[ "${OPERATOR_IIB_IMAGE##*/}" == *:* ]]; then OPERATOR_IIB_IMAGE="${OPERATOR_IIB_IMAGE%:*}"; fi
OPERATOR_IIB_IMAGE="${OPERATOR_IIB_IMAGE}@${digest}"
echo "Using published Operator catalog: ${OPERATOR_IIB_IMAGE}"

if [[ -n "$subscription" ]]; then
    source_name=$(jq -r '.spec.source' <<< "$subscription")
    source_namespace=$(jq -r '.spec.sourceNamespace' <<< "$subscription")
    installed_image=$(oc get catalogsource "$source_name" -n "$source_namespace" -o jsonpath='{.spec.image}')
    if [[ "$installed_image" != "$OPERATOR_IIB_IMAGE" ]]; then
        echo "Error: Existing Operator uses ${installed_image}, not ${OPERATOR_IIB_IMAGE}." >&2
        exit 1
    fi
    verify_operator_installation
    exit 0
fi

if oc get namespace "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    oc get operatorgroups.operators.coreos.com -n "$OPERATOR_NAMESPACE" -o json | jq -e '
        all(.items[]; .metadata.name == "rhdh-operator-group")' >/dev/null || {
        echo "Error: ${OPERATOR_NAMESPACE} already contains another OperatorGroup." >&2
        exit 1
    }
fi

jq -n --arg namespace "$OPERATOR_NAMESPACE" --arg image "$OPERATOR_IIB_IMAGE" '{
    apiVersion: "v1", kind: "List", items: [
        {apiVersion: "v1", kind: "Namespace", metadata: {name: $namespace}},
        {apiVersion: "operators.coreos.com/v1", kind: "OperatorGroup",
         metadata: {name: "rhdh-operator-group", namespace: $namespace}, spec: {}},
        {apiVersion: "operators.coreos.com/v1alpha1", kind: "CatalogSource",
         metadata: {name: "rhdh-fast-2.1", namespace: "openshift-marketplace"},
         spec: {sourceType: "grpc", image: $image, displayName: "RHDH 2.1 RC", publisher: "Red Hat"}}
    ]
}' | oc apply -f -
oc wait catalogsource/rhdh-fast-2.1 -n openshift-marketplace \
    --for=jsonpath='{.status.connectionState.lastObservedState}'=READY --timeout=300s

jq -n --arg namespace "$OPERATOR_NAMESPACE" '{
    apiVersion: "operators.coreos.com/v1alpha1", kind: "Subscription",
    metadata: {name: "rhdh", namespace: $namespace},
    spec: {name: "rhdh", channel: "fast-2.1", source: "rhdh-fast-2.1",
           sourceNamespace: "openshift-marketplace", installPlanApproval: "Automatic"}
}' | oc apply -f -

deadline=$((SECONDS + 300))
while true; do
    csv=$(oc get subscriptions.operators.coreos.com rhdh -n "$OPERATOR_NAMESPACE" \
        -o jsonpath='{.status.installedCSV}')
    if [[ -n "$csv" ]] && oc get clusterserviceversion "$csv" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        break
    fi
    if ((SECONDS >= deadline)); then
        echo "Error: Timed out waiting for the published Operator bundle. Check the Subscription and InstallPlan for image pull errors." >&2
        exit 1
    fi
    sleep 5
done
oc wait "clusterserviceversion/${csv}" -n "$OPERATOR_NAMESPACE" \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
oc rollout status deployment/rhdh-operator -n "$OPERATOR_NAMESPACE" --timeout=300s
oc wait --for=condition=Established crd/backstages.rhdh.redhat.com --timeout=60s
verify_operator_installation
