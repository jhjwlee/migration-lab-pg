#!/usr/bin/env bash
# bootstrap.sh — Cloud Migration Lab 자원 일괄 생성
#
# 사용 환경:
#   - Azure Cloud Shell (권장, 키 관리 0)
#   - Linux/Mac/WSL 터미널
#   - SSH 키 입력 불필요 — VM은 cloud-init으로 셋업, 학생은 SSH 거의 안 씀
#
# 한 줄 실행:
#   curl -fsSL https://raw.githubusercontent.com/jhjwlee/migration-lab-pg/main/bootstrap.sh | bash
#
# 또는 환경변수 미리 지정:
#   export SUFFIX="jhj" LAB_PWD='MyLab@2026Pwd'
#   bash bootstrap.sh
#
# 진행 단계:
#   1. 사전 점검 (Azure CLI 로그인, 비밀번호 입력)
#   2. RG 생성
#   3. 소스 PG VM 생성 (cloud-init으로 PG 16 + 스키마 + 50K 시드 + logical 자동)
#   4. 타깃 PG Flexible Server 생성 (Part 1용, wal_level=logical 자동)
#   5. (선택) Azure SQL Database 생성 (Part 2용)
#   6. NSG 5432 오픈 (Migration Service 접근용)
#   7. 시드 완료 대기 + 검증
#   8. 환경변수 파일 출력 + 다음 단계 안내

set -euo pipefail

# ============================================================
# 🛡️ stdin 검사 — curl | bash 패턴 차단
# ============================================================
# 환경변수 LAB_PWD 가 주어지면 비대화형 OK
# 그렇지 않은데 stdin이 터미널 아니면 (파이프) 즉시 안내 후 종료
if [ ! -t 0 ] && [ -z "${LAB_PWD:-}" ]; then
  cat <<'EOF' >&2

❌ ERROR: stdin이 파이프입니다 (curl | bash 사용 추정)

비밀번호와 SUFFIX 입력이 필요한데 파이프 모드에서는 입력이 불가능합니다.
다음 두 가지 방법 중 하나를 사용해 주세요:

[방법 1] 다운로드 후 실행 (권장)
  curl -fsSL https://raw.githubusercontent.com/jhjwlee/migration-lab-pg/main/bootstrap.sh -o bootstrap.sh
  chmod +x bootstrap.sh
  ./bootstrap.sh

[방법 2] 환경변수로 미리 export
  export SUFFIX="jhj"
  read -s -p "Lab Password: " LAB_PWD; echo
  export LAB_PWD
  curl -fsSL .../bootstrap.sh | bash

EOF
  exit 1
fi


# ============================================================
# 기본값 + 환경변수
# ============================================================
# SUFFIX: 학생 식별자 (예: jhj, s001, 2026a) — RG 충돌 방지
SUFFIX="${SUFFIX:-}"

LOC="${LOC:-koreacentral}"
USER_NAME="${USER_NAME:-azureuser}"

# Repository raw URL (실제 push 후 변경)
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/jhjwlee/migration-lab-pg/main}"

# 색상
G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; B='\033[0;34m'; NC='\033[0m'
banner()  { echo ""; echo -e "${B}===== $1 =====${NC}"; }
ok()      { echo -e "${G}  ✓${NC} $1"; }
warn()    { echo -e "${Y}  ⚠${NC} $1"; }
abort()   { echo -e "${R}❌ $1${NC}"; exit 1; }

banner "🔄 Cloud Migration Lab — Bootstrap"

# ============================================================
# SUFFIX 검증 + 모든 자원 이름 구성
# ============================================================
# SUFFIX 정책:
#   - 영문 소문자 + 숫자만 (3~12자)
#   - Azure 자원 이름 제약 (PG Flex/SQL Server는 lowercase 알파벳만)
#   - 학생별 unique 식별자 역할 (예: jhj, s001, 2026a)

if [ -z "$SUFFIX" ]; then
  echo ""
  echo "  ▶ 학생 식별자 (suffix)를 입력하세요"
  echo "    - 영문 소문자 + 숫자 조합, 3~12자"
  echo "    - 예: jhj, s001, 2026a (자기 이니셜·학번 권장)"
  echo "    - 모든 자원 이름의 접미사로 사용됨"
  while true; do
    read -p "    SUFFIX: " SUFFIX
    if [[ "$SUFFIX" =~ ^[a-z0-9]{3,12}$ ]]; then
      break
    fi
    echo -e "${R}    형식 불일치. 영문 소문자 + 숫자, 3~12자 (예: jhj, s001)${NC}"
  done
fi

