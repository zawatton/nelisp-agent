# Background training design

Status: experimental initial background mode. CPU training and a responsive
service conversation have been exercised together; a tiny Vulkan GPU Adam
child has also passed its smoke test. GPU checkpoint/resume after an observed
normal stop is supported through an explicitly authorized service operation.
The packaged service executes training synchronously unless
`training.execution` is explicitly set to `"background"`.

This increment trains the project's own bounded P5 model from trajectory data.
It does not reconstruct a hosted free model, implement teacher distillation,
search model architectures, or autonomously modify NeLisp's source/runtime.
Those require separate data, evaluation, and deployment policies.

In background mode, the improvement tool starts a dedicated training process
and returns a public job identifier. The child trains and evaluates an isolated
candidate while the host continues serving conversation requests. Its process
sentinel, or an explicit status poll, finalizes the result on the host.

## Selecting completion-only training

Set `training.objective` to `"completion"` in an improvement configuration to
register `supervised-finetune` alongside the legacy handler. Omission or
`"trajectory"` preserves the existing catalog. The generic submission tool
still requires an explicit kind; this setting does not reinterpret legacy
payloads. A minimal training section is:

```json
{"objective":"completion","execution":"background",
 "backend":"cpu","optimizer":"sgd","sequence":256}
```

`examples/background-completion-config.json` is a complete opt-in example with
separate state paths. It starts a small project-native model, not reconstructed
weights from a hosted free model. Its sample benchmark is a wiring placeholder,
not an adequate production quality gate. Replace it with a fixed task-relevant
evaluation design before relying on learned behavior.

The ordinary completion configuration rejects `checkpointEvery` and
`checkpointDirectory` unless all durable-worker conditions are present:
background execution, GPU backend, a positive interval, and a checkpoint
directory. Synchronous completion remains an ephemeral public-wrapper path;
CPU checkpoint/resume and zero/incomplete checkpoint settings are rejected.
`examples/background-resumable-completion-config.json` shows the opt-in worker
profile with separate state paths. Pending jobs can still be saved and
restored, and the handler is registered before restoration. Loading
configuration does not launch GPU training. The sample benchmark is only a
wiring placeholder, not a practical quality gate.

The existing write-risk `model.improvement.submit` and execute-risk
`model.improvement.run` tools keep their separate authorization checks. Enabling
an objective does not grant either permission or approve captured records.

The configuration/tool increment passes seven configuration and eight
supervised-curation ERT tests, plus existing host, CLI, configuration, and
curation regressions. An independent synthetic check loaded a completion
configuration, admitted a record through the approved curation tool, ran a real
CPU child through the improvement tool, and published one candidate. A separate
synchronous GPU check observed zero enable calls during configuration loading
and one at execution, followed by promotion in its disposable catalog. These
checks do not establish useful task ability. The separate standalone
conversation check is described below.

## Ownership

The service host owns queue admission, permissions, the champion generation,
publication, model activation, and the lifetime of the queue and catalog locks.
It is the only writer of queue state and the public artifact catalog. A
training subprocess owns one isolated candidate and its optimizer buffers. It
receives a bounded data manifest and a private model snapshot, without
inference credentials or general tool capabilities.

The subprocess must not load the ordinary service assembly and independently
write the same queue or catalog. Two mutable queue copies can otherwise lose
submissions, reuse generations, or publish results against different parents.

## Transaction

1. Validate and authorize a queued job. Capture its parent generation and score,
   private model snapshot, configuration digest, and execution attempt id.
2. Persist running state and the private input manifest before starting the
   subprocess. Return the job id promptly to the conversational worker.
3. Poll the actual process handle and expose bounded progress through status.
   Checkpoint files supply recovery data; their presence is not proof of a live
   process. A slow poll does not authorize restarting a second writer.
4. On successful exit, validate the result artifact, attempt, request SHA-256,
   and unchanged parent. The fixed trusted child evaluator returns a score with
   its candidate snapshot; the host applies its existing promotion gate and
   publish-before-commit transaction. Model output cannot supply this score.
5. Persist terminal queue state before deleting private recovery files. Model
   activation remains a separate service request using the published catalog.

## JSON task-promotion integration

The optional [`taskPromotion` configuration example](../examples/background-task-promotion-config.json)
connects task evaluation to the background runner. See the
[task-evaluation contract](task-evaluation.md) for the suite, grammar, and
evidence rules. This is an opt-in background policy: the model-visible
`model.improvement.submit`, `model.improvement.run`, and status interfaces keep
their existing queue, authorization, and polling contract. The model does not
choose the evaluator or grant itself permission to use it.

