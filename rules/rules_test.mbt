///|
/// Fixture: pod in CrashLoopBackOff, previous termination was OOMKilled.
const OOMKILL_POD = "{\"metadata\":{\"name\":\"payments-api-7d9f6b-x2k9l\",\"namespace\":\"prod\"},\"spec\":{\"containers\":[{\"resources\":{\"limits\":{\"memory\":\"256Mi\"}}}]},\"status\":{\"phase\":\"Running\",\"containerStatuses\":[{\"restartCount\":12,\"state\":{\"waiting\":{\"reason\":\"CrashLoopBackOff\"}},\"lastState\":{\"terminated\":{\"reason\":\"OOMKilled\",\"exitCode\":137}}}]}}"

///|
/// Fixture: pod pending, scheduler reports insufficient memory.
const PENDING_POD = "{\"metadata\":{\"name\":\"worker-5f8a\",\"namespace\":\"batch\"},\"spec\":{\"containers\":[{\"resources\":{}}]},\"status\":{\"phase\":\"Pending\",\"containerStatuses\":[]}}"

///|
/// Small Array[String] membership helper (test-only).
fn list_contains(values : Array[String], target : String) -> Bool {
  for value in values {
    if value == target {
      return true
    }
  }
  false
}

///|
/// Build a structured event for fixtures.
fn event(
  reason : String,
  message : String,
  kind~ : String = "Pod",
  name~ : String = "",
  count~ : Int32 = 1,
) -> @rules.EventFact {
  {
    reason,
    message,
    event_type: "Warning",
    kind,
    name,
    count,
    last_seen: Some("2026-11-16T10:00:00Z"),
  }
}

///|
test "oomkilled_limit fires on OOMKilled pod" {
  let raw = @json.parse(OOMKILL_POD)
  let facts = @rules.PodFacts::from_pod(raw, events=[])
  let findings = @rules.run_all(facts)
  inspect(findings.length(), content="1")
  inspect(findings[0].rule_id, content="oomkilled_limit")
  inspect(facts.restarts, content="12")
  inspect(facts.mem_limit is Some("256Mi"), content="true")
  inspect(findings[0].evidence.length(), content="4")
}

///|
test "sched_insufficient fires with typed FailedScheduling event" {
  let raw = @json.parse(PENDING_POD)
  let events = [
    event("FailedScheduling", "0/6 nodes are available: insufficient memory."),
  ]
  let facts = @rules.PodFacts::from_pod(raw, events~)
  let findings = @rules.run_all(facts)
  inspect(findings.length(), content="1")
  inspect(findings[0].rule_id, content="sched_insufficient")
  inspect(findings[0].confidence == 0.85, content="true")
  inspect(findings[0].evidence[0].contains("Event/Pod"), content="true")
}

///|
test "healthy pod produces no findings" {
  let raw = @json.parse(
    "{\"metadata\":{\"name\":\"ok\",\"namespace\":\"x\"},\"status\":{\"phase\":\"Running\",\"containerStatuses\":[{\"restartCount\":0,\"state\":{\"running\":{}}}]}}",
  )
  let facts = @rules.PodFacts::from_pod(raw, events=[])
  inspect(@rules.run_all(facts).length(), content="0")
  inspect(facts.phase, content="Running")
}

///|
test "crash loop with non-oom exit 137 does not fire oom or crash_exit_1" {
  let raw = @json.parse(
    "{\"metadata\":{\"name\":\"a\",\"namespace\":\"x\"},\"status\":{\"phase\":\"Running\",\"containerStatuses\":[{\"restartCount\":3,\"state\":{\"waiting\":{\"reason\":\"CrashLoopBackOff\"}},\"lastState\":{\"terminated\":{\"reason\":\"Error\",\"exitCode\":137}}}]}}",
  )
  let facts = @rules.PodFacts::from_pod(raw, events=[])
  inspect(@rules.run_all(facts).length(), content="0")
}

