///|
/// Pure diagnostic result: the rendered diagnosis plus the fact set the LLM
/// narrator may use. Keeping facts here lets the narrator stay optional while
/// the deterministic path remains the source of truth.
pub(all) struct SnapshotDiagnosis {
  diagnosis : @rules.Diagnosis
  pod_facts : @rules.PodFacts?
  workload_facts : @rules.WorkloadFacts?
}

///|
/// Diagnose one snapshot. This is the whole offline core: no kubemoon, no
/// LLM, no network. The caller decides how the snapshot was obtained.
pub fn diagnose(snapshot : @snapshot.ClusterSnapshot) -> SnapshotDiagnosis {
  if snapshot.target_kind == "Deployment" {
    diagnose_workload(snapshot, parse_quotas(snapshot.quotas))
  } else if snapshot.target_kind == "Pod" {
    diagnose_pod(snapshot)
  } else {
    let notes = clone_notes(snapshot.notes)
    notes.push(
      "不支持的目标类型: \{snapshot.target_kind}(当前支持 Pod / Deployment)",
    )
    {
      diagnosis: {
        ns: snapshot.ns,
        target: snapshot.target_name,
        target_kind: snapshot.target_kind,
        phase: "Unknown",
        findings: [],
        notes,
        summary: None,
      },
      pod_facts: None,
      workload_facts: None,
    }
  }
}

///|
/// Workload path: walk Deployment -> ReplicaSet -> Pod count, then run the
/// admission/runtime workload rules over the facts.
fn diagnose_workload(
  snapshot : @snapshot.ClusterSnapshot,
  quotas : Array[@rules.QuotaFact],
) -> SnapshotDiagnosis {
  let deployment_uid = match snapshot.deployment {
    Some(raw) => @rules.object_uid(raw)
    None => None
  }
  // Scope the ReplicaSet list to the target Deployment before counting Pods:
  // namespace-wide lists would let a foreign workload's Pods pad the target's
  // count and mask the "Pod was never created" symptom.
  let (scoped_replicasets, scoped_by_uid) = owned_replicasets(
    snapshot.replicasets,
    deployment_uid,
  )
  let scoped_events = events_for_workload(
    snapshot,
    deployment_uid,
    if scoped_by_uid {
      scoped_replicasets
    } else {
      []
    },
  )
  let pod_count = count_owned_pods(scoped_replicasets, snapshot.pods)
  let facts = match snapshot.deployment {
    Some(raw) =>
      @rules.WorkloadFacts::from_deployment(
        raw,
        scoped_replicasets,
        events=scoped_events,
        quotas~,
        pod_count~,
        pods_status=snapshot.pods_status,
        events_status=snapshot.events_status,
      )
    None =>
      @rules.WorkloadFacts::empty(
        ns=snapshot.ns,
        kind="Deployment",
        name=snapshot.target_name,
        events=scoped_events,
        quotas~,
        pods_status=snapshot.pods_status,
        events_status=snapshot.events_status,
      )
  }
  let findings = @rules.run_all_workload(facts)
  let notes = clone_notes(snapshot.notes)
  if snapshot.deployment is None {
    notes.push(
      "未读取到 Deployment 对象,结论仅基于事件与配额证据",
    )
  }
  if scoped_by_uid is false && snapshot.deployment is Some(_) {
    notes.push(
      "Deployment 缺少 uid,无法按归属过滤 ReplicaSet;Pod 计数可能包含同 namespace 其他工作负载,证据不完整",
    )
  }
  if facts.replicasets.length() == 0 {
    notes.push(
      "未发现归属该 Deployment 的 ReplicaSet,无法确认控制器是否尝试创建 Pod",
    )
  }
  {
    diagnosis: {
      ns: snapshot.ns,
      target: snapshot.target_name,
      target_kind: "Deployment",
      phase: "Deployment",
      findings,
      notes,
      summary: None,
    },
    pod_facts: None,
    workload_facts: Some(facts),
  }
}