For an enabled job, the isolated child runs the configured task suite and
returns the bounded before/after evidence. The host validates the request,
policy, reports, and weight identities, writes the audit envelope, and only
then lets the queue's promotion transaction run; task inference is not moved
into the host. A numeric score gain is necessary but insufficient: insufficient
task improvement, per-case regressions, or malformed evidence reject the
candidate and leave the active model unchanged. If audit writing fails,
publication is prevented and the worker attempt is retained for explicit
diagnostics.

The queue-side policy manifest binds the detached policy and audit directory
to the queue state. Omitting or changing `taskPromotion` on reload fails
closed, and applying the policy to an existing queue without a matching
manifest requires a new queue state. This prevents policy omission, policy
substitution, and accidental migration of pending jobs into a differently
governed queue. The audit record is evidence for the adoption transaction,
not an independent signature or an automatic publication mechanism. The
manifest is a binding and fail-closed check, not protection against a trusted
operator deleting or changing the queue state and manifest.

The same data boundary remains in force: captured user data is used only when
explicitly authorized, the worker receives only its bounded manifest and
task tools, and neither the task policy nor the worker may modify NeLisp's
source or runtime. The example documents integration and safety plumbing, not
a claim of useful learned task capability; this integration is not a
competence benchmark.

Initially permit one active training job per service. Acquire exclusive service
ownership before opening a shared mutable queue/catalog. The example
`examples/background-improvement-config.json` uses GPU Adam. The worker has
passed a tiny GPU smoke test, not a capacity or throughput qualification of
that example profile. CPU/SGD is also supported. Parallel candidates need an
explicit policy for stale-parent results
before increasing this limit.

Locks are advisory. Do not share these mutable paths with an already-running
synchronous host or a legacy host that does not honor the locks. The current
configuration loader rejects paths already owned by a background runner.

## Recovery and cancellation

Pending, running, and interrupted jobs consume outstanding capacity. Completed
history retention must not remove interrupted work. A host restart records a
running job as interrupted and does not replay it. With GPU checkpointing and a
recovery directory configured, normal stop saves a validated recovery receipt.
An explicit authorized resume can start a new attempt from that receipt with
unchanged configuration, parent, payload, and benchmark. The previous attempt
cannot later publish a result. Abrupt host death or an unresolved active marker
does not authorize replay or automatic orphan adoption.

`examples/background-resumable-improvement-config.json` enables GPU Adam
checkpointing every 16 steps and a separate private recovery directory. Keep
the configuration unchanged across restarts: the scope includes its digest.
This example profile is not capacity- or throughput-qualified; the integration
tests use tiny models. CPU checkpoint/resume remains unsupported.

Private snapshots for interrupted attempts or failed queue persistence are
retained. Their recovery and retention/purge policy is unfinished; cancelling
an interrupted queue entry is not a guarantee that its background files are
removed.

The guarded `model.improvement.cancel` tool now also cancels a live background
job. The runner suppresses completion callbacks, observes the child stop,
persists `interrupted`, then persists `cancelled`. Only then may it remove that
runner's known private attempt. Queue/catalog ownership stays with the service,
so it can start the next job. Cancelling a different pending job does not stop
the active child. Synchronous queues retain their previous cancellation rules.

| Failure point | Retained state | Recovery |
| --- | --- | --- |
| Child does not stop | Live handle, claim, ownership | Retry cancellation; never publish the late result |
| Interrupt save fails | Running claim, stopped child, private snapshot | Retry the same job's cancellation |
| Cancel save fails | Interrupted job, private snapshot association | Retry cancellation; no training replay |
| Post-commit file cleanup fails | Durable cancelled job and cleanup warning | Service remains reusable; files need deliberate cleanup |

Cleanup-failure references are host-memory diagnostics, not a durable retention
index. A restarted runner does not guess ownership of old attempt directories.
Normal host shutdown attempts training and every MCP connection cleanup even
if one fails, then reports the first error. An assembly error is not replaced
by a secondary cleanup error. The supervisor's shutdown callback still has its
existing exactly-once semantics; this is not an automatic shutdown retry loop.

## Verified evidence

- The CPU child protocol and isolated worker path have been exercised.
- `test/training-worker-test.el` verifies a real tiny CPU child improves its
  fixed benchmark and changes weights, plus a real Vulkan GPU Adam child.
- `test/background-service-test.el` starts training through the actual
  improvement tool router, completes a conversation on the same live service
  while the child waits at a test-only barrier, then releases it to perform real
  CPU training and publish a measured improvement. The barrier makes ordering
  deterministic; this is not a throughput or simultaneous GPU-compute benchmark.
