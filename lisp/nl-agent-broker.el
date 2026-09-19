;;; nl-agent-broker.el --- host-mediated inference provider  -*- lexical-binding: t; -*-

;; Standalone NeLisp owns the agent state while a small host owns networking and
;; credentials.  CALL is the only boundary between them, so neither the service
;; core nor nelisp-llm needs to know how a remote request is transported.

;;; Code:

(require 'nl-llm-compat)
(require 'nl-llm-agent-provider)

(defun nl-agent-broker--keys (keys allowed)
  "Validate KEYS against ALLOWED."
  (unless (= (% (length keys) 2) 0)
    (error "nl-agent-broker-provider: options must be KEY VALUE pairs"))
  (let ((tail keys))
    (while tail
      (unless (memq (car tail) allowed)
        (error "nl-agent-broker-provider: unknown option %S" (car tail)))
      (setq tail (cddr tail))))
  keys)

;;;###autoload
(defun nl-agent-broker-provider (id models call &rest keys)
  "Create provider ID whose inference is delegated to host function CALL.

MODELS uses the normal provider catalog format.  CALL receives a plist with
:KIND, :PROVIDER, :MODEL, :OPTIONS, and provider-neutral :MESSAGES, and must
return assistant text.  Optional KEYS are :NAME and :CAPABILITIES."
  (unless (functionp call)
    (error "nl-agent-broker-provider: CALL must be a function"))
  (nl-agent-broker--keys keys '(:name :capabilities))
  (let ((provider-id
         (cond ((stringp id) id)
               ((symbolp id) (symbol-name id))
               (t id)))
        (capabilities
         (if (plist-member keys :capabilities)
             (plist-get keys :capabilities)
           '(generate broker host-transport))))
    (nl-llm-agent-provider-new
     provider-id
     :name (plist-get keys :name)
     :models models
     :capabilities capabilities
     :open
     (lambda (model options)
       (list :model model :options (copy-tree options)))
     :complete
     (lambda (state messages)
       (let ((result
              (funcall
               call
               (list :kind 'inference
                     :provider provider-id
                     :model (plist-get state :model)
                     :options (copy-tree (plist-get state :options))
                     :messages (copy-tree messages)))))
         (unless (stringp result)
           (error "broker provider %s returned non-text result: %S"
                  provider-id result))
         result)))))

(provide 'nl-agent-broker)
;;; nl-agent-broker.el ends here
