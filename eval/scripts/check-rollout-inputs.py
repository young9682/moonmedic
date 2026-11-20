"""Incomplete or inconsistent evidence must never produce a rollout projection."""
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
    (("deployment", "spec", "strategy", "rollingUpdate", "maxSurge"), "25%"),
]
with TemporaryDirectory() as folder:
    fixture = Path(folder) / "input.json"
    for path, value in mutations:
        case = deepcopy(base)
        target = case
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value
        fixture.write_text(json.dumps(case), encoding="utf-8")
        result = run(["moon", "run", "cmd/main", "--", "--snapshot", str(fixture), "--json"],
                     cwd=root, check=True, capture_output=True, encoding="utf-8")
        diagnosis = json.loads(result.stdout)
        if any(f["layer"] == "projection" for f in diagnosis["findings"]) or not any(
            "滚动发布路径未判定" in note for note in diagnosis["notes"]
        ):
            raise AssertionError(f"inconsistent input accepted: {path}")
print(f"{len(mutations)} incomplete/unsupported inputs correctly declined")
