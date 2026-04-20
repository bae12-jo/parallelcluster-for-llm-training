#!/bin/bash
# run-deepseek-mbridge.sh — Run DeepSeek-V3 671B pretrain benchmark via Megatron-Bridge
# Usage: bash run-deepseek-mbridge.sh [--gpus 16] [--dtype bf16|fp8] [--steps 50]
set -euo pipefail

# ---- Defaults ----
TOTAL_GPUS="${JOB_TOTAL_GPUS:-16}"
GPU_TYPE="${GPU_TYPE:-b200}"
DTYPE="${DTYPE:-bf16}"
TRAIN_STEPS="${TRAIN_STEPS:-50}"
WORKLOAD_DIR="${WORKLOAD_DIR:-/fsx/mbridge-workload}"
NEMO_IMAGE="${NEMO_IMAGE:-nvcr.io/nvidia/nemo:26.02.00}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EXP_DIR="${WORKLOAD_DIR}/experiments/deepseek_v3_${DTYPE}_gpus${TOTAL_GPUS}_${TIMESTAMP}"

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
  case $1 in
    --gpus)   TOTAL_GPUS="$2"; shift 2 ;;
    --dtype)  DTYPE="$2";      shift 2 ;;
    --steps)  TRAIN_STEPS="$2";shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

mkdir -p "${EXP_DIR}"/{logs,outputs}

echo "=== DeepSeek-V3 Megatron-Bridge Benchmark ==="
echo "  GPU type    : ${GPU_TYPE}"
echo "  Total GPUs  : ${TOTAL_GPUS}"
echo "  Precision   : ${DTYPE}"
echo "  Steps       : ${TRAIN_STEPS}"
echo "  Output dir  : ${EXP_DIR}"
echo ""

# ---- Generate Slurm job script ----
NODES=$(( TOTAL_GPUS / 8 ))   # p6-b200.48xlarge = 8 GPUs per node
GPUS_PER_NODE=8

cat > "${EXP_DIR}/job.sh" << SLURM
#!/bin/bash
#SBATCH --job-name=deepseek-v3-mbridge
#SBATCH --nodes=${NODES}
#SBATCH --ntasks-per-node=${GPUS_PER_NODE}
#SBATCH --gpus-per-node=${GPUS_PER_NODE}
#SBATCH --output=${EXP_DIR}/outputs/slurm_%j.out
#SBATCH --error=${EXP_DIR}/outputs/slurm_%j.err
#SBATCH --exclusive

source "${WORKLOAD_DIR}/env.sh"

export MASTER_ADDR=\$(scontrol show hostnames \$SLURM_JOB_NODELIST | head -n1)
export MASTER_PORT=6000
export WORLD_SIZE=\${SLURM_NTASKS}
export LOCAL_RANK=\${SLURM_LOCALID}
export RANK=\${SLURM_PROCID}

# Logging per rank
mkdir -p "${EXP_DIR}/logs"
RANK_LOG="${EXP_DIR}/logs/rank_\${SLURM_PROCID}.log"

echo "Node: \$(hostname), Rank: \${RANK}, Local: \${LOCAL_RANK}" | tee "\${RANK_LOG}"

srun --container-image="${NEMO_IMAGE}" \
     --container-mounts="${WORKLOAD_DIR}:${WORKLOAD_DIR},/fsx:/fsx" \
     --no-container-remap-root \
     bash "${WORKLOAD_DIR}/scripts/launch.sh" 2>&1 | tee -a "\${RANK_LOG}"
SLURM

# ---- Set benchmark env overrides ----
cat >> "${EXP_DIR}/job.sh" << ENVEOF

# Override defaults from launch.sh
export GPU_TYPE="${GPU_TYPE}"
export JOB_TOTAL_GPUS="${TOTAL_GPUS}"
export DTYPE="${DTYPE}"
export MAX_STEPS="${TRAIN_STEPS}"
export EXPERIMENT_DIR="${EXP_DIR}"
ENVEOF

echo "=== Submitting Slurm job ==="
SBATCH=$(command -v sbatch || echo /opt/slurm/bin/sbatch)
JOB_ID=$($SBATCH "${EXP_DIR}/job.sh" | awk '{print $NF}')
echo "  Job ID: ${JOB_ID}"
echo "  Monitor: squeue -j ${JOB_ID}"
echo "  Logs:    ${EXP_DIR}/logs/"
echo ""
echo "  Parse results after completion:"
echo "  bash benchmark/parse-results.sh ${EXP_DIR}"
echo "  python3 benchmark/visualize-results.py ${EXP_DIR}"

# Save job metadata
cat > "${EXP_DIR}/metadata.json" << META
{
  "job_id": "${JOB_ID}",
  "timestamp": "${TIMESTAMP}",
  "gpu_type": "${GPU_TYPE}",
  "total_gpus": ${TOTAL_GPUS},
  "dtype": "${DTYPE}",
  "train_steps": ${TRAIN_STEPS},
  "nemo_image": "${NEMO_IMAGE}",
  "exp_dir": "${EXP_DIR}"
}
META

echo "  Metadata: ${EXP_DIR}/metadata.json"
