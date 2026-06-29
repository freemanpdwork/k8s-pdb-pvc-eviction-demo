# k8s PDB + PVC + eviction demo — primary UX entrypoint
# Uses kind (4 nodes: 1 control-plane + 3 workers). See README.md for Docker Desktop fallback.
SHELL := /bin/bash
.DEFAULT_GOAL := help

CLUSTER_NAME    ?= pdb-pvc-demo
KIND_CONFIG     ?= kind/cluster.yaml
KUBECONFIG_FILE ?= $(CURDIR)/.kube/kind-$(CLUSTER_NAME)
ifneq (,$(wildcard $(KUBECONFIG_FILE)))
export KUBECONFIG := $(KUBECONFIG_FILE)
endif

NAMESPACE       ?= demo
STATEFULSET     ?= demo-app
DEMO_REPO_URL   ?= https://github.com/freemanpdwork/k8s-pdb-pvc-eviction-demo.git
DEMO_OVERLAY    ?= manifests/k8s-demo
STRICT_OVERLAY  ?= manifests/k8s-demo/overlays/strict
ARGOCD_NS         ?= argocd
ARGOCD_LOCAL_PORT ?= 8888
ARGOCD_PROXY_PORT ?= 8001
ARGOCD_NODE_PORT  ?= 30080
DEMO_NODE_PORT    ?= 30090
ARGOCD_INSTALL    ?= https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
ARGOCD_APP        ?= demo-app
ARGOCD_CLI        ?= argocd --core
ARGOCD_APP_FLAGS  ?= -N $(ARGOCD_NS)

RELAXED_KUSTOMIZE := manifests/k8s-demo/overlays/relaxed
STRICT_KUSTOMIZE  := manifests/k8s-demo/overlays/strict
KUSTOMIZE_FLAGS   := --load-restrictor LoadRestrictionsNone

kustomize_apply = kubectl kustomize $(1) $(KUSTOMIZE_FLAGS) | kubectl apply -f -
kustomize_delete = kubectl kustomize $(1) $(KUSTOMIZE_FLAGS) | kubectl delete -f - --ignore-not-found

