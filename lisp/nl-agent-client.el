;;; nl-agent-client.el --- bounded asynchronous JSONL client -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; This is deliberately only a transport client.  It does not know about the
;; supervisor, a UI, or a permission policy; callers decide what to do with
;; validated packets and approval challenges.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defconst nl-agent-client-max-frame-bytes (* 1024 1024))
(defconst nl-agent-client-max-text-chars 65536)
(defconst nl-agent-client-max-selector-chars 256)
(defconst nl-agent-client-max-depth 64)
(defconst nl-agent-client-max-nodes 100000)

(defconst nl-agent-client--methods
  '("models" "status" "chat" "run" "switch" "checkpoint" "quit"))

(cl-defstruct (nl-agent-client
               (:constructor nl-agent-client--make))
  process pending approval closed stderr-buffer on-event on-close
  next-id inflight used-approval-tokens close-notified input-buffer)

(defun nl-agent-client--string (value where maximum &optional empty)
  "Validate and detach text VALUE for WHERE." 
  (unless (and (stringp value)
               (or empty (> (length value) 0))
               (<= (length value) maximum))
    (error "%s must be %s text of at most %d characters"
           where (if empty "" "non-empty") maximum))
  (substring-no-properties value))

(defun nl-agent-client--object (value allowed required where)
  "Validate exact JSON object VALUE for WHERE." 
  (unless (listp value)
    (error "%s must be an object" where))
  (let ((tail value) seen)
    (while tail
      (unless (consp (car tail))
        (error "%s has an invalid member" where))
      (let ((key (car (car tail))))
        (unless (symbolp key)
          (error "%s has a non-symbol key" where))
        (when (memq key seen)
          (error "%s has duplicate key %S" where key))
        (when (and allowed (not (memq key allowed)))
          (error "%s has unknown key %S" where key))
        (push key seen))
      (setq tail (cdr tail)))
    (dolist (key required)
      (unless (memq key seen)
        (error "%s is missing key %S" where key)))
    value))

(defun nl-agent-client--json-plist (value allowed required where)
  "Validate keyword plist VALUE and return a detached JSON alist." 
  (unless (and (listp value) (zerop (% (length value) 2)))
    (error "%s must be a keyword plist" where))
  (let ((tail value) seen result)
    (while tail
      (let ((key (pop tail)) (item (pop tail)))
        (unless (keywordp key)
          (error "%s has a non-keyword" where))
        (when (memq key seen)
          (error "%s has duplicate key %S" where key))
        (unless (memq key allowed)
          (error "%s has unknown key %S" where key))
        (push key seen)
        (push (cons (intern (substring (symbol-name key) 1)) item) result)))
    (dolist (key required)
      (unless (memq key seen)
        (error "%s is missing key %S" where key)))
    (nreverse result)))

(defun nl-agent-client--params (method params)
  "Validate request PARAMS for METHOD and return an alist or nil." 
  (let ((method (if (symbolp method) (symbol-name method) method)))
    (unless (member method nl-agent-client--methods)
      (error "unknown client method %S" method))
    (pcase method
      ((or "models" "status" "checkpoint" "quit")
       (when params
         (nl-agent-client--json-plist params nil nil
                                      (format "%s params" method)))
       nil)
      ((or "chat" "run")
       (let ((result
              (nl-agent-client--json-plist
               params '(:text) '(:text) (format "%s params" method))))
         (setcdr (assq 'text result)
                 (nl-agent-client--string
                  (alist-get 'text result) "text"
                  nl-agent-client-max-text-chars))
         result))
      ("switch"
       (let ((result
              (nl-agent-client--json-plist
               params '(:selector) '(:selector) "switch params")))
         (let ((selector (alist-get 'selector result)))
           (unless (and (stringp selector)
                        (string-match-p "\\`[^/]+/.+\\'" selector))
             (error "switch selector must be provider-qualified text"))
           (setcdr (assq 'selector result)
                   (nl-agent-client--string
                    selector "switch selector"
                    nl-agent-client-max-selector-chars)))
         result)))))

(defun nl-agent-client--send-json (client object)
  "Send JSON OBJECT through CLIENT, or fail closed." 
  (let ((line (json-serialize object :null-object :json-null
                              :false-object :json-false)))
    (when (> (string-bytes line) nl-agent-client-max-frame-bytes)
      (error "client frame exceeds the UTF-8 size limit"))
    (when (string-match-p "[\r\n]" line)
      (error "client frame contains a raw newline"))
    (process-send-string
     (nl-agent-client-process client) (concat line "\n"))))

(defun nl-agent-client--reason (reason)
  "Detach a bounded close REASON." 
  (if (stringp reason)
      (substring-no-properties reason)
    reason))

(defun nl-agent-client--close-internal (client reason)
  "Close CLIENT once, clearing all request and approval state." 
  (unless (nl-agent-client-closed client)
    (setf (nl-agent-client-closed client) t
          (nl-agent-client-pending client) nil
          (nl-agent-client-inflight client) nil
          (nl-agent-client-approval client) nil
          (nl-agent-client-used-approval-tokens client) nil
          (nl-agent-client-input-buffer client) "")
    (let ((process (nl-agent-client-process client)))
      (setf (nl-agent-client-process client) nil)
      (when (process-live-p process)
        (set-process-query-on-exit-flag process nil)
        (delete-process process)))
    (unless (nl-agent-client-close-notified client)
      (setf (nl-agent-client-close-notified client) t)
      (let ((callback (nl-agent-client-on-close client)))
        (when callback
          (condition-case nil
              (funcall callback client (nl-agent-client--reason reason))
            (error nil))))))
  client)

(defun nl-agent-client--fail (client reason)
  "Fail closed CLIENT and return nil." 
  (nl-agent-client--close-internal client reason)
  nil)

(defun nl-agent-client--valid-json-data-p (value depth state)
  "Validate bounded parsed JSON VALUE for an approval event." 
  (when (> depth nl-agent-client-max-depth)
    (error "approval packet exceeds maximum depth"))
  (setcar state (1+ (car state)))
  (when (> (car state) nl-agent-client-max-nodes)
    (error "approval packet exceeds maximum node count"))
  (cond
   ((or (null value) (eq value :json-null) (eq value :json-false)
        (eq value t) (numberp value)) t)
   ((stringp value)
    (<= (string-bytes value) nl-agent-client-max-frame-bytes))
   ((vectorp value)
    (let ((index 0))
      (while (< index (length value))
        (unless (nl-agent-client--valid-json-data-p
                (aref value index) (1+ depth) state)
          (error "invalid approval packet data"))
        (setq index (1+ index)))
      t))
   ((listp value)
    (let (seen)
      (dolist (member value t)
        (unless (and (consp member)
                     (symbolp (car member))
                     (not (memq (car member) seen))
                     (progn (push (car member) seen) t)
                     (nl-agent-client--valid-json-data-p
                      (cdr member) (1+ depth) state))
          (error "invalid approval packet object")))))
   (t (error "invalid approval packet value"))))

(defun nl-agent-client--approval-request (value)
  "Validate and detach an approval REQUEST object." 
  (nl-agent-client--object
   value '(tool risk description args argsLisp)
   '(tool risk description args argsLisp) "approval request")
  (let ((args (alist-get 'args value)))
    (unless (nl-agent-client--valid-json-data-p args 0 (list 0))
      (error "invalid approval packet args"))
    (list (cons 'tool (nl-agent-client--string
                       (alist-get 'tool value) "approval tool" 128))
          (cons 'risk (nl-agent-client--string
                       (alist-get 'risk value) "approval risk" 32))
          (cons 'description
                (nl-agent-client--string
                 (alist-get 'description value) "approval description"
                 nl-agent-client-max-text-chars t))
          (cons 'args args)
          (cons 'argsLisp
                (nl-agent-client--string
                 (alist-get 'argsLisp value) "approval argsLisp"
                 nl-agent-client-max-text-chars t)))))

(defun nl-agent-client--packet (client line)
  "Validate one incoming JSON LINE and return its packet kind/value." 
  (let* ((object (json-parse-string
                  line :object-type 'alist :array-type 'array
                  :null-object :json-null :false-object :json-false))
         (keys (mapcar #'car object))
         (pending (nl-agent-client-inflight client)))
    (unless (and (listp object) (cl-every #'symbolp keys)
                 (= (length keys) (length (delete-dups (copy-sequence keys)))))
      (error "incoming packet must be a duplicate-free object"))
    (unless pending
      (error "unsolicited packet"))
    (cond
     ((memq 'event keys)
      (nl-agent-client--object object
                                '(id event approvalId request)
                                '(id event approvalId request)
                                "approval event")
      (let ((id (nl-agent-client--string (alist-get 'id object)
                                         "approval event id" 128))
            (event (nl-agent-client--string (alist-get 'event object)
                                             "approval event name" 32))
            (token (nl-agent-client--string (alist-get 'approvalId object)
                                             "approval token" 128)))
        (nl-agent-client--approval-request (alist-get 'request object))
        (unless (and (equal id (plist-get pending :id))
                     (equal event "approval")
                     (equal (plist-get pending :method) "run")
                     (not (nl-agent-client-approval client))
                     (not (member token
                                  (nl-agent-client-used-approval-tokens client))))
          (error "invalid or reused approval event"))
        (setf (nl-agent-client-approval client)
              (list :id id :token token)
              (nl-agent-client-used-approval-tokens client)
              (cons token (nl-agent-client-used-approval-tokens client)))
        object))
     ((memq 'ok keys)
      (let ((ok (alist-get 'ok object)))
        (cond
         ((eq ok t)
          (nl-agent-client--object object '(id ok result)
                                    '(id ok result) "success packet")
          (let ((id (alist-get 'id object)))
            (unless (equal id (plist-get pending :id))
              (error "success packet has a wrong request id"))
            (unless (listp (alist-get 'result object))
              (error "success packet result must be an object")))
          (unless (nl-agent-client--valid-json-data-p
                   (alist-get 'result object) 0 (list 0))
            (error "invalid success packet result")))
         ((eq ok :json-false)
          (nl-agent-client--object object '(id ok error)
                                    '(id ok error) "error packet")
          (let ((id (alist-get 'id object))
                (error-object (alist-get 'error object)))
            (when (eq id :json-null)
              (error "fatal null-id error packet"))
            (unless (equal id (plist-get pending :id))
              (error "error packet has a wrong request id"))
            (nl-agent-client--object error-object '(code message)
                                      '(code message) "error details")
            (nl-agent-client--string (alist-get 'code error-object)
                                     "error code" 128)
            (nl-agent-client--string (alist-get 'message error-object)
                                     "error message" nl-agent-client-max-text-chars t)))
         (t (error "packet ok must be true or false"))))
      (setf (nl-agent-client-inflight client) nil
            (nl-agent-client-pending client) nil
            (nl-agent-client-approval client) nil)
      object)
     (t (error "unknown incoming packet")))))

(defun nl-agent-client--dispatch (client packet)
  "Dispatch validated PACKET to CLIENT's callback." 
  (let ((callback (nl-agent-client-on-event client)))
    (when callback (funcall callback client packet))))

(defun nl-agent-client--filter (process chunk)
  "Consume fragmented or coalesced JSONL CHUNK from PROCESS." 
  (let ((client (process-get process 'nl-agent-client)))
    (when (and client (not (nl-agent-client-closed client)))
      (condition-case err
          (let ((pending (concat (nl-agent-client-input-buffer client) chunk)))
            (while (and (not (nl-agent-client-closed client))
                        (string-search "\n" pending))
              (let* ((index (string-search "\n" pending))
                     (line (substring pending 0 index)))
                (setq pending (substring pending (1+ index)))
                (when (and (> (length line) 0)
                           (= (aref line (1- (length line))) ?\r))
                  (setq line (substring line 0 -1)))
                (when (> (string-bytes line) nl-agent-client-max-frame-bytes)
                  (error "incoming frame exceeds the UTF-8 size limit"))
                (nl-agent-client--dispatch
                 client (nl-agent-client--packet client line))))
            (when (> (string-bytes pending) nl-agent-client-max-frame-bytes)
              (error "partial incoming frame exceeds the UTF-8 size limit"))
            (when (not (nl-agent-client-closed client))
              (setf (nl-agent-client-input-buffer client) pending)))
        (error
         (nl-agent-client--fail
          client (format "protocol error: %s" (error-message-string err))))))))

(defun nl-agent-client--sentinel (process _event)
  "Close the CLIENT owned by PROCESS when it exits." 
  (let ((client (process-get process 'nl-agent-client)))
    (when (and client (not (nl-agent-client-closed client))
               (not (process-live-p process))
               (memq (process-status process) '(exit signal failed closed)))
      (nl-agent-client--fail
       client (if (string-empty-p (nl-agent-client-input-buffer client))
                  "process exited"
                "process exited with a truncated JSONL frame")))))

;;;###autoload
(defun nl-agent-client-open (command directory on-event &optional on-close)
  "Start an asynchronous JSONL CLIENT for COMMAND in DIRECTORY.
ON-EVENT receives `(CLIENT PACKET)' for validated packets.  ON-CLOSE receives
`(CLIENT REASON)' once.  The process and stderr buffer are owned by CLIENT." 
  (unless (and (consp command) (cl-every #'stringp command))
    (error "client command must be a non-empty string list"))
  (unless (and (stringp directory) (file-directory-p directory))
    (error "client directory must exist"))
  (unless (functionp on-event)
    (error "client on-event callback must be callable"))
  (when (and on-close (not (functionp on-close)))
    (error "client on-close callback must be callable"))
  (let* ((stderr (generate-new-buffer " *nl-agent-client-stderr*"))
         (client (nl-agent-client--make
                  :process nil :pending nil :approval nil :closed nil
                  :stderr-buffer stderr :on-event on-event :on-close on-close
                  :next-id 0 :inflight nil :used-approval-tokens nil
                  :close-notified nil :input-buffer ""))
         (process
          (condition-case err
              (let ((default-directory
                     (file-name-as-directory (expand-file-name directory))))
                (make-process
                 :name (generate-new-buffer-name "nl-agent-client")
                 :command (copy-sequence command)
                 :connection-type 'pipe :coding 'utf-8-unix :noquery t
                 :stderr stderr
                 :filter #'nl-agent-client--filter
                 :sentinel #'nl-agent-client--sentinel))
            (error
             (kill-buffer stderr)
             (signal (car err) (cdr err))))))
    (set-process-query-on-exit-flag process nil)
    (set-process-coding-system process 'utf-8-unix 'utf-8-unix)
    (process-put process 'nl-agent-client client)
    (setf (nl-agent-client-process client) process)
    client))

;;;###autoload
(defun nl-agent-client-request (client method &optional params)
  "Send one ordinary METHOD request and return its request id.
Only one request may be in flight.  PARAMS is a keyword plist matching the
server JSONL method contract." 
  (unless (and (nl-agent-client-p client)
               (not (nl-agent-client-closed client))
               (process-live-p (nl-agent-client-process client)))
    (error "client is closed"))
  (when (nl-agent-client-inflight client)
    (error "client request is already in flight"))
  (let* ((method (if (symbolp method) (symbol-name method) method))
         (params-object (nl-agent-client--params method params))
         (next-id (1+ (nl-agent-client-next-id client)))
         (id (format "request-%d" next-id))
         (object (list (cons 'id id) (cons 'method method))))
    (when params-object
      (setq object (append object (list (cons 'params params-object)))))
    (condition-case err
        (progn
          (setf (nl-agent-client-next-id client) next-id
                (nl-agent-client-inflight client)
                (list :id id :method method)
                (nl-agent-client-pending client)
                (list :id id :method method)
                (nl-agent-client-used-approval-tokens client) nil)
          (nl-agent-client--send-json client object)
          id)
      (error
       (nl-agent-client--fail client (format "send failed: %s"
                                             (error-message-string err)))
       (signal (car err) (cdr err))))))

;;;###autoload
(defun nl-agent-client-approve (client id token decision)
  "Approve active ID/TOKEN with DECISION, sending exactly one reply." 
  (unless (and (nl-agent-client-p client)
               (not (nl-agent-client-closed client)))
    (error "client is closed"))
  (let ((pending (nl-agent-client-inflight client))
        (approval (nl-agent-client-approval client)))
    (unless (and pending approval
                 (equal id (plist-get pending :id))
                 (equal id (plist-get approval :id))
                 (equal token (plist-get approval :token))
                 (member decision '(once session deny)))
      (error "stale or invalid approval"))
    (setf (nl-agent-client-approval client) nil)
    (condition-case err
        (nl-agent-client--send-json
         client (list (cons 'id id) (cons 'method "approve")
                      (cons 'params
                            (list (cons 'approvalId token)
                                  (cons 'decision (symbol-name decision))))))
      (error
       (nl-agent-client--fail client (format "approval send failed: %s"
                                             (error-message-string err)))
       (signal (car err) (cdr err))))))

;;;###autoload
(defun nl-agent-client-close (client)
  "Close CLIENT and only its owned launcher process." 
  (unless (nl-agent-client-p client)
    (error "invalid client"))
  (nl-agent-client--close-internal client "client closed"))

(provide 'nl-agent-client)
;;; nl-agent-client.el ends here
