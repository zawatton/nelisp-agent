# Development handoff to Claude — 2026-09-21

## Start here

Continue development in `dev/nelisp-agent`, an independent repository in the
Notes workspace. Read the applicable workspace and `dev/` instructions first.
Then read this file and [the bulk delegation policy](bulk-policy.md), whose
opening section summarises every measurement and names the section that
establishes it. Read [the architecture](nelisp-cloud-local-ai-architecture.org)
and [the bulk-reader report](bulk-reader.md) as needed; the architecture was
moved here from `dev/nelisp/docs`, so use this copy.

The objective is unchanged: reduce total cost per validated result by
separating high-capability reasoning from bounded local execution. A shorter
main-model context alone does not establish an improvement. Prefer
deterministic reads and transformations whenever they can do the job.

Communicate with the user in concise Japanese. Keep repository documentation,
comments and docstrings in English. Routine implementation decisions and fixes
should proceed without repeated confirmation.

## State of the checkout

HEAD is `761b1f8` and the tree is clean; `origin/main` matches. The previous
handoff's three uncommitted files were committed long ago — do not go looking
for them.

Use source-preferred loading as in the Makefile. A stale `.elc` will silently
give you an old constant: a measurement script run with `-L lisp` alone read
`min-source-bytes` as 8192 instead of 3072 and split a table at the wrong
point. Pass `--eval '(setq load-prefer-newer t)'` in scratch scripts too, and
read the "newer than byte-compiled file" warning when it appears.

Use relative paths or environment variables in code and scratch scripts, never
machine paths.

## Completed work

The previous handoff's five-item milestone is **complete**. Do not restart it.

| Item | Where it landed |
| --- | --- |
| Frozen cases kept; cases for multiple facts, absence, conflict, quoted instructions | `bulk-policy-corpus.sexp`, `bulk-excluded-corpus.sexp`; the frozen corpus hash is checked on every load |
| Explicit host-side policy, direct by default, opt-in delegation, recorded reasons | `lisp/nl-agent-bulk-policy.el`, admission rules in fixed order |
| Schema validity, completeness diagnostics and manual review kept separate | diagnostic codes with per-screen severity; results stay `needs-review` |
| Explicit bounded fallback recording all costs | fallback and accounting in the policy arms |
| The changed path compared against direct reads | the canonical evaluation, 20 cases, both arms |

Four more corpora were added since: `bulk-dense`, `bulk-table`, `bulk-en`,
`bulk-nonnumeric` for screen calibration, plus `bulk-sizes` (the size ladder)
and `bulk-spread` (two facts near and far apart), both of which are now part
of the canonical evaluation or its tests.

## What the measurements show

Read `bulk-policy.md` for the evidence. In brief, and every figure is UTF-8
bytes of the exact messages sent — no token counts, no prices:

- **Source size decides whether delegation can pay.** Split at
  `min-source-bytes` (3072, itself measured), the same 20-case run gives
  main-model input at 144% of a direct read below the threshold — no price
  ratio recovers that — and 20% at or above it, with a break-even ratio of
  1.37. The exact crossing point depends on how much the worker quotes back:
  between 370 B and 1,923 B of source across everything observed.
- **It does not reduce total work.** Combined input is 1.30× a direct read on
  large sources and 3.44× on small ones. It pays only when the two models are
  priced differently.
- **The usable window has an upper edge set by the worker's context**, not by
  the arrangement. At the host default of 4096 tokens the window is roughly
  2 KB to 10 KB; at `OLLAMA_CONTEXT_LENGTH=16384` a 24 KB source was answered
  correctly at both ends.
- **Oversized prompts are truncated silently** — a server-side warning and a
  normal 200. A mildly truncated prompt still answers coherently from an
  incomplete source, and its citation verifies, because verification reads the
  file rather than whatever the worker was shown. `:max-request-bytes` exists
  to refuse before the call; it is unset by default because the right value is
  the worker's context and this code path cannot ask for it.
- **Citation discipline, not comprehension, was the cost driver.** Workers
  answered correctly and padded their citation lists; discarding those results
  cost the worker *and* the direct read. Repairing them took one worker from
  two rejections in five to none and its break-even ratio from 4.23 to 1.70.
- **Two question kinds are refused rather than screened**, on eight examples —
  with the limit found later that an 8B main model fails those sources
  directly too. The exclusion avoids paying a worker for an answer that will
  be wrong either way; it does not buy a right one.

Nothing here establishes a production threshold, a cloud saving or a ranking
of models. Every model measured is small and local. Read "Not measured" before
quoting any of it.

## Invariants to preserve

Bounded file access: at most eight files, 64 KiB per file, 128 KiB aggregate,
strict UTF-8, workspace/path/symlink restrictions. The host validates the
worker JSON schema and ranges, constructs exact excerpts and checks hashes on
re-fetch. Valid references do not prove semantic correctness. Results stay
`needs-review` with `semantic-validation` set to `unverified`. The serialized
tool result must fit its 3,500-character bound inside the runtime's
4,000-character observation boundary.

