;;; host-test.el --- standard host inference router tests  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-host)

(defvar nl-agent-host-test--fail 0)

(defun nl-agent-host-test--ck (name ok)
  (princ (format "%-62s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-host-test--fail
                         (1+ nl-agent-host-test--fail))
                   "FAIL"))))

(defun nl-agent-host-test--error-p (thunk)
  (condition-case nil
      (progn (funcall thunk) nil)
    (error t)))

(let* ((requests nil)
       (router
        (nl-agent-host-router-new
         (list
          (list
           :id "remote"
           :type 'openai
           :base-url "https://provider.invalid/v1"
           :models '("vendor/model:free")
           :transport
           (lambda (request)
             (setq requests (append requests (list request)))
             '(:choices ((:message (:content "remote reply")))))))))
       (inference (nl-agent-host-inference-function router))
       (event
        '(:event inference :request-id 7
          :provider "remote" :model "vendor/model:free"
          :options (:temperature 0.4)
          :messages ((system . "rules") (user . "hello"))))
       (result (funcall inference event)))
  (nl-agent-host-test--ck
   "standard host router returns OpenAI-compatible provider output"
   (equal result "remote reply"))
  (nl-agent-host-test--ck
   "host router forwards broker model, options, and messages"
   (let ((body (plist-get (car requests) :body)))
     (and (equal (plist-get body :model) "vendor/model:free")
          (equal (plist-get body :temperature) 0.4)
          (= (length (plist-get body :messages)) 2))))
  (nl-agent-host-test--ck
   "host model catalog callback exposes provider-qualified public data"
   (equal
    (mapcar
     (lambda (item) (plist-get item :qualified-id))
     (funcall (nl-agent-host-model-catalog-function router)))
    '("remote/vendor/model:free")))
  (nl-agent-host-test--ck
   "host router rejects malformed inference events"
   (nl-agent-host-test--error-p
    (lambda ()
      (nl-agent-host-infer router '(:event other :model "x"))))))

(let* ((calls nil)
       (registry (nl-agent-tool-registry-new))
       (policy
        (nl-agent-permission-policy-new
         :mode 'smart :approval (lambda (_request) 'once))))
  (nl-agent-tool-register
   registry
   (nl-agent-tool-new
    "shell"
    (lambda (args context)
      (setq calls (list args context))
      "host tool output")
    :risk 'execute))
  (let ((dispatch (nl-agent-host-tool-function registry policy)))
    (nl-agent-host-test--ck
     "host tool router authorizes and invokes a broker event"
     (and
      (equal
       (funcall dispatch
                '(:event tool :request-id 2 :tool "shell"
                  :args (:command "pwd") :context (:step 1)))
       "host tool output")
      (equal (car calls) '(:command "pwd"))))
    (nl-agent-host-test--ck
     "host tool router rejects malformed events"
     (nl-agent-host-test--error-p
      (lambda () (funcall dispatch '(:event inference :tool "shell")))))
    (nl-agent-host-test--ck
     "host catalog callback excludes invocation functions"
     (equal
      (funcall (nl-agent-host-tool-catalog-function registry))
      '((:name "shell" :description "" :risk execute :metadata nil))))))

(princ (format "NL-AGENT-HOST %s (%d failures)\n"
               (if (= nl-agent-host-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-host-test--fail))
(kill-emacs (if (= nl-agent-host-test--fail 0) 0 1))

;;; host-test.el ends here
