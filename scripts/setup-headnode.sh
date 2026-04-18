#!/bin/bash
# HeadNode setup: slurm_exporter (rivosinc v1.8.0) + node_exporter v1.11.1
# Args: $1 = S3_BUCKET (optional)
set -euxo pipefail

S3_BUCKET="${1:-}"
NODE_EXPORTER_VERSION="1.11.1"
SLURM_EXPORTER_VERSION="1.8.0"
GO_VERSION="1.23.1"
ARCH="linux-amd64"

echo "=== HeadNode monitoring setup ==="

# ---- Prerequisites ----
apt-get update -qq
apt-get install -y git curl wget unzip

# ---- AWS CLI ----
if ! command -v aws &>/dev/null; then
  curl -s https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install -i /usr/local/aws-cli -b /usr/local/bin
  rm -rf /tmp/awscliv2.zip /tmp/aws
fi
AWS_CLI=$(command -v aws || echo /usr/local/bin/aws)

# ---- Lustre kernel module: ensure running kernel version matches installed module ----
KERNEL=$(uname -r)
if ! modprobe lustre &>/dev/null; then
  echo "Lustre module not found for kernel ${KERNEL}, installing..."
  apt-get install -y "lustre-client-modules-${KERNEL}" 2>/dev/null || \
  apt-get install -y lustre-client-modules-aws 2>/dev/null || true
  modprobe lustre 2>/dev/null || echo "WARNING: lustre module still not loaded"
fi

# Fix fstab: remove 'noauto' so FSx mounts on boot without requiring manual trigger
if grep -q 'noauto' /etc/fstab; then
  sed -i 's/noauto,//g; s/,noauto//g' /etc/fstab
  echo "Fixed fstab: removed noauto from FSx entry"
fi

# Mount FSx if not already mounted
if ! mountpoint -q /fsx 2>/dev/null; then
  mkdir -p /fsx
  mount /fsx 2>/dev/null && echo "FSx mounted" || echo "WARNING: FSx mount failed, continuing"
fi

# ---- node_exporter ----
if ! systemctl is-active --quiet node_exporter 2>/dev/null; then
  curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}.tar.gz" \
    | tar -xz -C /tmp
  mv "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.${ARCH}/node_exporter" /usr/local/bin/
  chmod +x /usr/local/bin/node_exporter
  useradd -rs /bin/false node_exporter 2>/dev/null || true

  cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus node_exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter \
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
  systemctl enable --now node_exporter
  echo "node_exporter started on :9100"
fi

# ---- slurm_exporter: install post-boot via systemd oneshot ----
# go build takes ~10 min — runs AFTER cfn-signal so it doesn't block cluster creation
GO_VERSION="1.23.1"

# Download install script from S3 if bucket provided, else embed inline
if [ -n "${S3_BUCKET}" ]; then
  aws s3 cp "s3://${S3_BUCKET}/scripts/install-slurm-exporter.sh" \
    /usr/local/bin/install-slurm-exporter.sh 2>/dev/null || true
fi

# Fallback: write inline if not already present
if [ ! -f /usr/local/bin/install-slurm-exporter.sh ]; then
  cat > /usr/local/bin/install-slurm-exporter.sh <<'INSTALEOF'
#!/bin/bash
set -euxo pipefail
export HOME=/root
export GOPATH=/root/go
export GOMODCACHE=/root/go/pkg/mod
export GOCACHE=/root/.cache/go-build
export PATH=$PATH:/usr/local/go/bin

GO_VERSION="1.23.1"
SLURM_EXPORTER_VERSION="1.8.0"

apt-get install -y git -qq 2>/dev/null || true
mkdir -p "${GOPATH}" "${GOCACHE}"

# Always remove old Go and reinstall to avoid version mismatch
rm -rf /usr/local/go
if true; then
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -xz -C /usr/local
fi

rm -rf /tmp/pse
git clone --depth 1 --branch "v${SLURM_EXPORTER_VERSION}" \
  https://github.com/rivosinc/prometheus-slurm-exporter.git /tmp/pse
cd /tmp/pse
go build -o /usr/local/bin/slurm_exporter .
chmod +x /usr/local/bin/slurm_exporter

useradd -rs /bin/false slurm_exporter 2>/dev/null || true
echo "slurm_exporter ALL=(ALL) NOPASSWD: /opt/slurm/bin/sinfo, /opt/slurm/bin/squeue, /opt/slurm/bin/sacct, /opt/slurm/bin/scontrol" \
  > /etc/sudoers.d/slurm_exporter

cat > /etc/systemd/system/slurm_exporter.service <<EOF
[Unit]
Description=Prometheus Slurm exporter (rivosinc v${SLURM_EXPORTER_VERSION})
After=network.target slurmctld.service

[Service]
User=slurm_exporter
Environment=PATH=/opt/slurm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/bin/slurm_exporter --web.listen-address=:8080 --slurm.cli-fallback
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now slurm_exporter
echo "slurm_exporter installed and running on :8080"
INSTALEOF
fi
chmod +x /usr/local/bin/install-slurm-exporter.sh

cat > /etc/systemd/system/install-slurm-exporter.service <<EOF
[Unit]
Description=Install slurm_exporter post-boot (go build ~10min)
After=network-online.target parallelcluster-start.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/install-slurm-exporter.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable install-slurm-exporter.service
# Start in background — do NOT block here
systemctl start install-slurm-exporter.service &
echo "slurm_exporter build queued (runs in background, ~10min)"

# Tag instance for Prometheus EC2 SD
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
${AWS_CLI} ec2 create-tags --region "${REGION}" --resources "${INSTANCE_ID}" \
  --tags Key=parallelcluster:node-type,Value=HeadNode \
         Key=slurm:hostname,Value=headnode 2>/dev/null || true

echo "=== HeadNode monitoring setup complete ==="
echo "  node_exporter : :9100"
echo "  slurm_exporter: :8080 (installing in background, ~10min)"
