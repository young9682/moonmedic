"""Run real CLIs against the same read-only snapshot API on loopback."""

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from urllib.parse import parse_qs, unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]
SCENARIOS = (
    "e01-quota-zero-pods", "e02-quota-partial-pods", "r01-quota-missing-resources",
    "r02-generic-validation", "r03-webhook-with-saturation", "r04-unmatched-quota",
)
ROLLOUT_SCENARIOS = (
    "rollout-a-full", "rollout-b-more-surge", "rollout-c-retire-first",
    "rollout-d-extra-slot", "rollout-e-external-release",
)
RESOURCES = {
    "v1": {
        "namespaces": ("Namespace", None),
        "pods": ("Pod", "pods"),
        "events": ("Event", "events"),
        "resourcequotas": ("ResourceQuota", "quotas"),
        "limitranges": ("LimitRange", "limit_ranges"),
    },
    "apps/v1": {
        "deployments": ("Deployment", "deployment"),
        "replicasets": ("ReplicaSet", "replicasets"),
    },
}
HOLMES_PROJECTIONS = {
    "deployments": ".items[] | {name: .metadata.name, uid: .metadata.uid, desired: .spec.replicas, available: .status.availableReplicas}",
    "replicasets": ".items[] | {name: .metadata.name, uid: .metadata.uid, owners: .metadata.ownerReferences, conditions: .status.conditions}",
    "pods": ".items[] | {name: .metadata.name, owners: .metadata.ownerReferences, phase: .status.phase}",
    "resourcequotas": ".items[] | {name: .metadata.name, used: .status.used, hard: .status.hard}",
    "events": '.items[] | select(.reason == "FailedCreate") | {object: .involvedObject.name, reason, message}',
}
ROLLOUT_PROJECTIONS = {
    "deployments": ".items[] | {name: .metadata.name, uid: .metadata.uid, desired: .spec.replicas, strategy: .spec.strategy, template: .spec.template.metadata.labels, available: .status.availableReplicas}",
    "replicasets": ".items[] | {name: .metadata.name, uid: .metadata.uid, owners: .metadata.ownerReferences, template: .spec.template.metadata.labels, desired: .spec.replicas, actual: .status.replicas, available: .status.availableReplicas}",
    "pods": ".items[] | {name: .metadata.name, owners: .metadata.ownerReferences, deleting: .metadata.deletionTimestamp, phase: .status.phase}",
    "resourcequotas": HOLMES_PROJECTIONS["resourcequotas"],
    "events": ".items[] | {reason, message}",
}
# Explicit columns keep missing fixture fields visible and avoid deriving RS membership
# from selectors that the compact snapshots do not contain.
ROLLOUT_COLUMNS = {
    "deployments": "NAME:.metadata.name,DESIRED:.spec.replicas,SURGE:.spec.strategy.rollingUpdate.maxSurge,UNAVAILABLE:.spec.strategy.rollingUpdate.maxUnavailable,AVAILABLE:.status.availableReplicas",
    "replicasets": "NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].uid,VERSION:.spec.template.metadata.labels.version,DESIRED:.spec.replicas,ACTUAL:.status.replicas,AVAILABLE:.status.availableReplicas",
    "pods": "NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].uid,DELETING:.metadata.deletionTimestamp,PHASE:.status.phase",
    "resourcequotas": "NAME:.metadata.name,USED:.status.used.pods,HARD:.status.hard.pods",
    "events": "REASON:.reason,MESSAGE:.message",
}


class InvalidSelector(ValueError):
    pass


def field(obj, key):
    for part in key.split("."):
        obj = obj.get(part, {}) if isinstance(obj, dict) else {}
    return str(obj) if not isinstance(obj, dict) else ""


def selected(item, expression, prefix=""):
    for term in expression.split(","):
        if not term:
            continue
        if "!=" in term:
            key, value = term.split("!=", 1)
            if field(item, prefix + key) == value:
                return False
        elif "=" in term:
            key, value = term.split("=", 1)
            if field(item, prefix + key) != value.lstrip("="):
                return False
    return True


