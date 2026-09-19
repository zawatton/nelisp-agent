;;; diagnose-initialized-file-tasks.el --- deterministic file-task diagnostic -*- lexical-binding: t; -*-

;; This probe keeps the frozen supervised-file diagnostic as its complete
;; runner.  It changes only the one model-constructor call, using the opt-in
;; deterministic initializer from nl-llm-agent-initialization.

;;; Code:

(require 'cl-lib)

;; Declare the source guard before the dynamically scoped load binding.  The
;; frozen source must be loaded for its definitions, but must not run here.
(defvar nl-agent-supervised-file-diagnostic-auto-run nil)

(defconst nl-agent-initialized-file-diagnostic-format
  "nl-agent-initialized-file-diagnostic-v1")

(defconst nl-agent-initialized-file-diagnostic-seed #x1A2B3C4D)

(defconst nl-agent-initialized-file-diagnostic-source-sha256
  "a400847d318e81ff7219ec77a05db07a1dd16137584521e2ccf19be4bee0d2ba")

(defvar nl-agent-initialized-file-diagnostic-auto-run t
  "When non-nil, loading this example noninteractively runs the diagnostic.")

(defun nl-agent-initialized-file-diagnostic--file-sha256 (path)
  "Return the byte SHA-256 digest of PATH without text decoding."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (secure-hash 'sha256 (current-buffer))))

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (source (expand-file-name "diagnose-supervised-file-tasks.el" here))
       (actual-sha256
        (nl-agent-initialized-file-diagnostic--file-sha256 source)))
  (unless (equal actual-sha256
                 nl-agent-initialized-file-diagnostic-source-sha256)
    (error "frozen supervised-file diagnostic source SHA mismatch: %s"
           actual-sha256))
  ;; The source diagnostic's own runner is suppressed only for this load.
  (let ((nl-agent-supervised-file-diagnostic-auto-run nil))
    (load source nil nil t)))

;; The base diagnostic adds the LLM and Photon paths before loading this file's
;; definitions.  Require the initializer through those paths, rather than
;; embedding a machine-specific path in this wrapper.
(require 'nl-llm-agent-initialization)

(declare-function nl-agent-supervised-file-diagnostic-run
                  "diagnose-supervised-file-tasks" ())
(declare-function nl-llm-agent-initialization-create
                  "nl-llm-agent-initialization"
                  (&rest keys))
(declare-function nl-llm-agent-improve-model
                  "nl-llm-agent-improve"
                  (&optional dim ff vocab nblocks heads tokenizer))

;;;###autoload
(defun nl-agent-initialized-file-diagnostic-run ()
  "Run the frozen file diagnostic with a deterministic initial model.

The constructor is intercepted for the duration of the diagnostic only.  The
initializer temporarily restores the original constructor while creating its
model, avoiding recursive interception.  The returned plist keeps the full
original diagnostic under `:diagnostic' and records this probe's provenance.
No quality threshold is applied."
  (let* ((constructor 'nl-llm-agent-improve-model)
         (original (symbol-function constructor))
         (constructor-count 0)
         (diagnostic nil))
    ;; `cl-letf' restores the constructor even when the diagnostic signals an
    ;; error.  The inner binding is deliberately limited to the initializer
    ;; call so the initializer's constructor call is not intercepted again.
    (cl-letf (((symbol-function constructor)
               (lambda (&optional dim ff vocab nblocks heads tokenizer)
                 (setq constructor-count (1+ constructor-count))
                 (when (> constructor-count 1)
                   (error "initialized diagnostic constructor called %d times"
                          constructor-count))
                 (cl-letf (((symbol-function constructor) original))
                   (nl-llm-agent-initialization-create
                    :initializer 'xorshift32
                    :seed nl-agent-initialized-file-diagnostic-seed
                    :dim dim :ff ff :vocab vocab :nblocks nblocks
                    :heads heads :tokenizer tokenizer)))))
      (setq diagnostic (nl-agent-supervised-file-diagnostic-run)))
    (unless (= constructor-count 1)
      (error "initialized diagnostic constructor call count was %d, expected 1"
             constructor-count))
    (list :format nl-agent-initialized-file-diagnostic-format
          :initializer 'xorshift32
          :seed nl-agent-initialized-file-diagnostic-seed
          :source-sha256 nl-agent-initialized-file-diagnostic-source-sha256
          :constructor-count constructor-count
          :diagnostic diagnostic)))

(when (and noninteractive nl-agent-initialized-file-diagnostic-auto-run)
  (let ((print-length nil)
        (print-level nil)
        (print-circle nil)
        (print-escape-nonascii t))
    (prin1 (nl-agent-initialized-file-diagnostic-run))
    (terpri)))

(provide 'diagnose-initialized-file-tasks)

;;; diagnose-initialized-file-tasks.el ends here
