;;; stdio-broker-worker-fixture.el --- live host-broker fixture  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-service)
(require 'nl-agent-broker)
(require 'nl-agent-stdio)

(let* ((provider
        (nl-agent-broker-provider
         "remote" '("primary" "fallback")
         #'nl-agent-stdio-broker-call))
       (registry (nl-llm-agent-provider-registry-new)))
  (nl-llm-agent-provider-register registry provider)
  (nl-agent-stdio-main
   (nl-agent-service-new
    registry "remote/primary" :fallbacks '("remote/fallback"))))

;;; stdio-broker-worker-fixture.el ends here
