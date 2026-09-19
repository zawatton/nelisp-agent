;;; nl-agent-ui.el --- small read-only Emacs client for the JSONL service -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'simple)
(require 'subr-x)
(require 'nl-agent-client)

(defconst nl-agent-ui--source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory)))

(defun nl-agent-ui--default-command ()
  "Return the packaged standalone command relative to this library."
  (list (expand-file-name "../bin/nelisp-agent"
                          nl-agent-ui--source-directory)))

;;;###autoload
(defcustom nl-agent-ui-command (nl-agent-ui--default-command)
  "Base argv used to start the local NeLisp Agent service.
The value is an argv list, not a shell command string.  Credentials and
network endpoints are intentionally not supplied by this front end."
  :type '(repeat string)
  :group 'nl-agent)

;;;###autoload
(defcustom nl-agent-ui-arguments nil
  "Additional service arguments for `nl-agent-start'.
Protocol and mode flags are supplied by the UI and cannot be overridden here."
  :type '(repeat string)
  :group 'nl-agent)

(defvar-local nl-agent-ui--client nil)
(defvar-local nl-agent-ui--workspace nil)
(defvar-local nl-agent-ui--approval-id nil)
(defvar-local nl-agent-ui--approval-token nil)
(defvar-local nl-agent-ui--transcript-overflowed nil)

(defconst nl-agent-ui--max-transcript-bytes (* 1024 1024)
  "Maximum retained transcript size when no approval block is active.")

(defconst nl-agent-ui--forbidden-arguments
  '("--task" "--chat" "--help" "--version" "--unattended"
    "--jsonl" "--jsonl-approval" "--workspace" "--"))

(defun nl-agent-ui--argument-forbidden-p (argument)
  "Return non-nil when ARGUMENT attempts to replace a UI protocol flag."
  (or (member argument nl-agent-ui--forbidden-arguments)
      (cl-some (lambda (prefix)
                 (string-prefix-p (concat prefix "=") argument))
                 '("--task" "--chat" "--help" "--version"
                 "--unattended" "--jsonl" "--jsonl-approval"
                 "--workspace"))))

(defun nl-agent-ui--validate-argv (argv where)
  "Validate string ARGV for WHERE and return a detached copy."
  (unless (and (listp argv) argv)
    (error "%s must be a non-empty argv list" where))
  (dolist (argument argv)
    (unless (and (stringp argument) (not (string-empty-p argument)))
      (error "%s contains a non-string argument" where)))
  (copy-sequence argv))

(defun nl-agent-ui--command (workspace)
  "Build and validate the local service argv for WORKSPACE."
  (let ((base (nl-agent-ui--validate-argv nl-agent-ui-command
                                          "nl-agent-ui-command"))
        (extra (and nl-agent-ui-arguments
                    (nl-agent-ui--validate-argv nl-agent-ui-arguments
                                                "nl-agent-ui-arguments"))))
    (dolist (argument (append base extra))
      (when (nl-agent-ui--argument-forbidden-p argument)
        (error "UI argument attempts to override JSONL protocol: %s"
               argument)))
    (append base extra (list "--jsonl" "--jsonl-approval"
                             "--workspace" workspace))))

