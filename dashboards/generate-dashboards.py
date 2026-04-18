#!/usr/bin/env python3
"""Generate Grafana dashboard JSON files for AWS GPU Cluster monitoring.

Metric name mapping (verified on live cluster):
  slurm: slurm_node_count_per_state{state=}, slurm_cpus_idle, slurm_cpus_per_state{state=},
         slurm_cpus_total, slurm_mem_alloc, slurm_mem_free, slurm_mem_real,
         slurm_cpu_load, slurm_partition_*
  DCGM:  DCGM_FI_DEV_SM_CLOCK, DCGM_FI_DEV_MEM_CLOCK, DCGM_FI_DEV_GPU_TEMP,
         DCGM_FI_DEV_POWER_USAGE, DCGM_FI_DEV_GPU_UTIL, DCGM_FI_DEV_MEM_COPY_UTIL,
         DCGM_FI_DEV_FB_USED, DCGM_FI_DEV_FB_FREE, DCGM_FI_DEV_XID_ERRORS,
         DCGM_FI_DEV_ECC_SBE_VOL_TOTAL, DCGM_FI_DEV_ECC_DBE_VOL_TOTAL
  EFA:   node_efa_hw_rx_bytes, node_efa_hw_tx_bytes, node_efa_hw_rx_pkts,
         node_efa_hw_tx_pkts, node_efa_hw_retrans_pkts, node_efa_hw_rx_drops
  node:  node_cpu_seconds_total, node_memory_MemTotal_bytes, node_memory_MemAvailable_bytes,
         node_disk_read_bytes_total, node_disk_written_bytes_total,
         node_pressure_cpu_waiting_seconds_total, node_pressure_io_stalled_seconds_total
"""
import json, os

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

def ts(id, title, targets, unit="short", x=0, y=0, w=12, h=8):
    for i, tgt in enumerate(targets):
        tgt["refId"] = "ABCDEFGHIJ"[i]
    return {
        "id": id, "title": title, "type": "timeseries",
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": targets,
        "fieldConfig": {
            "defaults": {"unit": unit, "custom": {"lineWidth": 1, "fillOpacity": 5}},
            "overrides": []
        },
        "options": {"tooltip": {"mode": "multi"}, "legend": {"displayMode": "table", "placement": "bottom"}}
    }

def stat(id, title, expr, unit="short", x=0, y=0, w=4, h=3, thresholds=None):
    th = thresholds or {"mode": "absolute", "steps": [{"color": "green", "value": None}]}
    return {
        "id": id, "title": title, "type": "stat",
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"expr": expr, "legendFormat": " ", "refId": "A"}],
        "fieldConfig": {"defaults": {"unit": unit, "thresholds": th}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "textMode": "auto"}
    }

def tbl(id, title, targets, x=0, y=0, w=24, h=10):
    return {
        "id": id, "title": title, "type": "table",
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": targets,
        "fieldConfig": {"defaults": {}, "overrides": []},
        "options": {"sortBy": [], "footer": {"show": False}}
    }

def t(expr, legend="", ref="A"):
    return {"expr": expr, "legendFormat": legend, "refId": ref}

def dash(uid, title, panels, tags=None, variables=None):
    return {
        "uid": uid, "title": title,
        "schemaVersion": 39, "version": 1,
        "refresh": "30s",
        "time": {"from": "now-1h", "to": "now"},
        "timezone": "browser",
        "tags": tags or ["gpu-cluster", "parallelcluster"],
        "panels": panels,
        "templating": {"list": variables or []},
        "annotations": {"list": []},
        "links": [
            {"title": d, "url": f"/d/p6-{slug}", "type": "link", "targetBlank": False}
            for d, slug in [
                ("Overview", "overview"),
                ("Cluster", "cluster-overview"),
                ("Job Queue", "job-queue"),
                ("GPU Peer", "gpu-peer"),
                ("EFA/NVLink", "efa-nvlink"),
                ("Host System", "host-system"),
                ("Z-Score", "zscore"),
            ]
        ]
    }