///|
/// Fixture: pod stuck pulling a non-existent image tag.
const IMG_TAG_POD = "{\"metadata\":{\"name\":\"web-5d\",\"namespace\":\"prod\"},\"spec\":{\"containers\":[{\"image\":\"registry.example.com/app:v9.9.9\",\"resources\":{}}]},\"status\":{\"phase\":\"Pending\",\"containerStatuses\":[{\"restartCount\":0,\"state\":{\"waiting\":{\"reason\":\"ImagePullBackOff\"}}}]}}"

///|
/// Fixture: pod denied by a private registry.
const IMG_SECRET_POD = "{\"metadata\":{\"name\":\"pay-7f\",\"namespace\":\"prod\"},\"spec\":{\"containers\":[{\"image\":\"private.registry.corp/pay:2.1\",\"resources\":{}}]},\"status\":{\"phase\":\"Pending\",\"containerStatuses\":[{\"restartCount\":0,\"state\":{\"waiting\":{\"reason\":\"ImagePullBackOff\"}}}]}}"

///|
/// Fixture: running pod whose readiness probe keeps failing.
const PROBE_POD = "{\"metadata\":{\"name\":\"api-0\",\"namespace\":\"prod\"},\"spec\":{\"containers\":[{\"image\":\"app:1.0\",\"resources\":{}}]},\"status\":{\"phase\":\"Running\",\"containerStatuses\":[{\"restartCount\":0,\"state\":{\"running\":{}}}]}}"

///|
test "image_pull_tag fires on manifest unknown" {
  let raw = @json.parse(IMG_TAG_POD)
  let events = [
    event(
      "Failed", "Failed to pull image \"registry.example.com/app:v9.9.9\": manifest unknown",
    ),
  ]
  let facts = @rules.PodFacts::from_pod(raw, events~)
  let findings = @rules.run_all(facts)
  inspect(findings.length(), content="1")
  inspect(findings[0].rule_id, content="image_pull_tag")
  inspect(
    facts.image is Some("registry.example.com/app:v9.9.9"),
    content="true",
  )
  inspect(findings[0].evidence.length(), content="2")
}

///|
test "image_pull_secret fires on access denied" {
  let raw = @json.parse(IMG_SECRET_POD)
  let events = [
    event(
      "ErrImagePull", "pull access denied for pay, repository does not exist or may require authorization",
    ),
  ]
  let facts = @rules.PodFacts::from_pod(raw, events~)
  let findings = @rules.run_all(facts)
  inspect(findings.length(), content="1")
  inspect(findings[0].rule_id, content="image_pull_secret")
}

///|
test "probe_fail fires on typed Unhealthy event" {
  let raw = @json.parse(PROBE_POD)
  let events = [
    event(
      "Unhealthy", "Readiness probe failed: HTTP probe failed with statuscode: 404",
    ),
  ]
  let facts = @rules.PodFacts::from_pod(raw, events~)
  let findings = @rules.run_all(facts)
  inspect(findings.length(), content="1")
  inspect(findings[0].rule_id, content="probe_fail")
}

///|
test "quantity parser handles milli, binary and decimal suffixes" {
  inspect(@rules.parse_quantity("10") == Some(10.0), content="true")
  inspect(@rules.parse_quantity("500m") == Some(0.5), content="true")
  inspect(@rules.parse_quantity("64Mi") == Some(67108864.0), content="true")
  inspect(@rules.parse_quantity("4Gi") == Some(4294967296.0), content="true")
  inspect(@rules.parse_quantity("2G") == Some(2000000000.0), content="true")
  inspect(@rules.parse_quantity("abc") is None, content="true")
  inspect(@rules.quantity_compare("10", "10") == Some(0), content="true")
  inspect(@rules.quantity_compare("11", "10") == Some(1), content="true")
  inspect(@rules.quantity_saturated("10", "10"), content="true")
  inspect(@rules.quota_usage_percent("5", "10") == Some(50), content="true")
  inspect(@rules.quantity_headroom("7", "10") == Some(3.0), content="true")
}

