#!/usr/bin/env bash
# Guided PVC persistence act: capture pod/PVC state, evict, and compare after recreation.
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
STATEFULSET="${STATEFULSET:-demo-app}"
POD="${POD:-${STATEFULSET}-0}"
MARKER_FILE="/data/marker.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pod_value() {
  local jsonpath="$1"
  kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath="${jsonpath}"
}

marker_value() {
  kubectl exec -n "${NAMESPACE}" "${POD}" -- cat "${MARKER_FILE}" 2>/dev/null || true
}

echo ""
echo "=== ACT: PVC persistence ==="
echo "Pod: ${NAMESPACE}/${POD}"
echo "Browser: http://localhost:${DEMO_NODE_PORT:-30090}/"
echo ""

echo "Before eviction:"
uid_before="$(pod_value '{.metadata.uid}')"
node_before="$(pod_value '{.spec.nodeName}')"
claim_before="$(pod_value '{.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}')"
marker_before="$(marker_value)"
printf '  pod UID: %s\n' "${uid_before}"
printf '  node:    %s\n' "${node_before}"
printf '  PVC:     %s\n' "${claim_before}"
printf '  marker:  %s\n' "${marker_before:-"(missing)"}"
echo ""

echo "Waiting for relaxed PDB to allow one disruption..."
allowed=""
for _ in $(seq 30); do
  allowed="$(kubectl get pdb -n "${NAMESPACE}" demo-app-pdb -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || true)"
  [[ "${allowed}" == "1" ]] && break
  sleep 1
done
if [[ "${allowed}" != "1" ]]; then
  echo "PDB did not report ALLOWED DISRUPTIONS=1; found '${allowed:-unknown}'." >&2
  kubectl get pdb -n "${NAMESPACE}" demo-app-pdb -o wide 2>/dev/null || true
  exit 1
fi

echo "Evicting ${POD} through the policy/v1 Eviction API..."
"${SCRIPT_DIR}/evict-pod.sh" "${POD}"

echo ""
echo "Waiting for ${POD} to be Ready again..."
kubectl wait --for=condition=Ready "pod/${POD}" -n "${NAMESPACE}" --timeout=180s

echo ""
echo "After eviction:"
uid_after="$(pod_value '{.metadata.uid}')"
node_after="$(pod_value '{.spec.nodeName}')"
claim_after="$(pod_value '{.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}')"
marker_after="$(marker_value)"
printf '  pod UID: %s\n' "${uid_after}"
printf '  node:    %s\n' "${node_after}"
printf '  PVC:     %s\n' "${claim_after}"
printf '  marker:  %s\n' "${marker_after:-"(missing)"}"
echo ""

if [[ "${uid_before}" != "${uid_after}" ]]; then
  echo "Result: pod object was recreated."
else
  echo "Result: pod UID did not change; eviction may not have completed."
fi

if [[ "${claim_before}" == "${claim_after}" && "${marker_before}" == "${marker_after}" && -n "${marker_after}" ]]; then
  echo "Result: same PVC and marker data survived."
else
  echo "Result: PVC or marker changed; inspect pod/PVC state before presenting."
fi

if [[ "${node_before}" == "${node_after}" ]]; then
  echo "Note: node stayed the same. With kind local-path storage, PV node affinity often pulls the recreated pod back to the storage node."
else
  echo "Note: node changed. The important persistence proof is the stable PVC and marker, not the old pod object."
fi

echo ""
echo "Refresh http://localhost:${DEMO_NODE_PORT:-30090}/ and open /marker.txt to show the persisted file."
