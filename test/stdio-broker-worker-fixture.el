;;; stdio-broker-worker-fixture.el --- live host-broker fixture  -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path
             (or (getenv "NELISP_LLM_LISP")
                 (expand-file-name "../nelisp-llm/lisp")))
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
