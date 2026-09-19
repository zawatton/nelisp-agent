# Local-model Semantic IR rendering

The deterministic [Semantic IR baseline](semantic-ir.md) copies claims exactly.
The optional model adapter asks a configured local model to express those
claims as Japanese prose, through the existing NeLisp LLM provider interface.
The IR grammar is unchanged.

## Trust and routing

The host chooses one provider-qualified model selector and explicitly lists
it as a trusted local selector. This allowlist is an administrator assertion
about the configured backend, not network isolation or proof that a provider
runs locally. Provider names and model-authored metadata do not establish
locality. An administrator must check the endpoint and any forwarding done
by the backend before allowing private data through it.

This routing restriction applies only to the renderer's inference call. The
existing agent loop may include its tool observation in a subsequent request
to the agent's reasoning provider. If that provider is remote, the rendered
text can leave the machine. This milestone does not implement an end-to-end
`local-only` data policy; use an entirely local reasoning configuration when
the full workflow must remain local.

The task and tool arguments cannot override the selected model, endpoint,
generation options, or allowlist. A rejected task does not reach inference.
The default API makes one inference attempt, with no cloud fallback or retry.
The separate [bounded repair API](semantic-evaluation.md) supports explicit
host opt-in to at most three total attempts for structural output failures.
The adapter uses the host router's provider registry and opens a short-lived
provider session, closing it after completion or failure. The renderer does
not append to the agent's conversation or switch its active model.

Only an isolated rendering instruction, output constraints, and the original
claim texts go to the model. Task and claim IDs remain local metadata; they
are not labels for the model to copy into its prose. Claim texts are serialized
as data, not instructions to invoke tools. Model output is returned as text
and is never evaluated or dispatched as a tool.

## Validation and review

A nonempty, bounded response that satisfies the character constraint returns
`:status needs-review` with `:semantic-validation unverified`. This is not a
validated final answer. The model may omit, alter, or add facts even when it
is instructed to preserve all claims and `:allow-new-claims` is `nil`.
The returned claim IDs identify the input claims; they do not certify that
the output contains them.

Output size and character-limit failures return compact diagnostics rather
than the generated body. Provider errors are sanitized rather than exposing
request text, credentials, or backend error details. Diagnostics remain local;
no repair request is automatically sent to a cloud model.

The renderer also screens source-derived numeric tokens. Missing source
numbers and introduced output numbers cause a validation failure and can be
retried within the existing bounded repair policy. This guard uses the original
claims only; the evaluation corpus's required/forbidden literals are never
passed to the renderer or used as corrective hints.

This is a narrow numeric check, not semantic validation. The same numbers can
be attached to the wrong subjects or units, and unsupported nonnumeric claims
can still be introduced. Acceptable outputs therefore remain
`needs-review / unverified` even after numeric screening.

Numeric policy v1 compares distinct ASCII signed decimal lexemes as text.
For example, `30` differs from `130`, and `12.5` differs from `12`. Repeating
the same numeric token does not create a new requirement. The policy does not
normalize mathematically equivalent spellings, grouping separators, exponents,
full-width or Kanji numerals, or unit conversions. Such legitimate rewrites
may be rejected; keeping the source notation is the intended behavior.

Diagnostics include counts and a bounded sample of missing/introduced numeric
tokens, not the rejected prose. Comparison uses the full tokens, while samples
are limited to eight entries and 32 characters per entry. A passing result
does not certify number-to-subject associations, units, or nonnumeric facts.

## Existing service connection

The renderer is exposed through an explicitly registered `semantic.render`
tool. Its only argument is `:ir`, containing the versioned IR string. It has
the `execute` risk class and follows the existing host permission policy.
Registration alone does not grant approval.
An optional host-owned repair limit can be set at registration; tool arguments
cannot change it. The default remains one attempt.

```text
existing worker tool request: semantic.render {ir: ...}
  -> existing host broker
  -> permission policy
  -> fixed renderer configuration
  -> existing provider session
  -> local structural checks
  -> text requiring semantic review / compact failure
```

The broker's successful tool-call status means the tool executed, not that
the inner rendering result passed semantic review. Consumers must inspect
the rendering status. No new JSONL/HTTP method is introduced, and default
service startup does not silently enable this tool.

## Host API

```lisp
(require 'nl-agent-semantic-render)

;; ROUTER is an existing nl-agent-host-router; TOOLS is its host tool registry.
;; This selector must refer to a backend the administrator has checked.
(setq renderer
      (nl-agent-semantic-render-new
       router "local/llama3.2:3b" '("local/llama3.2:3b")
       :temperature 0.2 :max-tokens 512 :timeout-sec 60
       :max-output-bytes 65536))
(nl-agent-semantic-render-register-tool tools renderer)
```

Continue supplying `tools` through the existing
`nl-agent-host-tool-function` and `nl-agent-host-tool-catalog-function`
callbacks when assembling the supervisor. No worker code change is needed
for the already-supported typed-tool broker path.

`(nl-agent-semantic-render-run renderer ir-text)` is the direct trusted-host
API. It bypasses tool approval, so model-originated requests must use the
registered tool through the permission policy instead. The tool's result is
a printed data plist in the existing broker observation string, not executable
Lisp. The deterministic comparison remains `(nl-agent-ir-run ir-text)`.

The constructor accepts the four host-owned options shown above. Provider
generation options are passed through the existing session interface; their
execution depends on the configured provider honoring them. Output limits
are checked after completion, not as a streaming memory cap.

Run the focused suites and compile without contacting a model:

```sh
make test-semantic-render
make compile LISP='lisp/nl-agent-semantic-ir.el lisp/nl-agent-semantic-render.el'
```

## Runnable host example

The [example](../examples/semantic-render-example.el) assembles a provider,
renderer, tool registry, and permission policy, then dispatches a broker tool
event. Its fixed demonstration policy approves this call once; replace that
callback with your service's normal approval handler in an application.

The default uses a stub transport and performs no inference network request:

```sh
emacs -Q --batch --eval '(setq load-prefer-newer t)' \
  -L lisp -L ../nelisp-llm/lisp \
  -l examples/semantic-render-example.el \
  -f nl-agent-semantic-render-example-run
```

For an already-running local endpoint and an already-installed model:

```sh
NELISP_AGENT_RENDER_LIVE=1 \
NELISP_AGENT_RENDER_BASE_URL=http://127.0.0.1:11434/v1 \
NELISP_AGENT_RENDER_MODEL=llama3.2:3b \
emacs -Q --batch --eval '(setq load-prefer-newer t)' \
  -L lisp -L ../nelisp-llm/lisp \
  -l examples/semantic-render-example.el \
  -f nl-agent-semantic-render-example-run
```

These environment variables configure only the example. They do not change
the agent's default CLI or automatically enable a renderer in other services.
The example restricts its live base URL to a loopback authority. This URL
check does not establish that the endpoint itself will not forward requests.

## Verification scope

Mock-provider tests cover routing, isolated messages, cleanup, malformed input,
output constraints, and approval/denial through the actual host tool broker.
Live model quality and cost savings require a separate fixed-corpus evaluation;
a successful single request is only an integration smoke test.
The [fixed-corpus evaluation](semantic-evaluation.md) records output constraints,
literal-screening findings, and text for human review separately.

On 2026-09-19, the live example was exercised with an existing Ollama 0.21.0
endpoint on loopback and `llama3.2:3b`. It returned Japanese text through the
host tool broker with `needs-review` and `unverified`. No model download or
cloud call was required. This observation does not certify semantic quality,
other model configurations, or a full standalone-worker session.
