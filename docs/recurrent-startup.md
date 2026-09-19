# Recurrent startup

The command-line facade can opt into a pinned recurrent-depth provider with
`--recurrent-config FILE`, or with `NELISP_AGENT_RECURRENT_CONFIG`.  An
explicit command-line value takes precedence over the environment.  The
manifest is data-only; it names local relative artifacts and their lowercase
SHA-256 digests, and contains constrained-decoding grammar data.  It does not
train, promote, or alter the generic worker protocol.

```json
{
  "format": "nl-agent-recurrent-config-v1",
  "id": "recurrent",
  "name": "Pinned recurrent models",
  "models": [{
    "id": "tiny",
    "path": "artifacts/tiny.sexp",
    "sha256": "<replace with the 64 lowercase hex digest returned by artifact-save>",
    "grammar": {"type": "template", "segments": [{"slot": "ab"}]},
    "maxseq": 2048
  }]
}
```

Start a native-only session by selecting the qualified model explicitly:

```sh
bin/nelisp-agent --recurrent-config recurrent.json --model recurrent/tiny
```

Create each artifact beforehand with
`nl-llm-agent-recur-artifact-save`; the placeholder digest above is not
runnable until replaced with its returned SHA-256.  Artifact paths are
relative to the manifest directory and are resolved beneath it.  The host
validates the manifest and loads each artifact through the pinned recurrent
provider.  Its public catalog contains model IDs and capabilities, not
artifact paths or grammar closures.  The existing `models`, `switch`,
conversation history, and service checkpoint commands use the same provider
boundary as other native providers.  A provider-ID collision with an existing
native, improvement, or remote provider is rejected during startup.

The host opens a short-lived recurrent provider session for each inference;
the artifact digest is checked on every open, so changing a file is rejected
and never silently adopted.  Restart with a new manifest when intentionally
switching to a new digest.  `maxseq` counts tokenizer tokens, including the
worker's default system prompt, history, and generated text; use 2048 or 4096
for the packaged worker rather than the omitted default of 128.

This is a CPU experimental constrained-decoding path.  Recurrent inference
recomputes the full prefix and is not a pretrained-equivalence or capability
claim.  A one-character `ab` template is useful for `--chat` smoke tests but
does not produce a valid `DONE` task action; ordinary agent tasks need a grammar
that emits the action format expected by the worker.  GPU, training, automatic
promotion, and JSON configuration for other runtime services are outside this
startup option.  With only this provider configured, no remote provider is
assembled; network policy remains the responsibility of the selected host
configuration.
