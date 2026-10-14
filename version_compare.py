"""Compare Kubernetes module versions embedded in the built plugin binaries."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys


def isolation(module_file):
    source = module_file.read_text()
    declarations = re.findall(r"use_extension\((.*?)\)", source, re.DOTALL)
    go_deps = [declaration for declaration in declarations if '"go_deps"' in declaration]
    if len(go_deps) != 1:
        raise ValueError(f"Expected one go_deps declaration in {module_file}")
    return bool(re.search(r"\bisolate\s*=\s*True\b", go_deps[0]))


def report(runfiles_root, go_path, plugins):
    go = runfiles_root / go_path
    env = dict(os.environ, GOROOT=str(go.parent.parent), GOTOOLCHAIN="local")
    results = []
    for name, binary, module_file in plugins:
        metadata = json.loads(subprocess.check_output(
            [str(go), "version", "-json", "-m", str(runfiles_root / binary)],
            text=True,
            env=env,
        ))
        modules = {}
        for dependency in metadata.get("Deps", []):
            path = dependency["Path"]
            # Include api, apimachinery, apiextensions-apiserver, kube-openapi,
            # and any other linked k8s.io module whose path contains "api".
            if path.startswith("k8s.io/") and "api" in path.removeprefix("k8s.io/"):
                selected = dependency.get("Replace") or dependency
                modules[path] = selected.get("Version") or "(local replacement)"
        results.append((name, isolation(runfiles_root / module_file), metadata["GoVersion"], modules))

    headers = ["Module"] + [name for name, _, _, _ in results]
    rows = [
        ["Isolation"] + [str(enabled) for _, enabled, _, _ in results],
        ["Go compiler"] + [version for _, _, version, _ in results],
    ]
    for module in sorted({module for _, _, _, modules in results for module in modules}):
        rows.append([module] + [modules.get(module, "—") for _, _, _, modules in results])
    widths = [max(len(row[column]) for row in [headers] + rows) for column in range(len(headers))]
    for row in [headers, ["-" * width for width in widths]] + rows:
        print("  ".join(value.ljust(width) for value, width in zip(row, widths)).rstrip())
    print("\n— = module is not linked into this binary")


if __name__ == "__main__":
    arguments = sys.argv[1:]
    if len(arguments) < 5 or (len(arguments) - 2) % 3:
        sys.exit("Expected runfiles root, Go binary, and plugin/binary/MODULE.bazel triples")
    try:
        report(Path(arguments[0]), arguments[1], [arguments[i:i + 3] for i in range(2, len(arguments), 3)])
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"version-compare: {error}")
