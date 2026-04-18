# ParallelCluster 노드별 설치 스크립트

각 노드 타입별로 역할에 맞는 소프트웨어만 설치하여 효율적인 클러스터 구성을 제공합니다.

##  노드별 설치 항목

### Login Node (사용자 SSH 접속용)
**목적**: 사용자가 코드 작성 및 작업 제출  
**설치 항목**:
- CloudWatch Agent (시스템 메트릭 전송)
- 기본 개발 도구 (vim, git, htop)

**스크립트**: `config/loginnode/setup-loginnode.sh`

```bash
# 최소한의 설치로 빠른 부팅과 낮은 리소스 사용
apt-get install -y vim git htop
wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i amazon-cloudwatch-agent.deb
```

---

### Head Node (Slurm controller)
**목적**: 클러스터 관리 + 모니터링 메트릭 수집  
**설치 항목**:
- CloudWatch Agent (시스템 메트릭)
- Slurm controller/scheduler (ParallelCluster 자동 설치)
- Prometheus (Compute Node의 DCGM 메트릭 수집)

**스크립트**: `config/headnode/setup-headnode.sh`

```bash
# CloudWatch Agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i amazon-cloudwatch-agent.deb

# Prometheus (Compute Node 메트릭 수집)
wget https://github.com/prometheus/prometheus/releases/download/v2.45.0/prometheus-2.45.0.linux-amd64.tar.gz
tar xvf prometheus-2.45.0.linux-amd64.tar.gz
mv prometheus-2.45.0.linux-amd64 /opt/prometheus

# Prometheus 설정 - EC2 Auto-discovery
cat > /opt/prometheus/prometheus.yml <<EOF
scrape_configs:
  - job_name: 'dcgm'
    ec2_sd_configs:
      - region: us-west-2
        filters:
          - name: tag:aws:parallelcluster:node-type
            values: [Compute]
    relabel_configs:
      - source_labels: [__meta_ec2_private_ip]
        target_label: __address__
        replacement: '\${1}:9400'
EOF
```

---

### Compute Node (실제 작업 실행)
**목적**: GPU 학습 및 추론 작업 실행  
**설치 항목**:
- **필수**:
  - NVIDIA Driver (AMI에 포함)
  - CUDA Toolkit
  - NCCL (멀티 GPU 통신)
  - EFA Driver + libfabric (p4d/p5 고속 네트워킹)
  - CloudWatch Agent
- **강력 추천**:
  - Docker + NVIDIA Container Toolkit
  - Pyxis/Enroot (Slurm container plugin)
  - DCGM Exporter (GPU 메트릭 → Prometheus)
  - Node Exporter (시스템 메트릭 → Prometheus)

**스크립트**: `config/compute/setup-compute-node.sh`

```bash
# 병렬 설치로 시간 단축
{
    # EFA
    curl -O https://efa-installer.amazonaws.com/aws-efa-installer-latest.tar.gz
    tar -xf aws-efa-installer-latest.tar.gz
    cd aws-efa-installer && ./efa_installer.sh -y -g
} &

{
    # NCCL
    apt-get update
    apt-get install -y libnccl2 libnccl-dev
} &

{
    # Docker + NVIDIA Container Toolkit
    apt-get install -y docker.io
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | apt-key add -
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update && apt-get install -y nvidia-container-toolkit
    systemctl enable docker && systemctl start docker
} &

{
    # CloudWatch Agent
    wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
    dpkg -i amazon-cloudwatch-agent.deb
} &

wait

# Docker 의존성 있는 것들
# Pyxis
cd /tmp
git clone https://github.com/NVIDIA/pyxis.git
cd pyxis && make install

# DCGM Exporter (systemd service)
cat > /etc/systemd/system/dcgm-exporter.service <<EOF
[Unit]
Description=NVIDIA DCGM Exporter
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/docker run --rm --name dcgm-exporter \
  --gpus all --net host \
  nvcr.io/nvidia/k8s/dcgm-exporter:3.1.8-3.1.5-ubuntu22.04
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dcgm-exporter
systemctl start dcgm-exporter
```

---

##  데이터 흐름

```
Login Node → CloudWatch Agent → CloudWatch
                                      ↓
Head Node  → CloudWatch Agent → CloudWatch → Grafana
           → Prometheus ←┐                    
                         │
Compute    → CloudWatch Agent → CloudWatch
Nodes      → DCGM (9400) ─────┘
           → Node Exporter (9100) ─┘
```

