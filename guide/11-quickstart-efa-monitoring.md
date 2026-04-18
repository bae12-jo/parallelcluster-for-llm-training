# EFA 네트워크 모니터링 빠른 시작 가이드

## 개요

EFA (Elastic Fabric Adapter) 네트워크 모니터링은 GPU 인스턴스 간 통신 성능을 실시간으로 추적합니다.

## 자동 설치

EFA 모니터링은 **GPU 컴퓨트 노드에 자동으로 설치**됩니다. 별도 설정이 필요 없습니다.

### 설치 조건

-  인스턴스 타입: EFA 지원 (p4d, p5, p5en)
-  Setup Type: `gpu` (5번째 인자)
-  S3에 스크립트 업로드 완료

## 배포 단계

### 1. 스크립트 업로드

```bash
cd parallelcluster-for-llm
source environment-variables-bailey.sh

# 모니터링 스크립트 업로드
bash scripts/upload-monitoring-scripts.sh ${S3_BUCKET} ${REGION}
```

### 2. 클러스터 설정 생성

```bash
# 환경 변수로 설정 생성
envsubst < cluster-config.yaml.template > cluster-config.yaml
```

### 3. 클러스터 생성 또는 업데이트

```bash
# 새 클러스터 생성
pcluster create-cluster \
  --cluster-name ${CLUSTER_NAME} \
  --cluster-configuration cluster-config.yaml

# 기존 클러스터 업데이트
pcluster update-cluster \
  --cluster-name ${CLUSTER_NAME} \
  --cluster-configuration cluster-config.yaml
```

### 4. 확인

```bash
# 컴퓨트 노드에 SSH 접속
pcluster ssh --cluster-name ${CLUSTER_NAME} -i ~/.ssh/${KEY_PAIR_NAME}.pem

# EFA 모니터링 서비스 상태 확인
sudo systemctl status efa-monitor

# 실시간 로그 확인
sudo tail -f /var/log/efa_monitor.log

# 출력 예시:
# rdmap0s6: RX=125.34 Mbps, TX=98.21 Mbps
```

## 메트릭 확인

### CloudWatch 메트릭

```bash
# 메트릭 목록 확인
aws cloudwatch list-metrics \
  --namespace ParallelCluster/Network \
  --region ${REGION}

# 메트릭 조회
aws cloudwatch get-metric-statistics \
  --namespace ParallelCluster/Network \
  --metric-name rx_bytes_rate \
  --dimensions Name=InstanceId,Value=i-1234567890abcdef0 \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-01T01:00:00Z \
  --period 60 \
  --statistics Average \
  --region ${REGION}
```

### CloudWatch 대시보드

대시보드는 HeadNode 초기화 시 자동으로 생성됩니다:

```bash
# 대시보드 URL 확인
echo "https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=ParallelCluster-${CLUSTER_NAME}-EFA"
```

또는 수동으로 생성:

```bash
cd parallelcluster-for-llm/config/cloudwatch
bash create-efa-dashboard.sh ${CLUSTER_NAME} ${REGION}
```

## 수집되는 메트릭

| 메트릭 | 단위 | 설명 |
|--------|------|------|
| `rx_bytes_rate` | Bytes/Second | 수신 처리량 |
| `tx_bytes_rate` | Bytes/Second | 송신 처리량 |
| `rx_packets_rate` | Count/Second | 수신 패킷 속도 |
| `tx_packets_rate` | Count/Second | 송신 패킷 속도 |
| `rx_errors` | Count | 수신 오류 (누적) |
| `tx_discards` | Count | 송신 폐기 (누적) |

## 성능 기준

### p5en.48xlarge

- **EFA 대역폭**: 3200 Gbps (400 GB/s)
- **EFA 인터페이스**: 32x 100 Gbps
- **예상 처리량**:
  - NCCL All-Reduce: ~2800 Gbps
  - Point-to-point: ~3000 Gbps

