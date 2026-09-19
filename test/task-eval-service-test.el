;;; task-eval-service-test.el --- real service task evaluation -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-llm/lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-photon/lisp"))
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'nl-agent-task-suite)
(require 'nl-agent-task-eval)
(require 'nl-agent-task-eval-service)
(require 'nl-llm-agent-provider)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-improve)
(require 'nl-llm-agent-tokenizer)

(defun nl-agent-task-eval-service-test--read (path)
  "Return one scripted typed read action for PATH."
  (format "```tool\n(:name \"read\" :arguments (:path %S))\n```" path))

(defun nl-agent-task-eval-service-test--edit (path search replace)
  "Return one scripted exact edit of PATH from SEARCH to REPLACE."
  (format "%s\n<<<<<<< SEARCH\n%s\n=======\n%s\n>>>>>>> REPLACE"
          path search replace))

(defun nl-agent-task-eval-service-test--recipes ()
  "Return independently authored actions for the fixed suite.
This function does not receive or inspect suite expected values."
  (vector
   (list
    (nl-agent-task-eval-service-test--read "docs/guide.md")
    (nl-agent-task-eval-service-test--edit
     "docs/guide.md" "make strat" "make start")
    "DONE typo corrected")
   (list
    (nl-agent-task-eval-service-test--read "lisp/math.el")
    (nl-agent-task-eval-service-test--edit
     "lisp/math.el" "(+ n 2)" "(* n 2)")
    "DONE arithmetic corrected")
   (list
    (nl-agent-task-eval-service-test--read "lisp/greet.el")
    (nl-agent-task-eval-service-test--read "test/greet-test.el")
    (nl-agent-task-eval-service-test--edit
     "lisp/greet.el" "old-greeting" "current-greeting")
    (nl-agent-task-eval-service-test--edit
     "test/greet-test.el" "old-greeting" "current-greeting")
    "DONE definition and test renamed")
   (list
    (nl-agent-task-eval-service-test--read "config/app.json")
    (nl-agent-task-eval-service-test--edit
     "config/app.json" "\"retryCount\": 2" "\"retryCount\": 3")
    "DONE retry count changed")
   (list
    (nl-agent-task-eval-service-test--read "src/cache.el")
    (nl-agent-task-eval-service-test--read "src/cache-test.el")
    (nl-agent-task-eval-service-test--read "src/cache-old.el")
    (nl-agent-task-eval-service-test--edit
     "src/cache.el" "cache-size 10" "cache-size 20")
    "DONE selected cache file changed")
   (list
    (nl-agent-task-eval-service-test--read "messages/status.txt")
    (nl-agent-task-eval-service-test--read "messages/status-ascii.txt")
    (nl-agent-task-eval-service-test--edit
     "messages/status.txt" "状態: 失敗" "状態: 成功")
    "DONE Unicode status changed")))

(defun nl-agent-task-eval-service-test--scripted-provider ()
  "Return a provider whose literal recipes are private per fresh session."
  (let ((recipes (nl-agent-task-eval-service-test--recipes))
        (opened 0))
    (nl-llm-agent-provider-new
     "scripted" :models '("editor")
     :open
     (lambda (_model-id _options)
       (when (>= opened (length recipes))
         (error "scripted evaluator opened an unexpected extra session"))
       (prog1 (vector (copy-sequence (aref recipes opened)))
         (setq opened (1+ opened))))
     :complete
     (lambda (state _messages)
       (let* ((remaining (aref state 0))
              (reply (car remaining)))
         (unless reply
           (error "scripted evaluator requested an unexpected completion"))
         (aset state 0 (cdr remaining))
         reply))
     :close
     (lambda (state)
       (when (aref state 0)
         (error "scripted evaluator closed before consuming its recipe"))))))

(defun nl-agent-task-eval-service-test--done-provider ()
  "Return a provider which falsely claims completion without editing."
  (nl-llm-agent-provider-new
   "lying" :models '("done-only")
   :open (lambda (_model-id _options) nil)
   :complete (lambda (_state _messages) "DONE all requested edits complete")))

(defun nl-agent-task-eval-service-test--registry (provider)
  "Return a fresh registry containing PROVIDER."
  (let ((registry (nl-llm-agent-provider-registry-new)))
    (nl-llm-agent-provider-register registry provider)
    registry))

(defun nl-agent-task-eval-service-test--cli (&rest arguments)
  "Run the packaged task evaluator with ARGUMENTS and return status/output."
  (let ((output (generate-new-buffer " *task-eval-cli*"))
        (errors (make-temp-file "nl-agent-task-eval-cli-errors-"))
        status)
    (unwind-protect
        (progn
          (setq status
                (apply #'call-process
                       (expand-file-name "bin/nelisp-agent-eval")
                       nil (list output errors) nil arguments))
          (list :status status
                :output
                (with-current-buffer output
                  (buffer-substring-no-properties (point-min) (point-max)))
                :errors
                (with-temp-buffer
                  (insert-file-contents errors)
                  (buffer-substring-no-properties (point-min) (point-max)))))
      (kill-buffer output)
      (delete-file errors))))

(ert-deftest nl-agent-task-suite-factory-detaches-mutable-fixtures ()
  (let* ((first (nl-agent-task-suite-representative))
         (first-case (aref (plist-get first :cases) 0))
         (task (plist-get first-case :task))
         (input (plist-get (aref (plist-get first-case :files) 0) :text))
         (expected
          (plist-get (aref (plist-get first-case :expected) 0) :text)))
    (aset task 0 ?X)
    (aset input 0 ?Y)
    (aset expected 0 ?Z)
    (let* ((second (nl-agent-task-suite-representative))
           (second-case (aref (plist-get second :cases) 0)))
      (should-not (= (aref (plist-get second-case :task) 0) ?X))
      (should-not
       (= (aref (plist-get (aref (plist-get second-case :files) 0) :text) 0)
          ?Y))
      (should-not
       (= (aref (plist-get (aref (plist-get second-case :expected) 0)
                            :text)
                0)
          ?Z)))))

(ert-deftest nl-agent-task-eval-service-measures-files-not-done-claims ()
  (let* ((suite (nl-agent-task-suite-representative))
         (scripted-registry
          (nl-agent-task-eval-service-test--registry
           (nl-agent-task-eval-service-test--scripted-provider)))
         (lying-registry
          (nl-agent-task-eval-service-test--registry
           (nl-agent-task-eval-service-test--done-provider)))
         (read-count 0)
         (edit-count 0)
         (real-read (symbol-function 'nl-agent-local--read))
         (real-edit (symbol-function 'nl-agent-local--edit))
         positive before comparison)
    (cl-letf (((symbol-function 'nl-agent-local--read)
               (lambda (root args)
                 (setq read-count (1+ read-count))
                 (funcall real-read root args)))
              ((symbol-function 'nl-agent-local--edit)
               (lambda (root args)
                 (setq edit-count (1+ edit-count))
                 (funcall real-edit root args)))
              ((symbol-function 'nl-agent-local--shell)
               (lambda (&rest _args)
                 (error "file task evaluation exposed shell execution")))
              ((symbol-function 'nl-agent-local--elisp)
               (lambda (&rest _args)
                 (error "file task evaluation exposed Elisp execution"))))
      (setq positive
            (nl-agent-task-eval-service-run
             suite scripted-registry "scripted/editor" :max-steps 8)
            before
            (nl-agent-task-eval-service-run
             suite lying-registry "lying/done-only" :max-steps 8)
            comparison (nl-agent-task-eval-compare before positive)))
    (should (= read-count 10))
    (should (= edit-count 7))
    (should (= (plist-get positive :passed) 6))
    (should (= (plist-get positive :score) 1.0))
    (should (= (plist-get before :passed) 0))
    (should (= (plist-get before :score) 0.0))
    (dotimes (index (length (plist-get before :cases)))
      (let ((case (aref (plist-get before :cases) index)))
        (should (eq (plist-get case :status) 'done))
        (should (member 'content-mismatch
                        (append (plist-get case :failure-codes) nil)))))
    (should (= (plist-get comparison :passed-delta) 6))
    (should (= (plist-get comparison :score-delta) 1.0))))

(ert-deftest nl-agent-task-eval-real-utf8-native-done-baseline-scores-zero ()
  (let* ((directory (make-temp-file "nl-agent-task-native-eval-" t))
         (catalog (expand-file-name "catalog.json" directory))
         (model
          (nl-llm-agent-improve-model
           2 2 nil 1 1 nl-llm-agent-tokenizer-utf8))
         (registry (nl-llm-agent-provider-registry-new))
         report)
    (unwind-protect
        (progn
          (nl-llm-agent-artifact-publish
           catalog (nl-llm-agent-artifact-export-pav model)
           :id "done-g0" :name "Forced DONE wiring baseline"
           :grammar '(:type "template" :segments ["DONE baseline"])
           :maxseq 8192 :score 0.0 :generation 0)
          (nl-llm-agent-provider-register
           registry (nl-llm-agent-artifact-provider "native" catalog))
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _arguments)
                       (error "native task evaluation attempted HTTP"))))
            (setq report
                  (nl-agent-task-eval-service-run
                   (nl-agent-task-suite-representative)
                   registry "native/done-g0" :max-steps 2)))
          (should (equal (plist-get report :model-id) "native/done-g0"))
          (should (= (plist-get report :total) 6))
          (should (= (plist-get report :passed) 0))
          (should (= (plist-get report :score) 0.0))
          (dotimes (index (length (plist-get report :cases)))
            (let ((case (aref (plist-get report :cases) index)))
              (should (eq (plist-get case :status) 'done))
              (should-not (plist-get case :pass))))
          (let* ((cli
                  (nl-agent-task-eval-service-test--cli
                   "--native-catalog" catalog
                   "--model" "native/done-g0" "--max-steps" "2"))
                 (decoded
                  (json-parse-string
                   (string-trim (plist-get cli :output))
                   :object-type 'plist :array-type 'array)))
            (should (= (plist-get cli :status) 0))
            (should (= (plist-get decoded :score) 0.0))
            (should (= (plist-get decoded :passed) 0))
            (should (equal (plist-get decoded :model-id) "native/done-g0")))
          (let ((invalid
                 (nl-agent-task-eval-service-test--cli
                  "--native-catalog" catalog)))
            (should (= (plist-get invalid :status) 2))
            (should (string-empty-p (plist-get invalid :output)))
            (should (string-match-p "missing required evaluator option"
                                    (plist-get invalid :errors)))))
      (delete-directory directory t))))

(ert-run-tests-batch-and-exit)

;;; task-eval-service-test.el ends here
