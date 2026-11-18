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
priv struct CreationFailure {
  line : String
  reference : Evidence
}

///|
fn is_create_failure(condition : ConditionFact) -> Bool {
  condition.type_ == "ReplicaFailure" &&
  condition.status == "True" &&
  condition.reason == "FailedCreate"
}

///|
fn creation_failures(facts : WorkloadFacts) -> Array[CreationFailure] {
  let failures : Array[CreationFailure] = []
  for event in facts.events {
    if event.is_failed_create() &&
      (event.kind == "ReplicaSet" || event.kind == "Deployment") {
      failures.push({
        line: event.text(),
        reference: evidence_ref(
          source="events",
          resource_kind=event.kind,
          object_name=event.name,
          field_path="events[reason=FailedCreate].message",
          observed_value=event.message,
          observed_at=event.last_seen,
        ),
      })
    }
  }
  for rs in facts.replicasets {
    for condition in rs.conditions {
      if is_create_failure(condition) {
        failures.push({
          line: "ReplicaSet/\{rs.name} condition ReplicaFailure(FailedCreate): \{condition.message}",
          reference: evidence_ref(
            source="replicaset",
            resource_kind="ReplicaSet",
            object_name=rs.name,
            field_path="status.conditions[ReplicaFailure].message",
            observed_value=condition.message,
          ),
        })
      }
    }
  }
  failures
}

///|
fn quota_status_line(
  quota : QuotaFact,
  resource : String,
  used : String,
  hard : String,
) -> String {
  let percent = match quota_usage_percent(used, hard) {
    Some(value) => "\{value}%"
    None => "n/a"
  }
  "ResourceQuota/\{quota.name} status: \{resource} used=\"\{used}\", hard=\"\{hard}\"(\{percent})"
}

///|
fn append_quota_status(
  evidence : Array[String],
  refs : Array[Evidence],
  quota : QuotaFact,
  resource : String,
  used : String,
  hard : String,
) -> Unit {
  evidence.push(quota_status_line(quota, resource, used, hard))
  refs.push(
    evidence_ref(
      source="resourcequota",
      resource_kind="ResourceQuota",
      object_name=quota.name,
      field_path="status.used.\{resource}",
      observed_value=used,
    ),
  )
  refs.push(
    evidence_ref(
      source="resourcequota",
      resource_kind="ResourceQuota",
      object_name=quota.name,
      field_path="status.hard.\{resource}",
      observed_value=hard,
    ),
  )
}

///|
/// Keep explicit controller denials distinct from present-day saturation.
/// Status corroborates only a matching quota name and resource delta.
fn rule_quota_exceeded(facts : WorkloadFacts) -> Finding? {
  let evidence : Array[String] = []
  let refs : Array[Evidence] = []
  let requested_by_quota : Map[String, Map[String, Double]] = Map([])
  for failure in creation_failures(facts) {
    if classify_admission(failure.reference.observed_value)
      is QuotaExceeded(rejection) {
      evidence.push(failure.line)
      refs.push(failure.reference)
      let requests = match requested_by_quota.get(rejection.name) {
        Some(requests) => requests
        None => {
          let requests = Map([])
          requested_by_quota[rejection.name] = requests
          requests
        }
      }
      for resource, request in rejection.requested {
        // Use the largest recorded delta when multiple attempts differ.
        if request > requests.get(resource).unwrap_or(0.0) {
          requests[resource] = request
        }
      }
    }
  }
  if requested_by_quota.length() == 0 {
    return None
  }

  let mut measured = false
  let recommendations : Array[String] = []
  for quota in facts.quotas {
    if requested_by_quota.get(quota.name) is Some(requests) {
      for resource, request in requests {
        guard quota.used_quantity(resource) is Some(used) &&
          quota.hard_quantity(resource) is Some(hard) &&
          admission_quantity(used.trim()) is Some(used_value) &&
          admission_quantity(hard.trim()) is Some(hard_value) &&
          request > hard_value - used_value else {
          continue
        }
        measured = true
        append_quota_status(evidence, refs, quota, resource, used, hard)
        if resource == "pods" && request == 1.0 {
          if pods_quota_recommendation(
              facts,
              quota.name,
              used_value,
              hard_value,
            )
            is Some(text) {
            recommendations.push(text)
          }
        }
      }
    }
  }
  let explanation = if measured {
    "快照中的同名配额及同一资源项仍满足 used + requested > hard。"
  } else {
    "拒绝记录识别出配额超限，当前快照没有可佐证的同名配额资源数值。"
  }
  if recommendations.length() > 0 {
    refs.push(
      evidence_ref(
        source="deployment",
        resource_kind="Deployment",
        object_name=facts.name,
        field_path="spec.replicas",
        observed_value="\{facts.desired}",
      ),
    )
    refs.push(
      evidence_ref(
        source="snapshot",
        resource_kind="Deployment",
        object_name=facts.name,
        field_path="owned_pod_count",
        observed_value="\{facts.pod_count}",
      ),
    )
  }
  Some({
    rule_id: "quota_exceeded",
    title: "创建 Pod 请求超过 ResourceQuota",
    detail: explanation + recommendations.join(""),
    confidence: if measured {
      0.98
    } else {
      0.85
    },
    evidence,
    evidence_refs: refs,
  })
}

