# File-outcome task evaluation

Training loss and an agent's `DONE` response do not establish task success.
The task evaluator checks actual files after the ordinary service/runtime has
finished. It is an offline measurement surface, not an automatic training or
promotion policy.

## Fixed evaluation contract

`nl-agent-task-eval-run` validates and detaches the entire host-owned suite
before creating any case workspace. Each case receives a fresh private
temporary directory containing only its input files. The trusted host runner
receives task text, that directory, and the step limit; expected outputs are
not passed to the runner or written into the workspace.

A case passes only when runtime status is `done`, every expected file has the
exact expected bytes, and no unexpected filesystem entries exist. Unchanged
guard files are part of the expected output. Missing files, unexpected edits,
extra files/directories, symlinks, special files, invalid runner responses,
exceptions, and step-limit exits are failures. Failed cases remain in the
denominator. This first version does not evaluate file creation or deletion
tasks, and equivalent-but-differently-formatted solutions fail exact matching.

The suite is bounded to 32 cases, 32 files per case, 64 KiB per input/output
file, and 1 MiB of combined fixture text. Tasks are at most 8,192 characters;
the default step budget is 12, configurable from 1 through 64. Filesystem
inspection also has entry/depth bounds. These are resource guards, not an OS
sandbox or a wall-clock timeout for arbitrary trusted host callbacks.

## Optional promotion gate

The host may opt into an additional native task gate with
`nl-agent-task-promotion-gate`:

```elisp
(require 'nl-agent-task-promotion)

(let ((gate (nl-agent-task-promotion-gate
             suite grammar :max-sequence 4096 :max-steps 12)))
  (nl-llm-agent-evolve-p5-queue
   model evaluate catalog-file grammar
   :promotion-gate gate))
```

This gate is used only after the ordinary score has passed the strict numeric
gain threshold. It then requires a strict increase in passed cases and zero
per-case regressions: every case that passed before must still pass afterward.
Infrastructure failures are errors and fail closed; they are not converted to
quality scores. The callback receives detached model copies and evaluates
private temporary native-service workspaces using only the read/edit task
tools. It does not publish a catalog or edit a real workspace.

This direct gate is a host opt-in API. It runs synchronously in the trusted
host process and must not be assumed to be nonblocking. The background runner
profile below is a separate worker/evidence path. A JSON configuration may opt
into that background path with the `taskPromotion` object; the synchronous
wrapper remains a caller-owned API and is not selected by JSON. `nl-agent-task-promotion-evaluate` supplies full
before/after reports and model hashes for the native evaluation path. Existing
positive tests use synthetic reports, while the native actual-task fixture
currently demonstrates only the negative `DONE` outcome. No checked positive
learned-model capability should be claimed.

The gate closure is trusted host configuration; it is not serialized into
queue checkpoints or model proposals. The JSON loader writes an immutable
policy manifest beside the canonical queue-state path before restoring jobs.
Reloading with a changed or removed `taskPromotion` object fails closed; a
queue without that manifest requires an explicit new queue-state path. The
manifest binds the detached policy and audit directory, while the runner
request still carries the raw-configuration scope for resume checks.
This is a persistence boundary, not protection against an operator deleting
the manifest or queue files.

The background runner exposes the same boundary through the optional JSON
`taskPromotion` object, which becomes the worker profile's detached
`:task-promotion` policy and `:task-audit-directory`. It canonicalizes and detaches the policy before
locking files, binds it into every request (including preview/resume), and
installs a fail-closed queue gate. The worker performs the task evaluation and
returns content-bound evidence from the trusted local worker; its hashes verify
consistency, not authentication. The host only recomputes that evidence's
reports and before/after weight hashes, never runs task inference itself. A
strict numeric gain is still required before the gate is consulted. The queue
verdict is durable. Before adoption, the host runner writes the validated
complete request/result envelope (including the bounded before/after reports
and model snapshots) through `nl-agent-task-audit-save` under the configured audit
directory. Records are UTF-8, mode 600, atomically created without replacement,
and bounded by the 256 MiB protocol limit; an audit-save failure blocks
adoption and leaves the attempt for explicit handling. These records are
durable evidence, not a final adoption decision or an authentication
signature.
Stopping a runner leaves its in-memory queue gate fail-closed; a newly
reconstructed queue must have the same policy and gate explicitly installed.
The policy closure is not serialized in queue checkpoints.

