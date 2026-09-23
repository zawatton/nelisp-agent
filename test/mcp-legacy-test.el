;;; mcp-legacy-test.el --- legacy MCP stdio transport tests  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-permission)
(require 'nl-agent-mcp-stdio)

(defvar nl-agent-mcp-legacy-test--fail 0)

(defun nl-agent-mcp-legacy-test--ck (name ok)
  (princ (format "%-69s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-mcp-legacy-test--fail
                         (1+ nl-agent-mcp-legacy-test--fail))
                   "FAIL"))))

(let* ((project-directory default-directory)
       (emacs-binary
        (expand-file-name invocation-name invocation-directory))
       (legacy-fixture
        (expand-file-name
         "test/mcp-legacy-server-fixture.el" project-directory))
       (modern-fixture
        (expand-file-name
         "test/mcp-modern-server-fixture.el" project-directory))
       (client nil)
       (silent-client nil)
       (explicit-legacy-client nil)
       (modern-client nil)
       (unsupported-client nil)
       (explicit-modern-client nil))
  (unwind-protect
      (progn
        (setq client
              (nl-agent-mcp-stdio-client-new
               "legacy" (list emacs-binary "-Q" "--batch" "-l" legacy-fixture)
               :directory project-directory :timeout-sec 3))
        (let ((registry (nl-agent-tool-registry-new)))
          (nl-agent-mcp-register-tools registry client :risk 'read)
          (let ((transport
                 (plist-get (nl-agent-mcp-client-metadata client)
                            :transport-object)))
            (nl-agent-mcp-legacy-test--ck
             "legacy auto era resolves to legacy"
             (eq (nl-agent-mcp-stdio-resolved-era transport) 'legacy))
            (nl-agent-mcp-legacy-test--ck
             "legacy auto era negotiates 2025-03-26"
             (equal
              (nl-agent-mcp-stdio-negotiated-version transport)
              "2025-03-26")))
          (nl-agent-mcp-legacy-test--ck
           "legacy stdio tools/list discovers the echo catalog"
           (equal
            (mapcar (lambda (item) (plist-get item :name))
                    (nl-agent-tool-catalog registry))
            '("mcp.legacy.echo")))
          (let ((result
                 (nl-agent-permission-call
                  (nl-agent-permission-policy-new :mode 'smart)
                  registry "mcp.legacy.echo" '(:text "hi"))))
            (nl-agent-mcp-legacy-test--ck
             "legacy tools/call answers a server ping request"
             (and (eq (plist-get result :status) 'ok)
                  (equal (plist-get result :text) "echo:hi")))))

        (setq silent-client
              (nl-agent-mcp-stdio-client-new
               "silent-legacy"
               (list emacs-binary "-Q" "--batch" "-l" legacy-fixture)
               :directory project-directory :timeout-sec 3
               :environment '("NL_AGENT_MCP_LEGACY_SILENT=1")
               :probe-timeout-sec 0.5))
        (let ((registry (nl-agent-tool-registry-new)))
          (nl-agent-mcp-register-tools registry silent-client :risk 'read)
          (let ((result
                 (nl-agent-permission-call
                  (nl-agent-permission-policy-new :mode 'smart)
                  registry "mcp.silent-legacy.echo" '(:text "silent"))))
            (nl-agent-mcp-legacy-test--ck
             "silent legacy probe falls back and answers ping"
             (and (eq (plist-get result :status) 'ok)
                  (equal (plist-get result :text) "echo:silent")))))

        (setq explicit-legacy-client
              (nl-agent-mcp-stdio-client-new
               "explicit-legacy"
               (list emacs-binary "-Q" "--batch" "-l" legacy-fixture)
               :directory project-directory :timeout-sec 3
               :era 'legacy))
        (let ((registry (nl-agent-tool-registry-new))
              (transport
               (plist-get (nl-agent-mcp-client-metadata explicit-legacy-client)
                          :transport-object)))
          (nl-agent-mcp-register-tools registry explicit-legacy-client :risk 'read)
          (nl-agent-mcp-legacy-test--ck
           "explicit legacy era skips discovery probing"
           (not (cl-find-if
                 (lambda (event)
                   (eq (plist-get event :status) 'probed))
                 (nl-agent-mcp-stdio-history transport)))))

        (setq modern-client
              (nl-agent-mcp-stdio-client-new
               "modern" (list emacs-binary "-Q" "--batch" "-l" modern-fixture)
               :directory project-directory :timeout-sec 3))
        (let ((transport
               (plist-get (nl-agent-mcp-client-metadata modern-client)
                          :transport-object)))
          (nl-agent-mcp-register-tools
           (nl-agent-tool-registry-new) modern-client :risk 'read)
          (nl-agent-mcp-legacy-test--ck
           "modern fixture resolves to modern era"
           (eq (nl-agent-mcp-stdio-resolved-era transport) 'modern)))

        (setq unsupported-client
              (nl-agent-mcp-stdio-client-new
               "unsupported-modern"
               (list emacs-binary "-Q" "--batch" "-l" modern-fixture)
               :directory project-directory :timeout-sec 3
               :environment
               '("NL_AGENT_MCP_FIXTURE_VERSIONS=2099-01-01")))
        (condition-case nil
            (progn
              (nl-agent-mcp-register-tools
               (nl-agent-tool-registry-new) unsupported-client :risk 'read)
              (nl-agent-mcp-legacy-test--ck
               "modern unsupported discover result signals an error" nil))
          (error
           (let ((transport
                  (plist-get (nl-agent-mcp-client-metadata unsupported-client)
                             :transport-object)))
             (nl-agent-mcp-legacy-test--ck
              "modern unsupported discover result stays not legacy"
              (not (eq (nl-agent-mcp-stdio-resolved-era transport) 'legacy))))))

        (setq explicit-modern-client
              (nl-agent-mcp-stdio-client-new
               "explicit-modern"
               (list emacs-binary "-Q" "--batch" "-l" legacy-fixture)
               :directory project-directory :timeout-sec 3
               :era 'modern))
        (condition-case nil
            (progn
              (nl-agent-mcp-register-tools
               (nl-agent-tool-registry-new) explicit-modern-client :risk 'read)
              (nl-agent-mcp-legacy-test--ck
               "explicit modern era rejects a legacy fixture" nil))
          (error
           (nl-agent-mcp-legacy-test--ck
            "explicit modern era rejects a legacy fixture" t))))
    (when client (nl-agent-mcp-client-close client))
    (when silent-client (nl-agent-mcp-client-close silent-client))
    (when explicit-legacy-client
      (nl-agent-mcp-client-close explicit-legacy-client))
    (when modern-client (nl-agent-mcp-client-close modern-client))
    (when unsupported-client (nl-agent-mcp-client-close unsupported-client))
    (when explicit-modern-client
      (nl-agent-mcp-client-close explicit-modern-client))))

(princ (format "NL-AGENT-MCP-LEGACY %s (%d failures)\n"
               (if (= nl-agent-mcp-legacy-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-mcp-legacy-test--fail))
(kill-emacs (if (= nl-agent-mcp-legacy-test--fail 0) 0 1))

;;; mcp-legacy-test.el ends here
