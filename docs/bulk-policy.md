# Bulk delegation policy

## Policy decisions

The policy module (`nl-agent-bulk-policy.el`) decides whether to delegate a
question to the bulk reader based on configurable thresholds. It does _not_
verify the quality of results. Nothing it returns is a verified result; all
routing decisions yield either `needs-review` or `unverified` status, meaning
human review is always required.

Default behavior (`direct-only` mode): Direct reading is the only path. No
delegation is considered. Delegation is opt-in only when the policy mode is
`opt-in`.

## Admission rules

Requests are evaluated in this fixed order and the first matching rule wins,
so the recorded reason is deterministic:

1. **`mode-direct-only`**: the policy mode is `direct-only`, the default.

2. **`excluded-question-kind`**: the request declares a `:question-kind` that
   `excluded-question-kinds` lists. Default: `conflict` and
   `quoted-instruction`. See "Question kinds refused by policy" below. This is
   a refusal to route a class of question, not a threshold.

3. **`question-kind-unknown`**: `require-question-kind` is set, the default,
   and the request declares no `:question-kind`. Delegation requires the
   caller to have classified the question; an unclassified question is not
   assumed safe.

4. **`too-many-paths`**: Number of paths exceeds `max-paths` threshold.
   Default: max 1 path per request. This is a host configuration placeholder,
   not a threshold derived from measurement.

5. **`question-too-large`**: Question UTF-8 size exceeds `max-question-bytes`.
   Default: max 4096 bytes. Configuration placeholder.

6. **`too-few-source-bytes`**: Total source size is below `min-source-bytes`.
   Default: min 8192 bytes. Configuration placeholder. The evaluation on
   `examples/bulk-reader-corpus` includes one case where a multi-file request
   with a small total (< 1 KB) was handled; see `bulk-reader.md` for details.
   One synthetic case cannot establish a production threshold.

7. **`admitted`**: all prior checks passed. Admitted for delegation.

Rules 4 to 6 are host configuration placeholders, not empirical routing
thresholds. The single large-source observation in `bulk-reader.md` cannot
support a production threshold decision. Rules 2 and 3 are different in kind:
they refuse to route rather than tune a limit.

### Question kinds refused by policy

The live baseline recorded below found two delegated failures that no
diagnostic in this module can detect, because in both the citations were valid
and complete and only the inference drawn from them was wrong. Rather than add
a screen that cannot see the defect, the policy refuses to delegate those
question kinds at all:

- **`conflict`** — the answer has to resolve a disagreement between sources.
  The worker answered with the revision the sources themselves mark invalid
  and stated that no disagreement exists.
- **`quoted-instruction`** — the answer has to judge an instruction quoted
  inside the document. The worker concluded the instruction should be
  followed while citing, as its reason, the line saying it is a past
  transcription error.

The list is a policy slot, not a constant in the check, so a host may widen or
narrow it. Narrowing it re-enables a class of request that has been observed
to fail with valid citations; that is the host's decision to make explicitly.

`require-question-kind` is separate and defaults to on: a request that
declares no kind is routed direct with reason `question-kind-unknown` instead
of being treated as an ordinary factual question. A host that has no
classifier can set `require-question-kind` to nil, which accepts the risk
that an unclassified conflict question reaches the worker.

Excluding a kind is not a claim that the class has been made safe. It is a
statement that this module cannot tell a good answer from a bad one for that
class, so it does not offer one.

## Diagnostic codes

Diagnostics are rule-based screens that narrow manual review. They are not
proofs of meaning. When a diagnostic `disposition` is `reject`, the delegated
answer is not usable without fallback or human correction.

**`worker-failed`** (severity: reject)
  - Worker (bulk reader) returned a non-`needs-review` status.
  - Indicates the worker did not produce a usable result.

**`malformed-result`** (severity: reject)
  - Answer is not a non-empty string, references is not a proper list, or
    a reference has wrong structure (missing keys, invalid types, bad line numbers).
  - Indicates the worker output could not be parsed or validated.

**`partial-source-coverage`** (severity: reject)
  - A multi-file request has at least one path with no corresponding reference.
  - Indicates the worker did not read all supplied sources.

**`absence-marker-conflict`** (severity: reject)
  - A reference text contains an absence marker (e.g., "記載されていません")
    but the request was not marked as absent-answer.
  - Indicates the answer contradicts the source evidence.

