;;; semantic-eval-test.el --- semantic evaluation harness tests -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-semantic-eval)
(require 'nl-agent-host)
(require 'nl-llm-agent-provider)

(defconst nl-agent-semantic-eval-test--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Semantic evaluation project root for tests.")

(defconst nl-agent-semantic-eval-test--corpus
  (expand-file-name "examples/semantic-eval-corpus.sexp"
                    nl-agent-semantic-eval-test--root))

(defun nl-agent-semantic-eval-test--renderer ()
  "Return a renderer fixture whose provider is never contacted by stubs."
  (let* ((provider
          (nl-llm-agent-provider-new
           "fixture" :models '("model")
           :open (lambda (_model _options) nil)
           :complete (lambda (_state _messages) "unused")
           :close (lambda (_state) nil)))
         (router (nl-agent-host-router-new (list provider))))
    (nl-agent-semantic-render-new
     router "fixture/model" '("fixture/model"))))

(defun nl-agent-semantic-eval-test--write-temp (text)
  "Write TEXT to a temporary corpus file and return its path."
  (let ((path (make-temp-file "semantic-eval-corpus-" nil ".sexp")))
    (with-temp-file path
      (insert text))
    path))

(ert-deftest nl-agent-semantic-eval-loads-and-verifies-all-irs-first ()
  (let ((corpus (nl-agent-semantic-eval-load-corpus
                 nl-agent-semantic-eval-test--corpus)))
    (should (= 6 (length (plist-get corpus :cases))))
    (should (string-match-p "\\`[0-9a-f]+\\'" (plist-get corpus :hash)))
    (should (equal (mapcar (lambda (case) (plist-get case :id))
                           (plist-get corpus :cases))
                   '("schedule" "measurements" "negation" "procedure"
                     "concise" "quoted-instruction"))))
  (let ((path (nl-agent-semantic-eval-test--write-temp
               "(:version 1 :cases ((:id \"ok\" :ir \"(task :version 1 :id \\\"ok\\\" :plan (render :language ja :claims ((claim :id \\\"c\\\" :text \\\"x\\\"))) :constraints (:allow-new-claims nil :max-chars 10))\" :required (\"x\") :forbidden ()) (:id \"bad\" :ir \"#.(error \\\"must not evaluate\\\")\" :required () :forbidden ()))")))
    (unwind-protect
        (should-error (nl-agent-semantic-eval-load-corpus path)
                      :type 'nl-agent-semantic-eval-error)
      (delete-file path))))

(ert-deftest nl-agent-semantic-eval-rejects-unsafe-and-trailing-data ()
  (dolist (text '("(:version 1 :cases ())\n(:version 1 :cases ())"
                  "(:version 1 :cases #.(error \\\"no\\\"))"
                  "(:version 1 :cases ((:id \"x\" :ir \"bad\" :required () :forbidden ())))"))
    (let ((path (nl-agent-semantic-eval-test--write-temp text)))
      (unwind-protect
          (should-error (nl-agent-semantic-eval-load-corpus path))
        (delete-file path)))))

(ert-deftest nl-agent-semantic-eval-baseline-has-no-provider-calls ()
  (let ((calls 0)
        (corpus (nl-agent-semantic-eval-load-corpus
                 nl-agent-semantic-eval-test--corpus)))
    (cl-letf (((symbol-function 'nl-agent-semantic-render-run-with-repair)
               (lambda (&rest _args) (setq calls (1+ calls))))
              ((symbol-function 'nl-agent-semantic-render-run)
               (lambda (&rest _args) (setq calls (1+ calls)))))
      (let* ((report (nl-agent-semantic-eval-run corpus))
             (totals (plist-get report :totals)))
        (should (= calls 0))
        (should (= (plist-get totals :total) 6))
        (should (= (plist-get totals :ok) 5))
        (should (= (plist-get totals :failed) 1))
        (should (= (plist-get totals :screened-cases) 5))
        (should (= (plist-get totals :screening-unavailable-cases) 1))
        (let ((concise (nth 4 (plist-get report :cases))))
          (should (eq (plist-get concise :status) 'failed))
          (should (= (plist-get (plist-get concise :constraints)
                               :actual-chars)
                     29)))))))

(ert-deftest nl-agent-semantic-eval-screens-literal-proxies-only ()
  (let* ((renderer (nl-agent-semantic-eval-test--renderer))
         (corpus (nl-agent-semantic-eval-load-corpus
                  nl-agent-semantic-eval-test--corpus)))
    (cl-letf (((symbol-function 'nl-agent-semantic-render-run-with-repair)
               (lambda (_renderer ir _attempts)
                 (list :status 'needs-review
                       :semantic-validation 'unverified
                       :attempts 1
                       :text (if (string-match-p "negation" ir)
                                 "未定だが有料です。"
                               "短い出力")))))
      (let* ((report (nl-agent-semantic-eval-run corpus renderer))
             (negation (nth 2 (plist-get report :cases)))
             (totals (plist-get report :totals)))
        (should (equal (plist-get negation :missing-required) '("無料")))
        (should (equal (plist-get negation :found-forbidden) '("有料")))
        (should (eq (plist-get negation :semantic-review) 'unreviewed))
        (should (= (plist-get totals :required-miss-cases) 6))
        (should (= (plist-get totals :forbidden-hit-cases) 1))))))

(ert-deftest nl-agent-semantic-eval-repair-attempts-and-provider-failure-count ()
  (let* ((renderer (nl-agent-semantic-eval-test--renderer))
         (corpus (nl-agent-semantic-eval-load-corpus
                  nl-agent-semantic-eval-test--corpus))
         (calls 0))
    (cl-letf (((symbol-function 'nl-agent-semantic-render-run-with-repair)
               (lambda (_renderer _ir attempts)
                 (setq calls (1+ calls))
                 (if (= calls 1)
                     (list :status 'provider-failure
                           :error-code 'provider-request-failed
                           :attempts attempts)
                   (list :status 'needs-review
                         :semantic-validation 'unverified
                         :attempts attempts
                         :text "回復した出力")))))
      (let ((report (nl-agent-semantic-eval-run corpus renderer :attempts 2)))
        (should (= calls 6))
        (should (= (plist-get (plist-get report :totals) :total) 6))
        (should (= (plist-get (plist-get report :totals) :rendered-usable) 5))
        (should (= (plist-get (car (plist-get report :cases)) :attempts) 2))
        (should (= 5 (length (cl-remove-if-not
                              (lambda (case) (plist-member case :text))
                              (plist-get report :cases)))))))))

(ert-deftest nl-agent-semantic-eval-provider-failure-and-timing-are-bounded ()
  (let* ((renderer (nl-agent-semantic-eval-test--renderer))
         (corpus (nl-agent-semantic-eval-load-corpus
                  nl-agent-semantic-eval-test--corpus)))
    (cl-letf (((symbol-function 'nl-agent-semantic-render-run-with-repair)
               (lambda (&rest _args)
                 (list :status 'provider-failure
                       :error-code 'provider-request-failed
                       :attempts 0))))
      (let ((report (nl-agent-semantic-eval-run corpus renderer)))
        (should (= (plist-get (plist-get report :totals) :rendered-failures) 6))
        (should (>= (plist-get report :elapsed-seconds) 0.0))
        (dolist (case (plist-get report :cases))
          (should (>= (plist-get case :elapsed-seconds) 0.0))
          (should (eq (plist-get case :screening-status) 'unavailable)))))))

(ert-deftest nl-agent-semantic-eval-reports-policy-and-repair-history ()
  (let* ((renderer (nl-agent-semantic-eval-test--renderer))
         (corpus (nl-agent-semantic-eval-load-corpus
                  nl-agent-semantic-eval-test--corpus)))
    (cl-letf (((symbol-function 'nl-agent-semantic-render-run-with-repair)
               (lambda (&rest _args)
                 ;; The repair implementation owns this transition; this
                 ;; fixture checks that evaluation records it without scoring
                 ;; the semantic result.
                 (list :status 'needs-review
                       :semantic-validation 'unverified
                       :attempts 2
                       :repair-history
                       '((:error-code output-numeric-mismatch
                          :repair-request
                          (repair-request :version 1
                                          :task "schedule"
                                          :constraint numeric-preservation)))
                       :text "説明会は10月12日です。開始時刻は14時です。"))))
      (let* ((report (nl-agent-semantic-eval-run corpus renderer :attempts 2))
             (renderer-info (plist-get report :renderer))
             (first (car (plist-get report :cases)))
             (rendered (plist-get first :rendered)))
        (should (equal (plist-get renderer-info :policy-version)
                       (or nl-agent-semantic-render-policy-version
                           nl-agent-semantic-eval-default-policy-version)))
        (should (= (plist-get rendered :attempts) 2))
        (should (equal (plist-get rendered :repair-history)
                       '((:error-code output-numeric-mismatch
                          :repair-request
                          (repair-request :version 1
                                          :task "schedule"
                                          :constraint numeric-preservation)))))))))

(ert-deftest nl-agent-semantic-eval-unversioned-renderer-is-not-current-policy ()
  (let* ((renderer (nl-agent-semantic-eval-test--renderer))
         (corpus (nl-agent-semantic-eval-load-corpus
                  nl-agent-semantic-eval-test--corpus))
         (nl-agent-semantic-render-policy-version nil))
    (cl-letf (((symbol-function 'nl-agent-semantic-render-run-with-repair)
               (lambda (&rest _args)
                 (list :status 'needs-review
                       :semantic-validation 'unverified
                       :attempts 1
                       :text "検証用出力"))))
      (should (equal
               (plist-get (plist-get (nl-agent-semantic-eval-run
                                      corpus renderer)
                                     :renderer)
                          :policy-version)
               "legacy-unversioned")))))

(ert-deftest nl-agent-semantic-eval-telemetry-aggregate-marks-missing-attempts ()
  (let* ((renderer (nl-agent-semantic-eval-test--renderer))
         (corpus (nl-agent-semantic-eval-load-corpus
                  nl-agent-semantic-eval-test--corpus))
         (calls 0))
    (cl-letf (((symbol-function 'nl-agent-semantic-render-run-with-repair)
               (lambda (&rest _args)
                 (setq calls (1+ calls))
                 (if (= calls 1)
                     (list :status 'provider-failure :attempts 2
                           :attempt-metrics
                           '((:request-content-utf8-bytes 10
                              :output-utf8-bytes nil :elapsed-seconds 0.1
                              :outcome failed)
                             (:request-content-utf8-bytes 12
                              :output-utf8-bytes 4 :elapsed-seconds 0.2
                              :outcome accepted)))
                   (list :status 'provider-failure :attempts 1)))))
      (let* ((report (nl-agent-semantic-eval-run corpus renderer :attempts 2))
             (telemetry (plist-get report :telemetry)))
        (should (eq (plist-get telemetry :status) 'partial))
        (should (= (plist-get telemetry :attempts) 7))
        (should (= (plist-get telemetry :measured-attempts) 2))
        (should-not (plist-get telemetry :request-content-utf8-bytes))
        (should (= (plist-get telemetry :measured-request-content-utf8-bytes)
                   22))
        (should-not (plist-get telemetry :output-utf8-bytes))))))

(ert-deftest nl-agent-semantic-eval-serialization-retains-japanese-cases ()
  (let* ((corpus (nl-agent-semantic-eval-load-corpus
                  nl-agent-semantic-eval-test--corpus))
         (report (nl-agent-semantic-eval-run corpus))
         (json-text (nl-agent-semantic-eval-report-json report))
         (decoded (json-parse-string json-text :object-type 'alist))
         (result (alist-get 'result decoded))
         (cases (alist-get 'cases result)))
    (should (equal (alist-get 'id decoded) "semantic-evaluation"))
    (should (eq (alist-get 'ok decoded) t))
    (should (string-match-p "quoted-instruction" json-text))
    (should (string-match-p "説明会"
                            (alist-get 'text (aref cases 0))))))

(ert-run-tests-batch-and-exit)

;;; semantic-eval-test.el ends here
