# Demo script: PDB, PVC, Eviction & GitOps

**Audience:** Platform / SRE engineers  
**Duration:** ~45–60 minutes  
**Cluster:** kind (`kind-pdb-pvc-demo` context, 1 control-plane + 2 workers)

## Before you start

**Prerequisites:** Docker Desktop running, `kind`, and `kubectl` — see [README prerequisites](../README.md#prerequisites) for Homebrew install and verify commands.

Create the kind cluster, then bootstrap the demo:

```bash
cd k8s-pdb-pvc-eviction-demo
make setup
make status
```

Or step by step:

```bash
make cluster
make check-cluster
make argocd
make argocd-app    # registers demo-app + waits for Synced/Healthy
make demo-data
make status
```

`make setup` registers the `demo-app` Application in Argo CD and waits for GitOps sync — no separate `make argocd-app` step needed.

After bootstrap, open the Argo CD dashboard (see below). The `demo-app` Application should already show **Synced / Healthy**.

### Argo CD dashboard (local)

**No login required** — `make argocd` configures anonymous admin access and HTTP mode for the demo.

> **Security:** Anonymous admin is **local demo only** — never use this configuration in production.

Keep port-forward running in a **second terminal**:

```bash
# second terminal — leave running
make port-forward
```

Open **http://localhost:8080** — the dashboard loads immediately (no credentials, no certificate warnings).

**CLI only (optional):** `brew install argocd`, then `argocd login localhost:8080 --username admin --password <pwd> --plaintext` (password from `make argocd-password`). The web UI does not need this.

### GitOps repo

Default repo URL: `https://github.com/freemanpdwork/k8s-pdb-pvc-eviction-demo.git` (path: `manifests/k8s-demo/overlays/relaxed`).

`make setup` syncs from that repo automatically. For your own fork, push manifests first, then:

```bash
export DEMO_REPO_URL=https://github.com/YOUR_USER/k8s-pdb-pvc-eviction-demo.git
make setup
```

**Offline / no git push:** use `make deploy-direct` instead of relying on Argo sync (after `make cluster && make argocd`).

Re-sync or re-register manually:

```bash
make argocd-app
```

### Multi-node kind cluster

`make cluster` creates **1 control-plane + 2 workers** (`kind/cluster.yaml`). That gives you:

- **Pod spread** — StatefulSet pod anti-affinity prefers different workers; `make status` should show `demo-app-0` and `demo-app-1` on separate nodes.
- **Drain demo (Act 7)** — cordon and drain a worker that runs one demo pod; strict PDB blocks eviction; relaxed PDB allows one pod to move while the other stays on the second worker.

Contrast with production: anti-affinity is *preferred*, not guaranteed — mention that on single-node clusters both pods may co-locate.

---

## Act 1 — Cluster & Argo CD (5 min)

**Talking points:** kind gives a realistic multi-node topology on a laptop. Argo CD watches git and reconciles cluster state.

```bash
make setup          # or: make cluster && make argocd && make argocd-app
make check-cluster
kubectl get nodes -o wide
# second terminal (leave running):
make port-forward
```

**Expected:** 3 nodes (1 control-plane + 2 workers), all `Ready`. Argo CD pods Running in `argocd` namespace. Context `kind-pdb-pvc-demo`. UI at http://localhost:8080 — open in browser, no login. Application `demo-app` already **Synced / Healthy** in the dashboard.

**k9s:** `:nodes`, then `:applications argocd` — `demo-app` is listed

---

## Act 2 — k9s tour (5 min)

**Talking points:** StatefulSet gives stable network identity and per-pod PVCs. Anti-affinity spreads pods across workers when multiple nodes exist.

```bash
make status
# or k9s: :pods demo
```

**Expected:**

| Pod | PVC | Node |
|-----|-----|------|
| demo-app-0 | demo-app-data-demo-app-0 (Bound, 1Gi RWO) | worker A |
| demo-app-1 | demo-app-data-demo-app-1 (Bound, 1Gi RWO) | worker B |

Highlight labels: `app: demo-app`, headless Service `demo-app`.

Call out **pod spread across workers** — this is why we use kind instead of a single-node desktop cluster.

---

## Act 3 — PVC persistence (8 min)

**Talking points:** Data lives on the PVC at `/data`, not the container filesystem. Eviction/reschedule reattaches the same PVC.

```bash
make demo-data
```

**Expected output:** Each pod has `/data/marker.txt` with unique content.

Verify inside a pod:

```bash
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt
```

Delete the pod (simulates eviction reschedule):

```bash
kubectl delete pod -n demo demo-app-0
kubectl wait --for=condition=Ready pod/demo-app-0 -n demo --timeout=120s
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt
```

**Expected:** Marker content unchanged — same PVC, same data.

---

## Act 4 — Relaxed PDB allows eviction (8 min)

**Talking points:** PDB protects *voluntary* disruptions (drain, `kubectl evict`). With 2 replicas and `minAvailable: 1`, one pod may go away.

```bash
kubectl get pdb -n demo demo-app-pdb -o yaml
make evict
make status
make demo-data    # confirm markers on recreated pod
```

**Expected:** Eviction succeeds. StatefulSet recreates pod. PVC rebinds. PDB shows `ALLOWED DISRUPTIONS: 1`.

Sample eviction manifest (what `kubectl evict` sends):

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

---

## Act 5 — GitOps rollout (8 min)

**Talking points:** Desired state lives in git. Argo CD syncs automatically (prune + selfHeal).

**Option A — GitOps (requires push to remote):**

1. Edit something visible, e.g. bump nginx image tag in `manifests/k8s-demo/statefulset.yaml`
2. Commit and push to branch tracked by Argo CD
3. Watch sync:

```bash
kubectl get application demo-app -n argocd -w
# or argocd app sync demo-app
make status
```

In the Argo CD UI (already open at http://localhost:8080), watch the Application sync — no login step.

**Option B — Local only (no git push):**

```bash
make deploy-direct
```

**Expected:** Rolling update or reconcile; Argo CD shows Synced/Healthy (Application registered during `make setup`).

---

## Act 6 — Strict PDB blocks eviction (10 min)

**Talking points:** `minAvailable: 2` with 2 replicas means **zero** voluntary disruptions allowed. Eviction API returns 429.

**Option A — GitOps:** Change Argo CD Application path to `manifests/k8s-demo/overlays/strict`, commit `pdb-strict.yaml`, push.

**Option B — Local:**

```bash
make pdb-strict
kubectl get pdb -n demo demo-app-pdb
```

**Expected PDB:** `minAvailable: 2`, `ALLOWED DISRUPTIONS: 0`

Try eviction:

```bash
make evict
```

**Expected:** Error like `Cannot evict pod as it would violate the pod's disruption budget`.

---

## Act 7 — Drain blocked by strict PDB (10 min)

**Talking points:** `kubectl drain` uses the eviction API for each pod. PDB blocks the whole drain when no disruptions are allowed.

With **2 workers**, drain the worker running a demo pod — the other worker still has a pod, but strict PDB prevents evicting either one, so drain fails as expected.

```bash
make drain
```

**Expected:**

- One worker cordoned (`SchedulingDisabled`)
- Drain hangs or fails on demo-app pods on that worker
- Events mention PodDisruptionBudget
- Pod on the other worker keeps running

Inspect:

```bash
kubectl get events -n demo --sort-by='.lastTimestamp' | tail -15
kubectl get nodes
make status
```

Fix for next act:

```bash
make pdb-relaxed
make uncordon
make status
```

Retry drain with relaxed PDB — one pod on the cordoned worker should evict and reschedule on the other worker; one pod remains on the second worker.

---

## Act 8 — Drift & self-heal (5 min)

**Talking points:** Manual kubectl edits are drift. Argo CD `selfHeal: true` restores git state.

(`demo-app` is already registered and synced from `make setup`.)

```bash
kubectl label pod -n demo demo-app-0 drift=demo --overwrite
# Within ~3 min selfHeal removes the label (automated sync).
# Or: argocd app sync demo-app --force
```

With Argo CD UI (http://localhost:8080): show OutOfSync → Sync → label removed. No login required.

---

## Wrap-up & teardown (3 min)

**Key takeaways:**

1. **PVCs** survive pod eviction — plan storage for stateful workloads
2. **PDBs** gate voluntary disruption — tune for replica count and SLO
3. **Drain** respects PDBs — strict policies block node maintenance
4. **GitOps** makes policy changes auditable and reversible
5. **Multi-node spread** makes drain/eviction stories realistic

```bash
make teardown       # remove demo resources; kind cluster stays up
make clean          # teardown + delete kind cluster
make cluster-delete # delete kind cluster only
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Kubeconfig not found` | `make cluster` |
| `cluster unreachable` | `docker ps`; `make cluster-delete && make cluster` |
| Wrong kubectl context | `export KUBECONFIG=$(pwd)/.kube/kind-pdb-pvc-demo` or `make fix-context` |
| Argo CD UI blank / connection refused | Run `make port-forward` in a second terminal; open http://localhost:8080 (not https) |
| Argo CD login prompt | Re-run `make argocd` to apply `insecure-anonymous.yaml`; UI should need no credentials |
| PVC Pending | `kubectl get sc` — kind default is `standard` (local-path) |
| Pods on same node | Delete pods once: `kubectl delete pod -n demo -l app=demo-app`; or check worker count with `kubectl get nodes` |
| Fewer than 2 workers | Recreate: `make clean && make cluster` |
| Argo OutOfSync | Push manifests to `DEMO_REPO_URL` (see `make argocd-app` output); override with `DEMO_REPO_URL` for your fork; or `make deploy-direct` offline |
| Argo sync timeout on setup | Ensure repo is reachable and `manifests/k8s-demo/overlays/relaxed` exists at `DEMO_REPO_URL`; fallback: `make deploy-direct` |
| Drain stuck | `make uncordon`; check PDB with `kubectl get pdb -n demo` |
| Evict works under strict PDB | Confirm `make pdb-strict` applied; check `ALLOWED DISRUPTIONS` |

## Timing cheat sheet

| Act | Topic | ~min |
|-----|-------|------|
| 1 | Cluster + Argo CD | 5 |
| 2 | k9s tour | 5 |
| 3 | PVC persistence | 8 |
| 4 | Relaxed eviction | 8 |
| 5 | GitOps rollout | 8 |
| 6 | Strict PDB / evict blocked | 10 |
| 7 | Drain blocked | 10 |
| 8 | Self-heal | 5 |
