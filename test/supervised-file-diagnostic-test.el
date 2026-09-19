;;; supervised-file-diagnostic-test.el --- diagnostic probe tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(defvar nl-agent-supervised-file-experiment-auto-run nil)
(defvar nl-agent-supervised-file-diagnostic-auto-run nil)
(defvar nl-agent-supervised-file-diagnostic-development-suite)
(defvar nl-agent-supervised-file-diagnostic-format)
(defvar nl-agent-supervised-file-diagnostic-max-trace-events)
(defvar nl-agent-supervised-file-diagnostic-max-trace-chars)
(defvar nl-agent-supervised-file-experiment-dim)
(defvar nl-agent-supervised-file-experiment-ff)
(defvar nl-agent-supervised-file-experiment-blocks)
(defvar nl-agent-supervised-file-experiment-heads)
(defvar nl-agent-supervised-file-experiment-sequence)
(defvar nl-agent-supervised-file-experiment-epochs)
(defvar nl-agent-supervised-file-experiment-learning-rate)

(declare-function nl-agent-supervised-file-experiment--training-suite
                  "../examples/evaluate-supervised-file-tasks" ())
(declare-function nl-agent-supervised-file-experiment--teacher-provider
                  "../examples/evaluate-supervised-file-tasks" ())
(declare-function nl-agent-supervised-file-experiment--parameter-count
                  "../examples/evaluate-supervised-file-tasks" (model))
(declare-function nl-agent-supervised-file-experiment--model-digest
                  "../examples/evaluate-supervised-file-tasks" (model))
(declare-function nl-agent-supervised-file-diagnostic--trace
                  "../examples/diagnose-supervised-file-tasks" (response))
(declare-function nl-agent-supervised-file-diagnostic--evaluate
                  "../examples/diagnose-supervised-file-tasks"
                  (label suite registry qualified-model))
(declare-function nl-llm-agent-improve-model "nl-llm-agent-improve"
                  (&optional dim ff vocab nblocks heads tokenizer))
(declare-function nl-llm-evolve-copy-model "nl-llm-evolve" (model))
(declare-function nl-llm-agent-provider-registry-new
                  "nl-llm-agent-provider" ())
(declare-function nl-llm-agent-provider-register
                  "nl-llm-agent-provider" (registry provider))
(declare-function nl-llm-agent-provider-new
                  "nl-llm-agent-provider" (id &rest keys))

(let ((noninteractive nil))
  (load
   (expand-file-name
    "../examples/diagnose-supervised-file-tasks.el"
    (file-name-directory (or load-file-name buffer-file-name)))
   nil nil t))

