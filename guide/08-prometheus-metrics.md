# Prometheus 수집 메트릭 가이드

ParallelCluster HeadNode의 Prometheus가 수집하는 모든 메트릭에 대한 상세 가이드입니다.

##  메트릭 수집 구조

```
ComputeNode (GPU 모드)
├── DCGM Exporter (port 9400)
│   └── GPU 메트릭 → Prometheus
└── Node Exporter (port 9100)
    └── 시스템 메트릭 → Prometheus

HeadNode
└── Prometheus (port 9090)
    ├── 로컬 저장 (self-hosting)
    └── AMP remote_write (amp-only, amp+amg)
```

##  DCGM Exporter 메트릭 (GPU)

**Job Name**: `dcgm`  
**Port**: 9400  
**수집 주기**: 15초

### GPU 사용률
```promql
# GPU 사용률 (0-100%)
DCGM_FI_DEV_GPU_UTIL{gpu="0", instance_id="i-xxxxx"}

# 예제 쿼리: 평균 GPU 사용률
avg(DCGM_FI_DEV_GPU_UTIL)

# 예제 쿼리: GPU별 사용률
DCGM_FI_DEV_GPU_UTIL{gpu="0"}
```

### GPU 메모리
```promql
# GPU 메모리 사용률 (0-100%)
DCGM_FI_DEV_MEM_COPY_UTIL{gpu="0"}

# GPU 메모리 사용량 (MB)
DCGM_FI_DEV_FB_USED{gpu="0"}

# GPU 메모리 여유 공간 (MB)
DCGM_FI_DEV_FB_FREE{gpu="0"}

# 예제 쿼리: 총 GPU 메모리 사용량
sum(DCGM_FI_DEV_FB_USED)
```

### GPU 온도
```promql
# GPU 온도 (°C)
DCGM_FI_DEV_GPU_TEMP{gpu="0"}

# 예제 쿼리: 최고 온도
max(DCGM_FI_DEV_GPU_TEMP)

# 예제 쿼리: 온도 경고 (85°C 이상)
DCGM_FI_DEV_GPU_TEMP > 85
```

### GPU 전력
```promql
# GPU 전력 소비 (W)
DCGM_FI_DEV_POWER_USAGE{gpu="0"}

# 예제 쿼리: 총 전력 소비
sum(DCGM_FI_DEV_POWER_USAGE)

# 예제 쿼리: 평균 전력 소비 (5분)
avg_over_time(DCGM_FI_DEV_POWER_USAGE[5m])
```

### GPU 클럭
```promql
# SM (Streaming Multiprocessor) 클럭 (MHz)
DCGM_FI_DEV_SM_CLOCK{gpu="0"}

# 메모리 클럭 (MHz)
DCGM_FI_DEV_MEM_CLOCK{gpu="0"}
```

### GPU 에러
```promql
# ECC 에러 (Single-bit)
DCGM_FI_DEV_ECC_SBE_VOL_TOTAL{gpu="0"}

# ECC 에러 (Double-bit)
DCGM_FI_DEV_ECC_DBE_VOL_TOTAL{gpu="0"}

# XID 에러
DCGM_FI_DEV_XID_ERRORS{gpu="0"}
```

### GPU PCIe
```promql
# PCIe 송신 처리량 (KB/s)
DCGM_FI_DEV_PCIE_TX_THROUGHPUT{gpu="0"}

# PCIe 수신 처리량 (KB/s)
DCGM_FI_DEV_PCIE_RX_THROUGHPUT{gpu="0"}

# PCIe 재생 횟수
DCGM_FI_DEV_PCIE_REPLAY_COUNTER{gpu="0"}
```

### NVLINK (H100)
```promql
# NVLINK 대역폭 사용률
DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL{gpu="0"}

# NVLINK 에러
DCGM_FI_PROF_NVLINK_RX_BYTES{gpu="0"}
DCGM_FI_PROF_NVLINK_TX_BYTES{gpu="0"}
```

## ️ Node Exporter 메트릭 (시스템)

**Job Name**: `compute-nodes`  
**Port**: 9100  
**수집 주기**: 15초

### CPU
```promql
# CPU 사용 시간 (초)
node_cpu_seconds_total{mode="idle", instance_id="i-xxxxx"}
node_cpu_seconds_total{mode="user"}
node_cpu_seconds_total{mode="system"}
node_cpu_seconds_total{mode="iowait"}

# 예제 쿼리: CPU 사용률 (%)
100 - (avg by (instance_id) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 예제 쿼리: CPU 코어별 사용률
rate(node_cpu_seconds_total{mode!="idle"}[5m])
```

### 메모리
```promql
# 총 메모리 (bytes)
node_memory_MemTotal_bytes

# 사용 가능한 메모리 (bytes)
node_memory_MemAvailable_bytes

# 사용 중인 메모리 (bytes)
node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes

# 예제 쿼리: 메모리 사용률 (%)
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# 버퍼/캐시
node_memory_Buffers_bytes
node_memory_Cached_bytes

# Swap
node_memory_SwapTotal_bytes
node_memory_SwapFree_bytes
```

