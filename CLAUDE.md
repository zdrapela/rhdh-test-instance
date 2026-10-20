# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository provides **PR-driven deployment of Red Hat Developer Hub (RHDH) test instances** on OpenShift clusters. Users open a PR (optionally with custom configuration changes) and use the `/test deploy` slash command in PR comments to trigger automated deployment via Prow CI. The system handles cluster provisioning, shared Keycloak auth setup, RHDH installation, and posts deployment URLs and credentials back to the PR.

Two installation methods are supported (Helm and Operator), with optional components (NFS, Lightspeed, Scorecard, Orchestrator, RBAC). Local deployment is also possible as a secondary use case. The codebase is entirely Bash scripts and YAML configuration.

## GitHub PR Workflow (Primary Use Case)

Users deploy test instances by commenting on PRs:

```
/test deploy <install-type> <version> [duration]
```

- `install-type`: `helm` or `operator`
- `version`: `2.1`, a 2.1 patch release, or `2.1-128-CI`
- `duration`: optional cleanup timer (e.g., `4h`, `2.5h`; default `3h`)

Examples:
```
/test deploy helm 2.1 4h
/test deploy helm 2.1-128-CI 4h
/test deploy operator 2.1 2.5h
```

The bot responds with RHDH URL, OpenShift console link, and cluster credentials (from Vault). Users can test custom configurations by modifying config files in the PR branch before deploying. Max two concurrent instances.

Prow job status: https://prow.ci.openshift.org/?repo=redhat-developer%2Frhdh-test-instance&type=presubmit&job=pull-ci-redhat-developer-rhdh-test-instance-main-deploy

## Local Deployment Commands

### Deploy

```bash
# Helm deployment (primary method) — Keycloak OIDC is always auto-configured
make deploy-helm
make deploy-helm VERSION=2.1 NAMESPACE=rhdh

# 2.1 test day (NFS-focused)
make deploy-helm VERSION=2.1 WITH=nfs
make deploy-helm VERSION=2.1 WITH=nfs,lightspeed,scorecard,rbac
make deploy-helm VERSION=2.1 WITH=all WITHOUT=orchestrator

# Helm with optional components (comma-separated)
make deploy-helm WITH=nfs
make deploy-helm WITH=nfs,lightspeed
make deploy-helm WITH=nfs,lightspeed,scorecard,rbac
make deploy-helm WITH=orchestrator
make deploy-helm WITH=all
make deploy-helm WITH=all WITHOUT=orchestrator,lightspeed

# Helm with specific version + namespace + components
make deploy-helm VERSION=2.1 NAMESPACE=team-a WITH=nfs,lightspeed,scorecard,rbac
make deploy-helm VERSION=2.1 WITH=all WITHOUT=orchestrator

# Helm with PR image
make deploy-helm RHDH_IMAGE=quay.io/rhdh-community/rhdh:pr-1234 WITH=nfs

# Operator deployment (requires install-operator first)
make install-operator VERSION=2.1
make deploy-operator VERSION=2.1 WITH=nfs
make deploy-operator VERSION=2.1 WITH=nfs,lightspeed,scorecard,rbac
```

### Shared Keycloak

```bash
make deploy-keycloak      # Deploy shared Keycloak (auto-runs on every deploy)
make undeploy-keycloak    # Remove shared Keycloak (only after all instances are gone)
```

### Teardown

```bash
make undeploy-helm        # Remove Helm-deployed RHDH
make undeploy-operator    # Remove Operator-deployed RHDH
make undeploy-keycloak    # Remove the shared Keycloak infra (only after all instances are gone)
make undeploy-infra       # Remove orchestrator infra chart
make clean                # Delete the RHDH namespace (does NOT remove shared Keycloak)
```

### Debugging

```bash
make status    # Show pod status in namespace
make logs      # Tail RHDH pod logs
make url       # Print the RHDH portal URL
```

### Makefile Variables

| Variable | Default | Description |
|---|---|---|
| `NAMESPACE` | `rhdh` | OpenShift namespace for RHDH |
| `VERSION` | `2.1` | RHDH 2.1 release line, patch release, or CI chart build |
| `WITH` | (empty) | Comma-separated optional components: `nfs`, `lightspeed`, `scorecard`, `orchestrator`, `rbac`, or `all` |
| `WITHOUT` | (empty) | Comma-separated components to exclude (use with `WITH=all` to skip specific ones) |
| `RHDH_IMAGE` | (empty) | Override RHDH container image (e.g., `quay.io/rhdh-community/rhdh:pr-1234`) |
| `KEYCLOAK_NS` | `rhdh-keycloak` | Namespace for shared Keycloak (all RHDH instances share one Keycloak) |
| `PLUGINS` | (empty) | Infrastructure plugins to deploy/teardown (keycloak is always auto-included) |
| `CATALOG_INDEX_TAG` | (empty) | Optional plugin catalog index tag override |
| `CATALOG_INDEX_IMAGE` | (bundled with chart/Operator) | Optional full catalog image; overrides `CATALOG_INDEX_TAG` |

