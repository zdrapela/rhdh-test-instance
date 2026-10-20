NAMESPACE ?= rhdh
VERSION ?= 2.1
WITH ?=
WITHOUT ?=
PLUGINS ?=
USE_CONTAINER ?= false
CATALOG_INDEX_TAG ?=
CATALOG_INDEX_IMAGE ?=
RHDH_IMAGE ?=
RUNNER_IMAGE ?= quay.io/rhdh-community/rhdh-e2e-runner:main
OPERATOR_NAMESPACE ?= rhdh-operator-system
OPERATOR_IIB_IMAGE ?=
OPERATOR_EXPECTED_IMAGE ?=
OPERATOR_EXPECTED_RHDH_IMAGE ?=
OPERATOR_EXPECTED_CATALOG_IMAGE ?=
KEYCLOAK_NS ?= rhdh-keycloak

export CATALOG_INDEX_TAG
export CATALOG_INDEX_IMAGE
export RHDH_IMAGE
export OPERATOR_NAMESPACE
export OPERATOR_IIB_IMAGE
export OPERATOR_EXPECTED_IMAGE
export OPERATOR_EXPECTED_RHDH_IMAGE
export OPERATOR_EXPECTED_CATALOG_IMAGE
export KEYCLOAK_NS

# Build deploy flags
# WITH=<components>     Comma-separated list of optional components to enable
#   Available: nfs, lightspeed, scorecard, orchestrator, rbac (or "all")
# WITHOUT=<components>  Comma-separated list of components to exclude (use with WITH=all)
# PLUGINS=<infra>       Comma-separated infrastructure plugins (keycloak is always auto-included)
DEPLOY_FLAGS = --namespace $(NAMESPACE)
ifneq ($(WITH),)
DEPLOY_FLAGS += --with $(WITH)
endif
ifneq ($(WITHOUT),)
DEPLOY_FLAGS += --without $(WITHOUT)
endif
ifneq ($(PLUGINS),)
DEPLOY_FLAGS += --plugins $(PLUGINS)
endif

# ── Shared Keycloak ───────────────────────────────────────────────────────────

.PHONY: deploy-keycloak undeploy-keycloak

deploy-keycloak: ## Deploy shared Keycloak into KEYCLOAK_NS (auto-runs with PLUGINS=keycloak)
	@CLUSTER_ROUTER_BASE=$$(oc get route console -n openshift-console -o=jsonpath='{.spec.host}' | sed 's/^[^.]*\.//'); \
	export CLUSTER_ROUTER_BASE; \
	[[ -f .env ]] && source .env; \
	source scripts/plugins/config-keycloak-plugin.sh && \
	deploy_keycloak && \
	create_users_and_groups_keycloak && \
	apply_keycloak_labels

undeploy-keycloak: ## Remove the shared Keycloak infra from KEYCLOAK_NS (only after all instances are gone)
	@source scripts/plugins/config-keycloak-plugin.sh && uninstall_keycloak_infra
	@echo "To also delete the namespace: oc delete project $(KEYCLOAK_NS)"

# ── Deploy ────────────────────────────────────────────────────────────────────

.PHONY: deploy-helm install-operator deploy-operator

deploy-helm: ## Deploy RHDH via Helm (WITH=all WITHOUT=orchestrator,lightspeed)
ifeq ($(USE_CONTAINER),true)
	$(MAKE) run-in-runner CMD="./deploy.sh helm $(VERSION) $(DEPLOY_FLAGS)"
else
	./deploy.sh helm $(VERSION) $(DEPLOY_FLAGS)
endif

install-operator: ## Install RHDH operator on cluster (USE_CONTAINER=true to run in container)
ifeq ($(USE_CONTAINER),true)
	$(MAKE) run-in-runner CMD="bash operator/install-operator.sh $(VERSION)"
else
	bash operator/install-operator.sh $(VERSION)
endif

deploy-operator: ## Deploy RHDH instance via Operator (WITH=all WITHOUT=orchestrator)
ifeq ($(USE_CONTAINER),true)
	$(MAKE) run-in-runner CMD="./deploy.sh operator $(VERSION) $(DEPLOY_FLAGS)"
else
	./deploy.sh operator $(VERSION) $(DEPLOY_FLAGS)
endif

# ── Cleanup ───────────────────────────────────────────────────────────────────

.PHONY: undeploy-helm undeploy-operator undeploy-infra undeploy-plugins uninstall-operator clean