# ── 0. Unified Overview ────────────────────────────────────────────────────────
# PCS-style Slurm node state overview + full GPU/EFA/CPU metrics

def green_stat(id, title, expr, x, y, w=3, h=2):
    return stat(id, title, expr, "none", x=x, y=y, w=w, h=h)

def red_stat(id, title, expr, x, y, w=3, h=2):
    return stat(id, title, expr, "none", x=x, y=y, w=w, h=h,
        thresholds={"mode":"absolute","steps":[{"color":"green","value":None},{"color":"red","value":1}]})

def yellow_stat(id, title, expr, x, y, w=3, h=2):
    return stat(id, title, expr, "none", x=x, y=y, w=w, h=h,
        thresholds={"mode":"absolute","steps":[{"color":"green","value":None},{"color":"yellow","value":1}]})

def node_stat(id, title, state, color, x, y, w=3, h=3):
    # green=healthy, red=problem, yellow=warning, blue=other
    # show value regardless of 0; color only activates when >0 (except green)
    if color == "green":
        th = {"mode": "absolute", "steps": [{"color": "green", "value": None}]}
    elif color == "red":
        th = {"mode": "absolute", "steps": [{"color": "transparent", "value": None}, {"color": "red", "value": 1}]}
    elif color == "yellow":
        th = {"mode": "absolute", "steps": [{"color": "transparent", "value": None}, {"color": "yellow", "value": 1}]}
    else:
        th = {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}
    return {
        "id": id, "title": title, "type": "stat",
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [{"expr": f'slurm_node_count_per_state{{state="{state}"}}', "legendFormat": " ", "refId": "A", "instant": True}],
        "fieldConfig": {"defaults": {"unit": "none", "thresholds": th, "noValue": "0"}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "textMode": "auto", "orientation": "auto", "justifyMode": "center"}
    }

