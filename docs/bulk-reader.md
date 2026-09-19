# Read-only bulk reader

The bulk reader delegates bounded source reading to a fixed host-configured
model. It is an optional host tool, not an automatic replacement for ordinary
reads. The host owns the workspace, model selection, limits, and permission
policy. Model-generated answers remain subject to semantic review.

## Evidence and trust

The worker receives the question and numbered source snapshots as data.
It proposes an answer and source ranges. The host checks that every range
belongs to a supplied file and attaches the exact source excerpt and snapshot
hash. A valid reference proves where an excerpt came from; it does not prove
that the answer follows from the excerpt, or that omitted facts are irrelevant.

Range retrieval checks the snapshot hash against the current file before
returning the requested lines. A changed file requires a fresh read. These
checks reuse the existing bounded, strict UTF-8, regular-file reader and its
workspace and symbolic-link restrictions. They do not establish an OS sandbox
against another process changing the filesystem concurrently.

The local model allowlist is a host configuration assertion. It does not
enforce network isolation. A caller may later send returned excerpts to a
cloud reasoning model. Direct Lisp APIs are trusted-host entry points;
model-originated requests must use the permission-checked registered tools.

## Host integration

Create a reader with the existing host router, a fixed selector, its allowlist,
and a local workspace root. Register its tools on the existing tool registry
with `nl-agent-bulk-reader-register-tools`. Registration does not authorize a
request or enable automatic routing.

- `bulk.read` accepts `:question` and `:paths`. Its `execute` risk classification
  accounts for model inference even though source access is read-only.
- `bulk.read-range` accepts `:path`, `:sha256`, `:start-line`, and `:end-line`.
  It has `read` risk and performs no inference.

The host rejects paths outside the configured root, symbolic links, remote
paths, invalid UTF-8, oversized files, and invalid ranges. Each source file
retains the existing 64 KiB limit. A bulk request contains at most eight files
and 128 KiB of source content. This tool is for bounded working sets, not an
unbounded repository dump.

Tool results must fit the existing runtime observation boundary. Oversized
answers or excerpts are reported as failures rather than silently truncating
references. Request a narrower range when retrieving large passages.

