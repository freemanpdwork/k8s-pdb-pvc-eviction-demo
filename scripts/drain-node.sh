#!/usr/bin/env bash
# Cordon and drain a worker node that runs demo-app pods.
# Demonstrates PDB blocking when minAvailable cannot be satisfied.
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-120s}"
IGNORE_DAEMONSETS="${IGNORE_DAEMONSETS:---ignore-daemonsets}"

# Pick a worker node hosting at least one demo pod (skip control-plane).
node=""
for n in $(kubectl get pods -n "${NAMESPACE}" -l app=demo-app \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u); do
  if kubectl get node "${n}" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null | grep -q .; then
    continue
  fi
  node="${n}"
  break
done

if [[ -z "${node}" ]]; then
  # Fall back to any node with a demo pod
  node=$(kubectl get pods -n "${NAMESPACE}" -l app=demo-app \
    -o jsonpath='{.items[0].spec.nodeName}')
fi

if [[ -z "${node}" ]]; then
  echo "No demo-app pods found; cannot pick a node to drain." >&2
  exit 1
fi

echo "Selected node: ${node}"
echo "Pods on this node:"
kubectl get pods -n "${NAMESPACE}" -l app=demo-app \
  --field-selector="spec.nodeName=${node}" -o wide

echo ""
echo "Current PDB:"
kubectl get pdb -n "${NAMESPACE}" -o wide 2>/dev/null || echo "(no PDB)"

echo ""
echo "Cordoning ${node}..."
kubectl cordon "${node}"

echo ""
echo "Draining ${node} (timeout ${DRAIN_TIMEOUT})..."
echo "With strict PDB (minAvailable: 2, 2 replicas), drain should block eviction."
echo ""

set +e
kubectl drain "${node}" \
  --delete-emptydir-data \
  ${IGNORE_DAEMONSETS} \
  --grace-period=30 \
  --timeout="${DRAIN_TIMEOUT}"
drain_rc=$?
set -e

echo ""
if [[ ${drain_rc} -eq 0 ]]; then
  echo "Drain completed successfully."
else
  echo "Drain failed or timed out (exit ${drain_rc}) — expected when strict PDB blocks eviction."
  echo "Check events: kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp' | tail -20"
fi

echo ""
echo "Node status:"
kubectl get node "${node}"
echo ""
echo "To uncordon: kubectl uncordon ${node}"
echo "Or run: make uncordon"

exit "${drain_rc}"
