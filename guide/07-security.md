# Security Best Practices Guide

## Network Architecture

ParallelCluster uses a layered security model with public, private, and isolated subnets.

| Node | Subnet | Internet Exposure | Public IP | Access Method |
|------|--------|-------------------|-----------|---------------|
| **HeadNode** | Private | None | No | SSH via LoginNode |
| **LoginNode** | Public | Exposed | Yes | SSH (restricted) |
| **ComputeNode** | Private | None | No | SSH via HeadNode |

**Critical**: LoginNode is internet-facing and requires strict access control.

## SSH Access Control (Highest Priority)

### Restrict SSH to Specific IP During Deployment

Get your current IP:

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "Your IP: $MY_IP"
```

Deploy with SSH restricted:

```bash
aws cloudformation create-stack \
  --stack-name parallelcluster-infra \
  --template-body file://parallelcluster-infrastructure.yaml \
  --parameters \
    ParameterKey=PrimarySubnetAZ,ParameterValue=us-east-2a \
    ParameterKey=AllowedIPsForSSH,ParameterValue="${MY_IP}/32" \
  --capabilities CAPABILITY_IAM \
  --region us-east-2
```

### Change SSH IP After Deployment

```bash
# Update to new IP (when IP changes)
NEW_IP=$(curl -s https://checkip.amazonaws.com)

aws cloudformation update-stack \
  --stack-name parallelcluster-infra \
  --use-previous-template \
  --parameters \
    ParameterKey=AllowedIPsForSSH,ParameterValue="${NEW_IP}/32" \
  --region us-east-2
```

### Use Systems Manager Session Manager (More Secure)

Block SSH port entirely and use SSM instead:

```bash
# 1. Block SSH port (remove from security group)
aws ec2 revoke-security-group-ingress \
  --group-id <LoginNode-SG-ID> \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 \
  --region us-east-2

# 2. Connect via SSM (no port 22 needed)
aws ssm start-session --target <LoginNode-Instance-ID>
```

## Grafana/Prometheus Access Control

### Default Configuration (VPC Internal Only)

Grafana (port 3000) and Prometheus (port 9090) are accessible only from within the VPC by default.

### Secure External Access Methods

#### Method 1: SSM Port Forwarding (Recommended)

```bash
# Port forward Grafana
aws ssm start-session \
  --target <LoginNode-Instance-ID> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["443"],"localPortNumber":["8443"]}'

# Access from browser
# https://localhost:8443/grafana/
```

**Advantages**:
- No SSH port exposure
- Encrypted via AWS
- No credentials transmitted

#### Method 2: SSH Tunneling

```bash
# SSH port forwarding
ssh -i your-key.pem -L 8443:localhost:443 ubuntu@<LoginNode-Public-IP>

# Access from browser
# https://localhost:8443/grafana/
```

#### Method 3: VPN or Direct Connect

Connect to VPC via:
- Corporate VPN
- AWS Direct Connect
- Then access via private IP

## Change Default Passwords

### Grafana Default Credentials

**Default login**: `admin / Grafana4PC!`

**Change immediately**:

1. Access Grafana (via SSM port forward or SSH tunnel)
2. Click user icon (bottom left) → Profile
3. Change Password tab → Enter new password
4. Save

**Alternative via CLI**:

```bash
# SSH to LoginNode
ssh -i your-key.pem ubuntu@<LoginNode-IP>

# Change Grafana admin password
docker exec grafana grafana-cli admin reset-admin-password <new-password>
```

### SSH Key Management

```bash
# Set correct SSH key permissions
chmod 400 your-key.pem

# Store key securely
mv your-key.pem ~/.ssh/
ls -la ~/.ssh/

# Never commit keys to Git
echo "*.pem" >> .gitignore
echo "*.key" >> .gitignore
git add .gitignore
git commit -m "Add key files to gitignore"
```

## Security Group Rules (Least Privilege)

### LoginNode (Public)

**Inbound Rules**:

| Protocol | Port | Source | Purpose |
|----------|------|--------|---------|
| SSH | 22 | Restricted IP | SSH access (restricted) |
| HTTP | 80 | VPC internal | Redirect to HTTPS |
| HTTPS | 443 | VPC internal | Grafana, Jupyter |

**Outbound Rules**:
- All traffic to 0.0.0.0/0 (required for package downloads)

### HeadNode (Private)

**Inbound Rules**:

| Protocol | Port | Source | Purpose |
|----------|------|--------|---------|
| SSH | 22 | LoginNode only | SSH access |
| Slurm | 6817 | ComputeNode | Slurm communication |
| Prometheus | 9090 | ComputeNode | Metrics collection |

**Outbound Rules**:
- All traffic to VPC (inter-node communication)
- Restricted outbound to internet (S3, ECR only)

### ComputeNode (Private)

**Inbound Rules**:

| Protocol | Port | Source | Purpose |
|----------|------|--------|---------|
| SSH | 22 | HeadNode | SSH access |
| DCGM | 9400 | HeadNode | GPU metrics |
| Node Export | 9100 | HeadNode | System metrics |
| Slurm | 6817 | HeadNode | Slurm communication |

**Outbound Rules**:
- All traffic to VPC (inter-node communication)
- Restricted outbound to internet (security patches only)

## IAM Least Privilege

### Compute Node IAM Role

ComputeNodes should have minimal permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::cluster-bucket",
        "arn:aws:s3:::cluster-bucket/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": "cloudwatch:PutMetricData",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "logs:PutLogEvents",
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
```

