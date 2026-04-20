#!/bin/bash
# ==============================================================================
# ParallelCluster Environment Variables Configuration
# ==============================================================================
# Usage:
#   1. Edit the "USER CONFIGURATION" section below
#   2. source environment-variables.sh
#   3. envsubst < cluster-config.yaml.template > cluster-config.yaml
# ==============================================================================

# ==============================================================================
# INFRASTRUCTURE CONFIGURATION (Auto-fetched from CloudFormation)
# ==============================================================================

# Stack name from parallelcluster-infrastructure.yaml deployment
STACK_NAME="your-cloudformation-stack-name" # ⚠️ CHANGE THIS: Your cloudformation stack name

# Check AWS CLI configuration
export AWS_REGION=$(aws configure get region 2>/dev/null)

if [ -z "$AWS_REGION" ]; then
    echo "❌ Error: Please configure AWS credentials first."
    return 1 2>/dev/null || exit 1
fi

echo "📡 Fetching values from CloudFormation stack '${STACK_NAME}'..."
echo "   Region: ${AWS_REGION}"

# Verify stack status
STACK_STATUS=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
if [ "$STACK_STATUS" != "CREATE_COMPLETE" ] && [ "$STACK_STATUS" != "UPDATE_COMPLETE" ]; then
    echo "⚠️  Warning: Stack '${STACK_NAME}' status is '${STACK_STATUS}'"
    echo "   Expected: CREATE_COMPLETE or UPDATE_COMPLETE"
else
    echo "✓ Stack status: ${STACK_STATUS}"
fi

# Fetch CloudFormation outputs
export PRIVATE_SUBNET_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`PrimaryPrivateSubnet`].OutputValue' --output text)
export PUBLIC_SUBNET_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`PublicSubnet`].OutputValue' --output text)
export HEAD_NODE_SECURITY_GROUP=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`HeadNodeSecurityGroup`].OutputValue' --output text)
export COMPUTE_NODE_SECURITY_GROUP=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`ComputeNodeSecurityGroup`].OutputValue' --output text)
export LOGIN_NODE_SECURITY_GROUP=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`LoginNodeSecurityGroup`].OutputValue' --output text)
export FSxORootVolumeId=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`FSxORootVolumeId`].OutputValue' --output text)
export FSxLustreFilesystemId=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`FSxLustreFilesystemId`].OutputValue' --output text)

# Fetch Monitoring Type
export MONITORING_TYPE=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`MonitoringType`].OutputValue' --output text)

# Fetch AMP outputs if MonitoringType uses AMP (amp-only or amp+amg)
if [ "$MONITORING_TYPE" = "amp-only" ] || [ "$MONITORING_TYPE" = "amp+amg" ]; then
    export AMP_WORKSPACE_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`AMPWorkspaceId`].OutputValue' --output text)
    export AMP_ENDPOINT=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`AMPPrometheusEndpoint`].OutputValue' --output text)
    export AMP_REMOTE_WRITE_POLICY_ARN=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`AMPRemoteWritePolicyArn`].OutputValue' --output text)
    export AMP_QUERY_POLICY_ARN=$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} --query 'Stacks[0].Outputs[?OutputKey==`AMPQueryPolicyArn`].OutputValue' --output text)
    echo "✓ AMP configuration detected:"
    echo "  - Workspace ID: ${AMP_WORKSPACE_ID}"
    echo "  - Endpoint: ${AMP_ENDPOINT}"
    echo "  - Remote Write Policy: ${AMP_REMOTE_WRITE_POLICY_ARN}"
fi

echo "✓ CloudFormation outputs fetched successfully"

# ==============================================================================
# USER CONFIGURATION - EDIT THESE VALUES
# ==============================================================================

# ------------------------------------------------------------------------------
# Basic Configuration
# ------------------------------------------------------------------------------
export IMDS_SUPPORT="v2.0"  # IMDSv2 for enhanced security (recommended)
export OS_TYPE="ubuntu2204"  # OS: ubuntu2204, alinux2, centos7, rhel8, rocky8
export SCHEDULER="slurm"  # Scheduler: slurm (only option for ParallelCluster 3.x)
export KEY_PAIR_NAME="your-key-pair"  # ⚠️ CHANGE THIS: Your EC2 SSH key pair name
export CLUSTER_NAME="your-cluster-name"  # ⚠️ CHANGE THIS: Cluster name (used in CloudWatch logs and pcluster commands)

# ⚠️ IMPORTANT: S3 Bucket Configuration
# The entire 'scripts/' folder must be uploaded to S3 for CustomActions to work properly.
# 
# Setup instructions:
#   1. Create S3 bucket (if not exists):
#      aws s3 mb s3://my-pcluster-scripts --region ${AWS_REGION}
#
#   2. Upload all scripts to S3:
#      aws s3 sync scripts/ s3://my-pcluster-scripts/scripts/ --region ${AWS_REGION}
#
#   3. Verify upload:
#      aws s3 ls s3://my-pcluster-scripts/scripts/ --recursive
#
# Expected S3 structure:
#   s3://my-pcluster-scripts/
#   ├── scripts/
#   │   ├── install-efa-latest.sh
#   │   └── cloudwatch/
#   │       ├── install-cloudwatch-agent.sh
#   │       └── cloudwatch-agent-config.json
#
export S3_BUCKET="your-bucket-name"  # ⚠️ CHANGE THIS: Your S3 bucket name

