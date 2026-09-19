;;; task-eval-service-adapter-test.el --- confined evaluation adapter tests -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path
             (or (getenv "NELISP_LLM_LISP")
                 (expand-file-name "../nelisp-llm/lisp")))

(require 'ert)
(require 'nl-llm-agent-provider)
(require 'nl-agent-task-eval-service)

(defun nl-agent-task-eval-adapter-test--provider (events scenario)
  "Return a deterministic provider recording EVENTS under mutable SCENARIO."
  (nl-llm-agent-provider-new
   "fixed" :models '("model" "other")
   :open
   (lambda (model _options)
     (setcar events (cons (list 'open model) (car events)))
     (vector 0 (car scenario)))
   :complete
   (lambda (state messages)
     (setcar events (cons (list 'complete (copy-tree messages)) (car events)))
     (let ((step (aref state 0))
           (kind (aref state 1)))
       (aset state 0 (1+ step))
       (pcase kind
         ('edit
          (pcase step
            (0 (concat "```tool\n"
                       "(:name \"read\" :arguments (:path \"task.txt\"))\n"
                       "```"))
            (1 (concat "task.txt\n"
                       "<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE"))
            (_ "DONE exact file edited")))
         ('forbidden
          (if (= step 0)
              (concat "```tool\n"
                      "(:name \"shell\" :arguments (:command \"false\"))\n"
                      "```")
            "DONE unavailable capability stayed unavailable"))
         ('error (error "scripted provider failure"))
         (_ (error "unknown scripted scenario")))))
   :close
   (lambda (_state)
     (setcar events (cons '(close) (car events))))))

(defun nl-agent-task-eval-adapter-test--registry (events scenario)
  "Return a registry containing the scripted fixed provider."
  (let ((registry (nl-llm-agent-provider-registry-new)))
    (nl-llm-agent-provider-register
     registry (nl-agent-task-eval-adapter-test--provider events scenario))
    (nl-llm-agent-provider-register
     registry
     (nl-llm-agent-provider-new
      "unused" :models '("model")
      :open (lambda (&rest _args) (error "unused provider was opened"))
      :complete (lambda (&rest _args) (error "unused provider completed"))))
    registry))

(defun nl-agent-task-eval-adapter-test--write (directory text)
  "Write TEXT to the task fixture beneath DIRECTORY."
  (with-temp-file (expand-file-name "task.txt" directory)
    (insert text)))

(defun nl-agent-task-eval-adapter-test--text (directory)
  "Return the task fixture text beneath DIRECTORY."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "task.txt" directory))
    (buffer-string)))

(ert-deftest nl-agent-task-eval-service-fresh-fixed-model-file-runs ()
  (let* ((events (list nil))
         (scenario (list 'edit))
         (registry
          (nl-agent-task-eval-adapter-test--registry events scenario))
         (runner
          (nl-agent-task-eval-service-runner registry "fixed/model"))
         (first (make-temp-file "nl-agent-eval-adapter-a-" t))
         (second (make-temp-file "nl-agent-eval-adapter-b-" t)))
    (unwind-protect
        (progn
          (nl-agent-task-eval-adapter-test--write first "old\n")
          (nl-agent-task-eval-adapter-test--write second "old\n")
          (let ((one (funcall runner "edit the fixture" first 4))
                (two (funcall runner "edit the fixture" second 4)))
            (should (equal (plist-get one :status) 'done))
            (should (equal (plist-get two :status) 'done))
            (should-not (plist-member one :kind))
            (should (equal (nl-agent-task-eval-adapter-test--text first)
                           "new\n"))
            (should (equal (nl-agent-task-eval-adapter-test--text second)
                           "new\n"))
            (dolist (result (list one two))
              (let* ((trajectory (plist-get result :trajectory))
                     (read-auth
                      (plist-get
                       (plist-get (car trajectory) :tool-result)
                       :authorization))
                     (edit-auth
                      (plist-get
                       (plist-get (cadr trajectory) :tool-result)
                       :authorization)))
                (should (eq (plist-get read-auth :source) 'policy))
                (should (eq (plist-get edit-auth :source) 'approval)))))
          (let* ((all (car events))
                 (opens (cl-remove-if-not
                         (lambda (event) (eq (car event) 'open)) all))
                 (closes (cl-remove-if-not
                          (lambda (event) (eq (car event) 'close)) all))
                 (first-request
                  (cadr
                   (cl-find-if
                    (lambda (event) (eq (car event) 'complete)) all)))
                 (system (cdr (car first-request))))
            (should (= (length opens) 2))
            (should (= (length closes) 2))
            (should (cl-every
                     (lambda (event) (equal (cadr event) "model")) opens))
            (should (string-match-p "- read \\[read\\]" system))
            (should (string-match-p "- edit \\[write\\]" system))
            (should-not (string-match-p "- shell \\[" system))
            (should-not (string-match-p "- elisp \\[" system))))
      (delete-directory first t)
      (delete-directory second t))))

(ert-deftest nl-agent-task-eval-service-hides-nonfile-capabilities ()
  (let* ((events (list nil))
         (scenario (list 'forbidden))
         (registry
          (nl-agent-task-eval-adapter-test--registry events scenario))
         (runner
          (nl-agent-task-eval-service-runner registry "fixed/model"))
         (workspace (make-temp-file "nl-agent-eval-adapter-deny-" t)))
    (unwind-protect
        (let* ((result (funcall runner "do not execute" workspace 3))
               (tool-result
                (plist-get (car (plist-get result :trajectory)) :tool-result)))
          (should (eq (plist-get result :status) 'done))
          (should (eq (plist-get tool-result :status) 'error))
          (should (string-match-p "unknown tool: shell"
                                  (plist-get tool-result :error)))
          (should (= (length
                      (cl-remove-if-not
                       (lambda (event) (eq (car event) 'close))
                       (car events)))
                     1)))
      (delete-directory workspace t))))

(ert-deftest nl-agent-task-eval-service-closes-on-runtime-error ()
  (let* ((events (list nil))
         (scenario (list 'error))
         (registry
          (nl-agent-task-eval-adapter-test--registry events scenario))
         (runner
          (nl-agent-task-eval-service-runner registry "fixed/model"))
         (workspace (make-temp-file "nl-agent-eval-adapter-error-" t)))
    (unwind-protect
        (let ((result (funcall runner "trigger failure" workspace 2)))
          (should (eq (plist-get result :status) 'error))
          (should (= (length
                      (cl-remove-if-not
                       (lambda (event) (eq (car event) 'close))
                       (car events)))
                     1)))
      (delete-directory workspace t))))

(ert-deftest nl-agent-task-eval-service-requires-qualified-fixed-model ()
  (let* ((events (list nil))
         (scenario (list 'edit))
         (registry
          (nl-agent-task-eval-adapter-test--registry events scenario)))
    (should-error (nl-agent-task-eval-service-runner registry "model"))
    (should-error (nl-agent-task-eval-service-runner registry "unused/nope"))
    (should-not (car events))))

(ert-deftest nl-agent-task-eval-service-report-fixes-model-and-runner ()
  (let* ((events (list nil))
         (scenario (list 'edit))
         (registry
          (nl-agent-task-eval-adapter-test--registry events scenario))
         (suite
          '(:id "adapter" :version "1"
            :cases [(:id "edit" :task "replace old with new"
                     :files [(:path "task.txt" :text "old\n")]
                     :expected [(:path "task.txt" :text "new\n")])]))
         (report
          (nl-agent-task-eval-service-run
           suite registry "fixed/model" :max-steps 4)))
    (should (equal (plist-get report :model-id) "fixed/model"))
    (should (equal (plist-get report :runner-id)
                   nl-agent-task-eval-service-runner-id))
    (should (= (plist-get report :passed) 1))
    (should (= (plist-get report :total) 1))
    (should-error
     (nl-agent-task-eval-service-run
      suite registry "fixed/model" :model-id "unused/model"))))

(provide 'task-eval-service-adapter-test)

(ert-run-tests-batch-and-exit)

;;; task-eval-service-adapter-test.el ends here
