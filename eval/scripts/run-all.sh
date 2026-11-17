#!/usr/bin/env bash
# 离线回放 + Golden 断言(无集群、无网络、无 LLM)。
# 用法: run-all.sh [scenario-id ...]  缺省跑全部
set -uo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)"   # 仓库根
SCENARIOS=("$@")
if [ ${#SCENARIOS[@]} -eq 0 ]; then
  SCENARIOS=(e01-quota-zero-pods e02-quota-partial-pods e03-limitrange-reject e04-foreign-workload e05-incomplete-evidence)
fi
PASS=0; FAIL=0
for S in "${SCENARIOS[@]}"; do
  FIXTURE="eval/fixtures/$S.snapshot.json"
  EXPECTED="eval/expected/$S.json"
  OUT="eval/results/$S.out.json"
  if [ ! -f "$FIXTURE" ]; then echo "SKIP $S (无 fixture)"; continue; fi
  moon run cmd/main -- --snapshot "$FIXTURE" --json > "$OUT" 2>/dev/null
  if python eval/scripts/assert.py "$EXPECTED" "$OUT"; then
    PASS=$((PASS+1)); echo "PASS $S"
  else
    FAIL=$((FAIL+1)); echo "FAIL $S"
  fi
done
echo "----"
echo "pass=$PASS fail=$FAIL"
[ $FAIL -eq 0 ]
