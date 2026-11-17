///|
/// One entry of the Pod knowledge base: a rule id, a human title and a
/// deterministic check over PodFacts. Adding a scenario means adding a table
/// row plus a unit test - no changes to the engine.
pub struct Rule {
  id : String
  title : String
  check : (PodFacts) -> Finding?
}

///|
/// One workload-level rule (Deployment -> ReplicaSet -> Pod). Kept separate
/// from the Pod rule table because the fact type and evidence sources differ.
pub struct WorkloadRule {
  id : String
  title : String
  check : (WorkloadFacts) -> Finding?
}

///|
/// First event matching a predicate, preserving API order.
fn first_event(
  events : Array[EventFact],
  predicate : (EventFact) -> Bool,
) -> EventFact? {
  for event in events {
    if predicate(event) {
      return Some(event)
    }
  }
  None
}

///|
/// Event evidence lines matching a predicate, capped so one chatty controller
/// cannot dominate the report.
fn event_evidence(
  events : Array[EventFact],
  predicate : (EventFact) -> Bool,
) -> Array[String] {
  let out : Array[String] = []
  for event in events {
    if predicate(event) {
      out.push(event.text())
      if out.length() >= 5 {
        break
      }
    }
  }
  out
}

///|
/// Rule: container was OOM-killed (exit 137, reason OOMKilled).
fn rule_oomkilled(facts : PodFacts) -> Finding? {
  if facts.last_term_reason != Some("OOMKilled") {
    return None
  }
  let evidence = [
    "pod.status.containerStatuses[].lastState.terminated.reason = OOMKilled",
    "pod.status.containerStatuses[].restartCount = \{facts.restarts}",
  ]
  match facts.last_term_exit {
    Some(exit) => evidence.push("lastState.terminated.exitCode = \{exit}")
    None => ()
  }
  match facts.mem_limit {
    Some(limit) =>
      evidence.push("pod.spec.containers[0].resources.limits.memory = \{limit}")
    None =>
      evidence.push(
        "pod.spec.containers[0].resources.limits.memory = 未设置",
      )
  }
  Some({
    rule_id: "oomkilled_limit",
    title: "容器因内存超限被内核杀掉(OOMKilled)",
    detail: "容器上次以 OOMKilled 结束,通常是 memory limit 过低或进程存在内存泄漏。建议:1) 对比进程实际内存与当前 limit;2) 排查泄漏;3) 适当提高 limits.memory。",
    confidence: 0.9,
    evidence,
    evidence_refs: pod_evidence_refs(
      facts,
      field_path="status.containerStatuses[0].lastState.terminated.reason",
      observed_value="OOMKilled",
    ),
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
    "pod.status.containerStatuses[].state.waiting.reason = CrashLoopBackOff",
    "lastState.terminated.exitCode = 1",
    "restartCount = \{facts.restarts}",
  ]
  Some({
    rule_id: "crash_exit_1",
    title: "应用进程反复崩溃退出(exit 1)",
    detail: "容器进入 CrashLoopBackOff 且上次退出码为 1,多为应用自身启动失败(配置缺失、依赖不可达、fatal 日志)。建议查看容器日志尾部的报错栈。",
    confidence: 0.8,
    evidence,
    evidence_refs: pod_evidence_refs(
      facts,
      field_path="state.waiting.reason",
      observed_value="CrashLoopBackOff",
    ),
  })
}

///|
/// Rule: pod stuck Pending because the scheduler rejected it. Matches the
/// typed event reason first; message text is only a compatibility fallback.
fn rule_sched_insufficient(facts : PodFacts) -> Finding? {
  if facts.phase != "Pending" {
    return None
  }
  if facts.waiting_reason is Some(_) {
    return None
  }
  let matched = first_event(facts.events, fn(event) {
    event.reason == "FailedScheduling" ||
    event.message.contains("FailedScheduling")
  })
  let event = match matched {
    Some(event) => event
    None => return None
  }
  Some({
    rule_id: "sched_insufficient",
    title: "Pod 处于 Pending,调度器拒绝放置",
    detail: "事件显示 FailedScheduling,常见原因是节点资源不足、配额打满或亲和性/污点不匹配。请结合事件消息中的具体缺口( cpu / memory / pvc )处理。",
    confidence: 0.85,
    evidence: [event.text()],
    evidence_refs: [
      evidence_ref(
        source="events",
        resource_kind=event.kind,
        object_name=event.name,
        field_path="events[reason=FailedCreate].message",
        observed_value=event.message,
        observed_at=event.last_seen,
      ),
    ],
  })
}

///|
/// Gate shared by the two image-pull rules: the container must be stuck in
/// an image-pull wait state.
fn image_pull_pending(facts : PodFacts) -> Bool {
  facts.waiting_reason is Some("ImagePullBackOff") ||
  facts.waiting_reason is Some("ErrImagePull")
}

///|
/// Token-level predicate for pull failures: prefer the typed reason, then
/// accept the message text used by older kubelets.
fn is_pull_event(event : EventFact) -> Bool {
  event.reason == "ErrImagePull" ||
  event.reason == "ImagePullBackOff" ||
  event.reason == "Failed" ||
  event.message.contains("Failed to pull image") ||
  event.message.contains("ErrImagePull")
}

///|
/// Rule: the image reference itself cannot be resolved (bad name/tag).
fn rule_image_pull_tag(facts : PodFacts) -> Finding? {
  if !image_pull_pending(facts) {
    return None
  }
  let matched = first_event(facts.events, fn(event) {
    is_pull_event(event) &&
    (
      event.message.contains("not found") ||
      event.message.contains("manifest unknown") ||
      event.message.contains("could not be found")
    )
  })
  let event = match matched {
    Some(event) => event
    None => return None
  }
  let evidence = [event.text()]
  match facts.image {
    Some(image) => evidence.push("pod.spec.containers[0].image = \{image}")
    None => ()
  }
  Some({
    rule_id: "image_pull_tag",
    title: "镜像名或 tag 无法解析",
    detail: "仓库返回 manifest unknown / not found:检查镜像名拼写与 tag 是否真实存在;若为私有仓库镜像被公开引用也会报此错。",
    confidence: 0.85,
    evidence,
    evidence_refs: [
      evidence_ref(
        source="pod",
        resource_kind="Pod",
        object_name=facts.pod,
        field_path="spec.containers[0].image",
        observed_value=facts.image.unwrap_or(""),
        observed_at=None,
      ),
      evidence_ref(
        source="events",
        resource_kind=event.kind,
        object_name=event.name,
        field_path="events[reason=FailedCreate].message",
        observed_value=event.message,
        observed_at=event.last_seen,
      ),
    ],
  })
}

///|
/// Rule: the registry rejected the pull (credentials/authorization).
fn rule_image_pull_secret(facts : PodFacts) -> Finding? {
  if !image_pull_pending(facts) {
    return None
  }
  let matched = first_event(facts.events, fn(event) {
    is_pull_event(event) &&
    (
      event.message.contains("denied") ||
      event.message.contains("authentication required") ||
      event.message.contains("authorization") ||
      event.message.contains("unauthorized")
    )
  })
  let event = match matched {
    Some(event) => event
    None => return None
  }
  Some({
    rule_id: "image_pull_secret",
    title: "镜像仓库拒绝拉取(凭据问题)",
    detail: "仓库返回 denied / authentication required:私有仓库需要 imagePullSecrets。检查 ServiceAccount 是否绑定了正确的 docker-registry secret,以及凭据是否过期。",
    confidence: 0.8,
    evidence: [event.text()],
    evidence_refs: [
      evidence_ref(
        source="pod",
        resource_kind="Pod",
        object_name=facts.pod,
        field_path="spec.containers[0].image",
        observed_value=facts.image.unwrap_or(""),
        observed_at=None,
      ),
      evidence_ref(
        source="events",
        resource_kind=event.kind,
        object_name=event.name,
        field_path="events[reason=FailedCreate].message",
        observed_value=event.message,
        observed_at=event.last_seen,
      ),
    ],
  })
}

///|
/// Rule: liveness/readiness probe failures reported by the kubelet.
fn rule_probe_fail(facts : PodFacts) -> Finding? {
  let matched = first_event(facts.events, fn(event) {
    event.reason == "Unhealthy" ||
    event.message.contains("probe failed") ||
    event.message.contains("Unhealthy")
  })
  let event = match matched {
    Some(event) => event
    None => return None
  }
  Some({
    rule_id: "probe_fail",
    title: "探针失败(kubelet 报告 Unhealthy)",
    detail: "常见原因:探针路径/端口配置错误、应用启动慢于探针初检(建议配置 startupProbe)、依赖服务不可达。结合探针类型与返回码定位。",
    confidence: 0.75,
    evidence: [event.text()],
    evidence_refs: [
      evidence_ref(
        source="events",
        resource_kind=event.kind,
        object_name=event.name,
        field_path="events[reason=Unhealthy].message",
        observed_value=event.message,
        observed_at=event.last_seen,
      ),
    ],
  })
}

///|
/// The Pod knowledge base table.
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
/// Run every Pod rule over the facts and collect findings.
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
/// Scan all quotas for resources whose usage reached the hard limit.
/// Returns (evidence lines, resource names).
fn saturated_quota_lines(
  facts : WorkloadFacts,
) -> (Array[String], Array[String]) {
  let lines : Array[String] = []
  let resources : Array[String] = []
  for quota in facts.quotas {
    for pair in quota.hard {
      let (resource, hard) = pair
      match quota.used_quantity(resource) {
        Some(used) =>
          if quantity_saturated(used, hard) {
            let percent = match quota_usage_percent(used, hard) {
              Some(value) => "\{value}%"
              // hard=0(如 pods=0)在数学上是 0/0:语义上任何请求都超限,
              // 显示 n/a 而不是空括号。
              None => "n/a"
            }
            lines.push(
              "ResourceQuota/\{quota.name} status: \{resource} used=\"\{used}\", hard=\"\{hard}\"(\{percent})",
            )
            resources.push(resource)
          }
        None => ()
      }
    }
  }
  (lines, resources)
}

///|
/// Build a structured evidence reference from fact-level fields. `source`
/// records where the value was collected from (kubernetes object kinds or
/// the snapshot computation layer).
fn evidence_ref(
  source~ : String,
  resource_kind~ : String,
  object_name~ : String,
  field_path~ : String,
  observed_value~ : String,
  observed_at~ : String? = None,
) -> Evidence {
  {
    source,
    resource_kind,
    object_name,
    field_path,
    observed_value,
    observed_at,
    resource_version: None,
  }
}

///|
/// Structured refs for Pod-field rules (PodFacts carries the observed values).
fn pod_evidence_refs(
  facts : PodFacts,
  field_path~ : String,
  observed_value~ : String,
) -> Array[Evidence] {
  [
    evidence_ref(
      source="pod",
      resource_kind="Pod",
      object_name=facts.pod,
      field_path~,
      observed_value~,
    ),
  ]
}

///|
/// Corroborating creation failures for the quota root cause. Narrow by
/// design: the evidence itself must mention quota. A bare "forbidden" or a
/// plain FailedCreate can come from LimitRange, admission webhooks or RBAC,
/// and must not upgrade the finding to "quota exceeded".
fn quota_failure_evidence(facts : WorkloadFacts) -> Array[String] {
  let lines = event_evidence(facts.events, fn(event) {
    event.is_failed_create() &&
    (
      event.message.contains("exceeded quota") ||
      event.message.contains("quota")
    )
  })
  for rs in facts.replicasets {
    for condition in rs.conditions {
      if condition.type_ == "ReplicaFailure" &&
        condition.status == "True" &&
        condition.message.contains("quota") {
        lines.push(
          "ReplicaSet/\{rs.name} condition ReplicaFailure(\{condition.reason}): \{condition.message}",
        )
      }
    }
  }
  lines
}

///|
/// Rule: a resource quota is exhausted AND a controller reported a creation
/// failure. This is the root-cause finding for "the Pod was never created".
fn rule_quota_exceeded(facts : WorkloadFacts) -> Finding? {
  let (quota_lines, resources) = saturated_quota_lines(facts)
  let failure_lines = quota_failure_evidence(facts)
  if quota_lines.length() == 0 && failure_lines.length() == 0 {
    return None
  }
  let evidence : Array[String] = []
  for line in quota_lines {
    evidence.push(line)
  }
  for line in failure_lines {
    evidence.push(line)
  }
  let corroborated = failure_lines.length() > 0
  let measured = quota_lines.length() > 0
  // A saturated quota alone is a warning, not a proven rejection. Require a
  // controller failure or the missing-Pod symptom before calling it a root
  // cause; otherwise `quota_at_capacity` owns the finding.
  // The pod_missing corroboration relies on a trustworthy Pod count: an
  // unavailable/truncated Pods list must not upgrade this finding.
  if !corroborated && (!facts.pod_missing || !facts.pods_status.is_usable()) {
    return None
  }
  let confidence = if corroborated && measured {
    0.98
  } else if corroborated {
    0.85
  } else {
    0.7
  }
  let resource_text = if resources.length() > 0 {
    "饱和资源:\{resources.join(", ")}。"
  } else {
    "配额对象未返回 used 数据,结论依据创建失败事件。"
  }
  let recommendation = match pods_quota_recommendation(facts) {
    Some(text) => text
    None => ""
  }
  let cause_text = if corroborated {
    "控制器已报告 FailedCreate,说明 Pod 不是崩溃而是根本没有被创建。"
  } else {
    "未读取到 FailedCreate 事件,但工作负载期望副本 > 0 而归属 Pod 为 0;结论依据配额数据与缺失 Pod 现象。"
  }
  let refs : Array[Evidence] = []
  for quota in facts.quotas {
    for pair in quota.hard {
      let (resource, hard) = pair
      match quota.used_quantity(resource) {
        Some(used) =>
          if quantity_saturated(used, hard) {
            refs.push(
              evidence_ref(
                source="resourcequota",
                resource_kind="ResourceQuota",
                object_name=quota.name,
                field_path="status." + resource,
                observed_value="used=" + used + ", hard=" + hard,
                observed_at=None,
              ),
            )
          }
        None => ()
      }
    }
  }
  for event in facts.events {
    if event.is_failed_create() && event.message.contains("quota") {
      refs.push(
        evidence_ref(
          source="events",
          resource_kind=event.kind,
          object_name=event.name,
          field_path="events[reason=FailedCreate].message",
          observed_value=event.message,
          observed_at=event.last_seen,
        ),
      )
    }
  }
  for rs in facts.replicasets {
    for condition in rs.conditions {
      if condition.type_ == "ReplicaFailure" &&
        condition.message.contains("quota") {
        refs.push(
          evidence_ref(
            source="replicaset",
            resource_kind="ReplicaSet",
            object_name=rs.name,
            field_path="status.conditions[ReplicaFailure].message",
            observed_value=condition.message,
            observed_at=None,
          ),
        )
      }
    }
  }
  Some({
    rule_id: "quota_exceeded",
    title: "命名空间配额耗尽,新 Pod 无法创建",
    detail: "\{resource_text}\{cause_text}\{recommendation}建议:1) 清理不再使用的 Pod/Job 释放配额;2) 核对 requests 与 limits 是否计入预期资源;3) 由管理员提高 ResourceQuota 上限。",
    confidence,
    evidence,
    evidence_refs: refs,
  })
}

///|
/// Compute a concrete `pods` quota recommendation: how many more Pods the
/// workload needs and what hard limit would admit them. Other resources stay
/// qualitative because their request sums need the Pod template.
fn pods_quota_recommendation(facts : WorkloadFacts) -> String? {
  let needed = facts.desired - facts.pod_count
  if needed <= 0 {
    return None
  }
  for quota in facts.quotas {
    let used = quota.used_quantity("pods")
    let hard = quota.hard_quantity("pods")
    if used is Some(used_text) {
      if hard is Some(hard_text) {
        if parse_quantity(used_text) is Some(used_value) {
          if parse_quantity(hard_text) is Some(hard_value) {
            let required = used_value + needed.to_double()
            if required > hard_value {
              let gap = (required - hard_value).to_int()
              return Some(
                "计算:pods 配额还差 \{gap} 个;将 hard 从 \{hard_text} 提高到 ≥\{required.to_int()},或缩容 \{gap} 个现有 Pod。",
              )
            }
          }
        }
      }
    }
  }
  None
}

///|
/// Rule: quota is at capacity but no creation failure has been observed yet.
fn rule_quota_at_capacity(facts : WorkloadFacts) -> Finding? {
  if quota_failure_evidence(facts).length() > 0 {
    return None
  }
  let (lines, _) = saturated_quota_lines(facts)
  if lines.length() == 0 {
    return None
  }
  let refs : Array[Evidence] = []
  for quota in facts.quotas {
    for pair in quota.hard {
      let (resource, hard) = pair
      match quota.used_quantity(resource) {
        Some(used) =>
          if quantity_saturated(used, hard) {
            refs.push(
              evidence_ref(
                source="resourcequota",
                resource_kind="ResourceQuota",
                object_name=quota.name,
                field_path="status." + resource,
                observed_value="used=" + used + ", hard=" + hard,
                observed_at=None,
              ),
            )
          }
        None => ()
      }
    }
  }
  for event in facts.events {
    if event.is_failed_create() && event.message.contains("quota") {
      refs.push(
        evidence_ref(
          source="events",
          resource_kind=event.kind,
          object_name=event.name,
          field_path="events[reason=FailedCreate].message",
          observed_value=event.message,
          observed_at=event.last_seen,
        ),
      )
    }
  }
  for rs in facts.replicasets {
    for condition in rs.conditions {
      if condition.type_ == "ReplicaFailure" &&
        condition.message.contains("quota") {
        refs.push(
          evidence_ref(
            source="replicaset",
            resource_kind="ReplicaSet",
            object_name=rs.name,
            field_path="status.conditions[ReplicaFailure].message",
            observed_value=condition.message,
            observed_at=None,
          ),
        )
      }
    }
  }
  Some({
    rule_id: "quota_at_capacity",
    title: "命名空间配额已用满",
    detail: "ResourceQuota 的 used 已达到 hard 上限。当前工作负载可能仍可运行,但任何新的 Pod 创建/滚动更新都可能被拒绝。建议提前清理或扩容配额。",
    confidence: 0.7,
    evidence: lines,
    evidence_refs: refs,
  })
}

///|
/// Rule: the ReplicaSet controller itself failed to create Pods. This is the
/// mechanism-level finding that explains a missing Pod.
fn rule_replicaset_create_failed(facts : WorkloadFacts) -> Finding? {
  for rs in facts.replicasets {
    for condition in rs.conditions {
      if condition.type_ == "ReplicaFailure" && condition.status == "True" {
        return Some({
          rule_id: "replicaset_create_failed",
          title: "ReplicaSet 创建 Pod 失败(FailedCreate)",
          detail: "ReplicaSet 的 ReplicaFailure 条件为 True,表示控制器已尝试创建 Pod 但被 API Server 拒绝。常见原因:ResourceQuota 耗尽、LimitRange 校验失败、准入 Webhook 拒绝。请结合同报告中的配额/准入证据定位。",
          confidence: 0.9,
          evidence: [
            "ReplicaSet/\{rs.name} desired=\{rs.desired}, ready=\{rs.ready}",
            "ReplicaSet/\{rs.name} condition: type=ReplicaFailure status=True reason=\{condition.reason} message=\{condition.message}",
          ],
          evidence_refs: [
            evidence_ref(
              source="replicaset",
              resource_kind="ReplicaSet",
              object_name=rs.name,
              field_path="status.conditions[ReplicaFailure].message",
              observed_value=condition.message,
              observed_at=None,
            ),
          ],
        })
      }
    }
  }
  None
}

///|
/// Rule: the workload desires Pods but none exist. This is the symptom that
/// a Pod-only diagnosis cannot see.
fn rule_workload_no_pods(facts : WorkloadFacts) -> Finding? {
  if !facts.pod_missing {
    return None
  }
  // "Zero Pods" is only a fact when the Pods list itself is trustworthy.
  if !facts.pods_status.is_usable() {
    return None
  }
  let failed : Array[EventFact] = []
  for event in facts.events {
    if event.is_failed_create() {
      failed.push(event)
    }
  }
  let confidence = if failed.length() > 0 { 0.9 } else { 0.75 }
  let evidence = [
    "Deployment/\{facts.name} spec.replicas = \{facts.desired}, status.readyReplicas = \{facts.ready}",
    "owned ReplicaSets = \{facts.replicasets.length()}, Pods owned by them = \{facts.pod_count}",
  ]
  for event in failed {
    evidence.push(event.text())
  }
  let cause_text = if !facts.events_status.is_usable() {
    "事件列表不可用,无法从事件侧排除或确认拒绝原因。"
  } else if failed.length() > 0 {
    "这不是容器启动失败,而是创建请求在准入阶段被拒绝。"
  } else {
    "未观察到 FailedCreate 事件;请检查控制器状态、RBAC 或准入 Webhook。"
  }
  let refs : Array[Evidence] = [
    evidence_ref(
      source="deployment",
      resource_kind="Deployment",
      object_name=facts.name,
      field_path="spec.replicas",
      observed_value="\{facts.desired}",
      observed_at=None,
    ),
    evidence_ref(
      source="deployment",
      resource_kind="Deployment",
      object_name=facts.name,
      field_path="status.readyReplicas",
      observed_value="\{facts.ready}",
      observed_at=None,
    ),
    evidence_ref(
      source="snapshot",
      resource_kind="Deployment",
      object_name=facts.name,
      field_path="owned_pod_count",
      observed_value="\{facts.pod_count}",
      observed_at=None,
    ),
  ]
  for event in failed {
    refs.push(
      evidence_ref(
        source="events",
        resource_kind=event.kind,
        object_name=event.name,
        field_path="events[reason=FailedCreate].message",
        observed_value=event.message,
        observed_at=event.last_seen,
      ),
    )
  }
  Some({
    rule_id: "workload_no_pods",
    title: "工作负载没有任何 Pod(不是崩溃,而是未创建)",
    detail: "控制器期望 \{facts.desired} 个副本,但其 ReplicaSet 下没有任何 Pod。\{cause_text}优先检查 FailedCreate 事件、ResourceQuota 与 LimitRange。",
    confidence,
    evidence,
    evidence_refs: refs,
  })
}

///|
/// Rule: LimitRange admission rejected the Pod shape (min/max or ratio).
fn rule_limitrange_reject(facts : WorkloadFacts) -> Finding? {
  let looks_like_limitrange = fn(message : String) {
    (
      message.contains("LimitRange") ||
      message.contains("minimum") ||
      message.contains("maximum") ||
      message.contains("must be less than or equal to") ||
      message.contains("Invalid value")
    ) &&
    !message.contains("exceeded quota")
  }
  let matched = first_event(facts.events, fn(event) {
    event.is_failed_create() && looks_like_limitrange(event.message)
  })
  let evidence : Array[String] = []
  let refs : Array[Evidence] = []
  match matched {
    Some(event) => {
      evidence.push(event.text())
      refs.push(
        evidence_ref(
          source="events",
          resource_kind=event.kind,
          object_name=event.name,
          field_path="events[reason=FailedCreate].message",
          observed_value=event.message,
          observed_at=event.last_seen,
        ),
      )
    }
    None => ()
  }
  for rs in facts.replicasets {
    for condition in rs.conditions {
      if condition.type_ == "ReplicaFailure" &&
        looks_like_limitrange(condition.message) {
        evidence.push(
          "ReplicaSet/\{rs.name} condition: \{condition.reason}: \{condition.message}",
        )
      }
    }
  }
  if evidence.length() == 0 {
    return None
  }
  Some({
    rule_id: "limitrange_reject",
    title: "LimitRange 校验拒绝创建 Pod",
    detail: "创建失败信息包含 LimitRange 的 min/max 约束。检查命名空间 LimitRange 的 default/min/max 与 Pod 的 requests/limits 是否匹配(尤其是未显式设置 resources 的容器)。",
    confidence: 0.85,
    evidence,
    evidence_refs: refs,
  })
}

///|
/// Rule: Deployment rollout is permanently blocked.
fn rule_deployment_stalled(facts : WorkloadFacts) -> Finding? {
  for condition in facts.conditions {
    if condition.type_ == "Progressing" &&
      condition.status == "False" &&
      condition.reason == "ProgressDeadlineExceeded" {
      return Some({
        rule_id: "deployment_stalled",
        title: "Deployment 滚动更新超时(ProgressDeadlineExceeded)",
        detail: "Deployment 在 progressDeadlineSeconds 内未达到可用副本数。结合失败原因(FailedCreate / 镜像 / 探针)定位;修复后删除旧 ReplicaSet 或重新触发 rollout。",
        confidence: 0.8,
        evidence: [
          "Deployment/\{facts.name} condition Progressing=False reason=ProgressDeadlineExceeded",
          "Deployment/\{facts.name} desired=\{facts.desired}, ready=\{facts.ready}, available=\{facts.available}",
        ],
        evidence_refs: [
          evidence_ref(
            source="deployment",
            resource_kind="Deployment",
            object_name=facts.name,
            field_path="status.conditions[Progressing]",
            observed_value=condition.message,
            observed_at=None,
          ),
        ],
      })
    }
  }
  for condition in facts.conditions {
    if condition.type_ == "ReplicaFailure" && condition.status == "True" {
      return Some({
        rule_id: "deployment_stalled",
        title: "Deployment 无法推进(ReplicaFailure)",
        detail: "Deployment 的 ReplicaFailure 条件为 True,说明控制器在创建 ReplicaSet/Pod 时被拒绝。查看同报告的 FailedCreate 与配额证据。",
        confidence: 0.8,
        evidence: [
          "Deployment/\{facts.name} condition ReplicaFailure=True reason=\{condition.reason} message=\{condition.message}",
        ],
        evidence_refs: [
          evidence_ref(
            source="deployment",
            resource_kind="Deployment",
            object_name=facts.name,
            field_path="status.conditions[condition.type_].message",
            observed_value=condition.message,
            observed_at=None,
          ),
        ],
      })
    }
  }
  None
}

///|
/// The workload knowledge base. Rules form a causal chain:
/// quota/limit (root cause) -> ReplicaSet FailedCreate (mechanism) ->
/// no Pods (symptom).

///|
/// Rule: a source that the pod-count conclusions depend on could not be
/// collected (or was truncated). This downgrades the diagnosis to
/// "insufficient evidence" instead of letting "the API said no" read as
/// "the cluster has none".
fn rule_insufficient_evidence(facts : WorkloadFacts) -> Finding? {
  let reasons : Array[String] = []
  if !facts.pods_status.is_usable() {
    reasons.push("Pods 列表: \{facts.pods_status.label()}")
  }
  if !facts.events_status.is_usable() {
    reasons.push("Events 列表: \{facts.events_status.label()}")
  }
  if reasons.is_empty() {
    return None
  }
  Some({
    rule_id: "insufficient_evidence",
    title: "采集不完整,诊断降级为部分证据",
    detail: "以下数据源不可用或被截断,依赖它们的结论已降级或不输出;请修复采集权限、放大分页上限后重试。",
    confidence: 0.2,
    evidence: reasons,
    evidence_refs: [
      evidence_ref(
        source="snapshot",
        resource_kind="ListStatus",
        object_name="pods",
        field_path="data_status.pods",
        observed_value=facts.pods_status.label(),
        observed_at=None,
      ),
      evidence_ref(
        source="snapshot",
        resource_kind="ListStatus",
        object_name="events",
        field_path="data_status.events",
        observed_value=facts.events_status.label(),
        observed_at=None,
      ),
    ],
  })
}

///|
let workload_rule_table : Array[WorkloadRule] = [
  {
    id: "quota_exceeded",
    title: "Quota exhausted",
    check: rule_quota_exceeded,
  },
  {
    id: "quota_at_capacity",
    title: "Quota at capacity",
    check: rule_quota_at_capacity,
  },
  {
    id: "limitrange_reject",
    title: "LimitRange rejection",
    check: rule_limitrange_reject,
  },
  {
    id: "replicaset_create_failed",
    title: "ReplicaSet FailedCreate",
    check: rule_replicaset_create_failed,
  },
  {
    id: "workload_no_pods",
    title: "Workload has no Pods",
    check: rule_workload_no_pods,
  },
  {
    id: "insufficient_evidence",
    title: "Insufficient evidence",
    check: rule_insufficient_evidence,
  },
  {
    id: "deployment_stalled",
    title: "Deployment stalled",
    check: rule_deployment_stalled,
  },
]

///|
/// Run every workload rule, then suppress the weaker quota warning when the
/// root-cause `quota_exceeded` finding already fired.
pub fn run_all_workload(facts : WorkloadFacts) -> Array[Finding] {
  let raw : Array[Finding] = []
  for rule in workload_rule_table {
    match (rule.check)(facts) {
      Some(finding) => raw.push(finding)
      None => ()
    }
  }
  let mut has_quota_exceeded = false
  for finding in raw {
    if finding.rule_id == "quota_exceeded" {
      has_quota_exceeded = true
    }
  }
  let findings : Array[Finding] = []
  for finding in raw {
    if has_quota_exceeded && finding.rule_id == "quota_at_capacity" {
      continue
    }
    findings.push(finding)
  }
  findings
}
