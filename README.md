# RHDH Test Instance

A comprehensive test instance setup for **Red Hat Developer Hub (RHDH)** on OpenShift, providing a ready-to-use developer portal with Keycloak OIDC authentication, dynamic plugins, and optional components like NFS, Lightspeed, Scorecard, Orchestrator, and RBAC.

## Overview

This project provides automated deployment scripts and configuration files to set up fully functional RHDH test instances on OpenShift. A shared Keycloak instance is automatically deployed for authentication, and multiple RHDH instances can share it.

### Features

- 🤖 **GitHub PR Integration** with `/test` command for on-demand deployments
- 📦 **Multiple Install Types**: Support for both Helm and Operator installation methods
- 🔄 **RHDH 2.1 Deployments**: Deploy the latest 2.1 chart or a specific 2.1 build (`2.1`, `2.1-128-CI`)
- 🔐 **Shared Keycloak OIDC**: Automatic Keycloak setup in a shared namespace — all instances share one Keycloak
- 🧩 **Optional Components**: Enable NFS, Lightspeed, Scorecard, Orchestrator, RBAC via `WITH=`
- 🌐 **Cluster Information Sharing**: Automatic sharing of deployment URLs, OpenShift console access, and cluster credentials
- 👥 **Runtime Test Users**: Keycloak test users provisioned with a generated password stored in a cluster Secret
- 🏠 **Local Deployment**: Support for local development and testing environments
- ⚡ **Resource Management**: Automatic cleanup with configurable timers and resource limits
- 🎯 **Instance Limits**: Maximum of two concurrent test instances to manage resource usage
- 💬 **User-friendly feedback** with deployment status comments and live URLs

## GitHub PR Workflow Integration

Deploy test environments directly from Pull Requests using slash commands and test different configurations without local setup.

### Slash Commands

The bot supports flexible deployment commands directly from PR comments:

```bash
/test deploy <install-type> <version> [duration]
```

**Parameters:**

- `install-type`: `helm` or `operator`
- `version`: Version to deploy (see supported versions below)
- `duration`: Optional cleanup timer (e.g., `4h`, `2.5h`)

**Examples:**

```bash
/test deploy helm 2.1 4h           # Deploy RHDH 2.1 with Helm, cleanup after 4 hours
/test deploy operator 2.1 2.5h     # Deploy RHDH 2.1 with Operator, cleanup after 2.5 hours
/test deploy helm 2.1              # Deploy the latest 2.1 chart with the default 3h duration
/test deploy operator 2.1-128-CI   # Select the 2.1 operator release line
```

### How to Use PR Integration

1. **Comment on any PR on rhdh-test-instance repo:**

   ```bash
    /test deploy helm 2.1 4h
   ```

### Feedback Loop

The bot provides comprehensive feedback through PR comments for eg:

```text
🚀 Deployed RHDH version: 2.1 using helm

🌐 RHDH URL: https://redhat-developer-hub-rhdh.apps.rhdh-4-17-us-east-2-kz69l.rhdh-qe.devcluster.openshift.com

🖥️ OpenShift Console: Open Console

🔑 Cluster Credentials: Available in vault under ocp-cluster-creds with keys:
• Username: CLUSTER_ADMIN_USERNAME
• Password: CLUSTER_ADMIN_PASSWORD

⏰ Cluster Availability: Next 1 hours
```

### Live Status of deploy Job

**Prow Status:**
<https://prow.ci.openshift.org/?repo=redhat-developer%2Frhdh-test-instance&type=presubmit&job=pull-ci-redhat-developer-rhdh-test-instance-main-deploy>

**Job History:**
<https://prow.ci.openshift.org/job-history/gs/test-platform-results/pr-logs/directory/pull-ci-redhat-developer-rhdh-test-instance-main-deploy>

### Testing Custom Configurations via PRs

Users can deploy different configuration flavors by:

1. **Creating a PR** with modified configuration files
2. **Using bot commands** to deploy the PR's configuration:

   ```bash
    /test deploy helm 2.1 2h
   ```

