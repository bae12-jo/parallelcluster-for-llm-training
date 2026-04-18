# NCCL Performance Testing Guide

Complete guide for validating NCCL performance on AWS ParallelCluster with GPU instances.

##  Overview

This guide covers 4 phases of NCCL testing to validate your cluster's communication performance:

| Phase | Purpose | Duration | Nodes | Key Metrics |
|-------|---------|----------|-------|-------------|
| **Phase 1** | Baseline single-node | 30 min | 1 | Bus bandwidth, NVLink |
| **Phase 2** | Multi-node scaling | 60 min | 2+ | EFA network, scaling efficiency |
| **Phase 3** | Real workload simulation | 90 min | 2+ | MoE patterns, latency |
| **Phase 4** | Optimization validation | 60 min | 2+ | Tuning parameters |

**Total testing time**: ~4 hours for complete validation

##  Testing Goals

### Dense Models (GPT, BERT, LLaMA)
- **AllReduce bandwidth**: >800 GB/s per node
- **Scaling efficiency**: >90% across nodes
- **Latency**: <5ms for 1GB messages

### MoE Models (Switch Transformer, GLaM)
- **AllToAll bandwidth**: >300 GB/s per node
- **AllToAll latency**: <50μs for small messages
- **Expert capacity**: Optimal balance found
- **Network utilization**: >80% of 3.2Tbps EFA

##  Test Files Location

All test scripts are in `config/nccl/`:

```
config/nccl/
├── README.md                           # This guide
├── install-nccl-tests.sh               # Install NCCL tests
├── phase1-baseline.sbatch              # Phase 1: Single-node baseline
├── phase1-baseline-container.sbatch    # Phase 1: Container version
├── phase2-multinode.sbatch             # Phase 2: Multi-node scaling
├── phase3-workload.sbatch              # Phase 3: Real workload
├── phase3-workload-container.sbatch    # Phase 3: Container version
├── phase4-optimization.sbatch          # Phase 4: Optimization
└── phase4-optimization-container.sbatch # Phase 4: Container version
```

##  Quick Start

### Prerequisites

1. **Cluster running** with GPU compute nodes
2. **FSx Lustre** mounted at `/fsx`
3. **NCCL installed** (via CustomActions or shared storage)
4. **NCCL tests installed**:

```bash
# Install NCCL tests to /fsx
bash /fsx/nccl/install-nccl-tests.sh

# Verify installation
ls -la /opt/nccl-tests/
```

### Run All Phases

```bash
# Phase 1: Baseline (single node)
sbatch /fsx/nccl/phase1-baseline.sbatch

# Wait for completion, then check results
squeue
cat /fsx/nccl-results/phase1-baseline-report.txt

# Phase 2: Multi-node scaling (2+ nodes)
sbatch /fsx/nccl/phase2-multinode.sbatch

# Phase 3: Real workload simulation
sbatch /fsx/nccl/phase3-workload.sbatch

# Phase 4: Optimization validation
sbatch /fsx/nccl/phase4-optimization.sbatch
```

### Monitor Progress

```bash
# Check job status
squeue

# Watch job output in real-time
tail -f /fsx/nccl-results/phase1-baseline_*.out

# View all results
ls -la /fsx/nccl-results/
```

---

## Phase 1: Baseline Performance Check

**Purpose**: Verify basic NCCL functionality on a single node

### What It Tests

1. **AllReduce (Dense Model Pattern)**
   - Gradient synchronization for dense models
   - Message sizes: 128MB to 2GB
   - Tests NVLink bandwidth between GPUs

2. **AllToAll (MoE Model Pattern)**
   - Token routing to experts in MoE models
   - Message sizes: 8MB to 512MB
   - Tests GPU-to-GPU communication

### Expected Results

**Dense Model (AllReduce)**:
- **Target**: >800 GB/s for 1GB messages
- **Expected**: 800-1200 GB/s (single node with NVLink)
- **Critical**: Should see near-linear scaling with message size

**MoE Model (AllToAll)**:
- **Target**: >200 GB/s for 128MB messages
- **Latency**: <100μs for 8MB messages
- **Expected**: 200-400 GB/s (single node)

### Run Phase 1

```bash
# Standard version (requires NCCL installed)
sbatch /fsx/nccl/phase1-baseline.sbatch

# Container version (self-contained)
sbatch /fsx/nccl/phase1-baseline-container.sbatch
```

### Interpret Results

```bash
# View summary report
cat /fsx/nccl-results/phase1_*/phase1-baseline-report.txt

# Check detailed logs
cat /fsx/nccl-results/phase1_*/allreduce-dense.log
cat /fsx/nccl-results/phase1_*/alltoall-moe.log
```

