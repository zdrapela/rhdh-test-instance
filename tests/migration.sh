#!/usr/bin/env bash
# Cluster-free regression checks. Optionally set RHDH_TEST_CHART to a local 2.1
# chart archive to also exercise the Helm deployment script and rendered pods.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR=$(mktemp -d "${TMPDIR:-${PWD}}/rhdh-migration-test.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
source "${ROOT}/scripts/deployment-common.sh"

export WITH_NFS=1 WITH_ORCHESTRATOR=1 WITH_LIGHTSPEED=1 WITH_SCORECARD=1 WITH_RBAC=1 PLUGINS=lighthouse
mapfile -t configs < <(plugin_config_files)

# Synthetic registry entries test resolution and plugin-path preservation without
# maintaining actual package pins or needing registry/cluster credentials.
for file in "${configs[@]}"; do yq -o=json '.' "$file"; done | jq -s '
    {includes: ["dynamic-plugins.default.yaml"],
     plugins: [(.[] | if type == "array" then . else .plugins end)[]]}
' > "${WORK_DIR}/dynamic-plugins.json"
jq '{plugins: [.plugins[] |
        {package: ("oci://registry.example.test/plugins/" + (.package | ltrimstr("ref://")) + ":test!exported-plugin")}
    ]}' "${WORK_DIR}/dynamic-plugins.json" > "${WORK_DIR}/defaults.json"
bash "${ROOT}/scripts/check-plugin-refs.sh" "${WORK_DIR}/defaults.json" "${configs[@]}"

jq '.plugins |= map(select(.package | contains("backstage-community-plugin-tekton") | not))' \
    "${WORK_DIR}/defaults.json" > "${WORK_DIR}/missing.json"
if bash "${ROOT}/scripts/check-plugin-refs.sh" "${WORK_DIR}/missing.json" "${configs[@]}" > "${WORK_DIR}/error" 2>&1; then
    echo "Missing catalog definitions must fail validation." >&2
    exit 1
fi
jq -Rs -e 'contains("backstage-community-plugin-tekton")' "${WORK_DIR}/error" >/dev/null
if ! bash "${ROOT}/scripts/check-plugin-refs.sh" "${WORK_DIR}/defaults.json" \
    "${ROOT}/config/dynamic-plugins.yaml" "${ROOT}/resources/keycloak/dynamic-plugins.yaml" >/dev/null; then
    exit 1
fi
if bash "${ROOT}/scripts/check-plugin-refs.sh" "${WORK_DIR}/defaults.json" \
    "${configs[@]}" "${ROOT}/config/nfs-dynamic-plugins.yaml" > "${WORK_DIR}/error" 2>&1; then
    echo "Duplicate plugin overrides must fail validation." >&2
    exit 1
fi
jq '{plugins: [.plugins[0]]}' "${WORK_DIR}/defaults.json" > "${WORK_DIR}/direct.json"
if bash "${ROOT}/scripts/check-plugin-refs.sh" "${WORK_DIR}/defaults.json" \
    "${WORK_DIR}/direct.json" > "${WORK_DIR}/error" 2>&1; then
    echo "Direct package URLs must fail validation." >&2
    exit 1
fi
jq -Rs -e 'contains("must use ref://")' "${WORK_DIR}/error" >/dev/null

export RHDH_BASE_URL=https://rhdh.example.test LIGHTSPEED_HAS_PROVIDER=true
export CATALOG_INDEX_IMAGE=registry.example.test:5000/custom/catalog@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
export RHDH_IMAGE=registry.example.test:5000/rhdh:custom
bash "${ROOT}/operator/render-cr.sh" test-ns 2.1 > "${WORK_DIR}/backstage.json"
jq -e '
    .apiVersion == "rhdh.redhat.com/v1alpha5" and
    (.spec.application | has("image") or has("replicas") | not) and
    .spec.deployment.patch.spec.replicas == 1 and
    .spec.deployment.patch.spec.template.spec.automountServiceAccountToken == true and
    .spec.deployment.patch.spec.template.spec.containers[0].image == env.RHDH_IMAGE and
    .spec.deployment.patch.spec.template.spec.initContainers[0].image == env.RHDH_IMAGE and
    any(.spec.application.extraEnvs.envs[]; .name == "SEGMENT_TEST_MODE" and .value == "true") and
    any(.spec.application.extraEnvs.envs[]; .name == "CATALOG_INDEX_IMAGE" and
        .value == env.CATALOG_INDEX_IMAGE and .containers == ["install-dynamic-plugins"]) and
    any(.spec.application.extraEnvs.secrets[]; .name == "lightspeed-secret" and .containers == ["lightspeed-core"]) and
    any(.spec.application.extraFiles.configMaps[]; .name == "lightspeed-stack" and .containers == ["lightspeed-core"])
' "${WORK_DIR}/backstage.json" >/dev/null

WITH_NFS=0 WITH_ORCHESTRATOR=0 WITH_LIGHTSPEED=0 RHDH_IMAGE='' \
    bash "${ROOT}/operator/render-cr.sh" test-ns 2.1 > "${WORK_DIR}/base.json"
