# Development handoff to Claude — 2026-09-19

## Start here

Continue development in `dev/nelisp-agent`, an independent repository in the
Notes workspace. Read the applicable workspace and `dev/` instructions first.
Then read this file, [the architecture](nelisp-cloud-local-ai-architecture.org),
and [the bulk-reader report](bulk-reader.md). Read other files only as needed.
The architecture was moved here from `dev/nelisp/docs`; use this copy.

The objective is to reduce total cost per validated result by separating
high-capability reasoning from bounded local execution. A shorter main-model
context alone does not establish an improvement. Prefer deterministic reads
and transformations whenever they can do the job.

Communicate with the user in concise Japanese. Keep repository documentation,
comments, and docstrings in English. The user requested lightweight models
(Luna or equivalent) for code implementation, with the lead responsible for
design, review, and validation. If Luna is unavailable in Claude, use an
available lightweight implementation model and state the substitution;
do not claim to have used Luna. Routine implementation decisions and fixes
should proceed without repeated confirmation.

## Preserve the current checkout

At handoff, HEAD was `5a837bd` (`Import the existing NeLisp Agent source under
version control`). These files had uncommitted changes:

- `docs/bulk-reader.md`
- `examples/evaluate-bulk-reader.el`
- `test/bulk-eval-test.el`

This handoff adds another file. Recheck `git status` and diffs before editing;
the checkout may have changed since this snapshot. Preserve existing changes.
Do not assume the repository is still untracked or has no commits.

Local `.elc` files were visible for the evaluation example and its test at
handoff. Use source-preferred loading as in the Makefile; do not rely on stale
compiled files or indiscriminately delete generated/user files. Use relative
paths or environment variables in code and scratch scripts, not machine paths.

## Completed work

The previous bulk-reader goal is complete; do not restart it or report it as
unfinished. Its acceptance criteria were implementation, boundary/failure
tests, a fixed comparison corpus, an honest comparison report, and docs/logs.
The experiment was allowed to conclude that delegation was not beneficial.

| Component | Entry points / documentation | Current contract |
| --- | --- | --- |
| Semantic IR | `lisp/nl-agent-semantic-ir.el`, [IR documentation](semantic-ir.md) | Strict parsing and deterministic rendering |
| Local rendering | `lisp/nl-agent-semantic-render.el`, [rendering](semantic-render.md) | Review-required model output, bounded repair and numeric screening |
| Rendering evaluation | `lisp/nl-agent-semantic-eval.el`, [evaluation](semantic-evaluation.md) | Fixed corpus, per-attempt byte/time metrics; literal checks are proxies |
| Bulk reader | `lisp/nl-agent-bulk-reader.el`, [report](bulk-reader.md) | Read-only worker extraction with host-attached excerpts and hashes |
| Bulk evaluation | `examples/evaluate-bulk-reader.el`, `examples/bulk-reader-corpus.sexp` | Direct and delegated answers on identical questions, with separate main/worker metrics |

Bulk-reader host entry points are `nl-agent-bulk-reader-new`,
`nl-agent-bulk-reader-run`, `nl-agent-bulk-reader-read-range`, and
`nl-agent-bulk-reader-register-tools`. Registered tools are `bulk.read`
(execute risk because it invokes a model) and `bulk.read-range` (read risk).
Use the existing permission system for model-originated calls. Registration
does not grant permission or enable routing.

Preserve bounded file access: at most eight files, 64 KiB per file, 128 KiB
aggregate, strict UTF-8, workspace/path/symlink restrictions. The host validates
the worker JSON schema and ranges, constructs exact excerpts, and checks hashes
on re-fetch. Valid references do not prove semantic correctness. Results stay
`needs-review` with `semantic-validation` set to `unverified`.

The serialized tool result must fit its 3,500-character bound inside the
runtime's 4,000-character observation boundary. Do not truncate references
silently or weaken schema validation to accommodate model output. Host APIs
are trusted entry points; the allowlist is not an OS/network sandbox.

## What the actual experiment showed

The local main model was `llama3.1:8b`; the worker was `llama3.2:3b` with JSON
mode. Five synthetic cases ran once in fixed order. Exact settings, model
digests, review criteria, per-case data, and limitations are in the report.

