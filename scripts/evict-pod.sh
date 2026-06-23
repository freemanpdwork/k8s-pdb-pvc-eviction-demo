#!/usr/bin/env bash
# Evict a demo pod via the policy/v1 Eviction API.
# Clearly shows HTTP 201 (allowed) or HTTP 429 (blocked by PDB).
set -uo pipefail

NAMESPACE="${NAMESPACE:-demo}"
POD="${1:-}"

if [[ -z "${POD}" ]]; then
  POD=$(kubectl get pods -n "${NAMESPACE}" -l app=demo-app \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi

if [[ -z "${POD}" ]]; then
  echo "No Running demo-app pod found in namespace ${NAMESPACE}." >&2
  exit 1
fi

echo "=== PDB state before eviction ==="
kubectl get pdb -n "${NAMESPACE}" -o wide
allowed=$(kubectl get pdb -n "${NAMESPACE}" \
  -o jsonpath='{.items[0].status.disruptionsAllowed}' 2>/dev/null || echo "?")
echo ""

echo "--- Eviction API request ---"
printf "  POST /api/v1/namespaces/%s/pods/%s/eviction\n\n" "${NAMESPACE}" "${POD}"
cat <<EOF
  {
    "apiVersion": "policy/v1",
    "kind": "Eviction",
    "metadata": { "name": "${POD}", "namespace": "${NAMESPACE}" }
  }
EOF
echo ""

evict_err=$(kubectl create -f - 2>&1 <<EOF || true
apiVersion: policy/v1
kind: Eviction
metadata:
  name: ${POD}
  namespace: ${NAMESPACE}
EOF
)
evict_rc=$?

echo "--- Eviction API response ---"
echo ""

if [[ ${evict_rc} -eq 0 ]]; then
  echo "  HTTP 201 Created"
  echo ""
  echo "  ✓  EVICTION ALLOWED"
  echo "     disruptionsAllowed was ${allowed} — one disruption permitted."
  echo ""
  echo "Pod ${POD} is terminating. Watching recreation (15s)..."
  kubectl get pods -n "${NAMESPACE}" -l app=demo-app -w &
  watch_pid=$!
  sleep 15
  kill "${watch_pid}" 2>/dev/null || true
  echo ""
  echo "=== Pod + PVC state after eviction ==="
  kubectl get pods,pvc -n "${NAMESPACE}" -l app=demo-app
elif echo "${evict_err}" | grep -q "disruption budget"; then
  echo "  HTTP 429 Too Many Requests"
  echo ""
  echo "  ✗  EVICTION BLOCKED by PDB"
  echo "     disruptionsAllowed is ${allowed} — no voluntary disruption permitted."
  echo ""
  echo "  API message: $(echo "${evict_err}" | sed 's/^error: //')"
  echo ""
  echo "Pod ${POD} was NOT deleted."
  echo ""
  echo "=== PDB state (confirming block) ==="
  kubectl get pdb -n "${NAMESPACE}" -o wide
else
  echo "  Eviction failed for an unexpected reason (exit ${evict_rc}):"
  echo "  ${evict_err}"
  exit "${evict_rc}"
fi