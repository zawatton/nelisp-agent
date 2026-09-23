;;; cli-trajectory-test.el --- opt-in CLI trajectory capture tests -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'ert)
(require 'cl-lib)
(require 'nl-agent-cli)
(require 'nl-agent-trajectory)

(defun nl-agent-cli-trajectory-test--response (status)
  "Return a representative agent-run response with STATUS."
  (append
   (list :kind 'agent-run :status status :steps 2
         :result (if (eq status 'done) "finished" "not finished")
         :messages '((user . "TASK: inspect") (assistant . "DONE"))
         :trajectory nil)
   (when (eq status 'error) (list :error "worker failure"))))

(ert-deftest nl-agent-cli-trajectory-option-and-environment-precedence ()
  (should
   (equal
    (nl-agent-cli-parse-args
     '("--trajectory-directory" "records" "--task" "inspect"))
    '(:trajectory-directory "records" :task "inspect")))
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "NELISP_AGENT_TRAJECTORY_DIRECTORY" "environment-records")
    (should
     (equal
      (plist-get (nl-agent-cli-options-with-environment nil)
                 :trajectory-directory)
      "environment-records"))
    (should
     (equal
      (plist-get
       (nl-agent-cli-options-with-environment
        '(:trajectory-directory "flag-records"))
       :trajectory-directory)
      "flag-records"))))

(ert-deftest nl-agent-cli-call-captures-all-returned-run-statuses-once ()
  (dolist (status '(done limit error))
    (let ((supervisor-calls 0)
          (save-calls 0)
          (response (nl-agent-cli-trajectory-test--response status)))
      (cl-letf (((symbol-function 'nl-agent-supervisor-call)
                 (lambda (_supervisor _request)
                   (setq supervisor-calls (1+ supervisor-calls))
                   response))
                ((symbol-function 'nl-agent-trajectory-save)
                 (lambda (directory task saved-response)
                   (setq save-calls (1+ save-calls))
                   (should (equal directory "/records"))
                   (should (equal task "inspect"))
                   (should (equal saved-response response))
                   (format "/records/%s.sexp" status))))
        (let ((captured
               (nl-agent-cli--call
                'supervisor '(run "inspect") "/records")))
          (should (= supervisor-calls 1))
          (should (= save-calls 1))
          (should
           (equal (plist-get captured :trajectory-record)
                  (format "/records/%s.sexp" status)))
          (should (eq (plist-get captured :status) status)))))))

(ert-deftest nl-agent-cli-call-preserves-response-when-save-fails ()
  (dolist (status '(done limit error))
    (let ((calls 0)
          (response (nl-agent-cli-trajectory-test--response status)))
      (cl-letf (((symbol-function 'nl-agent-supervisor-call)
                 (lambda (_supervisor _request)
                   (setq calls (1+ calls))
                   response))
                ((symbol-function 'nl-agent-trajectory-save)
                 (lambda (&rest _args) (error "trajectory sink full"))))
        (let* ((returned
                (nl-agent-cli--call
                 'supervisor '(run "inspect") "/records"))
               (formatted (nl-agent-cli-format-response returned)))
          (should (= calls 1))
          (should (eq (plist-get returned :status) status))
          (should (equal (plist-get returned :result)
                         (plist-get response :result)))
          (should (string-match-p "trajectory sink full"
                                  (plist-get returned :trajectory-warning)))
          (should (string-match-p "WARNING:.*trajectory sink full"
                                  formatted))
          (pcase status
            ('done (should (string-prefix-p "finished" formatted)))
            ('limit (should (string-prefix-p "LIMIT:" formatted)))
            ('error (should (string-prefix-p "ERROR:" formatted)))))))))

(ert-deftest nl-agent-cli-call-does-no-file-work-when-disabled-or-not-run ()
  (let ((calls 0)
        (saves 0))
    (cl-letf (((symbol-function 'nl-agent-supervisor-call)
               (lambda (_supervisor request)
                 (setq calls (1+ calls))
                 (if (eq (car request) 'run)
                     (nl-agent-cli-trajectory-test--response 'done)
                   '(:kind completion :status ok :text "chat"))))
              ((symbol-function 'nl-agent-trajectory-save)
               (lambda (&rest _args)
                 (setq saves (1+ saves))
                 "/unexpected")))
      (nl-agent-cli--call 'supervisor '(run "disabled"))
      (nl-agent-cli--call 'supervisor '(chat "not a task") "/records")
      (nl-agent-cli--call 'supervisor '(status) "/records")
      (should (= calls 3))
      (should (= saves 0)))))

(ert-deftest nl-agent-cli-run-loop-captures-plain-and-explicit-runs-only ()
  (let ((inputs '("plain task" "/run explicit task" "/chat hello"
                  "/status" "/quit"))
        (requests nil)
        (saved-tasks nil))
    (cl-letf (((symbol-function 'nl-agent-supervisor-call)
               (lambda (_supervisor request)
                 (setq requests (append requests (list request)))
                 (pcase (car request)
                   ('run (nl-agent-cli-trajectory-test--response 'done))
                   ('chat '(:kind completion :status ok :text "chat"))
                   ('status '(:kind status :status ok :state open
				    :model "native/test" :message-count 0
				    :generation 0))
                   (_ '(:kind closed :status ok)))))
              ((symbol-function 'nl-agent-trajectory-save)
               (lambda (_directory task _response)
                 (setq saved-tasks (append saved-tasks (list task)))
                 (concat "/records/" task ".sexp"))))
      (should
       (= 0
          (nl-agent-cli-run-loop
           'supervisor
           (lambda (_prompt)
             (let ((input (car inputs)))
               (setq inputs (cdr inputs))
               input))
           (lambda (_text) nil)
           "/records")))
      (should
       (equal requests
              '((run "plain task") (run "explicit task")
                (chat "hello") (status) (quit))))
      (should (equal saved-tasks '("plain task" "explicit task"))))))

(ert-deftest nl-agent-cli-run-options-validates-and-preserves-exit-status ()
  (let ((supervisor-created nil))
    (cl-letf (((symbol-function 'nl-agent-cli--supervisor)
               (lambda (&rest _args)
                 (setq supervisor-created t)
                 'supervisor)))
      (should-error
       (nl-agent-cli-run-options
        '(:trajectory-directory "" :task "must not run")))
      (should-not supervisor-created)))
  (dolist (case '((done . 0) (limit . 1)))
    (let ((calls 0)
          (written nil)
          (process-environment (copy-sequence process-environment)))
      (setenv "NELISP_AGENT_TRAJECTORY_DIRECTORY" nil)
      (cl-letf (((symbol-function 'nl-agent-cli--supervisor)
                 (lambda (&rest _args) 'supervisor))
                ((symbol-function 'nl-agent-supervisor-call)
                 (lambda (_supervisor _request)
                   (setq calls (1+ calls))
                   (nl-agent-cli-trajectory-test--response (car case))))
                ((symbol-function 'nl-agent-trajectory-save)
                 (lambda (&rest _args) (error "cannot save")))
                ((symbol-function 'nl-agent-cli--write-line)
                 (lambda (text) (setq written text)))
                ((symbol-function 'nl-agent-supervisor-stop)
                 (lambda (_supervisor) nil)))
        (should
         (= (cdr case)
            (nl-agent-cli-run-options
             '(:trajectory-directory "records" :task "inspect"))))
        (should (= calls 1))
        (should (string-match-p "WARNING:.*cannot save" written))))))

(provide 'cli-trajectory-test)

(ert-run-tests-batch-and-exit)

;;; cli-trajectory-test.el ends here
