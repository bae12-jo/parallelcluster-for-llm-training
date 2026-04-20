#!/bin/bash
# OnNodeStart hook — p6-b200 NVSwitch/fabricmanager fix
# AMI v4+ has ib_umad in /etc/modules, fabricmanager disabled, needrestart removed
# Strategy: pre-start fabricmanager HERE so cinc nvidia_config sees it running → no-op
set -uo pipefail

echo "=== ComputeNode OnNodeStart: p6-b200 fabricmanager fix ==="

# Suppress reboot-triggering services
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l
export NEEDRESTART_SUSPEND=1
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl mask unattended-upgrades 2>/dev/null || true
systemctl mask needrestart 2>/dev/null || true

# Ensure ib_umad is loaded (AMI v4 loads it via /etc/modules at boot, this is a safety net)
modprobe ib_umad 2>/dev/null && echo "ib_umad loaded" || echo "ib_umad already loaded"
lsmod | grep -q ib_umad && echo "ib_umad confirmed in kernel"

# Start nvlsm service (required for NVLink5/NVSwitch enumeration on B200)
systemctl start nvlsm 2>/dev/null && echo "nvlsm service started" || echo "nvlsm service skip (may not exist)"

# Ensure fabricmanager is unmasked then start it
# cinc nvidia_config will try systemctl start — if already running, it's a no-op (success)
systemctl unmask nvidia-fabricmanager 2>/dev/null || true
systemctl reset-failed nvidia-fabricmanager 2>/dev/null || true
systemctl enable nvidia-fabricmanager 2>/dev/null || true
systemctl start nvidia-fabricmanager 2>/dev/null && \
  echo "nvidia-fabricmanager started successfully" || \
  echo "WARNING: nvidia-fabricmanager start failed (cinc will retry)"
systemctl is-active nvidia-fabricmanager && echo "ACTIVE" || echo "INACTIVE"

# Clear reboot-required flag (apt upgrades set this; cinc finalize reboots if found)
rm -f /var/run/reboot-required /var/run/reboot-required.pkgs 2>/dev/null || true
echo "reboot-required flag cleared"

echo "=== OnNodeStart complete ==="