Four rules in the reader were each forced by a measurement and should not be
relaxed without one:

- A reference that cannot be verified is dropped and counted, **but if none
  survives and the answer claims a find, the result still fails.** Repairing a
  wholly invented citation list into a success would invert what this module
  is for.
- At most two references per path, and **per path** matters: a global cap drops
  whole files and turns a correct multi-file answer into a coverage rejection.
- No reference may span more than half its source, with a floor of 8 lines so
  the fraction does not reject ordinary citations of small files. A citation
  covering its file points at nothing and made the delegated prompt 109% of
  the direct one.
- The fabrication diagnostic fires only on invented citations, never on the
  reader's own budgets. Mixing them teaches a host to ignore the code.

Host APIs are trusted entry points; the allowlist is not an OS or network
sandbox. Registration grants neither permission nor routing.

Current decision: keep bulk reading optional. Do not enable automatic
delegation by default or label its answers verified.

## Recommended next milestone

This is a proposed scope, not a claim that it exists: **measure the regime
that pays, at the sizes where it pays.**

Every table argues that the larger the source the better delegation looks,
with `r*` falling towards 1.01 — and the largest source ever measured is
9.9 KB, because the worker's default context stops there. The asymptote is a
fit over material no worker in these runs could read. Either it holds and this
mechanism has a clear home, or it does not and the honest conclusion is that
the payable window is narrow.

1. Raise the worker context deliberately and record how (`OLLAMA_CONTEXT_LENGTH`
   is a server setting, not a request field) with the memory cost measured, not
   assumed. Set `:max-request-bytes` to match and check it refuses rather than
   letting the server cut.
2. Extend the ladder to roughly 16, 32 and 64 KB, keeping the existing shape:
   one buried fact, filler carrying no rival values, the fact's depth held
   constant so size is the only moving variable.
3. Measure `D`, `M`, `W` and answer correctness at each size, and check whether
   `M` stays flat as it did to 8.5 KB. If it grows, the asymptote argument
   fails and the guide should say so.
4. Watch for silent truncation at every size: compare the server log against
   the results, and treat a run with a truncation warning as void rather than
   as data.
5. Report the crossing point and `r*` per size as the existing tables do, and
   revise the summary at the top of `bulk-policy.md` rather than appending
   another section beside a stale claim.

Acceptance: the size ladder extends past 10 KB with every run free of
truncation warnings; `M`'s behaviour at those sizes is stated from measurement;
the guide's asymptote claim is either supported or withdrawn. A negative result
is acceptable and is the point. Keep changes scoped.

Two smaller things worth doing if the above stalls: every main-model
measurement used a local 8B model, so whether a frontier main clears the
excluded kinds is unknown and would change the exclusion's rationale; and every
corpus is synthetic, so a run against real `capture/` material would test
external validity, subject to the user's decision about their own data.

## Verification and re-run

From the repository root, with sibling `nelisp-llm` and `nelisp-photon`
checkouts:

```sh
make test-bulk-reader        # 33 ERT tests
make test-bulk-policy        # 74
make test-bulk-policy-eval   # 22
make test-semantic-eval      # 9
make compile                 # warning-as-error
```

All pass at `761b1f8`, and the frozen corpus hash is
`13a0c00f4bc1b49afaae896fd678628c98a28a8371712b042cf59d0b375e4f40`. This is
focused host-side validation, not a claim that the full standalone NeLisp
suite passed.

Changes to the reader or the policy should be covered by a mutation run, not
only by green tests: disable each check in turn and confirm exactly the
matching test turns red, then restore and verify the module is byte-identical.
Twenty-nine mutations currently cover these two modules. Two of them found
gaps in the tests rather than confirming them, which is the point of running
them.

The default evaluation is a deterministic stub. For real local inference, with
a running loopback Ollama service:

```sh
NELISP_AGENT_BULK_EVAL_LIVE=1 \
NELISP_AGENT_BULK_EVAL_WORKER_SELECTOR=local/llama3.2:3b \
NELISP_AGENT_BULK_EVAL_WORKER_TIMEOUT=240 \
emacs -Q --batch --eval '(setq load-prefer-newer t)' \
  -L lisp -L ../nelisp-llm/lisp -L ../nelisp-photon/lisp \
  -l examples/evaluate-bulk-policy.el \
  -f nl-agent-example-evaluate-bulk-policy-main \
  -- --output <path>/report.sexp
```

Keep previous reports instead of overwriting them, and check that a report is
live before comparing it with one: a `stub` report records fabricated answers
that look plausible in a diff. Read the actual answers and excerpts; process
exit success and `usable` status do not establish accuracy.

## Completion reporting

Report changed behaviour, relevant tests, measured results and limitations in
Japanese. Follow the workspace DB-primary worklog process (`worklog-add`); do
not append to legacy `capture/ai-logs-*` or edit user journals. The most recent
completion worklog digest is `2cddb1b67def4bf0c20a9ccbf648fe7834c24954`.
