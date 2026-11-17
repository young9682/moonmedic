///|
/// A single conclusion produced by a diagnostic rule.
pub(all) struct Finding {
  rule_id : String
  title : String
  detail : String
  confidence : Double
  evidence : Array[String]
}

///|
/// Structured result of one diagnosis run. `target_kind` records what was
/// actually diagnosed: a Pod when it exists, or the owning workload when the
/// Pod was never created (quota/limit rejection).
pub(all) struct Diagnosis {
  ns : String
  target : String
  target_kind : String
  phase : String
  findings : Array[Finding]
  notes : Array[String]
  /// Optional LLM-written conclusion. None = LLM absent or failed; the
  /// report then falls back to the deterministic rule-engine conclusion.
  summary : String?
}

///|
/// One Kubernetes Event reduced to the fields the knowledge base reasons
/// over. Rules match on `reason` (a typed API field) first and only fall back
/// to message text for vendor-specific wording.
pub(all) struct EventFact {
  reason : String
  message : String
  event_type : String
  kind : String
  name : String
  count : Int32
  last_seen : String?
}

///|
/// Event as a stable, human-readable evidence line.
pub fn EventFact::text(self : EventFact) -> String {
  let target = if self.kind.is_empty() && self.name.is_empty() {
    ""
  } else if self.name.is_empty() {
    "\{self.kind}/?"
  } else {
    "\{self.kind}/\{self.name}"
  }
  let stamp = match self.last_seen {
    Some(value) if !value.is_empty() => " @ \{value}"
    _ => ""
  }
  let head = if target.is_empty() {
    "Event/\{self.event_type}/\{self.reason}"
  } else {
    "Event/\{target} \{self.event_type}/\{self.reason}"
  }
  "\{head} ×\{self.count}\{stamp}: \{self.message}"
}

///|
/// True when this event reports an object-creation failure (the mechanism
/// behind quota / LimitRange rejections).
pub fn EventFact::is_failed_create(self : EventFact) -> Bool {
  self.reason == "FailedCreate"
}

///|
/// A status condition (Deployment, ReplicaSet, ...).
pub(all) struct ConditionFact {
  type_ : String
  status : String
  reason : String
  message : String
}

///|
/// One ReplicaSet owned by the diagnosed workload.
pub(all) struct ReplicaSetFact {
  name : String
  desired : Int32
  ready : Int32
  conditions : Array[ConditionFact]
}

///|
/// One ResourceQuota with its hard limits and current usage.
pub(all) struct QuotaFact {
  name : String
  hard : Array[(String, String)]
  used : Array[(String, String)]
}

///|
/// Facts for a workload-level diagnosis. This is how moonmedic answers "the
/// Pod does not exist": walk Deployment -> ReplicaSet -> Pod count, then
/// correlate namespace events and ResourceQuota usage.
pub(all) struct WorkloadFacts {
  ns : String
  kind : String
  name : String
  desired : Int32
  ready : Int32
  available : Int32
  conditions : Array[ConditionFact]
  replicasets : Array[ReplicaSetFact]
  events : Array[EventFact]
  quotas : Array[QuotaFact]
  pod_count : Int32
  pod_missing : Bool
}

///|
/// Facts with no workload data at all, used when the object itself could not
/// be read but events/quota evidence is still worth running rules over.
pub fn WorkloadFacts::empty(
  ns~ : String,
  kind~ : String,
  name~ : String,
  events~ : Array[EventFact],
  quotas~ : Array[QuotaFact],
) -> WorkloadFacts {
  {
    ns,
    kind,
    name,
    desired: 0,
    ready: 0,
    available: 0,
    conditions: [],
    replicasets: [],
    events,
    quotas,
    pod_count: 0,
    pod_missing: false,
  }
}
