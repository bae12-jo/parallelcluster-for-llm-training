#!/bin/bash
# ==============================================================================
# ParallelCluster Advanced Dashboard with Slurm Metrics
# ==============================================================================

set +e  # Don't exit on error (can be called from background)

CLUSTER_NAME="${1:-p5en-48xlarge-cluster}"
AWS_REGION="${2:-us-east-2}"
DASHBOARD_NAME="ParallelCluster-${CLUSTER_NAME}-Advanced"

echo "=================================================="
echo "Creating Advanced ParallelCluster Dashboard"
echo "=================================================="
echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"
echo "Dashboard: ${DASHBOARD_NAME}"
echo ""

cat > /tmp/dashboard-advanced-${CLUSTER_NAME}.json << 'DASHBOARD_EOF'
{
    "widgets": [
        {
            "type": "text",
            "x": 0,
            "y": 0,
            "width": 24,
            "height": 2,
            "properties": {
                "markdown": "# ParallelCluster Advanced: ${CLUSTER_NAME}\n## Slurm 작업 큐 및 노드 상태 실시간 모니터링"
            }
        },
        {
            "type": "metric",
            "x": 0,
            "y": 2,
            "width": 8,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "ParallelCluster/${CLUSTER_NAME}/Slurm", "NodesTotal", { "label": "Total Nodes", "color": "#1f77b4" } ],
                    [ ".", "NodesIdle", { "label": "Idle Nodes", "color": "#2ca02c" } ],
                    [ ".", "NodesAllocated", { "label": "Allocated Nodes", "color": "#ff7f0e" } ],
                    [ ".", "NodesDown", { "label": "Down Nodes", "color": "#d62728" } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "Slurm 노드 상태",
                "period": 60,
                "stat": "Average",
                "yAxis": {
                    "left": {
                        "min": 0
                    }
                }
            }
        },
        {
            "type": "metric",
            "x": 8,
            "y": 2,
            "width": 8,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "ParallelCluster/${CLUSTER_NAME}/Slurm", "JobsRunning", { "label": "Running Jobs", "color": "#2ca02c" } ],
                    [ ".", "JobsPending", { "label": "Pending Jobs", "color": "#ff7f0e" } ],
                    [ ".", "JobsTotal", { "label": "Total Jobs", "color": "#1f77b4" } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "Slurm 작업 큐 상태",
                "period": 60,
                "stat": "Average",
                "yAxis": {
                    "left": {
                        "min": 0
                    }
                }
            }
        },
        {
            "type": "metric",
            "x": 16,
            "y": 2,
            "width": 8,
            "height": 6,
            "properties": {
                "metrics": [
                    [ { "expression": "m1/m2*100", "label": "Node Utilization %", "id": "e1", "color": "#1f77b4" } ],
                    [ "ParallelCluster/${CLUSTER_NAME}/Slurm", "NodesAllocated", { "id": "m1", "visible": false } ],
                    [ ".", "NodesTotal", { "id": "m2", "visible": false } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "노드 활용률",
                "period": 60,
                "stat": "Average",
                "yAxis": {
                    "left": {
                        "min": 0,
                        "max": 100
                    }
                }
            }
        },
        {
            "type": "metric",
            "x": 0,
            "y": 8,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/EC2", "CPUUtilization", { "stat": "Average" } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "전체 노드 CPU 사용률",
                "period": 300
            }
        },
        {
            "type": "metric",
            "x": 12,
            "y": 8,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "ParallelCluster/${CLUSTER_NAME}", "MEM_USED", { "stat": "Average" } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "전체 노드 메모리 사용률",
                "period": 300
            }
        },
        {
            "type": "log",
            "x": 0,
            "y": 14,
            "width": 24,
            "height": 6,
            "properties": {
                "query": "SOURCE '/aws/parallelcluster/${CLUSTER_NAME}/slurm'\n| fields @timestamp, @message\n| filter @message like /JobId|COMPLETED|FAILED|CANCELLED/\n| sort @timestamp desc\n| limit 50",
                "region": "${AWS_REGION}",
                "title": "Slurm 작업 완료/실패 로그",
                "stacked": false
            }
        },
        {
            "type": "metric",
            "x": 0,
            "y": 20,
            "width": 8,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/EC2", "NetworkIn", { "stat": "Sum" } ],
                    [ ".", "NetworkOut", { "stat": "Sum" } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "네트워크 트래픽 (EFA 포함)",
                "period": 300
            }
        },
        {
            "type": "metric",
            "x": 8,
            "y": 20,
            "width": 8,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/FSx", "DataReadBytes", { "stat": "Sum" } ],
                    [ ".", "DataWriteBytes", { "stat": "Sum" } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "FSx Lustre 처리량",
                "period": 300
            }
        },
        {
            "type": "metric",
            "x": 16,
            "y": 20,
            "width": 8,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "ParallelCluster/${CLUSTER_NAME}", "DISK_USED", { "stat": "Average" } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "디스크 사용률",
                "period": 300,
                "yAxis": {
                    "left": {
                        "min": 0,
                        "max": 100
                    }
                }
            }
        },
        {
            "type": "log",
            "x": 0,
            "y": 26,
            "width": 12,
            "height": 6,
            "properties": {
                "query": "SOURCE '/aws/parallelcluster/${CLUSTER_NAME}/dcgm'\n| fields @timestamp, @message\n| filter @message like /GPU|Temperature|Power|Memory/\n| sort @timestamp desc\n| limit 30",
                "region": "${AWS_REGION}",
                "title": "GPU 상태 모니터링 (DCGM)",
                "stacked": false
            }
        },
        {
            "type": "log",
            "x": 12,
            "y": 26,
            "width": 12,
            "height": 6,
            "properties": {
                "query": "SOURCE '/aws/parallelcluster/${CLUSTER_NAME}/nvidia'\n| fields @timestamp, @message\n| sort @timestamp desc\n| limit 20",
                "region": "${AWS_REGION}",
                "title": "NVIDIA 드라이버 로그",
                "stacked": false
            }
        }
    ]
}
DASHBOARD_EOF

sed -i "s/\${CLUSTER_NAME}/${CLUSTER_NAME}/g" /tmp/dashboard-advanced-${CLUSTER_NAME}.json
sed -i "s/\${AWS_REGION}/${AWS_REGION}/g" /tmp/dashboard-advanced-${CLUSTER_NAME}.json

aws cloudwatch put-dashboard \
    --dashboard-name "${DASHBOARD_NAME}" \
    --dashboard-body file:///tmp/dashboard-advanced-${CLUSTER_NAME}.json \
    --region ${AWS_REGION}

rm -f /tmp/dashboard-advanced-${CLUSTER_NAME}.json

echo ""
echo " Advanced dashboard created successfully!"
echo ""
echo "Dashboard URL:"
echo "https://console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#dashboards:name=${DASHBOARD_NAME}"
