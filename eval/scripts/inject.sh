#!/usr/bin/env bash
# 用法: inject.sh <scenario-id>   (如 e01-quota-zero-pods)
# 在真实集群上创建隔离 namespace 并注入故障,等待故障证据就绪。
set -euo pipefail
SCENARIO="$1"
KIND="${SCENARIO%%-*}"                # e01
NS="moonmedic-eval-$KIND"
DIR="$(cd "$(dirname "$0")/.." && pwd)/scenarios/$SCENARIO"

echo "[inject] 创建/复用 namespace $NS"
kubectl apply -f "$DIR/manifest.yaml"

echo "[inject] 等待故障证据就绪(最多 90s)…"
for i in $(seq 1 45); do
  EVENTS=$(kubectl get events -n "$NS" -o json 2>/dev/null || echo '{"items":[]}')
  FOUND=$(python - "$KIND" "$EVENTS" <<'PY'
import json, sys
kind, raw = sys.argv[1], sys.argv[2]
try:
    d = json.loads(raw)
except Exception:
    print("no"); raise SystemExit
msgs = " ".join(
    (e.get("message", "") + " " + e.get("reason", ""))
    for e in d.get("items", [])
)
if kind in ("e01", "e02", "e05"):
    ok = "exceeded quota" in msgs
elif kind == "e03":
    ok = "LimitRange" in msgs or "must be less than or equal to" in msgs
elif kind == "e04":
    ok = "exceeded quota" in msgs
else:
    ok = False
print("yes" if ok else "no")
PY
)
  if [ "$FOUND" = "yes" ]; then
    echo "[inject] 证据就绪(第 ${i} 轮)"
    exit 0
  fi
  sleep 2
done
echo "[inject] 超时:未等到预期事件" >&2
exit 1
