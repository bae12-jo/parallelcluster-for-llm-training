#!/bin/bash
#
# Install NCCL to shared storage (/fsx)
# This script should run on HeadNode only
# ComputeFleet nodes will reference the shared installation
#
# Usage: install-nccl-shared.sh <nccl_version> <aws_ofi_nccl_version> <shared_dir>
# Example: install-nccl-shared.sh v2.28.7-1 v1.17.2-aws /fsx

set -e

NCCL_VERSION="${1:-v2.28.7-1}"
AWS_OFI_NCCL_VERSION="${2:-v1.17.2-aws}"
SHARED_DIR="${3:-/fsx}"

NCCL_INSTALL_DIR="${SHARED_DIR}/nccl"
NCCL_VERSION_FILE="${NCCL_INSTALL_DIR}/.nccl_version"

echo "=========================================="
echo "Installing NCCL to Shared Storage"
echo "=========================================="
echo "NCCL Version: ${NCCL_VERSION}"
echo "AWS OFI NCCL Version: ${AWS_OFI_NCCL_VERSION}"
echo "Shared Directory: ${SHARED_DIR}"
echo "Install Directory: ${NCCL_INSTALL_DIR}"
echo "=========================================="

# Check if shared directory exists
if [ ! -d "${SHARED_DIR}" ]; then
    echo "️  Warning: Shared directory ${SHARED_DIR} does not exist"
    echo "   NCCL will be installed locally instead"
    NCCL_INSTALL_DIR="/opt/nccl"
fi

# Check if NCCL is already installed with the same version
if [ -f "${NCCL_VERSION_FILE}" ]; then
    INSTALLED_VERSION=$(cat "${NCCL_VERSION_FILE}")
    if [ "${INSTALLED_VERSION}" = "${NCCL_VERSION}-${AWS_OFI_NCCL_VERSION}" ]; then
        echo " NCCL ${NCCL_VERSION} with AWS OFI ${AWS_OFI_NCCL_VERSION} is already installed"
        echo "   Location: ${NCCL_INSTALL_DIR}"
        exit 0
    else
        echo "️  Different NCCL version found: ${INSTALLED_VERSION}"
        echo "   Reinstalling with ${NCCL_VERSION}-${AWS_OFI_NCCL_VERSION}"
    fi
fi

# Create installation directory
mkdir -p "${NCCL_INSTALL_DIR}"

# Create marker file to indicate installation in progress
touch "${NCCL_INSTALL_DIR}/.installing"

echo ""
echo "Downloading NCCL installation script from AWS samples..."
curl -fsSL https://raw.githubusercontent.com/aws-samples/aws-parallelcluster-post-install-scripts/main/nccl/postinstall.sh -o /tmp/nccl-postinstall.sh
chmod +x /tmp/nccl-postinstall.sh

echo ""
echo "Installing NCCL..."
echo "This may take 10-15 minutes on HeadNode (one-time installation)"
echo ""

# Run the NCCL installation script
# Note: This script will install NCCL system-wide, but we'll create symlinks in shared storage
bash /tmp/nccl-postinstall.sh "${NCCL_VERSION}" "${AWS_OFI_NCCL_VERSION}"

# Create version marker
echo "${NCCL_VERSION}-${AWS_OFI_NCCL_VERSION}" > "${NCCL_VERSION_FILE}"

# Copy test scripts to shared storage
echo ""
echo "Copying NCCL test scripts to shared storage..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy test scripts if they exist
for script in test-nccl-simple.py test-nccl-bandwidth.py example-training-job.py \
              submit-nccl-simple.sh submit-nccl-bandwidth.sh submit-training-example.sh; do
    if [ -f "${SCRIPT_DIR}/${script}" ]; then
        cp "${SCRIPT_DIR}/${script}" "${NCCL_INSTALL_DIR}/"
        chmod +x "${NCCL_INSTALL_DIR}/${script}"
        echo "   Copied ${script}"
    elif [ -f "/tmp/${script}" ]; then
        cp "/tmp/${script}" "${NCCL_INSTALL_DIR}/"
        chmod +x "${NCCL_INSTALL_DIR}/${script}"
        echo "   Copied ${script}"
    fi
