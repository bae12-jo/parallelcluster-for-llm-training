#!/bin/bash
# Full deployment script: S3 upload + ParallelCluster create
# Usage: ./scripts/deploy.sh <S3_BUCKET> <CLUSTER_NAME> [--dry-run]
set -euo pipefail

S3_BUCKET="${1:?Usage: deploy.sh <S3_BUCKET> <CLUSTER_NAME> <KEY_PAIR> [--dry-run]}"
CLUSTER_NAME="${2:?Usage: deploy.sh <S3_BUCKET> <CLUSTER_NAME> <KEY_PAIR> [--dry-run]}"
KEY_PAIR="${3:?Usage: deploy.sh <S3_BUCKET> <CLUSTER_NAME> <KEY_PAIR> [--dry-run]}"
DRY_RUN="${4:-}"
REGION="us-east-1"
STACK_NAME="gpu-cluster-for-distributed-training-infra"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

export AWS_PROFILE="${AWS_PROFILE:-bailey-ai}"

echo "=== P6 Monitoring Deployment ==="
echo "  Stack   : ${STACK_NAME}"
echo "  Cluster : ${CLUSTER_NAME}"
echo "  S3      : s3://${S3_BUCKET}"
echo "  KeyPair : ${KEY_PAIR}"
echo "  Region  : ${REGION}"
echo

# ---- 1. Fetch CFn outputs ----
echo "[1/4] Fetching CloudFormation outputs from ${STACK_NAME}..."
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

echo "  PrivateSubnet : ${PRIVATE_SUBNET}"
echo "  PublicSubnet  : ${PUBLIC_SUBNET}"
echo "  HeadNodeSG    : ${HEADNODE_SG}"
echo "  ComputeSG     : ${COMPUTE_SG}"
echo "  LoginSG       : ${LOGIN_SG}"
echo "  FSxId         : ${FSX_ID}"
echo "  GrafanaURL    : ${GRAFANA_URL}"
echo

# ---- 2. Upload scripts to S3 ----
echo "[2/4] Uploading scripts to s3://${S3_BUCKET}/scripts/..."

if [ "${DRY_RUN}" = "--dry-run" ]; then
  echo "  [dry-run] would sync ${SCRIPT_DIR}/ -> s3://${S3_BUCKET}/scripts/"
else
  aws s3 sync "${SCRIPT_DIR}/" "s3://${S3_BUCKET}/scripts/" \
    --exclude "*.sh.swp" \
    --exclude "deploy.sh" \
    --region "${REGION}"
  echo "  Scripts uploaded."
fi
echo

# ---- 3. Generate cluster config from template ----
echo "[3/4] Generating cluster config..."
CLUSTER_CONFIG="${PROJECT_DIR}/cluster/cluster-config-${CLUSTER_NAME}.yaml"
cp "${PROJECT_DIR}/cluster/cluster-config.yaml" "${CLUSTER_CONFIG}"

ACCOUNT_ID=$(aws sts get-caller-identity --profile "${AWS_PROFILE}" --query 'Account' --output text)
sed -i '' \
  -e "s|<KEY_PAIR>|${KEY_PAIR}|g" \
  -e "s|<PRIVATE_SUBNET_ID>|${PRIVATE_SUBNET}|g" \
  -e "s|<PUBLIC_SUBNET_ID>|${PUBLIC_SUBNET}|g" \
  -e "s|<HEADNODE_SG>|${HEADNODE_SG}|g" \
  -e "s|<COMPUTE_SG>|${COMPUTE_SG}|g" \
  -e "s|<LOGIN_SG>|${LOGIN_SG}|g" \
  -e "s|<FSX_ID>|${FSX_ID}|g" \
  -e "s|<S3_BUCKET>|${S3_BUCKET}|g" \
  -e "s|<ACCOUNT_ID>|${ACCOUNT_ID}|g" \
  "${CLUSTER_CONFIG}"

echo "  Generated: ${CLUSTER_CONFIG}"
echo

# ---- 4. Create ParallelCluster ----
echo "[4/4] Creating ParallelCluster '${CLUSTER_NAME}'..."

if [ "${DRY_RUN}" = "--dry-run" ]; then
  echo "  [dry-run] would run: pcluster create-cluster --cluster-name ${CLUSTER_NAME} ..."
  echo "  Config preview:"
  cat "${CLUSTER_CONFIG}"
else
  pcluster create-cluster \
    --region "${REGION}" \
    --cluster-name "${CLUSTER_NAME}" \
    --cluster-configuration "${CLUSTER_CONFIG}"
  echo
  echo "=== Deployment initiated ==="
  echo "  Monitor: pcluster describe-cluster --cluster-name ${CLUSTER_NAME} --region ${REGION}"
  echo "  Grafana: ${GRAFANA_URL} (admin/admin — change immediately)"
fi
