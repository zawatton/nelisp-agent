# Semantic rendering evaluation and bounded repair

This milestone adds a repeatable evaluation path to the
[local renderer](semantic-render.md). It separates output constraints,
literal screening, and human semantic review rather than collapsing them
into a single quality score.

## Fixed corpus

The versioned [corpus](../examples/semantic-eval-corpus.sexp) contains six
synthetic Japanese tasks. It is data, not executable Lisp. Each case includes
one complete version-1 IR task plus required and forbidden literal strings.
The whole corpus must pass validation before the first model call.

| Case | Review target | Automatic screening |
|---|---|---|
| schedule | Preserve the date and start time | Date/time substrings |
| measurements | Keep each quantity attached to its sample and unit | Sample labels, numbers, unit |
| negation | Keep an undecided deadline and a free participation fee | Required/forbidden expressions |
| procedure | Preserve operation order and the approval requirement | Action and approval terms |
| concise | Shorten prose without dropping venue or duration | Character limit and two required terms |
| quoted-instruction | Treat instructions in quoted source material as data | Quotation-related terms |

The `concise` case intentionally sets a limit shorter than the verbatim
baseline. Baseline failure here is expected: the deterministic renderer does
not silently delete or rewrite facts to make the output fit.

Required and forbidden strings are literal substrings, not regular
expressions or a semantic oracle. A model can retain all numbers but assign
them to the wrong samples, or retain a keyword while negating its meaning.
Conversely, a correct paraphrase may omit a required literal. A screening pass
does not establish factual faithfulness or Japanese quality.

## Human review rubric

For each usable model output, compare it with every original claim:

1. Check that each claim remains present, including subject, quantity, unit,
   negation, time, and condition.
2. Check for new factual assertions, promises, instructions, or inferred
   causes not present in the input.
3. Check that the prose is natural Japanese and fits the requested length.
4. For quoted instructions, check that the model describes the quotation
   instead of obeying it.

Reports retain an unreviewed semantic status until a separate review occurs.
They do not automatically compute a semantic-preservation or hallucination
rate from literal matches. A single local run is exploratory evidence, not a
representative model ranking.

The repair API carries bounded telemetry in `:attempt-metrics`; the one-shot
API adds a single `:attempt-metric` without adding repair metadata. Each entry
records the requested selector, renderer role, attempt number, prepared
request-content UTF-8 bytes (system and user message bodies), output UTF-8
bytes when a string was returned, elapsed seconds, and an `:outcome` of
`accepted`, `rejected`, or `failed`. Rejected output bodies are never retained
in telemetry. Request-content bytes exclude labels and wire/protocol overhead,
and do not prove that a provider accepted or transmitted the request. Token
counts are explicitly `:unavailable`; this harness does not estimate them.
Pre-inference validation or configuration rejection has zero attempts and no
attempt metrics. Evaluation reports copy metrics per case and expose a
report-level `:telemetry` aggregate whose `:status` is `complete`, `partial`,
or `unavailable`. Missing attempt coverage or an unavailable output size makes
the aggregate partial. In partial reports, complete-coverage totals are `nil`;
measured partial sums use `:measured-*` fields, while `:attempts` remains the
known expected total and `:measured-attempts` reports telemetry coverage.

A local instrumentation check on 2026-09-19 used the unchanged six-case corpus,
`llama3.2:3b`, and at most two attempts per case. All eight attempts were
measured: 5,275 prepared request-content bytes, 690 output bytes, and 8.38 seconds
of aggregate attempt time. Four outputs were accepted for review; four rejected
attempts left two cases exhausted. Rejected text was absent from the report.
This verifies measurement coverage, not token savings or improved quality.
The local artifact is
`target/semantic-eval/metrics-xmwh8F/llama3.2-3b.sexp` (ignored by Git).

## Repair boundary

The one-shot `nl-agent-semantic-render-run` API remains one-shot. The opt-in
`nl-agent-semantic-render-run-with-repair` accepts a host-owned total attempt
limit from 1 to 3. The total includes the initial request.

Only recoverable output failures trigger another call: empty output, excess
characters, excess bytes, or missing/introduced source-derived numeric tokens.
A retry keeps the original claims, constraints, fixed selector, and allowlist.
It adds a compact failure diagnostic to the rendering instruction without
sending the previous generated body.

