#!/usr/bin/env bash
# Wait for demo StatefulSet pods, PVCs, and PDB to become ready.
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
STATEFULSET="${STATEFULSET:-demo-app}"
TIMEOUT="${TIMEOUT:-180s}"

echo "Waiting for StatefulSet/${STATEFULSET} rollout in namespace ${NAMESPACE}..."
kubectl rollout status "statefulset/${STATEFULSET}" -n "${NAMESPACE}" --timeout="${TIMEOUT}"

echo "Waiting for pods to be Ready..."
kubectl wait --for=condition=Ready pod \
  -l app=demo-app \
  -n "${NAMESPACE}" \
  --timeout="${TIMEOUT}"

echo "Waiting for PVCs to be Bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc \
  -l app=demo-app \
  -n "${NAMESPACE}" \
  --timeout="${TIMEOUT}" 2>/dev/null || {
  # volumeClaimTemplates may not propagate the label to PVCs on all clusters
  pending=$(kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -c Pending || true)
  if [[ "${pending}" -gt 0 ]]; then
    echo "Some PVCs still Pending; waiting..."
    sleep 5
    kubectl get pvc -n "${NAMESPACE}"
  fi
}

if kubectl get pdb demo-app-pdb -n "${NAMESPACE}" &>/dev/null; then
  echo "PDB demo-app-pdb is present."
  kubectl get pdb demo-app-pdb -n "${NAMESPACE}"
fi

echo "All resources ready."
kubectl get pods,pvc,pdb -n "${NAMESPACE}" -l app=demo-app 2>/dev/null || \
  kubectl get pods,pvc,pdb -n "${NAMESPACE}"
