;;; nl-agent-permission.el --- fail-closed agent permission boundary  -*- lexical-binding: t; -*-

;; The policy decision is made before a tool function is reachable.  Hard-deny
;; rules are an unoverrideable floor; unattended runs never prompt and deny any
;; operation that would otherwise need approval.

;;; Code:

(require 'nl-llm-compat)
(require 'cl-lib)
(require 'nl-agent-tool)

(cl-defstruct (nl-agent-permission-policy
               (:constructor nl-agent-permission-policy--make))
  mode
  approval-fn
  hard-deny-fn
  unattended
  session-approvals
  history)

(defun nl-agent-permission--keys (keys allowed where)
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
(defun nl-agent-permission-policy-new (&rest keys)
  "Create a tool permission policy.

KEYS accepts :MODE (`smart', `manual', or `off'), :APPROVAL, :HARD-DENY,
and :UNATTENDED.  Smart mode allows `safe' and `read' tools automatically and
asks for all higher-risk tools.  Manual asks for every tool.  Off allows tools
without asking, but never overrides HARD-DENY.  Missing approval and unattended
runs fail closed whenever approval would be required."
  (nl-agent-permission--keys
   keys '(:mode :approval :hard-deny :unattended)
   "nl-agent-permission-policy-new")
  (let ((mode (or (plist-get keys :mode) 'smart))
        (approval (plist-get keys :approval))
        (hard-deny (plist-get keys :hard-deny)))
    (unless (memq mode '(smart manual off))
      (error "nl-agent-permission-policy-new: invalid mode %S" mode))
    (when (and approval (not (functionp approval)))
      (error "nl-agent-permission-policy-new: :approval must be a function"))
    (when (and hard-deny (not (functionp hard-deny)))
      (error "nl-agent-permission-policy-new: :hard-deny must be a function"))
    (nl-agent-permission-policy--make
     :mode mode
     :approval-fn approval
     :hard-deny-fn hard-deny
     :unattended (and (plist-get keys :unattended) t)
     :session-approvals nil
     :history nil)))

(defun nl-agent-permission--record (policy decision)
  "Record DECISION in POLICY and return a detached copy."
  (setf (nl-agent-permission-policy-history policy)
        (cons (copy-tree decision)
              (nl-agent-permission-policy-history policy)))
  (copy-tree decision))

(defun nl-agent-permission--request (tool args context)
  "Build an approval request for TOOL, ARGS, and CONTEXT."
  (list :tool (nl-agent-tool-name tool)
        :risk (nl-agent-tool-risk tool)
        :description (nl-agent-tool-description tool)
        :args (copy-tree args)
        :context (copy-tree context)))

(defun nl-agent-permission--session-key (request)
  "Return an exact-call session approval key for REQUEST."
  (prin1-to-string
   (list (plist-get request :tool) (plist-get request :args))))

(defun nl-agent-permission--decision (request decision source &optional reason)
  "Return a structured permission DECISION for REQUEST from SOURCE."
  (append
   (list :decision decision
         :source source
         :tool (plist-get request :tool)
         :risk (plist-get request :risk)
         :args (copy-tree (plist-get request :args)))
   (when reason (list :reason reason))))

;;;###autoload
(defun nl-agent-permission-authorize (policy tool args &optional context)
  "Authorize TOOL with ARGS under POLICY and return a decision plist.

An approval callback receives a detached request plist and returns `once',
`session', `autonomous', or `deny'.  `autonomous' is an allow-once decision
recorded separately for a trusted host-side scope.  Session grants match the
exact tool and arguments."
  (unless (nl-agent-permission-policy-p policy)
    (error "nl-agent-permission-authorize: invalid policy"))
  (unless (nl-agent-tool-p tool)
    (error "nl-agent-permission-authorize: invalid tool"))
  (let* ((request (nl-agent-permission--request tool args context))
         (hard-deny-fn (nl-agent-permission-policy-hard-deny-fn policy))
         (hard-reason (and hard-deny-fn
                           (funcall hard-deny-fn (copy-tree request))))
         (mode (nl-agent-permission-policy-mode policy))
         (risk (nl-agent-tool-risk tool))
         (session-key (nl-agent-permission--session-key request))
         decision)
    (setq decision
          (cond
           (hard-reason
            (nl-agent-permission--decision
             request 'deny 'hard-deny
             (if (stringp hard-reason)
                 hard-reason
               "blocked by a hard-deny rule")))
           ((eq mode 'off)
            (nl-agent-permission--decision request 'allow 'policy))
           ((and (eq mode 'smart) (memq risk '(safe read)))
            (nl-agent-permission--decision request 'allow 'policy))
           ((member session-key
                    (nl-agent-permission-policy-session-approvals policy))
            (nl-agent-permission--decision request 'allow 'session))
           ((nl-agent-permission-policy-unattended policy)
            (nl-agent-permission--decision
             request 'deny 'unattended
             "approval is unavailable in unattended mode"))
           ((null (nl-agent-permission-policy-approval-fn policy))
            (nl-agent-permission--decision
             request 'deny 'fail-closed
             "approval is required but no approval callback is configured"))
           (t
            (let ((answer
                   (funcall
                    (nl-agent-permission-policy-approval-fn policy)
                    (copy-tree request))))
              (cond
               ((eq answer 'once)
                (nl-agent-permission--decision request 'allow 'approval))
               ((eq answer 'session)
                (setf (nl-agent-permission-policy-session-approvals policy)
                      (cons
                       session-key
                       (nl-agent-permission-policy-session-approvals policy)))
                (nl-agent-permission--decision request 'allow 'approval))
               ((eq answer 'autonomous)
                (nl-agent-permission--decision
                 request 'allow 'autonomous-scope))
               (t
                (nl-agent-permission--decision
                 request 'deny 'approval "approval was denied")))))))
    (nl-agent-permission--record policy decision)))

;;;###autoload
(defun nl-agent-permission-call
    (policy registry name args &optional context)
  "Authorize and invoke NAME from REGISTRY with ARGS.
Return structured `ok', `denied', or `error' data; tool errors never escape."
  (condition-case err
      (let* ((tool (nl-agent-tool--resolve registry name))
             (authorization
              (nl-agent-permission-authorize
               policy tool args context)))
        (if (eq (plist-get authorization :decision) 'deny)
            (list :status 'denied
                  :tool (nl-agent-tool-name tool)
                  :authorization authorization
                  :error (or (plist-get authorization :reason)
                             "permission denied"))
          (condition-case tool-error
              (let ((value (nl-agent-tool--invoke tool args context)))
                (list :status 'ok
                      :tool (nl-agent-tool-name tool)
                      :authorization authorization
                      :value value
                      :text (if (stringp value)
                                value
                              (format "%S" value))))
            (error
             (list :status 'error
                   :tool (nl-agent-tool-name tool)
                   :authorization authorization
                   :error (format "%S" tool-error))))))
    (error
     (list :status 'error :tool name :error (format "%S" err)))))

(provide 'nl-agent-permission)
;;; nl-agent-permission.el ends here
