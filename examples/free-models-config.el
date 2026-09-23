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

(defun nl-agent-example-free-service (base-url &optional api-key-environment)
  "Open the example service at OpenAI-compatible BASE-URL.
When API-KEY-ENVIRONMENT is non-nil, its value is resolved for every request."
  (let ((provider
         (list :id "remote"
               :type 'openai
               :base-url base-url
               :models nl-agent-example-free-models)))
    (when api-key-environment
      (setq provider
            (append provider (list :api-key-env api-key-environment))))
    (nl-agent-config-open
     (list :default-model nl-agent-example-default-model
           :fallback-models nl-agent-example-fallback-models
           :system "You are NeLisp Agent."
           :providers (list provider)))))

(provide 'nl-agent-example-free-models)
;;; free-models-config.el ends here
