///|
/// Live-cluster adapters that turn kubemoon GET responses into a
/// ClusterSnapshot. This is the only package that talks to a cluster; the
/// diagnostic core never imports it.

///|
/// Hard cap for LIST results. Keeps a pathological namespace from exhausting
/// memory; snapshot builders add a note when the cap is hit.
const LIST_LIMIT : Int32 = 1000

///|
/// GET one object and return its raw JSON body.
async fn get_object_json(
  target : K8sTarget,
  group~ : String,
  version~ : String,
  resource~ : String,
  name~ : String,
) -> Result[Json, String] {
  let config = build_config(target)
  let gvr = @resource.GroupVersionResource(group~, version~, resource~)
  let path = @resource.object_path(gvr, @resource.Namespace(target.ns), name)
  let body = match get_raw(config, path) {
    Ok(body) => body
    Err(message) => return Err(message)
  }
  let parsed = @json.parse(body) catch {
    _ => return Err("invalid JSON from \{path}")
  }
  Ok(parsed)
}

///|
/// LIST one collection and unwrap its `items` array.
async fn list_objects_json(
  target : K8sTarget,
  group~ : String,
  version~ : String,
  resource~ : String,
) -> Result[Array[Json], String] {
  let config = build_config(target)
  let gvr = @resource.GroupVersionResource(group~, version~, resource~)
  let path = @resource.collection_path(gvr, @resource.Namespace(target.ns))
  let body = match get_raw(config, path) {
    Ok(body) => body
    Err(message) => return Err(message)
  }
  let parsed = @json.parse(body) catch {
    _ => return Err("invalid JSON from \{path}")
  }
  guard parsed is Object(fields) else {
    return Err("list response from \{path} is not an object")
  }
  match fields.get("items") {
    Some(Array(items)) =>
      if items.length() <= LIST_LIMIT {
        Ok(items)
      } else {
        let capped : Array[Json] = []
        for i in 0..<LIST_LIMIT {
          capped.push(items[i])
        }
        Ok(capped)
      }
    _ => Err("list response from \{path} has no items array")
  }
}

///|
pub async fn get_pod_json(
  target : K8sTarget,
  name~ : String,
) -> Result[Json, String] {
  get_object_json(target, group="", version="v1", resource="pods", name~)
}

///|
pub async fn get_deployment_json(
  target : K8sTarget,
  name~ : String,
) -> Result[Json, String] {
  get_object_json(
    target,
    group="apps",
    version="v1",
    resource="deployments",
    name~,
  )
}

///|
pub async fn list_pods_json(target : K8sTarget) -> Result[Array[Json], String] {
  list_objects_json(target, group="", version="v1", resource="pods")
}

///|
pub async fn list_replicasets_json(
  target : K8sTarget,
) -> Result[Array[Json], String] {
  list_objects_json(target, group="apps", version="v1", resource="replicasets")
}

///|
pub async fn list_events_json(
  target : K8sTarget,
) -> Result[Array[Json], String] {
  list_objects_json(target, group="", version="v1", resource="events")
}

///|
pub async fn list_quotas_json(
  target : K8sTarget,
) -> Result[Array[Json], String] {
  list_objects_json(target, group="", version="v1", resource="resourcequotas")
}

///|
pub async fn list_limit_ranges_json(
  target : K8sTarget,
) -> Result[Array[Json], String] {
  list_objects_json(target, group="", version="v1", resource="limitranges")
}

