;;; free-models-host.el --- supervised host for the free-model worker  -*- lexical-binding: t; -*-

(defconst nl-agent-example-host-root
  (let ((source (or load-file-name buffer-file-name)))
    (if source
        (file-name-directory
         (directory-file-name (file-name-directory source)))
      (file-name-as-directory (expand-file-name "."))))
  "NeLisp Agent project root resolved from this file.")

(add-to-list 'load-path (expand-file-name "lisp" nl-agent-example-host-root))
(add-to-list 'load-path
             (expand-file-name "../nelisp-llm/lisp"
                               nl-agent-example-host-root))
(defvar nl-agent-example-free-models)
(defvar nl-agent-example-default-model)
(defvar nl-agent-example-fallback-models)
(declare-function nl-agent-example-remote-models "free-models-config" ())
(declare-function nl-agent-example-remote-default-model "free-models-config" ())
(declare-function nl-agent-example-remote-fallback-models "free-models-config" ())
(declare-function nl-agent-example-remote-timeout-sec "free-models-config" ())
(load (expand-file-name "examples/free-models-config.el"
                        nl-agent-example-host-root))
(require 'nl-agent-host)
(require 'nl-agent-local-tools)
(require 'nl-agent-service-tools)
(require 'nl-agent-improvement)
(require 'nl-agent-mcp)
(require 'nl-agent-supervisor)

(declare-function nl-agent-training-runner-stop "nl-agent-training-runner"
                  (runner))
(declare-function nl-agent-curation-register-tools "nl-agent-curation-tools"
                  (registry queue curator &optional kind))

(defun nl-agent-example-free--cleanup-owned (improvement-runner clients)
  "Attempt to stop IMPROVEMENT-RUNNER and close every client in CLIENTS.
Signal the first cleanup error only after every owned resource was attempted."
  (let ((first-error nil))
    (when improvement-runner
      (condition-case err
          (nl-agent-training-runner-stop improvement-runner)
        (error (setq first-error err))))
    (dolist (client clients)
      (condition-case err
          (nl-agent-mcp-client-close client)
        (error
         (unless first-error
           (setq first-error err)))))
    (when first-error
      (signal (car first-error) (cdr first-error)))))

(defun nl-agent-example-free-supervisor
    (nelisp-binary base-url
                   &optional api-key-environment checkpoint-file
                   approval workspace-root mcp-entries native-providers
                   improvement-queue improvement-runner initial-model curator
                   curation-kind)
  "Return a configured supervisor using NELISP-BINARY and configured models.
API-KEY-ENVIRONMENT names an optional credential variable.  CHECKPOINT-FILE
enables durable conversation recovery across host restarts.  APPROVAL receives
host tool requests and returns `once', `session', or `deny'; nil safely denies
all tools that require approval.  WORKSPACE-ROOT defaults to this project.
MCP-ENTRIES are data returned by `nl-agent-mcp-config-load'; their clients are
owned and closed by the returned supervisor.  NATIVE-PROVIDERS are ordinary
nelisp-llm provider objects, keeping artifact loading outside this assembler.
When IMPROVEMENT-QUEUE is non-nil, guarded improvement tools expose its
allowlisted experiments.  Optional IMPROVEMENT-RUNNER performs training in a
separate process and is stopped when this supervisor shuts down.  CURATOR, when
non-nil, adds guarded trajectory curation for IMPROVEMENT-QUEUE.  CURATION-KIND
is host-selected and defaults to legacy `trajectory-finetune'; selecting
  `supervised-finetune' requires that handler to be registered in the queue."
  (let ((clients (mapcar (lambda (entry) (plist-get entry :client))
                         mcp-entries)))
    (condition-case err
        (progn
          (when (and base-url
                     (not (and (stringp base-url)
                               (not (string-empty-p base-url)))))
            (error "remote base URL must be non-empty text or nil"))
          (when (and api-key-environment
                     (not (and (stringp base-url)
                               (not (string-empty-p base-url)))))
            (error "API key environment requires a remote base URL"))
          (when (and initial-model
                     (not (and (stringp initial-model)
                               (string-match-p "\\`[^/]+/.+\\'"
                                               initial-model))))
            (error "initial model must be a provider-qualified selector"))
          (let ((providers (copy-sequence native-providers))
                (remote
                 (and (stringp base-url) (not (string-empty-p base-url)))))
            (when remote
              (let ((provider
                     (list :id "remote"
                           :type 'openai
                           :base-url base-url
                           :models (nl-agent-example-remote-models)))
                    (timeout (nl-agent-example-remote-timeout-sec)))
                (when api-key-environment
                  (setq provider
                        (append provider
                                (list :api-key-env api-key-environment))))
                (when timeout
                  (setq provider
                        (append provider
                                (list :timeout-sec timeout))))
                (setq providers (cons provider providers))))
            (unless providers
              (error "configure --base-url, --native-catalog, --improvement-config, or --recurrent-config"))
            (unless (or remote initial-model)
              (error "native-only startup requires an explicit --model selector"))
            (let* ((router (nl-agent-host-router-new providers))
                   (registry (nl-agent-host-router-registry router))
                   (available (nl-llm-agent-provider-models registry))
                   (selected
                    (or initial-model
                        (nl-agent-example-remote-default-model)))
                   (resolved
                    (condition-case resolve-error
                        (nl-llm-agent-provider-resolve registry selected)
                      (error
                       (if (null available)
                           (error "configured model catalog is empty; publish an artifact before selecting %s"
                                  selected)
                         (signal (car resolve-error)
                                 (cdr resolve-error))))))
                   (startup-model (plist-get resolved :qualified-id))
                   (startup-fallbacks
                    (if (and remote
                             (equal (plist-get resolved :provider) "remote"))
                        (nl-agent-example-remote-fallback-models)
                      nil))
                   (workspace
                    (or workspace-root nl-agent-example-host-root))
                   (tools (nl-agent-local-tool-registry workspace))
                   (policy
                    (nl-agent-permission-policy-new
                     :mode 'smart
                     :approval approval
                     :hard-deny (nl-agent-local-hard-deny workspace))))
              (nl-agent-service-tools-register tools router)
              (when improvement-queue
                (nl-agent-improvement-register-tools
                 tools improvement-queue improvement-runner))
              (when curator
                (unless improvement-queue
                  (error "trajectory curation requires an improvement queue"))
                (require 'nl-agent-curation-tools)
                (nl-agent-curation-register-tools
                 tools improvement-queue curator curation-kind))
              (dolist (entry mcp-entries)
		(let ((client (plist-get entry :client)))
                  (unless (nl-agent-mcp-client-p client)
                    (error "invalid MCP entry: %S" entry))
                  (nl-agent-mcp-register-tools
                   tools client :risk (or (plist-get entry :risk) 'external))))
              (nl-agent-supervisor-new
               (list (expand-file-name nelisp-binary nl-agent-example-host-root)
                     "--load"
                     (expand-file-name "examples/free-models-worker.el"
                                       nl-agent-example-host-root))
               :directory nl-agent-example-host-root
               :await-ready t
               :model-catalog (nl-agent-host-model-catalog-function router)
               :inference (nl-agent-host-inference-function router)
               :tool (nl-agent-host-tool-function tools policy)
               :tool-catalog (nl-agent-host-tool-catalog-function tools)
               :startup-config
               (list :model startup-model :fallbacks startup-fallbacks)
               :shutdown
               (lambda ()
		 (nl-agent-example-free--cleanup-owned
                  improvement-runner clients))
               :checkpoint-every 1
               :checkpoint-file checkpoint-file
               :max-requests 250))))
      (error
       (condition-case nil
           (nl-agent-example-free--cleanup-owned
            improvement-runner clients)
         (error nil))
       (signal (car err) (cdr err))))))

(provide 'nl-agent-example-free-host)
;;; free-models-host.el ends here
