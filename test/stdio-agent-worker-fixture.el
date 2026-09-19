;;; stdio-agent-worker-fixture.el --- live brokered agent fixture  -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path
             (or (getenv "NELISP_LLM_LISP")
                 (expand-file-name "../nelisp-llm/lisp")))
(require 'nl-agent-service)
(require 'nl-agent-broker)
(require 'nl-agent-runtime)
(require 'nl-agent-stdio)

(let* ((model-bridge
        (nl-agent-stdio-model-bridge-new
         (nl-agent-stdio-host-model-catalog)))
       (models (nl-agent-stdio-model-bridge-registry model-bridge))
       (refresh-models
        (lambda ()
          (nl-agent-stdio-model-bridge-refresh
           model-bridge (nl-agent-stdio-host-model-catalog))))
       (tools
        (nl-agent-stdio-broker-tool-registry
         (nl-agent-stdio-host-tool-catalog)))
       (service
        (nl-agent-service-new
         models "remote/model"
         :system (nl-agent-runtime-system-prompt tools)))
       ;; This transport policy cannot grant host authority.  The host repeats
       ;; permission checks before its real tool function is reachable.
       (transport-policy
        (nl-agent-permission-policy-new :mode 'off)))
  (nl-agent-stdio-ready)
  (nl-agent-stdio-main
   service
   (lambda (task)
    (nl-agent-runtime-run
      service tools transport-policy task :max-steps 4
      :model-refresh refresh-models))
   (lambda (request)
     (when (memq (car-safe request) '(models switch))
       (funcall refresh-models)))))

;;; stdio-agent-worker-fixture.el ends here
