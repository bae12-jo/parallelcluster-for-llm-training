#!/bin/bash
# ==============================================================================
# Prometheus to CloudWatch Exporter Setup
# ==============================================================================
# Purpose: Export Prometheus metrics (DCGM, Node Exporter) to CloudWatch
# Installation: Run on HeadNode
# ==============================================================================

set -e

CLUSTER_NAME="${1:-my-cluster}"
AWS_REGION="${2:-us-east-1}"

echo "=================================================="
echo "Installing Prometheus CloudWatch Exporter"
echo "=================================================="
echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"
echo ""

# Install CloudWatch Exporter
echo "[1/4] Downloading CloudWatch Exporter..."
EXPORTER_VERSION="0.15.5"
wget -q https://github.com/prometheus/cloudwatch_exporter/releases/download/v${EXPORTER_VERSION}/cloudwatch_exporter-${EXPORTER_VERSION}.linux-amd64.tar.gz
tar xzf cloudwatch_exporter-${EXPORTER_VERSION}.linux-amd64.tar.gz
mv cloudwatch_exporter-${EXPORTER_VERSION}.linux-amd64/cloudwatch_exporter /usr/local/bin/
rm -rf cloudwatch_exporter-${EXPORTER_VERSION}.linux-amd64*

# Create configuration
echo "[2/4] Creating CloudWatch Exporter configuration..."
cat > /etc/prometheus-cloudwatch-exporter.yml <<EOF
# Prometheus to CloudWatch Exporter Configuration
region: ${AWS_REGION}
metrics:
  # GPU Utilization
  - aws_namespace: ParallelCluster/${CLUSTER_NAME}/GPU
    aws_metric_name: GPUUtilization
    aws_dimensions: [instance_id]
    aws_statistics: [Average]
    
  # GPU Memory Utilization
  - aws_namespace: ParallelCluster/${CLUSTER_NAME}/GPU
    aws_metric_name: GPUMemoryUtilization
    aws_dimensions: [instance_id]
    aws_statistics: [Average]
    
  # GPU Temperature
  - aws_namespace: ParallelCluster/${CLUSTER_NAME}/GPU
    aws_metric_name: GPUTemperature
    aws_dimensions: [instance_id]
    aws_statistics: [Average, Maximum]
    
  # GPU Power Usage
  - aws_namespace: ParallelCluster/${CLUSTER_NAME}/GPU
    aws_metric_name: GPUPowerUsage
    aws_dimensions: [instance_id]
    aws_statistics: [Average]
EOF

# Create systemd service
echo "[3/4] Creating systemd service..."
cat > /etc/systemd/system/prometheus-cloudwatch-exporter.service <<EOF
[Unit]
Description=Prometheus CloudWatch Exporter
After=network.target prometheus.service
Requires=prometheus.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudwatch_exporter -config.file=/etc/prometheus-cloudwatch-exporter.yml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Start service
echo "[4/4] Starting CloudWatch Exporter..."
systemctl daemon-reload
systemctl enable prometheus-cloudwatch-exporter
systemctl start prometheus-cloudwatch-exporter

echo ""
echo " Prometheus CloudWatch Exporter installed"
echo "  - Port: 9106 (metrics endpoint)"
echo "  - Config: /etc/prometheus-cloudwatch-exporter.yml"
echo "  - Service: prometheus-cloudwatch-exporter"
echo ""
echo "Note: This exports FROM CloudWatch TO Prometheus"
echo "      For DCGM → CloudWatch, use the script below instead"
