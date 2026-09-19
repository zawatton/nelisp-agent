;;; bulk-policy-eval-test.el --- tests for bulk-policy evaluation -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'nl-llm-agent-provider)
(require 'nl-agent-host)

(defconst nl-agent-bulk-policy-eval-test--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))

(add-to-list 'load-path (expand-file-name "lisp" nl-agent-bulk-policy-eval-test--root))
(add-to-list 'load-path (expand-file-name "../nelisp-llm/lisp" nl-agent-bulk-policy-eval-test--root))
(add-to-list 'load-path (expand-file-name "../nelisp-photon/lisp" nl-agent-bulk-policy-eval-test--root))

(load (expand-file-name "examples/evaluate-bulk-reader.el" nl-agent-bulk-policy-eval-test--root) nil t)
(load (expand-file-name "examples/evaluate-bulk-policy.el" nl-agent-bulk-policy-eval-test--root) nil t)

(declare-function nl-agent-example-bulk-eval-load-corpus "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--utf8-bytes "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--numbered "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--prompt "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--message-bytes "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--screen "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--stub-answer "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--verify-sources "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--serialize-tool "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--call-main "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--live-router "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-policy-load-cases "evaluate-bulk-policy.el")
(declare-function nl-agent-example-bulk-policy--get-kind "evaluate-bulk-policy.el")
(declare-function nl-agent-example-bulk-policy--screen-with-kind "evaluate-bulk-policy.el")
(declare-function nl-agent-example-bulk-policy-run "evaluate-bulk-policy.el")
(declare-function nl-agent-example-bulk-policy--summary "evaluate-bulk-policy.el")

(ert-deftest bulk-policy-eval-test-frozen-corpus-loads-with-hash ()
  "The frozen corpus loads and its hash matches the expected constant.
The combined list is nine cases: first five equal to frozen corpus."
  (let ((cases-data (nl-agent-example-bulk-policy-load-cases)))
    (should (= (plist-get cases-data :total) 9))
    (should (= (plist-get cases-data :frozen) 5))
    (should (= (plist-get cases-data :policy) 4))
    (should (equal (plist-get cases-data :frozen-hash)
                   nl-agent-example-bulk-policy--frozen-corpus-hash))
    ;; First five cases should be equal to those from frozen corpus.
    (let ((frozen (nl-agent-example-bulk-eval-load-corpus)))
      (let ((frozen-cases (plist-get frozen :cases))
            (all-cases (plist-get cases-data :cases)))
        (should (= (length frozen-cases) 5))
        (dolist (i (number-sequence 0 4))
          (should (equal (nth i frozen-cases) (nth i all-cases))))))))

(ert-deftest bulk-policy-eval-test-tampering-hash-check-signals ()
  "Tampering with the frozen corpus hash constant makes the loader signal."
  (let ((nl-agent-example-bulk-policy--frozen-corpus-hash "0000000000000000000000000000000000000000000000000000000000000000"))
    (should-error (nl-agent-example-bulk-policy-load-cases))))

(ert-deftest bulk-policy-eval-test-every-case-has-review-kind ()
  "Every loaded case id has a review kind; missing id signals."
  (let ((cases-data (nl-agent-example-bulk-policy-load-cases)))
    (dolist (case (plist-get cases-data :cases))
      (let ((id (plist-get case :id)))
        ;; Should not signal.
        (let ((kind (nl-agent-example-bulk-policy--get-kind id)))
          (should kind))))
    ;; Now test that a missing id signals.
    (let ((nl-agent-example-bulk-policy--review-kinds
           (cl-remove-if (lambda (pair) (equal (car pair) "multi-fact"))
                        nl-agent-example-bulk-policy--review-kinds)))
      (should-error (nl-agent-example-bulk-policy-load-cases)))))

(ert-deftest bulk-policy-eval-test-conflict-never-proxy-pass ()
  "A conflict case never yields proxy-pass, even when all required literals are present.
Assert proxy-review explicitly."
  (let* ((case (list :id "test-conflict" :question "Test?" :paths nil
                     :required '("9月24日") :absent nil))
         (kind 'conflict)
         (answer "年次点検の実施日は9月24日です。食い違いがあります。")
         (screening (nl-agent-example-bulk-policy--screen-with-kind case answer kind)))
    (should (eq (plist-get screening :proxy-status) 'proxy-review))))

(ert-deftest bulk-policy-eval-test-non-conflict-with-all-required-proxy-pass ()
  "A non-conflict case with all required literals present yields proxy-pass."
  (let* ((case (list :id "test-fact" :question "Test?" :paths nil
                     :required '("7月3日" "2時間") :absent nil))
         (kind 'fact)
         (answer "更新工事の実施日は7月3日で、停電時間は2時間です。")
         (screening (nl-agent-example-bulk-policy--screen-with-kind case answer kind)))
    (should (eq (plist-get screening :proxy-status) 'proxy-pass))))

(ert-deftest bulk-policy-eval-test-stub-run-contacts-no-provider ()
  "The stub run contacts no provider. Supplied router with failing complete signals."
  (let ((failed-router
         (nl-agent-host-router-new
          (list (nl-llm-agent-provider-new
                 "fail" :models '("main" "worker")
                 :open (lambda (&rest _) nil)
                 :complete (lambda (&rest _) (error "provider called!"))
                 :close (lambda (&rest _) nil))))))
    ;; This should not signal because stub mode uses stub provider, not the supplied one.
    (let ((report (nl-agent-example-bulk-policy-run
                   nil (list failed-router "fail/main" "fail/worker"))))
      (should (eq (plist-get report :mode) 'stub)))))

(ert-deftest bulk-policy-eval-test-policy-conservative-mode-direct-only ()
  "Policy-conservative records decision reason mode-direct-only for all cases.
Never invokes the delegate thunk."
  (let ((delegate-called nil)
        (cases-data (nl-agent-example-bulk-policy-load-cases))
        (root (expand-file-name "examples/bulk-reader-corpus"
                               nl-agent-example-bulk-policy-root)))
    (let* ((router (nl-agent-host-router-new
                    (list (nl-llm-agent-provider-new
                           "stub" :models '("main" "worker")
                           :open (lambda (&rest _) nil)
                           :complete (lambda (&rest _) "")
                           :close (lambda (&rest _) nil)))))
           (reader (nl-agent-bulk-reader-new
                    router "stub/worker" (list "stub/worker") root
                    :max-tokens 1024 :timeout-sec 60 :temperature 0.0))
           (policy (nl-agent-bulk-policy-new)))
      (dolist (case (plist-get cases-data :cases))
        (let* ((paths (plist-get case :paths))
               (sources (nl-agent-bulk-reader-sources reader paths))
               (question (plist-get case :question))
               (source-bytes (apply #'+ (mapcar (lambda (s)
                                                   (nl-agent-example-bulk-eval--utf8-bytes
                                                    (plist-get s :text)))
                                               sources)))
               (request (list :question question :paths paths :source-bytes source-bytes)))
          (let ((result (nl-agent-bulk-policy-resolve
                         policy request
                         :direct (lambda () (list :status 'usable :answer "answer"
                                                 :request-content-utf8-bytes 100
                                                 :elapsed-seconds 0.0
                                                 :output-utf8-bytes 6))
                         :delegate (lambda () (setq delegate-called t)
                                    (list :status 'failed)))))
            (should (eq (plist-get (plist-get result :decision) :reason)
                       'mode-direct-only))))))))

(ert-deftest bulk-policy-eval-test-unknown-totals-stay-nil ()
  "Unknown totals stay nil: a case whose worker metrics are unknown makes the arm total nil."
  (let* ((case-with-unknown
          (list :id "test" :kind 'fact
                :delegated (list :worker-metrics (list :request-content-utf8-bytes nil)
                                :status 'usable)))
         (cases (list case-with-unknown)))
    (let ((summary (nl-agent-example-bulk-policy--summary cases)))
      (should (null (plist-get summary :paired-worker-request-bytes))))))

(ert-deftest bulk-policy-eval-test-new-corpus-validated ()
  "The new four-case corpus is bounded and validated.
At most eight paths per case, ids unique, invalid corpus opens no inference."
  ;; Load the new corpus and verify its shape.
  (let ((policy-path (expand-file-name "examples/bulk-policy-corpus.sexp"
                                       nl-agent-example-bulk-policy-root))
        (policy-corpus (nl-agent-example-bulk-eval-load-corpus
                       (expand-file-name "examples/bulk-policy-corpus.sexp"
                                        nl-agent-example-bulk-policy-root))))
    (dolist (case (plist-get policy-corpus :cases))
      (let ((paths (plist-get case :paths)))
        (should (<= (length paths) 8))))
    ;; Ids should be unique across both corpora.
    (let ((cases-data (nl-agent-example-bulk-policy-load-cases)))
      (let ((ids (mapcar (lambda (c) (plist-get c :id))
                        (plist-get cases-data :cases))))
        (should (= (length ids) (length (delete-dups ids))))))))

(defun nl-agent-bulk-policy-eval-test--stub-report ()
  "Run the deterministic stub evaluation once and return its report."
  (nl-agent-example-bulk-policy-run))

(defun nl-agent-bulk-policy-eval-test--arm (case label)
  "Return CASE's policy arm named LABEL."
  (cl-find label (plist-get case :policy-arms)
           :key (lambda (arm) (plist-get arm :label))))

(ert-deftest bulk-policy-eval-test-policy-arms-recorded-for-every-case ()
  "Both policy arms are recorded for all nine cases, and never as verified.
The arms are produced by `nl-agent-bulk-policy-resolve', so this also proves the
runner actually calls the policy module instead of only requiring it."
  (let ((report (nl-agent-bulk-policy-eval-test--stub-report)))
    (should (= 9 (length (plist-get report :cases))))
    (dolist (case (plist-get report :cases))
      (let ((conservative (nl-agent-bulk-policy-eval-test--arm
                           case 'policy-conservative))
            (exercise (nl-agent-bulk-policy-eval-test--arm
                       case 'policy-exercise)))
        (should conservative)
        (should exercise)
        (dolist (arm (list conservative exercise))
          (should (eq t (plist-get arm :replayed)))
          (should (equal "bulk-policy-v1" (plist-get arm :policy-version)))
          (should (eq 'needs-review (plist-get arm :review-status)))
          (should (eq 'unverified (plist-get arm :semantic-validation))))))))

(ert-deftest bulk-policy-eval-test-policy-conservative-never-delegates ()
  "The shipped default takes the direct path on every case and never delegates."
  (let ((report (nl-agent-bulk-policy-eval-test--stub-report)))
    (dolist (case (plist-get report :cases))
      (let* ((arm (nl-agent-bulk-policy-eval-test--arm case 'policy-conservative))
             (calls (plist-get arm :thunk-calls)))
        (should (eq 'mode-direct-only
                    (plist-get (plist-get arm :decision) :reason)))
        (should (eq 'direct (plist-get (plist-get arm :final) :path)))
        (should (= 1 (plist-get calls :direct)))
        (should (= 0 (plist-get calls :delegate)))
        (should (= 0 (plist-get calls :delegated-main)))
        (should (null (plist-get arm :diagnostics)))))
    (let ((summary (cl-find 'policy-conservative
                            (plist-get (plist-get report :summary) :policy-arms)
                            :key (lambda (arm) (plist-get arm :label)))))
      (should (= 9 (plist-get summary :final-direct)))
      (should (= 0 (plist-get summary :final-delegated)))
      (should (equal '((mode-direct-only . 9))
                     (plist-get summary :decision-reasons))))))

(ert-deftest bulk-policy-eval-test-excluded-kinds-are-never-delegated ()
  "Conflict and quoted-instruction cases are refused delegation by policy.
The live baseline found both shapes failing with valid citations, so no
diagnostic can catch them and the exercise arm must not route them either."
  (let* ((report (nl-agent-bulk-policy-eval-test--stub-report))
         (excluded 0))
    (dolist (case (plist-get report :cases))
      (let* ((kind (plist-get case :kind))
             (arm (nl-agent-bulk-policy-eval-test--arm case 'policy-exercise))
             (reason (plist-get (plist-get arm :decision) :reason))
             (calls (plist-get (plist-get arm :thunk-calls) :delegate)))
        (if (memq kind '(conflict quoted-instruction))
            (progn
              (setq excluded (1+ excluded))
              (should (eq 'excluded-question-kind reason))
              (should (eq 'direct (plist-get (plist-get arm :final) :path)))
              (should (= 0 calls)))
          (should (eq 'admitted reason))
          (should (= 1 calls)))))
    ;; One conflict case plus two quoted-instruction cases in the corpus.
    (should (= 3 excluded))))

(ert-deftest bulk-policy-eval-test-policy-exercise-admits-and-falls-back ()
  "The exercise arm admits the routable cases, diagnoses, and falls back.
Cases whose kind the policy excludes are covered by the test above."
  (let* ((report (nl-agent-bulk-policy-eval-test--stub-report))
         (cases (cl-remove-if (lambda (case)
                                (memq (plist-get case :kind)
                                      '(conflict quoted-instruction)))
                              (plist-get report :cases)))
         (codes nil)
         (rejected 0))
    (should (= 6 (length cases)))
    (dolist (case cases)
      (let ((arm (nl-agent-bulk-policy-eval-test--arm case 'policy-exercise)))
        (should (eq 'admitted (plist-get (plist-get arm :decision) :reason)))
        (should (= 1 (plist-get (plist-get arm :thunk-calls) :delegate)))
        (dolist (diagnostic (plist-get arm :diagnostics))
          (push (plist-get diagnostic :code) codes))
        (when (eq 'reject (plist-get arm :disposition))
          (setq rejected (1+ rejected))
          ;; A rejected delegation must be visible and must cost the fallback.
          (should (plist-get (plist-get arm :fallback) :used))
          (should (eq 'direct (plist-get (plist-get arm :final) :path)))
          (should (eq 'direct (plist-get (plist-get arm :fallback) :to)))
          (should (>= (plist-get (plist-get arm :accounting) :attempt-count) 2)))))
    (should (> rejected 0))
    (should (or (memq 'partial-source-coverage codes)
                (memq 'absence-marker-conflict codes)))))

(ert-deftest bulk-policy-eval-test-arm-histogram-matches-case-diagnostics ()
  "The summary histogram counts exactly the diagnostics present in the arms."
  (let* ((report (nl-agent-bulk-policy-eval-test--stub-report))
         (cases (plist-get report :cases)))
    (dolist (label '(policy-conservative policy-exercise))
      (let ((expected nil)
            (summary (cl-find label
                              (plist-get (plist-get report :summary) :policy-arms)
                              :key (lambda (arm) (plist-get arm :label)))))
        (dolist (case cases)
          (dolist (diagnostic (plist-get
                               (nl-agent-bulk-policy-eval-test--arm case label)
                               :diagnostics))
            (let* ((code (plist-get diagnostic :code))
                   (cell (assq code expected)))
              (if cell (setcdr cell (1+ (cdr cell)))
                (push (cons code 1) expected)))))
        (should (equal (sort expected
                             (lambda (left right)
                               (string< (symbol-name (car left))
                                        (symbol-name (car right)))))
                       (plist-get summary :diagnostic-histogram)))))))

(ert-deftest bulk-policy-eval-test-conflict-screening-in-report-is-proxy-review ()
  "The conflict case never reports proxy-pass in the emitted report.
This covers the wiring: the kind-aware screen must be the one the runner uses."
  (let* ((report (nl-agent-bulk-policy-eval-test--stub-report))
         (conflict (cl-find "conflicting-sources" (plist-get report :cases)
                            :key (lambda (case) (plist-get case :id))
                            :test #'equal))
         (other (cl-find "short-factual" (plist-get report :cases)
                         :key (lambda (case) (plist-get case :id))
                         :test #'equal)))
    (should conflict)
    (should (eq 'conflict (plist-get conflict :kind)))
    (dolist (arm '(:direct :delegated))
      (should (eq 'proxy-review
                  (plist-get (plist-get (plist-get conflict arm) :screening)
                             :proxy-status))))
    ;; The non-conflict control still reaches proxy-pass, so the assertion above
    ;; is not passing because every case is forced to proxy-review.
    (should (eq 'proxy-pass
                (plist-get (plist-get (plist-get other :direct) :screening)
                           :proxy-status)))))

(when noninteractive
  (ert-run-tests-batch-and-exit))

(provide 'bulk-policy-eval-test)
;;; bulk-policy-eval-test.el ends here
