# Demo steps — command cheat sheet

Condensed speaker reference for live demos. Full narrative, timing, and troubleshooting: **[DEMO.md](DEMO.md)**.

| Resource | Name |
|----------|------|
| Cluster / context | `pdb-pvc-demo` / `kind-pdb-pvc-demo` |
| Namespace | `demo` |
| StatefulSet | `demo-app` |
| Pods | `demo-app-0`, `demo-app-1` |
| PVCs | `data-demo-app-0`, `data-demo-app-1` (1Gi RWO, `/data`) |
| PDB | `demo-app-pdb` |
| Workers | `pdb-pvc-demo-worker`, `pdb-pvc-demo-worker2` |
| GitOps path | `manifests/k8s-demo` (relaxed) · `manifests/k8s-demo/overlays/strict` (strict) |

---

## Prep (before the room)

```bash
cd k8s-pdb-pvc-eviction-demo
make setup          # cluster + Argo CD + demo-app synced + demo data
make check-cluster  # context kind-pdb-pvc-demo, 3 nodes Ready
make status         # pods spread, PVCs Bound, PDB present
# Argo CD UI (preferred — no tunnel):
open http://localhost:30080
# Fallback if NodePort unavailable:
make port-forward   # http://127.0.0.1:8888
# Or: make argocd-proxy (prints proxy URL)
```

| Step | Command | Notes |
|------|---------|-------|
| Bootstrap | `make setup` | Registers `demo-app` Application; waits Synced/Healthy |
| Verify | `make check-cluster` | 1 control-plane + 2 workers Ready |
| Snapshot | `make status` | `demo-app-0` / `demo-app-1` on separate workers |
| Argo CD UI | http://localhost:30080 | After `make argocd` / `make setup` — no login; `make argocd-expose` to re-apply |
| Argo CD fallback | `make port-forward` | Second terminal — tunnel; can reset on kind/Mac |
| Optional | `k9s` | `:nodes`, `:applications argocd`, `:pods demo` |

**Expected:** Application `demo-app` **Synced / Healthy**; two pods **Running** on `pdb-pvc-demo-worker` and `pdb-pvc-demo-worker2`; PVCs `data-demo-app-0` and `data-demo-app-1` **Bound**.

---

## Suggested live order