# ------------------------------------------------------------------------------
# HeadNode Configuration
# ------------------------------------------------------------------------------
export HEAD_NODE_INSTANCE_TYPE="m5.8xlarge"  # Instance type: m5.8xlarge (32 vCPU, 128GB RAM) - adjust based on workload
export HEAD_NODE_ROOT_VOLUME_SIZE="500"  # Root volume size in GB (min: 35, recommended: 200-500 for logs/packages)
export HEAD_NODE_ROOT_VOLUME_ENCRYPTED=""  # Optional: true/false - Enable EBS encryption (recommended for compliance)
export HEAD_NODE_ROOT_VOLUME_TYPE=""  # Optional: gp3 (default, best price/performance), gp2, io1, io2
export HEAD_NODE_ROOT_VOLUME_IOPS=""  # Optional: IOPS (io1: 100-64000, io2: 100-256000, gp3: 3000-16000)
export HEAD_NODE_ROOT_VOLUME_THROUGHPUT=""  # Optional: MB/s for gp3 only (125-1000, default: 125)
export HEAD_NODE_ELASTIC_IP=""  # Optional: true/false - Assign static public IP (useful for whitelisting)
export HEAD_NODE_DISABLE_HT=""  # Optional: true/false - Disable hyperthreading (may improve HPC performance)
export HEAD_NODE_CUSTOM_AMI=""  # Optional: ami-xxxxx - Use custom AMI with pre-installed software

# ------------------------------------------------------------------------------
# LoginNode Configuration
# ------------------------------------------------------------------------------
export LOGIN_NODE_POOL_NAME="login-pool"  # Pool name for login nodes
export LOGIN_NODE_COUNT="2"  # Number of login nodes (1-10, use 2+ for HA)
export LOGIN_NODE_INSTANCE_TYPE="m5.large"  # Instance type: m5.large (2 vCPU, 8GB RAM) - sufficient for SSH/monitoring
export LOGIN_NODE_USE_PRIVATE_SUBNET=""  # Optional: true/false - Use private subnet + SSM (more secure than public)
export LOGIN_NODE_SUBNET_ID="${PUBLIC_SUBNET_ID}"  # Subnet ID (auto-set to public, change if using private)
export LOGIN_NODE_KEY_PAIR="${KEY_PAIR_NAME}"  # SSH key pair for login node access
                                                # Note: Since ParallelCluster 3.14+, LoginNodes automatically inherit
                                                # the HeadNode's SSH key if not explicitly specified

# ------------------------------------------------------------------------------
# Compute Queue Configuration
# ------------------------------------------------------------------------------
export QUEUE_NAME="compute-gpu"  # Queue name (used in Slurm: squeue, sbatch -p <queue>)
export CAPACITY_TYPE="ONDEMAND"  # ONDEMAND (stable), SPOT (70% cheaper), CAPACITY_BLOCK (reserved)
export PLACEMENT_GROUP_ENABLED="true"  # Placement group not recommended with Capacity Block (may cause capacity errors)
export JOB_EXCLUSIVE_ALLOCATION="true"  # Allocate entire node per job (recommended for GPU workloads)

# SPOT Configuration (only if CAPACITY_TYPE=SPOT)
export SPOT_ALLOCATION_STRATEGY=""  # Optional: lowest-price (cheapest) or capacity-optimized (less interruption)
export SPOT_PRICE=""  # Optional: Max price in USD/hour (e.g., 0.50) - leave empty for on-demand price

# Capacity Reservation (choose one or leave both empty for on-demand/spot)
export CAPACITY_RESERVATION_ID=""  # ⚠️ Capacity Reservation ID for p5en.48xlarge
export CAPACITY_RESERVATION_GROUP_ARN=""  # Optional: arn:aws:resource-groups:... for CR group

# ------------------------------------------------------------------------------
# ComputeResource Configuration
# ------------------------------------------------------------------------------
export COMPUTE_RESOURCE_NAME="distributed-ml"  # Resource name (identifier for this compute type)
export COMPUTE_INSTANCE_TYPE="m5.large"  # ⚠️ Instance: p5en.48xlarge (8x H100 80GB, 192 vCPU, 2TB RAM)
export MIN_COUNT="2"  # Minimum nodes (Capacity Block requires MinCount > 0 and MinCount = MaxCount)
export MAX_COUNT="2"  # Maximum nodes (must equal MinCount when using Capacity Block)
export EFA_ENABLED="false"  # Enable EFA for 3.2Tbps networking (required for multi-node training)

