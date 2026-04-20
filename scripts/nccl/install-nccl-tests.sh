#!/bin/bash
#
# NCCL Tests Installation Script for p5en.48xlarge
# Optimized for H200 GPUs with EFA networking
#

set -e

echo "Installing NCCL Tests for p5en.48xlarge..."

# Check if running on a ParallelCluster node
if [[ ! -f /etc/parallelcluster/cfnconfig ]]; then
    echo "This script should be run on a ParallelCluster node"
    exit 1
fi

# Source ParallelCluster config
. /etc/parallelcluster/cfnconfig

# Set installation directory
INSTALL_DIR="/opt/nccl-tests"
RESULTS_DIR="/fsx/nccl-results"

# Create directories
sudo mkdir -p $INSTALL_DIR
mkdir -p $RESULTS_DIR

# Check CUDA installation
if ! command -v nvcc &> /dev/null; then
    echo "CUDA not found. Installing CUDA toolkit..."
    # CUDA should be pre-installed on p5en instances
    export PATH=/usr/local/cuda/bin:$PATH
    export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
fi

# Check NCCL installation
if [[ ! -f /usr/local/cuda/lib64/libnccl.so ]]; then
    echo "NCCL not found. Please ensure NCCL is installed."
    echo "Expected location: /usr/local/cuda/lib64/libnccl.so"
    exit 1
fi

# Clone and build NCCL tests
cd /tmp
if [[ -d nccl-tests ]]; then
    rm -rf nccl-tests
fi

echo "Cloning NCCL tests repository..."
git clone https://github.com/NVIDIA/nccl-tests.git
cd nccl-tests

# Build NCCL tests
echo "Building NCCL tests..."
make MPI=1 MPI_HOME=/opt/amazon/openmpi CUDA_HOME=/usr/local/cuda NCCL_HOME=/usr/local/cuda

# Install binaries
echo "Installing NCCL test binaries..."
sudo cp build/* $INSTALL_DIR/
sudo chmod +x $INSTALL_DIR/*

# Create symlinks for easy access
sudo ln -sf $INSTALL_DIR/all_reduce_perf /usr/local/bin/nccl_all_reduce_perf
sudo ln -sf $INSTALL_DIR/all_gather_perf /usr/local/bin/nccl_all_gather_perf
sudo ln -sf $INSTALL_DIR/broadcast_perf /usr/local/bin/nccl_broadcast_perf
sudo ln -sf $INSTALL_DIR/reduce_scatter_perf /usr/local/bin/nccl_reduce_scatter_perf
sudo ln -sf $INSTALL_DIR/alltoall_perf /usr/local/bin/nccl_alltoall_perf

# Cleanup
cd /
rm -rf /tmp/nccl-tests

echo "NCCL tests installed successfully!"
echo "Binaries available in: $INSTALL_DIR"
echo "Results will be saved to: $RESULTS_DIR"
echo ""
echo "Test installation:"
echo "  mpirun -np 8 $INSTALL_DIR/all_reduce_perf -b 1K -e 1G -f 2 -g 1"