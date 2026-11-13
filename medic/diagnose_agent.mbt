///|
/// The W4 agent path: deterministic rule findings first (always present),
/// then the LLM agent loop with the read-only tool whitelist for the human
/// conclusion. Any agent failure degrades to the rule-only report with a
/// note - the pipeline never blocks on the LLM.
pub async fn diagnose_agent(
  target : @tools.K8sTarget,
  pod_name~ : String,
  config : @llm.LlmConfig,
  max_steps~ : Int32 = 8,
  logs_tail~ : Int32 = 100,
) -> @rules.Diagnosis {
  let (facts, notes) = gather_facts(target, pod_name~, logs_tail~)
  let findings = @rules.run_all(facts)
  let initial = @llm.build_summary_prompt(facts, findings)
  let user_msg : Map[String, Json] = Map([])
  user_msg["role"] = Json::string("user")
  user_msg["content"] = Json::string(
    "诊断目标:\{target.ns}/\{pod_name}。\n以下是已自动收集的证据与规则初筛,可用工具进一步取证:\n\n\{initial}",
  )
  let messages = [
    Json::object({
      "role": Json::string("system"),
      "content": Json::string(AGENT_SYSTEM),
    }),
    Json::object(user_msg),
  ]
  let tools = tool_defs()
  let mut summary : String? = None
  let mut converged = false
  let mut step = 0
  while step < max_steps && !converged {
    step = step + 1
    match @llm.chat_with_tools(config, messages~, tools~) {
      Err(message) => {
        notes.push("Agent 循环失败(第 \{step} 步):\{message}")
        break
      }
      Ok(turn) =>
        if turn.tool_calls.is_empty() {
          if !turn.content.is_empty() {
            summary = Some(turn.content)
          }
          converged = true
        } else {
          messages.push(build_assistant_msg(turn.content, turn.tool_calls))
          for call in turn.tool_calls {
            let result = execute_tool(target, pod_name~, call)
            messages.push(build_tool_msg(call.id, result))
          }
        }
    }
  }
  if !converged && summary is None {
    notes.push(
      "Agent 达到步数上限(\{max_steps})未收敛,已降级为规则报告",
    )
  }
  {
    ns: target.ns,
    pod: pod_name,
    phase: facts.phase,
    findings,
    notes,
    summary,
  }
}
