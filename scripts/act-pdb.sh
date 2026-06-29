#!/usr/bin/env bash
# Guided PDB act: switch to strict mode, prove eviction is blocked, and compare pod UID.
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
STATEFULSET="${STATEFULSET:-demo-app}"
POD="${POD:-${STATEFULSET}-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ready_count="$(kubectl get pods -n "${NAMESPACE}" -l app=demo-app \
  -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' | wc -l | tr -d ' ')"

if [[ "${ready_count}" != "2" ]]; then
  echo "Strict PDB demo expects exactly 2 Running demo-app pods; found ${ready_count}." >&2
  echo "Run: make wait-ready && make status" >&2
  exit 1
fi

echo ""
echo "=== ACT: PDB enforcement ==="
echo "Switching to strict PDB: minAvailable=2 with 2 replicas."
echo ""
make --no-print-directory argocd-strict

echo ""
echo "Waiting for strict PDB to report ALLOWED DISRUPTIONS=0..."
allowed=""
for _ in $(seq 30); do
  allowed="$(kubectl get pdb -n "${NAMESPACE}" demo-app-pdb -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null || true)"
  [[ "${allowed}" == "0" ]] && break
  sleep 1
done
if [[ "${allowed}" != "0" ]]; then
  echo "PDB did not report ALLOWED DISRUPTIONS=0; found '${allowed:-unknown}'." >&2
  kubectl get pdb -n "${NAMESPACE}" demo-app-pdb -o wide 2>/dev/null || true
  exit 1
fi

echo ""
echo "Before blocked eviction:"
uid_before="$(kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath='{.metadata.uid}')"
node_before="$(kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath='{.spec.nodeName}')"
printf '  pod UID: %s\n' "${uid_before}"
printf '  node:    %s\n' "${node_before}"
kubectl get pdb -n "${NAMESPACE}" demo-app-pdb -o wide

echo ""
echo "Trying to evict ${POD}. Strict PDB should return HTTP 429 and leave the pod running."
"${SCRIPT_DIR}/evict-pod.sh" "${POD}"

echo ""
echo "After blocked eviction:"
uid_after="$(kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath='{.metadata.uid}')"
node_after="$(kubectl get pod -n "${NAMESPACE}" "${POD}" -o jsonpath='{.spec.nodeName}')"
printf '  pod UID: %s\n' "${uid_after}"
printf '  node:    %s\n' "${node_after}"
kubectl get pods -n "${NAMESPACE}" -l app=demo-app -o wide

echo ""
if [[ "${uid_before}" == "${uid_after}" ]]; then
  echo "Result: PDB blocked the voluntary disruption; the pod object was not deleted."
else
  echo "Result: pod UID changed unexpectedly; confirm the PDB showed ALLOWED DISRUPTIONS=0."
fi

echo ""
echo "Restore the demo with: make argocd-relaxed"
