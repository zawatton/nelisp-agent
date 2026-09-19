# Emacs client

`nl-agent-ui.el` provides an opt-in, local Emacs front end for the packaged
JSONL service.  Load the library from this checkout, then run `M-x
nl-agent-start`.  For a checkout-relative setup, evaluate
`(add-to-list 'load-path (expand-file-name "lisp" default-directory))` from
`dev/nelisp-agent`, then
`(require 'nl-agent-ui)`.  It creates a dedicated read-only `special-mode`
transcript buffer and asks for a workspace directory when called
interactively.

The default launcher is resolved relative to `nl-agent-ui.el`:
`../bin/nelisp-agent`.  Customize `nl-agent-ui-command` when using another
local launcher, and use `nl-agent-ui-arguments` for ordinary service flags.
Both values are argv lists; no shell string is evaluated.  For example,
`nl-agent-ui-arguments` may contain `("--model" "native/g1"
"--native-catalog" "state/catalog.json")`.  The UI always adds
`--jsonl --jsonl-approval` and rejects flags that could replace those modes,
including `--task`, `--chat`, `--help`, `--version`, `--unattended`,
`--workspace`, and `--`.  The selected workspace is passed explicitly to the
launcher.  It does not auto-connect, load a provider backend, or choose
credentials.

Keys in the transcript buffer are:

| Key | Action |
| --- | --- |
| `r` / `c` | Prompt and send a run / chat request |
| `m` / `g` | Request models / status |
| `s` | Switch to a provider-qualified model |
| `a` / `S` / `d` | Approve once / approve the exact call for the session / deny |
| `q` | Request graceful quit (the transport rejects a busy request) |
| `C-c C-k` | Confirm and force-disconnect the owned launcher |

Approval blocks display the tool, risk, description, and the exact inert
`argsLisp` diagnostic text.  The block is cleared after its answer, final
response, or disconnect.  A session decision is applied by the host policy to
the same exact tool call; the transport only sends the decision and does not
turn it into a general permission grant.

Incoming packets are rendered as inert plain text.  Control and bidi
characters are escaped, text properties and links are not activated, and the
transcript retains the newest bounded portion when no approval block is
active.  If an active approval would exceed the bound, the owned connection
is closed so that the displayed approval is not silently truncated.  A buffer
kill closes only its owned client process; force disconnect does not roll back
side effects already performed by the service.

This is a local convenience client, not an authentication boundary or a
network listener.  The underlying JSONL client still owns framing, request
correlation, approval-token validation, and process cleanup.
