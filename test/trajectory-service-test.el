;;; trajectory-service-test.el --- packaged CLI trajectory capture -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-llm/lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-photon/lisp"))
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'nl-agent-cli)
(require 'nl-agent-trajectory)
(require 'nl-llm-agent-openai)

(defun nl-agent-trajectory-service-test--clear-environment ()
  "Remove ambient NeLisp Agent options from `process-environment'."
  (dolist (entry (copy-sequence process-environment))
    (when (string-prefix-p "NELISP_AGENT_" entry)
      (setenv (car (split-string entry "=")) nil))))

(defun nl-agent-trajectory-service-test--records (directory)
  "Return sorted trajectory record paths in DIRECTORY."
  (sort (directory-files directory t "\\`run-.*\\.sexp\\'") #'string<))

(defun nl-agent-trajectory-service-test--contents (file)
  "Return FILE contents literally."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (buffer-string)))

(defun nl-agent-trajectory-service-test--run
    (nelisp workspace task trajectory-directory &optional fail-publication)
  "Run TASK through the packaged CLI and return test observations.
When FAIL-PUBLICATION is non-nil, fail the trajectory's atomic rename."
  (let ((replies
         (list
          (concat
           "```tool\n"
           "(:name \"shell\" :arguments (:command \"pwd\"))\n"
           "```")
          "DONE trajectory complete"))
        (transport-calls 0)
        (approvals nil)
        (output nil)
        (save-calls 0)
        (saved-response nil)
        (real-rename (symbol-function 'rename-file))
        (real-save (symbol-function 'nl-agent-trajectory-save)))
    (cl-letf
        (((symbol-function 'nl-llm-agent-openai-default-transport)
          (lambda (_request)
            (setq transport-calls (1+ transport-calls))
            (let ((reply (pop replies)))
              (unless reply
                (error "unexpected repeated provider completion"))
              (list :choices (list (list :message (list :content reply)))))))
         ((symbol-function 'url-retrieve-synchronously)
          (lambda (&rest _arguments)
            (error "trajectory integration attempted external HTTP")))
         ((symbol-function 'nl-agent-cli-interactive-approval)
          (lambda (request &rest _arguments)
            (setq approvals (append approvals (list (copy-tree request))))
            'once))
         ((symbol-function 'nl-agent-cli--write-line)
          (lambda (text) (setq output (append output (list text)))))
         ((symbol-function 'nl-agent-trajectory-save)
          (lambda (directory saved-task response)
            (setq save-calls (1+ save-calls))
            (setq saved-response (copy-tree response))
            (funcall real-save directory saved-task response)))
         ((symbol-function 'rename-file)
          (lambda (file newname &optional ok-if-already-exists)
            (if (and fail-publication
                     trajectory-directory
                     (equal (file-name-directory (expand-file-name newname))
                            (file-name-as-directory
                             (expand-file-name trajectory-directory)))
                     (string-prefix-p "run-"
                                      (file-name-nondirectory newname)))
                (error "injected trajectory publication failure")
              (funcall real-rename file newname ok-if-already-exists)))))
      (let* ((arguments
              (append
               (list "--base-url" "https://provider.invalid/v1"
                     "--nelisp" nelisp
                     "--workspace" workspace)
               (and trajectory-directory
                    (list "--trajectory-directory" trajectory-directory))
               (list "--task" task)))
             (exit (nl-agent-cli-run-options
                    (nl-agent-cli-parse-args arguments))))
        (list :exit exit :output output :approvals approvals
              :transport-calls transport-calls :remaining replies
              :save-calls save-calls :response saved-response)))))

(ert-deftest nl-agent-packaged-cli-persists-unverified-tool-trajectory ()
  (let* ((project-directory default-directory)
         (nelisp
          (expand-file-name
           (or (getenv "NELISP_BIN") "../nelisp/target/nelisp")
           project-directory))
         (directory (make-temp-file "nl-agent-trajectory-service-" t))
         (workspace (expand-file-name "workspace" directory))
         (records (expand-file-name "records" directory))
         (failed-records (expand-file-name "failed" directory))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (make-directory workspace)
          (make-directory records)
          (make-directory failed-records)
          (nl-agent-trajectory-service-test--clear-environment)

          (let* ((task "report the workspace directory")
                 (first
                  (nl-agent-trajectory-service-test--run
                   nelisp workspace task records))
                 (paths (nl-agent-trajectory-service-test--records records))
                 (path (car paths))
                 (record (and path (nl-agent-trajectory-read path)))
                 (response (plist-get first :response))
                 (events (plist-get record :trajectory))
                 (tool-result (plist-get (car events) :tool-result))
                 (authorization (plist-get tool-result :authorization))
                 (approval (car (plist-get first :approvals))))
            (should (= (plist-get first :exit) 0))
            (should (= (plist-get first :transport-calls) 2))
            (should (= (plist-get first :save-calls) 1))
            (should-not (plist-get first :remaining))
            (should (equal (plist-get first :output)
                           '("trajectory complete")))
            (should (= (length paths) 1))
            (should (equal (plist-get record :format)
                           "nl-agent-trajectory-v1"))
            (should (equal (plist-get record :task) task))
            (should (eq (plist-get record :status) 'done))
            (should (= (plist-get record :steps) 2))
            (should (equal (plist-get record :result)
                           "trajectory complete"))
            (should (equal (plist-get record :evidence) "unverified"))
            (let ((tail record)
                  (keys nil))
              (while tail
                (setq keys (append keys (list (car tail))))
                (setq tail (cddr tail)))
              (should
               (equal keys
                      '(:format :task :status :steps :result
                        :trajectory :evidence))))
            (should-not (plist-member record :messages))
            (should-not (plist-member record :verified))
            (should (plist-member response :messages))
            (should (equal events (plist-get response :trajectory)))
            (should (= (length events) 2))
            (should (equal (plist-get tool-result :tool) "shell"))
            (should (eq (plist-get authorization :decision) 'allow))
            ;; The worker records its transport policy; the host-side approval
            ;; callback below is the separate authoritative permission proof.
            (should (eq (plist-get authorization :source) 'policy))
            (should (equal (plist-get approval :tool) "shell"))
            (should (eq (plist-get approval :risk) 'execute))
            (should (equal (plist-get approval :args) '(:command "pwd")))
            (should (equal (plist-get (plist-get approval :context) :task)
                           task))
            (should
             (string-match-p
              (regexp-quote (directory-file-name (file-truename workspace)))
              (plist-get (car events) :observation)))

            ;; A fresh CLI invocation owns a fresh worker and unique record;
            ;; publishing it must leave the earlier immutable record untouched.
            (let* ((original (nl-agent-trajectory-service-test--contents path))
                   (second
                    (nl-agent-trajectory-service-test--run
                     nelisp workspace "report it again" records))
                   (updated
                    (nl-agent-trajectory-service-test--records records)))
              (should (= (plist-get second :exit) 0))
              (should (= (plist-get second :transport-calls) 2))
              (should (= (length (plist-get second :approvals)) 1))
              (should (= (plist-get second :save-calls) 1))
              (should (= (length updated) 2))
              (should (member path updated))
              (should (equal original
                             (nl-agent-trajectory-service-test--contents path)))
              (should
               (equal
                (sort (mapcar (lambda (item)
                                (plist-get (nl-agent-trajectory-read item) :task))
                              updated)
                      #'string<)
                '("report it again" "report the workspace directory")))))

          ;; Without the opt-in option, even a successful tool trajectory is
          ;; returned normally and no recording directory is touched.
          (let ((disabled
                 (nl-agent-trajectory-service-test--run
                  nelisp workspace "do not save this" nil)))
            (should (= (plist-get disabled :exit) 0))
            (should (= (plist-get disabled :transport-calls) 2))
            (should (= (plist-get disabled :save-calls) 0))
            (should-not (plist-get disabled :response)))

          ;; Exercise the store's real atomic-publication failure.  The done
          ;; response remains successful and the worker tool call is not retried.
          (let ((failed
                 (nl-agent-trajectory-service-test--run
                  nelisp workspace "survive failed capture" failed-records t)))
            (should (= (plist-get failed :exit) 0))
            (should (= (plist-get failed :transport-calls) 2))
            (should (= (plist-get failed :save-calls) 1))
            (should (= (length (plist-get failed :approvals)) 1))
            (should-not (plist-get failed :remaining))
            (should (= (length (plist-get failed :output)) 1))
            (should (string-prefix-p "trajectory complete\nWARNING: "
                                     (car (plist-get failed :output))))
            (should (string-match-p "injected trajectory publication failure"
                                    (car (plist-get failed :output))))
            (should-not
             (directory-files failed-records nil
                              directory-files-no-dot-files-regexp))))
      (delete-directory directory t))))

(ert-run-tests-batch-and-exit)

;;; trajectory-service-test.el ends here
