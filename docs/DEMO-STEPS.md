# Demo steps — command cheat sheet

Condensed speaker reference for live demos. Full narrative and timing: **[DEMO.md](DEMO.md)**. Troubleshooting: **[README.md#troubleshooting](../README.md#troubleshooting)**.

## Choose your track

| Track | ~time | Sections | Key commands |
|-------|-------|----------|--------------|
| **10 min** | 10m | [Quick demo — 3 concepts](#quick-demo--3-concepts-10-minutes) | `make setup` · `make demo-url` · `make act-pvc` · `make act-pdb` |
| **30 min** | 30m | [Prep](#prep-before-the-room) · [1 GitOps](#1-gitops-deployment) · [3 PVC](#3-pvc-persistence) · [4 PDB](#4-pdb-protection) · [5 Eviction](#5-eviction-api) | `make preflight` · `make act-pvc` · `make act-pdb` |
| **60 min** | 60m | [Suggested live order](#suggested-live-order) (sections 0–6) | `make act-drain` · `make uncordon` · `make argocd-resume-sync` · full cheat sheet below |

Run `make preflight` before the room — validates overlays, checks the cluster, probes GitHub reachability, and prints Argo CD (`:30080`) and demo app (`:30090`) URLs.

| Resource | Name |
|----------|------|
| Cluster / context | `pdb-pvc-demo` / `kind-pdb-pvc-demo` |
| Namespace | `demo` |
| StatefulSet | `demo-app` |
| Pods | `demo-app-0`, `demo-app-1` |
| PVCs | `data-demo-app-0`, `data-demo-app-1` (1Gi RWO, `/data`) |
| PDB | `demo-app-pdb` |
| Workers | `pdb-pvc-demo-worker`, `pdb-pvc-demo-worker2`, `pdb-pvc-demo-worker3` |
| GitOps path | `manifests/k8s-demo` (relaxed) · `manifests/k8s-demo/overlays/strict` (strict) |

---

## Prep (before the room)

```bash
cd k8s-pdb-pvc-eviction-demo
make setup          # cluster + Argo CD + demo-app synced + demo data
make check-cluster  # context kind-pdb-pvc-demo, 4 nodes Ready
make status         # pods spread, PVCs Bound, PDB present
make preflight      # validate overlays + cluster + GitHub + print URLs
# Optional before maintenance/drift acts:
make argocd-pause-sync   # pause automated sync; manual argocd sync still works
# Argo CD UI (preferred — no tunnel):
open http://localhost:30080
# Demo app HTTP (PVC data in browser — no tunnel):
make demo-url       # → http://localhost:30090/
```

| Step | Command | Notes |
|------|---------|-------|
| Bootstrap | `make setup` | Registers `demo-app` Application; waits Synced/Healthy |
| Verify | `make check-cluster` | 1 control-plane + 3 workers Ready |
| Pause sync | `make argocd-pause-sync` | Set Application sync policy to manual for maintenance/drift demos |
| Snapshot | `make status` | `demo-app-0` / `demo-app-1` on separate workers |
| Preflight | `make preflight` | Overlays, cluster, GitHub reachability, URLs |
| Argo CD UI | http://localhost:30080 | After `make argocd` / `make setup` — no login; `make argocd-expose` to re-apply |
| Demo app HTTP | `make demo-url` | http://localhost:30090/ — `make demo-expose` to re-apply NodePort |
| Argo CD fallback | `make port-forward` | Second terminal — tunnel; can reset on kind/Mac |
| Optional | `k9s` | `:nodes`, `:applications argocd`, `:pods demo` |

**Expected:** Application `demo-app` **Synced / Healthy**; two pods **Running** on separate workers (e.g. `pdb-pvc-demo-worker` and `pdb-pvc-demo-worker2`); PVCs `data-demo-app-0` and `data-demo-app-1` **Bound**.

---

## Quick demo — 3 concepts, ~10 minutes

Fastest path through the demo. Run `make setup` first (or see raw setup commands below).

Each step shows the **make shortcut** and the **raw kubectl** equivalent.

---

### 1. PVC persistence — data survives pod deletion

**make shortcut**
```bash
make act-pvc   # guided before/after: pod UID changes, same PVC marker survives
# or step by step:
make status    # show pods + PVCs + node placement
make evict     # evict one pod via Eviction API (relaxed PDB allows it)
make status    # pod recreated, same PVC marker data
```

**raw kubectl**
```bash
# Show cluster state
kubectl get nodes -o wide
kubectl get pods,pvc,pdb -n demo -o wide

# Evict a pod via the Eviction API (Eviction is a pod subresource — use proxy + curl)
kubectl proxy --port=38001 &
curl -s -w "\nHTTP %{http_code}\n" -X POST \
  http://localhost:38001/api/v1/namespaces/demo/pods/demo-app-0/eviction \
  -H 'Content-Type: application/json' \
  -d '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"demo-app-0","namespace":"demo"}}'
kill %1   # stop the proxy
# → HTTP 201 Created (eviction allowed)

# Watch recreation and PVC data
kubectl get pods,pvc -n demo -o wide
```

**Point:** the pod restarted and the data at `/data` is intact. With kind's `local-path-provisioner`, the PV has required node affinity for the original node, so the pod is constrained back to the same worker — the PVC doesn't "follow" to a new node, it pulls the pod home.

---

### 2. PDB blocks eviction — switch to strict PDB

**make shortcut**
```bash
make act-pdb      # guided strict PDB act: HTTP 429, pod UID unchanged
# or step by step:
make argocd-strict # Argo CD syncs strict PDB desired state
make evict        # Eviction API returns HTTP 429 — blocked
make act-drain    # pause auto-sync, then cordon/drain blocked by PDB
make argocd-relaxed # restore relaxed PDB desired state
make uncordon     # uncordon the node drained above
make argocd-resume-sync
```

**raw Argo CD + kubectl**
```bash
# Switch desired state to strict PDB through Argo CD
argocd --core app set demo-app -N argocd --path manifests/k8s-demo/overlays/strict
argocd --core app sync demo-app -N argocd --prune
argocd --core app wait demo-app -N argocd --sync --health
kubectl get pdb -n demo

# Try to evict — HTTP 429: blocked by PDB
kubectl proxy --port=38001 &
curl -s -w "\nHTTP %{http_code}\n" -X POST \
  http://localhost:38001/api/v1/namespaces/demo/pods/demo-app-0/eviction \
  -H 'Content-Type: application/json' \
  -d '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"demo-app-0","namespace":"demo"}}'
kill %1
# → HTTP 429 Too Many Requests (PDB blocked it)

# Try to drain — also blocked by PDB
NODE=$(kubectl get pods -n demo demo-app-0 -o jsonpath='{.spec.nodeName}')
kubectl cordon "$NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=60s

# Restore: switch back to relaxed PDB and uncordon
argocd --core app set demo-app -N argocd --path manifests/k8s-demo
argocd --core app sync demo-app -N argocd --prune
kubectl uncordon "$NODE"
```

**Point:** PDB is enforced by the Eviction API, not just advisory — drain and evict both get a hard 429.

---

### 3. Argo CD GitOps — push a change, watch it sync

**make shortcut**
```bash
# Edit manifests/k8s-demo/statefulset.yaml, then:
git commit -am "demo: change replicas" && git push
make status   # shows updated pod count after Argo CD syncs
```

**raw kubectl**
```bash
# Edit the manifest (e.g. change replicas: 2 → 1)
vi manifests/k8s-demo/statefulset.yaml

# Push to git — Argo CD watches this repo
git add manifests/k8s-demo/statefulset.yaml
git commit -m "demo: scale replicas"
git push

# Watch Argo CD detect drift and reconcile (~30-60 s)
kubectl get application demo-app -n argocd -w
kubectl get pods -n demo -w

# Open http://localhost:30080 → demo-app → watch the sync animation
```

**Point:** Argo CD continuously reconciles; a manual `kubectl scale` would be reverted within ~3 minutes.

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
| `make setup-offline` | Bootstrap without GitOps (cluster + Argo CD + deploy-direct + demo data) |
| `make preflight` | Validate overlays + check cluster + GitHub + print URLs |
| `make status` | Nodes, pods, PVCs, PDB, Argo Application |
| `make argocd-expose` | Argo CD UI at http://localhost:30080 (preferred on kind/Mac) |
| `make demo-expose` | Demo app HTTP at http://localhost:30090 (preferred on kind/Mac) |
| `make demo-url` | Print demo app URL and apply NodePort if needed |
| `make argocd-pause-sync` | Pause automated sync (manual mode) |
| `make argocd-resume-sync` | Resume automated sync with prune + selfHeal |
| `make argocd-relaxed` | Argo CD desired state: relaxed PDB |
| `make argocd-strict` | Argo CD desired state: strict PDB |
| `make argocd-resume-sync` | Restore automated sync from `manifests/argocd/application.yaml` |
| `make port-forward` | Argo CD UI tunnel fallback (`ARGOCD_LOCAL_PORT`, default 8888) |
| `make argocd-proxy` | kubectl proxy fallback for Argo CD UI |
| `make demo-data` | Write `/data/marker.txt` on each pod's PVC |
| `make evict` | Evict one Running pod via Eviction API |
| `make pdb-relaxed` | Alias for `make argocd-relaxed` |
| `make pdb-strict` | Alias for `make argocd-strict` |
| `make drain` | Cordon + drain a worker running demo pods |
| `make act-drain` | Pause auto-sync, sync strict desired state, then cordon/drain |
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

**Expected:** 4 nodes Ready (1 control-plane + 3 workers); Argo CD Application `demo-app` Synced/Healthy; two pods Running on separate workers; PVCs Bound.

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

> **Voluntary vs forced delete:** `kubectl delete pod` bypasses the Eviction API — the API server deletes the pod directly. PDB does **not** block `kubectl delete`. Use `make evict` or `kubectl drain` to demonstrate PDB enforcement; reserve `kubectl delete pod` for drift/StatefulSet demos (section 2) or PVC persistence only.

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

### Argo CD — relaxed (default)

```bash
make argocd-relaxed
kubectl get pdb -n demo demo-app-pdb -o wide
kubectl get pdb -n demo demo-app-pdb -o jsonpath='minAvailable={.spec.minAvailable} allowed={.status.disruptionsAllowed}{"\n"}'
```

### Argo CD — strict

```bash
make argocd-strict
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

### PDB YAML breakdown

Show the YAML when you switch modes:

```bash
make pdb-explain
# or inspect the files directly:
sed -n '1,80p' manifests/k8s-demo/pdb-relaxed.yaml
sed -n '1,80p' manifests/k8s-demo/pdb-strict.yaml
kubectl describe pdb -n demo demo-app-pdb
```

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: demo-app-pdb
  namespace: demo
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: demo-app
```

| Field | What to say |
|-------|-------------|
| `apiVersion: policy/v1` | PDB is a policy API object; it is enforced by the Eviction API path used by drain/autoscaler-style maintenance. |
| `metadata.name` | There is one PDB named `demo-app-pdb`; Argo CD swaps relaxed vs strict by changing the Application path. |
| `spec.selector.matchLabels.app: demo-app` | The PDB only counts pods with this label. If labels drift or the selector is wrong, the budget may protect zero pods or the wrong pods. |
| `spec.minAvailable: 1` | With 2 ready replicas, Kubernetes can allow 1 voluntary disruption. |
| `spec.minAvailable: 2` | With 2 ready replicas, Kubernetes must keep both available, so `ALLOWED DISRUPTIONS=0`. |

Useful status fields from `kubectl describe pdb`:

| Status field | Why it matters |
|--------------|----------------|
| `Allowed disruptions` | The number the Eviction API uses for allow/block. `0` means HTTP 429 for demo pods. |
| `Current Healthy` | Ready pods currently matching the selector. |
| `Desired Healthy` | Minimum healthy pods required by the budget. |
| `Expected Pods` | Pods selected by the PDB; should be `2` in the normal demo. |

### PDB problems to call out

| Problem | Symptom | Explanation / fix |
|---------|---------|-------------------|
| Strict PDB conflicts with replica count | `ALLOWED DISRUPTIONS=0`; drain/evict returns 429 | This is intentional in the strict act with 2 replicas and `minAvailable: 2`. If you accidentally run strict with fewer replicas, maintenance is also blocked. Restore with `make argocd-relaxed` or increase replicas. |
| Selector does not match pods | `Expected Pods` is `0` or not `2` | PDB math only sees selected pods. Check `kubectl get pods -n demo --show-labels` and the PDB selector. |
| Argo CD is Synced/Healthy but drain fails | Argo CD looks green; `kubectl drain` fails | This is not an Argo CD failure. Argo CD successfully applied desired state; the desired state says voluntary disruptions are not allowed. |
| Argo CD path is not what you think | PDB mode does not match the story | Run `argocd --core app get demo-app -N argocd` and check the source path. Use `make argocd-relaxed` or `make argocd-strict`. |
| Direct `kubectl delete pod` appears to ignore PDB | Pod disappears despite strict PDB | PDBs gate the Eviction API, not forced pod deletion. Use `make evict` or `make drain` to demonstrate enforcement. |

---

## 5. Eviction API

**Talking point:** `kubectl drain` and `make evict` use the policy/v1 **Eviction** API. The PDB controller decides allow (HTTP 201) or block (HTTP 429).

> **Voluntary vs forced delete:** `kubectl delete pod` is **not** gated by PDB — it removes the pod immediately without consulting the Eviction API. `make evict`, `kubectl drain`, and cluster autoscaler scale-down all use the Eviction API and respect PDB. Do not use `kubectl delete` when demonstrating PDB blocks.

### Argo CD desired state + Eviction API — relaxed succeeds

```bash
make argocd-relaxed
make evict
make status
make demo-data
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt
```

Manual eviction (same as `make evict` / `scripts/evict-pod.sh`):

```bash
# Eviction is a pod subresource — use kubectl proxy + curl
kubectl proxy --port=38001 &
curl -s -w "\nHTTP %{http_code}\n" -X POST \
  http://localhost:38001/api/v1/namespaces/demo/pods/demo-app-0/eviction \
  -H 'Content-Type: application/json' \
  -d '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"demo-app-0","namespace":"demo"}}'
kill %1
# Relaxed PDB → HTTP 201 Created (allowed)
# Strict PDB  → HTTP 429 Too Many Requests (blocked)
```

### Argo CD desired state + Eviction API — strict blocks

```bash
make argocd-strict
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

**Talking point:** Node maintenance cordons the node, then drains pods via the Eviction API. Strict PDB blocks the whole drain; relaxed PDB permits one eviction, but kind's node-local PV affinity may keep the replacement pod Pending until the storage node is uncordoned.

### Argo CD desired state + kubectl drain — strict blocks

```bash
make act-drain
kubectl get nodes
kubectl get events -n demo --sort-by='.lastTimestamp' | tail -15
make status
```

Manual cordon + drain (pick the worker running `demo-app-0`):

```bash
NODE=$(kubectl get pods -n demo demo-app-0 -o jsonpath='{.spec.nodeName}')
kubectl cordon "$NODE"
kubectl drain "$NODE" \
  --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=120s
```

### Argo CD relaxed desired state + drain contrast

```bash
make argocd-relaxed
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

**Expected (strict):** Worker cordoned (`SchedulingDisabled`); drain fails or times out; demo pods on the remaining workers keep running; events mention PodDisruptionBudget.

**Expected (relaxed):** PDB allows the eviction (HTTP 201), so the pod is terminated from the cordoned worker. However, `local-path-provisioner` PVs have required node affinity — `demo-app-0` will be stuck **Pending** until the node is uncordoned, because its PVC can only bind on the original worker. `demo-app-1` on the other worker stays Running. Run `make uncordon` to restore. This is the real-world reason production stateful workloads use distributed storage (Ceph, EFS, etc.) instead of node-local PVs.

---

## Teardown

```bash
make uncordon        # if nodes were cordoned during drain demo
make teardown        # remove demo resources; kind cluster stays
make clean           # teardown + delete kind cluster
make cluster-delete  # delete kind cluster only
```

---

## Troubleshooting

See **[README.md#troubleshooting](../README.md#troubleshooting)** for full diagnostics (context, cluster, Argo CD UI, GitOps sync, drain/PDB).

Quick checks:

- **Argo CD UI unreachable** — `make argocd-expose` → http://localhost:30080
- **Demo app HTTP unreachable** — `make demo-expose` → http://localhost:30090
- **Cluster predates NodePort mappings** — `make cluster-delete && make cluster`
- **GitHub unreachable** — `make setup-offline` instead of `make setup`
