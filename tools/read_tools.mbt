///|
/// Read-only cluster access tools for the diagnosis pipeline (W2).
/// Every function issues GET requests only; there is no write path by design.

///|
/// Execute one GET against an absolute path on the target API server and
/// return the raw response body. Mirrors kubemoon's own request preparation:
/// Accept header plus the bearer authorization header when configured.
async fn get_raw(
  config : @config.ClientConfig,
  path : String,
) -> Result[String, String] {
  let transport = @httptransport.HttpTransport::connect(config)
  defer transport.close()
  let request = @transport.Request::Request(Get, "\{config.server()}\{path}").with_header(
    "Accept", "application/json",
  )
  let request = match config.authorization_header() {
    Some(header) => request.with_header("Authorization", header)
    None => request
  }
  let response = transport.send(request)
  if !response.is_success() {
    let body = response.body()
    if body.length() <= 400 {
      return Err("HTTP \{response.status()}: \{body}")
    }
    return Err("HTTP \{response.status()} (body \{body.length()} bytes)")
  }
  Ok(response.body())
}

///|
/// Fetch one object as a kubemoon DynamicObject (name/ns/uid + raw JSON).
pub async fn get_object(
  target : K8sTarget,
  group~ : String,
  version~ : String,
  resource~ : String,
  name~ : String,
) -> Result[@object.DynamicObject, String] {
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
  @object.DynamicObject::try_from_json(parsed)
}

///|
/// Fetch one pod with full status (container state machine, restarts).
pub async fn get_pod(
  target : K8sTarget,
  name~ : String,
) -> Result[@object.DynamicObject, String] {
  get_object(target, group="", version="v1", resource="pods", name~)
}

///|
/// Fetch event summary lines ("reason: message") related to one pod,
/// capped at 50. Events are listed per namespace and filtered client-side
/// (kubemoon 0.1.1 has no fieldSelector support on list requests yet).
pub async fn get_events(
  target : K8sTarget,
  pod_name~ : String,
) -> Result[Array[String], String] {
  let config = build_config(target)
  let events_gvr = @resource.GroupVersionResource(
    group="",
    version="v1",
    resource="events",
  )
  let request = client_list_request(
    config,
    events_gvr,
    @resource.Namespace(target.ns),
  )
  let transport = @httptransport.HttpTransport::connect(config)
  defer transport.close()
  let response = transport.send(request)
  if !response.is_success() {
    let body = response.body()
    if body.length() <= 400 {
      return Err("HTTP \{response.status()}: \{body}")
    }
    return Err("HTTP \{response.status()} (body \{body.length()} bytes)")
  }
  let snapshot = match @object.decode_list_snapshot(response.body()) {
    Ok(snapshot) => snapshot
    Err(message) => return Err(message)
  }
  let lines = []
  for item in snapshot.items() {
    let raw = item.raw()
    let involved = match raw {
      Object(fields) => json_child(fields, "involvedObject")
      _ => None
    }
    let obj_name = match involved {
      Some(Object(fields)) => json_str(fields, "name")
      _ => None
    }
    if obj_name != Some(pod_name) {
      continue
    }
    let reason = match raw {
      Object(fields) => json_str(fields, "reason").unwrap_or("Unknown")
      _ => "Unknown"
    }
    let message = match raw {
      Object(fields) => json_str(fields, "message").unwrap_or("")
      _ => ""
    }
    lines.push("\{reason}: \{message}")
    if lines.length() >= 50 {
      break
    }
  }
  Ok(lines)
}

///|
/// Fetch recent container logs for one pod (GET pods/{name}/log).
/// kubemoon 0.1.1 has no subresource builder, so the log path is composed
/// manually with the same authentication contract as client requests.
pub async fn get_logs(
  target : K8sTarget,
  pod_name~ : String,
  tail~ : Int32 = 100,
  container? : String,
) -> Result[String, String] {
  let config = build_config(target)
  let pods = @resource.GroupVersionResource(
    group="",
    version="v1",
    resource="pods",
  )
  let base = @resource.object_path(
    pods,
    @resource.Namespace(target.ns),
    pod_name,
  )
  let mut path = "\{base}/log?tailLines=\{tail}"
  match container {
    Some(name) => path = "\{path}&container=\{name}"
    None => ()
  }
  get_raw(config, path)
}

///|
/// Build a list request for one collection. Duplicates the tiny part of
/// kubemoon's client preparation that generic paths need; kept private.
fn client_list_request(
  config : @config.ClientConfig,
  resource : @resource.GroupVersionResource,
  scope : @resource.Scope,
) -> @transport.Request {
  let client = @client.DynamicClient::DynamicClient(config)
  client.list_request(resource, scope)
}

///|
/// Name of the pod's first container (spec.containers[0].name), used to
/// target logs on multi-container pods.
pub fn first_container_name(pod : @object.DynamicObject) -> String? {
  match pod.raw() {
    Object(fields) =>
      match fields.get("spec") {
        Some(Object(spec)) =>
          match spec.get("containers") {
            Some(Array(containers)) =>
              if containers.length() > 0 && containers[0] is Object(first) {
                match first.get("name") {
                  Some(String(name)) => Some(name)
                  _ => None
                }
              } else {
                None
              }
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

///|
/// Read a nested object field from a JSON field map.
fn json_child(fields : Map[String, Json], key : String) -> Json? {
  fields.get(key)
}

///|
/// Read a string field from a JSON field map.
fn json_str(fields : Map[String, Json], key : String) -> String? {
  match fields.get(key) {
    Some(String(value)) => Some(value)
    _ => None
  }
}