undeploy-helm: ## Uninstall Helm RHDH release and all cluster resources (PLUGINS=keycloak,lighthouse to also teardown plugin infra)
ifdef PLUGINS
	./teardown.sh helm --namespace $(NAMESPACE) --plugins $(PLUGINS)
else
	./teardown.sh helm --namespace $(NAMESPACE)
endif

undeploy-operator: ## Remove Operator RHDH deployment and all cluster resources (PLUGINS=keycloak,lighthouse to also teardown plugin infra)
ifdef PLUGINS
	./teardown.sh operator --namespace $(NAMESPACE) --plugins $(PLUGINS)
else
	./teardown.sh operator --namespace $(NAMESPACE)
endif

undeploy-plugins: ## Teardown plugin infrastructure only, leave RHDH running (PLUGINS=keycloak,lighthouse)
ifndef PLUGINS
	$(error PLUGINS is required, e.g. make undeploy-plugins PLUGINS=keycloak,lighthouse)
endif
	TEARDOWN=true NAMESPACE=$(NAMESPACE) bash scripts/config-plugins.sh $(PLUGINS)

undeploy-infra: ## Uninstall orchestrator infra chart
	helm uninstall orchestrator-infra -n $(NAMESPACE) || true

uninstall-operator: ## Uninstall the RHDH operator (deletes the operator namespace)
	oc delete project $(OPERATOR_NAMESPACE) --ignore-not-found
	@echo "Operator uninstalled. RHDH CRDs may linger until all Backstage CRs are removed."

clean: ## Delete the entire deployment namespace (does NOT uninstall the operator)
	oc delete project $(NAMESPACE) --ignore-not-found

# ── Status ────────────────────────────────────────────────────────────────────

.PHONY: status logs url

status: ## Show deployment status
	@echo "=== Namespace: $(NAMESPACE) ==="
	@oc get pods -n $(NAMESPACE) 2>/dev/null || echo "Namespace not found"
	@echo ""
	@echo "=== Helm Releases ==="
	@helm list -n $(NAMESPACE) 2>/dev/null || true
	@echo ""
	@echo "=== Orchestrator Operators ==="
	@oc get csv -n openshift-serverless-logic -o custom-columns='NAME:.metadata.name,VERSION:.spec.version,PHASE:.status.phase' 2>/dev/null || echo "Not installed"

logs: ## Tail RHDH pod logs
	oc logs -f -l 'app.kubernetes.io/name=developer-hub' -n $(NAMESPACE) --tail=100

url: ## Print the RHDH URL
	@CLUSTER_ROUTER_BASE=$$(oc get route console -n openshift-console -o=jsonpath='{.spec.host}' | sed 's/^[^.]*\.//'); \
	echo "http://redhat-developer-hub-$(NAMESPACE).$${CLUSTER_ROUTER_BASE}"

# ── Runner ────────────────────────────────────────────────────────────────────

.PHONY: run-in-runner

run-in-runner: ## Run a command inside the e2e-runner container (requires oc login on host)
ifndef CMD
	$(error CMD is required)
endif
	K8S_CLUSTER_URL="$$(oc whoami --show-server)" K8S_CLUSTER_TOKEN="$$(oc whoami --show-token)" \
	podman run --rm \
		-v $(CURDIR):/workspace:z \
		-w /workspace \
		--tmpfs /run/rhdh:rw,mode=0700 \
		-e KUBECONFIG=/run/rhdh/kubeconfig -e TMPDIR=/run/rhdh \
		-e K8S_CLUSTER_URL -e K8S_CLUSTER_TOKEN \
		-e CATALOG_INDEX_IMAGE -e CATALOG_INDEX_TAG -e RHDH_IMAGE \
		-e OPERATOR_NAMESPACE -e OPERATOR_IIB_IMAGE -e KEYCLOAK_NS \
		-e OPERATOR_EXPECTED_IMAGE -e OPERATOR_EXPECTED_RHDH_IMAGE -e OPERATOR_EXPECTED_CATALOG_IMAGE \
		-e SONARQUBE_API_KEY \
		$(RUNNER_IMAGE) \
		bash -c 'oc login --token="$$K8S_CLUSTER_TOKEN" --server="$$K8S_CLUSTER_URL" --insecure-skip-tls-verify=true >/dev/null && source .env && $(CMD)'

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