### 디스크
```promql
# 디스크 사용 공간 (bytes)
node_filesystem_size_bytes{mountpoint="/"}
node_filesystem_avail_bytes{mountpoint="/"}
node_filesystem_used_bytes{mountpoint="/"}

# 예제 쿼리: 디스크 사용률 (%)
(node_filesystem_size_bytes{mountpoint="/"} - node_filesystem_avail_bytes{mountpoint="/"}) / node_filesystem_size_bytes{mountpoint="/"} * 100

# FSx Lustre
node_filesystem_size_bytes{mountpoint="/fsx"}
node_filesystem_avail_bytes{mountpoint="/fsx"}
```

### 디스크 I/O
```promql
# 읽기 바이트 (bytes)
rate(node_disk_read_bytes_total[5m])

# 쓰기 바이트 (bytes)
rate(node_disk_written_bytes_total[5m])

# I/O 시간 (초)
rate(node_disk_io_time_seconds_total[5m])

# 예제 쿼리: 디스크 처리량 (MB/s)
rate(node_disk_read_bytes_total[5m]) / 1024 / 1024
rate(node_disk_written_bytes_total[5m]) / 1024 / 1024
```

### 네트워크
```promql
# 수신 바이트 (bytes)
rate(node_network_receive_bytes_total{device="eth0"}[5m])

# 송신 바이트 (bytes)
rate(node_network_transmit_bytes_total{device="eth0"}[5m])

# 예제 쿼리: 네트워크 처리량 (Mbps)
rate(node_network_receive_bytes_total{device="eth0"}[5m]) * 8 / 1000000
rate(node_network_transmit_bytes_total{device="eth0"}[5m]) * 8 / 1000000

# 에러 및 드롭
node_network_receive_errs_total
node_network_transmit_errs_total
node_network_receive_drop_total
node_network_transmit_drop_total
```

### 시스템 부하
```promql
# Load Average
node_load1   # 1분 평균
node_load5   # 5분 평균
node_load15  # 15분 평균

# 예제 쿼리: CPU 코어당 부하
node_load5 / count(node_cpu_seconds_total{mode="idle"})
```

### 프로세스
```promql
# 실행 중인 프로세스 수
node_procs_running

# 차단된 프로세스 수
node_procs_blocked

# 총 프로세스 수
node_processes_state{state="running"}
node_processes_state{state="sleeping"}
node_processes_state{state="zombie"}
```

### 시스템 정보
```promql
# 부팅 시간 (Unix timestamp)
node_boot_time_seconds

# 예제 쿼리: 업타임 (시간)
(time() - node_boot_time_seconds) / 3600

# 컨텍스트 스위치
rate(node_context_switches_total[5m])

# 인터럽트
rate(node_intr_total[5m])
```

##  유용한 PromQL 쿼리 예제

### GPU 모니터링

#### 1. 전체 GPU 사용률
```promql
# 평균 GPU 사용률
avg(DCGM_FI_DEV_GPU_UTIL)

# 노드별 평균 GPU 사용률
avg by (instance_id) (DCGM_FI_DEV_GPU_UTIL)

# GPU별 사용률
DCGM_FI_DEV_GPU_UTIL
```

#### 2. GPU 메모리 사용률
```promql
# GPU 메모리 사용률 (%)
(DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)) * 100

# 노드별 총 GPU 메모리 사용량
sum by (instance_id) (DCGM_FI_DEV_FB_USED)
```

#### 3. GPU 온도 경고
```promql
# 85°C 이상인 GPU
DCGM_FI_DEV_GPU_TEMP > 85

# 최고 온도
max(DCGM_FI_DEV_GPU_TEMP)
```

#### 4. GPU 전력 소비
```promql
# 총 전력 소비 (W)
sum(DCGM_FI_DEV_POWER_USAGE)

# 노드별 전력 소비
sum by (instance_id) (DCGM_FI_DEV_POWER_USAGE)

# 5분 평균 전력 소비
avg_over_time(sum(DCGM_FI_DEV_POWER_USAGE)[5m:])
```

### 시스템 모니터링

