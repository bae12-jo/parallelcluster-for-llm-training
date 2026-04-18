# AWS ParallelCluster for Distributed Training

> Samples and configurations in this repository are based on p6-b200 instance types.

Self-contained setup for distributed training clusters on AWS ParallelCluster, with automated GPU monitoring, EFA networking, and FSx Lustre storage.

---

## Architecture

```
                         Private Subnet
                    ┌────────────────────┐
LoginNode ──SSH──▶  │  HeadNode (Slurm)  │
(Public)            │  ComputeNodes x N  │
                    │  FSx Lustre /fsx   │
                    └────────────────────┘

                         Public Subnet
                    ┌────────────────────┐
                    │  Monitoring EC2    │ ◀── ALB (HTTP :80)
                    │  Prometheus :9090  │
                    │  Grafana     :3000 │
                    └────────────────────┘
```

- **LoginNode** — user SSH access and job submission (public subnet, IP-restricted)
- **HeadNode** — Slurm scheduler, NFS /home server (private subnet)
- **ComputeNodes** — GPU workloads, auto-scaling, EFA networking (private subnet)
- **Monitoring** — self-hosted Prometheus + Grafana, or AWS Managed Prometheus + Grafana

---

## Directory Structure

```
.
├── parallelcluster-infrastructure.yaml  CloudFormation: VPC, FSx, SGs, monitoring (4 modes)
├── cluster-config.yaml.template         Cluster config template (envsubst-based)
├── cluster-sample.yaml                  Ready-to-use sample based on p6-b200
├── environment-variables.sh             All configurable variables with defaults
│
├── scripts/
│   ├── setup-headnode.sh                OnNodeConfigured: node_exporter + slurm_exporter
│   ├── setup-compute-node.sh            OnNodeConfigured: DCGM exporter + EFA metrics
│   ├── install-slurm-exporter.sh        Standalone slurm_exporter build (Go, ~10 min)
│   ├── import-dashboards.sh             Import Grafana dashboards via API
│   ├── deploy-cluster-stack.sh          Full deploy: CFn stack + pcluster (env-var driven)
│   ├── check-compute-setup.sh           Validate compute node configuration
│   ├── monitor-compute-node-setup.sh    Track compute node bootstrap progress
│   └── upload-monitoring-scripts.sh     Sync scripts to S3
│
├── dashboards/
│   ├── generate-dashboards.py           Regenerate all dashboard JSONs
│   ├── 00-overview.json                 Unified overview
│   ├── 01-cluster-overview.json         Node states, GPU temp/clock
│   ├── 02-job-queue.json                Slurm allocation over time
│   ├── 03-job-overview.json             Per-job GPU drill-down
│   ├── 04-gpu-peer-comparison.json      GPU util/temp/memory per node
│   ├── 05-efa-nvlink.json               Inter-node bandwidth, RDMA
│   ├── 06-host-system.json              CPU, memory, PSI, storage I/O
│   └── 07-z-score-outlier.json          Statistical outlier detection
│
├── guide/                               Detailed documentation (numbered)
│   ├── 01-instance-type-configuration.md
│   ├── 02-timeout-configuration.md
│   ├── 06-amp-amg-setup.md
│   ├── 08-prometheus-metrics.md
│   └── ... (16 guides total, see guide/README.md)
│
├── config/                              Node init scripts and component configs
├── security-best-practices/             Security hardening and access guides
└── img/                                 Architecture diagrams
```

---

## Prerequisites

- AWS CLI v2
- ParallelCluster CLI v3.15+: `pip install aws-parallelcluster`
- An S3 bucket for scripts and dashboards
- An EC2 key pair

---

## Quick Start

### 1. Set environment variables

```bash
export S3_BUCKET=my-pcluster-bucket
export KEY_PAIR=my-ec2-keypair
export GRAFANA_PASS=changeme
export AWS_PROFILE=default    # optional
export REGION=us-east-1       # optional
```

### 2. Upload scripts and dashboards to S3

```bash
aws s3 sync scripts/    s3://${S3_BUCKET}/scripts/    --exclude "deploy-cluster-stack.sh"
aws s3 sync dashboards/ s3://${S3_BUCKET}/dashboards/ --exclude "*.py"
```

### 3. Deploy infrastructure + cluster

`deploy-cluster-stack.sh` handles the full flow in one command:

```bash
./scripts/deploy-cluster-stack.sh
```

Or step by step:

**3a. CloudFormation stack (VPC, FSx, monitoring)**

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)