### 모니터링 포트
- **9090**: Prometheus (Head Node)
- **9100**: Node Exporter (Compute Nodes - 시스템 메트릭)
- **9400**: DCGM Exporter (Compute Nodes - GPU 메트릭)
- **3000**: Grafana (별도 Monitoring Instance)

---

##  S3 업로드

스크립트를 S3에 업로드하여 ParallelCluster CustomActions에서 사용:

```bash
# 전체 config 폴더 업로드
aws s3 sync config/ s3://your-bucket/config/ --region us-east-1

# 업로드 확인
aws s3 ls s3://your-bucket/config/ --recursive
```

---

##  사용 방법

### 1. environment-variables.sh 설정

```bash
# 각 노드별 설치 활성화
export ENABLE_LOGINNODE_SETUP="true"    # LoginNode 설정
export ENABLE_HEADNODE_SETUP="true"     # HeadNode 설정
export ENABLE_COMPUTE_SETUP="true"      # ComputeNode 설정

export S3_BUCKET="your-bucket-name"
export CLUSTER_NAME="my-cluster"
export AWS_REGION="us-east-1"
```

### 2. 클러스터 설정 생성

```bash
source environment-variables.sh
envsubst < cluster-config.yaml.template > cluster-config.yaml
```

### 3. 클러스터 생성

```bash
pcluster create-cluster \
  --cluster-name my-cluster \
  --cluster-configuration cluster-config.yaml
```

---

## ⏱️ 예상 설치 시간

| 노드 타입 | 설치 시간 | 주요 항목 |
|----------|----------|----------|
| Login Node | ~2분 | CloudWatch + 기본 도구 |
| Head Node | ~5분 | CloudWatch + Prometheus |
| Compute Node | ~15-20분 | EFA + NCCL + Docker + DCGM (병렬 설치) |

---

##  문제 해결

### 스크립트 실행 로그 확인

```bash
# Head Node
sudo tail -f /var/log/cfn-init.log
sudo tail -f /var/log/parallelcluster/clustermgtd

# Compute Node
sudo tail -f /var/log/cloud-init-output.log
```

### 서비스 상태 확인

```bash
# Prometheus (Head Node)
sudo systemctl status prometheus
curl http://localhost:9090/-/healthy

# DCGM Exporter (Compute Node)
sudo systemctl status dcgm-exporter
curl http://localhost:9400/metrics

# Node Exporter (Compute Node)
sudo systemctl status node-exporter
curl http://localhost:9100/metrics
```

---

##  참고 자료

