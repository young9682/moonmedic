"""Check rollout input guards through the snapshot CLI."""
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


def projections(diagnosis):
    return [f for f in diagnosis["findings"] if f["layer"] == "projection"]


def assert_undetermined(diagnosis, label):
    assert not projections(diagnosis) and any(
        "滚动发布路径未判定" in note for note in diagnosis["notes"]
    ), label


def owner(name):
    return [{"kind": "ReplicaSet", "controller": True, "name": name, "uid": name}]


def with_value(snapshot, path, value):
    case = deepcopy(snapshot)
    target = case
    for key in path[:-1]:
        target = target[key]
    target[path[-1]] = value
    return case


with TemporaryDirectory() as folder:
    fixture = Path(folder) / "input.json"
    for path, value in mutations:
        case = with_value(base, path, value)
        assert_undetermined(diagnose(case, fixture), path)

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
        findings = projections(diagnose(case, fixture))
        assert [f["rule_id"] for f in findings] == [expected], (surge, unavailable, findings)
        effective = (f"生效策略 maxSurge={effective_surge}，maxUnavailable={effective_unavailable}，"
                     f"最低可用 {3 - effective_unavailable}")
        assert effective in findings[0]["evidence"], findings[0]
        if expected == "rollout_reachable":
            assert any(step.startswith("scale_old_rs(-1)") for step in findings[0]["evidence"])

    history = deepcopy(base["replicasets"][1])
    history["metadata"].update(name="history", uid="history")
    history["spec"]["replicas"] = 0
    history["spec"]["template"]["metadata"]["labels"]["version"] = "history"
    history["status"] = {"replicas": 0}
    historical = deepcopy(base)
    historical["replicasets"].insert(0, history)
    terminal = deepcopy(historical["pods"][0])
    terminal["metadata"].update(name="finished", uid="finished", ownerReferences=owner("history"))
    terminal["status"]["phase"] = "Succeeded"
    historical["pods"].append(terminal)

    blocked, = projections(diagnose(historical, fixture))
    assert blocked["rule_id"] == "rollout_blocked"
    assert any(ref["object_name"] == "history" and ref["field_path"] == "status"
               for ref in blocked["evidence_refs"])

    retire_first = deepcopy(historical)
    retire_first["deployment"]["spec"]["strategy"]["rollingUpdate"]["maxUnavailable"] = 1
    reachable, = projections(diagnose(retire_first, fixture))
    assert reachable["rule_id"] == "rollout_reachable"
    assert any(step.startswith("scale_old_rs(-1)") for step in reachable["evidence"])

    released = deepcopy(historical)
    _, new, old = released["replicasets"]
    new["spec"]["replicas"] = 3
    new["status"] = {"replicas": 3, "availableReplicas": 3}
    old["spec"]["replicas"] = 0
    old["status"] = {"replicas": 0}
    for pod in released["pods"][:3]:
        pod["metadata"]["ownerReferences"] = owner("new")
    complete, = projections(diagnose(released, fixture))
    assert "快照中已达到替换目标" in complete["detail"]

    draining = deepcopy(released)
    draining["replicasets"][1]["status"] = {"replicas": 2, "availableReplicas": 2}
    draining["pods"][0]["metadata"].update(
        ownerReferences=owner("old"), deletionTimestamp="2026-11-20T00:00:00Z",
    )
    pending, = projections(diagnose(draining, fixture))
    assert pending["rule_id"] == "rollout_reachable"
    assert any(step.startswith("release_old_slot → create_new_pod") for step in pending["evidence"])

    history_mutations = [
        (("replicasets", 0, "spec", "replicas"), 1),
        (("replicasets", 0, "status"), {}),
        (("replicasets", 0, "status", "availableReplicas"), 1),
        (("replicasets", 0, "metadata", "uid"), "old"),
        (("replicasets", 0, "spec", "template"), base["deployment"]["spec"]["template"]),
        (("pods", 3, "metadata", "ownerReferences"), owner("history")),
    ]
    for path, value in history_mutations:
        case = with_value(historical, path, value)
        assert_undetermined(diagnose(case, fixture), path)

    deleting = deepcopy(historical)
    deleting["pods"][3]["metadata"].update(
        ownerReferences=owner("history"), deletionTimestamp="2026-11-20T00:00:00Z",
    )
    assert_undetermined(diagnose(deleting, fixture), "second old RS still has a terminating Pod")

    quota_cases = [
        ((4, 4), "rollout_blocked", "4（slots、guard-slots）"),
        ((5, 4), "rollout_blocked", "4（guard-slots）"),
        ((4, 5), "rollout_blocked", "4（slots）"),
        ((5, 5), "rollout_reachable", "5（slots、guard-slots）"),
    ]
    for (first, second), expected, limiting in quota_cases:
        paired = deepcopy(base)
        original = paired["quotas"][0]
        guard_quota = deepcopy(original)
        guard_quota["metadata"].update(name="guard-slots", uid="guard-slots")
        for quota, limit in ((original, first), (guard_quota, second)):
            quota["spec"]["hard"]["pods"] = str(limit)
            quota["status"]["hard"]["pods"] = str(limit)
        paired["quotas"].append(guard_quota)
        projected, = projections(diagnose(paired, fixture))
        assert projected["rule_id"] == expected, projected
        assert f"生效 pods 配额上限 {limiting}" in projected["evidence"], projected
        assert {ref["object_name"] for ref in projected["evidence_refs"]
                if ref["resource_kind"] == "ResourceQuota"} == {"slots", "guard-slots"}
        if expected == "rollout_reachable":
            assert any(step.startswith("create_new_pod") for step in projected["evidence"])
            assert not any("需调整的配额" in item for item in projected["evidence"])
        else:
            changes = "、".join(f"{q['metadata']['name']} 4→5" for q in paired["quotas"]
                               if q["status"]["hard"]["pods"] == "4")
            assert f"需调整的配额 {changes}" in projected["evidence"]

    quota_mutations = [
        (("quotas", 1, "status", "used", "pods"), "3"),
        (("quotas", 1, "spec", "hard", "pods"), "6"),
        (("quotas", 1, "spec", "scopes"), ["BestEffort"]),
        (("quotas", 1, "metadata", "name"), "slots"),
        (("quotas", 1, "metadata", "namespace"), "other"),
        (("quotas", 1), {
            **guard_quota,
            "spec": {"hard": {"pods": "5", "requests.cpu": "2"}},
            "status": {"hard": {"pods": "5", "requests.cpu": "2"},
                       "used": {"pods": "4", "requests.cpu": "1"}},
        }),
    ]
    for path, value in quota_mutations:
        assert_undetermined(diagnose(with_value(paired, path, value), fixture), path)

    # With the old version already removed, two new Pods are still missing.
    # All caps below 4, including the one that has headroom now, must rise.
    partial = deepcopy(base)
    new, old = partial["replicasets"]
    new["spec"]["replicas"] = 3
    new["status"] = {"replicas": 1, "availableReplicas": 1}
    old["spec"]["replicas"] = 0
    old["status"] = {"replicas": 0}
    partial["pods"] = [partial["pods"][0], partial["pods"][3]]
    partial["pods"][0]["metadata"]["ownerReferences"] = owner("new")
    partial["quotas"] = []
    for name, limit in (("slots", "2"), ("guard-slots", "3"), ("loose-slots", "4")):
        quota = deepcopy(base["quotas"][0])
        quota["metadata"].update(name=name, uid=name)
        quota["spec"]["hard"]["pods"] = limit
        quota["status"]["hard"]["pods"] = limit
        quota["status"]["used"]["pods"] = "2"
        partial["quotas"].append(quota)
    projected, = projections(diagnose(partial, fixture))
    assert projected["rule_id"] == "rollout_blocked"
    assert "需调整的配额 slots 2→4、guard-slots 3→4" in projected["evidence"]
    assert any(item.startswith("扩配额后的路径 create_new_pod") for item in projected["evidence"])
    for cap, expected in (("3", "rollout_blocked"), ("4", "rollout_reachable")):
        for quota in partial["quotas"][:2]:
            quota["spec"]["hard"]["pods"] = cap
            quota["status"]["hard"]["pods"] = cap
        replayed, = projections(diagnose(partial, fixture))
        assert replayed["rule_id"] == expected, replayed
print(f"{len(mutations)} invalid/unsupported inputs and {len(percentage_cases)} percentage policies passed")
print(f"{len(history_mutations) + 5} historical ReplicaSet cases passed")
print(f"{len(quota_cases) + len(quota_mutations)} overlapping pods quota cases passed")
print("Minimum quota plan and its adjacent cap replays passed")
