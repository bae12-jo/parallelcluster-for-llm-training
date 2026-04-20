# Self-Hosted Monitoring (Prometheus + Grafana) Guide

## Overview

Self-hosted monitoring uses Prometheus on the HeadNode to collect metrics from compute nodes and Grafana for visualization. This provides full control over retention, dashboards, and alerting.

## Architecture

```
ComputeNode 1 (GPU instances)
├── DCGM Exporter (port 9400)
│   └── GPU metrics
└── Node Exporter (port 9100)
    └── System metrics
         ↓
HeadNode Prometheus (port 9090)
├── Local storage (15-day retention)
├── Scrape interval: 15 seconds
└── Remote write to AMP (optional)
         ↓
HeadNode Grafana (port 3000)
├── Dashboards
└── Alerts
```

## Exporters

### DCGM Exporter

Collects GPU metrics from NVIDIA DCGM.

**Installation**: Automatic on GPU compute nodes via CustomActions

**Configuration**:
```bash
# Port: 9400
# Startup: Runs as systemd service
# Metrics: GPU utilization, temperature, power, memory, errors

# Verify
sudo systemctl status dcgm-exporter
curl http://localhost:9400/metrics | head -20
```

**Metrics Collected**:
- GPU utilization (0-100%)
- GPU memory used/free
- GPU temperature
- GPU power consumption
- GPU clocks (SM, memory)
- NVLINK bandwidth (H100)
- ECC errors
- PCIe statistics

### Node Exporter

Collects system and network metrics.

**Installation**: Automatic on GPU compute nodes via CustomActions

**Configuration**:
```bash
# Port: 9100
# Startup: Runs as systemd service
# Metrics: CPU, memory, disk, network, load, processes

# Verify
sudo systemctl status node-exporter
curl http://localhost:9100/metrics | head -20
```

**Metrics Collected**:
- CPU seconds (idle, user, system, iowait)
- Memory available, buffers, cached
- Disk size, available, usage
- Disk I/O reads/writes
- Network RX/TX bytes and errors
- Load average
- Process counts
- System uptime

### slurm_exporter

Collects Slurm cluster metrics.

**Installation**: Automatic on HeadNode via CustomActions

**Configuration**:
```bash
# Port: 6817
# Startup: Runs as systemd service
# Metrics: Node status, job counts, queue info

# Verify
sudo systemctl status slurm-exporter
curl http://localhost:6817/metrics | head -20
```

**Metrics Collected**:
- Node states (idle, allocated, down)
- Job counts (pending, running, failed)
- Job wait times
- Partition information
- Reservation details

## Prometheus Configuration

Prometheus scrapes metrics from exporters on compute nodes using EC2 Service Discovery.

### EC2 Service Discovery

Automatically discovers compute nodes:

```yaml
# Part of /opt/prometheus/prometheus.yml
scrape_configs:
  - job_name: 'compute-nodes'
    ec2_sd_configs:
      - region: us-east-2
        port: 9100
    relabel_configs:
      - source_labels: [__meta_ec2_instance_id]
        target_label: instance_id
      - source_labels: [__meta_ec2_tag_Name]
        target_label: node_name
```

**How it works**:
1. Prometheus queries EC2 API for instances
2. Finds instances with specific tags (e.g., ParallelCluster compute nodes)
3. Scrapes metrics from port 9100 (Node Exporter)
4. Automatically adds labels from EC2 tags

### Node Name Relabeling

Adds human-readable labels to metrics:

```yaml
relabel_configs:
  - source_labels: [__meta_ec2_tag_Name]
    target_label: node_name
  - source_labels: [__meta_ec2_instance_id]
    target_label: instance_id
```

**Result**: Metrics include `node_name` label (e.g., `gpu-nodes-compute-1`) instead of just instance ID.

## Prometheus Metrics Reference

### GPU Metrics (DCGM)

#### GPU Utilization