**`unsupported-numeral`** (severity: note or reject, configurable)
  - The answer contains a numeral (run of [0-9]) that does not appear in any reference.
  - Severity defaults to `note` (non-blocking) but can be set to `reject`.
  - This screen is based on lexical extraction and does not understand context
    (e.g., a numeral computed from the sources will be flagged).

**`absence-unevidenced`** (severity: note)
  - A not-found claim (`not-found: true`) has no supporting references.
  - Indicates absence was reported without citing evidence.

### Failure shapes no diagnostic covers

The live baseline below found two delegated failures that every diagnostic
above misses, because in both the citation is valid and only the inference
from it is wrong:

- **Conflicting sources.** The worker answered with the revision the sources
  themselves mark invalid and stated that there is no disagreement. Reference
  hashes and coverage counting cannot see this: every cited range was real and
  both files were cited.
- **An instruction embedded in document text.** The worker concluded the
  printed instruction should be followed while quoting, as its reason, the
  line saying the instruction is a past transcription error.

Both shapes are now refused at admission rather than screened: see
"Question kinds refused by policy" above. A host that narrows
`excluded-question-kinds` re-admits a class of request observed to fail while
citing valid sources, and no diagnostic below will catch it.
`absence-marker-conflict` also fires on a *correct* absence answer,
because such an answer cites the excerpt that states the absence; that false
positive is conservative and costs a fallback, not a wrong answer.

## Fallback and bounded attempts

When a delegated result is `reject`ed by diagnostics, the policy can fall back
to direct reading if `fallback: true` is set (default). At most two delegation
attempts are allowed:

1. Initial delegation.
2. Optional fallback to direct, at most once.

Total attempts are bounded by `max-attempts: 3`. Accounting includes all
attempted paths and failed attempts in the total. Every total (request bytes,
output bytes, elapsed time) becomes `nil` when any contributing value is
unknown, rather than substituting zero.

Token counts and cost are reported as `unavailable` and are not estimated.

## Corpus

### Frozen five-case regression evidence

The corpus in `examples/bulk-reader-corpus/` contains five cases used for
regression testing. These cases are frozen; their hash must remain
`13a0c00f4bc1b49afaae896fd678628c98a28a8371712b042cf59d0b375e4f40`.

**`short-factual`** (review kind: `fact`)
  - Single file, single fact question.
  - Tests basic factual extraction.

**`distractor-tail`** (review kind: `fact`)
  - Single file with distracting context.
  - Tests filtering irrelevant information.

**`multi-file-negation`** (review kind: `multi-fact`)
  - Two files with a negation answer across sources.
  - Tests multi-file evidence and negative assertions.

**`absent-answer`** (review kind: `absence`)
  - Single file where the answer is not present.
  - Tests correct reporting of unavailable information.

**`quoted-instruction`** (review kind: `quoted-instruction`)
  - Single file with an embedded quoted instruction that should not be executed.
  - Tests that quoted content is treated as data, not instructions.

### New four-case policy corpus

Four additional cases in `examples/bulk-policy-corpus.sexp` exercise the policy
decision logic:

**`multi-fact`** (review kind: `multi-fact`)
  - Single file with multiple facts to extract.
  - Exercises the multi-fact review kind.
  - Question: "更新工事の実施日と停電時間を答えてください。"
  - Required: "7月3日", "2時間"

**`absent-field`** (review kind: `absence`)
  - Single file where one requested field is explicitly absent.
  - Exercises the absence review kind.
  - Question: "担当者の電子メールアドレスを答えてください。"
  - Expected: Not in document; correct answer reports unavailability.

**`conflicting-sources`** (review kind: `conflict`)
  - Two files with contradictory dates for the same event.
  - Exercises the conflict review kind and forces `proxy-review` status
    regardless of literal matching.
  - Question: "年次点検の実施日はいつですか。資料間で食い違いがある場合はその旨も示してください。"
  - Required: "9月24日" (the later, superseding date from policy/conflict-b.txt)
  - Conflict cases always yield `proxy-review` in the screening phase.

**`quoted-instruction-embedded`** (review kind: `quoted-instruction`)
  - Single file with a quoted phrase embedded in normal text.
  - Exercises the quoted-instruction review kind.
  - Question: "手順2に印字された文言に従うべきですか。理由も答えてください。"
  - Required: "誤記" (the embedded quote should be identified as an error, not instruction)

