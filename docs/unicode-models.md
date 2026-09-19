# Unicode model identity and text boundaries

Unicode support is a model contract, not a text-cleanup step. The tokenizer
used for training must also interpret prompts, generated tokens, checkpoints,
evaluation data, and resumed work. This document describes the integration
contract; verification results are recorded separately below when available.

## Encoding identities

| Identifier | Vocabulary | Meaning |
| --- | ---: | --- |
| `ascii-char-v1` | 96 | Printable ASCII characters plus newline; legacy mapping |
| `utf8-byte-v1` | 256 | UTF-8 bytes, with token ID equal to byte value; no BPE merges |

Missing tokenizer metadata means the legacy ASCII mapping only. A checkpoint
with 256 vocabulary entries must explicitly name `utf8-byte-v1`; tensor shape
alone is not a tokenizer specification. Existing checkpoints are not rewritten
or expanded into a different vocabulary. Selecting a UTF-8 model creates or
loads a separately identified compatible model.

The byte alphabet shares the base representation of `photon-bpe`, but this
profile has no learned merge table. It represents Unicode scalar values,
including Japanese and supplementary-plane characters, without an unknown
character substitution. Surrogates, Emacs raw-byte pseudo-characters, malformed
UTF-8, and out-of-range token IDs are errors. There is no normalization or
automatic replacement with spaces. Legacy ASCII input outside its alphabet
also fails explicitly at the model-policy boundary.

Byte encoding is a correctness foundation, not a compression or quality claim.
Many Japanese characters require three tokens and supplementary characters
four. A future BPE profile needs its own immutable merge-table identity and
compatible weights; it cannot silently reinterpret this profile's tokens.

## Generation and capacity

The native policy encodes the complete prompt before allocating its caches.
Context capacity counts tokens, not displayed characters. Unsupported text or
an over-capacity prompt must fail before prefill; history is not silently cut.

The constrained action grammar still operates on complete characters. Forced
characters feed every encoded byte to the model. At a variable position,
decoding greedily selects among valid byte prefixes of the permitted
characters, consulting fresh logits after each byte. It exposes a character to
the grammar only after the complete encoding has been selected. Choosing only
the first UTF-8 byte would incorrectly conflate characters sharing that prefix.
This is greedy constrained byte decoding, not global sequence likelihood
ranking. A forced Japanese scaffold proves encoding, not learned Japanese
reasoning or free-form language generation.

## Training, evaluation, and persistence

The host fixes tokenizer identity with the model. Fine-tune tool payloads do
not acquire an arbitrary tokenizer callback or an encoding override. Example
validation retains character/count/aggregate limits and also bounds encoded
token lengths. GPU sequence checks must use encoded lengths as well.

The fixed-sequence GPU trainer retains its existing space-padding behavior:
padding is token 0 for ASCII and token 32 for UTF-8 bytes. Padding is not
loss-masked in this trainer; this change does not implement masked sequence or
assistant-only supervised loss. Treat padding effects as part of evaluation,
not as evidence of additional language capability.

The evaluator uses the same encoding but independently fixed held-out text.
Copying a model, publishing a checkpoint, reloading it, and returning a trained
child result must preserve tokenizer identity. A tokenizer mismatch is rejected
before weights can replace the active model. Resume identity includes encoding
semantics, not merely equal tensor shapes.

Curation is separately opt-in and uses a trusted host tokenizer selection.
Source hashes, evaluation policy, encoding provenance, and ordinary approval
boundaries still apply. Supporting Japanese text does not establish data-use
rights, redact secrets, prove task success, or authorize automatic training.

In an improvement configuration, set `model.tokenizer` to `utf8-byte-v1`.
Vocabulary and the pre-allocation parameter budget follow that identifier.
Loading an existing generation under a different configured encoding is an
error. A corresponding curator uses `:tokenizer "utf8-byte-v1"`; adding only
that curator setting does not convert an ASCII model or its saved weights.
Use a separate artifact prefix or catalog when starting a new UTF-8 lineage
alongside existing ASCII generations; do not delete or relabel old weights.

## Verification

From `dev/nelisp-llm`, `make test-agent-unicode` runs tokenizer and native
inference checks under both Emacs and standalone NeLisp, plus the training and
artifact suite under Emacs. Coverage includes Unicode scalar boundaries,
malformed encodings, shared byte-prefix choices, context-token overflow before
cache allocation, explicit artifact identity, CPU evaluation/training, and real
Vulkan Adam training resumed from a snapshot with identical final parameters.
The legacy self-improvement rollout keeps temperature sampling rather than
substituting greedy native decoding.

From `dev/nelisp-agent`, `make test` includes `test/unicode-service-test.el`.
An isolated CPU training child consumes Japanese examples. The packaged host
then captures a literal-output Japanese task, checks it against a fixed expected
answer, curates it through approval, trains/evaluates a new generation, reloads
the published artifact, and switches the same service worker to that model.
The test delegates real native decode steps while recording their token IDs;
the consumed prefill prefix must exactly match the full encoded prompt. Its
Japanese output uses a forced grammar scaffold. This fixture is deliberately
small and does not establish generalization or useful Japanese reasoning.

Protocol regressions additionally compare the pre-tokenizer ASCII request's
historical semantic digest with its explicitly labeled equivalent. This
normalization does not rewrite stored requests, weaken exact file hashes, or
erase non-ASCII tokenizer identity.

## Scope

This work does not recreate a remote proprietary model, provide pretrained
Japanese weights, or establish Hermes-level capability. It removes a text
representation barrier so representative Japanese training and evaluation can
be developed without silently losing the input.
