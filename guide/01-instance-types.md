# Instance Type Configuration Guide

## Overview

This guide covers instance type configuration and component setup for ParallelCluster GPU instances. Different instance types require different components for optimal performance.

## Supported Instance Types

### GPU + EFA Instances (Multi-Node Training)

**Instance Types**: p5en.48xlarge, p5.48xlarge, p4d.24xlarge

**Characteristics**:
- GPU support (H100, A100)
- EFA (Elastic Fabric Adapter) support - up to 3.2 Tbps
- Optimized for multi-node distributed training
- High-speed GPU-to-GPU communication via NCCL over EFA

**Use Cases**:
- Large-scale language model training
- Multi-node distributed learning
- High-performance GPU clusters

### GPU Only Instances (Single-Node Training)

**Instance Types**: g5.xlarge, g5.12xlarge, g4dn.xlarge

**Characteristics**:
- GPU support (A10G, T4)
- No EFA support
- Suitable for single-node workloads
- Cost-effective

**Use Cases**:
- Single-node model training
- Inference workloads
- Development and testing

### CPU Instances (General Computing)

**Instance Types**: c5.xlarge, m5.large, m5.8xlarge, r5.xlarge

**Characteristics**:
- No GPU
- No EFA support
- CPU-based workloads
- Cost-effective

**Use Cases**:
- Data preprocessing
- CPU-based training
- General computing tasks

## Component Configuration Matrix

| Component | GPU Mode | CPU Mode | Notes |
|-----------|----------|----------|-------|
| Docker | Yes | Yes | Container runtime |
| NVIDIA Container Toolkit | Yes | No | GPU container support |
| Pyxis | Yes | Yes | Slurm container plugin |
| EFA Driver | Auto-detect | No | p5/p4d only |
| DCGM Exporter | Yes (if GPU) | No | GPU metrics to Prometheus |
| Node Exporter | Yes | Yes | System metrics to Prometheus |
| CloudWatch Agent | Yes | Yes | Always enabled |

## Configuration via Environment Variables

### Setting COMPUTE_SETUP_TYPE

Edit `environment-variables-bailey.sh`:

```bash
export COMPUTE_SETUP_TYPE="gpu"         # GPU instances
# OR
export COMPUTE_SETUP_TYPE="cpu"         # CPU instances
# OR
export COMPUTE_SETUP_TYPE=""            # Minimal (testing only)
```

### Installation Time Estimates

| Setup Type | Components | Time |
|-----------|-----------|------|
| `"gpu"` | Docker + NVIDIA Toolkit + EFA + DCGM + Node Exporter | 15-20 min |
| `"cpu"` | Docker + Pyxis | 5-10 min |
| `""` | None (ParallelCluster defaults only) | 1-2 min |

## P6-B200 Specific Requirements

The p6-b200 instance type requires additional configuration for InfiniBand and NVL fabric management.

### Required Modules

```bash
# InfiniBand device management
ib_umad

# NVIDIA Fabric Manager
nvlsm
fabricmanager
```

### Pre-NVL5 Panic Root Cause and Fix

**Issue**: cinc (cluster initialization and configuration) attempts to start fabricmanager, causing a panic if:
1. fabricmanager is already running (no-op intended, but fails)
2. fabricmanager is masked (systemd prevents startup)

**Root Cause**: cinc runs `fabricmanager :start` directly without checking current state.

**Fix**: Ensure fabricmanager is not masked in systemd:

```bash
# Check status
sudo systemctl is-enabled fabricmanager

# Unmask if necessary
sudo systemctl unmask fabricmanager

# Enable and start
sudo systemctl enable fabricmanager
sudo systemctl start fabricmanager

# Verify
sudo systemctl status fabricmanager
```

## Custom AMI Checklist

If creating a custom AMI for ParallelCluster:

- [ ] NVIDIA driver installed (version compatible with CUDA)
- [ ] CUDA toolkit installed
- [ ] EFA driver and libfabric installed (for EFA-capable instances)
- [ ] Docker and NVIDIA Container Toolkit installed
- [ ] CloudWatch Agent installed and configured
- [ ] Node Exporter installed (if using Prometheus monitoring)
- [ ] DCGM installed (for GPU monitoring)
- [ ] Slurm client libraries installed
- [ ] SSH configured for key-based access
- [ ] Firewall rules allow inter-node communication
- [ ] Permissions set for monitoring components

## Applying Configuration

### Step 1: Set Environment Variables

```bash
cd parallelcluster-for-llm
vim environment-variables-bailey.sh

# Set COMPUTE_SETUP_TYPE based on your instance types
export COMPUTE_SETUP_TYPE="gpu"
```

### Step 2: Generate Cluster Configuration

```bash
source environment-variables-bailey.sh
envsubst < cluster-config.yaml.template > cluster-config.yaml
```

### Step 3: Upload to S3

```bash
aws s3 sync config/ s3://${S3_BUCKET}/config/ --region ${AWS_REGION}
```

### Step 4: Create or Update Cluster

```bash
# Create new cluster
pcluster create-cluster \
    --cluster-name ${CLUSTER_NAME} \
    --cluster-configuration cluster-config.yaml \
    --region ${AWS_REGION}

# Or update existing cluster
pcluster update-cluster \
    --cluster-name ${CLUSTER_NAME} \
    --cluster-configuration cluster-config.yaml \
    --region ${AWS_REGION}
```

## Verification

### Check EFA Installation

```bash
# On compute node
ls -la /dev/infiniband/
/opt/amazon/efa/bin/fi_info --version
```

### Check DCGM Exporter

```bash
# On compute node
sudo systemctl status dcgm-exporter
curl http://localhost:9400/metrics | head -20
```

### Check Node Exporter

```bash
# On compute node
sudo systemctl status node-exporter
curl http://localhost:9100/metrics | head -20
```

### Verify Configuration

```bash
# On HeadNode, check compute node setup
sinfo -N -l
scontrol show nodes
```

## Performance Baselines

### EFA Bandwidth (p5en.48xlarge)

- **Maximum**: 3200 Gbps (400 GB/s)
- **Interfaces**: 32x 100 Gbps
- **Expected NCCL**: ~2800 Gbps for all-reduce
- **Expected point-to-point**: ~3000 Gbps

### GPU Performance

**H100 (p5en.48xlarge)**:
- GPU-to-GPU via NVLink: ~1000 GB/s
- Node to node via EFA: ~2800 GB/s

**A100 (p4d.24xlarge)**:
- GPU-to-GPU via NVLink: ~600 GB/s
- Node to node via EFA: ~400 Gbps

## Troubleshooting

### EFA Installation Failed

```bash
# Check if EFA device exists
ls -la /dev/infiniband/

# Verify instance type supports EFA
# Only p5, p5en, p4d, p4de support EFA

# Check EFA driver
dmesg | grep -i efa
```

### DCGM Exporter Not Starting

```bash
# Check if GPU is detected
lspci | grep -i nvidia
nvidia-smi

# Check Docker
sudo systemctl status docker

# View logs
sudo journalctl -u dcgm-exporter -n 50
```

### Node Exporter Not Starting

```bash
# Check binary exists
ls -l /usr/local/bin/node_exporter

# View logs
sudo journalctl -u node-exporter -n 50
```

## Related Documentation

- [Deployment Considerations](02-deployment-considerations.md)
- [Monitoring Self-Hosted](04-monitoring-self-hosted.md)
- [EFA Monitoring](05-efa-monitoring.md)
- [AWS EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
