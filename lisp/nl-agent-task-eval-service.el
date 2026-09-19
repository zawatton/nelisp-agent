;;; nl-agent-task-eval-service.el --- service adapter for task evaluation -*- lexical-binding: t; -*-

;; This adapter runs the ordinary host service/runtime core directly.  It does
;; not construct the packaged standalone supervisor.  Every case receives a
;; fresh provider session and exposes only workspace-confined file tools.

;;; Code:

(require 'nl-llm-agent-provider)
(require 'nl-agent-local-tools)
(require 'nl-agent-permission)
(require 'nl-agent-runtime)
(require 'nl-agent-service)
(require 'nl-agent-task-eval)

(defconst nl-agent-task-eval-service-runner-id
  "nl-agent-file-task-runtime-v1"
  "Stable runner identity for the confined service evaluation adapter.")

;;;###autoload
(defun nl-agent-task-eval-service-runner (provider-registry qualified-model)
  "Return a fixed-model task evaluator callback.

PROVIDER-REGISTRY supplies the model, and QUALIFIED-MODEL must be its exact
provider-qualified selector.  The returned callback accepts (TASK WORKSPACE
MAXSTEPS), opens a fresh service without fallbacks, and returns the ordinary
`nl-agent-runtime-run' result.  WORKSPACE remains owned by the caller."
  (unless (nl-llm-agent-provider-registry-p provider-registry)
    (error "task evaluation requires a provider registry"))
  (let* ((resolved
          (nl-llm-agent-provider-resolve
           provider-registry qualified-model))
         (qualified (plist-get resolved :qualified-id)))
    (unless (and (stringp qualified-model)
                 (equal qualified-model qualified))
      (error "task evaluation model must be provider-qualified: %S"
             qualified-model))
    (setq qualified (copy-sequence qualified))
    (lambda (task workspace maxsteps)
      (unless (stringp task)
        (error "task evaluation task must be text"))
      (unless (and (integerp maxsteps) (> maxsteps 0))
        (error "task evaluation maxsteps must be positive"))
      (let* ((tools (nl-agent-local-file-tool-registry workspace))
             (policy
              (nl-agent-permission-policy-new
               :mode 'smart
               :approval
               (lambda (request)
                 (if (equal (plist-get request :tool) "edit")
                     'once
                   'deny))
               :hard-deny (nl-agent-local-hard-deny workspace)))
             (service nil))
        (unwind-protect
            (progn
              (setq service
                    (nl-agent-service-new
                     provider-registry qualified
                     :system (nl-agent-runtime-system-prompt tools)
                     :fallbacks nil))
              (nl-agent-runtime-run
               service tools policy task :max-steps maxsteps))
          (when service
            (nl-agent-service-close service)))))))

;;;###autoload
(defun nl-agent-task-eval-service-run
    (suite provider-registry qualified-model &rest keys)
  "Evaluate SUITE with a fixed model through the confined service adapter.

PROVIDER-REGISTRY and QUALIFIED-MODEL have the same meaning as for
`nl-agent-task-eval-service-runner'.  KEYS accepts only optional :MAX-STEPS;
the selected model and runner identities in the report are host-fixed."
  (unless (or (null keys)
              (and (= (length keys) 2) (eq (car keys) :max-steps)))
    (error "nl-agent-task-eval-service-run: expected optional :max-steps VALUE"))
  (let ((runner
         (nl-agent-task-eval-service-runner
          provider-registry qualified-model)))
    (apply #'nl-agent-task-eval-run suite runner
           :model-id (copy-sequence qualified-model)
           :runner-id nl-agent-task-eval-service-runner-id
           keys)))

(provide 'nl-agent-task-eval-service)
;;; nl-agent-task-eval-service.el ends here
