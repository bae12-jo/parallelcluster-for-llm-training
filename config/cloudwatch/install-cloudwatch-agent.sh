#!/bin/bash
# ==============================================================================
# CloudWatch Agent Installation Script
# ==============================================================================
# Purpose: Install and configure CloudWatch Agent on ParallelCluster nodes
# Usage: Called by setup scripts (setup-headnode.sh, setup-compute-node.sh)
# ==============================================================================

set -e

CLUSTER_NAME=$1
AWS_REGION=$2
S3_BUCKET=$3

echo "=================================================="
echo "Installing CloudWatch Agent"
echo "=================================================="
echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"
echo "S3 Bucket: ${S3_BUCKET}"
echo ""

# Download CloudWatch Agent
echo "[1/4] Downloading CloudWatch Agent..."
wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -O /tmp/amazon-cloudwatch-agent.deb

# Install CloudWatch Agent
echo "[2/4] Installing CloudWatch Agent..."
dpkg -i -E /tmp/amazon-cloudwatch-agent.deb
rm -f /tmp/amazon-cloudwatch-agent.deb

# Download configuration from S3
echo "[3/4] Downloading CloudWatch Agent configuration..."
aws s3 cp s3://${S3_BUCKET}/config/cloudwatch/cloudwatch-agent-config.json /opt/aws/amazon-cloudwatch-agent/etc/config.json --region ${AWS_REGION}

# Replace CLUSTER_NAME placeholder in config
sed -i "s/\${CLUSTER_NAME}/${CLUSTER_NAME}/g" /opt/aws/amazon-cloudwatch-agent/etc/config.json

# Start CloudWatch Agent
echo "[4/4] Starting CloudWatch Agent..."
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json

# Verify agent is running
sleep 5
if systemctl is-active --quiet amazon-cloudwatch-agent; then
    echo " CloudWatch Agent installed and running"
else
    echo " CloudWatch Agent failed to start"
    systemctl status amazon-cloudwatch-agent
    exit 1
fi

echo ""
echo "CloudWatch Agent installation complete"
echo "Logs: /opt/aws/amazon-cloudwatch-agent/logs/"
echo "Config: /opt/aws/amazon-cloudwatch-agent/etc/config.json"
