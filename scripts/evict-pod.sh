#!/usr/bin/env bash
# Evict a demo pod via the policy/v1 Eviction API.
# Usage: evict-pod.sh [pod-name]
# If pod-name is omitted, evicts the first Running demo-app pod.
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
POD="${1:-}"

if [[ -z "${POD}" ]]; then
  POD=$(kubectl get pods -n "${NAMESPACE}" -l app=demo-app \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}')
fi

if [[ -z "${POD}" ]]; then
  echo "No Running demo-app pod found to evict." >&2
  exit 1
fi

echo "Evicting pod/${POD} in namespace ${NAMESPACE}..."
echo ""
echo "Sample eviction manifest (for reference):"
cat <<EOF
apiVersion: policy/v1
kind: Eviction
metadata:
  name: ${POD}
  namespace: ${NAMESPACE}
spec:
  deleteOptions:
    gracePeriodSeconds: 30
EOF
echo ""

if kubectl create -f - <<EOF
apiVersion: policy/v1
kind: Eviction
metadata:
  name: ${POD}
  namespace: ${NAMESPACE}
spec:
  deleteOptions:
    gracePeriodSeconds: 30
EOF
then
  echo "Eviction succeeded for ${POD}."
else
  rc=$?
  echo ""
  echo "Eviction failed (exit ${rc}). Common causes:"
  echo "  - PDB minAvailable blocks voluntary disruption"
  echo "  - Pod is not Running or already terminating"
  exit "${rc}"
fi

echo ""
echo "Watching pod recreation..."
kubectl get pods -n "${NAMESPACE}" -l app=demo-app -w &
watch_pid=$!
sleep 15
kill "${watch_pid}" 2>/dev/null || true

echo ""
kubectl get pods,pvc -n "${NAMESPACE}" -l app=demo-app
