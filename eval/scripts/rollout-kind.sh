#!/usr/bin/env bash
# Run on a disposable kind cluster named moonmedic-rollout.
set -euo pipefail
test "$(kubectl config current-context)" = kind-moonmedic-rollout
out=${1:?pass an evidence directory}
mkdir -p "$out"
ns=moonmedic-eval-rollout
kubectl create namespace "$ns"
k=(kubectl -n "$ns")
image=$(docker exec moonmedic-rollout-control-plane crictl images -o json |
  jq -er '[.images[].repoTags[]? | select(test("/pause:[0-9]"))][0]')
"${k[@]}" create quota slots --hard=pods=4
"${k[@]}" create quota guard-slots --hard=pods=4
cat <<YAML | "${k[@]}" create -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxSurge: "25%", maxUnavailable: "25%"}
  selector:
    matchLabels: {app: web}
  template:
    metadata:
      labels: {app: web}
    spec:
      terminationGracePeriodSeconds: 1
      containers:
      - name: web
        image: $image
        imagePullPolicy: IfNotPresent
YAML
"${k[@]}" rollout status deployment/web --timeout=180s
# Complete one rollout with a free slot to leave a real, scaled-to-zero revision.
"${k[@]}" patch deployment web -p '{"spec":{"template":{"metadata":{"annotations":{"test-revision":"previous"}}}}}'
"${k[@]}" rollout status deployment/web --timeout=180s
"${k[@]}" wait --for=jsonpath='{.status.used.pods}'=3 quota/slots --timeout=90s
"${k[@]}" wait --for=jsonpath='{.status.used.pods}'=3 quota/guard-slots --timeout=90s
"${k[@]}" run other --image="$image" --image-pull-policy=IfNotPresent --restart=Never
"${k[@]}" wait --for=condition=Ready pod/other --timeout=180s
capture() {
  bash eval/scripts/capture-snapshot.sh rollout web "$out/$1.json"
}
wait_for_quota_denial() {
  for _ in {1..60}; do
    if "${k[@]}" get rs -l "app=$1" -o json | jq -e 'any(.items[].status.conditions[]?;
      .reason=="FailedCreate" and (.message|contains("exceeded quota")))' >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}
capture before
"${k[@]}" patch deployment web -p '{"spec":{"template":{"metadata":{"annotations":{"test-revision":"new"}}}}}'
wait_for_quota_denial web || { capture quota-denial-timeout; exit 1; }
capture blocked
jq -e 'any(.replicasets[].status.conditions[]?; .reason=="FailedCreate" and (.message|contains("exceeded quota")))' "$out/blocked.json" >/dev/null
history=$(jq -er 'select((.replicasets | length)==3) | .replicasets[]
  | select(.spec.template.metadata.annotations["test-revision"]==null
    and .spec.replicas==0 and .status.replicas==0) | .metadata.name' "$out/blocked.json")
"${k[@]}" get rs --watch -o custom-columns='NAME:.metadata.name,VERSION:.metadata.resourceVersion,DESIRED:.spec.replicas,AVAILABLE:.status.availableReplicas' >"$out/rs-transitions.txt" &
watcher=$!
kubectl proxy --address=127.0.0.1 --port=8001 >"$out/proxy.log" 2>&1 &
proxy=$!
trap 'kill "$proxy" "$watcher" 2>/dev/null || true' EXIT
for _ in {1..20}; do curl -fsS http://127.0.0.1:8001/version >/dev/null && break; sleep 1; done
MOONMEDIC_SERVER=http://127.0.0.1:8001 moon run cmd/main -- --deployment "$ns" web --json >"$out/live-diagnosis.json"
jq -e 'any(.findings[]; .rule_id=="rollout_blocked")' "$out/live-diagnosis.json" >/dev/null
jq -e 'any(.findings[] | select(.rule_id=="rollout_blocked") | .evidence[];
  contains("maxSurge=1，maxUnavailable=0"))' "$out/live-diagnosis.json" >/dev/null
jq -e --arg history "$history" 'any(.findings[] | select(.rule_id=="rollout_blocked") | .evidence_refs[];
  .resource_kind=="ReplicaSet" and .object_name==$history and .field_path=="status")' "$out/live-diagnosis.json" >/dev/null
jq -e 'any(.findings[] | select(.rule_id=="rollout_blocked") | .evidence[];
  .=="生效 pods 配额上限 4（guard-slots、slots）" or .=="生效 pods 配额上限 4（slots、guard-slots）")' "$out/live-diagnosis.json" >/dev/null
jq -e 'any(.findings[] | select(.rule_id=="rollout_blocked") | .evidence[];
  contains("生效 pods 配额至少为 5") and contains("增加 1 个名额"))' "$out/live-diagnosis.json" >/dev/null
# Predict the effect of relaxing one quota and then both quotas.
jq '(.quotas[] | select(.metadata.name=="slots") | .spec.hard.pods, .status.hard.pods)="5"' "$out/blocked.json" >"$out/one-raised-counterfactual.json"
moon run cmd/main -- --snapshot "$out/one-raised-counterfactual.json" --json >"$out/one-raised-prediction.json"
jq -e 'any(.findings[]; .rule_id=="rollout_blocked"
  and any(.evidence[]; contains("生效 pods 配额上限 4（guard-slots）")))' "$out/one-raised-prediction.json" >/dev/null