///|
fn pods_quota_recommendation(
  facts : WorkloadFacts,
  quota_name : String,
  used : Double,
  hard : Double,
) -> String? {
  let needed = facts.desired - facts.pod_count
  if needed <= 0 || !facts.pods_status.is_usable() {
    return None
  }
  let required = used + needed.to_double()
  let int_max = 2147483647.0
  if required <= hard ||
    required > int_max ||
    used != used.to_int().to_double() ||
    hard != hard.to_int().to_double() {
    return None
  }
  let gap = (required - hard).to_int()
  Some(
    "按当前用量与缺失副本估算，ResourceQuota/\{quota_name} 的 pods 配额还差 \{gap} 个，需 hard ≥\{required.to_int()}。",
  )
}

///|
fn rule_quota_at_capacity(facts : WorkloadFacts) -> Finding? {
  let evidence : Array[String] = []
  let refs : Array[Evidence] = []
  for quota in facts.quotas {
    for pair in quota.hard {
      let (resource, hard) = pair
      if quota.used_quantity(resource) is Some(used) &&
        quantity_saturated(used, hard) {
        append_quota_status(evidence, refs, quota, resource, used, hard)
      }
    }
  }
  if evidence.length() == 0 {
    return None
  }
  Some({
    rule_id: "quota_at_capacity",
    title: "命名空间存在已用满的配额",
    detail: "快照中部分资源的 used 已达到 hard。若新 Pod 计入该配额，创建可能受阻。请结合控制器的拒绝记录确认原因。",
    confidence: 0.7,
    evidence,
    evidence_refs: refs,
  })
}

///|
/// Rule: the ReplicaSet controller itself failed to create Pods. This is the
/// mechanism-level finding that explains a missing Pod.
fn rule_replicaset_create_failed(facts : WorkloadFacts) -> Finding? {
  for rs in facts.replicasets {
    for condition in rs.conditions {
      if is_create_failure(condition) {
        let detail = match classify_admission(condition.message) {
          MissingQuotaResources =>
            "ReplicaSet 报告 FailedCreate。配额要求显式声明资源，请按原始消息补齐 requests 或 limits。"
          Unclassified =>
            "ReplicaSet 报告 FailedCreate。请从原始消息确认创建失败原因。"
          QuotaExceeded(_) | LimitRangeRejected =>
            "ReplicaSet 报告 FailedCreate。请结合报告中的配额或 LimitRange 证据定位。"
        }
        return Some({
          rule_id: "replicaset_create_failed",
          title: "ReplicaSet 创建 Pod 失败(FailedCreate)",
          detail,
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
  if first_event(facts.events, fn(event) {
      event.kind == "ReplicaSet" && event.is_failed_create()
    })
    is Some(event) {
    return Some({
      rule_id: "replicaset_create_failed",
      title: "ReplicaSet 创建 Pod 失败(FailedCreate)",
      detail: "观察到 ReplicaSet 的 FailedCreate 事件。请核对原始创建失败消息。",
      confidence: 0.9,
      evidence: [event.text()],
      evidence_refs: [
        evidence_ref(
          source="events",
          resource_kind="ReplicaSet",
          object_name=event.name,
          field_path="events[reason=FailedCreate].message",
          observed_value=event.message,
          observed_at=event.last_seen,
        ),
      ],
    })
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
    "观察到控制器的 FailedCreate 记录，请结合消息查找失败原因。"
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
    title: "快照中工作负载的归属 Pod 数为零",
    detail: "控制器期望 \{facts.desired} 个副本,但其 ReplicaSet 下没有任何 Pod。\{cause_text}优先检查 FailedCreate 事件、ResourceQuota 与 LimitRange。",
    confidence,
    evidence,
    evidence_refs: refs,
  })
}

///|
/// Rule: LimitRange admission rejected the Pod shape (min/max or ratio).
fn rule_limitrange_reject(facts : WorkloadFacts) -> Finding? {
  let evidence : Array[String] = []
  let refs : Array[Evidence] = []
  for failure in creation_failures(facts) {
    if classify_admission(failure.reference.observed_value)
      is LimitRangeRejected {
      evidence.push(failure.line)
      refs.push(failure.reference)
    }
  }
  if evidence.length() == 0 {
    return None
  }
  Some({
    rule_id: "limitrange_reject",
    title: "LimitRange 校验拒绝创建 Pod",
    detail: "控制器的拒绝消息符合 LimitRanger 约束格式。请按证据中的资源项检查命名空间 LimitRange 与 Pod 的 requests 和 limits。",
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
