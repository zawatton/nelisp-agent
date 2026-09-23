#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
before=$(git -C "$repo" worktree list --porcelain)
output=$("$repo/tools/calibrate-bulk-policy.sh" HEAD)
after=$(git -C "$repo" worktree list --porcelain)

test "$before" = "$after"
printf '%s\n' "$output" | grep -F 'baseline ref: HEAD' >/dev/null
test "$(printf '%s\n' "$output" | grep -c 'fires (10 of 42 cases)')" -eq 2
printf '%s\n' "$output" | grep -F 'missing from working tree: none' >/dev/null
printf '%s\n' "$output" | grep -F 'added in working tree: none' >/dev/null
printf '%s\n' "$output" | grep -F 'changed in working tree: none' >/dev/null

if "$repo/tools/calibrate-bulk-policy.sh" refs/heads/no-such-calibration-ref \
    >/dev/null 2>&1; then
    printf '%s\n' 'invalid baseline ref unexpectedly succeeded' >&2
    exit 1
fi
test "$before" = "$(git -C "$repo" worktree list --porcelain)"

failing_emacs=$(mktemp)
trap 'rm -f "$failing_emacs"' EXIT HUP INT TERM
printf '%s\n' '#!/bin/sh' 'exit 7' >"$failing_emacs"
chmod +x "$failing_emacs"
if EMACS="$failing_emacs" "$repo/tools/calibrate-bulk-policy.sh" HEAD \
    >/dev/null 2>&1; then
    printf '%s\n' 'failing evaluator unexpectedly succeeded' >&2
    exit 1
fi
rm -f "$failing_emacs"
trap - EXIT HUP INT TERM
test "$before" = "$(git -C "$repo" worktree list --porcelain)"

printf '%s\n' 'bulk-policy calibration test: PASS'
