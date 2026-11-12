///|
/// moonmedic CLI.
///
/// Usage:
/// - `moon run cmd/main`                       list pod names in MOONMEDIC_NAMESPACE (W1 PoC)
/// - `moon run cmd/main -- <ns> <pod>`         diagnose one pod and print a Markdown report (W2)
///
/// Configuration via environment variables:
/// - MOONMEDIC_SERVER     default "http://127.0.0.1:8001" (kubectl proxy)
/// - MOONMEDIC_TOKEN      optional bearer token
/// - MOONMEDIC_CA_FILE    optional PEM file with the API server CA
async fn main {
  let server = @env.get_env_var("MOONMEDIC_SERVER").unwrap_or(
    "http://127.0.0.1:8001",
  )
  let token = @env.get_env_var("MOONMEDIC_TOKEN")
  let ca_file = @env.get_env_var("MOONMEDIC_CA_FILE")
  let args = @env.args()
  // args[0] is the program name; two operands select diagnose mode.
  if args.length() >= 3 {
    let ns = args[1]
    let pod = args[2]
    let target = @tools.K8sTarget::from_parts(server~, token~, ca_file~, ns~)
    let diagnosis = @medic.diagnose_pod(target, pod_name=pod)
    println(@report.render_markdown(diagnosis))
    return
  }
  if args.length() == 2 {
    // Diagnose with the default namespace when only a pod name is given.
    let ns = @env.get_env_var("MOONMEDIC_NAMESPACE").unwrap_or("default")
    let target = @tools.K8sTarget::from_parts(server~, token~, ca_file~, ns~)
    let diagnosis = @medic.diagnose_pod(target, pod_name=args[1])
    println(@report.render_markdown(diagnosis))
    return
  }
  // No operands: W1 list-pods mode.
  let ns = @env.get_env_var("MOONMEDIC_NAMESPACE").unwrap_or("kube-system")
  let target = @tools.K8sTarget::from_parts(server~, token~, ca_file~, ns~)
  println(
    "moonmedic — listing pods in namespace \"\{ns}\" (usage: moonmedic <ns> <pod> to diagnose)",
  )
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
