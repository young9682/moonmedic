///|
/// Per-source collection status for every List a snapshot carries. This is
/// how "the API said no" stays distinguishable from "the cluster has none":
/// a rule that needs Pod objects must not run on an Unavailable list.
#derive(Debug)
pub(all) enum ListStatus {
  Available
  Empty
  Unavailable(String)
  Truncated(Int32)
}

///|
pub impl Show for ListStatus with output(self, logger) {
  logger.write_string(self.label())
}

///|
/// Whether a rule may draw conclusions from this source. Unavailable and
/// Truncated lists are evidence-incomplete: counts from them are not exact.
pub fn ListStatus::is_usable(self : ListStatus) -> Bool {
  match self {
    Available | Empty => true
    Unavailable(_) | Truncated(_) => false
  }
}

///|
/// Short label for notes and reports.
pub fn ListStatus::label(self : ListStatus) -> String {
  match self {
    Available => "available"
    Empty => "empty"
    Unavailable(reason) => "unavailable(\{reason})"
    Truncated(seen) => "truncated(seen=\{seen})"
  }
}

///|
/// Decode one source status from the data_status JSON value. Object form
/// carries {state, reason?, seen?}; a bare string label is also accepted for
/// hand-written fixtures. Unknown labels degrade to Unavailable — never to
/// a usable state.
fn list_status_from_json(value : Json) -> ListStatus {
  match value {
    Object(fields) => {
      let state = match fields.get("state") {
        Some(String(state)) => state
        _ => ""
      }
      match state {
        "available" => Available
        "empty" => Empty
        "unavailable" => {
          let reason = match fields.get("reason") {
            Some(String(reason)) => reason
            _ => "unknown"
          }
          Unavailable(reason)
        }
        "truncated" => {
          let seen = match fields.get("seen") {
            Some(Number(value, ..)) => value.to_int()
            _ => 0
          }
          Truncated(seen)
        }
        other => Unavailable("unknown state: \{other}")
      }
    }
    String("available") => Available
    String("empty") => Empty
    String(other) => Unavailable("unknown state: \{other}")
    _ => Unavailable("malformed data_status entry")
  }
}

///|
/// Encode one source status into the data_status JSON object form.
fn list_status_to_json(status : ListStatus) -> Json {
  let fields : Map[String, Json] = Map([])
  match status {
    Available => fields["state"] = Json::string("available")
    Empty => fields["state"] = Json::string("empty")
    Unavailable(reason) => {
      fields["state"] = Json::string("unavailable")
      fields["reason"] = Json::string(reason)
    }
    Truncated(seen) => {
      fields["state"] = Json::string("truncated")
      fields["seen"] = Json::number(seen.to_double())
    }
  }
  Json::object(fields)
}

///|
/// Read one source status from the data_status map. Absent labels default by
/// array shape; unknown labels degrade to Unavailable (never to usable).
fn list_status_field(
  map : Map[String, Json],
  key : String,
  items : Array[Json],
) -> ListStatus {
  match map.get(key) {
    Some(value) => list_status_from_json(value)
    _ => if items.is_empty() { Empty } else { Available }
  }
}

///|
/// One diagnosis input, independent of transport. A live cluster, a
/// `kubectl` export and a recorded fixture all produce the same shape, so the
/// diagnostic core never imports kubemoon or an LLM SDK.
pub(all) struct ClusterSnapshot {
  ns : String
  target_kind : String
  target_name : String
  pod : Json?
  deployment : Json?
  replicasets : Array[Json]
  pods : Array[Json]
  events : Array[Json]
  quotas : Array[Json]
  limit_ranges : Array[Json]
  replicasets_status : ListStatus
  pods_status : ListStatus
  events_status : ListStatus
  quotas_status : ListStatus
  limit_ranges_status : ListStatus
  logs : String?
  notes : Array[String]
}

///|
/// Empty snapshot for one diagnosis target.
pub fn ClusterSnapshot::empty(
  ns~ : String,
  target_kind~ : String,
  target_name~ : String,
) -> ClusterSnapshot {
  {
    ns,
    target_kind,
    target_name,
    pod: None,
    deployment: None,
    replicasets: [],
    pods: [],
    events: [],
    quotas: [],
    limit_ranges: [],
    replicasets_status: Empty,
    pods_status: Empty,
    events_status: Empty,
    quotas_status: Empty,
    limit_ranges_status: Empty,
    logs: None,
    notes: [],
  }
}