///|
/// Build a Pod snapshot. A missing Pod is not an error: the snapshot carries
/// `pod=None` so the caller can fall back to workload diagnosis.
pub async fn pod_snapshot(
  target : K8sTarget,
  pod_name~ : String,
  logs_tail~ : Int32 = 100,
) -> @snapshot.ClusterSnapshot {
  let notes : Array[String] = []
  let pod = match get_pod_json(target, name=pod_name) {
    Ok(raw) => Some(raw)
    Err(message) => {
      notes.push("Pod 读取失败:\{message}")
      None
    }
  }
  let events = match list_events_json(target) {
    Ok(items) => {
      if items.length() >= LIST_LIMIT {
        notes.push("事件列表已截断至 \{LIST_LIMIT} 条")
      }
      items
    }
    Err(message) => {
      notes.push("事件读取失败:\{message}")
      []
    }
  }
  let logs = match pod {
    Some(raw) =>
      match first_container_name_from_json(raw) {
        Some(container) =>
          match get_logs(target, pod_name~, tail=logs_tail, container~) {
            Ok(text) => Some(text)
            Err(message) => {
              notes.push("日志读取失败:\{message}")
              None
            }
          }
        None => {
          notes.push("Pod 没有容器定义,无法读取日志")
          None
        }
      }
    None => None
  }
  let base = @snapshot.ClusterSnapshot::empty(
    ns=target.ns,
    target_kind="Pod",
    target_name=pod_name,
  )
  { ..base, pod, events, logs, notes, }
}

///|
/// Build a Deployment snapshot. The Deployment itself is required; all other
/// sources degrade to a note plus an empty collection.
pub async fn workload_snapshot(
  target : K8sTarget,
  name~ : String,
) -> Result[@snapshot.ClusterSnapshot, String] {
  let deployment = match get_deployment_json(target, name~) {
    Ok(raw) => raw
    Err(message) => return Err(message)
  }
  let notes : Array[String] = []
  let replicasets = match list_replicasets_json(target) {
    Ok(items) => {
      if items.length() >= LIST_LIMIT {
        notes.push("ReplicaSet 列表已截断至 \{LIST_LIMIT} 条")
      }
      items
    }
    Err(message) => {
      notes.push("ReplicaSet 读取失败:\{message}")
      []
    }
  }
  let pods = match list_pods_json(target) {
    Ok(items) => {
      if items.length() >= LIST_LIMIT {
        notes.push("Pod 列表已截断至 \{LIST_LIMIT} 条")
      }
      items
    }
    Err(message) => {
      notes.push("Pod 列表读取失败:\{message}")
      []
    }
  }
  let events = match list_events_json(target) {
    Ok(items) => {
      if items.length() >= LIST_LIMIT {
        notes.push("事件列表已截断至 \{LIST_LIMIT} 条")
      }
      items
    }
    Err(message) => {
      notes.push("事件读取失败:\{message}")
      []
    }
  }
  let quotas = match list_quotas_json(target) {
    Ok(items) => {
      if items.length() >= LIST_LIMIT {
        notes.push("ResourceQuota 列表已截断至 \{LIST_LIMIT} 条")
      }
      items
    }
    Err(message) => {
      notes.push("ResourceQuota 读取失败:\{message}")
      []
    }
  }
  let limit_ranges = match list_limit_ranges_json(target) {
    Ok(items) => {
      if items.length() >= LIST_LIMIT {
        notes.push("LimitRange 列表已截断至 \{LIST_LIMIT} 条")
      }
      items
    }
    Err(message) => {
      notes.push("LimitRange 读取失败:\{message}")
      []
    }
  }
  let base = @snapshot.ClusterSnapshot::empty(
    ns=target.ns,
    target_kind="Deployment",
    target_name=name,
  )
  Ok({
    ..base,
    deployment: Some(deployment),
    replicasets,
    pods,
    events,
    quotas,
    limit_ranges,
    notes,
  })
}

///|
/// spec.containers[0].name from raw Pod JSON.
fn first_container_name_from_json(pod_raw : Json) -> String? {
  guard pod_raw is Object(fields) else { return None }
  guard fields.get("spec") is Some(Object(spec)) else { return None }
  guard spec.get("containers") is Some(Array(containers)) else { return None }
  guard containers.length() > 0 && containers[0] is Object(container) else {
    return None
  }
  match container.get("name") {
    Some(String(name)) => Some(name)
    _ => None
  }
}
