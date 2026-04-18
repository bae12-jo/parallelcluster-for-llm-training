#!/bin/bash
# Login Node Setup Script
# Minimal installation: CloudWatch Agent + basic dev tools only

# Don't exit on error - continue even if individual components fail
set +e

CLUSTER_NAME="${1:-my-cluster}"
REGION="${2:-us-east-1}"
S3_BUCKET="${3}"
MONITORING_TYPE="${4:-unknown}"  # Monitoring type (for informational purposes)

echo "=== Login Node Setup Started ==="
echo "Cluster Name: ${CLUSTER_NAME}"
echo "Region: ${REGION}"
echo "Monitoring Type: ${MONITORING_TYPE}"

# Install basic dev tools
(
    set +e  # Don't exit on error
    echo "Installing basic dev tools..."
    apt-get update
    apt-get install -y vim git htop curl wget
    echo " Basic dev tools installed"
) || echo "️  Basic dev tools installation failed (non-critical)"

# Install CloudWatch Agent
(
    set +e  # Don't exit on error
    echo "Installing CloudWatch Agent..."
    wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
    dpkg -i amazon-cloudwatch-agent.deb
    rm -f amazon-cloudwatch-agent.deb

    # Configure CloudWatch Agent
    if [ -n "${S3_BUCKET}" ]; then
    echo "Downloading CloudWatch Agent config..."
    if aws s3 cp "s3://${S3_BUCKET}/config/cloudwatch/cloudwatch-agent-config.json" /tmp/cloudwatch-agent-config.json 2>/dev/null; then
        sed -i "s/{cluster_name}/${CLUSTER_NAME}/g" /tmp/cloudwatch-agent-config.json
        
        # Start CloudWatch Agent
        /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
            -a fetch-config \
            -m ec2 \
            -s \
            -c file:/tmp/cloudwatch-agent-config.json
        
        echo " CloudWatch Agent configured with custom config"
    else
        echo "️  Warning: CloudWatch Agent config not found in S3"
        echo "   Expected: s3://${S3_BUCKET}/config/cloudwatch/cloudwatch-agent-config.json"
        echo ""
        echo "   What's installed:"
        echo "    CloudWatch Agent binary"
        echo "    Basic dev tools (vim, git, htop)"
        echo ""
        echo "   What's NOT configured:"
        echo "    CloudWatch custom metrics"
        echo ""
        echo "   Impact:"
        echo "   - ParallelCluster default logs still work"
        echo "   - Custom metrics won't be collected (optional for LoginNode)"
        echo ""
        echo "   To fix later (optional):"
        echo "   1. Upload config: aws s3 cp config/cloudwatch/cloudwatch-agent-config.json s3://${S3_BUCKET}/config/cloudwatch/"
        echo "   2. On LoginNode: sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/path/to/config.json"
    fi
    else
        echo "️  Warning: S3_BUCKET not provided"
        echo "   CloudWatch Agent installed but not configured"
    fi
) || echo "️  CloudWatch Agent installation/configuration failed (non-critical)"

echo ""
echo " Login Node Setup Complete"
echo "Installed components:"
echo "  - CloudWatch Agent"
echo "  - Basic dev tools (vim, git, htop)"
if [ -n "${MONITORING_TYPE}" ]; then
    echo "  - Monitoring: ${MONITORING_TYPE}"
fi
