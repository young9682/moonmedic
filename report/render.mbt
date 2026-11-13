///|
/// Render a diagnosis as a Markdown report. Pure function over data:
/// easy to snapshot-test and to reuse for CLI/file/LLM outputs later.
pub fn render_markdown(d : @rules.Diagnosis) -> String {
  let out = []
  out.push("# moonmedic 诊断报告")
  out.push("")
  out.push("- Pod: `\{d.ns}/\{d.pod}`")
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
          "未命中已知规则。Pod 状态本身未呈现可自动判定的故障特征,建议结合事件与日志人工确认。",
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
