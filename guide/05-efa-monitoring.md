# EFA Networking and Monitoring Guide

## Elastic Fabric Adapter (EFA) Overview

EFA provides high-speed, low-latency network interconnect for GPU instances in a cluster.

### Specifications

**p5en.48xlarge**:
- **Bandwidth**: 3200 Gbps (400 GB/s)
- **Interfaces**: 32x 100 Gbps
- **Expected NCCL throughput**: ~2800 Gbps (87% utilization)

**p4d.24xlarge**:
- **Bandwidth**: 400 Gbps
- **Interfaces**: 8x 50 Gbps
- **Expected NCCL throughput**: ~350 Gbps (87% utilization)

### When to Enable EFA

- Multi-node distributed training
- NCCL All-Reduce operations
- p5en, p5, p4d, p4de instance types

### When EFA is Not Available

- Single-node training (use NVLink instead)
- g5, g4dn instances (no EFA support)
- CPU instances

## EFA Monitoring

### Automatic Installation

EFA monitoring is automatically installed on GPU compute nodes:

```bash
# Runs as systemd service
sudo systemctl status efa-monitor

# Collects EFA network statistics
# Updates CloudWatch metrics every 5 minutes
```

### Available Metrics

| Metric | Unit | Description |
|--------|------|-------------|
| `rx_bytes_rate` | Bytes/Second | Receive throughput |
| `tx_bytes_rate` | Bytes/Second | Transmit throughput |
| `rx_packets_rate` | Packets/Second | Receive packet rate |
| `tx_packets_rate` | Packets/Second | Transmit packet rate |
| `rx_errors` | Count | Receive errors (cumulative) |
| `tx_discards` | Count | Transmit discards (cumulative) |

### CloudWatch Namespace

Metrics stored in CloudWatch:
- **Namespace**: `ParallelCluster/Network`
- **Dimensions**: `InstanceId`, `Interface`

### Querying Metrics

```bash
# List available metrics
aws cloudwatch list-metrics \
  --namespace ParallelCluster/Network \
  --region us-east-2

# Get metric statistics
aws cloudwatch get-metric-statistics \
  --namespace ParallelCluster/Network \
  --metric-name tx_bytes_rate \
  --dimensions Name=InstanceId,Value=i-1234567890abcdef0 \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-01T01:00:00Z \
  --period 300 \
  --statistics Average,Maximum \
  --region us-east-2
```

## Textfile Collector Setup

The EFA monitor uses a textfile collector to export metrics to Prometheus.

### Collector Location

```bash
# Textfile directory
/var/lib/node_exporter/textfile_collector/

# EFA metrics file
/var/lib/node_exporter/textfile_collector/efa_metrics.prom
```

### Metric Format

```
# HELP efa_rx_bytes_rate Receive throughput in bytes/second
# TYPE efa_rx_bytes_rate gauge
efa_rx_bytes_rate{interface="rdmap0s6"} 2500000000

# HELP efa_tx_bytes_rate Transmit throughput in bytes/second
# TYPE efa_tx_bytes_rate gauge
efa_tx_bytes_rate{interface="rdmap0s6"} 2500000000

# HELP efa_rx_errors Receive errors
# TYPE efa_rx_errors counter
efa_rx_errors{interface="rdmap0s6"} 0

# HELP efa_tx_discards Transmit discards
# TYPE efa_tx_discards counter
efa_tx_discards{interface="rdmap0s6"} 0
```

### Prometheus Queries

```promql
# EFA receive throughput
efa_rx_bytes_rate{interface="rdmap0s6"}

# EFA transmit throughput
efa_tx_bytes_rate{interface="rdmap0s6"}

# Total EFA bandwidth (both directions)
efa_rx_bytes_rate + efa_tx_bytes_rate

# Bandwidth utilization percentage (p5en: 3200 Gbps max)
(efa_tx_bytes_rate + efa_rx_bytes_rate) / (3200 * 1000 * 1000 * 1000) * 100

# EFA errors (should be 0)
efa_rx_errors + efa_tx_discards
```

## Key Metrics to Watch

### During Training

```bash
# SSH to compute node
pcluster ssh --cluster-name your-cluster -i ~/.ssh/key.pem

# Watch real-time EFA statistics
watch -n 1 'tail -5 /var/log/efa_monitor.log'

# Expected output (during training):
# rdmap0s6: RX=2500 Mbps, TX=2500 Mbps
```

### Baseline Performance

**Idle (no training)**:
- RX: 0 Mbps
- TX: 0 Mbps
- Errors: 0

