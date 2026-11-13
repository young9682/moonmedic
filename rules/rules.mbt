///|
/// One entry of the diagnostic knowledge base: a rule id, a human title and
/// a deterministic check over PodFacts. Adding a scenario means adding a
/// table row plus a unit test - no changes to the engine.
pub struct Rule {
  id : String
  title : String
  check : (PodFacts) -> Finding?
}

///|
/// Rule: container was OOM-killed (exit 137, reason OOMKilled).
fn rule_oomkilled(facts : PodFacts) -> Finding? {
  if facts.last_term_reason != Some("OOMKilled") {
    return None
  }
  let evidence = [
    "lastState.terminated.reason = OOMKilled",
    "restartCount = \{facts.restarts}",
  ]
  match facts.last_term_exit {
    Some(exit) => evidence.push("lastState.terminated.exitCode = \{exit}")
    None => ()
  }
  match facts.mem_limit {
    Some(limit) => evidence.push("resources.limits.memory = \{limit}")
    None => evidence.push("resources.limits.memory = 未设置")
  }
  Some({
    rule_id: "oomkilled_limit",
    title: "容器因内存超限被内核杀掉(OOMKilled)",
    detail: "容器上次以 OOMKilled 结束,通常是 memory limit 过低或进程存在内存泄漏。建议:1) 对比进程实际内存与当前 limit;2) 排查泄漏;3) 适当提高 limits.memory。",
    confidence: 0.9,
    evidence,
  })
}

///|
/// Rule: application crash loop with exit code 1.
fn rule_crash_exit_1(facts : PodFacts) -> Finding? {
  if facts.waiting_reason != Some("CrashLoopBackOff") {
    return None
  }
  if facts.last_term_exit != Some(1) {
    return None
  }
  let evidence = [
    "status.containerStatuses[].state.waiting.reason = CrashLoopBackOff",
    "lastState.terminated.exitCode = 1",
    "restartCount = \{facts.restarts}",
  ]
  Some({
    rule_id: "crash_exit_1",
    title: "应用进程反复崩溃退出(exit 1)",
    detail: "容器进入 CrashLoopBackOff 且上次退出码为 1,多为应用自身启动失败(配置缺失、依赖不可达、fatal 日志)。建议查看容器日志尾部的报错栈。",
    confidence: 0.8,
    evidence,
  })
}

///|
/// Rule: pod stuck Pending because the scheduler rejected it.
fn rule_sched_insufficient(facts : PodFacts) -> Finding? {
  if facts.phase != "Pending" {
    return None
  }
  if facts.waiting_reason is Some(_) {
    return None
  }
  let mut hit : String? = None
  for line in facts.events {
    if line.contains("FailedScheduling") {
      hit = Some(line)
      break
    }
  }
  let message = match hit {
    Some(line) => line
    None => return None
  }
  Some({
    rule_id: "sched_insufficient",
    title: "Pod 处于 Pending,调度器拒绝放置",
    detail: "事件显示 FailedScheduling,常见原因是节点资源不足、配额打满或亲和性/污点不匹配。请结合事件消息中的具体缺口( cpu / memory / pvc )处理。",
    confidence: 0.85,
    evidence: [message],
  })
}

///|
/// The knowledge base table. Order = evaluation order; multiple rules may
/// fire on the same facts.
let rule_table : Array[Rule] = [
  { id: "oomkilled_limit", title: "OOMKilled", check: rule_oomkilled, },
  { id: "crash_exit_1", title: "CrashLoop exit 1", check: rule_crash_exit_1, },
  {
    id: "sched_insufficient",
    title: "Pending / FailedScheduling",
    check: rule_sched_insufficient,
  },
  { id: "image_pull_tag", title: "ImagePull tag", check: rule_image_pull_tag, },
  {
    id: "image_pull_secret",
    title: "ImagePull auth",
    check: rule_image_pull_secret,
  },
  { id: "probe_fail", title: "probe failure", check: rule_probe_fail, },
]

///|
/// Run every rule over the facts and collect findings.
pub fn run_all(facts : PodFacts) -> Array[Finding] {
  let findings = []
  for rule in rule_table {
    match (rule.check)(facts) {
      Some(finding) => findings.push(finding)
      None => ()
    }
  }
  findings
}

///|
/// Gate shared by the two image-pull rules: the container must be stuck in
/// an image-pull wait state.
fn image_pull_pending(facts : PodFacts) -> Bool {
  facts.waiting_reason is Some("ImagePullBackOff") ||
  facts.waiting_reason is Some("ErrImagePull")
}

///|
/// Rule: the image reference itself cannot be resolved (bad name/tag).
fn rule_image_pull_tag(facts : PodFacts) -> Finding? {
  if !image_pull_pending(facts) {
    return None
  }
  let mut matched : String? = None
  for line in facts.events {
    if line.contains("Failed to pull image") &&
      (line.contains("not found") || line.contains("manifest unknown")) {
      matched = Some(line)
      break
    }
  }
  let line = match matched {
    Some(line) => line
    None => return None
  }
  let evidence = [line]
  match facts.image {
    Some(image) => evidence.push("spec.containers[0].image = \{image}")
    None => ()
  }
  Some({
    rule_id: "image_pull_tag",
    title: "镜像名或 tag 无法解析",
    detail: "仓库返回 manifest unknown / not found:检查镜像名拼写与 tag 是否真实存在;若为私有仓库镜像被公开引用也会报此错。",
    confidence: 0.85,
    evidence,
  })
}

///|
/// Rule: the registry rejected the pull (credentials/authorization).
fn rule_image_pull_secret(facts : PodFacts) -> Finding? {
  if !image_pull_pending(facts) {
    return None
  }
  let mut matched : String? = None
  for line in facts.events {
    if line.contains("denied") ||
      line.contains("authentication required") ||
      line.contains("authorization") {
      matched = Some(line)
      break
    }
  }
  let line = match matched {
    Some(line) => line
    None => return None
  }
  Some({
    rule_id: "image_pull_secret",
    title: "镜像仓库拒绝拉取(凭据问题)",
    detail: "仓库返回 denied / authentication required:私有仓库需要 imagePullSecrets。检查 ServiceAccount 是否绑定了正确的 docker-registry secret,以及凭据是否过期。",
    confidence: 0.8,
    evidence: [line],
  })
}

///|
/// Rule: liveness/readiness probe failures reported by the kubelet.
fn rule_probe_fail(facts : PodFacts) -> Finding? {
  let mut matched : String? = None
  for line in facts.events {
    if line.contains("probe failed") || line.contains("Unhealthy") {
      matched = Some(line)
      break
    }
  }
  let line = match matched {
    Some(line) => line
    None => return None
  }
  Some({
    rule_id: "probe_fail",
    title: "探针失败(kubelet 报告 Unhealthy)",
    detail: "常见原因:探针路径/端口配置错误、应用启动慢于探针初检(建议配置 startupProbe)、依赖服务不可达。结合探针类型与返回码定位。",
    confidence: 0.75,
    evidence: [line],
  })
}
