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
  --collector.textfile.directory=/var/lib/node_exporter/textfile \
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

# ---- Docker + nvidia-container-toolkit (for NeMo/mbridge on HeadNode) ----
if ! command -v docker &>/dev/null; then
  echo "Installing Docker + nvidia-container-toolkit on HeadNode..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --no-tty --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  ARCH=$(dpkg --print-architecture)
  CODENAME=$(lsb_release -cs 2>/dev/null || echo jammy)
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
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
  echo "Docker installed on HeadNode"
fi


# ---- ubuntu cross-node SSH (required for mpirun across nodes) ----
# mpirun uses ubuntu user SSH — root SSH is blocked by pcluster
# Strategy: generate key on headnode, publish pub key to FSx
#           compute nodes (OnNodeConfigured) pick it up via /fsx/cluster/ubuntu-headnode.pub
if [ ! -f /home/ubuntu/.ssh/id_ed25519 ]; then
  echo "Setting up ubuntu user SSH key for cross-node MPI..."
  mkdir -p /home/ubuntu/.ssh
  ssh-keygen -t ed25519 -N "" -f /home/ubuntu/.ssh/id_ed25519 -q
  cat /home/ubuntu/.ssh/id_ed25519.pub >> /home/ubuntu/.ssh/authorized_keys
  chmod 700 /home/ubuntu/.ssh
  chmod 600 /home/ubuntu/.ssh/authorized_keys /home/ubuntu/.ssh/id_ed25519
  chown -R ubuntu:ubuntu /home/ubuntu/.ssh
  su - ubuntu -c "ssh-keyscan -H localhost >> ~/.ssh/known_hosts 2>/dev/null" || true
  echo "ubuntu SSH key created"
fi
# Publish pub key to FSx so compute nodes can pick it up in OnNodeConfigured
if mountpoint -q /fsx 2>/dev/null; then
  mkdir -p /fsx/cluster
  cp /home/ubuntu/.ssh/id_ed25519.pub /fsx/cluster/ubuntu-headnode.pub
  # Pre-scan compute node hostnames into known_hosts (avoids interactive prompt during mpirun)
  for h in $(seq 1 8); do
    su - ubuntu -c "ssh-keyscan -H p6b200-st-p6b200-nodes-${h} >> ~/.ssh/known_hosts 2>/dev/null" || true
  done
  echo "ubuntu pub key published to /fsx/cluster/ubuntu-headnode.pub"
fi

# ---- enroot + Pyxis: container runtime for srun --container-image ----
# Required for NCCL tests and NeMo benchmarks via Slurm
# enroot: unprivileged container runtime (NVIDIA)
# Pyxis: Slurm SPANK plugin that adds --container-image/--container-mounts to srun
ENROOT_VERSION="3.4.1"
PYXIS_VERSION="0.20.0"
SLURM_VERSION=$(sinfo --version 2>/dev/null | awk '{print $2}' || echo "")

if ! command -v enroot &>/dev/null; then
  echo "Installing enroot ${ENROOT_VERSION}..."
  # Install dependencies
  apt-get install -y curl gawk squashfs-tools parallel libcap2-bin 2>/dev/null || true

  ARCH=$(dpkg --print-architecture)
  ENROOT_DEB="enroot_${ENROOT_VERSION}+1_${ARCH}.deb"
  ENROOT_DEB_CAPS="enroot+caps_${ENROOT_VERSION}+1_${ARCH}.deb"

  curl -fsSL "https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VERSION}/${ENROOT_DEB}" \
    -o "/tmp/${ENROOT_DEB}" 2>/dev/null
  curl -fsSL "https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VERSION}/${ENROOT_DEB_CAPS}" \
    -o "/tmp/${ENROOT_DEB_CAPS}" 2>/dev/null
  apt-get install -y "/tmp/${ENROOT_DEB}" "/tmp/${ENROOT_DEB_CAPS}" 2>&1 | tail -3 || true
  rm -f "/tmp/${ENROOT_DEB}" "/tmp/${ENROOT_DEB_CAPS}"

  # enroot config: use /fsx for scratch (large image imports)
  mkdir -p /etc/enroot
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

  mkdir -p /fsx/enroot/cache /fsx/enroot/data
  echo "enroot installed: $(enroot version 2>/dev/null || echo 'check version manually')"
else
  echo "enroot already installed: $(enroot version 2>/dev/null)"
