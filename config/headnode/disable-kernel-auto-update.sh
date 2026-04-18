#!/bin/bash
#
# Disable automatic kernel updates to prevent Lustre module mismatch
# This prevents Ubuntu's unattended-upgrades from updating the kernel
#

set -e

echo "=== Disabling Automatic Kernel Updates ==="

# Method 1: Configure unattended-upgrades to skip kernel updates
if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
    echo "Configuring unattended-upgrades to skip kernel packages..."
    
    # Backup original file
    cp /etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/50unattended-upgrades.backup
    
    # Add kernel packages to blacklist
    if ! grep -q "linux-image" /etc/apt/apt.conf.d/50unattended-upgrades; then
        sed -i '/Unattended-Upgrade::Package-Blacklist {/a\    "linux-image-*";\n    "linux-headers-*";\n    "linux-modules-*";\n    "linux-aws";' /etc/apt/apt.conf.d/50unattended-upgrades
        echo " Added kernel packages to blacklist"
    else
        echo " Kernel packages already blacklisted"
    fi
fi

# Method 2: Hold current kernel packages
echo "Holding current kernel packages..."
KERNEL_VERSION=$(uname -r)
KERNEL_PACKAGE="linux-image-${KERNEL_VERSION}"

if dpkg -l | grep -q "${KERNEL_PACKAGE}"; then
    apt-mark hold ${KERNEL_PACKAGE}
    apt-mark hold linux-headers-${KERNEL_VERSION}
    apt-mark hold linux-modules-${KERNEL_VERSION}
    apt-mark hold linux-aws
    echo " Kernel packages held at current version"
else
    echo "️  Current kernel package not found in dpkg"
fi

# Method 3: Pin Lustre client modules to current kernel
echo "Installing Lustre client modules for current kernel..."
apt-get update -qq
apt-get install -y lustre-client-modules-${KERNEL_VERSION}
apt-mark hold lustre-client-modules-${KERNEL_VERSION}
echo " Lustre modules installed and held"

# Create systemd service to check Lustre on boot
cat > /etc/systemd/system/lustre-module-check.service << 'EOF'
[Unit]
Description=Check and fix Lustre kernel module on boot
After=network.target
Before=fsx.mount

[Service]
Type=oneshot
ExecStart=/fsx/scripts/fix-lustre-module.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Copy fix script to /fsx/scripts
mkdir -p /fsx/scripts
if [ -f /tmp/fix-lustre-module.sh ]; then
    cp /tmp/fix-lustre-module.sh /fsx/scripts/
    chmod +x /fsx/scripts/fix-lustre-module.sh
fi

# Enable service
systemctl daemon-reload
systemctl enable lustre-module-check.service
echo " Lustre module check service enabled"

echo ""
echo "=== Kernel Auto-Update Prevention Complete ==="
echo ""
echo "Current kernel: ${KERNEL_VERSION}"
echo "Held packages:"
apt-mark showhold | grep -E "(linux|lustre)"
echo ""
echo "To manually update kernel in the future:"
echo "  1. apt-mark unhold linux-aws linux-image-* linux-headers-*"
echo "  2. apt-get update && apt-get upgrade"
echo "  3. apt-get install lustre-client-modules-\$(uname -r)"
echo "  4. reboot"
