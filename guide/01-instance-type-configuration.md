# 인스턴스 타입별 설정 가이드

ParallelCluster에서 다양한 인스턴스 타입을 사용할 때 필요한 컴포넌트를 선택적으로 설정하는 방법입니다.

##  목차

- [인스턴스 타입별 특징](#인스턴스-타입별-특징)
- [설정 방법](#설정-방법)
- [인스턴스 타입별 권장 설정](#인스턴스-타입별-권장-설정)
- [컴포넌트 설명](#컴포넌트-설명)
- [적용 방법](#적용-방법)

##  인스턴스 타입별 특징

### 1. GPU + EFA 인스턴스 (멀티 노드 학습)

**인스턴스 타입**: p5en.48xlarge, p4d.24xlarge, p5.48xlarge

**특징:**
-  GPU 지원 (H100, A100)
-  EFA (Elastic Fabric Adapter) 지원 - 최대 3.2Tbps
-  멀티 노드 분산 학습에 최적화
-  NCCL over EFA로 고속 GPU 간 통신

**사용 사례:**
- 대규모 언어 모델 학습 (LLM)
- 멀티 노드 분산 학습
- 고성능 GPU 클러스터

### 2. GPU Only 인스턴스 (단일 노드 학습)

**인스턴스 타입**: g5.xlarge, g5.12xlarge, g4dn.xlarge

**특징:**
-  GPU 지원 (A10G, T4)
-  EFA 미지원
-  단일 노드 학습에 적합
-  비용 효율적

**사용 사례:**
- 단일 노드 모델 학습
- 추론 워크로드
- 개발 및 테스트

### 3. Non-GPU 인스턴스 (일반 컴퓨팅)

**인스턴스 타입**: c5.xlarge, m5.large, r5.xlarge

**특징:**
-  GPU 없음
-  EFA 미지원
-  CPU 기반 워크로드
-  비용 효율적

**사용 사례:**
- 데이터 전처리
- CPU 기반 학습
- 일반 컴퓨팅 작업

## ️ 설정 방법

### environment-variables-bailey.sh 설정

```bash
# ComputeNode: Setup configuration
export COMPUTE_SETUP_TYPE="gpu"         # "gpu", "cpu", or "" (disabled)
```

### 설정 옵션 설명

| 값 | 설명 | 설치 항목 | 설치 시간 |
|----|------|-----------|-----------|
| `"gpu"` | GPU 인스턴스용 (기본값) | Docker + Pyxis + EFA + DCGM + Node Exporter | ~15-20분 |
| `"cpu"` | CPU 인스턴스용 | Docker + Pyxis | ~5-10분 |
| `""` | 설치 비활성화 (테스트용) | 없음 (ParallelCluster 기본값만) | ~1-2분 |

##  인스턴스 타입별 권장 설정

### 1. GPU 인스턴스 (p5, p4d, g5, g4dn)

```bash
# environment-variables-bailey.sh
export COMPUTE_SETUP_TYPE="gpu"
```

**설치되는 컴포넌트:**
-  EFA Driver + libfabric (고속 네트워킹, p5/p4d만)
-  Docker + NVIDIA Container Toolkit
-  Pyxis (Slurm container plugin)
-  CloudWatch Agent (로그 및 메트릭)
-  DCGM Exporter (port 9400) - GPU 메트릭
-  Node Exporter (port 9100) - 시스템 메트릭

**설치 시간**: ~15-20분

**자동 감지:**
- EFA는 지원하는 인스턴스에서만 설치됨
- GPU가 없으면 DCGM Exporter 자동 스킵

### 2. CPU 인스턴스 (c5, m5, r5)

```bash
# environment-variables-bailey.sh
export COMPUTE_SETUP_TYPE="cpu"
```

**설치되는 컴포넌트:**
-  Docker
-  Pyxis (Slurm container plugin)
-  CloudWatch Agent (로그 및 메트릭)

**설치 시간**: ~5-10분

### 3. 최소 설정 (테스트/개발)

```bash
# environment-variables-bailey.sh
export COMPUTE_SETUP_TYPE=""            # 빈 문자열 = 비활성화
```

**설치되는 컴포넌트:**
-  ParallelCluster 기본 설정만

**설치 시간**: ~1-2분

##  컴포넌트 설명

### EFA (Elastic Fabric Adapter)

**용도**: 고속 네트워크 통신 (멀티 노드 학습)

**필요한 경우:**
- 멀티 노드 GPU 학습
- NCCL All-Reduce 통신
- p5, p4d 인스턴스

**불필요한 경우:**
- 단일 노드 학습
- EFA 미지원 인스턴스 (g5, c5, m5 등)

**성능:**
- p5en.48xlarge: 최대 3.2Tbps
- p4d.24xlarge: 최대 400Gbps

### DCGM Exporter

**용도**: GPU 메트릭 수집 (Prometheus)

**수집 메트릭:**
- GPU 사용률
- GPU 메모리 사용량
- GPU 온도
- GPU 전력 소비

**필요한 경우:**
- GPU 인스턴스 모니터링
- GPU 성능 추적
- Prometheus 대시보드

**불필요한 경우:**
- Non-GPU 인스턴스
- CloudWatch만 사용하는 경우

### Node Exporter

**용도**: 시스템 메트릭 수집 (Prometheus)

**수집 메트릭:**
- CPU 사용률
- 메모리 사용량
- 디스크 I/O
- 네트워크 트래픽

**필요한 경우:**
- Prometheus 모니터링
- 시스템 성능 추적
- 커스텀 대시보드

**불필요한 경우:**
- CloudWatch만 사용하는 경우
- 모니터링 최소화

##  적용 방법

### 1단계: 환경 변수 설정

```bash
cd parallelcluster-for-llm
vim environment-variables-bailey.sh

# 인스턴스 타입에 맞게 설정 수정
export COMPUTE_SETUP_TYPE="cpu"         # 예: CPU 인스턴스
# 또는
export COMPUTE_SETUP_TYPE="gpu"         # 예: GPU 인스턴스
# 또는
export COMPUTE_SETUP_TYPE=""            # 예: 최소 설정 (테스트)
```

### 2단계: 설정 생성

```bash
source environment-variables-bailey.sh
envsubst < cluster-config.yaml.template > cluster-config.yaml
```

### 3단계: S3 업로드

```bash
aws s3 sync config/ s3://${S3_BUCKET}/config/ --region ${AWS_REGION}
```

### 4단계: 클러스터 생성/업데이트

```bash
# 새 클러스터
pcluster create-cluster \
    --cluster-name ${CLUSTER_NAME} \
    --cluster-configuration cluster-config.yaml

# 기존 클러스터 업데이트
pcluster update-cluster \
    --cluster-name ${CLUSTER_NAME} \
    --cluster-configuration cluster-config.yaml
```

##  확인 방법

### 설정 확인

```bash
# 환경 변수 확인
source environment-variables-bailey.sh
echo "Compute Setup Type: ${COMPUTE_SETUP_TYPE}"
```

### 클러스터 생성 후 확인

```bash
# Compute Node에 SSH 접속
ssh compute-node-1

# EFA 확인 (활성화 시)
ls -la /dev/infiniband/
/opt/amazon/efa/bin/fi_info --version

# DCGM Exporter 확인 (활성화 시)
sudo systemctl status dcgm-exporter
curl http://localhost:9400/metrics

# Node Exporter 확인 (활성화 시)
sudo systemctl status node-exporter
curl http://localhost:9100/metrics

# CloudWatch Agent 확인 (항상 활성화)
sudo systemctl status amazon-cloudwatch-agent
```

##  비교표

| 항목 | GPU 모드 | CPU 모드 | 최소 설정 |
|------|----------|----------|-----------|
| **설정 값** | `"gpu"` | `"cpu"` | `""` |
| **인스턴스 예시** | p5, p4d, g5, g4dn | c5, m5, r5 | 모든 타입 |
| **Docker** |  + NVIDIA Toolkit |  |  |
| **Pyxis** |  |  |  |
| **EFA** |  (자동 감지) |  |  |
| **DCGM Exporter** |  (GPU 있을 때) |  |  |
| **Node Exporter** |  |  |  |
| **CloudWatch Agent** |  |  |  (기본) |
| **GPU 메트릭** |  |  |  |
| **시스템 메트릭 (Prometheus)** |  |  |  |
| **시스템 메트릭 (CloudWatch)** |  |  |  |
| **설치 시간** | ~15-20분 | ~5-10분 | ~1-2분 |
| **사용 사례** | GPU 학습/추론 | CPU 워크로드 | 테스트/개발 |

##  권장 사항

### 프로덕션 환경

**GPU 인스턴스 (p5, p4d, g5, g4dn):**
```bash
export COMPUTE_SETUP_TYPE="gpu"
```
- 모든 GPU 모니터링 및 최적화 도구 설치
- EFA는 지원하는 인스턴스에서만 자동 설치

**CPU 인스턴스 (c5, m5, r5):**
```bash
export COMPUTE_SETUP_TYPE="cpu"
```
- Docker + Pyxis만 설치
- 빠른 부팅 시간

### 개발/테스트 환경

**빠른 테스트가 필요한 경우:**
```bash
export COMPUTE_SETUP_TYPE=""
```
- 최소 설정으로 빠른 클러스터 생성
- 기본 기능만 테스트

**실제 워크로드 테스트:**
```bash
export COMPUTE_SETUP_TYPE="gpu"  # 또는 "cpu"
```
- 프로덕션과 동일한 환경으로 테스트

## ️ 트러블슈팅

### EFA 설치 실패

```bash
# EFA 디바이스 확인
ls -la /dev/infiniband/

# EFA 지원 인스턴스 확인
# p5, p4d, p4de만 EFA 지원
```

### DCGM Exporter 시작 실패

```bash
# GPU 확인
lspci | grep -i nvidia

# Docker 확인
sudo systemctl status docker

# DCGM Exporter 로그
sudo journalctl -u dcgm-exporter -n 50
```

### Node Exporter 시작 실패

```bash
# Node Exporter 바이너리 확인
ls -l /usr/local/bin/node_exporter

# 로그 확인
sudo journalctl -u node-exporter -n 50
```

##  관련 문서

- [CloudWatch 모니터링 가이드](../config/cloudwatch/README.md)
- [클러스터 설정 가이드](../README.md)
- [타임아웃 설정](TIMEOUT-CONFIGURATION.md)
- [최소 클러스터 테스트](TESTING-MINIMAL-CLUSTER.md)

##  AWS 문서

- [EFA 지원 인스턴스](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [GPU 인스턴스](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/accelerated-computing-instances.html)
- [ParallelCluster 인스턴스 타입](https://docs.aws.amazon.com/parallelcluster/latest/ug/instance-types.html)
