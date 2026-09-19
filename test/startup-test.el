;;; startup-test.el --- startup selection protocol tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'nl-agent-startup)
(require 'nl-agent-supervisor)
(require 'nl-agent-stdio)

(ert-deftest nl-agent-startup-validator-accepts-nil-and-detaches-data ()
  (should-not (nl-agent-startup-validate-config nil))
  (let* ((model (copy-sequence "remote/main"))
         (fallback (copy-sequence "native/team/model"))
         (source (list :model model :fallbacks (list fallback)))
         (validated (nl-agent-startup-validate-config source)))
    (should (equal validated source))
    (should-not (eq validated source))
    (should-not (eq (plist-get validated :model) model))
    (should-not (eq (car (plist-get validated :fallbacks)) fallback))
    (aset model 0 ?X)
    (aset fallback 0 ?X)
    (should (equal validated
                   '(:model "remote/main"
                     :fallbacks ("native/team/model"))))))

(ert-deftest nl-agent-startup-validator-rejects-malformed-data ()
  (dolist (value
           '((:model "remote/main")
             (:fallbacks nil)
             (:model "remote/main" :fallbacks nil :extra t)
             (:model "remote/main" :model "native/main" :fallbacks nil)
             (:model "unqualified" :fallbacks nil)
             (:model "/empty-provider" :fallbacks nil)
             (:model "empty-model/" :fallbacks nil)
             (:model "remote/main" :fallbacks ("bad"))
             (:model "remote/main" :fallbacks . "bad")))
    (should-error (nl-agent-startup-validate-config value)))
  (should-error
   (nl-agent-startup-validate-config
    (list :model "remote/main" :fallbacks (cons "native/main" "tail"))))
  (let ((config (list :model "remote/main" :fallbacks nil))
        (fallbacks (list "native/main")))
    (setcdr (last config) config)
    (should-error (nl-agent-startup-validate-config config))
    (setcdr fallbacks fallbacks)
    (should-error
     (nl-agent-startup-validate-config
      (list :model "remote/main" :fallbacks fallbacks)))))

(ert-deftest nl-agent-startup-validator-runs-under-standalone-nelisp ()
  (let* ((project
          (file-name-directory
           (directory-file-name
            (file-name-directory (or load-file-name buffer-file-name)))))
         (nelisp
          (expand-file-name
           (or (getenv "NELISP_BIN") "../nelisp/target/nelisp") project))
         (module (expand-file-name "lisp/nl-agent-startup.el" project)))
    (unless (file-executable-p nelisp)
      (ert-skip "standalone NeLisp binary unavailable"))
    (let ((script (make-temp-file "nl-agent-startup-standalone-" nil ".el")))
      (unwind-protect
          (progn
            (with-temp-file script
              (prin1 `(load ,module) (current-buffer))
              (terpri (current-buffer))
              (insert
               "(unless (equal (nl-agent-startup-validate-config "
               "'(:model \"native/base\" :fallbacks (\"remote/a\"))) "
               "'(:model \"native/base\" :fallbacks (\"remote/a\"))) "
               "(error \"valid startup rejected\"))\n"
               "(dolist (bad '((:model \"bad\" :fallbacks nil) "
               "(:model \"native/base\" :fallbacks nil :unknown t) "
               "(:model \"native/base\" :model \"remote/a\" :fallbacks nil) "
               "(:model \"native/base\" :fallbacks . \"tail\"))) "
               "(unless (condition-case nil "
               "(progn (nl-agent-startup-validate-config bad) nil) "
               "(error t)) (error \"invalid startup accepted: %S\" bad)))\n"
               "'startup-validator-pass\n"))
            (with-temp-buffer
              (should (= 0 (call-process nelisp nil (current-buffer) nil
                                         "--load" script)))
              (should (string-match-p "startup-validator-pass"
                                      (buffer-string)))))
        (when (file-exists-p script) (delete-file script))))))

(ert-deftest nl-agent-supervisor-validates-and-detaches-startup-config ()
  (let* ((model (copy-sequence "native/base"))
         (config (list :model model :fallbacks '("remote/backup")))
         (supervisor
          (nl-agent-supervisor-new
           '("unused") :directory default-directory :startup-config config)))
    (aset model 0 ?X)
    (should
     (equal (nl-agent-supervisor-startup-config supervisor)
            '(:model "native/base" :fallbacks ("remote/backup"))))
    (should-error
     (nl-agent-supervisor-new
      '("unused") :directory default-directory
      :startup-config '(:model "not-qualified" :fallbacks nil)))))

(ert-deftest nl-agent-supervisor-serves-startup-config-during-await-ready ()
  (let* ((supervisor
          (nl-agent-supervisor-new
           '("unused") :directory default-directory
           :startup-config '(:model "native/base" :fallbacks nil)))
         (lines '("(:event startup-config :request-id 17)"
                  "(:event ready)"))
         sent)
    (cl-letf (((symbol-function 'nl-agent-supervisor--next-line)
               (lambda (_supervisor) (pop lines)))
              ((symbol-function 'nl-agent-supervisor--send)
               (lambda (_supervisor form) (push form sent))))
      (nl-agent-supervisor--await-ready supervisor))
    (should
     (equal sent
            '((startup-config-result 17
                                     (:model "native/base" :fallbacks nil)))))))

(ert-deftest nl-agent-supervisor-serves-nil-startup-during-call ()
  (let* ((supervisor
          (nl-agent-supervisor-new '("unused") :directory default-directory))
         (lines '("(:event startup-config :request-id 3)"
                  "(:status ok :kind status)"))
         sent response)
    (cl-letf (((symbol-function 'nl-agent-supervisor--next-line)
               (lambda (_supervisor) (pop lines)))
              ((symbol-function 'nl-agent-supervisor--send)
               (lambda (_supervisor form) (setq sent (append sent (list form))))))
      (setq response (nl-agent-supervisor--call-raw supervisor '(status))))
    (should (equal response '(:status ok :kind status)))
    (should
     (equal sent
            '((status) (startup-config-result 3 nil))))))

(ert-deftest nl-agent-stdio-requests-correlated-startup-config ()
  (let ((nl-agent-stdio--next-request-id 0)
        sent)
    (cl-letf (((symbol-function 'nl-agent-stdio-write)
               (lambda (form) (setq sent form)))
              ((symbol-function 'nl-agent-stdio-next-line)
               (lambda ()
                 "(startup-config-result 1 (:model \"native/base\" :fallbacks (\"remote/a\")))")))
      (should
       (equal
        (nl-agent-stdio-host-startup-config)
        '(:model "native/base" :fallbacks ("remote/a")))))
    (should (equal sent '(:event startup-config :request-id 1)))))

(ert-deftest nl-agent-stdio-rejects-startup-errors-and-mismatches ()
  (dolist (line
           '("(startup-config-result 2 nil)"
             "(startup-config-result 1 (:model \"bad\" :fallbacks nil))"
             "(startup-config-error 1 \"host rejected selection\")"
             "(model-catalog-result 1 nil)"))
    (let ((nl-agent-stdio--next-request-id 0))
      (cl-letf (((symbol-function 'nl-agent-stdio-write) (lambda (_form) nil))
                ((symbol-function 'nl-agent-stdio-next-line)
                 (lambda () line)))
        (should-error (nl-agent-stdio-host-startup-config))))))

(provide 'startup-test)

(ert-run-tests-batch-and-exit)

;;; startup-test.el ends here
