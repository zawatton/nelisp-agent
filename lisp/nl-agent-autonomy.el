;;; nl-agent-autonomy.el --- scoped host authority for self-evolution  -*- lexical-binding: t; -*-

;; This module knows only tool names and the model namespace it may activate.
;; It does not own the CLI, training queue, provider registry, or permission
;; policy, so other service facades can reuse the same narrow authority.

;;; Code:

(require 'nl-llm-compat)
(require 'subr-x)

(defconst nl-agent-autonomy-improvement-tools
  '("model.improvement.submit"
    "model.improvement.run"
    "model.improvement.resume"
    "model.improvement.cancel")
  "State-changing tools eligible for explicitly scoped autonomy.")

(defun nl-agent-autonomy--identifier (value where)
  "Return bounded namespace identifier VALUE for WHERE."
  (unless (and (stringp value)
               (<= 1 (length value)) (<= (length value) 128)
               (string-match-p "\\`[A-Za-z0-9_.-]+\\'" value))
    (error "%s has invalid identifier %S" where value))
  (copy-sequence value))

(defun nl-agent-autonomy--self-generation-selector-p
    (args provider-id id-prefix)
  "Return non-nil when ARGS selects PROVIDER-ID/ID-PREFIX-gN exactly."
  (let ((selector
         (and (listp args) (= (length args) 2)
              (eq (car args) :selector)
              (stringp (cadr args))
              (cadr args))))
    (and selector
         (string-match-p
          (concat "\\`" (regexp-quote provider-id) "/"
                  (regexp-quote id-prefix) "-g[0-9]+\\'")
          selector))))

(defun nl-agent-autonomy--request-p (request provider-id id-prefix)
  "Return non-nil when REQUEST stays inside the supplied evolution scope."
  (let ((tool (plist-get request :tool)))
    (or (member tool nl-agent-autonomy-improvement-tools)
        (and (equal tool "service.model.switch")
             (nl-agent-autonomy--self-generation-selector-p
              (plist-get request :args) provider-id id-prefix)))))

;;;###autoload
(defun nl-agent-autonomy-improvement-approval
    (provider-id id-prefix &optional fallback)
  "Return an approval callback for one self-evolution namespace.

The callback returns `autonomous' only for bounded improvement queue mutations
or a provider-qualified PROVIDER-ID/ID-PREFIX-gN switch.  Every other request
delegates to FALLBACK, or returns `deny' when no fallback is supplied."
  (let ((provider-id
         (nl-agent-autonomy--identifier provider-id "autonomy provider"))
        (id-prefix
         (nl-agent-autonomy--identifier id-prefix "autonomy artifact prefix")))
    (when (and fallback (not (functionp fallback)))
      (error "autonomy fallback must be a function"))
    (lambda (request)
      (cond
       ((nl-agent-autonomy--request-p request provider-id id-prefix)
        'autonomous)
       (fallback (funcall fallback request))
       (t 'deny)))))

(provide 'nl-agent-autonomy)
;;; nl-agent-autonomy.el ends here