```promql
# GPU utilization percentage (0-100)
DCGM_FI_DEV_GPU_UTIL{gpu="0", instance_id="i-xxxxx"}

# Average across all GPUs
avg(DCGM_FI_DEV_GPU_UTIL)

# Per-node average
avg by (instance_id) (DCGM_FI_DEV_GPU_UTIL)
```

#### GPU Memory

```promql
# GPU memory used (MB)
DCGM_FI_DEV_FB_USED{gpu="0"}

# GPU memory free (MB)
DCGM_FI_DEV_FB_FREE{gpu="0"}

# Memory utilization percentage
(DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)) * 100
```

#### GPU Temperature

```promql
# GPU temperature (Celsius)
DCGM_FI_DEV_GPU_TEMP{gpu="0"}

# Maximum temperature across all GPUs
max(DCGM_FI_DEV_GPU_TEMP)

# Alert if temperature exceeds 85°C
DCGM_FI_DEV_GPU_TEMP > 85
```

#### GPU Power

```promql
# GPU power consumption (Watts)
DCGM_FI_DEV_POWER_USAGE{gpu="0"}

# Total cluster power (all GPUs)
sum(DCGM_FI_DEV_POWER_USAGE)

# 5-minute average
avg_over_time(sum(DCGM_FI_DEV_POWER_USAGE)[5m:])
```

#### NVLink Bandwidth (H100)

```promql
# NVLink bandwidth used
DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL{gpu="0"}

# Total inter-GPU bandwidth
sum(DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL)
```

### System Metrics (Node Exporter)

#### CPU Usage

```promql
# CPU seconds in each mode
node_cpu_seconds_total{mode="idle"}
node_cpu_seconds_total{mode="user"}
node_cpu_seconds_total{mode="system"}
node_cpu_seconds_total{mode="iowait"}

# CPU utilization percentage (5-minute average)
100 - (avg by (instance_id) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# I/O wait percentage (indicates disk bottleneck)
avg(rate(node_cpu_seconds_total{mode="iowait"}[5m])) * 100
```

#### Memory Usage

```promql
# Memory bytes
node_memory_MemTotal_bytes          # Total
node_memory_MemAvailable_bytes      # Available
node_memory_Buffers_bytes           # Buffers
node_memory_Cached_bytes            # Cached
node_memory_SwapTotal_bytes         # Swap total
node_memory_SwapFree_bytes          # Swap free

# Memory utilization percentage
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# Used memory (GB)
(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / 1024 / 1024 / 1024
```

#### Disk Usage

```promql
# Disk space (bytes)
node_filesystem_size_bytes{mountpoint="/"}         # Total
node_filesystem_avail_bytes{mountpoint="/"}        # Available
node_filesystem_used_bytes{mountpoint="/"}         # Used

# Disk utilization percentage
(1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})) * 100

# FSx Lustre
node_filesystem_size_bytes{mountpoint="/fsx"}
node_filesystem_avail_bytes{mountpoint="/fsx"}
```

#### Disk I/O

```promql
# I/O bytes (5-minute rate)
rate(node_disk_read_bytes_total[5m])          # Read
rate(node_disk_written_bytes_total[5m])       # Write

# I/O throughput (MB/s)
rate(node_disk_read_bytes_total[5m]) / 1024 / 1024
rate(node_disk_written_bytes_total[5m]) / 1024 / 1024

# Total I/O time
rate(node_disk_io_time_seconds_total[5m])
```

#### Network

```promql
# Network bytes (5-minute rate, eth0)
rate(node_network_receive_bytes_total{device="eth0"}[5m])      # RX
rate(node_network_transmit_bytes_total{device="eth0"}[5m])     # TX

# Network bandwidth (Mbps)
rate(node_network_receive_bytes_total{device="eth0"}[5m]) * 8 / 1000000
rate(node_network_transmit_bytes_total{device="eth0"}[5m]) * 8 / 1000000

# EFA network (p5 instances)
rate(node_network_receive_bytes_total{device=~"efa.*"}[5m])
rate(node_network_transmit_bytes_total{device=~"efa.*"}[5m])

# Network errors
node_network_receive_errs_total
node_network_transmit_errs_total
```