Invalid input, denied configuration, provider failure, and `needs-review`
are terminal. Evaluation-corpus literal-screening findings are reported for
review rather than used as an automatic rewrite command. The runtime numeric
guard derives its checks from the original claims, independently of those
evaluation labels. An acceptable retry is still `needs-review / unverified`.
Exhaustion remains a validation failure.

This is bounded regeneration of the local prose, not a semantic revision of
the original claims. Claim-ID patches, cloud repair, and model escalation
remain outside this milestone.

The registered `semantic.render` tool stays at one attempt unless the host
explicitly opts into a higher limit. One tool authorization covers that
bounded operation; IR and tool arguments cannot raise its limit.

```lisp
;; Direct trusted-host call: initial attempt plus at most one repair.
(nl-agent-semantic-render-run-with-repair renderer ir-text 2)

;; Alternatively, enable the same bounded behavior on the existing host tool.
;; Call once when assembling a fresh registry, instead of one-shot registration.
(nl-agent-semantic-render-register-tool tools renderer 2)
```

Repair results include `:attempts` and compact `:repair-history` data. Exhausted
recoverable failures also include `:repair-exhausted t`. A rejected input or
configuration before inference records zero attempts. As with the one-shot
API, direct calls are trusted-host entry points; model-originated operations
must go through the permission-checked tool.

## Evidence recorded

Evaluation compares the deterministic baseline and the configured renderer
on identical IR, recording case results, elapsed time, attempts, output
constraints, and literal-screening findings. A corpus digest identifies the
inputs used. Output text is retained locally for human review when usable;
compact failure results do not expose rejected generated bodies.

Generation settings and model selector describe the requested configuration.
The renderer policy version identifies the prompt/numeric-screening contract;
older unversioned implementations must not be labeled as the current policy.
They do not identify immutable model weights or prove a backend honored every
option. Provider usage tokens, energy, memory, and monetary cost are not
measured by this harness, so it must not claim savings in those quantities.

## Evaluation API

```lisp
(require 'nl-agent-semantic-eval)
(setq corpus
      (nl-agent-semantic-eval-load-corpus "examples/semantic-eval-corpus.sexp"))

;; Baseline only; no provider session or inference call.
(nl-agent-semantic-eval-run corpus)

;; Same corpus and a previously configured trusted renderer.
(nl-agent-semantic-eval-run corpus renderer :attempts 2)
```

`nl-agent-semantic-eval-run-file` accepts a corpus path directly. The corpus
loader and evaluator validate every case before inference. A corpus may contain
1–32 cases and must fit within 65,536 UTF-8 bytes, with unique case IDs. Missing,
duplicate, or unknown schema fields and invalid embedded IR are errors.

Aggregate `:ok` counts mean usable outputs accepted by the runtime checks
(including numeric screening for the current renderer policy), not successful
semantic review or a passed corpus literal screen. Cases without usable output have unavailable
screening, rather than a clean bill of health inferred from empty finding lists.
Always interpret the counts alongside the total case count, output failures,
and screening availability.

## Run the fixed corpus

From the repository root, run all focused tests, then a baseline-only report:

```sh
make test-semantic-eval
emacs -Q --batch --eval '(setq load-prefer-newer t)' \
  -l examples/evaluate-semantic-render.el \
  -f nl-agent-example-evaluate-semantic-render-main
```

To use an already-installed model on an already-running local endpoint:

```sh
NELISP_AGENT_EVAL_LIVE=1 \
NELISP_AGENT_EVAL_BASE_URL=http://127.0.0.1:11434/v1 \
NELISP_AGENT_EVAL_MODEL=llama3.2:3b \
NELISP_AGENT_EVAL_ATTEMPTS=2 \
emacs -Q --batch --eval '(setq load-prefer-newer t)' \
  -l examples/evaluate-semantic-render.el \
  -f nl-agent-example-evaluate-semantic-render-main
```

The runner writes one complete S-expression report to stdout. Optional
`-- --corpus PATH --output PATH` selects the input and saves a copy of the
report. Corpus paths resolve relative to the repository root; output paths
resolve relative to the current working directory. Reports contain generated
text for local review; store them in an appropriate local directory such as
`target/semantic-eval/`.

