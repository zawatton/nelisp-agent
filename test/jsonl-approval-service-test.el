;;; jsonl-approval-service-test.el --- packaged JSONL approval service -*- lexical-binding: t; -*-

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name "../lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-llm/lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-photon/lisp" here)))

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'nl-agent-cli)
(require 'nl-agent-local-tools)
(require 'nl-llm-agent-provider)

(defun nl-agent-jsonl-approval-service-test--json (line)
  "Parse one JSONL LINE as bounded public data."
  (json-parse-string line :object-type 'alist :array-type 'array
                     :null-object nil :false-object :json-false))

(defun nl-agent-jsonl-approval-service-test--clear-environment ()
  "Remove ambient Agent settings from this test's child-process setup."
  (dolist (entry (copy-sequence process-environment))
    (when (string-prefix-p "NELISP_AGENT_" entry)
      (setenv (car (split-string entry "=")) nil))))

(defun nl-agent-jsonl-approval-service-test--run
    (project workspace trajectory approval-line)
  "Run one real JSONL session and return its parsed output lines.
APPROVAL-LINE is the one response consumed by the approval callback."
  (let ((inputs
         (list
          "{\"id\":\"r\",\"method\":\"run\",\"params\":{\"text\":\"inspect\"}}"
          approval-line
          "{\"id\":\"q\",\"method\":\"quit\"}"))
        (outputs nil)
        (options
         (nl-agent-cli-parse-args
          (list "--jsonl" "--jsonl-approval"
                "--base-url" "https://unused.invalid/v1"
                "--model" "remote/model"
                "--nelisp"
                (expand-file-name "../nelisp/target/nelisp" project)
                "--workspace" workspace
                "--trajectory-directory" trajectory))))
    (cl-letf (((symbol-function 'nl-agent-cli--read-line)
               (lambda (&optional _prompt)
                 (prog1 (car inputs)
                   (setq inputs (cdr inputs)))))
              ((symbol-function 'nl-agent-cli--write-line)
               (lambda (line)
                 (setq outputs (append outputs (list line))))))
      (should (= (nl-agent-cli-run-options options) 0)))
    (should-not inputs)
    (should (= (length outputs) 3))
    (mapcar #'nl-agent-jsonl-approval-service-test--json outputs)))

(ert-deftest nl-agent-jsonl-approval-packaged-service-uses-real-tool-boundary ()
  "Exercise the packaged worker with once, deny, and stale approval replies."
  (let* ((here (file-name-directory (or load-file-name buffer-file-name)))
         (project (expand-file-name ".." here))
         (root (make-temp-file "nl-agent-jsonl-approval-service-" t))
         (workspace (expand-file-name "workspace" root))
         (trajectory (expand-file-name "trajectory" root))
         (original-shell (symbol-function 'nl-agent-local--shell))
         (shell-calls 0)
         (http-calls 0)
         (provider-calls 0))
    (make-directory workspace t)
    (unwind-protect
        (let ((process-environment (copy-sequence process-environment)))
          (nl-agent-jsonl-approval-service-test--clear-environment)
          (cl-letf
              (((symbol-function 'nl-llm-agent-openai-provider)
                (lambda (&rest _args)
                  (setq provider-calls (1+ provider-calls))
                  (let ((completions 0))
                    (nl-llm-agent-provider-new
                     "remote" :models '("model")
                     :open (lambda (_model _options) nil)
                     :complete
                     (lambda (_state _messages)
                       (setq completions (1+ completions))
                       (if (= completions 1)
                           "```sh\npwd\n```"
                         "DONE inspected"))))))
               ((symbol-function 'url-retrieve-synchronously)
                (lambda (&rest _args)
                  (setq http-calls (1+ http-calls))
                  (error "approval service test attempted HTTP")))
               ((symbol-function 'nl-agent-local--shell)
                (lambda (root args)
                  (setq shell-calls (1+ shell-calls))
                  (funcall original-shell root args))))
            (let* ((once
                    (nl-agent-jsonl-approval-service-test--run
                     project workspace trajectory
                     "{\"id\":\"r\",\"method\":\"approve\",\"params\":{\"approvalId\":\"approval-1\",\"decision\":\"once\"}}"))
                   (once-event (nth 0 once))
                   (once-result (nth 1 once))
                   (once-quit (nth 2 once)))
              (should (equal (alist-get 'id once-event) "r"))
              (should (equal (alist-get 'event once-event) "approval"))
              (should (equal (alist-get 'approvalId once-event) "approval-1"))
              (should (equal (alist-get 'risk (alist-get 'request once-event))
                             "execute"))
              (should (equal (alist-get 'command (alist-get 'args
                                                             (alist-get 'request once-event)))
                             "pwd"))
              (should (equal (alist-get 'argsLisp (alist-get 'request once-event))
                             "(:command \"pwd\")"))
              (should (eq (alist-get 'ok once-result) t))
              (should (equal (alist-get 'id once-result) "r"))
              (should (equal (alist-get 'kind (alist-get 'result once-result))
                             "agent-run"))
              (should (equal (alist-get 'status (alist-get 'result once-result))
                             "done"))
              (should (equal (alist-get 'result (alist-get 'result once-result))
                             "inspected"))
              (should (equal (alist-get 'id once-quit) "q"))
              (should (equal (alist-get 'kind (alist-get 'result once-quit))
                             "closed"))
              (should (equal (alist-get 'status (alist-get 'result once-quit))
                             "ok"))
              (should (= shell-calls 1))
              (should (cl-some
                       (lambda (file)
                         (with-temp-buffer
                           (insert-file-contents file)
                           (string-match-p (regexp-quote workspace)
                                           (buffer-string))))
                       (directory-files trajectory t "\\.sexp\\'")))
              (should (> provider-calls 0)))
            (let ((before-deny shell-calls))
              (let ((deny
                     (nl-agent-jsonl-approval-service-test--run
                      project workspace trajectory
                      "{\"id\":\"r\",\"method\":\"approve\",\"params\":{\"approvalId\":\"approval-1\",\"decision\":\"deny\"}}")))
                (should (equal (alist-get 'event (nth 0 deny)) "approval"))
                (should (equal (alist-get 'kind (alist-get 'result (nth 1 deny)))
                               "agent-run"))
                (should (equal (alist-get 'status (alist-get 'result (nth 1 deny)))
                               "done"))
                (should (equal (alist-get 'id (nth 0 deny)) "r"))
                (should (equal (alist-get 'id (nth 1 deny)) "r"))
                (should (equal (alist-get 'id (nth 2 deny)) "q"))
                (should (equal (alist-get 'argsLisp
                                          (alist-get 'request (nth 0 deny)))
                               "(:command \"pwd\")"))
                (should (string-match-p
                         "denied"
                         (prin1-to-string
                          (alist-get 'trajectory
                                     (alist-get 'result (nth 1 deny))))))
                (should (= shell-calls before-deny))))
            (let ((before-stale shell-calls))
              (let ((stale
                     (nl-agent-jsonl-approval-service-test--run
                      project workspace trajectory
                      "{\"id\":\"r\",\"method\":\"approve\",\"params\":{\"approvalId\":\"stale\",\"decision\":\"once\"}}")))
                (should (equal (alist-get 'event (nth 0 stale)) "approval"))
                (should (equal (alist-get 'kind (alist-get 'result (nth 1 stale)))
                               "agent-run"))
                (should (equal (alist-get 'status (alist-get 'result (nth 1 stale)))
                               "done"))
                (should (equal (alist-get 'id (nth 0 stale)) "r"))
                (should (equal (alist-get 'id (nth 1 stale)) "r"))
                (should (equal (alist-get 'id (nth 2 stale)) "q"))
                (should (equal (alist-get 'argsLisp
                                          (alist-get 'request (nth 0 stale)))
                               "(:command \"pwd\")"))
                (should (string-match-p
                         "denied"
                         (prin1-to-string
                          (alist-get 'trajectory
                                     (alist-get 'result (nth 1 stale))))))
                (should (= shell-calls before-stale))))
          (should (= http-calls 0))))
      (when (file-directory-p root)
        (delete-directory root t)))))

(provide 'jsonl-approval-service-test)
(ert-run-tests-batch-and-exit)

;;; jsonl-approval-service-test.el ends here