- That test also discovers the new model, activates it through the guarded
  model-switch tool, and runs the real native inference policy. All loaded
  inference tensors, including the independent output head, match the promoted
  artifact. The same worker remains alive and the earlier conversation is a
  prefix of the later checkpoint. An unavailable-model switch preserves state.
- `test/training-cancel-test.el` covers live child cancellation, retained locks,
  late callbacks, permission denial, persistence failures with retry, cleanup
  failure, and successful subsequent real CPU training.
- `test/host-cleanup-test.el` injects independent cleanup failures and verifies
  all owned resources get a close attempt without masking an assembly error.
- `test/background-resume-service-test.el` stops a real GPU child after a
  durable checkpoint, reloads the service configuration without automatic
  execution, rejects an unauthorized resume, and resumes through the approved
  tool. It checks a new attempt, active-marker lifetime, evaluation, promotion,
  and terminal receipt cleanup.
- `test/training-runner-resume-test.el` exercises receipt-save and queue-save
  failures with retry, pre-spawn quit, active-marker blocking, replacement by
  a later stopped attempt, cancellation of a resumed child, and isolation from
  a late result in an old attempt directory. Receipt-store unit tests also
  cover malformed data, symbolic links, and attempt-scoped replacement/removal.
- Host ownership, bounded protocol validation, and queue-state publication stay
  on the host; the child receives only its private snapshot and fixed-evaluator
  inputs.

## Native context and execution

The CPU policy preserves the full rendered conversation. It rejects a prompt
larger than the configured context capacity before allocating caches or
executing model steps. Generation can still exhaust the remaining capacity;
an arbitrary grammar's eventual output length is not known in advance. Every
decoder step checks all block caches before modifying any of them for capacity
or cache-layout errors. This is not a transaction for arbitrary weight or
numeric errors that occur after computation starts.

The native policy defaults to `nl-llm-agent-model-inference-mode = auto`.
Before each valid invocation, the in-memory inference adapter prepares a
measured allowlist of numeric functions when an Emacs byte compiler is
available. Standalone NeLisp falls back to its existing execution path.
`source` restores only bindings installed and still owned by the adapter;
`byte-code` instead treats compiler unavailability or failure as an error.
These bindings are shared process-wide, not isolated per model session.

The adapter checks function definitions and compilation metadata between
invocations. External redefinitions are preserved, and stale owned code is
replaced as a group. Compilation finishes before installation, and changes
detected during compilation abort installation. Compiler macros and byte
optimization are disabled for this adapter so stale accessor expansions and
implicit dependency compilation cannot bypass a redefinition. It writes no
`.elc` files. This is a between-turn refresh mechanism, not safe simultaneous
runtime/structure replacement in the middle of decoding, nor authorization for
a model to edit source code.

`../nelisp-llm/examples/bench-native-inference.el` compares source execution
with selected numeric functions byte-compiled in memory. Its deterministic
tiny P5 model has an independent output head. It checks every logit at 128
positions and runs the real constrained policy with a 2,800-character prompt.
One Emacs 31.1 development measurement was 10.853 seconds from source versus
1.476 seconds with ordinary compiler optimization (7.35 times faster), with
identical output and zero measured logit difference. A separate run of the
production `auto` adapter, after restoring source dependency definitions and
properties, took 1.696 seconds (6.40 times faster) with identical output.
The production adapter deliberately uses more conservative compiler settings.
These are tiny-model microbenchmarks, not evidence of model quality or
throughput at useful model sizes. Attention still scans
the accumulated cache, so full-history prefill remains quadratic in length.

The actual background-service capstone uses the default `auto` mode without
preloading the compiler. It checks that both decoder entry points are running
byte-code after real native inference. A subsequent full service-suite run
measured 1.972 seconds for its unchanged 2,802-character prompt and 4,096-position
cache, versus 12.030 seconds in the earlier source run. The complete capstone
took 42.855 seconds, including process startup, training, and protocol work.
The model is tiny and grammar-constrained; these development timings do not
establish useful language capability, long-context scaling, or an SLA.

## Worker recovery protocol

The v1 request also accepts an optional string `:kind`. Omission or
`"trajectory-finetune"` retains the legacy whole-trajectory objective and its
existing request-binding digest. `"supervised-finetune"` carries explicit
prompt/completion pairs and trains only completion targets through the public
supervised trainer on the ordinary no-checkpoint path. Its kind is included in
the semantic request binding; durable checkpoint/resume uses the isolated
worker protocol described below.
Neither kind changes the trusted profile's fixed string-vector benchmark;
completion-only training does not implicitly change the publication metric.