# SUFFIX 형식 재검증 (환경변수로 들어온 경우)
if [[ ! "$SUFFIX" =~ ^[a-z0-9]{3,12}$ ]]; then
  abort "SUFFIX 형식 오류: '$SUFFIX' (영문 소문자+숫자 3~12자만 가능)"
fi

# 모든 자원 이름에 SUFFIX 적용
RG="${RG:-rg-migration-lab-$SUFFIX}"
VM_PG="${VM_PG:-vm-pg-$SUFFIX}"
PG_FLEX="${PG_FLEX:-pgflex-$SUFFIX}"
AZSQL="${AZSQL:-sqltgt-$SUFFIX}"
echo ""
echo "  ▶ 생성될 자원 (SUFFIX = '$SUFFIX'):"
echo "    SUFFIX:  $SUFFIX"
echo "    RG:      $RG"
echo "    LOC:     $LOC"
echo "    VM_PG:   $VM_PG"
echo "    PG_FLEX: $PG_FLEX"
echo "    AZSQL:   $AZSQL"

# ============================================================
# Step 1: 사전 점검
# ============================================================
banner "Step 1/8: 사전 점검"

command -v az >/dev/null || abort "Azure CLI 미설치. https://aka.ms/azcli"
ok "az CLI: $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null)"

# 로그인 확인
if ! az account show >/dev/null 2>&1; then
  warn "Azure 로그인 필요"
  if [ -n "${ACC_LOGIN_DEVICE:-}" ]; then
    az login --use-device-code
  else
    az login
  fi
fi
SUB=$(az account show --query name -o tsv)
ok "Subscription: $SUB"

# 비밀번호 입력 (없으면)
# ============================================================
# 비밀번호 입력 헬퍼 — Azure SQL 정책 + 12자 이상
# ============================================================
# 정책 (Azure SQL 기준 + 강화):
#   - 12자 이상 (Azure SQL은 8자, 우리는 안전 마진)
#   - 4가지 카테고리 중 3가지 포함:
#     • 영문 대문자 [A-Z]
#     • 영문 소문자 [a-z]
#     • 숫자        [0-9]
#     • 영숫자 외   [^A-Za-z0-9]
#   - 5회 실패 시 abort

validate_pwd() {
  local pwd="$1"
  local len="${#pwd}"
  local cats=0

  [ "$len" -lt 12 ] && { echo "12자 미만 ($len자)"; return 1; }

  [[ "$pwd" =~ [A-Z] ]] && cats=$((cats + 1))
  [[ "$pwd" =~ [a-z] ]] && cats=$((cats + 1))
  [[ "$pwd" =~ [0-9] ]] && cats=$((cats + 1))
  [[ "$pwd" =~ [^A-Za-z0-9] ]] && cats=$((cats + 1))

  [ "$cats" -lt 3 ] && {
    echo "복잡도 부족 (대문자·소문자·숫자·특수문자 4가지 중 3가지 필요, 현재 ${cats}가지)"
    return 1
  }

  return 0
}

ask_pwd() {
  local var_name="$1"
  local pwd1 pwd2 attempt=0 err

  while [ $attempt -lt 5 ]; do
    attempt=$((attempt + 1))

    if ! read -s -p "    Password: " pwd1; then
      abort "stdin EOF — 입력 받을 수 없음. 다운로드 후 실행 권장."
    fi
    echo
    if ! read -s -p "    Confirm:  " pwd2; then
      abort "stdin EOF"
    fi
    echo

    if [ -z "$pwd1" ]; then
      echo -e "${R}    빈 비밀번호 (시도 $attempt/5)${NC}"
      continue
    fi
    if [ "$pwd1" != "$pwd2" ]; then
      echo -e "${R}    불일치 (시도 $attempt/5)${NC}"
      continue
    fi
    if ! err=$(validate_pwd "$pwd1"); then
      echo -e "${R}    $err (시도 $attempt/5)${NC}"
      continue
    fi

    eval "$var_name=\$pwd1"
    return 0
  done

  abort "비밀번호 입력 5회 실패. 종료."
}

# ============================================================
# Lab 비밀번호 입력 — 1개로 모든 자원에 사용
# ============================================================
if [ -z "${LAB_PWD:-}" ]; then
  echo ""
  echo "  ▶ Lab 비밀번호 (모든 DB 계정에 동일하게 적용)"
  echo "    • 12자 이상"
  echo "    • 대문자·소문자·숫자·특수문자 중 3종류 이상 포함"
  echo "    • 예: MyLab\\$2026!  /  CarMarket@Lab2026"
  echo ""
  echo "  사용처:"
  echo "    - 소스 PG의 'postgres' 사용자"
  echo "    - 소스 PG의 'migrationuser' 사용자 (REPLICATION)"
  echo "    - PG Flexible Server 'pgadmin'"
  echo "    - Azure SQL Database 'sqladmin'"
  echo ""
  ask_pwd LAB_PWD
