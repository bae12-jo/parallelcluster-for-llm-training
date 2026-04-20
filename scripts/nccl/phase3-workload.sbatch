#!/bin/bash
#SBATCH --job-name=nccl-phase3-workload
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=24
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
#SBATCH --time=01:30:00
#SBATCH --output=/fsx/nccl-results/phase3-workload_%j.out
#SBATCH --error=/fsx/nccl-results/phase3-workload_%j.err

# Phase 3: Real Workload Simulation
# Simulates actual MoE and Dense model communication patterns
# Tests latency-sensitive and bandwidth-sensitive operations

set -e

echo "=========================================="
echo "Phase 3: Real Workload Simulation"
echo "=========================================="
echo "Nodes: $SLURM_NNODES"
echo "Total GPUs: $((SLURM_NNODES * 8))"
echo "Date: $(date)"
echo "Job ID: $SLURM_JOB_ID"
echo ""

# Environment setup
export CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7
export NCCL_DEBUG=WARN  # Reduce verbosity for workload tests
export NCCL_SOCKET_IFNAME=^docker0,lo

# EFA optimizations
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export FI_EFA_FORK_SAFE=1
export FI_EFA_ENABLE_SHM_TRANSFER=1
export FI_EFA_USE_HUGE_PAGE=1

# NCCL optimizations
export NCCL_PROTO=Simple
export NCCL_ALGO=Ring,Tree
export NCCL_IB_DISABLE=1
export NCCL_P2P_DISABLE=0
export NCCL_SHM_DISABLE=0
export NCCL_NET_GDR_LEVEL=PIX
export NCCL_CROSS_NIC=0
export NCCL_NVLS_ENABLE=1

# MoE-specific tuning
export NCCL_MIN_NCHANNELS=16
export NCCL_MAX_NCHANNELS=32
export NCCL_BUFFSIZE=8388608

# Create results directory
mkdir -p /fsx/nccl-results

RESULT_DIR="/fsx/nccl-results/phase3_$(date +%Y%m%d_%H%M%S)"
mkdir -p $RESULT_DIR

echo "Results will be saved to: $RESULT_DIR"
echo ""

# Test 1: MoE Expert Capacity Sweep
echo "=========================================="
echo "Test 1: MoE Expert Capacity Analysis"
echo "=========================================="
echo "Purpose: Find optimal expert capacity for your cluster"
echo "Testing capacities: 64, 128, 256, 512 tokens per expert"
echo ""

for capacity in 64 128 256 512; do
    echo "Testing capacity: $capacity tokens/expert..."
    
    # Calculate message size (capacity * hidden_dim * dtype)
    # Assuming hidden_dim=1024, fp16=2 bytes
    msg_size=$((capacity * 1024 * 2))
    msg_size_end=$((msg_size * 4))
    
    srun --mpi=pmix \
        --ntasks=$SLURM_NTASKS \
        --ntasks-per-node=8 \
        /opt/nccl-tests/alltoall_perf \
        -b $msg_size -e $msg_size_end -f 2 -g 1 -c 1 -n 50 \
        > $RESULT_DIR/moe-capacity-${capacity}.log 2>&1
    
    echo "   Capacity $capacity completed"
done

echo ""
echo " Expert capacity sweep completed"
echo ""

# Test 2: Latency-Sensitive Operations (Small Messages)
echo "=========================================="
echo "Test 2: Latency-Sensitive Operations"
echo "=========================================="
echo "Purpose: Measure latency for control messages and routing"
echo "Message sizes: 1KB to 1MB (typical for MoE routing)"
echo ""

srun --mpi=pmix \
    --ntasks=$SLURM_NTASKS \
    --ntasks-per-node=8 \
    /opt/nccl-tests/alltoall_perf \
    -b 1K -e 1M -f 2 -g 1 -c 1 -n 100 -w 20 \
    | tee $RESULT_DIR/latency-sensitive.log

echo ""
echo " Latency test completed"
echo ""

# Test 3: Bandwidth-Sensitive Operations (Large Messages)
echo "=========================================="
echo "Test 3: Bandwidth-Sensitive Operations"
echo "=========================================="
echo "Purpose: Measure peak bandwidth for gradient sync"
echo "Message sizes: 128MB to 2GB (typical for dense models)"
echo ""

