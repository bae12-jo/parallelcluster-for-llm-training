#!/bin/bash
#
# Fix Lustre kernel module version mismatch
# This script ensures Lustre module matches current kernel
# Should be run early in node setup or as a systemd service
#

set -e

echo "=== Lustre Kernel Module Check ==="

# Get current kernel version
KERNEL_VERSION=$(uname -r)
echo "Current kernel: ${KERNEL_VERSION}"

# Check if Lustre module is loaded
if lsmod | grep -q lustre; then
    LOADED_VERSION=$(modinfo lustre | grep ^vermagic: | awk '{print $2}')
    echo "Loaded Lustre module: ${LOADED_VERSION}"
    
    if [ "${LOADED_VERSION}" = "${KERNEL_VERSION}" ]; then
        echo " Lustre module matches kernel version"
        exit 0
    else
        echo "️  Lustre module version mismatch!"
        echo "   Kernel: ${KERNEL_VERSION}"
        echo "   Module: ${LOADED_VERSION}"
        echo "   Unloading old module..."
        rmmod lustre 2>/dev/null || true
    fi
fi

# Check if matching Lustre module is installed
if [ -d "/lib/modules/${KERNEL_VERSION}/updates/kernel/fs/lustre" ]; then
    echo " Lustre module for ${KERNEL_VERSION} is installed"
else
    echo "Installing Lustre client module for ${KERNEL_VERSION}..."
    
    # Update package list
    apt-get update -qq
    
    # Install matching Lustre module
    if apt-get install -y lustre-client-modules-${KERNEL_VERSION}; then
        echo " Lustre module installed successfully"
    else
        echo " Failed to install Lustre module"
        echo "Available modules:"
        apt-cache search lustre-client-modules | grep ${KERNEL_VERSION%-*}
        exit 1
    fi
fi

# Load Lustre module
echo "Loading Lustre module..."
if modprobe lustre; then
    echo " Lustre module loaded successfully"
else
    echo " Failed to load Lustre module"
    exit 1
fi

# Verify /fsx mount
if mountpoint -q /fsx; then
    echo " /fsx is mounted"
else
    echo "️  /fsx is not mounted, attempting to mount..."
    systemctl restart fsx.mount
    sleep 2
    
    if mountpoint -q /fsx; then
        echo " /fsx mounted successfully"
    else
        echo " Failed to mount /fsx"
        systemctl status fsx.mount
        exit 1
    fi
fi

echo "=== Lustre module check complete ==="
