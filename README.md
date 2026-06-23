# k8s PDB + PVC + Eviction Demo

Hands-on demo of **PodDisruptionBudgets**, **PVC-backed StatefulSets**, voluntary **eviction**, node **drain**, and **Argo CD GitOps** on a local **kind** cluster (3 nodes: 1 control-plane + 2 workers).

## Prerequisites

**macOS (Homebrew).** Install the tools below, then **start Docker Desktop** — kind runs containers on Docker and `make cluster` will fail if the daemon is not running.

| Tool | Required | Install | Verify |
|------|----------|---------|--------|
| [Docker Desktop](https://docs.docker.com/desktop/setup/install/mac-install/) | Yes | Install app, then open it | `docker info` |
| [kind](https://kind.sigs.k8s.io/) | Yes | `brew install kind` | `kind version` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Yes | `brew install kubectl` | `kubectl version --client` |
| [k9s](https://k9scli.io/) | No | `brew install k9s` | `k9s version` |
| [argocd CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) | No | `brew install argocd` | `argocd version --client` |

Quick install (required tools only):

```bash
brew install kind kubectl
# Docker Desktop: install from docker.com, launch the app, wait until `docker info` works
```

### Next steps

```bash
make setup            # cluster + argocd + argocd-app (GitOps sync) + demo-data (recommended)
# or create the cluster first:
make cluster          # 1 control-plane + 2 workers (kind/cluster.yaml)
make check-cluster    # context kind-pdb-pvc-demo, 3 nodes Ready
make port-forward     # second terminal — Argo CD UI at http://localhost:8080 (no login)
```

`make setup` registers the `demo-app` Application in Argo CD and waits until it is **Synced** and **Healthy** — the dashboard shows the app immediately after setup (no manual `make argocd-app`).

The Makefile auto-exports `KUBECONFIG` to `.kube/kind-pdb-pvc-demo` when that file exists. With 2 workers, pod anti-affinity usually spreads `demo-app-0` and `demo-app-1` across workers — ideal for the drain demo. kind's default `standard` StorageClass needs no extra setup.

## Quick start

```bash
make setup            # cluster + argocd + GitOps sync + demo-data (one command)
make status           # Pods, PVCs, PDB, node placement
```

In a **second terminal**, start the Argo CD UI (no login required):

```bash
make port-forward     # http://localhost:8080
```

The `demo-app` Application is already registered and synced — open the dashboard to see it **Synced / Healthy**.

Or step by step:

```bash
make cluster && make argocd && make argocd-app && make demo-data
```

Full speaker script: **[docs/DEMO.md](docs/DEMO.md)**

## Troubleshooting

### Empty or wrong kubectl context

If `make check-cluster` shows:

```text
WARNING: current context is '' (expected kind-pdb-pvc-demo).
```

**Quick fix:** `make fix-context`

### Step-by-step

1. **Create the cluster** — `make cluster` (requires Docker running).
2. **Export kubeconfig** — the Makefile does this automatically when `.kube/kind-pdb-pvc-demo` exists, or:
   ```bash
   export KUBECONFIG="$(pwd)/.kube/kind-pdb-pvc-demo"
   ```
3. **List and switch context:**
   ```bash
   kubectl config get-contexts
   kubectl config use-context kind-pdb-pvc-demo
   ```
4. **Unset stale KUBECONFIG** — if you previously used Docker Desktop or another kind cluster:
   ```bash
   echo "$KUBECONFIG"
   unset KUBECONFIG
   make fix-context
   ```

### Checklist

| Check | Expected |
|-------|----------|
| `kubectl config current-context` | `kind-pdb-pvc-demo` |
| `kubectl get nodes` | 3 nodes (1 control-plane + 2 workers) in `Ready` |
| `echo $KUBECONFIG` | `.../k8s-pdb-pvc-eviction-demo/.kube/kind-pdb-pvc-demo` (or empty if using default after export) |

### Cluster unreachable

Context is correct but `kubectl get nodes` fails:

1. **Confirm Docker is running** — `docker ps` should return quickly.
2. **Confirm kind cluster exists** — `kind get clusters` should list `pdb-pvc-demo`.
3. **Recreate if needed:**
   ```bash
   make cluster-delete
   make cluster
   ```
4. **Check kind nodes** — `docker ps --filter name=pdb-pvc-demo` should show 3 containers.

### Argo CD install fails: CRD annotation too long (Kubernetes 1.27+)

On Kubernetes 1.27+ (including kind v1.35), client-side `kubectl apply` can fail when installing Argo CD:

```text
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

**Cause:** client-side apply stores the full manifest in the `kubectl.kubernetes.io/last-applied-configuration` annotation. Large CRDs exceed Kubernetes' 262144-byte annotation limit.

**Fix:** `make argocd` uses server-side apply (`--server-side --force-conflicts`), which avoids that annotation. Ensure you have an up-to-date Makefile, then:

```bash
make argocd
```

**Partial install:** if a failed apply left the `argocd` namespace in a broken state, delete it and retry:

```bash
kubectl delete namespace argocd
make argocd
```

### Argo CD UI not loading

The dashboard is only reachable while port-forward is running. No login is required for the local demo.

1. **Start port-forward** (leave running in a terminal):
   ```bash
   make port-forward
   ```
2. **Open** [http://localhost:8080](http://localhost:8080) — use `http`, not `https`.
3. **Confirm Argo CD is installed** — `kubectl get pods -n argocd` should show `argocd-server` Running.
4. **Re-apply demo config** if you upgraded from an older install:
   ```bash
   make argocd
   ```

For `argocd` CLI commands only, use `make argocd-password` and `argocd login ... --plaintext` (not needed for the web UI).

### Argo CD sync status Unknown (ComparisonError)

If `demo-app` shows **Sync: Unknown** with a `ComparisonError` about kustomize load restrictions:

```text
file '.../namespace.yaml' is not in or below '.../overlays/relaxed'
```

**Cause:** Kustomize overlays (`manifests/k8s-demo/overlays/relaxed`, `overlays/strict`) reference parent files via `../../`. Argo CD's repo-server runs kustomize with the default load restrictor, which blocks paths outside the overlay directory. The Application CRD does not support per-Application `kustomize.buildOptions` on older Argo CD versions.

**Default fix:** The Application uses path `manifests/k8s-demo` (root `kustomization.yaml` lists files in the same directory — no `../../`). Re-apply:

```bash
make argocd-app
```

**Strict overlay via GitOps:** `make argocd` sets global `kustomize.buildOptions: --load-restrictor LoadRestrictionsNone` in `argocd-cmd-params-cm` and restarts `argocd-repo-server`. After that, change the Application path to `manifests/k8s-demo/overlays/strict` (edit `manifests/argocd/application.yaml` or patch the live Application), then `make argocd-app`.

The Application is applied from the local `manifests/argocd/application.yaml` via `make argocd-app` — no git push required for that step. Push to GitHub only if you want the repo copy to match.

### Pods on the same node

With 2 workers, anti-affinity usually spreads pods. If both land on one worker, delete pods once to reschedule:

```bash
kubectl delete pod -n demo demo-app-0 demo-app-1
make wait-ready
make status
```

## Teardown

```bash
make teardown        # Remove demo namespace + Argo app, uncordon nodes
make clean           # teardown + delete kind cluster
make cluster-delete  # Delete kind cluster only
```

## Argo CD

### Install

```bash
make argocd
```

Creates the `argocd` namespace, applies the upstream Argo CD install manifest with server-side apply (avoids CRD annotation size limits on Kubernetes 1.27+), applies local demo config (`manifests/argocd/insecure-anonymous.yaml` — anonymous admin, insecure HTTP, and global `kustomize.buildOptions` for overlay paths), restarts `argocd-server` and `argocd-repo-server`, and waits until both are ready.

> **Security:** Anonymous admin access is configured for **local demo only** — not for production.

### Dashboard (local)

**No login required.** `make argocd` enables anonymous admin access and HTTP mode for the UI.

Port-forward the UI (leave running):

```bash
make port-forward
```

Forwards `argocd-server` to **http://localhost:8080**. Open that URL in your browser — the dashboard loads without credentials.

### CLI (optional)

Install the CLI (macOS):

```bash
brew install argocd
```

For CLI commands you can log in with the initial admin password (`make argocd-password`, username `admin`):

```bash
argocd login localhost:8080 --username admin --password <pwd> --plaintext
```

Or use `kubectl` to inspect Applications without the CLI.

Useful commands during the demo:

```bash
argocd app list
argocd app get demo-app
argocd app sync demo-app
argocd app wait demo-app --health
argocd app diff demo-app
```

### GitOps repo URL

`make setup` deploys the demo app via Argo CD GitOps sync (not `kubectl apply`). Argo CD clones manifests from:

```bash
https://github.com/freemanpdwork/k8s-pdb-pvc-eviction-demo.git
```

(path: `manifests/k8s-demo` — relaxed PDB; use `manifests/k8s-demo/overlays/strict` for strict PDB after `make argocd` enables global kustomize options)

**Requirements:**

1. **Default repo** — works out of the box when that GitHub repo is reachable and contains the overlay at the path above.
2. **Your fork** — push `manifests/k8s-demo/` to your remote, then override before setup:

```bash
export DEMO_REPO_URL=https://github.com/YOUR_USER/k8s-pdb-pvc-eviction-demo.git
make setup
```

3. **Offline / no git** — skip GitOps and apply locally:

```bash
make cluster && make argocd && make deploy-direct && make demo-data
```

Re-register or re-sync the Application manually:

```bash
make argocd-app      # apply local manifests/argocd/application.yaml + wait for Synced/Healthy
make argocd-wait     # wait only (Application must already exist)
```

`make argocd-app` substitutes `DEMO_REPO_URL` and applies `manifests/argocd/application.yaml` from this repo — it does not pull the Application definition from GitHub.

### GitOps vs local deploy

| Target | When to use |
|--------|-------------|
| `make setup` | **Recommended** — cluster + Argo CD + GitOps sync + demo data |
| `make deploy` / `make deploy-direct` | **Local offline demo** — kubectl apply, no git push |
| `make argocd-app` | Re-register Application and wait for sync (also runs during `make setup`) |
| `make pdb-strict` | Switch to strict PDB without git (kubectl) |
| `make deploy-strict` | Full strict overlay apply |

For local-only demos, `make pdb-strict` and `make pdb-relaxed` switch PDB policy instantly without git.

## Demo flow (summary)

**Live command cheat sheet:** **[docs/DEMO-STEPS.md](docs/DEMO-STEPS.md)** (kubectl + k9s + Makefile shortcuts). Full speaker script: **[docs/DEMO.md](docs/DEMO.md)**.

1. **Full bootstrap** — `make setup` (cluster + Argo CD + `demo-app` synced via GitOps); `make port-forward` → http://localhost:8080 (no login)
2. **k9s tour** — pods spread across workers, PVCs bound
3. **PVC persistence** — `make demo-data`, restart pod, marker survives on `/data`
4. **Relaxed PDB** — `make evict` succeeds (minAvailable: 1)
5. **Git rollout** — change overlay, push, Argo sync (or `make deploy-direct`)
6. **Strict PDB** — `make pdb-strict`, `make evict` / `make drain` blocked
7. **Drift self-heal** — kubectl edit pod, Argo restores desired state

## k9s cheat sheet

| Key | Action |
|-----|--------|
| `:` | Command mode (`pods`, `pvc`, `pdb`, `applications`) |
| `/` | Filter |
| `d` | Describe |
| `l` | Logs |
| `s` | Shell (exec) |
| `Ctrl-a` | All namespaces |
| `?` | Help |

Useful views during demo: `:pods demo`, `:pvc demo`, `:pdb demo`, `:applications argocd`

## Architecture

```
kind cluster pdb-pvc-demo (kind-pdb-pvc-demo context)
├── control-plane
├── worker A  ── demo-app-0  (PVC demo-app-data-demo-app-0)
└── worker B  ── demo-app-1  (PVC demo-app-data-demo-app-1)

StatefulSet demo-app (2 replicas, Parallel)
  └── volumeClaimTemplates → 1Gi RWO mounted at /data
PDB demo-app-pdb
  ├── relaxed: minAvailable 1  (one pod may be evicted)
  └── strict:  minAvailable 2  (no voluntary disruption)
```

## Makefile targets

```bash
make help            # All targets
make setup           # Full demo bootstrap (cluster + argocd + GitOps sync + demo-data)
make cluster         # Create kind cluster + export kubeconfig
make cluster-delete  # Delete kind cluster
make check-cluster   # Verify kind cluster and nodes
make fix-context     # Fix empty/wrong kubectl context
make argocd          # Install Argo CD (anonymous admin, HTTP)
make port-forward    # Argo CD UI at http://localhost:8080 (no login)
make argocd-password # Initial admin password (CLI only)
make argocd-app      # Register demo-app Application + wait for sync
make argocd-wait     # Wait for demo-app Synced/Healthy
make deploy          # Apply relaxed overlay (offline kubectl)
make demo-data       # Write PVC markers
make pdb-strict      # Strict PDB (blocks eviction)
make pdb-relaxed     # Relaxed PDB (allows one eviction)
make evict           # Evict a pod via API
make drain           # Cordon + drain node (PDB demo)
make status          # Resource overview
make teardown        # Remove demo resources
make clean           # Teardown + delete kind cluster
make validate        # kubectl kustomize build check
```

## Alternative: Docker Desktop Kubernetes

If you prefer Docker Desktop's built-in Kubernetes instead of kind:

1. **Docker Desktop → Settings → Kubernetes** → enable **Enable Kubernetes** → **Apply & restart**
2. `kubectl config use-context docker-desktop`
3. Run `make fix-context` if needed (supports `docker-desktop` as fallback)
4. Continue with `make argocd && make argocd-app && make demo-data` (or `make setup` if using kind from scratch)
5. `make port-forward` in a second terminal → http://localhost:8080 (no login)

**Single-node note:** Docker Desktop usually provides one node. Eviction and strict PDB behave the same, but both demo pods may share that node and the drain demo is less realistic than with 2 kind workers.

## License

See [LICENSE](LICENSE).
