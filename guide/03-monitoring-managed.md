# AWS Managed Monitoring (AMP + AMG) Guide

## Overview

AWS Managed Prometheus (AMP) and AWS Managed Grafana (AMG) provide a fully managed monitoring solution for ParallelCluster. Metrics are automatically collected and dashboards are pre-configured.

## Architecture

```
ParallelCluster
├── HeadNode Prometheus → AMP remote_write
├── ComputeNode DCGM → HeadNode Prometheus
└── ComputeNode Node Exporter → HeadNode Prometheus

AMP (AWS Managed Prometheus)
└── Remote storage (150-day retention)

AMG (AWS Managed Grafana)
├── Data source: AMP
├── Authentication: AWS SSO
└── Dashboards: Auto-configured
```

## Automated Setup

Infrastructure stack deployment automatically:

1. **Creates AMP Workspace**
   - Prometheus remote write endpoint
   - IAM policies for remote_write and queries
   - 150-day metric retention

2. **Creates AMG Workspace**
   - AWS SSO authentication
   - IAM role for data source access
   - SigV4 authentication configured

3. **Connects AMP to AMG**
   - Lambda function adds AMP as data source
   - Configures automatic authentication
   - Sets as default data source

4. **Integrates ParallelCluster**
   - HeadNode Prometheus remote_write to AMP
   - ComputeNode exporters send to HeadNode

## Required Manual Setup

### Prerequisites

AWS IAM Identity Center (SSO) must be enabled. Check:

```bash
aws sso-admin list-instances --region us-east-2
```

If not enabled, activate in AWS Console: IAM Identity Center > Enable.

### Deployment Steps

#### Step 1: Deploy Infrastructure Stack

```bash
aws cloudformation create-stack \
    --stack-name pcluster-infra \
    --template-body file://parallelcluster-infrastructure.yaml \
    --parameters \
        ParameterKey=MonitoringType,ParameterValue=amp+amg \
        ParameterKey=VPCName,ParameterValue=pcluster-vpc \
    --capabilities CAPABILITY_NAMED_IAM \
    --region us-east-2
```

Wait for completion (~10 minutes):

```bash
aws cloudformation wait stack-create-complete \
    --stack-name pcluster-infra \
    --region us-east-2
```

#### Step 2: Retrieve Grafana Information

```bash
# Get Grafana URL
GRAFANA_URL=$(aws cloudformation describe-stacks \
    --stack-name pcluster-infra \
    --region us-east-2 \
    --query 'Stacks[0].Outputs[?OutputKey==`ManagedGrafanaWorkspaceEndpoint`].OutputValue' \
    --output text)

# Get Workspace ID
GRAFANA_WORKSPACE_ID=$(aws cloudformation describe-stacks \
    --stack-name pcluster-infra \
    --region us-east-2 \
    --query 'Stacks[0].Outputs[?OutputKey==`ManagedGrafanaWorkspaceId`].OutputValue' \
    --output text)

echo "Grafana URL: https://${GRAFANA_URL}"
echo "Workspace ID: ${GRAFANA_WORKSPACE_ID}"
```

#### Step 3: Add Grafana Users

Add users with appropriate roles:

```bash
# Add single user as ADMIN
aws grafana update-permissions \
    --workspace-id ${GRAFANA_WORKSPACE_ID} \
    --region us-east-2 \
    --update-instruction-batch '[
        {
            "action": "ADD",
            "role": "ADMIN",
            "users": [
                {
                    "id": "your-email@example.com",
                    "type": "SSO_USER"
                }
            ]
        }
    ]'
```

**Role options**:
- `ADMIN`: Full permissions (create/modify/delete dashboards)
- `EDITOR`: Create and modify dashboards
- `VIEWER`: Read-only access

**Add multiple users**:

```bash
aws grafana update-permissions \
    --workspace-id ${GRAFANA_WORKSPACE_ID} \
    --region us-east-2 \
    --update-instruction-batch '[
        {
            "action": "ADD",
            "role": "ADMIN",
            "users": [
                {"id": "admin@example.com", "type": "SSO_USER"}
            ]
        },
        {
            "action": "ADD",
            "role": "EDITOR",
            "users": [
                {"id": "engineer1@example.com", "type": "SSO_USER"},
                {"id": "engineer2@example.com", "type": "SSO_USER"}
            ]
        },
        {
            "action": "ADD",
            "role": "VIEWER",
            "users": [
                {"id": "viewer@example.com", "type": "SSO_USER"}
            ]
        }
    ]'
```

#### Step 4: Deploy ParallelCluster

```bash
source environment-variables-bailey.sh

pcluster create-cluster \
    --cluster-name ${CLUSTER_NAME} \
    --cluster-configuration cluster-config.yaml \
    --region ${AWS_REGION}
```

Metrics will automatically flow to AMP and become visible in Grafana.

## Accessing Grafana

### Via Web Browser

```bash
# Get URL
echo "https://<workspace-id>.grafana-workspace.us-east-2.amazonaws.com"

# Login with AWS SSO
```

### Via SSH Port Forwarding