fi

# 환경변수로 들어온 LAB_PWD도 정책 검증
if ! err=$(validate_pwd "$LAB_PWD"); then
  abort "LAB_PWD 정책 위반: $err"
fi

# 모든 자원이 같은 비밀번호 사용 (cloud-init 변수 호환을 위해 별칭 export)
PG_PWD="$LAB_PWD"
MIGRATION_PWD="$LAB_PWD"
PG_FLEX_PWD="$LAB_PWD"
SQL_PWD="$LAB_PWD"


ok "비밀번호 4종 설정 완료"

# 비용·시간 안내
echo ""
echo "  💰 예상 비용 (8h 기준): 약 \$3.5/인 (Migration Service 무료)"
echo "  ⏱  예상 시간: VM 생성 5분 + cloud-init 5분 = 약 10분"
read -p "  진행하시겠습니까? (y/N): " ok_proceed
[[ "$ok_proceed" =~ ^[Yy]$ ]] || abort "취소"

# ============================================================
# Step 2: RG 생성
# ============================================================
banner "Step 2/8: Resource Group"
if az group show -n "$RG" >/dev/null 2>&1; then
  ok "RG '$RG' 이미 존재 (재사용)"
else
  az group create -n "$RG" -l "$LOC" --output none
  ok "RG '$RG' 생성"
fi

# ============================================================
# Step 3: 소스 PG VM 생성 (cloud-init)
# ============================================================
banner "Step 3/8: 소스 PG VM 생성 (~5분)"

# cloud-init 다운로드 + 비밀번호 치환
CLOUD_INIT=$(mktemp)
if [ -f "./cloud-init/pg-source.yaml.tpl" ]; then
  cp ./cloud-init/pg-source.yaml.tpl "$CLOUD_INIT"
  ok "로컬 cloud-init 템플릿 사용"
else
  curl -fsSL "$REPO_RAW/cloud-init/pg-source.yaml.tpl" -o "$CLOUD_INIT"
  ok "원격 cloud-init 템플릿 다운로드"
fi

# 변수 치환 (envsubst 사용)
export PG_PWD MIGRATION_PWD
CLOUD_INIT_RENDERED=$(mktemp)
envsubst '$PG_PWD $MIGRATION_PWD' < "$CLOUD_INIT" > "$CLOUD_INIT_RENDERED"

# 비밀번호 인증으로 VM 생성 (SSH 키 X)
# Cloud-init이 모든 셋업을 자동 처리하므로 SSH는 거의 사용 안 함
if az vm show -g "$RG" -n "$VM_PG" >/dev/null 2>&1; then
  warn "VM '$VM_PG' 이미 존재 → 재사용 (cloud-init 재실행 안 됨)"
else
  echo "  → VM 생성 중 (3~5분)..."
  az vm create \
    --resource-group "$RG" \
    --name "$VM_PG" \
    --image Ubuntu2404 \
    --size Standard_B2s \
    --admin-username "$USER_NAME" \
    --admin-password "$PG_PWD" \
    --authentication-type password \
    --public-ip-sku Standard \
    --storage-sku Premium_LRS \
    --os-disk-size-gb 32 \
    --custom-data "$CLOUD_INIT_RENDERED" \
    --output none
  ok "VM '$VM_PG' 생성 완료 (cloud-init은 백그라운드 진행 중)"
fi
rm -f "$CLOUD_INIT" "$CLOUD_INIT_RENDERED"

PUBIP=$(az vm show -d -g "$RG" -n "$VM_PG" --query publicIps -o tsv)
ok "소스 PG VM Public IP: $PUBIP"

# NSG: PostgreSQL 5432 오픈 (학습용 — Migration Service 접근)
if ! az network nsg rule show -g "$RG" --nsg-name "${VM_PG}NSG" -n allow_5432 >/dev/null 2>&1; then
  az vm open-port -g "$RG" -n "$VM_PG" --port 5432 --priority 1020 --output none
  ok "NSG 5432 오픈 (학습용)"
fi

# ============================================================
# Step 4: 타깃 PG Flexible Server
# ============================================================
banner "Step 4/8: 타깃 PG Flexible Server (~5분)"

if az postgres flexible-server show -g "$RG" -n "$PG_FLEX" >/dev/null 2>&1; then
  warn "PG Flexible '$PG_FLEX' 이미 존재 → 재사용"
