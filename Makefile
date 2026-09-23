EMACS ?= emacs
NELISP ?= ../nelisp/target/nelisp
LLM_LISP ?= ../nelisp-llm/lisp
PHOTON_LISP ?= ../nelisp-photon/lisp

SHARED_TESTS = wire-framing-test.el service-test.el stdio-test.el config-test.el broker-test.el \
	host-test.el runtime-test.el mcp-test.el autonomy-test.el
EMACS_TESTS = $(SHARED_TESTS) startup-test.el supervisor-test.el local-tools-test.el \
	cli-test.el cli-native-test.el cli-jsonl-test.el cli-jsonl-approval-test.el \
	cli-jsonl-service-test.el jsonl-test.el jsonl-approval-test.el \
	jsonl-approval-service-test.el client-test.el ui-test.el native-only-service-test.el \
	recurrent-config-test.el cli-recurrent-test.el \
	trajectory-test.el cli-trajectory-test.el trajectory-service-test.el \
	curation-test.el curation-supervised-test.el curation-supervised-queue-test.el \
	curation-tools-test.el curation-service-test.el \
	curation-supervised-tools-test.el supervised-config-test.el \
	unicode-service-test.el \
	task-eval-test.el task-eval-service-adapter-test.el task-eval-service-test.el \
	task-promotion-test.el task-promotion-queue-test.el \
	task-audit-test.el task-audit-runner-test.el task-audit-summary-test.el \
	task-promotion-config-test.el \
	background-task-promotion-service-test.el \
	improvement-evaluation-test.el \
	supervised-file-experiment-test.el supervised-file-diagnostic-test.el \
	initialized-file-diagnostic-test.el file-teacher-forcing-test.el \
	file-choice-loss-test.el \
	mcp-stdio-test.el mcp-legacy-test.el mcp-config-test.el \
	host-cleanup-test.el \
	native-artifact-service-test.el improvement-test.el improvement-config-test.el \
	service-tools-test.el \
	self-evolution-service-test.el training-worker-test.el \
	training-supervised-protocol-test.el training-supervised-worker-test.el \
	training-task-promotion-protocol-test.el training-task-promotion-worker-test.el \
	training-supervised-resume-protocol-test.el training-supervised-resume-worker-test.el \
	training-supervised-runner-test.el training-supervised-runner-resume-test.el \
	training-task-promotion-runner-test.el \
	training-resume-protocol-test.el training-resume-worker-test.el \
	training-recovery-test.el training-runner-resume-test.el \
	background-resume-service-test.el \
	background-config-test.el training-lock-test.el training-runner-test.el training-cancel-test.el \
	background-service-test.el
