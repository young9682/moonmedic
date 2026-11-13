///|
/// Minimal OpenAI-compatible chat-completions client (POST /chat/completions,
/// stream=false). Implemented directly on moonbitlang/async http so the
/// native build stays free of C stubs; the same request shape works for
/// DeepSeek, GLM, Kimi, vLLM and OpenAI itself.
pub struct LlmConfig {
  base_url : String
  api_key : String?
  model : String
  system_prompt : String
}

///|
pub fn LlmConfig::try_from_parts(
  base_url~ : String,
  api_key~ : String = "",
  model~ : String,
  system_prompt~ : String = "",
) -> Result[LlmConfig, String] {
  if base_url.is_empty() {
    return Err("base_url is empty")
  }
  if model.is_empty() {
    return Err("model is empty")
  }
  let key : String? = if api_key.is_empty() { None } else { Some(api_key) }
  Ok({
    base_url: base_url.trim_end(chars="/").to_owned(),
    api_key: key,
    model,
    system_prompt,
  })
}

///|
/// Split a base URL that may carry a path into (origin, path prefix).
/// async http's Client wants a bare origin; the path must ride on targets.
fn split_origin(base_url : String) -> (String, String) {
  let parts = base_url.split("://").to_array()
  if parts.length() != 2 {
    return (base_url, "")
  }
  let scheme = parts[0].to_owned()
  let host_and_path = parts[1].to_owned()
  let segments = host_and_path.split("/").to_array()
  if segments.length() <= 1 {
    return (base_url, "")
  }
  let origin = "\{scheme}://\{segments[0].to_owned()}"
  let prefix = host_and_path[segments[0].length():].to_owned()
  (origin, prefix)
}

///|
/// One buffered chat completion. Returns the assistant message content.
/// Any network/format failure becomes Err so the caller can degrade.
pub async fn chat_complete(
  config : LlmConfig,
  user_prompt~ : String,
) -> Result[String, String] {
  let body = "{\"model\":\"\{config.model}\",\"messages\":[{\"role\":\"system\",\"content\":\"\{json_escape(config.system_prompt)}\"},{\"role\":\"user\",\"content\":\"\{json_escape(user_prompt)}\"}],\"stream\":false,\"temperature\":0.2}"
  let headers : Map[@http.CaseInsensitiveString, String] = Map([
    (@http.CaseInsensitiveString("Content-Type"), "application/json"),
  ])
  match config.api_key {
    Some(key) =>
      headers[@http.CaseInsensitiveString("Authorization")] = "Bearer \{key}"
    None => ()
  }
  // Explicit byte length: async http defaults to chunked transfer otherwise,
  // and the body contains multi-byte UTF-8 (Chinese prompts).
  headers[@http.CaseInsensitiveString("Content-Length")] = @utf8.encode(body)
    .length()
    .to_string()
  let (origin, prefix) = split_origin(config.base_url)
  let outcome : Result[(Int32, String), String] = try {
    let client = @http.Client(origin)
    defer client.close()
    client.request(
      Post,
      "\{origin}\{prefix}/chat/completions",
      extra_headers=headers,
    )
    client.write(body)
    let response = client.end_request()
    let text = client.read_all().text()
    Ok((response.code, text))
  } catch {
    _ => Err("LLM 请求失败(网络错误或 URL 无效)")
  }
  let (code, text) = match outcome {
    Ok(pair) => pair
    Err(message) => return Err(message)
  }
  if code != 200 {
    if text.length() <= 400 {
      return Err("HTTP \{code}: \{text}")
    }
    return Err("HTTP \{code} (body \{text.length()} bytes)")
  }
  extract_content(text)
}

///|
/// Parse choices[0].message.content out of a chat-completions response.
fn extract_content(body : String) -> Result[String, String] {
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
  match message.get("content") {
    Some(String(content)) => Ok(content)
    _ => Err("LLM 响应缺少 message.content")
  }
}

///|
/// Escape a string for embedding inside a JSON body built by hand.
fn json_escape(value : String) -> String {
  let buf = StringBuilder(size_hint=value.length() + 16)
  for ch in value {
    match ch {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      '\u{0000}'..<='\u{001F}' => buf.write_string(" ")
      c => buf.write_char(c)
    }
  }
  buf.to_string()
}