# Compute Node Storage
export COMPUTE_NODE_ROOT_VOLUME_SIZE="200"  # Root volume in GB (min: 35, recommended: 200+ for containers/datasets)
export COMPUTE_NODE_ROOT_VOLUME_ENCRYPTED=""  # Optional: true/false - EBS encryption (recommended)
export COMPUTE_NODE_ROOT_VOLUME_TYPE=""  # Optional: gp3 (best value), io1/io2 (high IOPS), gp2 (legacy)
export COMPUTE_NODE_ROOT_VOLUME_IOPS=""  # Optional: IOPS (gp3: 3000-16000, io1: 100-64000, io2: 100-256000)
export COMPUTE_NODE_ROOT_VOLUME_THROUGHPUT=""  # Optional: MB/s for gp3 (125-1000, default: 125)
export COMPUTE_NODE_EPHEMERAL_ENCRYPTED=""  # Optional: true/false - Encrypt /scratch ephemeral volume

# Compute Node Advanced Options
export COMPUTE_DISABLE_HT=""  # Optional: true/false - Disable hyperthreading (may improve performance)
export STATIC_NODE_PRIORITY=""  # Optional: 1-10000 - Priority for static nodes (higher = more priority)
export DYNAMIC_NODE_PRIORITY=""  # Optional: 1-10000 - Priority for dynamic nodes
export GPU_HEALTH_CHECK_ENABLED=""  # Optional: true/false - Run GPU health check before job (adds startup time)

# ------------------------------------------------------------------------------
# Slurm Scheduling Configuration
# ------------------------------------------------------------------------------
export SCALEDOWN_IDLETIME="60"  # Minutes before idle nodes terminate (60 = 1 hour, lower = more cost savings)
export QUEUE_UPDATE_STRATEGY="DRAIN"  # DRAIN (finish jobs) or TERMINATE (kill jobs) on config update
export KILL_WAIT="300"  # Seconds to wait before force-killing job (default: 30, increase for cleanup)
export SLURMD_TIMEOUT="600"  # Seconds before marking unresponsive node as DOWN (default: 300)
export UNKILLABLE_STEP_TIMEOUT="120"  # Seconds before force-killing unkillable job step (default: 60)

# Slurm Advanced Options
export ENABLE_MEMORY_BASED_SCHEDULING=""  # Optional: true/false - Schedule based on memory (not just CPU/GPU)
export SLURM_DATABASE_URI=""  # Optional: mysql://user:pass@host:port/db - External slurmdbd for accounting
export CUSTOM_SLURM_SETTINGS_EXTRA=""  # Optional: Additional slurm.conf settings (comma-separated)
export MUNGE_KEY_SECRET_ARN=""  # Optional: arn:aws:secretsmanager:... - Shared munge key for multi-cluster

# ------------------------------------------------------------------------------
# NCCL and EFA Versions
# ------------------------------------------------------------------------------
# Compatibility: NCCL v2.28.7-1 + AWS OFI NCCL v1.17.2-aws + EFA installer latest
# Reference: https://docs.aws.amazon.com/parallelcluster/latest/ug/document_history.html
export NCCL_VERSION="v2.28.7-1"  # NVIDIA NCCL version for multi-GPU communication
export AWS_OFI_NCCL_VERSION="v1.17.2-aws"  # AWS OFI plugin for NCCL over EFA
export EFA_INSTALLER_VERSION="latest"  # EFA driver version (latest recommended, or pin like "1.44.0")

# ------------------------------------------------------------------------------
# CustomActions Enable/Disable (Timeout Prevention)
# ------------------------------------------------------------------------------
# Role-based installation per node type:
# - LoginNode: CloudWatch only (minimal installation)
# - HeadNode: CloudWatch + Prometheus (metrics collection)
# - ComputeNode: Full GPU stack (EFA, NCCL, Docker, DCGM, etc.)

# LoginNode: Basic dev tools + CloudWatch only
export ENABLE_LOGINNODE_SETUP="true"    # LoginNode setup script (~2 min)

# HeadNode: CloudWatch + Prometheus
export ENABLE_HEADNODE_SETUP="true"     # HeadNode setup script (~5 min)

# ComputeNode: Setup configuration
# ⚠️ Choose setup type based on your workload
export COMPUTE_SETUP_TYPE="cpu"         # ComputeNode setup type: "gpu" or "cpu" or "" (disabled)
                                         # "gpu"  : Docker + Pyxis + EFA + DCGM + Node Exporter (~15-20 min)
                                         #          For GPU instances: p5, p4d, g5, g4dn
                                         # "cpu"  : Docker + Pyxis only (~5-10 min)
                                         #          For CPU instances: c5, m5, r5
                                         # ""     : No setup (minimal cluster for testing)

# ------------------------------------------------------------------------------
# Monitoring Configuration
# ------------------------------------------------------------------------------
# Monitoring Type: Automatically fetched from CloudFormation stack
# CloudFormation Output 'MonitoringType' will be used (self-hosting, amp, or none)
# Note: MONITORING_TYPE is already set above from CloudFormation outputs
# Do not override it here unless you want to force a specific value

export ENABLE_MONITORING="true"  # Enable CloudWatch monitoring (recommended)
export DETAILED_MONITORING="false"  # 1-minute metrics (vs 5-minute, slightly higher cost)
export CLOUDWATCH_LOGS_ENABLED="true"  # Send logs to CloudWatch (OS, Slurm, ParallelCluster)
export CLOUDWATCH_DASHBOARDS_ENABLED="true"  # Auto-create CloudWatch dashboards
export CLOUDWATCH_LOGS_RETENTION="7"  # Log retention in days (7, 14, 30, 60, 90, 120, 180, 365, etc.)

