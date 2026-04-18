#!/bin/bash
#
# Download NGC containers from S3 to FSx Lustre for shared access
# This script runs on HeadNode and downloads pre-built containers from S3
#
# Usage: download-ngc-containers.sh <s3_bucket> [aws_region]
# Example: download-ngc-containers.sh pcluster-setup-269550163595 us-east-2

set -e

S3_BUCKET="${1:-pcluster-setup-269550163595}"
AWS_REGION="${2:-us-east-2}"
CONTAINER_DIR="/fsx/containers"
LOG_DIR="/fsx/logs/container-downloads"

echo "=========================================="
echo "NGC Container Setup from S3"
echo "=========================================="
echo "S3 Bucket: s3://${S3_BUCKET}/containers/"
echo "AWS Region: ${AWS_REGION}"
echo "Target Directory: ${CONTAINER_DIR}"
echo "Log Directory: ${LOG_DIR}"
echo "=========================================="
echo ""

# Check and fix Lustre kernel module if needed
echo "Checking Lustre filesystem..."
if ! mountpoint -q /fsx; then
    echo "️  /fsx is not mounted, checking Lustre kernel module..."
    
    # Check if Lustre module is loaded
    if ! lsmod | grep -q lustre; then
        echo "Lustre module not loaded, attempting to load..."
        
        # Get current kernel version
        KERNEL_VERSION=$(uname -r)
        echo "Current kernel: ${KERNEL_VERSION}"
        
        # Check if matching Lustre module exists
        if [ ! -d "/lib/modules/${KERNEL_VERSION}/updates/kernel/fs/lustre" ]; then
            echo "Installing Lustre client module for kernel ${KERNEL_VERSION}..."
            apt-get update -qq
            apt-get install -y lustre-client-modules-${KERNEL_VERSION} || {
                echo " Failed to install Lustre module for ${KERNEL_VERSION}"
                echo "Available modules:"
                apt-cache search lustre-client-modules | grep ${KERNEL_VERSION%-*}
                exit 1
            }
        fi
        
        # Load Lustre module
        modprobe lustre || {
            echo " Failed to load Lustre module"
            exit 1
        }
        
        echo " Lustre module loaded"
    fi
    
    # Try to mount /fsx
    echo "Attempting to mount /fsx..."
    systemctl restart fsx.mount || {
        echo " Failed to mount /fsx"
        systemctl status fsx.mount
        exit 1
    }
    
    sleep 2
    
    if ! mountpoint -q /fsx; then
        echo " Error: /fsx is still not mounted after fixing Lustre"
        exit 1
    fi
    
    echo " /fsx mounted successfully"
else
    echo " /fsx is already mounted"
fi

# Verify /fsx is accessible
if [ ! -w /fsx ]; then
    echo " Error: /fsx is not writable"
    ls -ld /fsx
    exit 1
fi

echo " Lustre filesystem ready"
echo ""

# Create directories
echo "Creating directories..."
mkdir -p "${CONTAINER_DIR}"
mkdir -p "${LOG_DIR}"
mkdir -p /fsx/scripts
echo " Directories created"
echo ""

# Install enroot if not already installed
echo "Checking enroot installation..."
if ! command -v enroot &> /dev/null; then
    echo "Installing enroot..."
    
    # Install dependencies
    apt-get update -qq
    apt-get install -y squashfs-tools parallel
    
    # Download and install enroot
    ENROOT_VERSION="3.4.1"
    wget -q https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VERSION}/enroot_${ENROOT_VERSION}-1_amd64.deb
    wget -q https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VERSION}/enroot+caps_${ENROOT_VERSION}-1_amd64.deb
    
    dpkg -i enroot_${ENROOT_VERSION}-1_amd64.deb
    dpkg -i enroot+caps_${ENROOT_VERSION}-1_amd64.deb
    
    rm -f enroot*.deb
    
    echo " enroot installed"
else
    echo " enroot already installed ($(enroot version))"
fi
echo ""