fi

if ! ls /usr/local/lib/slurm/spank_pyxis.so &>/dev/null; then
  echo "Installing Pyxis ${PYXIS_VERSION}..."
  apt-get install -y build-essential libslurm-dev 2>/dev/null || true

  # Find Slurm include path
  SLURM_INCLUDE=$(find /opt/slurm /usr -name "slurm.h" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo /usr/include/slurm)

  cd /tmp
  rm -rf pyxis-src
  git clone --depth=1 --branch "v${PYXIS_VERSION}" \
    https://github.com/NVIDIA/pyxis.git pyxis-src 2>&1 | tail -3
  cd pyxis-src

  # Build against pcluster Slurm
  SLURM_PREFIX=$(dirname "$(dirname "$(command -v sinfo 2>/dev/null || echo /opt/slurm/bin/sinfo)")")
  make SLURM_PREFIX="${SLURM_PREFIX}" 2>&1 | tail -5
  make install SLURM_PREFIX="${SLURM_PREFIX}" 2>&1 | tail -3
  cd / && rm -rf /tmp/pyxis-src

  # Register Pyxis SPANK plugin
  PLUGSTACK_CONF="${SLURM_PREFIX}/etc/plugstack.conf"
  if ! grep -q pyxis "${PLUGSTACK_CONF}" 2>/dev/null; then
    echo "include /etc/slurm/plugstack.conf.d/*.conf" >> "${PLUGSTACK_CONF}" 2>/dev/null || true
    mkdir -p /etc/slurm/plugstack.conf.d
    echo "required ${SLURM_PREFIX}/lib/slurm/spank_pyxis.so" \
      > /etc/slurm/plugstack.conf.d/pyxis.conf
  fi

  # Restart slurmctld to load Pyxis
  systemctl restart slurmctld 2>/dev/null || true
  echo "Pyxis installed: spank_pyxis.so"
else
  echo "Pyxis already installed"
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
export PATH=/usr/local/go/bin:$PATH

GO_VERSION="1.23.1"
SLURM_EXPORTER_VERSION="1.8.0"

apt-get install -y git -qq 2>/dev/null || true
mkdir -p "${GOPATH}" "${GOCACHE}"

# Always remove old Go (including system-installed) to avoid PATH conflicts
rm -rf /usr/local/go /usr/lib/go-* /usr/bin/go /usr/bin/gofmt 2>/dev/null || true
curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -xz -C /usr/local
hash -r

rm -rf /tmp/pse
git clone --depth 1 --branch "v${SLURM_EXPORTER_VERSION}" \
  https://github.com/rivosinc/prometheus-slurm-exporter.git /tmp/pse
cd /tmp/pse
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
TOKEN=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token 2>/dev/null || echo "")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/placement/region)
${AWS_CLI} ec2 create-tags --region "${REGION}" --resources "${INSTANCE_ID}" \
  --tags Key=parallelcluster:node-type,Value=HeadNode \
         Key=slurm:hostname,Value=headnode 2>/dev/null || true

# ---- Slurm TaskProlog — inject HPC env into every sbatch/srun job ----
# slurmctld reads slurm.conf; TaskProlog runs on the compute node inside the job env.
# The prolog file itself is deployed by setup-compute-node.sh — we just register the path here.
SLURM_CONF=/opt/slurm/etc/slurm.conf
if [ -f "${SLURM_CONF}" ] && ! grep -q "^TaskProlog" "${SLURM_CONF}"; then
  echo "TaskProlog=/opt/slurm/etc/task_prolog.sh" >> "${SLURM_CONF}"
  systemctl reload slurmctld 2>/dev/null || systemctl restart slurmctld 2>/dev/null || true
  echo "TaskProlog registered in slurm.conf"
fi

# ---- Compute node hostname tagger (cron backup) ----
# Compute nodes tag themselves at boot, but Slurm hostname may not be assigned in time.
# This cron runs every 5 minutes from HeadNode and tags any compute node missing slurm:hostname.
AWS_CLI_PATH=$(command -v aws || echo /usr/local/bin/aws)
cat > /usr/local/bin/tag-compute-nodes.sh << TAGSCRIPT
#!/bin/bash
# Tag compute nodes with slurm:hostname if not already tagged
# Runs from HeadNode where slurmctld knows all node hostnames
AWS_CLI=\$(command -v aws || echo /usr/local/bin/aws)
REGION=\$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
CLUSTER_NAME=\$(cat /etc/parallelcluster/cfnconfig 2>/dev/null | grep "^stack_name" | cut -d= -f2 | tr -d ' ' || echo "")

