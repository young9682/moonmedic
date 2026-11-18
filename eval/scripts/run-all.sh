#!/usr/bin/env bash
# 离线回放 + Golden 断言(无集群、无网络、无 LLM)。
# 用法: run-all.sh [scenario-id ...]  缺省跑全部
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
SCENARIOS=("$@")
if [ ${#SCENARIOS[@]} -eq 0 ]; then
  SCENARIOS=(
    e01-quota-zero-pods e02-quota-partial-pods e03-limitrange-reject
    e04-foreign-workload e05-incomplete-evidence
    r01-quota-missing-resources r02-generic-validation
    r03-webhook-with-saturation r04-unmatched-quota
  )
fi
OUT=$(mktemp) || exit 1
trap 'rm -f -- "$OUT"' EXIT
PASS=0; FAIL=0
for S in "${SCENARIOS[@]}"; do
  FIXTURE="eval/fixtures/$S.snapshot.json"
  EXPECTED="eval/expected/$S.json"
  if [ ! -f "$FIXTURE" ] || [ ! -f "$EXPECTED" ]; then
    FAIL=$((FAIL+1)); echo "FAIL $S (缺少 fixture 或期望文件)" >&2
    continue
  fi
  if moon run cmd/main -- --snapshot "$FIXTURE" --json > "$OUT" &&
    python -X utf8 eval/scripts/assert.py "$EXPECTED" "$OUT"; then
    PASS=$((PASS+1)); echo "PASS $S"
  else
    FAIL=$((FAIL+1)); echo "FAIL $S"
  fi
done
echo "----"
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] && [ "$PASS" -eq "${#SCENARIOS[@]}" ]
