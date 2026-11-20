///|
/// The fact set a rule sees for a Pod that exists. Pure data, no I/O: rules
/// stay deterministic and unit-testable without a cluster.
pub struct PodFacts {
  ns : String
  pod : String
  phase : String
  restarts : Int32
  waiting_reason : String?
  last_term_reason : String?
  last_term_exit : Int32?
  mem_limit : String?
  image : String?
  events : Array[EventFact]
  logs_tail : String?
}

///|
/// Facts with no pod data at all - used when the pod itself could not be
/// read but event/log evidence is still worth running rules over.
pub fn PodFacts::empty(events~ : Array[EventFact], logs? : String) -> PodFacts {
  {
    ns: "",
    pod: "",
    phase: "Unknown",
    restarts: 0,
    waiting_reason: None,
    last_term_reason: None,
    last_term_exit: None,
    mem_limit: None,
    image: None,
    events,
    logs_tail: logs,
  }
}

///|
/// Extract PodFacts from a raw pod JSON (status.phase, container state
/// machine, resource limits). Missing fields degrade to None/defaults so
/// that partially-populated fixtures still produce useful facts.
pub fn PodFacts::from_pod(
  pod_raw : Json,
  events~ : Array[EventFact],
  logs? : String,
) -> PodFacts {
  let mut ns = ""
  let mut pod = ""
  let mut phase = "Unknown"
  let mut restarts = 0
  let mut waiting : String? = None
  let mut term_reason : String? = None
  let mut term_exit : Int32? = None
  let mut mem_limit : String? = None
  let mut image : String? = None
  if pod_raw is Object(fields) {
    if fields.get("metadata") is Some(Object(meta)) {
      ns = json_sf(meta, "namespace").unwrap_or("")
      pod = json_sf(meta, "name").unwrap_or("")
    }
    if fields.get("status") is Some(Object(status)) {
      phase = json_sf(status, "phase").unwrap_or("Unknown")
      if status.get("containerStatuses") is Some(Array(statuses)) {
        for status in statuses {
          if status is Object(cs) {
            if cs.get("restartCount") is Some(Number(count, ..)) {
              restarts = restarts + count.to_int()
            }
            if waiting is None &&
              cs.get("state") is Some(Object(state_fields)) &&
              state_fields.get("waiting") is Some(Object(waiting_fields)) {
              waiting = json_sf(waiting_fields, "reason")
            }
            if term_reason is None &&
              cs.get("lastState") is Some(Object(last_fields)) &&
              last_fields.get("terminated") is Some(Object(term_fields)) {
              term_reason = json_sf(term_fields, "reason")
              if term_fields.get("exitCode") is Some(Number(exit, ..)) {
                term_exit = Some(exit.to_int())
              }
            }
          }
        }
      }
    }
    if fields.get("spec") is Some(Object(spec)) &&
      spec.get("containers") is Some(Array(containers)) &&
      containers.length() > 0 &&
      containers[0] is Object(container) {
      image = json_sf(container, "image")
      if container.get("resources") is Some(Object(res_fields)) &&
        res_fields.get("limits") is Some(Object(limits)) {
        mem_limit = json_sf(limits, "memory")
      }
    }
  }
  {
    ns,
    pod,
    phase,
    restarts,
    waiting_reason: waiting,
    last_term_reason: term_reason,
    last_term_exit: term_exit,
    mem_limit,
    image,
    events,
    logs_tail: logs,
  }
}

///|
/// Reduce one Kubernetes Event object to an EventFact. Unknown fields are
/// tolerated; a missing reason degrades to "Unknown" rather than dropping the
/// event, so evidence is never silently lost.
pub fn EventFact::from_json(raw : Json) -> EventFact? {
  guard raw is Object(fields) else { return None }
  let reason = json_sf(fields, "reason").unwrap_or("Unknown")
  let message = json_sf(fields, "message").unwrap_or("")
  let event_type = json_sf(fields, "type").unwrap_or("Normal")
  let mut kind = ""
  let mut name = ""
  if fields.get("involvedObject") is Some(Object(involved)) {
    kind = json_sf(involved, "kind").unwrap_or("")
    name = json_sf(involved, "name").unwrap_or("")
  }
  let count = match fields.get("count") {
    Some(Number(value, ..)) => value.to_int()
    _ => 1
  }
  let last_seen = match json_sf(fields, "lastTimestamp") {
    Some(value) => Some(value)
    None =>
      match json_sf(fields, "eventTime") {
        Some(value) => Some(value)
        None => json_sf(fields, "firstTimestamp")
      }
  }
  Some({ reason, message, event_type, kind, name, count, last_seen, })
}

