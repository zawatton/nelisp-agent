;;; -*- lexical-binding: t -*-

(require 'cl-lib)
(require 'subr-x)
(require 'ert)
(require 'nl-agent-bulk-policy)

;; Helper to create a proper worker result fixture with nested :metrics plist
(defun nl-agent-bulk-policy-test--make-worker-fixture (request-bytes output-bytes elapsed-seconds &rest opts)
  "Create a worker result fixture with proper metrics nesting.
REQUEST-BYTES, OUTPUT-BYTES, and ELAPSED-SECONDS are metric values.
OPTS is a plist with optional keys: :status, :answer, :references, :not-found.
Returns a fixture with :metrics as a nested plist."
  (let ((status (plist-get opts :status))
        (answer (plist-get opts :answer))
        (references (plist-get opts :references))
        (not-found (plist-get opts :not-found)))
    (unless status (setq status 'needs-review))
    (unless answer (setq answer "answer"))
    (list :status status
          :semantic-validation 'unverified
          :answer answer
          :references references
          :not-found not-found
          :metrics (list :role 'bulk-reader
                         :policy-version "bulk-reader-v1"
                         :request-content-utf8-bytes request-bytes
                         :output-utf8-bytes output-bytes
                         :elapsed-seconds elapsed-seconds
                         :selector "local/worker"
                         :json-mode t
                         :token-counts (list :status 'unavailable :input nil :output nil)))))

;; Test 1: Direct-only mode rejects delegated path
(ert-deftest nl-agent-bulk-policy-test-direct-only-default ()
  (let ((policy (nl-agent-bulk-policy-new)))
    (let ((decision (nl-agent-bulk-policy-admit policy '(:question "q" :paths ("f.txt") :source-bytes 100))))
      (should (eq 'direct (plist-get decision :path)))
      (should (eq 'mode-direct-only (plist-get decision :reason))))))

;; Test 2: Too few source bytes
(ert-deftest nl-agent-bulk-policy-test-too-few-source-bytes ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 10000)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 100 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "answer"
                                       :request-content-utf8-bytes 100
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0)))))
      (should (eq 'too-few-source-bytes (plist-get (plist-get result :decision) :reason))))))

;; Test 3: Too many paths
(ert-deftest nl-agent-bulk-policy-test-too-many-paths ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :max-paths 1)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file1.txt" "file2.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "answer"
                                       :request-content-utf8-bytes 100
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0)))))
      (should (eq (plist-get (plist-get result :decision) :reason) 'too-many-paths)))))

;; Test 4: Question too large
(ert-deftest nl-agent-bulk-policy-test-question-too-large ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :max-question-bytes 10)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "this is a very long question" :paths ("file.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "answer"
                                       :request-content-utf8-bytes 100
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0)))))
      (should (eq (plist-get (plist-get result :decision) :reason) 'question-too-large)))))

;; Test 5: Admitted with delegated-main (STRENGTHENED)
(ert-deftest nl-agent-bulk-policy-test-admitted-with-main ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 100)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact
                     :sources ((:path "file.txt" :text "line\n")))
                   :direct (lambda () '(:status usable :answer "direct"
                                       :request-content-utf8-bytes 100
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0))
                   :delegate (lambda () (nl-agent-bulk-policy-test--make-worker-fixture
                                         200 100 2.0
                                         :status 'needs-review
                                         :answer "worker answer"
                                         :references (list (list :path "file.txt" :start-line 1 :end-line 1
                                                                 :sha256 (make-string 64 ?a)
                                                                 :text "line\n"))))
                   :delegated-main (lambda (_wr) '(:status usable :answer "main"
                                                  :request-content-utf8-bytes 300
                                                  :output-utf8-bytes 60
                                                  :elapsed-seconds 1.5)))))
      (should (eq 'accept-for-review (plist-get result :disposition)))
      (let ((acct (plist-get result :accounting)))
        (should (= 500 (plist-get acct :total-request-content-utf8-bytes)))
        (should (= 160 (plist-get acct :total-output-utf8-bytes)))
        (should (= 3.5 (plist-get acct :total-elapsed-seconds)))
        (should (equal '(delegated delegated) (plist-get acct :paths-taken)))
        (should (eq t (plist-get acct :includes-failed-attempts)))))))

;; Test 6: Worker fails with fallback (STRENGTHENED)
(ert-deftest nl-agent-bulk-policy-test-failed-worker-fallback ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 100 :fallback t)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "direct"
                                       :request-content-utf8-bytes 1000
                                       :output-utf8-bytes 100
                                       :elapsed-seconds 2.0))
                   :delegate (lambda () (nl-agent-bulk-policy-test--make-worker-fixture
                                         800 nil 1.0
                                         :status 'failed)))))
      (should (eq 'direct (plist-get (plist-get result :final) :path)))
      (should (= 2 (plist-get (plist-get result :accounting) :attempt-count)))
      (should (eq 'reject (plist-get result :disposition)))
      (should (cl-some (lambda (d) (and (eq (plist-get d :code) 'worker-failed)
                                        (eq (plist-get d :severity) 'reject)))
                       (plist-get result :diagnostics)))
      ;; The detail names how the worker failed, so a report does not lose the
      ;; reader's error code the way the qwen3:4b run did.
      (should (string-match-p "error-code"
                              (plist-get (cl-find 'worker-failed
                                                  (plist-get result :diagnostics)
                                                  :key (lambda (d) (plist-get d :code)))
                                         :detail)))
      (let ((acct (plist-get result :accounting)))
        (should (= 1800 (plist-get acct :total-request-content-utf8-bytes)))
        (should (null (plist-get acct :total-output-utf8-bytes)))
        (should (= 3.0 (plist-get acct :total-elapsed-seconds)))
        (should (equal '(delegated direct) (plist-get acct :paths-taken)))
        (should (eq t (plist-get acct :includes-failed-attempts)))))))

;; Test 7: Worker fails, no fallback
(ert-deftest nl-agent-bulk-policy-test-failed-worker-no-fallback ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 100 :fallback nil)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "direct"
                                       :request-content-utf8-bytes 1000
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0))
                   :delegate (lambda () (nl-agent-bulk-policy-test--make-worker-fixture
                                         200 nil 2.0
                                         :status 'failed)))))
      (should (<= (plist-get (plist-get result :accounting) :attempt-count)
                  nl-agent-bulk-policy-max-attempts)))))

;; Test 7b: delegated-main fails with fallback (STRENGTHENED)
(ert-deftest nl-agent-bulk-policy-test-delegated-main-failed-fallback ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 100 :fallback t)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact
                     :sources ((:path "file.txt" :text "line\n")))
                   :direct (lambda () '(:status usable :answer "direct answer"
                                       :request-content-utf8-bytes 500
                                       :output-utf8-bytes 100
                                       :elapsed-seconds 1.0))
                   :delegate (lambda () (nl-agent-bulk-policy-test--make-worker-fixture
                                         200 50 1.5
                                         :status 'needs-review
                                         :answer "worker answer"
                                         :references (list (list :path "file.txt" :start-line 1 :end-line 1
                                                                 :sha256 (make-string 64 ?a)
                                                                 :text "line\n"))))
                   :delegated-main (lambda (_wr) '(:status failed :answer nil
                                                  :request-content-utf8-bytes 300
                                                  :output-utf8-bytes 60
                                                  :elapsed-seconds 0.5)))))
      (should (eq 'direct (plist-get (plist-get result :final) :path)))
      (should (plist-get (plist-get result :fallback) :used))
      (should (eq 'delegated-main-failed (plist-get (plist-get result :fallback) :reason)))
      (let ((acct (plist-get result :accounting)))
        (should (= 3 (plist-get acct :attempt-count)))
        (should (= 1000 (plist-get acct :total-request-content-utf8-bytes)))
        (should (= 210 (plist-get acct :total-output-utf8-bytes)))
        (should (= 3.0 (plist-get acct :total-elapsed-seconds)))
        (should (equal '(delegated delegated direct) (plist-get acct :paths-taken)))
        (should (eq t (plist-get acct :includes-failed-attempts)))))))

;; Test 8: malformed reference missing :text
(ert-deftest nl-agent-bulk-policy-test-malformed-reference-missing-text ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 100)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "direct"
                                       :request-content-utf8-bytes 100
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0))
                   :delegate (lambda () '(:status needs-review :answer "worker answer"
                                         :references ((:path "file.txt" :start-line 1 :end-line 1
                                                      :sha256 (make-string 64 ?a)))
                                         :not-found nil
                                         :metrics (:request-content-utf8-bytes 200
                                                  :output-utf8-bytes 100
                                                  :elapsed-seconds 2.0))))))
      (should (cl-some (lambda (d) (eq (plist-get d :code) 'malformed-result))
                       (plist-get result :diagnostics)))
      (should (eq 'reject (plist-get result :disposition))))))

;; Test 9: malformed reference not a plist
(ert-deftest nl-agent-bulk-policy-test-malformed-reference-not-plist ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 100)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "direct"
                                       :request-content-utf8-bytes 100
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0))
                   :delegate (lambda () '(:status needs-review :answer "worker answer"
                                         :references ("not a plist")
                                         :not-found nil
                                         :metrics (:request-content-utf8-bytes 200
                                                  :output-utf8-bytes 100
                                                  :elapsed-seconds 2.0))))))
      (should (cl-some (lambda (d) (eq (plist-get d :code) 'malformed-result))
                       (plist-get result :diagnostics)))
      (should (eq 'reject (plist-get result :disposition))))))

;; RESTORED TESTS: Constructor and argument validation

;; Test 10: constructor-unknown-keyword
(ert-deftest nl-agent-bulk-policy-test-constructor-unknown-keyword ()
  (should-error (nl-agent-bulk-policy-new :mode 'opt-in :unknown-key 123)
                :type 'error))

;; Test 11: constructor-duplicate-keyword
(ert-deftest nl-agent-bulk-policy-test-constructor-duplicate-keyword ()
  (should-error (nl-agent-bulk-policy-new :mode 'opt-in :mode 'direct-only)
                :type 'error))

;; Test 12: constructor-odd-length
(ert-deftest nl-agent-bulk-policy-test-constructor-odd-length ()
  (should-error (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes)
                :type 'error))

;; Test 13: constructor-bad-mode
(ert-deftest nl-agent-bulk-policy-test-constructor-bad-mode ()
  (should-error (nl-agent-bulk-policy-new :mode 'invalid-mode)
                :type 'error))

;; Test 14: constructor-bad-min-source-bytes
(ert-deftest nl-agent-bulk-policy-test-constructor-bad-min-source-bytes ()
  (should-error (nl-agent-bulk-policy-new :min-source-bytes -1)
                :type 'error)
  (should-error (nl-agent-bulk-policy-new :min-source-bytes "not an int")
                :type 'error)
  (should-error (nl-agent-bulk-policy-new :min-source-bytes 131073)
                :type 'error))

;; Test 15: constructor-bad-max-paths
(ert-deftest nl-agent-bulk-policy-test-constructor-bad-max-paths ()
  (should-error (nl-agent-bulk-policy-new :max-paths 0)
                :type 'error)
  (should-error (nl-agent-bulk-policy-new :max-paths 9)
                :type 'error)
  (should-error (nl-agent-bulk-policy-new :max-paths "not an int")
                :type 'error))

;; Test 16: constructor-empty-absence-markers
(ert-deftest nl-agent-bulk-policy-test-constructor-empty-absence-markers ()
  (should-error (nl-agent-bulk-policy-new :absence-markers nil)
                :type 'error)
  (should-error (nl-agent-bulk-policy-new :absence-markers '())
                :type 'error)
  (should-error (nl-agent-bulk-policy-new :absence-markers '("valid" 123))
                :type 'error))

;; Test 17: request-wrong-keys
(ert-deftest nl-agent-bulk-policy-test-request-wrong-keys ()
  (let ((policy (nl-agent-bulk-policy-new)))
    ;; Missing key
    (should-error (nl-agent-bulk-policy-admit policy '(:question "q" :paths ("f.txt")))
                  :type 'error)
    ;; Extra key
    (should-error (nl-agent-bulk-policy-admit policy '(:question "q" :paths ("f.txt") :source-bytes 100 :extra "val"))
                  :type 'error)
    ;; Non-string question
    (should-error (nl-agent-bulk-policy-admit policy '(:question 123 :paths ("f.txt") :source-bytes 100))
                  :type 'error)
    ;; Empty paths
    (should-error (nl-agent-bulk-policy-admit policy '(:question "q" :paths () :source-bytes 100))
                  :type 'error)
    ;; Duplicated path
    (should-error (nl-agent-bulk-policy-admit policy '(:question "q" :paths ("f.txt" "f.txt") :source-bytes 100))
                  :type 'error)
    ;; Negative source-bytes
    (should-error (nl-agent-bulk-policy-admit policy '(:question "q" :paths ("f.txt") :source-bytes -1))
                  :type 'error)))

;; Test 18: resolve-non-function-direct
(ert-deftest nl-agent-bulk-policy-test-resolve-non-function-direct ()
  (let ((policy (nl-agent-bulk-policy-new)))
    ;; Missing :direct
    (should-error (nl-agent-bulk-policy-resolve policy '(:question "q" :paths ("f.txt") :source-bytes 100))
                  :type 'error)
    ;; :direct not a function
    (should-error (nl-agent-bulk-policy-resolve policy '(:question "q" :paths ("f.txt") :source-bytes 100)
                                                :direct 123)
                  :type 'error)))

;; DIAGNOSTIC TESTS

;; Test 19: partial-source-coverage
(ert-deftest nl-agent-bulk-policy-test-partial-source-coverage ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :max-paths 2)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file1.txt" "file2.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "answer"
                                       :request-content-utf8-bytes 100
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0))
                   :delegate (lambda () (nl-agent-bulk-policy-test--make-worker-fixture
                                         200 100 2.0
                                         :status 'needs-review
                                         :answer "found in file1"
                                         :references (list (list :path "file1.txt" :start-line 1 :end-line 1
                                                                 :sha256 (make-string 64 ?a)
                                                                 :text "content1")))))))
      (let ((diags (plist-get result :diagnostics)))
        (should (cl-some (lambda (d) (eq (plist-get d :code) 'partial-source-coverage)) diags))
        (should (cl-some (lambda (d) (and (eq (plist-get d :code) 'partial-source-coverage)
                                          (eq (plist-get d :severity) 'reject)
                                          (string-match-p "file2.txt" (plist-get d :detail)))) diags)))
      (should (eq 'reject (plist-get result :disposition))))))

;; Test 20: absence-marker-conflict
(ert-deftest nl-agent-bulk-policy-test-absence-marker-conflict ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "answer"
                                       :request-content-utf8-bytes 100
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0))
                   :delegate (lambda () (nl-agent-bulk-policy-test--make-worker-fixture
                                         200 100 2.0
                                         :status 'needs-review
                                         :answer "result"
                                         :not-found nil
                                         :references (list (list :path "file.txt" :start-line 5 :end-line 7
                                                                 :sha256 (make-string 64 ?b)
                                                                 :text "記載されていません")))))))
      (let ((diags (plist-get result :diagnostics)))
        (should (cl-some (lambda (d) (eq (plist-get d :code) 'absence-marker-conflict)) diags))
        (should (cl-some (lambda (d) (and (eq (plist-get d :code) 'absence-marker-conflict)
                                          (eq (plist-get d :severity) 'reject)
                                          (string-match-p "file.txt" (plist-get d :detail))
                                          (string-match-p "5" (plist-get d :detail))
                                          (string-match-p "7" (plist-get d :detail)))) diags)))
      (should (eq 'reject (plist-get result :disposition))))))

;; Test 21: absence-unevidenced
(ert-deftest nl-agent-bulk-policy-test-absence-unevidenced ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "answer"
                                       :request-content-utf8-bytes 100
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0))
                   :delegate (lambda () (nl-agent-bulk-policy-test--make-worker-fixture
                                         200 100 2.0
                                         :status 'needs-review
                                         :answer "not found"
                                         :not-found t
                                         :references nil)))))
      (let ((diags (plist-get result :diagnostics)))
        (should (= 1 (length diags)))
        (should (eq (plist-get (car diags) :code) 'absence-unevidenced))
        (should (eq (plist-get (car diags) :severity) 'note)))
      (should (eq 'accept-for-review (plist-get result :disposition))))))

;; Test 22: unsupported-numeral-note
(ert-deftest nl-agent-bulk-policy-test-unsupported-numeral-note ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact
                     :sources ((:path "file.txt" :text "line\n")))
                   :direct (lambda () '(:status usable :answer "answer"
                                       :request-content-utf8-bytes 100
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0))
                   :delegate (lambda () (nl-agent-bulk-policy-test--make-worker-fixture
                                         200 100 2.0
                                         :status 'needs-review
                                         :answer "The answer is 9999"
                                         :references (list (list :path "file.txt" :start-line 1 :end-line 1
                                                                 :sha256 (make-string 64 ?a)
                                                                 :text "found 1234")))))))
      (let ((diags (plist-get result :diagnostics)))
        (should (cl-some (lambda (d) (eq (plist-get d :code) 'unsupported-numeral)) diags)))
      (let ((num-diag (cl-find-if (lambda (d) (eq (plist-get d :code) 'unsupported-numeral))
                                   (plist-get result :diagnostics))))
        (should (eq (plist-get num-diag :severity) 'note)))
      (should (eq 'accept-for-review (plist-get result :disposition))))))

;; Test 23: unsupported-numeral-reject
(ert-deftest nl-agent-bulk-policy-test-unsupported-numeral-reject ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :numeral-screen 'reject)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "answer"
                                       :request-content-utf8-bytes 100
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0))
                   :delegate (lambda () (nl-agent-bulk-policy-test--make-worker-fixture
                                         200 100 2.0
                                         :status 'needs-review
                                         :answer "The answer is 9999"
                                         :references (list (list :path "file.txt" :start-line 1 :end-line 1
                                                                 :sha256 (make-string 64 ?a)
                                                                 :text "found 1234")))))))
      (let ((num-diag (cl-find-if (lambda (d) (eq (plist-get d :code) 'unsupported-numeral))
                                   (plist-get result :diagnostics))))
        (should (eq (plist-get num-diag :severity) 'reject)))
      (should (eq 'reject (plist-get result :disposition))))))

;; Test 24: fullwidth-digits
(ert-deftest nl-agent-bulk-policy-test-fullwidth-digits ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in)))
    ;; Test 1: fullwidth digit that appears in ASCII form in references
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "answer"
                                       :request-content-utf8-bytes 100
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0))
                   :delegate (lambda () (nl-agent-bulk-policy-test--make-worker-fixture
                                         200 100 2.0
                                         :status 'needs-review
                                         :answer "答え：１０４２"
                                         :references (list (list :path "file.txt" :start-line 1 :end-line 1
                                                                 :sha256 (make-string 64 ?a)
                                                                 :text "answer is 1042")))))))
      (should (not (cl-find-if (lambda (d) (eq (plist-get d :code) 'unsupported-numeral))
                               (plist-get result :diagnostics)))))
    ;; Test 2: fullwidth digit that does NOT appear anywhere
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "answer"
                                       :request-content-utf8-bytes 100
                                       :output-utf8-bytes 50
                                       :elapsed-seconds 1.0))
                   :delegate (lambda () (nl-agent-bulk-policy-test--make-worker-fixture
                                         200 100 2.0
                                         :status 'needs-review
                                         :answer "答え：５５５５"
                                         :references (list (list :path "file.txt" :start-line 1 :end-line 1
                                                                 :sha256 (make-string 64 ?a)
                                                                 :text "answer is 1042")))))))
      (should (cl-find-if (lambda (d) (eq (plist-get d :code) 'unsupported-numeral))
                          (plist-get result :diagnostics))))))

;; RESOLVE BEHAVIOUR TESTS

;; Test 25: attempt-count-bounded
(ert-deftest nl-agent-bulk-policy-test-attempt-count-bounded ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :fallback t)))
    (let ((attempt-count 0))
      (let ((result (nl-agent-bulk-policy-resolve
                     policy
                     '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact)
                     :direct (lambda () (setq attempt-count (1+ attempt-count))
                                       '(:status usable :answer "answer"
                                         :request-content-utf8-bytes 100
                                         :output-utf8-bytes 50
                                         :elapsed-seconds 1.0))
                     :delegate (lambda () (setq attempt-count (1+ attempt-count))
                                         (nl-agent-bulk-policy-test--make-worker-fixture
                                          200 100 2.0
                                          :status 'failed)))))
        (should (<= (plist-get (plist-get result :accounting) :attempt-count)
                    nl-agent-bulk-policy-max-attempts))
        (should (= (plist-get (plist-get result :accounting) :attempt-count)
                   (length (plist-get result :attempts))))))))

;; Test 26: direct-thunk-signals
(ert-deftest nl-agent-bulk-policy-test-direct-thunk-signals ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () (error "Test error")))))
      ;; The error should be caught and recorded, not propagate
      (should (cl-some (lambda (attempt)
                         (eq (plist-get attempt :error-code) 'direct-failure))
                       (plist-get result :attempts))))))

;; Test 27: unknown-totals
(ert-deftest nl-agent-bulk-policy-test-unknown-totals ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("file.txt") :source-bytes 10000 :question-kind fact)
                   :direct (lambda () '(:status usable :answer "direct"
                                       :request-content-utf8-bytes 8000
                                       :output-utf8-bytes 500
                                       :elapsed-seconds 3.0))
                   :delegate (lambda () (nl-agent-bulk-policy-test--make-worker-fixture
                                         nil nil nil
                                         :status 'needs-review
                                         :answer "worker"
                                         :references (list (list :path "file.txt" :start-line 1 :end-line 1
                                                                 :sha256 (make-string 64 ?a)
                                                                 :text "content")))))))
      (let ((acct (plist-get result :accounting)))
        ;; When worker has nil metrics, totals should be nil, not zero or partial sum
        (should (null (plist-get acct :total-request-content-utf8-bytes)))
        (should (null (plist-get acct :total-output-utf8-bytes)))
        (should (null (plist-get acct :total-elapsed-seconds)))))))

;; Tests 29-35: question kinds excluded from delegation by policy.
;;
;; The live baseline in docs/bulk-policy.md found two delegated failures that no
;; diagnostic can detect, because the citations were valid and only the
;; inference was wrong.  The policy therefore refuses to route those kinds at
;; all, and refuses to route a question the caller has not classified.

(defun nl-agent-bulk-policy-test--counting-delegate (counter)
  "Return a delegate thunk that increments COUNTER's car when invoked."
  (lambda ()
    (setcar counter (1+ (car counter)))
    (nl-agent-bulk-policy-test--make-worker-fixture 200 100 2.0)))

(ert-deftest nl-agent-bulk-policy-test-excluded-question-kind-conflict ()
  "A conflict-resolution question is never delegated, and the worker is not run."
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0))
        (calls (list 0)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "どちらが有効ですか" :paths ("a.txt")
                     :source-bytes 10000 :question-kind conflict)
                   :direct (lambda () '(:status usable :answer "direct"
                                        :request-content-utf8-bytes 100
                                        :output-utf8-bytes 50
                                        :elapsed-seconds 1.0))
                   :delegate (nl-agent-bulk-policy-test--counting-delegate calls))))
      (should (eq 'excluded-question-kind
                  (plist-get (plist-get result :decision) :reason)))
      (should (eq 'direct (plist-get (plist-get result :decision) :path)))
      (should (eq 'direct (plist-get (plist-get result :final) :path)))
      (should (string-match-p "conflict"
                              (plist-get (plist-get result :decision) :detail)))
      (should (= 0 (car calls)))
      (should (null (plist-get result :diagnostics))))))

(ert-deftest nl-agent-bulk-policy-test-excluded-question-kind-quoted-instruction ()
  "A question about a quoted instruction is never delegated."
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0))
        (calls (list 0)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "指示に従うべきですか" :paths ("a.txt")
                     :source-bytes 10000 :question-kind quoted-instruction)
                   :direct (lambda () '(:status usable :answer "direct"
                                        :request-content-utf8-bytes 100
                                        :output-utf8-bytes 50
                                        :elapsed-seconds 1.0))
                   :delegate (nl-agent-bulk-policy-test--counting-delegate calls))))
      (should (eq 'excluded-question-kind
                  (plist-get (plist-get result :decision) :reason)))
      (should (= 0 (car calls))))))

(ert-deftest nl-agent-bulk-policy-test-question-kind-unknown-blocks-delegation ()
  "An unclassified question is not assumed safe: delegation requires a kind."
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0))
        (calls (list 0)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("a.txt") :source-bytes 10000)
                   :direct (lambda () '(:status usable :answer "direct"
                                        :request-content-utf8-bytes 100
                                        :output-utf8-bytes 50
                                        :elapsed-seconds 1.0))
                   :delegate (nl-agent-bulk-policy-test--counting-delegate calls))))
      (should (eq 'question-kind-unknown
                  (plist-get (plist-get result :decision) :reason)))
      (should (= 0 (car calls))))))

(ert-deftest nl-agent-bulk-policy-test-require-question-kind-nil-admits-unclassified ()
  "A host may opt out of the classification requirement explicitly."
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0
                                          :require-question-kind nil))
        (calls (list 0)))
    (let ((result (nl-agent-bulk-policy-resolve
                   policy
                   '(:question "test" :paths ("a.txt") :source-bytes 10000)
                   :direct (lambda () '(:status usable :answer "direct"
                                        :request-content-utf8-bytes 100
                                        :output-utf8-bytes 50
                                        :elapsed-seconds 1.0))
                   :delegate (nl-agent-bulk-policy-test--counting-delegate calls))))
      (should (eq 'admitted (plist-get (plist-get result :decision) :reason)))
      (should (= 1 (car calls))))))

(ert-deftest nl-agent-bulk-policy-test-excluded-question-kinds-are-configurable ()
  "The exclusion list is read from the policy, not hardcoded in the check."
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0
                                          :excluded-question-kinds '(fact))))
    (should (eq 'excluded-question-kind
                (plist-get (nl-agent-bulk-policy-admit
                            policy '(:question "q" :paths ("a.txt")
                                     :source-bytes 10000 :question-kind fact))
                           :reason)))
    ;; With `fact' excluded instead, a conflict question is now admitted, which
    ;; would be impossible if the default list were consulted directly.
    (should (eq 'admitted
                (plist-get (nl-agent-bulk-policy-admit
                            policy '(:question "q" :paths ("a.txt")
                                     :source-bytes 10000 :question-kind conflict))
                           :reason)))))

(ert-deftest nl-agent-bulk-policy-test-mode-is-checked-before-question-kind ()
  "Admission order is fixed: mode outranks the kind exclusion."
  (let ((policy (nl-agent-bulk-policy-new)))
    (should (eq 'mode-direct-only
                (plist-get (nl-agent-bulk-policy-admit
                            policy '(:question "q" :paths ("a.txt")
                                     :source-bytes 10000 :question-kind conflict))
                           :reason)))))

(ert-deftest nl-agent-bulk-policy-test-question-kind-option-validation ()
  "The new constructor options and the request kind are validated strictly."
  (should-error (nl-agent-bulk-policy-new :excluded-question-kinds 'conflict))
  (should-error (nl-agent-bulk-policy-new :excluded-question-kinds '(:conflict)))
  (should-error (nl-agent-bulk-policy-new :excluded-question-kinds '(nil)))
  (should-error (nl-agent-bulk-policy-new :require-question-kind 'yes))
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0)))
    (should-error (nl-agent-bulk-policy-admit
                   policy '(:question "q" :paths ("a.txt") :source-bytes 10
                            :question-kind :conflict)))
    (should-error (nl-agent-bulk-policy-admit
                   policy '(:question "q" :paths ("a.txt") :source-bytes 10
                            :question-kind "conflict")))))

;; Tests 36-42: absence screening beyond the cited excerpts.
;;
;; The worker comparison in docs/bulk-policy.md showed the cited-excerpt check
;; being evaded by a narrower citation, and rejecting correct absence answers
;; because a correct answer necessarily cites the line stating the absence.
;; These tests pin both directions with the observed fixtures.

(defconst nl-agent-bulk-policy-test--absence-source
  '((:path "absent.txt"
     :text "代表メモ\n代表電話は 06-1234-5678 です。\n携帯電話番号はこの資料には記載されていません。\n"))
  "The source snapshot for the absence fixtures, as the host reads it.")

(defun nl-agent-bulk-policy-test--absence-request (&rest extra)
  "An absence-question request, with EXTRA appended to the plist."
  (append (list :question "携帯電話番号を答えてください"
                :paths '("absent.txt") :source-bytes 10000 :question-kind 'fact)
          extra))

(defun nl-agent-bulk-policy-test--absence-worker (answer cited-text)
  "A worker result answering ANSWER while citing CITED-TEXT."
  (nl-agent-bulk-policy-test--make-worker-fixture
   200 100 2.0
   :status 'needs-review :answer answer
   :references (list (list :path "absent.txt" :start-line 2 :end-line 3
                           :sha256 (make-string 64 ?a) :text cited-text))))

(ert-deftest nl-agent-bulk-policy-test-absence-conflict-still-caught-when-cited ()
  "The observed baseline failure: the worker cites the absence and denies it."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--absence-request
                 :sources nl-agent-bulk-policy-test--absence-source)
                (nl-agent-bulk-policy-test--absence-worker
                 "06-1234-5678です。"
                 "代表電話は 06-1234-5678 です。\n携帯電話番号はこの資料には記載されていません。"))))
    (should (eq 'reject (plist-get diag :disposition)))
    (should (cl-some (lambda (d) (eq (plist-get d :code) 'absence-marker-conflict))
                     (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-absence-conflict-caught-when-cited-narrowly ()
  "The observed worker-comparison miss: a narrower citation must not evade it.
The answer denies an absence the sources state, but the cited excerpt omits the
line that states it, so only the source-wide screen can see the conflict."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--absence-request
                 :sources nl-agent-bulk-policy-test--absence-source)
                (nl-agent-bulk-policy-test--absence-worker
                 "代表電話の 06-1234-5678 が責任者の携帯電話番号です。"
                 "代表電話は 06-1234-5678 です。"))))
    (should (eq 'reject (plist-get diag :disposition)))
    (should (cl-some (lambda (d) (eq (plist-get d :code) 'uncited-absence-marker))
                     (plist-get diag :diagnostics)))
    (should-not (cl-some (lambda (d) (eq (plist-get d :code) 'absence-marker-conflict))
                         (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-correct-absence-answer-is-not-rejected ()
  "A correct absence answer cites the absence line and must not be rejected.
This removes the false positive both live runs produced on absent-field."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--absence-request
                 :sources nl-agent-bulk-policy-test--absence-source)
                (nl-agent-bulk-policy-test--absence-worker
                 "携帯電話番号はこの資料には記載されていません。"
                 "携帯電話番号はこの資料には記載されていません。"))))
    (should (eq 'accept-for-review (plist-get diag :disposition)))
    (should-not (cl-some (lambda (d) (memq (plist-get d :code)
                                           '(absence-marker-conflict
                                             uncited-absence-marker)))
                         (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-uncited-absence-screen-can-be-a-note ()
  "A host may downgrade the source-wide screen without turning it off."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0
                                           :uncited-absence-screen 'note))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--absence-request
                 :sources nl-agent-bulk-policy-test--absence-source)
                (nl-agent-bulk-policy-test--absence-worker
                 "代表電話の 06-1234-5678 が責任者の携帯電話番号です。"
                 "代表電話は 06-1234-5678 です。"))))
    (should (eq 'accept-for-review (plist-get diag :disposition)))
    (should (cl-some (lambda (d) (and (eq (plist-get d :code) 'uncited-absence-marker)
                                      (eq (plist-get d :severity) 'note)))
                     (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-uncited-absence-screen-off-is-explicit ()
  "Turning the screen off is a configuration choice, and then nothing fires."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0
                                           :uncited-absence-screen nil))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--absence-request)
                (nl-agent-bulk-policy-test--absence-worker
                 "代表電話の 06-1234-5678 が責任者の携帯電話番号です。"
                 "代表電話は 06-1234-5678 です。"))))
    (should (eq 'accept-for-review (plist-get diag :disposition)))
    (should-not (cl-some (lambda (d) (memq (plist-get d :code)
                                           '(uncited-absence-marker
                                             absence-scope-unavailable)))
                         (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-enabled-screen-without-sources-rejects ()
  "A configured check that cannot run is a loud reject, never a silent skip."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--absence-request)
                (nl-agent-bulk-policy-test--absence-worker
                 "代表電話の 06-1234-5678 が責任者の携帯電話番号です。"
                 "代表電話は 06-1234-5678 です。"))))
    (should (eq 'reject (plist-get diag :disposition)))
    (should (cl-some (lambda (d) (eq (plist-get d :code) 'absence-scope-unavailable))
                     (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-sources-and-screen-validation ()
  "The new option and the new request key are validated strictly."
  (should-error (nl-agent-bulk-policy-new :uncited-absence-screen 'maybe))
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0)))
    (should-error (nl-agent-bulk-policy-admit
                   policy (nl-agent-bulk-policy-test--absence-request
                           :sources "not-a-list")))
    (should-error (nl-agent-bulk-policy-admit
                   policy (nl-agent-bulk-policy-test--absence-request
                           :sources '((:path "a.txt")))))
    (should-error (nl-agent-bulk-policy-admit
                   policy (nl-agent-bulk-policy-test--absence-request
                           :sources '((:path "" :text "x")))))))

;; Tests 43-48: coverage counting separates a missing fact from a missing
;; citation.  Both directions come from the recorded live runs on
;; multi-file-negation: llama3.2:3b dropped a fact and cited one file, while
;; hermes3:8b answered completely and still cited one file.

(defconst nl-agent-bulk-policy-test--multi-sources
  '((:path "project.txt" :text "プロジェクト日程\n搬入日は6月18日です。\n作業場所は東棟です。\n")
    (:path "rules.txt" :text "作業規則\n通常時間の作業は申請済みです。\n夜間作業は許可されていません。\n安全確認を先に行います。\n"))
  "The two-file snapshot behind the observed coverage cases.")

(defun nl-agent-bulk-policy-test--multi-request (&rest extra)
  (append (list :question "搬入日と夜間作業について答えてください"
                :paths '("project.txt" "rules.txt")
                :source-bytes 10000 :question-kind 'fact)
          extra))

(defun nl-agent-bulk-policy-test--multi-worker (answer cited-path cited-text)
  (nl-agent-bulk-policy-test--make-worker-fixture
   200 100 2.0
   :status 'needs-review :answer answer
   :references (list (list :path cited-path :start-line 2 :end-line 3
                           :sha256 (make-string 64 ?a) :text cited-text))))

(ert-deftest nl-agent-bulk-policy-test-coverage-still-rejects-a-missing-fact ()
  "The observed true positive: the answer drops a fact from the uncited file."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0 :max-paths 2))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--multi-request
                 :sources nl-agent-bulk-policy-test--multi-sources)
                (nl-agent-bulk-policy-test--multi-worker
                 "夜間作業は許可されていません。"
                 "rules.txt" "夜間作業は許可されていません。\n安全確認を先に行います。"))))
    (should (eq 'reject (plist-get diag :disposition)))
    (should (cl-some (lambda (d) (eq (plist-get d :code) 'partial-source-coverage))
                     (plist-get diag :diagnostics)))
    (should (string-match-p "project.txt"
                            (plist-get (cl-find 'partial-source-coverage
                                                (plist-get diag :diagnostics)
                                                :key (lambda (d) (plist-get d :code)))
                                       :detail)))))

(ert-deftest nl-agent-bulk-policy-test-coverage-accepts-a-complete-answer ()
  "The observed false positive: a complete answer that cited only one file.
The uncited file's wording appears verbatim in the answer, so the defect is the
citation, recorded as a note, not a missing fact."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0 :max-paths 2))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--multi-request
                 :sources nl-agent-bulk-policy-test--multi-sources)
                (nl-agent-bulk-policy-test--multi-worker
                 "搬入日は6月18日ですが、夜間作業は許可されていません。"
                 "project.txt" "搬入日は6月18日です。"))))
    (should (eq 'accept-for-review (plist-get diag :disposition)))
    (should-not (cl-some (lambda (d) (eq (plist-get d :code) 'partial-source-coverage))
                         (plist-get diag :diagnostics)))
    (should (cl-some (lambda (d) (and (eq (plist-get d :code) 'uncited-source-used)
                                      (eq (plist-get d :severity) 'note)))
                     (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-coverage-needs-a-long-shared-span ()
  "A short coincidental overlap is not evidence that the source was used.
Here the answer and the uncited file share 作業 only, which is well under the
default span, so the rejection stands."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0 :max-paths 2))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--multi-request
                 :sources nl-agent-bulk-policy-test--multi-sources)
                (nl-agent-bulk-policy-test--multi-worker
                 "作業について特筆事項はありません。"
                 "project.txt" "搬入日は6月18日です。"))))
    (should (eq 'reject (plist-get diag :disposition)))
    (should (cl-some (lambda (d) (eq (plist-get d :code) 'partial-source-coverage))
                     (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-coverage-exemption-can-be-disabled ()
  "Setting coverage-overlap-chars to nil restores strict coverage counting."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0 :max-paths 2
                                           :coverage-overlap-chars nil))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--multi-request
                 :sources nl-agent-bulk-policy-test--multi-sources)
                (nl-agent-bulk-policy-test--multi-worker
                 "搬入日は6月18日ですが、夜間作業は許可されていません。"
                 "project.txt" "搬入日は6月18日です。"))))
    (should (eq 'reject (plist-get diag :disposition)))
    (should (cl-some (lambda (d) (eq (plist-get d :code) 'partial-source-coverage))
                     (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-coverage-without-sources-stays-strict ()
  "With no snapshot there is no evidence, and the conservative reading wins."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0 :max-paths 2
                                           :uncited-absence-screen nil))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--multi-request)
                (nl-agent-bulk-policy-test--multi-worker
                 "搬入日は6月18日ですが、夜間作業は許可されていません。"
                 "project.txt" "搬入日は6月18日です。"))))
    (should (eq 'reject (plist-get diag :disposition)))
    (should (cl-some (lambda (d) (eq (plist-get d :code) 'partial-source-coverage))
                     (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-coverage-overlap-chars-validation ()
  (should-error (nl-agent-bulk-policy-new :coverage-overlap-chars 1))
  (should-error (nl-agent-bulk-policy-new :coverage-overlap-chars 257))
  (should-error (nl-agent-bulk-policy-new :coverage-overlap-chars "8"))
  (should (nl-agent-bulk-policy-p (nl-agent-bulk-policy-new :coverage-overlap-chars nil)))
  (should (nl-agent-bulk-policy-p (nl-agent-bulk-policy-new :coverage-overlap-chars 2))))

(when noninteractive
  (ert-run-tests-batch-and-exit))
