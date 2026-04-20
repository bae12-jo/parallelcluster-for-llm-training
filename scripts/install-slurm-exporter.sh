#!/bin/bash
# Post-boot slurm_exporter install on HeadNode
# Verified working: run via SSM or manually after cluster is CREATE_COMPLETE
# go build requires HOME/GOCACHE to be set explicitly (SSM runs without HOME)
set -euxo pipefail

GO_VERSION="1.23.1"
SLURM_EXPORTER_VERSION="1.8.0"

export HOME=/root
export GOPATH=/root/go
export GOMODCACHE=/root/go/pkg/mod
export GOCACHE=/root/.cache/go-build
export PATH=/usr/local/go/bin:$PATH

apt-get install -y git -qq 2>/dev/null || true
mkdir -p "${GOPATH}" "${GOCACHE}"

# Install Go if not present
# Always remove old Go and reinstall to avoid version mismatch
rm -rf /usr/local/go /usr/lib/go-* /usr/bin/go /usr/bin/gofmt 2>/dev/null || true
if true; then
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -xz -C /usr/local
fi

# Build slurm_exporter from source
rm -rf /tmp/pse
git clone --depth 1 --branch "v${SLURM_EXPORTER_VERSION}" \
  https://github.com/rivosinc/prometheus-slurm-exporter.git /tmp/pse
cd /tmp/pse
# Patch go.mod: strip patch version (e.g. 1.23.1 → 1.23) for older Go toolchain compatibility
sed -i 's/^go [0-9]\+\.[0-9]\+\.[0-9]\+/go 1.23/' go.mod
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
systemctl is-active slurm_exporter
echo "slurm_exporter installed and running on :8080"
