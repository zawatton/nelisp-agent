;;; nl-agent-service-tools.el --- host-authorized service controls  -*- lexical-binding: t; -*-

;; Service mutations originate in the standalone worker but remain host
;; authorized.  The host resolves a requested selector against its authoritative
;; provider catalog and returns only the qualified selector.  The worker applies
;; that directive transactionally after receiving the correlated approval.

;;; Code:

(require 'nl-llm-compat)
(require 'nl-llm-agent-provider)
(require 'nl-agent-host)
(require 'nl-agent-tool)

(defconst nl-agent-service-model-switch-schema
  '(:type "object"
    :properties (:selector (:type "string"))
    :required ["selector"]
    :additionalProperties nil)
  "Input schema for a host-authorized live model switch.")

(defun nl-agent-service-tools--selector (args)
  "Return the only valid model selector from tool ARGS."
  (unless (and (listp args) (= (length args) 2)
               (eq (car args) :selector)
               (stringp (cadr args))
               (> (length (cadr args)) 0))
    (error "service model switch requires only non-empty :selector text"))
  (cadr args))

;;;###autoload
(defun nl-agent-service-tools-register (registry router)
  "Register host-authorized service controls in tool REGISTRY for ROUTER."
  (unless (nl-agent-tool-registry-p registry)
    (error "nl-agent-service-tools-register: invalid tool registry"))
  (unless (nl-agent-host-router-p router)
    (error "nl-agent-service-tools-register: invalid host router"))
  (nl-agent-tool-register
   registry
   (nl-agent-tool-new
    "service.model.switch"
    (lambda (args _context)
      (let ((model
             (nl-llm-agent-provider-resolve
              (nl-agent-host-router-registry router)
              (nl-agent-service-tools--selector args))))
        (plist-get model :qualified-id)))
    :description
    "Transactionally activate an available model after explicit host approval"
    :risk 'write
    :metadata
    (list :input-schema nl-agent-service-model-switch-schema
          :service-operation 'model-switch)))
  registry)

(provide 'nl-agent-service-tools)
;;; nl-agent-service-tools.el ends here
