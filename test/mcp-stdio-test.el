;;; mcp-stdio-test.el --- live modern MCP stdio transport tests  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-permission)
(require 'nl-agent-mcp-stdio)

(defvar nl-agent-mcp-stdio-test--fail 0)

(defun nl-agent-mcp-stdio-test--ck (name ok)
  (princ (format "%-69s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-mcp-stdio-test--fail
                         (1+ nl-agent-mcp-stdio-test--fail))
                   "FAIL"))))

(let* ((project-directory default-directory)
       (emacs-binary
        (expand-file-name invocation-name invocation-directory))
       (fixture
        (expand-file-name
         "test/mcp-modern-server-fixture.el" project-directory))
       (old-secret (getenv "NL_AGENT_MCP_TEST_SECRET"))
       (client nil)
       (explicit-client nil))
  (unwind-protect
      (progn
        (setenv "NL_AGENT_MCP_TEST_SECRET" "parent-secret")
        (setq client
              (nl-agent-mcp-stdio-client-new
               "fixture" (list emacs-binary "-Q" "--batch" "-l" fixture)
               :directory project-directory :timeout-sec 3))
        (let ((registry (nl-agent-tool-registry-new)))
          (nl-agent-mcp-register-tools registry client :risk 'read)
          (nl-agent-mcp-stdio-test--ck
           "modern stdio tools/list discovers a deterministic catalog"
           (equal
            (mapcar (lambda (item) (plist-get item :name))
                    (nl-agent-tool-catalog registry))
            '("mcp.fixture.echo" "mcp.fixture.environment_probe")))
          (let ((result
                 (nl-agent-permission-call
                  (nl-agent-permission-policy-new :mode 'smart)
                  registry "mcp.fixture.echo" '(:text "hello"))))
            (nl-agent-mcp-stdio-test--ck
             "modern stdio tools/call round trip returns text content"
             (and (eq (plist-get result :status) 'ok)
                  (equal (plist-get result :text) "echo:hello"))))
          (let ((result
                 (nl-agent-permission-call
                  (nl-agent-permission-policy-new :mode 'smart)
                  registry "mcp.fixture.environment_probe" nil)))
            (nl-agent-mcp-stdio-test--ck
             "MCP subprocess does not inherit arbitrary host secrets"
             (equal (plist-get result :text) "missing"))))
        (setq explicit-client
              (nl-agent-mcp-stdio-client-new
               "explicit"
               (list emacs-binary "-Q" "--batch" "-l" fixture)
               :directory project-directory :timeout-sec 3
               :environment '("NL_AGENT_MCP_TEST_SECRET=explicit")))
        (let ((registry (nl-agent-tool-registry-new)))
          (nl-agent-mcp-register-tools registry explicit-client :risk 'read)
          (let ((result
                 (nl-agent-permission-call
                  (nl-agent-permission-policy-new :mode 'smart)
                  registry "mcp.explicit.environment_probe" nil)))
            (nl-agent-mcp-stdio-test--ck
             "explicit MCP environment grants cross the process boundary"
             (equal (plist-get result :text) "explicit"))))
        (let* ((metadata (nl-agent-mcp-client-metadata client))
               (transport (plist-get metadata :transport-object)))
          (nl-agent-mcp-stdio-test--ck
           "MCP audit records completed methods without arguments or secrets"
           (and
            (cl-find-if
             (lambda (event)
               (equal (plist-get event :method) "tools/list"))
             (nl-agent-mcp-stdio-history transport))
            (not (string-match-p
                  "parent-secret"
                  (prin1-to-string
                   (nl-agent-mcp-stdio-history transport)))))))
        (nl-agent-mcp-client-close client)
        (let* ((transport
                (plist-get (nl-agent-mcp-client-metadata client)
                           :transport-object)))
          (nl-agent-mcp-stdio-test--ck
           "closing MCP client terminates the stdio subprocess"
           (not (process-live-p
                 (nl-agent-mcp-stdio-process transport))))))
    (when client (nl-agent-mcp-client-close client))
    (when explicit-client (nl-agent-mcp-client-close explicit-client))
    (setenv "NL_AGENT_MCP_TEST_SECRET" old-secret)))

(princ (format "NL-AGENT-MCP-STDIO %s (%d failures)\n"
               (if (= nl-agent-mcp-stdio-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-mcp-stdio-test--fail))
(kill-emacs (if (= nl-agent-mcp-stdio-test--fail 0) 0 1))

;;; mcp-stdio-test.el ends here