#### 1. CPU 사용률
```promql
# 전체 CPU 사용률 (%)
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 노드별 CPU 사용률
100 - (avg by (instance_id) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

#### 2. 메모리 사용률
```promql
# 메모리 사용률 (%)
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# 사용 중인 메모리 (GB)
(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / 1024 / 1024 / 1024
```

#### 3. 디스크 I/O
```promql
# 읽기 처리량 (MB/s)
rate(node_disk_read_bytes_total[5m]) / 1024 / 1024

# 쓰기 처리량 (MB/s)
rate(node_disk_written_bytes_total[5m]) / 1024 / 1024

# 총 I/O 처리량
(rate(node_disk_read_bytes_total[5m]) + rate(node_disk_written_bytes_total[5m])) / 1024 / 1024
```

#### 4. 네트워크 대역폭
```promql
# 수신 대역폭 (Mbps)
rate(node_network_receive_bytes_total{device="eth0"}[5m]) * 8 / 1000000

# 송신 대역폭 (Mbps)
rate(node_network_transmit_bytes_total{device="eth0"}[5m]) * 8 / 1000000

# EFA 네트워크 (p5 인스턴스)
rate(node_network_receive_bytes_total{device=~"efa.*"}[5m]) * 8 / 1000000
```

### 분산 학습 모니터링

#### 1. 멀티 노드 GPU 사용률
```promql
# 모든 노드의 평균 GPU 사용률
avg(DCGM_FI_DEV_GPU_UTIL)

# 노드별 GPU 사용률 (8 GPU per node)
avg by (instance_id) (DCGM_FI_DEV_GPU_UTIL)

# GPU 사용률 분산 (표준편차)
stddev(DCGM_FI_DEV_GPU_UTIL)
```

#### 2. 네트워크 통신 (All-Reduce)
```promql
# 노드 간 네트워크 트래픽
sum(rate(node_network_transmit_bytes_total[5m]))

# NVLINK 대역폭 (노드 내 GPU 통신)
sum(DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL)
```

#### 3. 학습 병목 감지
```promql
# GPU 사용률이 낮은 노드 (< 50%)
DCGM_FI_DEV_GPU_UTIL < 50

# CPU I/O wait이 높은 노드 (> 20%)
rate(node_cpu_seconds_total{mode="iowait"}[5m]) * 100 > 20

# 메모리 부족 노드 (> 90%)
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90
```

##  Grafana 대시보드 예제

### GPU 대시보드 패널

#### Panel 1: GPU 사용률
```promql
# Query
avg(DCGM_FI_DEV_GPU_UTIL)

# Visualization: Gauge
# Thresholds: 
#   - Green: 0-70
#   - Yellow: 70-90
#   - Red: 90-100
```

#### Panel 2: GPU 메모리
```promql
# Query
sum(DCGM_FI_DEV_FB_USED) / 1024  # GB

# Visualization: Time series
# Unit: GB
```

#### Panel 3: GPU 온도
```promql
# Query
max(DCGM_FI_DEV_GPU_TEMP)

# Visualization: Stat
# Thresholds:
#   - Green: 0-75
#   - Yellow: 75-85
#   - Red: 85-100
```

#### Panel 4: GPU 전력
```promql
# Query
sum(DCGM_FI_DEV_POWER_USAGE)

# Visualization: Time series
# Unit: Watt
```

### 시스템 대시보드 패널

#### Panel 1: CPU 사용률
```promql
# Query
100 - (avg by (instance_id) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Visualization: Time series
# Legend: {{instance_id}}
```

#### Panel 2: 메모리 사용률
```promql
# Query
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# Visualization: Gauge
```

#### Panel 3: 네트워크 I/O
```promql
# Query A (Receive)
rate(node_network_receive_bytes_total{device="eth0"}[5m]) * 8 / 1000000

# Query B (Transmit)
rate(node_network_transmit_bytes_total{device="eth0"}[5m]) * 8 / 1000000

# Visualization: Time series
# Unit: Mbps
```

##  메트릭 보존 기간

### Self-hosting
- **로컬 저장**: 15일 (기본값)
- **설정 위치**: `/opt/prometheus/prometheus.yml`
- **변경 방법**: `--storage.tsdb.retention.time=30d`

### AMP (amp-only, amp+amg)
- **로컬 저장**: 1시간 (임시)
- **AMP 저장**: 150일 (자동)
- **비용**: 저장 용량에 따라 과금

##  메트릭 확인 방법

### Prometheus UI
```bash
# HeadNode에서
curl http://localhost:9090/api/v1/targets

# 브라우저에서 (포트 포워딩 필요)
ssh -L 9090:localhost:9090 headnode
# http://localhost:9090
```

### PromQL 쿼리
```bash
# 메트릭 목록 확인
curl http://localhost:9090/api/v1/label/__name__/values

# 특정 메트릭 쿼리
curl 'http://localhost:9090/api/v1/query?query=DCGM_FI_DEV_GPU_UTIL'
```

### Grafana Explore
1. Grafana → Explore
2. Data source: Amazon Managed Prometheus
3. Metric browser에서 메트릭 선택
4. Run query

##  요약

### GPU 메트릭 (DCGM)
-  사용률, 메모리, 온도, 전력
-  클럭, PCIe, NVLINK
-  ECC 에러, XID 에러
- **총**: ~50개 메트릭

### 시스템 메트릭 (Node Exporter)
-  CPU, 메모리, 디스크, 네트워크
-  부하, 프로세스, I/O
- **총**: ~200개 메트릭

### 수집 주기
- **Scrape interval**: 15초
- **Evaluation interval**: 15초
- **Remote write**: 30초 (AMP)

### 저장 용량 예상
- **노드당**: ~1-2 MB/hour
- **10 노드**: ~10-20 MB/hour
- **월간**: ~7-15 GB/month
