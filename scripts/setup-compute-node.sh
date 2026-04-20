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

# DCGM exporter — binary (no Docker, avoids iptables disruption)
if ! systemctl is-active --quiet dcgm-exporter 2>/dev/null; then
  # Install nvidia-dcgm if not already present (DLAMI may include it)
  if ! command -v nv-hostengine &>/dev/null; then
    curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
      -o /tmp/cuda-keyring.deb
    dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb
    apt-get update -qq
    apt-get install -y datacenter-gpu-manager
  fi

  # dcgm-exporter binary
  DCGM_EXPORTER_VERSION="4.5.2"
  if ! command -v dcgm-exporter &>/dev/null; then
    curl -fsSL "https://github.com/NVIDIA/dcgm-exporter/releases/download/v\${DCGM_EXPORTER_VERSION}/dcgm-exporter_\${DCGM_EXPORTER_VERSION}_Linux_x86_64.tar.gz" \
      -o /tmp/dcgm-exporter.tar.gz 2>/dev/null || true
    if [ -f /tmp/dcgm-exporter.tar.gz ]; then
      tar -xz -C /usr/local/bin -f /tmp/dcgm-exporter.tar.gz dcgm-exporter 2>/dev/null || true
      chmod +x /usr/local/bin/dcgm-exporter 2>/dev/null || true
      rm /tmp/dcgm-exporter.tar.gz
    fi
  fi

  # nv-hostengine must be running before dcgm-exporter
  systemctl enable --now nvidia-dcgm 2>/dev/null || \
    (nv-hostengine 2>/dev/null &) || true

  cat > /etc/systemd/system/dcgm-exporter.service << SVCEOF
[Unit]
Description=NVIDIA DCGM Exporter (binary)
After=network.target nvidia-dcgm.service
Wants=nvidia-dcgm.service

[Service]
ExecStart=/usr/local/bin/dcgm-exporter --address :9400
Restart=on-failure
RestartSec=30
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
SVCEOF
  systemctl daemon-reload
  systemctl enable --now dcgm-exporter
  echo "dcgm-exporter (binary) started on :9400"
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
# post-slurmd-monitoring.service temporarily disabled — docker install via systemd causes reboot on p6-b200
# systemctl enable post-slurmd-monitoring.service
systemctl enable tag-slurm-hostname.timer
systemctl start tag-slurm-hostname.timer

echo "=== ComputeNode pre-slurmd setup complete ==="
