;;; stdio-worker-fixture.el --- live pipe fixture for NeLisp Agent  -*- lexical-binding: t; -*-

;; This is deliberately a fixture, not a production model provider.  It proves
;; that the complete service/model-switch protocol survives a real NeLisp pipe.

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path
             (or (getenv "NELISP_LLM_LISP")
                 (expand-file-name "../nelisp-llm/lisp")))
(require 'nl-llm-agent-provider)
(require 'nl-agent-service)
(require 'nl-agent-stdio)

(let* ((provider
        (nl-llm-agent-provider-new
         "fixture"
         :models '("alpha" "beta")
         :open (lambda (model _options) model)
         :complete
         (lambda (model messages)
           (format "%s:%d" model (length messages)))))
       (registry (nl-llm-agent-provider-registry-new)))
  (nl-llm-agent-provider-register registry provider)
  (nl-agent-stdio-main
   (nl-agent-service-new registry "fixture/alpha")))

;;; stdio-worker-fixture.el ends here