When the background profile has an audit directory, the model-visible
catalog includes the read-only `model.improvement.evaluation` tool in addition
to the ordinary five improvement tools. It accepts exactly `:scope`, `:id`,
and `:attempt`; the scope must equal the current runner profile scope before
the host reads any record. The tool returns only the bounded allowlisted
summary (counts, scores, task-criterion verdict, and an opaque reference),
never task text, fixture paths, model weights, or raw validation errors. Read
or validation failures are reported as the generic `evaluation unavailable`.
Lookup synchronously reads and validates the complete bounded audit envelope
on the trusted host (currently up to 256 MiB); it has no nonblocking or
low-latency guarantee. The tool performs no training, polling, queue mutation,
or publication. The status identity projection itself does not read audit
files, although the existing public status call may poll to finalize a child.

The value returned by `nl-agent-training-runner-start` carries a detached
`:evaluation-reference` with the same `:scope`, `:id`, and `:attempt`; the
public running status may carry that identity while its request is retained.
This is a stable lookup identity, not an assertion that an audit record is
ready and not an adoption decision. A caller may retain the original
reference and query it after an exact JSON reload even if queue history has
been trimmed. A reformatted or otherwise scope-changing configuration denies
the old reference, and there is no automatic index or reference discovery.
The `:task-accepted` field describes only the task-evaluation criterion;
numeric minimum-delta checks, compare/gate results, and publication may still
reject the candidate independently.

`examples/background-task-promotion-config.json` is a small relative-path
configuration example. It is opt-in data only: loading it does not start
training or publish a model, and its audit records do not claim learned task
capability.

## Same runtime, restricted tools

`nl-agent-task-eval-service-run` uses the public service constructor and
`nl-agent-runtime-run`, with a fresh session for every case and a fixed
provider-qualified model. It disables fallbacks and exposes only the
production workspace `read` and `edit` tools. There is no shell, arbitrary
Elisp, model switching, training, or publishing tool in this profile.

Read is limited to regular, strict UTF-8 files within the workspace, rejects
symlink paths, and has a 64 KiB byte limit. Runtime observations retain their
separate 4,000-character truncation rule; the bundled fixtures are smaller.
Edit uses the existing exact SEARCH/REPLACE implementation. Permissions are
still checked: the host preauthorizes those confined fixture edits, rather
than asking the model to approve itself.

This adapter runs the host service/runtime core directly under Emacs. It does
not start the packaged standalone supervisor. Host code and provider
implementations are trusted and share a process; the evaluator does not
protect its oracle from malicious host code or prove artifact identity by a
model display name. Real workspace edits and automatic conversation capture
are not enabled by running this suite.

## Representative microtasks

`nl-agent-task-suite-representative` supplies six versioned cases:

- A Japanese documentation command typo, preserving a changelog.
- An explicitly specified Elisp arithmetic expression correction.
- A coordinated function rename in a definition and its caller.
- A JSON value change, preserving neighboring settings.
- Selection of one file among similarly named files with matching text.
- A Unicode literal replacement, preserving an ASCII companion file.

These are deliberately small, mostly explicit edit instructions. They measure
basic instruction following and tool use, not repository-scale reasoning,
open-ended bug diagnosis, or parity with Hermes or large pretrained models.
Keep held-out tasks separate from training data: repeatedly optimizing against
these six visible fixtures alone can overfit this test.

Native candidates can use the opt-in
[file-actions-v1 grammar](../../nelisp-llm/docs/file-action-grammar.md) to choose
read, edit, or DONE with variable string arguments. Use the same grammar and
alphabet for every case and both model snapshots. Grammar reachability tests
with scripted logits are syntax tests, not file-task capability measurements.

## Fixed supervised learning probe

`examples/evaluate-supervised-file-tasks.el` is a manual, local-GPU experiment:

```sh
emacs -Q --batch -l examples/evaluate-supervised-file-tasks.el
```

It obtains 12 prompt/completion records from four synthetic training tasks
executed through the actual service and read/edit tools. The prompts retain
the full system message and actual observations. Two distinct held-out tasks
are evaluated with real native logits; their expected actions are not supplied
to training or the grammar. All workspaces are private temporary fixtures.

