#!/bin/bash
# ==============================================================================
# DCGM Metrics to CloudWatch Exporter
# ==============================================================================
# Purpose: Send DCGM GPU metrics directly to CloudWatch
# Installation: Run on HeadNode (collects from all Compute Nodes)
# ==============================================================================

set -e

CLUSTER_NAME="${1:-my-cluster}"
AWS_REGION="${2:-us-east-1}"

echo "=================================================="
echo "Installing DCGM to CloudWatch Exporter"
echo "=================================================="
echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"
echo ""

# Install Python dependencies
echo "[1/4] Installing Python dependencies..."
apt-get update -qq
apt-get install -y python3-pip python3-venv

# Create virtual environment
python3 -m venv /opt/dcgm-cloudwatch-exporter
source /opt/dcgm-cloudwatch-exporter/bin/activate

# Install required packages
pip install boto3 requests prometheus-client

# Create exporter script
echo "[2/4] Creating DCGM to CloudWatch exporter script..."
cat > /opt/dcgm-cloudwatch-exporter/exporter.py <<'PYTHON_EOF'
#!/usr/bin/env python3
"""
DCGM to CloudWatch Exporter
Scrapes DCGM metrics from Prometheus and sends to CloudWatch
"""

import boto3
import requests
import time
import os
import sys
from datetime import datetime

# Configuration
PROMETHEUS_URL = os.environ.get('PROMETHEUS_URL', 'http://localhost:9090')
CLUSTER_NAME = os.environ.get('CLUSTER_NAME', 'my-cluster')
AWS_REGION = os.environ.get('AWS_REGION', 'us-east-1')
SCRAPE_INTERVAL = int(os.environ.get('SCRAPE_INTERVAL', '60'))

# CloudWatch client
cloudwatch = boto3.client('cloudwatch', region_name=AWS_REGION)

# DCGM metrics mapping
DCGM_METRICS = {
    'DCGM_FI_DEV_GPU_UTIL': {
        'name': 'GPUUtilization',
        'unit': 'Percent'
    },
    'DCGM_FI_DEV_MEM_COPY_UTIL': {
        'name': 'GPUMemoryUtilization',
        'unit': 'Percent'
    },
    'DCGM_FI_DEV_GPU_TEMP': {
        'name': 'GPUTemperature',
        'unit': 'None'
    },
    'DCGM_FI_DEV_POWER_USAGE': {
        'name': 'GPUPowerUsage',
        'unit': 'None'
    },
    'DCGM_FI_DEV_FB_USED': {
        'name': 'GPUMemoryUsed',
        'unit': 'Megabytes'
    },
    'DCGM_FI_DEV_FB_FREE': {
        'name': 'GPUMemoryFree',
        'unit': 'Megabytes'
    }
}

def query_prometheus(metric_name):
    """Query Prometheus for a specific metric"""
    try:
        response = requests.get(
            f'{PROMETHEUS_URL}/api/v1/query',
            params={'query': metric_name},
            timeout=10
        )
        response.raise_for_status()
        return response.json()
    except Exception as e:
        print(f"Error querying Prometheus for {metric_name}: {e}")
        return None

def send_to_cloudwatch(metric_data):
    """Send metrics to CloudWatch"""
    if not metric_data:
        return
    
    try:
        cloudwatch.put_metric_data(
            Namespace=f'ParallelCluster/{CLUSTER_NAME}/GPU',
            MetricData=metric_data
        )
        print(f" Sent {len(metric_data)} metrics to CloudWatch")
    except Exception as e:
        print(f"Error sending to CloudWatch: {e}")

def main():
    print(f"Starting DCGM to CloudWatch exporter")
    print(f"Cluster: {CLUSTER_NAME}")
    print(f"Region: {AWS_REGION}")
    print(f"Prometheus: {PROMETHEUS_URL}")
    print(f"Scrape interval: {SCRAPE_INTERVAL}s")
    print("")
    
    while True:
        try:
            metric_data = []
            timestamp = datetime.utcnow()
            
            for dcgm_metric, config in DCGM_METRICS.items():
                result = query_prometheus(dcgm_metric)
                
                if not result or result.get('status') != 'success':
                    continue
                
                for item in result.get('data', {}).get('result', []):
                    value = float(item['value'][1])
                    labels = item.get('metric', {})
                    
                    # Extract dimensions
                    dimensions = []
                    if 'instance_id' in labels:
                        dimensions.append({
                            'Name': 'InstanceId',
                            'Value': labels['instance_id']
                        })
                    if 'gpu' in labels:
                        dimensions.append({
                            'Name': 'GPU',
                            'Value': labels['gpu']
                        })
                    
                    metric_data.append({
                        'MetricName': config['name'],
                        'Value': value,
                        'Unit': config['unit'],
                        'Timestamp': timestamp,
                        'Dimensions': dimensions
                    })
            
            # Send to CloudWatch (max 20 metrics per call)
            for i in range(0, len(metric_data), 20):
                send_to_cloudwatch(metric_data[i:i+20])
            
            print(f"Collected {len(metric_data)} metrics at {timestamp}")
            
        except Exception as e:
            print(f"Error in main loop: {e}")
        
        time.sleep(SCRAPE_INTERVAL)

if __name__ == '__main__':
    main()
PYTHON_EOF

chmod +x /opt/dcgm-cloudwatch-exporter/exporter.py

# Create systemd service
echo "[3/4] Creating systemd service..."
cat > /etc/systemd/system/dcgm-cloudwatch-exporter.service <<EOF
[Unit]
Description=DCGM to CloudWatch Exporter
After=network.target prometheus.service
Requires=prometheus.service

[Service]
Type=simple
User=root
Environment="PROMETHEUS_URL=http://localhost:9090"
Environment="CLUSTER_NAME=${CLUSTER_NAME}"
Environment="AWS_REGION=${AWS_REGION}"
Environment="SCRAPE_INTERVAL=60"
ExecStart=/opt/dcgm-cloudwatch-exporter/bin/python3 /opt/dcgm-cloudwatch-exporter/exporter.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Start service
echo "[4/4] Starting DCGM CloudWatch Exporter..."
systemctl daemon-reload
systemctl enable dcgm-cloudwatch-exporter
systemctl start dcgm-cloudwatch-exporter

echo ""
echo " DCGM to CloudWatch Exporter installed"
echo "  - Service: dcgm-cloudwatch-exporter"
echo "  - Logs: journalctl -u dcgm-cloudwatch-exporter -f"
echo "  - Namespace: ParallelCluster/${CLUSTER_NAME}/GPU"
echo ""
echo "Exported metrics:"
echo "  - GPUUtilization (Percent)"
echo "  - GPUMemoryUtilization (Percent)"
echo "  - GPUTemperature"
echo "  - GPUPowerUsage"
echo "  - GPUMemoryUsed (MB)"
echo "  - GPUMemoryFree (MB)"
echo ""
echo "View in CloudWatch:"
echo "  aws cloudwatch list-metrics --namespace 'ParallelCluster/${CLUSTER_NAME}/GPU' --region ${AWS_REGION}"