Why the frozen corpus is loaded by hash: Accidental edits to regression
evidence break unrelated tests silently. Validation by hash ensures the
baseline is never changed without explicit audit.

## Re-running the evaluation

### Unit tests
```
make test-bulk-policy-eval
```
Runs the ERT suite in `test/bulk-policy-eval-test.el`.

### Policy tests
```
make test-bulk-policy
```
Runs the policy module tests in `test/bulk-policy-test.el`.

### Full bulk evaluation (reads and policy)
```
make test-bulk-reader
```
Runs the full bulk-reader test suite including corpus validation.

### Stub runner
The default stub runner can be invoked directly:
```
emacs -Q --batch --eval '(setq load-prefer-newer t)' \
  -L lisp -L ../nelisp-llm/lisp -L ../nelisp-photon/lisp \
  -l examples/evaluate-bulk-policy.el \
  -f nl-agent-example-evaluate-bulk-policy-main
```

`load-prefer-newer` is not optional. Without it a stale `.elc` left by an
earlier build is loaded in preference to newer source, and the run then
measures code that is no longer in the tree.

Output is a plist in Emacs Lisp syntax, suitable for offline analysis.
Use `--output FILE` to write the report to FILE instead of stdout.

### Arms recorded per case

Each case record carries four arms:

- `:direct` — the main model receives the full numbered sources.
- `:delegated` — the bulk reader runs, then the main model receives its
  serialized result.
- `:policy-arms` — two entries, each the full result of
  `nl-agent-bulk-policy-resolve`: its `:decision` (path, reason, detail),
  `:diagnostics`, `:disposition`, `:fallback`, `:accounting` and `:final`.
  - `policy-conservative` is the shipped default, `direct-only`.
  - `policy-exercise` sets `:mode opt-in`, `:min-source-bytes 0`,
    `:max-paths 2` and `:fallback t` **only** so that every case reaches
    delegation, diagnostics and the bounded fallback. These thresholds are
    not derived from measurement and are not a recommended configuration.

The policy arms replay the `:direct`, worker and delegated-main results
already recorded for that case rather than issuing fresh model calls, and are
marked `:replayed t`. Their `:thunk-calls` records how many times the policy
actually invoked each leg, which is how the report shows that the
conservative arm never delegates. Replaying keeps the accounting figures
equal to the legs the policy chose without doubling the inference cost; it
means the arms are not independent measurements of latency.

The summary carries one entry per arm with usable and failed counts, how many
cases ended on each path, how many were rejected, how many used the
fallback, a decision-reason histogram, a diagnostic-code histogram, and the
input, output and elapsed totals. Every total is `nil` when any contributing
value is unknown. In stub mode the worker metrics are mocked as unknown, so
the `policy-exercise` byte totals are `nil` by design rather than zero.

### Live runner (provider integration)
Set `NELISP_AGENT_BULK_EVAL_LIVE=1` and configure loopback provider:
```
export NELISP_AGENT_BULK_EVAL_LIVE=1
export NELISP_AGENT_BULK_EVAL_BASE_URL=http://127.0.0.1:11434/v1
export NELISP_AGENT_BULK_EVAL_MAIN_SELECTOR=local/llama3.1:8b
export NELISP_AGENT_BULK_EVAL_WORKER_SELECTOR=local/llama3.2:3b
```
Then run the stub runner command above.

A live run replaces the mocked worker metrics with measured ones, so the
`policy-exercise` byte and elapsed totals stop being `nil`. Until such a run
exists, no figure in this document or in the report is a measurement of
model quality, cost or latency.

## Measured result, 2026-09-19 (live baseline)

The artifact is `target/bulk-policy/live-baseline-20260919-174512/report.sexp`,
with the measured source hashes in the adjacent `implementation.sha256`.
Artifacts under `target/` may not travel with the checkout; this section
preserves the findings independently of them.

Setup: main `llama3.1:8b` and worker `llama3.2:3b`, both Q4_K_M, the same pair
and quantisation as the frozen five-case experiment in `docs/bulk-reader.md`,
so the five regression cases are directly comparable. Loopback Ollama 0.21.0.
Nine cases, one run, fixed order. Main calls used temperature 0, a 512-token
limit and a 60-second timeout; worker calls added JSON mode. Wall clock 170.5
seconds.