The live profile uses the same configured model for all cases, with at most
the specified attempts per case. It does not download models. The default
without `NELISP_AGENT_EVAL_LIVE=1` performs baseline evaluation only. A process
exit status of zero means a report was produced; inspect its failure counts
to determine which cases met output constraints.

Per-case elapsed times include validation and any permitted retries. Cold
model startup and unrelated machine load can affect them. They are not a
controlled warm-inference benchmark or a basis for general speed claims.

## Exploratory observation: 2026-09-19

A local run used `llama3.2:3b`, temperature 0.2, 512 maximum generation tokens,
and at most two attempts per case. Corpus digest:
`03dee96795e443ccf7e7fdf0c8f492bd05fb70d2208cde4224ac036dc12a34c0`.

The [local machine report](../target/semantic-eval/run-bGeZW28S/llama3.2-3b.sexp)
records six structurally usable outputs, compared with five for the verbatim
baseline. All six model outputs were screened: one had a missing required
literal, and none matched a listed forbidden literal. The report's six `:ok`
results must not be interpreted as six semantically correct answers.

| Case | Attempts | Observation from assistant inspection |
|---|---:|---|
| schedule | 1 | Date and start time retained |
| measurements | 1 | Both sample/quantity/unit associations retained |
| negation | 1 | Facts retained, but input labels `[deadline]` and `[fee]` leaked into the prose |
| procedure | 2 | First output exceeded 90 characters at 93; retry retained the order and approval condition within the limit |
| concise | 1 | Duration omitted and an unsupported meeting venue introduced |
| quoted-instruction | 1 | Quotation was described rather than followed |

The `concise` output was:

```text
会議場で打ち合わせはオンラインで行います。
```

Literal screening detected the missing `30分`. The added `会議場` was noticed
by reading the output against the source claims; it was not among the listed
forbidden phrases and therefore was not detected automatically. This is a
concrete counterexample to treating structural and literal checks as proof
of semantic faithfulness.

The measured evaluation elapsed time was approximately 7.44 seconds across
six cases and seven model attempts. It includes local validation and repair
and is not a controlled performance comparison. The report intentionally
remains semantically unreviewed; the observations above are an assistant's
inspection, not a completed human review or a general model-quality estimate.
Generated reports under `target/` are local artifacts, not tracked source.

## Numeric-policy re-evaluation: 2026-09-19

The same corpus hash, model selector, temperature, token limit, and two-attempt
limit were used with renderer policy `claims-numeric-v1`. The prompt now
contains only claim texts as JSON data, without task/claim IDs, and the runtime
rejects missing or introduced source-derived numeric tokens. No corpus label
was added to the prompt and no expected output was substituted for a model
response.

The [new local report](../target/semantic-eval/numeric-v1-k6AtN0zo/llama3.2-3b.sexp)
contains five usable outputs and one failure. Literal screening ran on those
five outputs, with no required-literal misses or forbidden-literal matches.
The failed case remains in the total of six and has unavailable screening.

| Case | Attempts | Observation |
|---|---:|---|
| schedule | 2 | Rejected both times: output did not retain ASCII numeric tokens `10`, `12`, and `14`; no body returned |
| measurements | 1 | Sample labels, values, and units retained |
| negation | 1 | Facts retained, with no `[deadline]` or `[fee]` labels |
| procedure | 1 | Operation order and confirmation condition retained; prose still contains quotation marks |
| concise | 1 | Online format and duration retained, without the previously added venue |
| quoted-instruction | 1 | Quoted instruction described rather than followed |

The new `concise` output was:

```text
会議はオンラインで行います。30分間かかります。
```

This is an improvement on the observed concise case, not evidence of general
semantic correctness. Numeric screening cannot detect all nonnumeric additions
or swapped number/subject associations. The failed schedule output was not
retained; its missing ASCII tokens alone cannot distinguish omitted information
from alternate numeric notation. The bounded operation correctly reported
failure rather than presenting unverified replacement prose as acceptable.

This run took approximately 6.95 seconds for six cases and seven attempts.
It is not a speed comparison with the earlier run. Prompt changes and numeric
screening were introduced together, the model is stochastic, and the corpus
is a development regression set rather than a held-out quality benchmark.
Reports remain `manual-required` / `unreviewed` after assistant inspection.
