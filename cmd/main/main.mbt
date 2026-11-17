///|
/// moonmedic CLI.
///
/// Usage:
/// - `moon run cmd/main`                       list pod names in MOONMEDIC_NAMESPACE
/// - `moon run cmd/main -- <pod>`              diagnose a Pod (fallback to Deployment)
/// - `moon run cmd/main -- <ns> <name>`        diagnose a Pod or a same-named Deployment
/// - `moon run cmd/main -- --deployment <ns> <name>`  diagnose a Deployment directly
/// - `--json`                                  machine-readable output for eval
/// - `--agent`                                 use the LLM tool loop (Pod path)
///
/// Cluster configuration via environment variables:
/// - MOONMEDIC_SERVER     default "http://127.0.0.1:8001" (kubectl proxy)
/// - MOONMEDIC_TOKEN      optional bearer token
/// - MOONMEDIC_CA_FILE    optional PEM file with the API server CA
///
/// LLM configuration (optional; without it the report is rule-only):
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
  let mut kind = "Pod"
  let mut json = false
  let mut use_agent = false
  let mut snapshot_file : String? = None
  let operands : Array[String] = []
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if arg == "--deployment" || arg == "--workload" {
      kind = "Deployment"
    } else if arg == "--pod" {
      kind = "Pod"
    } else if arg == "--json" {
      json = true
    } else if arg == "--agent" {
      use_agent = true
    } else if arg == "--snapshot" && i + 1 < args.length() {
      // Offline replay: diagnose a recorded ClusterSnapshot JSON file with
      // no cluster, no network and no LLM. Used by the eval harness.
      snapshot_file = Some(args[i + 1])
      i = i + 1
    } else {
      operands.push(arg)
    }
    i = i + 1
  }
  match snapshot_file {
    Some(path) => {
      let text = @fs.read_file(path).text() catch {
        _ => {
          println("无法读取 snapshot 文件:\{path}")
          return
        }
      }
      let parsed = @json.parse(text) catch {
        _ => {
          println("snapshot 文件不是有效 JSON:\{path}")
          return
        }
      }
      let snapshot = match @snapshot.ClusterSnapshot::from_json(parsed) {
        Ok(snapshot) => snapshot
        Err(message) => {
          println("snapshot 解析失败:\{message}")
          return
        }
      }
      let result = @core.diagnose(snapshot)
      if json {
        println(@report.render_json(result.diagnosis))
      } else {
        println(@report.render_markdown(result.diagnosis))
      }
      return
    }
    None => ()
  }
  if operands.length() >= 1 {
    let ns = if operands.length() >= 2 {
      operands[0]
    } else {
      @env.get_env_var("MOONMEDIC_NAMESPACE").unwrap_or("default")
    }
    let name = if operands.length() >= 2 { operands[1] } else { operands[0] }
    let target = @tools.K8sTarget::from_parts(server~, token~, ca_file~, ns~)
    let diagnosis = if kind == "Deployment" {
      @medic.diagnose_workload(target, name~, llm_config?)
    } else {
      match (llm_config, use_agent) {
        (Some(config), true) =>
          @medic.diagnose_agent(target, pod_name=name, config)
        (Some(_), false) => @medic.diagnose_target(target, name~, llm_config?)
        (None, _) => @medic.diagnose_target(target, name~)
      }
    }
    if json {
      println(@report.render_json(diagnosis))
    } else {
      println(@report.render_markdown(diagnosis))
    }
    return
  }
  // No operands: list pods in the default namespace.
  let ns = @env.get_env_var("MOONMEDIC_NAMESPACE").unwrap_or("kube-system")
  let target = @tools.K8sTarget::from_parts(server~, token~, ca_file~, ns~)
  println(
    "moonmedic — listing pods in namespace \"\{ns}\" (usage: moonmedic [--deployment] <ns> <name> to diagnose)",
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