# CloudWatch Agent (auto-install)
export ENABLE_CLOUDWATCH_AGENT="true"  # Auto-install CloudWatch Agent on nodes (recommended)
export CLOUDWATCH_POLICY_ARN=""  # Auto-filled by setup-cloudwatch.sh (leave empty)

# ------------------------------------------------------------------------------
# Network Configuration (Optional)
# ------------------------------------------------------------------------------
export HTTP_PROXY_ADDRESS=""  # Optional: http://proxy.example.com:8080 - HTTP proxy for outbound traffic
export HTTPS_PROXY_ADDRESS=""  # Optional: https://proxy.example.com:8080 - HTTPS proxy
export NO_PROXY=""  # Optional: localhost,127.0.0.1,169.254.169.254 - Proxy bypass list

# ------------------------------------------------------------------------------
# NICE DCV Remote Desktop (Optional)
# ------------------------------------------------------------------------------
export DCV_ENABLED=""  # Optional: true/false - Enable NICE DCV for remote desktop (GPU visualization)
export DCV_PORT=""  # Optional: 8443 - DCV server port (default: 8443)
export DCV_ALLOWED_IPS=""  # Optional: 0.0.0.0/0 - CIDR blocks allowed to connect (restrict for security)

# ------------------------------------------------------------------------------
# Directory Service / LDAP (Optional)
# ------------------------------------------------------------------------------
export DIRECTORY_SERVICE_DOMAIN_NAME=""  # Optional: corp.example.com - Active Directory domain
export DIRECTORY_SERVICE_DOMAIN_ADDR=""  # Optional: ldap://dc.example.com - LDAP server address
export DIRECTORY_SERVICE_PASSWORD_SECRET_ARN=""  # Optional: arn:aws:secretsmanager:... - AD password in Secrets Manager
export DIRECTORY_SERVICE_DOMAIN_READ_ONLY_USER=""  # Optional: cn=ReadOnlyUser,ou=Users,dc=corp,dc=example,dc=com
export DIRECTORY_SERVICE_LDAP_TLS_CA_CERT=""  # Optional: /path/to/certificate.pem - LDAP TLS CA certificate
export DIRECTORY_SERVICE_LDAP_TLS_REQ_CERT=""  # Optional: never, allow, try, demand - TLS certificate requirement
export DIRECTORY_SERVICE_LDAP_ACCESS_FILTER=""  # Optional: memberOf=cn=TeamOne,... - LDAP filter for access control

# ------------------------------------------------------------------------------
# Additional Shared Storage (Optional)
# ------------------------------------------------------------------------------
export EBS_VOLUME_ID=""  # Optional: vol-xxxxx - Existing EBS volume ID to attach
export EBS_MOUNT_DIR=""  # Optional: /ebs - Mount point for EBS volume
export EFS_FILE_SYSTEM_ID=""  # Optional: fs-xxxxx - Existing EFS filesystem ID
export EFS_MOUNT_DIR=""  # Optional: /efs - Mount point for EFS (shared across all nodes)

# ==============================================================================
# AUTOMATIC CONFIGURATION PROCESSING - DO NOT EDIT BELOW
# ==============================================================================

# ------------------------------------------------------------------------------
# HeadNode Configuration Processing
# ------------------------------------------------------------------------------
export HEAD_NODE_CUSTOM_AMI_CONFIG=""
[ -n "$HEAD_NODE_CUSTOM_AMI" ] && export HEAD_NODE_CUSTOM_AMI_CONFIG="CustomAmi: ${HEAD_NODE_CUSTOM_AMI}
  "

export HEAD_NODE_DISABLE_HT_CONFIG=""
[ -n "$HEAD_NODE_DISABLE_HT" ] && export HEAD_NODE_DISABLE_HT_CONFIG="DisableSimultaneousMultithreading: ${HEAD_NODE_DISABLE_HT}
  "

export HEAD_NODE_ELASTIC_IP_CONFIG=""
[ -n "$HEAD_NODE_ELASTIC_IP" ] && export HEAD_NODE_ELASTIC_IP_CONFIG="ElasticIp: ${HEAD_NODE_ELASTIC_IP}
    "

export HEAD_NODE_ROOT_VOLUME_ENCRYPTED_CONFIG=""
[ -n "$HEAD_NODE_ROOT_VOLUME_ENCRYPTED" ] && export HEAD_NODE_ROOT_VOLUME_ENCRYPTED_CONFIG="Encrypted: ${HEAD_NODE_ROOT_VOLUME_ENCRYPTED}
      "

export HEAD_NODE_ROOT_VOLUME_TYPE_CONFIG=""
[ -n "$HEAD_NODE_ROOT_VOLUME_TYPE" ] && export HEAD_NODE_ROOT_VOLUME_TYPE_CONFIG="VolumeType: ${HEAD_NODE_ROOT_VOLUME_TYPE}
      "

export HEAD_NODE_ROOT_VOLUME_IOPS_CONFIG=""
[ -n "$HEAD_NODE_ROOT_VOLUME_IOPS" ] && export HEAD_NODE_ROOT_VOLUME_IOPS_CONFIG="Iops: ${HEAD_NODE_ROOT_VOLUME_IOPS}
      "