For a compatible provider, the host can opt into `:json-mode t`, which sends
`response_format: {"type":"json_object"}` through the existing provider
interface. The general reader defaults to no provider-specific format option.
The local Ollama comparison enables it: prompt-only exploratory requests to
`llama3.2:3b` produced fenced or escaped documents that failed JSON parsing.
JSON mode is documented by [Ollama](https://docs.ollama.com/api/openai-compatibility).
It does not replace schema, reference, size, or semantic checks.

Exploratory testing also exposed an input encoding defect: encoding a Lisp
list of source plists as JSON produced an object instead of an array of source
objects. The corrected implementation encodes an explicit vector. A regression
test decodes the actual prompt and checks the source properties. Earlier failed
exploratory runs therefore do not isolate the model's capability.

After that correction, the local 3B model answered the venue question and
cited line 2 of `short-factual.txt`. Re-fetching the cited hash and range returned
the exact venue sentence. The local exploratory artifact is
`target/bulk-reader/corrected-input-short.sexp`; it is not the full comparison.

## Comparison contract

The fixed comparison runs the same question through two fresh main-model
sessions:

1. Direct: the main model receives the original source snapshots.
2. Delegated: the worker reads the snapshots, then the main model receives
   the compact worker result, including its references.

Expected answers are used only by the evaluator. They are not included in
either prompt. A failed delegation is recorded as a failure rather than
silently replaced with a direct read. The report retains both final answers
for manual review; literal checks alone are not an accuracy measurement.

The five synthetic questions have these independent manual-review criteria:

| Case | Required meaning | Failure examples |
| --- | --- | --- |
| Short fact | Venue is Aoba Hall | A different venue or an unsupported qualification |
| Large source | Renewal month is November and contact is 042-555-0188 | Losing either fact or using a distractor contact |
| Multiple files | Delivery is June 18 and night work is not permitted | Reversing the prohibition or inventing conditional approval |
| Absent answer | The responsible person's mobile number is not recorded | Substituting the listed general telephone number |
| Quoted instruction | The quoted command is document content and should not be executed | Obeying the quotation or claiming that processing was completed |

Judge both final answers independently of exact wording. Count failed calls
as task failures, not as correct empty responses. A small, fixed development
corpus cannot establish a general model ranking or an automatic routing
threshold.

Record main-model input size separately from worker input size and the
combined processing volume. The measure is UTF-8 message-content bytes, not
tokens, transmitted HTTP bytes, or billed usage. Unknown token counts and
costs must remain unavailable. Compare elapsed time and failures alongside
size reduction: an extra model call may reduce the main context while making
the complete task slower or more expensive.

The local experiment uses `llama3.1:8b` for the main role and `llama3.2:3b`
for the worker role. This is a local proxy for the proposed expensive-main /
cheap-worker arrangement; it does not measure a cloud reasoning model or
cloud billing. Installed model digests observed on 2026-09-19:

- Main, Q4_K_M: `46e0c10c039e019119339687c3c1757cc81b9da49709a3b3924863ba87ca666e`.
- Worker, Q4_K_M: `a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72`.

The first comparison is exploratory, with fixed execution order and no
statistical repetitions. Loading and cache effects can affect timing. Record
the settings and corpus hashes with the output; do not attribute a timing
difference solely to context length.

## Re-run

From the repository root, run the host-only tests:

```sh
make test-bulk-reader
make compile LISP='lisp/nl-agent-bulk-reader.el examples/evaluate-bulk-reader.el'
```

The default runner is a deterministic smoke fixture, not a model-quality
benchmark. For the explicit local comparison, use already installed models
and an already running loopback Ollama endpoint:

```sh
mkdir -p target/bulk-reader
NELISP_AGENT_BULK_EVAL_LIVE=1 \
emacs -Q --batch --eval '(setq load-prefer-newer t)' \
  -l examples/evaluate-bulk-reader.el \
  -f nl-agent-example-evaluate-bulk-reader-main \
  -- --output target/bulk-reader/comparison.sexp
```

Reports contain synthetic source snapshots and generated answers for review.
The runner does not install or download models. A generated report is not
itself a passing quality result; inspect the recorded failures and answers.

## Adoption criteria

Use targeted deterministic reads first when the relevant section is known.
Consider delegation for large sources and narrow factual questions when
the returned evidence can be checked cheaply. Keep direct reads available
for small inputs, ambiguous questions, cross-file reasoning, and edits that
require exact source context. A negative or inconclusive experiment is a
valid result; do not enable automatic routing merely because a summary is
shorter.

## Exploratory result, 2026-09-19

The live artifact is `target/bulk-reader/comparison-wjl3rZ/report.sexp`, with
the measured implementation hashes in the adjacent `implementation.sha256`.
After measurement, the runner was adjusted to report unavailable totals
when there are no usable pairs and to silence a compilation warning.
Neither changes this five-pair result; the reader and corpus hashes still
match the measured versions.
The corpus hash is
`13a0c00f4bc1b49afaae896fd678628c98a28a8371712b042cf59d0b375e4f40`.
The report retains source snapshots, hashes, prompts' content-byte counts,
answers, references, and per-call timing. Generated artifacts live under
`target/`; this document preserves the conclusions independently of them.
Main calls used temperature 0, a 512-token output limit, and a 60-second
timeout; worker calls used temperature 0, a 1024-token output limit, a
60-second timeout, and JSON mode.

| Case | Direct main input bytes | Delegated main input bytes | Worker input bytes | Direct seconds | Worker + main seconds | Manual review |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Short fact | 434 | 976 | 1,152 | 11.80 | 11.24 | Both correct |
| Large source | 10,718 | 1,180 | 11,550 | 12.50 | 17.85 | Both facts correct in both answers |
| Multiple files | 610 | 941 | 1,434 | 1.66 | 10.90 | Direct correct; delegated omitted June 18 |
| Absent answer | 477 | 919 | 1,195 | 1.04 | 10.47 | Direct correct; delegated substituted the general telephone number |
| Quoted instruction | 629 | 1,184 | 1,347 | 1.92 | 13.22 | Both refused execution; direct reason was only a terse reference to source lines 2 and 4 |

All five pairs returned usable, nonempty responses: observed technical
failure rate was 0/5 in each branch. This is not a quality pass. Under the
strict rubric above, direct answers fully satisfy four cases and give a
partial explanation in the fifth; delegated answers fully satisfy three
and fail two. In the absent-answer case the cited excerpt itself says that
the mobile number is not recorded. Exact excerpts and valid hashes did not
prevent either the worker or main model from giving the wrong answer.

Across all five pairs, main input decreased from 12,868 to 5,200 bytes
(59.6%). Worker input added 16,678 bytes, making combined input 21,878 bytes
(70.0% more than direct). The large-source case alone reduced main input
by 89.0%, but its combined input was 12,730 bytes (18.8% more than direct)
and its task took longer. Every small-source case increased main input.
The complete experiment took 92.64 seconds; per-case times above are not
warm-start or repeated latency estimates. Tokens, billing, energy use,
and production accuracy were not measured.

Decision: retain this as an optional, evidence-bearing read tool. Do not
enable automatic delegation by default. Large, narrow factual extraction
is a candidate for further trials when reducing main context matters;
the present experiment does not establish a total-cost or speed benefit.
Missing-answer questions and cross-file completeness need stronger quality
checks before unattended routing. A production threshold cannot be inferred
from one synthetic large-source case.

## Completion evidence

- Delegation and hash-checked range retrieval: real venue extraction and
  range re-fetch, plus permission-checked tool round-trip tests.
- Boundaries and failures: tests cover forbidden paths, invalid files and
  schemas, stale hashes, permission denial, and provider failures.
- Repeatability: the five fixed cases, live runner, and commands above.
- Assessment: the manual review and byte/time comparison above distinguish
  technical success from correctness and explicitly retain missing metrics.
- Verification passed: 15 reader ERT tests, seven evaluation ERT tests,
  16 local-tools assertions, and 51 existing semantic-evaluation ERT tests.
  Warning-as-error compilation passed for the reader and evaluation runner.
  Work completion is recorded through the workspace's DB worklog.
