"""Golden 断言:校验离线诊断输出与预期规则/证据一致。

用法: assert.py <expected.json> <actual-diagnosis.json>
expected: {"expect_rule_ids": [...], "forbid_rule_ids": [...], "evidence_contains": [...]}
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

if failures:
    print("FAIL")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print(f"PASS (findings: {ids})")