# Terminal styling (bold-cyan headers, dim command hints, bold-yellow notes)
FMT_H     := \033[1;36m
FMT_C     := \033[2m
FMT_W     := \033[1;33m
FMT_RESET := \033[0m

.PHONY: help setup setup-offline preflight cluster cluster-delete check-cluster fix-context guard-context \
        argocd argocd-cli-check argocd-expose argocd-password argocd-app argocd-sync argocd-wait \
        argocd-relaxed argocd-strict argocd-pause-sync argocd-resume-sync \
        port-forward argocd-proxy deploy deploy-direct deploy-strict pdb-relaxed pdb-strict \
        pdb-explain demo-data demo-expose demo-url wait-ready status logs evict drain uncordon act-pvc act-pdb act-drain teardown clean \
        dry-run validate

help: ## Show available targets
	@grep -E '^[a-zA-Z0-9_.-]+:.*##' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

setup: ## Create kind cluster, install Argo CD, sync app via GitOps, write demo data
	@$(MAKE) cluster
	@$(MAKE) argocd
	@$(MAKE) argocd-app
	@$(MAKE) demo-expose
	@$(MAKE) demo-data
	@$(MAKE) status
	@echo ""
	@echo "Demo ready. Argo CD UI: http://localhost:$(ARGOCD_NODE_PORT) (no login; run make argocd-expose if needed)"
	@echo "Demo app HTTP: http://localhost:$(DEMO_NODE_PORT)/ (run make demo-expose if needed)"
	@echo "Application 'demo-app' is registered and synced from $(DEMO_REPO_URL)"

setup-offline: ## Bootstrap without GitOps (cluster + Argo CD + kubectl deploy + demo data)
	@$(MAKE) cluster
	@$(MAKE) argocd
	@$(MAKE) deploy-direct
	@$(MAKE) demo-data
	@$(MAKE) status
	@echo ""
	@echo "Demo ready (offline). Argo CD UI: http://localhost:$(ARGOCD_NODE_PORT) (no Application registered — use make argocd-app for GitOps)"
	@echo "Demo app HTTP: http://localhost:$(DEMO_NODE_PORT)/"

preflight: validate check-cluster argocd-cli-check ## Validate overlays, verify cluster, GitHub reachability, print demo URLs
	@repo="$(DEMO_REPO_URL)"; \
	repo="$${repo%.git}"; \
	owner_repo="$${repo##*github.com/}"; \
	api_url="https://api.github.com/repos/$${owner_repo}"; \
	echo ""; \
	printf '$(FMT_H)GitHub reachability$(FMT_RESET)\n'; \
	if curl -sfI --connect-timeout 5 "$$api_url" >/dev/null 2>&1; then \
		echo "  OK: $$api_url"; \
	elif curl -sfI --connect-timeout 5 "$(DEMO_REPO_URL)" >/dev/null 2>&1; then \
		echo "  OK: $(DEMO_REPO_URL)"; \
	else \
		printf '$(FMT_W)  WARNING: cannot reach $(DEMO_REPO_URL)$(FMT_RESET)\n'; \
		echo "  GitOps setup (make setup) may fail at argocd-wait."; \
		echo "  Offline fallback: make setup-offline"; \
	fi; \
	default_repo="https://github.com/freemanpdwork/k8s-pdb-pvc-eviction-demo.git"; \
	if [[ "$(DEMO_REPO_URL)" != "$$default_repo" ]]; then \
		echo ""; \
		printf '$(FMT_W)  Custom DEMO_REPO_URL — push manifests/k8s-demo to your fork before make setup.$(FMT_RESET)\n'; \
	fi
	@echo ""
	@printf '$(FMT_H)Demo URLs$(FMT_RESET)\n'
	@printf '  Argo CD UI:    http://localhost:$(ARGOCD_NODE_PORT)  (no login)\n'
	@printf '  Demo app HTTP: http://localhost:$(DEMO_NODE_PORT)/  (run make demo-expose if needed)\n'

argocd-cli-check: ## Verify argocd CLI is installed for Argo CD-centered workflow
	@command -v argocd >/dev/null || { \
		echo "argocd CLI is required for the primary demo workflow." >&2; \
		echo "Install: brew install argocd" >&2; \
		exit 1; \
	}
	@printf '$(FMT_H)Argo CD CLI:$(FMT_RESET) '
	@argocd version --client --short

cluster: ## Create kind cluster if missing and export kubeconfig
	@command -v kind >/dev/null || { echo "kind is required. Install: https://kind.sigs.k8s.io/" >&2; exit 1; }
	@command -v docker >/dev/null || { echo "docker is required (kind runs on Docker)." >&2; exit 1; }
	@mkdir -p $(dir $(KUBECONFIG_FILE))
	@if kind get clusters 2>/dev/null | grep -qx '$(CLUSTER_NAME)'; then \
		echo "kind cluster '$(CLUSTER_NAME)' already exists"; \
	else \
		echo "Creating kind cluster '$(CLUSTER_NAME)' from $(KIND_CONFIG)..."; \
		kind create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG); \
	fi
	@kind export kubeconfig --name $(CLUSTER_NAME) --kubeconfig $(KUBECONFIG_FILE)
	@echo "Kubeconfig written to $(KUBECONFIG_FILE)"
	@echo "Context: kind-$(CLUSTER_NAME)"
	@echo "Run: export KUBECONFIG=$(KUBECONFIG_FILE)"
	@echo "Or:  make check-cluster (Makefile auto-exports KUBECONFIG when the file exists)"

cluster-delete: ## Delete kind cluster and local kubeconfig
	@command -v kind >/dev/null || { echo "kind is required." >&2; exit 1; }
	@if kind get clusters 2>/dev/null | grep -qx '$(CLUSTER_NAME)'; then \
		echo "Deleting kind cluster '$(CLUSTER_NAME)'..."; \
		kind delete cluster --name $(CLUSTER_NAME); \
	else \
		echo "kind cluster '$(CLUSTER_NAME)' not found (nothing to delete)"; \
	fi
	@rm -f $(KUBECONFIG_FILE)

guard-context: ## Abort if kubectl context is not a known local cluster (kind or Docker Desktop)
	@if [[ "$${SKIP_GUARD:-}" == "1" ]]; then exit 0; fi; \
	if [[ "$${KUBECONFIG:-}" == "$(KUBECONFIG_FILE)" ]]; then exit 0; fi; \
	ctx=$$(kubectl config current-context 2>/dev/null || echo ""); \
	case "$$ctx" in \
		kind-$(CLUSTER_NAME)|docker-desktop|docker-for-desktop) \
			true;; \
		*) \
			printf '\n\033[1;31mSAFETY ABORT\033[0m: kubectl context is '"'"'%s'"'"'\n' "$$ctx" >&2; \
			echo "This Makefile targets local demo clusters only (kind or Docker Desktop)." >&2; \
			echo "Safe contexts: kind-$(CLUSTER_NAME), docker-desktop, docker-for-desktop" >&2; \
			echo "Override (dangerous): SKIP_GUARD=1 make <target>" >&2; \
			echo "" >&2; \
			exit 1;; \
	esac

check-cluster: guard-context ## Verify kind cluster is reachable and nodes are ready
	@command -v kubectl >/dev/null || { echo "kubectl is required but not installed." >&2; exit 1; }
	@command -v kind >/dev/null || { echo "kind is required. Install: https://kind.sigs.k8s.io/" >&2; exit 1; }
	@if [[ ! -f "$(KUBECONFIG_FILE)" ]]; then \
		echo "Kubeconfig not found at $(KUBECONFIG_FILE)." >&2; \
		echo "Create the cluster: make cluster" >&2; \
		exit 1; \
	fi
	@export KUBECONFIG="$(KUBECONFIG_FILE)"; \
	ctx=$$(kubectl config current-context 2>/dev/null || true); \
	expected="kind-$(CLUSTER_NAME)"; \
	if [[ -z "$$ctx" ]]; then \
		echo "WARNING: current context is '' (expected $$expected)." >&2; \
		echo "" >&2; \
		echo "Quick fix:" >&2; \
		echo "  1. Run: make cluster" >&2; \
		echo "  2. Run: make fix-context" >&2; \
		echo "  3. Or: export KUBECONFIG=$(KUBECONFIG_FILE)" >&2; \
		echo "" >&2; \
		echo "See README.md → Troubleshooting for details." >&2; \
		exit 1; \
	fi; \
	case "$$ctx" in \
		kind-$(CLUSTER_NAME)) \
			echo "kubectl context: $$ctx (kind)";; \
		docker-desktop|docker-for-desktop*) \
			echo "kubectl context: $$ctx (Docker Desktop — see README.md for kind setup)";; \
		*) \
			echo "WARNING: current context is '$$ctx' (expected kind-$(CLUSTER_NAME))." >&2; \
			echo "Switch with: kubectl config use-context kind-$(CLUSTER_NAME)" >&2; \
			echo "Or run: make fix-context" >&2; \
			if [[ -n "$$KUBECONFIG" && "$$KUBECONFIG" != "$(KUBECONFIG_FILE)" ]]; then \
				echo "Stale KUBECONFIG? Run: export KUBECONFIG=$(KUBECONFIG_FILE)" >&2; \
			fi;; \
	esac
	@export KUBECONFIG="$(KUBECONFIG_FILE)"; \
	kubectl cluster-info >/dev/null 2>&1 || { \
		echo "Cluster unreachable. Is the kind cluster running?" >&2; \
		echo "  - docker ps | grep $(CLUSTER_NAME)" >&2; \
		echo "  - make cluster  (recreate if needed)" >&2; \
		echo "See README.md → Troubleshooting." >&2; \
		exit 1; \
	}
	@export KUBECONFIG="$(KUBECONFIG_FILE)"; \
	node_count=$$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' '); \
	worker_count=$$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' 2>/dev/null | wc -l | tr -d ' '); \
	echo "Nodes: $$node_count ($$worker_count worker(s))"; \
	kubectl get nodes -o wide; \
	if [[ "$$worker_count" -lt 3 ]]; then \
		echo ""; \
		echo "WARNING: fewer than 3 workers — pod spread and drain demos work best with 3 workers."; \
		echo "  Expected: make cluster (uses $(KIND_CONFIG): 1 control-plane + 3 workers)"; \
		echo "  Eviction/PDB behavior still works; pods may land on the same node."; \
	fi