///|
/// Append a collection/read failure note. Notes are rendered in the report's
/// "data completeness" section instead of being silently swallowed.
pub fn ClusterSnapshot::note(self : ClusterSnapshot, message : String) -> Unit {
  self.notes.push(message)
}

///|
/// Decode a snapshot from the fixture/eval JSON format.
pub fn ClusterSnapshot::from_json(
  raw : Json,
) -> Result[ClusterSnapshot, String] {
  guard raw is Object(fields) else {
    return Err("snapshot must be a JSON object")
  }
  let ns = string_field(fields, "ns").unwrap_or("")
  let target_kind = match string_field(fields, "target_kind") {
    Some(value) if !value.is_empty() => value
    _ => return Err("snapshot.target_kind is required")
  }
  let target_name = match string_field(fields, "target_name") {
    Some(value) if !value.is_empty() => value
    _ => return Err("snapshot.target_name is required")
  }
  let replicasets = array_field(fields, "replicasets")
  let pods = array_field(fields, "pods")
  let events = array_field(fields, "events")
  let quotas = array_field(fields, "quotas")
  let limit_ranges = array_field(fields, "limit_ranges")
  // data_status makes Unavailable/Truncated explicit in fixtures; a fixture
  // without it defaults by array shape (deliberate empty = Empty).
  let status_map : Map[String, Json] = match fields.get("data_status") {
    Some(Object(map)) => map
    _ => Map([])
  }
  Ok({
    ns,
    target_kind,
    target_name,
    pod: object_field(fields, "pod"),
    deployment: object_field(fields, "deployment"),
    replicasets,
    pods,
    events,
    quotas,
    limit_ranges,
    replicasets_status: list_status_field(
      status_map, "replicasets", replicasets,
    ),
    pods_status: list_status_field(status_map, "pods", pods),
    events_status: list_status_field(status_map, "events", events),
    quotas_status: list_status_field(status_map, "quotas", quotas),
    limit_ranges_status: list_status_field(
      status_map, "limit_ranges", limit_ranges,
    ),
    logs: string_field(fields, "logs"),
    notes: string_array_field(fields, "notes"),
  })
}

///|
/// Encode a snapshot back to JSON. Used by golden fixtures and by tools that
/// want to persist a diagnosis input for replay.
pub fn ClusterSnapshot::to_json(self : ClusterSnapshot) -> Json {
  let fields : Map[String, Json] = Map([])
  fields["ns"] = Json::string(self.ns)
  fields["target_kind"] = Json::string(self.target_kind)
  fields["target_name"] = Json::string(self.target_name)
  fields["pod"] = match self.pod {
    Some(value) => value
    None => Json::null()
  }
  fields["deployment"] = match self.deployment {
    Some(value) => value
    None => Json::null()
  }
  fields["replicasets"] = Json::array(self.replicasets)
  fields["pods"] = Json::array(self.pods)
  fields["events"] = Json::array(self.events)
  fields["quotas"] = Json::array(self.quotas)
  fields["limit_ranges"] = Json::array(self.limit_ranges)
  let data_status : Map[String, Json] = Map([])
  data_status["replicasets"] = list_status_to_json(self.replicasets_status)
  data_status["pods"] = list_status_to_json(self.pods_status)
  data_status["events"] = list_status_to_json(self.events_status)
  data_status["quotas"] = list_status_to_json(self.quotas_status)
  data_status["limit_ranges"] = list_status_to_json(self.limit_ranges_status)
  fields["data_status"] = Json::object(data_status)
  fields["logs"] = match self.logs {
    Some(value) => Json::string(value)
    None => Json::null()
  }
  let notes : Array[Json] = []
  for note in self.notes {
    notes.push(Json::string(note))
  }
  fields["notes"] = Json::array(notes)
  Json::object(fields)
}

///|
/// Read a string field.
fn string_field(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}

///|
/// Read an object field; null/missing/non-object all degrade to None.
fn object_field(fields : Map[String, Json], key : String) -> Json? {
  match fields.get(key) {
    Some(Object(_)) => fields.get(key)
    _ => None
  }
}

///|
/// Read an array field; missing/non-array degrade to an empty array.
fn array_field(fields : Map[String, Json], key : String) -> Array[Json] {
  match fields.get(key) {
    Some(Array(items)) => items
    _ => []
  }
}

///|
/// Read an array of strings, skipping non-string entries.
fn string_array_field(
  fields : Map[String, Json],
  key : String,
) -> Array[String] {
  let out : Array[String] = []
  if fields.get(key) is Some(Array(items)) {
    for item in items {
      if item is String(value) {
        out.push(value)
      }
    }
  }
  out
}