### 정상 동작 확인

```bash
# 학습 중 EFA 사용률 확인
sudo tail -f /var/log/efa_monitor.log

# 예상 출력 (학습 중):
# rdmap0s6: RX=2500.00 Mbps, TX=2500.00 Mbps  ← 높은 처리량
# rdmap0s6: RX=0.00 Mbps, TX=0.00 Mbps        ← 유휴 상태

# 오류 확인 (0이어야 정상)
grep -E "rx_errors|tx_discards" /var/log/efa_monitor.log
```

## 문제 해결

### 서비스가 시작되지 않음

```bash
# 상세 로그 확인
sudo journalctl -u efa-monitor -n 50

# EFA 인터페이스 확인
ls -la /sys/class/infiniband/

# 수동 실행 (테스트)
sudo python3 /opt/monitoring/efa_network_monitor.py
```

### CloudWatch에 메트릭이 없음

```bash
# IAM 권한 확인
aws cloudwatch put-metric-data \
  --namespace Test \
  --metric-name TestMetric \
  --value 1

# 스크립트 실행 확인
ps aux | grep efa_network_monitor

# 로그 확인
sudo tail -100 /var/log/efa_monitor.log
```

### CPU 사용률이 높음

정상적으로 <5% CPU를 사용해야 합니다. 높은 경우:

```bash
# 수집 간격 확인 (60초여야 함)
grep COLLECTION_INTERVAL /opt/monitoring/efa_network_monitor.py

# 서비스 재시작
sudo systemctl restart efa-monitor
```

## 비용

### 월간 예상 비용 (4 노드)

- **메트릭**: 6개 × 4노드 × $0.30 = $7.20
- **API 호출**: ~17,000회 × $0.01/1000 = $0.17
- **대시보드**: $3.00
- **총계**: ~$10.37/월

### 비용 최적화

```bash
# 수집 간격 늘리기 (API 호출 감소)
sudo vim /opt/monitoring/efa_network_monitor.py
# COLLECTION_INTERVAL = 300  # 5분으로 변경

# 배치 크기 늘리기
# BATCH_SIZE = 10  # 10분으로 변경

# 서비스 재시작
sudo systemctl restart efa-monitor
```

## 서비스 관리

```bash
# 상태 확인
sudo systemctl status efa-monitor

# 시작
sudo systemctl start efa-monitor

# 중지
sudo systemctl stop efa-monitor

# 재시작
sudo systemctl restart efa-monitor

# 부팅 시 자동 시작 활성화
sudo systemctl enable efa-monitor

# 부팅 시 자동 시작 비활성화
sudo systemctl disable efa-monitor

# 로그 확인
sudo journalctl -u efa-monitor -f
sudo tail -f /var/log/efa_monitor.log
```

## 통합 모니터링

EFA 모니터링은 다른 모니터링 도구와 함께 작동합니다:

- **DCGM Exporter**: GPU 메트릭 (포트 9400)
- **Node Exporter**: 시스템 메트릭 (포트 9100)
- **CloudWatch Agent**: 시스템 + 커스텀 메트릭
- **Prometheus**: 메트릭 집계 (HeadNode)

모든 메트릭은 다음에서 확인 가능:
- CloudWatch (AWS Console)
- Prometheus (self-hosting 모드)
- Grafana (AMG 사용 시)

## 관련 문서

- [EFA 모니터링 상세 가이드](guide/EFA-MONITORING.md)
- [DCGM 모니터링](guide/DCGM-TO-CLOUDWATCH.md)
- [NVLink 모니터링](guide/NVLINK-MONITORING.md)
- [CloudWatch 모니터링](guide/MONITORING.md)

## 참고 자료

- [AWS EFA 문서](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [EFA 성능](https://aws.amazon.com/hpc/efa/)
- [NCCL with EFA](https://github.com/aws/aws-ofi-nccl)