#### System Load

```promql
# Load average
node_load1   # 1-minute
node_load5   # 5-minute
node_load15  # 15-minute

# Load per CPU core
node_load5 / count(node_cpu_seconds_total{mode="idle"})
```

### Slurm Metrics

```promql
# Node states
slurm_node_state{node_state="idle"}          # Idle nodes
slurm_node_state{node_state="allocated"}     # Allocated nodes
slurm_node_state{node_state="down"}          # Down nodes

# Job counts
slurm_job_state{job_state="pending"}
slurm_job_state{job_state="running"}
slurm_job_state{job_state="failed"}

# Queue information
slurm_queue_info{partition="gpu"}
slurm_queue_info{partition="cpu"}
```

## Useful PromQL Queries

### Distributed Training Monitoring

#### Multi-Node GPU Utilization

```promql
# Average GPU utilization across all nodes
avg(DCGM_FI_DEV_GPU_UTIL)

# GPU utilization per node
avg by (instance_id) (DCGM_FI_DEV_GPU_UTIL)

# Standard deviation (identify imbalance)
stddev(DCGM_FI_DEV_GPU_UTIL)
```

#### Network Performance (All-Reduce Indicator)

```promql
# Network transmit rate (indicates gradient sync)
sum(rate(node_network_transmit_bytes_total[5m]))

# EFA bandwidth utilization
sum(rate(node_network_transmit_bytes_total{device=~"efa.*"}[5m])) / 3200000000  # Percentage of 3.2Tbps
```

#### Bottleneck Detection

```promql
# Nodes with low GPU utilization
DCGM_FI_DEV_GPU_UTIL < 50

# Nodes with high I/O wait (disk bottleneck)
rate(node_cpu_seconds_total{mode="iowait"}[5m]) * 100 > 20

# Nodes with memory pressure (>90% utilized)
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90
```

## Metric Retention

**Default**: 15 days local storage

**Change retention**:
```bash
# Edit Prometheus systemd service
sudo vim /etc/systemd/system/prometheus.service

# Change this line:
ExecStart=/opt/prometheus/prometheus --storage.tsdb.retention.time=30d

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart prometheus
```

**Storage impact**:
- 15 days (default): ~100 GB for 10-node cluster
- 30 days: ~200 GB
- 90 days: ~600 GB

## Grafana Configuration

Grafana on HeadNode provides dashboard visualization.

**Access**:
- URL: `http://HeadNode:3000` (VPC internal only)
- Default login: `admin / Grafana4PC!` (change immediately)

**Configure data source**:
1. Left menu → Configuration → Data Sources
2. Add Prometheus
3. URL: `http://localhost:9090`
4. Save & Test

## Troubleshooting

### Prometheus not scraping metrics

```bash
# Check Prometheus status
sudo systemctl status prometheus

# View targets
curl http://localhost:9090/api/v1/targets

# Check EC2 SD configuration
aws ec2 describe-instances --filters "Name=instance-type,Values=p5en.48xlarge"
```

### Missing metrics in Grafana

```bash
# Verify exporter is running on compute node
ssh compute-node-1
sudo systemctl status node-exporter
curl http://localhost:9100/metrics | wc -l
```

### High Prometheus disk usage

```bash
# Check TSDB size
du -sh /opt/prometheus/data/

# Reduce retention
sudo systemctl edit prometheus
# Set: --storage.tsdb.retention.time=7d
sudo systemctl restart prometheus
```

## Related Documentation

- [EFA Monitoring](05-efa-monitoring.md)
- [Managed Monitoring (AMP + AMG)](03-monitoring-managed.md)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Node Exporter Textfile Collector](https://github.com/prometheus/node_exporter)
