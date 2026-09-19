;;; nl-agent-supervisor.el --- host supervisor for NeLisp Agent workers  -*- lexical-binding: t; -*-

;; This Emacs-hosted reference supervisor proves the production boundary: the
;; host owns processes, remote inference, and restart policy; standalone NeLisp
;; owns model selection, fallback, and provider-neutral conversation state.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'nl-agent-startup)
(require 'nl-agent-wire)

(defvar read-eval)

(cl-defstruct (nl-agent-supervisor
               (:constructor nl-agent-supervisor--make))
  command
  directory
  inference-fn
  model-catalog-fn
  tool-fn
  tool-catalog-fn
  startup-config
  shutdown-fn
  shutdown-called
  await-ready
  max-requests
  checkpoint-every
  checkpoint-file
  timeout-sec
  process
  stderr-buffer
  pending
  lines
  request-count
  restart-count
  checkpoint
  checkpoint-request-count
  last-error)

(defun nl-agent-supervisor--keys (keys allowed)
  "Validate constructor KEYS against ALLOWED."
  (unless (= (% (length keys) 2) 0)
    (error "nl-agent-supervisor-new: options must be KEY VALUE pairs"))
  (let ((tail keys))
    (while tail
      (unless (memq (car tail) allowed)
        (error "nl-agent-supervisor-new: unknown option %S" (car tail)))
      (setq tail (cddr tail))))
  keys)

(defun nl-agent-supervisor--read-checkpoint-file (path)
  "Read exactly one non-evaluated checkpoint form from PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (let* ((text (buffer-string))
           (read-eval nil)
           (parsed (read-from-string text))
           (checkpoint (car parsed))
           (trailing (string-trim (substring text (cdr parsed)))))
      (unless (string-empty-p trailing)
        (error "checkpoint file contains trailing data: %s" path))
      (unless (and (listp checkpoint)
                   (eq (plist-get checkpoint :format)
                       'nl-agent-service-v1))
        (error "checkpoint file has unsupported data: %s" path))
      checkpoint)))

