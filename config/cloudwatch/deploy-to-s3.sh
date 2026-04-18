#!/bin/bash
# ==============================================================================
# Deploy CloudWatch Configuration to S3
# ==============================================================================

set -e

# Load environment variables
if [ -f "environment-variables-bailey.sh" ]; then
    source environment-variables-bailey.sh
else
    echo " Error: environment-variables-bailey.sh not found"
    exit 1
fi

echo "=================================================="
echo "Deploying CloudWatch Configuration to S3"
echo "=================================================="
echo "S3 Bucket: ${S3_BUCKET}"
echo "Region: ${AWS_REGION}"
echo ""

# Sync cloudwatch config to S3
echo "[1/2] Uploading CloudWatch configuration files..."
aws s3 sync config/cloudwatch/ s3://${S3_BUCKET}/config/cloudwatch/ \
    --region ${AWS_REGION} \
    --exclude "*.md" \
    --exclude "deploy-to-s3.sh"

# Verify upload
echo ""
echo "[2/2] Verifying upload..."
aws s3 ls s3://${S3_BUCKET}/config/cloudwatch/ --recursive --region ${AWS_REGION}

echo ""
echo " CloudWatch configuration deployed successfully!"
echo ""
echo "Next steps:"
echo "1. Update cluster configuration (if needed)"
echo "2. Create/update cluster: pcluster update-cluster --cluster-name ${CLUSTER_NAME}"
echo "3. After cluster is running, create dashboards:"
echo "   bash config/cloudwatch/create-dashboard.sh ${CLUSTER_NAME} ${AWS_REGION}"
echo "   bash config/cloudwatch/create-advanced-dashboard.sh ${CLUSTER_NAME} ${AWS_REGION}"
