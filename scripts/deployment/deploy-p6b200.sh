#!/bin/bash
# Deployment script for p6-b200 validation — us-east-2 (Ohio), sanghwa profile
# Usage: ./scripts/deploy-p6b200.sh <S3_BUCKET> <CLUSTER_NAME> [--dry-run]
set -euo pipefail

S3_BUCKET="${1:?Usage: deploy-p6b200.sh <S3_BUCKET> <CLUSTER_NAME> <KEY_PAIR> <CAPACITY_RESERVATION_ID> [--dry-run]}"
CLUSTER_NAME="${2:?Usage: deploy-p6b200.sh <S3_BUCKET> <CLUSTER_NAME> <KEY_PAIR> <CAPACITY_RESERVATION_ID> [--dry-run]}"
KEY_PAIR="${3:?Usage: deploy-p6b200.sh <S3_BUCKET> <CLUSTER_NAME> <KEY_PAIR> <CAPACITY_RESERVATION_ID> [--dry-run]}"
CAPACITY_RESERVATION_ID="${4:?Usage: deploy-p6b200.sh <S3_BUCKET> <CLUSTER_NAME> <KEY_PAIR> <CAPACITY_RESERVATION_ID> [--dry-run]}"
DRY_RUN="${5:-}"
GRAFANA_PASSWORD="admin"
REGION="us-east-2"
STACK_NAME="gpu-cluster-for-distributed-training-infra"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

export AWS_PROFILE="${AWS_PROFILE:-sanghwa}"

# ---- Lookup Capacity Block AZ ----
CB_AZ=$(aws ec2 describe-capacity-reservations --profile "${AWS_PROFILE}" --region "${REGION}" \
  --capacity-reservation-ids "${CAPACITY_RESERVATION_ID}" \
  --query 'CapacityReservations[0].AvailabilityZone' --output text 2>&1)
if [ -z "${CB_AZ}" ] || [ "${CB_AZ}" = "None" ]; then
  echo "ERROR: Could not determine AZ for Capacity Reservation ${CAPACITY_RESERVATION_ID}"
  exit 1
fi
# Secondary AZ: pick a different AZ in same region
PRIMARY_AZ="${CB_AZ}"
SECONDARY_AZ=$(aws ec2 describe-availability-zones --profile "${AWS_PROFILE}" --region "${REGION}" \
  --query "AvailabilityZones[?ZoneName!='${CB_AZ}'].ZoneName" \
  --output text 2>&1 | awk '{print $1}')

echo "=== P6-B200 Monitoring Deployment ==="
echo "  Stack        : ${STACK_NAME}"
echo "  Cluster      : ${CLUSTER_NAME}"
echo "  S3           : s3://${S3_BUCKET}"
echo "  KeyPair      : ${KEY_PAIR}"
echo "  Capacity Rsv : ${CAPACITY_RESERVATION_ID}"
echo "  CB AZ        : ${CB_AZ} (PrimarySubnetAZ)"
echo "  Secondary AZ : ${SECONDARY_AZ}"
echo "  Region       : ${REGION}"
echo "  Profile      : ${AWS_PROFILE}"
echo

# ---- 0. Deploy infra stack if not exists ----
STACK_STATUS=$(aws cloudformation describe-stacks --profile "${AWS_PROFILE}" --region "${REGION}" \
  --stack-name "${STACK_NAME}" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_EXIST")

if [ "${STACK_STATUS}" = "NOT_EXIST" ] || [ "${STACK_STATUS}" = "DELETE_COMPLETE" ]; then
  echo "[0/4] Deploying infrastructure stack..."
  if [ "${DRY_RUN}" = "--dry-run" ]; then
    echo "  [dry-run] would deploy ${STACK_NAME} in ${REGION}"
  else
    aws cloudformation deploy \
      --profile "${AWS_PROFILE}" --region "${REGION}" \
      --template-file "${PROJECT_DIR}/infrastructure/gpu-cluster-infra.yaml" \
      --stack-name "${STACK_NAME}" \
      --capabilities CAPABILITY_IAM \
      --parameter-overrides \
        VPCName="${STACK_NAME}" \
        PrimarySubnetAZ="${PRIMARY_AZ}" \
        SecondarySubnetAZ="${SECONDARY_AZ}" \
        MonitoringKeyPair="${KEY_PAIR}" \
        AllowedIPsForSSH="$(curl -s https://checkip.amazonaws.com)/32" \
        AllowedIPsForALB="$(curl -s https://checkip.amazonaws.com)/32" \
        GrafanaAdminPassword="${GRAFANA_PASSWORD}" \
        S3BucketName="${S3_BUCKET}" \
        VpcCidr="10.0.0.0/16" \
        VpcSecondaryCidr="10.1.0.0/16"
    echo "  Infrastructure stack deployed."
    aws cloudformation wait stack-create-complete \
      --profile "${AWS_PROFILE}" --region "${REGION}" \
      --stack-name "${STACK_NAME}"
    echo "  Stack create complete."
  fi
  echo
else
  echo "[0/4] Infrastructure stack already exists (${STACK_STATUS}), skipping."
  echo
fi

# ---- 1. Fetch CFn outputs ----
echo "[1/4] Fetching CloudFormation outputs from ${STACK_NAME}..."
get_output() {
  aws cloudformation describe-stacks --profile "${AWS_PROFILE}" --region "${REGION}" \
    --stack-name "${STACK_NAME}" \
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
    --profile "${AWS_PROFILE}" \
    --exclude "*.sh.swp" \
    --exclude "deploy*.sh" \
    --region "${REGION}"
  echo "  Scripts uploaded."
fi
echo

# ---- 3. Generate cluster config ----
echo "[3/4] Generating cluster config..."
CLUSTER_CONFIG="${PROJECT_DIR}/cluster/cluster-config-${CLUSTER_NAME}.yaml"
cp "${PROJECT_DIR}/cluster/cluster-config-p6b200.yaml" "${CLUSTER_CONFIG}"

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
  -e "s|<CAPACITY_RESERVATION_ID>|${CAPACITY_RESERVATION_ID}|g" \
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
