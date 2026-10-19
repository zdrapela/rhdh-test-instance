#!/bin/bash
set -e

# Deploys an RHDH instance via the operator.
# Assumes the operator is already installed (run install-operator.sh first).

namespace="$1"
version="$2"

if [[ -z "$namespace" || -z "$version" ]]; then
    echo "Usage: $0 <namespace> <version>"
    exit 1
fi

# Determine branch based on version type
# Semantic versions (e.g., "1.9") use release branches; CI versions extract major.minor; "next" uses main
if [[ "$version" =~ ^([0-9]+\.[0-9]+)$ ]]; then
    branch="release-${version}"
elif [[ "$version" =~ ^([0-9]+\.[0-9]+)-[0-9]+-CI$ ]]; then
    branch="release-${BASH_REMATCH[1]}"
elif [[ "$version" == "next" ]]; then
    branch="main"
else
    echo "Error: Invalid version '${version}'. Use semantic version (e.g., '1.9'), CI version (e.g., '1.10-114-CI'), or 'next'."
    exit 1
fi

echo "Using operator branch: ${branch}"

# Ensure operator is installed
if ! oc get crd/backstages.rhdh.redhat.com &>/dev/null; then
    echo "Error: RHDH operator not found. Run 'make install-operator' first."
    exit 1
fi

# Install orchestrator infrastructure if requested
if [[ "${WITH_ORCHESTRATOR}" == "1" ]]; then
    if ! oc get subscription -n openshift-serverless --no-headers 2>/dev/null | grep -q .; then
        echo "Installing serverless operator..."
        infra_branch="${branch}"
        serverless_url="https://raw.githubusercontent.com/redhat-developer/rhdh-operator/refs/heads/${infra_branch}/config/profile/rhdh/plugin-infra/serverless.yaml"
        if ! curl -sfL -o /tmp/serverless.yaml "$serverless_url"; then
            infra_branch="main"
            serverless_url="https://raw.githubusercontent.com/redhat-developer/rhdh-operator/refs/heads/main/config/profile/rhdh/plugin-infra/serverless.yaml"
            curl -sfL -o /tmp/serverless.yaml "$serverless_url"
        fi
        oc apply -f /tmp/serverless.yaml
        rm /tmp/serverless.yaml
    else
        echo "Serverless operator subscription already exists."
    fi

    if ! oc get subscription -n openshift-serverless-logic --no-headers 2>/dev/null | grep -q .; then
        echo "Installing serverless logic operator..."
        infra_branch="${infra_branch:-${branch}}"
        logic_url="https://raw.githubusercontent.com/redhat-developer/rhdh-operator/refs/heads/${infra_branch}/config/profile/rhdh/plugin-infra/serverless-logic.yaml"
        if ! curl -sfL -o /tmp/serverless-logic.yaml "$logic_url"; then
            logic_url="https://raw.githubusercontent.com/redhat-developer/rhdh-operator/refs/heads/main/config/profile/rhdh/plugin-infra/serverless-logic.yaml"
            curl -sfL -o /tmp/serverless-logic.yaml "$logic_url"
        fi
        oc apply -f /tmp/serverless-logic.yaml
        rm /tmp/serverless-logic.yaml
    else
        echo "Serverless logic operator subscription already exists."
    fi

    echo "Waiting for serverless operator pods..."
    for i in $(seq 1 60); do
        if oc get pods -n openshift-serverless --no-headers 2>/dev/null | grep -q Running && \
           oc get pods -n openshift-serverless-logic --no-headers 2>/dev/null | grep -q Running; then
            echo "Serverless operator pods are running."
            break
        fi
        sleep 10
    done

    # Ensure SonataFlow platform exists in the target namespace
    if ! oc get sonataflowplatform -n "$namespace" --no-headers 2>/dev/null | grep -q .; then
        echo "Creating SonataFlowPlatform in namespace ${namespace}..."
        cat <<SFEOF | oc apply -n "$namespace" -f -
apiVersion: sonataflow.org/v1alpha08
kind: SonataFlowPlatform
metadata:
  name: sonataflow-platform
spec:
  services:
    dataIndex:
      enabled: true
      podTemplate:
        container:
          resources: {}
    jobService:
      enabled: true
      podTemplate:
        container:
          resources: {}
SFEOF
        echo "Waiting for SonataFlow data-index service..."
        for i in $(seq 1 60); do
            if oc get svc sonataflow-platform-data-index-service -n "$namespace" &>/dev/null; then
                echo "SonataFlow data-index service is ready."
                break
            fi
            sleep 5
        done
    else
        echo "SonataFlowPlatform already exists in ${namespace}."
    fi
fi

# Catalog index tag defaults to the major.minor version, or "next" for next
if [[ "$version" == "next" ]]; then
    export CATALOG_INDEX_TAG="${CATALOG_INDEX_TAG:-next}"
else
    export CATALOG_INDEX_TAG="${CATALOG_INDEX_TAG:-$(echo "$version" | grep -oE '^[0-9]+\.[0-9]+')}"
fi
echo "Using catalog index tag: ${CATALOG_INDEX_TAG}"

