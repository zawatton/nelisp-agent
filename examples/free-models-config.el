;;; free-models-config.el --- user-supplied free model catalog example  -*- lexical-binding: t; -*-

;; Availability is provider-controlled and can change.  Pass the provider's
;; current OpenAI-compatible base URL instead of embedding a machine endpoint.

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-config)

(defconst nl-agent-example-free-models
  '((:id "upstage/solar-pro4:free" :name "Solar Pro 4")
    (:id "meituan/longcat-2.0:free" :name "LongCat 2.0")
    (:id "inclusionai/ling-3.0-flash-sante:free" :name "Ling Sante")
    (:id "inclusionai/ling-3.0-flash-fin:free" :name "Ling Fin")
    (:id "poolside/laguna-s-2.1:free" :name "Laguna S 2.1")
    (:id "stepfun/step-3.7-flash:free" :name "Step 3.7 Flash")
    (:id "poolside/laguna-xs-2.1:free" :name "Laguna XS 2.1"))
  "Free-model snapshot supplied for the initial NeLisp Agent design.")

(defconst nl-agent-example-default-model
  "remote/poolside/laguna-s-2.1:free"
  "Legacy initial model used when the remote provider is configured.")

(defconst nl-agent-example-fallback-models
  '("remote/meituan/longcat-2.0:free"
    "remote/poolside/laguna-xs-2.1:free")
  "Legacy remote fallback selectors in preference order.")

(defun nl-agent-example-remote-models ()
  "Return the configured remote model catalog.
When NELISP_AGENT_REMOTE_MODELS is non-blank, parse it as a comma-separated
list of provider model IDs.  Otherwise return the hard-coded example catalog."
  (let ((configured (getenv "NELISP_AGENT_REMOTE_MODELS")))
    (if (and configured (not (string-blank-p configured)))
        (mapcar (lambda (id) (list :id id :name id))
                (seq-filter
                 (lambda (item) (not (string-blank-p item)))
                 (mapcar #'string-trim
                         (split-string configured ","))))
      nl-agent-example-free-models)))

(defun nl-agent-example-remote-default-model ()
  "Return the configured remote default model selector."
  (let ((models (nl-agent-example-remote-models)))
    (if (eq models nl-agent-example-free-models)
        nl-agent-example-default-model
      (concat "remote/" (plist-get (car models) :id)))))

(defun nl-agent-example-remote-fallback-models ()
  "Return the configured remote fallback model selectors."
  (let ((models (nl-agent-example-remote-models)))
    (if (eq models nl-agent-example-free-models)
        nl-agent-example-fallback-models
      (mapcar (lambda (model)
                (concat "remote/" (plist-get model :id)))
              (cdr models)))))

(defun nl-agent-example-remote-timeout-sec ()
  "Return NELISP_AGENT_REMOTE_TIMEOUT_SEC as a positive number, or nil."
  (let ((configured (getenv "NELISP_AGENT_REMOTE_TIMEOUT_SEC")))
    (when (and configured (not (string-blank-p configured)))
      (let ((value (string-to-number (string-trim configured))))
        (when (and (numberp value) (> value 0))
          value)))))

(defun nl-agent-example-free-service (base-url &optional api-key-environment)
  "Open the example service at OpenAI-compatible BASE-URL.
When API-KEY-ENVIRONMENT is non-nil, its value is resolved for every request."
  (let ((provider
         (list :id "remote"
               :type 'openai
               :base-url base-url
               :models (nl-agent-example-remote-models)))
        (timeout (nl-agent-example-remote-timeout-sec)))
    (when api-key-environment
      (setq provider
            (append provider (list :api-key-env api-key-environment))))
    (when timeout
      (setq provider
            (append provider (list :timeout-sec timeout))))
    (nl-agent-config-open
     (list :default-model (nl-agent-example-remote-default-model)
           :fallback-models (nl-agent-example-remote-fallback-models)
           :system "You are Kaji, a coding agent."
           :providers (list provider)))))

(provide 'nl-agent-example-free-models)
;;; free-models-config.el ends here
