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
"${k[@]}" run other --image="$image" --image-pull-policy=IfNotPresent --restart=Never
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
"${k[@]}" wait --for=condition=Ready pod/other --timeout=180s
"${k[@]}" rollout status deployment/web --timeout=180s
capture() {
  bash eval/scripts/capture-snapshot.sh rollout web "$out/$1.json"
}
capture before
"${k[@]}" patch deployment web -p '{"spec":{"template":{"metadata":{"annotations":{"test-revision":"new"}}}}}'
for _ in {1..60}; do
  if "${k[@]}" get rs -o json | jq -e 'any(.items[].status.conditions[]?;
      .reason == "FailedCreate" and (.message | contains("exceeded quota"))) ' >/dev/null; then break; fi
  sleep 2
done
capture blocked
jq -e 'any(.replicasets[].status.conditions[]?; .reason=="FailedCreate" and (.message|contains("exceeded quota")))' "$out/blocked.json" >/dev/null
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
# Predict the effect of the one-field change before submitting it to the controller.
jq '.quotas[0].spec.hard.pods="5" | .quotas[0].status.hard.pods="5"' "$out/blocked.json" >"$out/counterfactual.json"
moon run cmd/main -- --snapshot "$out/counterfactual.json" --json >"$out/recovery-prediction.json"
jq -e 'any(.findings[]; .rule_id=="rollout_reachable")' "$out/recovery-prediction.json" >/dev/null
"${k[@]}" patch quota slots -p '{"spec":{"hard":{"pods":"5"}}}'
if ! "${k[@]}" rollout status deployment/web --timeout=240s; then
  capture recovery-timeout
  "${k[@]}" get rs,pods,quota -o wide
  "${k[@]}" get events --sort-by=.metadata.creationTimestamp
  exit 1
fi
for _ in {1..30}; do
  capture recovered
  if jq -e '(.pods|length)==4 and .quotas[0].status.used.pods=="4"
    and all(.pods[]; .metadata.deletionTimestamp==null)' "$out/recovered.json" >/dev/null; then break; fi
  sleep 2
done
jq -e '.deployment.status.updatedReplicas==3 and .deployment.status.availableReplicas==3
 and (.quotas[0].status.hard.pods=="5" and .quotas[0].status.used.pods=="4")
 and .deployment.spec.strategy.rollingUpdate=={maxSurge:"25%", maxUnavailable:"25%"}
 and (.pods|length)==4 and all(.pods[]; .metadata.deletionTimestamp==null)
 and any(.replicasets[]; .spec.template.metadata.annotations["test-revision"]=="new" and .status.availableReplicas==3)
 and all(.replicasets[] | select(.spec.template.metadata.annotations["test-revision"]!="new"); .spec.replicas==0)' "$out/recovered.json" >/dev/null
moon run cmd/main -- --snapshot "$out/recovered.json" --json >"$out/final-diagnosis.json"
jq -e 'any(.findings[]; .rule_id=="rollout_reachable" and (.detail|contains("已达到替换目标")))' "$out/final-diagnosis.json" >/dev/null
for phase in before blocked recovered; do
  jq -c --arg phase "$phase" '{phase:$phase,quota:.quotas[0].status,rs:[.replicasets[]|{name:.metadata.name,desired:.spec.replicas,available:(.status.availableReplicas//0)}]}' "$out/$phase.json"
done