EMACS_TESTS += semantic-ir-test.el
EMACS_TESTS += semantic-render-test.el
EMACS_TESTS += semantic-repair-test.el
EMACS_TESTS += semantic-faithfulness-test.el
EMACS_TESTS += semantic-eval-test.el
EMACS_TESTS += bulk-reader-test.el
EMACS_TESTS += bulk-policy-test.el
EMACS_TESTS += bulk-eval-test.el
EMACS_TESTS += bulk-policy-eval-test.el
EMACS_TESTS += remote-models-config-test.el
EMACS_TESTS += read-only-shell-test.el
NELISP_TESTS = $(SHARED_TESTS)
LISP = lisp/nl-agent-wire.el lisp/nl-agent-startup.el \
	lisp/nl-agent-service.el lisp/nl-agent-stdio.el lisp/nl-agent-config.el \
	lisp/nl-agent-broker.el lisp/nl-agent-supervisor.el lisp/nl-agent-host.el \
	lisp/nl-agent-tool.el lisp/nl-agent-permission.el lisp/nl-agent-runtime.el \
	lisp/nl-agent-autonomy.el \
	lisp/nl-agent-local-tools.el lisp/nl-agent-service-tools.el \
	lisp/nl-agent-improvement.el lisp/nl-agent-mcp.el \
	lisp/nl-agent-improvement-config.el \
	lisp/nl-agent-mcp-stdio.el lisp/nl-agent-mcp-config.el \
	lisp/nl-agent-trajectory.el lisp/nl-agent-jsonl.el lisp/nl-agent-jsonl-approval.el lisp/nl-agent-client.el lisp/nl-agent-cli.el lisp/nl-agent-ui.el \
	lisp/nl-agent-recurrent-config.el \
	lisp/nl-agent-curation.el lisp/nl-agent-curation-tools.el \
	lisp/nl-agent-task-eval.el lisp/nl-agent-task-eval-service.el \
	lisp/nl-agent-task-suite.el lisp/nl-agent-task-promotion.el \
	lisp/nl-agent-task-audit.el \
	lisp/nl-agent-training-protocol.el lisp/nl-agent-training-worker.el \
	lisp/nl-agent-training-recovery.el \
	lisp/nl-agent-training-runner.el \
	lisp/nl-agent-semantic-ir.el \
	lisp/nl-agent-semantic-render.el \
	lisp/nl-agent-semantic-eval.el \
	lisp/nl-agent-bulk-reader.el \
	lisp/nl-agent-bulk-policy.el \
	examples/free-models-config.el examples/free-models-host.el \
	examples/evaluate-native-tasks.el examples/bench-stdio-encoding.el \
	examples/semantic-render-example.el \
	examples/evaluate-semantic-render.el

LISP += examples/evaluate-bulk-reader.el
LISP += examples/evaluate-bulk-policy.el

.PHONY: drop-stale-elc
.PHONY: test test-emacs test-nelisp test-stdio test-cli test-http test-ui test-task-eval \
	test-cli-jsonl test-cli-jsonl-approval test-cli-jsonl-service \
	test-task-promotion test-task-promotion-config test-task-promotion-service \
	test-improvement-evaluation test-training-task-promotion test-recurrent-config \
	test-semantic-eval \
	test-supervised-resume test-semantic-ir test-semantic-render test-bulk-policy test-bulk-policy-eval compile check

.PHONY: test-bulk-reader

test-bulk-reader:
	@$(MAKE) test-emacs EMACS_TESTS='bulk-reader-test.el bulk-eval-test.el local-tools-test.el'

test-bulk-policy:
	@$(MAKE) test-emacs EMACS_TESTS='bulk-policy-test.el'

test-bulk-policy-eval:
	@$(MAKE) test-emacs EMACS_TESTS='bulk-policy-eval-test.el'

test: test-emacs test-nelisp test-stdio test-cli compile

# A .elc whose source is newer silently supplies the old constants to any
# `emacs --batch -l FILE' that does not set `load-prefer-newer' — which is every
# hand-written probe, as opposed to the targets below, which do set it.  That is
# a wrong answer, not a slow build: a measurement script here once read
# min-source-bytes as 8192 instead of 3072 and split its results at the wrong
# threshold.  Only stale files go; a .elc at least as new as its source is left
# alone, and so is a .elc with no source beside it.
drop-stale-elc:
	@find . -type f -name '*.elc' 2>/dev/null \
	  | while IFS= read -r compiled; do \
	      source="$${compiled%c}"; \
	      if [ -f "$$source" ] && [ "$$source" -nt "$$compiled" ]; then \
	        rm -f "$$compiled" && echo "removed stale $$compiled"; \
	      fi; \
	    done; \
	true