## Architecture

```
deploy.sh (entry point)
├── Parses args: method (helm/operator), version, namespace, --with <components>, --without <components>
├── Sources .env (local; required) or uses CI-injected Vault secrets (OPENSHIFT_CI=true)
├── Bootstraps the shared Operator in CI if missing, then verifies the installed 2.1 RC
├── Validates requested ref:// plugins against the supplied catalog before instance changes
├── Deploys shared Keycloak via scripts/plugins/config-keycloak-plugin.sh (into KEYCLOAK_NS)
│   └── Auto-fixes KC_HOSTNAME if cluster has changed (pool rotation)
├── Creates namespace and app-config ConfigMap from config/
├── Resets dynamic-plugins ConfigMap (oc replace --force for clean slate)
├── Appends component configs to dynamic-plugins ConfigMap:
│   ├── Keycloak (always) — resources/keycloak/dynamic-plugins.yaml
│   ├── NFS — config/nfs-dynamic-plugins.yaml + config/nfs-app-config.yaml
│   ├── Lightspeed — config/lightspeed-dynamic-plugins.yaml + LCS sidecar
│   ├── Scorecard — config/scorecard-dynamic-plugins.yaml
│   ├── Orchestrator — config/orchestrator-dynamic-plugins.yaml
│   └── RBAC — config/rbac-dynamic-plugins.yaml
└── Delegates to:
    ├── helm/deploy.sh     — Resolves version from Quay API, installs RHDH Helm chart
    └── operator/deploy.sh — Applies Backstage CR after optional operator install
```

### Key directories

