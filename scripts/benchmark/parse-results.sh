#!/bin/bash
# parse-results.sh — Parse Megatron-Bridge training logs → CSV
# Usage: bash parse-results.sh <EXP_DIR> [--warmup 10]
set -euo pipefail

EXP_DIR="${1:?Usage: parse-results.sh <EXP_DIR> [--warmup 10]}"
WARMUP_STEPS="${2:-10}"   # skip first N steps (JIT / warmup noise)
OUTPUT_CSV="${EXP_DIR}/results.csv"
SUMMARY_JSON="${EXP_DIR}/summary.json"

echo "=== Parsing results from ${EXP_DIR} ==="

# Collect rank 0 log (primary metrics)
RANK0_LOG=$(ls "${EXP_DIR}/logs/rank_0.log" 2>/dev/null || ls "${EXP_DIR}/outputs/"*.out 2>/dev/null | head -1)

if [ -z "${RANK0_LOG}" ]; then
  echo "ERROR: No log files found in ${EXP_DIR}/logs/ or outputs/"
  exit 1
fi

echo "  Source log: ${RANK0_LOG}"

# Extract metrics — Megatron-Bridge format:
# iteration X/Y | consumed_samples: Z | elapsed_time_per_iteration_ms: A | ...
# throughput: B tokens/s | tflops: C | mfu: D
python3 - "${RANK0_LOG}" "${OUTPUT_CSV}" "${WARMUP_STEPS}" "${SUMMARY_JSON}" << 'PYEOF'
import sys, re, json, csv
from statistics import mean, stdev

log_path, csv_path, warmup, summary_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]

rows = []
patterns = {
    'iteration':    r'iteration\s+(\d+)',
    'elapsed_ms':   r'elapsed_time_per_iteration_ms:\s*([\d.]+)',
    'tokens_sec':   r'throughput[^:]*:\s*([\d.]+)\s*tokens.?s',
    'tflops':       r'tflops[_\s]*per[_\s]*gpu:\s*([\d.]+)',
    'mfu':          r'mfu:\s*([\d.]+)',
    'loss':         r'loss:\s*([\d.]+)',
}

with open(log_path) as f:
    current = {}
    for line in f:
        for key, pat in patterns.items():
            m = re.search(pat, line, re.IGNORECASE)
            if m:
                current[key] = float(m.group(1))
        if 'iteration' in current and 'elapsed_ms' in current:
            rows.append(dict(current))
            current = {}

if not rows:
    print("WARNING: No metric rows found. Check log format.")
    sys.exit(0)

# Write CSV
fieldnames = ['iteration','elapsed_ms','tokens_sec','tflops','mfu','loss']
with open(csv_path, 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction='ignore')
    w.writeheader()
    w.writerows(rows)

print(f"  Parsed {len(rows)} steps → {csv_path}")

# Summary (exclude warmup)
valid = [r for r in rows if r.get('iteration',0) > warmup]
if valid:
    def safe_mean(key):
        vals = [r[key] for r in valid if key in r]
        return mean(vals) if vals else None
    def safe_stdev(key):
        vals = [r[key] for r in valid if key in r]
        return stdev(vals) if len(vals) > 1 else 0

    summary = {
        'total_steps': len(rows),
        'analyzed_steps': len(valid),
        'warmup_steps': warmup,
        'avg_tokens_sec':  safe_mean('tokens_sec'),
        'avg_tflops_gpu':  safe_mean('tflops'),
        'avg_mfu':         safe_mean('mfu'),
        'avg_step_ms':     safe_mean('elapsed_ms'),
        'std_step_ms':     safe_stdev('elapsed_ms'),
        'avg_loss':        safe_mean('loss'),
    }

    with open(summary_path, 'w') as f:
        json.dump(summary, f, indent=2)

    print(f"\n  === Summary (steps {warmup+1}+) ===")
    print(f"  Avg tokens/sec  : {summary['avg_tokens_sec']:,.0f}" if summary['avg_tokens_sec'] else "  Avg tokens/sec  : N/A")
    print(f"  Avg TFLOPS/GPU  : {summary['avg_tflops_gpu']:.1f}" if summary['avg_tflops_gpu'] else "  Avg TFLOPS/GPU  : N/A")
    print(f"  Avg MFU         : {summary['avg_mfu']:.3f}" if summary['avg_mfu'] else "  Avg MFU         : N/A")
    print(f"  Avg step time   : {summary['avg_step_ms']:.1f} ms ± {summary['std_step_ms']:.1f}" if summary['avg_step_ms'] else "  Avg step time   : N/A")
    print(f"  Summary JSON    : {summary_path}")
PYEOF
