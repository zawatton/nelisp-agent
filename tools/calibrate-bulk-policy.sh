#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
baseline_ref=${1:-HEAD}
parent=$(dirname -- "$repo")
baseline_dir=
baseline_output=
working_output=
baseline_keys=
working_keys=
worktree_added=false

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$worktree_added" = true ]; then
        if ! git -C "$repo" worktree remove --force "$baseline_dir" >/dev/null 2>&1; then
            printf 'failed to remove calibration worktree: %s\n' "$baseline_dir" >&2
            status=1
        fi
    fi
    for temporary in "$baseline_output" "$working_output" "$baseline_keys" "$working_keys"; do
        if [ -n "$temporary" ] && ! rm -f "$temporary"; then
            status=1
        fi
    done
    if [ -n "$baseline_dir" ] && [ -d "$baseline_dir" ] && ! rmdir "$baseline_dir"; then
        printf 'failed to remove calibration directory: %s\n' "$baseline_dir" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

baseline_dir=$(mktemp -d "$parent/.nelisp-agent-calibration.XXXXXX")
rmdir "$baseline_dir"
baseline_output=$(mktemp)
working_output=$(mktemp)
baseline_keys=$(mktemp)
working_keys=$(mktemp)

git -C "$repo" worktree add --quiet --detach "$baseline_dir" "$baseline_ref"
worktree_added=true

run_arm() {
    root=$1
    output=$2
    NL_AGENT_CALIBRATION_ROOT=$root "${EMACS:-emacs}" -Q --batch \
        --eval '(setq load-prefer-newer t)' \
        -L "$root/lisp" \
        -L "$root/../nelisp-llm/lisp" \
        -L "$root/../nelisp-photon/lisp" \
        -l "$repo/tools/bulk-policy-calibration.el" >"$output"
    summary=$(tail -n 1 "$output")
    case "$summary" in
        "@summary$(printf '\t')"*) ;;
        *) printf 'invalid calibration summary: %s\n' "$summary" >&2; return 1 ;;
    esac
    arm_total=$(printf '%s\n' "$summary" | cut -f2)
    arm_fires=$(printf '%s\n' "$summary" | cut -f3)
    test "$arm_total" -eq 42
    test "$arm_fires" -ge 0
    awk 'NR > 1 { print previous } { previous = $0 }' "$output" >"$working_keys"
    mv "$working_keys" "$output"
    sort -o "$output" "$output"
}

run_arm "$baseline_dir" "$baseline_output"
baseline_total=$arm_total
baseline_fires=$arm_fires
run_arm "$repo" "$working_output"
working_total=$arm_total
working_fires=$arm_fires

cut -f1,2 "$baseline_output" | sort -u >"$baseline_keys"
cut -f1,2 "$working_output" | sort -u >"$working_keys"

printf 'baseline ref: %s\n' "$baseline_ref"
printf '\n=== baseline fires (%s of %s cases) ===\n' "$baseline_fires" "$baseline_total"
cat "$baseline_output"
printf '\n=== working tree fires (%s of %s cases) ===\n' "$working_fires" "$working_total"
cat "$working_output"
printf '\n=== diff (baseline -> working tree) ===\n'
if cmp -s "$baseline_output" "$working_output"; then
    printf 'no differences\n'
else
    if diff -u "$baseline_output" "$working_output"; then
        :
    else
        diff_status=$?
        test "$diff_status" -eq 1 || exit "$diff_status"
    fi
fi

missing=$(comm -23 "$baseline_keys" "$working_keys")
added=$(comm -13 "$baseline_keys" "$working_keys")
changed=$(awk -F '\t' '
    NR == FNR { baseline[$1 FS $2] = $3; next }
    (($1 FS $2) in baseline) && baseline[$1 FS $2] != $3 { print $1 FS $2 }
' "$baseline_output" "$working_output")

printf '\nmissing from working tree: %s\n' "${missing:-none}"
printf 'added in working tree: %s\n' "${added:-none}"
printf 'changed in working tree: '
if [ -z "$changed" ]; then
    printf 'none\n'
else
    printf '\n%s\n' "$changed"
fi

# A changed tuple is still the same firing case and is reported above.  Only
# losing a baseline corpus/case identity is a failed calibration.
test -z "$missing"
