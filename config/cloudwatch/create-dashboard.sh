#!/bin/bash
# ==============================================================================
# ParallelCluster Comprehensive Dashboard Creator
# ==============================================================================
# Purpose: Create CloudWatch dashboard for distributed training cluster monitoring
# Target Users: Infrastructure managers and ML training engineers
# ==============================================================================

set +e  # Don't exit on error (can be called from background)

# Configuration
CLUSTER_NAME="${1:-p5en-48xlarge-cluster}"
AWS_REGION="${2:-us-east-2}"
DASHBOARD_NAME="ParallelCluster-${CLUSTER_NAME}"

echo "=================================================="
echo "Creating ParallelCluster Dashboard"
echo "=================================================="
echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${AWS_REGION}"
echo "Dashboard: ${DASHBOARD_NAME}"
echo ""

# Get cluster information
echo "[1/3] Fetching cluster information..."
HEAD_NODE_ID=$(aws ec2 describe-instances \
    --region ${AWS_REGION} \
    --filters "Name=tag:parallelcluster:cluster-name,Values=${CLUSTER_NAME}" \
              "Name=tag:parallelcluster:node-type,Values=HeadNode" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || echo "")

if [ -z "$HEAD_NODE_ID" ] || [ "$HEAD_NODE_ID" = "None" ]; then
    echo "️  Warning: HeadNode not found. Dashboard will be created but may show no data."
    HEAD_NODE_ID="i-placeholder"
fi

echo "HeadNode Instance ID: ${HEAD_NODE_ID}"

# Create dashboard JSON
echo "[2/3] Generating dashboard configuration..."
cat > /tmp/dashboard-${CLUSTER_NAME}.json << 'DASHBOARD_EOF'
{
    "widgets": [
        {
            "type": "text",
            "x": 0,
            "y": 0,
            "width": 24,
            "height": 2,
            "properties": {
                "markdown": "# ParallelCluster: ${CLUSTER_NAME}\n## 분산학습 클러스터 종합 모니터링 대시보드\n**인프라 관리자 및 모델 학습자를 위한 실시간 모니터링**"
            }
        },
        {
            "type": "metric",
            "x": 0,
            "y": 2,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/EC2", "CPUUtilization", { "stat": "Average", "label": "HeadNode CPU" } ],
                    [ "ParallelCluster/${CLUSTER_NAME}", "CPU_IDLE", { "stat": "Average", "label": "Compute Nodes CPU Idle" } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "클러스터 CPU 사용률",
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
            "type": "metric",
            "x": 12,
            "y": 2,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "ParallelCluster/${CLUSTER_NAME}", "MEM_USED", { "stat": "Average" } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "메모리 사용률",
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
            "y": 8,
            "width": 24,
            "height": 6,
            "properties": {
                "query": "SOURCE '/aws/parallelcluster/${CLUSTER_NAME}/slurm'\n| fields @timestamp, @message\n| filter @message like /error|fail|ERROR|FAIL/\n| sort @timestamp desc\n| limit 50",
                "region": "${AWS_REGION}",
                "title": "Slurm 에러 로그 (최근 50개)",
                "stacked": false
            }
        },
        {
            "type": "metric",
            "x": 0,
            "y": 14,
            "width": 8,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/EC2", "NetworkIn", { "stat": "Sum", "label": "Network In" } ],
                    [ ".", "NetworkOut", { "stat": "Sum", "label": "Network Out" } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "네트워크 트래픽",
                "period": 300
            }
        },
        {
            "type": "metric",
            "x": 8,
            "y": 14,
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
            "type": "metric",
            "x": 16,
            "y": 14,
            "width": 8,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "ParallelCluster/${CLUSTER_NAME}", "read_bytes", { "stat": "Sum", "label": "Disk Read" } ],
                    [ ".", "write_bytes", { "stat": "Sum", "label": "Disk Write" } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "디스크 I/O",
                "period": 300
            }
        },
        {
            "type": "log",
            "x": 0,
            "y": 20,
            "width": 12,
            "height": 6,
            "properties": {
                "query": "SOURCE '/aws/parallelcluster/${CLUSTER_NAME}/slurm-resume'\n| fields @timestamp, @message\n| sort @timestamp desc\n| limit 20",
                "region": "${AWS_REGION}",
                "title": "Slurm Resume 로그 (노드 시작)",
                "stacked": false
            }
        },
        {
            "type": "log",
            "x": 12,
            "y": 20,
            "width": 12,
            "height": 6,
            "properties": {
                "query": "SOURCE '/aws/parallelcluster/${CLUSTER_NAME}/slurm-suspend'\n| fields @timestamp, @message\n| sort @timestamp desc\n| limit 20",
                "region": "${AWS_REGION}",
                "title": "Slurm Suspend 로그 (노드 종료)",
                "stacked": false
            }
        },
        {
            "type": "log",
            "x": 0,
            "y": 26,
            "width": 24,
            "height": 6,
            "properties": {
                "query": "SOURCE '/aws/parallelcluster/${CLUSTER_NAME}/dcgm'\n| fields @timestamp, @message\n| filter @message like /GPU|gpu|error|ERROR/\n| sort @timestamp desc\n| limit 30",
                "region": "${AWS_REGION}",
                "title": "GPU 모니터링 (DCGM 로그)",
                "stacked": false
            }
        },
        {
            "type": "log",
            "x": 0,
            "y": 32,
            "width": 24,
            "height": 6,
            "properties": {
                "query": "SOURCE '/aws/parallelcluster/${CLUSTER_NAME}/clustermgtd'\n| fields @timestamp, @message\n| sort @timestamp desc\n| limit 30",
                "region": "${AWS_REGION}",
                "title": "클러스터 관리 로그 (clustermgtd)",
                "stacked": false
            }
        },
        {
            "type": "metric",
            "x": 0,
            "y": 38,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/FSx", "DataReadBytes", { "stat": "Sum" } ],
                    [ ".", "DataWriteBytes", { "stat": "Sum" } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "FSx Lustre I/O",
                "period": 300
            }
        },
        {
            "type": "metric",
            "x": 12,
            "y": 38,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/FSx", "DataReadOperations", { "stat": "Sum" } ],
                    [ ".", "DataWriteOperations", { "stat": "Sum" } ]
                ],
                "view": "timeSeries",
                "stacked": false,
                "region": "${AWS_REGION}",
                "title": "FSx Lustre Operations",
                "period": 300
            }
        }
    ]
}
DASHBOARD_EOF

# Replace placeholders
sed -i "s/\${CLUSTER_NAME}/${CLUSTER_NAME}/g" /tmp/dashboard-${CLUSTER_NAME}.json
sed -i "s/\${AWS_REGION}/${AWS_REGION}/g" /tmp/dashboard-${CLUSTER_NAME}.json

# Create dashboard
echo "[3/3] Creating CloudWatch dashboard..."
aws cloudwatch put-dashboard \
    --dashboard-name "${DASHBOARD_NAME}" \
    --dashboard-body file:///tmp/dashboard-${CLUSTER_NAME}.json \
    --region ${AWS_REGION}

# Cleanup
rm -f /tmp/dashboard-${CLUSTER_NAME}.json

echo ""
echo " Dashboard created successfully!"
echo ""
echo "Dashboard URL:"
echo "https://console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#dashboards:name=${DASHBOARD_NAME}"
echo ""
echo "Dashboard includes:"
echo "   CPU/Memory/Disk usage across all nodes"
echo "   Network and FSx Lustre I/O metrics"
echo "   Slurm job logs (resume/suspend/errors)"
echo "   GPU monitoring (DCGM logs)"
echo "   Cluster management logs"
