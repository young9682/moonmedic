///|
/// Render a diagnosis as a Markdown report. Pure function over data:
/// easy to snapshot-test and to reuse for CLI/file/LLM outputs later.
pub fn render_markdown(d : @rules.Diagnosis) -> String {
  let out = []
  out.push("# moonmedic 诊断报告")
  out.push("")
  let target_label = if d.target_kind.is_empty() {
    "Pod"
  } else {
    d.target_kind
  }
  out.push("- \{target_label}: `\{d.ns}/\{d.target}`")
  out.push("- Phase: `\{d.phase}`")
  out.push("")
  // LLM conclusion comes first when available: it is the human-readable
  // answer; the rule findings below are its evidence trail. The deterministic
  // "no rule hit" conclusion only appears when no LLM summary exists.
  match d.summary {
    Some(text) => {
      out.push("## 结论(LLM 归纳)")
      out.push("")
      out.push(text)
      out.push("")
    }
    None =>
      if d.findings.length() == 0 {
        out.push("## 结论")
        out.push("")
        out.push(
          "未命中已知规则。对象状态本身未呈现可自动判定的故障特征,建议结合事件、配额与日志人工确认。",
        )
        out.push("")
      }
  }
  if d.findings.length() > 0 {
    out.push("## 发现(\{d.findings.length()} 条)")
    out.push("")
    for finding in d.findings {
      let percent = (finding.confidence * 100.0).to_int()
      out.push("### [\{finding.rule_id}] \{finding.title}")
      out.push("")
      out.push("- 置信度: \{percent}%")
      out.push("- 判断: \{finding.detail}")
      out.push("- 证据:")
      for item in finding.evidence {
        out.push("  - \{item}")
      }
      for ref in finding.evidence_refs {
        out.push(
          "  - ⌗ \{ref.resource_kind}/\{ref.object_name} · \{ref.field_path} = \{ref.observed_value}",
        )
      }
      out.push("")
    }
  }
  if d.notes.length() > 0 {
    out.push("## 数据完整性说明")
    out.push("")
    for note in d.notes {
      out.push("- \{note}")
    }
    out.push("")
  }
  let mode = match d.summary {
    Some(_) => "+LLM 归纳"
    None => "仅规则引擎"
  }
  out.push("---")
  out.push(
    "由 moonmedic 生成 · 只读诊断 · \{mode} · 建议仅供参考",
  )
  out.join("\n")
}

///|
/// Machine-readable diagnosis for eval harnesses. The shape is stable:
/// target identity, findings with rule ids and evidence, notes and the
/// optional LLM summary.
pub fn render_json(d : @rules.Diagnosis) -> String {
  let root : Map[String, Json] = Map([])
  root["ns"] = Json::string(d.ns)
  root["target"] = Json::string(d.target)
  root["target_kind"] = Json::string(d.target_kind)
  root["phase"] = Json::string(d.phase)
  let findings : Array[Json] = []
  for finding in d.findings {
    let item : Map[String, Json] = Map([])
    item["rule_id"] = Json::string(finding.rule_id)
    item["title"] = Json::string(finding.title)
    item["detail"] = Json::string(finding.detail)
    item["confidence"] = Json::number(finding.confidence)
    item["layer"] = Json::string(finding_layer(finding.rule_id))
    let evidence : Array[Json] = []
    for line in finding.evidence {
      evidence.push(Json::string(line))
    }
    item["evidence"] = Json::array(evidence)
    let refs : Array[Json] = []
    for ref in finding.evidence_refs {
      let ref_item : Map[String, Json] = Map([])
      ref_item["source"] = Json::string(ref.source)
      ref_item["resource_kind"] = Json::string(ref.resource_kind)
      ref_item["object_name"] = Json::string(ref.object_name)
      ref_item["field_path"] = Json::string(ref.field_path)
      ref_item["observed_value"] = Json::string(ref.observed_value)
      match ref.observed_at {
        Some(at) => ref_item["observed_at"] = Json::string(at)
        None => ()
      }
      refs.push(Json::object(ref_item))
    }
    item["evidence_refs"] = Json::array(refs)
    findings.push(Json::object(item))
  }
  root["findings"] = Json::array(findings)
  let notes : Array[Json] = []
  for note in d.notes {
    notes.push(Json::string(note))
  }
  root["notes"] = Json::array(notes)
  root["summary"] = match d.summary {
    Some(text) => Json::string(text)
    None => Json::null()
  }
  Json::object(root).stringify()
}

///|
/// Diagnosis layer per rule (Task B presentation layering): root_cause /
/// mechanism / symptom / insufficient. Unknown rule ids fall back to
/// "related" so the JSON contract stays forward-compatible.
fn finding_layer(rule_id : String) -> String {
  match rule_id {
    "quota_exceeded"
    | "limitrange_reject"
    | "oomkilled_limit"
    | "crash_exit_1"
    | "image_pull_tag"
    | "image_pull_secret"
    | "sched_insufficient"
    | "probe_fail" => "root_cause"
    "replicaset_create_failed" | "deployment_stalled" => "mechanism"
    "workload_no_pods" => "symptom"
    "insufficient_evidence" => "insufficient"
    _ => "related"
  }
}
