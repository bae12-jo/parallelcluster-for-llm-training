# config/

Utility scripts for optional post-deployment tasks. These are not called by `OnNodeConfigured` — run them manually as needed.

## headnode/

| File | Purpose |
|------|---------|
| `install-nccl-to-fsx.sh` | Build and install NCCL + AWS OFI NCCL to `/fsx` for shared use across compute nodes |
| `download-ngc-containers.sh` | Pre-pull NGC container images to FSx so compute nodes don't pull at job start |
| `disable-kernel-auto-update.sh` | Prevent automatic kernel upgrades that could break the Lustre kernel module |
| `LUSTRE-KERNEL-MODULE-FIX.md` | Troubleshooting guide for Lustre kernel module version mismatch errors |

## nccl/

NCCL performance testing workflow (4 phases) with both bare-metal and container variants.

| File | Purpose |
|------|---------|
| `install-nccl-shared.sh` | Install NCCL to FSx shared storage |
| `install-nccl-tests.sh` | Build nccl-tests binaries |
| `apply-nccl-to-running-nodes.sh` | Apply NCCL env setup to already-running nodes |
| `use-shared-nccl.sh` | Source this to use the FSx-installed NCCL |
| `phase1-baseline*.sbatch` | Single-node baseline (bare-metal and container) |
| `phase2-multinode.sbatch` | Multi-node NCCL AllReduce |
| `phase3-workload*.sbatch` | Workload simulation |
| `phase4-optimization*.sbatch` | Tuning and optimization |