# The dynamic-plugins ConfigMap was seeded in deploy.sh from the base config
# and may have been augmented by plugin setup scripts. Append additional
# plugin entries here if requested, then apply the Backstage CR.
# All plugins use chart/catalog-index defaults via {{inherit}} — no version overrides.
ORCH_CONFIG_BLOCK=""
if [[ "${WITH_ORCHESTRATOR}" == "1" ]]; then
    echo "Creating orchestrator app-config ConfigMap..."
    cat <<ORCHCFG | oc apply -n "$namespace" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config-orchestrator
data:
  app-config-orchestrator.yaml: |
    orchestrator:
      dataIndexService:
        url: http://sonataflow-platform-data-index-service.${namespace}.svc.cluster.local
ORCHCFG
    ORCH_CONFIG_BLOCK="
        - name: app-config-orchestrator"
fi
# Build NFS env var block if requested
NFS_ENV_BLOCK=""
NFS_CONFIG_BLOCK=""
if [[ "${WITH_NFS}" == "1" ]]; then
    # RHDH 2.1+ ships NFS as the default `app` package — do not set
    # APP_CONFIG_app_packageName=app-next (package removed; breaks startup).
    echo "Enabling NFS extras (module federation) for operator instance..."
    NFS_ENV_BLOCK="
        - name: ENABLE_STANDARD_MODULE_FEDERATION
          value: \"true\""
    # app-config-nfs ConfigMap is created in deploy.sh when WITH_NFS=1
    NFS_CONFIG_BLOCK="
        - name: app-config-nfs"
fi

# Build custom image line if RHDH_IMAGE is set (e.g. for NFS PR images)
IMAGE_LINE=""
if [[ -n "${RHDH_IMAGE}" ]]; then
    echo "Overriding RHDH image: ${RHDH_IMAGE}"
    IMAGE_LINE="    image: ${RHDH_IMAGE}"
fi

# Detect the correct Backstage API version from the cluster
BACKSTAGE_API_VERSION=$(oc api-resources --api-group=rhdh.redhat.com -o name 2>/dev/null | head -1)
BACKSTAGE_API_VERSION=$(oc get crd backstages.rhdh.redhat.com -o jsonpath='{.spec.versions[?(@.served==true)].name}' 2>/dev/null | awk '{print $NF}')
echo "Using Backstage API version: rhdh.redhat.com/${BACKSTAGE_API_VERSION}"

# Build the list of appConfig ConfigMaps
GUEST_AUTH_BLOCK=""
if [[ -n "${GUEST_AUTH_CONFIG_MAP_ENTRY:-}" ]]; then
    GUEST_AUTH_BLOCK="
        - name: app-config-guest-auth"
fi

# Lightspeed: operator path uses the same dynamic-plugins + lightspeed-secret
# created in deploy.sh. Native LCS sidecar is Helm-only for now; without an
# LLM provider the IA UI still loads (models list may be empty).
if [[ "${WITH_LIGHTSPEED}" == "1" ]]; then
    echo "Lightspeed plugins and secret are configured via deploy.sh overlays."
fi
if [[ "${WITH_SCORECARD}" == "1" ]]; then
    echo "Scorecard plugins are configured via deploy.sh overlays."
fi
if [[ "${WITH_RBAC}" == "1" ]]; then
    echo "RBAC plugins are configured via deploy.sh overlays."
fi

# RHDH 2.1 operator enables the intelligent-assistant flavour by default when
# flavours is unset. That injects ref:// IA plugins + LCS sidecar and duplicates
# our ConfigMap overlays (InstallException: Duplicate OCI plugin). Disable the
# default flavour; WITH=lightspeed enables IA via lightspeed-dynamic-plugins.yaml.
echo "Disabling default intelligent-assistant flavour (plugins come from ConfigMap overlays)."

# Generate the Backstage CR with all env vars inline
cat <<EOF | oc apply -f - -n "$namespace"
apiVersion: rhdh.redhat.com/${BACKSTAGE_API_VERSION}
kind: Backstage
metadata:
  name: developer-hub
spec:
  application:
${IMAGE_LINE:+$IMAGE_LINE
}    appConfig:
      configMaps:
        - name: app-config-rhdh${GUEST_AUTH_BLOCK}${NFS_CONFIG_BLOCK}${ORCH_CONFIG_BLOCK}
      mountPath: /opt/app-root/src
    extraFiles:
      mountPath: /opt/app-root/src
    replicas: 1
    route:
      enabled: true
    dynamicPluginsConfigMapName: dynamic-plugins
    extraEnvs:
      envs:
        - name: RHDH_BASE_URL
          value: "${RHDH_BASE_URL}"
        - name: CATALOG_INDEX_IMAGE
          value: "quay.io/rhdh/plugin-catalog-index:${CATALOG_INDEX_TAG}"${NFS_ENV_BLOCK}
      secrets:
        - name: rhdh-secrets
  database:
    enableLocalDb: true
  flavours:
    - name: intelligent-assistant
      enabled: false
EOF

echo "Waiting for RHDH deployment to roll out..."
if oc rollout status deployment/backstage-developer-hub -n "$namespace" --timeout=300s 2>&1; then
    echo "Deployment ready."
else
    echo "Error: Timed out waiting for deployment to be ready."
fi
