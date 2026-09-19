;;; nl-agent-service.el --- unified NeLisp Agent service core  -*- lexical-binding: t; -*-

;; This is the outward-facing boundary for NeLisp Agent.  It owns durable,
;; provider-neutral conversation state while nelisp-llm owns model discovery,
;; inference sessions, and transactional model switching.

;;; Code:

(require 'nl-llm-compat)
(require 'cl-lib)
(require 'subr-x)
(require 'nl-llm-agent-provider)

(cl-defstruct (nl-agent-service
               (:constructor nl-agent-service--make))
  registry
  session
  messages
  fallbacks
  state
  history
  last-error)

(defun nl-agent-service--keys (keys allowed where)
  "Validate KEYS against ALLOWED for WHERE and return KEYS."
  (unless (= (% (length keys) 2) 0)
    (error "%s: options must be KEY VALUE pairs" where))
  (let ((tail keys))
    (while tail
      (unless (memq (car tail) allowed)
        (error "%s: unknown option %S" where (car tail)))
      (setq tail (cddr tail))))
  keys)

(defun nl-agent-service--ensure (service where &optional allow-closed)
  "Validate SERVICE for WHERE, optionally ALLOW-CLOSED."
  (unless (nl-agent-service-p service)
    (error "%s: invalid service" where))
  (unless (or allow-closed (eq (nl-agent-service-state service) 'open))
    (error "%s: service is not open" where))
  service)

(defun nl-agent-service--record (service event)
  "Add EVENT to SERVICE's newest-first audit history."
  (setf (nl-agent-service-history service)
        (cons event (nl-agent-service-history service)))
  event)

(defun nl-agent-service--error (kind err)
  "Return a structured KIND error for condition ERR."
  (list :status 'error :kind kind :error (format "%S" err)))

(defun nl-agent-service--fallback-list (value)
  "Validate and copy ordered fallback selector VALUE."
  (unless (listp value)
    (error "nl-agent-service-new: :fallbacks must be a list"))
  (let ((result nil))
    (dolist (selector value)
      (unless (and (stringp selector) (not (string-empty-p selector)))
        (error "nl-agent-service-new: invalid fallback selector %S"
               selector))
      (unless (member selector result)
        (setq result (append result (list selector)))))
    result))

;;;###autoload
(defun nl-agent-service-new (registry selector &rest keys)
  "Open a NeLisp Agent service on SELECTOR from provider REGISTRY.

Recognized KEYS are :SYSTEM for an initial system message, :OPTIONS for opaque
provider options, and :FALLBACKS for ordered model selectors.  Conversation
messages remain provider-neutral and are owned by this service rather than by
any model backend."
  (nl-agent-service--keys
   keys '(:system :options :fallbacks) "nl-agent-service-new")
  (let ((system (plist-get keys :system))
        (options-present (plist-member keys :options))
        (fallbacks
         (nl-agent-service--fallback-list (plist-get keys :fallbacks))))
    (unless (or (null system) (stringp system))
      (error "nl-agent-service-new: :system must be nil or text"))
    (let ((session
           (if options-present
               (nl-llm-agent-session-open
                registry selector :options (plist-get keys :options))
             (nl-llm-agent-session-open registry selector))))
      (nl-agent-service--make
       :registry registry
       :session session
       :messages (if system (list (cons 'system system)) nil)
       :fallbacks fallbacks
       :state 'open
       :history nil
       :last-error nil))))

;;;###autoload
(defun nl-agent-service-models (service)
  "Return SERVICE's public model catalog."
  (nl-agent-service--ensure service "nl-agent-service-models" t)
  (mapcar #'nl-agent-service--unique-plist
          (nl-llm-agent-provider-models
           (nl-agent-service-registry service))))

(defun nl-agent-service--unique-plist (value)
  "Return VALUE with duplicate plist keys removed, preserving first wins.

Provider normalization prepends routing fields to descriptors that may already
contain those fields.  The public service boundary keeps the historical
`plist-get' first-value semantics while making the data safe for strict JSON
object encoders.  This is intentionally a shallow normalization."
  (let ((tail (copy-tree value)) result seen)
    (while tail
      (unless (consp (cdr tail))
        (error "service model descriptor is not a proper plist"))
      (let ((key (pop tail))
            (item (pop tail)))
        (unless (memq key seen)
          (push key seen)
          (setq result (append result (list key item))))))
    result))

;;;###autoload
(defun nl-agent-service-current-model (service)
  "Return SERVICE's active provider-qualified model id."
  (nl-agent-service--ensure service "nl-agent-service-current-model" t)
  (let ((session (nl-agent-service-session service)))
    (concat (nl-llm-agent-session-provider-id session)
            "/"
            (nl-llm-agent-session-model-id session))))

;;;###autoload
(defun nl-agent-service-status (service)
  "Return a provider-neutral status snapshot for SERVICE."
  (nl-agent-service--ensure service "nl-agent-service-status" t)
  (let* ((session (nl-agent-service-session service))
         (status
          (list :state (nl-agent-service-state service)
                :model (nl-agent-service-current-model service)
                :generation (nl-llm-agent-session-generation session)
                :message-count
                (length (nl-agent-service-messages service)))))
    (if (nl-agent-service-fallbacks service)
        (append status
                (list :fallbacks
                      (copy-sequence
                       (nl-agent-service-fallbacks service))))
      status)))

(defun nl-agent-service--complete-once (service request)
  "Complete REQUEST on SERVICE's current model and commit on success."
  (let* ((session (nl-agent-service-session service))
         (result (nl-llm-agent-session-complete session request)))
    (setf (nl-agent-service-messages service)
          (copy-tree (nl-llm-agent-session-messages session)))
    (setf (nl-agent-service-last-error service) nil)
    (nl-agent-service--record
     service
     (list :status 'completed
           :model (nl-agent-service-current-model service)
           :message-count (length (nl-agent-service-messages service))))
    result))

(defun nl-agent-service--qualified-selector (service selector)
  "Resolve SELECTOR for SERVICE and return its provider-qualified id."
  (let* ((session (nl-agent-service-session service))
         (model
          (nl-llm-agent-provider-resolve
           (nl-agent-service-registry service)
           selector
           (nl-llm-agent-session-provider-id session))))
    (plist-get model :qualified-id)))

(defun nl-agent-service--fallback-complete
    (service request primary primary-error)
  "Try SERVICE fallbacks for REQUEST after PRIMARY-ERROR on PRIMARY."
  (let ((attempted (list primary))
        (failures
         (list (list :model primary :error (format "%S" primary-error))))
        (outcome nil))
    (setq outcome
          (catch 'nl-agent-fallback-success
            (dolist (selector (nl-agent-service-fallbacks service))
              (condition-case err
                  (let ((qualified
                         (nl-agent-service--qualified-selector
                          service selector)))
                    (unless (member qualified attempted)
                      (setq attempted (append attempted (list qualified)))
                      (nl-agent-service-switch service selector)
                      (let ((result
                             (nl-agent-service--complete-once
                              service request)))
                        (nl-agent-service--record
                         service
                         (list :status 'failed-over
                               :from primary
                               :to (nl-agent-service-current-model service)
                               :failures (nreverse failures)))
                        (throw 'nl-agent-fallback-success
                               (cons t result)))))
                (error
                 (setq failures
                       (cons (list :model selector
                                   :error (format "%S" err))
                             failures)))))
            nil))
    (if outcome
        (cdr outcome)
      (let ((restore-error nil))
        (unless (equal (nl-agent-service-current-model service) primary)
          (condition-case err
              (nl-agent-service-switch service primary)
            (error (setq restore-error (format "%S" err)))))
        (setq failures (nreverse failures))
        (nl-agent-service--record
         service
         (list :status 'fallback-exhausted
               :model (nl-agent-service-current-model service)
               :failures failures
               :restore-error restore-error))
        (error "all completion attempts failed: %S"
               failures)))))

;;;###autoload
(defun nl-agent-service-send (service text)
  "Send user TEXT through SERVICE and return assistant text.
Only a successful completion is committed to the service conversation."
  (nl-agent-service--ensure service "nl-agent-service-send")
  (unless (stringp text)
    (error "nl-agent-service-send: TEXT must be a string"))
  (let* ((request
          (append (nl-agent-service-messages service)
                  (list (cons 'user text))))
         (primary (nl-agent-service-current-model service)))
    (condition-case err
        (nl-agent-service--complete-once service request)
      (error
       (nl-agent-service--fallback-complete
        service request primary err)))))

;;;###autoload
(defun nl-agent-service-switch (service selector &rest keys)
  "Transactionally switch SERVICE to model SELECTOR.
An optional :OPTIONS VALUE is forwarded to the provider session."
  (nl-agent-service--ensure service "nl-agent-service-switch")
  (nl-agent-service--keys
   keys '(:options) "nl-agent-service-switch")
  (let ((from (nl-agent-service-current-model service))
        (session (nl-agent-service-session service)))
    (condition-case err
        (progn
          (if (plist-member keys :options)
              (nl-llm-agent-session-switch
               session selector :options (plist-get keys :options))
            (nl-llm-agent-session-switch session selector))
          (setf (nl-agent-service-last-error service) nil)
          (nl-agent-service--record
           service
           (list :status 'switched
                 :from from
                 :to (nl-agent-service-current-model service)))
          service)
      (error
       (setf (nl-agent-service-last-error service) (format "%S" err))
       (nl-agent-service--record
        service
        (list :status 'failed :kind 'switch :from from
              :to selector :error (format "%S" err)))
       (signal (car err) (cdr err))))))

;;;###autoload
(defun nl-agent-service-close (service)
  "Close SERVICE idempotently and return it."
  (nl-agent-service--ensure service "nl-agent-service-close" t)
  (when (eq (nl-agent-service-state service) 'open)
    (nl-llm-agent-session-close (nl-agent-service-session service))
    (setf (nl-agent-service-state service) 'closed)
    (nl-agent-service--record
     service
     (list :status 'closed
           :model (nl-agent-service-current-model service))))
  service)

(defun nl-agent-service--checkpoint-messages (messages)
  "Validate provider-neutral checkpoint MESSAGES and return a copy."
  (unless (listp messages)
    (error "checkpoint :messages must be a list"))
  (dolist (message messages)
    (unless (and (consp message)
                 (or (symbolp (car message)) (stringp (car message)))
                 (stringp (cdr message)))
      (error "checkpoint contains invalid message %S" message)))
  (copy-tree messages))

;;;###autoload
(defun nl-agent-service-checkpoint (service)
  "Return SERVICE's portable state without backend objects or credentials."
  (nl-agent-service--ensure service "nl-agent-service-checkpoint")
  (let ((session (nl-agent-service-session service)))
    (list :format 'nl-agent-service-v1
          :model (nl-agent-service-current-model service)
          :options (copy-tree (nl-llm-agent-session-options session))
          :fallbacks (copy-sequence (nl-agent-service-fallbacks service))
          :messages (copy-tree (nl-agent-service-messages service)))))

(defun nl-agent-service--validate-checkpoint (checkpoint)
  "Validate CHECKPOINT and return a detached copy."
  (nl-agent-service--keys
   checkpoint '(:format :model :options :fallbacks :messages)
   "nl-agent-service-restore")
  (unless (eq (plist-get checkpoint :format) 'nl-agent-service-v1)
    (error "nl-agent-service-restore: unsupported checkpoint format %S"
           (plist-get checkpoint :format)))
  (let ((model (plist-get checkpoint :model)))
    (unless (and (stringp model) (not (string-empty-p model)))
      (error "nl-agent-service-restore: checkpoint model is invalid")))
  (let ((copy (copy-tree checkpoint)))
    (plist-put
     copy :fallbacks
     (nl-agent-service--fallback-list (plist-get copy :fallbacks)))
    (plist-put
     copy :messages
     (nl-agent-service--checkpoint-messages (plist-get copy :messages)))
    copy))

;;;###autoload
(defun nl-agent-service-restore (service checkpoint)
  "Transactionally replace SERVICE's portable state from CHECKPOINT.
The checkpoint model is opened before the old backend is closed."
  (nl-agent-service--ensure service "nl-agent-service-restore")
  (let* ((snapshot (nl-agent-service--validate-checkpoint checkpoint))
         (from (nl-agent-service-current-model service))
         (replacement
          (nl-agent-service-new
           (nl-agent-service-registry service)
           (plist-get snapshot :model)
           :options (plist-get snapshot :options)
           :fallbacks (plist-get snapshot :fallbacks)))
         (messages (plist-get snapshot :messages))
         (old-session (nl-agent-service-session service))
         (new-session (nl-agent-service-session replacement)))
    (setf (nl-agent-service-messages replacement) (copy-tree messages))
    (setf (nl-llm-agent-session-messages new-session) (copy-tree messages))
    (nl-llm-agent-session-close old-session)
    (setf (nl-agent-service-session service) new-session)
    (setf (nl-agent-service-messages service) (copy-tree messages))
    (setf (nl-agent-service-fallbacks service)
          (copy-sequence (nl-agent-service-fallbacks replacement)))
    (setf (nl-agent-service-state service) 'open)
    (setf (nl-agent-service-last-error service) nil)
    (nl-agent-service--record
     service
     (list :status 'restored
           :from from
           :to (nl-agent-service-current-model service)
           :message-count (length messages)))
    service))

;;;###autoload
(defun nl-agent-service-command (service input &optional literal)
  "Handle one user INPUT and return a structured service result.

Built-in commands are /models, /model SELECTOR, /status, and /quit.  Other
slash-prefixed input is rejected; ordinary input is sent to the active model.
When LITERAL is non-nil, INPUT is always sent as ordinary model text."
  (unless (stringp input)
    (error "nl-agent-service-command: INPUT must be a string"))
  (let ((command (string-trim input)))
    (cond
     ((and (not literal) (equal command "/models"))
      (condition-case err
          (list :status 'ok :kind 'models
                :models (nl-agent-service-models service))
        (error (nl-agent-service--error 'models err))))
     ((and (not literal) (equal command "/status"))
      (condition-case err
          (append (list :status 'ok :kind 'status)
                  (nl-agent-service-status service))
        (error (nl-agent-service--error 'status err))))
     ((and (not literal) (equal command "/model"))
      (list :status 'error :kind 'command
            :error "/model requires a model selector"))
     ((and (not literal) (string-prefix-p "/model " command))
      (let ((selector (string-trim (substring command 7)))
            (from (condition-case nil
                      (nl-agent-service-current-model service)
                    (error nil))))
        (if (string-empty-p selector)
            (list :status 'error :kind 'command
                  :error "/model requires a model selector")
          (condition-case err
              (progn
                (nl-agent-service-switch service selector)
                (list :status 'ok :kind 'switched
                      :from from
                      :model (nl-agent-service-current-model service)))
            (error (nl-agent-service--error 'switch err))))))
     ((and (not literal) (equal command "/quit"))
      (condition-case err
          (progn
            (nl-agent-service-close service)
            (list :status 'ok :kind 'closed))
        (error (nl-agent-service--error 'close err))))
     ((and (not literal) (string-prefix-p "/" command))
      (list :status 'error :kind 'command
            :error (format "unknown command: %s" command)))
     (t
      (condition-case err
          (let ((text (nl-agent-service-send service input)))
            (list :status 'ok :kind 'completion
                  :model (nl-agent-service-current-model service)
                  :text text))
        (error
         (setf (nl-agent-service-last-error service) (format "%S" err))
         (nl-agent-service--record
          service
          (list :status 'failed :kind 'completion
                :model (condition-case nil
                           (nl-agent-service-current-model service)
                         (error nil))
                :error (format "%S" err)))
         (nl-agent-service--error 'completion err)))))))

(provide 'nl-agent-service)
;;; nl-agent-service.el ends here
