;;; ui-test.el --- Emacs JSONL client UI tests -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)

(require 'cl-lib)
(require 'ert)
(require 'nl-agent-ui)

(defun nl-agent-ui-test--client (&optional pending)
  "Make a transport-only fake client for UI tests."
  (nl-agent-client--make
   :process t :pending pending :approval nil :closed nil :stderr-buffer nil
   :on-event nil :on-close nil :next-id 0 :inflight nil
   :used-approval-tokens nil :close-notified nil))

(defconst nl-agent-ui-test--approval
  '((id . "request-1") (event . "approval")
    (approvalId . "approval-1")
    (request . ((tool . "shell") (risk . "execute")
                (description . "run command")
                (args . ((command . "pwd")))
                (argsLisp . "(:command \"pwd\")")))))

(ert-deftest nl-agent-ui-command-is-argv-and-protocol-owned ()
  (let ((nl-agent-ui-command '("launcher"))
        (nl-agent-ui-arguments '("--model" "native/g1"))
        (workspace (file-name-as-directory default-directory)))
    (should (equal (nl-agent-ui--command workspace)
                   (list "launcher" "--model" "native/g1"
                         "--jsonl" "--jsonl-approval" "--workspace"
                         workspace)))
    (dolist (bad '("--jsonl" "--jsonl-approval" "--unattended" "--task=x"
                   "--chat=x" "--workspace" "--workspace=other" "--"))
      (let ((nl-agent-ui-arguments (list bad)))
        (should-error (nl-agent-ui--command workspace))))))

(ert-deftest nl-agent-ui-does-not-load-service-backend ()
  (should-not (featurep 'nl-agent-service))
  (should-not (featurep 'nl-agent-host))
  (should (equal (nl-agent-ui--safe-text "a\n\t\u202e")
                 "a\n\t\\u202E")))

(ert-deftest nl-agent-ui-renders-approval-and-ignores-stale-client ()
  (let ((client (nl-agent-ui-test--client))
        (stale (nl-agent-ui-test--client)))
    (with-temp-buffer
      (nl-agent-ui-mode)
      (setq-local nl-agent-ui--client client)
      (nl-agent-ui--event client nl-agent-ui-test--approval)
      (should (equal nl-agent-ui--approval-id "request-1"))
      (should (equal nl-agent-ui--approval-token "approval-1"))
      (should (string-match-p "APPROVAL PENDING" (buffer-string)))
      (should (string-match-p "argsLisp: (:command \\\"pwd\\\")"
                              (buffer-string)))
      (let ((before (buffer-string)))
        (nl-agent-ui--event stale
                             '((id . "stale") (event . "approval")
                               (approvalId . "wrong") (request . nil)))
        (should (equal before (buffer-string)))
        (should (equal nl-agent-ui--approval-token "approval-1"))))))

(ert-deftest nl-agent-ui-commands-forward-keyword-params-and-approval ()
  (let ((client (nl-agent-ui-test--client)) requests approvals)
    (with-temp-buffer
      (nl-agent-ui-mode)
      (setq-local nl-agent-ui--client client
                  nl-agent-ui--approval-id "request-1"
                  nl-agent-ui--approval-token "approval-1")
      (cl-letf (((symbol-function 'nl-agent-client-request)
                 (lambda (_client method params)
                   (push (list method params) requests) "request"))
                ((symbol-function 'nl-agent-client-approve)
                 (lambda (_client id token decision)
                   (push (list id token decision) approvals)))
                ((symbol-function 'read-string)
                 (lambda (&rest _args) "native/g2")))
        (nl-agent-ui-run)
        (nl-agent-ui-chat)
        (nl-agent-ui-switch)
        (nl-agent-ui-models)
        (nl-agent-ui-status)
        (nl-agent-ui-approve-once))
      (should (equal (car approvals) '("request-1" "approval-1" once)))
      (should-not nl-agent-ui--approval-id)
      (should (equal (mapcar #'car requests)
                     '("status" "models" "switch" "chat" "run")))
      (should (equal (nth 2 (assoc "switch" requests)) nil)))))

(ert-deftest nl-agent-ui-session-approval-and-force-disconnect-are-explicit ()
  (let ((client (nl-agent-ui-test--client)) approvals closed)
    (with-temp-buffer
      (nl-agent-ui-mode)
      (setq-local nl-agent-ui--client client
                  nl-agent-ui--approval-id "request-2"
                  nl-agent-ui--approval-token "approval-2")
      (cl-letf (((symbol-function 'nl-agent-client-approve)
                 (lambda (_client id token decision)
                   (push (list id token decision) approvals)))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'nl-agent-client-close)
                 (lambda (value)
                   (setq closed value)
                   (setf (nl-agent-client-closed value) t))))
        (nl-agent-ui-approve-session)
        (should (equal (car approvals) '("request-2" "approval-2" session)))
        (setq nl-agent-ui--approval-id "request-3"
              nl-agent-ui--approval-token "approval-3")
        (nl-agent-ui-disconnect))
      (should (eq closed client))
      (should-not nl-agent-ui--approval-token))))

(ert-deftest nl-agent-ui-quit-leaves-busy-check-to-transport ()
  (let ((client (nl-agent-ui-test--client "partial-frame")) called)
    (with-temp-buffer
      (nl-agent-ui-mode)
      (setq-local nl-agent-ui--client client)
      (cl-letf (((symbol-function 'nl-agent-client-request)
                 (lambda (&rest _args)
                   (setq called t)
                   (error "client request is already in flight"))))
        (nl-agent-ui-quit))
      (should called)
      (should (string-match-p "already in flight" (buffer-string))))))

(ert-deftest nl-agent-ui-approval-captures-client-identity ()
  (let ((client (nl-agent-ui-test--client))
        (replacement (nl-agent-ui-test--client)) approvals)
    (with-temp-buffer
      (nl-agent-ui-mode)
      (setq-local nl-agent-ui--client client
                  nl-agent-ui--approval-id "request-1"
                  nl-agent-ui--approval-token "approval-1")
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _args)
                   (setq-local nl-agent-ui--client replacement)
                   t))
                ((symbol-function 'nl-agent-client-approve)
                 (lambda (&rest args) (push args approvals))))
        (nl-agent-ui-approve-session))
      (should-not approvals)
      (should (equal nl-agent-ui--approval-token "approval-1")))))

(ert-deftest nl-agent-ui-trims-only-inactive-transcript ()
  (let ((nl-agent-ui--max-transcript-bytes 64)
        (client (nl-agent-ui-test--client)))
    (with-temp-buffer
      (nl-agent-ui-mode)
      (setq-local nl-agent-ui--client client)
      (nl-agent-ui--insert "%s" (make-string 200 ?x))
      (should (<= (string-bytes (buffer-string)) 64))
      (cl-letf (((symbol-function 'nl-agent-client-close)
                 (lambda (value) (setf (nl-agent-client-closed value) t)))
                ((symbol-function 'nl-agent-client-p)
                 (lambda (_value) t)))
        (nl-agent-ui--event client nl-agent-ui-test--approval))
      (should (string-match-p "transcript limit" (buffer-string)))
      (should-not nl-agent-ui--approval-token))))

(ert-deftest nl-agent-ui-active-approval-cap-closes-real-process ()
  (let ((process (start-process (generate-new-buffer-name "nl-agent-ui-cap-")
                                nil "cat"))
        (nl-agent-ui--max-transcript-bytes 256)
        client)
    (unwind-protect
        (with-temp-buffer
          (let ((buffer (current-buffer)))
            (setq client
                  (nl-agent-client--make
                   :process process :pending nil :approval nil :closed nil
                   :stderr-buffer nil :next-id 0 :inflight nil
                   :used-approval-tokens nil :close-notified nil
                   :on-event nil
                   :on-close
                   (lambda (value reason)
                     (with-current-buffer buffer
                       (nl-agent-ui--closed value reason)))))
            (nl-agent-ui-mode)
            (setq-local nl-agent-ui--client client)
            (nl-agent-ui--event client nl-agent-ui-test--approval)
            (nl-agent-ui--insert "%s" (make-string 300 ?x))
            (should (nl-agent-client-closed client))
            (should-not (process-live-p process))
            (should-not nl-agent-ui--approval-token)
            (should (string-match-p "transcript limit" (buffer-string)))
            (should (<= (string-bytes (buffer-string)) 256))))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest nl-agent-start-creates-dedicated-buffer-and-stale-callback-is-safe ()
  (let ((workspace (make-temp-file "nl-agent-ui-workspace-" t))
        (client (nl-agent-ui-test--client)) command directory event-callback
        close-callback)
    (unwind-protect
        (cl-letf (((symbol-function 'nl-agent-client-open)
                   (lambda (argv dir on-event on-close)
                     (setq command argv directory dir
                           event-callback on-event close-callback on-close)
                     client))
                  ((symbol-function 'nl-agent-client-close)
                   (lambda (_client) nil)))
          (let ((buffer (nl-agent-start workspace)))
            (unwind-protect
                (progn
                  (should (buffer-live-p buffer))
                  (should (equal directory (file-name-as-directory workspace)))
                  (should (member "--jsonl" command))
                  (should (member "--jsonl-approval" command))
                  (should (functionp close-callback))
                  (with-current-buffer buffer
                    (let ((replacement (nl-agent-ui-test--client)))
                      (setq-local nl-agent-ui--client replacement)
                      (funcall event-callback client nl-agent-ui-test--approval)
                      (should-not nl-agent-ui--approval-id))))
              (kill-buffer buffer))))
      (delete-directory workspace t))))

(provide 'ui-test)
(ert-run-tests-batch-and-exit)

;;; ui-test.el ends here
