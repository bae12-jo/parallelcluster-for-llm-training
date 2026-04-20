#!/bin/bash
# run-nccl-tests.sh — NCCL all_reduce + all_to_all benchmark for p6-b200
# Runs inside NeMo container via Slurm (nccl-tests pre-built or auto-built)
# Usage: bash run-nccl-tests.sh [--nodes 2] [--begin-size 1K] [--end-size 8G]
#
# ── p6-b200 EFA v3 Reference ─────────────────────────────────────────────────
#  EFA generation : 3rd gen (EFA v3)
#  Adapters/node  : 32 EFA NICs  (rdmap* devices, ibp* IB ports)
#  Per-adapter BW : 100 Gbps = 12.5 GB/s
#  Total/node     : 32 × 100 Gbps = 3.2 Tbps = 400 GB/s
#  GPU            : 8× NVIDIA B200 (Blackwell)
#  NVLink BW      : 1.8 TB/s bidirectional (intra-node)
#  GPU memory     : 192 GB HBM3e per GPU (1536 GB total/node)
#
#  Theoretical NCCL peaks (N nodes, Ring algorithm):
#    AllReduce  busbw ≈ 2×(N-1)/N × 400 GB/s   (2-node: ~400 GB/s)
#    AllToAll   busbw ≈   (N-1)/N × 400 GB/s   (2-node: ~200 GB/s)
#
#  B200 compute peaks:
#    FP8  : 18.0 PFLOPS/GPU → 144 PFLOPS/node
#    BF16 :  9.0 PFLOPS/GPU →  72 PFLOPS/node
#    FP32 :  1.8 PFLOPS/GPU →  14.4 PFLOPS/node
#
#  Practical NCCL targets (large msg, good tuning):
#    AllReduce  busbw : 250–350 GB/s  (63–88% of 400 GB/s)
#    AllToAll   busbw : 150–200 GB/s  (75–100% of 200 GB/s)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ---- Defaults ----
NODES="${NCCL_NODES:-2}"
GPUS_PER_NODE=8
TOTAL_GPUS=$(( NODES * GPUS_PER_NODE ))
NEMO_IMAGE="${NEMO_IMAGE:-nvcr.io/nvidia/nemo:26.02.00}"
WORKLOAD_DIR="${WORKLOAD_DIR:-/fsx/nccl-tests}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EXP_DIR="${WORKLOAD_DIR}/results/nccl_${NODES}nodes_${TIMESTAMP}"
BEGIN_SIZE="${BEGIN_SIZE:-1K}"    # 1K = 1024 bytes
END_SIZE="${END_SIZE:-8G}"
ITERS=100
WARMUP_ITERS=5
PARTITION="${SLURM_PARTITION:-p6b200}"

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
  case $1 in
    --nodes)       NODES="$2";      TOTAL_GPUS=$(( NODES * GPUS_PER_NODE )); shift 2 ;;
    --begin-size)  BEGIN_SIZE="$2"; shift 2 ;;
    --end-size)    END_SIZE="$2";   shift 2 ;;
    --iters)       ITERS="$2";      shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

mkdir -p "${EXP_DIR}"

# bytes helper: K=1024, M=1048576, G=1073741824
size_to_bytes() {
  local s="${1^^}"
  local num="${s%%[KMG]*}"
  case "${s: -1}" in
    K) echo $(( num * 1024 )) ;;
    M) echo $(( num * 1024 * 1024 )) ;;
    G) echo $(( num * 1024 * 1024 * 1024 )) ;;
    *) echo "${num}" ;;
  esac
}

BEGIN_BYTES=$(size_to_bytes "${BEGIN_SIZE}")
END_BYTES=$(size_to_bytes "${END_SIZE}")