///|
/// Pod path: runtime facts from the Pod object + events + logs.
fn diagnose_pod(snapshot : @snapshot.ClusterSnapshot) -> SnapshotDiagnosis {
  let uid = match snapshot.pod {
    Some(raw) => @rules.object_uid(raw)
    None => None
  }
  let scoped_events = @rules.events_from_items(
    snapshot.events.filter(fn(raw) {
      @rules.event_matches_object(
        raw,
        ns=snapshot.ns,
        kind="Pod",
        name=snapshot.target_name,
        uid?,
      )
    }),
  )
  let facts = match snapshot.pod {
    Some(raw) =>
      @rules.PodFacts::from_pod(raw, events=scoped_events, logs?=snapshot.logs)
    None => @rules.PodFacts::empty(events=scoped_events, logs?=snapshot.logs)
  }
  let findings = @rules.run_all(facts)
  let notes = clone_notes(snapshot.notes)
  if snapshot.pod is None {
    notes.push(
      "Pod 对象不可用(不存在或读取失败),运行时状态与日志证据缺失;若目标是工作负载请使用 --deployment",
    )
  }
  {
    diagnosis: {
      ns: snapshot.ns,
      target: snapshot.target_name,
      target_kind: "Pod",
      phase: facts.phase,
      findings,
      notes,
      summary: None,
    },
    pod_facts: Some(facts),
    workload_facts: None,
  }
}

///|
/// Parse ResourceQuota objects, skipping malformed entries.
fn parse_quotas(items : Array[Json]) -> Array[@rules.QuotaFact] {
  let out : Array[@rules.QuotaFact] = []
  for item in items {
    match @rules.QuotaFact::from_json(item) {
      Some(quota) => out.push(quota)
      None => ()
    }
  }
  out
}

///|
/// Keep only ReplicaSets owned by the target Deployment (ownerReference UID
/// match). When the Deployment UID is unavailable, scoping is impossible:
/// return the unfiltered list and report the degradation explicitly - the
/// caller must never present a possibly-polluted count as exact.
fn owned_replicasets(
  replicasets : Array[Json],
  deployment_uid : String?,
) -> (Array[Json], Bool) {
  match deployment_uid {
    Some(uid) => {
      let owned = []
      for rs in replicasets {
        if @rules.owned_by_uid(rs, uid) {
          owned.push(rs)
        }
      }
      (owned, true)
    }
    None => (replicasets, false)
  }
}

///|
/// Count Pods whose ownerReference points at any owned ReplicaSet. This is
/// the "did the controller manage to create anything?" signal.
fn count_owned_pods(replicasets : Array[Json], pods : Array[Json]) -> Int32 {
  let uids : Array[String] = []
  for raw in replicasets {
    match @rules.object_uid(raw) {
      Some(uid) => uids.push(uid)
      None => ()
    }
  }
  let mut count = 0
  for pod in pods {
    let mut owned = false
    for uid in uids {
      if @rules.owned_by_uid(pod, uid) {
        owned = true
        break
      }
    }
    if owned {
      count = count + 1
    }
  }
  count
}

///|
/// Qualify the Deployment and owned ReplicaSet names with their current
/// identity so retained events for a deleted namesake cannot drive diagnosis.
fn events_for_workload(
  snapshot : @snapshot.ClusterSnapshot,
  deployment_uid : String?,
  owned : Array[Json],
) -> Array[@rules.EventFact] {
  let targets : Map[(String, String), String?] = Map([])
  targets[("Deployment", snapshot.target_name)] = deployment_uid
  for raw in owned {
    if raw is Object(fields) &&
      fields.get("metadata") is Some(Object(meta)) &&
      meta.get("name") is Some(String(name)) {
      targets[("ReplicaSet", name)] = @rules.object_uid(raw)
    }
  }
  let out : Array[@rules.EventFact] = []
  for raw in snapshot.events {
    if @rules.EventFact::from_json(raw) is Some(event) &&
      targets.get((event.kind, event.name)) is Some(uid) &&
      @rules.event_matches_object(
        raw,
        ns=snapshot.ns,
        kind=event.kind,
        name=event.name,
        uid?,
      ) {
      out.push(event)
    }
  }
  out
}

///|
/// Copy notes so the caller's snapshot is not mutated by diagnosis.
fn clone_notes(notes : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for note in notes {
    out.push(note)
  }
  out
}
