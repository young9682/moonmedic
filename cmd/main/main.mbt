///|
/// moonmedic W1 PoC: connect to a cluster (read-only) and list pod names.
///
/// Configuration via environment variables:
/// - MOONMEDIC_SERVER     default "http://127.0.0.1:8001" (kubectl proxy)
/// - MOONMEDIC_TOKEN      optional bearer token
/// - MOONMEDIC_CA_FILE    optional PEM file with the API server CA
/// - MOONMEDIC_NAMESPACE  default "kube-system"
///
/// Run with `moon run cmd/main` from the project root.
async fn main raise {
  let server = @env.get_env_var("MOONMEDIC_SERVER").unwrap_or("http://127.0.0.1:8001")
  let token = @env.get_env_var("MOONMEDIC_TOKEN")
  let ca_file = @env.get_env_var("MOONMEDIC_CA_FILE")
  let ns = @env.get_env_var("MOONMEDIC_NAMESPACE").unwrap_or("kube-system")
  let target = @tools.K8sTarget::from_parts(
    server~,
    token~,
    ca_file~,
    ns~,
  )
  println("moonmedic W1 PoC — listing pods in namespace \"\{ns}\"")
  println("server: \{server}")
  match @tools.list_pod_names(target) {
    Ok(names) => {
      println("found \{names.length()} pods:")
      for name in names {
        println("  - \{name}")
      }
    }
    Err(message) => println("diagnosis aborted: \{message}")
  }
}
