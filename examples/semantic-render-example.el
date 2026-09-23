;;; semantic-render-example.el --- runnable semantic renderer host example -*- lexical-binding: t; -*-

;;; Code:

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-llm-agent-openai)
(require 'url-parse)
(require 'nl-agent-host)
(require 'nl-agent-permission)
(require 'nl-agent-semantic-render)

(defconst nl-agent-semantic-render-example--ir
  "(task :version 1 :id \"example\" :plan
  (render :language ja :claims
    ((claim :id \"c1\" :text \"点検結果を確認します。\")
     (claim :id \"c2\" :text \"異常があれば記録します。\")))
  :constraints (:allow-new-claims nil :max-chars 120))")

(defun nl-agent-semantic-render-example--stub-transport (_request)
  "Return a deterministic response without contacting a model."
  '(:choices ((:message (:content "点検結果を確認し、異常があれば記録します。")))))

(defun nl-agent-semantic-render-example--loopback-url-p (base-url)
  "Return non-nil only for an HTTP(S) URL with an exact loopback host."
  (condition-case nil
      (let* ((url (url-generic-parse-url base-url))
             (raw-host (downcase (url-host url)))
             (host (if (and (> (length raw-host) 1)
                           (eq (aref raw-host 0) ?\[)
                           (eq (aref raw-host (1- (length raw-host))) ?\]))
                       (substring raw-host 1 -1)
                     raw-host)))
        (and (member (url-type url) '("http" "https"))
             (member host '("127.0.0.1" "localhost" "::1"))
             (null (url-user url))
             (null (url-password url))))
    (error nil)))

;;;###autoload
(defun nl-agent-semantic-render-example-run (&optional live)
  "Run the host tool example with a stub, or a loopback model when LIVE.

The default is a stub so evaluating this example never performs network I/O.
Set NELISP_AGENT_RENDER_LIVE=1, or call this command with a prefix argument,
to use the loopback OpenAI-compatible endpoint configured by
NELISP_AGENT_RENDER_BASE_URL and NELISP_AGENT_RENDER_MODEL."
  (interactive "P")
  (let* ((live (or live (equal (getenv "NELISP_AGENT_RENDER_LIVE") "1")))
         (base-url (or (getenv "NELISP_AGENT_RENDER_BASE_URL")
                       "http://127.0.0.1:11434/v1"))
         (model (or (getenv "NELISP_AGENT_RENDER_MODEL") "llama3.2:3b")))
    (when (and live
               (not (nl-agent-semantic-render-example--loopback-url-p
                     base-url)))
      (error "live example requires an explicitly loopback base URL"))
    (let* ((provider
            (nl-llm-agent-openai-provider
             "local"
             :base-url base-url
             :models (list model)
             :transport (unless live
                          #'nl-agent-semantic-render-example--stub-transport)))
           (router (nl-agent-host-router-new (list provider)))
           ;; The allowlist is an administrator attestation for this exact
           ;; provider-qualified selector; it is not network isolation.
           (renderer
            (nl-agent-semantic-render-new
             router (concat "local/" model) (list (concat "local/" model))))
           (tools (nl-agent-tool-registry-new))
           (policy
            (nl-agent-permission-policy-new
             :mode 'smart :approval (lambda (_request) 'once))))
      (nl-agent-semantic-render-register-tool tools renderer)
      (princ
       (format "%S\n"
               (funcall
                (nl-agent-host-tool-function tools policy)
                (list :event 'tool
                      :tool "semantic.render"
                      :args (list :ir nl-agent-semantic-render-example--ir)
                      :context '(:source example))))))))

(provide 'semantic-render-example)

;;; semantic-render-example.el ends here
