# Config Folder Structure Summary

## Overview
The config folder contains both **unified setup scripts** (one per node type) and **standalone utility scripts** for manual operations.

## Unified Setup Scripts (Primary)

These are the main scripts called by ParallelCluster CustomActions:

```
config/
├── loginnode/setup-loginnode.sh        # Login Node: CloudWatch + basic tools
├── headnode/setup-headnode.sh          # Head Node: CloudWatch + Prometheus
├── compute/setup-compute-node.sh       # Compute Node: Full GPU stack
└── monitoring/setup-monitoring-instance.sh  # Reference only (UserData in CloudFormation)
```

### What Each Script Does

#### 1. Login Node (`loginnode/setup-loginnode.sh`)
**Arguments:** `<CLUSTER_NAME> <REGION> <S3_BUCKET> <MONITORING_TYPE>`
-  CloudWatch Agent
-  Basic dev tools (vim, git, htop)
- ⏱️ ~2 minutes

#### 2. Head Node (`headnode/setup-headnode.sh`)
**Arguments:** `<CLUSTER_NAME> <REGION> <S3_BUCKET> <MONITORING_TYPE> <AMP_ENDPOINT>`
-  CloudWatch Agent
-  Prometheus (monitoring type dependent):
  - **self-hosting**: Local storage only
  - **amp-only/amp+amg**: AMP remote_write with SigV4 auth
  - **none**: CloudWatch Agent only
-  EC2 auto-discovery for Compute Node metrics
- ⏱️ ~5 minutes

**Monitoring Type Behavior:**
```bash
# self-hosting: Local Prometheus
Prometheus → Local Storage (port 9090)

# amp-only or amp+amg: AMP remote_write
Prometheus → Local Storage (1h retention) + AMP remote_write

# none: No Prometheus
CloudWatch Agent only
```

#### 3. Compute Node (`compute/setup-compute-node.sh`)
**Arguments:** `<CLUSTER_NAME> <REGION> <S3_BUCKET> <MONITORING_TYPE>`

**Includes everything from EFA installer:**
-  EFA Driver (with GPU detection)
-  NCCL
-  Docker + NVIDIA Container Toolkit
-  Pyxis (Slurm container plugin)
-  CloudWatch Agent
-  DCGM Exporter (port 9400) - GPU metrics
-  Node Exporter (port 9100) - System metrics
- ⏱️ ~15-20 minutes

**GPU Detection Logic:**
```bash
if lspci | grep -i nvidia > /dev/null 2>&1; then
    # Install EFA with GPU support (-g flag)
    ./efa_installer.sh -y -g
else
    # Install basic EFA
    ./efa_installer.sh -y
fi
```

**Metrics Flow:**
```
DCGM Exporter (9400) + Node Exporter (9100)
    ↓
HeadNode Prometheus (EC2 auto-discovery)
    ↓
[self-hosting] Local Storage
[amp-only/amp+amg] AMP remote_write
```

#### 4. Monitoring Instance (CloudFormation UserData)
**Note**: Setup is embedded in `parallelcluster-infrastructure.yaml` UserData, not using the script.
-  Docker + Docker Compose
-  Grafana (port 3000)
-  Prometheus (federation from Head Node)
- ⏱️ ~5 minutes
-  `monitoring/setup-monitoring-instance.sh` is for reference/manual installation only

**Alternative**: Use AWS Managed Grafana (amp+amg) instead of self-hosting

## Standalone Utility Scripts (Secondary)

These can be used independently for manual operations:

### EFA Installer
```
config/efa/install-efa-latest.sh
```
**Purpose**: Standalone EFA installation with GPU detection
**Usage**: Can be called separately or is integrated into compute setup
**Features**:
- GPU instance detection
- Version checking
- Libfabric verification
- EFA device validation

### CloudWatch Configuration
```
config/cloudwatch/
├── cloudwatch-agent-config.json    # Required by all nodes
└── cloudwatch-config.yaml          # Configuration template
```

### NCCL Scripts
```
config/nccl/
├── install-nccl-shared.sh          # Install NCCL to shared storage
├── install-nccl-tests.sh           # Install NCCL test suite
├── use-shared-nccl.sh              # Setup environment for shared NCCL
├── phase1-baseline.sbatch          # Single node baseline test
├── phase2-multinode.sbatch         # Multi-node communication test
├── phase3-workload.sbatch          # Realistic workload test
└── phase4-optimization.sbatch      # Performance optimization test
```

## Usage Patterns

### Pattern 1: Automated Cluster Setup (Recommended)
Use unified scripts via environment-variables.sh:

