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
                ("Slurm / Job", "job-queue"),
                ("GPU Peer", "gpu-peer"),
                ("EFA/NVLink", "efa-nvlink"),
                ("Host System", "host-system"),
                ("Z-Score", "zscore"),
                ("Node Status", "node-status"),

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
    # use regex match to handle compound states (e.g. down~ = down+cloud)
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
        "targets": [{"expr": f'sum(slurm_node_count_per_state{{state=~"{state}.*"}}) or vector(0)', "legendFormat": " ", "refId": "A", "instant": True}],
        "fieldConfig": {"defaults": {"unit": "none", "thresholds": th, "noValue": "0"}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "textMode": "auto", "orientation": "auto", "justifyMode": "center"}
    }

d0_panels = [
    # ── Row 0 (y=0): 한줄 요약 — Healthy / Problem / Total / CPU / Load ──
    {
        "id": 50, "title": "🟢 Healthy Nodes",
        "description": "idle + allocated + mixed + completing + planned",
        "type": "stat",
        "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0},
        "targets": [{"expr": 'sum(slurm_node_count_per_state{state=~"idle.*|allocated.*|mixed.*|completing.*|planned.*"}) or vector(0)', "legendFormat": " ", "refId": "A", "instant": True}],
        "fieldConfig": {"defaults": {"unit": "none", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]}, "noValue": "0"}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "textMode": "auto", "justifyMode": "center"},
    },
    {
        "id": 51, "title": "🔴 Problem Nodes",
        "description": "down + fail + not_responding + drained + draining + maint + inval",
        "type": "stat",
        "gridPos": {"h": 4, "w": 6, "x": 6, "y": 0},
        "targets": [{"expr": 'sum(slurm_node_count_per_state{state=~"down.*|fail.*|not_responding.*|drained.*|draining.*|maint.*|inval.*"}) or vector(0)', "legendFormat": " ", "refId": "A", "instant": True}],
        "fieldConfig": {"defaults": {"unit": "none", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 1}]}, "noValue": "0"}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "textMode": "auto", "justifyMode": "center"},
    },
    stat(52, "Total Nodes",   'sum(slurm_node_count_per_state)',  "none",  x=12, y=0, w=4, h=4),
    stat(53, "CPU Idle Cores",'slurm_cpus_idle',                  "none",  x=16, y=0, w=4, h=4),
    stat(54, "Cluster Load",  'slurm_cpu_load',                   "short", x=20, y=0, w=4, h=4),

    # ── Row 1 (y=4): Node State History + Node Utilization ──
    {
        "id": 30, "title": "Node State History",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 14, "x": 0, "y": 4},
        "targets": [
            {"expr": 'slurm_node_count_per_state', "legendFormat": "{{state}}", "refId": "A"},
        ],
        "fieldConfig": {
            "defaults": {"unit": "none", "custom": {"lineWidth": 1, "fillOpacity": 20, "stacking": {"mode": "normal"}}},
            "overrides": []
        },
        "options": {"tooltip": {"mode": "multi"}, "legend": {"displayMode": "list", "placement": "bottom"}}
    },
    {
        "id": 21, "title": "Node Utilization (Active vs Total)",
        "description": "Active = ALLOCATED + MIXED + COMPLETING. Gap = idle capacity.",
        "type": "timeseries",
        "gridPos": {"h": 8, "w": 10, "x": 14, "y": 4},
        "targets": [
            {"expr": 'sum(slurm_node_count_per_state)', "legendFormat": "Total nodes", "refId": "A"},
            {"expr": 'sum(slurm_node_count_per_state{state=~"allocated.*|mixed.*|completing.*"})', "legendFormat": "Active nodes", "refId": "B"},
        ],
        "fieldConfig": {
            "defaults": {"unit": "none", "custom": {"lineWidth": 2, "fillOpacity": 5}},
            "overrides": []
        },
        "options": {"tooltip": {"mode": "multi"}, "legend": {"displayMode": "list", "placement": "bottom"}}
    },

    # ── Row 2 (y=12): GPU ──
    ts(22, "GPU Utilization per Node (%)",
       [t('avg by (node_name) (DCGM_FI_DEV_GPU_UTIL)', "{{node_name}}")],
       unit="percent", x=0, y=12, w=8, h=7),
    ts(23, "GPU Temp Max per Node (°C)",
       [t('max by (node_name) (DCGM_FI_DEV_GPU_TEMP)', "{{node_name}}")],
       unit="celsius", x=8, y=12, w=8, h=7),
    ts(24, "GPU Memory Used per Node (MiB)",
       [t('sum by (node_name) (DCGM_FI_DEV_FB_USED)', "{{node_name}}")],
       unit="decmbytes", x=16, y=12, w=8, h=7),

    # ── Row 3 (y=19): EFA + CPU ──
    ts(25, "EFA RX Bandwidth per Node (MB/s)",
       [t('sum by (node_name) (rate(node_efa_hw_rx_bytes[1m])) / 1e6', "{{node_name}}")],
       unit="MBs", x=0, y=19, w=8, h=7),
    ts(26, "EFA TX Bandwidth per Node (MB/s)",
       [t('sum by (node_name) (rate(node_efa_hw_tx_bytes[1m])) / 1e6', "{{node_name}}")],
       unit="MBs", x=8, y=19, w=8, h=7),
    ts(27, "CPU Utilization per Node (%)",
       [t('100 - (avg by (node_name) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)', "{{node_name}}")],
       unit="percent", x=16, y=19, w=8, h=7),

    # ── Row 4 (y=26): Memory + Storage + GPU Faults ──
    ts(28, "Memory Usage per Node (GiB)",
       [t('avg by (node_name) (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / 1073741824', "{{node_name}}")],
       unit="bytes", x=0, y=26, w=8, h=7),
    ts(29, "Storage I/O (MiB/s)",
       [t('sum by (node_name) (rate(node_disk_read_bytes_total{device=~"nvme.*"}[5m])) / 1048576', "{{node_name}} read"),
        t('sum by (node_name) (rate(node_disk_written_bytes_total{device=~"nvme.*"}[5m])) / 1048576', "{{node_name}} write")],
       unit="MBs", x=8, y=26, w=8, h=7),
    ts(30, "GPU Hardware Faults (ECC / Remap)",
       [t('max by (node_name) (DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS)', "{{node_name}} uncorrectable"),
        t('max by (node_name) (DCGM_FI_DEV_ROW_REMAP_FAILURE)', "{{node_name}} remap_fail")],
       unit="short", x=16, y=26, w=8, h=7),
]