fix-context: ## Fix empty/wrong kubectl context (kind or Docker Desktop)
	@command -v kubectl >/dev/null || { echo "kubectl is required but not installed." >&2; exit 1; }
	@if [[ -f "$(KUBECONFIG_FILE)" ]]; then \
		export KUBECONFIG="$(KUBECONFIG_FILE)"; \
		echo "Using kind kubeconfig: $(KUBECONFIG_FILE)"; \
	elif [[ -n "$$KUBECONFIG" ]]; then \
		stale=0; \
		IFS=':' read -ra cfgs <<< "$$KUBECONFIG"; \
		for cfg in "$${cfgs[@]}"; do \
			if [[ ! -f "$$cfg" ]]; then \
				echo "WARNING: KUBECONFIG points to missing file: $$cfg" >&2; \
				stale=1; \
			fi; \
		done; \
		if [[ $$stale -eq 1 ]]; then \
			echo "Unset stale KUBECONFIG: unset KUBECONFIG" >&2; \
			echo "" >&2; \
		fi; \
	fi
	@echo "Available contexts:"
	@kubectl config get-contexts || true
	@echo ""
	@if [[ -f "$(KUBECONFIG_FILE)" ]]; then \
		export KUBECONFIG="$(KUBECONFIG_FILE)"; \
		if kubectl config get-contexts -o name 2>/dev/null | grep -qx 'kind-$(CLUSTER_NAME)'; then \
			echo "Switching to kind-$(CLUSTER_NAME)..."; \
			kubectl config use-context kind-$(CLUSTER_NAME); \
		else \
			echo "ERROR: kind-$(CLUSTER_NAME) context not found in $(KUBECONFIG_FILE)." >&2; \
			echo "Run: make cluster" >&2; \
			exit 1; \
		fi; \
	elif kubectl config get-contexts -o name 2>/dev/null | grep -qx 'kind-$(CLUSTER_NAME)'; then \
		echo "Switching to kind-$(CLUSTER_NAME)..."; \
		kubectl config use-context kind-$(CLUSTER_NAME); \
	elif kubectl config get-contexts -o name 2>/dev/null | grep -qx 'docker-desktop'; then \
		echo "Switching to docker-desktop (Docker Desktop fallback)..."; \
		kubectl config use-context docker-desktop; \
	elif kubectl config get-contexts -o name 2>/dev/null | grep -qx 'docker-for-desktop'; then \
		echo "Switching to docker-for-desktop (older Docker Desktop)..."; \
		kubectl config use-context docker-for-desktop; \
	else \
		echo "ERROR: No kind-$(CLUSTER_NAME), docker-desktop, or docker-for-desktop context found." >&2; \
		echo "Create kind cluster: make cluster" >&2; \
		echo "Or enable Kubernetes in Docker Desktop (README.md → Alternative)." >&2; \
		exit 1; \
	fi
	@echo ""
	@echo "Verifying cluster access..."
	@kubectl get nodes || { \
		echo "Cluster unreachable." >&2; \
		echo "kind: make cluster && export KUBECONFIG=$(KUBECONFIG_FILE)" >&2; \
		echo "Docker Desktop: enable Kubernetes and wait for it to start." >&2; \
		echo "See README.md → Troubleshooting." >&2; \
		exit 1; \
	}

