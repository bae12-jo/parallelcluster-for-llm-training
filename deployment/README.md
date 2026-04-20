# deployment/

Infrastructure templates and sample configurations for deploying the cluster.

## Workflow

```
1. Deploy CloudFormation stack (templates/parallelcluster-infrastructure-template.yaml)
        ↓
2. Fill in environment variables (templates/environment-variables.sh)
        ↓
3. Generate cluster config from template (templates/cluster-config.yaml.template)
        ↓
4. Deploy cluster (pcluster create-cluster)
```

---

## templates/

Ready-to-use templates. Do not hardcode AWS resource IDs here.

| File | Purpose |
|------|---------|
| `parallelcluster-infrastructure-template.yaml` | CloudFormation: VPC, FSx Lustre, SGs, monitoring EC2 + ALB (4 monitoring modes: `self-hosting`, `amp-only`, `amp+amg`, `none`) |
| `cluster-config.yaml.template` | ParallelCluster cluster config — uses `${VAR}` placeholders filled by `environment-variables.sh` + `envsubst` |
| `environment-variables.sh` | Auto-fetches CloudFormation outputs (subnet IDs, SG IDs, etc.) and exports them as shell variables for use with `envsubst` |
| `prometheus.yml` | Prometheus scrape config with EC2 service discovery and `node_name` relabeling |

### Step 1 — Deploy CloudFormation

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)

aws cloudformation create-stack \
  --stack-name my-cluster-infra \
  --template-body file://deployment/templates/parallelcluster-infrastructure-template.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=PrimarySubnetAZ,ParameterValue=us-east-1a \
    ParameterKey=SecondarySubnetAZ,ParameterValue=us-east-1b \
    ParameterKey=MonitoringType,ParameterValue=self-hosting \
    ParameterKey=MonitoringKeyPair,ParameterValue=my-keypair \
    ParameterKey=AllowedIPsForSSH,ParameterValue="${MY_IP}/32" \
    ParameterKey=AllowedIPsForALB,ParameterValue="${MY_IP}/32" \
    ParameterKey=GrafanaAdminPassword,ParameterValue=changeme \
    ParameterKey=S3BucketName,ParameterValue=my-s3-bucket
```

Monitoring type options: `self-hosting` | `amp-only` | `amp+amg` | `none`

### Step 2 — Fill environment variables

Edit `STACK_NAME` in `environment-variables.sh`, then source it:

```bash
# Edit STACK_NAME at the top of the file first
vim deployment/templates/environment-variables.sh

source deployment/templates/environment-variables.sh
```

This auto-fetches subnet IDs, SG IDs, FSx ID, and other outputs from your CloudFormation stack.

### Step 3 — Generate cluster config

```bash
envsubst < deployment/templates/cluster-config.yaml.template > my-cluster-config.yaml
```

Review `my-cluster-config.yaml` and adjust instance types, node counts, or capacity reservation as needed.

### Step 4 — Deploy cluster

```bash
pcluster create-cluster \
  --cluster-name my-cluster \
  --cluster-configuration my-cluster-config.yaml \
  --region us-east-1
```

---

## samples/

Working examples based on real deployments. Use as reference or starting point.

| File | Purpose |
|------|---------|
| `cluster-sample.yaml` | g5.12xlarge on-demand cluster — good for testing and validation |
| `cluster-config-p6b200.yaml` | p6-b200.48xlarge Capacity Block — production p6 setup |
| `build-image-p6b200.yaml` | ParallelCluster build image config for custom p6-b200 AMI |