# Get all running compute instances in this cluster without slurm:hostname tag
INSTANCES=\$(\${AWS_CLI} ec2 describe-instances --region "\${REGION}" \
  --filters "Name=tag:parallelcluster:node-type,Values=Compute" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[?!Tags[?Key==\`slurm:hostname\`]].[InstanceId,PrivateIpAddress]' \
  --output text 2>/dev/null)

[ -z "\${INSTANCES}" ] && exit 0

# Match instance private IP to Slurm nodelist
while IFS=$'\t' read -r INSTANCE_ID PRIVATE_IP; do
  [ -z "\${INSTANCE_ID}" ] && continue
  # Find Slurm hostname by private IP via sinfo
  SLURM_HOST=\$(sinfo -h -o "%N %o" 2>/dev/null | awk -v ip="\${PRIVATE_IP}" '\$2==ip {print \$1}' | head -1)
  if [ -n "\${SLURM_HOST}" ]; then
    \${AWS_CLI} ec2 create-tags --region "\${REGION}" --resources "\${INSTANCE_ID}" \
      --tags "Key=slurm:hostname,Value=\${SLURM_HOST}" "Key=Name,Value=\${SLURM_HOST}" 2>/dev/null && \
      echo "Tagged \${INSTANCE_ID} (\${PRIVATE_IP}) -> \${SLURM_HOST}"
  fi
done <<< "\${INSTANCES}"
TAGSCRIPT
chmod +x /usr/local/bin/tag-compute-nodes.sh

# Register cron: run every 1 minute (faster hostname tag visibility)
cat > /etc/cron.d/tag-compute-nodes << 'CRONEOF'
* * * * * root /usr/local/bin/tag-compute-nodes.sh >> /var/log/tag-compute-nodes.log 2>&1
CRONEOF

# ---- Slurm node state + down reason collector ----
# Exposes node state and drain/down reason as Prometheus textfile metrics.
# Enables time-series tracking of why nodes went down in Grafana.
# Metric: slurm_node_state_reason{node, state, reason} 1
cat > /usr/local/bin/slurm-node-reason-collector.sh << 'REASONEOF'
#!/bin/bash
OUTFILE="/var/lib/node_exporter/textfile/slurm_node_reasons.prom"
TMPFILE="${OUTFILE}.tmp"
NOW=$(date +%s)
> "${TMPFILE}"
export PATH=/opt/slurm/bin:$PATH

# ── 1. Slurm node state + reason (from sinfo) ────────────────────────────────
while IFS= read -r line; do
  node=$(echo "$line"     | awk '{print $1}')
  state_raw=$(echo "$line"| awk '{print $2}')
  node_addr=$(echo "$line"| awk '{print $3}')
  reason=$(echo "$line"   | cut -d' ' -f4-)
  [ -z "$node" ] && continue
  state=$(echo "$state_raw" | tr -d '~*#$%+!' | tr '[:upper:]' '[:lower:]')
  reason="${reason:-none}"
  # node_addr == node_name when powered down; use empty string in that case
  [ "$node_addr" = "$node" ] && node_addr=""
  printf 'slurm_node_state_reason{node="%s",state="%s",state_raw="%s",node_addr="%s",reason="%s"} %s\n' \
    "$node" "$state" "$state_raw" "$node_addr" "$reason" "$NOW" >> "${TMPFILE}"
done < <(sinfo -h -o '%N %T %o %E' -N 2>/dev/null)

# ── 2. clustermgtd ALL node lifecycle events (ring buffer, last 24h) ─────────
EVENTS_FILE="/var/lib/node_exporter/textfile/clustermgtd_events.prom"
EVENTS_TMP="${EVENTS_FILE}.tmp"
> "${EVENTS_TMP}"

LOGFILE="/var/log/parallelcluster/clustermgtd"
[ -f "$LOGFILE" ] || LOGFILE="/var/log/parallelcluster/clustermgtd.log"

if [ -f "$LOGFILE" ]; then
  CUTOFF=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
           date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

  # Match ALL lines that reference a node name pattern or state change
  grep -E \
    "node.*state|state.*node|terminating|replacing|replaced|unhealthy|bootstrap|capacity|powered|powering|waking|launched|resuming|IDLE|DOWN|DRAIN|maintenance|replacement|resume|suspend|scaling" \
    "$LOGFILE" 2>/dev/null | \
  grep -E "[a-z0-9\-]+st[a-z0-9\-]+nodes-[0-9]+" | \
  while IFS= read -r entry; do
    # Extract timestamp
    ts_str=$(echo "$entry" | grep -oP '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}')
    [ -z "$ts_str" ] && continue
    [ -n "$CUTOFF" ] && [[ "$ts_str" < "$CUTOFF" ]] && continue
    ts_epoch=$(date -d "$ts_str" +%s 2>/dev/null || \
               date -j -f "%Y-%m-%d %H:%M:%S" "$ts_str" +%s 2>/dev/null || echo 0)
    [ "$ts_epoch" -eq 0 ] && continue

    # Extract node name (pcluster static node naming pattern)
    node=$(echo "$entry" | grep -oP "[a-z0-9\-]+st[a-z0-9\-]+nodes-[0-9]+" | head -1)
    [ -z "$node" ] && continue

    # Classify event type (ordered: most specific first)
    event_type="info"
    echo "$entry" | grep -qiE "bootstrap.failure|unhealthy"          && event_type="bootstrap_failure"
    echo "$entry" | grep -qiE "LimitedInstanceCapacity|ReservationCapacityExceeded|capacity" \
                                                                       && event_type="capacity_error"
    echo "$entry" | grep -qiE "terminating|being replaced|terminate"  && event_type="terminated"
    echo "$entry" | grep -qiE "in replacement|currently in replacement" && event_type="replacing"
    echo "$entry" | grep -qiE "Setting.*DOWN|set.*down|state.*DOWN"   && event_type="set_down"
    echo "$entry" | grep -qiE "Setting.*IDLE|set.*idle|state.*IDLE|now responding|powered up" \
                                                                       && event_type="set_idle"
    echo "$entry" | grep -qiE "Setting.*DRAIN|drained|draining"       && event_type="set_drained"
    echo "$entry" | grep -qiE "waking|powering.up|resuming|resume|POWERING_UP" \
                                                                       && event_type="powering_up"
    echo "$entry" | grep -qiE "powered.down|power.down|POWERED_DOWN|suspend" \
                                                                       && event_type="powered_down"
    echo "$entry" | grep -qiE "launched|launch|new instance"          && event_type="launched"
    echo "$entry" | grep -qiE "maintenance|replacing.*maintenance"    && event_type="maintenance"

    # Short reason: strip log prefix, keep 150 chars
    reason=$(echo "$entry" | sed 's/.*\] - //' | sed 's/.*\] //' | \
             cut -c1-150 | tr '"' "'" | tr '\n' ' ' | sed 's/  */ /g')

    printf 'slurm_node_event{node="%s",event_type="%s",reason="%s"} %s\n' \
      "$node" "$event_type" "$reason" "$ts_epoch" >> "${EVENTS_TMP}"
  done

  # Keep only latest entry per node+event_type (sort by timestamp DESC, keep first seen)
  # Value (timestamp) is the last field; sort numerically descending on it
  sort -t' ' -k2,2rn "${EVENTS_TMP}" 2>/dev/null | \
    awk -F'"' '!seen[$2"_"$4]++' > "${EVENTS_FILE}" 2>/dev/null || \
    mv "${EVENTS_TMP}" "${EVENTS_FILE}"
fi

mv "${TMPFILE}" "${OUTFILE}" 2>/dev/null || true
REASONEOF
chmod +x /usr/local/bin/slurm-node-reason-collector.sh

# Run every minute via cron (independent file)
echo '* * * * * root /usr/local/bin/slurm-node-reason-collector.sh' \
  > /etc/cron.d/slurm-node-reason-collector

# Seed initial run (slurm may not be ready yet — ignore errors)
/usr/local/bin/slurm-node-reason-collector.sh || true

echo "=== HeadNode monitoring setup complete ==="
echo "  node_exporter : :9100"
echo "  slurm_exporter: :8080 (installing in background, ~10min)"
echo "  compute tagging: cron every 5min via /usr/local/bin/tag-compute-nodes.sh"
echo "  slurm reason  : cron every 30s via /usr/local/bin/slurm-node-reason-collector.sh"