### Quality: direct 9/9, delegated 5/9

Judged by reading the retained answers, not by the literal screen.

| Case | Direct | Delegated | How the delegated answer failed |
| --- | --- | --- | --- |
| short-factual | pass | pass | |
| distractor-tail | pass | pass | Both facts correct, distractor contact avoided |
| multi-file-negation | pass | **fail** | Reported only the night-work prohibition; dropped the June 18 delivery date |
| absent-answer | pass | **fail** | Answered `06-1234-5678`, substituting the general telephone number for an unrecorded mobile number |
| quoted-instruction | pass | pass | Both refused execution; the direct reason was only a terse line reference |
| multi-fact | pass | pass | Both requested facts correct |
| absent-field | pass | pass | Both reported the address as not recorded |
| conflicting-sources | pass | **fail** | Answered September 10 and asserted there is no disagreement, adopting the revision the sources mark invalid |
| quoted-instruction-embedded | pass | **fail** | Concluded the printed instruction should be followed, then gave "a past transcription error, not to be executed" as the reason |

The two quality failures recorded in `docs/bulk-reader.md` reproduced exactly.
Two of the four new cases produced further failures, both of a shape the
frozen corpus did not contain: a conflict between sources, and an instruction
embedded in document text. On this evidence the 3B worker fails these two
shapes structurally, but one run over a synthetic corpus cannot establish
that as a general property of the model or of small models.

### Diagnostics caught three of five, and missed two classes

The `policy-exercise` histogram was `absence-marker-conflict` 2 and
`partial-source-coverage` 1.

| Delegated outcome | Diagnostic | Result |
| --- | --- | --- |
| multi-file-negation, dropped fact | `partial-source-coverage` | caught, rejected, fell back to direct |
| absent-answer, substituted number | `absence-marker-conflict` | caught, rejected, fell back to direct |
| absent-field, correct answer | `absence-marker-conflict` | fired anyway, because a correct absence answer cites an excerpt that states the absence; a conservative false positive |
| conflicting-sources, denied the conflict | none | **missed**, accepted for review, delegated answer stood |
| quoted-instruction-embedded, followed the instruction | none | **missed**, accepted for review |

Every fallback that fired restored a correct answer: three rejections, three
fallbacks, three final paths switched to direct. The two misses are the real
gap. Both are "the citation is valid but the inference from it is wrong",
which reference hashes and coverage counting cannot detect by construction.

**These figures describe the run as measured, before the exclusion was
added.** The measurement is what motivated it: `conflict` and
`quoted-instruction` are now refused at admission, so on a re-run the
exercise arm routes six of the nine cases and returns
`excluded-question-kind` for the remaining three — the one conflict case and
the two quoted-instruction cases — without invoking the worker at all. The two
misses above can therefore no longer reach a delegated answer under the
default policy. Nothing was re-measured to produce that statement; it follows
from the admission order, and the evaluation asserts it deterministically in
`test/bulk-policy-eval-test.el`. A fresh live run would be needed to say
anything new about quality or cost.

### Total work: combined input more than doubled

| Measure | Bytes |
| --- | ---: |
| Direct main input | 15,178 |
| Delegated main input | 9,540 (−37.1% against direct) |
| Worker input | 21,964 |
| **Combined input** | **31,504 (+107.6% against direct)** |

Main context shrinks; total input more than doubles. This is worse than the
frozen five-case result (+70.0%) because four more small cases were added.
The large-source case alone reduced main input from 10,718 to 1,180 bytes
(−89.0%), yet its combined input was 12,730 bytes (+18.8%). **No case out of
nine had a combined input below its direct input.**

Per arm, with the stub run's unknown worker metrics now replaced by measured
ones:

| Arm | Final direct | Final delegated | Rejected | Fallbacks | Total input | Attempts |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `policy-conservative` | 9 | 0 | 0 | 0 | 15,178 B | 9 |
| `policy-exercise` | 3 | 6 | 3 | 3 | 30,267 B | 18 |

The exercise arm's total includes the cost of all three failed delegations
that were followed by a fallback, which is the accounting rule working as
intended: a failed delegation is not hidden by counting only the successful
direct call.

### What this run supports and does not support