srun --mpi=pmix \
    --ntasks=$SLURM_NTASKS \
    --ntasks-per-node=8 \
    /opt/nccl-tests/all_reduce_perf \
    -b 128M -e 2G -f 2 -g 1 -c 1 -n 50 \
    | tee $RESULT_DIR/bandwidth-sensitive.log

echo ""
echo " Bandwidth test completed"
echo ""

# Test 4: Bi-directional Bandwidth (Realistic Training)
echo "=========================================="
echo "Test 4: Bi-directional Bandwidth Test"
echo "=========================================="
echo "Purpose: Simulate simultaneous send/receive in training"
echo ""

srun --mpi=pmix \
    --ntasks=$SLURM_NTASKS \
    --ntasks-per-node=8 \
    /opt/nccl-tests/sendrecv_perf \
    -b 1M -e 1G -f 2 -g 1 -c 1 -n 50 \
    | tee $RESULT_DIR/bidirectional.log

echo ""
echo " Bi-directional test completed"
echo ""

# Test 5: Mixed Pattern (MoE Training Simulation)
echo "=========================================="
echo "Test 5: Mixed Communication Pattern"
echo "=========================================="
echo "Purpose: Simulate real MoE training with mixed operations"
echo ""

# AllToAll for expert routing
echo "  Running AllToAll (expert routing)..."
srun --mpi=pmix \
    --ntasks=$SLURM_NTASKS \
    --ntasks-per-node=8 \
    /opt/nccl-tests/alltoall_perf \
    -b 16M -e 256M -f 2 -g 1 -c 1 -n 30 \
    > $RESULT_DIR/mixed-alltoall.log 2>&1

# ReduceScatter for expert output aggregation
echo "  Running ReduceScatter (expert aggregation)..."
srun --mpi=pmix \
    --ntasks=$SLURM_NTASKS \
    --ntasks-per-node=8 \
    /opt/nccl-tests/reduce_scatter_perf \
    -b 16M -e 256M -f 2 -g 1 -c 1 -n 30 \
    > $RESULT_DIR/mixed-reducescatter.log 2>&1

# AllReduce for shared parameter gradients
echo "  Running AllReduce (gradient sync)..."
srun --mpi=pmix \
    --ntasks=$SLURM_NTASKS \
    --ntasks-per-node=8 \
    /opt/nccl-tests/all_reduce_perf \
    -b 128M -e 512M -f 2 -g 1 -c 1 -n 30 \
    > $RESULT_DIR/mixed-allreduce.log 2>&1

echo ""
echo " Mixed pattern test completed"
echo ""

# Generate workload report
echo "=========================================="
echo "Generating Workload Analysis Report"
echo "=========================================="

REPORT_FILE="$RESULT_DIR/phase3-workload-report.txt"

cat > $REPORT_FILE << EOF
=== Phase 3: Real Workload Simulation Report ===
Generated: $(date)
Nodes: $SLURM_NNODES
Total GPUs: $((SLURM_NNODES * 8))

=== Test Results ===

1. MoE Expert Capacity Analysis
   Purpose: Find optimal expert capacity for performance
   
EOF

for capacity in 64 128 256 512; do
    echo "   Capacity $capacity tokens/expert:" >> $REPORT_FILE
    grep -E "[0-9]{6,}" $RESULT_DIR/moe-capacity-${capacity}.log | tail -3 | \
        awk '{printf "     %10s: %8.2f GB/s, %8.2f us\n", $1, $6, $4}' >> $REPORT_FILE
done

cat >> $REPORT_FILE << EOF

   Recommendation: Choose capacity with best bandwidth/latency balance
   - Lower capacity: Better latency, more frequent communication
   - Higher capacity: Better bandwidth, less frequent communication

2. Latency-Sensitive Operations (MoE Routing)
   Purpose: Measure overhead of frequent small messages
   
EOF

echo "   Key Results:" >> $REPORT_FILE
grep -E "(1024|4096|16384|65536|262144|1048576)" $RESULT_DIR/latency-sensitive.log | \
    awk '{printf "   %10s: %8.2f us latency, %8.2f GB/s\n", $1, $4, $6}' >> $REPORT_FILE

