# Host-evaluated trajectory curation

Captured trajectories are unverified observations. Curation is a separate
host-owned operation that selects a record for an inert improvement proposal;
it is neither automatic success labeling nor permission to train or publish.

## Authority and data flow

A trusted host configures a record directory, evaluator function, versioned
policy identifier, data-use approval, holdout source hashes, and bounded
learning parameters. A model can request a record identifier, but cannot
supply an evaluator, path, acceptance flag, replacement examples, metadata,
learning rate, or epoch count through the curation tool.

The curator reads one bounded immutable record snapshot and binds its exact
bytes with SHA-256. It rejects unsupported records and configured holdout
hashes before invoking the trusted evaluator. The evaluator receives a
detached record and must return an explicit acceptance decision and reason.
Changing that copy must not change the retained source or generated payload.
The original capture file remains `unverified` and is never overwritten.

The `model.improvement.curate` tool is a write-risk operation. Approval to
curate creates a pending `trajectory-finetune` proposal through the existing
queue, with source and policy provenance. Running the proposal still crosses
the ordinary execute permission and fixed model-evaluation/promotion gate.
The ordinary bounded self-evolution autonomy policy does not implicitly grant
this new curation operation.

## What an evaluator proves

The host must choose checks appropriate to the task. For example, a verifier
can independently inspect a specified test artifact and compare it with a
fixed expectation, rather than trusting a completion sentence. Such a check
proves the checked property at evaluation time, not necessarily which actor
created the artifact or the correctness of every action in the trajectory.
An evaluator that merely returns true confers no meaningful quality evidence.

Data-use approval is a host attestation, not an automated license or secret
detector. The policy identifier must change when policy semantics change; it
is not an automatically derived hash of arbitrary callback code. Exact source
hash exclusion prevents reuse of listed files only, not semantic train/test
leakage or alternate serialization of equivalent records.

## Training representation

Each assistant turn is paired with its preceding task-local context using the
native message renderer. The first user message has the runtime's `TASK:`
prefix; subsequent user inputs are the observations actually presented by the
runtime, including its observation-length bound. Tool implementation objects
and full session history are not added to training examples.

Capture does not retain the historical system prompt or previous conversation,
so these are reconstructed task-local examples, not exact original full-session
prompts. The default trajectory trainer uses full-sequence language-model loss;
the explicitly selected supervised kind trains only completion targets.
Unsupported characters, excessive example counts, and overlong
sequences are rejected, never silently stripped or shortened to fit.
The fine-tune contract accepts 1–128 examples of 2–4,096 characters and at most
65,536 characters in total. Each encoded example is also limited to 4,096
tokens. The default `ascii-char-v1` profile accepts printable ASCII and newlines
only. An explicitly configured `utf8-byte-v1` curator can process Japanese and
other Unicode scalar text for a matching 256-vocabulary model. Registration and
submission reject a curator/queue tokenizer mismatch, even for ASCII-only
examples. See [Unicode model identity](unicode-models.md) for encoding and
compatibility requirements.

An opt-in [completion-only training API](../../nelisp-llm/docs/completion-training.md)
can consume approved records through the opt-in host API below. The queue and
background worker preserve these boundaries for the supervised kind. Durable
optimizer checkpoints remain limited to the legacy full-sequence objective.

### Preparing completion-only examples

`nl-agent-curation-prepare-supervised CONTEXT RECORD-ID` reads one immutable
snapshot, applies the curator's existing source-hash holdout exclusion and
trusted evaluator, and returns a `nl-agent-curation-supervised-v1` result.
Its `:examples` vector contains explicit `(:prompt STRING :completion STRING)`
pairs, with the exact assistant text as the completion. Context rendering and
observation truncation match the legacy curator. This remains reconstructed
task-local context, not the original uncaptured system/session prompt.

The result includes `:lr`, `:epochs`, existing source/policy/evidence metadata,
and `:encoding` from the supervised encoder. Encoding records byte-aware
completion boundaries for `utf8-byte-v1` and a boundary-sensitive dataset
digest. All examples are validated before evaluation. Preparing examples does
not train, start a GPU, submit a queue job, or publish a model.

There is deliberately no `:payload` field: this result is not a legacy
`trajectory-finetune` queue proposal. A trusted host can explicitly train a
detached candidate of the matching tokenizer using the existing API:

```elisp
(let ((prepared (nl-agent-curation-prepare-supervised curator record-id)))
  (nl-llm-agent-supervised-train
   candidate (plist-get prepared :examples)
   :backend 'cpu :optimizer 'sgd
   :lr (plist-get prepared :lr) :epochs (plist-get prepared :epochs)))
```

`candidate` must be a host-owned model copy, not the serving champion. This
call mutates it; independent evaluation and any publication remain separate
host decisions. The encoded report is evidence, not a trusted plan accepted
instead of input validation by the training API. Model-facing curation tools
use the legacy path unless the host explicitly registers the supervised kind.

### Persistent completion-only proposals

A trusted host can explicitly add the `supervised-finetune` handler to an
existing P5 evolution queue. Its proposal payload contains prompt/completion
pairs, not legacy concatenated strings. The queue's existing fixed evaluator,
isolated candidate, publication gate, and pending-job checkpoint are reused.
Default queue construction and the `trajectory-finetune` handler are unchanged.

```elisp
(require 'nl-llm-agent-supervised-evolve)
(nl-llm-agent-supervised-evolve-register queue :training-backend 'cpu)
(nl-agent-curation-submit-supervised curator queue record-id "reviewed-copy-1")
;; Submission is inert. A separate host decision executes the pending job:
(nl-llm-evolve-queue-run queue "reviewed-copy-1")
```

The submission helper enforces matching curator/queue tokenizer identity and
host evaluation. It retains source/policy provenance and the boundary-aware
dataset digest in job metadata. It neither grants model-side tool permission
nor starts training. To restore pending work after restart, recreate the queue
with the appropriate champion/evaluator, register this handler, then call
`nl-llm-evolve-queue-restore` before execution. Configure the queue's
`:checkpoint-file` to enable persistence; registration alone does not create a
durable store.

The handler supports synchronous CPU SGD and caller-owned GPU training with a
fixed sequence capacity. A trusted host may also pass the queued job to
`nl-agent-training-runner-start`: its isolated worker preserves the explicit
prompt/completion pairs and supports CPU SGD or GPU training. The runner's
trusted training profile supplies the background backend/optimizer/sequence;
payload compatibility with that profile is checked before claiming the job.
The curation tool defaults to legacy but accepts a host-selected supervised
kind at registration; its model-facing arguments do not select the kind.

There is no completion-only mid-training resume handler. A background profile
containing `:checkpoint-every`, or a supervised resume request, is rejected
before claim, preserving the job. Pending-job durability is not completion-only
optimizer-state recovery. Interrupted training is not silently retried.
The background worker still evaluates with the profile's fixed string-vector
benchmark; configure the queue champion score/evaluator consistently with that
benchmark. Changing the training objective does not change the adoption metric.

Registration settings are trusted host configuration, not a new optimizer
checkpoint format. Recreate the same backend/optimizer/sequence settings when
restoring a pending queue; the existing queue snapshot does not persist those
callback bindings.

An independent synthetic integration check saved an approved `DONE a` record,
reconstructed a fresh queue from its pending checkpoint, and trained through
the registered handler. Its six completion tokens retained dataset digest
`48eb8824e9ed673928c83819795054166ef468176aa1c413f5705c085b9b2dc9`.
The fixed held-out prompt differed from the training prompt but used the same
completion. CPU SGD (one step, 0.01) improved its negative completion-loss score
from `-5.867750654516161` to `-5.8117921600483085`; a separate caller-owned GPU
Adam run (one step, 0.01, sequence 128) reached `-5.6971608498595`. Each passed
the fixed gate and published one artifact inside its disposable fixture.
Submission itself created no artifact. These are connection checks on a tiny
model, not evidence of novel task competence or a CPU/GPU optimizer comparison.

A separate CPU run with a deliberately unmet fixed improvement threshold
(`min-delta` 100.0) rejected the trained candidate, retained the original
champion score, and created no catalog artifact. Host regression checks cover
63 curator, tool, runner, cancellation, and recovery tests. These earlier
synchronous checks do not establish completion-only optimizer-state recovery;
the separate background protocol is described in `background-training.md`.

