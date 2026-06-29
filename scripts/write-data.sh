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

  marker="pod=${pod} ordinal=${ordinal} written=${timestamp}"

  echo "Writing marker to ${pod}:${MARKER_FILE}"
  kubectl exec -n "${NAMESPACE}" "${pod}" -- mkdir -p /data
  printf '%s\n' "${marker}" | kubectl exec -i -n "${NAMESPACE}" "${pod}" -- sh -c "cat > ${MARKER_FILE}"
  kubectl exec -n "${NAMESPACE}" "${pod}" -- cat "${MARKER_FILE}"

  # Write index.html - served by nginx when you run make demo-url.
  html_content=$(cat <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>PVC demo - ${pod}</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #17202a;
      --muted: #5f6c7b;
      --line: #d8dee7;
      --panel: #ffffff;
      --bg: #f4f7fb;
      --accent: #0f766e;
      --accent-2: #b45309;
      --code: #111827;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      background: var(--bg);
      color: var(--ink);
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    main {
      width: min(920px, calc(100vw - 32px));
      margin: 0 auto;
      padding: 32px 0 40px;
    }
    header {
      display: flex;
      justify-content: space-between;
      gap: 20px;
      align-items: flex-start;
      border-bottom: 1px solid var(--line);
      padding-bottom: 20px;
      margin-bottom: 20px;
    }
    h1 {
      margin: 0 0 8px;
      font-size: clamp(1.7rem, 4vw, 3rem);
      line-height: 1.05;
    }
    p {
      margin: 0;
      color: var(--muted);
      line-height: 1.5;
    }
    .pill {
      flex: 0 0 auto;
      border: 1px solid #9ad2ca;
      background: #e7f6f3;
      color: var(--accent);
      border-radius: 999px;
      padding: 8px 12px;
      font-weight: 700;
      white-space: nowrap;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 12px;
    }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
      min-width: 0;
    }
    .label {
      color: var(--muted);
      display: block;
      font-size: 0.78rem;
      font-weight: 700;
      margin-bottom: 8px;
      text-transform: uppercase;
    }
    .value {
      color: var(--ink);
      display: block;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 0.96rem;
      overflow-wrap: anywhere;
    }
    .wide {
      grid-column: span 2;
    }
    .marker {
      background: var(--code);
      color: #f9fafb;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      overflow-x: auto;
      white-space: pre-wrap;
    }
    .note {
      border-left: 4px solid var(--accent-2);
      margin-top: 12px;
    }
    a { color: var(--accent); font-weight: 700; }
    code {
      background: #e8edf4;
      border-radius: 5px;
      color: var(--code);
      padding: 2px 5px;
    }
    @media (max-width: 760px) {
      main { width: min(100vw - 20px, 920px); padding-top: 20px; }
      header { display: block; }
      .pill { display: inline-block; margin-top: 14px; }
      .grid { grid-template-columns: 1fr; }
      .wide { grid-column: auto; }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>${pod}</h1>
        <p>StatefulSet pod serving files from its PVC-backed <code>/data</code> directory.</p>
      </div>
      <div class="pill">PVC data is persistent</div>
    </header>

    <section class="grid" aria-label="Demo state">
      <div class="panel">
        <span class="label">Pod identity</span>
        <span class="value">${pod}</span>
      </div>
      <div class="panel">
        <span class="label">Ordinal</span>
        <span class="value">${ordinal}</span>
      </div>
      <div class="panel wide">
        <span class="label">PersistentVolumeClaim</span>
        <span class="value">${pvc}</span>
      </div>
      <div class="panel wide">
        <span class="label">Node when marker was written</span>
        <span class="value">${node}</span>
      </div>
      <div class="panel wide">
        <span class="label">Marker written at</span>
        <span class="value">${timestamp}</span>
      </div>
      <div class="panel marker wide">
${marker}
      </div>
      <div class="panel note wide">
        <span class="label">What to watch</span>
        <p>After eviction, the pod object is recreated but <code>marker.txt</code> remains on the same PVC. On kind, local-path PVs are node-local, so the volume anchors the pod to the storage node instead of freely moving the disk.</p>
      </div>
      <div class="panel wide">
        <span class="label">Raw marker</span>
        <p><a href="marker.txt">Open marker.txt</a></p>
      </div>
    </section>
  </main>
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