# ── 1. Cluster Overview — GPU/EFA anomaly detection ───────────────────────────
d1_panels = [
    ts(1, "GPU Temp Max (°C)",
       [t('max by (node_name) (DCGM_FI_DEV_GPU_TEMP)', "{{node_name}}")],
       unit="celsius", x=0, y=0, w=12, h=8),
    ts(2, "SM Clock (MHz)",
       [t('avg by (node_name) (DCGM_FI_DEV_SM_CLOCK)', "{{node_name}}")],
       unit="short", x=12, y=0, w=12, h=8),
    ts(3, "XID Errors",
       [t('max by (node_name) (DCGM_FI_DEV_UNCORRECTABLE_REMAPPED_ROWS)', "{{node_name}} uncorrectable")],
       unit="short", x=0, y=8, w=12, h=7),
    ts(4, "EFA RX Errors",
       [t('sum by (node_name) (rate(node_efa_hw_rx_drops[5m]))', "{{node_name}}")],
       unit="short", x=12, y=8, w=12, h=7),
]

# ── 2. Slurm / Job ────────────────────────────────────────────────────────────
d2_panels = [
    # ── Row 1: Slurm node/cpu stats ──
    {
        "id": 50, "title": "🟢 Healthy Nodes",
        "type": "stat",
        "gridPos": {"h": 3, "w": 4, "x": 0, "y": 0},
        "targets": [{"expr": 'sum(slurm_node_count_per_state{state=~"idle.*|allocated.*|mixed.*|completing.*|planned.*"}) or vector(0)', "legendFormat": " ", "refId": "A", "instant": True}],
        "fieldConfig": {"defaults": {"unit": "none", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]}, "noValue": "0"}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "textMode": "auto", "justifyMode": "center"},
    },
    {
        "id": 51, "title": "🔴 Problem Nodes",
        "type": "stat",
        "gridPos": {"h": 3, "w": 4, "x": 4, "y": 0},
        "targets": [{"expr": 'sum(slurm_node_count_per_state{state=~"down.*|fail.*|not_responding.*|drained.*|draining.*|maint.*|inval.*"}) or vector(0)', "legendFormat": " ", "refId": "A", "instant": True}],
        "fieldConfig": {"defaults": {"unit": "none", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 1}]}, "noValue": "0"}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "textMode": "auto", "justifyMode": "center"},
    },
    stat(1, "Nodes Idle",      'sum(slurm_node_count_per_state{state=~"idle.*"}) or vector(0)',      "none", x=8,  y=0, w=3, h=3),
    stat(2, "Nodes Allocated", 'sum(slurm_node_count_per_state{state=~"allocated.*"}) or vector(0)', "none", x=11, y=0, w=3, h=3),
    stat(3, "CPU Idle Cores",  'slurm_cpus_idle or vector(0)',                                       "none", x=14, y=0, w=4, h=3),
    stat(4, "CPUs Allocated",  'sum(slurm_cpus_per_state{state=~"allocated.*"}) or vector(0)',       "none", x=18, y=0, w=3, h=3),
    stat(5, "Cluster Load",    'slurm_cpu_load',                                                     "short",x=21, y=0, w=3, h=3),
    ts(6, "Node Count by State",
       [t('slurm_node_count_per_state', "{{state}}")],
       unit="none", x=0, y=3, w=12, h=8),
    ts(7, "CPU Allocation",
       [t('slurm_cpus_per_state', "{{state}}")],
       unit="none", x=12, y=3, w=12, h=8),
    ts(8, "Memory Allocated vs Free (GB)",
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

# ── 8. Node Status ───────────────────────────────────────────────────────────
d8_panels = [
    # ── Row 1: Summary stats ──
    {
        "id": 50, "title": "🟢 Healthy Nodes",
        "type": "stat",
        "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0},
        "targets": [{"expr": 'sum(slurm_node_count_per_state{state=~"idle.*|allocated.*|mixed.*|completing.*|planned.*"}) or vector(0)', "legendFormat": " ", "refId": "A", "instant": True}],
        "fieldConfig": {"defaults": {"unit": "none", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]}, "noValue": "0"}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "textMode": "auto", "justifyMode": "center"},
    },
    {
        "id": 51, "title": "🔴 Problem Nodes",
        "type": "stat",
        "gridPos": {"h": 4, "w": 6, "x": 6, "y": 0},
        "targets": [{"expr": 'sum(slurm_node_count_per_state{state=~"down.*|fail.*|not_responding.*|drained.*|draining.*|maint.*|inval.*"}) or vector(0)', "legendFormat": " ", "refId": "A", "instant": True}],
        "fieldConfig": {"defaults": {"unit": "none", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 1}]}, "noValue": "0"}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background", "textMode": "auto", "justifyMode": "center"},
    },
    stat(52, "Total Nodes",  'sum(slurm_node_count_per_state)', "none",  x=12, y=0, w=4, h=4),
    stat(53, "Down",         'sum(slurm_node_count_per_state{state=~"down.*"}) or vector(0)', "none", x=16, y=0, w=2, h=4,
         thresholds={"mode":"absolute","steps":[{"color":"green","value":None},{"color":"red","value":1}]}),
    stat(54, "Drained",      'sum(slurm_node_count_per_state{state=~"drained.*"}) or vector(0)', "none", x=18, y=0, w=2, h=4,
         thresholds={"mode":"absolute","steps":[{"color":"green","value":None},{"color":"orange","value":1}]}),
    stat(55, "Not Responding",'sum(slurm_node_count_per_state{state=~"not_responding.*"}) or vector(0)', "none", x=20, y=0, w=2, h=4,
         thresholds={"mode":"absolute","steps":[{"color":"green","value":None},{"color":"red","value":1}]}),
    stat(56, "Draining",     'sum(slurm_node_count_per_state{state=~"draining.*"}) or vector(0)', "none", x=22, y=0, w=2, h=4,
         thresholds={"mode":"absolute","steps":[{"color":"green","value":None},{"color":"yellow","value":1}]}),

    # ── Row 2: Node State Over Time stacked area (full width, tall) ──
    {
        "id": 60, "title": "Node State Over Time",
        "type": "timeseries",
        "gridPos": {"h": 10, "w": 24, "x": 0, "y": 4},
        "targets": [
            {"expr": 'slurm_node_count_per_state{state=~"idle.*|allocated.*|mixed.*|completing.*|planned.*"}', "legendFormat": "{{state}}", "refId": "A"},
            {"expr": 'slurm_node_count_per_state{state=~"down.*|fail.*|not_responding.*|drained.*|draining.*|maint.*"}', "legendFormat": "{{state}}", "refId": "B"},
            {"expr": 'slurm_node_count_per_state{state=~"powering_up.*|powering_down.*|powered_down.*|reboot.*"}', "legendFormat": "{{state}}", "refId": "C"},
        ],
        "fieldConfig": {
            "defaults": {"unit": "none", "custom": {"lineWidth": 1, "fillOpacity": 20, "stacking": {"mode": "normal"}}},
            "overrides": [
                {"matcher": {"id": "byName", "options": "idle"},    "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#73BF69"}}]},
                {"matcher": {"id": "byName", "options": "allocated"},"properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#5794F2"}}]},
                {"matcher": {"id": "byName", "options": "down"},    "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#F2495C"}}]},
                {"matcher": {"id": "byName", "options": "drained"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#FF9830"}}]},
                {"matcher": {"id": "byName", "options": "draining"},"properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#FF780A"}}]},
                {"matcher": {"id": "byName", "options": "not_responding"}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": "#E02F44"}}]},
            ],
        },
        "options": {"tooltip": {"mode": "multi"}, "legend": {"displayMode": "table", "placement": "right"}},
    },

    # ── Row 3: Node Status History table (full width, very tall) ──
    {
        "id": 11,
        "title": "Node Status History",
        "type": "table",
        "gridPos": {"h": 20, "w": 24, "x": 0, "y": 14},
        "targets": [
            {
                "expr": 'last_over_time(slurm_node_state_reason[2m]) == 1',
                "instant": False,
                "refId": "A",
                "legendFormat": "{{node}}",
            }
        ],
        "transformations": [
            {"id": "labelsToFields", "options": {"mode": "columns"}},
            {
                "id": "organize",
                "options": {
                    "excludeByName": {
                        "Time": True, "Value": True, "__name__": True,
                        "instance": True, "job": True, "node_type": True,
                        "node_name": True,
                    },
                    "renameByName": {"node": "Node", "state": "State", "reason": "Reason"},
                    "indexByName": {"node": 0, "state": 1, "reason": 2},
                }
            },
            {"id": "sortBy", "options": {"fields": [{"desc": True, "displayName": "State"}]}},
        ],
        "fieldConfig": {
            "defaults": {"custom": {"displayMode": "auto", "filterable": True, "minWidth": 150}},
            "overrides": [
                {
                    "matcher": {"id": "byName", "options": "State"},
                    "properties": [
                        {"id": "custom.displayMode", "value": "color-background"},
                        {"id": "custom.width", "value": 160},
                        {"id": "mappings", "value": [
                            {"type": "value", "options": {"down":         {"color": "#F2495C", "index": 0}}},
                            {"type": "value", "options": {"not_responding":{"color": "#E02F44", "index": 1}}},
                            {"type": "value", "options": {"fail":         {"color": "#F2495C", "index": 2}}},
                            {"type": "value", "options": {"drained":      {"color": "#FF9830", "index": 3}}},
                            {"type": "value", "options": {"draining":     {"color": "#FF780A", "index": 4}}},
                            {"type": "value", "options": {"maint":        {"color": "#FADE2A", "index": 5}}},
                            {"type": "value", "options": {"allocated":    {"color": "#5794F2", "index": 6}}},
                            {"type": "value", "options": {"idle":         {"color": "#73BF69", "index": 7}}},
                        ]},
                    ],
                },
                {"matcher": {"id": "byName", "options": "Node"},   "properties": [{"id": "custom.width", "value": 260}]},
                {"matcher": {"id": "byName", "options": "Reason"}, "properties": [{"id": "custom.displayMode", "value": "auto"}]},
            ],
        },
        "options": {"sortBy": [{"desc": True, "displayName": "State"}], "footer": {"show": False}, "showHeader": True},
    },
]

# ── Save all dashboards ────────────────────────────────────────────────────────
dashboards = [
    ("00-overview.json",
     dash("p6-overview", "0. Unified Overview", d0_panels)),
    ("01-cluster-overview.json",
     dash("p6-cluster-overview", "1. Cluster Overview", d1_panels)),
    ("02-job-queue.json",
     dash("p6-job-queue", "2. Slurm / Job", d2_panels)),
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
    ("08-node-status.json",
     dash("p6-node-status", "8. Node Status", d8_panels)),
]

for fname, d in dashboards:
    path = os.path.join(OUT_DIR, fname)
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
    print(f"  wrote {fname}")

print(f"\nDone. {len(dashboards)} dashboards in {OUT_DIR}/")
