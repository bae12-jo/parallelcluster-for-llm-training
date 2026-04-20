#!/usr/bin/env python3
"""
visualize-results.py — DeepSeek-V3 mbridge benchmark visualization
Usage: python3 visualize-results.py <EXP_DIR> [EXP_DIR2 ...]
       python3 visualize-results.py /fsx/mbridge-workload/experiments/deepseek_v3_bf16_gpus16_20260418_120000
       # Compare multiple runs (e.g. bf16 vs fp8):
       python3 visualize-results.py /fsx/.../deepseek_v3_bf16_... /fsx/.../deepseek_v3_fp8_...
"""
import sys
import os
import json
import csv
from pathlib import Path

try:
    import matplotlib.pyplot as plt
    import matplotlib.gridspec as gridspec
    import numpy as np
except ImportError:
    print("Installing matplotlib + numpy...")
    os.system("pip install -q matplotlib numpy")
    import matplotlib.pyplot as plt
    import matplotlib.gridspec as gridspec
    import numpy as np

COLORS = ['#00B4D8', '#F77F00', '#4CAF50', '#E91E63', '#9C27B0']
B200_PEAK_TFLOPS_BF16 = 4500   # B200 peak BF16 TFLOPS (per GPU, theoretical)
B200_PEAK_TFLOPS_FP8  = 9000

def load_run(exp_dir: str):
    exp_dir = Path(exp_dir)
    csv_path = exp_dir / "results.csv"
    summary_path = exp_dir / "summary.json"
    meta_path = exp_dir / "metadata.json"

    if not csv_path.exists():
        print(f"[WARN] No results.csv in {exp_dir}. Run parse-results.sh first.")
        return None

    rows = []
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            rows.append({k: float(v) for k, v in r.items() if v})

    summary = json.loads(summary_path.read_text()) if summary_path.exists() else {}
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}

    label = f"{meta.get('dtype','?').upper()} {meta.get('total_gpus','?')}GPU"
    return {"rows": rows, "summary": summary, "meta": meta, "label": label, "dir": exp_dir}