jq '(.quotas[] | .spec.hard.pods, .status.hard.pods)="5"' "$out/blocked.json" >"$out/counterfactual.json"
moon run cmd/main -- --snapshot "$out/counterfactual.json" --json >"$out/recovery-prediction.json"
jq -e 'any(.findings[]; .rule_id=="rollout_reachable")' "$out/recovery-prediction.json" >/dev/null
"${k[@]}" patch quota slots -p '{"spec":{"hard":{"pods":"5"}}}'
"${k[@]}" wait --for=jsonpath='{.status.hard.pods}'=5 quota/slots --timeout=90s
# Ask the real admission chain to evaluate creating a Pod without persisting it.
if "${k[@]}" run quota-probe --image="$image" --restart=Never --dry-run=server >"$out/one-raised-admission.txt" 2>&1; then
  echo "Pod creation dry run unexpectedly passed with guard-slots still full" >&2
  exit 1
fi
if ! grep -Fq 'exceeded quota: guard-slots' "$out/one-raised-admission.txt"; then
  cat "$out/one-raised-admission.txt" >&2
  exit 1
fi
capture one-raised
"${k[@]}" patch quota guard-slots -p '{"spec":{"hard":{"pods":"5"}}}'
if ! "${k[@]}" rollout status deployment/web --timeout=240s; then
  capture recovery-timeout
  "${k[@]}" get rs,pods,quota -o wide
  "${k[@]}" get events --sort-by=.metadata.creationTimestamp
  exit 1
fi
for _ in {1..30}; do
  capture recovered
  if jq -e '(.pods|length)==4 and all(.quotas[]; .status.used.pods=="4")
    and all(.pods[]; .metadata.deletionTimestamp==null)' "$out/recovered.json" >/dev/null; then break; fi
  sleep 2
done
jq -e '.deployment.status.updatedReplicas==3 and .deployment.status.availableReplicas==3
 and (.quotas | length)==2
 and all(.quotas[]; .status.hard.pods=="5" and .status.used.pods=="4")
 and .deployment.spec.strategy.rollingUpdate=={maxSurge:"25%", maxUnavailable:"25%"}
 and (.pods|length)==4 and all(.pods[]; .metadata.deletionTimestamp==null)
 and any(.replicasets[]; .spec.template.metadata.annotations["test-revision"]=="new" and .status.availableReplicas==3)
 and all(.replicasets[] | select(.spec.template.metadata.annotations["test-revision"]!="new"); .spec.replicas==0)' "$out/recovered.json" >/dev/null
moon run cmd/main -- --snapshot "$out/recovered.json" --json >"$out/final-diagnosis.json"
jq -e 'any(.findings[]; .rule_id=="rollout_reachable" and (.detail|contains("已达到替换目标")))' "$out/final-diagnosis.json" >/dev/null
for phase in before blocked one-raised recovered; do
  jq -c --arg phase "$phase" '{phase:$phase,quotas:[.quotas[]|{name:.metadata.name,status}],rs:[.replicasets[]|{name:.metadata.name,desired:.spec.replicas,available:(.status.availableReplicas//0)}]}' "$out/$phase.json"
done

# Fill the last slot with a separate Deployment, then recover it using only
# a policy change. At one replica, allowing one unavailable can take it to zero.
"${k[@]}" create deployment fixed-quota --image="$image" --replicas=1
"${k[@]}" rollout status deployment/fixed-quota --timeout=180s
"${k[@]}" patch deployment fixed-quota -p '{"spec":{"template":{"metadata":{"annotations":{"test-revision":"next"}}}}}'
wait_for_quota_denial fixed-quota || {
  bash eval/scripts/capture-snapshot.sh rollout fixed-quota "$out/fixed-quota-denial-timeout.json"
  exit 1
}
bash eval/scripts/capture-snapshot.sh rollout fixed-quota "$out/fixed-quota-blocked.json"
moon run cmd/main -- --snapshot "$out/fixed-quota-blocked.json" --json >"$out/fixed-quota-plan.json"
jq -e 'any(.findings[]; .rule_id=="rollout_blocked"
  and any(.evidence[]; contains("maxUnavailable 至少为 1，最低可用副本数从 1 降到 0"))
  and any(.evidence[]; startswith("放宽 maxUnavailable 后的路径 scale_old_rs(-1)")))' "$out/fixed-quota-plan.json" >/dev/null
"${k[@]}" patch deployment fixed-quota -p '{"spec":{"strategy":{"rollingUpdate":{"maxUnavailable":1}}}}'
if ! "${k[@]}" rollout status deployment/fixed-quota --timeout=240s; then
  bash eval/scripts/capture-snapshot.sh rollout fixed-quota "$out/fixed-quota-recovery-timeout.json"
  exit 1
fi
bash eval/scripts/capture-snapshot.sh rollout fixed-quota "$out/fixed-quota-recovered.json"
jq -e '.deployment.metadata.uid as $uid
 | [.replicasets[] | select(any(.metadata.ownerReferences[]?; .uid==$uid))] as $owned
 | .deployment.status.updatedReplicas==1 and .deployment.status.availableReplicas==1
   and .deployment.spec.strategy.rollingUpdate=={maxSurge:"25%", maxUnavailable:1}
   and (.quotas|length)==2 and all(.quotas[]; .spec.hard.pods=="5" and .status.hard.pods=="5")
   and ($owned|length)==2
   and any($owned[]; .spec.template.metadata.annotations["test-revision"]=="next" and .status.availableReplicas==1)
   and any($owned[]; .spec.template.metadata.annotations["test-revision"]!="next" and .spec.replicas==0)' "$out/fixed-quota-recovered.json" >/dev/null