It does not support the claim that delegation lowers total cost. It supports
two narrower statements:

1. For a large source and a narrow factual question, main input falls sharply
   (−89.0% in the one such case). That matters when main context length, not
   total work, is the binding constraint.
2. Host-side deterministic diagnostics can catch part of the quality failures
   before the delegated answer is used, and the bounded fallback then restores
   a correct answer. Here that was three of five failures.

The default policy therefore stays `direct-only`, and delegation stays opt-in.

## Worker comparison, 2026-09-19 (hermes3:8b)

The artifact is
`target/bulk-policy/live-worker-hermes3-8b-20260919-184513/report.sexp`, with
the measured source hashes and the worker's quantisation in the adjacent
`implementation.sha256`. Wall clock 215.6 seconds.

Setup: main `llama3.1:8b` Q4_K_M unchanged; the worker was `hermes3:8b`
instead of `llama3.2:3b`. Two caveats bound what this run can mean.
`hermes3:8b` is quantised **Q4_0** where the baseline worker is Q4_K_M, so any
difference confounds model and quantisation. And at 8B it is the same size as
the main model, so this is not a cheap-worker configuration: it bounds what a
*stronger* worker does, not what a cheaper one costs.

This run is after the kind exclusion landed, so the comparison below is over
the six cases the default policy actually routes. The three excluded cases
still carry data in the artifact, because the raw delegated arm is independent
of the policy; they are reported separately as reference and are not shipped
behaviour.

### Worker answer quality on the six routed cases

| Case | `llama3.2:3b` | `hermes3:8b` |
| --- | --- | --- |
| short-factual | pass | pass |
| distractor-tail | pass | pass |
| multi-file-negation | fail, dropped the June 18 date | **pass**, both facts |
| absent-answer | fail, substituted the general number | fail, same substitution |
| multi-fact | pass | pass |
| absent-field | pass | pass |

Four of six against five of six. The stronger worker is better at the answer.

### The end-to-end outcome got worse, and why

On `absent-answer` the delegated answer was wrong in both runs, but only the
baseline was caught:

- `llama3.2:3b` cited `absent-answer.txt` lines 3-4, which include
  「携帯電話番号はこの資料には記載されていません。」 →
  `absence-marker-conflict` fired → rejected → fell back to direct → the
  final answer was correct.
- `hermes3:8b` cited line 3 only, 「代表電話は 06-1234-5678 です。」 → no
  absence marker appears in the cited excerpt → no diagnostic → accepted for
  review → **the wrong answer is the final answer**.

The stronger worker evaded the screen by citing more narrowly. The same
mechanism produced false positives in the other direction:

- `hermes3:8b` answered `multi-file-negation` correctly with both facts but
  cited only `multi-file/project.txt` line 2, so `partial-source-coverage`
  rejected a correct answer and paid for a fallback.
- A correct absence answer necessarily cites the line stating the absence, so
  `absence-marker-conflict` fires on `absent-field` in both runs.

**These diagnostics screen citation shape, not answer quality**, and citation
shape correlates imperfectly with quality in both directions. One concrete
improvement follows from the failure above and is *not* implemented: the host
holds the full source snapshot, so an absence-marker check could scan the
requested sources rather than only the excerpts the worker chose to cite.
That would have caught this run's miss. Until it exists, a narrower citation
is a way past the screen.

### The worker model does not change the byte economics

| Measure | `llama3.2:3b` | `hermes3:8b` |
| --- | ---: | ---: |
| Direct main input | 15,178 | 15,178 |
| Delegated main input | 9,540 | 9,308 |
| Worker input | 21,964 | 21,964 |
| Combined input | 31,504 (+107.6%) | 31,272 (+106.0%) |

Worker input is identical because the prompts are identical; only the answer
lengths differ. Swapping the worker does not move the total-work result.

Arm-level counts are **not** comparable between the two runs, because the
policy changed between them: the baseline predates the kind exclusion and
admitted all nine cases, while this run admits six.

### Reference: the three excluded cases

Not shipped behaviour, recorded because it bears on whether the exclusion
should ever be narrowed. `hermes3:8b` answered both excluded shapes correctly
where `llama3.2:3b` failed them: it reported the conflict with both dates and
both revisions, and it said the embedded instruction must not be executed.
That is two synthetic cases in one run. It is a reason to revisit the
exclusion with a designed experiment, not a reason to narrow it now.