export HEAD_NODE_ROOT_VOLUME_THROUGHPUT_CONFIG=""
[ -n "$HEAD_NODE_ROOT_VOLUME_THROUGHPUT" ] && export HEAD_NODE_ROOT_VOLUME_THROUGHPUT_CONFIG="Throughput: ${HEAD_NODE_ROOT_VOLUME_THROUGHPUT}
      "

# ------------------------------------------------------------------------------
# ComputeNode Configuration Processing
# ------------------------------------------------------------------------------
export COMPUTE_DISABLE_HT_CONFIG=""
[ -n "$COMPUTE_DISABLE_HT" ] && export COMPUTE_DISABLE_HT_CONFIG="DisableSimultaneousMultithreading: ${COMPUTE_DISABLE_HT}
          "

export COMPUTE_NODE_ROOT_VOLUME_ENCRYPTED_CONFIG=""
[ -n "$COMPUTE_NODE_ROOT_VOLUME_ENCRYPTED" ] && export COMPUTE_NODE_ROOT_VOLUME_ENCRYPTED_CONFIG="Encrypted: ${COMPUTE_NODE_ROOT_VOLUME_ENCRYPTED}
            "

export COMPUTE_NODE_ROOT_VOLUME_TYPE_CONFIG=""
[ -n "$COMPUTE_NODE_ROOT_VOLUME_TYPE" ] && export COMPUTE_NODE_ROOT_VOLUME_TYPE_CONFIG="VolumeType: ${COMPUTE_NODE_ROOT_VOLUME_TYPE}
            "

export COMPUTE_NODE_ROOT_VOLUME_IOPS_CONFIG=""
[ -n "$COMPUTE_NODE_ROOT_VOLUME_IOPS" ] && export COMPUTE_NODE_ROOT_VOLUME_IOPS_CONFIG="Iops: ${COMPUTE_NODE_ROOT_VOLUME_IOPS}
            "

export COMPUTE_NODE_ROOT_VOLUME_THROUGHPUT_CONFIG=""
[ -n "$COMPUTE_NODE_ROOT_VOLUME_THROUGHPUT" ] && export COMPUTE_NODE_ROOT_VOLUME_THROUGHPUT_CONFIG="Throughput: ${COMPUTE_NODE_ROOT_VOLUME_THROUGHPUT}
            "

export COMPUTE_NODE_EPHEMERAL_ENCRYPTED_CONFIG=""
[ -n "$COMPUTE_NODE_EPHEMERAL_ENCRYPTED" ] && export COMPUTE_NODE_EPHEMERAL_ENCRYPTED_CONFIG="Encrypted: ${COMPUTE_NODE_EPHEMERAL_ENCRYPTED}
            "

export SPOT_PRICE_CONFIG=""
[ -n "$SPOT_PRICE" ] && export SPOT_PRICE_CONFIG="SpotPrice: ${SPOT_PRICE}
          "

export STATIC_NODE_PRIORITY_CONFIG=""
[ -n "$STATIC_NODE_PRIORITY" ] && export STATIC_NODE_PRIORITY_CONFIG="StaticNodePriority: ${STATIC_NODE_PRIORITY}
          "

export DYNAMIC_NODE_PRIORITY_CONFIG=""
[ -n "$DYNAMIC_NODE_PRIORITY" ] && export DYNAMIC_NODE_PRIORITY_CONFIG="DynamicNodePriority: ${DYNAMIC_NODE_PRIORITY}
          "

export GPU_HEALTH_CHECK_CONFIG=""
[ -n "$GPU_HEALTH_CHECK_ENABLED" ] && [ "$GPU_HEALTH_CHECK_ENABLED" = "true" ] && export GPU_HEALTH_CHECK_CONFIG="HealthChecks:
            GpuHealthCheck:
              Enabled: ${GPU_HEALTH_CHECK_ENABLED}
          "

# ------------------------------------------------------------------------------
# Network Configuration Processing
# ------------------------------------------------------------------------------
export HTTP_PROXY_CONFIG=""
if [ -n "$HTTP_PROXY_ADDRESS" ] || [ -n "$HTTPS_PROXY_ADDRESS" ]; then
    export HTTP_PROXY_CONFIG="Proxy:
      HttpProxyAddress: ${HTTP_PROXY_ADDRESS}
      HttpsProxyAddress: ${HTTPS_PROXY_ADDRESS}
      NoProxy: ${NO_PROXY}
    "
fi

# ------------------------------------------------------------------------------
# NICE DCV Configuration Processing
# ------------------------------------------------------------------------------
export DCV_CONFIG=""
[ -n "$DCV_ENABLED" ] && [ "$DCV_ENABLED" = "true" ] && export DCV_CONFIG="Dcv:
    Enabled: ${DCV_ENABLED}
    Port: ${DCV_PORT:-8443}
    AllowedIps: ${DCV_ALLOWED_IPS:-0.0.0.0/0}
  "