jq -e '
    (.spec.flavours | all(.enabled == false)) and
    (.spec.application.appConfig.configMaps | length == 1) and
    (.spec.application.extraEnvs.secrets | length == 1) and
    (.spec.deployment.patch.spec.template.spec | has("initContainers") | not)
' "${WORK_DIR}/base.json" >/dev/null
if bash "${ROOT}/operator/render-cr.sh" test-ns next > "${WORK_DIR}/error" 2>&1; then
    echo "Unsupported release lines must fail before rendering." >&2
    exit 1
fi

image_values "$CATALOG_INDEX_IMAGE" | jq -e '
    .registry == "registry.example.test:5000" and .repository == "custom/catalog" and
    .tag == "" and (.digest | startswith("sha256:"))' >/dev/null

# OLM can return before a newly installed operator creates its CRDs. Wait for
# object creation before asking kubectl/oc for the Established condition.
(
    attempts=0
    oc() {
        if [[ "$1" == get ]]; then
            attempts=$((attempts + 1))
            ((attempts >= 2))
        fi
    }
    sleep() { :; }
    wait_for_crd example.test
    [[ "$attempts" == 2 ]]
)
(
    oc() { return 1; }
    sleep() { SECONDS=$((SECONDS + 300)); }
    if wait_for_crd missing.test > "${WORK_DIR}/error" 2>&1; then
        echo "Missing CRDs must time out." >&2
        exit 1
    fi
)

source "${ROOT}/scripts/setup-lightspeed.sh"
jq -n '{
    service: {port: 8080}, inference: {providers: []},
    mcp_servers: [{name: "existing-tools", url: "http://localhost:7007/tools"}],
    customization: {profile_path: "/app-root/existing-profile.py"}
}' > "${WORK_DIR}/stack.json"
ENABLE_OPENAI=true ENABLE_VLLM=false ENABLE_OLLAMA=false ENABLE_VERTEX_AI=false \
    render_lightspeed_stack "${WORK_DIR}/stack.json" \
    | yq -o=json '.' | jq -e '
        .service.port == 8080 and .mcp_servers[0].name == "existing-tools" and
        .customization.profile_path == "/app-root/existing-profile.py" and
        (.inference.providers | length == 2 and .[0].type == "sentence_transformers" and
            .[1].type == "openai" and .[1].api_key_env == "OPENAI_API_KEY" and
            .[1].allowed_models == ["gpt-4o-mini", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o"])' >/dev/null
ENABLE_OPENAI=false ENABLE_VLLM=true ENABLE_OLLAMA=true ENABLE_VERTEX_AI=true \
    render_lightspeed_stack "${WORK_DIR}/stack.json" \
    | yq -o=json '.inference.providers' | jq -e '
        map(.type) == ["sentence_transformers", "vllm", "ollama", "vertexai"]' >/dev/null

if [[ -n "${RHDH_TEST_CHART:-}" ]]; then
    export RHDH_TEST_RENDERED="${WORK_DIR}/helm.yaml"
    export RHDH_TEST_CONFIG="${WORK_DIR}/dynamic-plugins.json"
    # Stub cluster operations; exercise the real Helm argument builder and chart.
    (
        oc() {
            if [[ "$*" == *"jsonpath="* ]]; then
                yq '.' "$RHDH_TEST_CONFIG"
            elif [[ "$1 ${2:-}" == "get pods" ]]; then
                printf '%s\n' 'existing-serverless-pod Running'
            fi
            return 0
        }
        helm() {
            if [[ "$1" == upgrade ]]; then
                shift 4
                command helm template redhat-developer-hub "$RHDH_TEST_CHART" "$@" > "$RHDH_TEST_RENDERED"
            fi
            return 0
        }
        export CLUSTER_ROUTER_BASE=apps.example.test
        for WITH_ORCHESTRATOR in 0 1; do
            for LIGHTSPEED_HAS_PROVIDER in false true; do
                export WITH_ORCHESTRATOR LIGHTSPEED_HAS_PROVIDER
                source "${ROOT}/helm/deploy.sh" test-ns 2.1-128-CI
                yq -o=json -I=0 '.' "$RHDH_TEST_RENDERED" | jq -se \
                    --argjson provider "$LIGHTSPEED_HAS_PROVIDER" --argjson orchestrator "$WITH_ORCHESTRATOR" '
                    [.[] | select(.kind == "Deployment") | .spec.template.spec.containers[]] as $containers |
                    any($containers[]; .name == "backstage-backend" and
                        any(.env[]; .name == "SEGMENT_TEST_MODE" and .value == "true")) and
                    (any($containers[]; .name == "lightspeed-core") == $provider) and
                    (any(.[]; .kind == "SonataFlowPlatform") == ($orchestrator == 1))
                ' >/dev/null
            done
        done
    )
    yq -o=json -I=0 '.' "$RHDH_TEST_RENDERED" | jq -se '
        [.[] | select(.kind == "Deployment") | .spec.template.spec.containers[]] as $containers |
        any($containers[]; .name == "backstage-backend" and
            any(.env[]; .name == "SEGMENT_TEST_MODE" and .value == "true") and
            .image == env.RHDH_IMAGE) and
        any($containers[]; .name == "lightspeed-core" and
            any(.envFrom[]; .secretRef.name == "lightspeed-secret"))
    ' >/dev/null
fi

echo "Migration regression checks passed."
