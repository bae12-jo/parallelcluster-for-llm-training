#!/bin/bash
export PATH=/opt/slurm/bin:$PATH
OUTFILE="/var/lib/node_exporter/textfile/slurm_node_reason.prom"
TMPFILE="${OUTFILE}.tmp"
> "${TMPFILE}"
scontrol show node -o 2>/dev/null | while read -r line; do
  NODE=$(echo "$line" | grep -oP 'NodeName=\K\S+')
  STATE=$(echo "$line" | grep -oP 'State=\K\S+')
  REASON=$(echo "$line" | grep -oP 'Reason=\K[^@\n]+' | sed 's/[[:space:]]*$//' | tr -d '"\\')
  [ -z "$NODE" ] && continue
  STATE_CLEAN=$(echo "$STATE" | tr '[:upper:]' '[:lower:]' | tr -d '*+~#$')
  REASON_CLEAN=$(echo "$REASON" | sed 's/[^a-zA-Z0-9 ._:-]//g' | cut -c1-128)
  echo "slurm_node_state_reason{node=\"${NODE}\",state=\"${STATE_CLEAN}\",reason=\"${REASON_CLEAN}\"} 1" >> "${TMPFILE}"
done
mv "${TMPFILE}" "${OUTFILE}" 2>/dev/null || true
