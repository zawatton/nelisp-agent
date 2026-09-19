;;; nl-agent-jsonl-approval.el --- local JSONL approval handshake -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'nl-agent-jsonl)

(define-error 'nl-agent-jsonl-approval-io-error
  "JSONL approval transport failed")

(cl-defstruct (nl-agent-jsonl-approval-state
               (:constructor nl-agent-jsonl-approval--make))
  read write active-id counter failed)

(defun nl-agent-jsonl-approval--plist (value allowed required where)
  "Validate exact plist VALUE for WHERE and return it."
  (unless (and (listp value) (zerop (% (length value) 2)))
    (error "%s must be a plist" where))
  (let ((tail value) seen)
    (while tail
      (let ((key (pop tail)))
        (unless (keywordp key)
          (error "%s contains a non-keyword" where))
        (when (memq key seen)
          (error "%s contains duplicate key %S" where key))
        (unless (memq key allowed)
          (error "%s contains unknown key %S" where key))
        (push key seen))
      (pop tail))
    (dolist (key required)
      (unless (memq key seen)
        (error "%s is missing required key %S" where key)))
    value))

(defun nl-agent-jsonl-approval--id (value where)
  "Validate and detach one non-empty approval identifier."
  (nl-agent-jsonl--string value where 128))

(defun nl-agent-jsonl-approval--lisp-view (value active)
  "Copy data-only VALUE for the diagnostic Lisp rendering.
Strings lose text properties; symbols and string values remain distinguishable.
The shared JSON serializer has already enforced the depth/node bounds."
  (cond
   ((null value) nil)
   ((stringp value) (substring-no-properties value))
   ((or (symbolp value) (numberp value) (characterp value)) value)
   ((vectorp value)
    (when (gethash value active)
      (error "approval args contain a cycle"))
    (puthash value t active)
    (unwind-protect
        (let ((result (make-vector (length value) nil)) (index 0))
          (while (< index (length value))
            (aset result index
                  (nl-agent-jsonl-approval--lisp-view
                   (aref value index) active))
            (setq index (1+ index)))
          result)
      (remhash value active)))
   ((consp value)
    (when (gethash value active)
      (error "approval args contain a cycle"))
    (puthash value t active)
    (unwind-protect
        (cons (nl-agent-jsonl-approval--lisp-view (car value) active)
              (nl-agent-jsonl-approval--lisp-view (cdr value) active))
      (remhash value active)))
   (t (error "approval args contain an opaque value"))))

