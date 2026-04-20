#!/bin/bash
#SBATCH --job-name=nccl-phase1-baseline
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=24
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
#SBATCH --time=00:30:00
#SBATCH --output=/fsx/nccl-results/phase1-baseline_%j.out
#SBATCH --error=/fsx/nccl-results/phase1-baseline_%j.err

# Phase 1: Baseline Performance Check
# Single-node tests to verify basic NCCL functionality
# Tests both Dense (AllReduce) and MoE (AllToAll) patterns

set -e

echo "=========================================="
echo "Phase 1: Baseline Performance Check"
echo "=========================================="
echo "Node: $(hostname)"
echo "Date: $(date)"
echo "Job ID: $SLURM_JOB_ID"
echo ""

# Environment setup
export CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7
export NCCL_DEBUG=INFO
export NCCL_SOCKET_IFNAME=^docker0,lo
export NCCL_IB_DISABLE=1
export NCCL_P2P_DISABLE=0
export NCCL_SHM_DISABLE=0

# Performance optimizations
export NCCL_NVLS_ENABLE=1
export NCCL_CROSS_NIC=0
export NCCL_NET_GDR_LEVEL=PIX
export NCCL_ALGO=Ring,Tree
export NCCL_PROTO=Simple

# Create results directory
mkdir -p /fsx/nccl-results

RESULT_DIR="/fsx/nccl-results/phase1_$(date +%Y%m%d_%H%M%S)"
mkdir -p $RESULT_DIR

echo "Results will be saved to: $RESULT_DIR"
echo ""

# MPI settings
MPI_OPTS="--bind-to none --map-by slot --mca pml ob1 --mca btl ^openib --mca btl_tcp_if_exclude lo,docker0"

# Test 1: AllReduce (Dense Model - Gradient Sync)
echo "=========================================="
echo "Test 1: AllReduce (Dense Model Pattern)"
echo "=========================================="
echo "Purpose: Gradient synchronization for dense models"
echo "Message sizes: 128MB to 2GB"
echo ""

mpirun -np 8 $MPI_OPTS /opt/nccl-tests/all_reduce_perf \
    -b 128M -e 2G -f 2 -g 1 -c 1 -n 50 \
    | tee $RESULT_DIR/allreduce-dense.log

echo ""
echo " AllReduce test completed"
echo ""

# Test 2: AllToAll (MoE Model - Expert Routing)
echo "=========================================="
echo "Test 2: AllToAll (MoE Model Pattern)"
echo "=========================================="
echo "Purpose: Token routing to experts in MoE models"
echo "Message sizes: 8MB to 512MB"
echo ""

mpirun -np 8 $MPI_OPTS /opt/nccl-tests/alltoall_perf \
    -b 8M -e 512M -f 2 -g 1 -c 1 -n 50 \
    | tee $RESULT_DIR/alltoall-moe.log

echo ""
echo " AllToAll test completed"
echo ""

# Generate baseline report
echo "=========================================="
echo "Generating Baseline Report"
echo "=========================================="

REPORT_FILE="$RESULT_DIR/phase1-baseline-report.txt"

cat > $REPORT_FILE << EOF
=== Phase 1: Baseline Performance Report ===
Generated: $(date)
Node: $(hostname)
GPUs: 8x H100 (80GB HBM3)
Instance Type: p5en.48xlarge
Test Type: Single-node baseline

=== Test Results ===

1. AllReduce (Dense Model - Gradient Sync)
   Purpose: Measures gradient synchronization performance
   Critical for: All dense models (GPT, BERT, etc.)
   
EOF

echo "   Key Results:" >> $REPORT_FILE
grep -E "(134217728|268435456|536870912|1073741824|2147483648)" $RESULT_DIR/allreduce-dense.log | \
    awk '{printf "   %10s: %8.2f GB/s, %8.2f ms\n", $1, $6, $4/1000}' >> $REPORT_FILE

cat >> $REPORT_FILE << EOF

2. AllToAll (MoE Model - Expert Routing)
   Purpose: Measures token routing to experts
   Critical for: MoE models (Switch Transformer, GLaM, etc.)
   
EOF

echo "   Key Results:" >> $REPORT_FILE
grep -E "(8388608|33554432|134217728|536870912)" $RESULT_DIR/alltoall-moe.log | \
    awk '{printf "   %10s: %8.2f GB/s, %8.2f us latency\n", $1, $6, $4}' >> $REPORT_FILE

cat >> $REPORT_FILE << EOF

=== Performance Targets ===

Dense Model (AllReduce):
   Target: >800 GB/s for 1GB messages
   Expected: 800-1200 GB/s (single node)
  
MoE Model (AllToAll):
   Target: >200 GB/s for 128MB messages
   Latency: <100us for 8MB messages
   Expected: 200-400 GB/s (single node)

=== Next Steps ===

If baseline tests pass:
  → Run Phase 2: Multi-node scaling tests
  → Command: sbatch phase2-multinode.sbatch

If performance is below target:
  → Check GPU topology: nvidia-smi topo -m
  → Verify NCCL settings: echo \$NCCL_*
  → Review logs for warnings

=== Files Generated ===
  - allreduce-dense.log: Dense model gradient sync results
  - alltoall-moe.log: MoE expert routing results
  - phase1-baseline-report.txt: This summary report
EOF

echo ""
echo "=========================================="
echo "Phase 1 Baseline Tests Completed!"
echo "=========================================="
echo ""
echo "Results saved to: $RESULT_DIR"
echo "Report: $REPORT_FILE"
echo ""
echo "Quick Summary:"
cat $REPORT_FILE
echo ""
echo "Next: sbatch phase2-multinode.sbatch"
