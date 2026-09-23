;;; broker-test.el --- host-broker provider tests  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-service)
(require 'nl-agent-broker)

(defvar nl-agent-broker-test--fail 0)

(defun nl-agent-broker-test--ck (name ok)
  (princ (format "%-61s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-broker-test--fail
                         (1+ nl-agent-broker-test--fail))
                   "FAIL"))))

(let* ((requests nil)
       (provider
        (nl-agent-broker-provider
         "host"
         '((:id "primary" :name "Primary")
           (:id "fallback" :name "Fallback"))
         (lambda (request)
           (setq requests (append requests (list request)))
           (if (equal (plist-get request :model) "primary")
               (error "upstream primary failed")
             "host reply"))))
       (registry (nl-llm-agent-provider-registry-new)))
  (nl-llm-agent-provider-register registry provider)
  (let* ((service
          (nl-agent-service-new
           registry "host/primary"
           :options '(:temperature 0.3)
           :fallbacks '("host/fallback")))
         (result (nl-agent-service-command service "hello")))
    (nl-agent-broker-test--ck
     "broker inference errors enter the normal fallback path"
     (and (eq (plist-get result :status) 'ok)
          (equal (plist-get result :model) "host/fallback")
          (equal (plist-get result :text) "host reply")))
    (nl-agent-broker-test--ck
     "broker request contains provider, model, options, and messages"
     (let ((request (cadr requests)))
       (and (eq (plist-get request :kind) 'inference)
            (equal (plist-get request :provider) "host")
            (equal (plist-get request :model) "fallback")
            (equal (plist-get request :options) '(:temperature 0.3))
            (equal (plist-get request :messages) '((user . "hello"))))))
    (nl-agent-broker-test--ck
     "broker catalog remains provider-neutral and public"
     (equal
      (mapcar
       (lambda (model) (plist-get model :qualified-id))
       (nl-agent-service-models service))
      '("host/primary" "host/fallback"))))

  (let* ((bad-provider
          (nl-agent-broker-provider
           "bad-host" '("bad") (lambda (_request) 42)))
         (bad-registry (nl-llm-agent-provider-registry-new)))
    (nl-llm-agent-provider-register bad-registry bad-provider)
    (let* ((service (nl-agent-service-new bad-registry "bad-host/bad"))
           (result (nl-agent-service-command service "hello")))
      (nl-agent-broker-test--ck
       "broker rejects a non-text host result without committing history"
       (and (eq (plist-get result :status) 'error)
            (null (nl-agent-service-messages service)))))))

(princ (format "NL-AGENT-BROKER %s (%d failures)\n"
               (if (= nl-agent-broker-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-broker-test--fail))
(kill-emacs (if (= nl-agent-broker-test--fail 0) 0 1))

;;; broker-test.el ends here
