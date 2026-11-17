#!/usr/bin/env bash
# 删除本轮评测创建的全部 namespace(只删 moonmedic-eval-* 前缀)。
set -euo pipefail
for NS in $(kubectl get ns -o json | python -c "
import json,sys
for ns in json.load(sys.stdin)['items']:
    if ns['metadata']['name'].startswith('moonmedic-eval-'):
        print(ns['metadata']['name'])"); do
  echo "[cleanup] 删除 $NS"
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
done
echo "[cleanup] 完成(后台异步删除)"
