# Headless JSONL service

`nelisp-agent --jsonl` runs one persistent supervisor session over newline-
delimited JSON. It is a local stdio mode, not an HTTP listener or deployment
surface. The flag is opt-in and is never enabled by an environment variable.
It cannot be combined with `--task` or `--chat`; `--autonomous-improvement`
remains available when paired with its normal bounded improvement
configuration. It is also exclusive with `--help` and `--version`, so a
JSONL invocation always keeps stdout JSON-only.

## Request envelope

Each input line is one object. IDs are non-empty strings and are echoed only
after the request has passed validation. The request method is one of the
existing supervisor commands:

```json
{"id":"1","method":"run","params":{"text":"inspect the workspace"}}
{"id":"2","method":"chat","params":{"text":"hello"}}
{"id":"3","method":"models"}
{"id":"4","method":"status"}
{"id":"5","method":"switch","params":{"selector":"remote/model"}}
{"id":"6","method":"checkpoint"}
{"id":"7","method":"quit"}
```

Methods without arguments omit `params`; `chat`, `run`, and `switch` require
their bounded `text` or provider-qualified `selector`. The decoder rejects
unknown methods, extra parameters, malformed JSON, embedded newlines, and
lines over 1 MiB after reading. Invalid requests receive one response with a
JSON `null` ID and the `invalid_request` code; the supervisor is not called
and the session continues.

## Responses and lifecycle

Success is encoded as `{ "id": ID, "ok": true, "result": RESPONSE }`.
`ok: true` means that the request was valid and dispatched; the structured
result may still report a model task `error` or `limit`. A dispatch or response
serialization failure returns the trusted request ID with the generic
`request_failed` code. The request is never replayed after a side effect.

`quit` receives exactly one response and then ends the session. EOF ends with
status 0 and emits no synthetic response. Startup/argument failures in JSONL
mode emit one `startup_error` envelope with a null ID and exit status 2.
Shutdown failures emit one `shutdown_error` envelope and exit status 2; they do
not repeat a completed request response.

The same supervisor owns all valid lines, so conversation state and model
selection persist across requests. By default JSONL uses the existing smart
permission policy: safe and read tools may be allowed automatically, while
unscoped operations that require approval are denied without an interactive
prompt. `--jsonl-approval` is the explicit human-approval exception described
below. `--checkpoint` retains its normal explicit checkpoint behavior; JSONL
does not automatically restore or resume work.

## Optional human approval

`--jsonl-approval` is an explicit opt-in that requires `--jsonl` and cannot be
combined with `--unattended`. It is never enabled by an environment variable;
ordinary `--jsonl` keeps fail-closed unattended behavior. The approval mode is
for a bounded local trusted-stdio client and may block while the client shows
the request to a human. It does not change host permission or hard-deny rules.

When a tool needs approval, the service emits an interim event rather than a
top-level request response:

```json
{"id":"run-1","event":"approval","approvalId":"approval-1","request":{"tool":"shell","risk":"execute","description":"Run one bounded shell command","args":{"command":"pwd"},"argsLisp":"(:command \"pwd\")"}}
```

The client must display the exact requested arguments before deciding. The
`args` object is convenient structured data; `argsLisp` is a bounded plain
text rendering of the original Lisp arguments and must never be evaluated by
the client. `context` is intentionally not sent. Reply with exactly one
approval object using the active request ID and token:

```json
{"id":"run-1","method":"approve","params":{"approvalId":"approval-1","decision":"once"}}
```

`decision` is `once`, `session`, or `deny`. A `session` grant is cached only
for the same tool and identical arguments, and only within the current
process. A stale, malformed, or mismatched reply consumes one line and denies
the tool without executing it. While approval is pending, the client should
not pipeline another ordinary request on the same stream; the approval reply
belongs to the active request. The `approvalId` token is correlation within
that connection, not authentication.

Approval transport I/O failure is sticky for the session: the active request
is not replayed, no final response is written, and the CLI exits with status 2
after cleanup when the active call returns to the host boundary. Any side
effects already completed by that call are not cancelled. Approval events are
not ordinary top-level requests and have no network authentication or
remote-listener semantics; tool and description text remains untrusted data.

`--trajectory-directory` remains an explicit opt-in capture path for `run`
responses. Capture records can contain task and tool text, so callers should
treat that directory as sensitive. JSONL bounds line and response sizes and
recursive response data; the line is necessarily read before the post-read
size check and this is not network-resource isolation. Checkpoint results may
contain dotted Lisp message pairs, which are encoded as JSON arrays such as
`["user", "text"]`; Lisp `nil` is JSON `null`. IDs are correlation-only and
are not deduplicated or used to replay requests. JSONL has no generic restore
method and does not automatically resume checkpoints.
