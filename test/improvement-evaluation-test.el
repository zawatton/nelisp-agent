;;; improvement-evaluation-test.el --- model-visible task summaries -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-llm/lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-photon/lisp"))

(require 'cl-lib)
(require 'ert)
(require 'nl-agent-improvement)
(require 'nl-agent-task-audit)
(require 'nl-agent-training-runner)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-evolve-queue)

(defun nl-agent-improvement-evaluation-test--queue (directory)
  "Return a small queue with one valid pending proposal in DIRECTORY."
  (let* ((model (nl-llm-agent-improve-model 2 2 96 1 1))
         (catalog (expand-file-name "catalog.json" directory))
         (queue-file (expand-file-name "queue.sexp" directory))
         (queue
          (nl-llm-agent-evolve-p5-queue
           model (lambda (_candidate) 0.0) catalog
           '(:type "done" :length 1)
           :id-prefix "evaluation-test" :training-sequence 8
           :checkpoint-file queue-file)))
    (nl-llm-evolve-queue-submit
     queue "trajectory-finetune" '(:examples [" a"] :lr 0.01 :epochs 1)
     :id "evaluation-job")
    queue))

(defun nl-agent-improvement-evaluation-test--runner
    (scope audit-directory)
  "Return a lightweight runner object for tool-boundary tests."
  (nl-agent-training-runner--make
   :profile (list :scope scope)
   :task-audit-directory audit-directory))

(defun nl-agent-improvement-evaluation-test--tool (registry)
  "Return the evaluation tool in REGISTRY."
  (cl-find-if
   (lambda (tool)
     (equal (nl-agent-tool-name tool) "model.improvement.evaluation"))
   (nl-agent-tool-registry-tools registry)))

(defun nl-agent-improvement-evaluation-test--register (runner)
  "Register tools around a tiny queue and RUNNER."
  (let* ((directory (make-temp-file "nl-improvement-evaluation-" t))
         (queue (nl-agent-improvement-evaluation-test--queue directory))
         (registry (nl-agent-tool-registry-new)))
    (nl-agent-improvement-register-tools registry queue runner)
    (list :directory directory :queue queue :registry registry)))

(ert-deftest nl-agent-improvement-evaluation-legacy-catalog-is-unchanged ()
  (let* ((directory (make-temp-file "nl-improvement-legacy-" t))
         (queue (nl-agent-improvement-evaluation-test--queue directory))
         (registry (nl-agent-tool-registry-new)))
    (unwind-protect
        (progn
          (nl-agent-improvement-register-tools registry queue)
          (should-not (nl-agent-improvement-evaluation-test--tool registry))
          (should (= (length (nl-agent-tool-catalog registry)) 5)))
      (delete-directory directory t))))

(ert-deftest nl-agent-improvement-evaluation-is-read-only-and-exact ()
  (let* ((scope (make-string 64 ?a))
         (fixture (nl-agent-improvement-evaluation-test--register
                   (nl-agent-improvement-evaluation-test--runner
                    scope "audit")))
         (registry (plist-get fixture :registry))
         (tool (nl-agent-improvement-evaluation-test--tool registry))
         (calls nil)
         (summary
          (list :format "nl-agent-task-evaluation-v1"
                :reference (list :scope scope :id "job" :attempt "try")
                :task-accepted t :before-passed 0 :after-passed 1
                :total 1 :regressions 0 :parent-score 0.0
                :candidate-score 1.0 :parent-generation 0
                :request-sha256 (make-string 64 ?b))))
    (unwind-protect
        (progn
          (should tool)
          (should (eq (nl-agent-tool-risk tool) 'read))
          (cl-letf (((symbol-function 'nl-agent-task-audit-summary)
                     (lambda (&rest args)
                       (setq calls args)
                       summary)))
            (let ((value (nl-agent-tool--invoke
                          tool (list :scope scope :id "job" :attempt "try") nil)))
              (should (equal calls (list "audit" scope "job" "try")))
              (should (equal (plist-get value :format)
                             "nl-agent-task-evaluation-v1"))
              (should-not (eq (plist-get value :reference)
                              (plist-get summary :reference)))
              (aset (plist-get (plist-get value :reference) :scope) 0 ?z)
              (should (= (aref (plist-get (plist-get summary :reference) :scope)
                               0)
                         ?a)))
            (should-error
             (nl-agent-tool--invoke
              tool (list :scope scope :scope scope :id "job" :attempt "try") nil))
            (should-error
             (nl-agent-tool--invoke
              tool (list :scope scope :id "job" :attempt "try" :extra 1) nil))))
      (delete-directory (plist-get fixture :directory) t))))

(ert-deftest nl-agent-improvement-evaluation-denies-scope-before-read ()
  (let* ((scope (make-string 64 ?a))
         (other (make-string 64 ?c))
         (fixture (nl-agent-improvement-evaluation-test--register
                   (nl-agent-improvement-evaluation-test--runner
                    scope "audit")))
         (tool (nl-agent-improvement-evaluation-test--tool
                (plist-get fixture :registry)))
         (calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'nl-agent-task-audit-summary)
                   (lambda (&rest _args) (setq calls (1+ calls))
                     (error "should not read"))))
          (let ((error-text
                 (condition-case error-data
                     (progn
                       (nl-agent-tool--invoke
                        tool (list :scope other :id "job" :attempt "try") nil)
                       nil)
                   (error (error-message-string error-data)))))
            (should (string-match-p "scope denied" error-text))
            (should (= calls 0))))
      (delete-directory (plist-get fixture :directory) t))))

(ert-deftest nl-agent-improvement-evaluation-hides-summary-errors ()
  (let* ((scope (make-string 64 ?a))
         (fixture (nl-agent-improvement-evaluation-test--register
                   (nl-agent-improvement-evaluation-test--runner
                    scope "audit")))
         (tool (nl-agent-improvement-evaluation-test--tool
                (plist-get fixture :registry))))
    (unwind-protect
        (cl-letf (((symbol-function 'nl-agent-task-audit-summary)
                   (lambda (&rest _args)
                     (error "secret task path /tmp/private"))))
          (let ((error-text
                 (condition-case error-data
                     (progn
                       (nl-agent-tool--invoke
                        tool (list :scope scope :id "job" :attempt "try") nil)
                       nil)
                   (error (error-message-string error-data)))))
            (should (equal error-text
                           "model improvement evaluation unavailable"))))
      (delete-directory (plist-get fixture :directory) t))))

(ert-deftest nl-agent-improvement-evaluation-reference-is-detached-and-stable ()
  (let* ((directory (make-temp-file "nl-improvement-reference-" t))
         (audit (expand-file-name "audit" directory))
         (scope (make-string 64 ?d))
         (queue (nl-agent-improvement-evaluation-test--queue directory))
         (profile (list :scope scope :benchmark [" a"]
                        :training '(:backend cpu :sequence 8 :optimizer sgd)
                        :directory directory))
         (runner (nl-agent-training-runner--make
                  :queue queue :profile profile
                  :task-audit-directory audit))
         (real-start-process (symbol-function 'start-process))
         started)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'start-process)
                     (lambda (_name _buffer _program &rest _args)
                       (funcall real-start-process "evaluation-test-child" nil
                                shell-file-name shell-command-switch
                                "sleep 5"))))
            (setq started
                  (nl-agent-training-runner-start runner
                                                  "evaluation-job")))
          (let* ((reference (plist-get started :evaluation-reference))
                 (status (nl-agent-training-runner-status runner)))
            (should (equal reference
                           (list :scope scope :id "evaluation-job"
                                 :attempt (plist-get reference :attempt))))
            (should (equal (plist-get status :evaluation-reference)
                           reference))
            (aset (plist-get reference :scope) 0 ?z)
            (should (= (aref (plist-get
                              (plist-get
                               (nl-agent-training-runner-status runner)
                               :evaluation-reference) :scope)
                             0)
                       ?d)))
          (nl-agent-training-runner-stop runner))
      (ignore-errors (nl-agent-training-runner-stop runner))
      (delete-directory directory t))))

(provide 'improvement-evaluation-test)

(ert-run-tests-batch-and-exit)
;;; improvement-evaluation-test.el ends here
