# DCGM 메트릭을 CloudWatch에서 보는 방법

DCGM (NVIDIA Data Center GPU Manager) 메트릭을 CloudWatch에서 확인하는 방법입니다.

##  현재 아키텍처

```
ComputeNode (GPU)
  └─ DCGM Exporter (port 9400)
       └─ Prometheus (HeadNode)
            ├─ Grafana (시각화)
            └─ AMP (AWS Managed Prometheus)
```

**문제**: CloudWatch에서는 DCGM 메트릭을 볼 수 없음

##  해결 방법

### 방법 1: DCGM → CloudWatch 직접 전송 (권장)

Prometheus에서 DCGM 메트릭을 스크랩하여 CloudWatch로 전송합니다.

#### 설치

```bash
# HeadNode에서 실행
ssh headnode

# S3에서 스크립트 다운로드
aws s3 cp s3://${S3_BUCKET}/config/cloudwatch/dcgm-to-cloudwatch.sh /tmp/
chmod +x /tmp/dcgm-to-cloudwatch.sh

# 설치
sudo bash /tmp/dcgm-to-cloudwatch.sh ${CLUSTER_NAME} ${AWS_REGION}
```

#### 확인

```bash
# 서비스 상태 확인
sudo systemctl status dcgm-cloudwatch-exporter

# 로그 확인
sudo journalctl -u dcgm-cloudwatch-exporter -f

# CloudWatch 메트릭 확인
aws cloudwatch list-metrics \
    --namespace "ParallelCluster/${CLUSTER_NAME}/GPU" \
    --region ${AWS_REGION}
```

#### CloudWatch에서 확인

```bash
# GPU 사용률 확인
aws cloudwatch get-metric-statistics \
    --namespace "ParallelCluster/${CLUSTER_NAME}/GPU" \
    --metric-name GPUUtilization \
    --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 60 \
    --statistics Average \
    --region ${AWS_REGION}
```

### 방법 2: CloudWatch 대시보드에 추가

기존 CloudWatch 대시보드에 GPU 메트릭 위젯을 추가합니다.

#### 대시보드 업데이트

```bash
# 현재 대시보드 가져오기
aws cloudwatch get-dashboard \
    --dashboard-name "ParallelCluster-${CLUSTER_NAME}" \
    --region ${AWS_REGION} \
    --query 'DashboardBody' \
    --output text > /tmp/dashboard.json

# GPU 위젯 추가 (수동 편집)
# 또는 자동 스크립트 사용
```

#### GPU 위젯 JSON

```json
{
    "type": "metric",
    "x": 0,
    "y": 0,
    "width": 12,
    "height": 6,
    "properties": {
        "metrics": [
            [ "ParallelCluster/${CLUSTER_NAME}/GPU", "GPUUtilization", { "stat": "Average" } ],
            [ ".", "GPUMemoryUtilization", { "stat": "Average" } ]
        ],
        "view": "timeSeries",
        "stacked": false,
        "region": "${AWS_REGION}",
        "title": "GPU 사용률",
        "period": 60,
        "yAxis": {
            "left": {
                "min": 0,
                "max": 100
            }
        }
    }
}
```

##  수집되는 GPU 메트릭

### DCGM Exporter가 제공하는 메트릭

| Prometheus 메트릭 | CloudWatch 메트릭 | 단위 | 설명 |
|-------------------|-------------------|------|------|
| `DCGM_FI_DEV_GPU_UTIL` | GPUUtilization | Percent | GPU 사용률 |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | GPUMemoryUtilization | Percent | GPU 메모리 사용률 |
| `DCGM_FI_DEV_GPU_TEMP` | GPUTemperature | None | GPU 온도 (°C) |
| `DCGM_FI_DEV_POWER_USAGE` | GPUPowerUsage | None | GPU 전력 소비 (W) |
| `DCGM_FI_DEV_FB_USED` | GPUMemoryUsed | Megabytes | 사용 중인 GPU 메모리 |
| `DCGM_FI_DEV_FB_FREE` | GPUMemoryFree | Megabytes | 사용 가능한 GPU 메모리 |

### Dimensions

- `InstanceId`: EC2 인스턴스 ID
- `GPU`: GPU 번호 (0-7 for p5en.48xlarge)

##  자동 설치 (HeadNode Setup에 통합)

HeadNode setup 스크립트에 자동으로 추가하려면:

### 1. S3에 스크립트 업로드

```bash
cd parallelcluster-for-llm
aws s3 cp config/cloudwatch/dcgm-to-cloudwatch.sh \
    s3://${S3_BUCKET}/config/cloudwatch/ \
    --region ${AWS_REGION}
```

### 2. setup-headnode.sh 수정

`config/headnode/setup-headnode.sh`에 다음 추가:

```bash
# Install DCGM to CloudWatch Exporter
(
    set +e
    echo "Installing DCGM to CloudWatch Exporter..."
    
    if [ -n "${S3_BUCKET}" ]; then
        aws s3 cp "s3://${S3_BUCKET}/config/cloudwatch/dcgm-to-cloudwatch.sh" /tmp/ --region ${REGION}
        if [ -f "/tmp/dcgm-to-cloudwatch.sh" ]; then
            chmod +x /tmp/dcgm-to-cloudwatch.sh
            bash /tmp/dcgm-to-cloudwatch.sh "${CLUSTER_NAME}" "${REGION}"
        else
            echo "️  DCGM to CloudWatch exporter script not found"
        fi
    fi
) || echo "️  DCGM to CloudWatch exporter installation failed (non-critical)"
```

