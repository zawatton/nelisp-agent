;;; semantic-repair-test.el --- bounded semantic renderer repair tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'nl-agent-semantic-render)

(defconst nl-agent-semantic-repair-test--ir
  "(task :version 1 :id \"repair-demo\" :plan
  (render :language ja :claims
    ((claim :id \"c1\" :text \"元の主張を保持します。\")))
  :constraints (:allow-new-claims nil :max-chars 10))")

(defvar nl-agent-semantic-repair-test--queue nil)
(defvar nl-agent-semantic-repair-test--calls nil)
(defvar nl-agent-semantic-repair-test--opens nil)
(defvar nl-agent-semantic-repair-test--closes nil)
(defvar nl-agent-semantic-repair-test--renderer nil)

(defun nl-agent-semantic-repair-test--fixture (responses)
  (setq nl-agent-semantic-repair-test--queue (copy-sequence responses)
        nl-agent-semantic-repair-test--calls nil
        nl-agent-semantic-repair-test--opens nil
        nl-agent-semantic-repair-test--closes nil)
  (let* ((provider
          (nl-llm-agent-provider-new
           "local" :models '("model")
           :open (lambda (model options)
                   (setq nl-agent-semantic-repair-test--opens
                         (append nl-agent-semantic-repair-test--opens
                                 (list (list model (copy-tree options)))))
                   (list :model model :options (copy-tree options)))
           :complete
           (lambda (state messages)
             (setq nl-agent-semantic-repair-test--calls
                   (append nl-agent-semantic-repair-test--calls
                           (list (list state (copy-tree messages)))))
             (let ((response (if nl-agent-semantic-repair-test--queue
                                 (pop nl-agent-semantic-repair-test--queue)
                               "")))
               (if (functionp response)
                   (funcall response state messages)
                 response)))
           :close
           (lambda (state)
             (setq nl-agent-semantic-repair-test--closes
                   (append nl-agent-semantic-repair-test--closes
                           (list state))))))
         (registry (nl-llm-agent-provider-registry-new)))
    (nl-llm-agent-provider-register registry provider)
    (setq nl-agent-semantic-repair-test--renderer
          (nl-agent-semantic-render-new
           (nl-agent-host-router-new registry)
           "local/model" '("local/model")))
    nl-agent-semantic-repair-test--renderer))

(defun nl-agent-semantic-repair-test--user (call)
  (cdr (cadr (cadr call))))

(ert-deftest nl-agent-semantic-render-repair-recovers-with-bounded-history ()
  (let ((renderer
         (nl-agent-semantic-repair-test--fixture '(
           ""
           "短い文章"))))
    (let ((result (nl-agent-semantic-render-run-with-repair
                   renderer nl-agent-semantic-repair-test--ir)))
      (should (eq (plist-get result :status) 'needs-review))
      (should (eq (plist-get result :semantic-validation) 'unverified))
      (should (= (plist-get result :attempts) 2))
      (should (= (length (plist-get result :repair-history)) 1))
      (should (eq (plist-get (car (plist-get result :repair-history))
                            :error-code)
                  'output-empty))
      (should (= (length nl-agent-semantic-repair-test--calls) 2))
      (should (= (length nl-agent-semantic-repair-test--closes) 2))
      (let ((repair-prompt
             (nl-agent-semantic-repair-test--user
              (cadr nl-agent-semantic-repair-test--calls))))
        (should (string-match-p "error-code=output-empty" repair-prompt))
        (should (string-match-p "constraint=min-nonempty-chars" repair-prompt))
        (should (string-match-p "expected=1 actual=0" repair-prompt))))))

(ert-deftest nl-agent-semantic-render-repair-preserves-facts-and-no-body-leak ()
  (let ((renderer
         (nl-agent-semantic-repair-test--fixture
          (list "PREVIOUS BODY SECRET" "短い文章"))))
    (let ((result (nl-agent-semantic-render-run-with-repair
                   renderer nl-agent-semantic-repair-test--ir 2)))
      (should (eq (plist-get result :status) 'needs-review))
      (let ((second-user
             (nl-agent-semantic-repair-test--user
              (cadr nl-agent-semantic-repair-test--calls))))
        (should (string-match-p "元の主張を保持します" second-user))
        (should-not (string-match-p "PREVIOUS BODY SECRET" second-user))
        (should (string-match-p "Maximum output characters: 10"
                                second-user))))))

(ert-deftest nl-agent-semantic-render-repair-exhaustion-is-explicit ()
  (let ((renderer
         (nl-agent-semantic-repair-test--fixture
          (list (make-string 11 ?あ) (make-string 12 ?い)))))
    (let ((result (nl-agent-semantic-render-run-with-repair
                   renderer nl-agent-semantic-repair-test--ir 2)))
      (should (eq (plist-get result :status) 'validation-failure))
      (should (plist-get result :repair-exhausted))
      (should (= (plist-get result :attempts) 2))
      (should (= (length (plist-get result :repair-history)) 2))
      (should-not (plist-member result :text))
      (should-not (plist-member result :claim-ids))
      (should (= (length nl-agent-semantic-repair-test--calls) 2)))))

(ert-deftest nl-agent-semantic-render-repair-does-not-retry-nonrecoverable-results ()
  (let ((renderer
         (nl-agent-semantic-repair-test--fixture
          (list (lambda (_state _messages)
                  (error "provider secret"))))))
    (let ((result (nl-agent-semantic-render-run-with-repair
                   renderer nl-agent-semantic-repair-test--ir 3)))
      (should (eq (plist-get result :status) 'provider-failure))
      (should (= (plist-get result :attempts) 1))
      (should (= (length nl-agent-semantic-repair-test--calls) 1))))
  (let ((renderer (nl-agent-semantic-repair-test--fixture '("unused"))))
    (let ((result (nl-agent-semantic-render-run-with-repair
                   renderer "#.(error \"no\")" 3)))
      (should (eq (plist-get result :error-code) 'invalid-ir))
      (should (= (plist-get result :attempts) 0))
      (should-not (plist-get result :repair-history))
      (should-not nl-agent-semantic-repair-test--calls))))

(ert-deftest nl-agent-semantic-render-repair-does-not-retry-review-success ()
  (let ((renderer (nl-agent-semantic-repair-test--fixture '("短い文章"))))
    (let ((result (nl-agent-semantic-render-run-with-repair
                   renderer nl-agent-semantic-repair-test--ir 3)))
      (should (eq (plist-get result :status) 'needs-review))
      (should (= (plist-get result :attempts) 1))
      (should (= (length nl-agent-semantic-repair-test--calls) 1)))))

(ert-deftest nl-agent-semantic-render-repair-recovers-byte-limit ()
  (let ((renderer (nl-agent-semantic-repair-test--fixture '("あ" "ok"))))
    (setf (nl-agent-semantic-renderer-max-output-bytes renderer) 2)
    (let ((result (nl-agent-semantic-render-run-with-repair
                   renderer nl-agent-semantic-repair-test--ir 2)))
      (should (eq (plist-get result :status) 'needs-review))
      (should (= (plist-get result :attempts) 2))
      (should (eq (plist-get (car (plist-get result :repair-history))
                            :error-code)
                  'output-byte-limit))
      (let ((repair-prompt
             (nl-agent-semantic-repair-test--user
              (cadr nl-agent-semantic-repair-test--calls))))
        (should (string-match-p "constraint=max-output-bytes" repair-prompt))
        (should (string-match-p "expected=2 actual=3" repair-prompt))))))

(ert-deftest nl-agent-semantic-render-repair-quit-still-closes-session ()
  (let ((renderer
         (nl-agent-semantic-repair-test--fixture
          (list (lambda (_state _messages) (signal 'quit nil)))))
        (caught nil))
    (condition-case nil
        (nl-agent-semantic-render-run-with-repair
         renderer nl-agent-semantic-repair-test--ir)
      (quit (setq caught t)))
    (should caught)
    (should (= (length nl-agent-semantic-repair-test--closes) 1))))

(ert-deftest nl-agent-semantic-render-repair-rechecks-selector-between-attempts ()
  (let ((renderer
         (nl-agent-semantic-repair-test--fixture
          (list (lambda (_state _messages)
                  (setf (nl-agent-semantic-renderer-selector
                         nl-agent-semantic-repair-test--renderer)
                        "another/model")
                  "")))))
    (setf (nl-agent-semantic-renderer-allowlist renderer)
          '("local/model" "another/model"))
    (let ((result (nl-agent-semantic-render-run-with-repair
                   renderer nl-agent-semantic-repair-test--ir 2)))
      (should (eq (plist-get result :status) 'configuration-failure))
      (should (eq (plist-get result :error-code) 'selector-not-allowlisted))
      (should (= (plist-get result :attempts) 1))
      (should (= (length nl-agent-semantic-repair-test--calls) 1)))))

(ert-deftest nl-agent-semantic-render-repair-attempt-limits-and-default-tool ()
  (let ((renderer (nl-agent-semantic-repair-test--fixture '("" "" ""))))
    (should-error
     (nl-agent-semantic-render-run-with-repair
      renderer nl-agent-semantic-repair-test--ir 0))
    (should-error
     (nl-agent-semantic-render-run-with-repair
      renderer nl-agent-semantic-repair-test--ir 4)))
  (let* ((renderer (nl-agent-semantic-repair-test--fixture '("" "修復後")))
         (tools (nl-agent-tool-registry-new))
         (policy (nl-agent-permission-policy-new :mode 'off)))
    (nl-agent-semantic-render-register-tool tools renderer)
    (let ((result
           (nl-agent-permission-call
            policy tools "semantic.render"
            (list :ir nl-agent-semantic-repair-test--ir))))
      (should (eq (plist-get result :status) 'ok))
      (should (= (length nl-agent-semantic-repair-test--calls) 1))
      (should-not (string-match-p ":attempts" (plist-get result :text))))))

(ert-deftest nl-agent-semantic-render-repair-tool-is-explicitly-opt-in ()
  (let* ((renderer (nl-agent-semantic-repair-test--fixture '("" "修復後")))
         (tools (nl-agent-tool-registry-new))
         (policy (nl-agent-permission-policy-new :mode 'off)))
    (nl-agent-semantic-render-register-tool tools renderer 2)
    (let ((result
           (nl-agent-permission-call
            policy tools "semantic.render"
            (list :ir nl-agent-semantic-repair-test--ir))))
      (should (eq (plist-get result :status) 'ok))
      (should (= (length nl-agent-semantic-repair-test--calls) 2))
      (should (string-match-p ":attempts 2" (plist-get result :text)))))
  (let ((renderer (nl-agent-semantic-repair-test--fixture '("ok")))
        (tools (nl-agent-tool-registry-new)))
    (should-error (nl-agent-semantic-render-register-tool tools renderer 0))
    (should-error (nl-agent-semantic-render-register-tool tools renderer 4))))

(ert-run-tests-batch-and-exit)
