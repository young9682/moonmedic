///|
/// Shared evidence gathering for the agent path. The deterministic paths use
/// `tools.pod_snapshot` / `tools.workload_snapshot` instead, so both share
/// the same snapshot IR while the agent keeps its live tool loop.
async fn gather_facts(
  target : @tools.K8sTarget,
  pod_name~ : String,
  logs_tail~ : Int32,
) -> (@rules.PodFacts, Array[String], String?) {
  let pod = @tools.get_pod(target, name=pod_name)
  let notes = []
  let pod_uid = match pod {
    Ok(pod) => @rules.object_uid(pod.raw())
    Err(_) => None
  }
  let events = match @tools.list_events_json(target) {
    Ok(items) => events_for_pod(items, ns=target.ns, pod_name~, pod_uid?)
    Err(message) => {
      notes.push("事件读取失败:\{message}")
      []
    }
  }
  let container = match pod {
    Ok(pod) => @tools.first_container_name(pod)
    Err(_) => None
  }
  let logs = match
    @tools.get_logs(target, pod_name~, tail=logs_tail, container?) {
    Ok(text) => Some(text)
    Err(message) => {
      notes.push("日志读取失败:\{message}")
      None
    }
  }
  let facts = match pod {
    Ok(pod) => @rules.PodFacts::from_pod(pod.raw(), events~, logs?)
    Err(message) => {
      notes.push("Pod 读取失败:\{message}")
      @rules.PodFacts::empty(events~, logs?)
    }
  }
  (facts, notes, pod_uid)
}

///|
/// Filter raw Event objects down to one Pod, keeping the typed fields.
fn events_for_pod(
  items : Array[Json],
  ns~ : String,
  pod_name~ : String,
  pod_uid? : String,
) -> Array[@rules.EventFact] {
  let out : Array[@rules.EventFact] = []
  for raw in items {
    if @rules.event_matches_object(
        raw,
        ns~,
        kind="Pod",
        name=pod_name,
        uid?=pod_uid,
      ) &&
      @rules.EventFact::from_json(raw) is Some(event) {
      out.push(event)
      if out.length() >= 50 {
        break
      }
    }
  }
  out
}

///|
/// Diagnose a Pod by name. Pods that do not exist are reported as such; the
/// caller may use `diagnose_target` for the automatic workload fallback.
pub async fn diagnose_pod(
  target : @tools.K8sTarget,
  pod_name~ : String,
  logs_tail~ : Int32 = 100,
  llm_config? : @llm.LlmConfig,
) -> @rules.Diagnosis {
  let snapshot = @tools.pod_snapshot(target, pod_name~, logs_tail~)
  let result = @core.diagnose(snapshot)
  match (llm_config, result.pod_facts) {
    (Some(config), Some(facts)) =>
      summarize_pod(config, facts, result.diagnosis)
    _ => result.diagnosis
  }
}

///|
/// Diagnose a Deployment. The snapshot builder walks ReplicaSets and counts
/// Pods by ownerReference, so a Pod that was never created is evidence, not a
/// dead end.
pub async fn diagnose_workload(
  target : @tools.K8sTarget,
  name~ : String,
  llm_config? : @llm.LlmConfig,
) -> @rules.Diagnosis {
  match @tools.workload_snapshot(target, name~) {
    Ok(snapshot) => {
      let result = @core.diagnose(snapshot)
      match (llm_config, result.workload_facts) {
        (Some(config), Some(facts)) =>
          summarize_workload(config, facts, result.diagnosis)
        _ => result.diagnosis
      }
    }
    Err(message) => {
      let notes = ["工作负载读取失败:\{message}"]
      {
        ns: target.ns,
        target: name,
        target_kind: "Deployment",
        phase: "Unknown",
        findings: [],
        notes,
        summary: None,
      }
    }
  }
}

///|
/// Diagnose by name with automatic fallback: try the Pod first, then a
/// Deployment with the same name. This is the path used by the plain
/// `<ns> <name>` CLI form.
pub async fn diagnose_target(
  target : @tools.K8sTarget,
  name~ : String,
  llm_config? : @llm.LlmConfig,
) -> @rules.Diagnosis {
  let snapshot = @tools.pod_snapshot(target, pod_name=name)
  if snapshot.pod is Some(_) {
    let result = @core.diagnose(snapshot)
    return match (llm_config, result.pod_facts) {
      (Some(config), Some(facts)) =>
        summarize_pod(config, facts, result.diagnosis)
      _ => result.diagnosis
    }
  }
  match @tools.workload_snapshot(target, name~) {
    Ok(workload_snapshot) => {
      let result = @core.diagnose(workload_snapshot)
      let switch_note = if notes_indicate_not_found(snapshot.notes) {
        "Pod 不存在,已切换为同名 Deployment 诊断"
      } else {
        "Pod 未能读取,已尝试同名 Deployment 诊断"
      }
      let notes : Array[String] = [switch_note]
      for note in result.diagnosis.notes {
        notes.push(note)
      }
      let diagnosis = { ..result.diagnosis, notes, }
      match (llm_config, result.workload_facts) {
        (Some(config), Some(facts)) =>
          summarize_workload(config, facts, diagnosis)
        _ => diagnosis
      }
    }
    Err(message) => {
      let result = @core.diagnose(snapshot)
      let notes : Array[String] = []
      for note in result.diagnosis.notes {
        notes.push(note)
      }
      notes.push("同名 Deployment 诊断也失败:\{message}")
      { ..result.diagnosis, notes, }
    }
  }
}

///|
/// True when a Pod read failed because the object was absent, as opposed to
/// a transport/RBAC failure. Used only to word the fallback note accurately.
fn notes_indicate_not_found(notes : Array[String]) -> Bool {
  for note in notes {
    if note.contains("HTTP 404") ||
      note.contains("NotFound") ||
      note.contains("not found") {
      return true
    }
  }
  false
}

///|
/// Attach an optional Pod conclusion. LLM failure is a note, not a fatal
/// error: the deterministic diagnosis is always returned.
async fn summarize_pod(
  config : @llm.LlmConfig,
  facts : @rules.PodFacts,
  diagnosis : @rules.Diagnosis,
) -> @rules.Diagnosis {
  match @llm.summarize(config, facts, diagnosis.findings) {
    Ok(text) => { ..diagnosis, summary: Some(text), }
    Err(message) => {
      let notes : Array[String] = []
      for note in diagnosis.notes {
        notes.push(note)
      }
      notes.push("LLM 归纳失败:\{message}")
      { ..diagnosis, notes, }
    }
  }
}

///|
/// Attach an optional workload conclusion with the same degradation contract.
async fn summarize_workload(
  config : @llm.LlmConfig,
  facts : @rules.WorkloadFacts,
  diagnosis : @rules.Diagnosis,
) -> @rules.Diagnosis {
  match @llm.summarize_workload(config, facts, diagnosis.findings) {
    Ok(text) => { ..diagnosis, summary: Some(text), }
    Err(message) => {
      let notes : Array[String] = []
      for note in diagnosis.notes {
        notes.push(note)
      }
      notes.push("LLM 归纳失败:\{message}")
      { ..diagnosis, notes, }
    }
  }
}
