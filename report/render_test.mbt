///|
test "render_markdown labels Deployment targets" {
  let diagnosis : @rules.Diagnosis = {
    ns: "prod",
    target: "payments-api",
    target_kind: "Deployment",
    phase: "Deployment",
    findings: [],
    notes: [],
    summary: None,
  }
  let text = @report.render_markdown(diagnosis)
  inspect(text.contains("Deployment: `prod/payments-api`"), content="true")
  inspect(text.contains("Phase: `Deployment`"), content="true")
}

///|
test "render_json exposes target kind, rule ids and notes" {
  let diagnosis : @rules.Diagnosis = {
    ns: "prod",
    target: "payments-api",
    target_kind: "Deployment",
    phase: "Deployment",
    findings: [
      {
        rule_id: "quota_exceeded",
        title: "配额耗尽",
        detail: "detail",
        confidence: 0.98,
        evidence: ["ResourceQuota/compute: pods used=\"10\", hard=\"10\""],
        evidence_refs: [
          @rules.Evidence::{
            source: "resourcequota",
            resource_kind: "ResourceQuota",
            object_name: "compute",
            field_path: "status.pods",
            observed_value: "used=10, hard=10",
            observed_at: None,
            resource_version: None,
          },
        ],
      },
    ],
    notes: ["fixture"],
    summary: None,
  }
  let text = @report.render_json(diagnosis)
  inspect(text.contains("\"target_kind\""), content="true")
  inspect(text.contains("Deployment"), content="true")
  inspect(text.contains("quota_exceeded"), content="true")
  inspect(text.contains("\"notes\""), content="true")
  inspect(text.contains("ResourceQuota/compute"), content="true")
}