class SnapshotAPI:
    def __init__(self, snapshot):
        self.snapshot = snapshot
        self.namespace = snapshot["ns"]
        self.trace = []

    def read(self, raw_path):
        url = urlsplit(raw_path)
        path = unquote(url.path).rstrip("/")
        query = parse_qs(url.query)
        if path == "/version":
            return {"major": "1", "minor": "33", "gitVersion": "v1.33.0"}
        if path == "/api":
            return {"apiVersion": "v1", "kind": "APIVersions", "versions": ["v1"]}
        apps = {"name": "apps", "versions": [{"groupVersion": "apps/v1", "version": "v1"}],
                "preferredVersion": {"groupVersion": "apps/v1", "version": "v1"}}
        if path == "/apis":
            return {"apiVersion": "v1", "kind": "APIGroupList", "groups": [apps]}
        if path == "/apis/apps":
            return {"apiVersion": "v1", "kind": "APIGroup", **apps}
        for group_version, resources in RESOURCES.items():
            base = "/api/v1" if group_version == "v1" else "/apis/apps/v1"
            if path == base:
                return {"apiVersion": "v1", "kind": "APIResourceList", "groupVersion": group_version,
                        "resources": [
                            {"name": name, "kind": kind, "namespaced": key is not None,
                             "singularName": kind.lower(), "verbs": ["get", "list"]}
                            for name, (kind, key) in resources.items()
                        ]}
            if not path.startswith(base + "/"):
                continue
            parts = path[len(base) + 1:].split("/")
            if parts[0] == "namespaces" and len(parts) >= 3:
                if parts[1] != self.namespace:
                    return None
                parts = parts[2:]
            if len(parts) > 2 or parts[0] not in resources:
                return None
            kind, key = resources[parts[0]]
            data = self.snapshot.get(key, []) if key else {
                "metadata": {"name": self.namespace}, "status": {"phase": "Active"},
            }
            items = data if isinstance(data, list) else [data]
            items = [dict(item, apiVersion=group_version, kind=kind) for item in items if item]
            if len(parts) == 2:
                return next((item for item in items if field(item, "metadata.name") == parts[1]), None)
            for selector in ("fieldSelector", "labelSelector"):
                value = query.get(selector, [""])[0]
                if any("=" not in term for term in value.split(",") if term):
                    raise InvalidSelector(f"Unsupported {selector}: {value}")
            items = [item for item in items
                     if selected(item, query.get("fieldSelector", [""])[0])
                     and selected(item, query.get("labelSelector", [""])[0], "metadata.labels.")]
            return {"apiVersion": group_version, "kind": kind + "List",
                    "metadata": {"resourceVersion": "1"}, "items": items}
        return None


def server_for(api):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            try:
                result = api.read(self.path)
                status, reason, message = (200, "", "") if result is not None else (
                    404, "NotFound", "Not represented in snapshot",
                )
            except InvalidSelector as err:
                status, reason, message = 400, "BadRequest", str(err)
            if status != 200:
                result = {"apiVersion": "v1", "kind": "Status", "status": "Failure",
                          "reason": reason, "message": message, "code": status}
            api.trace.append({"method": "GET", "path": self.path, "status": status})
            content = json.dumps(result).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        def log_message(self, *_):
            pass

    return ThreadingHTTPServer(("127.0.0.1", 0), Handler)


def put_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def as_text(value):
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else (value or "")


def execute(command, env, api, timeout=180):
    api.trace.clear()
    try:
        process = subprocess.run(
            [str(arg) for arg in command], env=env, cwd=ROOT, stdin=subprocess.DEVNULL,
            capture_output=True, timeout=timeout, text=True, encoding="utf-8", errors="replace",
        )
        record = {"exit_code": process.returncode, "stdout": process.stdout, "stderr": process.stderr}
    except subprocess.TimeoutExpired as err:
        record = {"exit_code": None, "stdout": as_text(err.stdout),
                  "stderr": as_text(err.stderr), "timeout": timeout}
    return {**record, "requests": list(api.trace)}