d0_panels = [
    # ── Node State Overview — 6×w=4 grid (scales to 1000+ nodes) ──
    # Row 1 (y=0): Core healthy states — 6 × w=4 = 24
    node_stat(1,  "Allocated",      "allocated",      "green",  x=0,  y=0, w=4, h=4),
    node_stat(2,  "Idle",           "idle",           "green",  x=4,  y=0, w=4, h=4),
    node_stat(3,  "Mixed",          "mixed",          "green",  x=8,  y=0, w=4, h=4),
    node_stat(4,  "Completing",     "completing",     "green",  x=12, y=0, w=4, h=4),
    stat(5,  "CPU Idle Cores", 'slurm_cpus_idle',     "none",   x=16, y=0, w=4, h=4),
    stat(6,  "Cluster Load",   'slurm_cpu_load',      "short",  x=20, y=0, w=4, h=4),
    # Row 2 (y=4): Problem + Warning + Total — 6 × w=4 = 24
    node_stat(9,  "Down",           "down",           "red",    x=0,  y=4, w=4, h=4),
    node_stat(10, "Fail / Failing", "fail",           "red",    x=4,  y=4, w=4, h=4),
    node_stat(11, "Not Responding", "not_responding", "red",    x=8,  y=4, w=4, h=4),
    node_stat(12, "Drained",        "drained",        "yellow", x=12, y=4, w=4, h=4),
    node_stat(13, "Draining",       "draining",       "yellow", x=16, y=4, w=4, h=4),
    stat(14, "Total Nodes",    'sum(slurm_node_count_per_state)', "none", x=20, y=4, w=4, h=4),
    # Row 3 (y=8): Power/other — 6 × w=4 = 24
    node_stat(40, "Maint",          "maint",          "yellow", x=0,  y=8, w=4, h=3),
    node_stat(41, "Powering Up",    "powering_up",    "blue",   x=4,  y=8, w=4, h=3),
    node_stat(42, "Powered Down",   "powered_down",   "blue",   x=8,  y=8, w=4, h=3),
    node_stat(43, "Power Down",     "power_down",     "blue",   x=12, y=8, w=4, h=3),
    node_stat(44, "Unknown",        "unknown",        "blue",   x=16, y=8, w=4, h=3),
    node_stat(45, "Planned/Reserved", "planned",      "green",  x=20, y=8, w=4, h=3),

    # ── y=9: Node State History + Node Utilization ──
    {
        "id": 30, "title": "Node State History",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 14, "x": 0, "y": 11},
        "targets": [
            {"expr": 'slurm_node_count_per_state', "legendFormat": "{{state}}", "refId": "A"},
        ],
        "fieldConfig": {
            "defaults": {"unit": "none", "custom": {"lineWidth": 1, "fillOpacity": 20, "stacking": {"mode": "normal"}}},
            "overrides": []
        },
        "options": {"tooltip": {"mode": "multi"}, "legend": {"displayMode": "list", "placement": "bottom"}}
    },

    # ── y=6: Node Utilization ──
    {
        "id": 21, "title": "Node Utilization (Active vs Total)",
        "description": "Active = ALLOCATED + MIXED + COMPLETING. Gap = idle capacity.",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 10, "x": 14, "y": 11},
        "targets": [
            {"expr": 'sum(slurm_node_count_per_state)', "legendFormat": "Total nodes", "refId": "A"},
            {"expr": 'sum(slurm_node_count_per_state{state=~"allocated|mixed|completing"})', "legendFormat": "Active nodes (alloc+mixed+completing)", "refId": "B"},
        ],
        "fieldConfig": {
            "defaults": {"unit": "none", "custom": {"lineWidth": 2, "fillOpacity": 5}},
            "overrides": []
        },
        "options": {"tooltip": {"mode": "multi"}, "legend": {"displayMode": "list", "placement": "bottom"}}
    },

    # ── Row 3: GPU ──
    ts(22, "GPU Utilization per Node (%)",
       [t('avg by (node_name) (DCGM_FI_DEV_GPU_UTIL)', "{{node_name}}")],
       unit="percent", x=0, y=19, w=8, h=7),
    ts(23, "GPU Temp Max per Node (°C)",
       [t('max by (node_name) (DCGM_FI_DEV_GPU_TEMP)', "{{node_name}}")],
       unit="celsius", x=8, y=19, w=8, h=7),
    ts(24, "GPU Memory Used per Node (MiB)",
       [t('sum by (node_name) (DCGM_FI_DEV_FB_USED)', "{{node_name}}")],
       unit="decmbytes", x=16, y=19, w=8, h=7),

    # ── Row 4: Network + CPU ──
    ts(25, "EFA RX Bandwidth per Node (MB/s)",
       [t('sum by (node_name) (rate(node_efa_hw_rx_bytes[1m])) / 1e6', "{{node_name}}")],
       unit="MBs", x=0, y=26, w=8, h=7),
    ts(26, "EFA TX Bandwidth per Node (MB/s)",
       [t('sum by (node_name) (rate(node_efa_hw_tx_bytes[1m])) / 1e6', "{{node_name}}")],
       unit="MBs", x=8, y=26, w=8, h=7),
    ts(27, "CPU Utilization per Node (%)",
       [t('100 - (avg by (node_name) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)', "{{node_name}}")],
       unit="percent", x=16, y=26, w=8, h=7),

    # ── Row 5: Memory + Storage + Faults ──
    ts(28, "Memory Usage per Node (GiB)",
       [t('avg by (node_name) (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / 1073741824', "{{node_name}}")],
       unit="bytes", x=0, y=33, w=8, h=7),
    ts(29, "Storage I/O (MiB/s)",
       [t('sum by (node_name) (rate(node_disk_read_bytes_total{device=~"nvme.*"}[5m])) / 1048576', "{{node_name}} read"),
        t('sum by (node_name) (rate(node_disk_written_bytes_total{device=~"nvme.*"}[5m])) / 1048576', "{{node_name}} write")],
       unit="MBs", x=8, y=33, w=8, h=7),
    ts(30, "GPU Hardware Faults (ECC / Remap)",
       [t('max by (node_name) (DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS)', "{{node_name}} uncorrectable"),
        t('max by (node_name) (DCGM_FI_DEV_ROW_REMAP_FAILURE)', "{{node_name}} remap_fail")],
       unit="short", x=16, y=33, w=8, h=7),
]

