# HeadNode Configuration

## Overview

HeadNode setup includes:
- **CloudWatch Agent**: System metrics and logs
- **Prometheus**: Metrics collection from compute nodes (DCGM, node_exporter)
- **NGC Containers**: Automatic download to FSx Lustre for shared access
- **FSx Directory Structure**: Organized storage for containers, datasets, checkpoints

## Automatic Setup

When the cluster is created, HeadNode automatically:

1. **Installs CloudWatch Agent** - Collects system metrics
2. **Installs Prometheus** - Scrapes metrics from compute nodes
3. **Initializes FSx Lustre** - Creates directory structure
4. **Downloads NGC Containers** - Background download to `/fsx/containers/`

## NGC Container Management

### Automatic Download (Background)

NGC containers are downloaded in the background during cluster creation:

```bash
# Check download progress
tail -f /fsx/logs/ngc-download.log

# List downloaded containers
/fsx/containers/list-containers.sh

# Or manually
ls -lh /fsx/containers/*.sqsh
```

### Container List

Default containers (defined in `containers.txt`):
- **PyTorch 24.01** - General LLM training (includes NCCL, Apex, Transformer Engine)
- **NeMo 24.01** - NVIDIA's LLM framework (includes Megatron-LM)

### Adding More Containers

Edit `/fsx/config/containers.txt` and re-run:

```bash
bash /fsx/scripts/download-ngc-containers.sh /fsx/config/containers.txt
```

Example additions:
```
# TensorFlow
docker://nvcr.io/nvidia/tensorflow:24.01-tf2-py3

# JAX
docker://nvcr.io/nvidia/jax:24.01-py3

# Triton Inference Server
docker://nvcr.io/nvidia/tritonserver:24.01-py3
```

## Using NGC Containers

### With Slurm + Pyxis

```bash
# Simple job
srun --container-image=/fsx/containers/nvcr.io_nvidia_pytorch-24.01-py3.sqsh \
     python train.py

# With mounts
srun --container-image=/fsx/containers/nvcr.io_nvidia_pytorch-24.01-py3.sqsh \
     --container-mounts=/fsx:/fsx \
     python train.py

# Multi-node training
srun --nodes=2 --ntasks-per-node=8 --gpus-per-task=1 \
     --container-image=/fsx/containers/nvcr.io_nvidia_nemo-24.01.sqsh \
     --container-mounts=/fsx:/fsx \
     python -m torch.distributed.launch train.py
```

### With enroot directly

```bash
# Start interactive shell
enroot start /fsx/containers/nvcr.io_nvidia_pytorch-24.01-py3.sqsh

# Run command
enroot start /fsx/containers/nvcr.io_nvidia_pytorch-24.01-py3.sqsh python train.py
```

### Slurm Batch Job Example

```bash
#!/bin/bash
#SBATCH --job-name=llm-training
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-task=1
#SBATCH --time=24:00:00
#SBATCH --output=/fsx/logs/training/%j.out

# Use NGC PyTorch container
srun --container-image=/fsx/containers/nvcr.io_nvidia_pytorch-24.01-py3.sqsh \
     --container-mounts=/fsx:/fsx \
     python /fsx/scripts/train_llm.py \
       --data-path /fsx/datasets/my-dataset \
       --checkpoint-path /fsx/checkpoints/my-model
```

## NCCL Installation (Manual)

NCCL is **NOT** automatically installed. You have two options:

### Option 1: Use NGC Containers (Recommended) 

NGC containers already include optimized NCCL:
- **PyTorch 24.01**: NCCL 2.19.3
- **NeMo 24.01**: NCCL 2.19.3 + AWS optimizations

**No additional installation needed!**

**Advantages**:
-  Zero installation time
-  Pre-tested and optimized for AWS
-  Includes all dependencies (CUDA, cuDNN, etc.)
-  Easy version management

### Option 2: Manual NCCL Installation to FSx

If you need a specific NCCL version or custom build:

#### Installation Steps

