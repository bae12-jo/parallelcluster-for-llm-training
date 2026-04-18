#!/bin/bash
#SBATCH --job-name=nccl-phase3-container
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=24
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
#SBATCH --time=01:30:00
#SBATCH --output=/fsx/nccl-results/phase3-container_%j.out
#SBATCH --error=/fsx/nccl-results/phase3-container_%j.err

# Phase 3: Real Workload Simulation (NGC Container Version)
# Simulates actual MoE and Dense model communication patterns
# Tests latency-sensitive and bandwidth-sensitive operations

set -e

echo "=========================================="
echo "Phase 3: Real Workload Simulation (Container)"
echo "=========================================="
echo "Nodes: $SLURM_NNODES"
echo "Total GPUs: $((SLURM_NNODES * 8))"
echo "Date: $(date)"
echo "Job ID: $SLURM_JOB_ID"
echo "Container: nvcr.io/nvidia/pytorch:24.11-py3"
echo ""

# NGC Container path
CONTAINER_IMAGE="/fsx/containers/pytorch+24.11-py3.sqsh"

# Check if container exists
if [ ! -f "$CONTAINER_IMAGE" ]; then
    echo "ERROR: Container not found at $CONTAINER_IMAGE"
    exit 1
fi

# Create results directory
RESULT_DIR="/fsx/nccl-results/phase3_container_$(date +%Y%m%d_%H%M%S)"
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
    
    srun --container-image=$CONTAINER_IMAGE \
        --container-mounts=/fsx:/fsx \
        --mpi=pmix \
        /opt/hpcx/nccl_tests/alltoall_perf \
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

srun --container-image=$CONTAINER_IMAGE \
    --container-mounts=/fsx:/fsx \
    --mpi=pmix \
    /opt/hpcx/nccl_tests/alltoall_perf \
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

srun --container-image=$CONTAINER_IMAGE \
    --container-mounts=/fsx:/fsx \
    --mpi=pmix \
    /opt/hpcx/nccl_tests/all_reduce_perf \
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

srun --container-image=$CONTAINER_IMAGE \
    --container-mounts=/fsx:/fsx \
    --mpi=pmix \
    /opt/hpcx/nccl_tests/sendrecv_perf \
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
srun --container-image=$CONTAINER_IMAGE \
    --container-mounts=/fsx:/fsx \
    --mpi=pmix \
    /opt/hpcx/nccl_tests/alltoall_perf \
    -b 16M -e 256M -f 2 -g 1 -c 1 -n 30 \
    > $RESULT_DIR/mixed-alltoall.log 2>&1

# ReduceScatter for expert output aggregation
echo "  Running ReduceScatter (expert aggregation)..."
srun --container-image=$CONTAINER_IMAGE \
    --container-mounts=/fsx:/fsx \
    --mpi=pmix \
    /opt/hpcx/nccl_tests/reduce_scatter_perf \
    -b 16M -e 256M -f 2 -g 1 -c 1 -n 30 \
    > $RESULT_DIR/mixed-reducescatter.log 2>&1

# AllReduce for shared parameter gradients
echo "  Running AllReduce (gradient sync)..."
srun --container-image=$CONTAINER_IMAGE \
    --container-mounts=/fsx:/fsx \
    --mpi=pmix \
    /opt/hpcx/nccl_tests/all_reduce_perf \
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
=== Phase 3: Real Workload Simulation Report (Container) ===
Generated: $(date)
Nodes: $SLURM_NNODES
Total GPUs: $((SLURM_NNODES * 8))
Container: nvcr.io/nvidia/pytorch:24.11-py3

=== Test Results ===

1. MoE Expert Capacity Analysis
   Purpose: Find optimal expert capacity for performance
   
EOF

for capacity in 64 128 256 512; do
    echo "   Capacity $capacity tokens/expert:" >> $REPORT_FILE
    grep -E "[0-9]{6,}" $RESULT_DIR/moe-capacity-${capacity}.log | tail -3 | \
        awk '{printf "     %10s: %8.2f GB/s, %8.2f us\n", $1, $6, $4}' >> $REPORT_FILE || echo "     (pending)" >> $REPORT_FILE
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
    awk '{printf "   %10s: %8.2f us latency, %8.2f GB/s\n", $1, $4, $6}' >> $REPORT_FILE || echo "   (pending)" >> $REPORT_FILE

cat >> $REPORT_FILE << EOF

   Critical for MoE: Latency <50us for good performance

3. Bandwidth-Sensitive Operations (Dense Gradient Sync)
   Purpose: Measure peak throughput for large transfers
   
EOF

echo "   Key Results:" >> $REPORT_FILE
grep -E "(134217728|268435456|536870912|1073741824|2147483648)" $RESULT_DIR/bandwidth-sensitive.log | \
    awk '{printf "   %10s: %8.2f GB/s, %8.2f ms\n", $1, $6, $4/1000}' >> $REPORT_FILE || echo "   (pending)" >> $REPORT_FILE

cat >> $REPORT_FILE << EOF

=== Next Steps ===

If workload tests pass:
  → Run Phase 4: Optimization validation
  → Command: sbatch phase4-optimization-container.sbatch

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
cat $REPORT_FILE
echo ""
echo "Next: sbatch phase4-optimization-container.sbatch"