echo "=== NCCL Tests — p6-b200 ==="
echo "  Nodes       : ${NODES}"
echo "  Total GPUs  : ${TOTAL_GPUS}"
echo "  Size range  : ${BEGIN_SIZE} → ${END_SIZE}"
echo "  Iters       : ${ITERS} (warmup: ${WARMUP_ITERS})"
echo "  Output dir  : ${EXP_DIR}"
echo ""

# ---- nccl-tests build script (runs directly on node, no container) ----
cat > "${EXP_DIR}/build-nccl-tests.sh" << 'BUILDEOF'
#!/bin/bash
set -euo pipefail
NCCL_TESTS_DIR="/fsx/nccl-tests/nccl-tests-bin"
if [ -f "${NCCL_TESTS_DIR}/all_reduce_perf" ]; then
  echo "nccl-tests already built at ${NCCL_TESTS_DIR}"
  exit 0
fi
echo "Building nccl-tests directly on node..."
mkdir -p "${NCCL_TESTS_DIR}"

# Find CUDA and NCCL paths on pcluster AMI
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
[ -d "${CUDA_HOME}" ] || CUDA_HOME=$(ls -d /usr/local/cuda-* 2>/dev/null | tail -1)
NCCL_HOME="${NCCL_HOME:-/usr}"
# Check NCCL in common locations
for p in /usr /usr/local /opt/amazon/efa; do
  [ -f "${p}/include/nccl.h" ] && NCCL_HOME="${p}" && break
done
MPI_HOME="${MPI_HOME:-/opt/amazon/efa}"
[ -d "${MPI_HOME}/include/mpi.h" ] || MPI_HOME=$(find /opt /usr -name "mpicc" 2>/dev/null | head -1 | xargs dirname | xargs dirname 2>/dev/null || echo /usr)

echo "  CUDA: ${CUDA_HOME}, NCCL: ${NCCL_HOME}, MPI: ${MPI_HOME}"

cd /tmp
rm -rf nccl-tests-src
git clone --depth=1 https://github.com/NVIDIA/nccl-tests.git nccl-tests-src
cd nccl-tests-src

# Build: try MPI first, fallback to no-MPI
if [ -f "${MPI_HOME}/bin/mpicc" ] || command -v mpicc &>/dev/null; then
  MPI_HOME_USED=$(command -v mpicc | xargs dirname | xargs dirname 2>/dev/null || echo "${MPI_HOME}")
  make MPI=1 MPI_HOME="${MPI_HOME_USED}" \
       CUDA_HOME="${CUDA_HOME}" \
       NCCL_HOME="${NCCL_HOME}" \
       -j$(nproc) 2>&1 | tail -15
else
  echo "  No MPI found, building without MPI (single-node only)"
  make CUDA_HOME="${CUDA_HOME}" NCCL_HOME="${NCCL_HOME}" -j$(nproc) 2>&1 | tail -15
fi

