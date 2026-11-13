///|
/// One tool call requested by the model (OpenAI tool-calling wire format).
pub(all) struct ToolCall {
  id : String
  name : String
  arguments : Json
}

///|
/// Buffered assistant turn: optional text content plus requested tool calls.
pub(all) struct AgentTurn {
  content : String
  tool_calls : Array[ToolCall]
}

///|
/// One agent chat turn with OpenAI tool-calling wire format. messages and
/// tools pass through as opaque OpenAI JSON; only the response is parsed.
pub async fn chat_with_tools(
  config : LlmConfig,
  messages~ : Array[Json],
  tools~ : Array[Json],
) -> Result[AgentTurn, String] {
  let body_map : Map[String, Json] = Map([])
  body_map["model"] = Json::string(config.model)
  body_map["messages"] = Json::array(messages)
  if tools.length() > 0 {
    body_map["tools"] = Json::array(tools)
  }
  body_map["stream"] = Json::boolean(false)
  body_map["temperature"] = Json::number(0.2)
  let (code, text) = match
    send_chat(config, Json::object(body_map).stringify()) {
    Ok(pair) => pair
    Err(message) => return Err(message)
  }
  if code != 200 {
    if text.length() <= 400 {
      return Err("HTTP \{code}: \{text}")
    }
    return Err("HTTP \{code} (body \{text.length()} bytes)")
  }
  parse_agent_turn(text)
}

///|
/// Parse choices[0].message into an AgentTurn: content (may be null when the
/// model calls tools) plus tool_calls with JSON-decoded arguments.
fn parse_agent_turn(body : String) -> Result[AgentTurn, String] {
  let parsed = @json.parse(body) catch {
    _ => return Err("LLM 响应不是有效 JSON")
  }
  guard parsed is Object(fields) else {
    return Err("LLM 响应必须是 JSON 对象")
  }
  guard fields.get("choices") is Some(Array(choices)) && choices.length() > 0 else {
    return Err("LLM 响应缺少 choices")
  }
  guard choices[0] is Object(choice) &&
    choice.get("message") is Some(Object(message)) else {
    return Err("LLM 响应缺少 choices[0].message")
  }
  let content = match message.get("content") {
    Some(String(text)) => text
    _ => ""
  }
  let calls : Array[ToolCall] = []
  if message.get("tool_calls") is Some(Array(raw_calls)) {
    for raw in raw_calls {
      match parse_tool_call(raw) {
        Some(call) => calls.push(call)
        None => return Err("LLM tool_calls 项格式无效")
      }
    }
  }
  Ok({ content, tool_calls: calls, })
}

///|
/// Parse one OpenAI tool call: {id, type:"function", function:{name,
/// arguments}} where arguments is a JSON-encoded string.
fn parse_tool_call(raw : Json) -> ToolCall? {
  guard raw is Object(fields) else { return None }
  let id = match fields.get("id") {
    Some(String(value)) => value
    _ => ""
  }
  guard fields.get("function") is Some(Object(function)) else { return None }
  let name = match function.get("name") {
    Some(String(value)) => value
    _ => return None
  }
  let arguments = match function.get("arguments") {
    Some(String(encoded)) =>
      @json.parse(encoded) catch {
        _ => Json::string(encoded)
      }
    Some(raw_args) => raw_args
    None => Json::object(Map([]))
  }
  Some({ id, name, arguments, })
}
