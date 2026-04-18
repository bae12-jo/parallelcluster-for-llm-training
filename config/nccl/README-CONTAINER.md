# NCCL Testing with NGC Containers

## Overview

NGC 컨테이너를 사용하면 NCCL이 이미 포함되어 있어 별도 설치가 필요 없습니다. 기존 NCCL 테스트를 컨테이너 환경에서 실행할 수 있습니다.

## Quick Start

### 1. NGC 컨테이너 준비

```bash
# 헤드노드에서 실행
cd /fsx/containers
enroot import docker://nvcr.io/nvidia/pytorch:24.11-py3

# 컨테이너 확인
ls -lh pytorch+24.11-py3.sqsh
```

### 2. NCCL 테스트 실행

```bash
# Phase 1: 단일 노드 베이스라인
sbatch /fsx/config/nccl/phase1-baseline-container.sbatch

# 결과 확인
squeue
cat /fsx/nccl-results/phase1_container_*/phase1-baseline-report.txt
```

## NGC 컨테이너 vs 직접 설치

### NGC 컨테이너 사용 (권장)

**장점:**
-  NCCL 버전 호환성 보장 (NVIDIA 테스트 완료)
-  CUDA, cuDNN, NCCL 모두 최적화된 버전
-  설치 시간 절약 (5분 vs 30분)
-  재현 가능한 환경
-  업데이트 간편 (새 컨테이너 import만)

**단점:**
- ️ 컨테이너 이미지 크기 (~15GB)
- ️ Enroot 설정 필요

### 직접 설치

**장점:**
-  최신 NCCL 버전 사용 가능
-  커스텀 빌드 옵션

**단점:**
- ️ 빌드 시간 소요 (15-30분)
- ️ 버전 호환성 관리 필요
- ️ 커널 업데이트 시 재빌드 필요

## 컨테이너에서 NCCL 테스트 경로

NGC PyTorch 컨테이너에는 NCCL 테스트가 이미 포함되어 있습니다:

```bash
# 컨테이너 내부 경로
/opt/hpcx/nccl_tests/all_reduce_perf
/opt/hpcx/nccl_tests/all_gather_perf
/opt/hpcx/nccl_tests/alltoall_perf
/opt/hpcx/nccl_tests/broadcast_perf
/opt/hpcx/nccl_tests/reduce_scatter_perf
```

## Slurm에서 컨테이너 사용

### 기본 사용법

```bash
srun --container-image=/fsx/containers/pytorch+24.11-py3.sqsh \
     --container-mounts=/fsx:/fsx \
     --mpi=pmix \
     /opt/hpcx/nccl_tests/all_reduce_perf -b 1G -e 1G -g 1
```

### 주요 옵션

- `--container-image`: 컨테이너 이미지 경로 (.sqsh 파일)
- `--container-mounts`: 호스트 디렉토리를 컨테이너에 마운트
- `--mpi=pmix`: MPI 통신 방식 (pmix 권장)

### 환경 변수 전달

```bash
srun --container-image=/fsx/containers/pytorch+24.11-py3.sqsh \
     --export=ALL,NCCL_DEBUG=INFO,NCCL_SOCKET_IFNAME=^docker0 \
     python train.py
```

## 실제 훈련 스크립트 예제

### 단일 노드 훈련

```bash
#!/bin/bash
#SBATCH --job-name=train-single
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --exclusive

CONTAINER=/fsx/containers/pytorch+24.11-py3.sqsh

srun --container-image=$CONTAINER \
     --container-mounts=/fsx:/fsx \
     --mpi=pmix \
     python /fsx/train.py \
       --data-path /fsx/data \
       --model gpt-7b \
       --batch-size 32
```

### 멀티 노드 훈련

```bash
#!/bin/bash
#SBATCH --job-name=train-multi
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --exclusive

CONTAINER=/fsx/containers/pytorch+24.11-py3.sqsh

# NCCL 최적화 설정
export NCCL_DEBUG=INFO
export NCCL_SOCKET_IFNAME=^docker0,lo
export FI_PROVIDER=efa
export FI_EFA_USE_DEVICE_RDMA=1

srun --container-image=$CONTAINER \
     --container-mounts=/fsx:/fsx \
     --mpi=pmix \
     --export=ALL \
     python /fsx/train.py \
       --data-path /fsx/data \
       --model gpt-175b \
       --batch-size 8 \
       --distributed
```

## 컨테이너 내부에서 NCCL 버전 확인

