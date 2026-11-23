"""Check evidence guards and percentage strategies through the snapshot CLI."""
import json
from copy import deepcopy
from pathlib import Path
from subprocess import run
from tempfile import TemporaryDirectory

root = Path(__file__).resolve().parents[2]
base = json.loads((root / "eval/fixtures/rollout-a-full.snapshot.json").read_text(encoding="utf-8"))
mutations = [
    (("data_status",), {"pods": {"state": "truncated", "seen": 4}}),
    (("quotas", 0, "spec"), {}),
    (("quotas", 0, "spec", "scopes"), ["BestEffort"]),
    (("quotas", 0, "status", "used", "pods"), "3"),
    (("replicasets", 1, "spec", "template"), base["deployment"]["spec"]["template"]),
    (("deployment", "spec", "paused"), True),
]
strategy_path = ("deployment", "spec", "strategy", "rollingUpdate")
mutations += [
    (strategy_path + ("maxSurge",), value)
    for value in ("25", "-1%", "+25%", "25.0%", "25%%", " 25%", "10000000001%")
]
mutations += [
    (strategy_path + ("maxUnavailable",), "101%"),
    (strategy_path, {"maxSurge": "0%", "maxUnavailable": 0}),
    (strategy_path, {"maxSurge": "25%"}),
]


def diagnose(case, fixture):
    fixture.write_text(json.dumps(case), encoding="utf-8")
    result = run(["moon", "run", "cmd/main", "--", "--snapshot", str(fixture), "--json"],
                 cwd=root, check=True, capture_output=True, encoding="utf-8")
    return json.loads(result.stdout)


with TemporaryDirectory() as folder:
    fixture = Path(folder) / "input.json"
    for path, value in mutations:
        case = deepcopy(base)
        target = case
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value
        diagnosis = diagnose(case, fixture)
        if any(f["layer"] == "projection" for f in diagnosis["findings"]) or not any(
            "滚动发布路径未判定" in note for note in diagnosis["notes"]
        ):
            raise AssertionError(f"inconsistent input accepted: {path}")

    # Three desired replicas and four occupied slots in all cases.
    percentage_cases = [
        ("25%", "25%", 1, "rollout_blocked", 1, 0),
        ("25%", "34%", 1, "rollout_reachable", 1, 1),
        ("0%", "1%", 0, "rollout_reachable", 0, 1),
        ("150%", 0, 1, "rollout_blocked", 5, 0),
        ("025%", 0, 1, "rollout_blocked", 1, 0),
    ]
    for surge, unavailable, desired, expected, effective_surge, effective_unavailable in percentage_cases:
        case = deepcopy(base)
        case["deployment"]["spec"]["strategy"]["rollingUpdate"] = {
            "maxSurge": surge, "maxUnavailable": unavailable,
        }
        case["replicasets"][0]["spec"]["replicas"] = desired
        findings = [
            f for f in diagnose(case, fixture)["findings"] if f["layer"] == "projection"
        ]
        assert [f["rule_id"] for f in findings] == [expected], (surge, unavailable, findings)
        effective = (f"生效策略 maxSurge={effective_surge}，maxUnavailable={effective_unavailable}，"
                     f"最低可用 {3 - effective_unavailable}")
        assert effective in findings[0]["evidence"], findings[0]
        if expected == "rollout_reachable":
            assert any(step.startswith("scale_old_rs(-1)") for step in findings[0]["evidence"])
print(f"{len(mutations)} invalid/unsupported inputs and {len(percentage_cases)} percentage policies passed")