def compare(case, args):
    fixture = ROOT / "eval" / "fixtures" / (case + ".snapshot.json")
    raw = fixture.read_bytes()
    api = SnapshotAPI(json.loads(raw))
    rollout = case in ROLLOUT_SCENARIOS
    server = server_for(api)
    worker = Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix="moonmedic-baseline-") as folder:
            folder = Path(folder)
            address = f"http://127.0.0.1:{server.server_port}"
            kubeconfig = folder / "kubeconfig.json"
            put_json(kubeconfig, {
                "apiVersion": "v1", "kind": "Config",
                "clusters": [{"name": "snapshot", "cluster": {"server": address}}],
                "contexts": [{"name": "snapshot", "context": {
                    "cluster": "snapshot", "user": "snapshot", "namespace": api.namespace,
                }}],
                "users": [{"name": "snapshot", "user": {}}], "current-context": "snapshot",
            })
            env = {k: v for k, v in os.environ.items() if k.upper() in {
                "PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "TEMP", "TMP",
                "USERPROFILE", "LOCALAPPDATA", "APPDATA", "PROGRAMDATA", "HOMEDRIVE", "HOMEPATH",
            }}
            env.update(KUBECONFIG=str(kubeconfig), PYTHONUTF8="1", NO_PROXY="127.0.0.1,localhost",
                       DO_NOT_TRACK="1", MSYS_NO_PATHCONV="1")
            name = api.snapshot["target_name"]
            records = {"fixture_sha256": hashlib.sha256(raw).hexdigest(), "namespace": api.namespace,
                       "target": name, "tools": {}}
            if "kubectl" in args.tools:
                commands = [
                    ("pods", ["get", "pods", "-o", "name"]),
                    ("deployment", ["describe", "deployment", name]),
                    ("replicasets", ["describe", "replicasets"]),
                    ("quota", ["describe", "resourcequotas"]),
                    ("events", ["get", "events", "-o", "json"]),
                ]
                if rollout:
                    commands = [(kind, ["get", kind, "-o", "custom-columns=" + columns])
                                for kind, columns in ROLLOUT_COLUMNS.items()]
                prefix = [args.kubectl, "--kubeconfig", kubeconfig, "--cache-dir", folder / "cache",
                          "--request-timeout=10s", "-n", api.namespace]
                records["tools"]["kubectl"] = {
                    key: execute(prefix + command, env, api) for key, command in commands
                }
            if "k8sgpt" in args.tools:
                config = folder / "k8sgpt.yaml"
                config.write_text("{}\n", encoding="utf-8")
                records["tools"]["k8sgpt"] = execute([
                    args.k8sgpt, "analyze", "--config", config, "--kubeconfig", kubeconfig,
                    "--namespace", api.namespace, "--filter", "Pod,ReplicaSet,Deployment",
                    "--output", "json", "--no-cache",
                ], env, api)
            if "holmes" in args.tools:
                records["tools"]["holmes"] = run_holmes(args, api, env, folder, rollout)
            if "moonmedic" in args.tools:
                records["tools"]["moonmedic"] = execute([
                    "moon", "run", "cmd/main", "--", "--snapshot", fixture, "--json",
                ], env, api)
            put_json(args.output / (case + ".json"), records)
            print(f"{case}: {', '.join(records['tools'])}", flush=True)
            results = records["tools"]
            commands = [result for name, result in results.items() if name != "kubectl"]
            commands.extend(results.get("kubectl", {}).values())
            if any(command["exit_code"] != 0 for command in commands):
                return False
            return "holmes" not in results or bool(results["holmes"].get("response", {}).get("result"))
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


