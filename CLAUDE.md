# CLAUDE.md — project context for Claude Code

This is a **local demo project** that teaches three Kubernetes concepts through live terminal exercises:
1. **PVC persistence** — data survives pod eviction/reschedule
2. **PodDisruptionBudget enforcement** — PDB gates the Eviction API (HTTP 201 / 429)
3. **Argo CD GitOps** — desired state lives in git; drift is automatically reconciled

It is not production code. Correctness of the demo UX matters more than generality or abstraction.

---

## Cluster

| Item | Value |
|------|-------|
| Tool | kind (Kubernetes in Docker) |
| Cluster name | `pdb-pvc-demo` |
| kubectl context | `kind-pdb-pvc-demo` |
| Kubeconfig | `.kube/kind-pdb-pvc-demo` (auto-exported by Makefile if present) |
| Nodes | 1 control-plane + 3 workers (`pdb-pvc-demo-worker`, `pdb-pvc-demo-worker2`, `pdb-pvc-demo-worker3`) |
| Kubernetes version | v1.34.0 |

## Demo resources

| Resource | Name | Namespace |
|----------|------|-----------|
| StatefulSet | `demo-app` | `demo` |
| Pods | `demo-app-0`, `demo-app-1` | `demo` |
| PVCs | `data-demo-app-0`, `data-demo-app-1` | `demo` |
| PDB | `demo-app-pdb` | `demo` |
| Argo CD Application | `demo-app` | `argocd` |
| Argo CD UI | http://localhost:30080 (NodePort, no login) | — |

**StatefulSet image:** `nginx:1.27-alpine` — serves HTTP on port 80, mounts 1Gi PVC at `/data`.
**Replica count:** 2 (intentional — strict PDB minAvailable=2 gives ALLOWED DISRUPTIONS=0).

## PDB modes

| Target | minAvailable | ALLOWED DISRUPTIONS (2 replicas) | Effect |
|--------|-------------|----------------------------------|--------|
| `make pdb-relaxed` | 1 | 1 | Eviction allowed |
| `make pdb-strict` | 2 | 0 | Eviction blocked (HTTP 429) |

Strict PDB only shows ALLOWED DISRUPTIONS=0 when exactly 2 replicas are running.

---

## Key files

```
Makefile                                   — all demo entrypoints; read this first
scripts/evict-pod.sh                       — evicts a pod, shows HTTP 201 / 429 clearly
scripts/drain-node.sh                      — cordons + drains a worker node
scripts/wait-ready.sh                      — waits for StatefulSet, pods, PVCs, PDB
scripts/write-data.sh                      — writes /data/marker.txt on each pod's PVC
manifests/k8s-demo/statefulset.yaml        — base StatefulSet (replicas: 2)
manifests/k8s-demo/pdb-relaxed.yaml        — minAvailable: 1
manifests/k8s-demo/pdb-strict.yaml         — minAvailable: 2
manifests/k8s-demo/overlays/relaxed/       — kustomize overlay (default)
manifests/k8s-demo/overlays/strict/        — kustomize overlay (strict PDB)
manifests/argocd/application.yaml          — Argo CD Application (URL injected by Makefile)
docs/DEMO-STEPS.md                         — speaker reference: make shortcuts + raw kubectl
docs/DEMO.md                               — full narrative with timing and talking points
```

## Common workflows

```bash
make setup          # full bootstrap: kind cluster + Argo CD + GitOps sync + demo data
make status         # show nodes, pods, PVCs, PDB, Argo CD app
make evict          # evict one pod via Eviction API (shows HTTP 201 or 429)
make pdb-strict     # switch to strict PDB (ALLOWED DISRUPTIONS: 0)
make pdb-relaxed    # switch back to relaxed PDB
make drain          # cordon + drain a worker node
make uncordon       # uncordon all nodes
make demo-data      # write /data/marker.txt on each pod
make teardown       # remove demo resources (cluster survives)
make clean          # teardown + delete kind cluster
```