```bash
# SSH tunnel to LoginNode
ssh -i your-key.pem -L 8443:localhost:443 ubuntu@<LoginNode-IP>

# Access locally
# https://localhost:8443/grafana/
```

### Via AWS Systems Manager Session Manager

```bash
# Port forward
aws ssm start-session \
    --target <LoginNode-Instance-ID> \
    --document-name AWS-StartPortForwardingSession \
    --parameters '{"portNumber":["443"],"localPortNumber":["8443"]}'

# Access locally
# https://localhost:8443/grafana/
```

## Available Metrics

Automatically collected from compute nodes:

### GPU Metrics (DCGM)

- `DCGM_FI_DEV_GPU_UTIL` - GPU utilization (%)
- `DCGM_FI_DEV_MEM_COPY_UTIL` - GPU memory utilization (%)
- `DCGM_FI_DEV_GPU_TEMP` - GPU temperature (°C)
- `DCGM_FI_DEV_POWER_USAGE` - GPU power consumption (W)
- `DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL` - NVLink bandwidth (bytes)

### System Metrics (Node Exporter)

- `node_cpu_seconds_total` - CPU time
- `node_memory_MemAvailable_bytes` - Available memory
- `node_disk_io_time_seconds_total` - Disk I/O
- `node_network_receive_bytes_total` - Network RX
- `node_network_transmit_bytes_total` - Network TX

See [Prometheus Metrics](04-monitoring-self-hosted.md#prometheus-metrics-reference) for complete list.

## Creating Dashboards

### Quick Start

1. Access Grafana
2. Left menu → Create → Dashboard
3. Add panel
4. Select metric (e.g., `DCGM_FI_DEV_GPU_UTIL`)
5. Data source: Amazon Managed Prometheus (auto-selected)
6. Configure visualization (time series, gauge, stat, etc.)
7. Save dashboard

### Example Query: GPU Utilization

```promql
# Average GPU utilization
avg(DCGM_FI_DEV_GPU_UTIL)

# GPU utilization per node
DCGM_FI_DEV_GPU_UTIL by (instance_id)
```

### Example Query: Memory Usage

```promql
# Memory utilization percentage
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100
```

## Troubleshooting

### Cannot Access Grafana

**Cause**: User not added to workspace

**Fix**:
```bash
# List current permissions
aws grafana list-permissions \
    --workspace-id ${GRAFANA_WORKSPACE_ID} \
    --region us-east-2

# Add user
aws grafana update-permissions \
    --workspace-id ${GRAFANA_WORKSPACE_ID} \
    --region us-east-2 \
    --update-instruction-batch '[
        {
            "action": "ADD",
            "role": "ADMIN",
            "users": [
                {"id": "your-email@example.com", "type": "SSO_USER"}
            ]
        }
    ]'
```

### AMP Data Source Missing

**Cause**: Lambda function failed to configure data source

**Fix**:
```bash
# Check Lambda logs
aws logs tail /aws/lambda/pcluster-infra-grafana-datasource-setup \
    --region us-east-2 \
    --follow

# Manually invoke Lambda
aws lambda invoke \
    --function-name pcluster-infra-grafana-datasource-setup \
    --region us-east-2 \
    /tmp/lambda-output.json

cat /tmp/lambda-output.json
```

### No Metrics in Grafana

**Cause**: HeadNode Prometheus not sending to AMP

**Fix**:
```bash
# SSH to HeadNode
ssh headnode

# Check Prometheus status
sudo systemctl status prometheus

# Check configuration
cat /opt/prometheus/prometheus.yml | grep -A 10 remote_write

# Verify AMP endpoint
curl -I https://aps-workspaces.us-east-2.amazonaws.com/workspaces/<workspace-id>/api/v1/remote_write
```

## Cost Estimates

### AMP (AWS Managed Prometheus)

- Metric ingestion: $0.30 per million samples
- Metric storage: $0.03 per GB-month
- Queries: $0.01 per million samples

**Estimated monthly** (10-node cluster, 100 metrics):
- Ingestion: ~$60
- Storage: ~$30
- Queries: ~$10
- **Total**: ~$100/month

### AMG (AWS Managed Grafana)

- Per active user: $9/month

**Estimated monthly**:
- 1-5 users: $9-45
- 6-10 users: $54-90

### Total Estimated Cost

- **1-5 users**: ~$140-210/month
- **Self-hosting comparison**: Similar or lower with operational overhead

## Metric Retention

### AMP

- **Local storage**: 1 hour (temporary)
- **AMP storage**: 150 days (automatic)
- **Long-term**: Export to S3 for archival (manual)

### Custom Retention

Cannot change AMP retention directly. Options:
1. Use 150-day retention (standard)
2. Export metrics to S3 before expiry
3. Query before expiry and store in external system

## Related Documentation

- [Self-Hosted Monitoring](04-monitoring-self-hosted.md)
- [Prometheus Metrics](04-monitoring-self-hosted.md#prometheus-metrics-reference)
- [AWS Managed Prometheus](https://docs.aws.amazon.com/prometheus/)
- [AWS Managed Grafana](https://docs.aws.amazon.com/grafana/)