**Key metrics to check**:
```
# AllReduce results (look for these lines)
1073741824  # 1GB message
  Avg bus bandwidth: 1000.00 GB/s  ← Should be >800 GB/s
  Time: 4.50 ms                     ← Should be <10ms

# AllToAll results
134217728   # 128MB message
  Avg bus bandwidth: 300.00 GB/s   ← Should be >200 GB/s
  Latency: 45.00 us                 ← Should be <100us
```

### Troubleshooting Phase 1

**Low bandwidth (<500 GB/s)**:
```bash
# Check GPU topology
nvidia-smi topo -m

# Should show NVLink connections (NV12 or higher)
# If showing "PIX" or "SYS", NVLink may not be working
```

**High latency (>200μs)**:
```bash
# Check NCCL settings
env | grep NCCL

# Verify P2P is enabled
echo $NCCL_P2P_DISABLE  # Should be 0 or empty
```

---

## Phase 2: Multi-Node Scaling Tests

**Purpose**: Validate EFA network performance and scaling efficiency

### What It Tests

1. **Multi-node AllReduce**
   - Gradient sync across nodes via EFA
   - Tests inter-node bandwidth
   - Validates scaling efficiency

2. **Multi-node AllToAll**
   - Expert routing across nodes
   - Critical for MoE expert parallelism
   - Tests network latency

3. **Algorithm Comparison**
   - Ring vs Tree algorithms
   - Finds optimal algorithm for cluster size

### Expected Results

**Dense Model (AllReduce)**:
- **2-node target**: >1600 GB/s aggregate (>90% efficiency)
- **4-node target**: >3200 GB/s aggregate
- **Network**: Should utilize >80% of 3.2Tbps EFA

**MoE Model (AllToAll)**:
- **Target**: >300 GB/s per node
- **Latency increase**: <20μs vs single-node
- **Scaling**: Should maintain >80% efficiency

### Run Phase 2

```bash
# Requires 2+ nodes
sbatch --nodes=2 /fsx/nccl/phase2-multinode.sbatch

# Or test with 4 nodes
sbatch --nodes=4 /fsx/nccl/phase2-multinode.sbatch
```

### Interpret Results

```bash
# View scaling report
cat /fsx/nccl-results/phase2_*/phase2-multinode-report.txt

# Calculate scaling efficiency
# Efficiency = (Multi-node BW) / (Single-node BW × Nodes)
```

**Example calculation**:
```
Single-node: 1000 GB/s
2-node:      1800 GB/s
Efficiency:  1800 / (1000 × 2) = 90%  Good!

If efficiency < 80%:
  → Check EFA configuration
  → Review network topology
  → Look for NCCL warnings in logs
```

### Troubleshooting Phase 2

**Low scaling efficiency (<70%)**:
```bash
# Check EFA status
fi_info -p efa

# Verify EFA is being used
grep "Using network EFA" /fsx/nccl-results/phase2_*/phase2-multinode_*.err

# Check for network errors
dmesg | grep -i efa
```

**High latency increase (>50μs)**:
```bash
# Check EFA settings
env | grep FI_EFA

# Verify RDMA is enabled
echo $FI_EFA_USE_DEVICE_RDMA  # Should be 1
```

---

## Phase 3: Real Workload Simulation

**Purpose**: Test actual MoE and Dense model communication patterns

### What It Tests

1. **MoE Expert Capacity Sweep**
   - Tests 64, 128, 256, 512 tokens per expert
   - Finds optimal capacity for your cluster
   - Balances latency vs bandwidth

2. **Latency-Sensitive Operations**
   - Small messages (1KB to 1MB)
   - MoE routing and control messages
   - Critical for MoE performance

3. **Bandwidth-Sensitive Operations**
   - Large messages (128MB to 2GB)
   - Dense model gradient sync
   - Tests peak throughput

4. **Bi-directional Bandwidth**
   - Simultaneous send/receive
   - Realistic training simulation
   - Tests full-duplex capability

5. **Mixed Communication Pattern**
   - AllToAll + ReduceScatter + AllReduce
   - Simulates real MoE training
   - Tests concurrent operations

### Expected Results

**Expert Capacity**:
- **64 tokens**: Best latency, more frequent communication
- **128 tokens**: Balanced (recommended for most cases)
- **256 tokens**: Better bandwidth, less frequent
- **512 tokens**: Maximum bandwidth, highest latency

**Latency-Sensitive**:
- **1KB-1MB**: <50μs latency critical for MoE
- **Throughput**: Less important than latency

**Bandwidth-Sensitive**:
- **128MB-2GB**: >800 GB/s for dense models
- **Latency**: Less critical than throughput

### Run Phase 3

