;;; nl-agent-stdio.el --- supervised stdio boundary for NeLisp Agent  -*- lexical-binding: t; -*-

;; Protocol: one s-expression request per line and one plist response per line.
;; Parsing never evaluates input.  A host process owns networking, credentials,
;; and worker restarts; this module owns service commands and framing.

;;; Code:

(require 'nl-llm-compat)
(require 'cl-lib)
(require 'subr-x)
(require 'nl-agent-service)
(require 'nl-agent-tool)
(require 'nl-agent-broker)
(require 'nl-agent-startup)
(require 'nl-agent-wire)

(declare-function read-stdin-bytes "ext:nelisp-runtime" (nbytes))
(declare-function nelisp--arena-stats "ext:nelisp-runtime" ())
(defvar read-eval)

(defvar nl-agent-stdio-chunk-size 4096
  "Bytes requested per standalone stdin read.")

(defvar nl-agent-stdio--pending ""
  "Input bytes that do not yet form a complete request line.")

(defvar nl-agent-stdio--next-request-id 0
  "Last nested request id emitted to the supervising host.")

(cl-defstruct (nl-agent-stdio-model-bridge
               (:constructor nl-agent-stdio-model-bridge--make))
  registry
  groups
  call)

(defun nl-agent-stdio--protocol-error (message)
  "Return a structured protocol error containing MESSAGE."
  (list :status 'error :kind 'protocol :error message))

(defun nl-agent-stdio--arity-p (request arity)
  "Return non-nil when proper list REQUEST contains ARITY arguments."
  (condition-case nil
      (= (length (cdr request)) arity)
    (error nil)))

;;;###autoload
(defun nl-agent-stdio-parse-line (line)
  "Parse exactly one data form from LINE without evaluating it.
Return (:status ok :request FORM), or a structured protocol error."
  (condition-case err
      (let* ((read-eval nil)
             (parsed (read-from-string line))
             (request (car parsed))
             (end (cdr parsed))
             (trailing (string-trim (substring line end))))
        (if (string-empty-p trailing)
            (list :status 'ok :request request)
          (nl-agent-stdio--protocol-error
           "request line must contain exactly one form")))
    (error
     (nl-agent-stdio--protocol-error
      (format "unreadable request: %S" err)))))

;;;###autoload
(defun nl-agent-stdio-handle (service request &optional run)
  "Handle one parsed REQUEST against SERVICE and return a response plist.

Accepted requests are (models), (status), (chat TEXT), (switch SELECTOR),
(command TEXT), (run TASK), (checkpoint), (restore SNAPSHOT), (stats), and
(quit).  RUN, when configured, receives TASK and implements the agent loop."
  (condition-case err
      (cond
       ((not (consp request))
        (nl-agent-stdio--protocol-error "request must be a non-empty list"))
       ((eq (car request) 'models)
        (if (nl-agent-stdio--arity-p request 0)
            (nl-agent-service-command service "/models")
          (nl-agent-stdio--protocol-error "models expects no arguments")))
       ((eq (car request) 'status)
        (if (nl-agent-stdio--arity-p request 0)
            (nl-agent-service-command service "/status")
          (nl-agent-stdio--protocol-error "status expects no arguments")))
       ((eq (car request) 'chat)
        (if (and (nl-agent-stdio--arity-p request 1)
                 (stringp (cadr request)))
            ;; Chat text is data, even when it begins with a service command.
            (nl-agent-service-command service (cadr request) t)
          (nl-agent-stdio--protocol-error "chat expects one text argument")))
       ((eq (car request) 'switch)
        (if (and (nl-agent-stdio--arity-p request 1)
                 (stringp (cadr request)))
            (nl-agent-service-command
             service (concat "/model " (cadr request)))
          (nl-agent-stdio--protocol-error
           "switch expects one model selector")))
       ((eq (car request) 'command)
        (if (and (nl-agent-stdio--arity-p request 1)
                 (stringp (cadr request)))
            (nl-agent-service-command service (cadr request))
          (nl-agent-stdio--protocol-error "command expects one text argument")))
       ((eq (car request) 'run)
        (cond
         ((not (and (nl-agent-stdio--arity-p request 1)
                    (stringp (cadr request))))
          (nl-agent-stdio--protocol-error "run expects one task argument"))
         ((not (functionp run))
          (nl-agent-stdio--protocol-error
           "agent runtime is not configured for this worker"))
         (t
          (let ((result (funcall run (cadr request))))
            (unless (listp result)
              (error "agent runtime returned non-data result: %S" result))
            (append (list :kind 'agent-run) result)))))
       ((eq (car request) 'checkpoint)
        (if (nl-agent-stdio--arity-p request 0)
            (list :status 'ok :kind 'checkpoint
                  :checkpoint (nl-agent-service-checkpoint service))
          (nl-agent-stdio--protocol-error
           "checkpoint expects no arguments")))
       ((eq (car request) 'restore)
        (if (nl-agent-stdio--arity-p request 1)
            (progn
              (nl-agent-service-restore service (cadr request))
              (list :status 'ok :kind 'restored
                    :model (nl-agent-service-current-model service)
                    :message-count
                    (length (nl-agent-service-messages service))))
          (nl-agent-stdio--protocol-error
           "restore expects one checkpoint argument")))
       ((eq (car request) 'stats)
        (if (not (nl-agent-stdio--arity-p request 0))
            (nl-agent-stdio--protocol-error "stats expects no arguments")
          (if (fboundp 'nelisp--arena-stats)
              (list :status 'ok :kind 'stats
                    :arena (nelisp--arena-stats))
            (list :status 'ok :kind 'stats :arena 'unavailable))))
       ((eq (car request) 'quit)
        (if (nl-agent-stdio--arity-p request 0)
            (nl-agent-service-command service "/quit")
          (nl-agent-stdio--protocol-error "quit expects no arguments")))
       (t
        (nl-agent-stdio--protocol-error
         (format "unknown operation: %S" (car request)))))
    (error
     (nl-agent-stdio--protocol-error (format "%S" err)))))

(defun nl-agent-stdio--fill ()
  "Read one chunk from stdin and append it to pending input."
  (let ((chunk (read-stdin-bytes nl-agent-stdio-chunk-size)))
    (when chunk
      (setq nl-agent-stdio--pending
            (concat nl-agent-stdio--pending chunk))
      t)))

(defun nl-agent-stdio-next-line ()
  "Return the next complete request line, or nil at end of input."
  (let ((idx (string-search "\n" nl-agent-stdio--pending))
        (open t))
    (while (and (null idx) open)
      (if (nl-agent-stdio--fill)
          (setq idx (string-search "\n" nl-agent-stdio--pending))
        (setq open nil)))
    (cond
     (idx
      (let ((line (substring nl-agent-stdio--pending 0 idx)))
        (setq nl-agent-stdio--pending
              (substring nl-agent-stdio--pending (1+ idx)))
        (if (string-suffix-p "\r" line)
            (substring line 0 (1- (length line)))
          line)))
     ((> (length nl-agent-stdio--pending) 0)
      (let ((line nl-agent-stdio--pending))
        (setq nl-agent-stdio--pending "")
        line))
     (t nil))))

(defun nl-agent-stdio-write (form)
  "Write FORM as one response line and flush when supported."
  ;; Standalone NeLisp currently prints literal newlines inside strings.  Escape
  ;; them after serialization so the one-form-per-line protocol stays framed;
  ;; the reader reconstructs the original string on the host.
  (princ (nl-agent-wire-frame form))
  (terpri)
  (when (fboundp 'force-output)
    (force-output)))

;;;###autoload
(defun nl-agent-stdio-ready ()
  "Notify a supervising host that worker initialization is complete."
  (nl-agent-stdio-write '(:event ready)))

;;;###autoload
(defun nl-agent-stdio-broker-call (request)
  "Send broker REQUEST to the host and synchronously return assistant text.

The emitted event contains a monotonically increasing :REQUEST-ID.  The next
input line must be (inference-result ID TEXT) or (inference-error ID TEXT).
This nested exchange lets a host own HTTP and credentials while standalone
NeLisp retains the service and conversation state."
  (setq nl-agent-stdio--next-request-id
        (1+ nl-agent-stdio--next-request-id))
  (let ((request-id nl-agent-stdio--next-request-id))
    (nl-agent-stdio-write
     (list :event 'inference
           :request-id request-id
           :provider (plist-get request :provider)
           :model (plist-get request :model)
           :options (copy-tree (plist-get request :options))
           :messages (copy-tree (plist-get request :messages))))
    (let ((line (nl-agent-stdio-next-line)))
      (unless line
        (error "host closed stdin during inference request %d" request-id))
      (let* ((parsed (nl-agent-stdio-parse-line line))
             (response (plist-get parsed :request)))
        (unless (eq (plist-get parsed :status) 'ok)
          (error "invalid host inference response %d: %s"
                 request-id (plist-get parsed :error)))
        (cond
         ((and (consp response)
               (eq (car response) 'inference-result)
               (nl-agent-stdio--arity-p response 2)
               (equal (cadr response) request-id)
               (stringp (caddr response)))
          (caddr response))
         ((and (consp response)
               (eq (car response) 'inference-error)
               (nl-agent-stdio--arity-p response 2)
               (equal (cadr response) request-id)
               (stringp (caddr response)))
          (error "host inference %d failed: %s"
                 request-id (caddr response)))
         (t
          (error "uncorrelated host inference response %d: %S"
                 request-id response)))))))

;;;###autoload
(defun nl-agent-stdio-tool-call (name args &optional context)
  "Ask the supervising host to invoke tool NAME with ARGS and CONTEXT.

The correlated host response is (tool-result ID TEXT) or
(tool-error ID TEXT).  Host-side permission checks remain authoritative."
  (unless (and (stringp name) (not (string-empty-p name)))
    (error "broker tool name must be non-empty text"))
  (setq nl-agent-stdio--next-request-id
        (1+ nl-agent-stdio--next-request-id))
  (let ((request-id nl-agent-stdio--next-request-id))
    (nl-agent-stdio-write
     (list :event 'tool
           :request-id request-id
           :tool name
           :args (copy-tree args)
           :context (copy-tree context)))
    (let ((line (nl-agent-stdio-next-line)))
      (unless line
        (error "host closed stdin during tool request %d" request-id))
      (let* ((parsed (nl-agent-stdio-parse-line line))
             (response (plist-get parsed :request)))
        (unless (eq (plist-get parsed :status) 'ok)
          (error "invalid host tool response %d: %s"
                 request-id (plist-get parsed :error)))
        (cond
         ((and (consp response)
               (eq (car response) 'tool-result)
               (nl-agent-stdio--arity-p response 2)
               (equal (cadr response) request-id)
               (stringp (caddr response)))
          (caddr response))
         ((and (consp response)
               (eq (car response) 'tool-error)
               (nl-agent-stdio--arity-p response 2)
               (equal (cadr response) request-id)
               (stringp (caddr response)))
          (error "host tool %d failed: %s"
                 request-id (caddr response)))
         (t
          (error "uncorrelated host tool response %d: %S"
                 request-id response)))))))

;;;###autoload
(defun nl-agent-stdio-host-model-catalog ()
  "Request the current public model catalog from the supervising host."
  (setq nl-agent-stdio--next-request-id
        (1+ nl-agent-stdio--next-request-id))
  (let ((request-id nl-agent-stdio--next-request-id))
    (nl-agent-stdio-write
     (list :event 'model-catalog :request-id request-id))
    (let ((line (nl-agent-stdio-next-line)))
      (unless line
        (error "host closed stdin during model catalog request %d"
               request-id))
      (let* ((parsed (nl-agent-stdio-parse-line line))
             (response (plist-get parsed :request)))
        (unless (eq (plist-get parsed :status) 'ok)
          (error "invalid host model catalog response %d: %s"
                 request-id (plist-get parsed :error)))
        (cond
         ((and (consp response)
               (eq (car response) 'model-catalog-result)
               (nl-agent-stdio--arity-p response 2)
               (equal (cadr response) request-id)
               (listp (caddr response)))
          (copy-tree (caddr response)))
         ((and (consp response)
               (eq (car response) 'model-catalog-error)
               (nl-agent-stdio--arity-p response 2)
               (equal (cadr response) request-id)
               (stringp (caddr response)))
          (error "host model catalog %d failed: %s"
                 request-id (caddr response)))
         (t
          (error "uncorrelated host model catalog response %d: %S"
                 request-id response)))))))

;;;###autoload
(defun nl-agent-stdio-host-startup-config ()
  "Request detached provider-neutral startup selection data from the host.
Return nil when the host selects legacy worker defaults."
  (setq nl-agent-stdio--next-request-id
        (1+ nl-agent-stdio--next-request-id))
  (let ((request-id nl-agent-stdio--next-request-id))
    (nl-agent-stdio-write
     (list :event 'startup-config :request-id request-id))
    (let ((line (nl-agent-stdio-next-line)))
      (unless line
        (error "host closed stdin during startup config request %d"
               request-id))
      (let* ((parsed (nl-agent-stdio-parse-line line))
             (response (plist-get parsed :request)))
        (unless (eq (plist-get parsed :status) 'ok)
          (error "invalid host startup config response %d: %s"
                 request-id (plist-get parsed :error)))
        (cond
         ((and (consp response)
               (eq (car response) 'startup-config-result)
               (nl-agent-stdio--arity-p response 2)
               (equal (cadr response) request-id))
          (nl-agent-startup-validate-config (caddr response)))
         ((and (consp response)
               (eq (car response) 'startup-config-error)
               (nl-agent-stdio--arity-p response 2)
               (equal (cadr response) request-id)
               (stringp (caddr response)))
          (error "host startup config %d failed: %s"
                 request-id (caddr response)))
         (t
          (error "uncorrelated host startup config response %d: %S"
                 request-id response)))))))

(defun nl-agent-stdio--model-descriptor (descriptor)
  "Return host DESCRIPTOR without provider routing fields."
  (unless (and (listp descriptor)
               (stringp (plist-get descriptor :provider))
               (plist-member descriptor :id))
    (error "invalid host model descriptor: %S" descriptor))
  (let ((tail descriptor) (result nil))
    (while tail
      (unless (memq (car tail) '(:provider :qualified-id))
        (setq result
              (append result (list (car tail) (cadr tail)))))
      (setq tail (cddr tail)))
    result))

;;;###autoload
(defun nl-agent-stdio--model-groups (descriptors)
  "Validate DESCRIPTORS and group public models by host provider."
  (unless (listp descriptors)
    (error "host model catalog must be a list"))
  (let ((groups nil))
    (dolist (descriptor descriptors)
      (let* ((provider (plist-get descriptor :provider))
             (public (nl-agent-stdio--model-descriptor descriptor))
             (group (assoc provider groups)))
        (if group
            (setcdr group (append (cdr group) (list public)))
          (setq groups
                (append groups (list (cons provider (list public))))))))
    groups))

;;;###autoload
(defun nl-agent-stdio-model-bridge-refresh (bridge descriptors)
  "Replace BRIDGE's public catalog with host DESCRIPTORS.
Existing provider objects read the replacement immediately.  Newly observed
providers are appended to the same registry without disturbing live sessions."
  (unless (nl-agent-stdio-model-bridge-p bridge)
    (error "nl-agent-stdio-model-bridge-refresh: invalid bridge"))
  (let ((groups (nl-agent-stdio--model-groups descriptors)))
    ;; Validate every group against an isolated registry before changing the
    ;; model catalogs visible to the live service.
    (let ((validation (nl-llm-agent-provider-registry-new)))
      (dolist (group groups)
        (nl-llm-agent-provider-register
         validation
         (nl-agent-broker-provider
          (car group) (copy-tree (cdr group))
          (nl-agent-stdio-model-bridge-call bridge)))))
    (setf (nl-agent-stdio-model-bridge-groups bridge) groups)
    (dolist (group groups)
      (let ((provider-id (car group)))
        (unless (nl-llm-agent-provider--get
                 (nl-agent-stdio-model-bridge-registry bridge) provider-id)
          (nl-llm-agent-provider-register
           (nl-agent-stdio-model-bridge-registry bridge)
           (nl-agent-broker-provider
            provider-id
            (lambda ()
              (copy-tree
               (cdr
                (assoc
                 provider-id
                 (nl-agent-stdio-model-bridge-groups bridge)))))
            (nl-agent-stdio-model-bridge-call bridge))))))
    (nl-agent-stdio-model-bridge-registry bridge)))

;;;###autoload
(defun nl-agent-stdio-model-bridge-new (descriptors &optional call)
  "Create a mutable broker bridge from host model DESCRIPTORS."
  (let ((call (or call #'nl-agent-stdio-broker-call)))
    (unless (functionp call)
      (error "nl-agent-stdio-model-bridge-new: CALL must be a function"))
    (let ((bridge
           (nl-agent-stdio-model-bridge--make
            :registry (nl-llm-agent-provider-registry-new)
            :groups nil :call call)))
      (nl-agent-stdio-model-bridge-refresh bridge descriptors)
      bridge)))

;;;###autoload
(defun nl-agent-stdio-broker-provider-registry (descriptors &optional call)
  "Build broker providers from public host model DESCRIPTORS.
CALL defaults to `nl-agent-stdio-broker-call'.  For a refreshable catalog use
`nl-agent-stdio-model-bridge-new' directly."
  (nl-agent-stdio-model-bridge-registry
   (nl-agent-stdio-model-bridge-new descriptors call)))

;;;###autoload
(defun nl-agent-stdio-host-tool-catalog ()
  "Request the current public tool catalog from the supervising host."
  (setq nl-agent-stdio--next-request-id
        (1+ nl-agent-stdio--next-request-id))
  (let ((request-id nl-agent-stdio--next-request-id))
    (nl-agent-stdio-write
     (list :event 'tool-catalog :request-id request-id))
    (let ((line (nl-agent-stdio-next-line)))
      (unless line
        (error "host closed stdin during tool catalog request %d"
               request-id))
      (let* ((parsed (nl-agent-stdio-parse-line line))
             (response (plist-get parsed :request)))
        (unless (eq (plist-get parsed :status) 'ok)
          (error "invalid host tool catalog response %d: %s"
                 request-id (plist-get parsed :error)))
        (cond
         ((and (consp response)
               (eq (car response) 'tool-catalog-result)
               (nl-agent-stdio--arity-p response 2)
               (equal (cadr response) request-id)
               (listp (caddr response)))
          (copy-tree (caddr response)))
         ((and (consp response)
               (eq (car response) 'tool-catalog-error)
               (nl-agent-stdio--arity-p response 2)
               (equal (cadr response) request-id)
               (stringp (caddr response)))
          (error "host tool catalog %d failed: %s"
                 request-id (caddr response)))
         (t
          (error "uncorrelated host tool catalog response %d: %S"
                 request-id response)))))))

;;;###autoload
(defun nl-agent-stdio-broker-tool-registry (descriptors)
  "Build a tool registry whose DESCRIPTORS execute through the host.

Each descriptor is a plist with :NAME and optional :DESCRIPTION, :RISK, and
:METADATA.  Only public descriptions cross into the standalone worker."
  (unless (listp descriptors)
    (error "nl-agent-stdio-broker-tool-registry: expected a list"))
  (let ((registry (nl-agent-tool-registry-new)))
    (dolist (descriptor descriptors)
      (unless (listp descriptor)
        (error "invalid broker tool descriptor: %S" descriptor))
      (let ((name (plist-get descriptor :name)))
        (nl-agent-tool-register
         registry
         (nl-agent-tool-new
          name
          (lambda (args context)
            (nl-agent-stdio-tool-call name args context))
          :description (or (plist-get descriptor :description) "")
          :risk (or (plist-get descriptor :risk) 'execute)
          :metadata (plist-get descriptor :metadata)))))
    registry))

;;;###autoload
(defun nl-agent-stdio-main (service &optional run prepare)
  "Serve SERVICE until (quit) or stdin reaches end of file.
RUN optionally implements the (run TASK) operation.  PREPARE, when non-nil,
receives each valid request before dispatch and may refresh broker state.
Return `nl-agent-service-eof' as the standalone --load stream marker."
  (when (and prepare (not (functionp prepare)))
    (error "nl-agent-stdio-main: PREPARE must be a function"))
  ;; Startup handshakes may already have consumed a chunk containing later
  ;; requests.  The process-level globals start empty, so resetting them here
  ;; would discard buffered input and reuse correlation ids.
  (let ((line (nl-agent-stdio-next-line))
        (running t))
    (while (and running line)
      (let* ((parsed (nl-agent-stdio-parse-line line))
             (valid (eq (plist-get parsed :status) 'ok))
             (request (plist-get parsed :request)))
        (if valid
            (nl-agent-stdio-write
             (condition-case err
                 (progn
                   (when prepare (funcall prepare request))
                   (nl-agent-stdio-handle service request run))
               (error
                (nl-agent-stdio--protocol-error (format "%S" err)))))
          (nl-agent-stdio-write parsed))
        (when valid
          (when (and (consp request) (eq (car request) 'quit))
            (setq running nil))))
      (when running
        (setq line (nl-agent-stdio-next-line)))))
  (when (eq (nl-agent-service-state service) 'open)
    (nl-agent-service-close service))
  'nl-agent-service-eof)

(provide 'nl-agent-stdio)
;;; nl-agent-stdio.el ends here
