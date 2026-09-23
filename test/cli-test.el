;;; cli-test.el --- NeLisp Agent command-line facade tests  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-cli)

(defvar nl-agent-cli-test--fail 0)

(defun nl-agent-cli-test--ck (name ok)
  (princ (format "%-66s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-cli-test--fail
                         (1+ nl-agent-cli-test--fail))
                   "FAIL"))))

(defun nl-agent-cli-test--error-p (thunk)
  (condition-case nil
      (progn (funcall thunk) nil)
    (error t)))

(nl-agent-cli-test--ck
 "argument parser keeps connection and one-shot options as data"
 (equal
 (nl-agent-cli-parse-args
   '("--" "--base-url" "https://provider.invalid/v1"
     "--mcp-config" "mcp.json" "--native-catalog" "models.json"
     "--improvement-config" "improvement.json"
     "--model" "native/self-g1"
     "--autonomous-improvement" "--task" "inspect" "--unattended"))
  '(:base-url "https://provider.invalid/v1"
    :mcp-config "mcp.json" :native-catalog "models.json"
    :improvement-config "improvement.json"
    :model "native/self-g1"
    :autonomous-improvement t
    :task "inspect" :unattended t)))

(let ((old (getenv "NELISP_AGENT_MCP_CONFIG")))
  (unwind-protect
      (progn
        (setenv "NELISP_AGENT_MCP_CONFIG" "environment-mcp.json")
        (nl-agent-cli-test--ck
         "MCP config environment fallback is applied without overriding flags"
         (and
          (equal
           (plist-get
            (nl-agent-cli-options-with-environment nil) :mcp-config)
           "environment-mcp.json")
          (equal
           (plist-get
            (nl-agent-cli-options-with-environment
             '(:mcp-config "flag-mcp.json"))
            :mcp-config)
           "flag-mcp.json"))))
    (setenv "NELISP_AGENT_MCP_CONFIG" old)))

(let ((old (getenv "NELISP_AGENT_IMPROVEMENT_CONFIG")))
  (unwind-protect
      (progn
        (setenv "NELISP_AGENT_IMPROVEMENT_CONFIG" "improvement.json")
        (nl-agent-cli-test--ck
         "improvement config has a dedicated environment fallback"
         (equal
          (plist-get
           (nl-agent-cli-options-with-environment nil)
           :improvement-config)
          "improvement.json")))
    (setenv "NELISP_AGENT_IMPROVEMENT_CONFIG" old)))

(let ((old (getenv "NELISP_AGENT_MODEL")))
  (unwind-protect
      (progn
        (setenv "NELISP_AGENT_MODEL" "native/self-g2")
        (nl-agent-cli-test--ck
         "initial model has a dedicated environment fallback"
         (and
          (equal
           (plist-get (nl-agent-cli-options-with-environment nil) :model)
           "native/self-g2")
          (equal
           (plist-get
            (nl-agent-cli-options-with-environment
             '(:model "native/flag-g1"))
            :model)
           "native/flag-g1"))))
    (setenv "NELISP_AGENT_MODEL" old)))

(let ((artifact-call nil)
      (supervisor-call nil))
  (cl-letf
      (((symbol-function 'nl-llm-agent-artifact-provider)
        (lambda (id path &optional name)
          (setq artifact-call (list id path name))
          'fake-native-provider))
       ((symbol-function 'nl-agent-example-free-supervisor)
        (lambda (&rest args)
          (setq supervisor-call args)
          'fake-supervisor)))
    (nl-agent-cli-test--ck
     "CLI injects promoted artifacts through the provider boundary"
     (and
      (eq
       (nl-agent-cli--supervisor
        '(:base-url "https://provider.invalid/v1"
          :native-catalog "promoted.json")
        'approval)
       'fake-supervisor)
      (equal artifact-call '("native" "promoted.json" nil))
      (equal (nth 7 supervisor-call) '(fake-native-provider))))))

(let* ((provider
       (nl-llm-agent-provider-new
         "native" :models '("self-g1")
         :open (lambda (_id _options) nil)
         :complete (lambda (_state _messages) "")))
       (config-call nil)
       (supervisor-call nil)
       (unexpected-artifact-call nil))
  (cl-letf
      (((symbol-function 'nl-agent-improvement-config-load)
        (lambda (path)
          (setq config-call path)
          (list :queue 'durable-improvement-queue
                :provider provider
                :provider-id "native" :id-prefix "self"
                :catalog-file (expand-file-name "models.json"))))
       ((symbol-function 'nl-llm-agent-artifact-provider)
        (lambda (&rest args)
          (setq unexpected-artifact-call args)
          'duplicate-provider))
       ((symbol-function 'nl-agent-example-free-supervisor)
        (lambda (&rest args)
          (setq supervisor-call args)
          'fake-supervisor)))
    (nl-agent-cli-test--ck
     "CLI assembles the durable improvement queue and provider together"
     (and
      (eq
       (nl-agent-cli--supervisor
        '(:improvement-config "improvement.json"
          :model "native/self-g1"
          :autonomous-improvement t
          :native-catalog "models.json")
        nil)
       'fake-supervisor)
      (equal config-call "improvement.json")
      (null unexpected-artifact-call)
      (equal (nth 7 supervisor-call) (list provider))
      (eq (nth 8 supervisor-call) 'durable-improvement-queue)
      (eq
       (funcall
        (nth 4 supervisor-call)
        '(:tool "model.improvement.submit" :args (:kind "x")))
       'autonomous)))))

(let ((unattended
       (nl-agent-autonomy-improvement-approval "native" "self")))
  (nl-agent-cli-test--ck
   "scoped autonomy permits only its queue and provider-qualified generations"
   (and
    (eq (funcall unattended
                 '(:tool "model.improvement.run" :args nil))
        'autonomous)
    (eq (funcall unattended
                 '(:tool "service.model.switch"
                   :args (:selector "native/self-g12")))
        'autonomous)
    (eq (funcall unattended
                 '(:tool "service.model.switch"
                   :args (:selector "remote/other")))
        'deny)
    (eq (funcall unattended
                 '(:tool "workspace.shell" :args (:command "make")))
        'deny))))

(let* ((calls 0)
      (approval
       (nl-agent-autonomy-improvement-approval
        "native" "self"
        (lambda (_request)
          (setq calls (1+ calls))
          'session))))
  (nl-agent-cli-test--ck
   "unrelated requests still use the ordinary interactive approval callback"
   (and (eq (funcall approval
                     '(:tool "workspace.shell" :args (:command "make")))
            'session)
        (= calls 1))))

(nl-agent-cli-test--ck
 "autonomous improvement cannot be enabled without its bounded configuration"
 (nl-agent-cli-test--error-p
  (lambda ()
    (nl-agent-cli--supervisor
     '(:base-url "https://provider.invalid/v1"
       :autonomous-improvement t)
     nil))))

(nl-agent-cli-test--ck
 "argument parser rejects conflicting one-shot modes"
 (nl-agent-cli-test--error-p
  (lambda ()
    (nl-agent-cli-parse-args
     '("--task" "one" "--chat" "two")))))

(nl-agent-cli-test--ck
 "argument parser rejects unknown options"
 (nl-agent-cli-test--error-p
  (lambda () (nl-agent-cli-parse-args '("--unsafe-magic")))))

(nl-agent-cli-test--ck
 "plain interactive text maps to the agent runtime"
 (equal (nl-agent-cli-route-line "fix the tests")
        '(:kind request :request (run "fix the tests"))))

(nl-agent-cli-test--ck
 "model command maps to transactional worker switching"
 (equal
  (nl-agent-cli-route-line "/model remote/fallback")
  '(:kind request :request (switch "remote/fallback"))))

(nl-agent-cli-test--ck
 "unknown slash command remains local and cannot reach the worker"
 (eq (plist-get (nl-agent-cli-route-line "/erase") :kind) 'error))

(nl-agent-cli-test--ck
 "agent completion formatter prints only the final answer"
 (equal
  (nl-agent-cli-format-response
   '(:kind agent-run :status done :result "finished" :trajectory nil))
  "finished"))

(nl-agent-cli-test--ck
 "model catalog formatter emits provider-qualified selectors"
 (equal
  (nl-agent-cli-format-response
   '(:status ok :kind models
     :models ((:qualified-id "remote/a" :id "a" :name "A"))))
  "remote/a — A"))

(let ((written nil))
  (nl-agent-cli-test--ck
   "interactive approval maps yes to a one-time grant"
   (eq
    (nl-agent-cli-interactive-approval
     '(:tool "shell" :risk execute :args (:command "pwd"))
     (lambda (_prompt) "yes")
     (lambda (text) (setq written text)))
    'once))
  (nl-agent-cli-test--ck
   "approval prompt displays the exact structured arguments"
   (and (string-match-p "shell" written)
        (string-match-p "pwd" written))))

(nl-agent-cli-test--ck
 "interactive approval maps session explicitly"
 (eq
  (nl-agent-cli-interactive-approval
   '(:tool "edit" :risk write :args (:path "a.el"))
   (lambda (_prompt) "session") (lambda (_text) nil))
  'session))

(nl-agent-cli-test--ck
 "empty approval response fails closed"
 (eq
  (nl-agent-cli-interactive-approval
   '(:tool "shell" :risk execute :args nil)
   (lambda (_prompt) nil) (lambda (_text) nil))
  'deny))

(let ((inputs '("do work" "/model remote/b" "/quit"))
      (requests nil)
      (outputs nil))
  (cl-letf
      (((symbol-function 'nl-agent-supervisor-call)
        (lambda (_supervisor request)
          (setq requests (append requests (list request)))
          (pcase (car request)
            ('run '(:kind agent-run :status done :result "done"))
            ('switch '(:kind switched :status ok :model "remote/b"))
            (_ '(:kind closed :status ok)))))
       ((symbol-function 'nl-agent-supervisor-p)
        (lambda (_value) t)))
    (let ((status
           (nl-agent-cli-run-loop
            'fake-supervisor
            (lambda (_prompt)
              (let ((line (car inputs)))
                (setq inputs (cdr inputs))
                line))
            (lambda (text)
              (setq outputs (append outputs (list text)))))))
      (nl-agent-cli-test--ck
       "interactive loop presents run, switch, and quit on one surface"
       (and (= status 0)
            (equal requests
                   '((run "do work") (switch "remote/b") (quit)))))
      (nl-agent-cli-test--ck
       "interactive loop formats each structured worker response"
       (and (member "done" outputs)
            (member "Model: remote/b" outputs)
            (member "NeLisp Agent stopped." outputs))))))

(princ (format "NL-AGENT-CLI %s (%d failures)\n"
               (if (= nl-agent-cli-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-cli-test--fail))
(kill-emacs (if (= nl-agent-cli-test--fail 0) 0 1))

;;; cli-test.el ends here
