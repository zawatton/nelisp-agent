;;; mcp-legacy-server-fixture.el --- initialize-era MCP stdio fixture  -*- lexical-binding: t; -*-

;; A 2025-03-26 style server: it serves nothing before the `initialize'
;; handshake completes, rejects modern `_meta' after it, and sends a `ping'
;; request of its own before answering `tools/call'.  Setting
;; NL_AGENT_MCP_LEGACY_SILENT=1 makes pre-handshake requests go unanswered,
;; the way some legacy servers ignore an unknown first request.

(require 'json)
(require 'subr-x)

(defun nl-agent-mcp-legacy-fixture--write (value)
  "Write JSON VALUE as one MCP stdio frame."
  (princ (json-encode value))
  (terpri)
  (when (fboundp 'force-output)
    (force-output)))

(defun nl-agent-mcp-legacy-fixture--error (id code message)
  "Write a JSON-RPC error for ID with CODE and MESSAGE."
  (nl-agent-mcp-legacy-fixture--write
   `(("jsonrpc" . "2.0") ("id" . ,id)
     ("error" . (("code" . ,code) ("message" . ,message))))))

(defun nl-agent-mcp-legacy-fixture--result (id result)
  "Write a JSON-RPC RESULT for ID."
  (nl-agent-mcp-legacy-fixture--write
   `(("jsonrpc" . "2.0") ("id" . ,id) ("result" . ,result))))

(defun nl-agent-mcp-legacy-fixture--read ()
  "Return the next parsed stdin message, :eof, or nil for a blank line."
  (let ((line (condition-case nil (read-string "") (end-of-file nil))))
    (cond ((null line) :eof)
          ((string-empty-p line) nil)
          (t (json-parse-string
              line :object-type 'plist :array-type 'list
              :null-object nil :false-object :json-false)))))

(defun nl-agent-mcp-legacy-fixture--ping-answered-p ()
  "Send a server `ping' and return non-nil when the client answers it."
  (nl-agent-mcp-legacy-fixture--write
   '(("jsonrpc" . "2.0") ("id" . "srv-ping-1") ("method" . "ping")))
  (let ((reply (nl-agent-mcp-legacy-fixture--read)))
    ;; An empty result object parses as nil, so test membership.
    (and (consp reply)
         (equal (plist-get reply :id) "srv-ping-1")
         (plist-member reply :result))))

(defconst nl-agent-mcp-legacy-fixture--tools
  (vector
   '(("name" . "echo")
     ("description" . "Echo one text value")
     ("inputSchema"
      . (("type" . "object")
         ("properties" . (("text" . (("type" . "string")))))
         ("required" . ["text"])))))
  "Tools advertised by the fixture.")

(let ((running t)
      (handshake nil)
      (initialized nil))
  (while running
    (let ((message (nl-agent-mcp-legacy-fixture--read)))
      (cond
       ((eq message :eof) (setq running nil))
       ((null message) nil)
       (t
        (let* ((id (plist-get message :id))
               (method (plist-get message :method))
               (params (plist-get message :params)))
          (cond
           ((null id)
            (when (and handshake (equal method "notifications/initialized"))
              (setq initialized t)))
           ((equal method "initialize")
            (setq handshake t)
            (nl-agent-mcp-legacy-fixture--result
             id `(("protocolVersion" . "2025-03-26")
                  ("capabilities" . (("tools" . ,(make-hash-table))))
                  ("serverInfo" . (("name" . "legacy") ("version" . "1"))))))
           ((not initialized)
            (unless (equal (getenv "NL_AGENT_MCP_LEGACY_SILENT") "1")
              (nl-agent-mcp-legacy-fixture--error
               id -32002 "Server not initialized")))
           ((plist-member params :_meta)
            (nl-agent-mcp-legacy-fixture--error id -32602 "unexpected _meta"))
           ((equal method "tools/list")
            (nl-agent-mcp-legacy-fixture--result
             id `(("tools" . ,nl-agent-mcp-legacy-fixture--tools))))
           ((and (equal method "tools/call")
                 (equal (plist-get params :name) "echo"))
            (let ((text (if (nl-agent-mcp-legacy-fixture--ping-answered-p)
                            (format "echo:%s"
                                    (plist-get (plist-get params :arguments)
                                               :text))
                          "ping-unanswered")))
              (nl-agent-mcp-legacy-fixture--result
               id `(("content" . [(("type" . "text") ("text" . ,text))])
                    ("isError" . ,json-false)))))
           ((equal method "tools/call")
            (nl-agent-mcp-legacy-fixture--error id -32602 "unknown tool"))
           (t
            (nl-agent-mcp-legacy-fixture--error
             id -32601 "unknown method")))))))))

;;; mcp-legacy-server-fixture.el ends here
