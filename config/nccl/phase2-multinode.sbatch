#!/bin/bash
#SBATCH --job-name=nccl-phase2-container
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=24
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
#SBATCH --time=01:00:00
#SBATCH --output=/fsx/nccl-results/phase2-container_%j.out
#SBATCH --error=/fsx/nccl-results/phase2-container_%j.err

# Phase 2: Multi-Node Scaling Tests (NGC Container Version)
# Tests scaling efficiency across multiple nodes
# Critical for understanding EFA network performance

set -e

echo "=========================================="
echo "Phase 2: Multi-Node Scaling (Container)"
echo "=========================================="
echo "Nodes: $SLURM_NNODES"
echo "Total GPUs: $((SLURM_NNODES * 8))"
echo "Date: $(date)"
echo "Job ID: $SLURM_JOB_ID"
echo "Node list: $SLURM_JOB_NODELIST"
echo "Container: nvcr.io/nvidia/pytorch:24.11-py3"
echo ""

# NGC Container path
CONTAINER_IMAGE="/fsx/containers/pytorch+24.11-py3.sqsh"

# Check if container exists
if [ ! -f "$CONTAINER_IMAGE" ]; then
    echo "ERROR: Container not found at $CONTAINER_IMAGE"
    echo "Please import container first:"
    echo "  enroot import docker://nvcr.io/nvidia/pytorch:24.11-py3"
    exit 1
fi

# Create results directory
RESULT_DIR="/fsx/nccl-results/phase2_container_$(date +%Y%m%d_%H%M%S)"
mkdir -p $RESULT_DIR

echo "Results will be saved to: $RESULT_DIR"
echo ""

# Test 1: Multi-node AllReduce (Dense Model Scaling)
echo "=========================================="
echo "Test 1: Multi-Node AllReduce Scaling"
echo "=========================================="
echo "Purpose: Verify gradient sync scales across nodes"
echo "Testing: 2-node, 4-node, 8-node (if available)"
echo ""

srun --container-image=$CONTAINER_IMAGE \
    --container-mounts=/fsx:/fsx \
    --mpi=pmix \
    /opt/hpcx/nccl_tests/all_reduce_perf \
    -b 128M -e 2G -f 2 -g 1 -c 1 -n 50 \
    | tee $RESULT_DIR/allreduce-multinode.log

echo ""
echo " Multi-node AllReduce test completed"
echo ""

# Test 2: Multi-node AllToAll (MoE Expert Parallel Scaling)
echo "=========================================="
echo "Test 2: Multi-Node AllToAll Scaling"
echo "=========================================="
echo "Purpose: Verify MoE expert routing scales across nodes"
echo "Critical for: Expert parallelism in large MoE models"
echo ""

srun --container-image=$CONTAINER_IMAGE \
    --container-mounts=/fsx:/fsx \
    --mpi=pmix \
    /opt/hpcx/nccl_tests/alltoall_perf \
    -b 16M -e 512M -f 2 -g 1 -c 1 -n 50 \
    | tee $RESULT_DIR/alltoall-multinode.log

echo ""
echo " Multi-node AllToAll test completed"
echo ""

# Test 3: Ring vs Tree Algorithm Comparison
echo "=========================================="
echo "Test 3: Algorithm Comparison (Ring vs Tree)"
echo "=========================================="
echo "Purpose: Find optimal algorithm for your cluster size"
echo ""

echo "Testing Ring algorithm..."
srun --container-image=$CONTAINER_IMAGE \
    --container-mounts=/fsx:/fsx \
    --mpi=pmix \
    --export=ALL,NCCL_ALGO=Ring \
    /opt/hpcx/nccl_tests/all_reduce_perf \
    -b 512M -e 2G -f 2 -g 1 -c 1 -n 20 \
    | tee $RESULT_DIR/allreduce-ring.log

echo ""
echo "Testing Tree algorithm..."
srun --container-image=$CONTAINER_IMAGE \
    --container-mounts=/fsx:/fsx \
    --mpi=pmix \
    --export=ALL,NCCL_ALGO=Tree \
    /opt/hpcx/nccl_tests/all_reduce_perf \
    -b 512M -e 2G -f 2 -g 1 -c 1 -n 20 \
    | tee $RESULT_DIR/allreduce-tree.log

echo ""
echo " Algorithm comparison completed"
echo ""

# Generate scaling report
echo "=========================================="
echo "Generating Multi-Node Scaling Report"
echo "=========================================="

