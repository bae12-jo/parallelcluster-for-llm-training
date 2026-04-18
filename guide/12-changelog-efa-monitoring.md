# EFA 네트워크 모니터링 통합 완료

## 변경 사항 요약

EFA (Elastic Fabric Adapter) 네트워크 모니터링이 ParallelCluster에 완전히 통합되었습니다. GPU 컴퓨트 노드에서 자동으로 설치 및 실행됩니다.

## 추가된 파일

### 1. 모니터링 스크립트
- `config/monitoring/efa_network_monitor.py` - EFA 통계 수집 및 CloudWatch 전송
- `config/monitoring/setup-efa-monitoring.sh` - 모니터링 서비스 설치 스크립트
- `config/monitoring/README.md` - 모니터링 디렉토리 문서

### 2. CloudWatch 대시보드
- `config/cloudwatch/create-efa-dashboard.sh` - EFA 대시보드 생성 스크립트

### 3. 문서
- `guide/EFA-MONITORING.md` - 상세 가이드 (아키텍처, 설치, 사용법)
- `QUICKSTART-EFA-MONITORING.md` - 빠른 시작 가이드
- `CHANGELOG-EFA-MONITORING.md` - 이 파일

### 4. 유틸리티
- `scripts/upload-monitoring-scripts.sh` - S3 업로드 스크립트

## 수정된 파일

### 1. Compute Node Setup (`config/compute/setup-compute-node.sh`)

**추가된 섹션**:
```bash
# Install EFA Network Monitor (for GPU instances with EFA) - Optional
if [ "$SETUP_TYPE" = "gpu" ] && [ "${ENABLE_EFA_INSTALLER}" = "true" ]; then
    # EFA 모니터링 설치 로직
fi
```

**위치**: Node Exporter 설치 직후, NCCL 설정 이전

**동작**:
- GPU 인스턴스에서만 실행
- S3에서 스크립트 다운로드
- systemd 서비스로 등록
- 자동 시작 및 재시작 설정

### 2. Head Node Setup (`config/headnode/setup-headnode.sh`)

**추가된 섹션**:
```bash
# Create EFA dashboard
aws s3 cp "s3://${S3_BUCKET}/config/cloudwatch/create-efa-dashboard.sh" /tmp/
bash /tmp/create-efa-dashboard.sh "${CLUSTER_NAME}" "${REGION}"
```

**위치**: CloudWatch 대시보드 생성 섹션

**동작**:
- 기본 및 고급 대시보드와 함께 EFA 대시보드 생성
- 백그라운드에서 실행 (클러스터 생성 차단 안 함)

### 3. README (`README.md`)

**추가된 섹션**:
- " Monitoring" 섹션에 EFA 모니터링 추가
- 통합 모니터링 스택 테이블
- 관련 가이드 링크

## 기능

### 자동 설치
-  GPU 컴퓨트 노드에 자동 설치
-  EFA 인터페이스 자동 감지
-  systemd 서비스로 등록
-  부팅 시 자동 시작
-  실패 시 자동 재시작

### 메트릭 수집
-  수신/송신 처리량 (Bytes/Second)
-  수신/송신 패킷 속도 (Count/Second)
-  수신 오류 (Count)
-  송신 폐기 (Count)

### CloudWatch 통합
-  배치 전송 (5분마다)
-  자동 대시보드 생성
-  인스턴스별 메트릭
-  인터페이스별 메트릭

### 성능 최적화
-  CPU 사용률 <5% (systemd 제한)
-  메모리 사용량 <256MB (systemd 제한)
-  로그 자동 로테이션 (7일)
-  최소 네트워크 오버헤드

## 사용 방법

### 1. 스크립트 업로드

```bash
cd parallelcluster-for-llm
source environment-variables-bailey.sh
bash scripts/upload-monitoring-scripts.sh ${S3_BUCKET} ${REGION}
```

### 2. 클러스터 생성/업데이트

```bash
# 설정 생성
envsubst < cluster-config.yaml.template > cluster-config.yaml

# 클러스터 생성
pcluster create-cluster \
  --cluster-name ${CLUSTER_NAME} \
  --cluster-configuration cluster-config.yaml
```

### 3. 확인

```bash
# 컴퓨트 노드 접속
pcluster ssh --cluster-name ${CLUSTER_NAME} -i ~/.ssh/${KEY_PAIR_NAME}.pem

# 서비스 상태
sudo systemctl status efa-monitor

# 실시간 로그
sudo tail -f /var/log/efa_monitor.log
```

### 4. 대시보드 확인

```bash
# CloudWatch 대시보드 URL
echo "https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=ParallelCluster-${CLUSTER_NAME}-EFA"
```

