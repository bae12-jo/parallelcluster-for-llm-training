# config/AMI/

Scripts for building a custom AMI with p6-b200 prerequisites baked in.
Run once on a builder instance (g4dn.2xlarge recommended), then create AMI from it.

| File | Purpose |
|------|---------|
| `build-p6b200-ami.sh` | Full AMI build: installs `ib_umad`, `nvlsm`, enables `nvidia-fabricmanager`. Run on a pcluster 3.15 official AMI instance. |

---

## NVIDIA Fabric Manager Setup Guide

Fabric Manager is required for NVSwitch-based instances (p4d, p5, p6-b200).
On non-NVSwitch instances (g5, g6) it installs but does not start — this is expected.

### Required packages

```bash
# 1. IB kernel modules (required for NVSwitch enumeration)
sudo apt install linux-modules-extra-$(uname -r) infiniband-diags ibutils -y
sudo modprobe ib_umad
echo "ib_umad" | sudo tee -a /etc/modules   # persist across reboots

# 2. NVLink Subnet Manager (NVL5/B200)
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/nvlsm_2025.10.11-1_amd64.deb
sudo dpkg -i nvlsm_2025.10.11-1_amd64.deb

# 3. Enable fabricmanager (pcluster cinc will start it — do NOT mask)
sudo systemctl enable nvidia-fabricmanager
```

### Key rule for pcluster AMIs

pcluster cinc runs `service[nvidia-fabricmanager] :start` during bootstrap.
- If fabricmanager is **already running** → cinc no-ops ✅
- If fabricmanager is **masked** → cinc fails, node goes DOWN ❌

Always `enable`, never `mask`.

### Verification

```bash
lsmod | grep ib_umad          # should show ib_umad loaded
dpkg -l nvlsm                 # should show installed
systemctl is-enabled nvidia-fabricmanager  # should show "enabled"
```

### Expected behavior by instance type

| Instance | NVSwitch | fabricmanager result |
|----------|----------|----------------------|
| g6.xlarge | No | Installs, does not start — normal |
| p4d.24xlarge | Yes | Starts successfully |
| p6-b200.48xlarge | Yes (NVL5) | Starts, initializes NVSwitch fabric |
