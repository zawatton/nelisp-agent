;;; nl-agent-host.el --- standard inference router for broker events  -*- lexical-binding: t; -*-

;; The host reuses nelisp-llm providers rather than implementing a second HTTP
;; stack.  Each event gets a short-lived provider session so credentials and
;; backend state never cross into the standalone worker checkpoint.

;;; Code:

(require 'nl-llm-compat)
(require 'cl-lib)
(require 'subr-x)
(require 'nl-llm-agent-provider)
(require 'nl-agent-config)
(require 'nl-agent-permission)

(cl-defstruct (nl-agent-host-router
               (:constructor nl-agent-host-router--make))
  registry)

;;;###autoload
(defun nl-agent-host-router-new (provider-specs)
  "Create a host inference router from PROVIDER-SPECS or an existing registry."
  (nl-agent-host-router--make
   :registry
   (if (nl-llm-agent-provider-registry-p provider-specs)
       provider-specs
     (nl-agent-config-registry provider-specs))))

(defun nl-agent-host--event-string (event key)
  "Return non-empty string KEY from broker EVENT, or signal."
  (let ((value (plist-get event key)))
    (unless (and (stringp value) (not (string-empty-p value)))
      (error "host inference event has invalid %S: %S" key value))
    value))

;;;###autoload
(defun nl-agent-host-infer (router event)
  "Run one broker EVENT through ROUTER and return assistant text."
  (unless (nl-agent-host-router-p router)
    (error "nl-agent-host-infer: invalid router"))
  (unless (and (listp event)
               (eq (plist-get event :event) 'inference))
    (error "nl-agent-host-infer: invalid inference event"))
  (let* ((provider (nl-agent-host--event-string event :provider))
         (model (nl-agent-host--event-string event :model))
         (messages (plist-get event :messages))
         (selector (concat provider "/" model)))
    (unless (listp messages)
      (error "nl-agent-host-infer: event messages must be a list"))
    (let ((session
           (nl-llm-agent-session-open
            (nl-agent-host-router-registry router)
            selector
            :options (copy-tree (plist-get event :options)))))
      (unwind-protect
          (nl-llm-agent-session-complete session (copy-tree messages))
        (nl-llm-agent-session-close session)))))

;;;###autoload
(defun nl-agent-host-inference-function (router)
  "Return a supervisor callback backed by host inference ROUTER."
  (unless (nl-agent-host-router-p router)
    (error "nl-agent-host-inference-function: invalid router"))
  (lambda (event)
    (nl-agent-host-infer router event)))

;;;###autoload
(defun nl-agent-host-model-catalog-function (router)
  "Return a callback exposing ROUTER's current public model catalog."
  (unless (nl-agent-host-router-p router)
    (error "nl-agent-host-model-catalog-function: invalid router"))
  (lambda ()
    (copy-tree
     (nl-llm-agent-provider-models
      (nl-agent-host-router-registry router)))))

;;;###autoload
(defun nl-agent-host-tool-function (registry policy)
  "Return an authoritative host tool callback using REGISTRY and POLICY.

The callback accepts a broker tool event, re-runs permission checks on the
host, and returns observation text.  Denials and tool failures signal so the
supervisor returns a correlated tool-error to the worker."
  (unless (nl-agent-tool-registry-p registry)
    (error "nl-agent-host-tool-function: invalid tool registry"))
  (unless (nl-agent-permission-policy-p policy)
    (error "nl-agent-host-tool-function: invalid permission policy"))
  (lambda (event)
    (unless (and (listp event)
                 (eq (plist-get event :event) 'tool)
                 (stringp (plist-get event :tool)))
      (error "invalid host tool event: %S" event))
    (let ((result
           (nl-agent-permission-call
            policy registry
            (plist-get event :tool)
            (copy-tree (plist-get event :args))
            (copy-tree (plist-get event :context)))))
      (pcase (plist-get result :status)
        ('ok (plist-get result :text))
        ('denied (error "host denied tool %s: %s"
                        (plist-get event :tool)
                        (plist-get result :error)))
        (_ (error "host tool %s failed: %s"
                  (plist-get event :tool)
                  (plist-get result :error)))))))

;;;###autoload
(defun nl-agent-host-tool-catalog-function (registry)
  "Return a callback exposing REGISTRY descriptors without implementations."
  (unless (nl-agent-tool-registry-p registry)
    (error "nl-agent-host-tool-catalog-function: invalid registry"))
  (lambda () (nl-agent-tool-catalog registry)))

(provide 'nl-agent-host)
;;; nl-agent-host.el ends here
