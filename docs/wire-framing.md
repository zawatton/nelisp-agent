# Shared one-line wire framing

The host supervisor and standalone service use `nl-agent-wire-frame` to
serialize a form and escape literal carriage returns and newlines. The result
does not include the terminating newline; each transport adds that delimiter.
The protocol remains one readable Lisp data form per physical line.

## Compatibility contract

The frame must exactly match the previous implementation:

```elisp
(string-replace "\r" "\\r"
                (string-replace "\n" "\\n" (prin1-to-string form)))
```

Serialization still uses the caller's printer settings. This helper does not
truncate histories, remove trajectory evidence, change fields, convert Unicode
to ASCII, or introduce a second protocol dialect. Literal backslash-n is not
an actual newline, and quote/backslash escaping remains the printer's job.
The shared helper avoids repeatedly copying the complete accumulated prefix
while escaping line endings.

This is an encoding optimization, not a new validation or security boundary.
Existing data-only parsing, correlated requests, authorization, and process
lifecycle checks still apply. Unsupported printer forms and cyclic objects do
not gain support from framing. Ambient printer truncation settings retain
their previous effect; callers requiring complete data must keep them unset.

## Verification

`test/wire-framing-test.el` runs on both Emacs and standalone NeLisp as part of
`make test`. It checks exact legacy equality, one physical line, and strict
data round trips for Unicode, literal and actual line endings, quotes,
backslashes, control characters, nested vectors, and dotted pairs. A separate
12,000-character string has an independently authored expected frame, so
truncation cannot masquerade as an optimization. Printer settings and caller
match data are covered too.

The real Unicode service integration additionally exercises the packaged
worker, approved training, artifact publication, and native model switching.
It is distinct from a synthetic encoding measurement.

## Reproduce the encoding measurement

From `dev/nelisp-agent`:

```sh
emacs -Q --batch -l examples/bench-stdio-encoding.el
../nelisp/target/nelisp --load examples/bench-stdio-encoding.el
```

To retain measurements together with the selected binary's identity, run from
`dev/nelisp`:

```sh
NELISP_BIN=target/nelisp tools/ai/nelisp-ai.sh probe \
  '(load "../nelisp-agent/examples/bench-stdio-encoding.el")'
```

Read the generated probe directory's output and metadata, including its exit
status. The explicit binary selection matters when the checkout also contains
platform-specific binaries. The benchmark generates a deterministic synthetic
response of approximately 12 KiB, measures the legacy printer and two
replacement stages, then measures the public replacement independently,
including its own printer pass. It requires exact frame equality and emits
measurements rather than response contents. Record other active workloads
when interpreting timings; this is not an end-to-end model-speed benchmark.

## Measured result

A paired Linux standalone measurement on 2026-09-06 used 12,404 serialized
characters (12,427 framed characters). The legacy path took 31.933 seconds:
2.393 seconds printing, 15.085 seconds replacing LF, and 14.456 seconds
replacing CR. The shared direct-character/span implementation took 4.648
seconds including its own printer pass, with exact legacy-frame equality.
That is approximately 6.9 times faster for this encoding operation, not a
claim about model inference or arbitrary response sizes.

The reference binary was `dev/nelisp/target/nelisp`, 7,013,832 bytes, SHA256
`bf60b852dfa877c93cf19cda538f426dd7b50f4b5dba4f945c944bb24b281cb7`.
The measured helper source SHA256 was
`831f5fce74f401afd70bc1bd57cfb25160790f21c41eebc98a17be9ccc49eb57`.
An unrelated NeLisp process was consuming roughly one CPU throughout the
paired observation; it was left untouched. These are observed wall times,
not an unloaded-machine performance guarantee. An intermediate regexp/span
implementation took 15.312 seconds and was replaced by the direct scan.

The previous 60-second Unicode fixture override has been removed. The
supervisor's production default remains 30 seconds per awaited line; there is
no global timeout increase, response truncation, or dropped evidence.
The final direct-scan implementation passed the real Unicode integration in
27.542 seconds for the entire scenario, including training, publication, and
native serving. That scenario duration is distinct from a single frame's
encoding time or the supervisor's per-line deadline.
