;;; bulk-reader-test.el --- bounded bulk reader tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'nl-llm-agent-provider)
(require 'nl-agent-bulk-reader)

(defmacro nl-agent-bulk-reader-test--file (contents &rest body)
  (declare (indent 1))
  `(let ((directory (make-temp-file "nl-bulk-" t)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "sample.txt" directory)
             (insert ,contents))
           ,@body)
       (delete-directory directory t))))

(ert-deftest nl-agent-bulk-reader-test-path-boundaries ()
  (nl-agent-bulk-reader-test--file "safe\n"
    (let ((reader (nl-agent-bulk-reader--make :root directory)))
      (dolist (path '("../sample.txt" "/tmp/sample.txt" "~/sample.txt" "x/../sample.txt"))
        (should-error (nl-agent-bulk-reader--path reader path))))))

(ert-deftest nl-agent-bulk-reader-test-unicode-snapshot ()
  (nl-agent-bulk-reader-test--file "一行\n二行\n"
    (let* ((reader (nl-agent-bulk-reader--make :root directory))
           (source (car (nl-agent-bulk-reader-sources reader '("sample.txt")))))
      (should (= 2 (plist-get source :line-count)))
      (should (= 64 (length (plist-get source :sha256))))
      (should (equal "一行\n二行\n" (plist-get source :text))))))

(ert-deftest nl-agent-bulk-reader-test-stale-range ()
  (nl-agent-bulk-reader-test--file "one\ntwo\n"
    (let* ((reader (nl-agent-bulk-reader--make :root directory))
           (source (car (nl-agent-bulk-reader-sources reader '("sample.txt")))))
      (with-temp-file (expand-file-name "sample.txt" directory) (insert "changed\n"))
      (should-error (nl-agent-bulk-reader-read-range reader "sample.txt"
                                                     (plist-get source :sha256) 1 1)))))

(ert-deftest nl-agent-bulk-reader-test-range-excerpt-and-bound ()
  (nl-agent-bulk-reader-test--file "one\ntwo\nthree\n"
    (let* ((reader (nl-agent-bulk-reader--make :root directory))
           (source (car (nl-agent-bulk-reader-sources reader '("sample.txt"))))
           (range (nl-agent-bulk-reader-read-range reader "sample.txt"
                                                   (plist-get source :sha256) 2 3)))
      (should (equal (plist-get range :text) "two\nthree"))
      (should-error (nl-agent-bulk-reader-read-range reader "sample.txt"
                                                     (plist-get source :sha256) 1 4)))))

(ert-deftest nl-agent-bulk-reader-test-output-schema ()
  (let ((sources '((:path "sample.txt" :sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                    :text "line\n" :line-count 1))))
    (should-error
     (nl-agent-bulk-reader--validate-output nil
       "{\"answer\":\"x\",\"references\":[{\"path\":\"sample.txt\",\"start_line\":1,\"end_line\":1,\"extra\":1}],\"not_found\":false}"
       sources)))
  (should-error
   (nl-agent-bulk-reader--validate-output nil
     "{\"answer\":\"x\",\"references\":{},\"not_found\":true}" nil))
  (should-error
   (nl-agent-bulk-reader--validate-output nil
     "{\"answer\":\"x\",\"references\":null,\"not_found\":true}" nil)))

(ert-deftest nl-agent-bulk-reader-test-empty-reference-array-is-valid ()
  (should (equal
           (plist-get
            (nl-agent-bulk-reader--validate-output nil
              "{\"answer\":\"none\",\"references\":[],\"not_found\":true}" nil)
            :answer)
           "none")))
  (should-error
   (nl-agent-bulk-reader--validate-output nil
     "{\"answer\":\"none\",\"references\":[],\"not_found\":false}" nil))

(ert-deftest nl-agent-bulk-reader-test-exact-tool-args ()
  (should-error (nl-agent-bulk-reader--args '(:question "x") '(:question :paths) "bulk.read"))
  (should-error (nl-agent-bulk-reader--args '(:question "x" :paths nil :extra 1)
                                             '(:question :paths) "bulk.read")))

(ert-deftest nl-agent-bulk-reader-test-permission-denial-precedes-read ()
  (let* ((registry (nl-agent-tool-registry-new))
         (reader (nl-agent-bulk-reader--make :root (file-name-as-directory temporary-file-directory)))
         (policy (nl-agent-permission-policy-new :mode 'manual :unattended t)))
    (nl-agent-bulk-reader-register-tools registry reader)
    (let ((result (nl-agent-permission-call policy registry "bulk.read"
                                            '(:question "q" :paths ("missing")))))
      (should (eq (plist-get result :status) 'denied)))))

(ert-deftest nl-agent-bulk-reader-test-tool-value-is-complete-string ()
  (let ((value (nl-agent-bulk-reader--tool-value
                '(:status needs-review :references ((:path "a" :text "full"))
                  :answer "answer"))))
    (should (stringp value))
    (should (string-match-p "full" value))))

(ert-deftest nl-agent-bulk-reader-test-registered-roundtrip-under-print-limits ()
  (nl-agent-bulk-reader-test--file "trusted quote\nsecond\n"
    (let ((registry (nl-llm-agent-provider-registry-new)))
      (nl-llm-agent-provider-register
       registry (nl-llm-agent-provider-new "local" :models '((:id "model"))
                                           :open (lambda (_m _o) '(:live t))
                                           :complete (lambda (_s _m)
                                                       "{\"answer\":\"found\",\"references\":[{\"path\":\"sample.txt\",\"start_line\":1,\"end_line\":1}],\"not_found\":false}")
                                           :close (lambda (_s) nil)))
      (let* ((reader (nl-agent-bulk-reader-new (nl-agent-host-router-new registry)
                                                "local/model" '("local/model") directory))
             (tools (nl-agent-tool-registry-new))
             (policy (nl-agent-permission-policy-new :mode 'off)))
        (nl-agent-bulk-reader-register-tools tools reader)
        (let* ((print-length 1) (print-level 1)
               (call (nl-agent-permission-call policy tools "bulk.read"
                                               '(:question "q" :paths ("sample.txt"))))
               (value (read (plist-get call :text)))
               (ref (car (plist-get value :references)))
               (range (nl-agent-permission-call
                       policy tools "bulk.read-range"
                       (list :path (plist-get ref :path) :sha256 (plist-get ref :sha256)
                             :start-line 1 :end-line 1))))
          (should (equal (plist-get ref :text) "trusted quote"))
          (should (string-match-p "trusted quote" (plist-get range :text))))))))

(ert-deftest nl-agent-bulk-reader-test-local-file-rejections ()
  (let ((directory (make-temp-file "nl-bulk-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "bad.txt" directory)
            (set-buffer-multibyte nil) (insert "\xff"))
          (with-temp-file (expand-file-name "big.txt" directory)
            (set-buffer-multibyte nil)
            (insert (make-string (1+ (* 64 1024)) ?x)))
          (let ((reader (nl-agent-bulk-reader--make :root directory)))
            (should-error (nl-agent-bulk-reader-sources reader '("bad.txt")))
            (should-error (nl-agent-bulk-reader-sources reader '("big.txt")))
            (when (fboundp 'make-symbolic-link)
              (make-symbolic-link (expand-file-name "bad.txt" directory)
                                  (expand-file-name "link.txt" directory))
              (should-error (nl-agent-bulk-reader-sources reader '("link.txt"))))))
      (delete-directory directory t))))

(ert-deftest nl-agent-bulk-reader-test-provider-success-and-close ()
  (nl-agent-bulk-reader-test--file "answer line\n"
    (let ((closed nil)
          (registry (nl-llm-agent-provider-registry-new)))
      (nl-llm-agent-provider-register
       registry
       (nl-llm-agent-provider-new "local" :models '((:id "model"))
                                  :open (lambda (_model _options) '(:state live))
                                  :complete (lambda (_state _messages)
                                              "{\"answer\":\"found\",\"references\":[{\"path\":\"sample.txt\",\"start_line\":1,\"end_line\":1}],\"not_found\":false}")
                                  :close (lambda (_state) (setq closed t))))
      (let* ((router (nl-agent-host-router-new registry))
             (reader (nl-agent-bulk-reader-new router "local/model" '("local/model") directory))
             (result (nl-agent-bulk-reader-run reader "where?" '("sample.txt"))))
        (should (eq (plist-get result :status) 'needs-review))
        (should (equal (plist-get result :answer) "found"))
        (should closed)))))

(ert-deftest nl-agent-bulk-reader-test-json-mode-option-is-host-fixed ()
  (nl-agent-bulk-reader-test--file "line\n"
    (let ((options nil) (registry (nl-llm-agent-provider-registry-new)))
      (nl-llm-agent-provider-register
       registry (nl-llm-agent-provider-new "local" :models '((:id "model"))
                                           :open (lambda (_m opts) (setq options opts) '(:live t))
                                           :complete (lambda (_s _m) "{\"answer\":\"x\",\"references\":[{\"path\":\"sample.txt\",\"start_line\":1,\"end_line\":1}],\"not_found\":false}")
                                           :close (lambda (_s) nil)))
      (let ((reader (nl-agent-bulk-reader-new (nl-agent-host-router-new registry)
                                               "local/model" '("local/model") directory :json-mode t)))
        (nl-agent-bulk-reader-run reader "q" '("sample.txt"))
        (should (equal (plist-get options :response_format) '(:type "json_object"))))
      (should-error (nl-agent-bulk-reader-new (nl-agent-host-router-new registry)
                                               "local/model" '("local/model") directory :json-mode 'yes)))))

(ert-deftest nl-agent-bulk-reader-test-files-are-json-array-of-objects ()
  (let* ((messages (nl-agent-bulk-reader--messages
                    "q"
                    '((:path "a.txt" :sha256 "a" :line-count 2 :text "a")
                      (:path "b.txt" :sha256 "b" :line-count 3 :text "b"))))
         (user (cdr (assq 'user messages)))
         (json (substring user (string-match "Files (data JSON):\n" user)))
         (value (json-parse-string (substring json (length "Files (data JSON):\n"))
                                   :object-type 'alist :array-type 'array)))
    (should (vectorp value))
    (should (= (length value) 2))
    (should (equal (alist-get 'path (aref value 0)) "a.txt"))
    (should (equal (alist-get 'sha256 (aref value 1)) "b"))))

(ert-deftest nl-agent-bulk-reader-test-provider-failure-is-sanitized ()
  (nl-agent-bulk-reader-test--file "data\n"
    (let ((registry (nl-llm-agent-provider-registry-new)))
      (nl-llm-agent-provider-register
       registry
       (nl-llm-agent-provider-new "local" :models '((:id "model"))
                                  :open (lambda (_model _options) '(:state live))
                                  :complete (lambda (_state _messages) (error "secret provider detail"))
                                  :close (lambda (_state) nil)))
      (let* ((router (nl-agent-host-router-new registry))
             (reader (nl-agent-bulk-reader-new router "local/model" '("local/model") directory))
             (result (nl-agent-bulk-reader-run reader "where?" '("sample.txt"))))
        (should (eq (plist-get result :status) 'failed))
        (should-not (string-match-p "secret" (prin1-to-string result)))))))

;;; bulk-reader-test.el ends here

(when noninteractive
  (ert-run-tests-batch-and-exit))
