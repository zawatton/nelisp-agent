# Semantic IR: deterministic text baseline

This is the first implementation slice of the
[cloud/local architecture proposal](nelisp-cloud-local-ai-architecture.org).
The proposal's examples describe the wider design space; only the versioned
grammar below is executable in this milestone.

## Ownership and integration boundary

NeLisp Agent owns the IR schema, task policy, executor selection, validation,
and repair protocol. NeLisp remains the general-purpose language/runtime.
This implementation is a host Emacs library, `nl-agent-semantic-ir.el`.
It does not yet run inside the standalone worker or add a JSONL/HTTP method.
It has no dependency on a provider, a model, or the training subsystem.

The optional [local-model renderer](semantic-render.md) uses the existing
provider interface and host tool permission boundary. IR operations never
enter the worker's CodeAct path as arbitrary executable Lisp. The deterministic
baseline remains independent of the model adapter.

## Version 1 grammar

```lisp
(task :version 1 :id "hybrid-demo"
  :plan
  (render :language ja
    :claims
    ((claim :id "cloud" :text "推論はクラウドで行います。")
     (claim :id "local" :text "結果はローカルで検証します。")))
  :constraints (:allow-new-claims nil :max-chars 100))
```

All displayed fields are required. Unknown and duplicate fields, unsupported
versions/operations/languages, improper lists, and duplicate claim IDs are
errors. IDs are nonempty strings of at most 128 characters. There must be
1–64 claims, each containing nonempty text of at most 8,192 characters.
`:max-chars` is an integer from 1 through 65,536. `:allow-new-claims` must be
the Lisp value `nil`; the symbol `false` is not an alias.

The input is one S-expression followed by optional whitespace, bounded to
65,536 UTF-8 bytes and 16 levels of list nesting before reading. Strings may
contain escaped quotes, backslashes, and reader-looking text. Outside strings,
reader dispatch, quoting, vectors, comments, and escaped symbols are rejected.
The input is data and is never evaluated.

## API and result contract

`(nl-agent-ir-parse TEXT)` returns a validated task. Invalid syntax or schema
signals `nl-agent-ir-error`; callers should distinguish this from a valid
task whose output fails a constraint.

`(nl-agent-ir-run TEXT)` parses and validates the task, joins its claim texts
with one newline between claims, and checks the resulting character count.
There is no trailing newline in the result text. Text remains verbatim and
claim IDs remain in input order. The language field restricts this first
profile to `ja`; it does not detect language or translate input.

On success, the result includes `:status ok`, `:task` (the task ID), `:text`,
and `:claim-ids`. On overflow, it includes `:status validation-failure` and:

```lisp
:repair-request
(repair-request :version 1 :task "hybrid-demo"
  :constraint max-chars :expected 1 :actual 28)
```

Overflow never silently truncates claims and does not include the full text
in the failure result. Character counts use Emacs string length, including
the inserted newlines; they are not token, byte, or display-width counts.
The library returns the diagnostic locally; it never sends it to a cloud
provider, retries, or applies patches automatically.

The deterministic renderer provides an exact-preservation baseline. This
does not establish factual correctness of the source claims or semantic
faithfulness of an LLM renderer. Those require separate evaluation.

## Run locally

From the repository root, no model or network setup is needed:

```sh
make test-semantic-ir
make compile LISP=lisp/nl-agent-semantic-ir.el
emacs -Q --batch -L lisp -l nl-agent-semantic-ir \
  --eval '(prin1 (nl-agent-ir-run (with-temp-buffer (insert-file-contents "examples/semantic-ir.sexp") (buffer-string))))'
```

The focused test target is also included in the host test suite. Standalone
NeLisp compatibility is not certified by these host tests.

## Next increments

1. Extend the [fixed-corpus evaluation](semantic-evaluation.md) with reviewed
   examples before claiming token or cost savings.
2. Define stable claim-patch targets beyond the existing bounded local
   regeneration, without treating model-generated output as verified.
3. Add document/spreadsheet executors as separate operations once their
   validation contracts are specified.
