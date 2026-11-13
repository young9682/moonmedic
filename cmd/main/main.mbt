///|
/// moonmedic CLI.
///
/// Usage:
/// - `moon run cmd/main`                       list pod names in MOONMEDIC_NAMESPACE (W1 PoC)
/// - `moon run cmd/main -- <ns> <pod>`         diagnose one pod and print a Markdown report (W2+)
///
/// Cluster configuration via environment variables:
/// - MOONMEDIC_SERVER     default "http://127.0.0.1:8001" (kubectl proxy)
/// - MOONMEDIC_TOKEN      optional bearer token
/// - MOONMEDIC_CA_FILE    optional PEM file with the API server CA
///
/// LLM configuration (optional, any OpenAI-compatible endpoint; without it
/// the report falls back to the deterministic rule-engine conclusion):
/// - MOONMEDIC_LLM_BASE_URL  e.g. "https://api.deepseek.com/v1"
/// - MOONMEDIC_LLM_MODEL     e.g. "deepseek-chat"
/// - MOONMEDIC_LLM_KEY       API key (empty = local/no-auth endpoints)
async fn main {
  let server = @env.get_env_var("MOONMEDIC_SERVER").unwrap_or(
    "http://127.0.0.1:8001",
  )
  let token = @env.get_env_var("MOONMEDIC_TOKEN")
  let ca_file = @env.get_env_var("MOONMEDIC_CA_FILE")
  let llm_config = build_llm_config()
  let args = @env.args()
  // args[0] is the program name; two operands select diagnose mode.
  if args.length() >= 3 {
    let ns = args[1]
    let pod = args[2]
    let target = @tools.K8sTarget::from_parts(server~, token~, ca_file~, ns~)
    let diagnosis = @medic.diagnose_pod(target, pod_name=pod, llm_config?)
    println(@report.render_markdown(diagnosis))
    return
  }
  if args.length() == 2 {
    // Diagnose with the default namespace when only a pod name is given.
    let ns = @env.get_env_var("MOONMEDIC_NAMESPACE").unwrap_or("default")
    let target = @tools.K8sTarget::from_parts(server~, token~, ca_file~, ns~)
    let diagnosis = @medic.diagnose_pod(target, pod_name=args[1], llm_config?)
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

///|
/// Build the optional LLM config from the environment. Absent/invalid
/// configuration simply disables the LLM section (rule-only report).
fn build_llm_config() -> @llm.LlmConfig? {
  let base = @env.get_env_var("MOONMEDIC_LLM_BASE_URL")
  let model = @env.get_env_var("MOONMEDIC_LLM_MODEL")
  match (base, model) {
    (Some(base), Some(model)) =>
      if !(base.is_empty() || model.is_empty()) {
        match
          @llm.LlmConfig::try_from_parts(
            base_url=base,
            api_key=@env.get_env_var("MOONMEDIC_LLM_KEY").unwrap_or(""),
            model~,
            system_prompt="",
          ) {
          Ok(config) => Some(config)
          Err(message) => {
            println("LLM 配置无效,已跳过 LLM 归纳:\{message}")
            None
          }
        }
      } else {
        None
      }
    _ => None
  }
}