///|
/// Match a core/v1 Event to its involved object. Older snapshots may omit UID
/// or namespace, but an explicit mismatch rules out that object.
pub fn event_matches_object(
  raw : Json,
  ns~ : String,
  kind~ : String,
  name~ : String,
  uid? : String,
) -> Bool {
  guard raw is Object(fields) else { return false }
  guard fields.get("involvedObject") is Some(Object(involved)) else {
    return false
  }
  guard json_sf(involved, "kind") == Some(kind) &&
    json_sf(involved, "name") == Some(name) else {
    return false
  }
  let event_ns = json_sf(involved, "namespace").unwrap_or("")
  guard event_ns.is_empty() || event_ns == ns else { return false }
  match (uid, json_sf(involved, "uid")) {
    (Some(current), Some(recorded)) =>
      current.is_empty() || recorded.is_empty() || current == recorded
    _ => true
  }
}

///|
/// Decode a Kubernetes EventList body into facts. Items that are not event
/// objects are skipped so one malformed entry cannot poison the batch.
pub fn events_from_json_array(raw : Json) -> Array[EventFact] {
  let out : Array[EventFact] = []
  if raw is Object(fields) && fields.get("items") is Some(Array(items)) {
    for item in items {
      match EventFact::from_json(item) {
        Some(event) => out.push(event)
        None => ()
      }
    }
  }
  out
}

///|
/// Decode an array of event objects (already unwrapped from `items`).
pub fn events_from_items(items : Array[Json]) -> Array[EventFact] {
  let out : Array[EventFact] = []
  for item in items {
    match EventFact::from_json(item) {
      Some(event) => out.push(event)
      None => ()
    }
  }
  out
}

///|
/// Extract status.conditions[] from any object status.
fn conditions_from_json(raw_status : Json) -> Array[ConditionFact] {
  let out : Array[ConditionFact] = []
  if raw_status is Object(status) &&
    status.get("conditions") is Some(Array(items)) {
    for item in items {
      if item is Object(fields) {
        out.push({
          type_: json_sf(fields, "type").unwrap_or(""),
          status: json_sf(fields, "status").unwrap_or(""),
          reason: json_sf(fields, "reason").unwrap_or(""),
          message: json_sf(fields, "message").unwrap_or(""),
        })
      }
    }
  }
  out
}

///|
/// metadata.uid of an object, used to follow ownerReferences.
pub fn object_uid(raw : Json) -> String? {
  if raw is Object(fields) && fields.get("metadata") is Some(Object(meta)) {
    json_sf(meta, "uid")
  } else {
    None
  }
}

///|
/// True when any ownerReference.uid equals `uid`. This is how the workload
/// path proves that a ReplicaSet (and therefore its Pods) belongs to the
/// Deployment being diagnosed.
pub fn owned_by_uid(raw : Json, uid : String) -> Bool {
  guard raw is Object(fields) else { return false }
  guard fields.get("metadata") is Some(Object(meta)) else { return false }
  guard meta.get("ownerReferences") is Some(Array(refs)) else { return false }
  for reference in refs {
    if reference is Object(fields) && json_sf(fields, "uid") == Some(uid) {
      return true
    }
  }
  false
}

///|
/// Decode one ResourceQuota. Hard/used are kept as ordered key/value pairs so
/// the report and tests see a stable representation.
pub fn QuotaFact::from_json(raw : Json) -> QuotaFact? {
  guard raw is Object(fields) else { return None }
  let name = match fields.get("metadata") {
    Some(Object(meta)) => json_sf(meta, "name").unwrap_or("")
    _ => ""
  }
  let mut hard : Array[(String, String)] = []
  let mut used : Array[(String, String)] = []
  if fields.get("status") is Some(Object(status)) {
    if status.get("hard") is Some(raw_hard) {
      hard = quantity_pairs(raw_hard)
    }
    if status.get("used") is Some(raw_used) {
      used = quantity_pairs(raw_used)
    }
  }
  Some({ name, hard, used, })
}