```bash
# Requires 2+ nodes
sbatch --nodes=2 /fsx/nccl/phase3-workload.sbatch

# Container version
sbatch --nodes=2 /fsx/nccl/phase3-workload-container.sbatch
```

### Interpret Results

```bash
# View workload analysis
cat /fsx/nccl-results/phase3_*/phase3-workload-report.txt

# Check expert capacity results
for capacity in 64 128 256 512; do
  echo "Capacity: $capacity"
  cat /fsx/nccl-results/phase3_*/moe-capacity-${capacity}.log | tail -5
done
```

**Choosing optimal expert capacity**:
```
Capacity 64:  250 GB/s, 30us latency  ← Best latency
Capacity 128: 300 GB/s, 45us latency  ← Balanced 
Capacity 256: 320 GB/s, 80us latency  ← Best bandwidth
Capacity 512: 330 GB/s, 150us latency ← Too high latency

Recommendation: Use 128 for balanced performance
```

### Troubleshooting Phase 3

**High latency (>100μs) for small messages**:
```bash
# Reduce buffer size
export NCCL_BUFFSIZE=4194304  # 4MB instead of 8MB

# Use LL protocol for small messages
export NCCL_PROTO=LL
```

**Low bandwidth for large messages**:
```bash
# Increase buffer size
export NCCL_BUFFSIZE=16777216  # 16MB

# Use Simple protocol
export NCCL_PROTO=Simple
```

---

## Phase 4: Optimization Validation

**Purpose**: Validate NCCL tuning parameters and EFA optimizations

### What It Tests

1. **NCCL Protocol Comparison**
   - Simple: Best for large messages (>64MB)
   - LL: Low-latency for small messages (<1MB)
   - LL128: Balanced approach

2. **Buffer Size Tuning**
   - 4MB: Lower latency, less bandwidth
   - 8MB: Balanced (recommended)
   - 16MB: Higher bandwidth, more latency

3. **Channel Count Optimization**
   - 8 channels: Dense models
   - 16 channels: Balanced
   - 32 channels: MoE models (more parallelism)

4. **EFA-Specific Optimizations**
   - Shared memory transfer
   - Huge page support
   - RDMA optimizations

### Expected Results

**Protocol Performance**:
- **Simple**: Best for >64MB (800+ GB/s)
- **LL**: Best for <1MB (lowest latency)
- **LL128**: Middle ground

**Buffer Size**:
- **4MB**: Good for latency-sensitive
- **8MB**: Best overall balance
- **16MB**: Maximum bandwidth

**Channel Count**:
- **8**: Sufficient for dense models
- **16**: Good for mixed workloads
- **32**: Best for MoE (more AllToAll)

**EFA Optimization**:
- **5-10% improvement** with SHM + Huge Pages

### Run Phase 4

```bash
# Requires 2+ nodes
sbatch --nodes=2 /fsx/nccl/phase4-optimization.sbatch

# Container version
sbatch --nodes=2 /fsx/nccl/phase4-optimization-container.sbatch
```

### Interpret Results

```bash
# View optimization report
cat /fsx/nccl-results/phase4_*/phase4-optimization-report.txt

# Compare protocols
grep "1GB:" /fsx/nccl-results/phase4_*/proto-*.log

# Compare buffer sizes
grep "1GB:" /fsx/nccl-results/phase4_*/buffsize-*.log
```

### Recommended Settings

**For Dense Models (GPT, BERT, LLaMA)**:
```bash
# Protocol and algorithm
export NCCL_PROTO=Simple
export NCCL_ALGO=Ring

# Buffer and channels
export NCCL_BUFFSIZE=8388608        # 8MB
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
export NCCL_CROSS_NIC=0
export NCCL_NVLS_ENABLE=1
```

**For MoE Models (Switch, GLaM, Mixtral)**:
```bash
# Protocol and algorithm
export NCCL_PROTO=Simple
export NCCL_ALGO=Ring,Tree
export NCCL_TREE_THRESHOLD=0        # Use tree for large messages

# Buffer and channels (more parallelism)
export NCCL_BUFFSIZE=8388608        # 8MB
export NCCL_MIN_NCHANNELS=16        # More channels for AllToAll
export NCCL_MAX_NCHANNELS=32
export NCCL_NTHREADS=512            # More threads

# EFA optimizations
export FI_EFA_ENABLE_SHM_TRANSFER=1
export FI_EFA_USE_HUGE_PAGE=1
export FI_EFA_USE_DEVICE_RDMA=1

# Network
export NCCL_IB_DISABLE=1
export NCCL_P2P_DISABLE=0
export NCCL_NET_GDR_LEVEL=PIX
export NCCL_CROSS_NIC=0
export NCCL_NVLS_ENABLE=1
```