aws cloudformation create-stack \
  --stack-name gpu-cluster-for-ml \
  --template-body file://parallelcluster-infrastructure.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=PrimarySubnetAZ,ParameterValue=${REGION}a \
    ParameterKey=SecondarySubnetAZ,ParameterValue=${REGION}b \
    ParameterKey=MonitoringType,ParameterValue=self-hosting \
    ParameterKey=MonitoringKeyPair,ParameterValue=${KEY_PAIR} \
    ParameterKey=AllowedIPsForSSH,ParameterValue="${MY_IP}/32" \
    ParameterKey=AllowedIPsForALB,ParameterValue="${MY_IP}/32" \
    ParameterKey=GrafanaAdminPassword,ParameterValue=${GRAFANA_PASS} \
    ParameterKey=S3BucketName,ParameterValue=${S3_BUCKET}
```

Monitoring type options: `self-hosting` | `amp-only` | `amp+amg` | `none`

**3b. Generate cluster config**

```bash
source environment-variables.sh
envsubst < cluster-config.yaml.template > cluster-config-generated.yaml
# or edit cluster-sample.yaml directly and fill in the placeholders
```

**3c. Create cluster**

```bash
pcluster create-cluster \
  --cluster-name my-cluster \
  --cluster-configuration cluster-config-generated.yaml \
  --region ${REGION}
```

### 4. Access Grafana

```bash
aws cloudformation describe-stacks --stack-name gpu-cluster-for-ml \
  --query 'Stacks[0].Outputs[?OutputKey==`GrafanaURL`].OutputValue' --output text
```

Import dashboards:

```bash
./scripts/import-dashboards.sh http://<grafana-url> ${GRAFANA_PASS}
```

> slurm_exporter is built from source at cluster boot (~10 min). Slurm metrics appear in Grafana after the build completes.

---

## Monitoring

### Self-hosted (self-hosting mode)

Deployed automatically when `MonitoringType=self-hosting`:

| Component | Version | Port |
|-----------|---------|------|
| Prometheus | v3.11.2 | 9090 |
| Grafana OSS | v13.0.1 | 3000 (via ALB :80) |
| DCGM Exporter | v4.5.2 | 9400 (compute nodes) |
| node_exporter | v1.11.1 | 9100 (all nodes) |
| slurm_exporter | v1.8.0 | 8080 (head node) |

DCGM Exporter 4.5.2 supports A10G, H100, H200, B200, GB200.

Prometheus uses EC2 service discovery via `parallelcluster:cluster-name` and `slurm:hostname` tags — no manual target configuration needed.

### AWS Managed (amp-only / amp+amg mode)

See [guide/06-amp-amg-setup.md](guide/06-amp-amg-setup.md).

---

## Cluster Access

The HeadNode is in a private subnet. Only the LoginNode is internet-facing.
For connection methods and security recommendations, see [Security Best Practices](security-best-practices/SECURITY.md).

---

## Software Installation on Cluster Nodes

Three approaches for installing GPU software (NCCL, frameworks, etc.):

**Option A: CustomActions (OnNodeConfigured)**
Scripts run automatically at cluster creation. Good for drivers and lightweight installs.
See `scripts/setup-headnode.sh` and `scripts/setup-compute-node.sh`.

**Option B: FSx shared storage**
Pre-install to `/fsx` so all nodes share binaries without re-downloading.
Recommended for NCCL and large framework installations.

**Option C: Containers**
Use NGC containers via Pyxis/Enroot. Fastest iteration for framework changes.

---

## Performance Reference

| Instance | GPU | NVLink BW | EFA BW | Multi-node scaling |
|----------|-----|-----------|--------|-------------------|
| p5.48xlarge | H100 x8 SXM | 900 GB/s | 3.2 Tbps | >90% |
| p5en.48xlarge | H200 x8 SXM | 900 GB/s | 3.2 Tbps | >90% |
| p6-b200.48xlarge | B200 x8 | 1800 GB/s | 3.2 Tbps | >90% |

---

## Troubleshooting

```bash
# Check cluster status
pcluster describe-cluster --cluster-name <NAME> --region <REGION>

# Watch compute node bootstrap
./scripts/monitor-compute-node-setup.sh <CLUSTER_NAME>

# Check CloudFormation events
aws cloudformation describe-stack-events --stack-name gpu-cluster-for-ml \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]'
```

For detailed troubleshooting, see the [guide/](guide/) directory.

---

## Additional Resources

- [AWS ParallelCluster Documentation](https://docs.aws.amazon.com/parallelcluster/)
- [NVIDIA DCGM Documentation](https://docs.nvidia.com/datacenter/dcgm/)
- [EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)

---

## License

MIT License. See [LICENSE](LICENSE) for details.