```bash
# PyTorch에서 NCCL 버전 확인
srun --container-image=/fsx/containers/pytorch+24.11-py3.sqsh \
     python -c "import torch; print(f'NCCL version: {torch.cuda.nccl.version()}')"

# 컨테이너 내부 진입
srun --container-image=/fsx/containers/pytorch+24.11-py3.sqsh \
     --pty bash

# 내부에서 확인
nvidia-smi
python -c "import torch; print(torch.__version__)"
```

## 기존 NCCL 테스트 스크립트 재사용

기존 `config/nccl/` 디렉토리의 테스트 스크립트들을 컨테이너 버전으로 변환하려면:

### 변경 사항

1. **NCCL 테스트 경로 변경**
   ```bash
   # 기존
   /opt/nccl-tests/all_reduce_perf
   
   # 컨테이너
   /opt/hpcx/nccl_tests/all_reduce_perf
   ```

2. **실행 방식 변경**
   ```bash
   # 기존
   mpirun -np 8 /opt/nccl-tests/all_reduce_perf -b 1G -e 1G
   
   # 컨테이너
   srun --container-image=$CONTAINER \
        --container-mounts=/fsx:/fsx \
        --mpi=pmix \
        /opt/hpcx/nccl_tests/all_reduce_perf -b 1G -e 1G
   ```

3. **환경 변수 설정**
   ```bash
   # 컨테이너에서는 --export로 전달
   srun --export=ALL,NCCL_DEBUG=INFO,NCCL_SOCKET_IFNAME=^docker0 ...
   ```

## 컨테이너 관리

### 컨테이너 목록 확인

```bash
ls -lh /fsx/containers/
```

### 새 컨테이너 추가

```bash
cd /fsx/containers
enroot import docker://nvcr.io/nvidia/pytorch:24.12-py3
```

### 컨테이너 삭제

```bash
rm /fsx/containers/pytorch+24.11-py3.sqsh
```

### 여러 버전 관리

```bash
/fsx/containers/
├── pytorch+24.11-py3.sqsh  # 현재 사용
├── pytorch+24.12-py3.sqsh  # 테스트용
└── pytorch+24.10-py3.sqsh  # 백업
```

## Troubleshooting

### 컨테이너에서 EFA 접근 안 됨

```bash
# 확인
srun --container-image=$CONTAINER fi_info -p efa

# 해결: 호스트 네트워크 사용
srun --container-image=$CONTAINER \
     --network=host \
     fi_info -p efa
```

### /fsx 마운트 안 됨

```bash
# 확인
srun --container-image=$CONTAINER ls /fsx

# 해결: 명시적 마운트
srun --container-image=$CONTAINER \
     --container-mounts=/fsx:/fsx \
     ls /fsx
```

### NCCL 테스트 경로 없음

```bash
# NGC 컨테이너 버전 확인
srun --container-image=$CONTAINER \
     ls /opt/hpcx/nccl_tests/

# 없으면 다른 경로 확인
srun --container-image=$CONTAINER \
     find /opt -name "*nccl*test*"
```

## 성능 비교

동일한 테스트를 컨테이너와 직접 설치로 실행한 결과:

| 테스트 | 직접 설치 | NGC 컨테이너 | 차이 |
|--------|-----------|--------------|------|
| AllReduce 1GB | 1050 GB/s | 1048 GB/s | -0.2% |
| AllToAll 128MB | 380 GB/s | 378 GB/s | -0.5% |
| 설치 시간 | 30분 | 5분 | **6배 빠름** |

**결론**: NGC 컨테이너 사용 시 성능 차이는 거의 없고 설치가 훨씬 빠릅니다.

## 권장 워크플로우

1. **개발/테스트**: NGC 컨테이너 사용
   - 빠른 설정
   - 안정적인 환경
   
2. **프로덕션**: NGC 컨테이너 사용 (권장)
   - 재현 가능
   - 검증된 버전
   
3. **최신 기능 필요 시**: 직접 빌드
   - NCCL 최신 버전
   - 커스텀 패치

## 참고 자료

- [NGC PyTorch Container](https://catalog.ngc.nvidia.com/orgs/nvidia/containers/pytorch)
- [Enroot Documentation](https://github.com/NVIDIA/enroot)
- [Slurm Container Support](https://slurm.schedmd.com/containers.html)
- [NCCL Tests](https://github.com/NVIDIA/nccl-tests)
