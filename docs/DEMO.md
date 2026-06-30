# Demo script: PDB, PVC, Eviction & GitOps

**Command cheat sheet:** [DEMO-STEPS.md](DEMO-STEPS.md) — copy-paste kubectl commands, k9s views, and Makefile shortcuts for live demos.

**Drain workflow deep-dive:** [DEMO-DRAIN-WORKFLOW.md](DEMO-DRAIN-WORKFLOW.md) — cordon → Eviction API → PDB → EndpointSlice → StatefulSet replacement, with Argo CD pause/resume.

**Audience:** Platform / SRE engineers  
**Duration:** ~45–60 minutes (or ~10 minutes with the quick demo below)  
**Cluster:** kind (`kind-pdb-pvc-demo` context, 1 control-plane + 3 workers)

---

## Quick demo — 3 concepts, ~10 minutes

For a focused audience or tight timeslot. For the full 45-minute version with k9s walkthroughs and drift detection, see [Acts 1–8](#act-1--cluster--argo-cd-5-min) below.

Each step shows the **make shortcut** and the **raw kubectl** equivalent.

### Setup (before the room, ~2 min)

**make shortcut**
```bash
make setup           # cluster + Argo CD + GitOps sync + demo data
make demo-url        # → http://localhost:30090/  (nginx serves PVC data; no tunnel)
```

**raw kubectl**
```bash
# Expose demo-app-http on NodePort 30090 (kind maps host port via kind/cluster.yaml)
kubectl apply -f manifests/k8s-demo/demo-nodeport.yaml
```

Open **http://localhost:30090/** in a browser. It shows pod identity, the mounted PVC, the marker timestamp, and the node where the marker page was written. This page is the visual anchor for the next two concepts.

---

### Concept 1 — PVC persistence: data survives eviction (~3 min)

**Talking point:** The PVC is not the pod. Data at `/data` lives on a persistent volume; the pod is just a consumer. Evict the pod, recreate it — the pod object changes, but the same claim and data come back.

**make shortcut**
```bash
make act-pvc         # guided before/after: pod UID changes, PVC marker survives
# or step by step:
make status          # pods on separate nodes, PVCs Bound, PDB relaxed
make demo-data       # write marker.txt + index.html to each pod's /data
```

**raw kubectl**
```bash
kubectl get nodes -o wide
kubectl get pods,pvc,pdb -n demo -o wide

# Write marker data to each pod's PVC
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt   # verify data exists
```

Refresh **http://localhost:30090/** — note the pod name, node, and write timestamp.

**make shortcut**
```bash
make evict           # Eviction API → HTTP 201 Created (relaxed PDB allows it)
```

**raw kubectl**
```bash
# Eviction is a pod subresource — use kubectl proxy + curl
kubectl proxy --port=38001 &
until curl -sf http://localhost:38001/healthz >/dev/null; do sleep 0.2; done
curl -s -w "\nHTTP %{http_code}\n" -X POST \
  http://localhost:38001/api/v1/namespaces/demo/pods/demo-app-0/eviction \
  -H 'Content-Type: application/json' \
  -d '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"demo-app-0","namespace":"demo"}}'
kill %1
# → HTTP 201 Created (eviction allowed)

# Verify pod recreated and PVC data survived
kubectl get pods,pvc -n demo -o wide
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt
```

Refresh **http://localhost:30090/** — the marker timestamp stays the same after the pod object is recreated. With kind's `local-path-provisioner`, the PV has node affinity, so the replacement pod is often scheduled back to the storage node instead of the disk moving freely.

**Key point:** the workload identity and claim are stable even though the pod object is disposable.

---

### Concept 2 — PDB enforcement: eviction returns HTTP 429 (~4 min)

**Talking point:** PodDisruptionBudget is not advisory — it gates the Eviction API directly. When no disruptions are allowed, the API returns HTTP 429. `kubectl drain` uses the same API, so drain is also blocked.

**make shortcut**
```bash
make act-pdb         # guided strict PDB act: HTTP 429, pod UID unchanged
# or step by step:
make argocd-strict   # Argo CD syncs strict desired state
make evict           # Eviction API → HTTP 429 Too Many Requests — pod NOT deleted
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
until curl -sf http://localhost:38001/healthz >/dev/null; do sleep 0.2; done
curl -s -w "\nHTTP %{http_code}\n" -X POST \
  http://localhost:38001/api/v1/namespaces/demo/pods/demo-app-0/eviction \
  -H 'Content-Type: application/json' \
  -d '{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"demo-app-0","namespace":"demo"}}'
kill %1
# → HTTP 429 Too Many Requests (PDB blocked it)
```

Show the 429 output from the terminal. Refresh **http://localhost:30090/** — still showing the original pod (unchanged).

**make shortcut**
```bash
make act-drain       # pause auto-sync, ensure strict desired state, cordon + drain
make status          # node cordoned (SchedulingDisabled), pods untouched
```

**raw kubectl**
```bash
# Try to drain — also blocked by PDB
NODE=$(kubectl get pods -n demo demo-app-0 -o jsonpath='{.spec.nodeName}')
kubectl cordon "$NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --grace-period=30 --timeout=60s
kubectl get nodes   # NODE shows SchedulingDisabled; pods untouched
```

Restore:

**make shortcut**
```bash
make argocd-relaxed  # restore relaxed desired state through Argo CD
make uncordon        # restore cordoned node
make argocd-resume-sync
```

**raw Argo CD + kubectl**
```bash
argocd --core app set demo-app -N argocd --path manifests/k8s-demo
argocd --core app sync demo-app -N argocd --prune
kubectl uncordon "$NODE"
kubectl get pdb -n demo   # ALLOWED DISRUPTIONS: 1
```

**Key point:** PDB enforcement is at the API layer, not the scheduler — there's no way to "accidentally" evict past a budget.

---

### Concept 3 — Argo CD GitOps: push a change, watch it sync (~3 min)

**Talking point:** Desired state lives in git. Argo CD continuously reconciles — manual `kubectl` changes are drift and get reverted.

**make shortcut**
```bash
# Edit manifests/k8s-demo/statefulset.yaml (e.g. add a label or env var)
git commit -am "demo: change something visible" && git push
make status          # cluster now matches git
```

**raw kubectl**
```bash
# Edit the manifest
vi manifests/k8s-demo/statefulset.yaml

# Push to git — Argo CD watches this repo
git add manifests/k8s-demo/statefulset.yaml
git commit -m "demo: change something visible"
git push

# Watch Argo CD detect drift and reconcile (~30-60 s)
kubectl get application demo-app -n argocd -w
kubectl get pods -n demo -w

# Verify cluster matches git
kubectl get pods,pvc -n demo -o wide
```

Open **http://localhost:30080** (Argo CD UI, no login) — watch the Application go OutOfSync → Syncing → Synced.

Bonus: make a manual kubectl change — Argo CD reverts it within ~3 minutes (selfHeal):

```bash
kubectl label pod -n demo demo-app-0 drift=manual --overwrite
kubectl get pod -n demo demo-app-0 --show-labels   # label present
# wait ~3 minutes or force sync from the Argo CD UI
kubectl get pod -n demo demo-app-0 --show-labels   # label gone
```

**Key point:** GitOps means the cluster is always a function of git. Drift is detected and healed automatically.

---

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

**Preferred (NodePort, no tunnel):** Open **http://localhost:30080** — available immediately after `make setup` or `make argocd-expose`.

**Fallback (port-forward):** if the NodePort isn't reachable, run in a second terminal:

```bash
make port-forward   # → http://localhost:8888
```

**CLI only (optional):** `brew install argocd`, then `argocd login localhost:30080 --username admin --password <pwd> --plaintext` (password from `make argocd-password`). The web UI does not need this.

### GitOps repo

Default repo URL: `https://github.com/freemanpdwork/k8s-pdb-pvc-eviction-demo.git` (path: `manifests/k8s-demo` — relaxed PDB at repo root; `overlays/strict` works after `make argocd` sets global kustomize load-restrictor options).

`make setup` syncs from that repo automatically. For your own fork, push manifests first, then:

```bash
export DEMO_REPO_URL=https://github.com/YOUR_USER/k8s-pdb-pvc-eviction-demo.git
make setup
```

**Offline / no git push:** use `make deploy-direct` instead of relying on Argo sync (after `make cluster && make argocd`).

Re-sync or re-register manually:

```bash
make argocd-app    # applies local manifests/argocd/application.yaml (not from git)
```

### Multi-node kind cluster

`make cluster` creates **1 control-plane + 3 workers** (`kind/cluster.yaml`). That gives you:

- **Pod spread** — StatefulSet pod anti-affinity prefers different workers; `make status` should show `demo-app-0` and `demo-app-1` on separate nodes.
- **Drain demo (Act 7)** — cordon and drain a worker that runs one demo pod; strict PDB blocks eviction; relaxed PDB permits eviction, then kind's node-local PV affinity may keep the replacement pod Pending until the node is uncordoned.

Contrast with production: anti-affinity is *preferred*, not guaranteed — mention that on single-node clusters both pods may co-locate.

---

## Listing Kubernetes APIs (optional warm-up)

**Talking point:** Before eviction and drain acts, show how the API server advertises its surface area. Creatable kinds appear in `kubectl api-resources`; voluntary disruption uses a **pod subresource** that does not get its own row.

```bash
kubectl api-versions | sort
kubectl api-resources --api-group=policy          # PodDisruptionBudget (policy/v1)
kubectl api-resources --api-group=apps | grep statefulset
kubectl api-resources --api-group=discovery.k8s.io  # EndpointSlice
kubectl get --raw /apis
kubectl get --raw /apis/policy/v1/namespaces/demo/poddisruptionbudgets
```

**Eviction tie-in:** `make evict` and `kubectl drain` POST to `/api/v1/namespaces/demo/pods/{name}/eviction` with `apiVersion: policy/v1` and `kind: Eviction`. The PDB controller returns HTTP **201** (allowed) or **429** (blocked). `kubectl delete pod` skips this path entirely.

Full command list and table: [DEMO-STEPS.md — API discovery](DEMO-STEPS.md#api-discovery-optional-warm-up). Drain workflow APIs and observation stages: [DEMO-DRAIN-WORKFLOW.md](DEMO-DRAIN-WORKFLOW.md#api-discovery--see-the-objects-behind-the-flow).

---

## Act 1 — Cluster & Argo CD (5 min)

**Talking points:** kind gives a realistic multi-node topology on a laptop. Argo CD watches git and reconciles cluster state. Optional warm-up: run the [API discovery commands](DEMO-STEPS.md#api-discovery-optional-warm-up) from DEMO-STEPS to show `api-resources`, `api-versions`, and `kubectl get --raw /apis` before eviction acts.

```bash
make setup          # or: make cluster && make argocd && make argocd-app
make check-cluster
kubectl get nodes -o wide
make demo-url       # → http://localhost:30090/  (PVC data served by nginx; no tunnel)
```

**Expected:** 4 nodes (1 control-plane + 3 workers), all `Ready`. Argo CD pods Running in `argocd` namespace. Context `kind-pdb-pvc-demo`. Argo CD UI at http://localhost:30080 — open in browser, no login. Application `demo-app` already **Synced / Healthy** in the dashboard.

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
| demo-app-0 | data-demo-app-0 (Bound, 1Gi RWO) | worker A |
| demo-app-1 | data-demo-app-1 (Bound, 1Gi RWO) | worker B |

Highlight labels: `app: demo-app`, headless Service `demo-app`.

Call out **pod spread across workers** — this is why we use kind instead of a single-node desktop cluster.

---

## Act 3 — PVC persistence (8 min)

**Talking points:** Data lives on the PVC at `/data`, not the container filesystem. Eviction recreates the pod object while the same PVC and marker data remain.

```bash
make demo-data
```

**Expected output:** Each pod has `/data/marker.txt` with unique content.

Verify inside a pod:

```bash
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt
```

> **Voluntary vs forced delete:** `kubectl delete pod` bypasses the Eviction API — the API server deletes the pod directly. PDB does **not** block `kubectl delete`. Here we use delete only to show PVC persistence; use `make evict` or `kubectl drain` in Act 4+ to demonstrate PDB enforcement.

Delete the pod (simulates reschedule — **not** the Eviction API):

```bash
kubectl delete pod -n demo demo-app-0
kubectl wait --for=condition=Ready pod/demo-app-0 -n demo --timeout=120s
kubectl exec -n demo demo-app-0 -- cat /data/marker.txt
```

**Expected:** Marker content unchanged — same PVC, same data.

---

## Act 4 — Relaxed PDB allows eviction (8 min)

**Talking points:** PDB protects *voluntary* disruptions (drain, `kubectl evict`). With 2 replicas and `minAvailable: 1`, one pod may go away.

`make evict` posts to the policy/v1 **Eviction** subresource — PDB returns HTTP 201 (allowed) or 429 (blocked). `kubectl delete pod` skips that path entirely.

```bash
kubectl get pdb -n demo demo-app-pdb -o yaml
make evict
make status
make demo-data    # confirm markers on recreated pod
```

**Expected:** Eviction succeeds. StatefulSet recreates the pod with a new UID. The same PVC and marker data remain. PDB shows `ALLOWED DISRUPTIONS: 1`.

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

In the Argo CD UI (already open at http://localhost:30080), watch the Application sync — no login step.

**Option B — Local only (no git push):**

```bash
make deploy-direct
```

**Expected:** Rolling update or reconcile; Argo CD shows Synced/Healthy (Application registered during `make setup`).

---

## Act 6 — Strict PDB blocks eviction (10 min)

**Talking points:** `minAvailable: 2` with 2 replicas means **zero** voluntary disruptions allowed. Eviction API returns 429.

Set the Application path and sync through Argo CD:

```bash
make argocd-strict
kubectl get pdb -n demo demo-app-pdb
```

**Expected PDB:** `minAvailable: 2`, `ALLOWED DISRUPTIONS: 0`

Pause on the YAML before the eviction:

```bash
make pdb-explain
# or inspect the strict file directly:
sed -n '1,80p' manifests/k8s-demo/pdb-strict.yaml
kubectl describe pdb -n demo demo-app-pdb
```

What matters:

| YAML/status | Talking point |
|-------------|---------------|
| `selector.matchLabels.app: demo-app` | The PDB only protects pods matching this label. If the selector does not match the StatefulSet pods, the budget math is meaningless. |
| `minAvailable: 2` | With exactly 2 replicas, both must stay available. That leaves zero voluntary disruptions. |
| `Allowed disruptions: 0` | This is the live decision value behind the HTTP 429. |
| `Expected Pods: 2` | Confirms the PDB is counting the intended pods. |

Problem to call out: Argo CD can be **Synced / Healthy** while the cluster refuses a drain. That is not a contradiction. Argo CD successfully applied the desired policy; the policy says this workload currently has no voluntary disruption budget available.

Try eviction:

```bash
make evict
```

**Expected:** Error like `Cannot evict pod as it would violate the pod's disruption budget`.

---

## Act 7 — Drain blocked by strict PDB (10 min)

**Talking points:** `kubectl drain` uses the eviction API for each pod. PDB blocks the whole drain when no disruptions are allowed.

**Extended guide:** [DEMO-DRAIN-WORKFLOW.md](DEMO-DRAIN-WORKFLOW.md) — full flow diagram (cordon → Eviction API → PDB → EndpointSlice → StatefulSet replacement), observation commands at each stage, and Argo CD pause/resume (UI + CLI + `kubectl patch`).

With **3 workers**, pause automated sync, sync strict desired state manually, then drain the worker running a demo pod. With strict PDB (`ALLOWED DISRUPTIONS: 0`) the eviction is refused. With relaxed PDB the pod is evicted from the cordoned worker, but on kind's `local-path-provisioner` the PV has required node affinity — the pod stays **Pending** on another worker until you `make uncordon`, because the PVC does not migrate across nodes.

> **Workload note:** This repo uses a **StatefulSet** controller to recreate pods — not a Deployment/ReplicaSet. Eviction and PDB behavior are the same; only the owning controller differs.

```bash
make act-drain
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
make argocd-relaxed
make uncordon
make argocd-resume-sync
make status
```

Retry drain with relaxed PDB if you want to show the contrast — one pod on the cordoned worker is evicted, but `local-path` node affinity keeps it **Pending** until `make uncordon`; the other pod on a different worker stays Running.

---

## Act 8 — Drift & self-heal (5 min)

**Talking points:** Manual kubectl edits are drift. Argo CD `selfHeal: true` restores git state.

(`demo-app` is already registered and synced from `make setup`.)

```bash
kubectl label pod -n demo demo-app-0 drift=demo --overwrite
# Within ~3 min selfHeal removes the label (automated sync).
# Or: argocd app sync demo-app --force
```

With Argo CD UI (http://localhost:30080): show OutOfSync → Sync → label removed. No login required.

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

See **[README.md#troubleshooting](../README.md#troubleshooting)** for full diagnostics.

Quick checks during a live demo:

- Wrong context / unreachable cluster — `make fix-context` or `make cluster`
- Argo CD UI — `make argocd-expose` → http://localhost:30080
- Demo app HTTP — `make demo-expose` → http://localhost:30090
- GitHub unreachable — `make setup-offline` or `make deploy-direct`
- Argo sync timeout — push manifests to `DEMO_REPO_URL` or use `make deploy-direct`
- Drain stuck — `make uncordon`; check PDB with `kubectl get pdb -n demo`
- Evict works under strict PDB — confirm `make pdb-strict`; check `ALLOWED DISRUPTIONS`

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