- Main input: 12,868 to 5,200 UTF-8 message-content bytes, down 59.6%.
- Worker input: 16,678 bytes; combined input: 21,878 bytes, up 70.0%.
- Technical failures: 0/5 in both paths. Technical success is not correctness.
- Delegated answers omitted June 18 in the multi-file case and substituted
  a general telephone number for a mobile number explicitly absent from the
  source. Three delegated answers fully satisfied the rubric; two failed.
- Direct answers fully satisfied four cases; the quoted-instruction case
  refused execution but supplied only a terse source-line explanation.
- The large-source case reduced main input by 89.0%, but increased combined
  input by 18.8% and took longer. Every small case increased main input.

Token counts, billing, energy, production accuracy, and a reliable latency
distribution were not measured. This local experiment does not establish
cloud savings. Do not describe bytes as tokens or mocked runs as model quality.

The raw local artifact is
`target/bulk-reader/comparison-wjl3rZ/report.sexp`; adjacent
`implementation.sha256` records the measured implementation. Artifacts under
`target/` may not travel with the checkout; the Markdown report preserves
the findings. Subsequent runner changes handled unavailable totals for zero
pairs and suppressed a compilation warning; they do not change this five-pair
result. The real venue extraction and hash-checked re-fetch were also verified.

Current decision: keep bulk reading optional. Do not enable automatic
delegation by default or label its answers verified.

## Recommended next milestone

This is the proposed next development scope, not a claim that it already exists:
add a bounded decision and fallback path that makes optional delegation useful
without hiding its failures. Start with quality and accounting, not default
automatic routing or another model integration.

1. Preserve the existing five cases as regression evidence. Add independent
   cases for multiple requested facts, explicit absence, conflicting sources,
   and quoted instructions. Keep expected answers out of model prompts.
2. Design an explicit host-side policy: direct reads remain the default;
   delegation requires opt-in and a suitable bounded request. Record why each
   path was chosen. Do not infer a universal size threshold from one case.
3. Distinguish schema/reference validity, completeness diagnostics, and manual
   semantic review. Missing or contradictory evidence must not become verified
   success. Rule-based diagnostics are useful but not proofs of meaning.
4. If adding fallback, make it explicit and bounded. Record the failed worker,
   fallback reason, all input/output volume, elapsed time, and final outcome.
   Never hide failed delegation by counting only the successful direct call.
5. Compare the changed path against direct reads using both regression and
   new cases. Use repeated/order-balanced runs only when making latency claims.

Acceptance: deterministic policy/failure tests pass; the two observed quality
failures remain visible and are handled by a documented policy; fallback costs
are included; unknown metrics remain unknown; the report explains whether
quality and total work improved. A negative result is acceptable. Keep changes
scoped; do not bundle unrelated runtime or cloud API rewrites.

## Verification and re-run

From the repository root, with sibling `nelisp-llm` and `nelisp-photon` checkouts:

```sh
make test-bulk-reader
make test-semantic-eval
make compile LISP='lisp/nl-agent-bulk-reader.el examples/evaluate-bulk-reader.el'
```

Previous verification: 15 reader ERT tests, seven evaluation ERT tests,
16 local-tools assertions, and 51 semantic-evaluation ERT tests passed.
Warning-as-error compilation passed. This was focused host-side validation,
not a claim that the full standalone NeLisp suite or all product flows passed.

The default evaluation is a mocked smoke run. For real local inference, use
already installed models and a running loopback Ollama service:

```sh
mkdir -p target/bulk-reader
NELISP_AGENT_BULK_EVAL_LIVE=1 \
emacs -Q --batch --eval '(setq load-prefer-newer t)' \
  -l examples/evaluate-bulk-reader.el \
  -f nl-agent-example-evaluate-bulk-reader-main \
  -- --output target/bulk-reader/claude-comparison.sexp
```

Keep previous reports instead of overwriting them. Check actual answers and
excerpts; process exit success and `usable` status do not establish accuracy.
Run broader tests when changes cross runtime/provider boundaries.

## Completion reporting

Report changed behavior, relevant tests, measured results, and limitations
in Japanese. Follow the workspace DB-primary worklog process (`worklog-add`);
do not append to legacy `capture/ai-logs-*` or edit user journals. The prior
bulk-reader completion worklog digest is
`27755f3c5bb7f6c21febad147454906b65970a08`.

For the first Claude session: inspect current changes, reproduce the focused
baseline, then implement the smallest policy/quality milestone above with a
lightweight implementation model. Continue routine corrections autonomously.
