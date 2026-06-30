# k8s PDB + PVC + Eviction Demo
###
Hands-on demo of **PodDisruptionBudgets**, **PVC-backed StatefulSets**, voluntary **eviction**, node **drain**, and **Argo CD GitOps** on a local **kind** cluster (4 nodes: 1 control-plane + 3 workers).

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
make preflight        # validate overlays, cluster, GitHub reachability, print URLs
make setup            # cluster + argocd + argocd-app (GitOps sync) + demo-data (recommended)
# or create the cluster first:
make cluster          # 1 control-plane + 3 workers (kind/cluster.yaml)
make check-cluster    # context kind-pdb-pvc-demo, 4 nodes Ready
# After make setup (no tunnel required on kind):
open http://localhost:30080   # Argo CD UI — no login
make demo-url         # → http://localhost:30090/ — PVC data in browser
```

**Prep checklist:** `make preflight` · `make setup` · `make status` · Argo CD at :30080 · demo app at :30090 (`make demo-url`). GitHub unreachable? Use `make setup-offline` instead.

`make setup` registers the `demo-app` Application in Argo CD and waits until it is **Synced** and **Healthy** — the dashboard shows the app immediately after setup (no manual `make argocd-app`).

The Makefile auto-exports `KUBECONFIG` to `.kube/kind-pdb-pvc-demo` when that file exists. With 3 workers, pod anti-affinity usually spreads `demo-app-0` and `demo-app-1` across workers — ideal for the drain demo. kind's default `standard` StorageClass needs no extra setup.

## Quick start

```bash
make setup            # cluster + argocd + GitOps sync + demo-data (one command)
make status           # Pods, PVCs, PDB, node placement
```

In a second terminal (optional — only if NodePort is unavailable), start a tunnel fallback:

```bash
make port-forward     # http://127.0.0.1:8888 (Argo CD fallback)
```

**Preferred on kind/Mac:** after `make setup` or `make deploy-direct`:

- Argo CD UI: **[http://localhost:30080](http://localhost:30080)** — no tunnel
- Demo app HTTP: **`make demo-url`** → **[http://localhost:30090](http://localhost:30090)** — PVC data in the browser

Run **`make preflight`** before presenting — validates overlays, checks the cluster, probes GitHub reachability, and prints both URLs.

The `demo-app` Application is already registered and synced — open the dashboard to see it **Synced / Healthy**.

Or step by step:

```bash
make cluster && make argocd && make argocd-app && make demo-data
```

Full speaker script: **[docs/DEMO.md](docs/DEMO.md)** · Command cheat sheet: **[docs/DEMO-STEPS.md](docs/DEMO-STEPS.md)** · Drain workflow: **[docs/DEMO-DRAIN-WORKFLOW.md](docs/DEMO-DRAIN-WORKFLOW.md)**

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
| `kubectl get nodes` | 4 nodes (1 control-plane + 3 workers) in `Ready` |
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
4. **Check kind nodes** — `docker ps --filter name=pdb-pvc-demo` should show 4 containers.

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

### `make argocd-app` fails: `configmap "argocd-cm" not found`

```text
{"level":"fatal","msg":"configmap \"argocd-cm\" not found"}
```

**Cause:** `argocd --core` reads Argo CD settings from the `argocd-cm` ConfigMap in the **Argo CD install namespace** (`argocd`). Without `--argocd-namespace`, the CLI may look in the wrong namespace (for example `default`). The `-N` flag on `app` commands is the **Application** namespace, not the install namespace.

**Fix:**

1. Install Argo CD first: `make argocd`
2. Use an up-to-date Makefile — `ARGOCD_CLI` includes `--argocd-namespace argocd` and exports `ARGOCD_NAMESPACE`
3. Confirm the ConfigMap exists:
   ```bash
   kubectl get configmap argocd-cm -n argocd
   ```

If the CLI still fails, `make argocd-app` falls back to server-side apply of `manifests/argocd/application.yaml` and waits for Synced/Healthy via `kubectl wait`.

### Argo CD UI not loading

**Preferred access (kind/Mac):** after `make argocd` or `make setup`, open **[http://localhost:30080](http://localhost:30080)** — no login, no tunnel. `make argocd` runs `make argocd-expose` automatically (NodePort + kind `extraPortMappings` in `kind/cluster.yaml`).

If you created the cluster **before** this NodePort mapping was added, recreate it so Docker forwards host port 30080:

```bash
make cluster-delete
make cluster
make argocd
```

#### Diagnostics

While a tunnel is running (`make port-forward` or `make argocd-proxy`), test from another terminal:

```bash
curl -v http://127.0.0.1:8888/          # port-forward default (ARGOCD_LOCAL_PORT)
curl -v http://127.0.0.1:30080/         # NodePort (preferred)
```

Watch the server if the UI fails or resets:

```bash
kubectl logs -n argocd deployment/argocd-server -f
```

Confirm the service and NodePort:

```bash
kubectl get svc argocd-server -n argocd
```

#### Fallback: port-forward / kubectl proxy

Tunnels can drop on kind/Mac when the browser connects (`connection reset by peer`). Use NodePort first; fall back only if needed.

1. **NodePort (recommended):**
   ```bash
   make argocd-expose
   # Open http://localhost:30080
   ```
2. **Port-forward** (leave running in a terminal):
   ```bash
   make port-forward
   ```
   Forwards `deployment/argocd-server` pod port **8080** to **http://127.0.0.1:8888** (default `ARGOCD_LOCAL_PORT`). Override if busy:
   ```bash
   ARGOCD_LOCAL_PORT=9080 make port-forward
   ```
3. **kubectl proxy:**
   ```bash
   make argocd-proxy
   # Open the printed URL (default http://127.0.0.1:8001/api/v1/namespaces/argocd/services/http:argocd-server:80/proxy/)
   ```

Use `http`, not `https`. No login is required for the local demo.

4. **Confirm Argo CD is installed** — `kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server` should show a **Ready** pod.
5. **Re-apply demo config** if you upgraded from an older install:
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

With 3 workers, anti-affinity usually spreads pods. If both land on one worker, delete pods once to reschedule:

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

**No login required.** `make argocd` enables anonymous admin access and HTTP mode for the UI, then exposes the dashboard on NodePort **30080**.

**Preferred (kind/Mac):** open **[http://localhost:30080](http://localhost:30080)** after `make argocd` or `make setup` — no second terminal.

Re-expose manually if needed:

```bash
make argocd-expose    # http://localhost:30080 (ARGOCD_NODE_PORT to override)
```

**Fallback tunnels** (can reset on kind/Mac when the browser connects):

```bash
make port-forward     # http://127.0.0.1:8888 (ARGOCD_LOCAL_PORT to override)
make argocd-proxy     # kubectl proxy — URL printed by make
```

### CLI (optional)

Install the CLI (macOS):

```bash
brew install argocd
```

For CLI commands you can log in with the initial admin password (`make argocd-password`, username `admin`):

```bash
argocd login localhost:30080 --username admin --password <pwd> --plaintext
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
make setup-offline    # cluster + argocd + deploy-direct + demo-data
# or step by step:
make cluster && make argocd && make deploy-direct && make demo-data
```

Re-register or re-sync the Application manually:

```bash
make argocd-app      # create/update Application through argocd CLI + wait for Synced/Healthy
make argocd-sync     # sync through argocd CLI
make argocd-wait     # wait only (Application must already exist)
```

`make argocd-app` uses `argocd --core --argocd-namespace argocd`, so no Argo CD login is required. The Application still points at `DEMO_REPO_URL`; Argo CD owns the deployed Kubernetes resources.

### GitOps vs local deploy

| Target | When to use |
|--------|-------------|
| `make setup` | **Recommended** — cluster + Argo CD + GitOps sync + demo data |
| `make deploy` / `make deploy-direct` | **Local offline demo** — kubectl apply, no git push |
| `make argocd-app` | Create/update Application through Argo CD CLI and sync |
| `make argocd-relaxed` / `make argocd-strict` | Point the Argo CD Application at relaxed/strict desired state and sync |
| `make pdb-relaxed` / `make pdb-strict` | Backward-compatible aliases for the Argo CD targets |
| `make deploy-strict` | Offline kubectl fallback only |

For the primary demo, use Argo CD targets for desired-state changes. `kubectl` is used for observation and operational actions such as eviction, cordon, and drain.

## Demo flow (summary)

**Live command cheat sheet:** **[docs/DEMO-STEPS.md](docs/DEMO-STEPS.md)** (kubectl + k9s + Makefile shortcuts). Full speaker script: **[docs/DEMO.md](docs/DEMO.md)**. Drain → eviction → PDB → replacement: **[docs/DEMO-DRAIN-WORKFLOW.md](docs/DEMO-DRAIN-WORKFLOW.md)**.

1. **Full bootstrap** — `make setup` (cluster + Argo CD + `demo-app` synced via GitOps); open http://localhost:30080 (no login)
2. **k9s tour** — pods spread across workers, PVCs bound
3. **PVC persistence** — `make act-pvc`, pod UID changes while the PVC marker survives on `/data`
4. **Relaxed PDB** — `make evict` succeeds (minAvailable: 1)
5. **Git rollout** — change overlay, push, `make argocd-sync`
6. **Strict PDB** — `make act-pdb`, Argo CD syncs strict desired state, Eviction API returns 429
7. **Maintenance** — `make act-drain`, pause automated sync, cordon/drain, PDB blocks eviction ([drain workflow doc](docs/DEMO-DRAIN-WORKFLOW.md))
8. **Drift self-heal** — kubectl edit pod, Argo restores desired state after `make argocd-resume-sync`

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
├── worker A  ── demo-app-0  (PVC data-demo-app-0)
├── worker B  ── demo-app-1  (PVC data-demo-app-1)
└── worker C  (idle — drain demo target)

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
make setup-offline   # Bootstrap without GitOps (cluster + argocd + deploy-direct + demo-data)
make preflight       # Validate overlays + cluster + GitHub reachability + print URLs
make cluster         # Create kind cluster + export kubeconfig
make cluster-delete  # Delete kind cluster
make check-cluster   # Verify kind cluster and nodes
make fix-context     # Fix empty/wrong kubectl context
make argocd          # Install Argo CD (anonymous admin, HTTP) + NodePort expose
make argocd-expose   # Expose Argo CD UI at http://localhost:30080 (kind/Mac)
make demo-expose     # Expose demo app HTTP at http://localhost:30090 (kind/Mac)
make demo-url        # Print demo app URL and apply NodePort if needed
make demo-drain-doc  # Print path to drain workflow doc
make port-forward    # Argo CD UI tunnel fallback (http://127.0.0.1:8888)
make argocd-proxy    # kubectl proxy fallback for Argo CD UI
make argocd-password # Initial admin password (CLI only)
make argocd-cli-check # Verify argocd CLI is installed
make argocd-app      # Create/update demo-app Application through argocd CLI
make argocd-sync     # Sync demo-app through argocd CLI
make argocd-wait     # Wait for demo-app Synced/Healthy
make argocd-relaxed  # Argo CD desired state: relaxed PDB
make argocd-strict   # Argo CD desired state: strict PDB
make argocd-pause-sync  # Pause automated sync (manual mode)
make argocd-resume-sync # Resume automated sync with prune + selfHeal
make deploy          # Apply relaxed overlay (offline kubectl)
make demo-data       # Write PVC markers
make act-pvc         # Guided PVC act: pod recreated, marker survives
make act-pdb         # Guided PDB act: strict PDB blocks eviction
make act-drain       # Guided maintenance act: pause sync + cordon/drain
make pdb-explain     # Show PDB YAML variants + live status math
make pdb-strict      # Alias for make argocd-strict
make pdb-relaxed     # Alias for make argocd-relaxed
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
5. Open http://localhost:30080 after `make argocd` (or `make port-forward` as fallback)

**Single-node note:** Docker Desktop usually provides one node. Eviction and strict PDB behave the same, but both demo pods may share that node and the drain demo is less realistic than with 3 kind workers.

## License

See [LICENSE](LICENSE).