else
  echo "  → PG Flexible 생성 중 (5~7분)..."
  az postgres flexible-server create \
    --resource-group "$RG" \
    --name "$PG_FLEX" \
    --location "$LOC" \
    --admin-user pgadmin \
    --admin-password "$PG_FLEX_PWD" \
    --sku-name Standard_B1ms \
    --tier Burstable \
    --storage-size 32 \
    --version 16 \
    --public-access 0.0.0.0 \
    --yes \
    --output none
  ok "PG Flexible Server 생성"
fi

# wal_level 등 logical replication 파라미터
echo "  → wal_level=logical 등 파라미터 설정..."
az postgres flexible-server parameter set -g "$RG" --server-name "$PG_FLEX" \
  --name wal_level --value logical --output none
az postgres flexible-server parameter set -g "$RG" --server-name "$PG_FLEX" \
  --name max_replication_slots --value 10 --output none
az postgres flexible-server parameter set -g "$RG" --server-name "$PG_FLEX" \
  --name max_wal_senders --value 10 --output none
az postgres flexible-server parameter set -g "$RG" --server-name "$PG_FLEX" \
  --name max_worker_processes --value 16 --output none

# 재시작
echo "  → PG Flexible 재시작 (파라미터 적용, 1~2분)..."
az postgres flexible-server restart -g "$RG" -n "$PG_FLEX" --output none

# 빈 carmarket DB 생성
sleep 10
PGPASSWORD="$PG_FLEX_PWD" psql \
  -h "$PG_FLEX.postgres.database.azure.com" -U pgadmin -d postgres \
  -c "CREATE DATABASE carmarket" 2>/dev/null || \
  ok "carmarket DB 이미 존재 또는 psql 로컬 미설치 (수동 생성 가능)"

ok "PG Flexible Server 준비 완료"

# ============================================================
# Step 5: Azure SQL Database (Part 2용)
# ============================================================
banner "Step 5/8: Azure SQL Database — Serverless"

if az sql server show -g "$RG" -n "$AZSQL" >/dev/null 2>&1; then
  warn "Azure SQL Server '$AZSQL' 이미 존재"
else
  az sql server create \
    --resource-group "$RG" \
    --name "$AZSQL" \
    --location "$LOC" \
    --admin-user sqladmin \
    --admin-password "$SQL_PWD" \
    --output none
  ok "Azure SQL Server 생성"

  # 방화벽: Azure 서비스 + SSMA 클라이언트(본인 IP)
  az sql server firewall-rule create \
    --resource-group "$RG" --server "$AZSQL" \
    --name AllowAzureServices \
    --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 \
    --output none

  MY_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "")
  if [ -n "$MY_IP" ]; then
    az sql server firewall-rule create \
      --resource-group "$RG" --server "$AZSQL" \
      --name AllowMyIP \
      --start-ip-address "$MY_IP" --end-ip-address "$MY_IP" \
      --output none 2>/dev/null || true
    ok "방화벽 — Azure 서비스 + 본인 IP ($MY_IP)"
  else
    warn "본인 IP 자동감지 실패 — SSMA 사용 시 수동 추가 필요"
  fi
fi

# Database (Serverless)
if az sql db show -g "$RG" --server "$AZSQL" -n CarMarket >/dev/null 2>&1; then
  warn "Azure SQL DB 'CarMarket' 이미 존재"
else
  az sql db create \
    --resource-group "$RG" \
    --server "$AZSQL" \
    --name CarMarket \
    --edition GeneralPurpose \
    --compute-model Serverless \
    --family Gen5 \
    --capacity 1 \
    --auto-pause-delay 60 \
    --max-size 32GB \
    --output none
  ok "Azure SQL DB 'CarMarket' 생성 (60분 idle 후 자동 일시정지)"
fi

# ============================================================
# Step 6: cloud-init 완료 대기
# ============================================================
banner "Step 6/8: 소스 VM cloud-init 완료 대기 (시드 50K)"

echo "  cloud-init이 PG 설치 + 50K 시드 + logical 활성화를 처리합니다."
echo "  소요: 약 5~8분. 진행 상황 모니터링..."

# /var/log/pg-bootstrap.done 마커 폴링 (run-command 사용 — SSH 불필요!)
MAX_WAIT=600  # 10분
ELAPSED=0
INTERVAL=15

