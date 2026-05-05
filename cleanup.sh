#!/usr/bin/env bash
# cleanup.sh — Migration Lab 자원 정리
set -euo pipefail

# SUFFIX 입력
SUFFIX="${SUFFIX:-}"
if [ -z "$SUFFIX" ]; then
  echo "  학생 식별자(SUFFIX) 입력 (예: jhj, s001):"
  read -p "  SUFFIX: " SUFFIX
fi

if [[ ! "$SUFFIX" =~ ^[a-z0-9]{3,12}$ ]]; then
  echo "❌ SUFFIX 형식 오류: '$SUFFIX'"
  exit 1
fi

RG="${RG:-rg-migration-lab-$SUFFIX}"
VM_PG="${VM_PG:-vm-pg-$SUFFIX}"

G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; NC='\033[0m'

echo "==============================================="
echo "Migration Lab — 정리 옵션"
echo "==============================================="
echo "  RG: $RG"
echo ""
echo "  1) Stop / Deallocate (다음날 재개 가능)"
echo "  2) Resource Group 통째로 삭제 (완전 정리)"
echo "  3) 취소"
echo "==============================================="
read -p "선택 [1/2/3]: " choice

case "$choice" in
  1)
    echo -e "${G}[*] Deallocate 진행...${NC}"
    az vm deallocate -g "$RG" -n "$VM_PG" --output none 2>/dev/null \
      && echo "  ✓ VM '$VM_PG' deallocated" || echo "  - VM 없거나 실패"

    # PG Flexible 자동 탐지
    PG_FLEX_LIST=$(az postgres flexible-server list -g "$RG" --query "[].name" -o tsv 2>/dev/null || echo "")
    for pg in $PG_FLEX_LIST; do
      az postgres flexible-server stop -g "$RG" -n "$pg" --output none 2>/dev/null \
        && echo "  ✓ PG Flexible '$pg' stopped" || echo "  - PG '$pg' 중지 실패 (이미 정지)"
    done

    echo ""
    echo "  💡 Azure SQL Serverless는 60분 idle 후 자동 일시정지"
    echo "  💡 다시 시작: az vm start -g $RG -n $VM_PG"
    ;;
  2)
    echo -e "${R}[!] RG '$RG' 통째로 삭제 — 복구 불가${NC}"
    read -p "  RG 이름 '$RG' 정확히 입력: " confirm
    if [ "$confirm" = "$RG" ]; then
      az group delete -n "$RG" --yes --no-wait
      echo -e "${G}  ✓ 백그라운드 삭제 진행 중 (5~10분)${NC}"
      echo "  확인: az group list --query \"[?name=='$RG']\" -o table"
    else
      echo "  이름 불일치 — 취소"
      exit 1
    fi
    ;;
  3) echo "취소"; exit 0 ;;
  *) echo "잘못된 선택"; exit 1 ;;
esac
