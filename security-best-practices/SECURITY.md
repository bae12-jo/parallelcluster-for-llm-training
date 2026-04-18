# Security Best Practices

## Network Architecture Overview

| Node | Subnet | Internet Exposure | Public IP | Access Method |
|------|--------|-------------------|-----------|---------------|
| **HeadNode** | Private | ❌ None | ❌ | SSH via LoginNode |
| **LoginNode** | Public | ⚠️ **Exposed** | ✅ | SSH (IP restriction recommended) |
| **ComputeNode** | Private | ❌ None | ❌ | SSH via HeadNode |

⚠️ **Important**: LoginNode is deployed in a Public Subnet and directly exposed to the internet.

## 1. SSH Access Control (Highest Priority)

### Restrict SSH to Specific IP During Deployment (Recommended)

```bash
# Check your current IP
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "Your IP: $MY_IP"

# Deploy with SSH restricted to specific IP
aws cloudformation create-stack \
  --stack-name parallelcluster-infra \
  --template-body file://parallelcluster-infrastructure.yaml \
  --parameters \
    ParameterKey=PrimarySubnetAZ,ParameterValue=us-east-2a \
    ParameterKey=AllowedIPsForSSH,ParameterValue="${MY_IP}/32" \
  --capabilities CAPABILITY_IAM
```

### Change SSH IP After Deployment

```bash
# Update to new IP
NEW_IP=$(curl -s https://checkip.amazonaws.com)
aws cloudformation update-stack \
  --stack-name parallelcluster-infra \
  --use-previous-template \
  --parameters \
    ParameterKey=PrimarySubnetAZ,UsePreviousValue=true \
    ParameterKey=AllowedIPsForSSH,ParameterValue="${NEW_IP}/32"
```

### Use SSM Session Manager (More Secure)

Block SSH port completely and use SSM only:

```bash
# 1. Block SSH port
aws ec2 revoke-security-group-ingress \
  --group-id <LoginNode-SG-ID> \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0

# 2. Connect via SSM
aws ssm start-session --target <LoginNode-Instance-ID>
```

## 2. Grafana/Prometheus Access Control

### Default Configuration (VPC Internal Only)

Grafana/Prometheus are accessible only from within the VPC (`10.0.0.0/16`, `10.1.0.0/16`) by default.

### Secure External Access Methods

#### Method 1: SSM Port Forwarding (Recommended)

```bash
# Forward Grafana port
aws ssm start-session \
  --target <LoginNode-Instance-ID> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["443"],"localPortNumber":["8443"]}'

# Access from browser
# https://localhost:8443/grafana/
```

#### Method 2: SSH Tunneling

```bash
# SSH port forwarding
ssh -i your-key.pem -L 8443:localhost:443 ubuntu@<LoginNode-Public-IP>

# Access from browser
# https://localhost:8443/grafana/
```

#### Method 3: VPN or Direct Connect

Connect to VPC via corporate VPN or AWS Direct Connect, then access via Private IP

## 3. Change Default Passwords

### Grafana

```
Default Login: admin / Grafana4PC!
```

**Change Immediately:**
1. Access Grafana (via SSM port forwarding or SSH tunnel)
2. Click on user icon (bottom left) → Profile
3. Change Password tab → Enter new password
4. Save

**Alternative via CLI:**
```bash
# SSH to LoginNode
ssh -i your-key.pem ubuntu@<LoginNode-IP>

# Change Grafana admin password
docker exec grafana grafana-cli admin reset-admin-password <new-password>
```

### SSH Keys

```bash
# Set correct SSH key permissions
chmod 400 your-key.pem

# Store key file in secure location
mv your-key.pem ~/.ssh/

# Never commit keys to Git
echo "*.pem" >> .gitignore
echo "*.key" >> .gitignore
```

## 4. Security Group Least Privilege Principle

### Currently Open Ports

**LoginNode (Public):**
- SSH (22): Restricted by `AllowedIPsForSSH` parameter
- HTTP/HTTPS (80, 443): VPC internal only
- Grafana (3000): VPC internal only
- Jupyter (8888-8892): VPC internal only
- TensorBoard (6006-6010): VPC internal only

**HeadNode (Private):**
- SSH (22): From LoginNode only

**ComputeNode (Private):**
- All ports: Between HeadNode and ComputeNode only

## 5. Monitoring and Auditing

### Enable CloudTrail

```bash
# Log API calls with CloudTrail
aws cloudtrail create-trail \
  --name pcluster-trail \
  --s3-bucket-name my-cloudtrail-bucket
```

### Enable VPC Flow Logs

```bash
# Log VPC traffic
aws ec2 create-flow-logs \
  --resource-type VPC \
  --resource-ids <VPC-ID> \
  --traffic-type ALL \
  --log-destination-type cloud-watch-logs \
  --log-group-name /aws/vpc/flowlogs
```

### Enable GuardDuty

```bash
# Threat detection service
aws guardduty create-detector --enable
```

## 6. Regular Security Audits

### Weekly Checklist

- [ ] Review SSH access logs
- [ ] Review security group rules
- [ ] Check Grafana access logs
- [ ] Verify abnormal network traffic

### Monthly Checklist

- [ ] Review IAM permissions
- [ ] Clean up unused resources
- [ ] Apply security patches
- [ ] Change passwords

## 7. Incident Response

### When Suspicious Activity is Detected

1. **Immediately Block SSH Port**
```bash
aws ec2 revoke-security-group-ingress \
  --group-id <LoginNode-SG-ID> \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0
```

2. **Check CloudTrail Logs**
```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=<LoginNode-Instance-ID> \
  --max-results 50
```

3. **Isolate Instance**
```bash
# Block all inbound traffic
aws ec2 modify-instance-attribute \
  --instance-id <LoginNode-Instance-ID> \
  --groups <Isolated-SG-ID>
```

## Additional Resources

- [AWS Security Best Practices](https://aws.amazon.com/architecture/security-identity-compliance/)
- [ParallelCluster Security](https://docs.aws.amazon.com/parallelcluster/latest/ug/security.html)
- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)

---

## Cluster Access Methods

The HeadNode is in a private subnet and cannot be reached directly.
Only the LoginNode is internet-facing (via ALB or public IP).

### Method 1: Two-hop SSH

```bash
# Step 1: connect to LoginNode
ssh -i /path/to/key.pem ec2-user@<LoginNode_DNS>

# Step 2: from LoginNode, connect to HeadNode
ssh <HeadNode_private_IP>
```

### Method 2: ProxyJump (recommended)

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

Then connect in a single command:

```bash
ssh cluster-headnode
```

### Method 3: pcluster ssh

```bash
pcluster ssh --cluster-name <CLUSTER_NAME> --region <REGION> -i /path/to/key.pem
```

Note: requires the HeadNode to be in a public subnet. The default configuration in this repository uses a private subnet, so Method 1 or Method 2 is recommended.

### Security notes

- Only the LoginNode is internet-facing. HeadNode and ComputeNodes are in private subnets and have no direct inbound access from the internet.
- ProxyJump does not require SSH Agent Forwarding, which reduces credential exposure.
- Restrict SSH access by setting `AllowedIPsForSSH` in the CloudFormation stack parameters to your IP or corporate CIDR.
