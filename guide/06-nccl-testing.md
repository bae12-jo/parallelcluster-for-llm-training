# NCCL Performance Testing Guide

## Overview

Complete guide for validating NCCL performance on AWS ParallelCluster with GPU instances.

## Testing Phases

| Phase | Purpose | Duration | Nodes | Key Metrics |
|-------|---------|----------|-------|-------------|
| **Phase 1** | Single-node baseline | 30 min | 1 | Bus bandwidth, NVLink |
| **Phase 2** | Multi-node scaling | 60 min | 2+ | EFA network, scaling efficiency |
| **Phase 3** | Workload simulation | 90 min | 2+ | MoE patterns, latency |
| **Phase 4** | NCCL optimization | 60 min | 2+ | Tuning parameters |

**Total time**: ~4 hours for complete validation

## Installation Timing

NCCL installation is not included in automatic cluster bootstrap due to build time.

### Why Separate Installation?

- **Build time**: 10-15 minutes
- **Bootstrap timeout**: 40 minutes (ComputeNode)
- **Issue**: Would delay cluster creation unnecessarily

### Installation Options

**Option 1: Use NGC Containers (Recommended)**

NGC containers include pre-optimized NCCL:

```bash
srun --container-image=/fsx/containers/nvcr.io_nvidia_pytorch-24.01-py3.sqsh \
     python train.py
```

- Zero installation time
- Pre-tested and optimized
- Includes all dependencies

**Option 2: Manual Installation (If Needed)**

Install NCCL to FSx after cluster is created:

```bash
# One-time installation (~10-15 minutes)
sudo bash /fsx/nccl/install-nccl-shared.sh v2.28.7-1 v1.17.2-aws /fsx

# Verify
ls -lh /fsx/nccl/
cat /fsx/nccl/.nccl_version
```

Use when:
- Specific NCCL version needed
- Custom NCCL patches required
- Testing NCCL development builds

## Phase 1: Baseline Performance Check

**Purpose**: Verify basic NCCL functionality on a single node

### What It Tests

1. **AllReduce** (Dense Model Synchronization)
   - Message sizes: 128MB to 2GB
   - Tests NVLink bandwidth
   - Critical for gradient synchronization

2. **AllToAll** (MoE Routing)
   - Message sizes: 8MB to 512MB
   - Tests GPU-to-GPU communication
   - Critical for expert parallelism

### Expected Results

**AllReduce (Dense Models)**:
- **Target**: >800 GB/s for 1GB messages
- **Expected**: 800-1200 GB/s (single node with NVLink)
- **Critical**: Near-linear scaling with message size

**AllToAll (MoE Models)**:
- **Target**: >200 GB/s for 128MB messages
- **Latency**: <100 microseconds for 8MB messages
- **Expected**: 200-400 GB/s (single node)

### Run Phase 1

```bash
# Standard version (requires NCCL installed)
sbatch /fsx/nccl/phase1-baseline.sbatch

# Container version (self-contained)
sbatch /fsx/nccl/phase1-baseline-container.sbatch

# Monitor progress
squeue
tail -f /fsx/nccl-results/phase1-baseline_*.out
```

### Interpret Results

```bash
# View summary report
cat /fsx/nccl-results/phase1_*/phase1-baseline-report.txt

# Check AllReduce results (1GB message)
grep "1073741824" /fsx/nccl-results/phase1_*/allreduce-dense.log
# Look for: "Avg bus bandwidth: 1000.00 GB/s" (should be >800 GB/s)

# Check AllToAll results (128MB message)
grep "134217728" /fsx/nccl-results/phase1_*/alltoall-moe.log
# Look for: "Avg bus bandwidth: 300.00 GB/s" (should be >200 GB/s)
```

## Phase 2: Multi-Node Scaling Tests

**Purpose**: Validate EFA network performance and scaling efficiency

### What It Tests

1. **Multi-node AllReduce**
   - Gradient sync across nodes via EFA
   - Inter-node bandwidth
   - Scaling efficiency

2. **Multi-node AllToAll**
   - Expert routing across nodes
   - Network latency
   - Load balancing

3. **Algorithm Comparison**
   - Ring vs Tree algorithms
   - Optimal algorithm for cluster size

### Expected Results

**2-Node Dense Model (AllReduce)**:
- **Target**: >1600 GB/s aggregate (>90% efficiency)
- **Expected**: 1600-1800 GB/s
- **Calculation**: 800 GB/s × 2 nodes × 90% efficiency