cp build/*_perf "${NCCL_TESTS_DIR}/"
echo "nccl-tests built: $(ls ${NCCL_TESTS_DIR})"
BUILDEOF
chmod +x "${EXP_DIR}/build-nccl-tests.sh"

# ---- EFA + NCCL environment ----
cat > "${EXP_DIR}/nccl-env.sh" << 'ENVEOF'
# Library paths — MPI, EFA, CUDA, NCCL
export LD_LIBRARY_PATH=/opt/amazon/openmpi/lib:/opt/amazon/efa/lib:/usr/local/cuda/lib64:/usr/local/cuda/targets/x86_64-linux/lib:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}
export PATH=/opt/amazon/openmpi/bin:/opt/amazon/efa/bin:/usr/local/cuda/bin:/opt/slurm/bin:${PATH}

# EFA provider
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1
export FI_EFA_FORK_SAFE=1

# NCCL tuning for B200 + EFA
export NCCL_SOCKET_IFNAME=enp71s0   # TCP bootstrap interface (EFA rdmap* used for data)
export NCCL_IB_DISABLE=0           # allow EFA/IB for data transport
export NCCL_NET_GDR_LEVEL=5        # GPU Direct RDMA
export NCCL_CROSS_NIC=1
export NCCL_ALGO=Tree              # Tree for large messages
export NCCL_PROTO=Simple
export NCCL_BUFFSIZE=8388608       # 8MB
export NCCL_P2P_NET_CHUNKSIZE=524288
export NCCL_MIN_NCHANNELS=4

# CUDA/GPU
export CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7
export NCCL_DEBUG=WARN
export NCCL_DEBUG_SUBSYS=INIT,ENV

# MPI settings
export OMPI_MCA_pml=^ucx
export OMPI_MCA_btl=^openib
export OMPI_MCA_mtl=ofi
export OMPI_MCA_osc=ucx
ENVEOF

# ---- Slurm job: all_reduce ----
cat > "${EXP_DIR}/job_all_reduce.sh" << SLURMEOF
#!/bin/bash
#SBATCH --job-name=nccl-all-reduce
#SBATCH --nodes=${NODES}
#SBATCH --ntasks-per-node=${GPUS_PER_NODE}
#SBATCH --gpus-per-node=${GPUS_PER_NODE}
#SBATCH --partition=${PARTITION}
#SBATCH --output=${EXP_DIR}/all_reduce_%j.out
#SBATCH --error=${EXP_DIR}/all_reduce_%j.err
#SBATCH --exclusive
#SBATCH --time=02:00:00

export PATH=/opt/slurm/bin:/opt/amazon/efa/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH
source "${EXP_DIR}/nccl-env.sh"
NCCL_BIN=/fsx/nccl-tests/nccl-tests-bin-nompi

echo "=== NCCL all_reduce_perf ==="
echo "Nodes: \${SLURM_JOB_NUM_NODES}, Tasks: \${SLURM_NTASKS}"
echo "Nodelist: \${SLURM_JOB_NODELIST}"
echo ""

source "${EXP_DIR}/nccl-env.sh"
NCCL_BIN_MPI=/fsx/nccl-tests/nccl-tests-bin

# Build MPI version if not present
if [ ! -f "\${NCCL_BIN_MPI}/all_reduce_perf" ]; then
  echo "Building nccl-tests with MPI..."
  mkdir -p "\${NCCL_BIN_MPI}"
  cd /tmp && rm -rf nccl-tests-src
  git clone --depth=1 https://github.com/NVIDIA/nccl-tests.git nccl-tests-src 2>&1 | tail -2
  cd nccl-tests-src
  make MPI=1 MPI_HOME=/opt/amazon/openmpi \
       CUDA_HOME=/usr/local/cuda NCCL_HOME=/usr \
       -j\$(nproc) 2>&1 | tail -5
  cp build/*_perf "\${NCCL_BIN_MPI}/"
  echo "Build done: \$(ls \${NCCL_BIN_MPI}/)"
fi

# Generate hostfile (1 entry per node, 8 slots each)
HOSTFILE="${EXP_DIR}/hostfile"
scontrol show hostnames \$SLURM_JOB_NODELIST | while read h; do echo "\$h slots=8"; done > \$HOSTFILE
echo "Hostfile:"
cat \$HOSTFILE

su - ubuntu -c "
  export PATH=/opt/amazon/openmpi/bin:/opt/amazon/efa/bin:/usr/local/cuda/bin:/opt/slurm/bin:\$PATH
  export LD_LIBRARY_PATH=/opt/amazon/openmpi/lib:/opt/amazon/efa/lib:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:\$LD_LIBRARY_PATH
  export FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1
  export NCCL_IB_DISABLE=0 NCCL_NET_GDR_LEVEL=5
  export NCCL_SOCKET_IFNAME=enp71s0 NCCL_CROSS_NIC=1
  export NCCL_DEBUG=WARN
  /opt/amazon/openmpi/bin/mpirun \
    --hostfile ${EXP_DIR}/hostfile \
    -np ${TOTAL_GPUS} --map-by ppr:8:node \
    -x PATH -x LD_LIBRARY_PATH \
    -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA \
    -x NCCL_IB_DISABLE -x NCCL_NET_GDR_LEVEL \
    -x NCCL_SOCKET_IFNAME -x NCCL_CROSS_NIC -x NCCL_DEBUG \
    --mca pml ob1 --mca btl ^openib \
    --mca btl_tcp_if_exclude lo,docker0 \
    --bind-to none \
    \${NCCL_BIN_MPI}/all_reduce_perf \
      --minbytes ${BEGIN_BYTES} \
      --maxbytes ${END_BYTES} \
      --stepfactor 2 \
      --iters ${ITERS} \
      --warmup_iters ${WARMUP_ITERS} \
      --check 0 --op sum 2>&1
" | tee "${EXP_DIR}/all_reduce_raw.txt"

echo ""
echo "=== all_reduce complete — parsing results ==="
python3 "${EXP_DIR}/parse-nccl.py" "${EXP_DIR}/all_reduce_raw.txt" \
  "${EXP_DIR}/all_reduce_results.csv" "all_reduce"
SLURMEOF

# ---- Slurm job: all_to_all ----
cat > "${EXP_DIR}/job_all_to_all.sh" << SLURMEOF
#!/bin/bash
#SBATCH --job-name=nccl-all-to-all
#SBATCH --nodes=${NODES}
#SBATCH --ntasks-per-node=${GPUS_PER_NODE}
#SBATCH --gpus-per-node=${GPUS_PER_NODE}
#SBATCH --partition=${PARTITION}
#SBATCH --output=${EXP_DIR}/all_to_all_%j.out
#SBATCH --error=${EXP_DIR}/all_to_all_%j.err
#SBATCH --exclusive
#SBATCH --time=02:00:00

export PATH=/opt/slurm/bin:/opt/amazon/efa/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH
source "${EXP_DIR}/nccl-env.sh"
NCCL_BIN=/fsx/nccl-tests/nccl-tests-bin-nompi

echo "=== NCCL all_to_all_perf ==="
echo "Nodes: \${SLURM_JOB_NUM_NODES}, Tasks: \${SLURM_NTASKS}"
echo ""

source "${EXP_DIR}/nccl-env.sh"
NCCL_BIN_MPI=/fsx/nccl-tests/nccl-tests-bin
HOSTFILE="${EXP_DIR}/hostfile"
[ -f "\$HOSTFILE" ] || scontrol show hostnames \$SLURM_JOB_NODELIST | while read h; do echo "\$h slots=8"; done > \$HOSTFILE

su - ubuntu -c "
  export PATH=/opt/amazon/openmpi/bin:/opt/amazon/efa/bin:/usr/local/cuda/bin:/opt/slurm/bin:\$PATH
  export LD_LIBRARY_PATH=/opt/amazon/openmpi/lib:/opt/amazon/efa/lib:/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu:\$LD_LIBRARY_PATH
  export FI_PROVIDER=efa FI_EFA_USE_DEVICE_RDMA=1
  export NCCL_IB_DISABLE=0 NCCL_NET_GDR_LEVEL=5
  export NCCL_SOCKET_IFNAME=enp71s0 NCCL_CROSS_NIC=1
  export NCCL_DEBUG=WARN
  /opt/amazon/openmpi/bin/mpirun \
    --hostfile ${EXP_DIR}/hostfile \
    -np ${TOTAL_GPUS} --map-by ppr:8:node \
    -x PATH -x LD_LIBRARY_PATH \
    -x FI_PROVIDER -x FI_EFA_USE_DEVICE_RDMA \
    -x NCCL_IB_DISABLE -x NCCL_NET_GDR_LEVEL \
    -x NCCL_SOCKET_IFNAME -x NCCL_CROSS_NIC -x NCCL_DEBUG \
    --mca pml ob1 --mca btl ^openib \
    --mca btl_tcp_if_exclude lo,docker0 \
    --bind-to none \
    \${NCCL_BIN_MPI}/alltoall_perf \
      --minbytes ${BEGIN_BYTES} \
      --maxbytes ${END_BYTES} \
      --stepfactor 2 \
      --iters ${ITERS} \
      --warmup_iters ${WARMUP_ITERS} \
      --check 0 2>&1
" | tee "${EXP_DIR}/all_to_all_raw.txt"

echo ""
echo "=== all_to_all complete — parsing results ==="
python3 "${EXP_DIR}/parse-nccl.py" "${EXP_DIR}/all_to_all_raw.txt" \
  "${EXP_DIR}/all_to_all_results.csv" "all_to_all"
SLURMEOF

# ---- NCCL log parser ----
cat > "${EXP_DIR}/parse-nccl.py" << 'PYEOF'
#!/usr/bin/env python3
"""Parse nccl-tests output → CSV + summary table with p6-b200 efficiency vs theory"""
import sys, re, csv, os
from pathlib import Path

# ── p6-b200 EFA v3 theoretical peaks ──────────────────────────────────────
# 32 EFA adapters × 100 Gbps = 3.2 Tbps = 400 GB/s per node
EFA_BW_PER_NODE_GBs = 400.0   # GB/s unidirectional per node

# Peak busbw by op (N nodes, Ring algo):
#   AllReduce  = 2*(N-1)/N * EFA_BW
#   AllToAll   = (N-1)/N   * EFA_BW
# Read node count from env set by Slurm
N_NODES = int(os.environ.get("SLURM_JOB_NUM_NODES", 2))

THEORY_BUSBW = {
    "all_reduce": 2 * (N_NODES - 1) / N_NODES * EFA_BW_PER_NODE_GBs,
    "all_to_all":     (N_NODES - 1) / N_NODES * EFA_BW_PER_NODE_GBs,
}
# ──────────────────────────────────────────────────────────────────────────

def human_size(b):
    for unit in ['B','KB','MB','GB']:
        if b < 1024: return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} TB"

def parse(log_path, csv_path, op_name):
    lines = Path(log_path).read_text().splitlines()
    rows = []
    header_found = False
    for line in lines:
        line = line.strip()
        if re.match(r'#\s+size\s+count', line):
            header_found = True
            continue
        if not header_found:
            continue
        if line.startswith('#') or not line:
            continue
        parts = line.split()
        if len(parts) < 12:
            continue
        try:
            size_bytes  = int(parts[0])
            oop_time_us = float(parts[5])
            oop_algbw   = float(parts[6])
            oop_busbw   = float(parts[7])
            ip_time_us  = float(parts[-3]) if len(parts) >= 15 else None
            ip_algbw    = float(parts[-2]) if len(parts) >= 15 else None
            ip_busbw    = float(parts[-1]) if len(parts) >= 15 else None
            rows.append({
                'size_bytes':    size_bytes,
                'size_human':    human_size(size_bytes),
                'oop_time_us':   oop_time_us,
                'oop_algbw_GBs': oop_algbw,
                'oop_busbw_GBs': oop_busbw,
                'ip_time_us':    ip_time_us,
                'ip_algbw_GBs':  ip_algbw,
                'ip_busbw_GBs':  ip_busbw,
            })
        except (ValueError, IndexError):
            continue

    if not rows:
        print(f"  [WARN] No rows parsed from {log_path}")
        return

    fields = ['size_bytes','size_human','oop_time_us','oop_algbw_GBs','oop_busbw_GBs',
              'ip_time_us','ip_algbw_GBs','ip_busbw_GBs']
    with open(csv_path, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)

    # Theoretical peak for this operation
    op_key = op_name.lower().replace('-', '_')
    theory = THEORY_BUSBW.get(op_key, EFA_BW_PER_NODE_GBs)

    print(f"\n  === {op_name} Results ({N_NODES} nodes, {len(rows)} sizes) ===")
    print(f"  EFA v3: {N_NODES}×32×100Gbps = {N_NODES}×{EFA_BW_PER_NODE_GBs:.0f} GB/s")
    print(f"  Theory peak busbw ({op_name}): {theory:.1f} GB/s")
    print()
    print(f"  {'Size':>10}  {'OOP BusBW':>12}  {'Efficiency':>11}  {'IP BusBW':>12}  {'IP Eff':>8}")
    print(f"  {'-'*10}  {'-'*12}  {'-'*11}  {'-'*12}  {'-'*8}")
    for r in rows:
        eff = r['oop_busbw_GBs'] / theory * 100 if theory > 0 else 0
        ip_bw  = f"{r['ip_busbw_GBs']:>10.2f}G" if r['ip_busbw_GBs'] else "       N/A"
        ip_eff = f"{r['ip_busbw_GBs']/theory*100:>7.1f}%" if r['ip_busbw_GBs'] else "    N/A"
        print(f"  {r['size_human']:>10}  {r['oop_busbw_GBs']:>11.2f}G  {eff:>10.1f}%  {ip_bw}  {ip_eff}")

    peak     = max(r['oop_busbw_GBs'] for r in rows)
    peak_eff = peak / theory * 100
    peak_sz  = next(r['size_human'] for r in rows if r['oop_busbw_GBs'] == peak)
    print(f"\n  Peak busbw : {peak:.2f} GB/s @ {peak_sz}  ({peak_eff:.1f}% of {theory:.0f} GB/s theory)")
    print(f"  CSV saved  : {csv_path}")

if __name__ == '__main__':
    parse(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else 'nccl')
PYEOF

chmod +x "${EXP_DIR}/job_all_reduce.sh" "${EXP_DIR}/job_all_to_all.sh"

echo "=== Job scripts ready ==="
echo ""
echo "  Run order:"
echo "  1. sbatch ${EXP_DIR}/job_all_reduce.sh"
echo "  2. sbatch --dependency=afterok:<JOB1> ${EXP_DIR}/job_all_to_all.sh"
echo ""
echo "  Or run both sequentially:"
echo "  JID1=\$(/opt/slurm/bin/sbatch ${EXP_DIR}/job_all_reduce.sh | awk '{print \$NF}')"
echo "  /opt/slurm/bin/sbatch --dependency=afterok:\$JID1 ${EXP_DIR}/job_all_to_all.sh"
echo ""
echo "  Monitor: squeue -u \$(whoami) -t all"
echo "  Results: ${EXP_DIR}/"
echo ""

# ---- Auto-submit if on HeadNode (slurm available) ----
if command -v sbatch &>/dev/null || [ -f /opt/slurm/bin/sbatch ]; then
  SBATCH=$(command -v sbatch 2>/dev/null || echo /opt/slurm/bin/sbatch)
  echo "=== Auto-submitting jobs ==="
  JID1=$($SBATCH "${EXP_DIR}/job_all_reduce.sh" | awk '{print $NF}')
  echo "  all_reduce  job: ${JID1}"
  JID2=$($SBATCH --dependency=afterok:${JID1} "${EXP_DIR}/job_all_to_all.sh" | awk '{print $NF}')
  echo "  all_to_all  job: ${JID2} (after ${JID1})"
  echo ""
  echo "  Monitor: $SBATCH -p ${PARTITION} --test-only || squeue -j ${JID1},${JID2}"

  # Save job IDs
  cat > "${EXP_DIR}/job_ids.txt" << EOF
all_reduce=${JID1}
all_to_all=${JID2}
exp_dir=${EXP_DIR}
EOF
  echo "  Job IDs saved: ${EXP_DIR}/job_ids.txt"
fi