///|
/// Fixture: Deployment whose ReplicaSet cannot create Pods because the
/// namespace quota for `pods` is exhausted. No Pod object exists at all.
const DEPLOYMENT_QUOTA = "{\"metadata\":{\"name\":\"payments-api\",\"namespace\":\"prod\",\"uid\":\"dep-1\"},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":0,\"availableReplicas\":0,\"conditions\":[{\"type\":\"Progressing\",\"status\":\"False\",\"reason\":\"ProgressDeadlineExceeded\",\"message\":\"ReplicaSet has timed out progressing\"}]}}"

///|
const REPLICASET_QUOTA = "{\"metadata\":{\"name\":\"payments-api-7d9f6b\",\"namespace\":\"prod\",\"uid\":\"rs-1\",\"ownerReferences\":[{\"uid\":\"dep-1\",\"kind\":\"Deployment\",\"name\":\"payments-api\"}]},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":0,\"conditions\":[{\"type\":\"ReplicaFailure\",\"status\":\"True\",\"reason\":\"FailedCreate\",\"message\":\"pods \\\"payments-api-7d9f6b-x2k9l\\\" is forbidden: exceeded quota: compute, requested: pods=1, used: pods=10, limited: pods=10\"}]}}"

///|
/// Same ownership, but no ReplicaFailure condition: used to test the
/// quota-at-capacity warning without a corroborated creation failure.
const REPLICASET_HEALTHY = "{\"metadata\":{\"name\":\"payments-api-7d9f6b\",\"namespace\":\"prod\",\"uid\":\"rs-1\",\"ownerReferences\":[{\"uid\":\"dep-1\",\"kind\":\"Deployment\",\"name\":\"payments-api\"}]},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":0}}"

///|
const QUOTA_COMPUTE = "{\"metadata\":{\"name\":\"compute\"},\"status\":{\"hard\":{\"pods\":\"10\",\"requests.cpu\":\"4\"},\"used\":{\"pods\":\"10\",\"requests.cpu\":\"4\"}}}"

///|
fn workload_fixture_facts(
  replicaset_raw : Json,
  quota_raw : Json,
  events : Array[@rules.EventFact],
  pod_count~ : Int32 = 0,
) -> @rules.WorkloadFacts raise {
  let quotas = match @rules.QuotaFact::from_json(quota_raw) {
    Some(quota) => [quota]
    None => []
  }
  @rules.WorkloadFacts::from_deployment(
    @json.parse(DEPLOYMENT_QUOTA),
    [replicaset_raw],
    events~,
    quotas~,
    pod_count~,
  )
}

///|
fn quota_fixture_facts(
  events : Array[@rules.EventFact],
) -> @rules.WorkloadFacts raise {
  workload_fixture_facts(
    @json.parse(REPLICASET_QUOTA),
    @json.parse(QUOTA_COMPUTE),
    events,
  )
}

///|
test "quota scenario: missing Pod is explained by quota + FailedCreate" {
  let events = [
    event(
      "FailedCreate",
      "pods \"payments-api-7d9f6b-x2k9l\" is forbidden: exceeded quota: compute, requested: pods=1, used: pods=10, limited: pods=10",
      kind="ReplicaSet",
      name="payments-api-7d9f6b",
      count=3,
    ),
  ]
  let facts = quota_fixture_facts(events)
  inspect(facts.pod_missing, content="true")
  inspect(facts.replicasets.length(), content="1")
  let findings = @rules.run_all_workload(facts)
  let ids = []
  for finding in findings {
    ids.push(finding.rule_id)
  }
  inspect(list_contains(ids, "quota_exceeded"), content="true")
  inspect(list_contains(ids, "replicaset_create_failed"), content="true")
  inspect(list_contains(ids, "workload_no_pods"), content="true")
  inspect(list_contains(ids, "quota_at_capacity"), content="false")
  inspect(findings[0].rule_id, content="quota_exceeded")
  inspect(findings[0].confidence == 0.98, content="true")
  inspect(findings[0].detail.contains("≥12"), content="true")
  inspect(findings[0].detail.contains("还差 2"), content="true")
  let evidence = findings[0].evidence.join("\n")
  inspect(evidence.contains("used=\"10\""), content="true")
  inspect(evidence.contains("hard=\"10\""), content="true")
  inspect(evidence.contains("FailedCreate"), content="true")
}

