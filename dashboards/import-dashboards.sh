#!/bin/bash
# Import all Grafana dashboard JSONs via Grafana HTTP API
# Usage: ./scripts/import-dashboards.sh <GRAFANA_URL> <GRAFANA_PASSWORD>
# Example: ./scripts/import-dashboards.sh http://gpu-cluster-monitoring-alb-1151117057.us-east-1.elb.amazonaws.com MyPassword
set -euo pipefail

GRAFANA_URL="${1:?Usage: import-dashboards.sh <GRAFANA_URL> <GRAFANA_PASSWORD>}"
GRAFANA_PASS="${2:?Usage: import-dashboards.sh <GRAFANA_URL> <GRAFANA_PASSWORD>}"
GRAFANA_USER="admin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="$(dirname "${SCRIPT_DIR}")/dashboards"

echo "=== Importing dashboards to ${GRAFANA_URL} ==="

# Wait for Grafana to be ready
for i in $(seq 1 20); do
  if curl -sf "${GRAFANA_URL}/api/health" > /dev/null 2>&1; then
    break
  fi
  echo "  Waiting for Grafana... (${i}/20)"
  sleep 5
done

for dashboard_file in "${DASHBOARD_DIR}"/*.json; do
  [ -f "${dashboard_file}" ] || continue
  [ "$(basename ${dashboard_file})" = "generate-dashboards.py" ] && continue

  name=$(basename "${dashboard_file}")
  echo -n "  Importing ${name}... "

  payload=$(python3 -c "
import json, sys
with open('${dashboard_file}') as f:
    d = json.load(f)
print(json.dumps({'dashboard': d, 'overwrite': True, 'folderId': 0}))
")

  status=$(curl -sf -X POST \
    -H "Content-Type: application/json" \
    -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
    "${GRAFANA_URL}/api/dashboards/db" \
    -d "${payload}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))")

  echo "${status}"
done

echo
echo "=== Done. Open ${GRAFANA_URL} ==="