argocd: check-cluster ## Install Argo CD and wait for server ready
	@kubectl get namespace $(ARGOCD_NS) >/dev/null 2>&1 || kubectl create namespace $(ARGOCD_NS)
	@printf '$(FMT_H)Installing Argo CD...$(FMT_RESET)\n'
	@printf '$(FMT_C)  $ kubectl apply --server-side -n $(ARGOCD_NS) -f <install.yaml>$(FMT_RESET)\n'
	@kubectl apply --server-side --force-conflicts -n $(ARGOCD_NS) -f $(ARGOCD_INSTALL)
	@printf '$(FMT_H)Applying demo config (anonymous admin, insecure HTTP)...$(FMT_RESET)\n'
	@printf '$(FMT_C)  $ kubectl apply -n $(ARGOCD_NS) -f manifests/argocd/insecure-anonymous.yaml$(FMT_RESET)\n'
	@kubectl apply -n $(ARGOCD_NS) -f manifests/argocd/insecure-anonymous.yaml
	@kubectl rollout restart deployment/argocd-server -n $(ARGOCD_NS)
	@kubectl rollout restart deployment/argocd-repo-server -n $(ARGOCD_NS)
	@printf '$(FMT_H)Waiting for argocd-server rollout...$(FMT_RESET)\n'
	@kubectl rollout status deployment/argocd-server -n $(ARGOCD_NS) --timeout=300s
	@kubectl rollout status deployment/argocd-repo-server -n $(ARGOCD_NS) --timeout=300s
	@kubectl rollout status deployment/argocd-applicationset-controller -n $(ARGOCD_NS) --timeout=300s 2>/dev/null || true
	@$(MAKE) argocd-expose