;;;###autoload
(defun nl-agent-supervisor-new (command &rest keys)
  "Create a worker supervisor for process COMMAND.

KEYS are :DIRECTORY, :INFERENCE, :MODEL-CATALOG, :TOOL, :TOOL-CATALOG,
:STARTUP-CONFIG, :SHUTDOWN, :AWAIT-READY, :MAX-REQUESTS, :CHECKPOINT-EVERY,
:CHECKPOINT-FILE, and :TIMEOUT-SEC.
INFERENCE receives broker event plists and returns assistant text.  TOOL
receives tool event plists and returns observation text after host permission
checks.  MODEL-CATALOG and TOOL-CATALOG return public descriptors for worker
discovery.  SHUTDOWN releases host resources once at final stop.  MAX-REQUESTS
defaults to 250; reaching it checkpoints, restarts, and restores the worker."
  (nl-agent-supervisor--keys
   keys '(:directory :inference :model-catalog :tool :tool-catalog :shutdown
          :await-ready :max-requests :checkpoint-every :checkpoint-file
          :timeout-sec :startup-config))
  (unless (and (consp command)
               (cl-every #'stringp command))
    (error "nl-agent-supervisor-new: COMMAND must be a non-empty string list"))
  (let ((directory (or (plist-get keys :directory) default-directory))
        (inference (plist-get keys :inference))
        (model-catalog (plist-get keys :model-catalog))
        (tool (plist-get keys :tool))
        (tool-catalog (plist-get keys :tool-catalog))
        (startup-config
         (nl-agent-startup-validate-config
          (plist-get keys :startup-config)))
        (shutdown (plist-get keys :shutdown))
        (await-ready (and (plist-get keys :await-ready) t))
        (max-requests
         (if (plist-member keys :max-requests)
             (plist-get keys :max-requests)
           250))
        (checkpoint-every
         (if (plist-member keys :checkpoint-every)
             (plist-get keys :checkpoint-every)
           1))
        (checkpoint-file (plist-get keys :checkpoint-file))
        (timeout (or (plist-get keys :timeout-sec) 30)))
    (unless (and (stringp directory) (file-directory-p directory))
      (error "nl-agent-supervisor-new: :directory must exist"))
    (when (and inference (not (functionp inference)))
      (error "nl-agent-supervisor-new: :inference must be a function"))
    (when (and model-catalog (not (functionp model-catalog)))
      (error "nl-agent-supervisor-new: :model-catalog must be a function"))
    (when (and tool (not (functionp tool)))
      (error "nl-agent-supervisor-new: :tool must be a function"))
    (when (and tool-catalog (not (functionp tool-catalog)))
      (error "nl-agent-supervisor-new: :tool-catalog must be a function"))
    (when (and shutdown (not (functionp shutdown)))
      (error "nl-agent-supervisor-new: :shutdown must be a function"))
    (unless (or (null max-requests)
                (and (integerp max-requests) (> max-requests 0)))
      (error "nl-agent-supervisor-new: :max-requests must be nil or positive"))
    (unless (or (null checkpoint-every)
                (and (integerp checkpoint-every) (> checkpoint-every 0)))
      (error
       "nl-agent-supervisor-new: :checkpoint-every must be nil or positive"))
    (when (and checkpoint-file
               (not (and (stringp checkpoint-file)
                         (not (string-empty-p checkpoint-file)))))
      (error
       "nl-agent-supervisor-new: :checkpoint-file must be nil or a path"))
    (unless (and (numberp timeout) (> timeout 0))
      (error "nl-agent-supervisor-new: :timeout-sec must be positive"))
    (let* ((directory
            (file-name-as-directory (expand-file-name directory)))
           (checkpoint-file
            (and checkpoint-file
                 (expand-file-name checkpoint-file directory)))
           (checkpoint
            (and checkpoint-file
                 (file-exists-p checkpoint-file)
                 (nl-agent-supervisor--read-checkpoint-file
                  checkpoint-file))))
      (nl-agent-supervisor--make
       :command (copy-sequence command)
       :directory directory
       :inference-fn inference
       :model-catalog-fn model-catalog
       :tool-fn tool
       :tool-catalog-fn tool-catalog
       :startup-config startup-config
       :shutdown-fn shutdown
       :shutdown-called nil
       :await-ready await-ready
       :max-requests max-requests
       :checkpoint-every checkpoint-every
       :checkpoint-file checkpoint-file
       :timeout-sec timeout
       :process nil
       :stderr-buffer nil
       :pending ""
       :lines nil
       :request-count 0
       :restart-count 0
       :checkpoint checkpoint
       :checkpoint-request-count (and checkpoint 0)
       :last-error nil))))

;;;###autoload
(defun nl-agent-supervisor-live-p (supervisor)
  "Return non-nil when SUPERVISOR owns a live worker process."
  (and (nl-agent-supervisor-p supervisor)
       (process-live-p (nl-agent-supervisor-process supervisor))))

(defun nl-agent-supervisor--filter (supervisor chunk)
  "Append process output CHUNK to SUPERVISOR's framed line queue."
  (let ((pending (concat (nl-agent-supervisor-pending supervisor) chunk))
        (lines (nl-agent-supervisor-lines supervisor))
        (index nil))
    (setq index (string-search "\n" pending))
    (while index
      (let ((line (substring pending 0 index)))
        (when (string-suffix-p "\r" line)
          (setq line (substring line 0 (1- (length line)))))
        (setq lines (append lines (list line))))
      (setq pending (substring pending (1+ index)))
      (setq index (string-search "\n" pending)))
    (setf (nl-agent-supervisor-pending supervisor) pending)
    (setf (nl-agent-supervisor-lines supervisor) lines)))

(defun nl-agent-supervisor--stderr (supervisor)
  "Return a bounded worker stderr string for SUPERVISOR."
  (let ((buffer (nl-agent-supervisor-stderr-buffer supervisor)))
    (if (and buffer (buffer-live-p buffer))
        (with-current-buffer buffer
          (let ((text (buffer-string)))
            (substring text (max 0 (- (length text) 2000)))))
      "")))

;;;###autoload
(defun nl-agent-supervisor-start (supervisor)
  "Start SUPERVISOR's worker unless it is already live."
  (unless (nl-agent-supervisor-p supervisor)
    (error "nl-agent-supervisor-start: invalid supervisor"))
  (unless (nl-agent-supervisor-live-p supervisor)
    (when (nl-agent-supervisor-process supervisor)
      (nl-agent-supervisor--dispose-process supervisor))
    (setf (nl-agent-supervisor-pending supervisor) "")
    (setf (nl-agent-supervisor-lines supervisor) nil)
    (let* ((default-directory (nl-agent-supervisor-directory supervisor))
           (stderr-buffer (generate-new-buffer " *nl-agent-worker-stderr*"))
           (process
            (make-process
             :name (generate-new-buffer-name "nl-agent-worker")
             :command (nl-agent-supervisor-command supervisor)
             :connection-type 'pipe
             :coding 'utf-8-unix
             :noquery t
             :stderr stderr-buffer
             :filter
             (lambda (_process chunk)
               (nl-agent-supervisor--filter supervisor chunk)))))
      (set-process-query-on-exit-flag process nil)
      (setf (nl-agent-supervisor-process supervisor) process)
      (setf (nl-agent-supervisor-stderr-buffer supervisor) stderr-buffer)
      (setf (nl-agent-supervisor-last-error supervisor) nil)
      (when (nl-agent-supervisor-await-ready supervisor)
        (nl-agent-supervisor--await-ready supervisor))
      (when (nl-agent-supervisor-checkpoint supervisor)
        (condition-case err
            (let ((response
                   (nl-agent-supervisor--call-raw
                    supervisor
                    (list 'restore
                          (nl-agent-supervisor-checkpoint supervisor)))))
              (unless (eq (plist-get response :status) 'ok)
                (error "worker restore failed: %S" response)))
          (error
           (setf (nl-agent-supervisor-last-error supervisor)
                 (format "%S" err))
           (nl-agent-supervisor--dispose-process supervisor)
           (signal (car err) (cdr err)))))))
  supervisor)

(defun nl-agent-supervisor--send (supervisor form)
  "Send one data FORM to SUPERVISOR's live worker."
  (unless (nl-agent-supervisor-live-p supervisor)
    (error "NeLisp Agent worker is not live: %s"
           (nl-agent-supervisor--stderr supervisor)))
  (process-send-string
   (nl-agent-supervisor-process supervisor)
   (concat
    ;; Emacs and standalone NeLisp both print literal newlines inside strings.
    ;; Escape them after serialization to preserve one-form-per-line framing.
    (nl-agent-wire-frame form)
    "\n")))

(defun nl-agent-supervisor--next-line (supervisor)
  "Wait for and return SUPERVISOR's next response line."
  (let ((deadline
         (+ (float-time) (nl-agent-supervisor-timeout-sec supervisor))))
    (while (and (null (nl-agent-supervisor-lines supervisor))
                (< (float-time) deadline)
                (nl-agent-supervisor-live-p supervisor))
      (accept-process-output
       (nl-agent-supervisor-process supervisor) 0.05))
    ;; Drain output delivered with the process sentinel/exit transition.
    (when (and (null (nl-agent-supervisor-lines supervisor))
               (nl-agent-supervisor-process supervisor))
      (accept-process-output
       (nl-agent-supervisor-process supervisor) 0.05))
    (let ((lines (nl-agent-supervisor-lines supervisor)))
      (unless lines
        (error "worker response timeout or exit: %s"
               (nl-agent-supervisor--stderr supervisor)))
      (setf (nl-agent-supervisor-lines supervisor) (cdr lines))
      (car lines))))

(defun nl-agent-supervisor--parse-line (line)
  "Parse exactly one non-evaluated form from worker LINE."
  (let* ((read-eval nil)
         (parsed (read-from-string line))
         (form (car parsed))
         (trailing (string-trim (substring line (cdr parsed)))))
    (unless (string-empty-p trailing)
      (error "worker emitted multiple forms on one line: %S" line))
    form))

(defun nl-agent-supervisor--inference-event-p (form)
  "Return non-nil when FORM is a broker inference event."
  (and (consp form)
       (keywordp (car form))
       (eq (plist-get form :event) 'inference)))

(defun nl-agent-supervisor--handle-inference (supervisor event)
  "Answer one broker EVENT for SUPERVISOR's worker."
  (let ((request-id (plist-get event :request-id))
        (inference (nl-agent-supervisor-inference-fn supervisor)))
    (unless (integerp request-id)
      (error "worker emitted inference event without integer request id"))
    (condition-case err
        (let ((result
               (if inference
                   (funcall inference event)
                 (error "no host inference function configured"))))
          (unless (stringp result)
            (error "host inference returned non-text result: %S" result))
          (nl-agent-supervisor--send
           supervisor (list 'inference-result request-id result)))
      (error
       (nl-agent-supervisor--send
        supervisor
        (list 'inference-error request-id (format "%S" err)))))))

(defun nl-agent-supervisor--tool-event-p (form)
  "Return non-nil when FORM is a broker tool event."
  (and (consp form)
       (keywordp (car form))
       (eq (plist-get form :event) 'tool)))

(defun nl-agent-supervisor--handle-tool (supervisor event)
  "Authorize and answer one tool EVENT for SUPERVISOR's worker."
  (let ((request-id (plist-get event :request-id))
        (tool (nl-agent-supervisor-tool-fn supervisor)))
    (unless (integerp request-id)
      (error "worker emitted tool event without integer request id"))
    (condition-case err
        (let ((result
               (if tool
                   (funcall tool event)
                 (error "no host tool function configured"))))
          (unless (stringp result)
            (error "host tool returned non-text result: %S" result))
          (nl-agent-supervisor--send
           supervisor (list 'tool-result request-id result)))
      (error
       (nl-agent-supervisor--send
        supervisor
        (list 'tool-error request-id (format "%S" err)))))))

(defun nl-agent-supervisor--model-catalog-event-p (form)
  "Return non-nil when FORM is a host model-catalog event."
  (and (consp form)
       (keywordp (car form))
       (eq (plist-get form :event) 'model-catalog)))

(defun nl-agent-supervisor--handle-model-catalog (supervisor event)
  "Answer one model-catalog EVENT for SUPERVISOR's worker."
  (let ((request-id (plist-get event :request-id))
        (catalog (nl-agent-supervisor-model-catalog-fn supervisor)))
    (unless (integerp request-id)
      (error "worker emitted model catalog event without integer request id"))
    (condition-case err
        (let ((result
               (if catalog
                   (funcall catalog)
                 (error "no host model catalog function configured"))))
          (unless (listp result)
            (error "host model catalog returned non-list data: %S" result))
          (nl-agent-supervisor--send
           supervisor
           (list 'model-catalog-result request-id (copy-tree result))))
      (error
       (nl-agent-supervisor--send
        supervisor
        (list 'model-catalog-error request-id (format "%S" err)))))))

(defun nl-agent-supervisor--tool-catalog-event-p (form)
  "Return non-nil when FORM is a host tool-catalog event."
  (and (consp form)
       (keywordp (car form))
       (eq (plist-get form :event) 'tool-catalog)))

(defun nl-agent-supervisor--startup-config-event-p (form)
  "Return non-nil when FORM is a startup-config request event."
  (and (consp form)
       (keywordp (car form))
       (eq (plist-get form :event) 'startup-config)))

(defun nl-agent-supervisor--handle-startup-config (supervisor event)
  "Answer one startup-config EVENT for SUPERVISOR's worker."
  (let ((request-id (plist-get event :request-id)))
    (unless (integerp request-id)
      (error "worker emitted startup config event without integer request id"))
    (condition-case err
        (nl-agent-supervisor--send
         supervisor
         (list 'startup-config-result request-id
               (nl-agent-startup-validate-config
                (nl-agent-supervisor-startup-config supervisor))))
      (error
       (nl-agent-supervisor--send
        supervisor
        (list 'startup-config-error request-id (format "%S" err)))))))

(defun nl-agent-supervisor--handle-tool-catalog (supervisor event)
  "Answer one tool-catalog EVENT for SUPERVISOR's worker."
  (let ((request-id (plist-get event :request-id))
        (catalog (nl-agent-supervisor-tool-catalog-fn supervisor)))
    (unless (integerp request-id)
      (error "worker emitted tool catalog event without integer request id"))
    (condition-case err
        (let ((result
               (if catalog
                   (funcall catalog)
                 (error "no host tool catalog function configured"))))
          (unless (listp result)
            (error "host tool catalog returned non-list data: %S" result))
          (nl-agent-supervisor--send
           supervisor
           (list 'tool-catalog-result request-id (copy-tree result))))
      (error
       (nl-agent-supervisor--send
        supervisor
        (list 'tool-catalog-error request-id (format "%S" err)))))))

(defun nl-agent-supervisor--ready-event-p (form)
  "Return non-nil when FORM is a worker ready event."
  (and (consp form)
       (keywordp (car form))
       (eq (plist-get form :event) 'ready)))

(defun nl-agent-supervisor--await-ready (supervisor)
  "Service startup events until SUPERVISOR's worker reports ready."
  (catch 'nl-agent-worker-ready
    (while t
      (let ((form
             (nl-agent-supervisor--parse-line
              (nl-agent-supervisor--next-line supervisor))))
        (cond
         ((nl-agent-supervisor--model-catalog-event-p form)
          (nl-agent-supervisor--handle-model-catalog supervisor form))
         ((nl-agent-supervisor--tool-catalog-event-p form)
          (nl-agent-supervisor--handle-tool-catalog supervisor form))
         ((nl-agent-supervisor--startup-config-event-p form)
          (nl-agent-supervisor--handle-startup-config supervisor form))
         ((nl-agent-supervisor--inference-event-p form)
          (nl-agent-supervisor--handle-inference supervisor form))
         ((nl-agent-supervisor--tool-event-p form)
          (nl-agent-supervisor--handle-tool supervisor form))
         ((nl-agent-supervisor--ready-event-p form)
          (throw 'nl-agent-worker-ready t))
         (t (error "unexpected worker startup response: %S" form)))))))

(defun nl-agent-supervisor--call-raw (supervisor request)
  "Send REQUEST and service broker events until the final response arrives."
  (nl-agent-supervisor--send supervisor request)
  (catch 'nl-agent-response
    (while t
      (let ((form
             (nl-agent-supervisor--parse-line
              (nl-agent-supervisor--next-line supervisor))))
        (cond
         ((nl-agent-supervisor--inference-event-p form)
          (nl-agent-supervisor--handle-inference supervisor form))
         ((nl-agent-supervisor--model-catalog-event-p form)
          (nl-agent-supervisor--handle-model-catalog supervisor form))
         ((nl-agent-supervisor--tool-event-p form)
          (nl-agent-supervisor--handle-tool supervisor form))
         ((nl-agent-supervisor--tool-catalog-event-p form)
          (nl-agent-supervisor--handle-tool-catalog supervisor form))
         ((nl-agent-supervisor--startup-config-event-p form)
          (nl-agent-supervisor--handle-startup-config supervisor form))
         ((eq form 'nl-agent-service-eof)
          (error "worker ended before returning a service response"))
         (t (throw 'nl-agent-response form)))))))

(defun nl-agent-supervisor--countable-p (request)
  "Return non-nil when REQUEST counts toward worker rotation."
  (and (consp request)
       (not (memq (car request) '(checkpoint restore quit stats)))))

(defun nl-agent-supervisor--persist-checkpoint (supervisor checkpoint)
  "Atomically persist CHECKPOINT for SUPERVISOR when configured."
  (let ((path (nl-agent-supervisor-checkpoint-file supervisor)))
    (when path
      (let ((directory (file-name-directory path)))
        (unless (file-directory-p directory)
          (error "checkpoint directory does not exist: %s" directory))
        (let ((temporary
               (make-temp-file
                (expand-file-name ".nl-agent-checkpoint-" directory))))
          (unwind-protect
              (progn
                (with-temp-file temporary
                  (let ((print-length nil)
                        (print-level nil))
                    (prin1 checkpoint (current-buffer))
                    (terpri (current-buffer))))
                (set-file-modes temporary #o600)
                (rename-file temporary path t)
                (setq temporary nil))
            (when (and temporary (file-exists-p temporary))
              (delete-file temporary))))))))

(defun nl-agent-supervisor--capture-checkpoint (supervisor)
  "Capture SUPERVISOR's current portable worker state."
  (let* ((response
          (nl-agent-supervisor--call-raw supervisor '(checkpoint)))
         (checkpoint (plist-get response :checkpoint)))
    (unless (and (eq (plist-get response :status) 'ok) checkpoint)
      (error "worker checkpoint failed: %S" response))
    (setf (nl-agent-supervisor-checkpoint supervisor) checkpoint)
    (setf (nl-agent-supervisor-checkpoint-request-count supervisor)
          (nl-agent-supervisor-request-count supervisor))
    (nl-agent-supervisor--persist-checkpoint supervisor checkpoint)
    checkpoint))

(defun nl-agent-supervisor--dispose-process (supervisor)
  "Release SUPERVISOR's current process and diagnostic buffer."
  (let ((process (nl-agent-supervisor-process supervisor))
        (stderr-buffer (nl-agent-supervisor-stderr-buffer supervisor)))
    (when (process-live-p process)
      (delete-process process))
    (when (and stderr-buffer (buffer-live-p stderr-buffer))
      (kill-buffer stderr-buffer))
    (setf (nl-agent-supervisor-process supervisor) nil)
    (setf (nl-agent-supervisor-stderr-buffer supervisor) nil)
    (setf (nl-agent-supervisor-pending supervisor) "")
    (setf (nl-agent-supervisor-lines supervisor) nil)))

(defun nl-agent-supervisor--stop-worker (supervisor)
  "Ask SUPERVISOR's worker to exit, then release it."
  (when (nl-agent-supervisor-live-p supervisor)
    (condition-case nil
        (nl-agent-supervisor--call-raw supervisor '(quit))
      (error nil))
    (let ((deadline (+ (float-time) 1.0)))
      (while (and (nl-agent-supervisor-live-p supervisor)
                  (< (float-time) deadline))
        (accept-process-output
         (nl-agent-supervisor-process supervisor) 0.05))))
  (nl-agent-supervisor--dispose-process supervisor))

;;;###autoload
(defun nl-agent-supervisor-restart (supervisor)
  "Checkpoint, restart, and restore SUPERVISOR's worker transactionally."
  (unless (nl-agent-supervisor-live-p supervisor)
    (error "nl-agent-supervisor-restart: worker is not live"))
  (unless (and (nl-agent-supervisor-checkpoint supervisor)
               (equal
                (nl-agent-supervisor-checkpoint-request-count supervisor)
                (nl-agent-supervisor-request-count supervisor)))
    (nl-agent-supervisor--capture-checkpoint supervisor))
  (nl-agent-supervisor--stop-worker supervisor)
  (nl-agent-supervisor-start supervisor)
  (setf (nl-agent-supervisor-request-count supervisor) 0)
  (setf (nl-agent-supervisor-checkpoint-request-count supervisor) 0)
  (setf (nl-agent-supervisor-restart-count supervisor)
        (1+ (nl-agent-supervisor-restart-count supervisor)))
  supervisor)

;;;###autoload
(defun nl-agent-supervisor-call (supervisor request)
  "Send one external REQUEST through SUPERVISOR and return its final response."
  (let ((recovering
         (and (nl-agent-supervisor-process supervisor)
              (not (nl-agent-supervisor-live-p supervisor))
              (nl-agent-supervisor-checkpoint supervisor))))
    (unless (nl-agent-supervisor-live-p supervisor)
      (nl-agent-supervisor-start supervisor))
    (when recovering
      ;; The restored process has a fresh arena even though its logical state
      ;; comes from an older request count.
      (setf (nl-agent-supervisor-request-count supervisor) 0)
      (setf (nl-agent-supervisor-checkpoint-request-count supervisor) 0)
      (setf (nl-agent-supervisor-restart-count supervisor)
            (1+ (nl-agent-supervisor-restart-count supervisor)))))
  (condition-case err
      (let ((response (nl-agent-supervisor--call-raw supervisor request)))
        (when (nl-agent-supervisor--countable-p request)
          (setf (nl-agent-supervisor-request-count supervisor)
                (1+ (nl-agent-supervisor-request-count supervisor)))
          (let ((interval
                 (nl-agent-supervisor-checkpoint-every supervisor)))
            (when (and interval
                       (= (% (nl-agent-supervisor-request-count supervisor)
                             interval)
                          0))
              (nl-agent-supervisor--capture-checkpoint supervisor)))
          (let ((limit (nl-agent-supervisor-max-requests supervisor)))
            (when (and limit
                       (>= (nl-agent-supervisor-request-count supervisor)
                           limit))
              (nl-agent-supervisor-restart supervisor))))
        (setf (nl-agent-supervisor-last-error supervisor) nil)
        response)
    (error
     (setf (nl-agent-supervisor-last-error supervisor) (format "%S" err))
     (signal (car err) (cdr err)))))

;;;###autoload
(defun nl-agent-supervisor-stop (supervisor)
  "Gracefully stop SUPERVISOR's worker and return SUPERVISOR."
  (unless (nl-agent-supervisor-p supervisor)
    (error "nl-agent-supervisor-stop: invalid supervisor"))
  (nl-agent-supervisor--stop-worker supervisor)
  (unless (nl-agent-supervisor-shutdown-called supervisor)
    ;; Mark ownership released before calling user code so a failing shutdown
    ;; callback cannot be invoked twice by a later cleanup path.
    (setf (nl-agent-supervisor-shutdown-called supervisor) t)
    (let ((shutdown (nl-agent-supervisor-shutdown-fn supervisor)))
      (when shutdown (funcall shutdown))))
  supervisor)

(provide 'nl-agent-supervisor)
;;; nl-agent-supervisor.el ends here
