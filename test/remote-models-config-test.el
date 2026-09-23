;;; remote-models-config-test.el --- configurable remote model catalog tests  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(load (expand-file-name "../examples/free-models-config.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)

(defvar nl-agent-remote-models-config-test--fail 0)

(defun nl-agent-remote-models-config-test--ck (name ok)
  (princ (format "%-69s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-remote-models-config-test--fail
                         (1+ nl-agent-remote-models-config-test--fail))
                   "FAIL"))))

(let ((directory (file-name-directory (or load-file-name buffer-file-name
                                          default-directory)))
      (old-models (getenv "NELISP_AGENT_REMOTE_MODELS"))
      models)
  (unwind-protect
      (progn
        (setenv "NELISP_AGENT_REMOTE_MODELS" nil)
        (nl-agent-remote-models-config-test--ck
         "unset environment uses the hard-coded model catalog"
         (eq (nl-agent-example-remote-models)
             nl-agent-example-free-models))
        (nl-agent-remote-models-config-test--ck
         "unset environment uses the hard-coded default model"
         (equal (nl-agent-example-remote-default-model)
                nl-agent-example-default-model))
        (nl-agent-remote-models-config-test--ck
         "unset environment uses the hard-coded fallback models"
         (equal (nl-agent-example-remote-fallback-models)
                nl-agent-example-fallback-models))

        (setenv "NELISP_AGENT_REMOTE_MODELS" " a/b:free , c/d:free , ")
        (setq models (nl-agent-example-remote-models))
        (nl-agent-remote-models-config-test--ck
         "configured environment trims model IDs and omits empty items"
         (equal (mapcar (lambda (model) (plist-get model :id)) models)
                '("a/b:free" "c/d:free")))
        (nl-agent-remote-models-config-test--ck
         "configured environment names models by provider ID"
         (equal (mapcar (lambda (model) (plist-get model :name)) models)
                '("a/b:free" "c/d:free")))
        (nl-agent-remote-models-config-test--ck
         "configured environment selects the first model by default"
         (equal (nl-agent-example-remote-default-model)
                "remote/a/b:free"))
        (nl-agent-remote-models-config-test--ck
         "configured environment uses remaining models as fallbacks"
         (equal (nl-agent-example-remote-fallback-models)
                '("remote/c/d:free"))))
    (setenv "NELISP_AGENT_REMOTE_MODELS" old-models)))

(princ (format "NL-AGENT-REMOTE-MODELS %s (%d failures)\n"
               (if (= nl-agent-remote-models-config-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-remote-models-config-test--fail))
(kill-emacs (if (= nl-agent-remote-models-config-test--fail 0) 0 1))

;;; remote-models-config-test.el ends here
