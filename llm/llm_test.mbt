///|
test "build_summary_prompt includes facts, findings and events" {
  let facts = @rules.PodFacts::empty(events=[
    "FailedScheduling: 0/6 nodes are available: insufficient memory.",
  ])
  let findings = [
    @rules.Finding::{
      rule_id: "sched_insufficient",
      title: "Pod 处于 Pending,调度器拒绝放置",
      detail: "d",
      confidence: 0.85,
      evidence: ["FailedScheduling: ..."],
    },
  ]
  let prompt = build_summary_prompt(facts, findings)
  inspect(prompt.contains("sched_insufficient"), content="true")
  inspect(prompt.contains("FailedScheduling"), content="true")
  inspect(prompt.contains("phase: Unknown"), content="true")
}

///|
test "build_summary_prompt trims long log tails to 2000 chars" {
  let long_log = "x".repeat(5000)
  let facts = @rules.PodFacts::empty(events=[], logs=long_log)
  let prompt = build_summary_prompt(facts, [])
  inspect(prompt.length() < 5000, content="true")
  inspect(prompt.contains("## 日志尾部"), content="true")
}

///|
test "try_from_parts validates base_url and model" {
  match @llm.LlmConfig::try_from_parts(base_url="", model="m") {
    Err(message) => inspect(message, content="base_url is empty")
    Ok(_) => inspect("unexpected Ok", content="expected Err")
  }
  match
    @llm.LlmConfig::try_from_parts(
      base_url="https://api.deepseek.com/v1/",
      model="deepseek-chat",
      api_key="sk-test",
    ) {
    Ok(config) => {
      inspect(config.base_url, content="https://api.deepseek.com/v1")
      inspect(config.api_key is Some(_), content="true")
    }
    Err(message) => inspect(message, content="expected Ok")
  }
}
