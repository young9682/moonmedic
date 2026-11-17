///|
/// Offline snapshot: Deployment -> ReplicaSet -> zero Pods, with a saturated
/// quota and a FailedCreate event. No cluster, no kubemoon, no LLM.
const WORKLOAD_SNAPSHOT = "{\"ns\":\"prod\",\"target_kind\":\"Deployment\",\"target_name\":\"payments-api\",\"deployment\":{\"metadata\":{\"name\":\"payments-api\",\"namespace\":\"prod\",\"uid\":\"dep-1\"},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":0,\"availableReplicas\":0}},\"replicasets\":[{\"metadata\":{\"name\":\"payments-api-7d9f6b\",\"namespace\":\"prod\",\"uid\":\"rs-1\",\"ownerReferences\":[{\"uid\":\"dep-1\",\"kind\":\"Deployment\",\"name\":\"payments-api\"}]},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":0,\"conditions\":[{\"type\":\"ReplicaFailure\",\"status\":\"True\",\"reason\":\"FailedCreate\",\"message\":\"pods is forbidden: exceeded quota: compute\"}]}}],\"pods\":[],\"events\":[{\"reason\":\"FailedCreate\",\"message\":\"pods is forbidden: exceeded quota: compute, requested: pods=1, used: pods=10, limited: pods=10\",\"type\":\"Warning\",\"count\":3,\"involvedObject\":{\"kind\":\"ReplicaSet\",\"name\":\"payments-api-7d9f6b\"}}],\"quotas\":[{\"metadata\":{\"name\":\"compute\"},\"status\":{\"hard\":{\"pods\":\"10\"},\"used\":{\"pods\":\"10\"}}}],\"notes\":[\"fixture\"]}"

///|
const POD_SNAPSHOT = "{\"ns\":\"prod\",\"target_kind\":\"Pod\",\"target_name\":\"api-0\",\"pod\":{\"metadata\":{\"name\":\"api-0\",\"namespace\":\"prod\"},\"spec\":{\"containers\":[{\"resources\":{\"limits\":{\"memory\":\"256Mi\"}}}]},\"status\":{\"phase\":\"Running\",\"containerStatuses\":[{\"restartCount\":4,\"state\":{\"waiting\":{\"reason\":\"CrashLoopBackOff\"}},\"lastState\":{\"terminated\":{\"reason\":\"OOMKilled\",\"exitCode\":137}}}]}},\"events\":[],\"notes\":[]}"

///|
fn list_contains(values : Array[String], target : String) -> Bool {
  for value in values {
    if value == target {
      return true
    }
  }
  false
}

///|
fn finding_ids(findings : Array[@rules.Finding]) -> Array[String] {
  let ids : Array[String] = []
  for finding in findings {
    ids.push(finding.rule_id)
  }
  ids
}

///|
test "offline workload snapshot yields the quota causal chain" {
  let snapshot = @snapshot.ClusterSnapshot::from_json(
    @json.parse(WORKLOAD_SNAPSHOT),
  ).unwrap()
  let result = @core.diagnose(snapshot)
  inspect(result.diagnosis.target_kind, content="Deployment")
  inspect(result.diagnosis.target, content="payments-api")
  inspect(result.workload_facts is Some(_), content="true")
  let ids = finding_ids(result.diagnosis.findings)
  inspect(list_contains(ids, "quota_exceeded"), content="true")
  inspect(list_contains(ids, "replicaset_create_failed"), content="true")
  inspect(list_contains(ids, "workload_no_pods"), content="true")
  inspect(list_contains(ids, "quota_at_capacity"), content="false")
  inspect(result.diagnosis.notes.length(), content="1")
}

///|
test "offline Pod snapshot yields runtime findings" {
  let snapshot = @snapshot.ClusterSnapshot::from_json(@json.parse(POD_SNAPSHOT)).unwrap()
  let result = @core.diagnose(snapshot)
  inspect(result.diagnosis.target_kind, content="Pod")
  inspect(result.diagnosis.phase, content="Running")
  inspect(result.pod_facts is Some(_), content="true")
  let ids = finding_ids(result.diagnosis.findings)
  inspect(list_contains(ids, "oomkilled_limit"), content="true")
}

///|
test "Pod snapshot with no Pod object keeps the missing-object note" {
  let snapshot = @snapshot.ClusterSnapshot::from_json(
    @json.parse(
      "{\"ns\":\"prod\",\"target_kind\":\"Pod\",\"target_name\":\"gone\",\"events\":[]}",
    ),
  ).unwrap()
  let result = @core.diagnose(snapshot)
  inspect(result.diagnosis.target_kind, content="Pod")
  let notes = result.diagnosis.notes.join("\n")
  inspect(notes.contains("不存在"), content="true")
}

///|
test "foreign Pod events are not attributed to the target" {
  let snapshot = @snapshot.ClusterSnapshot::from_json(
    @json.parse(
      "{\"ns\":\"prod\",\"target_kind\":\"Pod\",\"target_name\":\"api-0\",\"pod\":{\"metadata\":{\"name\":\"api-0\",\"namespace\":\"prod\"},\"status\":{\"phase\":\"Running\",\"containerStatuses\":[{\"restartCount\":0,\"state\":{\"running\":{}}}]}},\"events\":[{\"reason\":\"Unhealthy\",\"message\":\"Readiness probe failed\",\"type\":\"Warning\",\"involvedObject\":{\"kind\":\"Pod\",\"name\":\"other-pod\"}}]}",
    ),
  ).unwrap()
  let result = @core.diagnose(snapshot)
  inspect(result.diagnosis.findings.length(), content="0")
}

///|
test "foreign workload events are not attributed to the target" {
  let snapshot = @snapshot.ClusterSnapshot::from_json(
    @json.parse(
      "{\"ns\":\"prod\",\"target_kind\":\"Deployment\",\"target_name\":\"payments-api\",\"deployment\":{\"metadata\":{\"name\":\"payments-api\",\"uid\":\"dep-1\"},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":2}},\"replicasets\":[{\"metadata\":{\"name\":\"payments-api-7d9f6b\",\"uid\":\"rs-1\",\"ownerReferences\":[{\"uid\":\"dep-1\"}]},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":2}}],\"pods\":[{\"metadata\":{\"name\":\"p1\",\"ownerReferences\":[{\"uid\":\"rs-1\"}]}},{\"metadata\":{\"name\":\"p2\",\"ownerReferences\":[{\"uid\":\"rs-1\"}]}}],\"events\":[{\"reason\":\"FailedCreate\",\"message\":\"exceeded quota: other\",\"type\":\"Warning\",\"involvedObject\":{\"kind\":\"ReplicaSet\",\"name\":\"other-workload-abc\"}}],\"quotas\":[{\"metadata\":{\"name\":\"compute\"},\"status\":{\"hard\":{\"pods\":\"10\"},\"used\":{\"pods\":\"5\"}}}]}",
    ),
  ).unwrap()
  let result = @core.diagnose(snapshot)
  inspect(result.diagnosis.findings.length(), content="0")
}

///|
test "unsupported target kind degrades with a note" {
  let snapshot = @snapshot.ClusterSnapshot::from_json(
    @json.parse(
      "{\"ns\":\"prod\",\"target_kind\":\"StatefulSet\",\"target_name\":\"db\"}",
    ),
  ).unwrap()
  let result = @core.diagnose(snapshot)
  inspect(result.diagnosis.findings.length(), content="0")
  let notes = result.diagnosis.notes.join("\n")
  inspect(notes.contains("不支持的目标类型"), content="true")
}
