///|
/// Whitebox tests for the agent loop helpers.

///|
test "tool_defs exposes the readonly whitelist" {
  let defs = tool_defs()
  inspect(defs.length(), content="4")
  let all = defs[0].stringify() +
    defs[1].stringify() +
    defs[2].stringify() +
    defs[3].stringify()
  inspect(all.contains("\"get_pod\""), content="true")
  inspect(all.contains("\"get_events\""), content="true")
  inspect(all.contains("\"get_logs\""), content="true")
  inspect(all.contains("\"list_pods\""), content="true")
  // Namespace is never agent-controlled: no parameter key named namespace.
  inspect(all.contains("\"namespace\""), content="false")
}

///|
test "trim_result caps and marks truncation" {
  inspect(trim_result("short", cap=10), content="short")
  let long = "{\"kind\":\"Pod\",\"very\":\"long payload\"}"
  let trimmed = trim_result(long, cap=10)
  inspect(trimmed.contains("…(已截断"), content="true")
  inspect(trimmed.length() < long.length() + 30, content="true")
}

///|
test "build_tool_msg carries id and content" {
  let msg = build_tool_msg("call_9", "工具结果文本")
  inspect(
    msg.stringify().contains("\"tool_call_id\":\"call_9\""),
    content="true",
  )
  inspect(msg.stringify().contains("\"role\":\"tool\""), content="true")
}

///|
test "build_assistant_msg embeds tool calls with encoded arguments" {
  let call : @llm.ToolCall = {
    id: "call_1",
    name: "get_pod",
    arguments: Json::object({ "name": Json::string("demo-pod") }),
  }
  let msg = build_assistant_msg("", [call])
  let wire = msg.stringify()
  inspect(wire.contains("\"role\":\"assistant\""), content="true")
  inspect(wire.contains("\"name\":\"get_pod\""), content="true")
  inspect(wire.contains("\"arguments\":\"{"), content="true")
}

///|
test "arg helpers read typed fields" {
  let args = Json::object({
    "name": Json::string("p1"),
    "tail": Json::number(50.0),
  })
  inspect(arg_str(args, "name"), content="Some(p1)")
  inspect(arg_int(args, "tail") is Some(50), content="true")
  inspect(arg_str(args, "missing") is None, content="true")
}
