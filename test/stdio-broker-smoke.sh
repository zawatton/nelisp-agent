#!/bin/sh
# Verify nested host inference RPC, correlation, fallback, and event flushing.

set -eu

test_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$test_dir/.." && pwd)
nelisp_bin=${NELISP_BIN:-"$project_dir/../nelisp/target/nelisp"}
fixture="$test_dir/stdio-broker-worker-fixture.el"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

if [ ! -x "$nelisp_bin" ]; then
    printf 'missing NeLisp executable: %s\n' "$nelisp_bin" >&2
    exit 1
fi

cd "$project_dir"
printf '%s\n' \
    '(chat "hello")' \
    '(inference-error 1 "primary unavailable")' \
    '(inference-result 2 "fallback reply")' \
    '(status)' \
    '(quit)' \
    | "$nelisp_bin" --load "$fixture" > "$work_dir/roundtrip.txt"

line_count=$(grep -c . "$work_dir/roundtrip.txt" || true)
[ "$line_count" -eq 6 ]
grep -q ':event inference.*:request-id 1.*:model "primary"' \
    "$work_dir/roundtrip.txt"
grep -q ':event inference.*:request-id 2.*:model "fallback"' \
    "$work_dir/roundtrip.txt"
grep -q ':kind completion.*:model "remote/fallback".*:text "fallback reply"' \
    "$work_dir/roundtrip.txt"
grep -q ':kind status.*:model "remote/fallback".*:message-count 2' \
    "$work_dir/roundtrip.txt"
grep -q '^nl-agent-service-eof$' "$work_dir/roundtrip.txt"

# A real host cannot answer until it sees the inference event.  Keep the input
# pipe open and prove that the event is flushed before supplying its result.
request_pipe="$work_dir/request.pipe"
mkfifo "$request_pipe"
"$nelisp_bin" --load "$fixture" \
    < "$request_pipe" > "$work_dir/interactive.txt" &
worker_pid=$!
exec 3> "$request_pipe"
printf '%s\n' '(chat "interactive")' >&3
sleep 1
early_bytes=$(wc -c < "$work_dir/interactive.txt" | tr -d ' ')
grep -q ':event inference.*:request-id 1.*:model "primary"' \
    "$work_dir/interactive.txt"
printf '%s\n' '(inference-result 1 "interactive reply")' >&3
printf '%s\n' '(quit)' >&3
exec 3>&-
wait "$worker_pid"
[ "$early_bytes" -gt 0 ]
grep -q ':kind completion.*:text "interactive reply"' \
    "$work_dir/interactive.txt"

# The shipped free-model worker must load through the same standalone path; the
# endpoint and credentials remain entirely on the host side.
printf '%s\n' \
    '(startup-config-result 1 nil)' \
    '(model-catalog-result 2 ((:provider "remote" :id "poolside/laguna-s-2.1:free") (:provider "remote" :id "meituan/longcat-2.0:free") (:provider "remote" :id "poolside/laguna-xs-2.1:free")))' \
    '(tool-catalog-result 3 ())' \
    '(chat "hello")' \
    '(inference-result 4 "free reply")' \
    '(quit)' \
    | "$nelisp_bin" --load examples/free-models-worker.el \
        > "$work_dir/free-models.txt"
grep -q ':event startup-config.*:request-id 1' \
    "$work_dir/free-models.txt"
grep -q ':event model-catalog.*:request-id 2' \
    "$work_dir/free-models.txt"
grep -q ':event tool-catalog.*:request-id 3' \
    "$work_dir/free-models.txt"
grep -q ':event ready' "$work_dir/free-models.txt"
grep -q ':event inference.*:model "poolside/laguna-s-2.1:free"' \
    "$work_dir/free-models.txt"
grep -q ':kind completion.*:text "free reply"' \
    "$work_dir/free-models.txt"

printf 'NL-AGENT-BROKER-STDIO-SMOKE PASS (%s early bytes)\n' "$early_bytes"
