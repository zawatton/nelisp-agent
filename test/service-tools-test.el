;;; service-tools-test.el --- host-authorized live service controls  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-service-tools)
(require 'nl-agent-permission)
(require 'nl-agent-supervisor)

(defvar nl-agent-service-tools-test--fail 0)

(defun nl-agent-service-tools-test--ck (name ok &optional extra)
  (princ (format "%-72s %s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-service-tools-test--fail
                         (1+ nl-agent-service-tools-test--fail))
                   "FAIL")
                 (or extra ""))))

(defun nl-agent-service-tools-test--provider (id model complete)
  (nl-llm-agent-provider-new
   id :models (list model)
   :open (lambda (model-id _options) model-id)
   :complete complete))

(let* ((provider-registry (nl-llm-agent-provider-registry-new))
       (_remote
        (nl-llm-agent-provider-register
         provider-registry
         (nl-agent-service-tools-test--provider
          "remote" "model"
          (lambda (_state _messages)
            (concat
             "```tool\n"
             "(:name \"service.model.switch\" "
             ":arguments (:selector \"native/champion-g1\"))\n"
             "```")))))
       (_native
        (nl-llm-agent-provider-register
         provider-registry
         (nl-agent-service-tools-test--provider
          "native" "champion-g1"
          (lambda (_state _messages) "DONE activated generation"))))
       (router (nl-agent-host-router-new provider-registry))
       (tools (nl-agent-tool-registry-new))
       (smart (nl-agent-permission-policy-new :mode 'smart))
       (trusted (nl-agent-permission-policy-new :mode 'off))
       (project-directory default-directory)
       (nelisp
        (expand-file-name "../nelisp/target/nelisp" project-directory))
       (fixture
        (expand-file-name
         "test/stdio-agent-worker-fixture.el" project-directory))
       (inference-providers nil)
       (supervisor nil))
  (nl-agent-service-tools-register tools router)
  (let ((descriptor (car (nl-agent-tool-catalog tools))))
    (nl-agent-service-tools-test--ck
     "model switch is published as a write-risk host service directive"
     (and (equal (plist-get descriptor :name) "service.model.switch")
          (eq (plist-get descriptor :risk) 'write)
          (eq (plist-get (plist-get descriptor :metadata)
                         :service-operation)
              'model-switch)
          (not (plist-member descriptor :invoke-fn)))))
  (let ((denied
         (nl-agent-permission-call
          smart tools "service.model.switch"
          '(:selector "native/champion-g1"))))
    (nl-agent-service-tools-test--ck
     "model output cannot activate a generation without host approval"
     (eq (plist-get denied :status) 'denied)))
  (let ((missing
         (nl-agent-permission-call
          trusted tools "service.model.switch"
          '(:selector "native/missing"))))
    (nl-agent-service-tools-test--ck
     "host rejects activation of a model absent from its live catalog"
     (eq (plist-get missing :status) 'error)))
  (unwind-protect
      (progn
        (setq supervisor
              (nl-agent-supervisor-new
               (list nelisp "--load" fixture)
               :directory project-directory :await-ready t
               :max-requests 20 :timeout-sec 5
               :model-catalog
               (nl-agent-host-model-catalog-function router)
               :inference
               (lambda (event)
                 (setq inference-providers
                       (append
                        inference-providers
                        (list (plist-get event :provider))))
                 (funcall (nl-agent-host-inference-function router) event))
               :tool (nl-agent-host-tool-function tools trusted)
               :tool-catalog (nl-agent-host-tool-catalog-function tools)))
        (nl-agent-supervisor-call supervisor '(status))
        (let* ((worker (nl-agent-supervisor-process supervisor))
               (result
                (nl-agent-supervisor-call
                 supervisor '(run "activate the promoted generation")))
               (status (nl-agent-supervisor-call supervisor '(status)))
               (first-event (car (plist-get result :trajectory)))
               (tool-result (plist-get first-event :tool-result)))
          (let ((ok
                 (and (eq worker (nl-agent-supervisor-process supervisor))
                      (eq (plist-get result :status) 'done)
                      (equal (plist-get result :result) "activated generation")
                      (equal (plist-get status :model) "native/champion-g1")
                      (equal inference-providers '("remote" "native"))
                      (eq (plist-get tool-result :service-operation)
                          'model-switch)
                      (equal (plist-get tool-result :model)
                             "native/champion-g1"))))
            (nl-agent-service-tools-test--ck
             "authorized standalone directive switches in place before next inference"
             ok
             (unless ok
               (format "same-worker=%S result=%S status=%S providers=%S tool=%S"
                       (eq worker (nl-agent-supervisor-process supervisor))
                       result status inference-providers tool-result))))))
    (when supervisor (nl-agent-supervisor-stop supervisor))))

(princ (format "NL-AGENT-SERVICE-TOOLS %s (%d failures)\n"
               (if (= nl-agent-service-tools-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-service-tools-test--fail))
(kill-emacs (if (= nl-agent-service-tools-test--fail 0) 0 1))

;;; service-tools-test.el ends here
