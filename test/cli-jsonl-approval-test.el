;;; cli-jsonl-approval-test.el --- JSONL human approval CLI tests -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-llm/lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-photon/lisp"))

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'nl-agent-cli)
(require 'nl-agent-jsonl-approval)
(require 'nl-agent-permission)
(require 'nl-agent-tool)

(defun nl-agent-cli-jsonl-approval-test--parse (line)
  "Parse one JSONL approval or response LINE into an alist."
  (json-parse-string line :object-type 'alist :array-type 'array
                     :null-object nil :false-object :json-false))

(ert-deftest nl-agent-cli-jsonl-approval-flag-is-explicit ()
  (should (equal (nl-agent-cli-parse-args
                  '("--jsonl" "--jsonl-approval"))
                 '(:jsonl t :jsonl-approval t)))
  (should-error (nl-agent-cli-parse-args '("--jsonl-approval")))
  (should-error
   (nl-agent-cli-parse-args '("--jsonl" "--jsonl-approval" "--unattended")))
  (should-error
   (nl-agent-cli-parse-args '("--jsonl" "--jsonl-approval"
                              "--jsonl-approval")))
  (should-not
   (plist-get
    (nl-agent-cli-options-with-environment '(:jsonl t))
    :jsonl-approval)))

(ert-deftest nl-agent-cli-jsonl-approval-assembly-is-opt-in ()
  (let (approvals states runs stopped)
    (cl-letf (((symbol-function 'nl-agent-cli--supervisor)
               (lambda (_options approval)
                 (push approval approvals)
                 'service))
              ((symbol-function 'nl-agent-cli-run-jsonl)
               (lambda (_supervisor _read _write _trajectory state)
                 (push state states)
                 (push t runs)
                 0))
              ((symbol-function 'nl-agent-supervisor-stop)
               (lambda (_supervisor) (setq stopped t))))
      (should (= (nl-agent-cli-run-options '(:jsonl t)) 0))
      (should-not (car approvals))
      (should-not (car states))
      (setq approvals nil states nil stopped nil)
      (should (= (nl-agent-cli-run-options
                  '(:jsonl t :jsonl-approval t))
                 0)))
    (should (functionp (car approvals)))
    (should (nl-agent-jsonl-approval-state-p (car states)))
    (should runs)
    (should stopped)))

(ert-deftest nl-agent-cli-jsonl-approval-real-permission-call ()
  (let* ((inputs
          (list
           "{\"id\":\"run-1\",\"method\":\"run\",\"params\":{\"text\":\"use tool\"}}"
           "{\"id\":\"run-1\",\"method\":\"approve\",\"params\":{\"approvalId\":\"approval-1\",\"decision\":\"once\"}}"
           "{\"id\":\"quit-1\",\"method\":\"quit\"}"))
         (outputs nil)
         (executions 0)
         (state nil)
         (registry (nl-agent-tool-registry-new)))
    (nl-agent-tool-register
     registry
     (nl-agent-tool-new
      "shell" (lambda (_args _context) (setq executions (1+ executions))
                "ran")
      :description "Run one bounded shell command" :risk 'execute))
    (setq state
          (nl-agent-jsonl-approval-new
           (lambda (_prompt)
             (prog1 (car inputs) (setq inputs (cdr inputs))))
           (lambda (line) (setq outputs (append outputs (list line))))))
    (let ((policy
           (nl-agent-permission-policy-new
            :mode 'smart
            :approval
            (lambda (request)
              (nl-agent-jsonl-approval-callback state request)))))
      (cl-letf (((symbol-function 'nl-agent-supervisor-call)
                 (lambda (_supervisor request)
                   (pcase (car request)
                     ('run
                      (let ((permission
                             (nl-agent-permission-call
                              policy registry "shell"
                              '(:command "printf approved") nil)))
                        (list :kind 'agent-run :status 'done
                              :result (plist-get permission :text))))
                     ('quit '(:kind closed :status ok))))))
        (should (= (nl-agent-cli-run-jsonl
                    'service
                    (lambda (_prompt)
                      (prog1 (car inputs) (setq inputs (cdr inputs))))
                    (lambda (line) (setq outputs (append outputs (list line))))
                    nil state)
                   0)))
    (should (= executions 1))
    (should (= (length outputs) 3))
    (let* ((event (nl-agent-cli-jsonl-approval-test--parse (nth 0 outputs)))
           (reply (nl-agent-cli-jsonl-approval-test--parse (nth 1 outputs)))
           (quit (nl-agent-cli-jsonl-approval-test--parse (nth 2 outputs)))
           (request (alist-get 'request event)))
      (should (equal (alist-get 'event event) "approval"))
      (should (equal (alist-get 'id event) "run-1"))
      (should (equal (alist-get 'approvalId event) "approval-1"))
      (should (equal (alist-get 'tool request) "shell"))
      (should (equal (alist-get 'risk request) "execute"))
      (should (equal (alist-get 'args request)
                     '((command . "printf approved"))))
      (should (equal (alist-get 'argsLisp request)
                     "(:command \"printf approved\")"))
      (should (eq (alist-get 'ok reply) t))
      (should (eq (alist-get 'ok quit) t))))))

(ert-deftest nl-agent-cli-jsonl-approval-deny-stale-and-hard-deny ()
  (let* ((run (lambda (approval-response hard-deny)
                (let ((inputs
                       (append
                        (list
                         "{\"id\":\"run-1\",\"method\":\"run\",\"params\":{\"text\":\"use tool\"}}")
                        (and approval-response (list approval-response))
                        (list "{\"id\":\"quit-1\",\"method\":\"quit\"}")))
                     (outputs nil) (executions 0)
                     (registry (nl-agent-tool-registry-new)) state policy)
                 (nl-agent-tool-register
                  registry
                  (nl-agent-tool-new
                   "shell" (lambda (_args _context)
                             (setq executions (1+ executions)) "ran")
                   :description "Run one bounded shell command"
                   :risk 'execute))
                 (setq state
                       (nl-agent-jsonl-approval-new
                        (lambda (_prompt)
                          (prog1 (car inputs) (setq inputs (cdr inputs))))
                        (lambda (line) (setq outputs (append outputs
                                                            (list line))))))
                 (setq policy
                       (nl-agent-permission-policy-new
                        :mode 'smart :hard-deny hard-deny
                        :approval
                        (lambda (request)
                          (nl-agent-jsonl-approval-callback state request))))
                 (cl-letf (((symbol-function 'nl-agent-supervisor-call)
                            (lambda (_supervisor request)
                              (if (eq (car request) 'run)
                                  (progn
                                    (nl-agent-permission-call
                                     policy registry "shell"
                                     '(:command "true") nil)
                                    '(:kind agent-run :status done :result "done"))
                                '(:kind closed :status ok)))))
                   (nl-agent-cli-run-jsonl
                    'service
                    (lambda (_prompt)
                      (prog1 (car inputs) (setq inputs (cdr inputs))))
                    (lambda (line) (setq outputs (append outputs (list line))))
                    nil state))
                 (list executions outputs))))
        (stale (funcall run
                        "{\"id\":\"run-1\",\"method\":\"approve\",\"params\":{\"approvalId\":\"old\",\"decision\":\"once\"}}"
                        nil))
        (hard (funcall run nil (lambda (_request) "blocked"))))
    (should (= (car stale) 0))
    (should (= (car hard) 0))
    ;; Stale approval still emits one challenge and one ordinary final reply;
    ;; hard-deny emits no challenge and never invokes the tool.
    (should (= (length (cadr stale)) 3))
    (should (= (length (cadr hard)) 2))))

(ert-deftest nl-agent-cli-jsonl-approval-io-failure-is-sticky ()
  (let ((inputs
         (list
          "{\"id\":\"run-1\",\"method\":\"run\",\"params\":{\"text\":\"use tool\"}}"))
        (writes 0) (final-writes 0) (executions 0) state
        (registry (nl-agent-tool-registry-new)) policy)
    (nl-agent-tool-register
     registry
     (nl-agent-tool-new
      "shell" (lambda (_args _context) (setq executions (1+ executions)) "ran")
      :description "Run one bounded shell command" :risk 'execute))
    (setq state
          (nl-agent-jsonl-approval-new
           (lambda (_prompt) (error "closed input"))
           (lambda (_line) (setq writes (1+ writes))
             (error "closed output"))))
    (setq policy
          (nl-agent-permission-policy-new
           :mode 'smart
           :approval
           (lambda (request)
             (nl-agent-jsonl-approval-callback state request))))
    (cl-letf (((symbol-function 'nl-agent-supervisor-call)
               (lambda (_supervisor _request)
                 (nl-agent-permission-call
                  policy registry "shell" '(:command "true") nil)
                 '(:kind agent-run :status done))))
      (should-error
       (nl-agent-cli-run-jsonl
        'service
        (lambda (_prompt)
          (prog1 (car inputs) (setq inputs (cdr inputs))))
        (lambda (_line) (setq final-writes (1+ final-writes)))
        nil state)
       :type 'nl-agent-cli-jsonl-session-error))
    (should (= writes 1))
    (should (= final-writes 0))
    (should (= executions 0))))

(provide 'cli-jsonl-approval-test)

(ert-run-tests-batch-and-exit)

;;; cli-jsonl-approval-test.el ends here
