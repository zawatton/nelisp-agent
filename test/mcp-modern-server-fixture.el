;;; mcp-modern-server-fixture.el --- MCP 2026-07-28 stdio fixture  -*- lexical-binding: t; -*-

(require 'json)
(require 'subr-x)

(defun nl-agent-mcp-fixture--write (value)
  "Write JSON VALUE as one MCP stdio frame."
  (princ (json-encode value))
  (terpri)
  (when (fboundp 'force-output)
    (force-output)))

(defun nl-agent-mcp-fixture--error (id code message &optional data)
  "Write a JSON-RPC error for ID with CODE and MESSAGE.
When DATA is non-nil, include it as the error data member."
  (nl-agent-mcp-fixture--write
   `(("jsonrpc" . "2.0") ("id" . ,id)
     ("error" . (("code" . ,code) ("message" . ,message)
                 ,@(and data (list (cons "data" data))))))))

(defun nl-agent-mcp-fixture--supported-versions ()
  "Return the fixture's supported protocol versions."
  (let ((value
         (or (getenv "NL_AGENT_MCP_FIXTURE_VERSIONS")
             "2026-07-28")))
    (split-string value "[[:space:]]*,[[:space:]]*" t)))

(defun nl-agent-mcp-fixture--meta-valid-p (params)
  "Return non-nil when PARAMS has required modern metadata."
  (let ((meta (plist-get params :_meta)))
    (and
     (equal
      (plist-get meta :io.modelcontextprotocol/protocolVersion)
      "2026-07-28")
     (plist-member meta :io.modelcontextprotocol/clientCapabilities))))

(let ((running t))
  (while running
    (let ((line
           (condition-case nil
               (read-string "")
             (end-of-file nil))))
      (if (null line)
          (setq running nil)
        (unless (string-empty-p line)
          (let* ((request
                  (json-parse-string
                   line :object-type 'plist :array-type 'list
                   :null-object nil :false-object :json-false))
                 (id (plist-get request :id))
                 (method (plist-get request :method))
                 (params (plist-get request :params)))
            (cond
             ((not (nl-agent-mcp-fixture--meta-valid-p params))
              (nl-agent-mcp-fixture--error
               id -32602 "missing modern request metadata"))
             ((equal method "server/discover")
              (let ((supported
                     (nl-agent-mcp-fixture--supported-versions))
                    (requested
                     (plist-get
                      (plist-get params :_meta)
                      :io.modelcontextprotocol/protocolVersion)))
                (if (member requested supported)
                    (nl-agent-mcp-fixture--write
                     `(("jsonrpc" . "2.0") ("id" . ,id)
                       ("result"
                        . (("resultType" . "complete")
                           ("supportedVersions" . ,supported)
                           ("capabilities" . (("tools" . ())))
                           ("_meta"
                            . (("io.modelcontextprotocol/serverInfo"
                                . (("name" . "fixture")
                                   ("version" . "1")))))))))
                  (nl-agent-mcp-fixture--error
                   id -32022 "Unsupported protocol version"
                   `(("supported" . ,supported)
                     ("requested" . ,requested))))))
             ((equal method "tools/list")
              (nl-agent-mcp-fixture--write
               `(("jsonrpc" . "2.0") ("id" . ,id)
                 ("result"
                  . (("resultType" . "complete")
                     ("tools"
                      . [( ("name" . "echo")
                           ("description" . "Echo one text value")
                           ("inputSchema"
                            . (("type" . "object")
                               ("properties"
                                . (("text" . (("type" . "string")))))
                               ("required" . ["text"]))))
                         ( ("name" . "environment_probe")
                           ("description" . "Report isolated environment")
                           ("inputSchema" . (("type" . "object"))))]))))))
             ((equal method "tools/call")
              (let* ((name (plist-get params :name))
                     (arguments (plist-get params :arguments))
                     (text
                      (cond
                       ((equal name "echo")
                        (format "echo:%s"
                                (plist-get arguments :text)))
                       ((equal name "environment_probe")
                        (or (getenv "NL_AGENT_MCP_TEST_SECRET") "missing"))
                       (t nil))))
                (if text
                    (nl-agent-mcp-fixture--write
                     `(("jsonrpc" . "2.0") ("id" . ,id)
                       ("result"
                        . (("resultType" . "complete")
                           ("content"
                            . [( ("type" . "text")
                                 ("text" . ,text))])
                           ("isError" . ,json-false)))))
                  (nl-agent-mcp-fixture--error
                   id -32602 "unknown tool"))))
             (t
              (nl-agent-mcp-fixture--error
               id -32601 "unknown method")))))))))

;;; mcp-modern-server-fixture.el ends here
