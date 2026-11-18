"""Golden 断言:校验离线诊断输出与预期规则/证据一致。

用法: assert.py <expected.json> <actual-diagnosis.json>
expect_findings 按 rule_id 检查诊断层、权重、建议文本与结构化证据。
"""
import json, sys

expected = json.load(open(sys.argv[1], encoding="utf-8"))
actual = json.load(open(sys.argv[2], encoding="utf-8"))
findings = actual.get("findings", [])
ids = [f.get("rule_id") for f in findings]
evidence_text = "\n".join(
    line for f in findings for line in f.get("evidence", [])
)

failures = []
for rid in expected.get("expect_rule_ids", []):
    if rid not in ids:
        failures.append(f"缺少预期规则: {rid} (实际: {ids})")
for rid in expected.get("forbid_rule_ids", []):
    if rid in ids:
        failures.append(f"出现禁止规则: {rid}")
for needle in expected.get("evidence_contains", []):
    if needle not in evidence_text:
        failures.append(f"证据缺少关键内容: {needle}")

for rule_id, spec in expected.get("expect_findings", {}).items():
    matching = [finding for finding in findings if finding.get("rule_id") == rule_id]
    if len(matching) != 1:
        failures.append(f"{rule_id}: 期望一条诊断，实际 {len(matching)} 条")
        continue
    finding = matching[0]
    for field in ("layer", "confidence"):
        if field in spec and finding.get(field) != spec[field]:
            failures.append(f"{rule_id}: {field} 期望 {spec[field]!r}，实际 {finding.get(field)!r}")
    detail = finding.get("detail", "")
    for needle in spec.get("detail_contains", []):
        if needle not in detail:
            failures.append(f"{rule_id}: 建议缺少 {needle!r}")
    for needle in spec.get("forbid_detail_contains", []):
        if needle in detail:
            failures.append(f"{rule_id}: 建议包含禁止内容 {needle!r}")
    refs = finding.get("evidence_refs", [])
    for ref in spec.get("evidence_refs", []):
        if not any(all(item.get(key) == value for key, value in ref.items()) for item in refs):
            failures.append(f"{rule_id}: 结构化证据缺少 {ref!r}")
    for source in spec.get("forbid_evidence_sources", []):
        if any(item.get("source") == source for item in refs):
            failures.append(f"{rule_id}: 出现不应引用的证据来源 {source!r}")

if failures:
    print("FAIL")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print(f"PASS (findings: {ids})")