test-emacs: drop-stale-elc
	@set -eu; for test_file in $(EMACS_TESTS); do \
		case "$$test_file" in training-worker-test.el|training-cancel-test.el) \
			$(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' \
				-L lisp -L $(LLM_LISP) -L $(PHOTON_LISP) \
				-l test/$$test_file -f ert-run-tests-batch-and-exit ;; \
		*) \
			$(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' \
				-L lisp -L $(LLM_LISP) -L $(PHOTON_LISP) \
				-l test/$$test_file ;; \
		esac; \
	done

test-nelisp:
	@set -eu; for test_file in $(NELISP_TESTS); do \
		$(NELISP) --load test/$$test_file; \
	done

test-stdio:
	@NELISP_BIN="$(NELISP)" sh test/stdio-smoke.sh
	@NELISP_BIN="$(NELISP)" sh test/stdio-broker-smoke.sh

test-cli:
	@sh test/cli-smoke.sh

test-http:
	@python3 test/http-facade-test.py

test-cli-jsonl:
	@$(MAKE) test-emacs EMACS_TESTS='cli-jsonl-test.el'

test-cli-jsonl-approval:
	@$(MAKE) test-emacs EMACS_TESTS='jsonl-test.el jsonl-approval-test.el cli-jsonl-approval-test.el jsonl-approval-service-test.el'

test-cli-jsonl-service:
	@$(MAKE) test-emacs EMACS_TESTS='cli-jsonl-service-test.el'

test-ui:
	@$(MAKE) test-emacs EMACS_TESTS='client-test.el ui-test.el'

test-task-eval:
	@$(MAKE) test-emacs EMACS_TESTS='local-tools-test.el task-eval-test.el task-eval-service-adapter-test.el task-eval-service-test.el'

test-task-promotion:
	@$(MAKE) test-emacs EMACS_TESTS='task-promotion-test.el task-promotion-queue-test.el task-audit-test.el task-audit-runner-test.el task-promotion-config-test.el'

test-task-promotion-config:
	@$(MAKE) test-emacs EMACS_TESTS='task-audit-test.el task-audit-runner-test.el task-promotion-config-test.el'

test-task-promotion-service:
	@$(MAKE) test-emacs EMACS_TESTS='background-task-promotion-service-test.el'

test-improvement-evaluation:
	@$(MAKE) test-emacs EMACS_TESTS='task-audit-summary-test.el improvement-evaluation-test.el'

test-training-task-promotion:
	@$(MAKE) test-emacs EMACS_TESTS='training-task-promotion-protocol-test.el training-task-promotion-worker-test.el training-task-promotion-runner-test.el'

test-recurrent-config:
	@$(MAKE) test-emacs EMACS_TESTS='recurrent-config-test.el cli-recurrent-test.el'

test-supervised-resume:
	@$(MAKE) test-emacs EMACS_TESTS='training-supervised-resume-protocol-test.el training-supervised-resume-worker-test.el training-supervised-runner-test.el training-supervised-runner-resume-test.el'

test-semantic-ir:
	@$(MAKE) test-emacs EMACS_TESTS='semantic-ir-test.el'

test-semantic-render:
	@$(MAKE) test-emacs EMACS_TESTS='semantic-ir-test.el semantic-render-test.el'

test-semantic-eval:
	@$(MAKE) test-emacs EMACS_TESTS='semantic-ir-test.el semantic-render-test.el semantic-repair-test.el semantic-faithfulness-test.el semantic-eval-test.el'

# Compile in an owned temporary directory; never overwrite or sweep user .elc
# files.  `drop-stale-elc' is the one exception and is not a sweep: it removes
# only a .elc its own source has outlived.
compile: drop-stale-elc
	@set -eu; \
	$(EMACS) -Q --batch -L lisp -L $(LLM_LISP) -L $(PHOTON_LISP) \
		-l bytecomp \
		--eval '(setq byte-compile-error-on-warn t)' \
		--eval '(setq load-prefer-newer t)' \
		--eval '(let* ((directory (make-temp-file "nl-agent-compile-" t)) (byte-compile-dest-file-function (lambda (file) (expand-file-name (concat (file-name-nondirectory file) "c") directory)))) (unwind-protect (batch-byte-compile) (delete-directory directory t)))' $(LISP)

check: test
