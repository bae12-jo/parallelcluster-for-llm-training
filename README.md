# GPU Cluster Monitoring

Self-hosted Prometheus + Grafana monitoring stack for AWS ParallelCluster GPU clusters. Provides 8 pre-built dashboards covering cluster state, GPU performance, EFA network, host system, and statistical outlier detection.

Works with all NVIDIA GPU generations supported by DCGM: A10G, H100, H200, B200, GB200, GB300.

> **Integration note**: This directory is designed to be merged into [parallelcluster-for-llm-training](https://github.com/bae12-jo/parallelcluster-for-llm-training) as a `monitoring/` subdirectory. The CloudFormation template and cluster config can be used standalone or alongside that repo's infrastructure.

## Architecture

```
ParallelCluster nodes                 Monitoring instance (public subnet)
─────────────────────                 ───────────────────────────────────
HeadNode                              t3.medium EC2
  ├── node_exporter   :9100  ────────▶ Prometheus (Docker)  :9090
  └── slurm_exporter  :8080  ────────▶ Grafana   (Docker)   :3000
                                              │
Compute nodes (x N)                    ALB (port 80)
  ├── node_exporter   :9100  ────────▶       │
  └── dcgm-exporter   :9400  ────────▶       ▼
                                       http://<ALB_DNS>
```

Prometheus uses EC2 service discovery (`parallelcluster:cluster-name` / `parallelcluster:node-type` / `slurm:hostname` tags) to auto-detect nodes. No manual target configuration needed.

## Dashboards

| # | Dashboard | Key metrics |
|---|-----------|------------|
| 0 | Unified Overview | All key metrics in one view |
| 1 | Cluster Overview | Node states, GPU temp/clock, EFA errors |
| 2 | Job Queue | Slurm node/CPU/memory allocation over time |
| 3 | Job Overview | Per-job GPU util/memory/power drill-down |
| 4 | GPU Peer Comparison | GPU util/temp/memory/faults per node |
| 5 | EFA & NVLink | Inter-node bandwidth, retransmits, RDMA |
| 6 | Host System | CPU, memory, PSI pressure, storage I/O |
| 7 | Z-Score Outlier Detection | Statistical outliers across nodes |

## Directory Structure

```
infrastructure/
  gpu-cluster-infra.yaml   CloudFormation: VPC, FSx Lustre, SGs, monitoring EC2 + ALB
  prometheus.yml           Prometheus config template (EC2 SD with node_name relabeling)

cluster/
  cluster-config.yaml                 ParallelCluster config template (fill in placeholders)

scripts/
  setup-headnode.sh        OnNodeConfigured: node_exporter + queues slurm_exporter build
  setup-compute-node.sh    OnNodeConfigured: node_exporter (EFA) + DCGM exporter + hostname tag
  install-slurm-exporter.sh  Standalone slurm_exporter build script (also embedded in setup-headnode.sh)
  import-dashboards.sh     Imports all 8 Grafana dashboard JSONs via API
  redeploy.sh              Full redeploy: tear down + rebuild everything

dashboards/
  generate-dashboards.py   Generates all 8 dashboard JSONs (edit here, then regenerate)
  00-overview.json … 07-z-score-outlier.json
```

## Cluster Access

HeadNode is in a **private subnet** — direct SSH is not possible. Use one of the three methods below.

### Method 1 — Two-hop SSH (manual)

```bash
# Step 1: Local → LoginNode
ssh -i /path/to/key.pem ec2-user@<LoginNode_ALB_DNS>

# Step 2: LoginNode → HeadNode (same VPC)
ssh 10.x.x.x   # HeadNode private IP from pcluster describe-cluster
```

### Method 2 — ProxyJump (one command from local)

Add to `~/.ssh/config`:

```
Host p6-login
  HostName <LoginNode_ALB_DNS>
  User ec2-user
  IdentityFile /path/to/key.pem

Host p6-headnode
  HostName <HeadNode_private_IP>
  User ec2-user
  IdentityFile /path/to/key.pem
  ProxyJump p6-login
```

Then connect directly from local:

```bash
ssh p6-headnode
```

### Method 3 — pcluster ssh (requires HeadNode in public subnet)

> **Note**: Only works if HeadNode is in a **public subnet** with a public IP.  
> The default config in this repo places HeadNode in a private subnet, so this method is not available out of the box.

```bash
AWS_PROFILE=<profile> pcluster ssh \
  --cluster-name <cluster-name> \
  --region <region> \
  -i /path/to/key.pem
```

---

## Prerequisites

- AWS CLI configured (`aws configure` or SSO)
- `pcluster` CLI v3.15+: `pip install aws-parallelcluster`
- S3 bucket for scripts and dashboards
- EC2 key pair

## Deployment

### 1. Upload scripts and dashboards to S3

```bash
S3_BUCKET=<YOUR_BUCKET>
aws s3 mb s3://${S3_BUCKET} --region us-east-1   # skip if exists

aws s3 sync scripts/    s3://${S3_BUCKET}/scripts/    --exclude "redeploy.sh"
aws s3 sync dashboards/ s3://${S3_BUCKET}/dashboards/ --exclude "*.py"
```

### 2. Deploy monitoring infrastructure

```bash
aws cloudformation create-stack \
  --region us-east-1 \
  --stack-name gpu-cluster-for-ml \
  --template-body file://infrastructure/gpu-cluster-infra.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=PrimarySubnetAZ,ParameterValue=us-east-1a \
    ParameterKey=SecondarySubnetAZ,ParameterValue=us-east-1b \
    ParameterKey=MonitoringKeyPair,ParameterValue=<YOUR_KEYPAIR> \
    ParameterKey=AllowedIPsForSSH,ParameterValue=<YOUR_IP>/32 \
    ParameterKey=AllowedIPsForALB,ParameterValue=<YOUR_IP>/32 \
    ParameterKey=GrafanaAdminPassword,ParameterValue=<YOUR_PASSWORD> \
    ParameterKey=S3BucketName,ParameterValue=${S3_BUCKET}
```

Stack creation takes ~10 min. Grafana URL is in the `GrafanaURL` output.  
Dashboards are automatically provisioned from S3 during stack creation.

> **First access**: Grafana starts via Docker on the monitoring instance. Allow 2–3 min after stack `CREATE_COMPLETE` before the ALB health check passes and the URL becomes reachable.

### 3. Deploy ParallelCluster

Use the one-liner (handles CFn output lookup + config substitution + cluster creation):

```bash
./scripts/redeploy.sh <GRAFANA_PASSWORD> [CLUSTER_NAME]
```

Or manually fill placeholders in `cluster/cluster-config.yaml` and run:

```bash
pcluster create-cluster --region us-east-1 --cluster-name <NAME> \
  --cluster-configuration cluster/cluster-config-<NAME>.yaml
```

Cluster creation takes ~15-20 min.

### 4. Import dashboards

```bash
./scripts/import-dashboards.sh http://<ALB_DNS> <GRAFANA_PASSWORD>
```

> **Slurm metrics**: `slurm_exporter` builds from source (~10 min) automatically after cluster boot. Slurm metrics appear in Grafana ~10 min after `CREATE_COMPLETE`. No manual action needed.

## What's monitored

| Exporter | Port | Metrics |
|----------|------|---------|
| node_exporter | 9100 | CPU, memory, disk I/O, PSI pressure, EFA counters |
| dcgm-exporter | 9400 | GPU util/temp/power/clock/ECC, NVLink bandwidth |
| slurm_exporter | 8080 | Node states, CPU/memory allocation, job queue |

## Supported GPU instance types

DCGM exporter `4.5.2-4.8.1` supports all architectures below. No instance-specific flags needed.

| Instance | GPU | Architecture |
|----------|-----|-------------|
| g5.12/48xlarge | A10G | Ampere |
| p5.48xlarge | H100 SXM | Hopper |
| p5e/p5en.48xlarge | H200 SXM | Hopper |
| p6-b200.48xlarge | B200 | Blackwell |
| p6-gb200.48xlarge | GB200 | Blackwell (Grace+B200) |
| — | GB300 | Blackwell Ultra (DCGM 4.8.x support confirmed, not yet GA on AWS) |

Change `InstanceType` in the cluster config to switch GPU types. Everything else stays the same.

## Customizing dashboards

Edit `dashboards/generate-dashboards.py` and regenerate:

```bash
python3 dashboards/generate-dashboards.py
./scripts/import-dashboards.sh http://<ALB_DNS> <GRAFANA_PASSWORD>
```

## Integration with parallelcluster-for-llm-training

This repo is designed to merge into `parallelcluster-for-llm-training` as a `monitoring/` subdirectory:

```
parallelcluster-for-llm-training/
├── ... (existing content)
└── monitoring/          ← this repo
    ├── infrastructure/
    ├── cluster/
    ├── scripts/
    └── dashboards/
```

The `OnNodeConfigured` scripts in `scripts/` are referenced from the cluster config's `CustomActions` section. The monitoring CloudFormation stack can be deployed independently of the main infrastructure stack — just supply the VPC/subnet/SG IDs from whichever stack you use.

## Migrating stacks (preserving FSx data)

If you need to tear down and redeploy the infrastructure stack while keeping FSx data (e.g. NeMo images, datasets):

```bash
# 1. Before deleting the stack — change FSx DeletionPolicy to Retain
aws cloudformation get-template \
  --stack-name <STACK_NAME> --region <REGION> \
  --query 'TemplateBody' --output text \
  | sed 's/DeletionPolicy: Delete/DeletionPolicy: Retain/g; s/UpdateReplacePolicy: Delete/UpdateReplacePolicy: Retain/g' \
  > /tmp/retain-fsx.yaml

aws cloudformation update-stack \
  --stack-name <STACK_NAME> --region <REGION> \
  --template-body file:///tmp/retain-fsx.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters ... # use UsePreviousValue=true for all params

# 2. Delete old stack (FSx is retained)
aws cloudformation delete-stack --stack-name <STACK_NAME> --region <REGION>

# 3. Deploy new stack
aws cloudformation deploy ...

# 4. In the new cluster config, reference the existing FSx ID
#    (do NOT create a new FSx — point FsxLustreSettings.FileSystemId to existing fs-xxxx)
```

> **Default behavior**: `DeletionPolicy: Delete` — FSx is destroyed with the stack. This is correct for fresh deployments.

## Compute node naming and monitoring tips

### Do NOT modify pcluster-managed EC2 tags

pcluster uses specific EC2 tags internally to map Slurm nodes to EC2 instances. Modifying these tags will cause pcluster to treat the node as orphaned, terminate it, and launch a replacement — losing all in-memory state including pulled container images.

**Protected tags — never modify:**

| Tag | Purpose |
|-----|---------|
| `slurm:hostname` | Slurm ↔ EC2 instance mapping |
| `parallelcluster:cluster-name` | Cluster ownership |
| `parallelcluster:node-type` | HeadNode / Compute routing |

**Safe to modify:** `Name` tag — only used for display in EC2 console.

### Changing node display names in Grafana

To rename nodes in Grafana dashboards, edit the Prometheus relabeling rules in `infrastructure/gpu-cluster-infra.yaml` — not the EC2 tags.

```yaml
relabel_configs:
  - source_labels: [__meta_ec2_tag_slurm_hostname, __meta_ec2_private_ip]
    regex: "(.+);(.+)"
    replacement: '$1 ($2)'
    target_label: node_name
```

Replace the `replacement` pattern to change how node names appear in dashboards.

## Known issues

- **Profiling metrics** (`DCGM_FI_PROF_*`) require `nv-hostengine` running on the host — not available in Docker-only mode. Basic metrics (clock, temp, util, memory, ECC) work fine.
- **DCGM on hosts without nvidia-container-toolkit** requires `--pid=host -v /usr/lib/x86_64-linux-gnu:/...` — already set in `setup-compute-node.sh`.
- **LoginNode** node_exporter is not monitored (low priority).
- **Stale Prometheus series** after node rename/retag: disappear automatically after ~15 min (TSDB staleness timeout).