```bash
# 1. SSH to HeadNode
ssh headnode

# 2. Install NCCL to FSx Lustre (one-time, 10-15 min)
sudo bash /fsx/nccl/install-nccl-shared.sh v2.28.7-1 v1.17.2-aws /fsx

# 3. Verify installation
ls -lh /fsx/nccl/
cat /fsx/nccl/.nccl_version
```

**What gets installed**:
- NCCL library (compiled from source)
- AWS OFI NCCL plugin (EFA support)
- NCCL tests
- Environment setup scripts

#### ComputeNode Auto-Detection

ComputeNodes **automatically detect** NCCL in `/fsx/nccl/` during initialization.

**How it works**:

1. **New ComputeNodes** (started after NCCL installation):
   -  Automatically detect `/fsx/nccl/setup-nccl-env.sh`
   -  Configure environment variables
   -  Ready to use immediately
   -  **No additional steps needed**

2. **Already running ComputeNodes** (started before NCCL installation):
   - ️ Need manual configuration (one-time)
   - Run: `bash /fsx/nccl/apply-nccl-to-running-nodes.sh`
   -  Applies to all nodes permanently

#### Applying NCCL to Running Nodes

If you installed NCCL **after** ComputeNodes were already running:

```bash
# On HeadNode, run once
bash /fsx/nccl/apply-nccl-to-running-nodes.sh
```

**What this script does**:
1. Detects all running ComputeNodes
2. Creates `/etc/profile.d/nccl-shared.sh` on each node
3. Applies environment variables to current sessions
4. Makes configuration permanent (survives reboots)

**After running this script**:
-  Current Slurm jobs can use NCCL immediately
-  New Slurm jobs automatically use NCCL
-  New SSH sessions automatically load NCCL
-  Configuration persists after reboot
-  **No need to run again**

#### Recommended Workflow

**Best Practice** (avoids manual configuration):

```bash
# 1. Create cluster with MinCount=0 for ComputeNodes
pcluster create-cluster --cluster-name my-cluster --cluster-configuration cluster-config.yaml

# 2. Install NCCL on HeadNode
ssh headnode
sudo bash /fsx/nccl/install-nccl-shared.sh v2.28.7-1 v1.17.2-aws /fsx

# 3. Submit job → ComputeNodes start → NCCL auto-detected 
sbatch my-training-job.sh
```

**Alternative** (if nodes already running):

```bash
# 1. Create cluster (nodes start immediately)
pcluster create-cluster --cluster-name my-cluster --cluster-configuration cluster-config.yaml

# 2. Install NCCL
ssh headnode
sudo bash /fsx/nccl/install-nccl-shared.sh v2.28.7-1 v1.17.2-aws /fsx

# 3. Apply to running nodes (one-time)
bash /fsx/nccl/apply-nccl-to-running-nodes.sh

# 4. Use NCCL immediately
sbatch my-training-job.sh
```

#### Verification

```bash
# Check NCCL version
srun --nodes=1 bash -c 'source /etc/profile.d/nccl-shared.sh && echo $NCCL_VERSION'

# Check environment variables
srun --nodes=1 bash -c 'source /etc/profile.d/nccl-shared.sh && env | grep NCCL'

# Run NCCL test
srun --nodes=2 --ntasks=16 --gpus-per-task=1 \
  /opt/nccl-tests/build/all_reduce_perf -b 8 -e 128M -f 2 -g 1
```

#### Troubleshooting

**NCCL not found in job**:

```bash
# Check if NCCL is installed
ls -lh /fsx/nccl/setup-nccl-env.sh

# Check if profile script exists on ComputeNode
srun --nodes=1 ls -lh /etc/profile.d/nccl-shared.sh

# If missing, apply to running nodes
bash /fsx/nccl/apply-nccl-to-running-nodes.sh
```

**Already open SSH session doesn't have NCCL**:

```bash
# In the existing SSH session, manually source
source /etc/profile.d/nccl-shared.sh

# Or open a new SSH session (auto-loads)
```

