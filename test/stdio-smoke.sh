#!/bin/sh
# Verify real NeLisp pipe framing, model switching, completion, and flushing.

set -eu

test_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$test_dir/.." && pwd)
nelisp_bin=${NELISP_BIN:-"$project_dir/../nelisp/target/nelisp"}
fixture="$test_dir/stdio-worker-fixture.el"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

if [ ! -x "$nelisp_bin" ]; then
    printf 'missing NeLisp executable: %s\n' "$nelisp_bin" >&2
    exit 1
fi

cd "$project_dir"
printf '%s\n' \
    '(status)' \
    '(chat "hello")' \
    '(switch "fixture/beta")' \
    '(chat "continue")' \
    '(status) (quit)' \
    '(quit)' \
    | "$nelisp_bin" --load "$fixture" > "$work_dir/out.txt"

line_count=$(grep -c . "$work_dir/out.txt" || true)
[ "$line_count" -eq 7 ]
grep -q ':model "fixture/alpha"' "$work_dir/out.txt"
grep -q ':text "alpha:1"' "$work_dir/out.txt"
grep -q ':kind switched.*:model "fixture/beta"' "$work_dir/out.txt"
grep -q ':text "beta:3"' "$work_dir/out.txt"
grep -q ':kind protocol.*exactly one form' "$work_dir/out.txt"
grep -q '^nl-agent-service-eof$' "$work_dir/out.txt"

# Keep stdin open after the first request: output must arrive before exit so a
# supervising host can use this as an interactive worker.
( printf '%s\n' '(status)'; sleep 2; printf '%s\n' '(quit)' ) \
    | "$nelisp_bin" --load "$fixture" > "$work_dir/flush.txt" &
worker_pid=$!
sleep 1
early_bytes=$(wc -c < "$work_dir/flush.txt" | tr -d ' ')
wait "$worker_pid"
[ "$early_bytes" -gt 0 ]

printf 'NL-AGENT-STDIO-SMOKE PASS (%s early bytes)\n' "$early_bytes"