---

## Non-obvious decisions / constraints

### Argo CD Application wait uses `--for=jsonpath`, not `--for=condition`
Argo CD Application CRD does NOT use `status.conditions[]`. It uses `status.sync.status` and `status.health.status`. The standard `kubectl wait --for=condition=Synced` always times out. The Makefile uses:
```bash
kubectl wait --for=jsonpath='{.status.sync.status}'=Synced application/demo-app -n argocd
kubectl wait --for=jsonpath='{.status.health.status}'=Healthy application/demo-app -n argocd
```

### kustomize uses `labels` (not `commonLabels`)
kustomize v5 deprecated `commonLabels`. All three kustomization.yaml files use:
```yaml
labels:
  - pairs:
      app.kubernetes.io/part-of: demo-app
    includeSelectors: true
    includeTemplates: true
```
`includeSelectors: true` is required because the deployed StatefulSet's `.spec.selector` already includes `app.kubernetes.io/part-of: demo-app` (set when the cluster was first created with `commonLabels`). StatefulSet selectors are immutable — the label must remain in the selector.

### StatefulSet selector is immutable
Once a StatefulSet is created, `.spec.selector` cannot be changed. Do not remove labels from the selector or you'll be forced to delete and recreate the StatefulSet (which would briefly delete the pods, though PVCs survive).

### Eviction API requires `kubectl proxy + curl`, NOT `kubectl create -f -`
The Eviction resource is a **pod subresource** at `/api/v1/namespaces/{ns}/pods/{name}/eviction`. It does not appear in `kubectl api-resources` and cannot be mapped by `kubectl create`. Always use:
```bash
kubectl proxy --port=38001 &
curl -s -w "\nHTTP %{http_code}\n" -X POST \
  http://localhost:38001/api/v1/namespaces/demo/pods/demo-app-0/eviction \
  -H 'Content-Type: application/json' \
  -d '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"demo-app-0","namespace":"demo"}}'
kill %1
```
`evict-pod.sh` uses this approach automatically (starts proxy on a random port, POSTs, shows HTTP 201 or 429).

### Context safety guard
All destructive Makefile targets depend on `guard-context`, which aborts if the current kubectl context is not one of:
- `kind-pdb-pvc-demo`
- `docker-desktop`
- `docker-for-desktop`

Override with `SKIP_GUARD=1 make <target>`. The guard is bypassed automatically when `KUBECONFIG` points to `.kube/kind-pdb-pvc-demo` (the local kind kubeconfig file).

### Argo CD GitOps means local manifest changes need a `git push`
Argo CD syncs from `DEMO_REPO_URL` (GitHub). Changing files locally and running `make deploy-direct` applies changes to the cluster immediately — but Argo CD will revert the cluster to match GitHub within ~3 minutes (selfHeal). Push to GitHub to make changes permanent.

### Extra PDB table in terminal output
If a zsh `preexec`/`precmd` hook runs `kubectl get pdb -n demo demo-app-pdb`, it produces an extra table before and/or after `make` commands. This is a shell hook in the user's zsh config, not a Makefile bug.

### `SessionAffinity` warning from kustomize
`Warning: spec.SessionAffinity is ignored for headless services` — this is a benign kubectl warning about the headless Service (ClusterIP: None). Safe to ignore.

---

## Argo CD UI

Preferred access: http://localhost:30080 (no login, anonymous admin via `insecure-anonymous.yaml`).

Fallbacks:
- `make port-forward` → http://127.0.0.1:8888 (tunnel; can reset on macOS/kind)
- `make argocd-proxy` → kubectl proxy URL

If the UI is unreachable: run `make argocd-expose` to re-apply the NodePort Service.

---

## Demo app testing

```bash
# Ping nginx inside the pod
kubectl exec -n demo demo-app-0 -- wget -qO- localhost

# Check PVC mount
kubectl exec -n demo demo-app-0 -- ls /data
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt  # after make demo-data
```