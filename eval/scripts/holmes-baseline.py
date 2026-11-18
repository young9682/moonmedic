"""Run the upstream Holmes CLI with explicit toolsets and an optional Windows shim."""

import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

from holmes.config import Config
from holmes.core import toolset_manager
from holmes.main import app

create_llm = Config.create_toolcalling_llm
load_builtin = toolset_manager.load_builtin_toolsets


def explicit_toolsets(self, **kwargs):
    # The standalone CLI otherwise auto-enables all toolsets with prerequisites.
    kwargs["enable_all_toolsets_possible"] = False
    return create_llm(self, **kwargs)


def load_kubernetes_only(*args, **kwargs):
    return [toolset for toolset in load_builtin(*args, **kwargs) if toolset.name == "kubernetes/core"]


def route_scripts_to_git_bash(bash):
    original_popen = subprocess.Popen

    class GitBashPopen(original_popen):
        def __init__(self, args, *positional, **kwargs):
            if kwargs.get("executable") == "/bin/bash" and kwargs.get("shell"):
                kwargs["shell"] = False
                kwargs.pop("executable")
                # Convert only generated temporary tool scripts to LF.
                prefix, separator, script = args.rpartition("; ")
                path = Path(script)
                temp = Path(tempfile.gettempdir()).resolve()
                if path.is_absolute() and path.suffix == ".sh" and path.resolve().is_relative_to(temp):
                    data = path.read_bytes()
                    path.write_bytes(data.replace(b"\r\n", b"\n"))
                    args = prefix + separator + shlex.quote(path.as_posix())
                args = [bash, "-c", args]
            super().__init__(args, *positional, **kwargs)

    subprocess.Popen = GitBashPopen


bash = sys.argv.pop(1)
if bash:
    route_scripts_to_git_bash(bash)
Config.create_toolcalling_llm = explicit_toolsets
toolset_manager.load_builtin_toolsets = load_kubernetes_only
app()
