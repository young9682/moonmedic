///|
/// Parsed scope of an explicit ResourceQuota denial. Requests are the
/// resource deltas printed by the admission plugin for the rejected request.
priv struct QuotaRejection {
  name : String
  requested : Map[String, Double]
}

///|
priv enum AdmissionRejection {
  QuotaExceeded(QuotaRejection)
  MissingQuotaResources
  LimitRangeRejected
  Unclassified
}

///|
/// Strip the controller and API status wrappers, if present. Test snapshots
/// can also supply the bare reason. Never search inside arbitrary messages.
fn admission_payload(message : String) -> StringView {
  let text = message.trim()
  let text = text.strip_prefix("Error creating: ").unwrap_or(text)
  if text.strip_prefix("pods \"") is Some(pod) &&
    pod.split_once("\" is forbidden: ") is Some((name, payload)) &&
    !name.is_empty() &&
    !name.contains("\"") {
    payload
  } else {
    text
  }
}

///|
fn classify_admission(message : String) -> AdmissionRejection {
  let payload = admission_payload(message)
  if payload.strip_prefix("exceeded quota: ") is Some(body) {
    return match parse_quota_rejection(body) {
      Some(rejection) => QuotaExceeded(rejection)
      None => Unclassified
    }
  }
  if payload.strip_prefix("failed quota: ") is Some(body) &&
    body.split_once(": must specify ") is Some((name, fields)) &&
    !name.is_empty() &&
    !fields.is_empty() {
    return MissingQuotaResources
  }
  if is_limitrange_message(payload) {
    LimitRangeRejected
  } else {
    Unclassified
  }
}

///|
fn parse_quota_rejection(body : StringView) -> QuotaRejection? {
  guard body.split_once(", requested: ") is Some((name, rest)) &&
    !name.is_empty() &&
    !name.contains(" ") &&
    !name.contains(",") &&
    rest.split_once(", used: ") is Some((request_text, rest)) &&
    rest.split_once(", limited: ") is Some((used_text, hard_text)) else {
    return None
  }
  guard parse_admission_quantities(request_text) is Some(requested) &&
    parse_admission_quantities(used_text) is Some(used) &&
    parse_admission_quantities(hard_text) is Some(hard) &&
    requested.length() == used.length() &&
    requested.length() == hard.length() else {
    return None
  }
  for resource, request in requested {
    guard used.get(resource) is Some(previous) &&
      hard.get(resource) is Some(limit) &&
      request > 0.0 &&
      request > limit - previous else {
      return None
    }
  }
  Some({ name: name.to_owned(), requested, })
}

///|
fn parse_admission_quantities(text : StringView) -> Map[String, Double]? {
  let quantities : Map[String, Double] = Map([])
  for item in text.split(",") {
    guard item.trim().split_once("=") is Some((key, value)) &&
      !key.is_empty() &&
      !key.contains(" ") &&
      !quantities.contains(key.to_owned()) &&
      admission_quantity(value) is Some(quantity) else {
      return None
    }
    quantities[key.to_owned()] = quantity
  }
  if quantities.length() == 0 {
    None
  } else {
    Some(quantities)
  }
}

///|
fn admission_quantity(text : StringView) -> Double? {
  guard parse_quantity(text.to_owned()) is Some(value) &&
    value.is_finite() &&
    value >= 0.0 else {
    return None
  }
  Some(value)
}

///|
/// Recognize the upstream Container/Pod min, max and ratio forms. Kubernetes
/// also encloses multiple LimitRanger violations in brackets. For that form
/// the first clause suffices to attribute the rejection.
fn is_limitrange_message(payload : StringView) -> Bool {
  let aggregated = payload.has_prefix("[") && payload.has_suffix("]")
  let payload = if aggregated {
    payload[1:payload.length() - 1]
  } else {
    payload
  }
  if payload.strip_prefix("minimum ") is Some(body) {
    return limitrange_bound(body, minimum=true, aggregated~)
  }
  if payload.strip_prefix("maximum ") is Some(body) {
    return limitrange_bound(body, minimum=false, aggregated~)
  }
  guard payload.split_once(" max limit to request ratio per ")
    is Some((resource, bound)) &&
    is_limitrange_resource(resource) &&
    limitrange_scope(bound) is Some(bound) &&
    bound.split_once(", but ") is Some((limit, violation)) &&
    admission_quantity(limit) is Some(limit) else {
    return false
  }
  let violation = first_limitrange_violation(violation, aggregated)
  if violation.strip_prefix("provided ratio is ") is Some(observed) &&
    admission_quantity(observed) is Some(observed) {
    return observed > limit
  }
  violation == "no request is specified or request is 0" ||
  violation == "no limit is specified or limit is 0"
}

///|
fn limitrange_bound(
  body : StringView,
  minimum~ : Bool,
  aggregated~ : Bool,
) -> Bool {
  guard body.split_once(" usage per ") is Some((resource, bound)) &&
    is_limitrange_resource(resource) &&
    limitrange_scope(bound) is Some(bound) else {
    return false
  }
  if bound.split_once(".  No ") is Some((limit, missing)) &&
    admission_quantity(limit) is Some(_) {
    let missing = first_limitrange_violation(missing, aggregated)
    return missing == "request is specified" ||
      (!minimum && missing == "limit is specified")
  }
  if bound.split_once(", but ") is Some((limit, violation)) {
    let violation = first_limitrange_violation(violation, aggregated)
    let observed = match violation.strip_prefix("request is ") {
      Some(value) => Some(value)
      None => violation.strip_prefix("limit is ")
    }
    guard admission_quantity(limit) is Some(limit) &&
      observed is Some(observed) &&
      admission_quantity(observed) is Some(observed) else {
      return false
    }
    return if minimum { observed < limit } else { observed > limit }
  }
  false
}

///|
fn is_limitrange_resource(resource : StringView) -> Bool {
  !resource.is_empty() && !resource.contains(" ") && !resource.contains(",")
}

///|
fn limitrange_scope(bound : StringView) -> StringView? {
  match bound.strip_prefix("Container is ") {
    Some(rest) => Some(rest)
    None => bound.strip_prefix("Pod is ")
  }
}

///|
fn first_limitrange_violation(
  text : StringView,
  aggregated : Bool,
) -> StringView {
  if aggregated && text.split_once(", ") is Some((first, _)) {
    first
  } else {
    text
  }
}
