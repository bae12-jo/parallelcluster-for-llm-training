#!/bin/bash
#
# Monitor ComputeNode setup progress
# Usage: bash monitor-compute-node-setup.sh <cluster-name> [region]

set -e

CLUSTER_NAME="${1}"
REGION="${2:-us-east-2}"

if [ -z "$CLUSTER_NAME" ]; then
    echo "Usage: $0 <cluster-name> [region]"
    echo "Example: $0 p5en-48xlarge-cluster us-east-2"
    exit 1
fi

echo "=========================================="
echo "ComputeNode Setup Monitor"
echo "=========================================="
echo "Cluster: ${CLUSTER_NAME}"
echo "Region: ${REGION}"
echo "=========================================="
echo ""

# Function to check CloudWatch logs
check_logs() {
    local log_group="/aws/parallelcluster/${CLUSTER_NAME}"
    
    echo "📋 Checking CloudWatch Logs..."
    echo ""
    
    # Get latest ComputeNode log streams
    LOG_STREAMS=$(aws logs describe-log-streams \
        --log-group-name "${log_group}" \
        --region "${REGION}" \
        --order-by LastEventTime \
        --descending \
        --max-items 10 \
        --query 'logStreams[?contains(logStreamName, `Compute`) || contains(logStreamName, `compute`)].logStreamName' \
        --output text 2>/dev/null)
    
    if [ -z "$LOG_STREAMS" ]; then
        echo "⚠️  No ComputeNode logs found yet"
        echo "   Nodes may still be starting..."
        return
    fi
    
    echo "Found ComputeNode log streams:"
    echo "$LOG_STREAMS" | tr '\t' '\n' | sed 's/^/  - /'
    echo ""
    
    # Check latest log stream for installation progress
    LATEST_STREAM=$(echo "$LOG_STREAMS" | awk '{print $1}')
    echo "Checking latest stream: ${LATEST_STREAM}"
    echo ""
    
    # Get recent log events
    aws logs get-log-events \
        --log-group-name "${log_group}" \
        --log-stream-name "${LATEST_STREAM}" \
        --region "${REGION}" \
        --limit 50 \
        --start-from-head \
        --query 'events[*].message' \
        --output text | grep -E "Installing|✓|⚠️|❌|Error|Failed|Complete" | tail -20
}

# Function to check EC2 instances
check_instances() {
    echo ""
    echo "🖥️  Checking EC2 Instances..."
    echo ""
    
    aws ec2 describe-instances \
        --filters "Name=tag:aws:cloudformation:stack-name,Values=${CLUSTER_NAME}" \
                  "Name=tag:Name,Values=Compute" \
        --region "${REGION}" \
        --query 'Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,IP:PrivateIpAddress,LaunchTime:LaunchTime,Type:InstanceType}' \
        --output table
}

# Function to check CloudFormation stack
check_stack() {
    echo ""
    echo "☁️  Checking CloudFormation Stack..."
    echo ""
    
    STACK_STATUS=$(aws cloudformation describe-stacks \
        --stack-name "${CLUSTER_NAME}" \
        --region "${REGION}" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null)
    
    if [ -z "$STACK_STATUS" ]; then
        echo "❌ Stack not found: ${CLUSTER_NAME}"
        return
    fi
    
    echo "Stack Status: ${STACK_STATUS}"
    
    # Check for WaitCondition resources
    echo ""
    echo "WaitCondition Status:"
    aws cloudformation describe-stack-resources \
        --stack-name "${CLUSTER_NAME}" \
        --region "${REGION}" \
        --query 'StackResources[?ResourceType==`AWS::CloudFormation::WaitCondition`].{Resource:LogicalResourceId,Status:ResourceStatus,Reason:ResourceStatusReason}' \
        --output table
}

# Function to check from HeadNode (if accessible)
check_from_headnode() {
    echo ""
    echo "🔍 Checking from HeadNode (if accessible)..."
    echo ""
    
    # Get HeadNode IP
    HEADNODE_IP=$(aws ec2 describe-instances \
        --filters "Name=tag:aws:cloudformation:stack-name,Values=${CLUSTER_NAME}" \
                  "Name=tag:Name,Values=HeadNode" \
                  "Name=instance-state-name,Values=running" \
        --region "${REGION}" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text 2>/dev/null)
    
    if [ -z "$HEADNODE_IP" ] || [ "$HEADNODE_IP" = "None" ]; then
        echo "⚠️  HeadNode not accessible yet"
        return
    fi
    
    echo "HeadNode IP: ${HEADNODE_IP}"
    echo ""
    echo "To check ComputeNode status from HeadNode:"
    echo "  ssh headnode"
    echo "  sinfo -N -l"
    echo "  srun --nodes=1 bash /fsx/scripts/check-compute-setup.sh"
}

# Main execution
check_stack
check_instances
check_logs
check_from_headnode

echo ""
echo "=========================================="
echo "Monitoring Tips"
echo "=========================================="
echo ""
echo "Real-time log monitoring:"
echo "  aws logs tail /aws/parallelcluster/${CLUSTER_NAME} \\"
echo "    --region ${REGION} --follow --filter-pattern Compute"
echo ""
echo "Check specific installation step:"
echo "  aws logs filter-log-events \\"
echo "    --log-group-name /aws/parallelcluster/${CLUSTER_NAME} \\"
echo "    --region ${REGION} \\"
echo "    --filter-pattern \"Installing EFA\""
echo ""
echo "Check for errors:"
echo "  aws logs filter-log-events \\"
echo "    --log-group-name /aws/parallelcluster/${CLUSTER_NAME} \\"
echo "    --region ${REGION} \\"
echo "    --filter-pattern \"Error OR Failed OR ❌\""
echo ""