The fixed configuration is a 27,264-parameter UTF-8 P5 model (dimension 32,
feed-forward 64, one block/head), GPU Adam at 0.003, sequence 2048, and 16 epochs
(192 example steps). Inference uses context 4096, three steps, and the same
`file-actions-v1` profile with maximum field length 64 and default ASCII
alphabet. The before model is an isolated initial snapshot, not a model
trained a second time. Snapshot hashes are checked after training/evaluation.
Version 2 uses compact completion transfers and converts detached training
snapshots through the validated artifact-to-inference path. It evaluates the
initial snapshot before allocating the GPU training context, then exports a
fresh inference snapshot after training synchronization. Runtime errors abort
the experiment with bounded diagnostics rather than becoming quality scores.
The first, dense-transfer run incorrectly passed trainable PAV objects directly
to inference and failed on missing KV-cache metadata. Its zero scores are not
evidence about learned capability. Version 2 preserves that run's dataset,
model geometry, learning rate, epochs, and held-out criteria.

The final stdout S-expression records dataset/model hashes, settings, exact
file scores, and their comparison. Progress goes to stderr. There is no
success threshold assertion, hyperparameter retuning from held-out outcomes,
automatic publication, or real-user data collection. CPU completion loss is
not measured in this probe; its full-context host cost is separate from GPU
training. A single tiny deterministic run cannot establish generalization or
Hermes-level competence, including when its weights change successfully.

The completed version-2 run produced a valid **0/2 before, 0/2 after** result.
Both initial cases exhausted three steps. After training, one exhausted three
steps and the other returned `done`, but neither changed the required file to
its expected contents. There were no inference runtime errors. The initial
and trained snapshots remained unchanged during evaluation; training changed
the weights. The compact run's final weight digest also matched the original
dense run's final digest. Thus this run verifies the corrected execution path
and consistent updates, not improved file-editing capability.

Reproduction identities:

- Dataset SHA256: `1c2536d677b6280cc34a010cec6573ed9e43c342885aa2e99f99fe4df16a1a42`
- Example source SHA256: `47651088e72504800fb7a7bc24c7761ef6bc910e518c92646c4c168cb56036f0`
- Initial weights SHA256: `b0689a027fd4380699728ebcbeb368d7deff2032a683f3656d1fbc0fb22b8244`
- Trained weights SHA256: `ea37b59ac4bb02828ec97fca6e62840bca6273af604cfc8e52ccacf8fb8e9a76`

Further development must use separate training/development cases rather than
retuning against these two held-out outcomes.

The inexpensive `test/supervised-file-experiment-test.el` checks fixed
demonstrations, message-derived dataset identity, bounds, model geometry, real
exported-model service inference, and rejection of the original PAV wiring
error. It does not run GPU training or held-out tasks. Changing service prompt
semantics requires reviewing the frozen dataset digest, not silently retaining
the old experimental identity.

## Training/development action diagnosis

`examples/diagnose-supervised-file-tasks.el` is a separate manual local-GPU
diagnostic, not another held-out measurement:

```sh
emacs -Q --batch -l examples/diagnose-supervised-file-tasks.el
```

It reuses the fixed synthetic training demonstrations and training settings,
then runs the trained native model on both the four training tasks and two
separate development tasks. This separates failure to execute learned tasks
from failure to transfer to new tasks. It does not execute the frozen held-out
suite or change the original experiment. Development outcomes may guide
engineering, but must not be presented as independent generalization evidence.

The diagnostic reports actual file scores alongside bounded chronological
action/observation traces from the ordinary runtime. These traces contain
synthetic fixture text; full service prompts are not included. Truncation is
explicit. Runtime errors invalidate the diagnostic instead of becoming model
quality scores. Model hashes are checked around evaluation. No artifact is
published and no real workspace or conversation is used for training.

The cheap diagnostic tests belong to `make test`; the real GPU training run
remains manual. A scripted-provider test can verify trace collection and file
scoring but cannot establish learned task ability.

The first completed diagnostic scored **0/4 training tasks and 0/2 development
tasks**, with the same trained weight digest as experiment v2. All six initial
actions selected `read`, but none reproduced the required path. For example,
`train/status.txt` became `train/statumet`; later actions continued with wrong
arguments or returned `DONE` without the edit. Runtime plumbing completed;
tool denials/errors were ordinary observations. No trace field was truncated.
Thus the deficit already affects the training tasks, not just unseen-task
transfer. Accurate argument generation and recovery remain unlearned in this
run; this does not by itself distinguish insufficient data, training objective,
optimization, or model capacity. The original held-out suite was not rerun.