---

##  Results Analysis

### Generate Combined Report

```bash
# Combine all phase reports
cat /fsx/nccl-results/phase*/phase*-report.txt > /fsx/nccl-results/complete-report.txt

# View complete report
less /fsx/nccl-results/complete-report.txt
```

### Performance Checklist

Use this checklist to validate your cluster:

- [ ] **Phase 1 Baseline**
  - [ ] AllReduce: >800 GB/s for 1GB messages
  - [ ] AllToAll: >200 GB/s for 128MB messages
  - [ ] Latency: <100μs for small messages

- [ ] **Phase 2 Scaling**
  - [ ] Scaling efficiency: >90%
  - [ ] Network utilization: >80% of 3.2Tbps
  - [ ] Latency increase: <20μs vs single-node

- [ ] **Phase 3 Workload**
  - [ ] Expert capacity optimized
  - [ ] Latency-sensitive: <50μs
  - [ ] Bandwidth-sensitive: >800 GB/s
  - [ ] Mixed pattern: All operations working

- [ ] **Phase 4 Optimization**
  - [ ] Optimal protocol identified
  - [ ] Buffer size tuned
  - [ ] Channel count optimized
  - [ ] EFA optimizations validated

### Common Issues and Solutions

| Issue | Symptom | Solution |
|-------|---------|----------|
| **Low NVLink bandwidth** | <500 GB/s single-node | Check `nvidia-smi topo -m`, verify NVLink |
| **Poor scaling** | <70% efficiency | Check EFA with `fi_info -p efa` |
| **High latency** | >100μs for small msgs | Use LL protocol, reduce buffer size |
| **Low bandwidth** | <600 GB/s multi-node | Increase buffer size, check EFA RDMA |
| **NCCL errors** | Timeouts, hangs | Check `NCCL_DEBUG=INFO` logs |

---

##  Advanced Tuning

### For Specific Instance Types

**p5en.48xlarge (H100)**:
```bash
# Optimized for H100 NVLink
export NCCL_NVLS_ENABLE=1           # Enable NVSwitch
export NCCL_NET_GDR_LEVEL=PIX       # GPU Direct RDMA
export NCCL_P2P_LEVEL=NVL           # NVLink for P2P
```

**p4d.24xlarge (A100)**:
```bash
# Optimized for A100 NVLink
export NCCL_NVLS_ENABLE=0           # No NVSwitch on A100
export NCCL_NET_GDR_LEVEL=PIX
export NCCL_P2P_LEVEL=NVL
```

### For Large Clusters (>8 nodes)

```bash
# Use Tree algorithm for better scaling
export NCCL_ALGO=Tree
export NCCL_TREE_THRESHOLD=0

# Increase channels for more parallelism
export NCCL_MIN_NCHANNELS=16
export NCCL_MAX_NCHANNELS=32

# Larger buffers for bandwidth
export NCCL_BUFFSIZE=16777216       # 16MB
```

### Debug Mode

```bash
# Enable detailed logging
export NCCL_DEBUG=INFO
export NCCL_DEBUG_SUBSYS=ALL

# Run test and check logs
sbatch phase1-baseline.sbatch
cat /fsx/nccl-results/phase1-baseline_*.err | grep -i "error\|warn"
```

---

##  Additional Resources

### NCCL Documentation
- [NCCL User Guide](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/)
- [NCCL Environment Variables](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html)
- [NCCL Tests Repository](https://github.com/NVIDIA/nccl-tests)

### AWS Documentation
- [EFA User Guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [P5 Instance Guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/p5-instances.html)
- [ParallelCluster Performance](https://docs.aws.amazon.com/parallelcluster/latest/ug/best-practices.html)

### Related Guides
- [NCCL Installation Guide](../config/nccl/README.md)
- [NCCL Container Usage](../config/nccl/README-CONTAINER.md)
- [NCCL Installation Timing](NCCL-INSTALLATION-TIMING.md)
- [EFA Monitoring](EFA-MONITORING.md)

---

##  Summary

After completing all 4 phases, you should have:

1.  **Validated baseline performance** (Phase 1)
2.  **Confirmed multi-node scaling** (Phase 2)
3.  **Optimized for your workload** (Phase 3)
4.  **Tuned NCCL parameters** (Phase 4)

Your cluster is now ready for production training!

**Next steps**:
1. Apply recommended settings to your training scripts
2. Monitor performance during actual training
3. Adjust expert capacity based on Phase 3 results
4. Re-run tests if you change cluster configuration

**Questions or issues?**
- Check logs in `/fsx/nccl-results/`
- Review NCCL documentation
- Enable `NCCL_DEBUG=INFO` for detailed diagnostics