(defun nl-agent-ui--plain-data (value)
  "Return VALUE with packet strings detached from text properties."
  (cond
   ((stringp value) (substring-no-properties value))
   ((vectorp value)
    (vconcat (mapcar #'nl-agent-ui--plain-data value)))
   ((consp value)
    (cons (nl-agent-ui--plain-data (car value))
          (nl-agent-ui--plain-data (cdr value))))
   (t value)))

(defun nl-agent-ui--safe-text (value)
  "Render VALUE as inert plain text with controls escaped."
  (let ((text (substring-no-properties
               (if (stringp value)
                   value
                 (prin1-to-string (nl-agent-ui--plain-data value))))))
    (apply #'concat
           (mapcar
            (lambda (character)
              (cond
               ((or (= character ?\n) (= character ?\t))
                (char-to-string character))
               ((or (< character 32)
                    (= character #x7f)
                    (and (>= character #x80) (<= character #x9f))
                    (= character #x61c)
                    (= character #x200e)
                    (= character #x200f)
                    (and (>= character #x202a) (<= character #x202e))
                    (and (>= character #x2066) (<= character #x2069)))
                (format "\\u%04X" character))
               (t (char-to-string character))))
            (string-to-list text)))))

(defun nl-agent-ui--trim-transcript (&optional reserve)
  "Keep the newest transcript within the UI byte budget.
An active approval is never truncated; if it would exceed the budget, close
the connection so the displayed approval remains a bounded final record."
  (let ((limit (max 0 (- nl-agent-ui--max-transcript-bytes (or reserve 0)))))
    (when (> (string-bytes (buffer-string)) limit)
      (let ((inhibit-read-only t))
        ;; Delete large prefixes in logarithmically many passes.  This keeps
        ;; the newest transcript without repeatedly rescanning each line.
        (while (> (string-bytes (buffer-string)) limit)
          (goto-char (point-min))
          (delete-region (point-min)
                         (+ (point-min)
                            (max 1 (/ (- (point-max) (point-min)) 2)))))))))

(defun nl-agent-ui--raw-insert (text)
  "Insert already-rendered inert TEXT without transcript accounting."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert text)))

(defun nl-agent-ui--insert (format-string &rest arguments)
  "Insert inert formatted text into the current UI buffer."
  (unless nl-agent-ui--transcript-overflowed
    (let* ((text (nl-agent-ui--safe-text (apply #'format format-string arguments)))
           (text (if (string-suffix-p "\n" text) text (concat text "\n")))
           (current (string-bytes (buffer-string))))
      (if (and nl-agent-ui--approval-id
               (> (+ current (string-bytes text))
                  nl-agent-ui--max-transcript-bytes))
          (progn
            (setq nl-agent-ui--transcript-overflowed t)
            (nl-agent-ui--clear-approval)
            (nl-agent-ui--trim-transcript 256)
            (nl-agent-ui--raw-insert
             "[ERROR] transcript limit; disconnected; approval not actionable\n")
            (when (nl-agent-ui--live-client-p)
              (condition-case nil
                  (nl-agent-client-close nl-agent-ui--client)
                (error nil))))
        (nl-agent-ui--raw-insert text)
        (nl-agent-ui--trim-transcript)))))

(defun nl-agent-ui--live-client-p ()
  "Return non-nil when the current buffer owns an open client."
  (and (nl-agent-client-p nl-agent-ui--client)
       (not (nl-agent-client-closed nl-agent-ui--client))))

(defun nl-agent-ui--clear-approval ()
  "Forget the approval currently displayed by this buffer."
  (setq nl-agent-ui--approval-id nil
        nl-agent-ui--approval-token nil))

(defun nl-agent-ui--event (client packet)
  "Render PACKET received from CLIENT, if CLIENT is still current."
  (when (and (buffer-live-p (current-buffer))
             (eq client nl-agent-ui--client))
    (let ((event (alist-get 'event packet)))
      (if (equal event "approval")
          (let* ((request (alist-get 'request packet))
                 (id (alist-get 'id packet))
                 (token (alist-get 'approvalId packet)))
            (setq nl-agent-ui--approval-id id
                  nl-agent-ui--approval-token token)
            (nl-agent-ui--insert
             "\n[APPROVAL PENDING]\nid: %s\napprovalId: %s\ntool: %s\nrisk: %s\ndescription: %s\nargsLisp: %s\n"
             id token (alist-get 'tool request) (alist-get 'risk request)
             (alist-get 'description request) (alist-get 'argsLisp request)))
        (when (and nl-agent-ui--approval-id
                   (equal nl-agent-ui--approval-id (alist-get 'id packet)))
          (nl-agent-ui--clear-approval))
        (nl-agent-ui--insert "\n[RESPONSE]\n%s\n" packet)))))

(defun nl-agent-ui--closed (client reason)
  "Render CLIENT closure REASON only for the current connection."
  (when (and (buffer-live-p (current-buffer))
             (eq client nl-agent-ui--client))
    (nl-agent-ui--clear-approval)
    (nl-agent-ui--insert "\n[DISCONNECTED]\n%s\n" reason)))

(defun nl-agent-ui--request (method &optional params)
  "Send METHOD and PARAMS through the current client."
  (if (not (nl-agent-ui--live-client-p))
      (nl-agent-ui--insert "[ERROR] no active connection")
    (condition-case err
        (progn
          (nl-agent-client-request nl-agent-ui--client method params)
          (nl-agent-ui--insert "[SENT] %s\n" method))
      (error (nl-agent-ui--insert "[ERROR] %s" (error-message-string err))))))

(defun nl-agent-ui-run ()
  "Send a run request after prompting for text."
  (interactive)
  (nl-agent-ui--request "run"
                        (list :text (read-string "Run: "))))

(defun nl-agent-ui-chat ()
  "Send a chat request after prompting for text."
  (interactive)
  (nl-agent-ui--request "chat"
                        (list :text (read-string "Chat: "))))

(defun nl-agent-ui-models ()
  "Request the available model catalog."
  (interactive)
  (nl-agent-ui--request "models"))

(defun nl-agent-ui-status ()
  "Request the current service status."
  (interactive)
  (nl-agent-ui--request "status"))

(defun nl-agent-ui-switch ()
  "Prompt for and request a provider-qualified model switch."
  (interactive)
  (nl-agent-ui--request
   "switch" (list :selector (read-string "Model (provider/id): "))))

(defun nl-agent-ui--approval (decision)
  "Answer the displayed approval with DECISION."
  (if (not (and (nl-agent-ui--live-client-p)
                nl-agent-ui--approval-id nl-agent-ui--approval-token))
      (nl-agent-ui--insert "[ERROR] no pending approval")
    (let ((approval-client nl-agent-ui--client)
          (id nl-agent-ui--approval-id)
          (token nl-agent-ui--approval-token)
          (approved
           (or (not (equal decision "session"))
               (yes-or-no-p "Approve this exact tool call for the session? "))))
      (if (or (not approved)
              (not (eq approval-client nl-agent-ui--client))
              (not (equal id nl-agent-ui--approval-id))
              (not (equal token nl-agent-ui--approval-token))
              (not (nl-agent-ui--live-client-p)))
          (nl-agent-ui--insert (if approved
                                   "[ERROR] approval became stale"
                                 "[APPROVAL] cancelled\n"))
        (condition-case err
            (progn
              (nl-agent-client-approve nl-agent-ui--client id token
                                       (intern decision))
              (nl-agent-ui--clear-approval)
              (nl-agent-ui--insert "[APPROVAL] %s\n" decision))
          (error (nl-agent-ui--insert "[ERROR] %s"
                                      (error-message-string err))))))))

(defun nl-agent-ui-approve-once ()
  "Approve the displayed tool request once."
  (interactive)
  (nl-agent-ui--approval "once"))

(defun nl-agent-ui-approve-session ()
  "Approve the exact displayed tool call for this session."
  (interactive)
  (nl-agent-ui--approval "session"))

(defun nl-agent-ui-deny ()
  "Deny the displayed tool request."
  (interactive)
  (nl-agent-ui--approval "deny"))

(defun nl-agent-ui-quit ()
  "Gracefully quit the service when no request is pending."
  (interactive)
  ;; The transport owns the in-flight request check.
  (nl-agent-ui--request "quit"))

(defun nl-agent-ui-disconnect ()
  "Force-disconnect the owned local service process."
  (interactive)
  (when (and (nl-agent-ui--live-client-p)
             (yes-or-no-p "Force disconnect the local Agent? "))
    (nl-agent-client-close nl-agent-ui--client)
    (nl-agent-ui--clear-approval)))

(defun nl-agent-ui--kill-buffer ()
  "Clean up the owned client when its UI buffer is killed."
  (when (nl-agent-ui--live-client-p)
    (condition-case nil
        (nl-agent-client-close nl-agent-ui--client)
      (error nil))))

(defvar nl-agent-ui-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "r") #'nl-agent-ui-run)
    (define-key map (kbd "c") #'nl-agent-ui-chat)
    (define-key map (kbd "m") #'nl-agent-ui-models)
    (define-key map (kbd "s") #'nl-agent-ui-switch)
    (define-key map (kbd "g") #'nl-agent-ui-status)
    (define-key map (kbd "q") #'nl-agent-ui-quit)
    (define-key map (kbd "a") #'nl-agent-ui-approve-once)
    (define-key map (kbd "S") #'nl-agent-ui-approve-session)
    (define-key map (kbd "d") #'nl-agent-ui-deny)
    (define-key map (kbd "C-c C-k") #'nl-agent-ui-disconnect)
    map))

(define-derived-mode nl-agent-ui-mode special-mode "NeLisp-Agent"
  "Read-only transcript mode for one local NeLisp Agent connection."
  (setq-local truncate-lines nil)
  (setq-local buffer-read-only t))

;;;###autoload
(defun nl-agent-start (&optional workspace)
  "Start a fresh local NeLisp Agent UI connection.
When called interactively, prompt for WORKSPACE.  The service is always
started with JSONL and approval protocol flags; no network client is loaded."
  (interactive
   (list (read-directory-name "Agent workspace: " default-directory nil t)))
  (let* ((workspace (file-name-as-directory
                     (expand-file-name (or workspace default-directory))))
         (buffer (generate-new-buffer "*NeLisp Agent*"))
         (client nil))
    (with-current-buffer buffer
      (nl-agent-ui-mode)
      (setq-local nl-agent-ui--workspace workspace)
      (add-hook 'kill-buffer-hook #'nl-agent-ui--kill-buffer nil t)
      (nl-agent-ui--insert "NeLisp Agent workspace: %s\n" workspace)
      (condition-case err
          (setq client
                (nl-agent-client-open
                 (nl-agent-ui--command workspace) workspace
                 (lambda (event-client packet)
                   (when (and (buffer-live-p buffer)
                              (eq event-client (buffer-local-value
                                          'nl-agent-ui--client buffer)))
                     (with-current-buffer buffer
                       (nl-agent-ui--event event-client packet))))
                 (lambda (event-client reason)
                   (when (and (buffer-live-p buffer)
                              (eq event-client (buffer-local-value
                                          'nl-agent-ui--client buffer)))
                     (with-current-buffer buffer
                       (nl-agent-ui--closed event-client reason))))))
        (error
         (nl-agent-ui--insert "[ERROR] %s\n" (error-message-string err))))
      (setq-local nl-agent-ui--client client))
    (pop-to-buffer buffer)
    buffer))

(provide 'nl-agent-ui)
;;; nl-agent-ui.el ends here