argocd-expose: check-cluster ## Expose Argo CD UI via NodePort (ARGOCD_NODE_PORT, default 30080)
	@echo "Waiting for argocd-server pod to be Ready..."
	@kubectl wait --for=condition=Ready pod \
		-l app.kubernetes.io/name=argocd-server -n $(ARGOCD_NS) --timeout=120s
	@sed 's/nodePort: 30080/nodePort: $(ARGOCD_NODE_PORT)/' manifests/argocd/nodeport-patch.yaml | \
		kubectl apply -f -
	@echo ""
	@printf '$(FMT_H)Argo CD UI:$(FMT_RESET) http://localhost:$(ARGOCD_NODE_PORT)  (no login required)\n'
	@echo "Fallback tunnels: make port-forward  or  make argocd-proxy"
	@echo "Note: existing clusters need 'make cluster-delete && make cluster' for host port mapping"

argocd-password: ## Print initial Argo CD admin password
	@kubectl -n $(ARGOCD_NS) get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' 2>/dev/null | base64 -d; echo

port-forward: check-cluster ## Port-forward Argo CD UI (fallback; prefer make argocd-expose on kind)
	@echo "Waiting for argocd-server pod to be Ready..."
	@kubectl wait --for=condition=Ready pod \
		-l app.kubernetes.io/name=argocd-server -n $(ARGOCD_NS) --timeout=120s
	@if command -v lsof >/dev/null 2>&1 && \
		lsof -iTCP:$(ARGOCD_LOCAL_PORT) -sTCP:LISTEN -t >/dev/null 2>&1; then \
		echo "ERROR: local port $(ARGOCD_LOCAL_PORT) is already in use." >&2; \
		echo "Use another port: ARGOCD_LOCAL_PORT=9080 make port-forward" >&2; \
		echo "Or use direct access: make argocd-expose → http://localhost:$(ARGOCD_NODE_PORT)" >&2; \
		exit 1; \
	fi
	@echo "Prefer direct access on kind: make argocd-expose → http://localhost:$(ARGOCD_NODE_PORT)"
	@echo "Open http://127.0.0.1:$(ARGOCD_LOCAL_PORT) (Ctrl+C to stop)"
	@echo "If connection resets, use: make argocd-expose or make argocd-proxy"
	@kubectl port-forward deployment/argocd-server -n $(ARGOCD_NS) \
		--address 127.0.0.1 $(ARGOCD_LOCAL_PORT):8080

argocd-proxy: check-cluster ## kubectl proxy to Argo CD UI (fallback; prefer make argocd-expose on kind)
	@echo "Waiting for argocd-server pod to be Ready..."
	@kubectl wait --for=condition=Ready pod \
		-l app.kubernetes.io/name=argocd-server -n $(ARGOCD_NS) --timeout=120s
	@echo "Prefer direct access on kind: make argocd-expose → http://localhost:$(ARGOCD_NODE_PORT)"
	@echo "Open (leave this running):"
	@echo "  http://127.0.0.1:$(ARGOCD_PROXY_PORT)/api/v1/namespaces/$(ARGOCD_NS)/services/http:argocd-server:80/proxy/"
	@kubectl proxy --port=$(ARGOCD_PROXY_PORT) --address=127.0.0.1

deploy: deploy-direct ## Apply relaxed overlay via kubectl (works offline)
deploy-direct: guard-context ## kubectl apply relaxed overlay (no Argo CD required)
	@printf '$(FMT_C)  $ kubectl kustomize $(RELAXED_KUSTOMIZE) | kubectl apply -f -$(FMT_RESET)\n'
	@$(call kustomize_apply,$(RELAXED_KUSTOMIZE))
	@$(MAKE) wait-ready
	@$(MAKE) demo-expose

deploy-strict: guard-context ## Apply strict PDB overlay via kubectl
	@printf '$(FMT_C)  $ kubectl kustomize $(STRICT_KUSTOMIZE) | kubectl apply -f -$(FMT_RESET)\n'
	@$(call kustomize_apply,$(STRICT_KUSTOMIZE))
	@$(MAKE) wait-ready