## 통합 포인트

### Compute Node Setup 통합

**조건부 설치**:
```bash
if [ "$SETUP_TYPE" = "gpu" ] && [ "${ENABLE_EFA_INSTALLER}" = "true" ]; then
    # EFA 모니터링 설치
fi
```

**설치 순서**:
1. EFA Driver
2. Docker + NVIDIA Toolkit
3. CloudWatch Agent
4. DCGM Exporter
5. Node Exporter
6. **EFA Network Monitor** ← 새로 추가
7. NCCL 설정

### Head Node Setup 통합

**대시보드 생성 순서**:
1. 기본 대시보드 (ParallelCluster-{cluster})
2. 고급 대시보드 (ParallelCluster-{cluster}-Advanced)
3. **EFA 대시보드** (ParallelCluster-{cluster}-EFA) ← 새로 추가

## 기존 코드와의 호환성

###  기존 기능 유지
- 모든 기존 모니터링 기능 정상 작동
- DCGM Exporter와 독립적으로 동작
- Node Exporter와 독립적으로 동작
- CloudWatch Agent와 독립적으로 동작

###  조건부 설치
- GPU 인스턴스에만 설치
- EFA 인터페이스가 없으면 자동 스킵
- 설치 실패 시 클러스터 생성 계속 진행

###  리소스 격리
- 독립적인 systemd 서비스
- 독립적인 로그 파일
- 독립적인 CloudWatch 네임스페이스

## 테스트 체크리스트

### 설치 테스트
- [ ] GPU 인스턴스에 자동 설치 확인
- [ ] CPU 인스턴스에 설치 안 됨 확인
- [ ] EFA 없는 인스턴스에 설치 안 됨 확인
- [ ] systemd 서비스 정상 시작 확인

### 메트릭 테스트
- [ ] CloudWatch에 메트릭 전송 확인
- [ ] 대시보드 자동 생성 확인
- [ ] 메트릭 값 정상 확인 (학습 중)
- [ ] 오류 메트릭 0 확인

### 성능 테스트
- [ ] CPU 사용률 <5% 확인
- [ ] 메모리 사용량 <256MB 확인
- [ ] 로그 로테이션 동작 확인
- [ ] 서비스 재시작 동작 확인

### 통합 테스트
- [ ] 기존 모니터링과 충돌 없음 확인
- [ ] 클러스터 생성 시간 영향 없음 확인
- [ ] 클러스터 업데이트 정상 동작 확인
- [ ] 클러스터 삭제 정상 동작 확인

## 비용 영향

### 추가 비용 (4 노드 기준)
- CloudWatch 메트릭: $7.20/월
- CloudWatch API 호출: $0.17/월
- CloudWatch 대시보드: $3.00/월
- **총 추가 비용**: ~$10.37/월

### 비용 최적화 옵션
- 수집 간격 증가 (60초 → 300초)
- 배치 크기 증가 (5분 → 10분)
- 필요 시 서비스 중지

## 문서 업데이트

### 새 문서
- `guide/EFA-MONITORING.md` - 완전한 가이드
- `QUICKSTART-EFA-MONITORING.md` - 빠른 시작

### 업데이트된 문서
- `README.md` - 모니터링 섹션 추가
- `config/monitoring/README.md` - 새로 생성

## 다음 단계

### 사용자 액션
1. S3에 스크립트 업로드
2. 클러스터 생성 또는 업데이트
3. 대시보드 확인
4. 학습 중 메트릭 모니터링

### 선택적 설정
- 수집 간격 조정
- 대시보드 커스터마이징
- 알람 설정
- Grafana 통합

## 참고 사항

### 자동 설치 조건
-  인스턴스 타입: EFA 지원 (p4d, p5, p5en)
-  Setup Type: `gpu` (5번째 인자)
-  S3에 스크립트 업로드 완료
-  CloudWatch IAM 권한 설정

### 수동 설치가 필요한 경우
- 기존 클러스터에 추가
- 커스텀 설정 필요
- 테스트 및 디버깅

### 문제 해결
- 로그 확인: `/var/log/efa_monitor.log`
- 서비스 상태: `systemctl status efa-monitor`
- 수동 실행: `python3 /opt/monitoring/efa_network_monitor.py`

## 관련 문서

- [EFA 모니터링 가이드](guide/EFA-MONITORING.md)
- [빠른 시작 가이드](QUICKSTART-EFA-MONITORING.md)
- [DCGM 모니터링](guide/DCGM-TO-CLOUDWATCH.md)
- [NVLink 모니터링](guide/NVLINK-MONITORING.md)
- [CloudWatch 모니터링](guide/MONITORING.md)
