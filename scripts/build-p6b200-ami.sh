#!/bin/bash
# Build custom AMI for p6-b200 based on pcluster 3.15 official AMI
# Fixes: nvidia-fabricmanager disabled at boot (prevents Pre-NVL5 panic)
#        ib_umad + nvlsm pre-installed for NVSwitch initialization
# Usage: bash build-p6b200-ami.sh <REGION> <KEY_PAIR> <SUBNET_ID> <SECURITY_GROUP_ID>
set -euo pipefail

REGION="${1:?Usage: build-p6b200-ami.sh <REGION> <KEY_PAIR> <SUBNET_ID> <SECURITY_GROUP_ID>}"
KEY_PAIR="${2:?}"
SUBNET_ID="${3:?}"
SG_ID="${4:?}"

BASE_AMI="ami-0f8eed74478b388d3"  # pcluster 3.15 ubuntu2204 us-east-1
INSTANCE_TYPE="g4dn.2xlarge"       # needs NVIDIA driver
AMI_NAME="pcluster-3.15-p6b200-$(date +%Y%m%d)"

export AWS_PROFILE="${AWS_PROFILE:-sanghwa}"

echo "=== Launching builder instance ==="
INSTANCE_ID=$(aws ec2 run-instances \
  --region $REGION \
  --image-id $BASE_AMI \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_PAIR \
  --subnet-id $SUBNET_ID \
  --security-group-ids $SG_ID \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":200,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=pcluster-ami-builder}]" \
  --query 'Instances[0].InstanceId' --output text 2>&1)
echo "Builder: $INSTANCE_ID"

aws ec2 wait instance-running --region $REGION --instance-ids $INSTANCE_ID
echo "Instance running. Waiting for SSM..."
sleep 60

echo "=== Applying p6-b200 fixes ==="
CMD_ID=$(aws ssm send-command \
  --region $REGION \
  --instance-ids $INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":[
    "export DEBIAN_FRONTEND=noninteractive",
    "apt-get install -y linux-modules-extra-$(uname -r) infiniband-diags ibutils 2>&1 | tail -3",
    "modprobe ib_umad && echo ib_umad loaded",
    "echo ib_umad | tee -a /etc/modules",
    "curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/nvlsm_2025.06.5-1_amd64.deb -o /tmp/nvlsm.deb && dpkg -i /tmp/nvlsm.deb && rm /tmp/nvlsm.deb",
    "systemctl disable nvidia-fabricmanager",
    "systemctl stop nvidia-fabricmanager 2>/dev/null || true",
    "echo FIXES_APPLIED"
  ]}' \
  --timeout-seconds 600 \
  --query 'Command.CommandId' --output text 2>&1)
echo "Setup CMD: $CMD_ID"

while true; do
  STATUS=$(aws ssm get-command-invocation --region $REGION \
    --instance-id $INSTANCE_ID --command-id $CMD_ID \
    --query 'Status' --output text 2>/dev/null)
  echo "$(date '+%H:%M:%S') $STATUS"
  [ "$STATUS" = "Success" ] && break
  [ "$STATUS" = "Failed" ] && echo "FAILED!" && exit 1
  sleep 15
done

aws ssm get-command-invocation --region $REGION \
  --instance-id $INSTANCE_ID --command-id $CMD_ID \
  --query 'StandardOutputContent' --output text 2>&1 | tail -5

echo "=== Running AMI cleanup ==="
CLEAN_CMD=$(aws ssm send-command \
  --region $REGION \
  --instance-ids $INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":[
    "sudo rm -f /opt/parallelcluster/system_info",
    "sudo /usr/local/sbin/ami_cleanup.sh 2>/dev/null || true",
    "echo CLEANUP_DONE"
  ]}' \
  --timeout-seconds 120 \
  --query 'Command.CommandId' --output text 2>&1)
sleep 30
aws ssm get-command-invocation --region $REGION \
  --instance-id $INSTANCE_ID --command-id $CLEAN_CMD \
  --query 'StandardOutputContent' --output text 2>&1 | tail -3

echo "=== Creating AMI: $AMI_NAME ==="
AMI_ID=$(aws ec2 create-image \
  --region $REGION \
  --instance-id $INSTANCE_ID \
  --name "$AMI_NAME" \
  --description "pcluster 3.15 + ib_umad + nvlsm + fabricmanager disabled for p6-b200" \
  --no-reboot \
  --query 'ImageId' --output text 2>&1)
echo "AMI: $AMI_ID"

echo "=== Waiting for AMI to be available ==="
aws ec2 wait image-available --region $REGION --image-ids $AMI_ID
echo "AMI $AMI_ID is available!"

echo "=== Terminating builder instance ==="
aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID 2>&1
echo "Done! Use AMI: $AMI_ID"