# Configure enroot
echo "Configuring enroot..."
mkdir -p /etc/enroot
cat > /etc/enroot/enroot.conf << 'EOF'
# Enroot configuration for FSx Lustre shared storage

# Use FSx Lustre for container storage
ENROOT_RUNTIME_PATH /fsx/containers/runtime
ENROOT_CACHE_PATH /fsx/containers/cache
ENROOT_DATA_PATH /fsx/containers/data

# Temporary directory (local for performance)
ENROOT_TEMP_PATH /tmp

# Allow unprivileged users
ENROOT_ALLOW_SUPERUSER yes
ENROOT_ALLOW_HTTP yes

# GPU support
ENROOT_MOUNT_HOME yes
ENROOT_RESTRICT_DEV no
EOF

# Create enroot directories
mkdir -p /fsx/containers/{runtime,cache,data}
echo " enroot configured"
echo ""

# Download containers from S3
echo "=========================================="
echo "Downloading Containers from S3"
echo "=========================================="
echo ""

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/download_${TIMESTAMP}.log"

echo "Log file: ${LOG_FILE}"
echo ""

# List of containers to download from S3
# Format: s3_filename:local_filename
CONTAINERS=(
    "pytorch-24.11-py3.tar:pytorch+24.11-py3.sqsh"
)

SUCCESS_COUNT=0
FAIL_COUNT=0

for container_spec in "${CONTAINERS[@]}"; do
    S3_FILE=$(echo "$container_spec" | cut -d: -f1)
    LOCAL_FILE=$(echo "$container_spec" | cut -d: -f2)
    
    S3_PATH="s3://${S3_BUCKET}/containers/${S3_FILE}"
    TAR_PATH="/tmp/${S3_FILE}"
    SQSH_PATH="${CONTAINER_DIR}/${LOCAL_FILE}"
    
    echo "----------------------------------------"
    echo "Container: ${S3_FILE}"
    echo "S3 Path: ${S3_PATH}"
    echo "Output: ${SQSH_PATH}"
    echo ""
    
    # Check if already exists
    if [ -f "${SQSH_PATH}" ]; then
        SIZE=$(du -h "${SQSH_PATH}" | cut -f1)
        echo " Already exists (${SIZE}), skipping"
        ((SUCCESS_COUNT++))
        echo ""
        continue
    fi
    
    # Download from S3
    echo "Downloading from S3..."
    START_TIME=$(date +%s)
    
    if aws s3 cp "${S3_PATH}" "${TAR_PATH}" --region "${AWS_REGION}" >> "${LOG_FILE}" 2>&1; then
        DOWNLOAD_TIME=$(date +%s)
        DOWNLOAD_DURATION=$((DOWNLOAD_TIME - START_TIME))
        TAR_SIZE=$(du -h "${TAR_PATH}" | cut -f1)
        
        echo " Downloaded from S3 (${TAR_SIZE} in ${DOWNLOAD_DURATION}s)"
        
        # Convert to Enroot format
        echo "Converting to Enroot format..."
        if enroot import -o "${SQSH_PATH}" "docker-archive://${TAR_PATH}" >> "${LOG_FILE}" 2>&1; then
            END_TIME=$(date +%s)
            TOTAL_DURATION=$((END_TIME - START_TIME))
            SQSH_SIZE=$(du -h "${SQSH_PATH}" | cut -f1)
            
            echo " Converted successfully"
            echo "  Final size: ${SQSH_SIZE}"
            echo "  Total duration: ${TOTAL_DURATION}s"
            
            # Cleanup tar file
            rm -f "${TAR_PATH}"
            
            ((SUCCESS_COUNT++))
        else
            echo " Conversion failed (see log for details)"
            rm -f "${TAR_PATH}"
            ((FAIL_COUNT++))
        fi
    else
        echo " S3 download failed (see log for details)"
        echo "   Make sure the file exists: aws s3 ls ${S3_PATH}"
        ((FAIL_COUNT++))
    fi
    
    echo ""
done