///|
test "pods recommendation counts only missing replicas" {
  let events = [
    event(
      "FailedCreate",
      "pods is forbidden: exceeded quota: compute",
      kind="ReplicaSet",
      name="payments-api-7d9f6b",
    ),
  ]
  let facts = workload_fixture_facts(
    @json.parse(REPLICASET_QUOTA),
    @json.parse(QUOTA_COMPUTE),
    events,
    pod_count=1,
  )
  let findings = @rules.run_all_workload(facts)
  inspect(findings[0].rule_id, content="quota_exceeded")
  inspect(findings[0].detail.contains("还差 1"), content="true")
  inspect(findings[0].detail.contains("≥11"), content="true")
}

///|
test "quota_exceeded without FailedCreate does not claim one" {
  let facts = workload_fixture_facts(
    @json.parse(REPLICASET_HEALTHY),
    @json.parse(QUOTA_COMPUTE),
    [],
    pod_count=0,
  )
  let findings = @rules.run_all_workload(facts)
  inspect(findings[0].rule_id, content="quota_exceeded")
  inspect(
    findings[0].detail.contains("未读取到 FailedCreate"),
    content="true",
  )
  inspect(findings[0].detail.contains("控制器已报告"), content="false")
}

///|
test "quota_at_capacity fires without a creation failure" {
  let facts = workload_fixture_facts(
    @json.parse(REPLICASET_HEALTHY),
    @json.parse(QUOTA_COMPUTE),
    [],
    pod_count=2,
  )
  let findings = @rules.run_all_workload(facts)
  let ids = []
  for finding in findings {
    ids.push(finding.rule_id)
  }
  inspect(list_contains(ids, "quota_at_capacity"), content="true")
  inspect(list_contains(ids, "quota_exceeded"), content="false")
}

///|
test "quota below hard limit does not fire" {
  let facts = workload_fixture_facts(
    @json.parse(REPLICASET_HEALTHY),
    @json.parse(
      "{\"metadata\":{\"name\":\"compute\"},\"status\":{\"hard\":{\"pods\":\"10\"},\"used\":{\"pods\":\"7\"}}}",
    ),
    [],
    pod_count=2,
  )
  let findings = @rules.run_all_workload(facts)
  let ids = []
  for finding in findings {
    ids.push(finding.rule_id)
  }
  inspect(list_contains(ids, "quota_at_capacity"), content="false")
  inspect(list_contains(ids, "quota_exceeded"), content="false")
}

///|
test "LimitRange rejection is distinguished from quota exhaustion" {
  let facts = workload_fixture_facts(
    @json.parse(REPLICASET_HEALTHY),
    @json.parse(
      "{\"metadata\":{\"name\":\"compute\"},\"status\":{\"hard\":{},\"used\":{}}}",
    ),
    [
      event(
        "FailedCreate",
        "pods \"x\" is forbidden: maximum cpu usage per Container is 1, but limit is 2",
        kind="ReplicaSet",
        name="payments-api-7d9f6b",
      ),
    ],
  )
  let findings = @rules.run_all_workload(facts)
  let ids = []
  for finding in findings {
    ids.push(finding.rule_id)
  }
  inspect(list_contains(ids, "limitrange_reject"), content="true")
}

