# NCCL Performance Testing Guide

## Overview

This directory contains a **4-phase testing framework** for validating NCCL performance on your ParallelCluster. The tests cover both **Dense models** (GPT, BERT) and **MoE models** (Switch Transformer, GLaM) with comprehensive performance analysis.

### Why These Tests Matter

- **Dense Models**: Rely on AllReduce for gradient synchronization
- **MoE Models**: Rely on AllToAll for expert routing (latency-critical)
- **Multi-node**: EFA network (3.2Tbps) becomes the bottleneck
- **Optimization**: Proper NCCL tuning can improve performance by 20-30%

## Quick Start (NGC Container - Recommended)

```bash
# 1. SSH to LoginNode
ssh -i your-key.pem ubuntu@<loginnode-ip>

# 2. Import NGC container (one-time setup)
cd /fsx/containers
enroot import docker://nvcr.io/nvidia/pytorch:24.11-py3

# 3. Run Phase 1 (baseline check)
sbatch /fsx/config/nccl/phase1-baseline-container.sbatch

# 4. Check results
squeue  # Wait for completion
cat /fsx/nccl-results/phase1_container_*/phase1-baseline-report.txt
```

## Quick Start (Direct Install - Advanced)

```bash
# 1. SSH to LoginNode
ssh -i your-key.pem ubuntu@<loginnode-ip>

# 2. Install NCCL tests (one-time setup)
cd /fsx/nccl
srun --nodes=1 --ntasks=1 --gpus=1 bash install-nccl-tests.sh

# 3. Run Phase 1 (baseline check)
sbatch phase1-baseline.sbatch

# 4. Check results
squeue  # Wait for completion
cat /fsx/nccl-results/phase1_*/phase1-baseline-report.txt
```

## Testing Framework

### Phase 1: Baseline Performance (30 min)

**Purpose**: Verify basic NCCL functionality on single node

**Tests**:
- AllReduce (Dense model gradient sync)
- AllToAll (MoE expert routing)

**Command (NGC Container)**:
```bash
sbatch phase1-baseline-container.sbatch
```

**Command (Direct Install)**:
```bash
sbatch phase1-baseline.sbatch
```

**What to check**:
-  AllReduce: >800 GB/s for 1GB messages
-  AllToAll: >200 GB/s for 128MB messages
-  AllToAll latency: <100us for 8MB messages

**Output**: `/fsx/nccl-results/phase1_<timestamp>/`

---

### Phase 2: Multi-Node Scaling (1 hour)

**Purpose**: Validate scaling across nodes and EFA network performance

**Tests**:
- Multi-node AllReduce scaling
- Multi-node AllToAll scaling
- Ring vs Tree algorithm comparison

**Command (NGC Container)**:
```bash
sbatch phase2-multinode-container.sbatch
```

**Command (Direct Install)**:
```bash
sbatch phase2-multinode.sbatch
```

**What to check**:
-  Scaling efficiency: >90%
-  Network utilization: >80% of 3.2Tbps
-  Inter-node latency: <20us overhead

**Output**: `/fsx/nccl-results/phase2_<timestamp>/`

---

### Phase 3: Real Workload Simulation (1.5 hours)

**Purpose**: Test actual training communication patterns

**Tests**:
- MoE expert capacity sweep (64, 128, 256, 512 tokens)
- Latency-sensitive operations (1KB-1MB)
- Bandwidth-sensitive operations (128MB-2GB)
- Bi-directional bandwidth
- Mixed communication patterns

**Command (NGC Container)**:
```bash
sbatch phase3-workload-container.sbatch
```

**Command (Direct Install)**:
```bash
sbatch phase3-workload.sbatch
```

**What to check**:
-  Optimal expert capacity for your cluster
-  Small message latency: <50us
-  Large message bandwidth: >800 GB/s
-  Mixed pattern performance

**Output**: `/fsx/nccl-results/phase3_<timestamp>/`

---

### Phase 4: Optimization Validation (1 hour)

**Purpose**: Tune NCCL parameters for optimal performance

**Tests**:
- Protocol comparison (Simple, LL, LL128)
- Buffer size tuning (4MB, 8MB, 16MB)
- Channel count optimization (8, 16, 32)
- EFA-specific optimizations

**Command (NGC Container)**:
```bash
sbatch phase4-optimization-container.sbatch
```

**Command (Direct Install)**:
```bash
sbatch phase4-optimization.sbatch
```

**What to check**:
-  Best protocol for your workload
-  Optimal buffer size
-  Optimal channel count
-  EFA optimization gains (5-10%)

