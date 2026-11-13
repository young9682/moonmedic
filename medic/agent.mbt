///|
/// The W4 agent loop: the LLM autonomously decides which read-only tool to
/// call next until it can write a grounded conclusion. Loop design mirrors
/// mizchi/llm's `run_json_chat_loop` (OpenAI tool-calling wire format, same
/// message bookkeeping) adapted to async HTTP and async tools; the tool
/// whitelist below is the only reachable surface and every request is a GET.
///
/// Degradation ladder: agent failure -> rule-only report (summary=None),
/// so the pipeline never blocks on the LLM.

///|
const AGENT_SYSTEM = "你是 moonmedic,Kubernetes 集群的只读排障助手。你只能通过提供的工具取证,禁止臆造工具结果中不存在的信息。策略:先 get_pod 看状态机,再看 get_events 关联事件,必要时 get_logs 看崩溃现场;证据足够后停止调用工具,直接输出 Markdown 报告,结构:\n**根因**:…\n**依据**:…(引用工具返回的具体内容)\n**建议**:…(最多 3 条,具体可执行)\n**置信度**:高/中/低\n证据不足时在报告中明确写\"证据不足\"。"

///|
/// OpenAI function schemas for the read-only tool whitelist. The namespace
/// is fixed by the CLI target and never agent-controlled.
fn tool_defs() -> Array[Json] {
  let get_pod = tool_def(
    "get_pod",
    "读取一个 Pod 的完整状态:phase、容器状态机(waiting/terminated)、重启次数、资源限制",
    [("name", "Pod 名称;默认就是当前诊断目标")],
  )
  let get_events = tool_def(
    "get_events",
    "读取与目标 Pod 相关的最近事件(如 FailedScheduling、Unhealthy、OOM 信号)",
    [],
  )
  let get_logs = tool_def(
    "get_logs",
    "读取目标 Pod 第一个容器的最近日志尾部",
    [("tail", "行数,默认 100,上限 500")],
  )
  let list_pods = tool_def(
    "list_pods",
    "列出当前 namespace 的全部 Pod 名(用于对比同类 Pod 是否都异常)",
    [],
  )
  [get_pod, get_events, get_logs, list_pods]
}

///|
/// Build one OpenAI function-tool schema. props maps parameter name to a
/// short human description (kept as plain strings for readability).
fn tool_def(
  name : String,
  description : String,
  props : Array[(String, String)],
) -> Json {
  let properties : Map[String, Json] = Map([])
  for pair in props {
    let (param, desc) = pair
    let schema : Map[String, Json] = Map([])
    schema["type"] = Json::string("string")
    schema["description"] = Json::string(desc)
    properties[param] = Json::object(schema)
  }
  let parameters : Map[String, Json] = Map([])
  parameters["type"] = Json::string("object")
  parameters["properties"] = Json::object(properties)
  let function : Map[String, Json] = Map([])
  function["name"] = Json::string(name)
  function["description"] = Json::string(description)
  function["parameters"] = Json::object(parameters)
  let def : Map[String, Json] = Map([])
  def["type"] = Json::string("function")
  def["function"] = Json::object(function)
  Json::object(def)
}

///|
/// Read one string field from a tool-call arguments object.
fn arg_str(args : Json, key : String) -> String? {
  match args {
    Object(fields) =>
      match fields.get(key) {
        Some(String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
/// Read one integer field from a tool-call arguments object.
fn arg_int(args : Json, key : String) -> Int32? {
  match args {
    Object(fields) =>
      match fields.get(key) {
        Some(Number(value, ..)) => Some(value.to_int())
        _ => None
      }
    _ => None
  }
}

///|
/// Execute one whitelisted tool call. Failures become readable tool results
/// so the model can adapt instead of crashing the loop.
async fn execute_tool(
  target : @tools.K8sTarget,
  pod_name~ : String,
  call : @llm.ToolCall,
) -> String {
  let result : Result[String, String] = match call.name {
    "get_pod" => {
      let name = arg_str(call.arguments, "name").unwrap_or(pod_name)
      match @tools.get_pod(target, name~) {
        Ok(pod) => Ok(trim_result(pod.raw().stringify()))
        Err(message) => Err(message)
      }
    }
    "get_events" =>
      match @tools.get_events(target, pod_name~) {
        Ok(lines) =>
          Ok(
            if lines.is_empty() {
              "(无相关事件)"
            } else {
              lines.join("\n")
            },
          )
        Err(message) => Err(message)
      }
    "get_logs" => {
      let tail = match arg_int(call.arguments, "tail") {
        Some(value) => if value < 500 { value } else { 500 }
        None => 100
      }
      match @tools.get_pod(target, name=pod_name) {
        Ok(pod) =>
          match @tools.first_container_name(pod) {
            Some(container) =>
              match @tools.get_logs(target, pod_name~, tail~, container~) {
                Ok(text) => Ok(trim_result(text))
                Err(message) => Err(message)
              }
            None => Err("Pod 没有容器定义,无法读日志")
          }
        Err(message) => Err("get_logs 前置失败(get_pod):\{message}")
      }
    }
    "list_pods" =>
      match @tools.list_pod_names(target) {
        Ok(names) => Ok(names.join("\n"))
        Err(message) => Err(message)
      }
    other =>
      Err(
        "未知工具 \"\{other}\",可用工具:get_pod/get_events/get_logs/list_pods",
      )
  }
  match result {
    Ok(text) => text
    Err(message) => "工具失败:\{message}"
  }
}

///|
/// Cap a tool result so a chatty pod cannot blow up the context window.
fn trim_result(text : String, cap~ : Int32 = 1500) -> String {
  if text.length() <= cap {
    text
  } else {
    text[:cap].to_owned() + "\n…(已截断,共 \{text.length()} 字符)"
  }
}

///|
/// Rebuild one assistant message (content + tool_calls) in OpenAI wire
/// format, mirroring mizchi/llm's build_assistant_message.
fn build_assistant_msg(content : String, calls : Array[@llm.ToolCall]) -> Json {
  let msg : Map[String, Json] = Map([])
  msg["role"] = Json::string("assistant")
  msg["content"] = Json::string(content)
  if !calls.is_empty() {
    let arr = []
    for call in calls {
      let function : Map[String, Json] = Map([])
      function["name"] = Json::string(call.name)
      function["arguments"] = Json::string(call.arguments.stringify())
      let item : Map[String, Json] = Map([])
      item["id"] = Json::string(call.id)
      item["type"] = Json::string("function")
      item["function"] = Json::object(function)
      arr.push(Json::object(item))
    }
    msg["tool_calls"] = Json::array(arr)
  }
  Json::object(msg)
}

///|
/// Build the tool result message in OpenAI wire format.
fn build_tool_msg(id : String, result : String) -> Json {
  let msg : Map[String, Json] = Map([])
  msg["role"] = Json::string("tool")
  msg["tool_call_id"] = Json::string(id)
  msg["content"] = Json::string(result)
  Json::object(msg)
}
