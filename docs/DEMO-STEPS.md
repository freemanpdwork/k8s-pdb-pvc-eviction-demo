# Demo steps — command cheat sheet

Condensed speaker reference for live demos. Full narrative, timing, and troubleshooting: **[DEMO.md](DEMO.md)**.

**Cluster:** kind `pdb-pvc-demo` · context `kind-pdb-pvc-demo` · namespace `demo`  
**App:** StatefulSet `demo-app` · pods `demo-app-0`, `demo-app-1` · PDB `demo-app-pdb`  
**PVCs:** `data-demo-app-0`, `data-demo-app-1` (1Gi RWO, mounted at `/data`)  
**Nodes:** `pdb-pvc-demo-control-plane`, `pdb-pvc-demo-worker`, `pdb-pvc-demo-worker2`  
**GitOps path:** `manifests/k8s-demo` (relaxed PDB) · `manifests/k8s-demo/overlays/strict` (strict PDB)

---

## Prep (before the room)

| Step | Command | Notes |
|------|---------|-------|
| Bootstrap | `make setup` | Cluster + Argo CD + `demo-app` synced + demo data |
| Verify | `make check-cluster` | Context `kind-pdb-pvc-demo`, 3 nodes Ready |
| Snapshot | `make status` | Pods spread across workers, PVCs Bound |
| Argo CD UI | `make port-forward` | **Second terminal** — http://localhost:8080 (no login) |
| Optional | `k9s` | `:nodes`, `:applications argocd`, `:pods demo` |

```bash
cd k8s-pdb-pvc-eviction-demo
make setup
make status
# second terminal:
make port-forward
```

**Expected:** `demo-app` Application **Synced / Healthy** in Argo CD; `demo-app-0` and `demo-app-1` Running on separate workers; PVCs `data-demo-app-0` and `data-demo-app-1` Bound.

---

## Suggested live order

