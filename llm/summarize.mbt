///|
/// System prompt for the moonmedic summarizer. Grounded-answers discipline:
/// only evidence provided, explicit "证据不足" when unsure, bounded length.
const SYSTEM_PROMPT = "你是 moonmedic,Kubernetes 集群的只读排障助手。只依据给出的证据回答,禁止臆造证据中没有的信息;证据不足时必须明确写\"证据不足\"。输出 Markdown,不超过 250 字,结构为:\n**根因**:…\n**依据**:…(引用给出的证据)\n**建议**:…(最多 3 条,具体可执行)\n**置信度**:高/中/低"

///|
/// Build the user prompt from facts + rule findings. Pure function, so the
/// prompt format is unit-testable without an API key.
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
      out.push("- \{facts.events[i]}")
    }
  }
  match facts.logs_tail {
    Some(logs) => {
      out.push("")
      out.push("## 日志尾部")
      let trimmed = if logs.length() > 2000 {
        // Keep the tail: crash evidence lives at the end of the log.
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
/// One-shot summarization: rules triage + raw evidence -> human conclusion.
/// Any failure returns Err; the caller degrades to the rule-only report.
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
