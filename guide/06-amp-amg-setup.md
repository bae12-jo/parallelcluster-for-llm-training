# AMP + AMG 자동 연결 가이드

AWS Managed Prometheus (AMP)와 AWS Managed Grafana (AMG)를 사용한 완전 관리형 모니터링 설정 가이드입니다.

##  목차

- [자동으로 수행되는 작업](#자동으로-수행되는-작업)
- [수동으로 수행해야 하는 작업](#수동으로-수행해야-하는-작업)
- [전체 설정 프로세스](#전체-설정-프로세스)
- [Grafana 접근 방법](#grafana-접근-방법)
- [트러블슈팅](#트러블슈팅)

##  자동으로 수행되는 작업

Infrastructure 스택 배포 시 자동으로 수행됩니다:

### 1. AMP Workspace 생성
-  Prometheus 워크스페이스 자동 생성
-  Remote write endpoint 설정
-  IAM 정책 자동 생성 (remote_write, query)

### 2. AMG Workspace 생성
-  Grafana 워크스페이스 자동 생성
-  AWS SSO 인증 설정
-  IAM 역할 자동 생성

### 3. AMP ↔ AMG 자동 연결
-  Lambda 함수가 자동으로 AMP 데이터소스를 Grafana에 추가
-  SigV4 인증 자동 설정
-  기본 데이터소스로 설정

### 4. ParallelCluster 통합
-  HeadNode Prometheus가 AMP로 메트릭 전송
-  IAM 정책 자동 연결

##  수동으로 수행해야 하는 작업

### 1. AWS IAM Identity Center (SSO) 설정

**필수 사전 조건**: AWS IAM Identity Center가 활성화되어 있어야 합니다.

```bash
# Identity Center 활성화 확인
aws sso-admin list-instances --region us-east-2
```

**활성화되지 않은 경우:**
1. AWS Console → IAM Identity Center
2. "Enable" 클릭
3. 조직 이메일 설정

### 2. Grafana 사용자 추가

Infrastructure 스택 배포 후:

```bash
# 1. Grafana Workspace ID 가져오기
GRAFANA_WORKSPACE_ID=$(aws cloudformation describe-stacks \
    --stack-name pcluster-infra \
    --region us-east-2 \
    --query 'Stacks[0].Outputs[?OutputKey==`ManagedGrafanaWorkspaceId`].OutputValue' \
    --output text)

echo "Grafana Workspace ID: ${GRAFANA_WORKSPACE_ID}"

# 2. 사용자에게 ADMIN 권한 부여
aws grafana update-permissions \
    --workspace-id ${GRAFANA_WORKSPACE_ID} \
    --region us-east-2 \
    --update-instruction-batch '[
        {
            "action": "ADD",
            "role": "ADMIN",
            "users": [
                {
                    "id": "your-email@example.com",
                    "type": "SSO_USER"
                }
            ]
        }
    ]'
```

**역할 옵션:**
- `ADMIN`: 모든 권한 (대시보드 생성/수정/삭제)
- `EDITOR`: 대시보드 생성/수정
- `VIEWER`: 읽기 전용

### 3. 여러 사용자 추가

```bash
# 여러 사용자 한 번에 추가
aws grafana update-permissions \
    --workspace-id ${GRAFANA_WORKSPACE_ID} \
    --region us-east-2 \
    --update-instruction-batch '[
        {
            "action": "ADD",
            "role": "ADMIN",
            "users": [
                {"id": "admin@example.com", "type": "SSO_USER"}
            ]
        },
        {
            "action": "ADD",
            "role": "EDITOR",
            "users": [
                {"id": "engineer1@example.com", "type": "SSO_USER"},
                {"id": "engineer2@example.com", "type": "SSO_USER"}
            ]
        },
        {
            "action": "ADD",
            "role": "VIEWER",
            "users": [
                {"id": "viewer@example.com", "type": "SSO_USER"}
            ]
        }
    ]'
```

##  전체 설정 프로세스

### 1단계: Infrastructure 스택 배포

```bash
# MonitoringType을 amp+amg로 설정
aws cloudformation create-stack \
    --stack-name pcluster-infra \
    --template-body file://parallelcluster-infrastructure.yaml \
    --parameters \
        ParameterKey=MonitoringType,ParameterValue=amp+amg \
        ParameterKey=VPCName,ParameterValue=pcluster-vpc \
        ParameterKey=PrimarySubnetAZ,ParameterValue=us-east-2a \
    --capabilities CAPABILITY_NAMED_IAM \
    --region us-east-2
```

**자동으로 수행되는 작업:**
- AMP Workspace 생성 (~1분)
- AMG Workspace 생성 (~5분)
- Lambda 함수가 AMP 데이터소스를 Grafana에 추가 (~1분)

### 2단계: 스택 완료 대기

```bash
# 스택 생성 완료 대기 (약 5-10분)
aws cloudformation wait stack-create-complete \
    --stack-name pcluster-infra \
    --region us-east-2

echo " Infrastructure stack created successfully"
```

### 3단계: Grafana 접근 정보 확인

```bash
# Grafana URL 가져오기
GRAFANA_URL=$(aws cloudformation describe-stacks \
    --stack-name pcluster-infra \
    --region us-east-2 \
    --query 'Stacks[0].Outputs[?OutputKey==`ManagedGrafanaWorkspaceEndpoint`].OutputValue' \
    --output text)

echo "Grafana URL: https://${GRAFANA_URL}"

# Workspace ID 가져오기
GRAFANA_WORKSPACE_ID=$(aws cloudformation describe-stacks \
    --stack-name pcluster-infra \
    --region us-east-2 \
    --query 'Stacks[0].Outputs[?OutputKey==`ManagedGrafanaWorkspaceId`].OutputValue' \
    --output text)

echo "Workspace ID: ${GRAFANA_WORKSPACE_ID}"
```

### 4단계: 사용자 추가 (수동)

```bash
# 자신의 이메일로 ADMIN 권한 추가
aws grafana update-permissions \
    --workspace-id ${GRAFANA_WORKSPACE_ID} \
    --region us-east-2 \
    --update-instruction-batch '[
        {
            "action": "ADD",
            "role": "ADMIN",
            "users": [
                {
                    "id": "your-email@example.com",
                    "type": "SSO_USER"
                }
            ]
        }
    ]'

echo " User added to Grafana workspace"
```

### 5단계: ParallelCluster 생성

```bash
# environment-variables-bailey.sh에서 CLUSTER_NAME 확인
source environment-variables-bailey.sh

# 클러스터 생성
pcluster create-cluster \
    --cluster-name ${CLUSTER_NAME} \
    --cluster-configuration cluster-config.yaml \
    --region ${AWS_REGION}
```

**자동으로 수행되는 작업:**
- HeadNode Prometheus가 AMP로 메트릭 전송
- ComputeNode DCGM/Node Exporter가 HeadNode Prometheus로 메트릭 전송
- Prometheus가 AMP로 remote_write

##  Grafana 접근 방법

### 1. Grafana URL 접속

```bash
# URL 확인
aws cloudformation describe-stacks \
    --stack-name pcluster-infra \
    --region us-east-2 \
    --query 'Stacks[0].Outputs[?OutputKey==`ManagedGrafanaWorkspaceEndpoint`].OutputValue' \
    --output text
```

브라우저에서 `https://<workspace-id>.grafana-workspace.us-east-2.amazonaws.com` 접속

### 2. AWS SSO 로그인

1. "Sign in with AWS SSO" 클릭
2. Identity Center 이메일/비밀번호 입력
3. MFA 인증 (설정된 경우)

### 3. AMP 데이터소스 확인

Grafana 접속 후:
1. 좌측 메뉴 → Configuration → Data sources
2. "Amazon Managed Prometheus" 확인
3. "Default" 태그 확인

### 4. 대시보드 생성

```
1. 좌측 메뉴 → Create → Dashboard
2. Add panel
3. Query: 메트릭 선택 (예: up, node_cpu_seconds_total)
4. Data source: Amazon Managed Prometheus (자동 선택됨)
5. Save dashboard
```

##  사전 구성된 메트릭

AMP에 자동으로 수집되는 메트릭:

### DCGM (GPU 메트릭)
- `DCGM_FI_DEV_GPU_UTIL` - GPU 사용률
- `DCGM_FI_DEV_MEM_COPY_UTIL` - GPU 메모리 사용률
- `DCGM_FI_DEV_GPU_TEMP` - GPU 온도
- `DCGM_FI_DEV_POWER_USAGE` - GPU 전력 소비

### Node Exporter (시스템 메트릭)
- `node_cpu_seconds_total` - CPU 사용 시간
- `node_memory_MemAvailable_bytes` - 사용 가능한 메모리
- `node_disk_io_time_seconds_total` - 디스크 I/O
- `node_network_receive_bytes_total` - 네트워크 수신

### Slurm 메트릭 (CloudWatch에서 수집)
- CloudWatch에서 확인 가능
- Grafana CloudWatch 데이터소스로 조회 가능

## ️ 트러블슈팅

### 문제: Grafana에 접근할 수 없음

**원인**: 사용자가 Grafana workspace에 추가되지 않음

**해결:**
```bash
# 사용자 목록 확인
aws grafana list-permissions \
    --workspace-id ${GRAFANA_WORKSPACE_ID} \
    --region us-east-2

# 사용자 추가
aws grafana update-permissions \
    --workspace-id ${GRAFANA_WORKSPACE_ID} \
    --region us-east-2 \
    --update-instruction-batch '[{"action":"ADD","role":"ADMIN","users":[{"id":"your-email@example.com","type":"SSO_USER"}]}]'
```

### 문제: AMP 데이터소스가 Grafana에 없음

**원인**: Lambda 함수 실행 실패

**해결:**
```bash
# Lambda 로그 확인
aws logs tail /aws/lambda/pcluster-infra-grafana-datasource-setup \
    --region us-east-2 \
    --follow

# Lambda 함수 수동 재실행
aws lambda invoke \
    --function-name pcluster-infra-grafana-datasource-setup \
    --region us-east-2 \
    /tmp/lambda-output.json

cat /tmp/lambda-output.json
```

### 문제: Grafana에서 메트릭이 보이지 않음

**원인**: HeadNode Prometheus가 AMP로 메트릭을 전송하지 않음

**해결:**
```bash
# HeadNode에서 Prometheus 상태 확인
ssh headnode
sudo systemctl status prometheus

# Prometheus 설정 확인
cat /opt/prometheus/prometheus.yml | grep -A10 remote_write

# AMP endpoint 확인
curl -I https://aps-workspaces.us-east-2.amazonaws.com/workspaces/<workspace-id>/api/v1/remote_write
```

### 문제: Identity Center가 활성화되지 않음

**원인**: AWS IAM Identity Center가 설정되지 않음

**해결:**
1. AWS Console → IAM Identity Center
2. "Enable" 클릭
3. 조직 이메일 설정
4. 사용자 추가
5. Grafana 권한 부여

##  비용 예상

### AMP (AWS Managed Prometheus)
- 메트릭 수집: $0.30 per million samples
- 메트릭 저장: $0.03 per GB-month
- 쿼리: $0.01 per million samples
- **예상**: ~$10-30/month (워크로드에 따라)

### AMG (AWS Managed Grafana)
- Workspace: $9/month per active user
- **예상**: $9-90/month (사용자 수에 따라)

### 총 예상 비용
- **1-5 사용자**: ~$60-80/month
- **Self-hosting 대비**: 비슷하거나 약간 높음
- **장점**: 완전 관리형, 자동 스케일링, 고가용성

##  관련 문서

- [AWS Managed Prometheus](https://docs.aws.amazon.com/prometheus/)
- [AWS Managed Grafana](https://docs.aws.amazon.com/grafana/)
- [IAM Identity Center](https://docs.aws.amazon.com/singlesignon/)
- [Prometheus Remote Write](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#remote_write)

##  요약

### 자동화된 부분 
- AMP Workspace 생성
- AMG Workspace 생성
- AMP ↔ AMG 데이터소스 연결
- ParallelCluster → AMP 메트릭 전송

### 수동 작업 필요 
- IAM Identity Center 활성화 (최초 1회)
- Grafana 사용자 추가 (사용자당 1회)
- 대시보드 생성 (선택)

### 소요 시간
- Infrastructure 배포: ~10분
- 사용자 추가: ~1분
- 클러스터 생성: ~30분
- **총**: ~40분 (대부분 자동)
