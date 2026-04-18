#!/bin/bash
# ==============================================================================
# Install Slurm Metrics Collector on HeadNode
# ==============================================================================

set -e

CLUSTER_NAME=$1
AWS_REGION=$2
S3_BUCKET=$3

echo "=================================================="
echo "Installing Slurm Metrics Collector"
echo "=================================================="

# Download collector script
aws s3 cp s3://${S3_BUCKET}/config/cloudwatch/slurm-metrics-collector.sh /usr/local/bin/slurm-metrics-collector.sh --region ${AWS_REGION}
chmod +x /usr/local/bin/slurm-metrics-collector.sh

# Create cron job (run every minute)
cat > /etc/cron.d/slurm-metrics << EOF
# Slurm metrics collection for CloudWatch
* * * * * root /usr/local/bin/slurm-metrics-collector.sh ${CLUSTER_NAME} ${AWS_REGION} >> /var/log/slurm-metrics.log 2>&1
EOF

chmod 644 /etc/cron.d/slurm-metrics

echo " Slurm metrics collector installed"
echo "  - Script: /usr/local/bin/slurm-metrics-collector.sh"
echo "  - Cron: /etc/cron.d/slurm-metrics (runs every minute)"
echo "  - Logs: /var/log/slurm-metrics.log"
