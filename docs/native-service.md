# Native-only service startup

The command-line service does not require an external inference endpoint
when a usable native artifact is available. Model selection belongs in host
configuration, not in the worker's hard-coded remote example or in the order
of catalog entries.

## Startup contract

The host sends a data-only startup selection containing a provider-qualified
model selector and fallback selectors. The worker uses the same provider
registry and service constructor for remote and native models. No credential,
artifact path, callback, or model tensor is part of this startup message.

The existing remote default and fallback order remain the default when an
endpoint is configured and no initial model is selected. Native-only startup
requires an explicit initial model and a catalog containing that model. An
empty improvement catalog is not a trained model: startup must explain the
missing artifact rather than silently invent one or connect to a remote API.

An existing conversation checkpoint remains authoritative during restoration.
The initial model selects the bootstrap service; it is not a request to discard
the checkpoint's model or history. Use `/model PROVIDER/MODEL` after restoring
to switch the live conversation deliberately.

## Command surface

From the project directory, with an existing published artifact:

```sh
bin/nelisp-agent --native-catalog state/models/catalog.json \
  --model native/self-g1 --checkpoint state/session.checkpoint
```

The catalog path and model id above are examples, not bundled pretrained
weights. The corresponding environment selector is `NELISP_AGENT_MODEL`.
Endpoint and credential environment settings still count as configuration;
unset them when selecting native-only operation. Native-only means no remote
inference provider is assembled, not an OS network sandbox: explicitly
configured MCP servers and approved tools retain their ordinary capabilities.

With both a remote endpoint and a native catalog, either provider can be the
initial selection and `/model` continues to switch through the same service
boundary. Selecting an initial native model must not silently add remote
fallback inference.

For Japanese text, select an artifact explicitly using the `utf8-byte-v1`
tokenizer and 256-vocabulary model. An old ASCII artifact is not converted by
switching its display name or enlarging the context. See
[Unicode model identity and verification](unicode-models.md).

## Verified integration

`test/native-only-service-test.el` exercises parsed CLI options and the real
one-shot `--chat` path, using the packaged standalone worker and real tiny
native CPU inference. It fails if an OpenAI provider or HTTP transport is
constructed or called, clears ambient `NELISP_AGENT_*` settings, and checks
that only native models appear in the catalog. It then discovers and switches
to a second published generation without changing conversation history and
compares the separately captured history with a second host's restored state.

`test/startup-test.el` covers strict startup data validation, detached model
strings, correlated broker responses, and host handling before worker-ready
and during ordinary calls. It also runs the validator under standalone NeLisp.
The CLI assembly tests reject missing/unqualified selections, empty catalogs,
and API-key settings without an endpoint before starting a worker.

## Scope

This removes a packaging dependency; it does not improve model quality or
train an initial model. The native P5 models used by the test suite are tiny
and grammar-constrained. Practical language ability and autonomous source edits
remain separate work. [Host-evaluated trajectory curation](trajectory-curation.md)
is separately opt-in; native-only startup does not enable it automatically.

[File-outcome task evaluation](task-evaluation.md) provides a separate fixed
microtask suite for measuring actual edits through the same service/runtime.
It does not treat a successful startup or a `DONE` response as model capability.

### Standalone response latency

The Unicode integration fixture previously exceeded the default 30-second
per-line wait while constructing and emitting an approximately 12 KiB response.
Stage measurements traced most of that time to two character-by-character
`string-replace` passes, not to the training callback. The shared
[wire framing helper](wire-framing.md) now uses a direct scan and joins spans
once. A paired synthetic measurement fell from 31.933 to 4.648 seconds with
identical frame contents. The fixture-local 60-second workaround was removed;
the production default remains 30 seconds. This does not guarantee that
arbitrarily large responses fit that deadline. The direct host-side task
evaluator does not exercise this standalone transport path.
