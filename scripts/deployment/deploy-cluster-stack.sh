#!/bin/bash
# Deploy monitoring infrastructure (CloudFormation) + ParallelCluster in one step.
#
# Required environment variables:
#   S3_BUCKET      — S3 bucket containing scripts/ and dashboards/
#   KEY_PAIR       — EC2 key pair name for HeadNode/LoginNode SSH access
#   GRAFANA_PASS   — Grafana admin password
#
# Optional:
#   CLUSTER_NAME   — ParallelCluster name (default: gpu-monitoring-test)
#   STACK_NAME     — CloudFormation stack name (default: gpu-cluster-for-ml)
#   REGION         — AWS region (default: us-east-1)
#   AWS_PROFILE    — AWS CLI profile (default: default)
#
# Usage:
#   export S3_BUCKET=my-bucket KEY_PAIR=my-keypair GRAFANA_PASS=changeme
#   ./scripts/deploy-cluster-stack.sh

set -euo pipefail

S3_BUCKET="${S3_BUCKET:?S3_BUCKET env var required (e.g. my-pcluster-bucket)}"
KEY_PAIR="${KEY_PAIR:?KEY_PAIR env var required (e.g. my-ec2-keypair)}"
GRAFANA_PASS="${GRAFANA_PASS:?GRAFANA_PASS env var required}"
CLUSTER_NAME="${CLUSTER_NAME:-gpu-monitoring-test}"
STACK_NAME="${STACK_NAME:-gpu-cluster-for-ml}"
REGION="${REGION:-us-east-1}"
MY_IP=$(curl -s https://checkip.amazonaws.com)

export AWS_PROFILE="${AWS_PROFILE:-default}"

echo "=== GPU Cluster Monitoring — Full Deploy ==="
echo "  Stack  : ${STACK_NAME}"
echo "  Cluster: ${CLUSTER_NAME}"
echo "  Region : ${REGION}"
echo "  My IP  : ${MY_IP}"
echo

# ---- 1. Delete pcluster if exists ----
if pcluster describe-cluster --cluster-name "${CLUSTER_NAME}" --region "${REGION}" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['clusterStatus'])" 2>/dev/null | grep -q "COMPLETE\|PROGRESS"; then
  echo "[1/5] Deleting pcluster ${CLUSTER_NAME}..."
  pcluster delete-cluster --cluster-name "${CLUSTER_NAME}" --region "${REGION}"
  until pcluster describe-cluster --cluster-name "${CLUSTER_NAME}" --region "${REGION}" 2>&1 | grep -q "does not exist\|DELETE_COMPLETE"; do
    echo "  waiting for pcluster delete..."
    sleep 30
  done
  echo "  pcluster deleted."
else
  echo "[1/5] No existing pcluster ${CLUSTER_NAME}, skipping."
fi

# ---- 2. Delete CFn stack if exists ----
STACK_STATUS=$(aws cloudformation describe-stacks --region "${REGION}" \
  --stack-name "${STACK_NAME}" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "${STACK_STATUS}" != "DOES_NOT_EXIST" ]; then
  echo "[2/5] Deleting CFn stack ${STACK_NAME} (status: ${STACK_STATUS})..."
  aws cloudformation delete-stack --region "${REGION}" --stack-name "${STACK_NAME}"
  aws cloudformation wait stack-delete-complete --region "${REGION}" --stack-name "${STACK_NAME}"
  echo "  CFn stack deleted."
else
  echo "[2/5] No existing CFn stack ${STACK_NAME}, skipping."
fi

# ---- 3. Upload scripts + dashboards to S3 ----
echo "[3/5] Uploading scripts and dashboards to S3..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

aws s3 sync "${SCRIPT_DIR}/" "s3://${S3_BUCKET}/scripts/" \
  --exclude "deploy-cluster-stack.sh" --region "${REGION}"
aws s3 sync "${PROJECT_DIR}/dashboards/" "s3://${S3_BUCKET}/dashboards/" \
  --exclude "*.py" --exclude ".omc/*" --region "${REGION}"
echo "  Uploaded."

# ---- 4. Create CFn stack ----
echo "[4/5] Creating CFn stack ${STACK_NAME}..."
aws cloudformation create-stack \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --template-body "file://${PROJECT_DIR}/parallelcluster-infrastructure.yaml" \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=PrimarySubnetAZ,ParameterValue="${REGION}a" \
    ParameterKey=SecondarySubnetAZ,ParameterValue="${REGION}b" \
    ParameterKey=MonitoringKeyPair,ParameterValue="${KEY_PAIR}" \
    ParameterKey=AllowedIPsForSSH,ParameterValue="${MY_IP}/32" \
    ParameterKey=AllowedIPsForALB,ParameterValue="${MY_IP}/32" \
    ParameterKey=GrafanaAdminPassword,ParameterValue="${GRAFANA_PASS}" \
    ParameterKey=S3BucketName,ParameterValue="${S3_BUCKET}"

aws cloudformation wait stack-create-complete --region "${REGION}" --stack-name "${STACK_NAME}"
echo "  CFn stack created."

# ---- Fetch outputs ----
get_output() {
  aws cloudformation describe-stacks --region "${REGION}" --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='${1}'].OutputValue" --output text
}

PRIVATE_SUBNET=$(get_output PrivateSubnetId)
PUBLIC_SUBNET=$(get_output PublicSubnetId)
HEADNODE_SG=$(get_output HeadNodeSGId)
COMPUTE_SG=$(get_output ComputeNodeSGId)
LOGIN_SG=$(get_output LoginNodeSGId)
FSX_ID=$(get_output FSxLustreFilesystemId)
GRAFANA_URL=$(get_output GrafanaURL)
COMPUTE_TAGGING_POLICY_ARN=$(get_output ComputeNodeTaggingPolicyArn)

echo
echo "  GrafanaURL : ${GRAFANA_URL}"
echo "  FSxId      : ${FSX_ID}"

# ---- 5. Generate cluster config + deploy pcluster ----
echo "[5/5] Deploying pcluster ${CLUSTER_NAME}..."
CLUSTER_CONFIG="${PROJECT_DIR}/cluster-sample.yaml"
GENERATED_CONFIG="/tmp/cluster-config-${CLUSTER_NAME}.yaml"
cp "${CLUSTER_CONFIG}" "${GENERATED_CONFIG}"

sed -i \
  -e "s|<KEY_PAIR>|${KEY_PAIR}|g" \
  -e "s|<PRIVATE_SUBNET_ID>|${PRIVATE_SUBNET}|g" \
  -e "s|<PUBLIC_SUBNET_ID>|${PUBLIC_SUBNET}|g" \
  -e "s|<HEADNODE_SG>|${HEADNODE_SG}|g" \
  -e "s|<COMPUTE_SG>|${COMPUTE_SG}|g" \
  -e "s|<LOGIN_SG>|${LOGIN_SG}|g" \
  -e "s|<FSX_ID>|${FSX_ID}|g" \
  -e "s|<S3_BUCKET>|${S3_BUCKET}|g" \
  "${GENERATED_CONFIG}"

pcluster create-cluster \
  --region "${REGION}" \
  --cluster-name "${CLUSTER_NAME}" \
  --cluster-configuration "${GENERATED_CONFIG}"

echo
echo "=== Deployment initiated ==="
echo "  Monitor : pcluster describe-cluster --cluster-name ${CLUSTER_NAME} --region ${REGION}"
echo "  Grafana : ${GRAFANA_URL} (admin / <your password>)"
echo "  Note    : slurm_exporter auto-installs ~10 min after CREATE_COMPLETE"
