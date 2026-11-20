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
fn controlled(raw : Json, kind : String, uid : String) -> Bool {
  guard field(field(raw, "metadata"), "ownerReferences") is Array(refs) else {
    return false
  }
  refs.any(fn(r) {
    field(r, "kind") == Json::string(kind) &&
    field(r, "uid") == Json::string(uid) &&
    field(r, "controller") == Json::boolean(true)
  })
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
  let surge = count(field(ru, "maxSurge"))
  let unavailable = count(field(ru, "maxUnavailable"))
  guard replicas > 0 &&
    surge >= 0 &&
    unavailable >= 0 &&
    surge + unavailable > 0 else {
    return Err("需要正副本数与整数策略参数")
  }
  guard template(dep) is Some(target) &&
    @rules.object_uid(dep) is Some(dep_uid) &&
    !dep_uid.is_empty() &&
    field(field(dep, "metadata"), "namespace") == Json::string(s.ns) &&
    field(field(dep, "metadata"), "name") == Json::string(s.target_name) else {
    return Err("缺少模板或 Deployment UID")
  }
  let current = sets.filter(fn(rs) { template(rs) == Some(target) })
  let previous = sets.filter(fn(rs) { template(rs) is Some(t) && t != target })
  guard current.length() == 1 && previous.length() == 1 else {
    return Err("无法唯一识别新旧模板")
  }
  let new_rs = current[0]
  let old_rs = previous[0]
  guard sets.all(fn(rs) {
      controlled(rs, "Deployment", dep_uid) &&
      field(field(rs, "metadata"), "namespace") == Json::string(s.ns) &&
      field(field(rs, "metadata"), "deletionTimestamp") == Json::null()
    }) &&
    @rules.object_uid(old_rs) is Some(old_uid) &&
    @rules.object_uid(new_rs) is Some(new_uid) &&
    old_uid != new_uid &&
    !old_uid.is_empty() &&
    !new_uid.is_empty() else {
    return Err("RS 归属不完整")
  }
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
  let mut old = 0
  let mut live = 0
  let mut retiring = 0
  let mut other_retiring = 0
  let mut total = 0
  let releases : Array[@rules.Evidence] = []
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
    if controlled(pod, "ReplicaSet", old_uid) {
      if deleting {
        retiring = retiring + 1
      } else {
        old = old + 1
      }
    } else if controlled(pod, "ReplicaSet", new_uid) {
      if deleting {
        return Err("新版 Pod 正在删除")
      }
      live = live + 1
    } else if deleting {
      other_retiring = other_retiring + 1
      guard field(meta, "name") is String(name) else {
        return Err("缺少终止 Pod 名称")
      }
      releases.push(
        rollout_ref(
          "Pod",
          name,
          "metadata.deletionTimestamp",
          field(meta, "deletionTimestamp"),
        ),
      )
    }
  }
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
  ]
  if path.length() > 0 {
    evidence.push(path.join(" → "))
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
    releases,
  })
}
