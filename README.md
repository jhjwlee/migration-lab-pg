# 🔄 Migration Lab — PostgreSQL → Azure

**Azure Database Engineer Bootcamp · Day 5 · 클라우드 마이그레이션 핸즈온**

[![Azure](https://img.shields.io/badge/Azure-PostgreSQL%20%2B%20SQL-0078D4?logo=microsoftazure)](https://azure.microsoft.com)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-336791?logo=postgresql)](https://www.postgresql.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

---

## 📖 개요

PostgreSQL을 두 가지 시나리오로 Azure에 마이그레이션하는 실습 자료:

- **Part 1 — 동종(Homogeneous)**: PG VM → Azure DB for PostgreSQL Flexible Server (Online + CDC)
- **Part 2 — 이기종(Heterogeneous)**: PG VM → Azure SQL Database (Schema 변환 + SSMA)

**핵심 설계**: 인프라 셋업은 자동(cloud-init), 마이그레이션 자체는 학생이 손으로 (학습 가치 있는 부분에만 집중).

---

## ⚡ 한 줄 시작 — Azure Cloud Shell 권장

### 옵션 A — Azure Cloud Shell (가장 쉬움, SSH 키 불필요)

브라우저에서 [shell.azure.com](https://shell.azure.com) 접속 → bash 선택 → 아래 두 줄:

```bash
curl -fsSL https://raw.githubusercontent.com/jhjwlee/migration-lab-pg/main/bootstrap.sh -o bootstrap.sh
bash bootstrap.sh
```

스크립트가 다음을 입력받습니다 (비밀번호는 1개만):

| 입력 | 형식 | 예시 | 용도 |
|---|---|---|---|
| **SUFFIX** | 영문 소문자+숫자, 3~12자 | `jhj`, `s001` | 모든 자원 이름의 식별자 |
| **LAB_PWD** | 12자+, 3종류 이상 | `MyLab@2026Pwd` | 모든 DB 계정에 동일 적용 |

**비밀번호 정책** (Azure SQL 호환):
- 12자 이상
- 다음 4종류 중 **3종류 이상** 포함:
  - 영문 대문자 (A-Z)
  - 영문 소문자 (a-z)
  - 숫자 (0-9)
  - 영숫자 외 특수문자 (`! @ # $ % ^ & * ( ) _ + -` 등)

**사용처** (모두 같은 비밀번호):
- 소스 PG의 `postgres` 사용자
- 소스 PG의 `migrationuser` (REPLICATION 권한)
- PG Flexible Server의 `pgadmin`
- Azure SQL Database의 `sqladmin`

> **왜 비밀번호 1개?** 학습용 lab은 8시간 후 RG 통째로 삭제하는 단기 환경입니다. 학생이 4개 비밀번호를 외우거나 어딘가 적어두는 게 더 위험합니다 (포스트잇 사태). 1개만 기억하면 디버깅·접속·검증 시 편합니다. 실무 프로덕션에서는 자원별 다른 비밀번호 + Key Vault 사용이 정답입니다.

SUFFIX 'jhj' 입력 시 생성되는 자원:
- `rg-migration-lab-jhj` (Resource Group)
- `vm-pg-jhj` (소스 PG VM)
- `pgflex-jhj` (PG Flexible Server)
- `sqltgt-jhj` (Azure SQL Server)

> ⚠️ **`curl ... | bash` 패턴은 사용 불가**: 비밀번호 prompt 때문에 stdin이 필요합니다. 반드시 다운로드 후 실행 패턴을 사용하세요.

### (선택) 비대화형 모드 — 환경변수로 미리 지정

CI/CD나 자동화에서는 SUFFIX와 LAB_PWD를 미리 export하면 prompt가 스킵되고 `curl | bash`도 동작:

```bash
export SUFFIX="jhj"
read -s -p "Lab Password: " LAB_PWD; echo
export LAB_PWD

curl -fsSL https://raw.githubusercontent.com/jhjwlee/migration-lab-pg/main/bootstrap.sh | bash
```

### 옵션 B — 로컬 PC (Mac/Linux/WSL)

Windows PowerShell의 SSH 키 문제를 겪고 싶지 않으면 옵션 A 사용 권장. 그래도 로컬에서 하려면:

```bash
# Azure CLI 로그인
az login

# Bootstrap 실행
curl -fsSL https://raw.githubusercontent.com/jhjwlee/migration-lab-pg/main/bootstrap.sh -o bootstrap.sh
bash bootstrap.sh
```

**Windows 사용자**는 옵션 A를 강력 권장합니다 (SSH 키 관리 부담 0).

---

## 🤖 Bootstrap이 자동으로 하는 것

| 자원 | 자동화 | 학생 작업 |
|---|---|---|
| Resource Group | ✅ 자동 | — |
| **소스 PG VM** | ✅ Ubuntu 24.04 + PostgreSQL 16 | — |
| **PG 스키마 + 시드 50K** | ✅ cloud-init이 자동 | — |
| **logical replication 활성화** | ✅ wal_level=logical, REPLICATION user | — |
| 외부 접근 + NSG 5432 | ✅ 자동 | — |
| **타깃 PG Flexible Server** | ✅ wal_level=logical 자동 | — |
| **Azure SQL Database** | ✅ Serverless tier | — |
| 방화벽 (Azure 서비스 + 본인 IP) | ✅ 자동 | — |
| **마이그레이션 실행** | ❌ 학생이 직접 | Portal/SSMA로 학습 |
| 검증 SQL | 워크북 부록 A 제공 | 학생이 실행·비교 |

학생은 **"Migration Service 만드는 법"과 "스키마 변환 결과 분석"** 같은 학습 가치 있는 부분에만 집중합니다.

---

## 📚 워크북

`docs/Migration_HandsOn_Workbook.docx` — 46페이지

```
Part 0: 강의 — 6R 전략 + Online vs Offline + CDC 메커니즘
Part 1: 동종 마이그레이션 (Step 1~5)
Part 2: 이기종 마이그레이션 (Step 6~9)
Step 10: 자원 정리
부록 A: 검증 SQL (5가지)
부록 B: PG ↔ SQL Server 타입 매핑
부록 C: 트러블슈팅 13건
부록 D: Native Logical Replication 심화
```

---

## 📂 디렉토리 구조

```
migration-lab-pg/
├── README.md
├── bootstrap.sh           ← 한 줄 자원 생성
├── cleanup.sh             ← 비용 차단
├── cloud-init/
│   └── pg-source.yaml.tpl ← VM 자동 셋업 템플릿
├── docs/
│   └── Migration_HandsOn_Workbook.docx
└── Migration_HandsOn_Workbook_v2.docx
```

---

## 💰 비용 (1인 일일 8h 기준)

| 자원 | 비용 |
|---|---|
| PG VM (B2s) | $0.40 |
| PG Flexible Server (Burstable B1ms) | $0.30 |
| Azure SQL DB (Serverless 1 vCore) | $0.50 |
| Migration Service | **무료** |
| **합계** | **약 $1.5 ~ $3.5** |

부트캠프 일일 한도 $10의 35%.

---

## 🛠 Bootstrap 후 다음 단계

### Part 1 — 동종 마이그레이션

워크북 Step 4 (Migration Service Online 설정)부터 시작.

Cloud Shell에서 환경변수 다시 로드:
```bash
source ~/.migration-lab-env
echo $PG_FLEX  # 타깃 서버명 확인
```

Azure Portal → `$PG_FLEX` → Migration → Create.

### Part 2 — 이기종 마이그레이션

SSMA는 Windows 전용. 다음 중 하나 선택:
- 로컬 Windows PC에 설치
- Azure Windows VM 생성 (워크북 Step 7.1 참조)
- Parallels 등 Mac의 Windows VM

---

## 🧹 정리

```bash
curl -fsSL https://raw.githubusercontent.com/jhjwlee/migration-lab-pg/main/cleanup.sh | bash
```

또는 Cloud Shell에서:
```bash
az group delete -n rg-migration-lab --yes --no-wait
```

---

## 🔍 SSH 접속이 필요한 경우

학생이 PG VM에 직접 접속할 일은 거의 없습니다 (cloud-init이 모든 것을 처리). 만약 필요하다면 SSH 키 없이도 가능한 3가지 방법:

### 1. `az ssh` (Azure CLI 통합)
```bash
az ssh vm -g $RG -n $VM_PG --local-user azureuser
```

### 2. `az vm run-command` (명령 한 줄 실행)
```bash
az vm run-command invoke -g $RG -n $VM_PG \
  --command-id RunShellScript \
  --scripts "sudo -u postgres psql -d carmarket -c 'SELECT COUNT(*) FROM cars'"
```

### 3. Azure Portal → VM → Bastion / Serial console
브라우저에서 직접 콘솔 접근. 키 관리 0.

---

## 📜 라이선스

MIT — 자유롭게 사용·수정·재배포

## 👥 제작

OpenScale · Azure Database Engineer Bootcamp 2026
