#!/bin/bash
# ComputeNode setup: DCGM exporter 4.5.2 (B200 support) + EFA node_exporter fork
# Args: $1 = S3_BUCKET (optional)
set -euxo pipefail

S3_BUCKET="${1:-}"
# DCGM exporter 4.5.2-4.8.1 -- full Blackwell/B200 + NVLink-5 support
DCGM_EXPORTER_IMAGE="nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-ubuntu22.04"
NODE_EXPORTER_VERSION="1.11.1"
ARCH="linux-amd64"

echo "=== ComputeNode monitoring setup ==="

# ---- AWS CLI ----
if ! command -v aws &>/dev/null; then
  apt-get install -y unzip -qq 2>/dev/null || true
  curl -s https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install -i /usr/local/aws-cli -b /usr/local/bin
  rm -rf /tmp/awscliv2.zip /tmp/aws
fi
AWS_CLI=$(command -v aws || echo /usr/local/bin/aws)

# ---- Docker + nvidia-container-toolkit ----
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y ca-certificates curl gnupg

  # Docker repo
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  # nvidia-container-toolkit repo
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list

  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl enable --now docker
  systemctl restart docker
fi

# ---- EFA node_exporter fork ----
# aws-samples/awsome-distributed-training EFA-patched node_exporter
# Adds /sys/class/infiniband EFA counters as Prometheus metrics
if ! systemctl is-active --quiet node_exporter_efa; then
  EFA_EXPORTER_DIR="/opt/efa-node-exporter"
  mkdir -p "${EFA_EXPORTER_DIR}"

  # Download pre-built EFA fork binary if available, else build upstream with EFA collector script
  # Using upstream node_exporter + textfile collector for EFA counters (portable approach)
  curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz" \
    | tar -xz -C /tmp
  mv "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}/node_exporter" "${EFA_EXPORTER_DIR}/"
  chmod +x "${EFA_EXPORTER_DIR}/node_exporter"

  # EFA textfile collector: reads /sys/class/infiniband counters
  mkdir -p /var/lib/node_exporter/textfile
  cat > /usr/local/bin/efa-metrics-collector.sh <<'EFAEOF'
#!/bin/bash
# Collect EFA (rdma) counters via /sys/class/infiniband
# Outputs Prometheus textfile format to /var/lib/node_exporter/textfile/efa.prom
OUTFILE="/var/lib/node_exporter/textfile/efa.prom"
TMPFILE="${OUTFILE}.tmp"

> "${TMPFILE}"