- **config/** — RHDH application config and dynamic plugin definitions. Base configs (`app-config-rhdh.yaml`, `dynamic-plugins.yaml`) are always applied. Component-specific configs (`nfs-*`, `lightspeed-*`, `scorecard-*`, `rbac-*`) are conditionally appended based on `WITH=` flags.
- **helm/** — Helm-specific deployment: `deploy.sh` resolves chart versions from Quay, `value_file.yaml` provides Helm overrides. `extraAppConfig` is dynamically built based on enabled components.
- **operator/** — `install-operator.sh` installs the RHDH operator; `render-cr.sh` renders `backstage.yaml` with the current `rhdh.redhat.com/v1alpha5` API, and `deploy.sh` applies it with strict validation. Image and replica overrides use `spec.deployment.patch`.
- **resources/keycloak/** — Keycloak plugin resources: Helm values, OIDC client template, users/groups JSON, dynamic-plugins overlay.
- **resources/lightspeed/** — LCS Secret and unified provider definitions. Stack defaults come from the upstream 2.1 chart or a supplied `LIGHTSPEED_STACK_FILE`.
- **scripts/plugins/config-keycloak-plugin.sh** — Shared Keycloak deployment: Helm install into `KEYCLOAK_NS`, realm/user/group creation, per-instance OIDC client registration. Auto-detects and fixes stale `KC_HOSTNAME` on cluster rotation.
- **scripts/setup-lightspeed.sh** — Creates the LCS stack ConfigMap and credentials Secret consumed by the Helm chart or Operator flavour, selecting providers through the existing `ENABLE_*` flags.
- **scripts/config-plugins.sh** — Plugin orchestration: sources all plugin scripts, provides `_append_plugin_dynamic_config` helper for appending plugin YAML to the cluster ConfigMap.

### Deployment flow

1. Keycloak is deployed once into a **shared namespace** (`rhdh-keycloak` by default, controlled by `KEYCLOAK_NS`). If it already exists, deployment is skipped (but `KC_HOSTNAME` is auto-corrected if the cluster changed). A realm (`rhdh`), test users, and groups are created (idempotent). Each RHDH instance gets its own OIDC client (`rhdh-client-<namespace>`) with a redirect URI specific to that instance.
2. Environment variables (Keycloak URLs, per-instance client credentials) are written into `rhdh-secrets` in the RHDH namespace.
3. The `dynamic-plugins` ConfigMap is force-replaced with a clean `plugins: []` base, then component configs are appended sequentially. This prevents duplicate entries on re-deploys.
4. `config/app-config-rhdh.yaml` configures RHDH with OIDC auth pointing to the shared Keycloak and catalog entity locations from GitHub.
5. For Helm: the RHDH chart is installed with dynamic plugins config. For Operator: a Backstage CR is applied referencing the ConfigMaps.
6. Optional components are enabled via `--with <components>` (comma-separated):
   - `nfs` — Catalog references from `config/nfs-dynamic-plugins.yaml` (global header, homepage, extensions, bulk import, TechDocs, Kubernetes, Topology, etc.). Home and theme are built into the 2.1 app. `nfs-app-config.yaml` preserves homepage/language/quickstart settings; NFS is already the default frontend.
   - `orchestrator` — orchestrator plugins merged from `config/orchestrator-dynamic-plugins.yaml`, serverless operators installed
   - `lightspeed` — intelligent-assistant plugins merged from `config/lightspeed-dynamic-plugins.yaml`. If LLM provider credentials exist (e.g., `ENABLE_OPENAI=true`), LCS sidecar is deployed; otherwise UI loads but shows "Could not load models"
   - `scorecard` — scorecard plugins merged from `config/scorecard-dynamic-plugins.yaml`
   - `rbac` — RBAC permission framework plugin from `config/rbac-dynamic-plugins.yaml`
   - `all` — enables all of the above
7. `--without <components>` can be used with `--with all` to exclude specific components (e.g., `--with all --without orchestrator,lightspeed`).

### Secrets

- **PR deployments (primary):** when `OPENSHIFT_CI=true`, `deploy.sh` skips `.env` and uses secrets injected by Prow from Vault at `vault.ci.openshift.org` under `selfservice/rhdh-test-instance/`. This repo does not call the Vault CLI.
- **Local deployments:** `deploy.sh` always runs `source .env` when not in CI. Copy `.env.example` to `.env` first (file must exist or deploy fails). Empty `KEYCLOAK_*` placeholders are fine — Keycloak setup writes real values into `rhdh-secrets`. There is no local Vault fallback.
- **Lightspeed credentials:** `ENABLE_OPENAI`, `OPENAI_API_KEY`, etc. in `.env` — see `.env.example` for all supported providers. Only needed for `WITH=lightspeed`.

## Required CLI Tools

`oc`, `helm`, `jq`, `curl`, Mike Farah's `yq` v4, `skopeo`, Python 3, Bash 4.3+, and `podman` (or `docker` for container-based operator install)

## Version Resolution

Helm resolves `2.1` to the latest available tag on that release line via Quay. Specific 2.1 patch/CI tags are passed through. Other release lines and `next` are rejected. Operator installation uses a published 2.1 IIB directly through OLM, resolving its tag to an immutable digest. `OPERATOR_IIB_IMAGE` selects a recorded IIB. Never rebuild Operator bundles/catalogs or patch downloaded installer scripts. Existing installations are verified before reuse; optional `OPERATOR_EXPECTED_IMAGE`, `OPERATOR_EXPECTED_RHDH_IMAGE`, and `OPERATOR_EXPECTED_CATALOG_IMAGE` enforce per-run RC expectations.

## Plugin Configuration Migration Rules

- Preserve existing configuration and enabled/disabled integrations when migrating.
- Use built-in defaults or `ref://` entries, with `enabled: true/false`. Do not hardcode plugin artifact URLs, versions, digests, or plugin paths, or rewrite bundled defaults.
- Omit Scorecard for Helm `2.1-119-CI`: all nine bundled Scorecard artifacts lack discovery metadata (RHDHBUGS-3834). The pinned Operator RC and latest 2.1 catalog have valid metadata; try normal defaults there. If an optional plugin blocks deployment, capture the evidence and skip it for that deployment rather than adding fragile packaging workarounds.
- Use the selected Helm chart's or Operator's bundled catalog by default. Explicit catalog overrides remain supported. Missing references require a supplied catalog containing installable defaults; do not generate supplemental defaults or silently drop plugins. The user approved removing unavailable Tekton, ACR, Nexus, Quay backend and TechDocs search module refs from NFS. MCP and Lighthouse still require additional defaults. Additional UI-only catalogs do not resolve `ref://` entries.
- Use the current Backstage CR API (`v1alpha5`), not an older served version.
- Both deployment methods must set `SEGMENT_TEST_MODE=true`.
- Keep Keycloak infrastructure unchanged during this migration.

## Validation

Run `bash tests/migration.sh` for cluster-free migration regression checks. Set `RHDH_TEST_CHART` to a local 2.1 chart archive to also render Helm variants. `bash operator/render-cr.sh <namespace> 2.1` renders the Operator CR without cluster access (`RHDH_BASE_URL` is required).