| # | Section | ~min | PDB mode |
|---|---------|------|----------|
| 0 | [Prep](#prep-before-the-room) | — | relaxed (default) |
| 1 | [GitOps deployment](#1-gitops-deployment) | 5 | relaxed |
| 2 | [Drift detection](#2-drift-detection) | 5 | relaxed |
| 3 | [PVC persistence](#3-pvc-persistence) | 8 | relaxed |
| 4 | [PDB protection](#4-pdb-protection) | 5 | relaxed → strict |
| 5 | [Eviction API](#5-eviction-api) | 8 | relaxed, then strict |
| 6 | [Cordon / drain / migrate](#6-cordon--drain--migrate) | 10 | strict, then relaxed |

After section 6, run `make uncordon` if any node is cordoned. Relaxed PDB is the default after `make setup`.

---

## k9s quick reference

| Key / command | Action |
|---------------|--------|
| `:` | Command mode — enter a resource view |
| `/` | Filter list |
| `d` | Describe selected resource |
| `l` | Logs |
| `s` | Shell (exec) |
| `Ctrl-k` | Delete selected resource |
| `Ctrl-a` | Toggle all namespaces |
| `?` | Help |
| `Esc` | Back / clear filter |

| View | k9s command | Use during |
|------|-------------|------------|
| Nodes | `:nodes` | Prep, drain demo |
| Pods | `:pods demo` | Spread, PVC, eviction |
| PVCs | `:pvc demo` | Persistence, rebind |
| PDB | `:pdb demo` | **ALLOWED DISRUPTIONS** column |
| Applications | `:applications argocd` | GitOps sync status |
| Events | `:events demo` | Drain / eviction failures |

---

## Makefile shortcuts

| Target | Purpose |
|--------|---------|
| `make setup` | Full bootstrap (cluster + Argo CD + GitOps sync + demo data) |
| `make status` | Nodes, pods, PVCs, PDB, Argo Application |
| `make argocd-expose` | Argo CD UI at http://localhost:30080 (preferred on kind/Mac) |
| `make port-forward` | Argo CD UI tunnel fallback (`ARGOCD_LOCAL_PORT`, default 8888) |
| `make argocd-proxy` | kubectl proxy fallback for Argo CD UI |
| `make demo-data` | Write `/data/marker.txt` on each pod's PVC |
| `make evict` | Evict one Running pod via Eviction API |
| `make pdb-relaxed` | `minAvailable: 1` — one voluntary disruption allowed |
| `make pdb-strict` | `minAvailable: 2` — blocks voluntary eviction/drain |
| `make drain` | Cordon + drain a worker running demo pods |
| `make uncordon` | Uncordon all nodes (post-drain cleanup) |
| `make deploy-direct` | Apply manifests via kubectl (offline, no git push) |
| `make argocd-app` | Re-register Application + wait Synced/Healthy |
| `make teardown` | Remove demo resources (cluster stays) |
| `make clean` | Teardown + delete kind cluster |

---

## 1. GitOps deployment

**Talking point:** Desired state lives in git; Argo CD watches the repo and reconciles cluster state automatically (prune + selfHeal).

### kubectl

```bash
make check-cluster
kubectl get nodes -o wide
kubectl get application demo-app -n argocd
kubectl get statefulset,pdb,svc -n demo
kubectl get pods,pvc -n demo -o wide
make status
```

### Argo CD UI

1. Open http://localhost:30080 (after `make argocd` or `make setup`; no tunnel).
2. Click **demo-app** → **Synced / Healthy**, source path `manifests/k8s-demo`.
3. Expand resource tree: StatefulSet, PDB, Service, PVCs.

### k9s

| View | Action |
|------|--------|
| `:applications argocd` | Select `demo-app`, press `d` for sync conditions |
| `:pods demo` | Show `demo-app-0` / `demo-app-1` on different workers |
| `:pvc demo` | `data-demo-app-0`, `data-demo-app-1` — status Bound |

**Expected:** 3 nodes Ready; Argo CD Application `demo-app` Synced/Healthy; two pods Running on separate workers (`pdb-pvc-demo-worker`, `pdb-pvc-demo-worker2`); PVCs Bound.

---

## 2. Drift detection

**Talking point:** Manual `kubectl` edits are drift. Argo CD `selfHeal: true` restores git truth within ~3 minutes (or force sync from the UI / CLI).

### kubectl

```bash
# Label drift
kubectl label pod -n demo demo-app-0 drift=demo --overwrite
kubectl get pod -n demo demo-app-0 --show-labels

# Watch Application reconcile (or wait ~3 min for automated sync)
kubectl get application demo-app -n argocd -w

# Force sync (optional): Argo CD UI → demo-app → Sync
# Or: argocd app sync demo-app   (after argocd login)

# Delete pod — Argo / StatefulSet recreates from desired state
kubectl delete pod -n demo demo-app-0
kubectl wait --for=condition=Ready pod/demo-app-0 -n demo --timeout=120s
kubectl get pod -n demo demo-app-0 --show-labels

# Delete StatefulSet — Argo recreates from git
kubectl delete statefulset -n demo demo-app
kubectl get statefulset,pods -n demo -w
```

### k9s

| View | Action |
|------|--------|
| `:applications argocd` | Watch `demo-app` flip OutOfSync → Syncing → Synced |
| `:pods demo` | Pod count drops then returns to 2 |
| `:events demo` | Argo / controller recreate events |

**Expected:** Drift label removed; deleted pod/StatefulSet recreated; Application returns to **Synced / Healthy**. PVCs and data on `/data` survive pod recreation.

---

## 3. PVC persistence

**Talking point:** Data lives on the PVC at `/data`, not the container filesystem. Eviction and reschedule reattach the same volume claim.

### kubectl

```bash
make demo-data
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt

# Simulate eviction reschedule
kubectl delete pod -n demo demo-app-0
kubectl wait --for=condition=Ready pod/demo-app-0 -n demo --timeout=120s
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt

kubectl get pvc -n demo data-demo-app-0 -o wide
kubectl get pod -n demo demo-app-0 -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}{"\n"}'
```

### k9s

| View | Action |
|------|--------|
| `:pods demo` | Delete `demo-app-0` (`Ctrl-k`), watch recreate |
| `:pvc demo` | `data-demo-app-0` stays Bound (same claim name) |
| `:pods demo` → `s` | `cat /data/marker.txt` inside shell |

**Expected:** Marker content unchanged after pod delete; PVC `data-demo-app-0` still **Bound** to the new `demo-app-0` pod.

---

## 4. PDB protection

**Talking point:** PodDisruptionBudget gates *voluntary* disruption (evict, drain). Tune `minAvailable` for replica count and SLO — relaxed allows one pod down; strict allows zero.

### kubectl — relaxed (default)

```bash
make pdb-relaxed
kubectl get pdb -n demo demo-app-pdb -o wide
kubectl get pdb -n demo demo-app-pdb -o jsonpath='minAvailable={.spec.minAvailable} allowed={.status.disruptionsAllowed}{"\n"}'
```

### kubectl — strict

```bash
make pdb-strict
kubectl get pdb -n demo demo-app-pdb -o wide
kubectl get pdb -n demo demo-app-pdb -o jsonpath='minAvailable={.spec.minAvailable} allowed={.status.disruptionsAllowed}{"\n"}'
```

### k9s

| View | Action |
|------|--------|
| `:pdb demo` | Column **ALLOWED DISRUPTIONS**: `1` (relaxed) or `0` (strict) |
| `:pods demo` | Two Running pods; PDB selector `app: demo-app` |

| PDB mode | minAvailable | ALLOWED DISRUPTIONS (2 replicas) |
|----------|--------------|----------------------------------|
| Relaxed | 1 | 1 |
| Strict | 2 | 0 |

**Expected:** Relaxed PDB allows one voluntary disruption; strict PDB allows zero — any evict/drain attempt on demo pods will be blocked.

---

## 5. Eviction API

**Talking point:** `kubectl drain` and `kubectl evict` use the policy/v1 **Eviction** API. The PDB controller decides allow (HTTP 201) or block (HTTP 429).

### kubectl — relaxed (eviction succeeds)

```bash
make pdb-relaxed
make evict
make status
make demo-data
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt
```

Manual eviction (same as `make evict` / `scripts/evict-pod.sh`):

```bash
kubectl create -f - <<'EOF'
apiVersion: policy/v1
kind: Eviction
metadata:
  name: demo-app-0
  namespace: demo
spec:
  deleteOptions:
    gracePeriodSeconds: 30
EOF
```

### kubectl — strict (eviction blocked)

```bash
make pdb-strict
make evict
```

### k9s

| View | Action |
|------|--------|
| `:pdb demo` | ALLOWED DISRUPTIONS `1` → evict OK; `0` → blocked |
| `:pods demo` | Watch pod terminate and recreate (relaxed only) |
| `:events demo` | PDB violation message on strict failure |

**Expected (relaxed):** Eviction succeeds; StatefulSet recreates pod; PVC `data-demo-app-0` rebinds; marker on `/data` survives.

**Expected (strict):** Error like `Cannot evict pod as it would violate the pod's disruption budget`.

---

## 6. Cordon / drain / migrate

**Talking point:** Node maintenance cordons the node, then drains pods via the Eviction API. Strict PDB blocks the whole drain; relaxed PDB allows one pod to move while the other stays up on the second worker.

### kubectl — strict PDB (drain blocked)

```bash
make pdb-strict
make drain
kubectl get nodes
kubectl get events -n demo --sort-by='.lastTimestamp' | tail -15
make status
```

Manual cordon + drain (pick worker from `kubectl get pods -n demo -o wide`):

```bash
kubectl cordon pdb-pvc-demo-worker
kubectl drain pdb-pvc-demo-worker \
  --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=120s
```

### kubectl — relaxed PDB (migrate succeeds)

```bash
make pdb-relaxed
make uncordon
make status
make drain
make status
kubectl get pods -n demo -o wide
```

### k9s

| View | Action |
|------|--------|
| `:nodes` | Cordoned node shows `SchedulingDisabled` |
| `:pods demo` | One pod evicted/rescheduled; one remains on other worker |
| `:pdb demo` | Strict: ALLOWED DISRUPTIONS `0` during failed drain |
| `:events demo` | PodDisruptionBudget events |

**Expected (strict):** Worker cordoned (`SchedulingDisabled`); drain fails or times out; demo pod on `pdb-pvc-demo-worker2` keeps running; events mention PodDisruptionBudget.

**Expected (relaxed):** One pod evicts from cordoned worker and reschedules on the other; PVC rebinds; drain completes for demo pods.

---

## Teardown

```bash
make uncordon        # if nodes were cordoned during drain demo
make teardown        # remove demo resources; kind cluster stays
make clean           # teardown + delete kind cluster
make cluster-delete  # delete kind cluster only
```

---

## Argo CD UI troubleshooting

| Symptom | Fix |
|---------|-----|
| UI unreachable at :30080 | `make argocd-expose`; if cluster predates NodePort mapping: `make cluster-delete && make cluster && make argocd` |
| `connection reset by peer` / `lost connection to pod` | Use http://localhost:30080 (`make argocd-expose`); avoid tunnels on kind/Mac |
| `local port … is already in use` | `ARGOCD_LOCAL_PORT=9080 make port-forward` or use NodePort :30080 |
| UI blank / connection refused | Use `http://` not `https`; `kubectl logs -n argocd deployment/argocd-server -f` |
| Pod not Ready | `kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server` — wait or `make argocd` |

**Diagnostics (another terminal):**

```bash
curl -v http://127.0.0.1:30080/
kubectl logs -n argocd deployment/argocd-server -f
kubectl get svc argocd-server -n argocd
```
