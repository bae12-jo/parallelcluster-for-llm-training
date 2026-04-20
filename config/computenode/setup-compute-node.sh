#!/bin/bash
# ComputeNode setup: runs during OnNodeConfigured (before slurmd)
# Only does minimal work that is safe before slurmd starts.
# Docker/DCGM/monitoring install is deferred to post-slurmd-monitoring.service
# Args: $1 = S3_BUCKET (optional)
set -euxo pipefail

S3_BUCKET="${1:-}"
NODE_EXPORTER_VERSION="1.11.1"
ARCH="linux-amd64"

echo "=== ComputeNode setup (pre-slurmd phase) ==="

# ---- IMDSv2 token (required: cluster uses ImdsSupport: v2.0) ----
TOKEN=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token)
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/placement/region)

# ---- AWS CLI (guarded — transient network failure must not abort hook) ----
if ! command -v aws &>/dev/null; then
  apt-get install -y unzip -qq 2>/dev/null || true
  curl -sf https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip || true
  if [ -f /tmp/awscliv2.zip ]; then
    unzip -q /tmp/awscliv2.zip -d /tmp || true
    /tmp/aws/install -i /usr/local/aws-cli -b /usr/local/bin || true
    rm -rf /tmp/awscliv2.zip /tmp/aws
  fi
fi
AWS_CLI=$(command -v aws || echo /usr/local/bin/aws)

# ---- NVIDIA Fabric Manager ----
# Moved to post-slurmd phase — NVSwitch driver may not be ready at OnNodeConfigured time
# Fabric manager is started in post-slurmd-monitoring.sh with retry logic
echo "nvidia-fabricmanager will be started in post-slurmd phase"

# ---- Tag instance for Prometheus EC2 SD ----
${AWS_CLI} ec2 create-tags --region "${REGION}" --resources "${INSTANCE_ID}" \
  --tags Key=parallelcluster:node-type,Value=Compute 2>/dev/null || true

# NOTE: slurm:hostname and Name tags are set by:
#   1. tag-slurm-hostname.service (systemd timer, runs post-slurmd, retries every 30s for 10min)
#   2. HeadNode cron (every 1min) as authoritative backup via sinfo IP↔hostname mapping
# Pre-slurmd hostname poll removed: Slurm hostname is never assigned at this phase.

# ---- enroot + Pyxis: container runtime for srun --container-image ----
# Must be installed on compute nodes — srun tasks run here
ENROOT_VERSION="3.4.1"
PYXIS_VERSION="0.20.0"

if ! command -v enroot &>/dev/null; then
  echo "Installing enroot ${ENROOT_VERSION} on compute node..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y curl gawk squashfs-tools parallel libcap2-bin 2>/dev/null || true
  ARCH_DEB=$(dpkg --print-architecture)
  curl -fsSL "https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VERSION}/enroot_${ENROOT_VERSION}+1_${ARCH_DEB}.deb" \
    -o /tmp/enroot.deb 2>/dev/null && \
  curl -fsSL "https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VERSION}/enroot+caps_${ENROOT_VERSION}+1_${ARCH_DEB}.deb" \
    -o /tmp/enroot-caps.deb 2>/dev/null && \
  apt-get install -y /tmp/enroot.deb /tmp/enroot-caps.deb 2>&1 | tail -3 || true
  rm -f /tmp/enroot.deb /tmp/enroot-caps.deb
  # enroot config: use /fsx for cache/data
  mkdir -p /etc/enroot /fsx/enroot/cache /fsx/enroot/data 2>/dev/null || true
  cat > /etc/enroot/enroot.conf << 'ENROOTEOF'
ENROOT_RUNTIME_PATH    /run/enroot/user-$(id -u)
ENROOT_CACHE_PATH      /fsx/enroot/cache
ENROOT_DATA_PATH       /fsx/enroot/data
ENROOT_TEMP_PATH       /tmp
ENROOT_SQUASH_OPTIONS  -noI -noD -noF -noX -no-progress
ENROOT_MOUNT_HOME      y
ENROOT_RESTRICT_DEV    y
ENROOT_ROOTFS_WRITABLE y
ENROOTEOF
  echo "enroot installed on compute node"