## Local Deployment

For local development and testing environments, you can deploy RHDH directly to your OpenShift cluster.

> **Note: Bring Your Own Cluster (BYOC)**
> Local deployment requires you to have access to your own OpenShift cluster.

### Prerequisites

- `oc` CLI logged into your OpenShift cluster
- `helm` CLI installed
- Bash 4.3+, `curl`, `jq`, [Mike Farah's `yq` v4](https://github.com/mikefarah/yq), `skopeo`, and Python 3
- `make` installed
- `.env` file configured (copy from `.env.example`) — needed for Lightspeed credentials and other optional secrets

### Quick Start

1. **Clone the repository:**

   ```bash
   git clone <repository-url>
   cd rhdh-test-instance
   ```

2. **Configure environment:**

   ```bash
   cp .env.example .env
    # Edit .env to add Lightspeed API keys or other credentials
    # Leave CATALOG_INDEX_IMAGE empty to use the bundled catalog
   ```

3. **Deploy RHDH:**

   ```bash
   make deploy-helm                                # Basic deploy (Keycloak OIDC auto-configured)
   make deploy-helm VERSION=2.1 WITH=nfs           # 2.1 test day: New Frontend System
   make deploy-helm VERSION=2.1 WITH=nfs,lightspeed,scorecard,rbac
   make deploy-helm WITH=all                       # Everything enabled
   make deploy-helm WITH=all WITHOUT=orchestrator  # Everything except orchestrator
   ```

4. **Access your RHDH instance:**

   ```bash
   make url
   ```

### Make Commands

Run `make help` to see all available commands.

#### Deploy

```bash
# Basic Helm deployment (Keycloak OIDC is always auto-configured)
make deploy-helm
make deploy-helm NAMESPACE=my-rhdh

# With optional components (comma-separated)
make deploy-helm WITH=nfs
make deploy-helm WITH=nfs,lightspeed
make deploy-helm WITH=nfs,lightspeed,scorecard,rbac
make deploy-helm WITH=orchestrator
make deploy-helm WITH=all
make deploy-helm WITH=all WITHOUT=orchestrator,lightspeed

# With a specific version and components
make deploy-helm VERSION=2.1 WITH=nfs,lightspeed
make deploy-helm VERSION=2.1 NAMESPACE=team-a WITH=nfs,lightspeed,scorecard,rbac
make deploy-helm VERSION=2.1-128-CI WITH=nfs
make deploy-helm VERSION=2.1 WITH=all WITHOUT=orchestrator

# With a custom RHDH image
make deploy-helm RHDH_IMAGE=quay.io/rhdh-community/rhdh:pr-1234 WITH=nfs

# Operator (one-time operator install, then deploy instance)
make install-operator VERSION=2.1
make deploy-operator VERSION=2.1 WITH=nfs
make deploy-operator VERSION=2.1 WITH=nfs,lightspeed,scorecard,rbac
```

#### Shared Keycloak

Keycloak is automatically deployed into the `rhdh-keycloak` namespace on first deploy. All RHDH instances share it. You can also manage it independently:

```bash
make deploy-keycloak                  # Deploy shared Keycloak (auto-runs on deploy-helm)
make undeploy-keycloak                # Remove shared Keycloak (only after all instances are gone)
```

#### Cleanup

```bash
# Remove RHDH only (leave shared Keycloak in place)
make undeploy-helm
make undeploy-operator

# Remove RHDH and tear down plugin infrastructure
make undeploy-helm PLUGINS=keycloak,lighthouse
make undeploy-operator PLUGINS=keycloak

# Tear down plugin infra only, leave RHDH running
make undeploy-plugins PLUGINS=keycloak,lighthouse

# Remove orchestrator infra chart
make undeploy-infra

# Delete the entire RHDH namespace (does NOT remove shared Keycloak)
make clean

# Remove the shared Keycloak (only after all RHDH instances are gone)
make undeploy-keycloak
```

#### Status and Debugging

```bash
make status                           # Pods, helm releases, operator versions
make logs                             # Tail RHDH pod logs
make url                              # Print RHDH URL
```

#### Variables

All make commands accept these variables:

| Variable            | Default                                       | Description                                                                   |
| ------------------- | --------------------------------------------- | ----------------------------------------------------------------------------- |
| `NAMESPACE`         | `rhdh`                                        | Target namespace for RHDH                                                     |
| `VERSION`           | `2.1`                                         | RHDH 2.1 release line, patch release, or CI chart build (`2.1-128-CI`)        |
| `WITH`              | _(empty)_                                     | Comma-separated optional components: `nfs`, `lightspeed`, `scorecard`, `orchestrator`, `rbac`, or `all` |
| `WITHOUT`           | _(empty)_                                     | Comma-separated components to exclude (use with `WITH=all` to skip specific ones) |
| `PLUGINS`           | _(empty)_                                     | Infrastructure plugins to deploy/teardown (e.g. `keycloak,lighthouse`)        |
| `KEYCLOAK_NS`       | `rhdh-keycloak`                               | Namespace for shared Keycloak (all RHDH instances share one Keycloak)         |
| `RHDH_IMAGE`        | _(empty)_                                     | Override RHDH container image (e.g., `quay.io/rhdh-community/rhdh:pr-1234`)  |
| `CATALOG_INDEX_TAG` | (empty)                                       | Optional catalog tag override when no full image is supplied                |
| `CATALOG_INDEX_IMAGE` | (bundled with chart/Operator)                | Optional full catalog image; takes precedence over `CATALOG_INDEX_TAG`      |
| `OPERATOR_IIB_IMAGE` | (published 2.1 IIB for the cluster)           | Optional immutable IIB reference for a reproducible Operator installation |
| `OPERATOR_EXPECTED_IMAGE` | (empty)                                 | Verify the installed Operator manager image against this RC reference |
| `OPERATOR_EXPECTED_RHDH_IMAGE` | (empty)                            | Verify the Operator's bundled application image |
| `OPERATOR_EXPECTED_CATALOG_IMAGE` | (empty)                         | Verify the Operator's bundled plugin catalog image |
| `USE_CONTAINER`     | `false`                                       | Set to `true` to run commands inside the e2e-runner container                 |
| `RUNNER_IMAGE`      | `quay.io/rhdh-community/rhdh-e2e-runner:main` | Container image for `install-operator`                                       |

> **Note:** `install-operator` requires you to be logged into the cluster via `oc login` on your host.
> Installation uses `oc`, `jq`, `yq`, and `skopeo`, either on the host or in the e2e-runner container.
> The operator is installed once per cluster. After that, `deploy-operator` runs locally like `deploy-helm`.

The installer creates a CatalogSource and Subscription from the published RHDH
2.1 IIB for the cluster's OpenShift version and architecture. It resolves the IIB
tag to a digest and prints the immutable reference. Set `OPERATOR_IIB_IMAGE` to
that reference to reproduce the installation. Bundles and catalogs are never rebuilt.
An existing installation is verified and reused; an explicitly requested IIB must
match its CatalogSource. Set `OPERATOR_EXPECTED_IMAGE`, `OPERATOR_EXPECTED_RHDH_IMAGE`,
and `OPERATOR_EXPECTED_CATALOG_IMAGE` to verify a specific RC's manager, bundled
application, and catalog images before deployment. Missing or mismatched published
artifacts are installation errors, rather than reasons to rewrite bundles.

### Direct Script Usage

You can also use `deploy.sh` and `teardown.sh` directly:

**Deploy:**

```bash
./deploy.sh <install-method> <version> [--namespace <ns>] [--with <components>] [--without <components>] [--plugins <list>]
```

```bash
./deploy.sh helm 2.1
./deploy.sh helm 2.1 --with nfs,lightspeed
./deploy.sh helm 2.1 --with all
./deploy.sh helm 2.1 --with all --without orchestrator,lightspeed
./deploy.sh helm 2.1 --namespace my-test --with nfs,scorecard
./deploy.sh operator 2.1 --with orchestrator
```

**Teardown:**

```bash
./teardown.sh <install-method> [--namespace <ns>] [--plugins <list>] [--clean]
```

```bash
./teardown.sh helm                                              # Remove RHDH only
./teardown.sh helm --plugins keycloak,lighthouse               # Remove RHDH + plugin infra
./teardown.sh helm --namespace rhdh-helm --plugins keycloak    # Remove from non-default namespace
./teardown.sh operator --plugins keycloak,lighthouse
./teardown.sh helm --clean                                      # Full wipe: delete entire namespace
./teardown.sh helm --plugins keycloak,lighthouse --clean        # Teardown plugins then delete namespace
```

> **Note:** `--clean` deletes the entire namespace after teardown, removing all resources including image streams. Omit it when redeploying to the same namespace to preserve cached image streams and avoid registry rate limits.

### Accessing Your Local RHDH Instance

After successful installation, access your RHDH instance at:

```text
https://redhat-developer-hub-<namespace>.<cluster-router-base>
```

### Login Process

1. Navigate to the RHDH URL (`make url` to print it)
2. Click **Sign In**
3. Sign in with a Keycloak test user (e.g. `test1`) — see [Finding Keycloak Credentials](#finding-keycloak-credentials) below

## Configuration

### Application Configuration

The main application configuration is stored in `config/app-config-rhdh.yaml` and contains base settings (URLs, CORS, languages, auth, catalog and RBAC policy files). When NFS extras are enabled (`WITH=nfs`), `config/nfs-app-config.yaml` supplies the existing homepage, language, quickstart and Intelligent Assistant customizations. Both deployment methods set `SEGMENT_TEST_MODE=true`.

### Dynamic Plugins

The base dynamic plugin config is `config/dynamic-plugins.yaml`:

```yaml
includes:
  - dynamic-plugins.default.yaml
plugins: []
```

Optional component plugins are stored in separate files and conditionally appended based on the `WITH=` flag:

| File | Component | Description |
|------|-----------|-------------|
| `config/nfs-dynamic-plugins.yaml` | `nfs` | Catalog references for the existing NFS extras; home and theme use built-in defaults |
| `config/lightspeed-dynamic-plugins.yaml` | `lightspeed` | Intelligent Assistant frontend + backend |
| `config/scorecard-dynamic-plugins.yaml` | `scorecard` | Scorecard health/compliance KPIs |
| `config/orchestrator-dynamic-plugins.yaml` | `orchestrator` | Serverless workflow orchestrator |
| `config/rbac-dynamic-plugins.yaml` | `rbac` | RBAC permission framework |

Plugin overrides use `ref://<image-name>` and `enabled: true/false`. Package
URLs, versions, digests and any required `!plugin-path` come from catalog defaults.
Existing disabled integrations (Jira Scorecard and Orchestrator Loki) remain disabled.

The catalog bundled with Helm `2.1-119-CI` references Scorecard images with empty
discovery annotations ([RHDHBUGS-3834](https://redhat.atlassian.net/browse/RHDHBUGS-3834)).
Supply the fixed `2.1-109` catalog to enable Scorecard with this chart:

```bash
make deploy-helm VERSION=2.1-119-CI WITH=nfs,orchestrator,scorecard,rbac \
  CATALOG_INDEX_IMAGE=quay.io/rhdh/plugin-catalog-index@sha256:915486da4cf127445b28a7bf160d2298a86a62daffd0f9c9d7b980a4e2646833
```

The pinned Operator RC already bundles working Scorecard artifacts. The scripts
inherit plugin artifacts from the selected catalog without patching metadata or
defaults. Homepage discovery metadata determines whether to use legacy `page:home`
or modern `page:homepage`, including when a catalog overrides an older chart.

#### Supplying a catalog

By default, each deployment uses the catalog bundled with its selected Helm chart
or installed Operator. Preflight validates that exact catalog without replacing
the release's runtime default. Install the Operator before deploying a local
instance; CI installs it automatically when its defaults are missing.

Optionally set `CATALOG_INDEX_IMAGE` in `.env` or as a make variable to the full
image reference of your RHDH 2.1-compatible catalog. It must contain
`dynamic-plugins.default.yaml` with definitions for every requested plugin.

The primary RHDH 2.1 index does **not** define every optional package used here:
Lightspeed enables MCP Actions and MCP extras; Lighthouse needs its frontend/backend
definitions. Supply a catalog with those definitions to deploy those components.
NFS omits unavailable Tekton, ACR, Nexus, Quay backend and TechDocs search module refs.
Additional Extensions UI catalogs alone do not supply installable defaults.

Before changing instance resources, deployment downloads the selected catalog and
checks all requested references, including explicitly disabled overrides. Missing
definitions are reported by name. The scripts do not generate supplemental defaults
or fall back to hardcoded plugin URLs.

You can validate a supplied defaults file locally:

```bash
bash scripts/check-plugin-refs.sh /path/to/dynamic-plugins.default.yaml \
  config/dynamic-plugins.yaml resources/keycloak/dynamic-plugins.yaml \
  config/nfs-dynamic-plugins.yaml
```

### Helm Values

Customize deployment in `helm/value_file.yaml`:

```yaml
# RHDH 2.1 uses top-level chart values.
extraEnvFrom:
  - secretRef:
      name: rhdh-secrets
auth:
  backend:
    existingSecretRef:
      name: rhdh-secrets
      key: BACKEND_SECRET
```

The `extraAppConfig` array always includes `app-config-rhdh`, adding NFS and
Orchestrator fragments according to the component flags.

### Operator CR

The Operator path renders `operator/backstage.yaml` using **`rhdh.redhat.com/v1alpha5`**
and requires that API to be served by the installed operator. Replica counts,
service-account token mounting and image overrides use `spec.deployment.patch`.
Image overrides target both `backstage-backend` and `install-dynamic-plugins`.
The Orchestrator flavour provides SonataFlow dependencies and NetworkPolicies;
the Intelligent Assistant flavour supplies LCS when a provider is configured.

To inspect a CR without accessing a cluster:

```bash
RHDH_BASE_URL=https://rhdh.example.test bash operator/render-cr.sh rhdh 2.1
```

## Authentication

### Keycloak OIDC (Default)

Keycloak is automatically deployed into a shared namespace (`rhdh-keycloak`) on first deploy. Each RHDH instance gets its own OIDC client (`rhdh-client-<namespace>`) registered in the shared Keycloak. Test users and groups are created from `resources/keycloak/users.json` and `resources/keycloak/groups.json`.

- **Realm**: `rhdh`
- **Client ID**: `rhdh-client-<namespace>` (per instance)
- **Test user password**: `<username>@123` (e.g., `test1@123`, `test2@123`)

Multiple RHDH instances share the same Keycloak — deploying to different namespaces (`team-a`, `team-b`, etc.) all use the same test users and Keycloak server.

### Finding Keycloak Credentials

After deployment, credentials are stored in a cluster Secret in the `rhdh-keycloak` namespace:

**Via `oc`:**

```bash
# Print all credentials
oc get secret keycloak-test-credentials -n rhdh-keycloak -o jsonpath='{.data}' | \
  jq 'to_entries[] | "\(.key): \(.value | @base64d)"' -r

# Print only the shared user password
oc get secret keycloak-test-credentials -n rhdh-keycloak \
  -o jsonpath='{.data.KEYCLOAK_USER_PASSWORD}' | base64 -d && echo

# Print the username list
oc get secret keycloak-test-credentials -n rhdh-keycloak \
  -o jsonpath='{.data.KEYCLOAK_USERNAMES}' | base64 -d && echo
```

**Via OpenShift Console:**

Navigate to **Workloads > Secrets > `keycloak-test-credentials`** in the `rhdh-keycloak` namespace and click **Reveal values**.

**Secret keys:**

| Key | Description |
|---|---|
| `KEYCLOAK_URL` | Keycloak base URL |
| `KEYCLOAK_USERNAMES` | Comma-separated list of all test usernames (read from `users.json` at deploy time) |
| `KEYCLOAK_USER_PASSWORD` | Password pattern for test users (`<username>@123`) |

**Admin credentials** are stored by the Bitnami Helm chart in the `keycloak-credentials` Secret in the `rhdh-keycloak` namespace:

```bash
oc get secret keycloak-credentials -n rhdh-keycloak \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

## Optional Components

### NFS (New Frontend System)

RHDH 2.1 uses the New Frontend System by default. `WITH=nfs` retains the existing
extra plugin set and homepage customization through catalog references. The app's
built-in home plugin and theme replace their former explicit dynamic packages.

### Lightspeed (Intelligent Assistant)

Enable with `WITH=lightspeed`. Deploys the Intelligent Assistant frontend and backend plugins. If LLM provider credentials are configured in `.env` (e.g., `ENABLE_OPENAI=true` and `OPENAI_API_KEY=<your-api-key>`), a Lightspeed Core Service (LCS) sidecar is automatically deployed alongside RHDH to proxy LLM requests. Without credentials, the UI loads but shows "Could not load models".

Supported providers: OpenAI, vLLM, Ollama, Vertex AI. See `.env.example` for all configuration options.

The existing `ENABLE_*` flags select `inference.providers` in a unified LCS stack
derived from the upstream 2.1 configuration. OpenAI keeps the existing four-model
allow-list. Credentials stay in `lightspeed-secret`; the non-secret stack lives in
`lightspeed-stack`. Both Helm and Operator mount these resources, without patching
Helm-managed ConfigMaps or scaling the deployment down after installation.
Set `LIGHTSPEED_STACK_FILE` to use your own unified stack file unchanged.

### Migration validation

Run the cluster-free regression checks with `bash tests/migration.sh`. Set
`RHDH_TEST_CHART` to a downloaded 2.1 chart archive to also render Helm variants
with and without LCS and Orchestrator. Cluster commands are stubbed during these
checks; `operator/render-cr.sh` renders the actual Operator configuration directly.

### Scorecard

Enable with `WITH=scorecard`. Adds health and compliance KPI dashboards.

Frontend/backend, SonarQube, Dependabot, GitHub, Filecheck and OpenSSF are enabled;
Jira remains disabled and DORA uses the catalog's disabled default. Existing
homepage Scorecard widgets remain hidden; entity Scorecard pages are available.
Filecheck checks `README.md`, `LICENSE` and `.github/CODEOWNERS` using
`scorecard.metricProviders.filecheck.fileExistence.options.files`.

GitHub integrations use public access. GitHub tokens are not forwarded to the
container runner or copied into namespace Secrets. Dependabot remains enabled
as in the original configuration, but collecting alerts requires separately
configured repository alert-read access. Set an optional `SONARQUBE_API_KEY` in
`.env` or the deployment environment for private SonarQube/SonarCloud data; only
that supplied key is merged into `rhdh-secrets`, preserving other existing keys.
SonarQube defaults to public SonarCloud projects when no API key is supplied.

Entities need `github.com/project-slug` for GitHub metrics,
`backstage.io/source-location` for Filecheck, `github.com/dependabot: 'true'`
to opt into Dependabot, and `sonarqube.org/project-key` for SonarQube metrics.
The existing admin and developer roles can read Scorecard metrics, subject to
their existing catalog permissions. Catalog-provided thresholds and schedules
are inherited.

### Orchestrator

Enable with `WITH=orchestrator`. Deploys serverless workflow orchestrator plugins and installs required operators (OpenShift Serverless, Serverless Logic).

### RBAC

Enable with `WITH=rbac`. Enables the RBAC permission framework plugin for fine-grained access control.

## Project Structure

```directory
rhdh-test-instance/
├── config/
│   ├── app-config-rhdh.yaml                # Base RHDH configuration (auth, catalog, CORS)
│   ├── nfs-app-config.yaml                 # NFS app.extensions, branding, globalHeader config
│   ├── dynamic-plugins.yaml                # Base dynamic plugins (plugins: [])
│   ├── nfs-dynamic-plugins.yaml            # NFS plugin catalog references
│   ├── lightspeed-dynamic-plugins.yaml     # Lightspeed/Intelligent Assistant plugins
│   ├── scorecard-dynamic-plugins.yaml      # Scorecard plugins
│   ├── orchestrator-dynamic-plugins.yaml   # Orchestrator plugins
│   ├── rbac-dynamic-plugins.yaml           # RBAC plugins
│   ├── rbac-policies.yaml                  # RBAC policy ConfigMap
│   └── rhdh-secrets.yaml                   # Reference template for rhdh-secrets Secret
├── helm/
│   ├── deploy.sh                           # Helm deployment script
│   └── value_file.yaml                     # Helm chart values
├── operator/
│   ├── install-operator.sh                 # One-time operator installation (runs in container)
│   ├── deploy.sh                           # Operator instance deployment
│   ├── backstage.yaml                      # v1alpha5 Backstage CR template
│   └── render-cr.sh                        # Cluster-free CR rendering
├── resources/
│   ├── catalog-entities/                   # Catalog entity ConfigMaps (applied unconditionally)
│   │   ├── components.yaml                 # Demo components (Lighthouse, Keycloak, etc.)
│   │   ├── operators.yaml                  # Operator catalog entities
│   │   ├── plugins.yaml                    # Plugin + topology test catalog entities
│   │   └── resources.yaml                  # Resource catalog entities
│   ├── image-stream-imports/               # Pre-import images to avoid rate limits
│   ├── keycloak/                           # Keycloak plugin resources and config
│   ├── lighthouse/                         # Lighthouse plugin resources and config
│   ├── lightspeed/                         # Lightspeed Core Service templates
│   │   ├── lightspeed-secret.yaml          # LCS credentials Secret template
│   │   └── providers.yaml                  # Unified LCS provider definitions
│   └── rhdh-script-examples/              # Demo workloads for Topology/Kubernetes views
├── scripts/
│   ├── config-plugins.sh                   # Plugin orchestration and _append_plugin_dynamic_config helper
│   ├── setup-resources.sh                  # Shared cluster resource provisioning/teardown
│   ├── setup-lightspeed.sh                 # LCS stack and credential setup
│   ├── deployment-common.sh                # 2.1 version, image and catalog helpers
│   ├── check-plugin-refs.sh                # Validate references against supplied defaults
│   └── plugins/
│       ├── config-keycloak-plugin.sh       # Keycloak deploy, realm/client/user setup
│       └── config-lighthouse-plugin.sh     # Lighthouse deploy and URL injection
├── deploy.sh                               # Main deploy entry point
├── teardown.sh                             # Main teardown entry point
├── Makefile                                # Make targets
├── .env.example                            # Example environment variables
├── CLAUDE.md                               # AI assistant guidance
├── OWNERS                                  # Project maintainers
└── README.md                               # This file
```

## Environment Variables

### PR Deployments (Vault Integration)

When using PR deployments, secrets are automatically pulled from vault at:
<https://vault.ci.openshift.org/ui/vault/secrets/kv/kv/list/selfservice/rhdh-test-instance/>

These secrets are available as environment variables with the same name and can be used directly in Kubernetes secrets. From there, they can be referenced in `app-config-rhdh.yaml` or `dynamic-plugins.yaml` configurations.

**Access Requirements:**

- To add or view vault secrets, ensure you have appropriate access
- For access requests, reach out in #team-rhdh slack channel

### Local Deployments (.env Configuration)

For local development, copy `.env.example` to `.env` and configure credentials:

```bash
cp .env.example .env
```

Key variables include Lightspeed provider credentials (`ENABLE_OPENAI`, `OPENAI_API_KEY`, etc.). See `.env.example` for the full list.
