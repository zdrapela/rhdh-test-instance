#!/usr/bin/env bash
# Render without accessing the cluster, for deployment and schema validation.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/deployment-common.sh"
namespace="${1:?Usage: render-cr.sh <namespace> <version>}"
version="${2:?Usage: render-cr.sh <namespace> <version>}"
validate_rhdh_version "$version"
resolve_catalog_image

yq -o=json '.' "${DEPLOY_ROOT}/operator/backstage.yaml" | jq \
    --arg namespace "$namespace" --arg url "${RHDH_BASE_URL:?RHDH_BASE_URL must be set}" \
    --arg catalog "$CATALOG_INDEX_IMAGE" --arg image "${RHDH_IMAGE:-}" \
    --argjson nfs "${WITH_NFS:-0}" --argjson orchestrator "${WITH_ORCHESTRATOR:-0}" \
    --argjson lightspeed "${WITH_LIGHTSPEED:-0}" --argjson provider "${LIGHTSPEED_HAS_PROVIDER:-false}" '
    .metadata.namespace = $namespace |
    .spec.application.extraEnvs.envs += [
        {name: "RHDH_BASE_URL", value: $url},
        {name: "CATALOG_INDEX_IMAGE", value: $catalog, containers: ["install-dynamic-plugins"]}
    ] |
    if $nfs == 1 then
        .spec.application.appConfig.configMaps += [{name: "app-config-nfs"}]
    else . end |
    if $orchestrator == 1 then
        .spec.application.appConfig.configMaps += [{name: "app-config-orchestrator"}]
    else . end |
    .spec.flavours = [
        {name: "intelligent-assistant", enabled: ($lightspeed == 1 and $provider)},
        {name: "orchestrator", enabled: ($orchestrator == 1)}
    ] |
    if $lightspeed == 1 and $provider then
        .spec.application.extraEnvs.secrets += [{name: "lightspeed-secret", containers: ["lightspeed-core"]}] |
        .spec.application.extraFiles.configMaps += [{
            name: "lightspeed-stack", key: "lightspeed-stack.yaml",
            mountPath: "/app-root", containers: ["lightspeed-core"]
        }]
    else . end |
    if $image != "" then
        .spec.deployment.patch.spec.template.spec.containers[0].image = $image |
        .spec.deployment.patch.spec.template.spec.initContainers = [{
            name: "install-dynamic-plugins", image: $image
        }]
    else . end
'