else
  echo "enroot already present: $(enroot version 2>/dev/null)"
fi

if ! ls /usr/local/lib/slurm/spank_pyxis.so &>/dev/null; then
  echo "Installing Pyxis ${PYXIS_VERSION} on compute node..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y build-essential 2>/dev/null || true
  SLURM_PREFIX=$(dirname "$(dirname "$(command -v sinfo 2>/dev/null || echo /opt/slurm/bin/sinfo)")")
  cd /tmp && rm -rf pyxis-src
  git clone --depth=1 --branch "v${PYXIS_VERSION}" \
    https://github.com/NVIDIA/pyxis.git pyxis-src 2>&1 | tail -2 || true
  if [ -d /tmp/pyxis-src ]; then
    cd /tmp/pyxis-src
    make SLURM_PREFIX="${SLURM_PREFIX}" 2>&1 | tail -3 || true
    make install SLURM_PREFIX="${SLURM_PREFIX}" 2>&1 | tail -2 || true
    cd / && rm -rf /tmp/pyxis-src
    # Register plugin
    mkdir -p /etc/slurm/plugstack.conf.d
    echo "required ${SLURM_PREFIX}/lib/slurm/spank_pyxis.so" \
      > /etc/slurm/plugstack.conf.d/pyxis.conf
    PLUGSTACK="${SLURM_PREFIX}/etc/plugstack.conf"
    grep -q plugstack.conf.d "${PLUGSTACK}" 2>/dev/null || \
      echo "include /etc/slurm/plugstack.conf.d/*.conf" >> "${PLUGSTACK}" 2>/dev/null || true
    echo "Pyxis installed on compute node"
  fi
else
  echo "Pyxis already present on compute node"
fi
# Ensure plugstack.conf is registered regardless (may be missing even if .so exists)
SLURM_PREFIX=$(dirname "$(dirname "$(command -v sinfo 2>/dev/null || echo /opt/slurm/bin/sinfo)")")
mkdir -p /etc/slurm/plugstack.conf.d
PYXIS_CONF="/etc/slurm/plugstack.conf.d/pyxis.conf"
if [ ! -f "${PYXIS_CONF}" ]; then
  echo "required ${SLURM_PREFIX}/lib/slurm/spank_pyxis.so" > "${PYXIS_CONF}"
  echo "pyxis.conf written"
fi
PLUGSTACK="${SLURM_PREFIX}/etc/plugstack.conf"
grep -q plugstack.conf.d "${PLUGSTACK}" 2>/dev/null || \
  echo "include /etc/slurm/plugstack.conf.d/*.conf" >> "${PLUGSTACK}" 2>/dev/null || true

# ---- NCCL dev libraries ----
# Wait for dpkg lock (cloud-init may hold it during boot)
for _i in $(seq 1 30); do
  fuser /var/lib/dpkg/lock-frontend 2>/dev/null || break
  sleep 3
done
if ! dpkg -l libnccl-dev 2>/dev/null | grep -q "^ii"; then
  echo "Installing NCCL dev libraries..."
  export DEBIAN_FRONTEND=noninteractive
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
    -o /tmp/cuda-keyring.deb 2>/dev/null && \
  dpkg -i /tmp/cuda-keyring.deb 2>/dev/null && rm -f /tmp/cuda-keyring.deb || true
  apt-get update -qq 2>/dev/null || true
  apt-get install -y libnccl2 libnccl-dev 2>/dev/null || true
  echo "NCCL dev libraries installed"
fi

# ---- Permanent PATH/LD_LIBRARY_PATH for all users ----
# Slurm job scripts source /etc/profile.d — avoids PATH issues in sbatch
mkdir -p /etc/environment.d
cat > /etc/environment.d/99-hpc-paths.conf << 'ENVEOF'
PATH=/opt/slurm/bin:/opt/amazon/efa/bin:/usr/local/cuda/bin:/opt/amazon/openmpi/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENVEOF

