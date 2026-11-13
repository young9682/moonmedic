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
/// Structured result of one diagnosis run.
pub(all) struct Diagnosis {
  ns : String
  pod : String
  phase : String
  findings : Array[Finding]
  notes : Array[String]
  /// Optional LLM-written conclusion. None = LLM absent or failed; the
  /// report then falls back to the deterministic rule-engine conclusion.
  summary : String?
}