cat >> $REPORT_FILE << EOF

   Critical for MoE: Latency <50us for good performance

3. Bandwidth-Sensitive Operations (Dense Gradient Sync)
   Purpose: Measure peak throughput for large transfers
   
EOF

echo "   Key Results:" >> $REPORT_FILE
grep -E "(134217728|268435456|536870912|1073741824|2147483648)" $RESULT_DIR/bandwidth-sensitive.log | \
    awk '{printf "   %10s: %8.2f GB/s, %8.2f ms\n", $1, $6, $4/1000}' >> $REPORT_FILE

cat >> $REPORT_FILE << EOF

4. Bi-directional Bandwidth (Realistic Training)
   Purpose: Simultaneous send/receive as in real training
   
EOF

echo "   Key Results:" >> $REPORT_FILE
grep -E "(1048576|16777216|134217728|1073741824)" $RESULT_DIR/bidirectional.log | \
    awk '{printf "   %10s: %8.2f GB/s\n", $1, $6}' >> $REPORT_FILE

cat >> $REPORT_FILE << EOF

5. Mixed Communication Pattern (MoE Training)
   Purpose: Simulate real MoE training workload
   
   AllToAll (Expert Routing):
EOF

grep -E "(16777216|67108864|268435456)" $RESULT_DIR/mixed-alltoall.log | \
    awk '{printf "     %10s: %8.2f GB/s\n", $1, $6}' >> $REPORT_FILE

cat >> $REPORT_FILE << EOF
   
   ReduceScatter (Expert Aggregation):
EOF

grep -E "(16777216|67108864|268435456)" $RESULT_DIR/mixed-reducescatter.log | \
    awk '{printf "     %10s: %8.2f GB/s\n", $1, $6}' >> $REPORT_FILE

cat >> $REPORT_FILE << EOF
   
   AllReduce (Gradient Sync):
EOF

grep -E "(134217728|268435456|536870912)" $RESULT_DIR/mixed-allreduce.log | \
    awk '{printf "     %10s: %8.2f GB/s\n", $1, $6}' >> $REPORT_FILE

cat >> $REPORT_FILE << EOF

=== Performance Checklist ===

 Bus Bandwidth: Should be >90% of theoretical peak
 AllToAll Latency: <50us for small messages (MoE critical)
 AllReduce Bandwidth: >800 GB/s for large messages
 Network Utilization: >80% of 3.2Tbps EFA
 Scaling Efficiency: >90% across nodes

=== MoE Model Recommendations ===

Based on test results:

1. Expert Capacity: Choose capacity with best performance
   - Typical range: 128-256 tokens per expert
   - Balance: Latency vs bandwidth

2. Expert Count: 
   - More experts = more AllToAll communication
   - Optimal: 8-64 experts per node

3. Load Balancing:
   - Critical for maintaining high utilization
   - Use auxiliary loss to balance expert selection

4. Communication Overlap:
   - Overlap AllToAll with computation when possible
   - Use async communication APIs

=== Next Steps ===

If workload tests pass:
  → Run Phase 4: Optimization validation
  → Command: sbatch phase4-optimization.sbatch

If performance is below target:
  → Adjust expert capacity based on results
  → Tune NCCL settings (NCCL_BUFFSIZE, NCCL_NCHANNELS)
  → Review network utilization

=== Files Generated ===
  - moe-capacity-*.log: Expert capacity sweep results
  - latency-sensitive.log: Small message latency
  - bandwidth-sensitive.log: Large message bandwidth
  - bidirectional.log: Bi-directional bandwidth
  - mixed-*.log: Mixed pattern simulation
  - phase3-workload-report.txt: This summary report
EOF

echo ""
echo "=========================================="
echo "Phase 3 Workload Tests Completed!"
echo "=========================================="
echo ""
echo "Results saved to: $RESULT_DIR"
echo "Report: $REPORT_FILE"
echo ""
echo "Quick Summary:"
cat $REPORT_FILE
echo ""
echo "Next: sbatch phase4-optimization.sbatch"