# ------------------------------------------------------------------------------
# Slurm Configuration Processing
# ------------------------------------------------------------------------------
export ENABLE_MEMORY_BASED_SCHEDULING_CONFIG=""
[ -n "$ENABLE_MEMORY_BASED_SCHEDULING" ] && export ENABLE_MEMORY_BASED_SCHEDULING_CONFIG="EnableMemoryBasedScheduling: ${ENABLE_MEMORY_BASED_SCHEDULING}
    "

export SLURM_DATABASE_CONFIG=""
[ -n "$SLURM_DATABASE_URI" ] && export SLURM_DATABASE_CONFIG="Database:
      Uri: ${SLURM_DATABASE_URI}
    "

export MUNGE_KEY_SECRET_CONFIG=""
[ -n "$MUNGE_KEY_SECRET_ARN" ] && export MUNGE_KEY_SECRET_CONFIG="MungeKeySecretArn: ${MUNGE_KEY_SECRET_ARN}
    "

export CUSTOM_SLURM_SETTINGS_EXTRA_CONFIG=""
[ -n "$CUSTOM_SLURM_SETTINGS_EXTRA" ] && export CUSTOM_SLURM_SETTINGS_EXTRA_CONFIG="- ${CUSTOM_SLURM_SETTINGS_EXTRA}
      "

# ------------------------------------------------------------------------------
# Storage Configuration Processing
# ------------------------------------------------------------------------------
export FSXOPENZFS_STORAGE_CONFIG=""
if [ -n "$FSxORootVolumeId" ] && [ "$FSxORootVolumeId" != "None" ]; then
    export FSXOPENZFS_STORAGE_CONFIG="- Name: HomeDirs
    MountDir: /home
    StorageType: FsxOpenZfs
    FsxOpenZfsSettings:
      VolumeId: ${FSxORootVolumeId}
  "
fi

export EBS_STORAGE_CONFIG=""
if [ -n "$EBS_VOLUME_ID" ] && [ -n "$EBS_MOUNT_DIR" ]; then
    export EBS_STORAGE_CONFIG="- Name: ebs-storage
    MountDir: ${EBS_MOUNT_DIR}
    StorageType: Ebs
    EbsSettings:
      VolumeId: ${EBS_VOLUME_ID}
  "
fi

export EFS_STORAGE_CONFIG=""
if [ -n "$EFS_FILE_SYSTEM_ID" ] && [ -n "$EFS_MOUNT_DIR" ]; then
    export EFS_STORAGE_CONFIG="- Name: efs-storage
    MountDir: ${EFS_MOUNT_DIR}
    StorageType: Efs
    EfsSettings:
      FileSystemId: ${EFS_FILE_SYSTEM_ID}
  "
fi

# ------------------------------------------------------------------------------
# Directory Service Configuration Processing
# ------------------------------------------------------------------------------
export DIRECTORY_SERVICE_CONFIG=""
[ -n "$DIRECTORY_SERVICE_DOMAIN_NAME" ] && export DIRECTORY_SERVICE_CONFIG="DirectoryService:
  DomainName: ${DIRECTORY_SERVICE_DOMAIN_NAME}
  DomainAddr: ${DIRECTORY_SERVICE_DOMAIN_ADDR}
  PasswordSecretArn: ${DIRECTORY_SERVICE_PASSWORD_SECRET_ARN}
  DomainReadOnlyUser: ${DIRECTORY_SERVICE_DOMAIN_READ_ONLY_USER}
  LdapTlsCaCert: ${DIRECTORY_SERVICE_LDAP_TLS_CA_CERT}
  LdapTlsReqCert: ${DIRECTORY_SERVICE_LDAP_TLS_REQ_CERT}
  LdapAccessFilter: ${DIRECTORY_SERVICE_LDAP_ACCESS_FILTER}
"

# ------------------------------------------------------------------------------
# LoginNode CustomActions Processing
# ------------------------------------------------------------------------------
export LOGIN_NODE_CUSTOM_ACTIONS_CONFIG=""
LOGIN_NODE_CUSTOM_ACTIONS=""

# LoginNode Setup (minimal: CloudWatch + basic tools)
if [ -n "$ENABLE_LOGINNODE_SETUP" ] && [ "$ENABLE_LOGINNODE_SETUP" = "true" ]; then
    if [ -z "$S3_BUCKET" ]; then
        echo "⚠️  Warning: ENABLE_LOGINNODE_SETUP=true but S3_BUCKET is not configured"
    else
        LOGIN_NODE_CUSTOM_ACTIONS="${LOGIN_NODE_CUSTOM_ACTIONS}- Script: 's3://${S3_BUCKET}/config/loginnode/setup-loginnode.sh'
              Args:
                - ${CLUSTER_NAME}
                - ${AWS_REGION}
                - ${S3_BUCKET}
                - ${MONITORING_TYPE}
            "
        echo "✓ LoginNode setup enabled (CloudWatch + basic tools)"
    fi
fi

# Export final LoginNode CustomActions config
if [ -n "$LOGIN_NODE_CUSTOM_ACTIONS" ]; then
    export LOGIN_NODE_CUSTOM_ACTIONS_CONFIG="CustomActions:
        OnNodeConfigured:
          Sequence:
            ${LOGIN_NODE_CUSTOM_ACTIONS}"
fi

