///|
/// Kubernetes resource.Quantity parsing for quota arithmetic. Supports plain
/// numbers, milli (`500m`), decimal suffixes (`1k`, `2M`, `3G`) and binary
/// suffixes (`64Mi`, `4Gi`). Unparseable values return None so rules degrade
/// instead of guessing.
pub fn parse_quantity(value : String) -> Double? {
  let text = value.trim()
  if text.is_empty() {
    return None
  }
  let binary : Array[(String, Double)] = [
    ("Ki", 1024.0),
    ("Mi", 1024.0 * 1024.0),
    ("Gi", 1024.0 * 1024.0 * 1024.0),
    ("Ti", 1024.0 * 1024.0 * 1024.0 * 1024.0),
    ("Pi", 1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0),
    ("Ei", 1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0),
  ]
  for suffix_factor in binary {
    let (suffix, factor) = suffix_factor
    if text.has_suffix(suffix) && text.length() > suffix.length() {
      let number = text[:text.length() - suffix.length()]
      let parsed = @string.parse_double(number) catch { _ => return None }
      return Some(parsed * factor)
    }
  }
  let decimal : Array[(String, Double)] = [
    ("m", 0.001),
    ("k", 1000.0),
    ("K", 1000.0),
    ("M", 1000.0 * 1000.0),
    ("G", 1000.0 * 1000.0 * 1000.0),
    ("T", 1000.0 * 1000.0 * 1000.0 * 1000.0),
    ("P", 1000.0 * 1000.0 * 1000.0 * 1000.0 * 1000.0),
    ("E", 1000.0 * 1000.0 * 1000.0 * 1000.0 * 1000.0 * 1000.0),
  ]
  for suffix_factor in decimal {
    let (suffix, factor) = suffix_factor
    if text.has_suffix(suffix) && text.length() > suffix.length() {
      let number = text[:text.length() - suffix.length()]
      let parsed = @string.parse_double(number) catch { _ => return None }
      return Some(parsed * factor)
    }
  }
  let parsed = @string.parse_double(text.exact_view(start=0, end=text.length())) catch {
    _ => return None
  }
  Some(parsed)
}

///|
/// Compare two quantities: -1 when used < hard, 0 when equal, 1 when used >
/// hard. None when either side cannot be parsed (rules then stay silent).
pub fn quantity_compare(used : String, hard : String) -> Int32? {
  match (parse_quantity(used), parse_quantity(hard)) {
    (Some(u), Some(h)) =>
      if u < h {
        Some(-1)
      } else if u > h {
        Some(1)
      } else {
        Some(0)
      }
    _ => None
  }
}

///|
/// Percentage of a hard limit already consumed, rounded down. None when the
/// hard limit is zero/negative or either quantity is unparseable.
pub fn quota_usage_percent(used : String, hard : String) -> Int32? {
  match (parse_quantity(used), parse_quantity(hard)) {
    (Some(u), Some(h)) =>
      if h <= 0.0 {
        None
      } else {
        Some((u / h * 100.0).to_int())
      }
    _ => None
  }
}

///|
/// True when usage has reached or exceeded the hard limit.
pub fn quantity_saturated(used : String, hard : String) -> Bool {
  match quantity_compare(used, hard) {
    Some(value) => value >= 0
    None => false
  }
}

///|
/// Remaining headroom in the same unit as `hard`, or None if unparseable.
pub fn quantity_headroom(used : String, hard : String) -> Double? {
  match (parse_quantity(used), parse_quantity(hard)) {
    (Some(u), Some(h)) => Some(h - u)
    _ => None
  }
}