**4-Node Dense Model (AllReduce)**:
- **Target**: >3200 GB/s aggregate
- **EFA utilization**: >80% of 3.2 Tbps

**MoE (AllToAll)**:
- **Target**: >300 GB/s per node
- **Latency increase**: <20 microseconds vs single-node
- **Scaling**: >80% efficiency

### Run Phase 2

```bash
# Test with 2 nodes
sbatch --nodes=2 /fsx/nccl/phase2-multinode.sbatch

# Test with 4 nodes
sbatch --nodes=4 /fsx/nccl/phase2-multinode.sbatch

# Monitor
squeue
tail -f /fsx/nccl-results/phase2-multinode_*.out
```

### Calculate Scaling Efficiency

```
Efficiency = (Multi-node Bandwidth) / (Single-node Bandwidth × Nodes)

Example:
  Single-node: 1000 GB/s
  2-node: 1800 GB/s
  Efficiency: 1800 / (1000 × 2) = 90%  Good!

If <80%:
  → Check EFA configuration
  → Review network topology
  → Look for NCCL warnings
```

## Phase 3: Real Workload Simulation

**Purpose**: Test actual model communication patterns

### What It Tests

1. **MoE Expert Capacity Sweep**
   - Tokens per expert: 64, 128, 256, 512
   - Finds optimal capacity for cluster
   - Balances latency vs bandwidth

2. **Latency-Sensitive Operations**
   - Small messages (1KB to 1MB)
   - MoE routing messages
   - Critical for responsiveness

3. **Bandwidth-Sensitive Operations**
   - Large messages (128MB to 2GB)
   - Dense model gradient sync
   - Tests peak throughput

4. **Bi-directional Bandwidth**
   - Simultaneous send/receive
   - Realistic training simulation
   - Full-duplex capability

5. **Mixed Pattern**
   - AllToAll + ReduceScatter + AllReduce
   - Simulates real MoE training
   - Tests concurrent operations

### Run Phase 3

```bash
# 2-node test
sbatch --nodes=2 /fsx/nccl/phase3-workload.sbatch

# Container version
sbatch --nodes=2 /fsx/nccl/phase3-workload-container.sbatch
```

### Choose Optimal Expert Capacity

```
Capacity 64:  250 GB/s, 30us latency  ← Best latency
Capacity 128: 300 GB/s, 45us latency  ← Balanced (recommended)
Capacity 256: 320 GB/s, 80us latency  ← Best bandwidth
Capacity 512: 330 GB/s, 150us latency ← Too high latency

Recommendation: Use 128 for balanced performance
```

## Phase 4: NCCL Optimization

**Purpose**: Validate NCCL tuning parameters

### What It Tests

1. **NCCL Protocol Comparison**
   - Simple: Best for large messages (>64MB)
   - LL: Low-latency for small (<1MB)
   - LL128: Balanced

2. **Buffer Size Tuning**
   - 4MB: Lower latency
   - 8MB: Balanced (default)
   - 16MB: Higher bandwidth

3. **Channel Count Optimization**
   - Dense models: 8 channels
   - Balanced: 16 channels
   - MoE models: 32 channels

### Run Phase 4

```bash
# 2-node test
sbatch --nodes=2 /fsx/nccl/phase4-optimization.sbatch

# Container version
sbatch --nodes=2 /fsx/nccl/phase4-optimization-container.sbatch
```

## Recommended Settings

### For Dense Models (GPT, BERT, LLaMA)

```bash
export NCCL_PROTO=Simple              # Best for large messages
export NCCL_ALGO=Ring
export NCCL_BUFFSIZE=8388608          # 8MB
export NCCL_MIN_NCHANNELS=8
export NCCL_MAX_NCHANNELS=16

# EFA optimizations
export FI_EFA_ENABLE_SHM_TRANSFER=1
export FI_EFA_USE_HUGE_PAGE=1
export FI_EFA_USE_DEVICE_RDMA=1

# Network
export NCCL_IB_DISABLE=1
export NCCL_P2P_DISABLE=0
export NCCL_NET_GDR_LEVEL=PIX
export NCCL_NVLS_ENABLE=1             # H100 NVSwitch
```

### For MoE Models (Switch, GLaM, Mixtral)