**During distributed training**:
- RX: 1000-2800 Mbps (depends on workload)
- TX: 1000-2800 Mbps
- Errors: 0 (must be zero)

**Maximum utilization** (NCCL All-Reduce):
- RX/TX: ~2800 Mbps (87% of 3200 Gbps)
- Errors: 0

## Troubleshooting

### Service Not Running

```bash
# Check service status
sudo systemctl status efa-monitor

# View detailed logs
sudo journalctl -u efa-monitor -n 50 -f

# Manually run script (for debugging)
sudo python3 /opt/monitoring/efa_network_monitor.py
```

### EFA Interfaces Not Found

```bash
# Check EFA device exists
ls -la /sys/class/infiniband/

# Expected output (p5en.48xlarge):
# rdmap0s0, rdmap0s6, rdmap0s12, rdmap0s18, ...

# Verify EFA driver installed
fi_info -p efa
```

### No Metrics in CloudWatch

```bash
# Verify IAM permissions
aws cloudwatch put-metric-data \
  --namespace Test \
  --metric-name TestMetric \
  --value 1

# Check if monitor is running
ps aux | grep efa_network_monitor

# Check logs for errors
sudo tail -100 /var/log/efa_monitor.log | grep -i error
```

### High CPU Usage

EFA monitor should use <5% CPU. If higher:

```bash
# Check collection interval
grep COLLECTION_INTERVAL /opt/monitoring/efa_network_monitor.py
# Should be 60 seconds or more

# Restart service
sudo systemctl restart efa-monitor

# Verify CPU usage
ps aux | grep efa_network_monitor
```

## Service Management

```bash
# Check status
sudo systemctl status efa-monitor

# View logs
sudo journalctl -u efa-monitor -f
tail -f /var/log/efa_monitor.log

# Restart
sudo systemctl restart efa-monitor

# Stop/Start
sudo systemctl stop efa-monitor
sudo systemctl start efa-monitor

# Enable/Disable on boot
sudo systemctl enable efa-monitor
sudo systemctl disable efa-monitor
```

## Performance Optimization

### EFA is Properly Utilized When

- NCCL All-Reduce: 2800+ Gbps on p5en (87% of max)
- Multi-node training runs smoothly
- No receive errors or transmit discards
- Network utilization matches GPU workload

### Signs of EFA Issues

- Throughput <500 Gbps despite active training
- Non-zero `rx_errors` or `tx_discards`
- Network latency spikes during training
- GPU utilization drops unexpectedly

### Validation Steps

```bash
# 1. Verify EFA installation
fi_info -p efa

# 2. Run NCCL test (see NCCL testing guide)
sbatch phase2-multinode.sbatch

# 3. Monitor EFA during test
watch -n 1 'tail -5 /var/log/efa_monitor.log'

# 4. Check CloudWatch dashboard
# Dashboard auto-created at cluster startup
```

## Integration with Other Monitoring

EFA metrics work alongside:

- **DCGM Exporter**: GPU metrics (port 9400)
- **Node Exporter**: System metrics (port 9100)
- **CloudWatch Agent**: Native CloudWatch metrics
- **Prometheus**: Collects all metrics (HeadNode)

### Complete Monitoring View

```promql
# GPU utilization during All-Reduce
DCGM_FI_DEV_GPU_UTIL

# Network throughput during All-Reduce
efa_tx_bytes_rate + efa_rx_bytes_rate

# GPU waiting on network (low GPU util, high network)
# Indicates network bottleneck (needs tuning)

# Network waiting on GPU (low network util, high GPU)
# Indicates compute-bound (not network-bound)
```

## Cost

### CloudWatch Metrics

For 4 compute nodes with EFA:

- **Metrics**: 6 metrics × 4 nodes × $0.30/month = $7.20
- **API calls**: ~17,000 PutMetricData requests × $0.01/1000 = $0.17
- **Dashboard**: $3.00
- **Total**: ~$10.37/month

### Cost Optimization

Increase collection interval or batch size:

```bash
# Edit collection interval (increase from 60 to 300 seconds)
sudo vim /opt/monitoring/efa_network_monitor.py
# COLLECTION_INTERVAL = 300

# Increase batch size (fewer API calls)
# BATCH_SIZE = 10

sudo systemctl restart efa-monitor
```

## Related Documentation

- [Instance Type Configuration](01-instance-types.md)
- [NCCL Performance Testing](06-nccl-testing.md)
- [Self-Hosted Monitoring](04-monitoring-self-hosted.md)
- [AWS EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
