# Run trajectory capture

The agent runtime already returns per-run trajectories, but a terminal's final
answer is not a reusable training record. The capture boundary stores returned
run data separately from the conversation checkpoint and the improvement
queue. It neither selects training examples nor grants permission to train.

## Contract

Capture is explicitly opt-in through `--trajectory-directory DIR` or
`NELISP_AGENT_TRAJECTORY_DIRECTORY`. It applies to one-shot `--task` and
interactive task runs, not ordinary chat or catalog/status requests. The host
configuration chooses the directory; model output cannot select a filename.

Each versioned record contains the task, reported outcome and step count,
final result, and chronological trajectory. Events retain the selected model,
assistant output, parsed action, and available tool result/observation. The
record deliberately excludes the complete session `:messages` history. Tool
output may nevertheless repeat older or sensitive text; this is not redaction.

Every record has `:evidence "unverified"`. In particular, `done` means the
model emitted a completion action, not that an independent evaluator verified
the task. Worker-reported tool/permission fields are provenance for inspection,
not a replacement for authoritative host authorization or an independent audit.

The store accepts bounded data, not callbacks or executable objects. Strings
are retained without Emacs text properties. Files are published atomically
with private permissions and unique names; prior records
are not overwritten or automatically purged. Capture failure must produce a
visible warning while preserving the already-returned task result and exit
status. It must never cause a tool call or whole task to be replayed.

## Privacy and limits

Raw tasks, code, tool arguments, observations, and results may contain secrets
or third-party material. Enable capture only for data you intend to retain.
File permissions are not encryption. Nothing is uploaded or automatically
submitted to an improvement job by this feature.

The default limits are 8 MiB serialized per record, 100,000 data nodes, nesting
depth 32, and 1,000 records per directory. Integers are also bounded. A host
writer holds an exclusive `.writer` directory during counting and publication.
If a host dies with that lock present, capture fails closed; it does not infer
that the owner is dead from age or automatically delete the lock. Capacity
exhaustion warns instead of deleting older data. Existing directories are not
recursively permission-rewritten; choose a private directory for this data.

Capture records only responses actually returned to the CLI. Abrupt host or
worker death, or failure before the supervisor returns a response, can leave
no record. This is not exactly-once auditing or a transactional action journal.

## Verified integration

`test/trajectory-service-test.el` uses the actual parsed CLI `--task` path and
packaged standalone worker. A deterministic test provider proposes a harmless
`pwd` tool call, the host approves that exact call, and the real tool result is
returned to the worker before completion. The saved record matches the returned
trajectory. A fresh CLI invocation creates a separate record without changing
the first file's bytes. Disabled capture invokes no save function. Injected
atomic-publication failure preserves the completion and exit status, warns,
and does not repeat the tool call. No external inference API is used in this
test; it verifies service integration, not model reasoning quality.

## Training boundary

The opt-in [host-evaluated curation API](trajectory-curation.md) selects records
against independent evidence and submits bounded payloads through the existing
authorized improvement queue. Its host must explicitly attest to data-use
permission and keep evaluation examples separate from training. Capture alone
does not enable that API or choose an evaluator.
Blindly relabeling all completed runs as successful demonstrations would train
the model on its own unchecked claims. This capture feature does not perform
that relabeling, distillation, source self-modification, or model promotion.
