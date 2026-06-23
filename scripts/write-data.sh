#!/usr/bin/env bash
# Write a unique marker file to /data/marker.txt on each demo-app pod (PVC-backed).
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
STATEFULSET="${STATEFULSET:-demo-app}"
MARKER_FILE="/data/marker.txt"

pods=$(kubectl get pods -n "${NAMESPACE}" -l app=demo-app \
  --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

if [[ -z "${pods}" ]]; then
  echo "No Running demo-app pods found in namespace ${NAMESPACE}." >&2
  exit 1
fi

while IFS= read -r pod; do
  [[ -z "${pod}" ]] && continue
  ordinal="${pod##*-}"
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  marker="pod=${pod} ordinal=${ordinal} written=${timestamp} host=$(hostname)"

  echo "Writing marker to ${pod}:${MARKER_FILE}"
  kubectl exec -n "${NAMESPACE}" "${pod}" -- sh -c \
    "mkdir -p /data && echo '${marker}' > ${MARKER_FILE} && cat ${MARKER_FILE}"
done <<< "${pods}"

echo ""
echo "Marker files on PVC-backed /data:"
while IFS= read -r pod; do
  [[ -z "${pod}" ]] && continue
  echo "--- ${pod} ---"
  kubectl exec -n "${NAMESPACE}" "${pod}" -- cat "${MARKER_FILE}" 2>/dev/null || \
    echo "(no marker yet)"
done <<< "${pods}"