| # | Demo | ~min |
|---|------|------|
| 0 | [Prep](#prep-before-the-room) | — |
| 1 | [GitOps deployment](#demo-1-gitops-deployment) | 5 |
| 2 | [PVC persistence](#demo-3-pvc-persistence) | 8 |
| 3 | [PDB protection (relaxed)](#demo-4-pdb-protection) | 5 |
| 4 | [Eviction API (relaxed)](#demo-5-eviction-api) | 8 |
| 5 | [PDB protection (strict)](#demo-4-pdb-protection) + [Eviction blocked](#demo-5-eviction-api) | 10 |
| 6 | [Cordon, drain, migrate](#demo-6-cordon-drain-migrate) | 10 |
| 7 | [Drift detection](#demo-2-drift-detection) | 5 |

Relaxed PDB is the default after `make setup`. Switch to strict before demos 5–6; restore relaxed before retrying drain.

---

## k9s quick reference

| Key / command | Action |
|---------------|--------|
| `:` | Command mode — enter a resource view |
| `/` | Filter list |
| `d` | Describe selected resource |
| `l` | Logs |
| `s` | Shell (exec) |
| `Ctrl-a` | Toggle all namespaces |
| `?` | Help |
| `Esc` | Back / clear filter |

| View | k9s command | Use during |
|------|-------------|------------|
| Nodes | `:nodes` | Prep, drain demo |
| Pods | `:pods demo` | PVC, eviction, spread |
| PVCs | `:pvc demo` | Persistence, rebind after evict |
| PDB | `:pdb demo` | ALLOWED DISRUPTIONS column |
| Applications | `:applications argocd` | GitOps sync status |
| Events | `:events demo` | Drain / eviction failures |

---

## Makefile shortcuts

| Target | Purpose |
|--------|---------|
| `make setup` | Full bootstrap (cluster + Argo CD + GitOps sync + demo data) |
| `make status` | Nodes, pods, PVCs, PDB, Argo Application |
| `make port-forward` | Argo CD UI at http://localhost:8080 |
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

## Demo #1: GitOps deployment

**Story:** Desired state lives in git; Argo CD reconciles the cluster automatically.

### kubectl

```bash
make check-cluster
kubectl get nodes -o wide
kubectl get application demo-app -n argocd
kubectl get pods,pvc,pdb -n demo -o wide
make status
```

### Argo CD UI

1. Open http://localhost:8080 (`make port-forward` in a second terminal).
2. Click **demo-app** → show **Synced / Healthy**, source path `manifests/k8s-demo`.
3. Expand resource tree: StatefulSet, PDB, Service, PVCs.

### k9s

| View | Keys |
|------|------|
| `:applications argocd` | Select `demo-app`, `d` for sync conditions |
| `:pods demo` | Show `demo-app-0` / `demo-app-1` on different workers |
| `:pvc demo` | `data-demo-app-0`, `data-demo-app-1` Bound |

**Expected:** 3 nodes Ready; Argo CD Application `demo-app` Synced/Healthy; two pods Running on separate workers; PVCs Bound.

---

## Demo #2: Drift detection

**Story:** Manual kubectl changes are drift; Argo CD `selfHeal: true` restores git truth within ~3 minutes.

### Pod label drift

```bash
kubectl label pod -n demo demo-app-0 drift=demo --overwrite
kubectl get pod -n demo demo-app-0 --show-labels
# wait ~3 min for automated sync, or force:
kubectl get application demo-app -n argocd -w
```

### Delete pod (self-heal recreates)

```bash
kubectl delete pod -n demo demo-app-0
kubectl wait --for=condition=Ready pod/demo-app-0 -n demo --timeout=120s
kubectl get pod -n demo demo-app-0 --show-labels
```

### Delete StatefulSet (Argo recreates)

```bash
kubectl delete statefulset -n demo demo-app
kubectl get statefulset,pods -n demo -w
# Argo CD recreates demo-app from git
```

### k9s

| View | Keys |
|------|------|
| `:applications argocd` | Watch `demo-app` flip OutOfSync → Syncing → Synced |
| `:pods demo` | Pod count drops then returns to 2 |
| `:events demo` | Argo / controller recreate events |

**Expected:** Drift label removed; deleted pod/StatefulSet recreated; Application returns to Synced/Healthy. PVCs and data survive pod recreation.

---

## Demo #3: PVC persistence

**Story:** Data lives on the PVC at `/data`, not the container — eviction and reschedule reattach the same volume.

### Commands

```bash
make demo-data
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt
kubectl delete pod -n demo demo-app-0
kubectl wait --for=condition=Ready pod/demo-app-0 -n demo --timeout=120s
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt
kubectl get pvc -n demo data-demo-app-0 -o wide
```

### k9s

| View | Keys |
|------|------|
| `:pods demo` | Delete `demo-app-0` (`Ctrl-k`), watch recreate |
| `:pvc demo` | `data-demo-app-0` stays Bound (same claim) |
| `:pods demo` → `s` | `cat /data/marker.txt` inside shell |

**Expected:** Marker content unchanged after pod delete; PVC `data-demo-app-0` still Bound to the new pod.

---

## Demo #4: PDB protection

**Story:** PDB gates *voluntary* disruption (evict, drain). Tune `minAvailable` for replica count and SLO.

### Relaxed (default — `minAvailable: 1`)

```bash
make pdb-relaxed
kubectl get pdb -n demo demo-app-pdb -o wide
kubectl get pdb -n demo demo-app-pdb -o yaml | grep -E 'minAvailable|disruptionsAllowed'
```

### Strict — `minAvailable: 2`

```bash
make pdb-strict
kubectl get pdb -n demo demo-app-pdb -o wide
kubectl get pdb -n demo demo-app-pdb -o yaml | grep -E 'minAvailable|disruptionsAllowed'
```

### k9s

| View | Keys |
|------|------|
| `:pdb demo` | Column **ALLOWED DISRUPTIONS**: `1` (relaxed) or `0` (strict) |
| `:pods demo` | `d` on PDB — selector `app: demo-app` |

| PDB mode | minAvailable | ALLOWED DISRUPTIONS (2 replicas) |
|----------|--------------|----------------------------------|
| Relaxed | 1 | 1 |
| Strict | 2 | 0 |

**Expected:** Relaxed allows one pod to be evicted; strict allows zero voluntary disruptions.

---

## Demo #5: Eviction API

**Story:** `kubectl drain` and `kubectl evict` use the Eviction API — PDB decides allow or block.

### Relaxed — eviction succeeds

```bash
make pdb-relaxed
make evict
make status
make demo-data
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt
```

Sample manifest (`make evict` / `scripts/evict-pod.sh` sends this):

```yaml
apiVersion: policy/v1
kind: Eviction
metadata:
  name: demo-app-0
  namespace: demo
spec:
  deleteOptions:
    gracePeriodSeconds: 30
```

Manual eviction:

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

### Strict — eviction blocked

```bash
make pdb-strict
make evict
```

### k9s

| View | Keys |
|------|------|
| `:pdb demo` | ALLOWED DISRUPTIONS `1` → evict OK; `0` → blocked |
| `:pods demo` | Watch pod terminate and recreate (relaxed) |
| `:events demo` | PDB violation message on strict failure |

**Expected (relaxed):** Eviction succeeds; StatefulSet recreates pod; PVC rebinds; marker survives.  
**Expected (strict):** Error like `Cannot evict pod as it would violate the pod's disruption budget`.

---

## Demo #6: Cordon, drain, migrate

**Story:** Node maintenance uses drain → eviction per pod. Strict PDB blocks the whole drain; relaxed allows one pod to move while the other stays up.

### Strict PDB — drain blocked

```bash
make pdb-strict
make drain
kubectl get nodes
kubectl get events -n demo --sort-by='.lastTimestamp' | tail -15
make status
```

Manual cordon + drain (replace node name from `kubectl get pods -n demo -o wide`):

```bash
kubectl cordon pdb-pvc-demo-worker
kubectl drain pdb-pvc-demo-worker --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=120s
```

### Restore and retry with relaxed PDB

```bash
make pdb-relaxed
make uncordon
make status
make drain
make status
```

### k9s

| View | Keys |
|------|------|
| `:nodes` | Cordoned node shows `SchedulingDisabled` |
| `:pods demo` | One pod evicted/rescheduled; one remains on other worker |
| `:pdb demo` | Strict: ALLOWED DISRUPTIONS `0` during failed drain |
| `:events demo` | PodDisruptionBudget events |

**Expected (strict):** Worker cordoned; drain fails or times out; demo pod on the other worker keeps running; events mention PodDisruptionBudget.  
**Expected (relaxed):** One pod evicts from cordoned worker and reschedules on the other; drain may complete for demo pods.

---

## Teardown

```bash
make teardown       # remove demo resources; kind cluster stays
make clean          # teardown + delete kind cluster
make cluster-delete # delete kind cluster only
```
