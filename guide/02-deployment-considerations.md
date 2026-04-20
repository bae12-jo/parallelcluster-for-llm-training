# Deployment Considerations Guide

## Timeout Configuration

ParallelCluster uses CloudFormation WaitCondition with timeouts. GPU instances require longer bootstrap times due to EFA and driver installation.

### Recommended Timeout Values

```yaml
DevSettings:
  Timeouts:
    HeadNodeBootstrapTimeout: 3600      # 60 minutes
    ComputeNodeBootstrapTimeout: 2400   # 40 minutes
```

### Why These Values?

**HeadNode (60 minutes)**:
- Actual installation time: ~5 minutes
- NGC container download: 10-20 minutes (background, non-blocking)
- Safety margin: 12× actual time
- HeadNode failure = entire cluster fails (be conservative)

**ComputeNode (40 minutes)**:
- EFA driver installation: 5-10 minutes
- Docker + NVIDIA Toolkit: 3 minutes
- DCGM Exporter: 1 minute
- Node Exporter: 1 minute
- Total actual: 15-20 minutes
- Safety margin: 2× actual time
- ComputeNodes can be retried if needed

### Default ParallelCluster Timeouts

ParallelCluster defaults (often too short):

| Resource | Default | Issue |
|----------|---------|-------|
| HeadNode | 1800s (30 min) | Too short for GPU setup |
| ComputeNode | 1800s (30 min) | Too short for EFA + NVIDIA |

## Bootstrap Timeout Monitoring

### Check for Timeout Issues

```bash
# Review CloudFormation events
aws cloudformation describe-stack-events \
  --stack-name your-cluster \
  --region us-east-2 \
  --query 'StackEvents[?contains(ResourceStatusReason, `timeout`)]'

# Check instance state
aws ec2 describe-instances \
  --filters "Name=tag:aws:cloudformation:stack-name,Values=your-cluster" \
  --region us-east-2 \
  --query 'Reservations[*].Instances[*].{State:State.Name,LaunchTime:LaunchTime}'

# View CloudWatch logs
aws logs tail /aws/parallelcluster/your-cluster \
  --region us-east-2 \
  --since 1h
```

### Signs of Timeout

1. Instance state: `shutting-down` shortly after `running`
2. CloudFormation: `CREATE_FAILED` with "timeout" in reason
3. Logs: Incomplete installation (stops mid-process)
4. Timing: Instance terminates at exactly 30 minutes (default timeout)

## Slurm Timeout Configuration

### SlurmdTimeout

Controls how long Slurm waits for node heartbeat before marking it down:

```yaml
SlurmSettings:
  SlurmdTimeout: 300              # 5 minutes
```

**Recommendations**:
- Development/testing: 300 seconds (5 min)
- Production: 600 seconds (10 min) with robust monitoring
- High-variability environments: 900 seconds (15 min)

### ComputeNodeBootstrapTimeout

Already covered above - set to 2400 seconds (40 minutes) for GPU instances.

### KillWait

Time to allow graceful shutdown before force-kill:

```yaml
SlurmSettings:
  KillWait: 30                    # 30 seconds
```

Typical range: 30-60 seconds.

## ScaledownIdletime

Controls when idle compute nodes are terminated to save costs:

```yaml
ComputeResources:
  - Name: gpu-nodes
    ScaledownIdletime: 300        # 5 minutes idle before termination
```

**Typical Values**:
- Development: 60-300 seconds (1-5 min)
- Production: 600-1800 seconds (10-30 min)
- Guaranteed on-demand: -1 (never scale down)

**Important**: ScaledownIdletime of 0 is valid and means nodes are terminated immediately when no jobs are queued.

## DebugFlags Configuration

Debug flags affect Slurm behavior and should be tuned for production:

```yaml
SlurmSettings:
  SlurmCtldDebugFlags: ''         # Empty for production
```

### Common Debug Flags to Remove

**Power**: Verbose power management logging
- Set in development: `DebugFlags: Power`
- Remove in production: Clean logs