argocd-app: check-cluster argocd-cli-check ## Create/update Argo CD Application and sync desired state
	@printf '$(FMT_H)Creating/updating Argo CD Application $(ARGOCD_APP)...$(FMT_RESET)\n'
	@printf '$(FMT_C)  $ $(ARGOCD_CLI) app create $(ARGOCD_APP) --repo $(DEMO_REPO_URL) --path $(DEMO_OVERLAY) --dest-server https://kubernetes.default.svc --dest-namespace $(NAMESPACE) --sync-policy automated --auto-prune --self-heal --upsert$(FMT_RESET)\n'
	@$(ARGOCD_CLI) app create $(ARGOCD_APP) $(ARGOCD_APP_FLAGS) \
		--repo "$(DEMO_REPO_URL)" \
		--revision main \
		--path "$(DEMO_OVERLAY)" \
		--dest-server https://kubernetes.default.svc \
		--dest-namespace "$(NAMESPACE)" \
		--project default \
		--label app.kubernetes.io/part-of=demo-app \
		--sync-policy automated \
		--auto-prune \
		--self-heal \
		--sync-option CreateNamespace=true \
		--set-finalizer \
		--upsert
	@echo "Argo CD Application registered. repoURL=$(DEMO_REPO_URL), path=$(DEMO_OVERLAY)"
	@$(MAKE) argocd-sync

argocd-sync: check-cluster argocd-cli-check ## Sync demo-app through Argo CD CLI and wait Healthy/Synced
	@printf '$(FMT_H)Syncing $(ARGOCD_APP) through Argo CD...$(FMT_RESET)\n'
	@printf '$(FMT_C)  $ $(ARGOCD_CLI) app sync $(ARGOCD_APP) --prune$(FMT_RESET)\n'
	@$(ARGOCD_CLI) app sync $(ARGOCD_APP) $(ARGOCD_APP_FLAGS) --prune --timeout 300
	@$(MAKE) argocd-wait

argocd-wait: check-cluster argocd-cli-check ## Wait for demo-app Application Synced and Healthy in Argo CD
	@echo "Waiting for Argo CD Application $(ARGOCD_APP) to become Synced and Healthy..."
	@echo "(Manifests must exist at the configured repo/path — push your fork if using DEMO_REPO_URL override)"
	@$(ARGOCD_CLI) app wait $(ARGOCD_APP) $(ARGOCD_APP_FLAGS) --sync --health --timeout 300 || { \
		echo "ERROR: $(ARGOCD_APP) did not reach Synced/Healthy within 300s." >&2; \
		echo "Push manifests to $(DEMO_REPO_URL) or set DEMO_REPO_URL to a reachable repo." >&2; \
		echo "Offline fallback: make deploy-direct" >&2; \
		$(ARGOCD_CLI) app get $(ARGOCD_APP) $(ARGOCD_APP_FLAGS) 2>/dev/null || true; \
		exit 1; \
	}
	@echo "$(ARGOCD_APP) is Synced and Healthy."

argocd-relaxed: check-cluster argocd-cli-check ## Set Argo CD desired state to relaxed PDB and sync
	@printf '$(FMT_H)Argo CD desired state: relaxed PDB$(FMT_RESET)\n'
	@printf '$(FMT_C)  $ $(ARGOCD_CLI) app set $(ARGOCD_APP) --path $(DEMO_OVERLAY)$(FMT_RESET)\n'
	@$(ARGOCD_CLI) app set $(ARGOCD_APP) $(ARGOCD_APP_FLAGS) --path "$(DEMO_OVERLAY)"
	@$(MAKE) argocd-sync
	@printf '$(FMT_C)  $ kubectl get pdb -n $(NAMESPACE)$(FMT_RESET)\n'
	@kubectl get pdb -n $(NAMESPACE)

argocd-strict: check-cluster argocd-cli-check ## Set Argo CD desired state to strict PDB and sync
	@printf '$(FMT_H)Argo CD desired state: strict PDB$(FMT_RESET)\n'
	@printf '$(FMT_C)  $ $(ARGOCD_CLI) app set $(ARGOCD_APP) --path $(STRICT_OVERLAY)$(FMT_RESET)\n'
	@$(ARGOCD_CLI) app set $(ARGOCD_APP) $(ARGOCD_APP_FLAGS) --path "$(STRICT_OVERLAY)"
	@$(MAKE) argocd-sync
	@printf '$(FMT_C)  $ kubectl get pdb -n $(NAMESPACE)$(FMT_RESET)\n'
	@kubectl get pdb -n $(NAMESPACE)
	@printf '$(FMT_W)Strict PDB active (minAvailable: 2). ALLOWED DISRUPTIONS=0 when 2 replicas are running — eviction and drain will be blocked.$(FMT_RESET)\n'

