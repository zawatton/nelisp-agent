;;; nl-agent-config.el --- declarative NeLisp Agent assembly  -*- lexical-binding: t; -*-

;; Configuration is data, not evaluated code.  It assembles provider objects
;; from nelisp-llm and opens the outward-facing service without teaching the
;; service core about any vendor or inference implementation.

;;; Code:

(require 'nl-llm-compat)
(require 'subr-x)
(require 'nl-llm-agent-provider)
(require 'nl-llm-agent-openai)
(require 'nl-agent-service)
(require 'nl-agent-broker)

(defun nl-agent-config--keys (value allowed where)
  "Validate plist VALUE against ALLOWED keys for WHERE."
  (unless (listp value)
    (error "%s: expected a plist" where))
  (unless (= (% (length value) 2) 0)
    (error "%s: plist must contain KEY VALUE pairs" where))
  (let ((tail value))
    (while tail
      (unless (memq (car tail) allowed)
        (error "%s: unknown key %S" where (car tail)))
      (setq tail (cddr tail))))
  value)

(defun nl-agent-config--api-key (spec)
  "Return the lazy API key source described by provider SPEC."
  (let ((direct-present (plist-member spec :api-key))
        (direct (plist-get spec :api-key))
        (environment (plist-get spec :api-key-env)))
    (when (and direct-present environment)
      (error "provider %S: use either :api-key or :api-key-env"
             (plist-get spec :id)))
    (when (and environment
               (not (and (stringp environment)
                         (not (string-empty-p environment)))))
      (error "provider %S: :api-key-env must be a non-empty string"
             (plist-get spec :id)))
    (if environment
        (let ((variable environment))
          (lambda () (getenv variable)))
      direct)))

(defun nl-agent-config--openai-provider (spec)
  "Build one OpenAI-compatible provider from SPEC."
  (nl-agent-config--keys
   spec
   '(:id :type :name :base-url :models :api-key :api-key-env
     :headers :transport :chat-path :timeout-sec)
   "OpenAI provider config")
  (let ((args
         (list :base-url (plist-get spec :base-url)
               :models (plist-get spec :models)
               :api-key (nl-agent-config--api-key spec))))
    (dolist (key '(:name :headers :transport :chat-path :timeout-sec))
      (when (plist-member spec key)
        (setq args (append args (list key (plist-get spec key))))))
    (apply #'nl-llm-agent-openai-provider
           (plist-get spec :id) args)))

(defun nl-agent-config--broker-provider (spec)
  "Build one host-broker provider from SPEC."
  (nl-agent-config--keys
   spec '(:id :type :name :models :call :capabilities)
   "broker provider config")
  (let ((args nil))
    (dolist (key '(:name :capabilities))
      (when (plist-member spec key)
        (setq args (append args (list key (plist-get spec key))))))
    (apply #'nl-agent-broker-provider
           (plist-get spec :id)
           (plist-get spec :models)
           (plist-get spec :call)
           args)))

(defun nl-agent-config--provider (spec)
  "Build or accept one provider described by SPEC."
  (cond
   ((nl-llm-agent-provider-p spec) spec)
   ((not (listp spec))
    (error "provider config must be a plist or provider object: %S" spec))
   ((eq (plist-get spec :type) 'openai)
    (nl-agent-config--openai-provider spec))
   ((eq (plist-get spec :type) 'broker)
    (nl-agent-config--broker-provider spec))
   (t
    (error "unsupported provider type: %S" (plist-get spec :type)))))

;;;###autoload
(defun nl-agent-config-registry (provider-specs)
  "Build a provider registry from declarative PROVIDER-SPECS.
Existing provider objects may be mixed with OpenAI-compatible provider plists."
  (unless (listp provider-specs)
    (error "nl-agent-config-registry: provider specs must be a list"))
  (let ((registry (nl-llm-agent-provider-registry-new)))
    (dolist (spec provider-specs)
      (nl-llm-agent-provider-register
       registry (nl-agent-config--provider spec)))
    registry))

;;;###autoload
(defun nl-agent-config-open (config)
  "Assemble and open a NeLisp Agent service from plist CONFIG.

CONFIG accepts :PROVIDERS, :DEFAULT-MODEL, :FALLBACK-MODELS, :SYSTEM, and
:OPTIONS.  Provider credentials should normally use :API-KEY-ENV so secrets
stay outside config."
  (nl-agent-config--keys
   config '(:providers :default-model :fallback-models :system :options)
   "nl-agent-config-open")
  (let ((selector (plist-get config :default-model)))
    (unless (and (stringp selector) (not (string-empty-p selector)))
      (error "nl-agent-config-open: :default-model is required"))
    (let ((registry
           (nl-agent-config-registry (plist-get config :providers)))
          (args nil))
      (when (plist-member config :system)
        (setq args (append args (list :system (plist-get config :system)))))
      (when (plist-member config :options)
        (setq args (append args (list :options (plist-get config :options)))))
      (when (plist-member config :fallback-models)
        (setq args
              (append args
                      (list :fallbacks
                            (plist-get config :fallback-models)))))
      (apply #'nl-agent-service-new registry selector args))))

(provide 'nl-agent-config)
;;; nl-agent-config.el ends here
