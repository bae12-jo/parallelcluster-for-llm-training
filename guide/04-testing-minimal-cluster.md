# 최소 구성 클러스터 테스트 가이드

## 목적

ComputeNode CustomActions를 비활성화하여 기본 클러스터 생성이 성공하는지 테스트합니다.

## 왜 필요한가?

타임아웃이 충분히 설정되었는데도 ComputeNode가 실패하는 경우:
1. CustomActions 스크립트 자체의 문제
2. ParallelCluster 기본 설정의 문제
3. 인프라 문제 (네트워크, 권한 등)

최소 구성으로 테스트하면 **어디서 문제가 발생하는지** 정확히 파악할 수 있습니다.

## 현재 상태

###  비활성화됨 (테스트 모드)

```bash
# environment-variables-bailey.sh
export ENABLE_COMPUTE_SETUP="false"  # CustomActions 비활성화
```

```yaml
# cluster-config.yaml
# CustomActions temporarily disabled for testing
# (주석 처리됨)
```

### 설치되는 것

**ParallelCluster 기본 설치만**:
-  Ubuntu 22.04 OS
-  Slurm worker 설정
-  FSx Lustre 마운트 (/fsx)
-  HeadNode NFS 마운트 (/home)
-  기본 네트워킹

**설치되지 않는 것**:
-  EFA Driver
-  Docker + NVIDIA Container Toolkit
-  Pyxis
-  CloudWatch Agent
-  DCGM Exporter
-  Node Exporter
-  NCCL 설정

## 테스트 절차

### 1. 환경 변수 확인

```bash
# environment-variables-bailey.sh 확인
grep "ENABLE_COMPUTE_SETUP" environment-variables-bailey.sh

# 출력: export ENABLE_COMPUTE_SETUP="false"
```

### 2. 클러스터 설정 재생성

```bash
# 환경 변수 로드
source environment-variables-bailey.sh

# 설정 파일 생성
envsubst < cluster-config.yaml.template > cluster-config.yaml

# CustomActions가 주석 처리되었는지 확인
grep -A 5 "CustomActions" cluster-config.yaml
```

### 3. 클러스터 생성

```bash
# 기존 클러스터 삭제 (있는 경우)
pcluster delete-cluster --cluster-name p5en-48xlarge-cluster --region us-east-2

# 삭제 완료 대기
pcluster describe-cluster --cluster-name p5en-48xlarge-cluster --region us-east-2

# 새 클러스터 생성
pcluster create-cluster \
  --cluster-name p5en-48xlarge-cluster \
  --cluster-configuration cluster-config.yaml \
  --region us-east-2
```

### 4. 생성 모니터링

```bash
# 실시간 모니터링
bash scripts/monitor-compute-node-setup.sh p5en-48xlarge-cluster us-east-2

# 또는 CloudWatch 로그
aws logs tail /aws/parallelcluster/p5en-48xlarge-cluster \
  --region us-east-2 --follow

# 인스턴스 상태 확인
watch -n 10 'aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=Compute" \
  --query "Reservations[*].Instances[*].{State:State.Name,LaunchTime:LaunchTime}" \
  --output table'
```

### 5. 성공 확인

**예상 시간**: 5-10분 (CustomActions 없이 매우 빠름)

**성공 지표**:
```bash
# 1. CloudFormation 스택 완료
aws cloudformation describe-stacks \
  --stack-name p5en-48xlarge-cluster \
  --region us-east-2 \
  --query 'Stacks[0].StackStatus'
# 출력: CREATE_COMPLETE

# 2. ComputeNode 실행 중
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=Compute" \
  --query 'Reservations[*].Instances[*].State.Name'
# 출력: running (shutting-down이 아님!)

# 3. Slurm 노드 등록
ssh headnode
sinfo -N -l
# 출력: compute-node-1  idle  (또는 allocated)
```

### 6. 기본 기능 테스트

```bash
# HeadNode 접속
ssh headnode

# Slurm 작동 확인
sinfo
squeue

# ComputeNode에 간단한 명령 실행
srun --nodes=1 hostname
srun --nodes=1 uptime
srun --nodes=1 df -h /fsx

# GPU 확인 (NVIDIA 드라이버는 기본 설치됨)
srun --nodes=1 nvidia-smi

# 간단한 계산 테스트
srun --nodes=2 --ntasks=2 hostname
```

## 테스트 결과 분석

