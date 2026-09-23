;;; config-test.el --- declarative NeLisp Agent configuration tests  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-config)

(defvar nl-agent-config-test--fail 0)

(defun nl-agent-config-test--ck (name ok)
  (princ (format "%-60s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-config-test--fail
                         (1+ nl-agent-config-test--fail))
                   "FAIL"))))

(defun nl-agent-config-test--error-p (thunk)
  (condition-case nil
      (progn (funcall thunk) nil)
    (error t)))

(let* ((requests nil)
       (transport
        (lambda (request)
          (push request requests)
          '(:choices ((:message (:content "configured reply"))))))
       (config
        (list
         :default-model "remote/vendor/model:free"
         :fallback-models '("remote/vendor/backup:free")
         :system "Configured system prompt"
         :options '(:temperature 0.25)
         :providers
         (list
          (list :id "remote"
                :type 'openai
                :base-url "https://provider.invalid/v1"
                :models '("vendor/model:free" "vendor/backup:free")
                :transport transport))))
       (service (nl-agent-config-open config)))
  (nl-agent-config-test--ck
   "config opens its default model through the provider registry"
   (equal (nl-agent-service-current-model service)
          "remote/vendor/model:free"))
  (let ((result (nl-agent-service-command service "hello")))
    (nl-agent-config-test--ck
     "configured OpenAI transport backs the unified service"
     (equal (plist-get result :text) "configured reply")))
  (nl-agent-config-test--ck
   "generation options cross the declarative boundary"
   (equal (plist-get (plist-get (car requests) :body) :temperature)
          0.25))
  (nl-agent-config-test--ck
   "system prompt is included in provider-neutral messages"
   (= (length
       (plist-get (plist-get (car requests) :body) :messages))
      2))
  (nl-agent-config-test--ck
   "declarative config carries fallback order into the service"
   (equal (nl-agent-service-fallbacks service)
          '("remote/vendor/backup:free"))))

(nl-agent-config-test--ck
 "config rejects unsupported provider types before opening"
 (nl-agent-config-test--error-p
  (lambda ()
    (nl-agent-config-registry
     '((:id "bad" :type mystery :models ("x")))))))

(let* ((registry
        (nl-agent-config-registry
         (list
          (list :id "brokered" :type 'broker :models '("remote")
                :call (lambda (_request) "broker reply")))))
       (service (nl-agent-service-new registry "brokered/remote")))
  (nl-agent-config-test--ck
   "config assembles a host-broker provider without service coupling"
   (equal (plist-get (nl-agent-service-command service "hello") :text)
          "broker reply")))

(nl-agent-config-test--ck
 "config rejects simultaneous direct and environment credentials"
 (nl-agent-config-test--error-p
  (lambda ()
    (nl-agent-config-registry
     '((:id "bad" :type openai
        :base-url "https://provider.invalid/v1"
        :models ("x") :api-key "secret" :api-key-env "KEY"))))))

(princ (format "NL-AGENT-CONFIG %s (%d failures)\n"
               (if (= nl-agent-config-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-config-test--fail))
(kill-emacs (if (= nl-agent-config-test--fail 0) 0 1))

;;; config-test.el ends here