argocd-pause-sync: check-cluster argocd-cli-check ## Pause automated sync (manual mode) for maintenance/drift demos
	@if ! kubectl get application $(ARGOCD_APP) -n $(ARGOCD_NS) >/dev/null 2>&1; then \
		echo "No $(ARGOCD_APP) Application — create it with make argocd-app." >&2; \
		exit 0; \
	fi
	@printf '$(FMT_H)Pausing automated sync for $(ARGOCD_APP)...$(FMT_RESET)\n'
	@$(ARGOCD_CLI) app set $(ARGOCD_APP) $(ARGOCD_APP_FLAGS) --sync-policy manual
	@printf '$(FMT_W)Automated sync is paused. Manual Argo CD sync still works with: make argocd-sync$(FMT_RESET)\n'
	@printf '$(FMT_W)Restore automated prune/selfHeal with: make argocd-resume-sync$(FMT_RESET)\n'

argocd-resume-sync: check-cluster argocd-cli-check ## Resume automated Argo CD sync with prune + selfHeal
	@printf '$(FMT_H)Resuming automated sync for $(ARGOCD_APP)...$(FMT_RESET)\n'
	@$(ARGOCD_CLI) app set $(ARGOCD_APP) $(ARGOCD_APP_FLAGS) \
		--sync-policy automated \
		--auto-prune \
		--self-heal
	@printf '$(FMT_W)Automated sync restored — Argo CD will reconcile drift to the selected repo path.$(FMT_RESET)\n'

pdb-relaxed: argocd-relaxed ## Alias: switch to relaxed PDB through Argo CD

pdb-strict: argocd-strict ## Alias: switch to strict PDB through Argo CD

pdb-explain: ## Show PDB YAML variants and current live PDB status
	@printf '$(FMT_H)Relaxed PDB YAML ($(RELAXED_KUSTOMIZE))$(FMT_RESET)\n'
	@sed -n '1,80p' manifests/k8s-demo/pdb-relaxed.yaml
	@echo ""
	@printf '$(FMT_H)Strict PDB YAML ($(STRICT_OVERLAY))$(FMT_RESET)\n'
	@sed -n '1,80p' manifests/k8s-demo/pdb-strict.yaml
	@echo ""
	@printf '$(FMT_H)Live PDB status$(FMT_RESET)\n'
	@if kubectl get pdb demo-app-pdb -n $(NAMESPACE) >/dev/null 2>&1; then \
		kubectl get pdb demo-app-pdb -n $(NAMESPACE) -o wide; \
		echo ""; \
		kubectl describe pdb demo-app-pdb -n $(NAMESPACE); \
	else \
		echo "No live PDB found in namespace $(NAMESPACE). Run make setup first for live status."; \
	fi

demo-data: guard-context wait-ready ## Write unique marker files to each pod's PVC at /data
	@./scripts/write-data.sh

wait-ready: ## Wait for StatefulSet, pods, PVCs, and PDB
	@./scripts/wait-ready.sh

status: ## Show pods, PVCs, PDB, and node placement
	@printf '$(FMT_H)=== Nodes ===\n$(FMT_RESET)'
	@printf '$(FMT_C)  $ kubectl get nodes -o wide$(FMT_RESET)\n'
	@kubectl get nodes -o wide
	@echo ""
	@printf '$(FMT_H)=== demo namespace ===\n$(FMT_RESET)'
	@printf '$(FMT_C)  $ kubectl get pods,pvc,pdb,svc -n $(NAMESPACE) -o wide$(FMT_RESET)\n'
	@kubectl get pods,pvc,pdb,svc -n $(NAMESPACE) -o wide 2>/dev/null || \
		echo "Namespace $(NAMESPACE) not found — run 'make deploy'"
	@echo ""
	@printf '$(FMT_H)=== Argo CD Application ===\n$(FMT_RESET)'
	@printf '$(FMT_C)  $ kubectl get application demo-app -n $(ARGOCD_NS)$(FMT_RESET)\n'
	@kubectl get application demo-app -n $(ARGOCD_NS) 2>/dev/null || \
		echo "(no Argo CD Application — run 'make argocd-app' or 'make setup')"
	@echo ""

