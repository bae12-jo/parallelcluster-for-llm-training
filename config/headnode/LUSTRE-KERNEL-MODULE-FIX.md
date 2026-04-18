# Lustre Kernel Module Version Mismatch 해결 가이드

## 문제 원인

### 근본 원인
1. **Ubuntu 자동 보안 업데이트**
   - `unattended-upgrades` 패키지가 백그라운드에서 커널 자동 업데이트
   - 클러스터 생성 후 몇 시간~며칠 내에 발생 가능

2. **Lustre 모듈의 커널 의존성**
   - Lustre 클라이언트 모듈은 정확한 커널 버전에 매칭되어야 함
   - 커널 `6.8.0-1039`용 모듈은 `6.8.0-1042`에서 작동 안 함

3. **발생 시나리오**
   ```
   클러스터 생성 (커널 6.8.0-1039)
   → Lustre 모듈 6.8.0-1039 설치
   → 자동 업데이트로 커널 6.8.0-1042 설치
   → 재부팅
   → 커널 6.8.0-1042로 부팅
   → Lustre 모듈 6.8.0-1039는 호환 안 됨
   → /fsx 마운트 실패
   ```

## 해결 방법

### 방법 1: 즉시 수동 수정 (긴급)

```bash
# 헤드노드에서 실행
sudo su

# 현재 커널 확인
uname -r

# 매칭되는 Lustre 모듈 설치
apt-get update
apt-get install -y lustre-client-modules-$(uname -r)

# Lustre 모듈 로드
modprobe lustre

# /fsx 마운트
systemctl restart fsx.mount

# 확인
df -h | grep fsx
```

### 방법 2: 자동 수정 스크립트 (권장)

#### A. setup-headnode.sh에 통합

`setup-headnode.sh` 시작 부분에 추가:

```bash
#!/bin/bash

# Fix Lustre module before anything else
echo "=== Checking Lustre kernel module ==="
KERNEL_VERSION=$(uname -r)

if [ ! -d "/lib/modules/${KERNEL_VERSION}/updates/kernel/fs/lustre" ]; then
    echo "Installing Lustre module for ${KERNEL_VERSION}..."
    apt-get update -qq
    apt-get install -y lustre-client-modules-${KERNEL_VERSION}
fi

if ! lsmod | grep -q lustre; then
    modprobe lustre
fi

if ! mountpoint -q /fsx; then
    systemctl restart fsx.mount
    sleep 2
fi

echo " Lustre ready"
```

#### B. 독립 스크립트 사용

```bash
# S3에서 다운로드
aws s3 cp s3://pcluster-setup-269550163595/config/headnode/fix-lustre-module.sh /tmp/
sudo bash /tmp/fix-lustre-module.sh
```

#### C. CustomActions에 추가

`cluster-config.yaml.template`에 추가:

```yaml
HeadNode:
  CustomActions:
    OnNodeStart:  # 부팅 시마다 실행
      Sequence:
        - Script: 's3://pcluster-setup-269550163595/config/headnode/fix-lustre-module.sh'
    OnNodeConfigured:
      Sequence:
        - Script: 's3://pcluster-setup-269550163595/config/headnode/setup-headnode.sh'
```

### 방법 3: 커널 자동 업데이트 방지 (예방)

#### A. 클러스터 생성 시 적용

`environment-variables-bailey.sh`에 추가:

```bash
# HeadNode CustomActions에 커널 업데이트 방지 스크립트 추가
HEADNODE_CUSTOM_ACTIONS="
- Script: 's3://${S3_BUCKET}/config/headnode/disable-kernel-auto-update.sh'
- Script: 's3://${S3_BUCKET}/config/headnode/setup-headnode.sh'
  Args:
    - ${CLUSTER_NAME}
    - ${AWS_REGION}
"
```

#### B. 기존 클러스터에 적용

```bash
# 헤드노드에서 실행
sudo bash /fsx/config/headnode/disable-kernel-auto-update.sh
```

이 스크립트는:
-  커널 패키지를 자동 업데이트 블랙리스트에 추가
-  현재 커널 버전을 hold
-  Lustre 모듈을 현재 커널에 고정
-  부팅 시 Lustre 모듈 체크 서비스 생성

### 방법 4: Systemd 서비스로 자동화 (최고 안정성)

```bash
# /etc/systemd/system/lustre-module-check.service 생성
cat > /etc/systemd/system/lustre-module-check.service << 'EOF'
[Unit]
Description=Check and fix Lustre kernel module on boot
After=network.target
Before=fsx.mount

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix-lustre-module.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 스크립트 복사
sudo cp /fsx/config/headnode/fix-lustre-module.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/fix-lustre-module.sh

# 서비스 활성화
sudo systemctl daemon-reload
sudo systemctl enable lustre-module-check.service
```

