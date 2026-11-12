///|
/// The fact set a rule sees. Built once per diagnosis from the pod object,
/// related event lines and (optionally) recent logs. Pure data, no I/O:
/// rules stay deterministic and unit-testable without a cluster.
pub struct PodFacts {
  ns : String
  pod : String
  phase : String
  restarts : Int32
  waiting_reason : String?
  last_term_reason : String?
  last_term_exit : Int32?
  mem_limit : String?
  events : Array[String]
  logs_tail : String?
}

///|
/// Facts with no pod data at all - used when the pod itself could not be
/// read but event/log evidence is still worth running rules over.
pub fn PodFacts::empty(events~ : Array[String], logs? : String) -> PodFacts {
  {
    ns: "",
    pod: "",
    phase: "Unknown",
    restarts: 0,
    waiting_reason: None,
    last_term_reason: None,
    last_term_exit: None,
    mem_limit: None,
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
  events~ : Array[String],
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
      containers[0] is Object(container) &&
      container.get("resources") is Some(Object(res_fields)) &&
      res_fields.get("limits") is Some(Object(limits)) {
      mem_limit = json_sf(limits, "memory")
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
    events,
    logs_tail: logs,
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
