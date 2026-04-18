# ParallelCluster Timeout Configuration

## Problem

ComputeNodes were terminating during initialization due to timeout:
- **Symptom**: Nodes start, then immediately go to "shutting-down" state
- **Cause**: Bootstrap timeout too short for p5en.48xlarge with EFA + Docker + DCGM installation
- **Default**: ParallelCluster default timeout is often too short for GPU instances

## Solution

Added `DevSettings.Timeouts` to cluster configuration:

```yaml
DevSettings:
  Timeouts:
    HeadNodeBootstrapTimeout: 3600      # 60 minutes
    ComputeNodeBootstrapTimeout: 2400   # 40 minutes
```

## Timeout Breakdown

### HeadNode (60 minutes)

| Component | Time | Notes |
|-----------|------|-------|
| CloudWatch Agent | ~1 min | System metrics |
| Prometheus | ~2 min | Metrics collection |
| FSx initialization | ~5 sec | Directory structure |
| NGC container download | ~10-20 min | Background, doesn't block |
| **Buffer** | ~35 min | Safety margin |
| **Total** | **60 min** | Conservative |

**Actual time**: ~5 minutes (NGC download is background)
**Timeout**: 60 minutes (12× safety margin)

### ComputeNode (40 minutes)

| Component | Time | Notes |
|-----------|------|-------|
| EFA Driver | ~5-10 min | Most time-consuming |
| Docker + NVIDIA Toolkit | ~3 min | Container runtime |
| Pyxis | ~2 min | Slurm container plugin (optional) |
| CloudWatch Agent | ~1 min | Metrics |
| DCGM Exporter | ~1 min | GPU metrics |
| Node Exporter | ~1 min | System metrics |
| NCCL configuration | ~5 sec | If available in /fsx |
| **Subtotal** | **15-20 min** | Actual installation |
| **Buffer** | ~20 min | Safety margin |
| **Total** | **40 min** | Conservative |

**Actual time**: 15-20 minutes
**Timeout**: 40 minutes (2× safety margin)

## Why These Values?

### HeadNode: 60 minutes (3600 seconds)

**Reasoning**:
- Actual time: ~5 minutes
- NGC download: 10-20 minutes (background, doesn't block cfn-signal)
- Safety margin: 12× actual time
- Allows for network issues, slow downloads, etc.

**Conservative because**:
- HeadNode failure = entire cluster fails
- Better to wait longer than fail early
- NGC download happens in background (doesn't block)

### ComputeNode: 40 minutes (2400 seconds)

**Reasoning**:
- Actual time: 15-20 minutes
- EFA installation is variable (5-10 min depending on network)
- Safety margin: 2× actual time
- p5en.48xlarge is expensive - don't want false failures

**Why not longer?**
- ComputeNodes can be retried (HeadNode can't)
- 40 minutes is reasonable for troubleshooting
- Longer timeout delays failure detection

## Default ParallelCluster Timeouts

ParallelCluster uses CloudFormation WaitCondition with these defaults:

| Resource | Default Timeout | Notes |
|----------|----------------|-------|
| HeadNode | 1800s (30 min) | Often too short |
| ComputeNode | 1800s (30 min) | Too short for GPU instances |
| LoginNode | 1800s (30 min) | Usually sufficient |

**Problem with defaults**:
- GPU instances (p5en.48xlarge) need more time
- EFA installation is slow
- NVIDIA drivers take time
- Network variability

## Timeout Calculation Formula

```
Timeout = (Actual Installation Time × Safety Factor) + Network Buffer

HeadNode:
  Actual: 5 min
  Safety: 12×
  Buffer: 0 (NGC is background)
  Total: 60 min

ComputeNode:
  Actual: 20 min
  Safety: 2×
  Buffer: 0
  Total: 40 min
```

## Monitoring Timeout Issues

### Check if timeout occurred:

```bash
# Check CloudFormation events
aws cloudformation describe-stack-events \
  --stack-name p5en-48xlarge-cluster \
  --region us-east-2 \
  --query 'StackEvents[?contains(ResourceStatusReason, `timeout`) || contains(ResourceStatusReason, `Timeout`)]'

# Check instance state
aws ec2 describe-instances \
  --filters "Name=tag:aws:cloudformation:stack-name,Values=p5en-48xlarge-cluster" \
  --region us-east-2 \
  --query 'Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,LaunchTime:LaunchTime}'

# Check CloudWatch logs
aws logs tail /aws/parallelcluster/p5en-48xlarge-cluster \
  --region us-east-2 \
  --since 1h
```

### Signs of timeout:

1. **Instance state**: `shutting-down` shortly after `running`
2. **CloudFormation**: `CREATE_FAILED` with "timeout" in reason
3. **Logs**: Incomplete installation (stops mid-process)
4. **Timing**: Terminates at exactly 30 minutes (default timeout)

## Adjusting Timeouts

### When to increase:

-  Slow network regions
-  Large instance types (more drivers to install)
-  Custom AMIs with additional software
-  Complex CustomActions scripts

### When to decrease:

- ️ Fast network, small instances
- ️ Minimal CustomActions
- ️ Want faster failure detection

**Recommendation**: Keep conservative values unless you have a specific reason to change.

## Best Practices

### 1. Error Handling in Scripts

All CustomActions scripts use `set +e` to continue on errors:

```bash
#!/bin/bash
set +e  # Don't exit on error

(
    set +e
    echo "Installing component..."
    install_component || echo "️ Installation failed (non-critical)"
) || echo "️ Component setup failed"
```

**Why**: Prevents timeout from script failures

### 2. Background Jobs

Long-running tasks run in background:

```bash
# NGC container download (10-20 min)
nohup bash /fsx/scripts/download-ngc-containers.sh > /fsx/logs/ngc-download.log 2>&1 &
```

**Why**: Doesn't block cfn-signal

### 3. Logging

All scripts log progress:

```bash
echo "Step 1: Installing EFA..."
# ... installation ...
echo " EFA installation complete"
```

**Why**: Easy to debug timeout issues

### 4. Timeout Buffer

Always include safety margin:

```
Timeout = Actual Time × 2 (minimum)
```

**Why**: Network variability, AWS service delays

## Troubleshooting

### Timeout still occurring?

1. **Check logs**:
   ```bash
   aws logs tail /aws/parallelcluster/CLUSTER_NAME --since 1h
   ```

2. **Identify slow component**:
   - Look for last completed step in logs
   - Time between log entries

3. **Increase timeout**:
   ```yaml
   DevSettings:
     Timeouts:
       ComputeNodeBootstrapTimeout: 3600  # Increase to 60 min
   ```

4. **Optimize scripts**:
   - Remove unnecessary installations
   - Use pre-built binaries instead of compiling
   - Parallelize installations

### Script hanging (not timeout)?

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
   # On the instance
   ps aux | grep -E 'apt|yum|docker|nvidia'
   ```

## References

- [ParallelCluster DevSettings](https://docs.aws.amazon.com/parallelcluster/latest/ug/DevSettings-v3.html)
- [CloudFormation WaitCondition](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-waitcondition.html)
- [ParallelCluster Troubleshooting](https://docs.aws.amazon.com/parallelcluster/latest/ug/troubleshooting-v3.html)

## Summary

**Current Configuration**:
-  HeadNode: 60 minutes (12× safety margin)
-  ComputeNode: 40 minutes (2× safety margin)
-  All scripts have error handling
-  Long tasks run in background
-  Comprehensive logging

**Result**: Cluster creation should complete successfully without timeout issues.
