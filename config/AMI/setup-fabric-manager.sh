#!/bin/bash
# Install and configure NVIDIA Fabric Manager
# Detects driver version and installs matching fabricmanager package.
# On non-NVSwitch instances (g5, g6), installs but does not start — this is expected.
#
# Usage: bash setup-fabric-manager.sh
set -euo pipefail

echo "=== Fabric Manager Setup ==="

# Detect installed NVIDIA driver version
DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1)
if [ -z "$DRIVER_VERSION" ]; then
  echo "ERROR: nvidia-smi not found or no GPU detected."
  exit 1
fi
echo "Detected NVIDIA driver version: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"

# Install matching fabricmanager
echo "Installing nvidia-fabricmanager matching driver version..."
apt-get update -qq
if apt-get install -y "nvidia-fabricmanager-${DRIVER_VERSION}" 2>/dev/null; then
  echo "Installed exact match: nvidia-fabricmanager-${DRIVER_VERSION}"
else
  echo "Exact match not found, installing latest available..."
  apt-get install -y nvidia-fabricmanager
fi

# Enable (do NOT mask — pcluster cinc expects to start it)
systemctl enable nvidia-fabricmanager
echo "nvidia-fabricmanager enabled."

# Attempt to start (will fail gracefully on non-NVSwitch instances)
echo "Attempting to start fabric manager..."
if systemctl start nvidia-fabricmanager 2>/dev/null; then
  echo "Fabric manager started successfully."
else
  echo "Fabric manager not started (no NVSwitch hardware present — expected on g5/g6)."
fi

echo "=== Fabric Manager Setup Complete ==="
