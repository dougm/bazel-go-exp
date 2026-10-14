#!/usr/bin/env bash
set -euo pipefail

# Bazel supplies the runfiles tree; rootpaths are relative to its main workspace.
runfiles_root="${RUNFILES_DIR:-$0.runfiles}/_main"
exec python3 "$runfiles_root/version_compare.py" "$runfiles_root" "$@"
