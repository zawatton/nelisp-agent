;;; nl-agent-tool.el --- provider-neutral agent tool registry  -*- lexical-binding: t; -*-

;; Tool descriptions are data and invocation functions remain private to the
;; runtime.  Permission checks live in `nl-agent-permission' so model output
;; never calls an operating-system capability directly.

;;; Code:

(require 'nl-llm-compat)
(require 'cl-lib)
(require 'subr-x)

(cl-defstruct (nl-agent-tool
               (:constructor nl-agent-tool--make))
  name
  description
  risk
  invoke-fn
  metadata)

(cl-defstruct (nl-agent-tool-registry
               (:constructor nl-agent-tool-registry-new))
  (tools nil))

(defconst nl-agent-tool-risks
  '(safe read write execute external destructive)
  "Risk classes accepted by `nl-agent-tool-new'.")

(defun nl-agent-tool--name (value where)
  "Return VALUE as a validated tool name for WHERE."
  (let ((name (cond ((stringp value) value)
                    ((symbolp value) (symbol-name value))
                    (t nil))))
    (unless (and name
                 (not (string-empty-p name))
                 (not (string-match-p "[ \t\n\r]" name)))
      (error "%s: tool name must be a non-empty word, got %S" where value))
    name))

(defun nl-agent-tool--keys (keys allowed where)
  "Validate KEYS against ALLOWED for WHERE."
  (unless (= (% (length keys) 2) 0)
    (error "%s: options must be KEY VALUE pairs" where))
  (let ((tail keys))
    (while tail
      (unless (memq (car tail) allowed)
        (error "%s: unknown option %S" where (car tail)))
      (setq tail (cddr tail))))
  keys)

;;;###autoload
(defun nl-agent-tool-new (name invoke &rest keys)
  "Create tool NAME backed by INVOKE.

INVOKE receives (ARGS CONTEXT).  KEYS accepts :DESCRIPTION, :RISK, and
:METADATA.  RISK defaults to `execute'; callers must opt into a lower class."
  (nl-agent-tool--keys
   keys '(:description :risk :metadata) "nl-agent-tool-new")
  (unless (functionp invoke)
    (error "nl-agent-tool-new: INVOKE must be a function"))
  (let ((risk (or (plist-get keys :risk) 'execute))
        (description (or (plist-get keys :description) "")))
    (unless (memq risk nl-agent-tool-risks)
      (error "nl-agent-tool-new: invalid risk %S" risk))
    (unless (stringp description)
      (error "nl-agent-tool-new: :description must be text"))
    (nl-agent-tool--make
     :name (nl-agent-tool--name name "nl-agent-tool-new")
     :description description
     :risk risk
     :invoke-fn invoke
     :metadata (copy-tree (plist-get keys :metadata)))))

(defun nl-agent-tool--find (registry name)
  "Return NAME from REGISTRY, or nil."
  (let ((name (nl-agent-tool--name name "tool lookup")))
    (cl-find-if
     (lambda (tool) (equal (nl-agent-tool-name tool) name))
     (nl-agent-tool-registry-tools registry))))

;;;###autoload
(defun nl-agent-tool-register (registry tool)
  "Register TOOL in REGISTRY and return TOOL.
Registration order is retained for deterministic model prompts."
  (unless (nl-agent-tool-registry-p registry)
    (error "nl-agent-tool-register: invalid registry"))
  (unless (nl-agent-tool-p tool)
    (error "nl-agent-tool-register: invalid tool"))
  (when (nl-agent-tool--find registry (nl-agent-tool-name tool))
    (error "tool already registered: %s" (nl-agent-tool-name tool)))
  (setf (nl-agent-tool-registry-tools registry)
        (append (nl-agent-tool-registry-tools registry) (list tool)))
  tool)

;;;###autoload
(defun nl-agent-tool-catalog (registry)
  "Return REGISTRY's model-visible descriptors without invocation functions."
  (unless (nl-agent-tool-registry-p registry)
    (error "nl-agent-tool-catalog: invalid registry"))
  (mapcar
   (lambda (tool)
     (list :name (nl-agent-tool-name tool)
           :description (nl-agent-tool-description tool)
           :risk (nl-agent-tool-risk tool)
           :metadata (copy-tree (nl-agent-tool-metadata tool))))
   (nl-agent-tool-registry-tools registry)))

(defun nl-agent-tool--resolve (registry name)
  "Return NAME from REGISTRY or signal an unknown-tool error."
  (unless (nl-agent-tool-registry-p registry)
    (error "tool lookup: invalid registry"))
  (or (nl-agent-tool--find registry name)
      (error "unknown tool: %s" name)))

(defun nl-agent-tool--invoke (tool args context)
  "Invoke TOOL with detached ARGS and CONTEXT.
Only the permission module should call this private function."
  (funcall (nl-agent-tool-invoke-fn tool)
           (copy-tree args) (copy-tree context)))

(provide 'nl-agent-tool)
;;; nl-agent-tool.el ends here
