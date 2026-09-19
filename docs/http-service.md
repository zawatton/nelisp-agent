# Local HTTP facade

`bin/nelisp-agent-http` exposes the existing persistent JSONL service through a
small HTTP boundary.  It is intended for a local UI or a same-machine client;
it is not an internet-facing server.

The listener is forced to `127.0.0.1`, and startup fails unless a non-empty
Bearer token environment variable exists.  The default variable is
`NELISP_AGENT_HTTP_TOKEN`.  `GET /health` is intentionally unauthenticated so
local process supervisors can check liveness.  All other routes return 404;
`POST /v1/jsonl` accepts one existing JSONL request object and returns its one
existing JSONL response object as JSON.

```sh
export NELISP_AGENT_HTTP_TOKEN="change-this-local-secret"
bin/nelisp-agent-http --port 8765 --worker -- \
  bin/nelisp-agent --jsonl --unattended \
  --native-catalog state/models/catalog.json --model native/self-g1
```

The worker stream is serialized because the service owns conversation and
model-selection state.  A worker response timeout terminates the worker so a
stuck request cannot be reused.  Defaults are a 1 MiB request body, 1 MiB
worker response, 120 seconds per worker response, and 1,000 requests per
process; use `--max-body`, `--max-response`, `--timeout`, and
`--max-requests` to lower them for a smaller deployment.  Once the request
budget is exhausted, restart the process.  HTTP has no approval transport; use `--unattended` and
configure the existing fail-closed host permission policy.

This facade does not add a second model API.  `/models`, `/status`, `/chat`,
`/run`, `/switch`, `/checkpoint`, and `/quit` retain the JSONL schemas and
semantics documented in [jsonl-service.md](jsonl-service.md).  Put TLS,
remote authentication, and rate limiting in a separately managed reverse
proxy if a future deployment needs network access; do not change the bind
address as a shortcut.