demo-expose: check-cluster ## Expose demo-app HTTP via NodePort (DEMO_NODE_PORT, default 30090)
	@if ! kubectl get svc demo-app-http -n $(NAMESPACE) >/dev/null 2>&1; then \
		echo "Service demo-app-http not found in namespace $(NAMESPACE)." >&2; \
		echo "Deploy first: make deploy-direct  or  make setup" >&2; \
		exit 1; \
	fi
	@sed 's/nodePort: 30090/nodePort: $(DEMO_NODE_PORT)/' manifests/k8s-demo/demo-nodeport.yaml | \
		kubectl apply -f -
	@echo ""
	@printf '$(FMT_H)Demo app HTTP:$(FMT_RESET) http://localhost:$(DEMO_NODE_PORT)/\n'
	@echo "  http://localhost:$(DEMO_NODE_PORT)/           → PVC marker dashboard"
	@echo "  http://localhost:$(DEMO_NODE_PORT)/marker.txt → raw PVC marker file"
	@echo "Note: existing clusters need 'make cluster-delete && make cluster' for host port mapping"

demo-url: demo-expose ## Print demo-app HTTP URL (NodePort $(DEMO_NODE_PORT); no tunnel)

logs: ## Tail logs from demo-app pods
	@printf '$(FMT_C)  $ kubectl logs -n $(NAMESPACE) -l app=demo-app --tail=50 --prefix=true$(FMT_RESET)\n'
	@kubectl logs -n $(NAMESPACE) -l app=demo-app --tail=50 --prefix=true

evict: ## Evict one demo pod (shows PDB allow/block)
	@./scripts/evict-pod.sh

drain: ## Cordon and drain a worker running demo pods
	@./scripts/drain-node.sh || true

act-pvc: guard-context ## Guided act: PVC data survives eviction/recreation
	@$(MAKE) argocd-relaxed
	@$(MAKE) demo-expose
	@$(MAKE) wait-ready
	@$(MAKE) demo-data
	@./scripts/act-pvc.sh

act-pdb: guard-context ## Guided act: strict PDB blocks voluntary eviction
	@$(MAKE) wait-ready
	@./scripts/act-pdb.sh

act-drain: guard-context ## Guided act: pause Argo auto-sync, then strict PDB blocks drain
	@$(MAKE) argocd-pause-sync
	@$(MAKE) argocd-strict
	@./scripts/drain-node.sh || true
	@echo ""
	@printf '$(FMT_H)Recent demo events$(FMT_RESET)\n'
	@kubectl get events -n $(NAMESPACE) --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true
	@echo ""
	@printf '$(FMT_W)Restore after this act: make uncordon && make argocd-relaxed && make argocd-resume-sync$(FMT_RESET)\n'

uncordon: ## Uncordon all nodes (post-drain cleanup)
	@for node in $$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do \
		kubectl uncordon "$$node" 2>/dev/null || true; \
	done
	@printf '$(FMT_C)  $ kubectl get nodes$(FMT_RESET)\n'
	@kubectl get nodes

teardown: guard-context uncordon ## Remove demo app, Argo Application, and demo namespace
	@printf '$(FMT_H)Removing demo resources...$(FMT_RESET)\n'
	@kubectl delete application demo-app -n $(ARGOCD_NS) --ignore-not-found --wait=false
	@-$(call kustomize_delete,$(RELAXED_KUSTOMIZE))
	@-$(call kustomize_delete,$(STRICT_KUSTOMIZE))
	@kubectl delete namespace $(NAMESPACE) --ignore-not-found --wait=false
	@echo "Demo resources removed. kind cluster '$(CLUSTER_NAME)' is unchanged."

clean: teardown cluster-delete ## Remove demo resources and delete kind cluster

validate: ## Build all kustomize overlays (offline YAML check)
	@kubectl kustomize $(RELAXED_KUSTOMIZE) $(KUSTOMIZE_FLAGS) >/dev/null
	@kubectl kustomize $(STRICT_KUSTOMIZE) $(KUSTOMIZE_FLAGS) >/dev/null
	@printf '$(FMT_H)All overlays build successfully.$(FMT_RESET)\n'

dry-run: validate ## Alias for validate
