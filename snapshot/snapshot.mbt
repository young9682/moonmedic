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
  Ok({
    ns,
    target_kind,
    target_name,
    pod: object_field(fields, "pod"),
    deployment: object_field(fields, "deployment"),
    replicasets: array_field(fields, "replicasets"),
    pods: array_field(fields, "pods"),
    events: array_field(fields, "events"),
    quotas: array_field(fields, "quotas"),
    limit_ranges: array_field(fields, "limit_ranges"),
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
