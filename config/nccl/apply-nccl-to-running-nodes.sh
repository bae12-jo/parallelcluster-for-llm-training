#!/bin/bash
#
# Apply shared NCCL configuration to already running ComputeNodes
# Run this script on HeadNode after installing NCCL to /fsx
#
# Usage: bash apply-nccl-to-running-nodes.sh

set -e

echo "=========================================="
echo "Apply NCCL to Running ComputeNodes"
echo "=========================================="

# Check if NCCL is installed
if [ ! -f "/fsx/nccl/setup-nccl-env.sh" ]; then
    echo " Error: NCCL not found in /fsx/nccl/"
    echo ""
    echo "Please install NCCL first:"
    echo "  sudo bash /fsx/nccl/install-nccl-shared.sh v2.28.7-1 v1.17.2-aws /fsx"
    exit 1
fi

NCCL_VERSION=$(cat /fsx/nccl/.nccl_version 2>/dev/null || echo "unknown")
echo " Found NCCL installation: ${NCCL_VERSION}"
echo ""

# Check if there are any compute nodes
NODE_COUNT=$(sinfo -N -h -o "%N" -p compute-gpu 2>/dev/null | wc -l)
if [ "$NODE_COUNT" -eq 0 ]; then
    echo "️  No ComputeNodes are currently running"
    echo ""
    echo "NCCL will be automatically configured when nodes start."
    echo "You can start nodes by submitting a Slurm job:"
    echo "  sbatch your-job.sh"
    exit 0
fi

echo "Found ${NODE_COUNT} ComputeNode(s)"
echo ""

# Get list of compute nodes
NODES=$(sinfo -N -h -o "%N" -p compute-gpu 2>/dev/null | tr '\n' ',' | sed 's/,$//')
echo "Nodes: ${NODES}"
echo ""

# Apply NCCL configuration to all nodes
echo "Applying NCCL configuration..."
echo ""

# Create profile script on all nodes
srun --nodes=${NODE_COUNT} --ntasks=${NODE_COUNT} bash -c '
    # Create profile script
    cat > /etc/profile.d/nccl-shared.sh << "EOF"
# Shared NCCL configuration from FSx Lustre
source /fsx/nccl/setup-nccl-env.sh
EOF
    chmod +x /etc/profile.d/nccl-shared.sh
    
    # Source it now for current sessions
    source /fsx/nccl/setup-nccl-env.sh
    
    # Verify
    if [ -n "$LD_LIBRARY_PATH" ] && echo "$LD_LIBRARY_PATH" | grep -q "/usr/local/lib"; then
        echo " NCCL configured on $(hostname)"
    else
        echo "️  NCCL configuration may have failed on $(hostname)"
    fi
'

echo ""
echo "=========================================="
echo " NCCL Configuration Applied"
echo "=========================================="
echo ""
echo "NCCL is now available on all running ComputeNodes."
echo ""
echo "To verify:"
echo "  srun --nodes=1 bash -c 'source /etc/profile.d/nccl-shared.sh && env | grep NCCL'"
echo ""
echo "To test:"
echo "  srun --nodes=2 --ntasks=16 --gpus-per-task=1 \\"
echo "    /opt/nccl-tests/build/all_reduce_perf -b 8 -e 128M -f 2 -g 1"
echo ""