Diagnostic source SHA256:
`a400847d318e81ff7219ec77a05db07a1dd16137584521e2ccf19be4bee0d2ba`.

### Initialization transfer probe

`examples/diagnose-initialized-file-tasks.el` reuses this frozen diagnostic
with the opt-in model-creation API, `xorshift32`, and seed `0x1A2B3C4D`:

```sh
emacs -Q --batch -l examples/diagnose-initialized-file-tasks.el
```

Only the fresh model's matrix initialization changes. The wrapper verifies
the diagnostic source hash, intercepts exactly one construction, and restores
the constructor even on error. It keeps 12 training records, 16 epochs, 192
steps, model geometry, grammar, evaluation fixtures, and inference budgets
unchanged. The report includes the full underlying diagnostic, initializer,
seed, and constructor count. This probes whether the short-copy improvement
transfers to real file actions; it does not assume that it will. No held-out
suite is rerun and no model is published or selected as the service default.

The first completed GPU run finished all 192 steps but scored **0/4 training
and 0/2 development tasks**, unchanged from the earlier legacy-initialization
diagnostic. Every first action selected `read`, but all six paths were wrong:
`train/st`, `train/stat`, or `th ` instead of the required fixture paths.
Subsequent actions also had wrong arguments or ended without the edit. The
ordinary runtime returned denials/errors; no trace was truncated and no
runtime exception invalidated the run. Training and evaluation preserved the
expected model identities. Thus short-copy improvement did not transfer to
successful file actions under these fixed conditions. This does not establish
which of data, input length/representation, optimization, or capacity remains
limiting, and it does not justify a new service default.

Reproduction identities:

- Wrapper source SHA256: `a66db977a9f81b57a9c5f7666167abb1211ba93491709606f4425b63732e81bb`
- Training dataset SHA256: `1c2536d677b6280cc34a010cec6573ed9e43c342885aa2e99f99fe4df16a1a42`
- Initial model SHA256: `cfd16a5a0ca1ac1d5a1ef1e170ab8b46f17b3d92a9a9e37f73d51d98358d9fe3`
- Trained model SHA256: `15f0fa51c0e0441f4c5b4bfa1266feed28588a1c996553e4b0f447d60aa05750`

Model hashes here use the file experiment's digest format, not the short-copy
probe's format. The new eight ERT tests and strict compilation passed. The
complete agent `make test` also passed (host, standalone service, stdio/broker,
CLI, and compilation), including the new test file. These checks establish
tested infrastructure behavior, not the learned task capability that failed
above. The standalone binary was unchanged, SHA256
`bf60b852dfa877c93cf19cda538f426dd7b50f4b5dba4f945c944bb24b281cb7`.

A subsequent input-contract check intercepted the 12 actual provider calls
while replaying the frozen training demonstrations and rendered their message
histories with `nl-llm-agent--render`. Every resulting prompt exactly matched
the corresponding prompt reconstructed by `--records` from the completed
runtime responses. Thus no prompt-construction mismatch was observed for
these training demonstrations. This does not compare unseen recovery traces
or establish numerical GPU/native equivalence at their full context length.

## Teacher-forced training diagnostic

The frozen 12 training completions contain 741 byte tokens: 460 positions
are forced by the file-action grammar and 281 are grammar-choice positions.
The latter include action selection, string contents and delimiters, and
the final response; they are not solely path characters. Counting correct
forced syntax as learned argument accuracy would overstate model capability.

A teacher-forced diagnostic can isolate next-token learning from cascading
generation errors: consume the full real prompt, score the next gold token,
then consume that gold token even if the model predicted something else.
Report unrestricted token accuracy and completion negative log likelihood
separately from grammar-choice accuracy. The first incorrect grammar-choice
prediction localizes a failure under a correct prefix. These are training
diagnostics, not unforced generation scores or held-out agent capability.
The actual read/edit task evaluator remains the end-to-end quality check.

The opt-in `examples/diagnose-file-teacher-forcing.el` wrapper retains the
complete initialized-file diagnostic and its ordinary free-running task
results, then scores the same 12 training records with native byte-code
inference. It checks dataset and trained-model identities before scoring and
model immutability afterward. It does not publish an artifact or change the
service's model. Run it manually from `dev/nelisp-agent`:

```sh
emacs -Q --batch \
  --eval '(setq nl-agent-file-teacher-forcing-auto-run t)' \
  -l examples/diagnose-file-teacher-forcing.el
```

This command repeats the fixed local GPU training experiment before scoring;
loading the file without opting in does not train. The mock scorer and
orchestration tests belong to `make test-emacs`; the real experiment does not.

The independent 2026-09-07 run reproduced the previous trained-model SHA256
`15f0fa51c0e0441f4c5b4bfa1266feed28588a1c996553e4b0f447d60aa05750`
after the same 192 GPU updates. Free-running file scores remained 0/4 training
and 0/2 development. Teacher-forced scores were:

| Training completion | Unrestricted top-1 tokens | Grammar-choice tokens | All choices correct, with gold history |
| --- | ---: | ---: | ---: |
| Read | 227/252 | 62/72 | 0/4 |
| Edit | 342/429 | 122/165 | 0/4 |
| DONE | 60/60 | 44/44 | 4/4 |
| Total | 629/741 | 228/281 | 4/12 |

Total completion NLL was `335.5028705446427`, or `0.45277040559331`
per token (natural logarithms). Every read/edit completion first diverged
inside its path, even with the correct prompt and preceding gold characters.
For the first read actions, status closed the string after `train/st`, color
selected `s` instead of `c` after `train/`, mode selected `h` instead of `r`
after `t`, and state closed the string after `train/stat`. These first
divergences also match the ordinary first-action traces. Subsequent teacher
forcing repairs each prefix for measurement, not for tool execution.

The four correct DONE completions all use the same text and correct prior
tool histories; they do not demonstrate successful edits or error recovery.
This result rules out cascading generation errors as the sole explanation
under these conditions. It does not distinguish insufficient data, objective,
optimization, context representation, or capacity as the underlying cause.
There was no model promotion or service-default change.

The nine new ERT checks and 17 existing related checks passed, as did strict
compilation. Independent checks confirmed the 741/281 token counts, uniform
logit NLL of `741 * log(256)`, and identical source/byte-code teacher scores
for a small native UTF-8 fixture. The full service suite was not rerun for
this diagnostic-only change. Source SHA256:
`7b7ffda31315b48d02871652970554490b6db04a44b4e5096ad427d96f03638d`.

## Grammar-choice-only loss comparison

`examples/compare-file-choice-loss.el` runs the frozen teacher-forcing
diagnostic in either explicit `completion` or `grammar-choice` mode. Both
retain its complete free-running file-task evaluation and teacher-forced
training scores. The former forwards the original training call unchanged;
the latter adds sparse `:loss-masks` selecting only grammar `:allow`
positions. Gold syntax and prompt tokens remain in the context, but forced
syntax no longer contributes direct loss. Each example's gradient is
normalized by its number of selected targets, not by all completion tokens.

For the fixed 12 records, this changes the selected target count from 741 to
281 without changing the token sequences, model initialization, 192 update
steps, learning rate, ordering, or task suites. The wrapper reports the
actual selection-mask digest and the selected mode outside the frozen
diagnostic; consumers must retain that outer objective annotation.
The inherited teacher-forced NLL still scores all 741 completion tokens,
including forced syntax. It is not the grammar-choice training objective;
its absolute value must not be mistaken for the candidate's selected-target
training loss.

Run either arm manually from `dev/nelisp-agent`, for example:

```sh
emacs -Q --batch -l examples/compare-file-choice-loss.el \
  --eval "(let ((print-length nil) (print-level nil)) (prin1 (nl-agent-file-choice-loss-run 'grammar-choice)) (terpri))"
```

Use `'completion` for the reference arm. This is an experimental objective,
not a service default or an automatic promotion rule. The intended primary
comparison is successful file edits; token accuracy or lower loss alone is
insufficient. It does not use development examples as training targets.

The independent paired run on 2026-09-07 completed both arms and checked
equal initial-model, dataset, geometry, training, and inference settings.
The reference exactly reproduced its previous trained-model digest and
teacher-forced scores.

| Measurement | Completion loss | Grammar-choice loss |
| --- | ---: | ---: |
| Training file tasks completed | 0/4 | 0/4 |
| Development file tasks completed | 0/2 | 0/2 |
| Teacher-forced choice tokens correct | 228/281 | 247/281 |
| Teacher-forced read choices correct | 62/72 | 67/72 |
| Teacher-forced edit choices correct | 122/165 | 136/165 |
| Completions with all choices correct, gold history | 4/12 | 5/12 |

