# EFA Network Monitoring Guide

## Overview

This guide covers EFA (Elastic Fabric Adapter) network performance monitoring for ParallelCluster GPU instances. EFA monitoring tracks inter-node network throughput, packet rates, and errors in real-time.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Compute Node (GPU instances with EFA)                       │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ EFA Network Monitor (Python)                         │  │
│  │  - Reads /sys/class/infiniband/*/counters           │  │
│  │  - Calculates rates (bytes/sec, packets/sec)        │  │
│  │  - Batches metrics (5 min)                          │  │
│  │  - CPU: <5%, Memory: <256MB                         │  │
│  └──────────────────────────────────────────────────────┘  │
│                           │                                  │
│                           ▼                                  │
│                    CloudWatch API                            │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ CloudWatch Metrics                                           │
│  Namespace: ParallelCluster/Network                         │
│                                                              │
│  Metrics:                                                    │
│   - rx_bytes_rate (Bytes/Second)                            │
│   - tx_bytes_rate (Bytes/Second)                            │
│   - rx_packets_rate (Count/Second)                          │
│   - tx_packets_rate (Count/Second)                          │
│   - rx_errors (Count)                                       │
│   - tx_discards (Count)                                     │
│                                                              │
│  Dimensions:                                                 │
│   - InstanceId                                              │
│   - Interface (rdmap0s6, etc.)                              │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ CloudWatch Dashboard                                         │
│  - Real-time throughput graphs                              │
│  - Bandwidth utilization                                    │
│  - Packet rates                                             │
│  - Error tracking                                           │
└─────────────────────────────────────────────────────────────┘
```

## Features

- **Lightweight**: <5% CPU, <256MB memory
- **Automatic**: Starts on boot, restarts on failure
- **Batched**: Collects 5 minutes of data before sending to CloudWatch
- **Multi-interface**: Monitors all EFA interfaces
- **Error tracking**: Tracks receive errors and transmit discards

## Installation

EFA monitoring is **automatically installed** on GPU compute nodes when the cluster is created. No manual installation required.

### Automatic Installation

The monitoring is integrated into the compute node setup script:

```bash
# In cluster-config.yaml.template
ComputeResources:
  - Name: gpu-nodes
    InstanceType: p5en.48xlarge
    Efa:
      Enabled: true
    CustomActions:
      OnNodeConfigured:
        Script: s3://your-bucket/config/compute/setup-compute-node.sh
        Args:
          - CLUSTER_NAME
          - REGION
          - S3_BUCKET
          - MONITORING_TYPE
          - gpu  # ← EFA monitoring enabled for GPU nodes
```

### Manual Installation (if needed)

If you need to install EFA monitoring on an existing compute node:

```bash
# SSH to compute node
pcluster ssh --cluster-name your-cluster -i ~/.ssh/key.pem

# Download scripts from S3
aws s3 cp s3://your-bucket/config/monitoring/efa_network_monitor.py /opt/monitoring/
aws s3 cp s3://your-bucket/config/monitoring/setup-efa-monitoring.sh /tmp/

# Run setup
sudo bash /tmp/setup-efa-monitoring.sh
```

## Service Management

```bash
# Check service status
sudo systemctl status efa-monitor

# View real-time logs
sudo tail -f /var/log/efa_monitor.log
sudo journalctl -u efa-monitor -f

# Restart service
sudo systemctl restart efa-monitor

# Stop service
sudo systemctl stop efa-monitor

# Start service
sudo systemctl start efa-monitor

# Disable auto-start
sudo systemctl disable efa-monitor

# Enable auto-start
sudo systemctl enable efa-monitor
```

## Metrics

### Available Metrics

| Metric Name | Unit | Description |
|------------|------|-------------|
| `rx_bytes_rate` | Bytes/Second | Receive throughput |
| `tx_bytes_rate` | Bytes/Second | Transmit throughput |
| `rx_packets_rate` | Count/Second | Receive packet rate |
| `tx_packets_rate` | Count/Second | Transmit packet rate |
| `rx_errors` | Count | Receive errors (cumulative) |
| `tx_discards` | Count | Transmit discards (cumulative) |

### Dimensions

- **InstanceId**: EC2 instance ID
- **Interface**: EFA interface name (e.g., `rdmap0s6`)

### CloudWatch Console

View metrics in CloudWatch:

```bash
# List available metrics
aws cloudwatch list-metrics \
  --namespace ParallelCluster/Network \
  --region us-east-2

# Get metric statistics
aws cloudwatch get-metric-statistics \
  --namespace ParallelCluster/Network \
  --metric-name rx_bytes_rate \
  --dimensions Name=InstanceId,Value=i-1234567890abcdef0 \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-01T01:00:00Z \
  --period 60 \
  --statistics Average \
  --region us-east-2
```

## Dashboard

### Create EFA Dashboard

```bash
cd parallelcluster-for-llm/config/cloudwatch
bash create-efa-dashboard.sh your-cluster-name us-east-2
```

### Dashboard Widgets

The EFA dashboard includes:

1. **Network Throughput** (Time Series)
   - RX/TX bytes per second
   - Shows actual bandwidth usage

2. **Bandwidth Utilization** (Time Series)
   - Converts to Gbps
   - Compares against EFA max (3200 Gbps for p5en)

3. **Packet Rate** (Time Series)
   - RX/TX packets per second
   - Useful for small message workloads

4. **Errors & Discards** (Time Series)
   - Receive errors
   - Transmit discards
   - Should be zero under normal operation

5. **Current Rates** (Single Value)
   - Latest RX/TX rates
   - Quick status check

### Access Dashboard

```
https://console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards:name=ParallelCluster-your-cluster-EFA
```

## Troubleshooting

### Service Not Starting

```bash
# Check service status
sudo systemctl status efa-monitor

# View detailed logs
sudo journalctl -u efa-monitor -n 50

# Check if EFA interfaces exist
ls -la /sys/class/infiniband/

# Manually run script (for testing)
sudo python3 /opt/monitoring/efa_network_monitor.py
```

### No Metrics in CloudWatch

```bash
# Verify IAM permissions
aws cloudwatch put-metric-data \
  --namespace Test \
  --metric-name TestMetric \
  --value 1

# Check if script is running
ps aux | grep efa_network_monitor

# Check logs for errors
sudo tail -100 /var/log/efa_monitor.log
```

### High CPU Usage

The monitor should use <5% CPU. If higher:

```bash
# Check collection interval (should be 60 seconds)
grep COLLECTION_INTERVAL /opt/monitoring/efa_network_monitor.py

# Check for errors in logs
sudo journalctl -u efa-monitor -n 100
```

## Performance Impact

- **CPU**: <5% (systemd enforced)
- **Memory**: <256MB (systemd enforced)
- **Network**: Minimal (batched CloudWatch API calls)
- **Disk**: <100MB logs (with rotation)

## EFA Performance Baselines

### p5en.48xlarge

- **EFA Bandwidth**: 3200 Gbps (400 GB/s)
- **EFA Interfaces**: 32x 100 Gbps
- **Expected Throughput**: 
  - NCCL All-Reduce: ~2800 Gbps
  - Point-to-point: ~3000 Gbps

### Monitoring During Training

```bash
# SSH to compute node during training
pcluster ssh --cluster-name your-cluster -i ~/.ssh/key.pem

# Watch real-time EFA stats
watch -n 1 'tail -5 /var/log/efa_monitor.log'

# Check NCCL test results
cat /fsx/logs/nccl-test-*.log
```

## Integration with Other Monitoring

EFA monitoring works alongside:

- **DCGM Exporter**: GPU metrics (port 9400)
- **Node Exporter**: System metrics (port 9100)
- **CloudWatch Agent**: System + custom metrics
- **Prometheus**: Metrics aggregation (HeadNode)

All metrics are available in:
- CloudWatch (AWS Console)
- Prometheus (if using self-hosting mode)
- Grafana (if using AMG)

## Cost Considerations

### CloudWatch Costs

- **Metrics**: $0.30 per metric per month
- **API Calls**: $0.01 per 1,000 PutMetricData requests
- **Dashboard**: $3.00 per month

### Estimated Monthly Cost

For 4 compute nodes with EFA:
- Metrics: 6 metrics × 4 nodes × $0.30 = $7.20
- API calls: ~17,000 calls × $0.01/1000 = $0.17
- Dashboard: $3.00
- **Total**: ~$10.37/month

### Cost Optimization

```bash
# Increase collection interval (reduce API calls)
# Edit /opt/monitoring/efa_network_monitor.py
COLLECTION_INTERVAL = 300  # 5 minutes instead of 60 seconds

# Increase batch size (fewer API calls)
BATCH_SIZE = 10  # 10 minutes instead of 5 minutes

# Restart service
sudo systemctl restart efa-monitor
```

## Best Practices

1. **Monitor during training**: Check EFA utilization during actual workloads
2. **Watch for errors**: rx_errors and tx_discards should be zero
3. **Compare with NCCL tests**: Validate against nccl-tests benchmarks
4. **Use dashboards**: Create custom dashboards for your workload
5. **Set alarms**: Alert on low throughput or high errors

## Related Documentation

- [DCGM Monitoring](./DCGM-TO-CLOUDWATCH.md)
- [NVLink Monitoring](./NVLINK-MONITORING.md)
- [Prometheus Metrics](./PROMETHEUS-METRICS.md)
- [CloudWatch Monitoring](./MONITORING.md)

## References

- [AWS EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [EFA Performance](https://aws.amazon.com/hpc/efa/)
- [NCCL with EFA](https://github.com/aws/aws-ofi-nccl)
