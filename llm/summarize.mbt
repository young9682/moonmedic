///|
/// System prompt for the moonmedic summarizer. Grounded-answers discipline:
/// only evidence provided, explicit "证据不足" when unsure, bounded length.
const SYSTEM_PROMPT = "你是 moonmedic,Kubernetes 集群的只读排障助手。只依据给出的证据回答,禁止臆造证据中没有的信息;证据不足时必须明确写\"证据不足\"。输出 Markdown,不超过 250 字,结构为:\n**根因**:…\n**依据**:…(引用给出的证据)\n**建议**:…(最多 3 条,具体可执行)\n**置信度**:高/中/低"

///|
/// Build the user prompt for a Pod diagnosis. Pure function, so the prompt
/// format is unit-testable without an API key.
pub fn build_summary_prompt(
  facts : @rules.PodFacts,
  findings : Array[@rules.Finding],
) -> String {
  let out = []
  out.push("请归纳以下 Kubernetes Pod 的诊断证据并给出结论。")
  out.push("")
  out.push("## 对象")
  out.push("- namespace/pod: \{facts.ns}/\{facts.pod}")
  out.push("- phase: \{facts.phase},重启次数: \{facts.restarts}")
  match facts.waiting_reason {
    Some(reason) => out.push("- 当前等待原因: \{reason}")
    None => ()
  }
  match facts.last_term_reason {
    Some(reason) =>
      out.push(
        "- 上次终止: \{reason}(exit \{facts.last_term_exit.unwrap_or(-1)})",
      )
    None => ()
  }
  match facts.mem_limit {
    Some(limit) => out.push("- 内存限制: \{limit}")
    None => ()
  }
  if findings.length() > 0 {
    out.push("")
    out.push("## 规则引擎初筛")
    for finding in findings {
      out.push(
        "- [\{finding.rule_id}] \{finding.title}(置信 \{(finding.confidence * 100.0).to_int()}%)",
      )
      for item in finding.evidence {
        out.push("  - 证据: \{item}")
      }
    }
  }
  if facts.events.length() > 0 {
    out.push("")
    out.push("## 相关事件")
    let cap = if facts.events.length() > 20 {
      20
    } else {
      facts.events.length()
    }
    for i in 0..<cap {
      out.push("- \{facts.events[i].text()}")
    }
  }
  match facts.logs_tail {
    Some(logs) => {
      out.push("")
      out.push("## 日志尾部")
      let trimmed = if logs.length() > 2000 {
        substring_tail(logs, 2000)
      } else {
        logs
      }
      out.push(trimmed)
    }
    None => out.push("")
  }
  out.join("\n")
}

///|
/// Build the user prompt for a workload diagnosis: object graph, conditions,
/// quota usage and typed events, plus the deterministic findings.
pub fn build_workload_prompt(
  facts : @rules.WorkloadFacts,
  findings : Array[@rules.Finding],
) -> String {
  let out = []
  out.push(
    "请归纳以下 Kubernetes 工作负载的诊断证据并给出结论。",
  )
  out.push("")
  out.push("## 对象")
  out.push("- namespace/deployment: \{facts.ns}/\{facts.name}")
  out.push(
    "- spec.replicas: \{facts.desired}, readyReplicas: \{facts.ready}, availableReplicas: \{facts.available}",
  )
  out.push(
    "- 归属 ReplicaSet 数: \{facts.replicasets.length()}, 归属 Pod 数: \{facts.pod_count}",
  )
  if facts.pod_missing {
    out.push("- 现象:期望副本 > 0,但归属 Pod 数为 0")
  }
  if facts.conditions.length() > 0 {
    out.push("")
    out.push("## Deployment 条件")
    for condition in facts.conditions {
      out.push(
        "- \{condition.type_}=\{condition.status} reason=\{condition.reason} message=\{condition.message}",
      )
    }
  }
  if facts.replicasets.length() > 0 {
    out.push("")
    out.push("## ReplicaSet")
    for rs in facts.replicasets {
      out.push("- \{rs.name}: desired=\{rs.desired}, ready=\{rs.ready}")
      for condition in rs.conditions {
        out.push(
          "  - \{condition.type_}=\{condition.status} reason=\{condition.reason} message=\{condition.message}",
        )
      }
    }
  }
  if facts.quotas.length() > 0 {
    out.push("")
    out.push("## ResourceQuota")
    for quota in facts.quotas {
      for pair in quota.hard {
        let (resource, hard) = pair
        let used = quota.used_quantity(resource).unwrap_or("?")
        out.push("- \{quota.name}: \{resource} used=\{used}, hard=\{hard}")
      }
    }
  }
  if findings.length() > 0 {
    out.push("")
    out.push("## 规则引擎初筛")
    for finding in findings {
      out.push(
        "- [\{finding.rule_id}] \{finding.title}(置信 \{(finding.confidence * 100.0).to_int()}%)",
      )
      for item in finding.evidence {
        out.push("  - 证据: \{item}")
      }
    }
  }
  if facts.events.length() > 0 {
    out.push("")
    out.push("## 相关事件")
    let cap = if facts.events.length() > 20 {
      20
    } else {
      facts.events.length()
    }
    for i in 0..<cap {
      out.push("- \{facts.events[i].text()}")
    }
  }
  out.join("\n")
}

///|
/// Last n characters of a string, for log tail trimming.
fn substring_tail(value : String, n : Int32) -> String {
  let len = value.length()
  if len <= n {
    value
  } else {
    value[len - n:len].to_owned()
  }
}

///|
/// One-shot Pod summarization: rules triage + raw evidence -> human
/// conclusion. Any failure returns Err; the caller degrades to rules only.
pub async fn summarize(
  config : LlmConfig,
  facts : @rules.PodFacts,
  findings : Array[@rules.Finding],
) -> Result[String, String] {
  let prompt = build_summary_prompt(facts, findings)
  let config = if config.system_prompt.is_empty() {
    { ..config, system_prompt: SYSTEM_PROMPT, }
  } else {
    config
  }
  chat_complete(config, user_prompt=prompt)
}

///|
/// One-shot workload summarization. The deterministic findings remain the
/// source of truth; the model only narrates them.
pub async fn summarize_workload(
  config : LlmConfig,
  facts : @rules.WorkloadFacts,
  findings : Array[@rules.Finding],
) -> Result[String, String] {
  let prompt = build_workload_prompt(facts, findings)
  let config = if config.system_prompt.is_empty() {
    { ..config, system_prompt: SYSTEM_PROMPT, }
  } else {
    config
  }
  chat_complete(config, user_prompt=prompt)
}
