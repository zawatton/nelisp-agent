;;; evaluate-semantic-render.el --- bounded semantic evaluation runner -*- lexical-binding: t; -*-

;; The default profile is deterministic and never creates a provider.  Set
;; NELISP_AGENT_EVAL_LIVE=1 to opt into a configured loopback OpenAI-compatible
;; endpoint.  This runner prints one complete S-expression report to stdout.

;;; Code:

(require 'url-parse)

(defconst nl-agent-example-semantic-eval-root
  (let ((source (or load-file-name buffer-file-name)))
    (if source
        (directory-file-name
         (file-name-directory (directory-file-name
                               (file-name-directory source))))
      (expand-file-name ".")))
  "Project root resolved relative to this example source.")

(add-to-list 'load-path
             (expand-file-name "lisp" nl-agent-example-semantic-eval-root))
(add-to-list 'load-path
             (expand-file-name "../nelisp-llm/lisp"
                               nl-agent-example-semantic-eval-root))
(add-to-list 'load-path
             (expand-file-name "../nelisp-photon/lisp"
                               nl-agent-example-semantic-eval-root))

(require 'nl-agent-host)
(require 'nl-agent-semantic-eval)
(require 'nl-agent-semantic-render)

(defun nl-agent-example-semantic-eval--loopback-url-p (base-url)
  "Return non-nil only for an HTTP(S) URL with an exact loopback host."
  (condition-case nil
      (let* ((url (url-generic-parse-url base-url))
             (raw-host (downcase (or (url-host url) "")))
             (host (if (and (> (length raw-host) 1)
                           (eq (aref raw-host 0) ?\[)
                           (eq (aref raw-host (1- (length raw-host))) ?\]))
                       (substring raw-host 1 -1)
                     raw-host)))
        (and (member (url-type url) '("http" "https"))
             (member host '("127.0.0.1" "localhost" "::1"))
             (null (url-user url))
             (null (url-password url))))
    (error nil)))

(defun nl-agent-example-semantic-eval--positive-attempts (text)
  "Parse bounded total attempt TEXT, defaulting to one when nil."
  (let ((value (if text (string-to-number text) 1)))
    (unless (and (integerp value) (<= 1 value 3)
                 (or (null text)
                     (equal (number-to-string value) text)))
      (error "NELISP_AGENT_EVAL_ATTEMPTS must be an integer from 1 through 3"))
    value))

(defun nl-agent-example-semantic-eval--options (arguments)
  "Parse strict runner ARGUMENTS into a plist."
  (when (equal (car arguments) "--")
    (setq arguments (cdr arguments)))
  (let ((corpus nil)
        (output nil)
        (seen nil))
    (while arguments
      (let ((flag (pop arguments)))
        (unless arguments
          (error "%s requires a value" flag))
        (when (member flag seen)
          (error "duplicate semantic evaluation option: %s" flag))
        (push flag seen)
        (pcase flag
          ("--corpus" (setq corpus (pop arguments)))
          ("--output" (setq output (pop arguments)))
          (_ (error "unknown semantic evaluation option: %s" flag)))))
    (list :corpus (expand-file-name
                   (or corpus "examples/semantic-eval-corpus.sexp")
                   nl-agent-example-semantic-eval-root)
          :output (and output (expand-file-name output)))))

(defun nl-agent-example-semantic-eval--renderer ()
  "Create the explicitly configured loopback renderer."
  (require 'nl-llm-agent-openai)
  (let* ((base-url (or (getenv "NELISP_AGENT_EVAL_BASE_URL")
                       "http://127.0.0.1:11434/v1"))
         (model (or (getenv "NELISP_AGENT_EVAL_MODEL") "llama3.2:3b")))
    (unless (and (stringp model) (not (string-empty-p model)))
      (error "NELISP_AGENT_EVAL_MODEL must be non-empty"))
    (unless (nl-agent-example-semantic-eval--loopback-url-p base-url)
      (error "live semantic evaluation requires an exact loopback base URL"))
    (let* ((provider
            (nl-llm-agent-openai-provider
             "local" :base-url base-url :models (list model)))
           (router (nl-agent-host-router-new (list provider)))
           (selector (concat "local/" model)))
      ;; The selector and options are host-owned and recorded in the report;
      ;; corpus data cannot replace them.
      (nl-agent-semantic-render-new router selector (list selector)))))

;;;###autoload
(defun nl-agent-example-evaluate-semantic-render-main ()
  "Print one complete baseline or explicitly opted-in live report."
  (condition-case err
      (let* ((options
              (nl-agent-example-semantic-eval--options command-line-args-left))
             (live (equal (getenv "NELISP_AGENT_EVAL_LIVE") "1"))
             (renderer (and live
                            (nl-agent-example-semantic-eval--renderer)))
             (attempts
              (nl-agent-example-semantic-eval--positive-attempts
               (getenv "NELISP_AGENT_EVAL_ATTEMPTS")))
             (report
              (nl-agent-semantic-eval-run-file
               (plist-get options :corpus) renderer :attempts attempts))
             (text
              (let ((print-length nil)
                    (print-level nil)
                    (print-circle nil))
                (concat (prin1-to-string report) "\n"))))
        (when (plist-get options :output)
          (with-temp-file (plist-get options :output)
            (insert text)))
        (princ text)
        (kill-emacs 0))
    (error
     (princ (format "semantic-eval: %s\n" (error-message-string err))
            'external-debugging-output)
     (kill-emacs 2))))

(provide 'evaluate-semantic-render)

;;; evaluate-semantic-render.el ends here