# ── 1. Cluster Overview ────────────────────────────────────────────────────────
d1_panels = [
    stat(1,  "Nodes Idle",      'slurm_node_count_per_state{state="idle"}',      "none", x=0,  y=0, w=4, h=3),
    stat(2,  "Nodes Allocated", 'slurm_node_count_per_state{state="allocated"}', "none", x=4,  y=0, w=4, h=3),
    stat(3,  "Nodes Down",      'slurm_node_count_per_state{state="down"}',      "none", x=8,  y=0, w=4, h=3,
         thresholds={"mode":"absolute","steps":[{"color":"green","value":None},{"color":"red","value":1}]}),
    stat(4,  "Nodes Draining",  'slurm_node_count_per_state{state="draining"}',  "none", x=12, y=0, w=4, h=3,
         thresholds={"mode":"absolute","steps":[{"color":"green","value":None},{"color":"yellow","value":1}]}),
    stat(5,  "CPU Idle Cores",       'slurm_cpus_idle',                               "none", x=16, y=0, w=4, h=3),
    stat(6,  "Cluster Load",    'slurm_cpu_load',                                "short",x=20, y=0, w=4, h=3),
    ts(7, "GPU Temp Max (°C)",
       [t('max by (node_name) (DCGM_FI_DEV_GPU_TEMP)', "{{node_name}}")],
       unit="celsius", x=0, y=3, w=12, h=8),
    ts(8, "SM Clock (MHz)",
       [t('avg by (node_name) (DCGM_FI_DEV_SM_CLOCK)', "{{node_name}}")],
       unit="short", x=12, y=3, w=12, h=8),
    ts(9, "XID Errors",
       [t('max by (node_name) (DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS)', "{{node_name}} uncorrectable")],
       unit="short", x=0, y=11, w=12, h=7),
    ts(10, "EFA RX Errors",
       [t('sum by (node_name) (rate(node_efa_hw_rx_drops[5m]))', "{{node_name}}")],
       unit="short", x=12, y=11, w=12, h=7),
    tbl(11, "Node Down / Draining Reasons",
       [t('slurm_node_state_reason{state!~"idle|allocated|mixed"} == 1', "{{node}} — {{state}}: {{reason}}")],
       x=0, y=18, w=24, h=6),
]

# ── 2. Job Queue ──────────────────────────────────────────────────────────────
d2_panels = [
    stat(1, "Nodes Idle",      'slurm_node_count_per_state{state="idle"}',      "none", x=0,  y=0, w=4, h=3),
    stat(2, "Nodes Allocated", 'slurm_node_count_per_state{state="allocated"}', "none", x=4,  y=0, w=4, h=3),
    stat(3, "Nodes Down",      'slurm_node_count_per_state{state="down"}',      "none", x=8,  y=0, w=4, h=3,
         thresholds={"mode":"absolute","steps":[{"color":"green","value":None},{"color":"red","value":1}]}),
    stat(4, "CPU Idle Cores",       'slurm_cpus_idle',                               "none", x=12, y=0, w=4, h=3),
    stat(5, "CPUs Allocated",  'slurm_cpus_per_state{state="allocated"}',       "none", x=16, y=0, w=4, h=3),
    stat(6, "Cluster Load",    'slurm_cpu_load',                                "short",x=20, y=0, w=4, h=3),
    ts(7, "Node Count by State",
       [t('slurm_node_count_per_state', "{{state}}")],
       unit="none", x=0, y=3, w=12, h=8),
    ts(8, "CPU Allocation",
       [t('slurm_cpus_per_state', "{{state}}")],
       unit="none", x=12, y=3, w=12, h=8),
    ts(9, "Memory Allocated vs Free (GB)",
       [t('slurm_mem_alloc / 1e9', "allocated"),
        t('slurm_mem_free / 1e9', "free")],
       unit="short", x=0, y=11, w=24, h=7),
]

