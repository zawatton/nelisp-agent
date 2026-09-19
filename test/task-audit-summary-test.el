;;; task-audit-summary-test.el --- bounded task-audit summaries -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name "../lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-llm/lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-photon/lisp" here)))
(require 'nl-agent-task-audit)
(require 'nl-agent-task-eval)
(require 'nl-agent-task-eval-service)
(require 'nl-agent-task-promotion)
(require 'nl-agent-training-protocol)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-improve)

(defun nl-agent-task-audit-summary-test--policy ()
  "Return a small policy whose task text contains a redaction sentinel."
  (nl-agent-task-promotion-policy
   (list :suite
         (list :id "summary-suite-日本" :version "1"
               :cases
               (vector
                (list :id "sentinel-case"
                      :task "SECRET TASK: replace 旧 with 新"
                      :files (vector (list :path "秘密.txt" :text "旧"))
                      :expected (vector (list :path "秘密.txt" :text "新")))))
         :grammar '(:type "done" :length 1 :allow "ab")
         :max-sequence 4096 :max-steps 1)))

(defun nl-agent-task-audit-summary-test--request (policy)
  "Return a valid request carrying POLICY."
  (nl-agent-training-protocol-validate-request
   (list :format nl-agent-training-protocol-format
         :attempt "summary-attempt-1" :job-id "summary-job"
         :parent-generation 7 :parent-score -0.123456789
         :scope (make-string 64 ?e)
         :payload '(:examples [" ab"] :lr 0.0123456789 :epochs 1)
         :parent-model
         (nl-llm-agent-artifact-export-pav
          (nl-llm-agent-improve-model 2 2 96 1 1))
         :training '(:backend cpu :sequence 8 :optimizer sgd)
         :benchmark [" ab"]
         :task-promotion policy)))

(defun nl-agent-task-audit-summary-test--evidence (request policy)
  "Return valid evidence with one deliberate before/after regression."
  (let ((model (nl-agent-training-protocol-import
                (plist-get request :parent-model))))
    (cl-letf (((symbol-function 'nl-agent-task-eval-service-run)
               (lambda (suite _registry model-id &rest keys)
                 (nl-agent-task-eval-run
                  suite
                  (lambda (_task workspace _max-steps)
                    ;; Make only the before report pass.  This exercises the
                    ;; redacted regression aggregate without task inference.
                    (when (equal model-id "native/before")
                      (with-temp-file (expand-file-name "秘密.txt" workspace)
                        (insert "新")))
                    (list :status 'done :steps 1 :result nil
                          :messages nil :trajectory nil))
                  :model-id model-id
                  :runner-id nl-agent-task-eval-service-runner-id
                  :max-steps (plist-get keys :max-steps)))))
      (nl-agent-task-promotion-evaluate
       model model (plist-get policy :suite) (plist-get policy :grammar)
       :max-sequence (plist-get policy :max-sequence)
       :max-steps (plist-get policy :max-steps)))))

(defun nl-agent-task-audit-summary-test--fixture ()
  "Return a temporary directory and a protocol-valid audit fixture."
  (let* ((tmp (make-temp-file "nl-task-audit-summary-" t))
         (audit (expand-file-name "audit" tmp))
         (policy (nl-agent-task-audit-summary-test--policy))
         (request (nl-agent-task-audit-summary-test--request policy))
         (request-file (expand-file-name "request.sexp" tmp))
         (evidence
          (nl-agent-task-audit-summary-test--evidence request policy))
         request-sha result)
    (nl-agent-training-protocol-write request-file request)
    (setq request-sha (nl-agent-training-protocol-hash request-file)
          result
          (list :format nl-agent-training-result-format
                :attempt (plist-get request :attempt)
                :request-sha256 request-sha
                :score 0.246813579
                :model (plist-get request :parent-model)
                :task-promotion evidence))
    (nl-agent-training-protocol-validate-result result request)
    (list :tmp tmp :audit audit :request request :result result
          :request-sha request-sha)))

(defun nl-agent-task-audit-summary-test--cleanup (fixture)
  (when (file-directory-p (plist-get fixture :tmp))
    (delete-directory (plist-get fixture :tmp) t)))

(defun nl-agent-task-audit-summary-test--contains (value needle)
  "Return non-nil when bounded VALUE contains string NEEDLE."
  (cond
   ((stringp value) (string-match-p (regexp-quote needle) value))
   ((consp value)
    (or (nl-agent-task-audit-summary-test--contains (car value) needle)
        (nl-agent-task-audit-summary-test--contains (cdr value) needle)))
   ((vectorp value)
    (cl-some (lambda (item)
               (nl-agent-task-audit-summary-test--contains item needle))
             (append value nil)))
   (t nil)))

(ert-deftest nl-agent-task-audit-summary-is-allowlisted-and-bounded ()
  (let* ((fixture (nl-agent-task-audit-summary-test--fixture))
         (request (plist-get fixture :request))
         (audit (plist-get fixture :audit))
         (hash (plist-get fixture :request-sha))
         (request-file (expand-file-name "request.sexp" (plist-get fixture :tmp))))
    (unwind-protect
        (progn
          (nl-agent-task-audit-save audit (plist-get fixture :request)
                                    (plist-get fixture :result) hash)
          (let* ((before-files (directory-files audit nil nil t))
                 (summary
                  (nl-agent-task-audit-summary
                   audit (plist-get request :scope)
                   (plist-get request :job-id)
                   (plist-get request :attempt)))
                 (expected
                  '(:format :reference :task-accepted :before-passed
                    :after-passed :total :regressions :parent-score
                    :candidate-score :parent-generation :request-sha256))
                 keys)
            (let ((tail summary))
              (while tail
                (push (pop tail) keys)
                (pop tail))
              (setq keys (nreverse keys)))
            (should (equal keys expected))
            (should (equal (plist-get summary :format)
                           "nl-agent-task-evaluation-v1"))
            (should (equal (plist-get summary :reference)
                           (list :scope (plist-get request :scope)
                                 :id (plist-get request :job-id)
                                 :attempt (plist-get request :attempt))))
            (should-not (plist-get summary :task-accepted))
            (should (= (plist-get summary :before-passed) 1))
            (should (= (plist-get summary :after-passed) 0))
            (should (= (plist-get summary :total) 1))
            (should (= (plist-get summary :regressions) 1))
            (should (= (plist-get summary :parent-score) -0.123456789))
            (should (= (plist-get summary :candidate-score) 0.246813579))
            (should (= (plist-get summary :parent-generation) 7))
            (should (equal (plist-get summary :request-sha256) hash))
            (should-not
             (nl-agent-task-audit-summary-test--contains
              summary "SECRET TASK"))
            (should-not
             (nl-agent-task-audit-summary-test--contains
              summary "秘密.txt"))
            (should (equal (directory-files audit nil nil t) before-files))
            (plist-put (plist-get summary :reference) :scope "mutated")
            (setq summary (plist-put summary :request-sha256 "mutated"))
            (should (equal (plist-get
                            (nl-agent-task-audit-summary
                             audit (plist-get request :scope)
                             (plist-get request :job-id)
                             (plist-get request :attempt))
                            :request-sha256)
                           hash)))
          (should (file-regular-p request-file)))
      (nl-agent-task-audit-summary-test--cleanup fixture))))

(ert-deftest nl-agent-task-audit-summary-rejects-tampered-record ()
  (let* ((fixture (nl-agent-task-audit-summary-test--fixture))
         (request (plist-get fixture :request))
         (audit (plist-get fixture :audit))
         (hash (plist-get fixture :request-sha)))
    (unwind-protect
        (progn
          (nl-agent-task-audit-save audit request (plist-get fixture :result)
                                    hash)
          (let ((path (nl-agent-task-audit--path
                       audit (plist-get request :scope)
                       (plist-get request :job-id)
                       (plist-get request :attempt))))
            (with-temp-file path
              (insert "(:format \"nl-agent-task-audit-v1\")"))
            (should-error
             (nl-agent-task-audit-summary
              audit (plist-get request :scope)
              (plist-get request :job-id)
              (plist-get request :attempt)))))
      (nl-agent-task-audit-summary-test--cleanup fixture))))

(provide 'task-audit-summary-test)
(ert-run-tests-batch-and-exit)
;;; task-audit-summary-test.el ends here
