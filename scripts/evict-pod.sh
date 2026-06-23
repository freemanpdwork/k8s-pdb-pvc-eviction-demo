#!/usr/bin/env bash
# Evict a demo pod via the policy/v1 Eviction API.
# Uses kubectl proxy + curl to show the real HTTP status: 201 (allowed) or 429 (PDB blocked).
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

# Eviction is a pod subresource — kubectl create -f - cannot discover it.
# Use kubectl proxy + curl to POST directly to the subresource endpoint.
proxy_port=$((RANDOM % 10000 + 30000))
while lsof -iTCP:"${proxy_port}" -sTCP:LISTEN -t >/dev/null 2>&1; do
  proxy_port=$((proxy_port + 1))
done
kubectl proxy --port="${proxy_port}" >/dev/null 2>&1 &
proxy_pid=$!
trap 'kill "${proxy_pid}" 2>/dev/null || true' EXIT

# Wait for proxy to be ready (up to 5s)
for _ in $(seq 25); do
  curl -sf "http://localhost:${proxy_port}/healthz" >/dev/null 2>&1 && break
  sleep 0.2
done

tmpfile=$(mktemp)
http_code=$(curl -s -o "${tmpfile}" -w "%{http_code}" -X POST \
  "http://localhost:${proxy_port}/api/v1/namespaces/${NAMESPACE}/pods/${POD}/eviction" \
  -H "Content-Type: application/json" \
  -d "{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\"${POD}\",\"namespace\":\"${NAMESPACE}\"}}")
body=$(cat "${tmpfile}"); rm -f "${tmpfile}"
kill "${proxy_pid}" 2>/dev/null || true; trap - EXIT

if command -v jq >/dev/null 2>&1; then
  api_msg=$(echo "${body}" | jq -r '.message // empty' 2>/dev/null || true)
else
  api_msg=$(echo "${body}" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
fi

echo "--- Eviction API response ---"
echo ""

case "${http_code}" in
  201)
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
    ;;
  429)
    echo "  HTTP 429 Too Many Requests"
    echo ""
    echo "  ✗  EVICTION BLOCKED by PDB"
    echo "     disruptionsAllowed is ${allowed} — no voluntary disruption permitted."
    echo ""
    [[ -n "${api_msg}" ]] && echo "  API message: ${api_msg}"
    echo ""
    echo "Pod ${POD} was NOT deleted."
    echo ""
    echo "=== PDB state (confirming block) ==="
    kubectl get pdb -n "${NAMESPACE}" -o wide
    ;;
  "")
    echo "  No response — kubectl proxy may not have started in time." >&2
    exit 1
    ;;
  *)
    echo "  HTTP ${http_code} — unexpected response"
    echo "  ${body}"
    exit 1
    ;;
esac