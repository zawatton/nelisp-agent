;;; mcp-config-test.el --- data-only MCP configuration tests  -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path
             (or (getenv "NELISP_LLM_LISP")
                 (expand-file-name "../nelisp-llm/lisp")))
(require 'nl-agent-mcp-config)

(defvar nl-agent-mcp-config-test--fail 0)

(defun nl-agent-mcp-config-test--ck (name ok)
  (princ (format "%-69s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-mcp-config-test--fail
                         (1+ nl-agent-mcp-config-test--fail))
                   "FAIL"))))

(defun nl-agent-mcp-config-test--error-p (thunk)
  (condition-case nil
      (progn (funcall thunk) nil)
    (error t)))

(let* ((directory (make-temp-file "nl-agent-mcp-config-" t))
       (config (expand-file-name "mcp.json" directory))
       (bad (expand-file-name "bad.json" directory))
       (old-secret (getenv "NL_AGENT_MCP_CONFIG_SECRET"))
       (old-unrelated (getenv "NL_AGENT_MCP_UNRELATED"))
       (entries nil))
  (unwind-protect
      (progn
        (setenv "NL_AGENT_MCP_CONFIG_SECRET" "resolved-secret")
        (setenv "NL_AGENT_MCP_UNRELATED" "must-not-cross")
        (write-region
         "{\"servers\":[{\"id\":\"notes\",\"command\":[\"server\",\"--stdio\"],\"directory\":\"subdir\",\"environment\":{\"TOKEN\":\"NL_AGENT_MCP_CONFIG_SECRET\"},\"risk\":\"read\",\"timeoutSec\":4}]}"
         nil config nil 'silent)
        (make-directory (expand-file-name "subdir" directory))
        (setq entries (nl-agent-mcp-config-load config))
        (nl-agent-mcp-config-test--ck
         "JSON config creates one typed MCP client entry"
         (and (= (length entries) 1)
              (equal (plist-get (car entries) :id) "notes")
              (eq (plist-get (car entries) :risk) 'read)))
        (let* ((client (plist-get (car entries) :client))
               (transport
                (plist-get (nl-agent-mcp-client-metadata client)
                           :transport-object))
               (environment
                (nl-agent-mcp-stdio-environment transport)))
          (nl-agent-mcp-config-test--ck
           "relative MCP directory resolves from the config file"
           (equal
            (nl-agent-mcp-stdio-directory transport)
            (file-name-as-directory
             (expand-file-name "subdir" directory))))
          (nl-agent-mcp-config-test--ck
           "config maps named host secret into the requested child variable"
           (member "TOKEN=resolved-secret" environment))
          (nl-agent-mcp-config-test--ck
           "unmentioned host environment is absent from MCP child"
           (not
            (cl-find-if
             (lambda (entry)
               (string-prefix-p "NL_AGENT_MCP_UNRELATED=" entry))
             environment))))
        (write-region
         "{\"servers\":[{\"id\":\"x\",\"command\":[\"server\"],\"risk\":\"trusted-by-server\"}]}"
         nil bad nil 'silent)
        (nl-agent-mcp-config-test--ck
         "unknown configured risk is rejected"
         (nl-agent-mcp-config-test--error-p
          (lambda () (nl-agent-mcp-config-load bad))))
        (write-region
         "{\"servers\":[{\"id\":\"x\",\"command\":[\"server\"],\"magic\":true}]}"
         nil bad nil 'silent)
        (nl-agent-mcp-config-test--ck
         "unknown server keys are rejected before process start"
         (nl-agent-mcp-config-test--error-p
          (lambda () (nl-agent-mcp-config-load bad))))
        (write-region "[]" nil bad nil 'silent)
        (nl-agent-mcp-config-test--ck
         "top-level JSON arrays cannot masquerade as configuration objects"
         (nl-agent-mcp-config-test--error-p
          (lambda () (nl-agent-mcp-config-load bad))))
        (write-region "{}" nil bad nil 'silent)
        (nl-agent-mcp-config-test--ck
         "configuration requires an explicit servers array"
         (nl-agent-mcp-config-test--error-p
          (lambda () (nl-agent-mcp-config-load bad)))))
    (when entries (nl-agent-mcp-config-close entries))
    (setenv "NL_AGENT_MCP_CONFIG_SECRET" old-secret)
    (setenv "NL_AGENT_MCP_UNRELATED" old-unrelated)
    (delete-directory directory t)))

(princ (format "NL-AGENT-MCP-CONFIG %s (%d failures)\n"
               (if (= nl-agent-mcp-config-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-mcp-config-test--fail))
(kill-emacs (if (= nl-agent-mcp-config-test--fail 0) 0 1))

;;; mcp-config-test.el ends here