**Restrict to only**:
- S3 read-only (training data, models)
- CloudWatch metrics (monitoring)
- CloudWatch Logs (logging)

### HeadNode IAM Role

HeadNode needs more permissions for cluster management:

```json
{
  "Effect": "Allow",
  "Action": [
    "ec2:DescribeInstances",
    "ec2:DescribeInstanceTypes"
  ],
  "Resource": "*"
}
```

**Restrict to only**:
- EC2 describe (needed for Prometheus discovery)
- S3 read-only (for configurations)
- CloudWatch (metrics and logs)
- No access to: IAM, SecurityGroups, Networking

## Monitoring and Auditing

### Enable CloudTrail

Log all API calls:

```bash
aws cloudtrail create-trail \
  --name pcluster-trail \
  --s3-bucket-name my-cloudtrail-bucket \
  --region us-east-2

# Start logging
aws cloudtrail start-logging --trail-name pcluster-trail
```

### Enable VPC Flow Logs

Log all network traffic:

```bash
aws ec2 create-flow-logs \
  --resource-type VPC \
  --resource-ids <VPC-ID> \
  --traffic-type ALL \
  --log-destination-type cloud-watch-logs \
  --log-group-name /aws/vpc/flowlogs \
  --region us-east-2
```

### Enable GuardDuty

AWS threat detection service:

```bash
aws guardduty create-detector --enable --region us-east-2
```

### Regular Security Audits

**Weekly**:
- [ ] Review SSH access logs
- [ ] Review security group rules
- [ ] Check Grafana access logs
- [ ] Monitor CloudTrail for suspicious activity

**Monthly**:
- [ ] Review IAM permissions
- [ ] Clean up unused resources
- [ ] Apply security patches
- [ ] Rotate credentials/keys
- [ ] Review VPC Flow Logs

## Incident Response

### When Suspicious Activity Detected

1. **Immediately Block SSH Port**

```bash
aws ec2 revoke-security-group-ingress \
  --group-id <LoginNode-SG-ID> \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 \
  --region us-east-2
```

2. **Check CloudTrail Logs**

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=<Instance-ID> \
  --max-results 50 \
  --region us-east-2
```

3. **Isolate Instance**

```bash
# Create isolated security group (no inbound)
aws ec2 create-security-group \
  --group-name isolated \
  --description "Isolated for investigation"

# Apply to compromised instance
aws ec2 modify-instance-attribute \
  --instance-id <Instance-ID> \
  --groups <Isolated-SG-ID>
```

4. **Preserve Evidence**

```bash
# Create AMI snapshot
aws ec2 create-image \
  --instance-id <Instance-ID> \
  --name "incident-$(date +%Y%m%d-%H%M%S)"

# Create EBS snapshot
aws ec2 create-snapshot \
  --volume-id <Volume-ID> \
  --description "Incident investigation"
```

## Cluster Access Methods

### Method 1: Two-Hop SSH

```bash
# Connect to LoginNode
ssh -i /path/to/key.pem ec2-user@<LoginNode_DNS>

# From LoginNode, connect to HeadNode
ssh <HeadNode_private_IP>
```

### Method 2: ProxyJump (Recommended)

Add to `~/.ssh/config`:

```
Host cluster-login
  HostName <LoginNode_DNS>
  User ec2-user
  IdentityFile /path/to/key.pem

Host cluster-headnode
  HostName <HeadNode_private_IP>
  User ec2-user
  IdentityFile /path/to/key.pem
  ProxyJump cluster-login
```

Connect in single command:

```bash
ssh cluster-headnode
```

**Advantages**: No SSH Agent Forwarding (reduces credential exposure)

### Method 3: pcluster ssh

```bash
pcluster ssh \
  --cluster-name <CLUSTER_NAME> \
  --region <REGION> \
  -i /path/to/key.pem
```

Note: Requires HeadNode in public subnet (not recommended).

### Method 4: AWS Systems Manager Session Manager

```bash
# Direct session to LoginNode
aws ssm start-session --target <LoginNode-Instance-ID>

# Then SSH to HeadNode from LoginNode
ssh <HeadNode_private_IP>
```

## Best Practices Summary

| Practice | Priority | Benefit |
|----------|----------|---------|
| Restrict SSH to specific IP | Critical | Prevents unauthorized access |
| Use SSM for port forwarding | Critical | No credential exposure |
| Change default passwords | Critical | Prevents credential compromise |
| Least privilege IAM | High | Limits blast radius of compromise |
| Enable CloudTrail/GuardDuty | High | Detect and respond to attacks |
| VPC Flow Logs | Medium | Forensic analysis |
| Regular security audits | Medium | Identify misconfigurations |
| Incident response plan | Medium | Faster recovery |

## Related Documentation

- [AWS Security Best Practices](https://aws.amazon.com/architecture/security-identity-compliance/)
- [ParallelCluster Security](https://docs.aws.amazon.com/parallelcluster/latest/ug/security.html)
- [AWS Systems Manager](https://docs.aws.amazon.com/systems-manager/)
- [IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
