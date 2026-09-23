;;; free-models-worker.el --- standalone broker worker for free models  -*- lexical-binding: t; -*-

;; Run from the project root with:
;;   ../nelisp/target/nelisp --load examples/free-models-worker.el

(defconst nl-agent-example-worker-root
  (let ((source (or load-file-name buffer-file-name)))
    (if source
        (file-name-directory
         (directory-file-name (file-name-directory source)))
      (file-name-as-directory (expand-file-name "."))))
  "NeLisp Agent project root resolved from this script.")

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(load (expand-file-name "examples/free-models-config.el"
                        nl-agent-example-worker-root))
(defvar nl-agent-example-default-model)
(defvar nl-agent-example-fallback-models)
(require 'nl-agent-service)
(require 'nl-agent-broker)
(require 'nl-agent-runtime)
(require 'nl-agent-stdio)

(let* ((startup (nl-agent-stdio-host-startup-config))
       (initial-model
        (or (plist-get startup :model) nl-agent-example-default-model))
       (fallbacks
        (if startup
            (plist-get startup :fallbacks)
          nl-agent-example-fallback-models))
       (model-bridge
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
         models initial-model
         :fallbacks fallbacks
         :system (nl-agent-runtime-system-prompt tools)))
       ;; The host is the authority and repeats policy checks before executing.
       (transport-policy
        (nl-agent-permission-policy-new :mode 'off)))
  (nl-agent-stdio-ready)
  (nl-agent-stdio-main
   service
   (lambda (task)
    (nl-agent-runtime-run
      service tools transport-policy task :max-steps 12
      :model-refresh refresh-models))
   (lambda (request)
     (when (memq (car-safe request) '(models switch))
       (funcall refresh-models)))))

;;; free-models-worker.el ends here
