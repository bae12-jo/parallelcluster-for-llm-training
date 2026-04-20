#!/bin/bash
# setup-mbridge.sh — Install NeMo container + Megatron-Bridge for DeepSeek-V3 benchmarking
# Run on HeadNode as root (via OnNodeConfigured or manually)
# Usage: bash setup-mbridge.sh [HF_TOKEN]
set -euxo pipefail

HF_TOKEN="${1:-${HF_TOKEN:-}}"
NEMO_IMAGE="nvcr.io/nvidia/nemo:26.02.00"
MBRIDGE_REPO="https://github.com/NVIDIA/Megatron-LM.git"
BENCHMARK_REPO="https://github.com/NVIDIA/dgxc-benchmarking.git"
INSTALL_DIR="/opt/mbridge"
WORKLOAD_DIR="/fsx/mbridge-workload"

echo "=== [1/6] Docker check ==="
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin nvidia-container-toolkit
  systemctl enable --now docker
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi

echo "=== [2/6] Pull NeMo container ==="
docker pull "${NEMO_IMAGE}"

echo "=== [3/6] Clone benchmark repo ==="
mkdir -p "${INSTALL_DIR}"
if [ ! -d "${INSTALL_DIR}/dgxc-benchmarking" ]; then
  git clone --depth=1 "${BENCHMARK_REPO}" "${INSTALL_DIR}/dgxc-benchmarking"
fi

echo "=== [4/6] Setup workload directories ==="
mkdir -p "${WORKLOAD_DIR}"/{experiments,logs,datasets,checkpoints,scripts}

# Copy mbridge scripts from benchmark repo
cp -r "${INSTALL_DIR}/dgxc-benchmarking/deepseek_v3/pretrain/megatron_bridge/"* \
  "${WORKLOAD_DIR}/scripts/"

echo "=== [5/6] Download tokenizer ==="
if [ -n "${HF_TOKEN}" ]; then
  docker run --rm \
    -e HF_TOKEN="${HF_TOKEN}" \
    -v "${WORKLOAD_DIR}/datasets:/datasets" \
    "${NEMO_IMAGE}" bash -c "
      pip install -q huggingface_hub &&
      python3 -c \"
from huggingface_hub import snapshot_download
snapshot_download(
  repo_id='deepseek-ai/DeepSeek-V3',
  local_dir='/datasets/deepseek-v3-tokenizer',
  ignore_patterns=['*.safetensors','*.bin','*.pt'],
  token='${HF_TOKEN}'
)
print('Tokenizer downloaded.')
\"
    "
else
  echo "  [SKIP] HF_TOKEN not set — tokenizer download skipped."
  echo "  Set HF_TOKEN and re-run, or manually place tokenizer at ${WORKLOAD_DIR}/datasets/deepseek-v3-tokenizer"
fi

echo "=== [6/6] Write env config ==="
cat > "${WORKLOAD_DIR}/env.sh" << EOF
export NEMO_IMAGE="${NEMO_IMAGE}"
export LLMB_INSTALL="${INSTALL_DIR}/dgxc-benchmarking"
export LLMB_WORKLOAD="${WORKLOAD_DIR}"
export GPU_TYPE="b200"
export DTYPE="bf16"
export WORKLOAD_DIR="${WORKLOAD_DIR}"
export HF_TOKEN="${HF_TOKEN}"
EOF
chmod 600 "${WORKLOAD_DIR}/env.sh"

echo ""
echo "=== Setup complete ==="
echo "  Install dir : ${INSTALL_DIR}"
echo "  Workload dir: ${WORKLOAD_DIR}"
echo "  Next step   : source ${WORKLOAD_DIR}/env.sh && bash benchmark/run-deepseek-mbridge.sh"
