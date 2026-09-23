;;; nl-agent-cli.el --- user-facing NeLisp Agent command line  -*- lexical-binding: t; -*-

;; The CLI is intentionally a thin facade.  It owns terminal interaction while
;; the supervisor, standalone worker, nelisp-llm providers, and tools retain
;; their existing boundaries.

;;; Code:

(load (expand-file-name "nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'cl-lib)
(require 'json)
(require 'nl-agent-jsonl)
(require 'subr-x)
(require 'nl-agent-supervisor)
(require 'nl-agent-mcp-config)
(require 'nl-agent-improvement-config)
(require 'nl-agent-autonomy)

(declare-function nl-agent-recurrent-config-load
                  "nl-agent-recurrent-config"
                  (file))

(declare-function nl-agent-example-free-supervisor
                  "free-models-host"
                  (nelisp-binary base-url &optional api-key-environment
                                 checkpoint-file approval workspace-root
                                 mcp-entries native-providers
                                 improvement-queue improvement-runner
                                 initial-model curator curation-kind))

(declare-function nl-agent-training-runner-stop "nl-agent-training-runner"
                  (runner))

(declare-function nl-agent-example-free--cleanup-owned
                  "free-models-host" (improvement-runner clients))

(declare-function nl-agent-trajectory-save
                  "nl-agent-trajectory" (directory task response))

(declare-function nl-agent-local-read-only-shell-approval
                  "nl-agent-local-tools" (request))

(defconst nl-agent-cli-root
  (let ((source (or load-file-name buffer-file-name)))
    (if source
        (file-name-directory
         (directory-file-name (file-name-directory source)))
      (file-name-as-directory (expand-file-name "."))))
  "NeLisp Agent project root resolved from this module.")

(require 'nl-llm-agent-artifact)

(declare-function nl-agent-jsonl-approval-new "nl-agent-jsonl-approval"
                  (read-function write-function))
(declare-function nl-agent-jsonl-approval-callback "nl-agent-jsonl-approval"
                  (state request))
(declare-function nl-agent-jsonl-approval-call "nl-agent-jsonl-approval"
                  (state id thunk))

(load (expand-file-name "examples/free-models-host.el" nl-agent-cli-root))

(defconst nl-agent-cli-version "0.1.0-dev"
  "Development version of the NeLisp Agent command-line facade.")

(define-error 'nl-agent-cli-jsonl-session-error
  "JSONL session input/output failure")

(defconst nl-agent-cli-help
  "Usage: kaji [OPTIONS]

Start an interactive Kaji session.  Plain input runs an agent task.

Options:
  --base-url URL       OpenAI-compatible provider endpoint (or environment)
  --nelisp PATH        Standalone NeLisp binary
  --api-key-env NAME   Environment variable containing an optional API key
  --checkpoint PATH    Durable session checkpoint
  --workspace DIR      Root exposed to host tools
  --mcp-config FILE    Data-only MCP server configuration
  --native-catalog FILE
                       Promoted nelisp-llm artifact catalog
  --improvement-config FILE
                       Durable nelisp-llm self-evolution configuration
  --recurrent-config FILE
                       Pinned recurrent-depth provider configuration
  --model SELECTOR     Initial provider-qualified model selector
  --trajectory-directory DIR
                       Save returned agent-run trajectories (disabled by default;
                       raw task and tool text may contain secrets)
  --autonomous-improvement
                       Pre-authorize only bounded self-evolution operations
  --task TEXT          Run one agent task and exit
  --chat TEXT          Send one chat completion and exit
  --jsonl               Run one persistent JSONL request/response session
  --jsonl-approval      Ask for tool approval through the JSONL stream
  --unattended         Never prompt; deny unscoped tools requiring approval
  --read-only-shell    With --unattended, allow read-only shell commands (rg, sed -n, git log, ...)
  --help               Show this help
  --version            Show the development version

Environment:
  NELISP_AGENT_BASE_URL
  NELISP_AGENT_NELISP
  NELISP_AGENT_API_KEY_ENV
  NELISP_AGENT_CHECKPOINT
  NELISP_AGENT_WORKSPACE
  NELISP_AGENT_MCP_CONFIG
  NELISP_AGENT_NATIVE_CATALOG
  NELISP_AGENT_IMPROVEMENT_CONFIG
  NELISP_AGENT_RECURRENT_CONFIG
  NELISP_AGENT_MODEL
  NELISP_AGENT_TRAJECTORY_DIRECTORY
  NELISP_AGENT_READ_ONLY_SHELL

Interactive commands:
  /models              List available models
  /model SELECTOR      Switch model without losing conversation
  /status              Show worker and active-model state
  /chat TEXT           Send a chat turn without the tool loop
  /run TEXT            Run an explicit agent task
  /checkpoint          Capture portable worker state
  /help                Show interactive commands
  /quit                Stop the worker and exit
"
  "Command-line and interactive help text.")

(defconst nl-agent-cli-interactive-help
  "Plain text runs an agent task.
/models | /model SELECTOR | /status | /chat TEXT | /run TEXT
/checkpoint | /help | /quit"
  "Short help shown inside an interactive session.")

(defun nl-agent-cli--need-value (option tail)
  "Return OPTION's value from TAIL or signal."
  (unless (and tail (stringp (car tail))
               (not (string-prefix-p "--" (car tail))))
    (error "%s requires a value" option))
  (car tail))

;;;###autoload
(defun nl-agent-cli-parse-args (args)
  "Parse command-line ARGS and return a detached options plist."
  (let ((tail (copy-sequence args))
        (options nil))
    (when (equal (car tail) "--")
      (setq tail (cdr tail)))
    (while tail
      (let ((option (car tail)))
        (setq tail (cdr tail))
        (cond
         ((member option
                  '("--base-url" "--nelisp" "--api-key-env"
                    "--checkpoint" "--workspace" "--mcp-config"
                    "--native-catalog" "--improvement-config"
                    "--recurrent-config" "--model" "--trajectory-directory"
                    "--task" "--chat"))
          (let ((value (nl-agent-cli--need-value option tail))
                (key
                 (cdr
                  (assoc option
                         '(("--base-url" . :base-url)
                           ("--nelisp" . :nelisp)
                           ("--api-key-env" . :api-key-env)
                           ("--checkpoint" . :checkpoint)
                           ("--workspace" . :workspace)
                           ("--mcp-config" . :mcp-config)
                           ("--native-catalog" . :native-catalog)
                           ("--improvement-config" . :improvement-config)
                           ("--recurrent-config" . :recurrent-config)
                           ("--model" . :model)
                           ("--trajectory-directory" . :trajectory-directory)
                           ("--task" . :task)
                           ("--chat" . :chat))))))
            (when (plist-member options key)
              (error "duplicate option: %s" option))
            (setq options (append options (list key value)))
            (setq tail (cdr tail))))
         ((equal option "--unattended")
          (setq options (plist-put options :unattended t)))
         ((equal option "--read-only-shell")
          (setq options (plist-put options :read-only-shell t)))
         ((equal option "--jsonl")
          (when (plist-member options :jsonl)
            (error "duplicate option: %s" option))
          (setq options (plist-put options :jsonl t)))
         ((equal option "--jsonl-approval")
          (when (plist-member options :jsonl-approval)
            (error "duplicate option: %s" option))
          (setq options (plist-put options :jsonl-approval t)))
         ((equal option "--autonomous-improvement")
          (setq options (plist-put options :autonomous-improvement t)))
         ((equal option "--help")
          (setq options (plist-put options :help t)))
         ((equal option "--version")
          (setq options (plist-put options :version t)))
         (t (error "unknown option: %s" option)))))
    (when (and (plist-member options :task)
               (plist-member options :chat))
      (error "use either --task or --chat, not both"))
    (when (and (plist-get options :jsonl)
               (or (plist-member options :task)
                   (plist-member options :chat)))
      (error "--jsonl cannot be combined with --task or --chat"))
    (when (and (plist-get options :jsonl)
               (or (plist-get options :help)
                   (plist-get options :version)))
      (error "--jsonl cannot be combined with --help or --version"))
    (when (plist-get options :jsonl-approval)
      (unless (plist-get options :jsonl)
        (error "--jsonl-approval requires --jsonl"))
      (when (plist-get options :unattended)
        (error "--jsonl-approval cannot be combined with --unattended")))
    (when (and (plist-get options :read-only-shell)
               (not (plist-get options :unattended)))
      (error "--read-only-shell requires --unattended"))
    options))

(defun nl-agent-cli-options-with-environment (options)
  "Fill absent OPTIONS from NeLisp Agent environment variables."
  (let ((result (copy-tree options)))
    (dolist
        (pair
         '((:base-url . "NELISP_AGENT_BASE_URL")
           (:nelisp . "NELISP_AGENT_NELISP")
           (:api-key-env . "NELISP_AGENT_API_KEY_ENV")
           (:checkpoint . "NELISP_AGENT_CHECKPOINT")
           (:workspace . "NELISP_AGENT_WORKSPACE")
           (:mcp-config . "NELISP_AGENT_MCP_CONFIG")
           (:native-catalog . "NELISP_AGENT_NATIVE_CATALOG")
           (:improvement-config . "NELISP_AGENT_IMPROVEMENT_CONFIG")
           (:recurrent-config . "NELISP_AGENT_RECURRENT_CONFIG")
           (:model . "NELISP_AGENT_MODEL")
           (:trajectory-directory . "NELISP_AGENT_TRAJECTORY_DIRECTORY")))
      (unless (plist-member result (car pair))
        (let ((value (getenv (cdr pair))))
          (when (and value (not (string-empty-p value)))
            (setq result
                  (append result (list (car pair) value)))))))
    (when (and (equal (getenv "NELISP_AGENT_READ_ONLY_SHELL") "1")
               (not (plist-member result :read-only-shell)))
      (setq result (plist-put result :read-only-shell t)))
    result))

(defun nl-agent-cli--read-line (prompt)
  "Read one terminal line after PROMPT, returning nil at end of input."
  (condition-case nil
      (read-string prompt)
    (end-of-file nil)))

(defun nl-agent-cli--write-line (text)
  "Write TEXT and a newline to the command-line terminal."
  (princ text)
  (terpri)
  (when (fboundp 'force-output)
    (force-output)))

;;;###autoload
(defun nl-agent-cli-interactive-approval
    (request &optional read-function write-function)
  "Prompt for REQUEST and return `once', `session', or `deny'.
READ-FUNCTION and WRITE-FUNCTION are injectable terminal boundaries."
  (let ((read-function (or read-function #'nl-agent-cli--read-line))
        (write-function (or write-function #'nl-agent-cli--write-line)))
    (funcall
     write-function
     (format "Tool request: %s [%s]\n  %S"
             (plist-get request :tool)
             (plist-get request :risk)
             (plist-get request :args)))
    (let ((answer
           (funcall
            read-function
            "Allow? [y] once, [s] exact call for session, [N] deny: ")))
      (cond
       ((and answer (member (downcase (string-trim answer))
                            '("y" "yes")))
        'once)
       ((and answer (member (downcase (string-trim answer))
                            '("s" "session")))
        'session)
       (t 'deny)))))

;;;###autoload
(defun nl-agent-cli-route-line (line)
  "Translate interactive LINE into a local action or worker request."
  (unless (stringp line)
    (error "nl-agent-cli-route-line: LINE must be text"))
  (let ((input (string-trim line)))
    (cond
     ((string-empty-p input) '(:kind ignore))
     ((equal input "/help")
      (list :kind 'local :text nl-agent-cli-interactive-help))
     ((equal input "/models") '(:kind request :request (models)))
     ((equal input "/status") '(:kind request :request (status)))
     ((equal input "/checkpoint")
      '(:kind request :request (checkpoint)))
     ((equal input "/quit") '(:kind request :request (quit) :quit t))
     ((equal input "/model")
      '(:kind error :error "/model requires a selector"))
     ((string-prefix-p "/model " input)
      (list :kind 'request
            :request (list 'switch (string-trim (substring input 7)))))
     ((equal input "/chat")
      '(:kind error :error "/chat requires text"))
     ((string-prefix-p "/chat " input)
      (list :kind 'request
            :request (list 'chat (string-trim (substring input 6)))))
     ((equal input "/run")
      '(:kind error :error "/run requires a task"))
     ((string-prefix-p "/run " input)
      (list :kind 'request
            :request (list 'run (string-trim (substring input 5)))))
     ((string-prefix-p "/" input)
      (list :kind 'error :error (format "unknown command: %s" input)))
     (t (list :kind 'request :request (list 'run input))))))

(defun nl-agent-cli--model-lines (models)
  "Return one display line per descriptor in MODELS."
  (mapcar
   (lambda (model)
     (format "%s%s"
             (plist-get model :qualified-id)
             (let ((name (plist-get model :name)))
               (if (and name
                        (not (equal name (plist-get model :id))))
                   (format " — %s" name)
                 ""))))
   models))

(defun nl-agent-cli--trajectory-directory (options)
  "Validate and resolve optional trajectory directory from OPTIONS."
  (when (plist-member options :trajectory-directory)
    (let ((value (plist-get options :trajectory-directory)))
      (unless (and (stringp value) (not (string-empty-p value)))
        (error "--trajectory-directory must be a non-empty path"))
      (let ((directory (expand-file-name value)))
        (when (file-symlink-p directory)
          (error "trajectory directory must not be a symbolic link"))
        (when (and (file-exists-p directory)
                   (not (file-directory-p directory)))
          (error "trajectory directory path is not a directory: %s"
                 directory))
        directory))))

(defun nl-agent-cli--capturable-run-p (request response)
  "Return non-nil when REQUEST and RESPONSE form a capturable agent run."
  (and (listp request)
       (= (length request) 2)
       (eq (car request) 'run)
       (stringp (cadr request))
       (listp response)
       (eq (plist-get response :kind) 'agent-run)
       (memq (plist-get response :status) '(done limit error))))

(defun nl-agent-cli--call (supervisor request &optional trajectory-directory)
  "Call SUPERVISOR once and optionally capture a returned run trajectory.
Capture failures annotate the original response without retrying the request."
  (let ((response (nl-agent-supervisor-call supervisor request)))
    (when (and trajectory-directory
               (nl-agent-cli--capturable-run-p request response))
      (setq response (copy-sequence response))
      (condition-case err
          (progn
            (require 'nl-agent-trajectory)
            (setq response
                  (plist-put
                   response :trajectory-record
                   (nl-agent-trajectory-save
                    trajectory-directory (cadr request) response))))
        (error
         (setq response
               (plist-put response :trajectory-warning
                          (error-message-string err))))))
    response))

;;;###autoload
(defun nl-agent-cli-format-response (response)
  "Return concise terminal text for structured worker RESPONSE."
  (unless (listp response)
    (error "nl-agent-cli-format-response: response must be data"))
  (let* ((status (plist-get response :status))
         (kind (plist-get response :kind))
         (warning (plist-get response :trajectory-warning))
         (text
          (cond
	   ((eq status 'error)
	    (format "ERROR: %s" (or (plist-get response :error) response)))
	   ((eq kind 'models)
	    (string-join (nl-agent-cli--model-lines
			  (plist-get response :models)) "\n"))
	   ((eq kind 'completion) (or (plist-get response :text) ""))
	   ((eq kind 'switched)
	    (format "Model: %s" (plist-get response :model)))
	   ((eq kind 'status)
	    (format "State: %s | Model: %s | Messages: %s | Generation: %s"
		    (plist-get response :state)
		    (plist-get response :model)
		    (plist-get response :message-count)
		    (plist-get response :generation)))
	   ((eq kind 'agent-run)
	    (pcase status
              ('done (or (plist-get response :result) ""))
              ('limit
               (format "LIMIT: stopped after %s steps"
                       (plist-get response :steps)))
              (_ (format "%S" response))))
	   ((eq kind 'checkpoint)
	    (format "Checkpoint captured (%s messages)."
		    (length
		     (plist-get (plist-get response :checkpoint) :messages))))
	   ((eq kind 'closed) "Kaji stopped.")
	   (t (format "%S" response)))))
    (if warning
      (concat text "\nWARNING: trajectory capture failed: " warning)
      text)))

(defun nl-agent-cli-run-jsonl
    (supervisor &optional read-function write-function trajectory-directory
                approval-state)
  "Run a persistent JSONL session over SUPERVISOR and return zero.
READ-FUNCTION receives an empty prompt and returns one line or nil at EOF.
WRITE-FUNCTION receives one JSON line without a trailing newline.  Invalid
requests are answered with a null id and do not call SUPERVISOR.  When
APPROVAL-STATE is non-nil, valid dispatches are wrapped in the approval
module's correlated call boundary."
  (let ((read-function (or read-function #'nl-agent-cli--read-line))
        (write-function (or write-function #'nl-agent-cli--write-line))
        (running t))
    (while running
      (let ((line
             (condition-case nil
                 (funcall read-function "")
               (error
                (signal 'nl-agent-cli-jsonl-session-error
                        '("JSONL input failed"))))))
        (if (null line)
            (setq running nil)
          (let ((decoded
                 (condition-case nil
                     (nl-agent-jsonl-decode line)
                   (error nil))))
            (if (null decoded)
                (condition-case nil
                    (funcall write-function
                             (nl-agent-jsonl-error
                              nil "invalid_request" "invalid request"))
                  (error
                   (signal 'nl-agent-cli-jsonl-session-error
                           '("JSONL output failed"))))
              (let* ((id (plist-get decoded :id))
                     (request (plist-get decoded :request))
                     (quit (eq (car request) 'quit))
                     (encoded
                      (condition-case approval-error
                          (condition-case dispatch-error
                              (nl-agent-jsonl-encode
                               id
                               (if approval-state
                                   (nl-agent-jsonl-approval-call
                                    approval-state id
                                    (lambda ()
                                      (nl-agent-cli--call
                                       supervisor request trajectory-directory)))
                                 (nl-agent-cli--call
                                  supervisor request trajectory-directory)))
                            (error
                             (if (eq (car dispatch-error)
                                     'nl-agent-jsonl-approval-io-error)
                                 (signal (car dispatch-error)
                                         (cdr dispatch-error))
                               (nl-agent-jsonl-error
                                id "request_failed" "request failed"))))
                        (nl-agent-jsonl-approval-io-error
                         (signal 'nl-agent-cli-jsonl-session-error
                                 (cdr approval-error))))))
                ;; Writer failures are deliberately outside the request
                ;; catches: never retry a request or emit a second response.
                (condition-case nil
                    (funcall write-function encoded)
                  (error
                   (signal 'nl-agent-cli-jsonl-session-error
                           '("JSONL output failed"))))
                (when quit (setq running nil))))))))
    0))

;;;###autoload
(defun nl-agent-cli-run-loop
    (supervisor &optional read-function write-function trajectory-directory)
  "Run an interactive loop over SUPERVISOR and return an exit status."
  (let ((read-function (or read-function #'nl-agent-cli--read-line))
        (write-function (or write-function #'nl-agent-cli--write-line))
        (running t))
    (funcall write-function
             (format "Kaji %s — /help for commands"
                     nl-agent-cli-version))
    (while running
      (let ((line (funcall read-function "nelisp> ")))
        (if (null line)
            (setq running nil)
          (let ((route (nl-agent-cli-route-line line)))
            (pcase (plist-get route :kind)
              ('ignore nil)
              ('local (funcall write-function (plist-get route :text)))
              ('error
               (funcall write-function
                        (concat "ERROR: " (plist-get route :error))))
              ('request
               (condition-case err
                   (funcall
                    write-function
                    (nl-agent-cli-format-response
                     (nl-agent-cli--call
                      supervisor (plist-get route :request)
                      trajectory-directory)))
                 (error
                  (funcall write-function
                           (format "ERROR: %S" err))))
               (when (plist-get route :quit)
                 (setq running nil))))))))
    0))

(defun nl-agent-cli--supervisor (options approval)
  "Construct the configured supervisor for OPTIONS and APPROVAL."
  (let ((base-url (plist-get options :base-url)))
    (let ((mcp-entries nil)
          (improvement nil))
      (condition-case err
          (progn
            (when (plist-get options :mcp-config)
              (setq mcp-entries
                    (nl-agent-mcp-config-load
                     (plist-get options :mcp-config))))
            (when (plist-get options :improvement-config)
              (setq improvement
                    (nl-agent-improvement-config-load
                     (plist-get options :improvement-config))))
            (when (plist-get options :autonomous-improvement)
              (unless improvement
                (error "--autonomous-improvement requires --improvement-config"))
              (setq approval
                    (nl-agent-autonomy-improvement-approval
                     (plist-get improvement :provider-id)
                     (plist-get improvement :id-prefix)
                     approval)))
            (let* ((configured-catalog
                    (and improvement
                         (plist-get improvement :catalog-file)))
                   (explicit-catalog (plist-get options :native-catalog))
                   (explicit-catalog-path
                    (and explicit-catalog
                         (expand-file-name explicit-catalog)))
                   (native-providers nil)
                   (recurrent-provider
                    (when (plist-get options :recurrent-config)
                      (require 'nl-agent-recurrent-config)
                      (nl-agent-recurrent-config-load
                       (plist-get options :recurrent-config)))))
              (when (and explicit-catalog-path
                         (not (equal explicit-catalog-path configured-catalog)))
                (setq native-providers
                      (list
                       (nl-llm-agent-artifact-provider
                        "native" explicit-catalog))))
              (when improvement
                (let* ((provider (plist-get improvement :provider))
                       (provider-id (nl-llm-agent-provider-id provider)))
                  (when (cl-find-if
                         (lambda (item)
                           (equal (nl-llm-agent-provider-id item) provider-id))
                         native-providers)
                    (error "duplicate configured native provider: %s"
                           provider-id))
                  (setq native-providers
                        (append native-providers (list provider)))))
              (when recurrent-provider
                (unless (nl-llm-agent-provider-p recurrent-provider)
                  (error "recurrent config did not return a provider"))
                (setq native-providers
                      (append native-providers (list recurrent-provider))))
              (nl-agent-example-free-supervisor
               (or (plist-get options :nelisp) "../nelisp/target/nelisp")
               base-url
               (plist-get options :api-key-env)
               (plist-get options :checkpoint)
               approval
               (or (plist-get options :workspace) default-directory)
               mcp-entries native-providers
               (and improvement (plist-get improvement :queue))
               (and improvement (plist-get improvement :runner))
               (plist-get options :model))))
        (error
         (condition-case nil
             (nl-agent-example-free--cleanup-owned
              (plist-get improvement :runner)
              (mapcar (lambda (entry) (plist-get entry :client))
                      mcp-entries))
           (error nil))
         (signal (car err) (cdr err)))))))

;;;###autoload
(defun nl-agent-cli-run-options (options)
  "Execute parsed OPTIONS and return a process exit status."
  (cond
   ((plist-get options :help)
    (nl-agent-cli--write-line nl-agent-cli-help)
    0)
   ((plist-get options :version)
    (nl-agent-cli--write-line
     (format "Kaji %s" nl-agent-cli-version))
    0)
   (t
    (let* ((options (nl-agent-cli-options-with-environment options))
           (trajectory-directory
            (nl-agent-cli--trajectory-directory options))
           (read-function #'nl-agent-cli--read-line)
           (write-function #'nl-agent-cli--write-line)
           (approval-state
            (when (plist-get options :jsonl-approval)
              (require 'nl-agent-jsonl-approval)
              (nl-agent-jsonl-approval-new
               read-function write-function)))
           (approval
            (cond
             (approval-state
              (lambda (request)
                (nl-agent-jsonl-approval-callback
                 approval-state request)))
             ((and (plist-get options :unattended)
                   (plist-get options :read-only-shell))
              (require 'nl-agent-local-tools)
              #'nl-agent-local-read-only-shell-approval)
             ((or (plist-get options :unattended)
                  (plist-get options :jsonl))
              nil)
             (t #'nl-agent-cli-interactive-approval)))
           (supervisor (nl-agent-cli--supervisor options approval)))
      (let ((body-status nil)
            (pending-io nil))
        (unwind-protect
            (condition-case err
                (setq body-status
                      (cond
                       ((plist-get options :jsonl)
                        (nl-agent-cli-run-jsonl
                         supervisor read-function write-function
                         trajectory-directory approval-state))
                       ((plist-member options :task)
                        (let ((response
                               (nl-agent-cli--call
                                supervisor (list 'run (plist-get options :task))
                                trajectory-directory)))
                          (nl-agent-cli--write-line
                           (nl-agent-cli-format-response response))
                          (if (eq (plist-get response :status) 'done) 0 1)))
                       ((plist-member options :chat)
                        (let ((response
                               (nl-agent-cli--call
                                supervisor (list 'chat (plist-get options :chat))
                                trajectory-directory)))
                          (nl-agent-cli--write-line
                           (nl-agent-cli-format-response response))
                          (if (eq (plist-get response :status) 'ok) 0 1)))
                       (t (nl-agent-cli-run-loop
                           supervisor nil nil trajectory-directory))))
              (nl-agent-cli-jsonl-session-error
               (setq pending-io err)))
          (condition-case stop-error
              (nl-agent-supervisor-stop supervisor)
            (error
             (unless pending-io
               (if (plist-get options :jsonl)
                   (condition-case _write-error
                       (progn
                         (nl-agent-cli--write-line
                          (nl-agent-jsonl-error
                           nil "shutdown_error" "service shutdown failed"))
                         (setq body-status 2))
                     (error
                      (setq pending-io
                            (list 'nl-agent-cli-jsonl-session-error
                                  "JSONL output failed"))))
                 (signal (car stop-error) (cdr stop-error)))))))
        (when pending-io
          (signal (car pending-io) (cdr pending-io)))
        body-status)))))

;;;###autoload
(defun nl-agent-cli-main ()
  "Command-line entry point for =bin/nelisp-agent=."
  (let ((jsonl-requested (member "--jsonl" command-line-args-left)))
    (condition-case err
        (let ((options (nl-agent-cli-parse-args command-line-args-left)))
          (setq command-line-args-left nil)
          (kill-emacs (nl-agent-cli-run-options options)))
      (error
       (if (and jsonl-requested
                (eq (car err) 'nl-agent-cli-jsonl-session-error))
           ;; A live session I/O failure has no safe response channel.  Do not
           ;; turn it into a second startup/error envelope.
           nil
         (if jsonl-requested
           (nl-agent-cli--write-line
            (nl-agent-jsonl-error
             nil "startup_error" "CLI startup failed"))
           (nl-agent-cli--write-line
            (format "ERROR: %s" (error-message-string err)))
           (nl-agent-cli--write-line "Run nelisp-agent --help for usage.")))
       (kill-emacs 2)))))

(provide 'nl-agent-cli)
;;; nl-agent-cli.el ends here