### 시나리오 A: 최소 구성 성공 

**의미**: ParallelCluster 기본 설정은 정상, CustomActions에 문제가 있음

**다음 단계**:
1. CustomActions 스크립트 검토
2. 개별 컴포넌트 수동 설치 테스트
3. 문제 컴포넌트 식별 및 수정

```bash
# 수동으로 컴포넌트 설치 테스트
ssh headnode
srun --nodes=1 bash << 'EOF'
  # EFA 설치 테스트
  cd /tmp
  curl -O https://efa-installer.amazonaws.com/aws-efa-installer-latest.tar.gz
  tar -xf aws-efa-installer-latest.tar.gz
  cd aws-efa-installer
  sudo ./efa_installer.sh -y
EOF
```

### 시나리오 B: 최소 구성도 실패 

**의미**: ParallelCluster 기본 설정 또는 인프라에 문제

**확인 사항**:
1. **네트워크**: Private Subnet, NAT Gateway, 라우팅
2. **권한**: IAM 역할, 정책
3. **리소스**: Capacity Block 예약 상태
4. **리전**: 리소스 가용성

```bash
# 네트워크 확인
aws ec2 describe-subnets --subnet-ids subnet-XXXXX --region us-east-2
aws ec2 describe-route-tables --region us-east-2

# IAM 역할 확인
aws iam get-role --role-name parallelcluster-* --region us-east-2

# Capacity Block 확인
aws ec2 describe-capacity-reservations \
  --capacity-reservation-ids cr-XXXXX \
  --region us-east-2
```

## CustomActions 재활성화

테스트 완료 후 CustomActions를 다시 활성화:

### 1. 환경 변수 수정

```bash
# environment-variables-bailey.sh
export ENABLE_COMPUTE_SETUP="true"  # 다시 활성화
```

### 2. 설정 재생성

```bash
source environment-variables-bailey.sh
envsubst < cluster-config.yaml.template > cluster-config.yaml

# CustomActions가 활성화되었는지 확인
grep -A 10 "CustomActions" cluster-config.yaml
```

### 3. 클러스터 재생성

```bash
pcluster delete-cluster --cluster-name p5en-48xlarge-cluster --region us-east-2
pcluster create-cluster \
  --cluster-name p5en-48xlarge-cluster \
  --cluster-configuration cluster-config.yaml \
  --region us-east-2
```

## 점진적 활성화 전략

문제를 정확히 찾기 위해 컴포넌트를 하나씩 활성화:

### 단계 1: EFA만 설치

```bash
# setup-compute-node.sh 수정
# Docker, Pyxis, DCGM 등 주석 처리
# EFA만 남기기
```

### 단계 2: EFA + Docker

```bash
# Docker 주석 해제
# 나머지는 주석 유지
```

### 단계 3: 전체 활성화

```bash
# 모든 컴포넌트 활성화
```

## 로그 분석

### 최소 구성 로그 (정상)

```
cloud-init[1234]: Cloud-init v. 23.1.2 running
...
[ParallelCluster] Configuring Slurm compute node
[ParallelCluster] Mounting shared filesystems
[ParallelCluster] FSx Lustre mounted at /fsx
[ParallelCluster] Node configuration complete
```

### CustomActions 활성화 로그 (정상)

```
=== Compute Node Setup Started ===
Cluster Name: p5en-48xlarge-cluster
...
Installing EFA...
 EFA installation complete
Installing Docker...
 Docker installation complete
...
 Compute Node Setup Complete
```

## 문제 해결 팁

1. **타임아웃 vs 스크립트 에러**
   - 타임아웃: 로그가 중간에 끊김
   - 스크립트 에러: 에러 메시지 후 종료

2. **네트워크 문제**
   - `curl` 또는 `wget` 실패
   - DNS 해석 실패
   - 패키지 다운로드 실패

3. **권한 문제**
   - S3 접근 거부
   - IAM 정책 부족
   - 리소스 생성 권한 없음

## 요약

**현재 상태**: CustomActions 비활성화 (테스트 모드)

**테스트 목적**: 기본 클러스터 생성 성공 여부 확인

**다음 단계**:
-  성공 → CustomActions 스크립트 문제, 개별 컴포넌트 테스트
-  실패 → 인프라/설정 문제, 네트워크/권한 확인

**재활성화**: `ENABLE_COMPUTE_SETUP="true"` 설정 후 재생성
