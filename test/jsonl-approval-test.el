;;; jsonl-approval-test.el --- JSONL approval handshake tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                          (file-name-directory (or load-file-name buffer-file-name
                                                   default-directory))) nil t)
)
(require 'nl-agent-jsonl)
(require 'nl-agent-jsonl-approval)

(defun nl-agent-jsonl-approval-test--request ()
  (list :tool "edit" :risk 'write :description "Replace old with new"
        :args '(:form ("a" a))
        :context '(:private "must-not-leak")))

(defun nl-agent-jsonl-approval-test--response (id token decision)
  (format "{\"id\":\"%s\",\"method\":\"approve\",\"params\":{\"approvalId\":\"%s\",\"decision\":\"%s\"}}"
          id token decision))

(defun nl-agent-jsonl-approval-test--state (responses)
  (let ((writes nil) (reads (copy-sequence responses)) (read-count 0))
    (list
     (nl-agent-jsonl-approval-new
      (lambda (&optional _prompt)
        (setq read-count (1+ read-count))
        (pop reads))
      (lambda (line) (push line writes)))
     (lambda () writes)
     (lambda () read-count))))

(ert-deftest nl-agent-jsonl-approval-positive-decisions-and-exact-event ()
  (let* ((fixture (nl-agent-jsonl-approval-test--state
                   (list (nl-agent-jsonl-approval-test--response
                          "call-1" "approval-1" "once")
                         (nl-agent-jsonl-approval-test--response
                          "call-2" "approval-2" "session")
                         (nl-agent-jsonl-approval-test--response
                          "call-3" "approval-3" "deny"))))
         (state (nth 0 fixture))
         (writes (nth 1 fixture))
         (request (nl-agent-jsonl-approval-test--request)))
    (should (eq
             (nl-agent-jsonl-approval-call
              state "call-1"
              (lambda () (nl-agent-jsonl-approval-callback state request)))
             'once))
    (should (eq
             (nl-agent-jsonl-approval-call
              state "call-2"
              (lambda () (nl-agent-jsonl-approval-callback state request)))
             'session))
    (should (eq
             (nl-agent-jsonl-approval-call
              state "call-3"
              (lambda () (nl-agent-jsonl-approval-callback state request)))
             'deny))
    (let* ((event
            (json-parse-string (car (funcall writes))
                               :object-type 'alist :array-type 'array
                               :null-object :json-null :false-object :json-false))
           (keys (mapcar #'car event))
           (request-object (alist-get 'request event)))
      (should (equal keys '(id event approvalId request)))
      (should-not (assoc 'context request-object))
      (should (equal (alist-get 'tool request-object) "edit"))
      (should (equal (alist-get 'args request-object)
                     '((form . ["a" "a"]))))
      (should (string-match-p "\\\"a\\\"" (alist-get 'argsLisp request-object)))
      (should (equal (alist-get 'argsLisp request-object)
                     "(:form (\"a\" a))"))
      (should-not (string-match-p "private" (alist-get 'argsLisp request-object))))
    (should (= (nl-agent-jsonl-approval-state-counter state) 3))))

(ert-deftest nl-agent-jsonl-approval-rejects-shapes-and-stale-replies ()
  (dolist (response
           (list
            "[]"
            "{\"id\":\"wrong\",\"method\":\"approve\",\"params\":{\"approvalId\":\"approval-1\",\"decision\":\"once\"}}"
            "{\"id\":\"call\",\"method\":\"approve\",\"params\":{\"approvalId\":\"stale\",\"decision\":\"once\"}}"
            "{\"id\":\"call\",\"method\":\"approve\",\"params\":{\"approvalId\":\"approval-1\",\"decision\":\"bad\"}}"
            "{\"id\":\"call\",\"method\":\"approve\",\"params\":{\"approvalId\":\"approval-1\",\"decision\":\"once\",\"decision\":\"deny\"}}"
            "{\"id\":\"call\",\"method\":\"approve\",\"params\":null}"))
    (let* ((fixture (nl-agent-jsonl-approval-test--state (list response)))
           (state (nth 0 fixture))
           (reads (nth 2 fixture)))
      (should (eq
               (nl-agent-jsonl-approval-call
                state "call"
                (lambda ()
                  (nl-agent-jsonl-approval-callback
                   state (nl-agent-jsonl-approval-test--request))))
               'deny))
      (should (= (funcall reads) 1))
      (should-not (nl-agent-jsonl-approval-state-failed state)))))

(ert-deftest nl-agent-jsonl-approval-failures-are-sticky-and-not-replayed ()
  (let* ((fixture (nl-agent-jsonl-approval-test--state nil))
         (state (nth 0 fixture))
         (request (nl-agent-jsonl-approval-test--request))
         (caught nil)
         (callback-result nil)
         (thunk-calls 0))
    (condition-case nil
        (nl-agent-jsonl-approval-call
         state "eof"
         (lambda ()
           (setq callback-result
                 (nl-agent-jsonl-approval-callback state request))))
      (nl-agent-jsonl-approval-io-error (setq caught t)))
    (should (eq callback-result 'deny))
    (should caught)
    (should (nl-agent-jsonl-approval-state-failed state))
    (setq caught nil)
    (condition-case nil
        (nl-agent-jsonl-approval-call
         state "again" (lambda () (setq thunk-calls (1+ thunk-calls)) 'ran))
      (nl-agent-jsonl-approval-io-error (setq caught t)))
    (should caught)
    (should (= thunk-calls 0))
    (should-not (nl-agent-jsonl-approval-state-active-id state))
    (should (eq (nl-agent-jsonl-approval-callback state request) 'deny)))
  (let* ((fixture (nl-agent-jsonl-approval-test--state
                   (list (nl-agent-jsonl-approval-test--response
                          "write" "approval-1" "once"))))
         (state (nth 0 fixture))
         (callback-result nil)
         (caught nil))
    (setf (nl-agent-jsonl-approval-state-write state)
          (lambda (_line) (error "write failed")))
    (condition-case nil
        (nl-agent-jsonl-approval-call
         state "write"
         (lambda ()
           (setq callback-result
                 (nl-agent-jsonl-approval-callback
                  state (nl-agent-jsonl-approval-test--request)))))
      (nl-agent-jsonl-approval-io-error (setq caught t)))
    (should (eq callback-result 'deny))
    (should caught)
    (should-not (nl-agent-jsonl-approval-state-active-id state))
    (should (nl-agent-jsonl-approval-state-failed state)))
  (let* ((fixture (nl-agent-jsonl-approval-test--state
                   (list (nl-agent-jsonl-approval-test--response
                          "read-error" "approval-1" "once"))))
         (state (nth 0 fixture))
         (writes (nth 1 fixture))
         (request (nl-agent-jsonl-approval-test--request))
         (caught nil)
         (callback-result nil))
    (setf (nl-agent-jsonl-approval-state-read state)
          (lambda (&optional _prompt) (error "read failed")))
    (condition-case nil
        (nl-agent-jsonl-approval-call
         state "read-error"
         (lambda ()
           (setq callback-result
                 (nl-agent-jsonl-approval-callback state request))))
      (nl-agent-jsonl-approval-io-error (setq caught t)))
    (should (eq callback-result 'deny))
    (should caught)
    (should (= (length (funcall writes)) 1))
    (should (nl-agent-jsonl-approval-state-failed state))
    (should-not (nl-agent-jsonl-approval-state-active-id state)))
  (let* ((fixture (nl-agent-jsonl-approval-test--state
                   (list (nl-agent-jsonl-approval-test--response
                          "opaque" "approval-1" "once"))))
         (state (nth 0 fixture))
         (writes (nth 1 fixture))
         (callback-result nil)
         (caught nil))
    (condition-case nil
        (nl-agent-jsonl-approval-call
         state "opaque"
         (lambda ()
           (setq callback-result
                 (nl-agent-jsonl-approval-callback
                  state (list :tool "edit" :risk 'write :description ""
                              :args (make-hash-table) :context nil)))))
      (nl-agent-jsonl-approval-io-error (setq caught t)))
    (should (eq callback-result 'deny))
    (should caught)
    (should (null (funcall writes)))
    (should (nl-agent-jsonl-approval-state-failed state))))

(ert-deftest nl-agent-jsonl-approval-outside-active-and-bounds ()
  (let* ((fixture (nl-agent-jsonl-approval-test--state nil))
         (state (nth 0 fixture))
         (request (nl-agent-jsonl-approval-test--request)))
    (should (eq (nl-agent-jsonl-approval-callback state request) 'deny))
    (should (= (funcall (nth 2 fixture)) 0)))
  (let ((response (nl-agent-jsonl-approval-test--response
                   "call" "approval-1" "once")))
    (let* ((fixture (nl-agent-jsonl-approval-test--state (list response)))
           (state (nth 0 fixture)))
      (should (eq
               (nl-agent-jsonl-approval-call
                state "call"
                (lambda ()
                  (nl-agent-jsonl-approval-callback
                   state (nl-agent-jsonl-approval-test--request))))
               'once))
      (should-not (nl-agent-jsonl-approval-state-failed state)))
    (let* ((nl-agent-jsonl-max-line-bytes (1- (string-bytes response)))
           (fixture (nl-agent-jsonl-approval-test--state (list response)))
           (state (nth 0 fixture)))
      (should (eq
               (nl-agent-jsonl-approval-call
                state "call"
                (lambda ()
                  (nl-agent-jsonl-approval-callback
                   state (nl-agent-jsonl-approval-test--request))))
               'deny))
      (should-not (nl-agent-jsonl-approval-state-failed state)))))

(ert-deftest nl-agent-jsonl-approval-lisp-view-strips-string-properties ()
  (let* ((fixture (nl-agent-jsonl-approval-test--state
                   (list (nl-agent-jsonl-approval-test--response
                          "props" "approval-1" "once"))))
         (state (nth 0 fixture))
         (writes (nth 1 fixture))
         (request (list :tool "edit" :risk 'write :description ""
                        :args (list :text
                                     (propertize
                                      "safe" 'secret
                                      (lambda () "must-not-leak")))
                        :context nil)))
    (should (eq
             (nl-agent-jsonl-approval-call
              state "props"
              (lambda ()
                (nl-agent-jsonl-approval-callback state request)))
             'once))
    (let* ((event (json-parse-string (car (funcall writes))
                                     :object-type 'alist :array-type 'array))
           (event-request (alist-get 'request event))
           (args-lisp (alist-get 'argsLisp event-request)))
      (should (equal args-lisp "(:text \"safe\")"))
      (should-not
       (string-match-p (regexp-opt '("secret" "must-not-leak")) args-lisp)))))

(provide 'jsonl-approval-test)
(ert-run-tests-batch-and-exit)
;;; jsonl-approval-test.el ends here