**Output**: `/fsx/nccl-results/phase4_<timestamp>/`

---

## Complete Test Sequence

### NGC Container (Recommended)

```bash
# Phase 1: Baseline (30 min)
sbatch phase1-baseline-container.sbatch
# Wait for completion, review results

# Phase 2: Multi-node (1 hour)
sbatch phase2-multinode-container.sbatch
# Wait for completion, review results

# Phase 3: Workload (1.5 hours)
sbatch phase3-workload-container.sbatch
# Wait for completion, review results

# Phase 4: Optimization (1 hour)
sbatch phase4-optimization-container.sbatch
# Wait for completion, review results

# Total time: ~4 hours for complete characterization
```

### Direct Install (Advanced)

```bash
# Phase 1: Baseline (30 min)
sbatch phase1-baseline.sbatch
# Wait for completion, review results

# Phase 2: Multi-node (1 hour)
sbatch phase2-multinode.sbatch
# Wait for completion, review results

# Phase 3: Workload (1.5 hours)
sbatch phase3-workload.sbatch
# Wait for completion, review results

# Phase 4: Optimization (1 hour)
sbatch phase4-optimization.sbatch
# Wait for completion, review results

# Total time: ~4 hours for complete characterization
```

## Understanding Results

### Key Metrics

#### For Dense Models (GPT, BERT, etc.)
- **AllReduce Bandwidth**: >800 GB/s (single node), >1600 GB/s (2 nodes)
- **Scaling Efficiency**: >90% across nodes
- **Message Size**: Typically 128MB-2GB (model gradients)

#### For MoE Models (Switch, GLaM, etc.)
- **AllToAll Bandwidth**: >200 GB/s (single node), >300 GB/s per node (multi-node)
- **AllToAll Latency**: <50us for small messages (critical!)
- **Expert Capacity**: 128-256 tokens per expert (optimal range)
- **Message Size**: Varies (4KB-512MB depending on capacity)

### Performance Targets

| Metric | Single Node | Multi-Node (2+) |
|--------|-------------|-----------------|
| AllReduce (1GB) | 800-1200 GB/s | >90% scaling |
| AllToAll (128MB) | 200-400 GB/s | 300-400 GB/s per node |
| AllToAll Latency (8MB) | <20us | <50us |
| Network Utilization | N/A | >80% of 3.2Tbps |

## Recommended NCCL Settings

### For Dense Models

```bash
# Add to your training script or Slurm job

export NCCL_PROTO=Simple
export NCCL_ALGO=Ring
export NCCL_BUFFSIZE=8388608        # 8MB
export NCCL_MIN_NCHANNELS=8
export NCCL_MAX_NCHANNELS=16

# EFA optimizations (AWS)
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export FI_EFA_FORK_SAFE=1
export FI_EFA_ENABLE_SHM_TRANSFER=1
export FI_EFA_USE_HUGE_PAGE=1

# Network settings
export NCCL_SOCKET_IFNAME=^docker0,lo
export NCCL_IB_DISABLE=1
export NCCL_P2P_DISABLE=0
export NCCL_SHM_DISABLE=0
export NCCL_NET_GDR_LEVEL=PIX
export NCCL_CROSS_NIC=0
export NCCL_NVLS_ENABLE=1
```

### For MoE Models

```bash
# Add to your training script or Slurm job

export NCCL_PROTO=Simple
export NCCL_ALGO=Ring,Tree
export NCCL_BUFFSIZE=8388608        # 8MB
export NCCL_MIN_NCHANNELS=16        # More channels for AllToAll
export NCCL_MAX_NCHANNELS=32
export NCCL_NTHREADS=512            # More threads for parallel ops

# EFA optimizations (AWS)
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export FI_EFA_FORK_SAFE=1
export FI_EFA_ENABLE_SHM_TRANSFER=1
export FI_EFA_USE_HUGE_PAGE=1

# Network settings
export NCCL_SOCKET_IFNAME=^docker0,lo
export NCCL_IB_DISABLE=1
export NCCL_P2P_DISABLE=0
export NCCL_SHM_DISABLE=0
export NCCL_NET_GDR_LEVEL=PIX
export NCCL_CROSS_NIC=0
export NCCL_NVLS_ENABLE=1

# MoE-specific
export NCCL_TREE_THRESHOLD=0        # Use tree for large messages
```

## Troubleshooting

### Low Performance

**Symptoms**: Bandwidth <50% of expected

**Check**:
```bash
# 1. GPU topology
nvidia-smi topo -m

# 2. NCCL settings
env | grep NCCL

# 3. EFA status
fi_info -p efa

# 4. Network interface
ifconfig | grep ens
```

