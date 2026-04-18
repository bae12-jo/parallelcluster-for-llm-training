#!/bin/bash
# Create CloudWatch Dashboard for EFA Network Monitoring

set -e

CLUSTER_NAME="${1}"
REGION="${2:-us-east-2}"

if [ -z "${CLUSTER_NAME}" ]; then
    echo "Usage: $0 <cluster-name> [region]"
    echo "Example: $0 my-cluster us-east-2"
    exit 1
fi

DASHBOARD_NAME="ParallelCluster-${CLUSTER_NAME}-EFA"

echo "Creating EFA Network Monitoring Dashboard..."
echo "  Cluster: ${CLUSTER_NAME}"
echo "  Region: ${REGION}"
echo "  Dashboard: ${DASHBOARD_NAME}"

# Create dashboard JSON
cat > /tmp/efa-dashboard.json <<EOF
{
  "widgets": [
    {
      "type": "text",
      "x": 0,
      "y": 0,
      "width": 24,
      "height": 1,
      "properties": {
        "markdown": "##  EFA Network Performance - ${CLUSTER_NAME}\n\nReal-time monitoring of Elastic Fabric Adapter (EFA) network performance for inter-node communication."
      }
    },
    {
      "type": "metric",
      "x": 0,
      "y": 1,
      "width": 12,
      "height": 6,
      "properties": {
        "metrics": [
          ["ParallelCluster/Network", "rx_bytes_rate", {"stat": "Average", "label": "RX Throughput"}],
          [".", "tx_bytes_rate", {"stat": "Average", "label": "TX Throughput"}]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "${REGION}",
        "title": "EFA Network Throughput",
        "period": 60,
        "yAxis": {
          "left": {
            "label": "Bytes/Second",
            "showUnits": false
          }
        },
        "annotations": {
          "horizontal": [
            {
              "label": "100 Gbps",
              "value": 12500000000
            }
          ]
        }
      }
    },
    {
      "type": "metric",
      "x": 12,
      "y": 1,
      "width": 12,
      "height": 6,
      "properties": {
        "metrics": [
          ["ParallelCluster/Network", "rx_bytes_rate", {"stat": "Average", "id": "m1"}]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "${REGION}",
        "title": "EFA Bandwidth Utilization (Gbps)",
        "period": 60,
        "yAxis": {
          "left": {
            "label": "Gbps"
          }
        },
        "stat": "Average",
        "legend": {
          "position": "bottom"
        },
        "annotations": {
          "horizontal": [
            {
              "label": "EFA Max (3200 Gbps for p5en)",
              "value": 400000000000
            }
          ]
        }
      }
    },
    {
      "type": "metric",
      "x": 0,
      "y": 7,
      "width": 12,
      "height": 6,
      "properties": {
        "metrics": [
          ["ParallelCluster/Network", "rx_packets_rate", {"stat": "Average", "label": "RX Packets"}],
          [".", "tx_packets_rate", {"stat": "Average", "label": "TX Packets"}]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "${REGION}",
        "title": "EFA Packet Rate",
        "period": 60,
        "yAxis": {
          "left": {
            "label": "Packets/Second"
          }
        }
      }
    },
    {
      "type": "metric",
      "x": 12,
      "y": 7,
      "width": 12,
      "height": 6,
      "properties": {
        "metrics": [
          ["ParallelCluster/Network", "rx_errors", {"stat": "Sum", "label": "RX Errors"}],
          [".", "tx_discards", {"stat": "Sum", "label": "TX Discards"}]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "${REGION}",
        "title": "EFA Errors & Discards",
        "period": 300,
        "yAxis": {
          "left": {
            "label": "Count",
            "min": 0
          }
        }
      }
    },
    {
      "type": "metric",
      "x": 0,
      "y": 13,
      "width": 6,
      "height": 3,
      "properties": {
        "metrics": [
          ["ParallelCluster/Network", "rx_bytes_rate", {"stat": "Average"}]
        ],
        "view": "singleValue",
        "region": "${REGION}",
        "title": "Current RX Rate",
        "period": 60
      }
    },
    {
      "type": "metric",
      "x": 6,
      "y": 13,
      "width": 6,
      "height": 3,
      "properties": {
        "metrics": [
          ["ParallelCluster/Network", "tx_bytes_rate", {"stat": "Average"}]
        ],
        "view": "singleValue",
        "region": "${REGION}",
        "title": "Current TX Rate",
        "period": 60
      }
    },
    {
      "type": "metric",
      "x": 12,
      "y": 13,
      "width": 6,
      "height": 3,
      "properties": {
        "metrics": [
          ["ParallelCluster/Network", "rx_errors", {"stat": "Sum"}]
        ],
        "view": "singleValue",
        "region": "${REGION}",
        "title": "Total RX Errors",
        "period": 300
      }
    },
    {
      "type": "metric",
      "x": 18,
      "y": 13,
      "width": 6,
      "height": 3,
      "properties": {
        "metrics": [
          ["ParallelCluster/Network", "tx_discards", {"stat": "Sum"}]
        ],
        "view": "singleValue",
        "region": "${REGION}",
        "title": "Total TX Discards",
        "period": 300
      }
    },
    {
      "type": "text",
      "x": 0,
      "y": 16,
      "width": 24,
      "height": 2,
      "properties": {
        "markdown": "###  Metrics Guide\n\n- **Throughput**: Actual data transfer rate (should approach EFA max during training)\n- **Packet Rate**: Number of packets per second (higher for small messages)\n- **Errors/Discards**: Should be zero under normal operation\n- **EFA Max**: p5en.48xlarge = 3200 Gbps (400 GB/s), p4d.24xlarge = 400 Gbps (50 GB/s)"
      }
    }
  ]
}
EOF

# Create dashboard
aws cloudwatch put-dashboard \
    --dashboard-name "${DASHBOARD_NAME}" \
    --dashboard-body file:///tmp/efa-dashboard.json \
    --region "${REGION}"

if [ $? -eq 0 ]; then
    echo ""
    echo " Dashboard created successfully!"
    echo ""
    echo "View dashboard:"
    echo "  https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD_NAME}"
    echo ""
    echo "Metrics namespace: ParallelCluster/Network"
    echo ""
else
    echo "️  Failed to create dashboard"
    exit 1
fi

# Cleanup
rm -f /tmp/efa-dashboard.json