- [AWS ParallelCluster Documentation](https://docs.aws.amazon.com/parallelcluster/)
- [NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter)
- [Prometheus EC2 Service Discovery](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#ec2_sd_config)
- [EFA Installer](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start.html)


---

##  CloudWatch 모니터링

### 종합 대시보드 솔루션

**위치**: `config/cloudwatch/`

**목적**: 인프라 관리자와 모델 학습자를 위한 실시간 모니터링 대시보드

**주요 기능**:
-  실시간 시스템 메트릭 (CPU, 메모리, 디스크, 네트워크)
-  Slurm 작업 큐 및 노드 상태 모니터링
-  GPU 모니터링 (DCGM)
-  FSx Lustre I/O 성능
-  로그 수집 및 분석 (Slurm, DCGM, 클러스터 관리)

### 빠른 시작 (5분)

```bash
# 1. S3에 설정 업로드
cd parallelcluster-for-llm
source environment-variables-bailey.sh
bash config/cloudwatch/deploy-to-s3.sh

# 2. 클러스터 생성/업데이트 (자동으로 모니터링 설치됨)
pcluster create-cluster --cluster-name ${CLUSTER_NAME} --cluster-configuration cluster-config.yaml

# 3. 대시보드 생성
bash config/cloudwatch/create-dashboard.sh ${CLUSTER_NAME} ${AWS_REGION}
bash config/cloudwatch/create-advanced-dashboard.sh ${CLUSTER_NAME} ${AWS_REGION}
```

### 대시보드 종류

**1. 기본 대시보드** (`create-dashboard.sh`)
- CPU/메모리/디스크 사용률
- 네트워크 및 FSx Lustre I/O
- Slurm 로그 (에러, resume, suspend)
- GPU 모니터링 (DCGM)
- 클러스터 관리 로그

**2. 고급 대시보드** (`create-advanced-dashboard.sh`)
- Slurm 노드 상태 (Total/Idle/Allocated/Down)
- 작업 큐 상태 (Running/Pending/Total)
- 노드 활용률 계산
- 작업 완료/실패 로그
- GPU 상태 실시간 모니터링

### 자동 설치 내용

클러스터 생성 시 자동으로 설치됩니다:

- **HeadNode**: CloudWatch Agent + Slurm 메트릭 수집기 + Prometheus
- **ComputeNode**: CloudWatch Agent + DCGM Exporter + Node Exporter
- **LoginNode**: CloudWatch Agent

### 파일 구조

```
cloudwatch/
├── README.md                          # 전체 문서
├── QUICKSTART.md                      # 5분 빠른 시작 가이드
├── cloudwatch-agent-config.json       # CloudWatch Agent 설정
├── install-cloudwatch-agent.sh        # CloudWatch Agent 설치
├── slurm-metrics-collector.sh         # Slurm 메트릭 수집
├── install-slurm-metrics.sh           # Slurm 메트릭 수집기 설치
├── create-dashboard.sh                # 기본 대시보드 생성
├── create-advanced-dashboard.sh       # 고급 대시보드 (Slurm 메트릭)
└── deploy-to-s3.sh                    # S3 배포 스크립트
```

### 수집되는 메트릭

**시스템 메트릭** (CloudWatch Agent):
- CPU: 사용률, idle, iowait
- 메모리: 사용률, available, used
- 디스크: 사용률, I/O (read/write bytes)
- 네트워크: TCP 연결 상태

**Slurm 메트릭** (Custom):
- 노드 상태: Total, Idle, Allocated, Down
- 작업 상태: Running, Pending, Total

**로그 수집**:
- `/var/log/slurmctld.log` - Slurm 컨트롤러
- `/var/log/slurmd.log` - Slurm 데몬
- `/var/log/parallelcluster/slurm_resume.log` - 노드 시작
- `/var/log/parallelcluster/slurm_suspend.log` - 노드 종료
- `/var/log/dcgm/nv-hostengine.log` - GPU 모니터링
- `/var/log/nvidia-installer.log` - NVIDIA 드라이버

### 대시보드 접근

AWS Console:
```
https://console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards:
```

또는 CLI:
```bash
aws cloudwatch list-dashboards --region ${AWS_REGION}
```

### 상세 문서

- [cloudwatch/README.md](cloudwatch/README.md) - 전체 문서 및 커스터마이징
- [cloudwatch/QUICKSTART.md](cloudwatch/QUICKSTART.md) - 5분 빠른 시작 가이드

---

##  업데이트된 데이터 흐름

```
Login Node → CloudWatch Agent → CloudWatch Logs/Metrics
                                      ↓
Head Node  → CloudWatch Agent → CloudWatch Logs/Metrics → Dashboard
           → Slurm Metrics    → CloudWatch Metrics
           → Prometheus ←┐                    
                         │
Compute    → CloudWatch Agent → CloudWatch Logs/Metrics
Nodes      → DCGM (9400) ─────┘
           → Node Exporter (9100) ─┘
```

### 모니터링 포트
- **9090**: Prometheus (Head Node)
- **9100**: Node Exporter (Compute Nodes - 시스템 메트릭)
- **9400**: DCGM Exporter (Compute Nodes - GPU 메트릭)

---

##  추가 팁

### CloudWatch 비용 최적화
- 로그 보관 기간: 7일 (기본값, `cloudwatch-agent-config.json`에서 변경 가능)
- 메트릭 수집 주기: 60초 (필요시 조정)
- 불필요한 로그 필터링

### 알람 설정
CloudWatch Alarms를 사용하여 임계값 초과 시 알림:
```bash
aws cloudwatch put-metric-alarm \
    --alarm-name high-cpu-usage \
    --alarm-description "Alert when CPU exceeds 80%" \
    --metric-name CPU_IDLE \
    --namespace "ParallelCluster/${CLUSTER_NAME}" \
    --statistic Average \
    --period 300 \
    --threshold 20 \
    --comparison-operator LessThanThreshold \
    --evaluation-periods 2
```

### 로그 쿼리 예제
CloudWatch Logs Insights에서 고급 쿼리:
```
# Slurm 작업 실패 분석
fields @timestamp, @message
| filter @message like /FAILED|ERROR/
| stats count() by bin(5m)

# GPU 온도 모니터링
fields @timestamp, @message
| filter @message like /Temperature/
| parse @message /Temperature: (?<temp>\d+)/
| stats avg(temp) by bin(1m)
```