The candidate correctly read `train/state.txt` in the real runtime and
selected the same correct path for its edit, but its search string was wrong
and no edit occurred. Its mode task generated `train/mode.txtxtxtxtxtxt`
instead of ending the path. Status and color retained their earlier first
path errors. Thus choice prediction improved in this small inspected
training set, without improving complete task success or development scores.
The candidate is not promoted and no service default changes.

The inherited unrestricted score fell from 629/741 to 268/741 and mean
all-completion NLL rose from `0.45277040559331` to `3.9885499246101035`.
These include syntax deliberately excluded from candidate training; they
are retained as diagnostics, not substituted for the task metric or called
the candidate's selected-target training loss.

Reproduction identities:

- Reference mask SHA256: `313e7b86ca08f1233889c42f8f9bfeec8950f785084d630d3a190926c5f0b47f`
- Candidate mask SHA256: `052cc27f334ab2e6932084658380d66472d7b3196c8ca7d5d9d0e08bf72e2d43`
- Candidate trained-model SHA256: `f8bba7aedd1a8d0632dedce0574ef7d5cac06e722b0a91267707e3cdc45d3edc`
- Comparison source SHA256: `bc8f1a92ffe41289a1f02324bac9b58e1f8fda0bad73acfec66c125cced331f3`

Eight wrapper/data ERT tests and strict compilation passed. The separate
engine tests covered six sparse-plan checks and real CPU/GPU SGD parity in
four padding/window configurations. Existing completion, compact-transfer,
epoch-shuffle, and real child-worker resume checks also passed. The full
service suite was not rerun for this change.

## Reports and comparison

Reports use `nl-agent-task-eval-v1`, with per-case status, steps, failure
codes, and expected/actual SHA256 hashes rather than file plaintext. The
aggregate is `passed / total`, not the rate of `DONE` responses. A suite hash
binds the canonical fixture contents, tasks, case order, protocol, step budget,
and runner identity. File entries are canonically sorted; case order is kept.
The service runner identity is `nl-agent-file-task-runtime-v1`.

`nl-agent-task-eval-compare` validates both reports, recomputes aggregates, and
requires matching suite identity, expected file hashes, case order, step
budget, and runner profile before reporting score/count deltas. It intentionally
allows different model IDs. This is a consistency check on trusted host
reports, not a signature, an independent audit, or an automatic deployment
decision. Preserve the actual model artifacts and their catalog hashes when
using reports as experiment evidence.

## Evaluate a native artifact

From `dev/nelisp-agent`, using an existing trusted local catalog:

```sh
bin/nelisp-agent-eval --native-catalog state/models/catalog.json \
  --model native/self-g1 --max-steps 12
```

The paths and selector are examples; this command does not supply pretrained
weights or create an initial catalog. The Japanese suite requires a compatible
UTF-8 model with enough context capacity. One JSON report is written to stdout.
Exit code 0 means a report was produced, including a legitimate score of zero;
invalid command/setup options exit 2 with a diagnostic on stderr. Per-case
runtime errors remain failed cases in a valid report. No remote inference
provider is configured by this command. `NELISP_AGENT_EMACS` can select the
host Emacs executable.

## Verification and limits

`make test` includes core evaluator checks, restricted service-adapter checks,
and the six-case integration fixture. `make test-task-eval` runs only the
focused file-tool/evaluation checks. The integration runs real production
read/edit tools with independently authored scripted actions, then invokes
real native inference and the actual CLI with a tiny UTF-8 artifact whose
grammar forces `DONE baseline`. The expected measurement for that native
wiring fixture is **0/6**: no requested file has changed. This is not an
unconstrained model-quality baseline or a before/after training experiment.

The positive scripted-provider tests demonstrate that the evaluator can
recognize correct edits; they do not demonstrate a learned model improvement.
Likewise, tiny grammar-constrained native fixtures establish inference wiring,
not useful pretrained capability. A passing implementation test can correctly
assert a model score of zero.

See [native service startup](native-service.md),
[Unicode model identity](unicode-models.md), and
[opt-in trajectory curation](trajectory-curation.md) for the separate model
selection, encoding, and approved training-data boundaries.
