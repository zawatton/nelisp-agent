;;; runtime-test.el --- permission-gated NeLisp Agent loop tests  -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path
             (or (getenv "NELISP_LLM_LISP")
                 (expand-file-name "../nelisp-llm/lisp")))
(require 'nl-llm-agent-provider)
(require 'nl-agent-service)
(require 'nl-agent-runtime)

(defvar nl-agent-runtime-test--fail 0)

(defun nl-agent-runtime-test--ck (name ok &optional extra)
  (princ (format "%-64s %s  %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-runtime-test--fail
                         (1+ nl-agent-runtime-test--fail))
                   "FAIL")
                 (or extra ""))))

(defun nl-agent-runtime-test--error-p (thunk)
  (condition-case nil
      (progn (funcall thunk) nil)
    (error t)))

(defun nl-agent-runtime-test--service (responses &optional requests)
  "Return a scripted service yielding RESPONSES and recording into REQUESTS."
  (let* ((queue (copy-sequence responses))
         (last "DONE no response")
         (provider
          (nl-llm-agent-provider-new
           "scripted" :models '("model")
           :open (lambda (_model _options) t)
           :complete
           (lambda (_state messages)
             (when requests
               (setcar requests
                       (append (car requests) (list (copy-tree messages)))))
             (if queue (setq last (pop queue)) last))))
         (model-registry (nl-llm-agent-provider-registry-new)))
    (nl-llm-agent-provider-register model-registry provider)
    (nl-agent-service-new
     model-registry "scripted/model"
     :system nl-llm-agent-system-prompt)))

(let* ((registry (nl-agent-tool-registry-new))
       (calls nil)
       (read-tool
        (nl-agent-tool-new
         "read" (lambda (args _context) (push args calls) "contents")
         :description "Read data" :risk 'read :metadata '(:format text)))
       (shell-tool
        (nl-agent-tool-new
         "shell" (lambda (args _context) (push args calls) "ran")
         :description "Run a command" :risk 'execute)))
  (nl-agent-tool-register registry read-tool)
  (nl-agent-tool-register registry shell-tool)
  (nl-agent-runtime-test--ck
   "tool catalog exposes descriptors but not invocation functions"
   (equal (nl-agent-tool-catalog registry)
          '((:name "read" :description "Read data" :risk read
             :metadata (:format text))
            (:name "shell" :description "Run a command" :risk execute
             :metadata nil))))
  (nl-agent-runtime-test--ck
   "duplicate tool registration is rejected"
   (nl-agent-runtime-test--error-p
    (lambda () (nl-agent-tool-register registry read-tool))))
  (let* ((policy (nl-agent-permission-policy-new :mode 'smart))
         (result
          (nl-agent-permission-call policy registry "read" '(:path "x"))))
    (nl-agent-runtime-test--ck
     "smart policy automatically allows read-only tools"
     (and (eq (plist-get result :status) 'ok)
          (eq (plist-get (plist-get result :authorization) :source)
              'policy))))
  (setq calls nil)
  (let* ((policy (nl-agent-permission-policy-new :mode 'smart))
         (result
          (nl-agent-permission-call
           policy registry "shell" '(:command "date"))))
    (nl-agent-runtime-test--ck
     "missing approval fails closed for an executable tool"
     (and (eq (plist-get result :status) 'denied)
          (eq (plist-get (plist-get result :authorization) :source)
              'fail-closed)
          (null calls))))
  (let* ((policy
          (nl-agent-permission-policy-new
           :mode 'smart :approval (lambda (_request) 'once)))
         (result
          (nl-agent-permission-call
           policy registry "shell" '(:command "date"))))
    (nl-agent-runtime-test--ck
     "one-time approval crosses the tool boundary"
     (and (eq (plist-get result :status) 'ok)
          (equal (plist-get result :text) "ran")
          (= (length calls) 1))))
  (setq calls nil)
  (let* ((policy
          (nl-agent-permission-policy-new
           :mode 'smart :approval (lambda (_request) 'autonomous)))
         (result
          (nl-agent-permission-call
           policy registry "shell" '(:command "date"))))
    (nl-agent-runtime-test--ck
     "trusted autonomous scope is audited separately from human approval"
     (and (eq (plist-get result :status) 'ok)
          (eq (plist-get (plist-get result :authorization) :source)
              'autonomous-scope)
          (= (length calls) 1))))
  (setq calls nil)
  (let* ((policy
          (nl-agent-permission-policy-new
           :mode 'off
           :hard-deny (lambda (_request) "immutable safety floor")))
         (result
          (nl-agent-permission-call
           policy registry "shell" '(:command "date"))))
    (nl-agent-runtime-test--ck
     "hard-deny cannot be bypassed by permission mode off"
     (and (eq (plist-get result :status) 'denied)
          (eq (plist-get (plist-get result :authorization) :source)
              'hard-deny)
          (null calls))))
  (let ((approvals 0))
    (let ((policy
           (nl-agent-permission-policy-new
            :mode 'manual
            :approval
            (lambda (_request)
              (setq approvals (1+ approvals))
              'session))))
      (nl-agent-permission-call policy registry "shell" '(:command "pwd"))
      (let ((second
             (nl-agent-permission-call
              policy registry "shell" '(:command "pwd"))))
        (nl-agent-runtime-test--ck
         "session approval is cached only for the exact call"
         (and (= approvals 1)
              (eq (plist-get second :status) 'ok)
              (eq (plist-get
                   (plist-get second :authorization) :source)
                  'session))))))
  (let ((approvals 0))
    (let ((policy
           (nl-agent-permission-policy-new
            :mode 'manual :unattended t
            :approval
            (lambda (_request)
              (setq approvals (1+ approvals))
              'once))))
      (let ((result
             (nl-agent-permission-call
              policy registry "read" '(:path "x"))))
        (nl-agent-runtime-test--ck
         "unattended execution denies instead of prompting"
         (and (eq (plist-get result :status) 'denied)
              (eq (plist-get (plist-get result :authorization) :source)
                  'unattended)
              (= approvals 0)))))))

(let* ((tool-calls nil)
       (registry (nl-agent-tool-registry-new))
       (policy
        (nl-agent-permission-policy-new
         :mode 'smart :approval (lambda (_request) 'once)))
       (service
        (nl-agent-runtime-test--service
         '("```sh\nprintf ready\n```" "DONE task complete"))))
  (nl-agent-tool-register
   registry
   (nl-agent-tool-new
    "shell"
    (lambda (args context)
      (setq tool-calls
            (append tool-calls (list (list args context))))
      "[exit 0]\nready")
    :description "Run a shell command" :risk 'execute))
  (let* ((result
          (nl-agent-runtime-run
           service registry policy "check readiness" :max-steps 4))
         (trajectory (plist-get result :trajectory))
         (first (car trajectory)))
    (nl-agent-runtime-test--ck
     "runtime completes a model-tool-observation-model episode"
     (and (eq (plist-get result :status) 'done)
          (equal (plist-get result :result) "task complete")
          (= (plist-get result :steps) 2)))
    (nl-agent-runtime-test--ck
     "runtime dispatches parsed action through the permission boundary"
     (and (= (length tool-calls) 1)
          (equal (plist-get (caar tool-calls) :command) "printf ready")
          (eq (plist-get
               (plist-get (plist-get first :tool-result) :authorization)
               :source)
              'approval)))
    (nl-agent-runtime-test--ck
     "runtime feeds the tool observation back into service history"
     (cl-find-if
      (lambda (message)
        (and (eq (car message) 'user)
             (string-match-p "\\[exit 0\\]" (cdr message))))
      (plist-get result :messages)))
    (nl-agent-runtime-test--ck
     "trajectory retains model, action, and observation for later curation"
     (and (= (length trajectory) 2)
          (equal (plist-get first :model) "scripted/model")
          (equal (plist-get first :action)
                 '(shell "printf ready"))
          (string-match-p "ready" (plist-get first :observation))))))

(let* ((requests (list nil))
       (invoked nil)
       (registry (nl-agent-tool-registry-new))
       (policy (nl-agent-permission-policy-new :mode 'smart))
       (service
        (nl-agent-runtime-test--service
         '("```sh\necho forbidden\n```" "DONE used another path")
         requests)))
  (nl-agent-tool-register
   registry
   (nl-agent-tool-new
    "shell" (lambda (_args _context) (setq invoked t) "bad")
    :risk 'execute))
  (let ((result
         (nl-agent-runtime-run
          service registry policy "stay safe" :max-steps 3)))
    (nl-agent-runtime-test--ck
     "denied action is not invoked and the model can recover"
     (and (eq (plist-get result :status) 'done) (not invoked)))
    (nl-agent-runtime-test--ck
     "denial becomes the next model observation"
     (let ((second-request (cadr (car requests))))
       (cl-find-if
        (lambda (message)
          (and (eq (car message) 'user)
               (string-match-p "DENIED" (cdr message))))
        second-request)))))

(let* ((registry (nl-agent-tool-registry-new))
       (policy (nl-agent-permission-policy-new :mode 'smart))
       (service
        (nl-agent-runtime-test--service
         '("I need to think." "Still thinking.")))
       (result
        (nl-agent-runtime-run
         service registry policy "bounded task" :max-steps 2)))
  (nl-agent-runtime-test--ck
   "runtime stops deterministically at the configured step limit"
   (and (eq (plist-get result :status) 'limit)
        (= (plist-get result :steps) 2)
        (= (length (plist-get result :trajectory)) 2))))

(princ (format "NL-AGENT-RUNTIME %s (%d failures)\n"
               (if (= nl-agent-runtime-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-runtime-test--fail))
(kill-emacs (if (= nl-agent-runtime-test--fail 0) 0 1))

;;; runtime-test.el ends here
