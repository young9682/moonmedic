///|
/// Offline snapshot: Deployment -> ReplicaSet -> zero Pods, with a saturated
/// quota and a FailedCreate event. No cluster, no kubemoon, no LLM.
const WORKLOAD_SNAPSHOT = "{\"ns\":\"prod\",\"target_kind\":\"Deployment\",\"target_name\":\"payments-api\",\"deployment\":{\"metadata\":{\"name\":\"payments-api\",\"namespace\":\"prod\",\"uid\":\"dep-1\"},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":0,\"availableReplicas\":0}},\"replicasets\":[{\"metadata\":{\"name\":\"payments-api-7d9f6b\",\"namespace\":\"prod\",\"uid\":\"rs-1\",\"ownerReferences\":[{\"uid\":\"dep-1\",\"kind\":\"Deployment\",\"name\":\"payments-api\"}]},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":0,\"conditions\":[{\"type\":\"ReplicaFailure\",\"status\":\"True\",\"reason\":\"FailedCreate\",\"message\":\"exceeded quota: compute, requested: pods=1, used: pods=10, limited: pods=10\"}]}}],\"pods\":[],\"events\":[{\"reason\":\"FailedCreate\",\"message\":\"exceeded quota: compute, requested: pods=1, used: pods=10, limited: pods=10\",\"type\":\"Warning\",\"count\":3,\"involvedObject\":{\"kind\":\"ReplicaSet\",\"name\":\"payments-api-7d9f6b\"}}],\"quotas\":[{\"metadata\":{\"name\":\"compute\"},\"status\":{\"hard\":{\"pods\":\"10\"},\"used\":{\"pods\":\"10\"}}}],\"notes\":[\"fixture\"]}"

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
test "Pod event identity rejects mismatches and accepts legacy references" {
  let raw =
    #|{
    #|  "ns": "prod", "target_kind": "Pod", "target_name": "api",
    #|  "pod": {"metadata": {"name": "api", "uid": "current"}, "status": {"phase": "Running"}},
    #|  "events": [
    #|    {"message": "old Pod", "involvedObject": {"kind": "Pod", "name": "api", "namespace": "prod", "uid": "deleted"}},
    #|    {"message": "foreign namespace", "involvedObject": {"kind": "Pod", "name": "api", "namespace": "staging"}},
    #|    {"message": "different kind", "involvedObject": {"kind": "Deployment", "name": "api", "namespace": "prod"}},
    #|    {"message": "current Pod", "involvedObject": {"kind": "Pod", "name": "api", "namespace": "prod", "uid": "current"}},
    #|    {"message": "legacy reference", "involvedObject": {"kind": "Pod", "name": "api"}}
    #|  ]
    #|}
  let snapshot = @snapshot.ClusterSnapshot::from_json(@json.parse(raw)).unwrap()
  let facts = @core.diagnose(snapshot).pod_facts.unwrap()
  inspect(
    facts.events.map(fn(event) { event.message }).join("|"),
    content="current Pod|legacy reference",
  )
}