# ── 3. Job Overview ────────────────────────────────────────────────────────────
d3_panels = [
    ts(1, "GPU Utilization per Node (%)",
       [t('avg by (node_name) (DCGM_FI_DEV_GPU_UTIL)', "{{node_name}}")],
       unit="percent", x=0, y=0, w=12, h=8),
    ts(2, "GPU Memory Used per Node (MiB)",
       [t('sum by (node_name) (DCGM_FI_DEV_FB_USED)', "{{node_name}}")],
       unit="decmbytes", x=12, y=0, w=12, h=8),
    ts(3, "GPU Temperature per Node (°C)",
       [t('max by (node_name) (DCGM_FI_DEV_GPU_TEMP)', "{{node_name}}")],
       unit="celsius", x=0, y=8, w=12, h=7),
    ts(4, "Power Usage per Node (W)",
       [t('sum by (node_name) (DCGM_FI_DEV_POWER_USAGE)', "{{node_name}}")],
       unit="watt", x=12, y=8, w=12, h=7),
]

# ── 4. GPU Peer Comparison ────────────────────────────────────────────────────
d4_panels = [
    ts(1, "GPU Utilization per Node (%)",
       [t('avg by (node_name) (DCGM_FI_DEV_GPU_UTIL)', "{{node_name}}")],
       unit="percent", x=0, y=0, w=12, h=8),
    ts(2, "GPU Memory Used per Node (MiB)",
       [t('sum by (node_name) (DCGM_FI_DEV_FB_USED)', "{{node_name}}")],
       unit="decmbytes", x=12, y=0, w=12, h=8),
    ts(3, "GPU Temp per Node (°C)",
       [t('max by (node_name) (DCGM_FI_DEV_GPU_TEMP)', "{{node_name}}")],
       unit="celsius", x=0, y=8, w=12, h=8),
    ts(4, "Power Usage per Node (W)",
       [t('sum by (node_name) (DCGM_FI_DEV_POWER_USAGE)', "{{node_name}}")],
       unit="watt", x=12, y=8, w=12, h=8),
    ts(5, "GPU Hardware Faults (ECC Remapped Rows / Row Remap Failure)",
       [t('max by (node_name) (DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS)', "{{node_name}} uncorrectable"),
        t('max by (node_name) (DCGM_FI_DEV_ROW_REMAP_FAILURE)', "{{node_name}} remap_fail")],
       unit="short", x=0, y=16, w=24, h=7),
]

# ── 5. Inter-Node Communication — EFA & NVLink ────────────────────────────────
d5_panels = [
    ts(1, "EFA RX Bandwidth per Node (MB/s)",
       [t('sum by (node_name) (rate(node_efa_hw_rx_bytes[1m])) / 1e6', "{{node_name}}")],
       unit="MBs", x=0, y=0, w=12, h=8),
    ts(2, "EFA TX Bandwidth per Node (MB/s)",
       [t('sum by (node_name) (rate(node_efa_hw_tx_bytes[1m])) / 1e6', "{{node_name}}")],
       unit="MBs", x=12, y=0, w=12, h=8),
    ts(3, "EFA Retransmits per Node",
       [t('sum by (node_name) (rate(node_efa_hw_retrans_pkts[5m]))', "{{node_name}}")],
       unit="short", x=0, y=8, w=8, h=7),
    ts(4, "EFA RX Drops per Node",
       [t('sum by (node_name) (rate(node_efa_hw_rx_drops[5m]))', "{{node_name}}")],
       unit="short", x=8, y=8, w=8, h=7),
    ts(5, "EFA RDMA Write Bytes per Node (MB/s)",
       [t('sum by (node_name) (rate(node_efa_hw_rdma_write_bytes[1m])) / 1e6', "{{node_name}}")],
       unit="MBs", x=16, y=8, w=8, h=7),
]

