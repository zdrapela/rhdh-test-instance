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
- `version`: `1.11`, `1.9-190-CI`, `next`
- `duration`: optional cleanup timer (e.g., `4h`, `2.5h`; default `3h`)

Examples:
```
/test deploy helm next 4h
/test deploy operator 1.11 2.5h
```

The bot responds with RHDH URL, OpenShift console link, and cluster credentials (from Vault). Users can test custom configurations by modifying config files in the PR branch before deploying. Max two concurrent instances.

Prow job status: https://prow.ci.openshift.org/?repo=redhat-developer%2Frhdh-test-instance&type=presubmit&job=pull-ci-redhat-developer-rhdh-test-instance-main-deploy

## Local Deployment Commands

### Deploy

```bash
# Helm deployment (primary method) — Keycloak OIDC is always auto-configured
make deploy-helm
make deploy-helm VERSION=1.11 NAMESPACE=rhdh

# Helm with optional components (comma-separated)
make deploy-helm WITH=nfs
make deploy-helm WITH=nfs,lightspeed
make deploy-helm WITH=nfs,lightspeed,scorecard,rbac
make deploy-helm WITH=orchestrator
make deploy-helm WITH=all

# Helm with specific version + namespace + components
make deploy-helm VERSION=1.11 NAMESPACE=team-a WITH=nfs,lightspeed,scorecard,rbac

# Helm with PR image
make deploy-helm RHDH_IMAGE=quay.io/rhdh-community/rhdh:pr-1234 WITH=nfs

# Operator deployment (requires install-operator first)
make install-operator VERSION=1.9
make deploy-operator VERSION=1.9 WITH=nfs
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
| `VERSION` | `next` | RHDH version (supports `1.11`, `1.9-190-CI`, `next`) |
| `WITH` | (empty) | Comma-separated optional components: `nfs`, `lightspeed`, `scorecard`, `orchestrator`, `rbac`, or `all` |
| `RHDH_IMAGE` | (empty) | Override RHDH container image (e.g., `quay.io/rhdh-community/rhdh:pr-1234`) |
| `KEYCLOAK_NS` | `rhdh-keycloak` | Namespace for shared Keycloak (all RHDH instances share one Keycloak) |
| `PLUGINS` | (empty) | Infrastructure plugins to deploy/teardown (keycloak is always auto-included) |
| `CATALOG_INDEX_TAG` | auto-detected | Plugin catalog index tag |

## Architecture

```
deploy.sh (entry point)
├── Parses args: method (helm/operator), version, namespace, --with <components>
├── Sources secrets from .env (local) or Vault (CI)
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
- **operator/** — Operator-based deployment: `install-operator.sh` installs the RHDH operator CRD, `deploy.sh` applies the Backstage CR from `subscription.yaml`.
- **resources/keycloak/** — Keycloak plugin resources: Helm values, OIDC client template, users/groups JSON, dynamic-plugins overlay.
- **resources/lightspeed/** — Lightspeed Core Service (LCS) Kubernetes resource templates: Secret, ConfigMaps for Llama Stack config, LCS stack config, and RHDH profile.
- **scripts/plugins/config-keycloak-plugin.sh** — Shared Keycloak deployment: Helm install into `KEYCLOAK_NS`, realm/user/group creation, per-instance OIDC client registration. Auto-detects and fixes stale `KC_HOSTNAME` on cluster rotation.
- **scripts/setup-lightspeed.sh** — Lightspeed Core Service setup: checks for LLM provider credentials, creates LCS Kubernetes resources, patches RHDH deployment with LCS sidecar container.
- **scripts/config-plugins.sh** — Plugin orchestration: sources all plugin scripts, provides `_append_plugin_dynamic_config` helper for appending plugin YAML to the cluster ConfigMap.

### Deployment flow

1. Keycloak is deployed once into a **shared namespace** (`rhdh-keycloak` by default, controlled by `KEYCLOAK_NS`). If it already exists, deployment is skipped (but `KC_HOSTNAME` is auto-corrected if the cluster changed). A realm (`rhdh`), test users, and groups are created (idempotent). Each RHDH instance gets its own OIDC client (`rhdh-client-<namespace>`) with a redirect URI specific to that instance.
2. Environment variables (Keycloak URLs, per-instance client credentials) are written into `rhdh-secrets` in the RHDH namespace.
3. The `dynamic-plugins` ConfigMap is force-replaced with a clean `plugins: []` base, then component configs are appended sequentially. This prevents duplicate entries on re-deploys.
4. `config/app-config-rhdh.yaml` configures RHDH with OIDC auth pointing to the shared Keycloak and catalog entity locations from GitHub.
5. For Helm: the RHDH chart is installed with dynamic plugins config. For Operator: a Backstage CR is applied referencing the ConfigMaps.
6. Optional components are enabled via `--with <components>` (comma-separated):
   - `nfs` — NFS GHCR plugins merged from `config/nfs-dynamic-plugins.yaml`, `app-next` package enabled, `nfs-app-config.yaml` applied as extra ConfigMap
   - `orchestrator` — orchestrator plugins merged from `config/orchestrator-dynamic-plugins.yaml`, serverless operators installed
   - `lightspeed` — intelligent-assistant plugins merged from `config/lightspeed-dynamic-plugins.yaml`. If LLM provider credentials exist (e.g., `ENABLE_OPENAI=true`), LCS sidecar is deployed; otherwise UI loads but shows "Could not load models"
   - `scorecard` — scorecard plugins merged from `config/scorecard-dynamic-plugins.yaml`
   - `rbac` — RBAC permission framework plugin from `config/rbac-dynamic-plugins.yaml`
   - `all` — enables all of the above

### Secrets

- **PR deployments (primary):** secrets pulled automatically from Vault at `vault.ci.openshift.org` under `selfservice/rhdh-test-instance/`
- **Local deployments:** secrets loaded from `.env` file (copy `.env.example` to `.env`); Vault is used when `.env` is absent
- **Lightspeed credentials:** `ENABLE_OPENAI`, `OPENAI_API_KEY`, etc. in `.env` — see `.env.example` for all supported providers

## Required CLI Tools

`oc`, `helm`, `jq`, `curl`, `podman` (or `docker` for container-based operator install)

## Version Resolution

Helm deploy resolves semantic versions (e.g., `1.11`) to the latest patch by querying the Quay.io API for available chart tags. CI versions like `1.9-190-CI` and `next` are passed through directly.
