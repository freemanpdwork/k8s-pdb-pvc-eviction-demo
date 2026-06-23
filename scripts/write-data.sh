#!/usr/bin/env bash
# Write marker.txt and index.html to /data on each demo-app pod (PVC-backed).
# index.html is served by nginx at http://localhost:30090/ (via make demo-url).
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
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
  node=$(kubectl get pod -n "${NAMESPACE}" "${pod}" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")
  pvc="data-${pod}"

  echo "Writing marker to ${pod}:${MARKER_FILE}"
  kubectl exec -n "${NAMESPACE}" "${pod}" -- sh -c \
    "mkdir -p /data && printf 'pod=%s ordinal=%s written=%s\n' '${pod}' '${ordinal}' '${timestamp}' > ${MARKER_FILE} && cat ${MARKER_FILE}"

  # Write index.html — served by nginx when you run make demo-url
  html_content=$(cat <<HTMLEOF
<!DOCTYPE html>
<html>
<head>
  <title>${pod}</title>
  <style>
    body { font-family: monospace; max-width: 600px; margin: 3em auto; padding: 0 1em; }
    h1 { border-bottom: 2px solid #333; padding-bottom: .4em; }
    table { border-collapse: collapse; width: 100%; margin: 1em 0; }
    td { padding: 6px 14px; vertical-align: top; }
    tr:nth-child(even) td { background: #f5f5f5; }
    .note { color: #555; font-size: .9em; margin-top: 1.5em; border-top: 1px solid #ccc; padding-top: 1em; }
  </style>
</head>
<body>
  <h1>${pod}</h1>
  <table>
    <tr><td>PVC</td><td>${pvc}</td></tr>
    <tr><td>Node</td><td>${node}</td></tr>
    <tr><td>Written</td><td>${timestamp}</td></tr>
    <tr><td>Ordinal</td><td>${ordinal}</td></tr>
  </table>
  <p><a href="marker.txt">marker.txt</a></p>
  <p class="note">
    Served from PVC-backed <code>/data/index.html</code>.<br>
    Evict this pod — the same file reattaches on the new node.
  </p>
</body>
</html>
HTMLEOF
)
  printf '%s\n' "${html_content}" | kubectl exec -i -n "${NAMESPACE}" "${pod}" -- sh -c "cat > /data/index.html"
  echo "  index.html written to ${pod}:/data/ (served at http://localhost:30090/ via make demo-url)"

done <<< "${pods}"

echo ""
echo "Marker files on PVC-backed /data:"
while IFS= read -r pod; do
  [[ -z "${pod}" ]] && continue
  echo "--- ${pod} ---"
  kubectl exec -n "${NAMESPACE}" "${pod}" -- cat "${MARKER_FILE}" 2>/dev/null || \
    echo "(no marker yet)"
done <<< "${pods}"