cat > /etc/profile.d/99-hpc-paths.sh << 'PROFEOF'
export PATH=/opt/slurm/bin:/opt/amazon/efa/bin:/usr/local/cuda/bin:/opt/amazon/openmpi/bin:${PATH}
export LD_LIBRARY_PATH=/opt/amazon/openmpi/lib:/opt/amazon/efa/lib:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export NCCL_IB_DISABLE=0
export NCCL_NET_GDR_LEVEL=5
export NCCL_CROSS_NIC=1
# Auto-detect TCP bootstrap interface (first non-lo, non-docker, non-ib, non-rdma Ethernet)
_NCCL_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|veth|ibp|rdmap)' | head -1)
export NCCL_SOCKET_IFNAME=${_NCCL_IF:-enp71s0}
PROFEOF

# ---- ubuntu SSH authorized_keys: copy from headnode via FSx ----
# HeadNode writes its pub key to /fsx/cluster/ubuntu-headnode.pub at startup
# Compute nodes pick it up here so mpirun cross-node SSH works
HEADNODE_PUBKEY="/fsx/cluster/ubuntu-headnode.pub"
if [ -f "${HEADNODE_PUBKEY}" ]; then
  mkdir -p /home/ubuntu/.ssh
  grep -qxFf "${HEADNODE_PUBKEY}" /home/ubuntu/.ssh/authorized_keys 2>/dev/null || \
    cat "${HEADNODE_PUBKEY}" >> /home/ubuntu/.ssh/authorized_keys
  chmod 700 /home/ubuntu/.ssh
  chmod 600 /home/ubuntu/.ssh/authorized_keys
  chown -R ubuntu:ubuntu /home/ubuntu/.ssh
  echo "ubuntu SSH key from headnode deployed"
fi

# ---- Register post-slurmd monitoring installer ----
# Docker + nvidia-container-toolkit + DCGM are installed AFTER slurmd starts
# to avoid network disruption during bootstrap
cat > /usr/local/bin/post-slurmd-monitoring.sh << MONEOF
#!/bin/bash
set -euo pipefail
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION}"
ARCH="${ARCH}"
S3_BUCKET="${S3_BUCKET}"
AWS_CLI=\$(command -v aws || echo /usr/local/bin/aws)