# ------------------------------------------------------------------------------
# Monitoring Configuration Processing
# ------------------------------------------------------------------------------
export MONITORING_CONFIG=""
if [ -n "$ENABLE_MONITORING" ] && [ "$ENABLE_MONITORING" = "true" ]; then
    export MONITORING_CONFIG="Monitoring:
  DetailedMonitoring: ${DETAILED_MONITORING:-true}
  Logs:
    CloudWatch:
      Enabled: ${CLOUDWATCH_LOGS_ENABLED:-true}
      RetentionInDays: ${CLOUDWATCH_LOGS_RETENTION:-7}
      DeletionPolicy: Delete
  Dashboards:
    CloudWatch:
      Enabled: ${CLOUDWATCH_DASHBOARDS_ENABLED:-true}
"
    echo "✓ CloudWatch monitoring enabled (log retention: ${CLOUDWATCH_LOGS_RETENTION:-7} days)"
fi

# ------------------------------------------------------------------------------
# CloudWatch Agent Configuration Processing
# ------------------------------------------------------------------------------
export CLOUDWATCH_POLICY_CONFIG=""
if [ -n "$CLOUDWATCH_POLICY_ARN" ]; then
    export CLOUDWATCH_POLICY_CONFIG="- Policy: ${CLOUDWATCH_POLICY_ARN}"
    echo "✓ CloudWatch IAM Policy added: ${CLOUDWATCH_POLICY_ARN}"
fi

# ------------------------------------------------------------------------------
# AMP (AWS Managed Prometheus) Configuration Processing
# ------------------------------------------------------------------------------
export AMP_POLICY_CONFIG=""
if [ "$MONITORING_TYPE" = "amp-only" ] || [ "$MONITORING_TYPE" = "amp+amg" ]; then
    if [ -n "$AMP_REMOTE_WRITE_POLICY_ARN" ]; then
        export AMP_POLICY_CONFIG="- Policy: ${AMP_REMOTE_WRITE_POLICY_ARN}"
        echo "✓ AMP IAM Policy configured for HeadNode:"
        echo "  - Policy ARN: ${AMP_REMOTE_WRITE_POLICY_ARN}"
        echo "  - AMP Workspace: ${AMP_WORKSPACE_ID}"
        echo "  - AMP Endpoint: ${AMP_ENDPOINT}"
    else
        echo "⚠️  Warning: MONITORING_TYPE is ${MONITORING_TYPE} but AMP_REMOTE_WRITE_POLICY_ARN is empty"
        echo "   This will cause Prometheus remote_write to fail (403 Forbidden)"
        echo "   Check CloudFormation stack outputs for AMPRemoteWritePolicyArn"
    fi
fi

# ------------------------------------------------------------------------------
# HeadNode CustomActions Processing
# ------------------------------------------------------------------------------
export HEADNODE_CUSTOM_ACTION_CONFIG=""
HEADNODE_CUSTOM_ACTIONS=""

# HeadNode Setup (CloudWatch + Prometheus)
if [ -n "$ENABLE_HEADNODE_SETUP" ] && [ "$ENABLE_HEADNODE_SETUP" = "true" ]; then
    if [ -z "$S3_BUCKET" ]; then
        echo "⚠️  Warning: ENABLE_HEADNODE_SETUP=true but S3_BUCKET is not configured"
    else
        HEADNODE_CUSTOM_ACTIONS="${HEADNODE_CUSTOM_ACTIONS}
        - Script: 's3://${S3_BUCKET}/config/headnode/setup-headnode.sh'
          Args:
            - ${CLUSTER_NAME}
            - ${AWS_REGION}
            - ${S3_BUCKET}
            - ${MONITORING_TYPE}
            - ${AMP_ENDPOINT}"
        echo "✓ HeadNode setup enabled (CloudWatch + Prometheus)"
        if [ "$MONITORING_TYPE" = "amp-only" ] || [ "$MONITORING_TYPE" = "amp+amg" ]; then
            echo "  → AMP remote_write will be configured"
            echo "  → AMP Endpoint: ${AMP_ENDPOINT}"
        fi
    fi
fi

# Export final HeadNode CustomActions config
export HEADNODE_CUSTOM_ACTION_CONFIG="${HEADNODE_CUSTOM_ACTIONS}"

# ------------------------------------------------------------------------------
# ComputeFleet CustomActions Processing
# ------------------------------------------------------------------------------
export CLOUDWATCH_CUSTOM_ACTION_CONFIG=""
COMPUTE_CUSTOM_ACTIONS=""

