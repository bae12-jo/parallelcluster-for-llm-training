#!/bin/bash
export PATH=/opt/slurm/bin:$PATH
AWS_CLI=$(command -v aws || echo /usr/local/bin/aws)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
INSTANCES=$($AWS_CLI ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:parallelcluster:node-type,Values=Compute" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[?!Tags[?Key==`slurm:hostname`]].[InstanceId,PrivateIpAddress]' \
  --output text 2>/dev/null)
[ -z "$INSTANCES" ] && exit 0
while IFS=$'\t' read -r INSTANCE_ID PRIVATE_IP; do
  [ -z "$INSTANCE_ID" ] && continue
  SLURM_HOST=$(sinfo -h -o "%N %o" 2>/dev/null | awk -v ip="$PRIVATE_IP" '$2==ip {print $1}' | head -1)
  if [ -n "$SLURM_HOST" ]; then
    $AWS_CLI ec2 create-tags --region "$REGION" --resources "$INSTANCE_ID" \
      --tags "Key=slurm:hostname,Value=$SLURM_HOST" "Key=Name,Value=$SLURM_HOST" 2>/dev/null \
      && echo "Tagged $INSTANCE_ID -> $SLURM_HOST"
  fi
done <<< "$INSTANCES"
