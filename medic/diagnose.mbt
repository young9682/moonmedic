///|
/// The W2 diagnosis pipeline: gather facts with read-only tools, then run
/// the rule table. No LLM yet (W3) - this path must stay useful on its own.
pub async fn diagnose_pod(
  target : @tools.K8sTarget,
  pod_name~ : String,
  logs_tail~ : Int32 = 100,
) -> @rules.Diagnosis {
  let pod = @tools.get_pod(target, name=pod_name)
  let notes = []
  // Events and logs are best-effort evidence: failing to read them must not
  // abort the diagnosis, it becomes a note in the report.
  let events = match @tools.get_events(target, pod_name~) {
    Ok(lines) => lines
    Err(message) => {
      notes.push("事件读取失败:\{message}")
      []
    }
  }
  // Logs target the first container: the API rejects container-less log
  // requests on multi-container pods (verified live in W2).
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
      // Pod itself unreadable: still run rules over the evidence we have,
      // so scheduling-related findings from events are not lost.
      notes.push("Pod 读取失败:\{message}")
      @rules.PodFacts::empty(events~, logs?)
    }
  }
  let findings = @rules.run_all(facts)
  { ns: target.ns, pod: pod_name, phase: facts.phase, findings, notes, }
}
