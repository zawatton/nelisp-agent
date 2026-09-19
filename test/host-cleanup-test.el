;;; host-cleanup-test.el --- owned host resource cleanup tests  -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path
             (or (getenv "NELISP_LLM_LISP")
                 (expand-file-name "../nelisp-llm/lisp")))
(require 'nl-agent-cli)

(defvar nl-agent-host-cleanup-test--fail 0)

(defun nl-agent-host-cleanup-test--ck (name ok)
  (princ (format "%-72s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-host-cleanup-test--fail
                         (1+ nl-agent-host-cleanup-test--fail))
                   "FAIL"))))

(defun nl-agent-host-cleanup-test--client (id close)
  (nl-agent-mcp-client-new id (lambda () nil) (lambda (&rest _args) nil)
                           :close close))

(defun nl-agent-host-cleanup-test--error-message (thunk)
  (condition-case err
      (progn (funcall thunk) nil)
    (error (error-message-string err))))

(let* ((events nil)
       (first
        (nl-agent-host-cleanup-test--client
         "first"
         (lambda ()
           (setq events (append events '(first-close)))
           (error "first close failed"))))
       (second
        (nl-agent-host-cleanup-test--client
         "second"
         (lambda ()
           (setq events (append events '(second-close))))))
       supervisor
       shutdown-error)
  (cl-letf (((symbol-function 'nl-agent-local-tool-registry)
             (lambda (_workspace) 'tools))
            ((symbol-function 'nl-agent-permission-policy-new)
             (lambda (&rest _args) 'policy))
            ((symbol-function 'nl-agent-local-hard-deny)
             (lambda (_workspace) nil))
            ((symbol-function 'nl-agent-service-tools-register)
             (lambda (&rest _args) nil))
            ((symbol-function 'nl-agent-mcp-register-tools)
             (lambda (&rest _args) nil))
            ((symbol-function 'nl-agent-host-model-catalog-function)
             (lambda (_router) (lambda () nil)))
            ((symbol-function 'nl-agent-host-inference-function)
             (lambda (_router) (lambda (&rest _args) nil)))
            ((symbol-function 'nl-agent-host-tool-function)
             (lambda (&rest _args) (lambda (&rest _args) nil)))
            ((symbol-function 'nl-agent-host-tool-catalog-function)
             (lambda (_tools) (lambda () nil)))
            ((symbol-function 'nl-agent-training-runner-stop)
             (lambda (_runner)
               (setq events (append events '(runner-stop)))
               (error "runner stop failed"))))
    (setq supervisor
          (nl-agent-example-free-supervisor
           "unused" "https://provider.invalid/v1" nil nil nil
           default-directory
           (list (list :client first) (list :client second))
           nil nil 'runner))
    (setq shutdown-error
          (nl-agent-host-cleanup-test--error-message
           (lambda () (nl-agent-supervisor-stop supervisor))))
    ;; The generic supervisor marks the callback called before invoking it.
    (nl-agent-supervisor-stop supervisor)
    ;; A successfully closed client remains safe under a direct retry too.
    (nl-agent-mcp-client-close second))
  (nl-agent-host-cleanup-test--ck
   "normal shutdown reports the first cleanup failure after all close attempts"
   (and (string-match-p "runner stop failed" shutdown-error)
        (equal events '(runner-stop first-close second-close))
        (nl-agent-mcp-client-closed second)))
  (nl-agent-host-cleanup-test--ck
   "a failing host shutdown callback still runs exactly once through supervisor"
   (equal events '(runner-stop first-close second-close))))

(let* ((events nil)
       (first
        (nl-agent-host-cleanup-test--client
         "assembly-first"
         (lambda ()
           (setq events (append events '(first-close)))
           (error "cleanup close failed"))))
       (second
        (nl-agent-host-cleanup-test--client
         "assembly-second"
         (lambda ()
           (setq events (append events '(second-close))))))
       assembly-error)
  (cl-letf (((symbol-function 'nl-agent-local-tool-registry)
             (lambda (_workspace) 'tools))
            ((symbol-function 'nl-agent-permission-policy-new)
             (lambda (&rest _args) 'policy))
            ((symbol-function 'nl-agent-local-hard-deny)
             (lambda (_workspace) nil))
            ((symbol-function 'nl-agent-service-tools-register)
             (lambda (&rest _args) nil))
            ((symbol-function 'nl-agent-mcp-register-tools)
             (lambda (&rest _args) nil))
            ((symbol-function 'nl-agent-host-model-catalog-function)
             (lambda (_router) (lambda () nil)))
            ((symbol-function 'nl-agent-host-inference-function)
             (lambda (_router) (lambda (&rest _args) nil)))
            ((symbol-function 'nl-agent-host-tool-function)
             (lambda (&rest _args) (lambda (&rest _args) nil)))
            ((symbol-function 'nl-agent-host-tool-catalog-function)
             (lambda (_tools) (lambda () nil)))
            ((symbol-function 'nl-agent-supervisor-new)
             (lambda (&rest _args) (error "original assembly failed")))
            ((symbol-function 'nl-agent-training-runner-stop)
             (lambda (_runner)
               (setq events (append events '(runner-stop)))
               (error "cleanup runner failed"))))
    (setq assembly-error
          (nl-agent-host-cleanup-test--error-message
           (lambda ()
             (nl-agent-example-free-supervisor
              "unused" "https://provider.invalid/v1" nil nil nil
              default-directory
              (list (list :client first) (list :client second))
              nil nil 'runner)))))
  (nl-agent-host-cleanup-test--ck
   "host assembly preserves its original error after every cleanup attempt"
   (and (string-match-p "original assembly failed" assembly-error)
        (equal events '(runner-stop first-close second-close))
        (nl-agent-mcp-client-closed second))))

(let* ((events nil)
       (first
        (nl-agent-host-cleanup-test--client
         "cli-first"
         (lambda ()
           (setq events (append events '(first-close)))
           (error "CLI cleanup close failed"))))
       (second
        (nl-agent-host-cleanup-test--client
         "cli-second"
         (lambda ()
           (setq events (append events '(second-close))))))
       (provider
        (nl-llm-agent-provider-new
         "native" :models nil :open (lambda (&rest _args) nil)
         :complete (lambda (&rest _args) "")))
       cli-error)
  (cl-letf (((symbol-function 'nl-agent-mcp-config-load)
             (lambda (_path)
               (list (list :client first) (list :client second))))
            ((symbol-function 'nl-agent-improvement-config-load)
             (lambda (_path)
               (list :runner 'runner :provider provider)))
            ((symbol-function 'nl-agent-example-free-supervisor)
             (lambda (&rest _args) (error "original CLI assembly failed")))
            ((symbol-function 'nl-agent-training-runner-stop)
             (lambda (_runner)
               (setq events (append events '(runner-stop)))
               (error "CLI cleanup runner failed"))))
    (setq cli-error
          (nl-agent-host-cleanup-test--error-message
           (lambda ()
             (nl-agent-cli--supervisor
              '(:base-url "https://provider.invalid/v1"
                :mcp-config "mcp.json"
                :improvement-config "improvement.json")
              nil)))))
  (nl-agent-host-cleanup-test--ck
   "CLI assembly preserves its original error after every cleanup attempt"
   (and (string-match-p "original CLI assembly failed" cli-error)
        (equal events '(runner-stop first-close second-close))
        (nl-agent-mcp-client-closed second))))

(let* ((events nil)
       (directory (make-temp-file "nl-agent-cleanup-config-" t))
       (config (expand-file-name "mcp.json" directory))
       (first
        (nl-agent-host-cleanup-test--client
         "config-first"
         (lambda ()
           (setq events (append events '(first-close)))
           (error "config cleanup close failed"))))
       (second
        (nl-agent-host-cleanup-test--client
         "config-second"
         (lambda ()
           (setq events (append events '(second-close))))))
       (clients (list first second))
       config-error)
  (unwind-protect
      (progn
        (write-region "{\"servers\":[{},{}]}" nil config nil 'silent)
        (cl-letf (((symbol-function 'nl-agent-mcp-config--entry)
                   (lambda (_spec _directory)
                     (list :id "duplicate" :client (pop clients)))))
          (setq config-error
                (nl-agent-host-cleanup-test--error-message
                 (lambda () (nl-agent-mcp-config-load config))))))
    (delete-directory directory t))
  (nl-agent-host-cleanup-test--ck
   "MCP config assembly preserves validation error and closes every owned client"
   (and (string-match-p "duplicate MCP server id" config-error)
        (equal events '(first-close second-close))
        (nl-agent-mcp-client-closed second))))

(princ (format "NL-AGENT-HOST-CLEANUP %s (%d failures)\n"
               (if (= nl-agent-host-cleanup-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-host-cleanup-test--fail))
(kill-emacs (if (= nl-agent-host-cleanup-test--fail 0) 0 1))

;;; host-cleanup-test.el ends here