#### NCCL Environment Variables

When NCCL is configured, these environment variables are set:

```bash
# Library paths
LD_LIBRARY_PATH=/usr/local/lib:...
LIBRARY_PATH=/usr/local/lib:...

# EFA configuration
FI_PROVIDER=efa
FI_EFA_USE_DEVICE_RDMA=1

# NCCL optimizations
NCCL_PROTO=simple
NCCL_DEBUG=INFO
NCCL_ALGO=Ring
NCCL_MIN_NRINGS=8
```

#### When to Use Manual NCCL Installation

Use manual installation when:
-  Need specific NCCL version (e.g., latest development build)
-  Testing NCCL patches or custom builds
-  Require specific AWS OFI NCCL version
-  Need NCCL tests for benchmarking

Use NGC containers when:
-  Standard training workloads
-  Want pre-tested, optimized setup
-  Need reproducible environments
-  Prefer zero installation time

## FSx Lustre Directory Structure

```
/fsx/
├── containers/          # NGC container images (.sqsh files)
│   ├── runtime/        # enroot runtime data
│   ├── cache/          # enroot cache
│   ├── data/           # enroot data
│   └── *.sqsh          # Container images
│
├── scripts/            # Shared scripts
│   └── download-ngc-containers.sh
│
├── config/             # Configuration files
│   └── containers.txt  # NGC container list
│
├── logs/               # Log files
│   ├── container-downloads/
│   ├── slurm/
│   └── training/
│
├── nccl/               # NCCL installation (optional, manual)
│   ├── install-nccl-shared.sh
│   └── setup-nccl-env.sh
│
├── datasets/           # Training datasets
├── checkpoints/        # Model checkpoints
└── results/            # Training results
```

## Monitoring

### Prometheus

Access Prometheus UI:
```bash
# Port forward from local machine
ssh -L 9090:localhost:9090 headnode

# Open browser
http://localhost:9090
```

Available metrics:
- **DCGM Exporter** (port 9400): GPU metrics from compute nodes
- **Node Exporter** (port 9100): System metrics from compute nodes

### CloudWatch

Metrics and logs are automatically sent to CloudWatch:
- Log Group: `/aws/parallelcluster/<cluster-name>`
- Metrics: Custom namespace `ParallelCluster`

## Troubleshooting

### NGC Container Download Failed

Check logs:
```bash
tail -f /fsx/logs/ngc-download.log
tail -f /fsx/logs/container-downloads/*.log
```

Retry manually:
```bash
bash /fsx/scripts/download-ngc-containers.sh /fsx/config/containers.txt
```

### Container Not Found

List available containers:
```bash
/fsx/containers/list-containers.sh
```

Download specific container:
```bash
enroot import -o /fsx/containers/my-container.sqsh docker://nvcr.io/nvidia/pytorch:24.01-py3
```

### FSx Not Mounted

Check mount status:
```bash
mountpoint /fsx
df -h /fsx
```

Remount if needed:
```bash
sudo mount -a
```

## Files in This Directory

| File | Purpose |
|------|---------|
| `setup-headnode.sh` | Main HeadNode setup script (auto-run) |
| `download-ngc-containers.sh` | NGC container downloader |
| `containers.txt` | List of NGC containers to download |
| `README.md` | This file |

## Best Practices

1. **Use NGC Containers**: Pre-built, optimized, includes NCCL
2. **Store datasets on FSx**: High-performance shared storage
3. **Save checkpoints to FSx**: Accessible from all nodes
4. **Monitor downloads**: Check `/fsx/logs/ngc-download.log`
5. **Test containers**: Run simple test before large training jobs

## References

- [NGC Catalog](https://catalog.ngc.nvidia.com/)
- [enroot Documentation](https://github.com/NVIDIA/enroot)
- [Pyxis Documentation](https://github.com/NVIDIA/pyxis)
- [NCCL Documentation](https://docs.nvidia.com/deeplearning/nccl/)
