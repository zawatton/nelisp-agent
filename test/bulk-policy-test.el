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
                                           :uncited-absence-screen nil
                                           ;; The rival screens also need
                                           ;; sources; off here so this test
                                           ;; isolates the absence screen.
                                           :rival-value-screen nil
                                           :field-rival-screen nil))
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

;; Tests 49-55: the rival-value screen.
;;
;; The fixtures are the three conflict answers the recorded runs actually
;; produced, plus the correct answer that must not be flagged.  This is the
;; only screen aimed at a wrong answer whose citations are all genuine.

(defconst nl-agent-bulk-policy-test--rival-sources
  '((:path "a.txt" :text "作業手順書\n発行日: 2026年4月1日\n高圧受電盤の点検間隔は6か月です。\n")
    (:path "b.txt" :text "作業手順書\n発行日: 2026年9月1日\n高圧受電盤の点検間隔は12か月です。\n"))
  "Two dated procedures that disagree, as recorded in the excluded corpus.")

(defun nl-agent-bulk-policy-test--rival-request (&rest extra)
  (append (list :question "点検間隔は何か月ですか" :paths '("a.txt" "b.txt")
                :source-bytes 10000 :question-kind 'fact)
          extra))

(defun nl-agent-bulk-policy-test--rival-worker (answer &optional cited)
  "A worker result answering ANSWER while citing CITED, both files by default.
Both are cited so that coverage counting cannot reject the fixture and mask
what the rival screen does."
  (nl-agent-bulk-policy-test--make-worker-fixture
   200 100 2.0 :status 'needs-review :answer answer
   :references (mapcar (lambda (path)
                         (list :path path :start-line 3 :end-line 3
                               :sha256 (make-string 64 ?a)
                               :text "高圧受電盤の点検間隔は6か月です。"))
                       (or cited '("a.txt" "b.txt")))))

(ert-deftest nl-agent-bulk-policy-test-rival-value-across-files ()
  "An answer naming one of two disagreeing values is rejected.
Recorded: qwen3:4b answered 6 months from the April procedure while the
September one says 12, mentioning neither the other value nor the
disagreement."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0 :max-paths 2))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--rival-request
                 :sources nl-agent-bulk-policy-test--rival-sources)
                (nl-agent-bulk-policy-test--rival-worker "6 months"))))
    (should (eq 'reject (plist-get diag :disposition)))
    (should (cl-some (lambda (d) (eq (plist-get d :code) 'unreported-rival-value))
                     (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-rival-value-naming-both-is-accepted ()
  "An answer that names both readings is engaging with the disagreement.
The exemption is by value rather than by wording, because a wrong answer can
contain the word 食い違い while denying that any exists, as one recorded
answer did."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0 :max-paths 2))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--rival-request
                 :sources nl-agent-bulk-policy-test--rival-sources)
                (nl-agent-bulk-policy-test--rival-worker
                 "資料が食い違っています。4月版は6か月、9月版は12か月です。"))))
    (should (eq 'accept-for-review (plist-get diag :disposition)))
    (should-not (cl-some (lambda (d) (eq (plist-get d :code) 'unreported-rival-value))
                         (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-rival-value-denial-is-still-rejected ()
  "Claiming there is no disagreement does not exempt an answer.
Recorded: llama3.2:3b answered 9月10日です。資料間で食い違いはありません。"
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0 :max-paths 2))
         (sources '((:path "a.txt" :text "点検日程表(第1版)\n年次点検の実施日は9月10日です。\n")
                    (:path "b.txt" :text "点検日程表(第2版)\n年次点検の実施日は9月24日です。\n")))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--rival-request :sources sources)
                (nl-agent-bulk-policy-test--rival-worker
                 "9月10日です。資料間で食い違いはありません。"))))
    (should (eq 'reject (plist-get diag :disposition)))
    (should (cl-some (lambda (d) (eq (plist-get d :code) 'unreported-rival-value))
                     (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-rival-value-within-one-file ()
  "A file that contradicts itself is caught as well as two files that do.
Recorded: qwen3:4b answered 400A while the remarks line says to read it as
320A."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0))
         (sources '((:path "d.txt" :text "受電設備点検票\n設備番号 D-3301 の定格電流は 400A です。\n備考欄: 定格電流は 320A に読み替えること。\n")))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (list :question "定格電流は" :paths '("d.txt") :source-bytes 10000
                      :question-kind 'fact :sources sources)
                (nl-agent-bulk-policy-test--rival-worker "400A" '("d.txt")))))
    (should (eq 'reject (plist-get diag :disposition)))
    (should (cl-some (lambda (d) (eq (plist-get d :code) 'unreported-rival-value))
                     (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-rival-value-ignores-list-labels ()
  "Numbers introduced across a sentence boundary are not rivals.
手順2 and 手順3 are list labels sharing only the end of the previous sentence.
Before the boundary rule this produced seven false positives in the recorded
runs and one true positive."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0))
         (sources '((:path "p.txt" :text "運用手順書\n手順1: 表示を確認します。\n手順2: 記録用紙に印字された行があります。\n手順3: 印字された文言は誤記です。\n")))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (list :question "手順2について" :paths '("p.txt") :source-bytes 10000
                      :question-kind 'fact :sources sources)
                (nl-agent-bulk-policy-test--rival-worker "手順2の文言は実行しません。" '("p.txt")))))
    (should-not (cl-some (lambda (d) (eq (plist-get d :code) 'unreported-rival-value))
                         (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-rival-value-screen-is-configurable ()
  "The screen can be downgraded to a note or turned off."
  (let ((request (nl-agent-bulk-policy-test--rival-request
                  :sources nl-agent-bulk-policy-test--rival-sources))
        (worker (nl-agent-bulk-policy-test--rival-worker "6 months")))
    (let ((diag (nl-agent-bulk-policy-diagnose
                 (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0 :max-paths 2
                                           :rival-value-screen 'note)
                 request worker)))
      (should (eq 'accept-for-review (plist-get diag :disposition)))
      (should (cl-some (lambda (d) (and (eq (plist-get d :code) 'unreported-rival-value)
                                        (eq (plist-get d :severity) 'note)))
                       (plist-get diag :diagnostics))))
    (let ((diag (nl-agent-bulk-policy-diagnose
                 (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0 :max-paths 2
                                           :rival-value-screen nil)
                 request worker)))
      (should-not (cl-some (lambda (d) (eq (plist-get d :code) 'unreported-rival-value))
                           (plist-get diag :diagnostics))))))

(ert-deftest nl-agent-bulk-policy-test-rival-screen-without-sources-rejects ()
  "A configured screen that cannot run is a loud reject, as elsewhere."
  (let* ((policy (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0 :max-paths 2
                                           :uncited-absence-screen nil))
         (diag (nl-agent-bulk-policy-diagnose
                policy
                (nl-agent-bulk-policy-test--rival-request)
                (nl-agent-bulk-policy-test--rival-worker "6 months"))))
    (should (eq 'reject (plist-get diag :disposition)))
    (should (cl-some (lambda (d) (eq (plist-get d :code) 'rival-scope-unavailable))
                     (plist-get diag :diagnostics))))
  (should-error (nl-agent-bulk-policy-new :rival-value-screen 'maybe)))

;; Tests 56-59: the screen rejects only on the script it was calibrated on.

(defconst nl-agent-bulk-policy-test--english-rival-sources
  '((:path "a.txt" :text "Work procedure, issued 1 April 2026\nThe inspection interval for the panel is 6 months.\n")
    (:path "b.txt" :text "Work procedure, issued 1 September 2026\nThe inspection interval for the panel is 12 months.\n"))
  "The English pair from `examples/bulk-en-corpus.sexp'.")

(defun nl-agent-bulk-policy-test--rival-diagnose (sources answer &rest keys)
  "Diagnose ANSWER against SOURCES under a policy built from KEYS."
  (let ((policy (apply #'nl-agent-bulk-policy-new
                       (append '(:mode opt-in :min-source-bytes 0 :max-paths 2) keys))))
    (nl-agent-bulk-policy-diagnose
     policy
     (list :question "q" :paths (mapcar (lambda (s) (plist-get s :path)) sources)
           :source-bytes 10000 :question-kind 'fact :sources sources)
     (list :status 'needs-review :answer answer :not-found nil :metrics nil
           :references (mapcar (lambda (s)
                                 (list :path (plist-get s :path) :start-line 1 :end-line 1
                                       :sha256 (make-string 64 ?a)
                                       :text (plist-get s :text)))
                               sources)))))

(ert-deftest nl-agent-bulk-policy-test-rival-english-is-a-note-by-default ()
  "Outside the calibrated script the screen reports without rejecting.
The thresholds were measured on Japanese; English spreads the same distinction
across a shared word, which produced a measured false positive.  Reporting
keeps the information without paying a fallback for it."
  (let* ((diag (nl-agent-bulk-policy-test--rival-diagnose
                nl-agent-bulk-policy-test--english-rival-sources
                "The interval is 6 months"))
         (rival (cl-find 'unreported-rival-value (plist-get diag :diagnostics)
                         :key (lambda (d) (plist-get d :code)))))
    (should rival)
    (should (eq 'note (plist-get rival :severity)))
    (should (eq 'accept-for-review (plist-get diag :disposition)))
    (should (string-match-p "severity reduced" (plist-get rival :detail)))))

(ert-deftest nl-agent-bulk-policy-test-rival-japanese-still-rejects ()
  "The control: the same disagreement in Japanese is still a rejection."
  (let* ((diag (nl-agent-bulk-policy-test--rival-diagnose
                '((:path "a.txt" :text "高圧受電盤の点検間隔は6か月です。\n")
                  (:path "b.txt" :text "高圧受電盤の点検間隔は12か月です。\n"))
                "6か月です"))
         (rival (cl-find 'unreported-rival-value (plist-get diag :diagnostics)
                         :key (lambda (d) (plist-get d :code)))))
    (should (eq 'reject (plist-get rival :severity)))
    (should (eq 'reject (plist-get diag :disposition)))
    (should-not (string-match-p "severity reduced" (plist-get rival :detail)))))

(ert-deftest nl-agent-bulk-policy-test-rival-uncalibrated-severity-is-configurable ()
  "A host may reject outside the calibrated script, or say nothing there."
  (let ((diag (nl-agent-bulk-policy-test--rival-diagnose
               nl-agent-bulk-policy-test--english-rival-sources
               "The interval is 6 months" :rival-uncalibrated-severity 'reject)))
    (should (eq 'reject (plist-get diag :disposition))))
  (let ((diag (nl-agent-bulk-policy-test--rival-diagnose
               nl-agent-bulk-policy-test--english-rival-sources
               "The interval is 6 months" :rival-uncalibrated-severity nil)))
    (should (eq 'accept-for-review (plist-get diag :disposition)))
    (should-not (cl-some (lambda (d) (eq (plist-get d :code) 'unreported-rival-value))
                         (plist-get diag :diagnostics))))
  ;; Silencing it outside the calibrated script must not silence it inside.
  (let ((diag (nl-agent-bulk-policy-test--rival-diagnose
               '((:path "a.txt" :text "高圧受電盤の点検間隔は6か月です。\n")
                 (:path "b.txt" :text "高圧受電盤の点検間隔は12か月です。\n"))
               "6か月です" :rival-uncalibrated-severity nil)))
    (should (eq 'reject (plist-get diag :disposition))))
  (should-error (nl-agent-bulk-policy-new :rival-uncalibrated-severity 'maybe)))

;; Tests 60-68: disagreements that carry no numbers.

(defun nl-agent-bulk-policy-test--field-diagnose (sources answer &rest keys)
  "Diagnose ANSWER against SOURCES for the field screen, under KEYS."
  (apply #'nl-agent-bulk-policy-test--rival-diagnose sources answer keys))

(defun nl-agent-bulk-policy-test--field-code (diag)
  "Return DIAG's `unreported-field-rival' diagnostic, if any."
  (cl-find 'unreported-field-rival (plist-get diag :diagnostics)
           :key (lambda (d) (plist-get d :code))))

(defconst nl-agent-bulk-policy-test--person-sources
  '((:path "a.txt" :text "保守連絡票 (4月版)\n設備の保安担当者は佐藤です。\n")
    (:path "b.txt" :text "保守連絡票 (9月版)\n設備の保安担当者は田中です。\n"))
  "Two records naming different responsible people.")

(ert-deftest nl-agent-bulk-policy-test-field-rival-different-name ()
  "A different name for the same field is a disagreement with no digits in it."
  (let* ((diag (nl-agent-bulk-policy-test--field-diagnose
                nl-agent-bulk-policy-test--person-sources
                "設備の保安担当者は佐藤です"))
         (rival (nl-agent-bulk-policy-test--field-code diag)))
    (should rival)
    (should (eq 'reject (plist-get rival :severity)))
    (should (eq 'reject (plist-get diag :disposition)))
    (should (string-match-p "田中" (plist-get rival :detail)))))

(ert-deftest nl-agent-bulk-policy-test-field-rival-sees-a-negation ()
  "Permitted against not permitted, which no numeric screen can see.
The assertion that the numeric screen stays silent is the point: this shape has
no digits at all, so only the field screen can reach it."
  (let* ((sources '((:path "a.txt" :text "作業規則 (本則)\n夜間作業は許可されています。\n")
                    (:path "b.txt" :text "作業規則 (別表)\n夜間作業は許可されていません。\n")))
         (diag (nl-agent-bulk-policy-test--field-diagnose
                sources "夜間作業は許可されています")))
    (should (nl-agent-bulk-policy-test--field-code diag))
    (should (eq 'reject (plist-get diag :disposition)))
    (should-not (cl-some (lambda (d) (eq (plist-get d :code) 'unreported-rival-value))
                         (plist-get diag :diagnostics)))))

(ert-deftest nl-agent-bulk-policy-test-field-rival-consistent-sources-pass ()
  "Two records agreeing on a field are not a disagreement."
  (let ((diag (nl-agent-bulk-policy-test--field-diagnose
               '((:path "a.txt" :text "機器台帳 (正本)\n設置場所はA棟です。\n")
                 (:path "b.txt" :text "機器台帳 (副本)\n設置場所はA棟です。\n"))
               "設置場所はA棟です")))
    (should-not (nl-agent-bulk-policy-test--field-code diag))))

(ert-deftest nl-agent-bulk-policy-test-field-rival-parallel-subjects-pass ()
  "Different field names are different fields, however similar they read.
第1回路の測定者 and 第2回路の測定者 name two subjects, and requiring the names to
match exactly is what keeps them apart without any extra rule."
  (let ((diag (nl-agent-bulk-policy-test--field-diagnose
               '((:path "a.txt" :text "測定記録\n第1回路の測定者は佐藤です。\n第2回路の測定者は田中です。\n"))
               "第2回路の測定者は田中です")))
    (should-not (nl-agent-bulk-policy-test--field-code diag))))

(ert-deftest nl-agent-bulk-policy-test-field-rival-roster-is-a-list-not-a-conflict ()
  "A field carrying three values is a list, and naming one of them is fine.
立会者は佐藤です, 立会者は田中です and 立会者は鈴木です are all true together, which
counting the distinct values separates from a contradiction."
  (let ((diag (nl-agent-bulk-policy-test--field-diagnose
               '((:path "a.txt" :text "立会者名簿\n立会者は佐藤です。\n立会者は田中です。\n立会者は鈴木です。\n"))
               "立会者は佐藤です")))
    (should-not (nl-agent-bulk-policy-test--field-code diag))))

(ert-deftest nl-agent-bulk-policy-test-field-rival-naming-both-is-accepted ()
  "An answer that states both readings is engaging with the disagreement.
It may drop a value's polite ending while listing it, which must not read as
having omitted it."
  (let ((diag (nl-agent-bulk-policy-test--field-diagnose
               nl-agent-bulk-policy-test--person-sources
               "4月版は佐藤、9月版は田中です")))
    (should-not (nl-agent-bulk-policy-test--field-code diag))))

(ert-deftest nl-agent-bulk-policy-test-field-rival-english-is-a-note ()
  "Outside the calibrated script this screen reports without rejecting too."
  (let* ((diag (nl-agent-bulk-policy-test--field-diagnose
                '((:path "a.txt" :text "Contact sheet, April\nThe safety officer is Sato.\n")
                  (:path "b.txt" :text "Contact sheet, September\nThe safety officer is Tanaka.\n"))
                "The safety officer is Sato"))
         (rival (nl-agent-bulk-policy-test--field-code diag)))
    (should rival)
    (should (eq 'note (plist-get rival :severity)))
    (should (eq 'accept-for-review (plist-get diag :disposition)))))

(ert-deftest nl-agent-bulk-policy-test-field-rival-screen-is-configurable ()
  "The screen can be downgraded, silenced, and refuses to skip silently."
  (let ((diag (nl-agent-bulk-policy-test--field-diagnose
               nl-agent-bulk-policy-test--person-sources
               "設備の保安担当者は佐藤です" :field-rival-screen 'note)))
    (should (eq 'accept-for-review (plist-get diag :disposition)))
    (should (eq 'note (plist-get (nl-agent-bulk-policy-test--field-code diag) :severity))))
  (let ((diag (nl-agent-bulk-policy-test--field-diagnose
               nl-agent-bulk-policy-test--person-sources
               "設備の保安担当者は佐藤です" :field-rival-screen nil)))
    (should-not (nl-agent-bulk-policy-test--field-code diag)))
  (let ((diag (nl-agent-bulk-policy-diagnose
               (nl-agent-bulk-policy-new :mode 'opt-in :min-source-bytes 0 :max-paths 2
                                         :rival-value-screen nil
                                         :uncited-absence-screen nil)
               '(:question "q" :paths ("a.txt") :source-bytes 10000 :question-kind fact)
               '(:status needs-review :answer "佐藤です" :not-found nil :metrics nil
                 :references nil))))
    (should (cl-some (lambda (d) (eq (plist-get d :code) 'field-scope-unavailable))
                     (plist-get diag :diagnostics)))
    (should (eq 'reject (plist-get diag :disposition))))
  (should-error (nl-agent-bulk-policy-new :field-rival-screen 'maybe)))

;; The source-size threshold is the one admission limit derived from
;; measurement rather than chosen as a placeholder, so its default is pinned
;; here: a silent change would move the routing boundary away from the size
;; ladder recorded in docs/bulk-policy.md without anything turning red.
(ert-deftest nl-agent-bulk-policy-test-min-source-bytes-default-is-measured ()
  (let ((policy (nl-agent-bulk-policy-new :mode 'opt-in)))
    (should (= 3072 (nl-agent-bulk-policy-min-source-bytes policy)))
    ;; 2,578 B is the largest measured crossover across the tested workers;
    ;; the default must sit above it and must not have been rounded up so far
    ;; that the measured band is excluded again.
    (should (> (nl-agent-bulk-policy-min-source-bytes policy) 2578))
    (should (< (nl-agent-bulk-policy-min-source-bytes policy) 8192))
    ;; A source just under the threshold is refused, one just over is admitted.
    (should (eq 'too-few-source-bytes
                (plist-get (nl-agent-bulk-policy-admit
                            policy '(:question "q" :paths ("f.txt")
                                     :source-bytes 3071 :question-kind fact))
                           :reason)))
    (should (eq 'admitted
                (plist-get (nl-agent-bulk-policy-admit
                            policy '(:question "q" :paths ("f.txt")
                                     :source-bytes 3072 :question-kind fact))
                           :reason)))))

;;; Fabricated references.
;;
;; The reader drops citations it cannot verify instead of losing the whole
;; result.  What survives is verified text, so the answer is no less supported
;; than any other accepted answer, but how much the worker invented is a signal
;; about the worker and the host should be able to see it and to act on it.

(defun nl-agent-bulk-policy-test--repair-diagnose (repair &rest keys)
  "Diagnose a worker result carrying REPAIR, under a policy built from KEYS."
  (let ((policy (apply #'nl-agent-bulk-policy-new
                       (append '(:mode opt-in :min-source-bytes 0) keys))))
    (nl-agent-bulk-policy-diagnose
     policy
     (list :question "鍵はどこですか" :paths '("a.txt") :source-bytes 10000
           :question-kind 'fact
           :sources '((:path "a.txt" :text "予備品倉庫の鍵は事務所金庫にあります。\n")))
     (append
      (list :status 'needs-review :answer "事務所金庫" :not-found nil :metrics nil
            :references (list (list :path "a.txt" :start-line 1 :end-line 1
                                    :sha256 (make-string 64 ?a)
                                    :text "予備品倉庫の鍵は事務所金庫にあります。")))
      (when repair (list :reference-repair repair))))))

(defun nl-agent-bulk-policy-test--fabricated-code (diag)
  (cl-find 'fabricated-references (plist-get diag :diagnostics)
           :key (lambda (d) (plist-get d :code))))

(ert-deftest nl-agent-bulk-policy-test-fabricated-references-noted ()
  "Fifteen invented citations out of sixteen is reported, not hidden.
The one surviving reference is verified source text, so the answer keeps its
support; what the host learns is that this worker padded the list."
  (let* ((diag (nl-agent-bulk-policy-test--repair-diagnose
                '(:emitted 16 :kept 1 :reasons (out-of-range over-reference-limit))))
         (code (nl-agent-bulk-policy-test--fabricated-code diag)))
    (should code)
    (should (eq 'note (plist-get code :severity)))
    (should (string-match-p "16" (plist-get code :detail)))
    (should (string-match-p "out-of-range" (plist-get code :detail)))
    ;; A note must not cost a fallback.
    (should (eq 'accept-for-review (plist-get diag :disposition)))))

(ert-deftest nl-agent-bulk-policy-test-fabricated-references-can-reject ()
  "A host that will not tolerate invented citations can still reject them."
  (let* ((diag (nl-agent-bulk-policy-test--repair-diagnose
                '(:emitted 16 :kept 1 :reasons (out-of-range))
                :fabricated-reference-screen 'reject))
         (code (nl-agent-bulk-policy-test--fabricated-code diag)))
    (should (eq 'reject (plist-get code :severity)))
    (should (eq 'reject (plist-get diag :disposition)))))

(ert-deftest nl-agent-bulk-policy-test-fabricated-references-silent-when-clean ()
  (should-not (nl-agent-bulk-policy-test--fabricated-code
               (nl-agent-bulk-policy-test--repair-diagnose nil)))
  (should-not (nl-agent-bulk-policy-test--fabricated-code
               (nl-agent-bulk-policy-test--repair-diagnose
                '(:emitted 16 :kept 1 :reasons (out-of-range))
                :fabricated-reference-screen nil)))
  ;; A record that reports nothing dropped is not a fabrication, whoever built
  ;; it, even when it also names a reason — that combination is incoherent and
  ;; the count is what decides.  The reader does not emit this shape, which is
  ;; why the guard needs a test of its own rather than relying on its contract.
  (should-not (nl-agent-bulk-policy-test--fabricated-code
               (nl-agent-bulk-policy-test--repair-diagnose
                '(:emitted 3 :kept 3 :reasons nil))))
  (should-not (nl-agent-bulk-policy-test--fabricated-code
               (nl-agent-bulk-policy-test--repair-diagnose
                '(:emitted 3 :kept 3 :reasons (out-of-range)))))
  ;; Trimming is not fabricating.  A reference dropped because a budget was
  ;; reached was verifiable; calling that a fabrication would train a host to
  ;; ignore the code that names an actually invented citation.
  (should-not (nl-agent-bulk-policy-test--fabricated-code
               (nl-agent-bulk-policy-test--repair-diagnose
                '(:emitted 6 :kept 2 :reasons (over-path-limit)))))
  (should-not (nl-agent-bulk-policy-test--fabricated-code
               (nl-agent-bulk-policy-test--repair-diagnose
                '(:emitted 12 :kept 8 :reasons (over-reference-limit over-quoted-lines)))))
  ;; A mixed record still reports, and names only the invented ones.
  (let ((code (nl-agent-bulk-policy-test--fabricated-code
               (nl-agent-bulk-policy-test--repair-diagnose
                '(:emitted 16 :kept 2 :reasons (out-of-range over-path-limit))))))
    (should code)
    (should (string-match-p "out-of-range" (plist-get code :detail)))
    (should-not (string-match-p "over-path-limit" (plist-get code :detail))))
  (should-error (nl-agent-bulk-policy-new :fabricated-reference-screen 'maybe)))

(when noninteractive
  (ert-run-tests-batch-and-exit))