def run_holmes(args, api, env, folder, rollout):
    config, model_list, response = (folder / f"{name}.json" for name in ("holmes", "model-list", "response"))
    put_json(config, {"toolsets": {"kubernetes/core": {"enabled": True}}})
    put_json(model_list, {"benchmark": {"model": f"openai/{args.model}",
                                        "api_base": args.model_url, "api_key": "local",
                                        "custom_args": {"temperature": 0, "max_tokens": 750}}})
    env.update(MODEL_LIST_FILE_LOCATION=str(model_list), LITELLM_LOCAL_MODEL_COST_MAP="True",
               LITELLM_LOCAL_ANTHROPIC_BETA_HEADERS="True", OPENAI_API_KEY="local")
    if args.jq:
        env["PATH"] = str(Path(args.jq).resolve().parent) + os.pathsep + env["PATH"]
    prompt = (
        f"Investigate Deployment {api.snapshot['target_name']} in namespace {api.namespace}. "
        "Use read-only Kubernetes tools. List deployments, replicasets, pods, resourcequotas, "
        "and events in this small namespace using those exact plural resource names. "
        "Omit label_selector, field_selector and filter. Project only useful fields from .items[] "
        "with kubernetes_jq_query; keep original creation failure messages. "
        "Report desired replicas, the observed number of owned Pods, "
        "the creation failure and evidence, and if applicable the relevant ResourceQuota name, "
        "resource, current used/hard, and the quota increase for missing replicas. "
        "Distinguish observed facts from conclusions, state missing evidence, and keep the final answer under 180 words."
    )
    projections = HOLMES_PROJECTIONS
    if rollout:
        projections = ROLLOUT_PROJECTIONS
        prompt = (
            f"Investigate Deployment {api.snapshot['target_name']} in namespace {api.namespace}. "
            "Use read-only kubernetes_jq_query on deployments, replicasets, pods, resourcequotas and events. "
            "Using this snapshot and its current strategy and quota, can the rollout finish with all desired "
            "new replicas available and all old replicas gone? Assume newly created Pods can become available "
            "and deletion eventually frees their slots. Other workloads stay unchanged except Pods already deleting. "
            "Give the evidence and a feasible order of actions, or explain what prevents completion. "
            "Identify any dependency on another workload. Separate observed state from possible next steps. "
            "Answer in under 180 words."
        )
    if args.holmes_fixed_queries:
        prompt += (
            f" For a controlled acquisition check use namespace {api.namespace} for every call. "
            "Copy these jq_expr values verbatim and do not add filters:\n"
            + "\n".join(f"{kind}: {projection}" for kind, projection in projections.items())
        )
    command = [args.holmes, Path(__file__).with_name("holmes-baseline.py"), args.git_bash or ""]
    if args.git_bash:
        git_usr_bin = Path(args.git_bash).resolve().parent.parent / "usr" / "bin"
        env["PATH"] = str(git_usr_bin) + os.pathsep + env["PATH"]
    command += ["ask", prompt, "--config", config, "--model", "benchmark",
                "--max-steps", "12", "--no-interactive", "--no-echo", "--bash-always-deny",
                "--json-output-file", response]
    output = execute(command, env, api, timeout=420)
    output["prompt"] = prompt
    if response.exists():
        output["response"] = json.loads(response.read_text(encoding="utf-8"))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tools", nargs="+", choices=["kubectl", "k8sgpt", "holmes", "moonmedic"],
                        default=["kubectl", "k8sgpt", "holmes", "moonmedic"])
    cases = parser.add_mutually_exclusive_group()
    cases.add_argument("--scenario", action="append", choices=SCENARIOS + ROLLOUT_SCENARIOS)
    cases.add_argument("--suite", choices=["admission", "rollout"], default="admission")
    parser.add_argument("--kubectl", default="kubectl")
    parser.add_argument("--k8sgpt", default="k8sgpt")
    parser.add_argument("--holmes", default="python", help="Python executable of the HolmesGPT environment")
    parser.add_argument("--git-bash", help="Windows Git Bash executable for upstream POSIX tool scripts")
    parser.add_argument("--jq", help="Path to jq executable")
    parser.add_argument("--model", default="qwen3-4b-instruct-2507")
    parser.add_argument("--model-url", default="http://127.0.0.1:18081/v1")
    parser.add_argument("--holmes-fixed-queries", action="store_true",
                        help="Run Holmes again with fixed read-only field projections")
    args = parser.parse_args()
    address = urlsplit(args.model_url)
    if address.scheme != "http" or address.hostname != "127.0.0.1" or address.username:
        parser.error("--model-url must point to an unauthenticated loopback HTTP server")
    args.output.mkdir(parents=True, exist_ok=True)
    scenarios = ROLLOUT_SCENARIOS if args.suite == "rollout" else SCENARIOS
    outcome = [compare(case, args) for case in args.scenario or scenarios]
    if not all(outcome):
        parser.exit(1, "One or more CLI invocations failed. Inspect the saved records.\n")


if __name__ == "__main__":
    main()