# ComputeNode Setup
if [ -n "$COMPUTE_SETUP_TYPE" ]; then
    if [ -z "$S3_BUCKET" ]; then
        echo "⚠️  Warning: COMPUTE_SETUP_TYPE='${COMPUTE_SETUP_TYPE}' but S3_BUCKET is not configured"
    else
        COMPUTE_CUSTOM_ACTIONS="${COMPUTE_CUSTOM_ACTIONS}- Script: 's3://${S3_BUCKET}/config/compute/setup-compute-node.sh'
              Args:
                - ${CLUSTER_NAME}
                - ${AWS_REGION}
                - ${S3_BUCKET}
                - ${MONITORING_TYPE}
                - ${COMPUTE_SETUP_TYPE}
            "
        
        if [ "$COMPUTE_SETUP_TYPE" = "gpu" ]; then
            echo "✓ ComputeNode setup enabled: GPU mode"
            echo "  → Docker + Pyxis"
            echo "  → EFA Installer (high-speed networking)"
            echo "  → DCGM Exporter (GPU metrics)"
            echo "  → Node Exporter (system metrics)"
            echo "  → CloudWatch Agent"
        elif [ "$COMPUTE_SETUP_TYPE" = "cpu" ]; then
            echo "✓ ComputeNode setup enabled: CPU mode"
            echo "  → Docker + Pyxis"
            echo "  → CloudWatch Agent"
        else
            echo "⚠️  Warning: Unknown COMPUTE_SETUP_TYPE='${COMPUTE_SETUP_TYPE}'"
            echo "   Valid values: 'gpu', 'cpu', or '' (empty for no setup)"
        fi
    fi
else
    echo "⚠️  ComputeNode CustomActions DISABLED (COMPUTE_SETUP_TYPE is empty)"
    echo "   Cluster will start with minimal configuration (ParallelCluster defaults only)"
fi

# Export final ComputeFleet CustomActions config
if [ -z "${COMPUTE_CUSTOM_ACTIONS}" ]; then
    # If no custom actions, don't include CustomActions section at all
    export COMPUTE_CUSTOM_ACTIONS_CONFIG="# CustomActions disabled for testing"
    echo "⚠️  ComputeNode CustomActions DISABLED"
    echo "   Cluster will start with minimal configuration (ParallelCluster defaults only)"
    echo "   To enable: Set COMPUTE_SETUP_TYPE='gpu' or 'cpu' in environment-variables.sh"
else
    # Include full CustomActions section
    export COMPUTE_CUSTOM_ACTIONS_CONFIG="CustomActions:
        OnNodeConfigured:
          Sequence:
            ${COMPUTE_CUSTOM_ACTIONS}"
fi

# ------------------------------------------------------------------------------
# Tags Configuration Processing
# ------------------------------------------------------------------------------
export TAGS_CONFIG=""

# ------------------------------------------------------------------------------
# Capacity Configuration Processing
# ------------------------------------------------------------------------------
if [ -n "$CAPACITY_RESERVATION_ID" ]; then
    export CAPACITY_TYPE="CAPACITY_BLOCK"
    export CAPACITY_RESERVATION_CONFIG="CapacityReservationTarget:
        CapacityReservationId: ${CAPACITY_RESERVATION_ID}
      "
    export ALLOCATION_STRATEGY_CONFIG=""
    echo "✓ Using Capacity Reservation ID: ${CAPACITY_RESERVATION_ID}"
elif [ -n "$CAPACITY_RESERVATION_GROUP_ARN" ]; then
    export CAPACITY_TYPE="CAPACITY_BLOCK"
    export CAPACITY_RESERVATION_CONFIG="CapacityReservationTarget:
        CapacityReservationResourceGroupArn: ${CAPACITY_RESERVATION_GROUP_ARN}
      "
    export ALLOCATION_STRATEGY_CONFIG=""
    echo "✓ Using Capacity Reservation Resource Group: ${CAPACITY_RESERVATION_GROUP_ARN}"
else
    export CAPACITY_RESERVATION_CONFIG=""
    if [ "$CAPACITY_TYPE" = "SPOT" ]; then
        if [ -n "$SPOT_ALLOCATION_STRATEGY" ]; then
            export ALLOCATION_STRATEGY_CONFIG="AllocationStrategy: ${SPOT_ALLOCATION_STRATEGY}
      "
            echo "✓ Using SPOT instances (strategy: ${SPOT_ALLOCATION_STRATEGY})"
        else
            export ALLOCATION_STRATEGY_CONFIG=""
            echo "✓ Using SPOT instances (default strategy)"
        fi
    else
        export ALLOCATION_STRATEGY_CONFIG=""
        echo "✓ Using ONDEMAND instances"
    fi
fi

# ==============================================================================
# SUMMARY AND NEXT STEPS
# ==============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Environment variables configured successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Next Steps:"
echo ""
echo "   1. Upload all config to S3 (REQUIRED for CustomActions):"
echo "      aws s3 sync config/ s3://${S3_BUCKET}/config/ --region ${AWS_REGION}"
echo ""
echo "   2. Verify config uploaded successfully:"
echo "      aws s3 ls s3://${S3_BUCKET}/config/ --recursive"
echo ""
echo "   3. Verify envsubst is installed:"
echo "      which envsubst || sudo apt-get install -y gettext-base"
echo ""
echo "   4. Generate cluster configuration:"
echo "      envsubst < cluster-config.yaml.template > cluster-config.yaml"
echo ""
echo "   5. Review generated configuration:"
echo "      head -50 cluster-config.yaml"
echo ""
echo "   6. Create cluster:"
echo "      pcluster create-cluster --cluster-name ${CLUSTER_NAME} --cluster-configuration cluster-config.yaml"
echo ""
echo "   7. Monitor cluster creation:"
echo "      pcluster describe-cluster --cluster-name ${CLUSTER_NAME}"
echo ""