(ert-deftest nl-agent-supervised-file-diagnostic-plan-is-fixed-and-disjoint ()
  (let* ((training-suite
          (nl-agent-supervised-file-experiment--training-suite))
         (training-cases (plist-get training-suite :cases))
         (development-cases
          (plist-get
           nl-agent-supervised-file-diagnostic-development-suite :cases))
         (training-paths
          (mapcar
           (lambda (case)
             (plist-get (aref (plist-get case :files) 0) :path))
           (append training-cases nil)))
         (development-paths
          (mapcar
           (lambda (case)
             (plist-get (aref (plist-get case :files) 0) :path))
           (append development-cases nil)))
         (source
          (expand-file-name
           "../examples/diagnose-supervised-file-tasks.el"
           (file-name-directory (or load-file-name buffer-file-name)))))
    (should (equal nl-agent-supervised-file-diagnostic-format
                   "nl-agent-supervised-file-diagnostic-v1"))
    (should (= (length training-cases) 4))
    (should (= (length development-cases) 2))
    (should-not
     (cl-intersection training-paths development-paths :test #'equal))
    (should (equal development-paths '("dev/name.txt" "dev/count.txt")))
    (should (= (* 12 nl-agent-supervised-file-experiment-epochs) 192))
    (should (= nl-agent-supervised-file-experiment-sequence 2048))
    (should (= nl-agent-supervised-file-experiment-learning-rate 0.003))
    ;; The diagnostic source must not name or access the capability suite.
    (with-temp-buffer
      (insert-file-contents source)
      (should-not
       (search-forward
        "nl-agent-supervised-file-experiment-heldout" nil t)))))

(ert-deftest nl-agent-supervised-file-diagnostic-trace-is-explicitly-bounded ()
  (let* ((long (make-string
                (+ nl-agent-supervised-file-diagnostic-max-trace-chars 17)
                ?x))
         (events nil))
    (dotimes (index (1+ nl-agent-supervised-file-diagnostic-max-trace-events))
      (push
       (list :step (1+ index) :assistant long
             :action (list 'tool "read" (list :path long))
             :tool-result (list :status 'ok)
             :observation long)
       events))
    (let* ((projection
            (nl-agent-supervised-file-diagnostic--trace
             (list :status 'limit :steps 3
                   :trajectory (nreverse events))))
           (projected (plist-get projection :events))
           (first (aref projected 0)))
      (should (= (length projected)
                 nl-agent-supervised-file-diagnostic-max-trace-events))
      (should (= (plist-get projection :events-available)
                 (1+ nl-agent-supervised-file-diagnostic-max-trace-events)))
      (should (plist-get projection :events-truncated))
      (dolist (field '(:assistant :action :observation))
        (let ((value (plist-get first field)))
          (should (plist-get value :truncated))
          (should (= (length (plist-get value :text))
                     nl-agent-supervised-file-diagnostic-max-trace-chars))))
      (should (eq (plist-get first :tool-status) 'ok)))))

(ert-deftest nl-agent-supervised-file-diagnostic-real-file-trace ()
  ;; Run one fixed teacher sequence through the actual service, permission
  ;; policy, and confined read/edit tools.  Only the provider actions are
  ;; scripted; observations and file scoring are real.
  (let* ((all-cases
          (plist-get
           (nl-agent-supervised-file-experiment--training-suite) :cases))
         (suite
          (list :id "diagnostic-training-smoke" :version "1"
                :cases (vector (copy-tree (aref all-cases 0)))))
         (registry (nl-llm-agent-provider-registry-new)))
    (nl-llm-agent-provider-register
     registry (nl-agent-supervised-file-experiment--teacher-provider))
    (let* ((evaluation
            (nl-agent-supervised-file-diagnostic--evaluate
             "training-smoke" suite registry
             "teacher/training-demonstrations"))
           (score (plist-get evaluation :file-score))
           (trace (aref (plist-get evaluation :traces) 0))
           (events (plist-get (plist-get trace :runtime) :events)))
      (should (= (plist-get score :passed) 1))
      (should (= (plist-get score :total) 1))
      (should (= (length events) 3))
      (should (string-search "read"
                             (plist-get
                              (plist-get (aref events 0) :action) :text)))
      (should (string-search "status: old"
                             (plist-get
                              (plist-get (aref events 0) :observation) :text)))
      (should (string-search "edit"
                             (plist-get
                              (plist-get (aref events 1) :action) :text)))
      (should (eq (plist-get (aref events 0) :tool-status) 'ok))
      (should (eq (plist-get (aref events 1) :tool-status) 'ok))
      (should-not
       (plist-get (plist-get trace :runtime) :events-truncated)))))

(ert-deftest nl-agent-supervised-file-diagnostic-runtime-error-is-not-score ()
  (let* ((registry (nl-llm-agent-provider-registry-new))
         (suite
          '(:id "diagnostic-error" :version "1"
            :cases
            [(:id "broken" :task "synthetic"
              :files [(:path "x.txt" :text "x")]
              :expected [(:path "x.txt" :text "x")])]))
         failure)
    (nl-llm-agent-provider-register
     registry
     (nl-llm-agent-provider-new
      "broken" :models '((:id "model"))
      :open (lambda (&rest _) t)
      :complete (lambda (&rest _) (error "synthetic diagnostic failure"))))
    (setq failure
          (should-error
           (nl-agent-supervised-file-diagnostic--evaluate
            "broken" suite registry "broken/model")))
    (should
     (string-search "synthetic diagnostic failure"
                    (error-message-string failure)))))

(ert-deftest nl-agent-supervised-file-diagnostic-model-identity-is-fixed ()
  (let* ((base
          (nl-llm-agent-improve-model
           nl-agent-supervised-file-experiment-dim
           nl-agent-supervised-file-experiment-ff 256
           nl-agent-supervised-file-experiment-blocks
           nl-agent-supervised-file-experiment-heads "utf8-byte-v1"))
         (copy (nl-llm-evolve-copy-model base)))
    (should (= (nl-agent-supervised-file-experiment--parameter-count base)
               27264))
    (should
     (equal (nl-agent-supervised-file-experiment--model-digest base)
            (nl-agent-supervised-file-experiment--model-digest copy)))
    (should-not (eq base copy))))

(provide 'supervised-file-diagnostic-test)

(ert-run-tests-batch-and-exit)

;;; supervised-file-diagnostic-test.el ends here
