#!/bin/bash
set -euo pipefail
IMAGE="nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-ubuntu22.04"

systemctl stop dcgm-exporter 2>/dev/null || true
docker rm -f dcgm-exporter 2>/dev/null || true

cat > /etc/systemd/system/dcgm-exporter.service <<EOF
[Unit]
Description=NVIDIA DCGM Exporter
After=docker.service
Requires=docker.service

[Service]
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f dcgm-exporter
ExecStart=/usr/bin/docker run --rm --name dcgm-exporter \
  --privileged --pid=host \
  -v /usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu \
  -v /dev:/dev \
  -e DCGM_EXPORTER_LISTEN=:9400 \
  -e DCGM_EXPORTER_KUBERNETES=false \
  -p 9400:9400 \
  ${IMAGE}
ExecStop=/usr/bin/docker stop dcgm-exporter

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start dcgm-exporter
sleep 10
docker logs dcgm-exporter 2>&1 | grep -E "GPU|NVML|Initializ|Error|metric" | head -15
echo "---metrics---"
curl -s http://localhost:9400/metrics | head -10