while [ $ELAPSED -lt $MAX_WAIT ]; do
  RESULT=$(az vm run-command invoke \
    --resource-group "$RG" --name "$VM_PG" \
    --command-id RunShellScript \
    --scripts "test -f /var/log/pg-bootstrap.done && echo READY || echo WAITING" \
    --query 'value[0].message' -o tsv 2>/dev/null || echo "WAITING")

  if echo "$RESULT" | grep -q "READY"; then
    ok "cloud-init 완료 (${ELAPSED}s)"
    break
  fi

  printf "."
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
  warn "cloud-init 타임아웃 (${MAX_WAIT}s). 백그라운드에서 계속 진행 중일 수 있음."
  warn "확인: az vm run-command invoke -g $RG -n $VM_PG --command-id RunShellScript --scripts 'tail -30 /var/log/pg-bootstrap.log'"
fi

# ============================================================
# Step 7: 검증
# ============================================================
banner "Step 7/8: 검증"

echo "  → 소스 PG: 시드 행 수 확인..."
VERIFY=$(az vm run-command invoke \
  --resource-group "$RG" --name "$VM_PG" \
  --command-id RunShellScript \
  --scripts "sudo -u postgres psql -d carmarket -tAc \"SELECT COUNT(*) FROM cars\"" \
  --query 'value[0].message' -o tsv 2>/dev/null || echo "?")

if echo "$VERIFY" | grep -q "50000"; then
  ok "소스 PG 시드 검증: cars 50,000행 ✓"
else
  warn "시드 검증 실패 또는 진행 중. VM에 직접 확인 필요."
  echo "$VERIFY" | head -5
fi

echo "  → 타깃 PG Flexible: 연결 확인..."
PGPASSWORD="$PG_FLEX_PWD" psql \
  -h "$PG_FLEX.postgres.database.azure.com" -U pgadmin -d postgres \
  -c "SHOW wal_level" 2>/dev/null | head -3 || \
  warn "psql이 로컬에 없음 (Cloud Shell이면 자동 설치됨)"

# ============================================================
# Step 8: 환경변수 파일 + 안내
# ============================================================
banner "Step 8/8: 환경변수 저장 + 안내"

ENV_FILE="$HOME/.migration-lab-env"
cat > "$ENV_FILE" <<EOF
# Migration Lab 환경변수 — 다음 셸에서: source $ENV_FILE
export RG="$RG"
export LOC="$LOC"
export VM_PG="$VM_PG"
export PG_FLEX="$PG_FLEX"
export AZSQL="$AZSQL"
export USER_NAME="$USER_NAME"
export PUBIP="$PUBIP"
# 비밀번호는 안전상 저장 안 함. 필요 시 재입력.
EOF
chmod 600 "$ENV_FILE"
ok "환경변수 저장: $ENV_FILE"

# ============================================================
# 완료 안내
# ============================================================
banner "🎉 Bootstrap 완료"

cat <<EOF

┌─────────────────────────────────────────────────────────┐
│  ✅ 소스 PG VM        : $VM_PG ($PUBIP)
│  ✅ 시드 데이터        : users 5K + cars 50K + inquiries 30K
│  ✅ logical 활성화     : wal_level=logical, REPLICATION user 준비
│  ✅ 타깃 PG Flexible   : $PG_FLEX
│  ✅ Azure SQL DB       : CarMarket on $AZSQL.database.windows.net
│  ✅ NSG 5432 오픈      : Migration Service 접근 가능
└─────────────────────────────────────────────────────────┘

📌 다음 단계 — Part 1: 동종 마이그레이션

1. Azure Portal 접속:
   https://portal.azure.com

2. PG Flexible Server 리소스로 이동:
   $PG_FLEX

3. 좌측 메뉴 'Migration' → '+ Create' 클릭

4. Setup 탭:
   • Migration name:  carmarket-online-mig
   • Source server type: Azure Virtual Machine
   • Migration option: Validate and migrate
   • Migration mode: Online

5. Connect to source 탭:
   • Server name: $PUBIP
   • Port: 5432
   • Admin login: migrationuser
   • Password: <Lab 비밀번호 — 입력하신 그 비밀번호>

6. 워크북 Step 4부터 따라 진행

📂 환경변수 다시 로드:
   source $ENV_FILE

📋 SSH 접속 (필요 시):
   az ssh vm -g $RG -n $VM_PG --local-user $USER_NAME
   (또는 Azure Portal → VM → Connect → 'Bastion' / 'Run command')

💰 비용 차단 (퇴근 시):
   az vm deallocate -g $RG -n $VM_PG
   az postgres flexible-server stop -g $RG -n $PG_FLEX
   # Azure SQL Serverless는 자동 일시정지

🗑  완전 정리:
   az group delete -n $RG --yes --no-wait

EOF