# ── 6. Host System ─────────────────────────────────────────────────────────────
d6_panels = [
    ts(1, "CPU Utilization per Node (%)",
       [t('100 - (avg by (node_name) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)', "{{node_name}}")],
       unit="percent", x=0, y=0, w=12, h=8),
    ts(2, "Memory Usage per Node (GiB)",
       [t('avg by (node_name) (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / 1073741824', "{{node_name}}")],
       unit="bytes", x=12, y=0, w=12, h=8),
    ts(3, "IO Pressure Stall (%)",
       [t('sum by (node_name) (rate(node_pressure_io_stalled_seconds_total[5m])) * 100', "{{node_name}}")],
       unit="percent", x=0, y=8, w=8, h=7),
    ts(4, "CPU Pressure Stall (%)",
       [t('sum by (node_name) (rate(node_pressure_cpu_waiting_seconds_total[5m])) * 100', "{{node_name}}")],
       unit="percent", x=8, y=8, w=8, h=7),
    ts(5, "Storage I/O (MiB/s)",
       [t('sum by (node_name) (rate(node_disk_read_bytes_total{device=~"nvme.*"}[5m])) / 1048576', "{{node_name}} read"),
        t('sum by (node_name) (rate(node_disk_written_bytes_total{device=~"nvme.*"}[5m])) / 1048576', "{{node_name}} write")],
       unit="MBs", x=16, y=8, w=8, h=7),
]

# ── 7. Z-Score Outlier Detection ──────────────────────────────────────────────
d7_panels = [
    ts(1, "GPU Utilization Z-Score (outlier = |z| > 2)",
       [t('(avg by (node_name) (DCGM_FI_DEV_GPU_UTIL) - scalar(avg(avg by (node_name) (DCGM_FI_DEV_GPU_UTIL)))) / (scalar(stddev(avg by (node_name) (DCGM_FI_DEV_GPU_UTIL))) + 0.0001)', "{{node_name}}")],
       unit="short", x=0, y=0, w=24, h=8),
    ts(2, "EFA RX Bandwidth Z-Score",
       [t('(sum by (node_name) (rate(node_efa_hw_rx_bytes[1m])) - scalar(avg(sum by (node_name) (rate(node_efa_hw_rx_bytes[1m]))))) / (scalar(stddev(sum by (node_name) (rate(node_efa_hw_rx_bytes[1m])))) + 0.0001)', "{{node_name}}")],
       unit="short", x=0, y=8, w=24, h=8),
    ts(3, "CPU Utilization Z-Score",
       [t('(avg by (node_name) (rate(node_cpu_seconds_total{mode!="idle"}[5m])) - scalar(avg(avg by (node_name) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))))) / (scalar(stddev(avg by (node_name) (rate(node_cpu_seconds_total{mode!="idle"}[5m])))) + 0.0001)', "{{node_name}}")],
       unit="short", x=0, y=16, w=24, h=8),
]

# ── Save all dashboards ────────────────────────────────────────────────────────
dashboards = [
    ("00-overview.json",
     dash("p6-overview", "0. Unified Overview", d0_panels)),
    ("01-cluster-overview.json",
     dash("p6-cluster-overview", "1. Cluster Overview", d1_panels)),
    ("02-job-queue.json",
     dash("p6-job-queue", "2. Job Queue", d2_panels)),
    ("03-job-overview.json",
     dash("p6-job-overview", "3. Job Overview", d3_panels)),
    ("04-gpu-peer-comparison.json",
     dash("p6-gpu-peer", "4. GPU Status — Peer Comparison", d4_panels)),
    ("05-efa-nvlink.json",
     dash("p6-efa-nvlink", "5. Inter-Node Communication — EFA & NVLink", d5_panels)),
    ("06-host-system.json",
     dash("p6-host-system", "6. Host System — CPU / Memory / PSI", d6_panels)),
    ("07-z-score-outlier.json",
     dash("p6-zscore", "7. Peer Outlier Detection — Z-Score", d7_panels)),
]

for fname, d in dashboards:
    path = os.path.join(OUT_DIR, fname)
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
    print(f"  wrote {fname}")

print(f"\nDone. {len(dashboards)} dashboards in {OUT_DIR}/")
