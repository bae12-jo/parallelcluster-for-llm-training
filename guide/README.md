# ParallelCluster Monitoring and Configuration Guides

7 consolidated technical guides covering instance configuration, deployment, monitoring, and security for AWS ParallelCluster GPU instances.

## Guide Files

### 1. 01-instance-types.md (282 lines)
Instance type configuration and component matrix for ParallelCluster.

**Topics**:
- Supported instance types (GPU+EFA, GPU only, CPU)
- Component configuration matrix (Docker, EFA, DCGM, Node Exporter)
- P6-B200 specific requirements (ib_umad, nvlsm, fabricmanager)
- Pre-NVL5 panic root cause and fix
- Custom AMI checklist
- Performance baselines

**Key Content**:
- Configuration via environment variables (COMPUTE_SETUP_TYPE)
- Installation time estimates (15-20 min GPU, 5-10 min CPU)
- EFA bandwidth specs (p5en: 3200 Gbps, p4d: 400 Gbps)

---

### 2. 02-deployment-considerations.md (282 lines)
Cluster deployment timing, timeouts, and bootstrap configuration.

**Topics**:
- Timeout configuration (HeadNode 60 min, ComputeNode 40 min)
- SlurmdTimeout and KillWait settings
- ScaledownIdletime configuration
- DebugFlags (Power, NO_CONF_HASH) cleanup
- DCGM image pull timing
- slurm_exporter build timing (~10 min)

**Key Content**:
- Timeout breakdown by component
- Why timeouts are conservative
- Monitoring timeout issues
- Best practices for parallel installation
- Troubleshooting timeout problems

---

### 3. 03-monitoring-managed.md (375 lines)
AWS Managed Prometheus (AMP) + AWS Managed Grafana (AMG) setup.

**Topics**:
- Architecture (HeadNode Prometheus → AMP → AMG)
- Automated setup (workspace creation, data source configuration)
- Manual setup (SSO prerequisites, user management)
- Deployment steps (4-step process)
- Grafana access methods (web, port forwarding, SSM)
- Available metrics (GPU, system, Slurm)
- Cost estimates (~$100-200/month)

**Key Content**:
- Fully managed monitoring with 150-day retention
- AWS SSO authentication
- Lambda-based automatic data source configuration
- Troubleshooting (access, data sources, metrics)

---

### 4. 04-monitoring-self-hosted.md (448 lines)
Self-hosted Prometheus + Grafana on HeadNode.

**Topics**:
- Architecture (ComputeNode exporters → HeadNode Prometheus → Grafana)
- Exporters (DCGM, Node Exporter, slurm_exporter)
- Prometheus configuration (EC2 SD, node name relabeling)
- Complete Prometheus metrics reference (~50 GPU, ~200 system metrics)
- Useful PromQL queries (distributed training, bottleneck detection)
- Metric retention (15-day default, adjustable)

**Key Content**:
- GPU metrics (utilization, memory, temperature, power, NVLink)
- System metrics (CPU, memory, disk, network, load)
- Multi-node monitoring queries
- Grafana data source configuration
- Troubleshooting missing metrics

---

### 5. 05-efa-monitoring.md (336 lines)
EFA networking and monitoring for inter-node communication.

**Topics**:
- EFA overview (3200 Gbps for p5en, 400 Gbps for p4d)
- Automatic installation and service management
- CloudWatch metrics (rx_bytes_rate, tx_bytes_rate, errors, discards)
- Textfile collector setup for Prometheus
- Key metrics to watch during training
- Baseline performance and performance optimization
- Cost considerations (~$10/month for 4 nodes)

**Key Content**:
- Real-time EFA statistics logging
- Expected utilization during training (87% of max)
- Error tracking (rx_errors, tx_discards should be 0)
- Integration with DCGM and Node Exporter
- CloudWatch dashboard auto-creation

---

### 6. 06-nccl-testing.md (415 lines)
NCCL performance testing and validation (4-phase workflow).

**Topics**:
- NCCL installation timing (10-15 min, not in bootstrap)
- Phase 1: Baseline single-node testing (AllReduce, AllToAll)
- Phase 2: Multi-node scaling validation
- Phase 3: Workload simulation (MoE patterns, expert capacity)
- Phase 4: NCCL parameter optimization
- Environment variables and tuning recommendations

**Key Content**:
- Expected performance baselines (>800 GB/s AllReduce)
- Scaling efficiency calculation (target >90%)
- Expert capacity optimization (64, 128, 256, 512 tokens)
- Dense model settings (GPT, BERT, LLaMA)
- MoE model settings (Switch, GLaM, Mixtral)
- H100 specific optimizations (NVSwitch, GDR)
- Troubleshooting low bandwidth and latency

---

### 7. 07-security.md (439 lines)
Network architecture, access control, and security best practices.

**Topics**:
- Network architecture (public LoginNode, private HeadNode/ComputeNode)
- SSH access control (IP restriction, SSM Session Manager)
- Grafana/Prometheus access (port forwarding, tunneling, VPN)
- Default password changes
- Security group rules (least privilege)
- IAM least privilege configuration
- Monitoring and auditing (CloudTrail, VPC Flow Logs, GuardDuty)
- Incident response procedures

**Key Content**:
- Restrict SSH to specific IP during deployment
- Use SSM for port forwarding (no SSH port exposure)
- Security group inbound rules per node type
- Minimal IAM permissions (read-only S3, CloudWatch)
- Three cluster access methods (two-hop SSH, ProxyJump, SSM)
- Weekly and monthly security audit checklists

---

## Content Summary

- **Total Lines**: 2,577 lines
- **Language**: English only
- **Formatting**: Markdown with headers, code blocks, tables, bullet points
- **Emojis**: None (clean technical content)
- **Source**: Consolidated from 9 remote guide files

## File Structure

All guides use consistent formatting:
- Level 1 header (#) for title
- Level 2 headers (##) for major sections
- Level 3 headers (###) for subsections
- Code blocks with bash/yaml language tags
- Tables for comparison and configuration matrices
- Bullet points for lists and checklists
- Cross-references to related documentation

## Usage

1. Start with **01-instance-types.md** for cluster configuration
2. Review **02-deployment-considerations.md** for timing and bootstrap
3. Choose monitoring approach:
   - **03-monitoring-managed.md** for AWS-managed (AMP+AMG)
   - **04-monitoring-self-hosted.md** for self-hosted (Prometheus+Grafana)
4. Use **05-efa-monitoring.md** for EFA performance validation
5. Follow **06-nccl-testing.md** for multi-node performance testing
6. Implement **07-security.md** best practices throughout

## Quality Assurance

All guides verified for:
- Accurate configuration commands (from remote source)
- Consistent English language (no foreign language content)
- Clean markdown formatting (no emojis)
- Scannable structure (headers, code blocks, tables)
- Complete technical substance (no filler, all load-bearing content)
- Cross-references between guides

## Related Resources

- AWS ParallelCluster Documentation: https://docs.aws.amazon.com/parallelcluster/
- AWS EFA Documentation: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html
- Prometheus Documentation: https://prometheus.io/docs/
- NCCL User Guide: https://docs.nvidia.com/deeplearning/nccl/user-guide/