for device in /sys/class/infiniband/*/; do
  dev_name=$(basename "${device}")
  for port_dir in "${device}ports"/*/; do
    port=$(basename "${port_dir}")
    counter_dir="${port_dir}counters"
    hw_counter_dir="${port_dir}hw_counters"

    for counter_file in "${counter_dir}"/*; do
      [ -f "${counter_file}" ] || continue
      counter_name=$(basename "${counter_file}")
      value=$(cat "${counter_file}" 2>/dev/null) || continue
      [[ "${value}" =~ ^[0-9]+$ ]] || continue
      echo "node_efa_${counter_name}{device=\"${dev_name}\",port=\"${port}\"} ${value}" >> "${TMPFILE}"
    done

    if [ -d "${hw_counter_dir}" ]; then
      for counter_file in "${hw_counter_dir}"/*; do
        [ -f "${counter_file}" ] || continue
        counter_name=$(basename "${counter_file}")
        value=$(cat "${counter_file}" 2>/dev/null) || continue
        [[ "${value}" =~ ^[0-9]+$ ]] || continue
        echo "node_efa_hw_${counter_name}{device=\"${dev_name}\",port=\"${port}\"} ${value}" >> "${TMPFILE}"
      done
    fi
  done
done

mv "${TMPFILE}" "${OUTFILE}"
EFAEOF
  chmod +x /usr/local/bin/efa-metrics-collector.sh

  # Cron: collect EFA metrics every 15s
  cat > /etc/cron.d/efa-metrics <<EOF
* * * * * root /usr/local/bin/efa-metrics-collector.sh
* * * * * root sleep 15; /usr/local/bin/efa-metrics-collector.sh
* * * * * root sleep 30; /usr/local/bin/efa-metrics-collector.sh
* * * * * root sleep 45; /usr/local/bin/efa-metrics-collector.sh
EOF

  useradd -rs /bin/false node_exporter 2>/dev/null || true
  chown -R node_exporter:node_exporter /var/lib/node_exporter || true

  cat > /etc/systemd/system/node_exporter_efa.service <<EOF
[Unit]
Description=Prometheus node_exporter with EFA textfile collector
After=network.target

[Service]
User=node_exporter
ExecStart=${EFA_EXPORTER_DIR}/node_exporter \
  --collector.textfile.directory=/var/lib/node_exporter/textfile \
  --collector.systemd \
  --collector.processes \
  --collector.pressure \
  --web.listen-address=:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now node_exporter_efa
  # Seed first collection
  /usr/local/bin/efa-metrics-collector.sh || true
  echo "node_exporter (EFA) started on :9100"
fi

# ---- NVIDIA Fabric Manager (NVLink/NVSwitch — required for B200/H100 multi-GPU) ----
# Installed in pcluster AMI but disabled by default — enable for NVLink topology
if systemctl list-unit-files nvidia-fabricmanager.service &>/dev/null; then
  systemctl enable --now nvidia-fabricmanager 2>/dev/null || true
  echo "nvidia-fabricmanager enabled"
fi

# ---- DCGM exporter 4.5.2-4.8.1 ----
# Pull + start via post-boot oneshot so it doesn't block OnNodeConfigured timeout
if ! systemctl is-active --quiet dcgm-exporter; then
  # Write start script — actual docker pull happens in background after cfn-signal
  cat > /usr/local/bin/start-dcgm-exporter.sh << DCGMEOF
#!/bin/bash
DCGM_EXPORTER_IMAGE="${DCGM_EXPORTER_IMAGE}"
docker pull "\${DCGM_EXPORTER_IMAGE}" 2>&1 | logger -t dcgm-pull
systemctl start dcgm-exporter
DCGMEOF
  chmod +x /usr/local/bin/start-dcgm-exporter.sh

  cat > /etc/systemd/system/dcgm-exporter.service <<EOF
[Unit]
Description=NVIDIA DCGM Exporter (4.5.2 - Blackwell B200 support)
After=docker.service
Requires=docker.service

[Service]
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f dcgm-exporter
ExecStart=/usr/bin/docker run --rm \
  --name dcgm-exporter \
  --privileged --pid=host \
  -v /usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu \
  -v /dev:/dev \
  -e DCGM_EXPORTER_LISTEN=:9400 \
  -e DCGM_EXPORTER_KUBERNETES=false \
  -p 9400:9400 \
  ${DCGM_EXPORTER_IMAGE}
ExecStop=/usr/bin/docker stop dcgm-exporter

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/dcgm-pull.service <<EOF
[Unit]
Description=Pull DCGM exporter image and start service
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/start-dcgm-exporter.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable dcgm-exporter
  systemctl enable dcgm-pull.service
  systemctl start dcgm-pull.service &
  echo "DCGM pull queued in background (~2min)"
fi

# Tag instance for Prometheus EC2 SD
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
${AWS_CLI} ec2 create-tags --region "${REGION}" --resources "${INSTANCE_ID}" \
  --tags Key=parallelcluster:node-type,Value=Compute 2>/dev/null || true

# Set Name tag using Slurm hostname (stable across instance replacements within same slot)
for i in $(seq 1 30); do
  HOST=$(hostname -s 2>/dev/null)
  if [[ -n "${HOST}" && ! "${HOST}" =~ ^ip- ]]; then
    ${AWS_CLI} ec2 create-tags --region "${REGION}" --resources "${INSTANCE_ID}" \
      --tags "Key=Name,Value=${HOST}" 2>/dev/null || true
    echo "Node Name tag set: ${HOST}"
    break
  fi
  sleep 10
done

# ---- slurm:hostname tag (for Prometheus node_name label) ----
# Slurm assigns hostname after boot; retry until we get a non-IMDS name
cat > /usr/local/bin/tag-slurm-hostname.sh <<'TAGEOF'
#!/bin/bash
AWS_CLI=$(command -v aws || echo /usr/local/bin/aws)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
for i in $(seq 1 30); do
  HOST=$(hostname -s 2>/dev/null)
  if [[ -n "${HOST}" && ! "${HOST}" =~ ^ip- ]]; then
    ${AWS_CLI} ec2 create-tags --region "${REGION}" --resources "${INSTANCE_ID}" \
      --tags "Key=slurm:hostname,Value=${HOST}" 2>/dev/null
    echo "Tagged ${INSTANCE_ID} slurm:hostname=${HOST}"
    systemctl disable tag-slurm-hostname.service 2>/dev/null || true
    exit 0
  fi
  sleep 10
done
echo "WARNING: could not get Slurm hostname after 5min, skipping tag"
TAGEOF
chmod +x /usr/local/bin/tag-slurm-hostname.sh

cat > /etc/systemd/system/tag-slurm-hostname.service <<EOF
[Unit]
Description=Tag EC2 instance with Slurm hostname for Prometheus
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tag-slurm-hostname.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tag-slurm-hostname.service
systemctl start tag-slurm-hostname.service &

echo "=== ComputeNode monitoring setup complete ==="
echo "  node_exporter (EFA): :9100"
echo "  dcgm-exporter       : :9400"
echo "  slurm:hostname tag  : tagging in background"
