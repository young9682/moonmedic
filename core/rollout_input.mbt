///|
fn field(raw : Json, key : String) -> Json {
  match raw {
    Object(fields) => fields.get(key).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
fn count(raw : Json) -> Int32 {
  match raw {
    Number(n, ..) if n >= 0 && n <= 100000000 && n.to_int().to_double() == n =>
      n.to_int()
    _ => -1
  }
}

///|
fn status_count(raw : Json, key : String) -> Int32 {
  match field(field(raw, "status"), key) {
    Null => 0
    x => count(x)
  }
}

///|
fn template(raw : Json) -> Json? {
  guard field(field(raw, "spec"), "template") is Object(t) &&
    t.get("spec") is Some(Object(_)) &&
    t.get("metadata") is Some(Object(m)) &&
    m.get("labels") is Some(Object(labels)) else {
    return None
  }
  let copy = labels.copy()
  copy.remove("pod-template-hash")
  let meta = m.copy()
  meta["labels"] = Json::object(copy)
  let result = t.copy()
  result["metadata"] = Json::object(meta)
  Some(Json::object(result))
}

///|
fn controller_uid(raw : Json, kind : String) -> String? {
  guard field(field(raw, "metadata"), "ownerReferences") is Array(refs) else {
    return None
  }
  for r in refs {
    if field(r, "kind") == Json::string(kind) &&
      field(r, "controller") == Json::boolean(true) &&
      field(r, "uid") is String(uid) &&
      !uid.is_empty() {
      return Some(uid)
    }
  }
  None
}

///|
fn has_zero_replicas(rs : Json) -> Bool {
  count(field(field(rs, "spec"), "replicas")) == 0 &&
  count(field(field(rs, "status"), "replicas")) == 0 &&
  status_count(rs, "availableReplicas") == 0 &&
  status_count(rs, "readyReplicas") == 0 &&
  status_count(rs, "fullyLabeledReplicas") == 0 &&
  status_count(rs, "terminatingReplicas") == 0
}

///|
fn quota_count(raw : Json) -> Int32 {
  guard raw is String(s) else { return -1 }
  let n = @string.parse_int(s[:]) catch { _ => return -1 }
  if n >= 0 && n <= 100000000 && n.to_string() == s {
    n
  } else {
    -1
  }
}

///|
/// Keep budgets in hundredths of a replica until both values are validated.
fn rollout_scaled_budget(
  raw : Json,
  replicas : Int32,
  percent_limit : Int64,
) -> Int64 {
  guard raw is String(text) else { return count(raw).to_int64() * 100L }
  guard text.has_suffix("%") && text.length() > 1 else { return -1L }
  let digits = text[:text.length() - 1]
  guard digits.iter().all(fn(c) { c >= '0' && c <= '9' }) else { return -1L }
  let percent = @string.parse_int64(digits, base=10) catch { _ => return -1L }
  guard percent <= percent_limit else { return -1L }
  percent * replicas.to_int64()
}

///|
fn rollout_ref(
  kind : String,
  name : String,
  path : String,
  value : Json,
) -> @rules.Evidence {
  {
    source: "snapshot",
    resource_kind: kind,
    object_name: name,
    field_path: path,
    observed_value: value.stringify(),
    observed_at: None,
    resource_version: None,
  }
}

///|
fn rollout_finding(
  s : @snapshot.ClusterSnapshot,
  dep : Json,
  sets : Array[Json],
) -> Result[@rules.Finding, String] {
  guard s.pods_status.is_usable() &&
    s.replicasets_status.is_usable() &&
    s.quotas_status.is_usable() else {
    return Err("列表不完整")
  }
  let spec = field(dep, "spec")
  let strategy = field(spec, "strategy")
  guard field(strategy, "type") == Json::string("RollingUpdate") &&
    field(spec, "paused") != Json::boolean(true) &&
    field(field(dep, "metadata"), "deletionTimestamp") == Json::null() else {
    return Err("需要活动的 RollingUpdate")
  }
  let ru = field(strategy, "rollingUpdate")
  let replicas = count(field(spec, "replicas"))
  guard replicas > 0 else { return Err("需要正副本数") }
  // Only maxUnavailable is restricted to 100% by Kubernetes. The larger
  // maxSurge bound keeps the scaled product within Int64 and the model range.
  let max_budget = 10000000000L
  let surge_scaled = rollout_scaled_budget(
    field(ru, "maxSurge"),
    replicas,
    max_budget,
  )
  let unavailable_scaled = rollout_scaled_budget(
    field(ru, "maxUnavailable"),
    replicas,
    100L,
  )
  guard surge_scaled >= 0 &&
    surge_scaled <= max_budget &&
    unavailable_scaled >= 0 &&
    (surge_scaled > 0 || unavailable_scaled > 0) else {
    return Err("需要有效的整数或百分比发布参数")
  }
  let surge = ((surge_scaled + 99L) / 100L).to_int()
  let unavailable = (unavailable_scaled / 100L).to_int()
  // ResolveFenceposts allows one unavailable replica when rounding would
  // otherwise leave a valid strategy with no room to move.
  let unavailable = if surge == 0 && unavailable == 0 { 1 } else { unavailable }
  guard template(dep) is Some(target) &&
    @rules.object_uid(dep) is Some(dep_uid) &&
    !dep_uid.is_empty() &&
    field(field(dep, "metadata"), "namespace") == Json::string(s.ns) &&
    field(field(dep, "metadata"), "name") == Json::string(s.target_name) else {
    return Err("缺少模板或 Deployment UID")
  }
  let owned : Map[String, Bool] = Map([])
  let current : Array[(String, Json)] = []
  let previous : Array[(String, Json)] = []
  for rs in sets {
    let meta = field(rs, "metadata")
    guard controller_uid(rs, "Deployment") == Some(dep_uid) &&
      field(meta, "namespace") == Json::string(s.ns) &&
      field(meta, "deletionTimestamp") == Json::null() &&
      @rules.object_uid(rs) is Some(uid) &&
      !uid.is_empty() &&
      !owned.contains(uid) else {
      return Err("RS 归属不完整")
    }
    guard template(rs) is Some(rs_template) else {
      return Err("无法唯一识别新旧模板")
    }
    owned[uid] = true
    if rs_template == target {
      current.push((uid, rs))
    } else {
      previous.push((uid, rs))
    }
  }
  guard current.length() == 1 && previous.length() > 0 else {
    return Err("无法唯一识别新旧模板")
  }
  let (new_uid, new_rs) = current[0]
  guard s.quotas.length() == 1 else {
    return Err("仅支持单个无作用域 pods 配额")
  }
  let quota = s.quotas[0]
  let qspec = field(quota, "spec")
  let qs = field(quota, "status")
  let qhard = field(qs, "hard")
  guard field(field(quota, "metadata"), "namespace") == Json::string(s.ns) &&
    field(qspec, "scopes") == Json::null() &&
    field(qspec, "scopeSelector") == Json::null() &&
    qhard is Object(h) &&
    h.length() == 1 &&
    field(qspec, "hard") == qhard else {
    return Err("配额存在其他约束或状态尚未同步")
  }
  let hard = quota_count(field(qhard, "pods"))
  let used = quota_count(field(field(qs, "used"), "pods"))
  guard hard >= 0 && used >= 0 && used <= hard else {
    return Err("无法核实 pods 配额")
  }
  let active_pods : Map[String, Int32] = Map([])
  let retiring_pods : Map[String, Int32] = Map([])
  let mut other_retiring = 0
  let mut total = 0
  let additional_refs : Array[@rules.Evidence] = []
  for pod in s.pods {
    let meta = field(pod, "metadata")
    guard field(meta, "namespace") == Json::string(s.ns) &&
      field(field(pod, "status"), "phase") is String(phase) else {
      return Err("Pod 命名空间或阶段缺失")
    }
    if phase == "Succeeded" || phase == "Failed" {
      continue
    }
    total = total + 1
    let deleting = field(meta, "deletionTimestamp") is String(_)
    if controller_uid(pod, "ReplicaSet") is Some(uid) && owned.contains(uid) {
      if deleting {
        retiring_pods[uid] = retiring_pods.get(uid).unwrap_or(0) + 1
      } else {
        active_pods[uid] = active_pods.get(uid).unwrap_or(0) + 1
      }
    } else if deleting {
      other_retiring = other_retiring + 1
      guard field(meta, "name") is String(name) else {
        return Err("缺少终止 Pod 名称")
      }
      additional_refs.push(
        rollout_ref(
          "Pod",
          name,
          "metadata.deletionTimestamp",
          field(meta, "deletionTimestamp"),
        ),
      )
    }
  }
  guard !retiring_pods.contains(new_uid) else {
    return Err("新版 Pod 正在删除")
  }
  let remaining = previous.filter(fn(entry) {
    let (uid, rs) = entry
    active_pods.contains(uid) ||
    retiring_pods.contains(uid) ||
    !has_zero_replicas(rs)
  })
  guard remaining.length() <= 1 else {
    return Err("存在多个尚未清空或状态未确认的旧版 RS")
  }
  // A fully retired revision can anchor the zero-old state after completion.
  let (old_uid, old_rs) = if remaining.is_empty() {
    previous[0]
  } else {
    remaining[0]
  }
  let old = active_pods.get(old_uid).unwrap_or(0)
  let live = active_pods.get(new_uid).unwrap_or(0)
  let retiring = retiring_pods.get(old_uid).unwrap_or(0)
  let desired = count(field(field(new_rs, "spec"), "replicas"))
  let available = status_count(new_rs, "availableReplicas")
  guard used == total &&
    old <= replicas &&
    old == count(field(field(old_rs, "spec"), "replicas")) &&
    old == status_count(old_rs, "availableReplicas") &&
    old == status_count(old_rs, "replicas") &&
    live == status_count(new_rs, "replicas") &&
    available >= 0 &&
    available <= live &&
    live <= desired &&
    desired <= replicas &&
    old + desired <= replicas + surge else {
    return Err("Pod、配额或 RS 副本状态超出模型范围")
  }
  let policy = {
    replicas,
    surge,
    unavailable: minimum(unavailable, replicas),
    hard,
    fixed_other: used - old - live - retiring - other_retiring,
  }
  let initial = { old, desired, live, available, retiring, other_retiring, }
  let assumption = "假定其他常驻负载不变，控制器能重试创建，新 Pod 能变为可用，缩容后的旧 Pod 能释放配额。"
  fn frontier(visited : Int32, state : RollState) -> String {
    let occupied = policy.fixed_other +
      state.old +
      state.live +
      state.retiring +
      state.other_retiring
    return "已检查 \{visited} 个状态。终点占用 \{occupied}/\{hard}，新版期望/实际 \{state.desired}/\{state.live}，可用 \{state.old+state.available}，最低可用 \{replicas-policy.unavailable}。"
  }
  let (rule_id, detail, path) = match rollout_search(policy, initial, false) {
    Path(path) =>
      (
        "rollout_reachable",
        if path.is_empty() {
          "快照中已达到替换目标。"
        } else {
          "存在完成替换的路径。"
        },
        path,
      )
    SearchLimit => return Err("搜索达到状态上限")
    Blocked(visited, last) =>
      if other_retiring > 0 {
        match rollout_search(policy, initial, true) {
          Path(path) =>
            (
              "rollout_release_required", "仅在外部终止 Pod 释放名额后存在完成路径。",
              path,
            )
          Blocked(released_count, released_last) =>
            (
              "rollout_blocked",
              "允许外部终止 Pod 释放名额后仍无法完成替换。" +
              frontier(released_count, released_last),
              [],
            )
          SearchLimit => return Err("搜索达到状态上限")
        }
      } else {
        (
          "rollout_blocked",
          "在当前可用副本下限与配额约束下无法完成替换。" +
          frontier(visited, last),
          [],
        )
      }
  }
  guard field(field(quota, "metadata"), "name") is String(qname) &&
    field(field(new_rs, "metadata"), "name") is String(new_name) &&
    field(field(old_rs, "metadata"), "name") is String(old_name) else {
    return Err("缺少证据对象名称")
  }
  let evidence = [
    "旧版可用 \{old}，新版期望/实际/可用 \{desired}/\{live}/\{available}，配额 \{used}/\{hard}，其他终止 Pod \{other_retiring}",
    "生效策略 maxSurge=\{policy.surge}，maxUnavailable=\{policy.unavailable}，最低可用 \{replicas-policy.unavailable}",
  ]
  if path.length() > 0 {
    evidence.push(path.join(" → "))
  }
  for entry in previous {
    let (uid, rs) = entry
    if uid != old_uid {
      guard field(field(rs, "metadata"), "name") is String(name) &&
        !name.is_empty() else {
        return Err("缺少历史 RS 名称")
      }
      evidence.push("历史 RS \{name} 已清空，未拥有非终态 Pod")
      additional_refs.push(
        rollout_ref(
          "ReplicaSet",
          name,
          "spec.replicas",
          field(field(rs, "spec"), "replicas"),
        ),
      )
      additional_refs.push(
        rollout_ref("ReplicaSet", name, "status", field(rs, "status")),
      )
    }
  }
  Ok({
    rule_id,
    title: "滚动发布路径分析",
    detail: detail + assumption,
    confidence: 1.0,
    evidence,
    evidence_refs: [
      rollout_ref(
        "Deployment",
        s.target_name,
        "spec.strategy.rollingUpdate",
        ru,
      ),
      rollout_ref(
        "Deployment",
        s.target_name,
        "spec.replicas",
        field(spec, "replicas"),
      ),
      rollout_ref(
        "ReplicaSet",
        old_name,
        "status.availableReplicas",
        field(field(old_rs, "status"), "availableReplicas"),
      ),
      rollout_ref(
        "ReplicaSet",
        new_name,
        "spec.replicas",
        field(field(new_rs, "spec"), "replicas"),
      ),
      rollout_ref("ResourceQuota", qname, "status", qs),
    ] +
    additional_refs,
  })
}