///|
/// Flatten a JSON object of quantities into key/value pairs.
fn quantity_pairs(raw : Json) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  if raw is Object(fields) {
    for key, value in fields {
      if value is String(text) {
        out.push((key, text))
      }
    }
  }
  out
}

///|
/// Current usage for one resource key in a quota, if reported.
pub fn QuotaFact::used_quantity(self : QuotaFact, resource : String) -> String? {
  for pair in self.used {
    let (key, value) = pair
    if key == resource {
      return Some(value)
    }
  }
  None
}

///|
/// Hard limit for one resource key in a quota, if reported.
pub fn QuotaFact::hard_quantity(self : QuotaFact, resource : String) -> String? {
  for pair in self.hard {
    let (key, value) = pair
    if key == resource {
      return Some(value)
    }
  }
  None
}

///|
/// Build workload facts by walking Deployment -> ReplicaSet -> Pod count.
/// `pod_count` is the number of Pods whose ownerReference points at any of
/// the owned ReplicaSets; 0 with desired > 0 is the "Pod was never created"
/// signal that the Pod-only pipeline could not express.
pub fn WorkloadFacts::from_deployment(
  deployment_raw : Json,
  replicasets : Array[Json],
  events~ : Array[EventFact],
  quotas~ : Array[QuotaFact],
  pod_count~ : Int32,
  pods_status~ : ListStatus,
  events_status~ : ListStatus,
) -> WorkloadFacts {
  let mut ns = ""
  let mut name = ""
  let mut desired = 0
  let mut ready = 0
  let mut available = 0
  let mut conditions : Array[ConditionFact] = []
  if deployment_raw is Object(fields) {
    if fields.get("metadata") is Some(Object(meta)) {
      ns = json_sf(meta, "namespace").unwrap_or("")
      name = json_sf(meta, "name").unwrap_or("")
    }
    if fields.get("spec") is Some(Object(spec)) {
      desired = match spec.get("replicas") {
        Some(Number(value, ..)) => value.to_int()
        _ => 1
      }
    }
    if fields.get("status") is Some(Object(status)) {
      ready = int_field(status, "readyReplicas")
      available = int_field(status, "availableReplicas")
      conditions = conditions_from_json(Json::object(status))
    }
  }
  let uid = object_uid(deployment_raw)
  let owned : Array[ReplicaSetFact] = []
  for raw in replicasets {
    let belongs = match uid {
      Some(value) => owned_by_uid(raw, value)
      None => false
    }
    if !belongs {
      continue
    }
    if raw is Object(fields) {
      let rs_name = match fields.get("metadata") {
        Some(Object(meta)) => json_sf(meta, "name").unwrap_or("")
        _ => ""
      }
      let mut rs_desired = 0
      if fields.get("spec") is Some(Object(spec)) {
        rs_desired = int_field(spec, "replicas")
      }
      let mut rs_ready = 0
      let mut rs_conditions : Array[ConditionFact] = []
      if fields.get("status") is Some(Object(status)) {
        rs_ready = int_field(status, "readyReplicas")
        rs_conditions = conditions_from_json(Json::object(status))
      }
      owned.push({
        name: rs_name,
        desired: rs_desired,
        ready: rs_ready,
        conditions: rs_conditions,
      })
    }
  }
  {
    ns,
    kind: "Deployment",
    name,
    desired,
    ready,
    available,
    conditions,
    replicasets: owned,
    events,
    quotas,
    pod_count,
    pod_missing: pod_count == 0 && desired > 0,
    pods_status,
    events_status,
  }
}

///|
/// Read an integer field, defaulting to 0.
fn int_field(fields : Map[String, Json], key : String) -> Int32 {
  match fields.get(key) {
    Some(Number(value, ..)) => value.to_int()
    _ => 0
  }
}

///|
/// Read a string field from a JSON object's field map.
fn json_sf(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}
