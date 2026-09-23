;;; semantic-render-test.el --- host semantic renderer tests -*- lexical-binding: t; -*-

(require 'ert)
(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-semantic-render)
(load (expand-file-name "examples/semantic-render-example.el") nil nil t)

(defconst nl-agent-semantic-render-test--ir
  "(task :version 1 :id \"render-demo\" :plan
  (render :language ja :claims
    ((claim :id \"c1\" :text \"第一の主張です。\")
     (claim :id \"c2\" :text \"第二の主張です。\")))
  :constraints (:allow-new-claims nil :max-chars 80))")

(defvar nl-agent-semantic-render-test--response nil)
(defvar nl-agent-semantic-render-test--calls nil)
(defvar nl-agent-semantic-render-test--opens nil)
(defvar nl-agent-semantic-render-test--closes nil)

(defun nl-agent-semantic-render-test--fixture (response)
  "Return a renderer fixture with mutable call/open/close cells."
  (setq nl-agent-semantic-render-test--response response
        nl-agent-semantic-render-test--calls (list nil)
        nl-agent-semantic-render-test--opens (list nil)
        nl-agent-semantic-render-test--closes (list nil))
  (let ((provider
         (nl-llm-agent-provider-new
          "local" :models '("model")
          :open (lambda (model options)
                  (setcar nl-agent-semantic-render-test--opens
                          (append (car nl-agent-semantic-render-test--opens)
                                  (list (list model (copy-tree options)))))
                  (list :model model :options (copy-tree options)))
          :complete (lambda (state messages)
                      (setcar nl-agent-semantic-render-test--calls
                              (append (car nl-agent-semantic-render-test--calls)
                                      (list (list state (copy-tree messages)))))
                      (if (functionp nl-agent-semantic-render-test--response)
                          (funcall nl-agent-semantic-render-test--response
                                   state messages)
                        nl-agent-semantic-render-test--response))
          :close (lambda (state)
                   (setcar nl-agent-semantic-render-test--closes
                           (append (car nl-agent-semantic-render-test--closes)
                                   (list state))))))
        (registry (nl-llm-agent-provider-registry-new)))
    (nl-llm-agent-provider-register registry provider)
    (list :renderer
          (nl-agent-semantic-render-new
           (nl-agent-host-router-new registry) "local/model" '("local/model"))
          :calls nl-agent-semantic-render-test--calls
          :opens nl-agent-semantic-render-test--opens
          :closes nl-agent-semantic-render-test--closes)))

(defun nl-agent-semantic-render-test--renderer (fixture)
  (plist-get fixture :renderer))

(ert-deftest nl-agent-semantic-render-success-is-review-required ()
  (let* ((fixture (nl-agent-semantic-render-test--fixture "生成された日本語です。"))
         (renderer (nl-agent-semantic-render-test--renderer fixture))
         (result (nl-agent-semantic-render-run renderer
                                               nl-agent-semantic-render-test--ir))
         (call (car (car (plist-get fixture :calls))))
         (messages (cadr call))
         (open (car (car (plist-get fixture :opens)))))
    (should (eq (plist-get result :status) 'needs-review))
    (should (eq (plist-get result :semantic-validation) 'unverified))
    (should (equal (plist-get result :text) "生成された日本語です。"))
    (should (equal (plist-get result :claim-ids) '("c1" "c2")))
    (should (equal (plist-get result :task) "render-demo"))
    (should (= (length messages) 2))
    (should (eq (car (car messages)) 'system))
    (should (eq (car (cadr messages)) 'user))
    (should-not (string-match-p "第一の主張です" (cdr (car messages))))
    (should (string-match-p "第一の主張です" (cdr (cadr messages))))
    (should (equal (car open) "model"))
    (should (equal (plist-get (cadr open) :temperature) 0.2))
    (should (equal (plist-get (cadr open) :max_tokens) 512))
    (should (= (length (car (plist-get fixture :closes))) 1))))

(ert-deftest nl-agent-semantic-render-telemetry-counts-rejected-retry-and-unicode ()
  (let* ((responses (list "" "再試行後の日本語。"))
         (fixture (nl-agent-semantic-render-test--fixture
                   (lambda (_state _messages) (prog1 (pop responses)))))
         (result (nl-agent-semantic-render-run-with-repair
                  (nl-agent-semantic-render-test--renderer fixture)
                  nl-agent-semantic-render-test--ir 2))
         (metrics (plist-get result :attempt-metrics)))
    (should (eq (plist-get result :status) 'needs-review))
    (should (= (length metrics) 2))
    (should (eq (plist-get (nth 0 metrics) :outcome) 'rejected))
    (should (eq (plist-get (nth 1 metrics) :outcome) 'accepted))
    (should (= (plist-get (nth 1 metrics) :output-utf8-bytes)
               (string-bytes (encode-coding-string "再試行後の日本語。" 'utf-8 t))))
    (should (> (plist-get (nth 1 metrics) :request-content-utf8-bytes)
               (plist-get (nth 0 metrics) :request-content-utf8-bytes)))
    (should (eq (plist-get (plist-get (nth 0 metrics) :token-counts)
                           :status)
               'unavailable))
    (should (equal (plist-get result :text) "再試行後の日本語。"))))

(ert-deftest nl-agent-semantic-render-telemetry-failure-has-no-output-body ()
  (let* ((fixture (nl-agent-semantic-render-test--fixture
                   (lambda (_state _messages)
                     (error "private provider detail"))))
         (result (nl-agent-semantic-render-run-with-repair
                  (nl-agent-semantic-render-test--renderer fixture)
                  nl-agent-semantic-render-test--ir 1))
         (metric (car (plist-get result :attempt-metrics))))
    (should (eq (plist-get metric :outcome) 'failed))
    (should (integerp (plist-get metric :request-content-utf8-bytes)))
    (should-not (plist-get metric :output-utf8-bytes))
    (should-not (string-match-p "private" (format "%S" result)))))

(ert-deftest nl-agent-semantic-render-pre-inference-rejection-has-zero-attempts ()
  (let* ((fixture (nl-agent-semantic-render-test--fixture "unused"))
         (result (nl-agent-semantic-render-run-with-repair
                  (nl-agent-semantic-render-test--renderer fixture)
                  "invalid" 2)))
    (should (= (plist-get result :attempts) 0))
    (should-not (plist-get result :attempt-metrics))))

(ert-deftest nl-agent-semantic-render-selector-is-fixed-before-inference ()
  (let* ((fixture (nl-agent-semantic-render-test--fixture "unused"))
         (renderer (nl-agent-semantic-render-test--renderer fixture)))
    (should-error
     (nl-agent-semantic-render-new
      (nl-agent-semantic-renderer-router renderer) "remote/model"
      '("local/model")))
    (setf (nl-agent-semantic-renderer-selector renderer) "remote/model")
    (let ((result (nl-agent-semantic-render-run
                   renderer nl-agent-semantic-render-test--ir)))
      (should (eq (plist-get result :status) 'configuration-failure))
      (should (eq (plist-get result :error-code) 'selector-not-allowlisted))
      (should-not (car (plist-get fixture :calls))))))

(ert-deftest nl-agent-semantic-render-parse-fails-before-provider ()
  (let* ((fixture (nl-agent-semantic-render-test--fixture "unused"))
         (result (nl-agent-semantic-render-run
                  (nl-agent-semantic-render-test--renderer fixture)
                  "#.(error \"must not run\")")))
    (should (eq (plist-get result :status) 'validation-failure))
    (should (eq (plist-get result :error-code) 'invalid-ir))
    (should-not (car (plist-get fixture :calls)))
    (should-not (car (plist-get fixture :opens)))))

(ert-deftest nl-agent-semantic-render-output-failures-are-compact-and-cleaned ()
  (let* ((fixture (nl-agent-semantic-render-test--fixture (make-string 81 ?あ)))
         (renderer (nl-agent-semantic-render-test--renderer fixture))
         (result (nl-agent-semantic-render-run renderer
                                               nl-agent-semantic-render-test--ir)))
    (should (eq (plist-get result :status) 'validation-failure))
    (should (eq (plist-get result :error-code) 'output-character-limit))
    (should-not (plist-member result :text))
    (should-not (plist-member result :claim-ids))
    (should (= (length (car (plist-get fixture :closes))) 1)))
  (let* ((fixture (nl-agent-semantic-render-test--fixture " \n"))
         (renderer (nl-agent-semantic-render-test--renderer fixture))
         (result (nl-agent-semantic-render-run renderer
                                               nl-agent-semantic-render-test--ir)))
    (should (eq (plist-get result :error-code) 'output-empty))
    (should (= (length (car (plist-get fixture :closes))) 1)))
  (let* ((fixture (nl-agent-semantic-render-test--fixture "あ"))
         (renderer (nl-agent-semantic-render-test--renderer fixture)))
    (setf (nl-agent-semantic-renderer-max-output-bytes renderer) 2)
    (let ((result (nl-agent-semantic-render-run
                   renderer nl-agent-semantic-render-test--ir)))
      (should (eq (plist-get result :error-code) 'output-byte-limit))
      (should-not (plist-member result :text))
      (should (= (length (car (plist-get fixture :closes))) 1)))))

(ert-deftest nl-agent-semantic-render-provider-failure-is-sanitized ()
  (let* ((fixture
          (nl-agent-semantic-render-test--fixture
           (lambda (_state _messages) (error "secret prompt and credential"))))
         (result (nl-agent-semantic-render-run
                  (nl-agent-semantic-render-test--renderer fixture)
                  nl-agent-semantic-render-test--ir)))
    (should (eq (plist-get result :status) 'provider-failure))
    (should (eq (plist-get result :error-code) 'provider-request-failed))
    (should-not (plist-member result :text))
    (should-not (string-match-p "secret" (format "%S" result)))
    (should (= (length (car (plist-get fixture :closes))) 1))))

(ert-deftest nl-agent-semantic-render-calls-are-isolated ()
  (let* ((fixture (nl-agent-semantic-render-test--fixture "one"))
         (renderer (nl-agent-semantic-render-test--renderer fixture)))
    (nl-agent-semantic-render-run renderer nl-agent-semantic-render-test--ir)
    (nl-agent-semantic-render-run renderer nl-agent-semantic-render-test--ir)
    (should (= (length (car (plist-get fixture :calls))) 2))
    (dolist (call (car (plist-get fixture :calls)))
      (should (= (length (cadr call)) 2)))))

(ert-deftest nl-agent-semantic-render-quit-still-closes-session ()
  (let* ((fixture
          (nl-agent-semantic-render-test--fixture
           (lambda (_state _messages) (signal 'quit nil))))
         (renderer (nl-agent-semantic-render-test--renderer fixture))
         (caught nil))
    (condition-case nil
        (nl-agent-semantic-render-run
         renderer nl-agent-semantic-render-test--ir)
      (quit (setq caught t)))
    (should caught)
    (should (= (length (car (plist-get fixture :closes))) 1))))

(ert-deftest nl-agent-semantic-render-tool-validates-args-and-permission ()
  (let* ((fixture (nl-agent-semantic-render-test--fixture "unused"))
         (renderer (nl-agent-semantic-render-test--renderer fixture))
         (registry (nl-agent-tool-registry-new))
         (policy (nl-agent-permission-policy-new :mode 'smart)))
    (nl-agent-semantic-render-register-tool registry renderer)
    (let ((denied
           (nl-agent-permission-call
            policy registry "semantic.render"
            (list :ir nl-agent-semantic-render-test--ir))))
      (should (eq (plist-get denied :status) 'denied))
      (should-not (car (plist-get fixture :calls))))
    (let ((malformed
           (nl-agent-permission-call
            (nl-agent-permission-policy-new :mode 'off)
            registry "semantic.render"
            (list :ir nl-agent-semantic-render-test--ir :model "remote"))))
      (should (eq (plist-get malformed :status) 'error))
      (should-not (car (plist-get fixture :calls))))
    (let ((print-length 2)
          (print-level 2)
          (allowed (nl-agent-permission-policy-new :mode 'off)))
      (let ((serialized
             (plist-get
              (nl-agent-permission-call
               allowed registry "semantic.render"
               (list :ir nl-agent-semantic-render-test--ir))
              :text)))
        (should (string-match-p ":claim-ids" serialized))))))

(ert-deftest nl-agent-semantic-render-approved-host-broker-call ()
  (let* ((fixture (nl-agent-semantic-render-test--fixture "broker result"))
         (renderer (nl-agent-semantic-render-test--renderer fixture))
         (registry (nl-agent-tool-registry-new))
         (policy (nl-agent-permission-policy-new
                  :mode 'smart :approval (lambda (_request) 'once))))
    (nl-agent-semantic-render-register-tool registry renderer)
    (let* ((dispatch (nl-agent-host-tool-function registry policy))
           (observation
            (funcall dispatch
                     (list :event 'tool :tool "semantic.render"
                           :args (list :ir nl-agent-semantic-render-test--ir)
                           :context '(:source "test"))))
           (result (car (read-from-string observation))))
      (should (eq (plist-get result :status) 'needs-review))
      (should (eq (plist-get result :semantic-validation) 'unverified))
      (should (= (length (car (plist-get fixture :calls))) 1)))))

(ert-deftest nl-agent-semantic-render-example-validates-loopback-authority ()
  (dolist (url '("http://127.0.0.1:11434/v1"
                 "https://localhost/v1"
                 "http://[::1]:11434/v1"))
    (should (nl-agent-semantic-render-example--loopback-url-p url)))
  (dolist (url '("http://localhost.evil.test/v1"
                 "http://127.0.0.1.evil.test/v1"
                 "http://127.0.0.1@evil.test/v1"
                 "http://user@localhost/v1"
                 "http://example.com/v1"))
    (should-not (nl-agent-semantic-render-example--loopback-url-p url))))

(ert-run-tests-batch-and-exit)