### 3. 클러스터 재생성

```bash
# 기존 클러스터 삭제
pcluster delete-cluster --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION}

# 새 클러스터 생성 (자동으로 DCGM → CloudWatch 설치됨)
pcluster create-cluster \
    --cluster-name ${CLUSTER_NAME} \
    --cluster-configuration cluster-config.yaml \
    --region ${AWS_REGION}
```

##  CloudWatch 대시보드 예제

### GPU 모니터링 대시보드

```json
{
    "widgets": [
        {
            "type": "metric",
            "properties": {
                "metrics": [
                    [ "ParallelCluster/${CLUSTER_NAME}/GPU", "GPUUtilization", { "stat": "Average" } ]
                ],
                "title": "GPU 사용률",
                "region": "${AWS_REGION}",
                "period": 60
            }
        },
        {
            "type": "metric",
            "properties": {
                "metrics": [
                    [ "ParallelCluster/${CLUSTER_NAME}/GPU", "GPUTemperature", { "stat": "Maximum" } ]
                ],
                "title": "GPU 온도",
                "region": "${AWS_REGION}",
                "period": 60,
                "yAxis": {
                    "left": {
                        "min": 0,
                        "max": 100
                    }
                }
            }
        },
        {
            "type": "metric",
            "properties": {
                "metrics": [
                    [ "ParallelCluster/${CLUSTER_NAME}/GPU", "GPUPowerUsage", { "stat": "Average" } ]
                ],
                "title": "GPU 전력 소비",
                "region": "${AWS_REGION}",
                "period": 60
            }
        },
        {
            "type": "metric",
            "properties": {
                "metrics": [
                    [ "ParallelCluster/${CLUSTER_NAME}/GPU", "GPUMemoryUsed", { "stat": "Average" } ],
                    [ ".", "GPUMemoryFree", { "stat": "Average" } ]
                ],
                "title": "GPU 메모리",
                "region": "${AWS_REGION}",
                "period": 60
            }
        }
    ]
}
```

## ️ 트러블슈팅

### 문제: CloudWatch에 메트릭이 나타나지 않음

**확인 사항:**

1. 서비스 상태 확인
```bash
sudo systemctl status dcgm-cloudwatch-exporter
```

2. 로그 확인
```bash
sudo journalctl -u dcgm-cloudwatch-exporter -f
```

3. Prometheus 연결 확인
```bash
curl http://localhost:9090/api/v1/query?query=DCGM_FI_DEV_GPU_UTIL
```

4. IAM 권한 확인
```bash
# HeadNode IAM 역할에 CloudWatch PutMetricData 권한 필요
aws iam list-attached-role-policies --role-name <HeadNode-Role>
```

### 문제: 일부 GPU만 메트릭이 보임

**원인**: DCGM Exporter가 일부 ComputeNode에서만 실행 중

**해결:**
```bash
# 모든 ComputeNode에서 DCGM Exporter 상태 확인
srun --nodes=all systemctl status dcgm-exporter
```

### 문제: 메트릭 지연

**원인**: 기본 스크랩 간격이 60초

**해결:**
```bash
# 스크랩 간격 변경 (30초)
sudo systemctl edit dcgm-cloudwatch-exporter

# 추가:
[Service]
Environment="SCRAPE_INTERVAL=30"

# 재시작
sudo systemctl restart dcgm-cloudwatch-exporter
```

##  비용 영향

### CloudWatch 메트릭 비용

- **커스텀 메트릭**: $0.30 per metric per month
- **API 요청**: $0.01 per 1,000 GetMetricStatistics requests

### 예상 비용 (p5en.48xlarge x 2 nodes)

- GPU 메트릭: 6개 x 8 GPUs x 2 nodes = 96 metrics
- 월 비용: 96 x $0.30 = **$28.80/month**

### 비용 절감 팁

1. **필요한 메트릭만 수집**
```python
# dcgm-to-cloudwatch.sh에서 불필요한 메트릭 제거
DCGM_METRICS = {
    'DCGM_FI_DEV_GPU_UTIL': {...},  # 필수
    'DCGM_FI_DEV_GPU_TEMP': {...},  # 필수
    # 'DCGM_FI_DEV_FB_FREE': {...},  # 제거
}
```

2. **스크랩 간격 늘리기**
```bash
Environment="SCRAPE_INTERVAL=300"  # 5분마다
```

##  관련 문서

- [DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter)
- [CloudWatch Custom Metrics](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/publishingMetrics.html)
- [Prometheus Python Client](https://github.com/prometheus/client_python)

##  요약

### 권장 방법: DCGM → CloudWatch 직접 전송

**장점:**
-  CloudWatch 대시보드에서 GPU 메트릭 확인 가능
-  CloudWatch Alarms 설정 가능
-  다른 AWS 서비스와 통합 용이

**단점:**
- ️ 추가 비용 (~$30/month for 2 nodes)
- ️ 약간의 지연 (60초 스크랩 간격)

**대안:**
- Grafana만 사용 (비용 없음, 실시간)
- AMP + AMG 사용 (완전 관리형)
