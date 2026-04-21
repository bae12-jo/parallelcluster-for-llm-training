#!/bin/bash
# ComputeNode setup: runs during OnNodeConfigured (before slurmd)
# This script must complete in < 5 min — heavy installs go in post-slurmd-monitoring.service
# Args: $1 = S3_BUCKET (optional)
set -euxo pipefail

S3_BUCKET="${1:-}"
NODE_EXPORTER_VERSION="1.11.1"
ARCH="linux-amd64"

echo "=== ComputeNode setup (pre-slurmd phase) ==="

# ---- IMDSv2 token ----
TOKEN=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token)
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/placement/region)

# ---- AWS CLI ----
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

# ---- dpkg hook: prevent reboot-required from triggering cinc finalize reboot ----
# Must be installed FIRST, before any apt calls below
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99-no-reboot-required << 'HOOKEOF'
DPkg::Post-Invoke { "rm -f /var/run/reboot-required /var/run/reboot-required.pkgs 2>/dev/null || true"; };
HOOKEOF
rm -f /var/run/reboot-required /var/run/reboot-required.pkgs 2>/dev/null || true

# ---- Tag instance for Prometheus EC2 SD ----
${AWS_CLI} ec2 create-tags --region "${REGION}" --resources "${INSTANCE_ID}" \
  --tags Key=parallelcluster:node-type,Value=Compute 2>/dev/null || true

# ---- PATH/LD_LIBRARY_PATH — three layers so every execution context gets correct paths ----

# Layer 1: /etc/environment — read by PAM for all login sessions and slurmd process env
# Write the full PATH explicitly (cannot append in /etc/environment format)
cat > /etc/environment << 'ENVEOF'
PATH="/opt/slurm/bin:/opt/amazon/efa/bin:/usr/local/cuda/bin:/opt/amazon/openmpi/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LD_LIBRARY_PATH="/opt/amazon/openmpi/lib:/opt/amazon/efa/lib:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu"
FI_PROVIDER="efa"
FI_EFA_USE_DEVICE_RDMA="1"
NCCL_IB_DISABLE="0"
NCCL_NET_GDR_LEVEL="5"
NCCL_CROSS_NIC="1"
ENVEOF

# Layer 2: /etc/profile.d — sourced by interactive shells and sudo -i
mkdir -p /etc/profile.d
cat > /etc/profile.d/99-hpc-paths.sh << 'PROFEOF'
export PATH=/opt/slurm/bin:/opt/amazon/efa/bin:/usr/local/cuda/bin:/opt/amazon/openmpi/bin:${PATH}
export LD_LIBRARY_PATH=/opt/amazon/openmpi/lib:/opt/amazon/efa/lib:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export NCCL_IB_DISABLE=0
export NCCL_NET_GDR_LEVEL=5
export NCCL_CROSS_NIC=1
# Auto-detect TCP bootstrap interface (first non-lo, non-docker, non-ib, non-rdma ethernet)
_NCCL_IF=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|veth|ibp|rdmap)' | head -1)
export NCCL_SOCKET_IFNAME=${_NCCL_IF:-eth0}
PROFEOF

# Layer 3: Slurm TaskProlog — runs in the job's env just before task launch
# This is the only reliable way to inject env into sbatch/srun non-interactive shells
mkdir -p /opt/slurm/etc
cat > /opt/slurm/etc/task_prolog.sh << 'PROLOGEOF'
#!/bin/bash
# Injected by pcluster setup — sets HPC paths for every Slurm task
export PATH=/opt/slurm/bin:/opt/amazon/efa/bin:/usr/local/cuda/bin:/opt/amazon/openmpi/bin:${PATH}
export LD_LIBRARY_PATH=/opt/amazon/openmpi/lib:/opt/amazon/efa/lib:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export NCCL_IB_DISABLE=0
export NCCL_NET_GDR_LEVEL=5
export NCCL_CROSS_NIC=1
_NCCL_IF=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|veth|ibp|rdmap)' | head -1)
export NCCL_SOCKET_IFNAME=${_NCCL_IF:-eth0}
PROLOGEOF
chmod +x /opt/slurm/etc/task_prolog.sh