(defun nl-agent-jsonl-approval--request (request)
  "Validate REQUEST and return its detached public event projection."
  (nl-agent-jsonl-approval--plist
   request '(:tool :risk :description :args :context)
   '(:tool :risk :description :args :context) "approval request")
  (let ((args (plist-get request :args)))
    ;; Validate the data-only JSON view before producing the diagnostic Lisp
    ;; view.  Neither view is executable or accepted back as a request.
    (nl-agent-jsonl--serialize args)
    (let ((args-lisp
           (let ((print-length nil) (print-level nil) (print-circle nil)
                 (print-escape-nonascii t) (float-output-format nil))
             (prin1-to-string
              (nl-agent-jsonl-approval--lisp-view
               args (make-hash-table :test 'eq))))))
      (when (> (string-bytes args-lisp) nl-agent-jsonl-max-output-bytes)
        (error "approval args Lisp view exceeds the UTF-8 size limit"))
      (list :tool (nl-agent-jsonl--string
                   (plist-get request :tool) "approval tool" 128)
            :risk (let ((risk (plist-get request :risk)))
                    (unless (memq risk
                                  '(safe read write execute external destructive))
                      (error "approval risk is invalid"))
                    (symbol-name risk))
            :description (nl-agent-jsonl--string
                          (plist-get request :description)
                          "approval description"
                          nl-agent-jsonl-max-text-chars t)
            :args args
            :argsLisp args-lisp))))

;;;###autoload
(defun nl-agent-jsonl-approval-new (read-fn write-fn)
  "Create a local JSONL approval STATE using READ-FN and WRITE-FN.
READ-FN is called with an empty prompt and returns one line or nil.  WRITE-FN
receives one encoded JSON line without a trailing newline."
  (unless (and (functionp read-fn) (functionp write-fn))
    (error "approval read and write functions must be callable"))
  (nl-agent-jsonl-approval--make
   :read read-fn :write write-fn :active-id nil :counter 0 :failed nil))

(defun nl-agent-jsonl-approval--response (state line token)
  "Parse one approval LINE for active TOKEN, or return deny."
  (if (or (not (stringp line))
          (> (string-bytes line) nl-agent-jsonl-max-line-bytes)
          (string-match-p "[\r\n]" line))
      'deny
    (condition-case nil
        (let* ((object
              (json-parse-string
               line :object-type 'alist :array-type 'array
               :null-object :json-null :false-object :json-false))
             (_checked
              (nl-agent-jsonl--object
               object '(id method params) '(id method params)
               "approval response"))
             (id (nl-agent-jsonl-approval--id
                  (alist-get 'id object) "approval response id"))
             (method (nl-agent-jsonl--string
                      (alist-get 'method object) "approval response method" 32))
             (params (alist-get 'params object)))
        (nl-agent-jsonl--object
         params '(approvalId decision) '(approvalId decision)
         "approval response params")
        (let ((approval-id
               (nl-agent-jsonl-approval--id
                (alist-get 'approvalId params) "approval response approvalId"))
              (decision (alist-get 'decision params)))
          (if (and (equal id (nl-agent-jsonl-approval-state-active-id state))
                   (equal method "approve")
                   (equal approval-id token)
                   (member decision '("once" "session" "deny")))
              (intern decision)
            'deny)))
      (error 'deny))))

;;;###autoload
(defun nl-agent-jsonl-approval-callback (state request)
  "Challenge the host for REQUEST during an active approval call.
Return `once', `session', or `deny'.  Invalid replies consume exactly one
line and deny.  I/O and encoding failures permanently fail STATE."
  (unless (nl-agent-jsonl-approval-state-p state)
    (error "invalid JSONL approval state"))
  (if (or (nl-agent-jsonl-approval-state-failed state)
          (null (nl-agent-jsonl-approval-state-active-id state)))
      'deny
    (condition-case nil
        (let* ((public-request
                (nl-agent-jsonl-approval--request request))
               (counter (1+ (nl-agent-jsonl-approval-state-counter state)))
               (token (format "approval-%d" counter))
               (event
                (nl-agent-jsonl--serialize
                 (list :id (nl-agent-jsonl-approval-state-active-id state)
                       :event "approval"
                       :approvalId token
                       :request public-request))))
          (setf (nl-agent-jsonl-approval-state-counter state) counter)
          (funcall (nl-agent-jsonl-approval-state-write state) event)
          (let ((line (funcall (nl-agent-jsonl-approval-state-read state) "")))
            (if (null line)
                (progn
                  (setf (nl-agent-jsonl-approval-state-failed state) t)
                  'deny)
              (nl-agent-jsonl-approval--response state line token))))
      (error
       (setf (nl-agent-jsonl-approval-state-failed state) t)
       'deny))))

;;;###autoload
(defun nl-agent-jsonl-approval-call (state id thunk)
  "Call THUNK once with active approval ID ID and unwind STATE safely.
If approval transport fails during THUNK, signal the dedicated
`nl-agent-jsonl-approval-io-error' even when THUNK catches the callback's deny."
  (unless (nl-agent-jsonl-approval-state-p state)
    (error "invalid JSONL approval state"))
  (when (nl-agent-jsonl-approval-state-failed state)
    (signal 'nl-agent-jsonl-approval-io-error
            '("approval state has permanently failed")))
  (when (nl-agent-jsonl-approval-state-active-id state)
    (error "JSONL approval call is already active"))
  (setf (nl-agent-jsonl-approval-state-active-id state)
        (nl-agent-jsonl-approval--id id "approval active id"))
  (unwind-protect
      (condition-case err
          (let ((value (funcall thunk)))
            (when (nl-agent-jsonl-approval-state-failed state)
              (signal 'nl-agent-jsonl-approval-io-error
                      '("approval transport failed during call")))
            value)
        (error
         (if (nl-agent-jsonl-approval-state-failed state)
             (signal 'nl-agent-jsonl-approval-io-error
                     '("approval transport failed during call"))
           (signal (car err) (cdr err)))))
    (setf (nl-agent-jsonl-approval-state-active-id state) nil)))

(provide 'nl-agent-jsonl-approval)
;;; nl-agent-jsonl-approval.el ends here
