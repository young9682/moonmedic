///|
/// Read-only access to a Kubernetes cluster via kubemoon's dynamic client.
/// W1 PoC: the only capability is listing pod names in one namespace.
/// Every request is a GET; moonmedic never issues writes by design.

///|
/// Where to find the cluster and how to authenticate.
/// Typical setups:
/// - kubectl proxy: server = "http://127.0.0.1:8001", no token, no CA file
/// - direct: server = "https://apiserver:6443", bearer token, PEM CA file
pub struct K8sTarget {
  server : String
  token : String?
  ca_file : String?
  ns : String
}

///|
pub fn K8sTarget::from_parts(
  server~ : String,
  token~ : String?,
  ca_file~ : String?,
  ns~ : String,
) -> K8sTarget {
  { server, token, ca_file, ns, }
}

///|
/// Build the kubemoon client config from explicitly provided credentials.
/// Missing credentials are fine: an anonymous/proxy setup is a valid choice.
fn build_config(target : K8sTarget) -> @config.ClientConfig {
  let server = target.server
  match (target.token, target.ca_file) {
    (Some(token), Some(ca)) =>
      @config.ClientConfig::ClientConfig(
        server~,
        bearer_token=token,
        ca_file=ca,
      )
    (Some(token), None) =>
      @config.ClientConfig::ClientConfig(server~, bearer_token=token)
    (None, Some(ca)) => @config.ClientConfig::ClientConfig(server~, ca_file=ca)
    (None, None) => @config.ClientConfig::ClientConfig(server~)
  }
}

///|
/// List pod names in the target namespace. Issues a single GET on
/// /api/v1/namespaces/{ns}/pods and decodes the collection snapshot.
pub async fn list_pod_names(
  target : K8sTarget,
) -> Result[Array[String], String] {
  let config = build_config(target)
  let client = @client.DynamicClient::DynamicClient(config)
  let pods = @resource.GroupVersionResource(
    group="",
    version="v1",
    resource="pods",
  )
  let request = client.list_request(pods, @resource.Namespace(target.ns))
  let body_result : Result[String, String] = try {
    let transport = @httptransport.HttpTransport::connect(config)
    defer transport.close()
    let response = transport.send(request)
    let body = response.body()
    if response.is_success() {
      Ok(body)
    } else if body.length() <= 400 {
      Err("HTTP \{response.status()}: \{body}")
    } else {
      Err("HTTP \{response.status()} (body \{body.length()} bytes)")
    }
  } catch {
    _ =>
      Err(
        "集群请求失败(网络错误或地址不可达): \{config.server()}",
      )
  }
  let body = match body_result {
    Ok(body) => body
    Err(message) => return Err(message)
  }
  let snapshot = match @object.decode_list_snapshot(body) {
    Ok(snapshot) => snapshot
    Err(message) => return Err(message)
  }
  let names = []
  for item in snapshot.items() {
    names.push(item.name())
  }
  Ok(names)
}