def make_figure(runs, output_path):
    n_runs = len(runs)
    fig = plt.figure(figsize=(20, 14))
    fig.patch.set_facecolor('#0F1117')

    title_dtype = " vs ".join(r["label"] for r in runs)
    fig.suptitle(f"DeepSeek-V3 671B  |  Megatron-Bridge  |  {title_dtype}",
                 fontsize=16, color='white', fontweight='bold', y=0.98)

    gs = gridspec.GridSpec(3, 3, figure=fig, hspace=0.45, wspace=0.35,
                           top=0.93, bottom=0.07, left=0.07, right=0.97)

    ax_tflops   = fig.add_subplot(gs[0, :2])   # TFLOPS/GPU over steps (wide)
    ax_mfu      = fig.add_subplot(gs[0, 2])    # MFU gauge bar
    ax_tokens   = fig.add_subplot(gs[1, :2])   # Tokens/sec over steps
    ax_steptime = fig.add_subplot(gs[1, 2])    # Step time box plot
    ax_loss     = fig.add_subplot(gs[2, :2])   # Loss curve
    ax_summary  = fig.add_subplot(gs[2, 2])    # Summary table

    for ax in [ax_tflops, ax_mfu, ax_tokens, ax_steptime, ax_loss, ax_summary]:
        ax.set_facecolor('#1A1D27')
        ax.tick_params(colors='#CCCCCC', labelsize=9)
        for sp in ax.spines.values():
            sp.set_color('#333355')

    # ---- 1. TFLOPS/GPU over steps ----
    ax_tflops.set_title("TFLOPS / GPU  (per step)", color='#AAAAEE', fontsize=11)
    for i, run in enumerate(runs):
        steps = [r['iteration'] for r in run['rows'] if 'tflops' in r]
        vals  = [r['tflops']   for r in run['rows'] if 'tflops' in r]
        if steps:
            ax_tflops.plot(steps, vals, color=COLORS[i], lw=1.5, alpha=0.85, label=run['label'])
            avg = run['summary'].get('avg_tflops_gpu')
            if avg:
                ax_tflops.axhline(avg, color=COLORS[i], lw=1, ls='--', alpha=0.6)
                ax_tflops.text(steps[-1], avg+20, f"avg {avg:.0f}", color=COLORS[i], fontsize=8)
    ax_tflops.set_xlabel("Iteration", color='#AAAAAA')
    ax_tflops.set_ylabel("TFLOPS", color='#AAAAAA')
    ax_tflops.legend(facecolor='#1A1D27', labelcolor='white', fontsize=9)
    ax_tflops.yaxis.label.set_color('#AAAAAA')

    # ---- 2. MFU bar ----
    ax_mfu.set_title("Model FLOPs Utilization", color='#AAAAEE', fontsize=11)
    labels, mfus = [], []
    for run in runs:
        mfu = run['summary'].get('avg_mfu')
        if mfu is not None:
            labels.append(run['label'])
            mfus.append(mfu * 100)
    if mfus:
        bars = ax_mfu.barh(labels, mfus, color=COLORS[:len(mfus)], alpha=0.85)
        for bar, val in zip(bars, mfus):
            ax_mfu.text(val + 0.5, bar.get_y() + bar.get_height()/2,
                        f"{val:.1f}%", va='center', color='white', fontsize=10, fontweight='bold')
        ax_mfu.set_xlim(0, 100)
        ax_mfu.axvline(50, color='#555577', lw=1, ls='--')
        ax_mfu.set_xlabel("MFU (%)", color='#AAAAAA')
    else:
        ax_mfu.text(0.5, 0.5, "MFU\nN/A", transform=ax_mfu.transAxes,
                    ha='center', va='center', color='#888888', fontsize=12)

    # ---- 3. Tokens/sec over steps ----
    ax_tokens.set_title("Tokens / Second  (throughput)", color='#AAAAEE', fontsize=11)
    for i, run in enumerate(runs):
        steps = [r['iteration'] for r in run['rows'] if 'tokens_sec' in r]
        vals  = [r['tokens_sec'] for r in run['rows'] if 'tokens_sec' in r]
        if steps:
            ax_tokens.plot(steps, vals, color=COLORS[i], lw=1.5, alpha=0.85, label=run['label'])
            avg = run['summary'].get('avg_tokens_sec')
            if avg:
                ax_tokens.axhline(avg, color=COLORS[i], lw=1, ls='--', alpha=0.6)
    ax_tokens.set_xlabel("Iteration", color='#AAAAAA')
    ax_tokens.set_ylabel("Tokens/sec", color='#AAAAAA')
    ax_tokens.legend(facecolor='#1A1D27', labelcolor='white', fontsize=9)

    # ---- 4. Step time box plot ----
    ax_steptime.set_title("Step Time Distribution (ms)", color='#AAAAEE', fontsize=11)
    data   = [[r['elapsed_ms'] for r in run['rows'] if 'elapsed_ms' in r] for run in runs]
    labels = [run['label'] for run in runs]
    if any(data):
        bp = ax_steptime.boxplot(data, labels=labels, patch_artist=True,
                                  medianprops=dict(color='white', lw=2))
        for patch, color in zip(bp['boxes'], COLORS):
            patch.set_facecolor(color)
            patch.set_alpha(0.7)
        for elem in ['whiskers','caps','fliers']:
            for line in bp[elem]:
                line.set_color('#AAAAAA')
    ax_steptime.set_ylabel("ms", color='#AAAAAA')
    ax_steptime.tick_params(axis='x', colors='#CCCCCC')

    # ---- 5. Loss curve ----
    ax_loss.set_title("Training Loss", color='#AAAAEE', fontsize=11)
    has_loss = False
    for i, run in enumerate(runs):
        steps = [r['iteration'] for r in run['rows'] if 'loss' in r]
        vals  = [r['loss']      for r in run['rows'] if 'loss' in r]
        if steps:
            ax_loss.plot(steps, vals, color=COLORS[i], lw=1.5, alpha=0.85, label=run['label'])
            has_loss = True
    if has_loss:
        ax_loss.set_xlabel("Iteration", color='#AAAAAA')
        ax_loss.set_ylabel("Loss", color='#AAAAAA')
        ax_loss.legend(facecolor='#1A1D27', labelcolor='white', fontsize=9)
    else:
        ax_loss.text(0.5, 0.5, "Loss\nN/A\n(synthetic data)", transform=ax_loss.transAxes,
                     ha='center', va='center', color='#888888', fontsize=11)

    # ---- 6. Summary table ----
    ax_summary.axis('off')
    ax_summary.set_title("Summary", color='#AAAAEE', fontsize=11)
    rows_table = []
    col_labels = ["Metric"] + [r["label"] for r in runs]

    def fmt(v, suffix=""):
        if v is None: return "N/A"
        if suffix == "K": return f"{v/1000:.1f}K"
        if suffix == "ms": return f"{v:.0f} ms"
        if suffix == "%": return f"{v*100:.1f}%"
        return f"{v:.1f}"

    metrics = [
        ("Tokens/sec",  "tokens_sec", "K"),
        ("TFLOPS/GPU",  "tflops",     ""),
        ("MFU",         "mfu",        "%"),
        ("Step (avg)",  "step_ms",    "ms"),
    ]
    key_map = {
        "tokens_sec": "avg_tokens_sec",
        "tflops":     "avg_tflops_gpu",
        "mfu":        "avg_mfu",
        "step_ms":    "avg_step_ms",
    }
    for label, key, suffix in metrics:
        row = [label]
        for run in runs:
            row.append(fmt(run['summary'].get(key_map[key]), suffix))
        rows_table.append(row)

    table = ax_summary.table(
        cellText=rows_table,
        colLabels=col_labels,
        cellLoc='center',
        loc='center',
        bbox=[0, 0.1, 1, 0.85]
    )
    table.auto_set_font_size(False)
    table.set_fontsize(9)
    for (r, c), cell in table.get_celld().items():
        cell.set_facecolor('#1A1D27' if r > 0 else '#2A2D40')
        cell.set_text_props(color='white')
        cell.set_edgecolor('#333355')

    plt.savefig(output_path, dpi=150, bbox_inches='tight',
                facecolor='#0F1117', edgecolor='none')
    print(f"  Chart saved: {output_path}")
    plt.close()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    exp_dirs = sys.argv[1:]
    runs = [load_run(d) for d in exp_dirs]
    runs = [r for r in runs if r is not None]

    if not runs:
        print("ERROR: No valid experiment directories found.")
        sys.exit(1)

    # Output next to first experiment
    out_dir = Path(runs[0]['dir'])
    out_path = out_dir / "benchmark_report.png"

    print(f"\n=== Visualizing {len(runs)} run(s) ===")
    for r in runs:
        print(f"  {r['label']} → {r['dir']}")

    make_figure(runs, out_path)
    print(f"\n=== Done ===")
    print(f"  Report : {out_path}")


if __name__ == "__main__":
    main()