The isolated worker wire protocol now supports supervised GPU checkpoints and
resume. A supervised request carries `:kind "supervised-finetune"`; the worker
derives its canonical completion plan from the prompt/completion payload and
training profile. A checkpoint stores that plan, and an optional
`:resume-state` carries the validated private checkpoint so the worker can
restore the bound model, optimizer state, and progress together. This is an
isolated worker/protocol capability, not an automatic queue or service recovery
path.

The public synchronous supervised wrapper remains ephemeral. The background
GPU configuration and runner connect this durable supervised checkpoint path
when the positive-cadence and recovery-directory requirements are met; CPU,
synchronous, zero/incomplete checkpoint settings remain rejected. The ordinary
no-checkpoint supervised path is unchanged. Recovery still requires an
explicit authorized resume and never starts automatically; this is not a claim
of model quality.

Independent checks matched CPU worker weights exactly to a direct supervised
training call with a two-token prompt. A real isolated GPU Adam child also
updated candidate weights and returned a matching request hash. These are
tiny-model protocol checks, not evidence of useful task competence.

The trusted host runner routes valid background GPU supervised checkpoint
requests and explicit resume operations through the isolated worker wire state.
Configuration rejects synchronous/CPU/incomplete checkpoint profiles before
runner assembly; the runner itself requires a GPU backend, positive cadence,
and recovery directory. It fails closed without changing pending/interrupted
state and never auto-restarts a job. The ordinary supervised admission and
no-checkpoint execution path remain separate, and the default curation and
queue kind remains legacy. See `trajectory-curation.md` for registration.

The currently verified integration loads the JSON completion configuration,
observes a GPU checkpoint at completed step 1 of 4, stops the child, reloads
without automatic execution, rejects an unscoped resume, then resumes through
the scoped approval path. The candidate is promoted and its catalog/history
metadata are retained. This tiny integration verifies wiring and recovery
boundaries, not model competence; the public synchronous wrapper remains
unsupported for durable completion resume.

The focused regression run passes 74 protocol, worker, runner, recovery,
cancellation, and supervised-curation tests, including the real supervised GPU
Adam child and legacy GPU resume tests. Another ten configuration/service tests
pass, including conversation during legacy background training. This is not a
claim that the full standalone suite was exercised by that increment.

The subsequent `background-service-test.el` extension runs both legacy and
completion objectives against the real standalone NeLisp service process.
Completion mode is assembled from JSON configuration, and the test reads the
actual child request file to check the supervised kind and prompt/completion
boundary. A child-side readiness barrier proves the same conversation process
can finish its response while the training child is live. After releasing the
child, the test checks promotion, provider-qualified catalog discovery,
transactional rejection of a nonexistent model, and activation of the trained
native model without replacing the conversation process or losing history.
Loaded inference weights match the published artifact and inference uses the
byte-compiled decode path. Both ERT cases pass. The remote provider is a local
deterministic fixture; this test makes no external model API calls.

The positive completion fixture uses a two-space prompt and completion `a`,
CPU SGD at 0.1 for four steps, with the fixed benchmark `" a"`. This is a
controlled connection test, not a generalization benchmark. An earlier
synthetic prompt `" x"` worsened that fixed score from `-5.50985949793582` to
`-6.402387347678262` and was correctly rejected; the gate was not relaxed.
Using two spaces makes the fixture's context consistent with its simple
benchmark and reaches `-4.043234815182029` in the independent CPU check.

An isolated fault-injection run removed only `:kind` from the serialized
supervised request and made the new test fail on the observed missing kind.
No production file was changed for that experiment. These checks establish
process separation and model-switch plumbing, not simultaneous GPU compute,
throughput, useful learned agent behavior, or completion checkpoint recovery.

Recovery must restore the candidate weights, optimizer moments, and flattened
epoch/example position together. Restarting from the champion or restoring
weights with a fresh Adam optimizer is not equivalent to resuming training.

The isolated worker extension uses an optional positive `:checkpoint-every`
in its GPU supervised training descriptor and an optional data-only
`:resume-state` in the supervised request. The latter is a validated private
training checkpoint, not a filename or executable callback. An unchanged
supervised request keeps the existing one-shot path. CPU checkpoint/resume is
not enabled by this extension; the public synchronous wrapper and unsupported
option guards remain unchanged.

