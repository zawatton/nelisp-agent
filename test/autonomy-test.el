;;; autonomy-test.el --- reusable scoped autonomy policy tests  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'cl-lib)
(require 'nl-agent-autonomy)

(defvar nl-agent-autonomy-test--fail 0)

(defun nl-agent-autonomy-test--ck (name ok)
  (princ (format "%-70s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-autonomy-test--fail
                         (1+ nl-agent-autonomy-test--fail))
                   "FAIL"))))

(defun nl-agent-autonomy-test--error-p (thunk)
  (condition-case nil
      (progn (funcall thunk) nil)
    (error t)))

(let ((approval
       (nl-agent-autonomy-improvement-approval "native" "self")))
  (nl-agent-autonomy-test--ck
   "bounded improvement mutations receive autonomous one-call authority"
   (cl-every
    (lambda (tool)
      (eq (funcall approval (list :tool tool :args nil)) 'autonomous))
    '("model.improvement.submit"
      "model.improvement.run"
      "model.improvement.resume"
      "model.improvement.cancel")))
  (nl-agent-autonomy-test--ck
   "only the exact provider-qualified self generation may be activated"
   (eq
    (funcall
     approval
     '(:tool "service.model.switch"
       :args (:selector "native/self-g42")))
    'autonomous))
  (nl-agent-autonomy-test--ck
   "remote, unqualified, malformed, and unrelated requests remain denied"
   (cl-every
    (lambda (request) (eq (funcall approval request) 'deny))
    '((:tool "service.model.switch"
       :args (:selector "remote/self-g42"))
      (:tool "service.model.switch" :args (:selector "self-g42"))
      (:tool "service.model.switch"
       :args (:selector "native/self-g42/extra"))
      (:tool "shell" :args (:command "pwd")))))
  (let* ((calls 0)
         (composed
          (nl-agent-autonomy-improvement-approval
           "native" "self"
           (lambda (_request)
             (setq calls (1+ calls))
             'session))))
    (nl-agent-autonomy-test--ck
     "unscoped requests delegate to the ordinary host approval callback"
     (and (eq (funcall composed
                       '(:tool "shell" :args (:command "pwd")))
              'session)
          (= calls 1))))
  (nl-agent-autonomy-test--ck
   "invalid provider namespaces are rejected before a callback is created"
   (nl-agent-autonomy-test--error-p
    (lambda ()
      (nl-agent-autonomy-improvement-approval "native/escape" "self")))))

(princ (format "NL-AGENT-AUTONOMY %s (%d failures)\n"
               (if (= nl-agent-autonomy-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-autonomy-test--fail))
(kill-emacs (if (= nl-agent-autonomy-test--fail 0) 0 1))

;;; autonomy-test.el ends here
