#!/usr/bin/env bash
# 用法: capture-snapshot.sh <scenario-id> <target-name> <out-file>
# 从真实集群采集 ClusterSnapshot JSON(全部来自 kubectl -o json,非手写)。
set -euo pipefail
SCENARIO="$1"
TARGET="$2"
OUT="$3"
NS="moonmedic-eval-${SCENARIO%%-*}"
TMP=$(mktemp -d)

kubectl get deployment "$TARGET" -n "$NS" -o json > "$TMP/dep.json"
kubectl get rs -n "$NS" -o json > "$TMP/rs.json"
kubectl get pods -n "$NS" -o json > "$TMP/pods.json"
kubectl get events -n "$NS" -o json > "$TMP/events.json"
kubectl get resourcequota -n "$NS" -o json > "$TMP/quota.json"
kubectl get limitrange -n "$NS" -o json > "$TMP/lr.json"

python - "$TARGET" "$TMP" "$OUT" <<'PY'
import json, sys

target, tmp, out = sys.argv[1], sys.argv[2], sys.argv[3]

def load_list(name):
    d = json.load(open(f"{tmp}/{name}.json", encoding="utf-8"))
    return d.get("items", []) if isinstance(d, dict) else d

def load_one(name):
    d = json.load(open(f"{tmp}/{name}.json", encoding="utf-8"))
    if isinstance(d, dict) and "items" in d:
        items = d["items"]
        return items[0] if items else None
    return d

snapshot = {
    "ns": (load_one("dep") or {}).get("metadata", {}).get("namespace", ""),
    "target_kind": "Deployment",
    "target_name": target,
    "deployment": load_one("dep"),
    "replicasets": load_list("rs"),
    "pods": load_list("pods"),
    "events": load_list("events"),
    "quotas": load_list("quota"),
    "limit_ranges": load_list("lr"),
    "data_status": {
        "replicasets": {"state": "available"},
        "pods": {"state": "available"},
        "events": {"state": "available"},
        "quotas": {"state": "available"},
        "limit_ranges": {"state": "available"},
    },
    "notes": [],
}
json.dump(snapshot, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(f"[capture] {out} (rs={len(snapshot['replicasets'])}, pods={len(snapshot['pods'])}, events={len(snapshot['events'])}, quota={len(snapshot['quotas'])})")
PY