Host verification for this addition passes seven supervised-curation tests
and 19 existing curator/tool tests, plus strict compilation. An independent
synthetic one-record CPU check exercised capture, approval, preparation, and
one real SGD step through the public supervised API: six completion tokens,
matching prepared/trained dataset digests, and changed candidate weights.
This checks the connection, not useful task ability or model promotion.

The standalone service regression was also attempted and failed *before* this
change: the current NeLisp binary serialized the startup list without spaces
(`(:eventstartup-config:request-id1)`). Direct runtime probes reproduced missing
list separators while vector printing and string concatenation retained them.
The affected binary SHA-256 is
`4e58e28b8679e35160b14d8422c6a4a4264555fbb1ac0fee7b0af64ecd63a408`.
Inspection of the installed `nelisp--prn-list-body` found the exact
`(ignore chunks " ")` substitution from the printer mutation-test row. The
source still contained the correct separator insertion. The mutation runner
had restored that source without rebuilding the binary: its rebuild predicate
omitted `standalone-reader-print-large-sexp-smoke`, although the gate itself
builds with the injected source. This was a retained fault-injection artifact,
not a demonstrated defect in the normal printer/compiler.

The missing rebuild-predicate entry was added, and a successful normal rebuild
restored the startup serialization and passed the previously failing standalone
curation service test. The restored binary SHA-256 is
`9c935d951b5956de12dac33bc628c7991992b195720f22ac9383402ea8b777aa`.
Do not run service checks against a tree while its mutation tests are changing
the binary. This fix covers normal completion of this mutation row, not
cross-process exclusion or recovery after an interrupted rebuild.

The focused mutation verification then executed one row (one detected fault,
zero findings/skips) and left both the source hashes and the restored binary
hash unchanged. Independent post-run serialization probes passed. Finally,
`make test` in `nelisp-agent` exited successfully, including host tests,
standalone worker tests, stdio/broker/CLI smokes, strict compilation, and real
GPU child training/stop/resume checks. This verifies the service infrastructure;
it does not establish model task competence or completion-only durable-queue
support.

## Integration scope

The host registration API is opt-in. It does not enable curation in every CLI
session or introduce a JSON field capable of loading arbitrary code. Embedders
must supply the trusted evaluator and host policy deliberately.

Create a context with `nl-agent-curation-new DIRECTORY EVALUATOR POLICY-ID
:data-use-approved t`; optional keywords are `:holdout-digests`, `:lr`,
`:epochs`, and `:tokenizer`. Register it with
`nl-agent-curation-register-tools REGISTRY QUEUE CURATOR`, optionally followed
by `"supervised-finetune"`. The corresponding handler must already be registered
(for example with `training.objective: "completion"` in the improvement
configuration). An embedding host can instead pass the optional `curator` and
following `curation-kind` arguments to `nl-agent-example-free-supervisor`.
The tool
accepts only `(:record-id "run-...sexp")`, an exact saved-record basename.
`nl-agent-curation-prepare` is the host API for obtaining the bounded payload
and provenance without submitting a job.

Repeated identical submissions can reuse a matching retained queue entry.
Supervised identifiers bind the proposal kind as well as source, policy, and
payload. Legacy identifiers are unchanged. Reuse requires identical kind,
payload, and provenance, including the completion dataset digest.
Once queue history is trimmed, there is no lifetime deduplication ledger; this
is not an exactly-once learning guarantee. None of these checks establishes
general model capability, autonomous source self-editing, or Hermes parity.

## Verified integration

`test/curation-service-test.el` runs the packaged standalone worker and host.
A deterministic test provider proposes an approved real file edit; the returned
trajectory is saved through the capture API. The same saved `done` record is
rejected when the independently inspected file has incorrect content. An exact
holdout digest prevents evaluation, and mutation of the evaluator's record copy
does not change the source bytes or rendered examples.

The provider then names only that record for an approved curation request and
separately requests an approved improvement run. Real CPU fine-tuning passes
the fixed held-out next-token loss gate and publishes generation 1. The fixture
uses a tiny model and a three-character held-out string, distinct from the
curated examples; it demonstrates wiring and measured loss on that fixture,
not useful language ability or broad generalization. No external inference API
is contacted. CLI automatic capture is covered separately by
`test/trajectory-service-test.el`.