**NO_CONF_HASH**: Disables configuration hash validation
- Set in development: `DebugFlags: Power,NO_CONF_HASH`
- Remove in production: `DebugFlags: Power` (then remove Power later)

**Recommended approach**:
1. Verify ScaledownIdletime=0 works correctly with your workload
2. Remove NO_CONF_HASH debug flag
3. Keep Power flag during initial testing
4. Remove Power flag once stable

## DCGM Image Pull Timing

DCGM container is pulled from NVIDIA Registry. Factor in pull time:

- **First pull**: 2-5 minutes (depends on network)
- **Subsequent pulls** (if updated): 2-5 minutes
- **Cached**: Instant

**Optimization**: Pre-pull DCGM image in custom AMI to avoid bootstrap delay.

## slurm_exporter Build Timing

slurm_exporter must be compiled from source during bootstrap:

- **Build time**: ~10 minutes on HeadNode
- **Dependencies**: Go compiler, build tools, Slurm dev libraries
- **Why long**: Single-threaded compilation, package manager delays

**Optimization**: Pre-build slurm_exporter in custom AMI or use pre-built binary.

## Parallel Installation Best Practices

### Run Long Tasks in Background

```bash
#!/bin/bash
# NGC container download (10-20 min) - runs in background
nohup bash /fsx/scripts/download-ngc-containers.sh > /fsx/logs/ngc-download.log 2>&1 &

# Quick tasks can run in foreground
apt-get update
apt-get install -y build-essential
```

**Why**: Doesn't block cfn-signal. Bootstrap timeout only enforces signal within time limit.

### Use Error Handling

```bash
#!/bin/bash
set +e  # Continue on errors

# Non-critical components can fail gracefully
install_nccl() {
    (
        set +e
        echo "Installing NCCL..."
        bash /fsx/scripts/install-nccl.sh
    ) || echo "NCCL installation failed (non-critical)"
}

install_nccl
```

### Log Progress

```bash
#!/bin/bash
echo "$(date): Starting DCGM installation"
# ... installation ...
echo "$(date): DCGM installation complete"
```

**Why**: Easy to debug timeout issues by checking logs.

## Complete Timeout Configuration Example

```yaml
DevSettings:
  Timeouts:
    HeadNodeBootstrapTimeout: 3600      # 60 minutes
    ComputeNodeBootstrapTimeout: 2400   # 40 minutes

SlurmSettings:
  SlurmdTimeout: 300
  KillWait: 30
  SlurmCtldDebugFlags: ''

ComputeResources:
  - Name: gpu-nodes
    InstanceType: p5en.48xlarge
    Efa:
      Enabled: true
    MinCount: 0
    MaxCount: 8
    DesiredCapacity: 2
    ScaledownIdletime: 300              # 5 minutes
```

## Troubleshooting Timeout Issues

### Timeout Still Occurring?

1. **Check logs**:
   ```bash
   aws logs tail /aws/parallelcluster/CLUSTER_NAME --since 1h
   ```

2. **Identify slow component**:
   - Look for last completed step
   - Check time between log entries

3. **Increase timeout**:
   ```yaml
   DevSettings:
     Timeouts:
       ComputeNodeBootstrapTimeout: 3600  # Increase to 60 min
   ```

4. **Optimize scripts**:
   - Remove unnecessary installations
   - Use pre-built binaries instead of compiling
   - Parallelize independent tasks

### Script Hanging (Not Timeout)?

If script hangs indefinitely:

1. **Add timeouts to commands**:
   ```bash
   timeout 300 apt-get install package  # 5 min timeout
   ```

2. **Check for interactive prompts**:
   ```bash
   apt-get install -y package  # Use -y flag
   ```

3. **Monitor processes**:
   ```bash
   ps aux | grep -E 'apt|yum|docker|nvidia'
   ```

## Related Documentation

- [Instance Type Configuration](01-instance-types.md)
- [Monitoring Self-Hosted](04-monitoring-self-hosted.md)
- [AWS ParallelCluster DevSettings](https://docs.aws.amazon.com/parallelcluster/latest/ug/DevSettings-v3.html)
