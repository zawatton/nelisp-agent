;;; bulk-eval-test.el --- fixed bulk-reader evaluation tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'nl-llm-agent-provider)
(require 'nl-agent-host)
(defconst nl-agent-bulk-eval-test--root
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))
(add-to-list 'load-path (expand-file-name "lisp" nl-agent-bulk-eval-test--root))
(add-to-list 'load-path (expand-file-name "../nelisp-llm/lisp" nl-agent-bulk-eval-test--root))
(add-to-list 'load-path (expand-file-name "../nelisp-photon/lisp" nl-agent-bulk-eval-test--root))
(load (expand-file-name "examples/evaluate-bulk-reader.el" nl-agent-bulk-eval-test--root) nil t)
(declare-function nl-agent-example-bulk-eval-load-corpus "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval-run "evaluate-bulk-reader.el")

(defun nl-agent-bulk-eval-test--scripted-router (mode calls)
  "Build a deterministic in-memory local/main and local/worker provider.
MODE controls main output (success, error, empty, or whitespace), and CALLS
receives `(MODEL MESSAGES OPTIONS)' records in call order."
  (let ((main-count 0))
    (nl-agent-host-router-new
     (list
      (nl-llm-agent-provider-new
       "local" :models '((:id "main") (:id "worker"))
       :open (lambda (model options) (list :model model :options options))
       :complete
       (lambda (state messages)
         (let ((model (plist-get state :model))
               (options (plist-get state :options)))
           (push (list model (copy-tree messages) (copy-tree options)) calls)
           (cond
            ((equal model "worker")
             (when (eq mode 'worker-failure)
               (error "scripted worker failure"))
             (let* ((user (cdr (assq 'user messages)))
                    (path (and (string-match
                                "\\\"path\\\":\\\"\\([^\\\"]+\\\)\\\"" user)
                               (match-string 1 user)))
                    (absent (and (string-match-p "責任者の携帯電話番号" user) t)))
               (unless absent (unless path (error "scripted worker saw no path")))
               (if absent
                   "{\"answer\":\"資料に記載されていません。\",\"references\":[],\"not_found\":true}"
                 (format "{\"answer\":\"scripted worker answer\",\"references\":[{\"path\":\"%s\",\"start_line\":1,\"end_line\":1}],\"not_found\":false}"
                         path))))
            ((equal model "main")
             (setq main-count (1+ main-count))
             (pcase mode
               ('error (error "scripted main failure"))
               ('empty "")
               ('whitespace "   ")
               (_ "scripted main answer")))
            (t (error "unexpected scripted model: %S" model))))
       :close (lambda (_state) nil)))))))

(defmacro nl-agent-bulk-eval-test--with-live (&rest body)
  (declare (indent 0))
  `(let ((old (getenv "NELISP_AGENT_BULK_EVAL_LIVE")))
     (unwind-protect
         (progn (setenv "NELISP_AGENT_BULK_EVAL_LIVE" "1") ,@body)
       (if old (setenv "NELISP_AGENT_BULK_EVAL_LIVE" old)
         (setenv "NELISP_AGENT_BULK_EVAL_LIVE" nil)))))

(defun nl-agent-bulk-eval-test--call-count (calls model)
  (cl-count model calls :key #'car :test #'equal))

(ert-deftest nl-agent-bulk-eval-corpus-is-fixed-and-bounded ()
  (let ((corpus (nl-agent-example-bulk-eval-load-corpus)))
    (should (= 5 (length (plist-get corpus :cases))))
    (should (string-match-p "\\`[0-9a-f]\\{64\\}\\'" (plist-get corpus :hash)))
    (should (equal (mapcar (lambda (case) (plist-get case :id))
                           (plist-get corpus :cases))
                   '("short-factual" "distractor-tail" "multi-file-negation"
                     "absent-answer" "quoted-instruction")))))

(ert-deftest nl-agent-bulk-eval-stub-does-not-contact-a-provider ()
  (let ((calls 0))
    (cl-letf (((symbol-function 'nl-llm-agent-session-open)
               (lambda (&rest _) (setq calls (1+ calls)) (error "provider called"))))
      (let* ((report (nl-agent-example-bulk-eval-run))
             (cases (plist-get report :cases))
             (absent (nth 3 cases)))
        (should (eq (plist-get report :mode) 'stub))
        (should (eq (plist-get report :metrics-source) 'mocked))
        (should (= calls 0))
        (should (= 5 (length cases)))
        (should (> (plist-get (plist-get (car cases) :direct)
                            :request-content-utf8-bytes) 0))
        (should (> (plist-get (plist-get (car cases) :delegated)
                            :serialized-input-utf8-bytes) 0))
        (should (eq (plist-get (plist-get (plist-get absent :direct) :screening)
                              :proxy-status)
                    'proxy-review))
        (should (null (plist-get (plist-get report :summary)
                                 :paired-combined-input-bytes)))))))

(ert-deftest nl-agent-bulk-eval-live-scripted-success-uses-real-pipeline ()
  (let ((calls nil))
    (nl-agent-bulk-eval-test--with-live
      (let* ((router (nl-agent-bulk-eval-test--scripted-router 'success calls))
             (report (nl-agent-example-bulk-eval-run
                      nil (list router "local/main" "local/worker")))
             (cases (plist-get report :cases))
             (summary (plist-get report :summary)))
        (should (eq (plist-get report :mode) 'live))
        (should (eq (plist-get report :metrics-source) 'empirical))
        (should (= 5 (plist-get summary :paired-cases)))
        (should (= 10 (nl-agent-bulk-eval-test--call-count calls "main")))
        (should (= 5 (nl-agent-bulk-eval-test--call-count calls "worker")))
        (should (> (plist-get summary :paired-direct-main-request-bytes) 0))
        (should (> (plist-get summary :paired-delegated-main-request-bytes) 0))
        (should (> (plist-get summary :paired-worker-request-bytes) 0))
        (should (= (+ (plist-get summary :paired-worker-request-bytes)
                      (plist-get summary :paired-delegated-main-request-bytes))
                   (plist-get summary :paired-combined-input-bytes)))
        (should (eq (plist-get summary :paired-metrics-coverage) 'complete))
        (dolist (case cases)
          (let* ((bulk (plist-get case :bulk-result))
                 (direct (plist-get case :direct))
                 (delegated (plist-get case :delegated))
                 (serialized (nl-agent-bulk-reader--tool-value bulk)))
            (should (eq (plist-get direct :status) 'usable))
            (should (eq (plist-get delegated :status) 'usable))
            (should (equal bulk (plist-get case :bulk-result)))
            (should (listp (plist-get bulk :metrics)))
            (should (or (plist-get bulk :references)
                        (plist-get bulk :not-found)))
            (should (= (plist-get delegated :serialized-input-utf8-bytes)
                       (string-bytes (encode-coding-string serialized 'utf-8 t))))
            (should (= (plist-get direct :request-content-utf8-bytes)
                       (nl-agent-example-bulk-eval--message-bytes
                        (nl-agent-example-bulk-eval--prompt
                         (plist-get case :question)
                         (nl-agent-example-bulk-eval--numbered
                          (plist-get case :sources))))))))))))

(ert-deftest nl-agent-bulk-eval-live-worker-failure-skips-delegated-main ()
  (let ((calls nil))
    (nl-agent-bulk-eval-test--with-live
      (let* ((router (nl-agent-bulk-eval-test--scripted-router 'worker-failure calls))
             (report (nl-agent-example-bulk-eval-run
                      nil (list router "local/main" "local/worker")))
             (summary (plist-get report :summary)))
        ;; The scripted provider's worker branch is made to fail below.
        (ignore router)
        (should (= 5 (plist-get summary :paired-cases)))
        (should (= 0 (plist-get summary :delegated-not-run)))
        (should (> (plist-get summary :paired-combined-input-bytes) 0))
        (should (= 10 (nl-agent-bulk-eval-test--call-count calls "main")))))))

(ert-deftest nl-agent-bulk-eval-live-main-failures-are-not-usable ()
  (dolist (mode '(error empty whitespace))
    (let ((calls nil))
      (nl-agent-bulk-eval-test--with-live
        (let* ((router (nl-agent-bulk-eval-test--scripted-router mode calls))
               (report (nl-agent-example-bulk-eval-run
                        nil (list router "local/main" "local/worker")))
               (cases (plist-get report :cases))
               (summary (plist-get report :summary)))
          (should (= 0 (plist-get summary :paired-cases)))
          (should (= 5 (plist-get summary :direct-failed)))
          (should (= 5 (plist-get summary :delegated-failed)))
          (dolist (case cases)
            (should (eq (plist-get (plist-get case :direct) :status) 'failed))
            (should (eq (plist-get (plist-get case :delegated) :status) 'failed))
            (when (eq mode 'empty)
              (should (= 0 (plist-get (plist-get case :direct)
                                      :output-utf8-bytes))))
            (when (eq mode 'error)
              (should (null (plist-get (plist-get case :direct)
                                       :output-utf8-bytes))))))))))

(ert-deftest nl-agent-bulk-eval-invalid-corpus-opens-no-inference ()
  (let ((directory (make-temp-file "nl-bulk-eval-invalid-" t))
        (calls nil))
    (unwind-protect
        (let ((path (expand-file-name "invalid.sexp" directory)))
          (with-temp-file path
            (insert "(:version 1 :cases ((:id \"bad\" :question 4 :paths () :required () :absent nil)))\n"))
          (nl-agent-bulk-eval-test--with-live
            (should-error
             (nl-agent-example-bulk-eval-run
              nil (list (nl-agent-bulk-eval-test--scripted-router 'success calls)
                        "local/main" "local/worker") path)))
          (should (= 0 (length calls))))
      (delete-directory directory t))))

(ert-deftest nl-agent-bulk-eval-source-is-large-distractor-fixture ()
  (let* ((path (expand-file-name "examples/bulk-reader-corpus/distractor-tail.txt"
                                nl-agent-bulk-eval-test--root))
         (bytes (file-attribute-size (file-attributes path))))
    (should (>= bytes 8000))))

(provide 'bulk-eval-test)
;;; bulk-eval-test.el ends here

(when noninteractive
  (ert-run-tests-batch-and-exit))
