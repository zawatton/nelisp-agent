#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(dirname -- "$test_dir")
output=$(sh "$project_root/bin/nelisp-agent" --help)

case "$output" in
  *"Usage: kaji"*"--improvement-config FILE"*"--autonomous-improvement"*"--unattended"*"/model SELECTOR"*)
    printf '%s\n' "NL-AGENT-CLI-SMOKE PASS"
    ;;
  *)
    printf '%s\n' "NL-AGENT-CLI-SMOKE FAIL"
    exit 1
    ;;
esac