REPORT_FILE="$RESULT_DIR/phase2-multinode-report.txt"

cat > $REPORT_FILE << EOF
=== Phase 2: Multi-Node Scaling Report (Container) ===
Generated: $(date)
Nodes: $SLURM_NNODES
Total GPUs: $((SLURM_NNODES * 8))
Network: 3.2Tbps EFA per node
Container: nvcr.io/nvidia/pytorch:24.11-py3

=== Test Results ===

1. Multi-Node AllReduce (Dense Model Scaling)
   Purpose: Gradient synchronization across nodes
   Network: Inter-node communication via EFA
   
EOF

echo "   Key Results:" >> $REPORT_FILE
grep -E "(134217728|536870912|2147483648)" $RESULT_DIR/allreduce-multinode.log | \
    awk '{printf "   %10s: %8.2f GB/s, %8.2f ms\n", $1, $6, $4/1000}' >> $REPORT_FILE

cat >> $REPORT_FILE << EOF

2. Multi-Node AllToAll (MoE Expert Parallel)
   Purpose: Expert routing across nodes
   Critical for: Large-scale MoE training
   
EOF

echo "   Key Results:" >> $REPORT_FILE
grep -E "(16777216|67108864|268435456|536870912)" $RESULT_DIR/alltoall-multinode.log | \
    awk '{printf "   %10s: %8.2f GB/s, %8.2f us\n", $1, $6, $4}' >> $REPORT_FILE

cat >> $REPORT_FILE << EOF

3. Algorithm Comparison (Ring vs Tree)
   
   Ring Algorithm (best for small clusters):
EOF

grep "1073741824" $RESULT_DIR/allreduce-ring.log | \
    awk '{printf "   1GB: %8.2f GB/s\n", $6}' >> $REPORT_FILE

cat >> $REPORT_FILE << EOF
   
   Tree Algorithm (best for large clusters):
EOF

grep "1073741824" $RESULT_DIR/allreduce-tree.log | \
    awk '{printf "   1GB: %8.2f GB/s\n", $6}' >> $REPORT_FILE

# Calculate scaling efficiency
SINGLE_NODE_BW=$(grep "1073741824" /fsx/nccl-results/phase1_*/allreduce-dense.log 2>/dev/null | tail -1 | awk '{print $6}' || echo "N/A")
MULTI_NODE_BW=$(grep "1073741824" $RESULT_DIR/allreduce-multinode.log | tail -1 | awk '{print $6}')

cat >> $REPORT_FILE << EOF

=== Scaling Efficiency Analysis ===

Single-node bandwidth: ${SINGLE_NODE_BW} GB/s
Multi-node bandwidth: ${MULTI_NODE_BW} GB/s
Nodes: $SLURM_NNODES

Expected scaling: Linear (2x nodes = 2x bandwidth)
Network bottleneck: 3.2Tbps = 400 GB/s per node

For MoE models:
  - AllToAll is network-bound for multi-node
  - Target: >300 GB/s per node for good efficiency
  - Load balancing is critical

=== Performance Targets ===

Dense Model (AllReduce):
   Target: >90% scaling efficiency
   2-node: >1600 GB/s aggregate
   4-node: >3200 GB/s aggregate
  
MoE Model (AllToAll):
   Target: >300 GB/s per node
   Latency increase: <20us vs single-node
   Network utilization: >80% of 3.2Tbps

=== Next Steps ===

If scaling tests pass:
  → Run Phase 3: Real workload simulation
  → Command: sbatch phase3-workload-container.sbatch

If scaling efficiency is low (<80%):
  → Check EFA configuration: fi_info -p efa
  → Verify network topology
  → Review NCCL_DEBUG logs for bottlenecks

=== Files Generated ===
  - allreduce-multinode.log: Multi-node gradient sync
  - alltoall-multinode.log: Multi-node expert routing
  - allreduce-ring.log: Ring algorithm results
  - allreduce-tree.log: Tree algorithm results
  - phase2-multinode-report.txt: This summary report
EOF

echo ""
echo "=========================================="
echo "Phase 2 Multi-Node Tests Completed!"
echo "=========================================="
echo ""
echo "Results saved to: $RESULT_DIR"
echo "Report: $REPORT_FILE"
echo ""
echo "Quick Summary:"
cat $REPORT_FILE
echo ""
echo "Next: sbatch phase3-workload-container.sbatch"