done

# Download test scripts from S3 if not found locally
if [ ! -f "${NCCL_INSTALL_DIR}/phase1-baseline.sbatch" ]; then
    echo "  Downloading test scripts from S3..."
    
    # NCCL tests installer
    aws s3 cp s3://pcluster-config-scripts-198023436207/scripts/nccl/install-nccl-tests.sh "${NCCL_INSTALL_DIR}/" 2>/dev/null || true
    
    # 4-phase testing framework
    aws s3 cp s3://pcluster-config-scripts-198023436207/scripts/nccl/phase1-baseline.sbatch "${NCCL_INSTALL_DIR}/" 2>/dev/null || true
    aws s3 cp s3://pcluster-config-scripts-198023436207/scripts/nccl/phase2-multinode.sbatch "${NCCL_INSTALL_DIR}/" 2>/dev/null || true
    aws s3 cp s3://pcluster-config-scripts-198023436207/scripts/nccl/phase3-workload.sbatch "${NCCL_INSTALL_DIR}/" 2>/dev/null || true
    aws s3 cp s3://pcluster-config-scripts-198023436207/scripts/nccl/phase4-optimization.sbatch "${NCCL_INSTALL_DIR}/" 2>/dev/null || true
    
    # README
    aws s3 cp s3://pcluster-config-scripts-198023436207/scripts/nccl/README.md "${NCCL_INSTALL_DIR}/" 2>/dev/null || true
    
    chmod +x "${NCCL_INSTALL_DIR}"/*.sh 2>/dev/null || true
    chmod +x "${NCCL_INSTALL_DIR}"/*.sbatch 2>/dev/null || true
fi

# Create environment setup script for compute nodes
cat > "${NCCL_INSTALL_DIR}/setup-nccl-env.sh" << 'ENVSCRIPT'
#!/bin/bash
# Source this script on compute nodes to use shared NCCL installation
# Usage: source /fsx/nccl/setup-nccl-env.sh

# NCCL library paths
export LD_LIBRARY_PATH=/usr/local/lib:${LD_LIBRARY_PATH}
export LIBRARY_PATH=/usr/local/lib:${LIBRARY_PATH}

# AWS OFI NCCL plugin
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export NCCL_PROTO=simple

# NCCL optimizations for EFA
export NCCL_DEBUG=INFO
export NCCL_ALGO=Ring
export NCCL_MIN_NRINGS=8

echo " NCCL environment configured"
echo "  NCCL Version: $(cat /fsx/nccl/.nccl_version 2>/dev/null || echo 'unknown')"
ENVSCRIPT

chmod +x "${NCCL_INSTALL_DIR}/setup-nccl-env.sh"

# Remove installation marker
rm -f "${NCCL_INSTALL_DIR}/.installing"

echo ""
echo "=========================================="
echo " NCCL Installation Complete"
echo "=========================================="
echo "Installation Directory: ${NCCL_INSTALL_DIR}"
echo "Version: ${NCCL_VERSION}-${AWS_OFI_NCCL_VERSION}"
echo ""
echo "Available test scripts:"
echo "  ${NCCL_INSTALL_DIR}/test-nccl-simple.py"
echo "  ${NCCL_INSTALL_DIR}/test-nccl-bandwidth.py"
echo "  ${NCCL_INSTALL_DIR}/example-training-job.py"
echo ""
echo "Submit test jobs from LoginNode:"
echo "  cd ${NCCL_INSTALL_DIR}"
echo "  sbatch submit-nccl-simple.sh"
echo "  sbatch submit-nccl-bandwidth.sh"
echo "  sbatch submit-training-example.sh"
echo ""
echo "Compute nodes can use NCCL by sourcing:"
echo "  source ${NCCL_INSTALL_DIR}/setup-nccl-env.sh"
echo "=========================================="