## 권장 워크플로우

### 신규 클러스터 생성 시

1. **예방 조치 (권장)**
   ```bash
   # environment-variables-bailey.sh 수정
   # HeadNode CustomActions에 disable-kernel-auto-update.sh 추가
   
   # 클러스터 생성
   pcluster create-cluster --cluster-name my-cluster \
     --cluster-configuration cluster-config.yaml
   ```

2. **생성 후 확인**
   ```bash
   # 헤드노드 접속
   ssh headnode
   
   # Lustre 상태 확인
   /fsx/scripts/check-lustre.sh
   ```

### 기존 클러스터 수정 시

1. **즉시 수정**
   ```bash
   sudo bash /fsx/config/headnode/fix-lustre-module.sh
   ```

2. **영구 방지**
   ```bash
   sudo bash /fsx/config/headnode/disable-kernel-auto-update.sh
   ```

3. **확인**
   ```bash
   /fsx/scripts/check-lustre.sh
   apt-mark showhold | grep linux
   ```

## 트러블슈팅

### 증상: /fsx 마운트 실패

```bash
# 에러 확인
systemctl status fsx.mount
journalctl -u fsx.mount -n 50

# 일반적인 에러 메시지
# "mount.lustre: mount fs-xxx at /fsx failed: No such device"
# "Are the lustre modules loaded?"
```

**해결:**
```bash
# 1. 커널 버전 확인
uname -r

# 2. 설치된 Lustre 모듈 확인
dpkg -l | grep lustre-client-modules

# 3. 매칭되는 모듈 설치
sudo apt-get install -y lustre-client-modules-$(uname -r)

# 4. 모듈 로드
sudo modprobe lustre

# 5. 마운트 재시도
sudo systemctl restart fsx.mount
```

### 증상: 모듈 설치 실패

```bash
# 에러: "Unable to locate package lustre-client-modules-6.8.0-1042-aws"
```

**해결:**
```bash
# 1. FSx Lustre 레포지토리 확인
cat /etc/apt/sources.list.d/fsxlustreclientrepo.list

# 2. 레포지토리 업데이트
sudo apt-get update

# 3. 사용 가능한 모듈 확인
apt-cache search lustre-client-modules | grep $(uname -r | cut -d- -f1-2)

# 4. 레포지토리 재추가 (필요시)
wget -O - https://fsx-lustre-client-repo-public-keys.s3.amazonaws.com/fsx-ubuntu-public-key.asc | sudo apt-key add -
sudo bash -c 'echo "deb https://fsx-lustre-client-repo.s3.amazonaws.com/ubuntu jammy main" > /etc/apt/sources.list.d/fsxlustreclientrepo.list'
sudo apt-get update
```

## 파일 위치

생성된 스크립트들:

```
/fsx/config/headnode/
├── fix-lustre-module.sh              # Lustre 모듈 자동 수정
├── disable-kernel-auto-update.sh     # 커널 자동 업데이트 방지
└── download-ngc-containers.sh        # Lustre 체크 포함된 컨테이너 다운로드

/fsx/scripts/
└── check-lustre.sh                   # Lustre 헬스 체크

/etc/systemd/system/
└── lustre-module-check.service       # 부팅 시 자동 체크 서비스
```

## 모니터링

### 정기 체크

```bash
# Cron으로 매일 체크
echo "0 2 * * * root /fsx/scripts/check-lustre.sh >> /var/log/lustre-check.log 2>&1" | sudo tee -a /etc/crontab
```

### CloudWatch 알람

```bash
# Lustre 마운트 실패 시 알람
aws cloudwatch put-metric-alarm \
  --alarm-name lustre-mount-failed \
  --alarm-description "Lustre filesystem not mounted" \
  --metric-name LustreAvailable \
  --namespace ParallelCluster \
  --statistic Average \
  --period 300 \
  --threshold 1 \
  --comparison-operator LessThanThreshold
```

## 참고 자료

- [AWS FSx for Lustre Client](https://docs.aws.amazon.com/fsx/latest/LustreGuide/install-lustre-client.html)
- [Ubuntu Unattended Upgrades](https://help.ubuntu.com/community/AutomaticSecurityUpdates)
- [ParallelCluster CustomActions](https://docs.aws.amazon.com/parallelcluster/latest/ug/custom-bootstrap-actions-v3.html)