# Register TaskProlog in slurm.conf (only on compute node — slurmctld reads it from headnode,
# but compute node needs it locally for slurmstepd which executes the prolog)
SLURM_CONF=/opt/slurm/etc/slurm.conf
if [ -f "${SLURM_CONF}" ]; then
  grep -q "^TaskProlog" "${SLURM_CONF}" || \
    echo "TaskProlog=/opt/slurm/etc/task_prolog.sh" >> "${SLURM_CONF}"
fi

# ---- ubuntu SSH authorized_keys: copy from headnode via FSx ----
HEADNODE_PUBKEY="/fsx/cluster/ubuntu-headnode.pub"
if [ -f "${HEADNODE_PUBKEY}" ]; then
  mkdir -p /home/ubuntu/.ssh
  grep -qxFf "${HEADNODE_PUBKEY}" /home/ubuntu/.ssh/authorized_keys 2>/dev/null || \
    cat "${HEADNODE_PUBKEY}" >> /home/ubuntu/.ssh/authorized_keys
  chmod 700 /home/ubuntu/.ssh
  chmod 600 /home/ubuntu/.ssh/authorized_keys
  chown -R ubuntu:ubuntu /home/ubuntu/.ssh
fi

# ---- post-slurmd-monitoring.service script (written now, executed AFTER slurmd) ----
# Heavy installs (enroot, Pyxis, NCCL, Docker, DCGM, node_exporter) happen here
# so OnNodeConfigured completes quickly and cfn-signal fires on time.
cat > /usr/local/bin/post-slurmd-monitoring.sh << MONEOF
#!/bin/bash
set -euo pipefail
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION}"
ARCH="${ARCH}"
S3_BUCKET="${S3_BUCKET}"
AWS_CLI=\$(command -v aws || echo /usr/local/bin/aws)

