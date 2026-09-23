;;; training-task-promotion-protocol-test.el --- task promotion wire tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                          (file-name-directory (or load-file-name buffer-file-name
                                                   default-directory))) nil t)
)

(require 'nl-agent-task-promotion)
(require 'nl-agent-training-protocol)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-improve)

(defun nl-agent-training-task-promotion-protocol-test--suite ()
  "Return a small immutable task suite fixture."
  (list :id (concat "promotion-wire-suite") :version (concat "1")
        :cases
        (vector
         (list :id (concat "done-case") :task (concat "done-case")
               :files (vector (list :path (concat "input.txt")
                                       :text (concat "before")))
               :expected (vector (list :path (concat "input.txt")
                                          :text (concat "never-match")))))))

(defun nl-agent-training-task-promotion-protocol-test--policy ()
  "Return a valid task promotion policy fixture."
  (list :suite (nl-agent-training-task-promotion-protocol-test--suite)
        :grammar (list :type (concat "done") :length 1
                       :allow (concat "ab"))
        :max-sequence 32 :max-steps 3))

(defun nl-agent-training-task-promotion-protocol-test--request
    (&optional policy)
  "Return a tiny CPU request, optionally carrying POLICY."
  (let ((request
         (list :format nl-agent-training-protocol-format
               :attempt "wire-attempt" :job-id "wire-job"
               :parent-generation 0 :parent-score 0.0
               :scope (make-string 64 ?a)
               :payload '(:examples ["ab"] :lr 0.01 :epochs 1)
               :parent-model
               (nl-llm-agent-artifact-export-pav
                (nl-llm-agent-improve-model 2 2 96 1 1))
               :training '(:backend cpu :sequence 8 :optimizer sgd)
               :benchmark ["ab"])))
    (if policy
        (append request (list :task-promotion policy))
      request)))

(defun nl-agent-training-task-promotion-protocol-test--write-expected
    (suite task workspace)
  "Write expected files for TASK in WORKSPACE."
  (let ((case
         (cl-find-if (lambda (candidate)
                       (equal task (plist-get candidate :task)))
                     (append (plist-get suite :cases) nil))))
    (dolist (entry (append (plist-get case :expected) nil))
      (let ((path (expand-file-name (plist-get entry :path) workspace)))
        (make-directory (file-name-directory path) t)
        (with-temp-file path
          (insert (plist-get entry :text)))))))

(defun nl-agent-training-task-promotion-protocol-test--report
    (suite model-id max-steps &optional pass)
  "Return a valid report, passing the only case when PASS is non-nil."
  (nl-agent-task-eval-run
   suite
   (lambda (task workspace _steps)
     (when pass
       (nl-agent-training-task-promotion-protocol-test--write-expected
        suite task workspace))
     (list :status 'done :steps 1 :result nil :messages nil :trajectory nil))
   :model-id model-id :runner-id nl-agent-task-eval-service-runner-id
   :max-steps max-steps))

(defmacro nl-agent-training-task-promotion-protocol-test--fake-evaluation
    (&rest body)
  "Evaluate BODY with deterministic passing native reports."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'nl-agent-task-eval-service-run)
              (lambda (suite _registry model-id &rest keys)
                (nl-agent-training-task-promotion-protocol-test--report
                 suite model-id (plist-get keys :max-steps)))))
     ,@body))

(defun nl-agent-training-task-promotion-protocol-test--evidence
    (request policy)
  "Build valid synthetic EVIDENCE for REQUEST and POLICY."
  (let* ((checkpoint (plist-get request :parent-model))
         (model (nl-agent-training-protocol-import checkpoint)))
    (nl-agent-training-task-promotion-protocol-test--fake-evaluation
      (nl-agent-task-promotion-evaluate
       model model
       (plist-get policy :suite) (plist-get policy :grammar)
       :max-sequence (plist-get policy :max-sequence)
       :max-steps (plist-get policy :max-steps)))))

(ert-deftest nl-agent-training-task-promotion-policy-is-canonical-and-detached ()
    (let* ((policy (nl-agent-training-task-promotion-protocol-test--policy))
         (canonical (nl-agent-task-promotion-policy policy)))
    (aset (plist-get (plist-get policy :suite) :cases) 0
          (list :id "changed" :task "changed"
                :files [(:path "x" :text "x")]
                :expected [(:path "x" :text "x")]))
    (aset (plist-get (plist-get policy :grammar) :allow) 0 ?z)
    (should (equal (plist-get (plist-get canonical :suite) :id)
                   "promotion-wire-suite"))
    (should (equal (plist-get (plist-get canonical :grammar) :allow) "ab"))
    (should (equal (nl-agent-task-promotion-policy canonical) canonical))
    (dolist (bad (list nil
                       (append policy '(:extra t))
                       (plist-put (copy-tree policy t) :max-steps 0)))
      (should-error (nl-agent-task-promotion-policy bad)))))

(ert-deftest nl-agent-training-task-promotion-request-binding-and-result-contract ()
  (let* ((policy (nl-agent-training-task-promotion-protocol-test--policy))
         (request (nl-agent-training-task-promotion-protocol-test--request policy))
         (evidence
          (nl-agent-training-task-promotion-protocol-test--evidence
           request policy))
         (result (list :format nl-agent-training-result-format
                       :attempt (plist-get request :attempt)
                       :request-sha256 (make-string 64 ?a)
                       :score 0.0 :model (plist-get request :parent-model)
                       :task-promotion evidence)))
    (should (eq (nl-agent-training-protocol-validate-request request)
                request))
    (should (eq (nl-agent-training-protocol-validate-result result request)
                result))
    (let ((changed (copy-tree request t)))
      (setf (plist-get (plist-get changed :task-promotion) :max-steps) 4)
      (should-not (equal (nl-agent-training-protocol-request-binding request)
                         (nl-agent-training-protocol-request-binding changed))))
    (should-error
     (nl-agent-training-protocol-validate-request
      (plist-put (copy-tree request t) :task-promotion nil)))
    (should-error
     (nl-agent-training-protocol-validate-result
      (let ((without (copy-tree result t)))
        (setq without (cl-loop for (key value) on without by #'cddr
                                unless (eq key :task-promotion)
                                append (list key value)))
        without)
      request))
    (should-error
     (nl-agent-training-protocol-validate-result
      (plist-put (copy-tree result t) :task-promotion evidence)
      (nl-agent-training-task-promotion-protocol-test--request)))))

(ert-deftest nl-agent-training-task-promotion-evidence-rejects-oracle-tampering ()
  (let* ((policy (nl-agent-training-task-promotion-protocol-test--policy))
         (request (nl-agent-training-task-promotion-protocol-test--request policy))
         (evidence
          (nl-agent-training-task-promotion-protocol-test--evidence
           request policy))
         (tampered (copy-tree evidence t)))
    ;; Keep both reports internally valid and use the same fake oracle in both;
    ;; policy-suite oracle binding must still reject this wire evidence.
    (dolist (report-key '(:before :after))
      (let* ((report (plist-get tampered report-key))
             (case (aref (plist-get report :cases) 0))
             (file (aref (plist-get case :files) 0)))
        (setf (plist-get file :expected-sha256) (make-string 64 ?0)
              (plist-get file :actual-sha256) (make-string 64 ?0))
        (should (nl-agent-task-eval--validate-report report))))
    (should (equal (nl-agent-task-eval-compare
                    (plist-get tampered :before)
                    (plist-get tampered :after))
                   (plist-get tampered :comparison)))
    (should-error
     (nl-agent-task-promotion-validate-evidence
      tampered
      (plist-get request :parent-model)
      (plist-get request :parent-model)
      policy))))

(ert-deftest nl-agent-training-task-promotion-evidence-recomputes-positive-acceptance ()
  (let* ((policy (nl-agent-training-task-promotion-protocol-test--policy))
         (request (nl-agent-training-task-promotion-protocol-test--request policy))
         (checkpoint (plist-get request :parent-model))
         (model (nl-agent-training-protocol-import checkpoint))
         evidence)
    (cl-letf (((symbol-function 'nl-agent-task-eval-service-run)
               (lambda (suite _registry model-id &rest keys)
                 (nl-agent-training-task-promotion-protocol-test--report
                  suite model-id (plist-get keys :max-steps)
                  (equal model-id "native/after")))))
      (setq evidence
            (nl-agent-task-promotion-evaluate
             model model (plist-get policy :suite) (plist-get policy :grammar)
             :max-sequence (plist-get policy :max-sequence)
             :max-steps (plist-get policy :max-steps))))
    (should (eq (plist-get evidence :accepted) t))
    (should (eq (plist-get
                 (nl-agent-task-promotion-validate-evidence
                  evidence checkpoint checkpoint policy)
                 :accepted)
                t))
    (let ((stepped (copy-tree checkpoint t)))
      (setf (plist-get stepped :step) 99)
      (should (eq (plist-get
                   (nl-agent-task-promotion-validate-evidence
                    evidence stepped checkpoint policy)
                   :accepted)
                  t)))
    (dolist (tampered
             (list
              (plist-put (copy-tree evidence t) :accepted nil)
              (let ((copy (copy-tree evidence t)))
                (plist-put copy :comparison
                           (plist-put (copy-tree (plist-get copy :comparison) t)
                                      :passed-delta 0))
                copy)
              (plist-put (copy-tree evidence t) :before-model-sha256
                         (make-string 64 ?0))
              (plist-put (copy-tree evidence t) :max-sequence 31)
              (plist-put (copy-tree evidence t) :grammar
                         '(:type "done" :length 2 :allow "ab"))))
      (should-error
       (nl-agent-task-promotion-validate-evidence
        tampered checkpoint checkpoint policy)))))

(ert-deftest nl-agent-training-task-promotion-evidence-rejects-infrastructure ()
  (let* ((policy (nl-agent-training-task-promotion-protocol-test--policy))
         (request (nl-agent-training-task-promotion-protocol-test--request policy))
         (checkpoint (plist-get request :parent-model))
         (suite (plist-get policy :suite))
         (before
          (nl-agent-task-eval-run
           suite (lambda (&rest _args) (error "wire callback failure"))
           :model-id "native/before"
           :runner-id nl-agent-task-eval-service-runner-id :max-steps 3))
         (after
          (nl-agent-training-task-promotion-protocol-test--report
           suite "native/after" 3 t))
         (base-evidence
          (list :accepted nil
                :grammar (plist-get policy :grammar)
                :max-sequence 32 :max-steps 3
                :before-model-sha256
                (nl-agent-task-promotion--checkpoint-digest checkpoint)
                :after-model-sha256
                (nl-agent-task-promotion--checkpoint-digest checkpoint)
                :before before :after after
                :comparison (nl-agent-task-eval-compare before after))))
    (dolist (claimed '(t nil))
      (let ((condition
             (should-error
              (nl-agent-task-promotion-validate-evidence
               (plist-put (copy-tree base-evidence t) :accepted claimed)
               checkpoint checkpoint policy))))
        (should (equal (error-message-string condition)
                       "task promotion evidence has infrastructure failures"))))))

(ert-run-tests-batch-and-exit)