The reserved `checkpoint.sexp` beside the result file contains a progress
envelope with the producing attempt id, request SHA-256, and checkpoint state.
The worker writes only its private attempt directory. Checkpoint state binds
the job, payload digest, configuration scope, parent generation/score, sequence,
optimizer, architecture, and planned/completed steps. Intermediate state is not
a model publication and is never evidence that its producing process is alive.

The wire state additionally carries a semantic request digest covering the
exact parent snapshot, benchmark, payload, job, scope, parent generation/score,
backend, sequence, and optimizer. The new attempt id and checkpoint interval
are excluded. Reusing a scope string alone must not permit resuming against a
different benchmark or parent. The extra binding is validated and removed
before passing the state to the existing model/optimizer restoration API.

Service integration performs these host-owned steps for background resume:

1. Observe the original process stop before accepting its final recovery state.
2. Validate the envelope against the original immutable request and known hash.
3. Durably associate the validated state with the interrupted queue job, without
   trusting a model-supplied path or scanning arbitrary old attempt directories.
4. Require an explicit authorized resume and an unchanged parent/configuration.
5. Create a new attempt and copy validated recovery data into its new request;
   never reuse the old process, result file, or attempt id.
6. Publish only a completed, newly evaluated result through the existing host
   promotion gate. Retain recoverable data when persistence fails.

The host stores this durable association only after observing its owned child
stop. A checkpoint left by an unknown or orphaned process is not sufficient.
Normal-stop integration does not establish arbitrary host-crash recovery.

`test/training-resume-protocol-test.el` exercises legacy compatibility, strict
state/envelope validation, exact optimizer tensor lengths, detached restoration
state, semantic digest stability across serialization, and size limits.
`test/training-resume-worker-test.el` runs four real GPU Adam child processes:
an uninterrupted baseline, an attempt interrupted by a test-only error after a
durable first-step checkpoint, a resumed attempt, and an already-completed
resume. Two distinct examples over two epochs distinguish the correct example
cursor from a restart at the first example. The resumed child performs exactly
three remaining updates, and the completed resume performs none. Full model
checkpoints, Adam tensors, and optimizer counters match the uninterrupted
baseline exactly. The result model matches its final checkpoint, including its
four-step per-job cursor; this is not a lifetime training-step count. The test
does not simulate arbitrary host death, a torn write, or orphan recovery.

## Host recovery lifecycle

The recovery design uses a separate host-owned receipt directory. A receipt
contains the original request, its known hash, and the validated progress
envelope; it does not contain a path selected by the model. Receipt names are
derived from the configuration scope and job id. The host must hold the
directory ownership lock for read/compare/write operations. Atomic file
replacement alone is not cross-process compare-and-swap protection.

A resumed attempt also requires a durable active marker **before** the child
is spawned. Keeping an old stopped receipt eligible during a later attempt
would allow a host restart to launch a duplicate while the later child might
still be alive. An active marker therefore blocks recovery loading until the
owning host proves no child was spawned, or observes that child stop. A crash
with a marker remains an unresolved attempt, not permission to replay work.

| Durable state | What the host may infer | Recovery action |
| --- | --- | --- |
| Stopped receipt, no active marker | A producing attempt was observed stopped | Explicit resume still requires an interrupted job, unchanged inputs, and authorization |
| Active marker present | A later attempt may exist | Reject recovery loading; do not infer liveness from checkpoint files |
| New stopped checkpoint saved, marker cleanup incomplete | Stop persistence did not fully finish | Retry the owned stop transaction; do not replay automatically |
| Terminal queue result, receipt cleanup failed | Training result is already committed | Retain cleanup diagnostics; do not retrain |

Old private attempt directories are retained unless their exact ownership is
already known to the running host's cleanup path. The receipt store does not
scan, adopt, or recursively remove arbitrary directories.

## Remaining validation

- Submission and status responsiveness during GPU work, and capacity/throughput
  qualification for the example GPU Adam profile.
- Recovery under abrupt host death and filesystem failures. Explicit
  normal-stop resume and tiny-model optimizer/weight equivalence are covered;
  they do not establish power-loss durability or general crash recovery.
- Concurrent submissions and host restart without lost jobs, including late
  output and stale-parent rejection.
- Recovery of orphaned child processes after abrupt host death; an old private
  result must never be treated as a new attempt or replayed automatically.
- Practical native inference latency at useful model sizes and context lengths.
  The measured improvement above preserves full-history CPU prefill; it does
  not eliminate its scaling cost or establish production model quality.

The child executes fixed trusted training code, not model-generated programs.
Environment filtering is not an operating-system sandbox. This design is an
ownership boundary, not an arbitrary self-edit safety guarantee, and makes no
claim of Hermes parity.
