///|
/// Whitebox tests for private helpers.

///|
test "json_escape handles quotes, newlines and control chars" {
  inspect(json_escape("a\"b"), content="a\\\"b")
  inspect(json_escape("line1\nline2"), content="line1\\nline2")
  inspect(json_escape("tab\there"), content="tab\\there")
  inspect(json_escape("back\\slash"), content="back\\\\slash")
  inspect(json_escape("\u{0001}ctl"), content=" ctl")
}

///|
test "extract_content reads choices[0].message.content" {
  let body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"根因是 OOM\"}}]}"
  inspect(extract_content(body), content="Ok(根因是 OOM)")
}

///|
test "extract_content reports missing choices" {
  let body = "{\"error\":{\"message\":\"rate limited\"}}"
  match extract_content(body) {
    Err(message) => inspect(message.contains("choices"), content="true")
    Ok(_) => inspect("unexpected Ok", content="expected Err")
  }
}
