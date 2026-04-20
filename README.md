# AWS ParallelCluster for Distributed Training

Self-contained setup for distributed training clusters on AWS ParallelCluster, with automated GPU monitoring, EFA networking, and FSx Lustre storage.

---

## Architecture

![Architecture Diagram](img/architecture.png)

- **LoginNode** — user SSH access and job submission (public subnet, IP-restricted)
- **HeadNode** — Slurm scheduler, NFS /home server (private subnet)
- **ComputeNodes** — GPU workloads, auto-scaling, EFA networking (private subnet)
- **Monitoring** — self-hosted Prometheus + Grafana, or AWS Managed Prometheus + Grafana

---

## Directory Structure

> Samples and configurations in this repository are based on p6-b200 instance types.

```
.
├── deployment/                          Infrastructure and cluster deployment files
│   ├── README.md                        Step-by-step deployment workflow
│   ├── templates/
│   │   ├── parallelcluster-infrastructure-template.yaml  CloudFormation: VPC, FSx, SGs, monitoring (4 modes)
│   │   ├── cluster-config.yaml.template                  Cluster config (envsubst-based, fill with env-vars)
│   │   ├── environment-variables.sh                      Auto-fetches CFn outputs, exports as shell vars
│   │   └── prometheus.yml                                Prometheus config (EC2 SD + node_name relabeling)
│   └── samples/
│       ├── cluster-sample.yaml          g5.12xlarge on-demand sample
│       ├── cluster-config-p6b200.yaml   p6-b200 Capacity Block sample
│       └── build-image-p6b200.yaml      Custom AMI build config for p6-b200
│
├── scripts/
│   ├── setup-headnode.sh                OnNodeConfigured: node_exporter + slurm_exporter
│   ├── setup-compute-node-start.sh      OnNodeStart: ib_umad + nvlsm + fabricmanager (p6-b200)
│   ├── setup-compute-node.sh            OnNodeConfigured: DCGM exporter + EFA metrics
│   ├── install-slurm-exporter.sh        Standalone slurm_exporter build (Go, ~10 min)
│   ├── import-dashboards.sh             Import Grafana dashboards via API
│   ├── deploy-cluster-stack.sh          Full deploy: CFn stack + pcluster (env-var driven)
│   ├── build-p6b200-ami.sh              Build custom AMI with p6-b200 prerequisites
│   ├── check-compute-setup.sh           Validate compute node configuration
│   └── monitor-compute-node-setup.sh    Track compute node bootstrap progress
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
│   └── ... (see guide/README.md)
│
├── config/
│   ├── AMI/                             AMI build guides for p6-b200
│   ├── headnode/                        HeadNode utilities: NCCL-to-FSx, NGC download, kernel update disable
│   └── nccl/                            NCCL test sbatch scripts (phase1–4) + shared install scripts
│
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
export S3_BUCKET=my-cluster-script-bucket
export KEY_PAIR=my-ec2-keypair
export GRAFANA_PASS=changeme
export AWS_PROFILE=default
export REGION=us-east-1
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
  --template-body file://deployment/templates/parallelcluster-infrastructure-template.yaml \
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
source deployment/templates/environment-variables.sh
envsubst < deployment/templates/cluster-config.yaml.template > my-cluster-config.yaml
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

## Dashboards

![Dashboard Sample](dashboards/dashboard-sample.png)

8 pre-built dashboards covering cluster state, GPU performance (DCGM), EFA network, host system, and statistical outlier detection. See [dashboards/](dashboards/) to regenerate or customize.

---

### AWS Managed (amp-only / amp+amg mode)

See [guide/06-amp-amg-setup.md](guide/06-amp-amg-setup.md).

---

## p6-b200 (Blackwell) Support

p6-b200 requires additional setup not included in the standard pcluster AMI. Use the custom AMI build script:

```bash
./scripts/build-p6b200-ami.sh
```

This adds `ib_umad`, `nvlsm`, and `nvidia-fabricmanager` enable — required for NVSwitch fabric initialization on B200. See [config/AMI/](config/AMI/) for details.

For Capacity Block deployments, use `deployment/samples/cluster-config-p6b200.yaml` and `scripts/deploy-p6b200.sh`.

---

## Cluster Access

The HeadNode is in a private subnet. Only the LoginNode is internet-facing.
For connection methods and security recommendations, see [Security Best Practices](security-best-practices/SECURITY.md).

---

## Software Installation on Cluster Nodes

Three approaches for installing GPU software (NCCL, frameworks, etc.) on cluster nodes:

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

| Instance | GPU | NVSwitch BW | EFA BW | GPU Memory |
|----------|-----|-------------|--------|------------|
| p5.48xlarge | H100 x8 SXM | 900 GB/s | 3.2 Tbps | 640 GB HBM3 |
| p5e/p5en.48xlarge | H200 x8 SXM | 900 GB/s | 3.2 Tbps | 1128 GB HBM3e |
| p6-b200.48xlarge | B200 x8 | 900 GB/s | 3.2 Tbps | 1440 GB HBM3e |

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
