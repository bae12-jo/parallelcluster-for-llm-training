# ParallelCluster 가이드 문서

이 디렉토리에는 AWS ParallelCluster 설정 및 운영에 대한 상세 가이드가 포함되어 있습니다.

##  문서 목록

### 설치 및 설정

- **[01-instance-type-configuration.md](01-instance-type-configuration.md)** ⭐ NEW
  - 인스턴스 타입별 설정 가이드
  - GPU+EFA, GPU Only, Non-GPU 인스턴스 설정
  - EFA/DCGM/Node Exporter 선택적 설치
  - 인스턴스 타입별 권장 설정

- **[02-timeout-configuration.md](02-timeout-configuration.md)**
  - ComputeNode 부트스트랩 타임아웃 설정
  - 타임아웃 문제 해결
  - 권장 타임아웃 값 및 근거

- **[04-testing-minimal-cluster.md](04-testing-minimal-cluster.md)**
  - 최소 구성 클러스터 테스트 가이드
  - CustomActions 비활성화 테스트
  - 문제 원인 파악 방법

### 모니터링 및 디버깅

- **[14-monitoring-setup-progress.md](14-monitoring-setup-progress.md)**
  - ComputeNode 설치 진행 상황 모니터링
  - CloudWatch Logs 확인 방법
  - 설치 단계별 로그 메시지
  - 문제 해결 체크리스트

### 성능 및 최적화

- **[15-nccl-installation-timing.md](15-nccl-installation-timing.md)**
  - NCCL 설치 시간 분석
  - 컴포넌트별 소요 시간
  - NGC 컨테이너 vs 수동 설치 비교

##  관련 문서

### 메인 문서
- [../README.md](../README.md) - 프로젝트 개요 및 Quick Start

### 설정 파일
- [../cluster-config.yaml.template](../cluster-config.yaml.template) - 클러스터 설정 템플릿
- [../environment-variables.sh](../environment-variables.sh) - 환경 변수 설정

### 스크립트
- [../scripts/monitor-compute-node-setup.sh](../scripts/monitor-compute-node-setup.sh) - 설치 모니터링 스크립트
- [../scripts/check-compute-setup.sh](../scripts/check-compute-setup.sh) - 설치 상태 확인 스크립트

### 설정 디렉토리
- [../config/headnode/README.md](../config/headnode/README.md) - HeadNode 설정 가이드
- [../config/nccl/README.md](../config/nccl/README.md) - NCCL 설치 및 테스트

##  문서 사용 가이드

### 클러스터 생성 전
1. [01-instance-type-configuration.md](01-instance-type-configuration.md) - 인스턴스 타입별 설정 ⭐
2. [02-timeout-configuration.md](02-timeout-configuration.md) - 타임아웃 설정 확인
3. [04-testing-minimal-cluster.md](04-testing-minimal-cluster.md) - 테스트 전략 수립

### 클러스터 생성 중
1. [14-monitoring-setup-progress.md](14-monitoring-setup-progress.md) - 실시간 모니터링

### 문제 발생 시
1. [14-monitoring-setup-progress.md](14-monitoring-setup-progress.md) - 로그 확인
2. [02-timeout-configuration.md](02-timeout-configuration.md) - 타임아웃 문제 해결
3. [04-testing-minimal-cluster.md](04-testing-minimal-cluster.md) - 최소 구성 테스트

### NCCL 설치 시
1. [15-nccl-installation-timing.md](15-nccl-installation-timing.md) - 설치 시간 예상
2. [../config/nccl/README.md](../config/nccl/README.md) - 설치 방법

##  빠른 참조

### 타임아웃 설정
```yaml
DevSettings:
  Timeouts:
    HeadNodeBootstrapTimeout: 3600      # 60분
    ComputeNodeBootstrapTimeout: 2400   # 40분
```

### 설치 모니터링
```bash
bash scripts/monitor-compute-node-setup.sh <cluster-name> <region>
```

### 최소 구성 테스트
```bash
# environment-variables.sh
export ENABLE_COMPUTE_SETUP="false"
```

### 설치 상태 확인
```bash
srun --nodes=1 bash /fsx/scripts/check-compute-setup.sh
```