```bash
export NCCL_PROTO=Simple
export NCCL_ALGO=Ring,Tree
export NCCL_TREE_THRESHOLD=0          # Use tree for large messages

# More channels for AllToAll
export NCCL_BUFFSIZE=8388608          # 8MB
export NCCL_MIN_NCHANNELS=16
export NCCL_MAX_NCHANNELS=32
export NCCL_NTHREADS=512              # More threads

# EFA and network settings (same as dense)
export FI_EFA_ENABLE_SHM_TRANSFER=1
export FI_EFA_USE_HUGE_PAGE=1
export FI_EFA_USE_DEVICE_RDMA=1
export NCCL_IB_DISABLE=1
export NCCL_P2P_DISABLE=0
export NCCL_NET_GDR_LEVEL=PIX
export NCCL_NVLS_ENABLE=1
```

### For H100 Specific (p5en.48xlarge)

```bash
export NCCL_NVLS_ENABLE=1             # Enable NVSwitch
export NCCL_NET_GDR_LEVEL=PIX         # GPU Direct RDMA
export NCCL_P2P_LEVEL=NVL             # NVLink for P2P
```

## Results Analysis

### Generate Combined Report

```bash
# Combine all phase reports
cat /fsx/nccl-results/phase*/phase*-report.txt > /fsx/nccl-results/complete-report.txt

# View complete report
less /fsx/nccl-results/complete-report.txt
```

### Performance Checklist

**Phase 1 Baseline**:
- [ ] AllReduce: >800 GB/s for 1GB messages
- [ ] AllToAll: >200 GB/s for 128MB messages
- [ ] Latency: <100μs for small messages

**Phase 2 Scaling**:
- [ ] Scaling efficiency: >90%
- [ ] Network utilization: >80% of max
- [ ] Latency increase: <20μs vs single-node

**Phase 3 Workload**:
- [ ] Expert capacity optimized
- [ ] Latency-sensitive: <50μs
- [ ] Bandwidth-sensitive: >800 GB/s

**Phase 4 Optimization**:
- [ ] Optimal protocol identified
- [ ] Buffer size tuned
- [ ] Channel count optimized

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| Low NVLink bandwidth (<500 GB/s) | NVLink not working | Check `nvidia-smi topo -m`, verify connections |
| Poor scaling (<70% efficiency) | EFA issue | Verify with `fi_info -p efa`, check RDMA |
| High latency (>100μs small msgs) | Buffer size too large | Use LL protocol, reduce NCCL_BUFFSIZE |
| Low bandwidth (>1000 GB/s) | Settings not optimized | Increase buffer size, use Simple protocol |

## Environment Variables Reference

### Protocol Control

```bash
NCCL_PROTO=Simple|LL|LL128          # Communication protocol
NCCL_ALGO=Ring|Tree                 # Reduction algorithm
NCCL_TREE_THRESHOLD=<bytes>         # Use tree for messages >N bytes
```

### Performance Tuning

```bash
NCCL_BUFFSIZE=<bytes>               # Ring buffer size (default 8MB)
NCCL_MIN_NCHANNELS=<n>              # Minimum channels per connection
NCCL_MAX_NCHANNELS=<n>              # Maximum channels per connection
NCCL_NTHREADS=<n>                   # Threads per channel (default 256)
```

### Network Control

```bash
NCCL_IB_DISABLE=0|1                 # Enable/disable InfiniBand
NCCL_P2P_DISABLE=0|1                # Enable/disable GPU P2P
NCCL_P2P_LEVEL=LOC|SYS|NVL          # P2P distance level
NCCL_NET_GDR_LEVEL=PIX              # GPU Direct RDMA
NCCL_NVLS_ENABLE=0|1                # NVSwitch (H100)
```

### EFA Optimization

```bash
FI_EFA_ENABLE_SHM_TRANSFER=0|1      # Shared memory transfer
FI_EFA_USE_HUGE_PAGE=0|1            # Huge page support
FI_EFA_USE_DEVICE_RDMA=0|1          # Device RDMA
```

### Debugging

```bash
NCCL_DEBUG=INFO                      # Enable logging
NCCL_DEBUG_SUBSYS=ALL               # Log all subsystems
NCCL_LAUNCH_MODE=GROUP              # Parallel thread launch
```

## Related Documentation

- [NCCL Installation Timing](01-instance-types.md)
- [EFA Monitoring](05-efa-monitoring.md)
- [Deployment Considerations](02-deployment-considerations.md)
- [NCCL Documentation](https://docs.nvidia.com/deeplearning/nccl/user-guide/)
- [AWS EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