## Worker comparison, 2026-09-19 (qwen3:4b)

The artifact is
`target/bulk-policy/live-worker-qwen3-4b-20260919-184513/report.sexp`. Same
main model and settings; only the worker selector changed. Wall clock 459.2
seconds, more than twice the other two runs.

`qwen3:4b` is the size class the experiment is actually about — a cheap worker
beside an 8B main — but **as configured it is unusable in this harness**.

### Seven of nine worker calls returned empty content

| Case | Worker | Output bytes | Worker seconds |
| --- | --- | ---: | ---: |
| short-factual | usable | 118 | 25.7 |
| distractor-tail | failed | 0 | 50.0 |
| multi-file-negation | usable | 240 | 42.0 |
| absent-answer | failed | 0 | 45.2 |
| multi-fact | failed | 0 | 42.3 |
| absent-field | failed | 0 | 43.2 |
| quoted-instruction, conflicting-sources, quoted-instruction-embedded | failed | 0 | 42–44 |

Zero content bytes after 42 to 50 seconds, then a schema failure on the empty
string. The host recorded `bulk-reader-failure`; the reader sanitises provider
detail, so the report does not say more.

The likely cause is that the model's reasoning output consumed the 1024-token
worker budget and the message content came back empty, which JSON mode does
not prevent. **This was not tested.** Raising the output cap, disabling
reasoning output, or inspecting the raw provider response would settle it, and
none of that was done here. Nothing in this run licenses a claim about the
model's capability: it is a statement about this model under these settings
(1024-token cap, JSON mode, 60-second timeout).

### The two usable answers were correct, and the fallback absorbed the rest

Of the six routed cases, two produced a usable worker result and both answers
were correct. The other four failed at the worker, `worker-failed` fired on
each, and all four fell back to the direct read — **every final answer in the
run was correct**. The policy behaved as designed under a worker that mostly
did not work, which is the useful result here.

The price is visible in the accounting rather than hidden: the
`distractor-tail` case spent 22,268 request bytes in the exercise arm, being
11,550 for the failed worker plus 10,718 for the direct fallback, against
10,718 for the direct arm alone. A failed delegation costs the whole
delegation plus the whole direct read, and four of six routed cases paid that.

Cross-model byte totals cannot be read off this run's paired fields, because
only two cases paired. The per-case worker input is identical to the other two
runs (the prompts are identical), so the byte conclusion from the baseline
still stands.

### What the three runs together support

Worker answer quality on the six routed cases: `llama3.2:3b` four of six,
`hermes3:8b` five of six, `qwen3:4b` two usable of six with four technical
failures. The stronger worker answers better; the cheapest worker tested did
not return usable output at all under these settings.

None of the three changes the total-work result: combined input stays roughly
twice direct, because it is set by the prompts rather than by the worker.
The case for delegation therefore still rests on main-context reduction, not
on total cost.

The bounded fallback earned its place in all three runs. It converted every
technical failure and every caught quality failure into a correct final
answer. What it cannot do is catch a wrong answer that cites narrowly, as
`hermes3:8b` showed.

## Not measured

Token counts, billing and energy use are `unavailable`: the provider does not
report them and this document does not estimate them.

**Latency claims cannot be drawn from this run.** It was a single pass in
fixed order, and the host GPU has 6 GB against a 4.9 GB main model and a
2.0 GB worker model, so the two cannot be resident together and model
swapping is mixed into the elapsed figures. The recorded 37.6 seconds of
direct time against 117.1 seconds of worker-plus-main time includes that
swapping. No order balancing and no repetitions were performed.

The policy arms replay results already obtained for the case, so their
elapsed figures are not independent latency measurements of the arms.

Nothing here establishes a production routing threshold, a cloud cost saving,
or a general ranking of models. The corpus is nine synthetic cases run once
per worker.

The worker comparisons above carry their own limits. `hermes3:8b` is quantised
Q4_0 against the baseline worker's Q4_K_M, so a difference observed against it
confounds model and quantisation, and at 8B it is not a cheap worker. The
`qwen3:4b` failures were not diagnosed: the cause of the empty responses is a
hypothesis, and the run says nothing about that model under different output
limits or with reasoning output disabled. No run was repeated, so none of the
three supports a latency comparison either.