**Solutions**:
- Verify EFA is enabled: `FI_PROVIDER=efa`
- Check NCCL_DEBUG logs for warnings
- Ensure correct network interface: `NCCL_SOCKET_IFNAME=^docker0,lo`

### High Latency (MoE Critical)

**Symptoms**: AllToAll latency >100us for small messages

**Check**:
```bash
# Run latency-specific test
srun --mpi=pmix --ntasks=16 \
  /opt/nccl-tests/alltoall_perf -b 1K -e 1M -f 2 -g 1 -w 20 -n 100
```

**Solutions**:
- Use LL protocol for small messages: `NCCL_PROTO=LL`
- Increase channel count: `NCCL_MIN_NCHANNELS=16`
- Enable SHM transfer: `FI_EFA_ENABLE_SHM_TRANSFER=1`

### Poor Scaling

**Symptoms**: Multi-node performance <80% of single-node × nodes

**Check**:
```bash
# Network connectivity
ping <other-node>

# EFA bandwidth
efa_test -s <server-node> -c <client-node>
```

**Solutions**:
- Verify EFA RDMA: `FI_EFA_USE_DEVICE_RDMA=1`
- Check network topology
- Review NCCL_DEBUG logs for timeout warnings

## File Structure

After running all phases:

```
/fsx/nccl-results/
├── phase1_<timestamp>/
│   ├── allreduce-dense.log
│   ├── alltoall-moe.log
│   └── phase1-baseline-report.txt
│
├── phase2_<timestamp>/
│   ├── allreduce-multinode.log
│   ├── alltoall-multinode.log
│   ├── allreduce-ring.log
│   ├── allreduce-tree.log
│   └── phase2-multinode-report.txt
│
├── phase3_<timestamp>/
│   ├── moe-capacity-*.log
│   ├── latency-sensitive.log
│   ├── bandwidth-sensitive.log
│   ├── bidirectional.log
│   ├── mixed-*.log
│   └── phase3-workload-report.txt
│
└── phase4_<timestamp>/
    ├── proto-*.log
    ├── buffsize-*.log
    ├── channels-*.log
    ├── efa-*.log
    └── phase4-optimization-report.txt
```

## Scripts in This Directory

| Script | Purpose | Duration |
|--------|---------|----------|
| `install-nccl-shared.sh` | Install NCCL to shared storage (HeadNode) | 10-15 min |
| `use-shared-nccl.sh` | Configure ComputeFleet to use shared NCCL | 10-30 sec |
| `install-nccl-tests.sh` | Install official NCCL tests | 5-10 min |
| `phase1-baseline.sbatch` | Single-node baseline tests | 30 min |
| `phase2-multinode.sbatch` | Multi-node scaling tests | 1 hour |
| `phase3-workload.sbatch` | Real workload simulation | 1.5 hours |
| `phase4-optimization.sbatch` | NCCL parameter tuning | 1 hour |

## Best Practices

1. **Run tests in order**: Each phase builds on previous results
2. **Review reports**: Check performance targets before proceeding
3. **Save results**: Keep test results for future reference
4. **Re-test after changes**: Re-run if you modify cluster configuration
5. **Monitor during training**: Actual training may reveal additional issues

## MoE-Specific Considerations

### Expert Capacity Selection

Based on Phase 3 results, choose expert capacity that balances:
- **Lower capacity (64-128)**: Better latency, more frequent communication
- **Higher capacity (256-512)**: Better bandwidth, less frequent communication

Typical recommendation: **128-256 tokens per expert**

### Load Balancing

Critical for MoE performance:
- Use auxiliary loss to balance expert selection
- Monitor expert utilization during training
- Adjust capacity factor if needed

### Communication Overlap

Optimize MoE training:
- Overlap AllToAll with computation when possible
- Use async communication APIs
- Pipeline expert processing

## References

- [NCCL Documentation](https://docs.nvidia.com/deeplearning/nccl/)
- [NCCL Tests Repository](https://github.com/NVIDIA/nccl-tests)
- [AWS EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [MoE Architecture Papers](https://arxiv.org/abs/2101.03961)
- [DeepSpeed MoE](https://www.deepspeed.ai/tutorials/mixture-of-experts/)
- [Megatron-LM](https://github.com/NVIDIA/Megatron-LM)

## Support

For issues or questions:
1. Check NCCL_DEBUG logs in test output files
2. Review phase reports for specific recommendations
3. Consult AWS ParallelCluster documentation
4. Check NCCL GitHub issues for known problems