///|
test "EventFact parses typed reason and involvedObject" {
  let raw = @json.parse(
    "{\"reason\":\"FailedCreate\",\"message\":\"exceeded quota\",\"type\":\"Warning\",\"count\":7,\"lastTimestamp\":\"2026-11-16T09:00:00Z\",\"involvedObject\":{\"kind\":\"ReplicaSet\",\"name\":\"app-6f7\"}}",
  )
  let parsed = @rules.EventFact::from_json(raw).unwrap()
  inspect(parsed.reason, content="FailedCreate")
  inspect(parsed.kind, content="ReplicaSet")
  inspect(parsed.name, content="app-6f7")
  inspect(parsed.count, content="7")
  inspect(parsed.text().contains("×7"), content="true")
}

///|
/// Fixture: unsaturated quota — used 3 of hard 10. Saturation alone gates the
/// quota root cause; without it, only quota-mentioning evidence counts.
const QUOTA_COMPUTE_UNSATURATED = "{\"metadata\":{\"name\":\"compute\"},\"status\":{\"hard\":{\"pods\":\"10\"},\"used\":{\"pods\":\"3\"}}}"

///|
/// Fixture: ReplicaFailure with a plain message that never mentions quota —
/// the cause could be LimitRange, a webhook or RBAC instead.
const REPLICASET_PLAIN_FAILURE = "{\"metadata\":{\"name\":\"payments-api-7d9f6b\",\"namespace\":\"prod\",\"uid\":\"rs-1\",\"ownerReferences\":[{\"uid\":\"dep-1\",\"kind\":\"Deployment\",\"name\":\"payments-api\"}]},\"spec\":{\"replicas\":2},\"status\":{\"readyReplicas\":0,\"conditions\":[{\"type\":\"ReplicaFailure\",\"status\":\"True\",\"reason\":\"FailedCreate\",\"message\":\"Error creating pod\"}]}}"

///|
fn finding_rule_ids(facts : @rules.WorkloadFacts) -> Array[String] {
  let ids = []
  for finding in @rules.run_all_workload(facts) {
    ids.push(finding.rule_id)
  }
  ids
}

///|
test "bare forbidden message does not corroborate quota_exceeded" {
  let events = [
    event(
      "FailedCreate",
      "pods \"payments-api-7d9f6b-x2k9l\" is forbidden: cannot create in namespace prod",
      kind="ReplicaSet",
      name="payments-api-7d9f6b",
      count=2,
    ),
  ]
  let facts = workload_fixture_facts(
    @json.parse(REPLICASET_PLAIN_FAILURE),
    @json.parse(QUOTA_COMPUTE_UNSATURATED),
    events,
  )
  let ids = finding_rule_ids(facts)
  inspect(list_contains(ids, "quota_exceeded"), content="false")
  // The creation failure itself is still reported as a mechanism finding.
  inspect(list_contains(ids, "replicaset_create_failed"), content="true")
}

///|
test "ReplicaFailure without quota wording does not corroborate quota_exceeded" {
  let facts = workload_fixture_facts(
    @json.parse(REPLICASET_PLAIN_FAILURE),
    @json.parse(QUOTA_COMPUTE_UNSATURATED),
    [],
  )
  let ids = finding_rule_ids(facts)
  inspect(list_contains(ids, "quota_exceeded"), content="false")
  inspect(list_contains(ids, "replicaset_create_failed"), content="true")
}

///|
test "plain FailedCreate event alone does not claim quota exhaustion" {
  let events = [
    event(
      "FailedCreate",
      "Error creating pod",
      kind="ReplicaSet",
      name="payments-api-7d9f6b",
      count=1,
    ),
  ]
  let facts = workload_fixture_facts(
    @json.parse(REPLICASET_PLAIN_FAILURE),
    @json.parse(QUOTA_COMPUTE_UNSATURATED),
    events,
  )
  let ids = finding_rule_ids(facts)
  inspect(list_contains(ids, "quota_exceeded"), content="false")
}

///|
test "quota-mentioning ReplicaFailure still corroborates on saturated quota" {
  let facts = quota_fixture_facts([])
  let ids = finding_rule_ids(facts)
  inspect(list_contains(ids, "quota_exceeded"), content="true")
}