# IMDSv2 token for all metadata calls inside this script
TOKEN=\$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token)
INSTANCE_ID=\$(curl -s -H "X-aws-ec2-metadata-token: \${TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-id)
REGION=\$(curl -s -H "X-aws-ec2-metadata-token: \${TOKEN}" \
  http://169.254.169.254/latest/meta-data/placement/region)

echo "=== Post-slurmd monitoring setup ==="

# Prevent automatic reboot during package install
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l
export NEEDRESTART_SUSPEND=1
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl mask needrestart 2>/dev/null || true
apt-get remove -y --purge needrestart 2>/dev/null || true

# ---- nccl-tests: build to FSx (deferred here to avoid blocking cfn-signal) ----
NCCL_TESTS_DIR="/fsx/nccl-tests/nccl-tests-bin"
if [ ! -f "\${NCCL_TESTS_DIR}/all_reduce_perf" ] && mountpoint -q /fsx 2>/dev/null; then
  echo "Building nccl-tests to \${NCCL_TESTS_DIR}..."
  mkdir -p "\${NCCL_TESTS_DIR}"
  cd /tmp && rm -rf nccl-tests-src
  git clone --depth=1 https://github.com/NVIDIA/nccl-tests.git nccl-tests-src 2>&1 | tail -2 || true
  if [ -d /tmp/nccl-tests-src ]; then
    cd /tmp/nccl-tests-src
    make MPI=1 MPI_HOME=/opt/amazon/openmpi CUDA_HOME=/usr/local/cuda NCCL_HOME=/usr \
         -j\$(nproc) 2>&1 | tail -5 || true
    cp build/*_perf "\${NCCL_TESTS_DIR}/" 2>/dev/null || true
    cd / && rm -rf /tmp/nccl-tests-src
    echo "nccl-tests built: \$(ls \${NCCL_TESTS_DIR}/ | wc -l) binaries"
  fi
fi

# EFA node_exporter
if ! systemctl is-active --quiet node_exporter_efa 2>/dev/null; then
  EFA_EXPORTER_DIR="/opt/efa-node-exporter"
  mkdir -p "\${EFA_EXPORTER_DIR}"
  curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v\${NODE_EXPORTER_VERSION}/node_exporter-\${NODE_EXPORTER_VERSION}.\${ARCH}.tar.gz" \
    | tar -xz -C /tmp
  mv "/tmp/node_exporter-\${NODE_EXPORTER_VERSION}.\${ARCH}/node_exporter" "\${EFA_EXPORTER_DIR}/"
  chmod +x "\${EFA_EXPORTER_DIR}/node_exporter"

  mkdir -p /var/lib/node_exporter/textfile
  cat > /usr/local/bin/efa-metrics-collector.sh << 'EFAEOF'
#!/bin/bash
OUTFILE="/var/lib/node_exporter/textfile/efa.prom"
TMPFILE="\${OUTFILE}.tmp"
> "\${TMPFILE}"
for device in /sys/class/infiniband/*/; do
  dev_name=\$(basename "\${device}")
  for port_dir in "\${device}ports"/*/; do
    port=\$(basename "\${port_dir}")
    for counter_file in "\${port_dir}counters"/*; do
      [ -f "\${counter_file}" ] || continue
      counter_name=\$(basename "\${counter_file}")
      value=\$(cat "\${counter_file}" 2>/dev/null) || continue
      [[ "\${value}" =~ ^[0-9]+\$ ]] || continue
      echo "node_efa_\${counter_name}{device=\"\${dev_name}\",port=\"\${port}\"} \${value}" >> "\${TMPFILE}"
    done
    for counter_file in "\${port_dir}hw_counters"/*; do
      [ -f "\${counter_file}" ] || continue
      counter_name=\$(basename "\${counter_file}")
      value=\$(cat "\${counter_file}" 2>/dev/null) || continue
      [[ "\${value}" =~ ^[0-9]+\$ ]] || continue
      echo "node_efa_hw_\${counter_name}{device=\"\${dev_name}\",port=\"\${port}\"} \${value}" >> "\${TMPFILE}"
    done
  done
done
mv "\${TMPFILE}" "\${OUTFILE}"
EFAEOF
  chmod +x /usr/local/bin/efa-metrics-collector.sh
  cat > /etc/cron.d/efa-metrics << 'CRONEOF'
* * * * * root /usr/local/bin/efa-metrics-collector.sh
* * * * * root sleep 15; /usr/local/bin/efa-metrics-collector.sh
* * * * * root sleep 30; /usr/local/bin/efa-metrics-collector.sh
* * * * * root sleep 45; /usr/local/bin/efa-metrics-collector.sh
CRONEOF

  useradd -rs /bin/false node_exporter 2>/dev/null || true
  chown -R node_exporter:node_exporter /var/lib/node_exporter || true
  cat > /etc/systemd/system/node_exporter_efa.service << SVCEOF
[Unit]
Description=Prometheus node_exporter with EFA textfile collector
After=network.target

[Service]
User=node_exporter
ExecStart=\${EFA_EXPORTER_DIR}/node_exporter \\
  --collector.textfile.directory=/var/lib/node_exporter/textfile \\
  --collector.systemd \\
  --collector.processes \\
  --collector.pressure \\
  --web.listen-address=:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
  # daemon-reload deferred to single call below after all service files written
  systemctl enable --now node_exporter_efa
  /usr/local/bin/efa-metrics-collector.sh || true
fi

# DCGM exporter — Docker (dcgm-exporter has no standalone binary release)
DCGM_IMAGE="nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-ubuntu22.04"
if ! systemctl is-active --quiet dcgm-exporter 2>/dev/null; then
  # Install Docker + nvidia-container-toolkit if needed
  if ! command -v docker &>/dev/null; then
    apt-get update -qq
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --no-tty --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    ARCH=\$(dpkg --print-architecture)
    CODENAME=\$(lsb_release -cs 2>/dev/null || echo jammy)
    echo "deb [arch=\${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \${CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --batch --no-tty --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl enable --now docker
  fi

  cat > /etc/systemd/system/dcgm-exporter.service << SVCEOF
[Unit]
Description=NVIDIA DCGM Exporter
After=docker.service
Requires=docker.service

[Service]
Restart=on-failure
RestartSec=30
StartLimitBurst=5
ExecStartPre=-/usr/bin/docker rm -f dcgm-exporter
ExecStart=/usr/bin/docker run --rm --name dcgm-exporter --privileged --pid=host \
  -v /usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu -v /dev:/dev \
  -e DCGM_EXPORTER_LISTEN=:9400 -e DCGM_EXPORTER_KUBERNETES=false \
  -p 9400:9400 \${DCGM_IMAGE}
ExecStop=/usr/bin/docker stop dcgm-exporter

[Install]
WantedBy=multi-user.target
SVCEOF
  systemctl enable dcgm-exporter
  # Pull synchronously so image is cached before service starts.
  # On reboot, Docker uses local cache — no re-pull needed.
  docker pull "\${DCGM_IMAGE}" 2>&1 | logger -t dcgm-pull
  systemctl start dcgm-exporter
  echo "dcgm-exporter (Docker) started on :9400"
fi

# Single daemon-reload after all service files are written
systemctl daemon-reload

# NOTE: nvidia-fabricmanager is handled by pcluster cinc recipe (fabric_manager :configure)
# Do NOT start/enable it here — causes race condition and unexpected reboot on p6-b200

echo "=== Post-slurmd monitoring setup complete ==="
MONEOF
chmod +x /usr/local/bin/post-slurmd-monitoring.sh

# Register as systemd service that runs after slurmd
# Restart=on-failure so transient apt/network errors are retried
cat > /etc/systemd/system/post-slurmd-monitoring.service << SVCEOF
[Unit]
Description=Install monitoring stack after slurmd is running
After=slurmd.service
Wants=slurmd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/post-slurmd-monitoring.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=60
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
SVCEOF

# ---- slurm:hostname tag via systemd timer (retries every 30s for up to 10min) ----
# Runs post-slurmd when Slurm hostname is reliably available.
# HeadNode cron (1min) is the authoritative backup.
cat > /usr/local/bin/tag-slurm-hostname.sh << 'TAGEOF'
#!/bin/bash
TOKEN=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token)
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/placement/region)
AWS_CLI=$(command -v aws || echo /usr/local/bin/aws)
# Read Slurm nodename from pcluster-written file (available before slurmd starts)
# Fallback to hostname -s for non-pcluster environments
HOST=$(cat /etc/parallelcluster/slurm_plugin/slurm_nodename 2>/dev/null || hostname -s 2>/dev/null)
if [[ -n "${HOST}" && ! "${HOST}" =~ ^ip- ]]; then
  ${AWS_CLI} ec2 create-tags --region "${REGION}" --resources "${INSTANCE_ID}" \
    --tags "Key=slurm:hostname,Value=${HOST}" "Key=Name,Value=${HOST}" 2>/dev/null && \
    echo "Tagged ${INSTANCE_ID} slurm:hostname=${HOST}" && \
    systemctl stop tag-slurm-hostname.timer
fi
TAGEOF
chmod +x /usr/local/bin/tag-slurm-hostname.sh

cat > /etc/systemd/system/tag-slurm-hostname.service << SVCEOF
[Unit]
Description=Tag EC2 instance with Slurm hostname for Prometheus

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tag-slurm-hostname.sh
SVCEOF

cat > /etc/systemd/system/tag-slurm-hostname.timer << SVCEOF
[Unit]
Description=Retry slurm:hostname EC2 tag every 30s (stops itself on success)

[Timer]
OnBootSec=30
OnUnitActiveSec=30
AccuracySec=5

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable post-slurmd-monitoring.service
systemctl enable tag-slurm-hostname.timer
systemctl start tag-slurm-hostname.timer

# Start post-slurmd-monitoring now if slurmd is already running
# (After=slurmd.service only triggers on boot — if OnNodeConfigured runs after slurmd, we must start manually)
if systemctl is-active --quiet slurmd 2>/dev/null; then
  echo "slurmd already running — starting post-slurmd-monitoring immediately"
  systemctl start post-slurmd-monitoring.service &
fi

echo "=== ComputeNode pre-slurmd setup complete ==="