```bash
# 1. Configure environment variables
vim environment-variables-bailey.sh
# Set: STACK_NAME, KEY_PAIR_NAME, S3_BUCKET, MONITORING_TYPE

# 2. Load environment variables
source environment-variables-bailey.sh

# 3. Upload config to S3
aws s3 sync config/ s3://${S3_BUCKET}/config/ --region ${AWS_REGION}

# 4. Generate cluster config
envsubst < cluster-config.yaml.template > cluster-config.yaml

# 5. Verify IAM policies (important for AMP)
grep -A 10 "HeadNode:" cluster-config.yaml | grep "AdditionalIamPolicies" -A 5

# 6. Create cluster
pcluster create-cluster --cluster-name ${CLUSTER_NAME} \
  --cluster-configuration cluster-config.yaml \
  --region ${AWS_REGION}
```

**Key Points:**
-  All values passed as script arguments (no IAM permissions needed)
-  Monitoring type auto-configured based on infrastructure stack
-  AMP Policy automatically added for amp-only/amp+amg modes
-  Graceful handling of missing S3 config files

### Pattern 2: Manual EFA Installation
Use standalone EFA installer:

```bash
# On any node
bash config/efa/install-efa-latest.sh latest

# Or with specific version
bash config/efa/install-efa-latest.sh 1.44.0
```

### Pattern 3: NCCL Testing
Use NCCL test scripts:

```bash
# Install NCCL to shared storage (on Head Node)
bash config/nccl/install-nccl-shared.sh v2.28.7-1 v1.17.2-aws /fsx

# Run tests (from Login Node)
cd /fsx/nccl
sbatch phase1-baseline.sbatch
sbatch phase2-multinode.sbatch
```

## Relationship Between Scripts

```
Unified Scripts (Automated)          Standalone Scripts (Manual)
─────────────────────────           ────────────────────────────
compute/setup-compute-node.sh  ──┐
                                 ├──> Includes logic from:
                                 │    - efa/install-efa-latest.sh
                                 │    - cloudwatch config
                                 └──> But can also use standalone

headnode/setup-headnode.sh     ──┐
loginnode/setup-loginnode.sh   ─┼──> Use cloudwatch config
compute/setup-compute-node.sh  ──┘    - cloudwatch-agent-config.json

All nodes                      ────> Can use nccl/ scripts
                                     for testing and benchmarking
```

## Key Improvements in Setup Scripts

### Recent Updates (2024-11)

#### 1. Simplified Architecture
-  **Removed**: CloudFormation API calls from scripts
-  **Added**: All values passed as arguments from environment-variables.sh
-  **Result**: No IAM permissions needed for cloudformation:DescribeStacks

#### 2. AMP Integration
-  HeadNode automatically configures AMP remote_write
-  Monitoring type passed as argument (self-hosting, amp-only, amp+amg, none)
-  AMP endpoint passed as argument (no API calls)
-  Fail-fast on configuration errors (prevents resource waste)

#### 3. Error Handling
-  Graceful handling of missing S3 config files
-  Clear error messages with troubleshooting steps
-  Detailed logging of what's installed vs. what's missing

#### 4. Compute Script Features
The compute setup script includes all advanced features:

1. **GPU Detection**: Automatically detects GPU and installs appropriate EFA version
2. **Version Checking**: Shows current EFA version before upgrade
3. **Verification**: Validates installation with multiple checks
4. **Device Validation**: Checks for EFA devices and libfabric
5. **Proper Cleanup**: Removes temporary files
6. **Parallel Installation**: Multiple components install simultaneously

## Files to Remove (Duplicates)

Only these CloudWatch scripts are redundant:
```bash
rm config/cloudwatch/install-cloudwatch-agent.sh
rm config/cloudwatch/setup-cloudwatch.sh
```

Everything else serves a purpose:
- **Unified scripts**: Primary automation
- **EFA installer**: Standalone utility + reference implementation
- **NCCL scripts**: Testing and benchmarking
- **CloudWatch configs**: Required by all nodes

## S3 Upload

Upload everything (minimal overhead):
```bash
aws s3 sync config/ s3://${S3_BUCKET}/config/ \
  --exclude "*.md" \
  --exclude ".DS_Store"
```

Expected size: ~50KB (mostly text scripts)

## Verification

After cluster creation, verify installations:

```bash
# On Compute Node
ssh compute-node-1

# Check EFA
cat /opt/amazon/efa_installed_packages
/opt/amazon/efa/bin/fi_info --version
ls -la /dev/infiniband/

# Check DCGM
systemctl status dcgm-exporter
curl http://localhost:9400/metrics | head

# Check Node Exporter
systemctl status node-exporter
curl http://localhost:9100/metrics | head
```

## Summary

- **4 unified scripts** for automated setup (one per node type)
- **1 standalone EFA installer** for manual operations and reference
- **8 NCCL scripts** for testing and benchmarking
- **2 CloudWatch configs** required by all nodes
- **2 redundant scripts** can be safely removed

Total essential files: ~15 scripts + configs