TOKEN=\$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token)
INSTANCE_ID=\$(curl -s -H "X-aws-ec2-metadata-token: \${TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-id)
REGION=\$(curl -s -H "X-aws-ec2-metadata-token: \${TOKEN}" \
  http://169.254.169.254/latest/meta-data/placement/region)

echo "=== Post-slurmd setup: enroot / Pyxis / NCCL / monitoring ==="

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l
export NEEDRESTART_SUSPEND=1
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl mask needrestart 2>/dev/null || true
apt-get remove -y --purge needrestart 2>/dev/null || true

# ---- enroot ----
ENROOT_VERSION="3.4.1"
if ! command -v enroot &>/dev/null; then
  echo "Installing enroot \${ENROOT_VERSION}..."
  apt-get install -y curl gawk squashfs-tools parallel libcap2-bin 2>/dev/null || true
  ARCH_DEB=\$(dpkg --print-architecture)
  curl -fsSL "https://github.com/NVIDIA/enroot/releases/download/v\${ENROOT_VERSION}/enroot_\${ENROOT_VERSION}+1_\${ARCH_DEB}.deb" \
    -o /tmp/enroot.deb 2>/dev/null
  curl -fsSL "https://github.com/NVIDIA/enroot/releases/download/v\${ENROOT_VERSION}/enroot+caps_\${ENROOT_VERSION}+1_\${ARCH_DEB}.deb" \
    -o /tmp/enroot-caps.deb 2>/dev/null
  apt-get install -y /tmp/enroot.deb /tmp/enroot-caps.deb 2>&1 | tail -3 || true
  rm -f /tmp/enroot.deb /tmp/enroot-caps.deb
  mkdir -p /etc/enroot /fsx/enroot/cache /fsx/enroot/data 2>/dev/null || true
  cat > /etc/enroot/enroot.conf << 'ENROOTEOF'
ENROOT_RUNTIME_PATH    /run/enroot/user-\$(id -u)
ENROOT_CACHE_PATH      /fsx/enroot/cache
ENROOT_DATA_PATH       /fsx/enroot/data
ENROOT_TEMP_PATH       /tmp
ENROOT_SQUASH_OPTIONS  -noI -noD -noF -noX -no-progress
ENROOT_MOUNT_HOME      y
ENROOT_RESTRICT_DEV    y
ENROOT_ROOTFS_WRITABLE y
ENROOTEOF
  echo "enroot installed"
fi

# ---- Pyxis (Slurm SPANK plugin for srun --container-image) ----
PYXIS_VERSION="0.20.0"
SLURM_PREFIX=\$(dirname "\$(dirname "\$(command -v sinfo 2>/dev/null || echo /opt/slurm/bin/sinfo)")")
if ! ls "\${SLURM_PREFIX}/lib/slurm/spank_pyxis.so" &>/dev/null; then
  echo "Building Pyxis \${PYXIS_VERSION}..."
  apt-get install -y build-essential git 2>/dev/null | tail -2 || true
  cd /tmp && rm -rf pyxis-src
  git clone --depth=1 --branch "v\${PYXIS_VERSION}" \
    https://github.com/NVIDIA/pyxis.git pyxis-src 2>&1 | tail -2 || true
  if [ -d /tmp/pyxis-src ]; then
    cd /tmp/pyxis-src
    make SLURM_PREFIX="\${SLURM_PREFIX}" CPPFLAGS="-I\${SLURM_PREFIX}/include -D_GNU_SOURCE" \
      2>&1 | tail -5 || true
    make install SLURM_PREFIX="\${SLURM_PREFIX}" 2>&1 | tail -2 || true
    cd / && rm -rf /tmp/pyxis-src
    # Register Pyxis — safe here because cinc init already completed before this runs
    mkdir -p /etc/slurm/plugstack.conf.d
    echo "required \${SLURM_PREFIX}/lib/slurm/spank_pyxis.so" \
      > /etc/slurm/plugstack.conf.d/pyxis.conf
    grep -q plugstack.conf.d "\${SLURM_PREFIX}/etc/plugstack.conf" 2>/dev/null || \
      echo "include /etc/slurm/plugstack.conf.d/*.conf" >> "\${SLURM_PREFIX}/etc/plugstack.conf" || true
    echo "Pyxis installed"
  fi
fi

# ---- NCCL dev libraries ----
if ! dpkg -l libnccl-dev 2>/dev/null | grep -q "^ii"; then
  echo "Installing NCCL dev libraries..."
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
    -o /tmp/cuda-keyring.deb 2>/dev/null
  dpkg -i /tmp/cuda-keyring.deb 2>/dev/null && rm -f /tmp/cuda-keyring.deb || true
  apt-get update -qq 2>/dev/null || true
  apt-get install -y libnccl2 libnccl-dev 2>/dev/null || true
fi

# ---- nccl-tests: build to FSx ----
NCCL_TESTS_DIR="/fsx/nccl-tests/nccl-tests-bin"
if [ ! -f "\${NCCL_TESTS_DIR}/all_reduce_perf" ] && mountpoint -q /fsx 2>/dev/null; then
  echo "Building nccl-tests..."
  mkdir -p "\${NCCL_TESTS_DIR}"
  cd /tmp && rm -rf nccl-tests-src
  git clone --depth=1 https://github.com/NVIDIA/nccl-tests.git nccl-tests-src 2>&1 | tail -2 || true
  if [ -d /tmp/nccl-tests-src ]; then
    cd /tmp/nccl-tests-src
    make MPI=1 MPI_HOME=/opt/amazon/openmpi CUDA_HOME=/usr/local/cuda NCCL_HOME=/usr \
         -j\$(nproc) 2>&1 | tail -5 || true
    cp build/*_perf "\${NCCL_TESTS_DIR}/" 2>/dev/null || true
    cd / && rm -rf /tmp/nccl-tests-src
    echo "nccl-tests: \$(ls \${NCCL_TESTS_DIR}/ | wc -l) binaries built"
  fi
fi

# ---- EFA node_exporter ----
# Service file is already written and enabled by OnNodeConfigured.
# This block runs the initial install if the binary is missing (first boot).
EFA_EXPORTER_DIR="/opt/efa-node-exporter"
if [ ! -f "\${EFA_EXPORTER_DIR}/node_exporter" ]; then
  mkdir -p "\${EFA_EXPORTER_DIR}"
  curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v\${NODE_EXPORTER_VERSION}/node_exporter-\${NODE_EXPORTER_VERSION}.\${ARCH}.tar.gz" \
    | tar -xz -C /tmp
  mv "/tmp/node_exporter-\${NODE_EXPORTER_VERSION}.\${ARCH}/node_exporter" "\${EFA_EXPORTER_DIR}/"
  chmod +x "\${EFA_EXPORTER_DIR}/node_exporter"
  echo "node_exporter binary installed"
fi
# Always start — handles first boot and reboot (service is enabled, just needs the binary)
systemctl start node_exporter_efa 2>/dev/null || true

# ---- DCGM exporter (Docker) ----
DCGM_IMAGE="nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-ubuntu22.04"
if ! command -v docker &>/dev/null; then
  echo "Installing Docker + nvidia-container-toolkit..."
  apt-get update -qq
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --batch --no-tty --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  ARCH_DPK=\$(dpkg --print-architecture)
  CODENAME=\$(lsb_release -cs 2>/dev/null || echo jammy)
  echo "deb [arch=\${ARCH_DPK} signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \${CODENAME} stable" \
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
# Pull image if not cached yet
docker image inspect "\${DCGM_IMAGE}" &>/dev/null || \
  docker pull "\${DCGM_IMAGE}" 2>&1 | logger -t dcgm-pull || true
# Start service (enabled by OnNodeConfigured, handles both first boot and reboot)
systemctl start dcgm-exporter 2>/dev/null || true

echo "=== Post-slurmd setup complete ==="
MONEOF
chmod +x /usr/local/bin/post-slurmd-monitoring.sh

# ---- EFA metrics collector (cron writes .prom textfile) ----
mkdir -p /var/lib/node_exporter/textfile
cat > /usr/local/bin/efa-metrics-collector.sh << 'EFAEOF'
#!/bin/bash
OUTFILE="/var/lib/node_exporter/textfile/efa.prom"
TMPFILE="${OUTFILE}.tmp"
> "${TMPFILE}"
for device in /sys/class/infiniband/*/; do
  dev_name=$(basename "${device}")
  for port_dir in "${device}ports"/*/; do
    port=$(basename "${port_dir}")
    for counter_file in "${port_dir}counters"/*; do
      [ -f "${counter_file}" ] || continue
      counter_name=$(basename "${counter_file}")
      value=$(cat "${counter_file}" 2>/dev/null) || continue
      [[ "${value}" =~ ^[0-9]+$ ]] || continue
      echo "node_efa_${counter_name}{device=\"${dev_name}\",port=\"${port}\"} ${value}" >> "${TMPFILE}"
    done
    for counter_file in "${port_dir}hw_counters"/*; do
      [ -f "${counter_file}" ] || continue
      counter_name=$(basename "${counter_file}")
      value=$(cat "${counter_file}" 2>/dev/null) || continue
      [[ "${value}" =~ ^[0-9]+$ ]] || continue
      echo "node_efa_hw_${counter_name}{device=\"${dev_name}\",port=\"${port}\"} ${value}" >> "${TMPFILE}"
    done
  done
done
mv "${TMPFILE}" "${OUTFILE}"
EFAEOF
chmod +x /usr/local/bin/efa-metrics-collector.sh
cat > /etc/cron.d/efa-metrics << 'CRONEOF'
* * * * * root /usr/local/bin/efa-metrics-collector.sh
* * * * * root sleep 15; /usr/local/bin/efa-metrics-collector.sh
* * * * * root sleep 30; /usr/local/bin/efa-metrics-collector.sh
* * * * * root sleep 45; /usr/local/bin/efa-metrics-collector.sh
CRONEOF

# ---- node_exporter_efa service (independent unit — survives reboots) ----
EFA_EXPORTER_DIR="/opt/efa-node-exporter"
mkdir -p "${EFA_EXPORTER_DIR}"
useradd -rs /bin/false node_exporter 2>/dev/null || true
mkdir -p /var/lib/node_exporter/textfile
chown -R node_exporter:node_exporter /var/lib/node_exporter || true
cat > /etc/systemd/system/node_exporter_efa.service << 'SVCEOF'
[Unit]
Description=Prometheus node_exporter with EFA textfile collector
After=network.target
# No dependency on post-slurmd-monitoring — binary installed separately

[Service]
User=node_exporter
ExecStart=/opt/efa-node-exporter/node_exporter \
  --collector.textfile.directory=/var/lib/node_exporter/textfile \
  --collector.systemd \
  --collector.processes \
  --collector.pressure \
  --web.listen-address=:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

# ---- dcgm-exporter service (independent unit — survives reboots) ----
DCGM_IMAGE="nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-ubuntu22.04"
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
  -p 9400:9400 ${DCGM_IMAGE}
ExecStop=/usr/bin/docker stop dcgm-exporter

[Install]
WantedBy=multi-user.target
SVCEOF

# ---- post-slurmd-monitoring service ----
cat > /etc/systemd/system/post-slurmd-monitoring.service << 'SVCEOF'
[Unit]
Description=Install enroot / Pyxis / NCCL / monitoring stack after slurmd
After=slurmd.service
Wants=slurmd.service
# Run on every boot — not just first boot (ConditionPathExists removed)

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

# ---- tag-slurm-hostname timer ----
cat > /usr/local/bin/tag-slurm-hostname.sh << 'TAGEOF'
#!/bin/bash
TOKEN=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token)
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/placement/region)
AWS_CLI=$(command -v aws || echo /usr/local/bin/aws)
HOST=$(cat /etc/parallelcluster/slurm_plugin/slurm_nodename 2>/dev/null || hostname -s 2>/dev/null)
if [[ -n "${HOST}" && ! "${HOST}" =~ ^ip- ]]; then
  ${AWS_CLI} ec2 create-tags --region "${REGION}" --resources "${INSTANCE_ID}" \
    --tags "Key=slurm:hostname,Value=${HOST}" "Key=Name,Value=${HOST}" 2>/dev/null && \
    echo "Tagged ${INSTANCE_ID} slurm:hostname=${HOST}" && \
    systemctl stop tag-slurm-hostname.timer
fi
TAGEOF
chmod +x /usr/local/bin/tag-slurm-hostname.sh

cat > /etc/systemd/system/tag-slurm-hostname.service << 'SVCEOF'
[Unit]
Description=Tag EC2 instance with Slurm hostname for Prometheus

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tag-slurm-hostname.sh
SVCEOF

cat > /etc/systemd/system/tag-slurm-hostname.timer << 'SVCEOF'
[Unit]
Description=Retry slurm:hostname EC2 tag every 30s (stops itself on success)

[Timer]
OnBootSec=30
OnUnitActiveSec=30
AccuracySec=5

[Install]
WantedBy=multi-user.target
SVCEOF

# ---- Enable all services ----
systemctl daemon-reload
systemctl enable post-slurmd-monitoring.service
systemctl enable node_exporter_efa.service
systemctl enable dcgm-exporter.service
systemctl enable tag-slurm-hostname.timer
systemctl start tag-slurm-hostname.timer

# post-slurmd-monitoring: start now if slurmd is already running.
# systemd After=slurmd.service only works on boot ordering — if OnNodeConfigured fires
# after slurmd has already started, the dependency is already satisfied and the service
# won't auto-start. We must trigger it explicitly.
# Using nohup so it runs independently and doesn't block cfn-signal.
nohup systemctl start post-slurmd-monitoring.service >/dev/null 2>&1 &
echo "post-slurmd-monitoring.service start triggered (runs in background)"

# ---- CRITICAL: clear reboot-required before cfn-signal ----
rm -f /var/run/reboot-required /var/run/reboot-required.pkgs 2>/dev/null || true

echo "=== ComputeNode pre-slurmd setup complete ==="