echo "=========================================="
echo "Download Summary"
echo "=========================================="
echo "Success: ${SUCCESS_COUNT}"
echo "Failed: ${FAIL_COUNT}"
echo "Total: $((SUCCESS_COUNT + FAIL_COUNT))"
echo ""
echo "Container directory: ${CONTAINER_DIR}"
echo "Log file: ${LOG_FILE}"
echo ""

# List downloaded containers
echo "Available containers:"
if ls "${CONTAINER_DIR}"/*.sqsh 1> /dev/null 2>&1; then
    ls -lh "${CONTAINER_DIR}"/*.sqsh
else
    echo "  (none)"
fi

echo ""
echo "=========================================="
echo "Usage Instructions"
echo "=========================================="
echo ""
echo "To use a container with Slurm:"
echo ""
echo "  srun --container-image=${CONTAINER_DIR}/pytorch+24.11-py3.sqsh \\"
echo "       --container-mounts=/fsx:/fsx \\"
echo "       --mpi=pmix \\"
echo "       python train.py"
echo ""
echo "For NCCL tests:"
echo ""
echo "  sbatch /fsx/config/nccl/phase1-baseline-container.sbatch"
echo ""
echo "=========================================="

# Create helper script for users
cat > /fsx/containers/list-containers.sh << 'EOFHELPER'
#!/bin/bash
# List available NGC containers

echo "Available NGC Containers in /fsx/containers:"
echo ""

for sqsh in /fsx/containers/*.sqsh; do
    if [ -f "$sqsh" ]; then
        NAME=$(basename "$sqsh" .sqsh)
        SIZE=$(du -h "$sqsh" | cut -f1)
        DATE=$(stat -c %y "$sqsh" | cut -d' ' -f1)
        
        echo "  - $NAME"
        echo "    Size: $SIZE"
        echo "    Downloaded: $DATE"
        echo "    Path: $sqsh"
        echo ""
    fi
done

echo "To use a container:"
echo "  srun --container-image=/fsx/containers/CONTAINER_NAME.sqsh \\"
echo "       --container-mounts=/fsx:/fsx \\"
echo "       --mpi=pmix \\"
echo "       python script.py"
EOFHELPER

chmod +x /fsx/containers/list-containers.sh

echo " Helper script created: /fsx/containers/list-containers.sh"
echo ""

# Create Lustre health check script
cat > /fsx/scripts/check-lustre.sh << 'EOFCHECK'
#!/bin/bash
# Check Lustre filesystem health

echo "Lustre Filesystem Health Check"
echo "==============================="
echo ""

# Check if mounted
if mountpoint -q /fsx; then
    echo " /fsx is mounted"
else
    echo " /fsx is NOT mounted"
    exit 1
fi

# Check kernel module
if lsmod | grep -q lustre; then
    echo " Lustre kernel module loaded"
    LUSTRE_VERSION=$(modinfo lustre | grep ^version: | awk '{print $2}')
    echo "  Version: ${LUSTRE_VERSION}"
else
    echo " Lustre kernel module NOT loaded"
fi

# Check kernel version
KERNEL_VERSION=$(uname -r)
echo " Kernel version: ${KERNEL_VERSION}"

# Check available Lustre modules
echo ""
echo "Available Lustre modules:"
dpkg -l | grep lustre-client-modules | awk '{print "  " $2 " " $3}'

# Check mount details
echo ""
echo "Mount details:"
mount | grep /fsx

# Check filesystem stats
echo ""
echo "Filesystem stats:"
df -h /fsx

echo ""
echo "==============================="
EOFCHECK

chmod +x /fsx/scripts/check-lustre.sh

echo " Lustre health check script created: /fsx/scripts/check-lustre.sh"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo " All containers downloaded successfully"
    exit 0
else
    echo "️  Some containers failed to download"
    echo "   Check log file: ${LOG_FILE}"
    echo "   Verify S3 bucket: aws s3 ls s3://${S3_BUCKET}/containers/"
    exit 1
fi