///|
test "foreign workload events are not attributed to the target" {
  let snapshot = @snapshot.ClusterSnapshot::from_json(
    @json.parse(
      "{\"ns\":\"prod\",\"target_kind\":\"Deployment\",\"target_name\":\"payments-api\",\"deployment\":{\"metadata\":{\"name\":\"payments-api\",\"uid\":\"dep-1\"},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":2}},\"replicasets\":[{\"metadata\":{\"name\":\"payments-api-7d9f6b\",\"uid\":\"rs-1\",\"ownerReferences\":[{\"uid\":\"dep-1\"}]},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":2}},{\"metadata\":{\"name\":\"other-workload-abc\",\"uid\":\"rs-other\",\"ownerReferences\":[{\"uid\":\"dep-other\"}]},\"spec\":{\"replicas\":1},\"status\":{\"readyReplicas\":1}}],\"pods\":[{\"metadata\":{\"name\":\"p1\",\"ownerReferences\":[{\"uid\":\"rs-1\"}]}},{\"metadata\":{\"name\":\"p2\",\"ownerReferences\":[{\"uid\":\"rs-1\"}]}}],\"events\":[{\"reason\":\"FailedCreate\",\"message\":\"exceeded quota: other, requested: pods=1, used: pods=5, limited: pods=5\",\"type\":\"Warning\",\"involvedObject\":{\"kind\":\"ReplicaSet\",\"name\":\"other-workload-abc\"}}],\"quotas\":[{\"metadata\":{\"name\":\"compute\"},\"status\":{\"hard\":{\"pods\":\"10\"},\"used\":{\"pods\":\"5\"}}}]}",
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

///|
/// Regression: a foreign Deployment's healthy ReplicaSet and Pods share the
/// namespace. They must not pad the target's Pod count — otherwise the
/// "Pod was never created" symptom is masked by someone else's replicas.
const WORKLOAD_SNAPSHOT_FOREIGN = "{\"ns\":\"prod\",\"target_kind\":\"Deployment\",\"target_name\":\"payments-api\",\"deployment\":{\"metadata\":{\"name\":\"payments-api\",\"namespace\":\"prod\",\"uid\":\"dep-1\"},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":0,\"availableReplicas\":0}},\"replicasets\":[{\"metadata\":{\"name\":\"payments-api-7d9f6b\",\"namespace\":\"prod\",\"uid\":\"rs-1\",\"ownerReferences\":[{\"uid\":\"dep-1\",\"kind\":\"Deployment\",\"name\":\"payments-api\"}]},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":0,\"conditions\":[{\"type\":\"ReplicaFailure\",\"status\":\"True\",\"reason\":\"FailedCreate\",\"message\":\"exceeded quota: compute, requested: pods=1, used: pods=10, limited: pods=10\"}]}},{\"metadata\":{\"name\":\"other-api-abc\",\"namespace\":\"prod\",\"uid\":\"rs-foreign\",\"ownerReferences\":[{\"uid\":\"dep-2\",\"kind\":\"Deployment\",\"name\":\"other-api\"}]},\"spec\":{\"replicas\":3},\"status\":{\"readyReplicas\":3}}],\"pods\":[{\"metadata\":{\"name\":\"other-pod-1\",\"namespace\":\"prod\",\"ownerReferences\":[{\"uid\":\"rs-foreign\",\"kind\":\"ReplicaSet\",\"name\":\"other-api-abc\"}]},\"status\":{\"phase\":\"Running\"}},{\"metadata\":{\"name\":\"other-pod-2\",\"namespace\":\"prod\",\"ownerReferences\":[{\"uid\":\"rs-foreign\",\"kind\":\"ReplicaSet\",\"name\":\"other-api-abc\"}]},\"status\":{\"phase\":\"Running\"}},{\"metadata\":{\"name\":\"other-pod-3\",\"namespace\":\"prod\",\"ownerReferences\":[{\"uid\":\"rs-foreign\",\"kind\":\"ReplicaSet\",\"name\":\"other-api-abc\"}]},\"status\":{\"phase\":\"Running\"}}],\"events\":[],\"quotas\":[],\"notes\":[]}"

///|
test "foreign workload Pods do not pad the target Pod count" {
  let snapshot = @snapshot.ClusterSnapshot::from_json(
    @json.parse(WORKLOAD_SNAPSHOT_FOREIGN),
  ).unwrap()
  let result = @core.diagnose(snapshot)
  match result.workload_facts {
    Some(facts) => inspect(facts.pod_count, content="0")
    None => inspect("missing workload facts", content="unexpected")
  }
  let ids = finding_ids(result.diagnosis.findings)
  inspect(list_contains(ids, "workload_no_pods"), content="true")
  // No uid-degradation note: the Deployment carries a uid, scoping succeeded.
  let degraded = result.diagnosis.notes
    .iter()
    .any(fn(note : String) { note.contains("无法按归属过滤") })
  inspect(degraded, content="false")
}

///|
test "Deployment without uid marks ReplicaSet scoping as degraded" {
  let snapshot = @snapshot.ClusterSnapshot::from_json(
    @json.parse(
      "{\"ns\":\"prod\",\"target_kind\":\"Deployment\",\"target_name\":\"no-uid\",\"deployment\":{\"metadata\":{\"name\":\"no-uid\",\"namespace\":\"prod\"},\"spec\":{\"replicas\":1}},\"replicasets\":[{\"metadata\":{\"name\":\"maybe-owned\",\"namespace\":\"prod\"},\"spec\":{\"replicas\":1},\"status\":{\"readyReplicas\":0}}],\"pods\":[],\"events\":[],\"quotas\":[],\"notes\":[]}",
    ),
  ).unwrap()
  let result = @core.diagnose(snapshot)
  let degraded = result.diagnosis.notes
    .iter()
    .any(fn(note : String) { note.contains("无法按归属过滤") })
  inspect(degraded, content="true")
}

///|
/// Offline fixture: the Pods list was collected with an RBAC failure, so the
/// snapshot marks it Unavailable instead of pretending the namespace has no
/// Pods. The workload diagnosis must downgrade accordingly.
const WORKLOAD_SNAPSHOT_PODS_UNAVAILABLE = "{\"ns\":\"prod\",\"target_kind\":\"Deployment\",\"target_name\":\"payments-api\",\"deployment\":{\"metadata\":{\"name\":\"payments-api\",\"namespace\":\"prod\",\"uid\":\"dep-1\"},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":0,\"availableReplicas\":0}},\"replicasets\":[{\"metadata\":{\"name\":\"payments-api-7d9f6b\",\"namespace\":\"prod\",\"uid\":\"rs-1\",\"ownerReferences\":[{\"uid\":\"dep-1\",\"kind\":\"Deployment\",\"name\":\"payments-api\"}]},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":0,\"conditions\":[{\"type\":\"ReplicaFailure\",\"status\":\"True\",\"reason\":\"FailedCreate\",\"message\":\"exceeded quota: compute, requested: pods=1, used: pods=10, limited: pods=10\"}]}}],\"pods\":[],\"events\":[],\"quotas\":[],\"limit_ranges\":[],\"data_status\":{\"replicasets\":\"available\",\"pods\":{\"state\":\"unavailable\",\"reason\":\"RBAC: pods list forbidden\"},\"events\":\"available\",\"quotas\":\"available\",\"limit_ranges\":\"available\"},\"notes\":[]}"

///|
test "unavailable Pods list downgrades the workload diagnosis" {
  let snapshot = @snapshot.ClusterSnapshot::from_json(
    @json.parse(WORKLOAD_SNAPSHOT_PODS_UNAVAILABLE),
  ).unwrap()
  let result = @core.diagnose(snapshot)
  match result.workload_facts {
    Some(facts) =>
      match facts.pods_status {
        Unavailable(reason) =>
          inspect(reason, content="RBAC: pods list forbidden")
        other => inspect(other, content="expected Unavailable")
      }
    None => inspect("missing workload facts", content="unexpected")
  }
  let ids = finding_ids(result.diagnosis.findings)
  inspect(list_contains(ids, "workload_no_pods"), content="false")
  inspect(list_contains(ids, "insufficient_evidence"), content="true")
  // The quota root cause survives on its own evidence (event + status.used).
  inspect(list_contains(ids, "quota_exceeded"), content="true")
}
