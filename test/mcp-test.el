;;; mcp-test.el --- transport-neutral MCP adapter tests  -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path
             (or (getenv "NELISP_LLM_LISP")
                 (expand-file-name "../nelisp-llm/lisp")))
(require 'nl-agent-permission)
(require 'nl-agent-runtime)
(require 'nl-agent-mcp)

(defvar nl-agent-mcp-test--fail 0)

(defun nl-agent-mcp-test--ck (name ok)
  (princ (format "%-67s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-mcp-test--fail
                         (1+ nl-agent-mcp-test--fail))
                   "FAIL"))))

(defun nl-agent-mcp-test--error-p (thunk)
  (condition-case nil
      (progn (funcall thunk) nil)
    (error t)))

(let* ((calls nil)
       (closed 0)
       (client
        (nl-agent-mcp-client-new
         "notes"
         (lambda ()
           '((:name "search" :description "Search notes"
              :inputSchema
              (:type "object"
               :properties (:query (:type "string"))
               :required ("query"))
              :annotations (:readOnlyHint t))))
         (lambda (name arguments context)
           (setq calls (append calls (list (list name arguments context))))
           '(:content ((:type "text" :text "one")
                       (:type "text" :text "two"))
             :isError :json-false))
         :close (lambda () (setq closed (1+ closed)))))
       (registry (nl-agent-tool-registry-new))
       (registered (nl-agent-mcp-register-tools registry client)))
  (nl-agent-mcp-test--ck
   "MCP discovery namespaces tools across servers"
   (equal registered '("mcp.notes.search")))
  (let* ((descriptor (car (nl-agent-tool-catalog registry)))
         (metadata (plist-get descriptor :metadata)))
    (nl-agent-mcp-test--ck
     "MCP catalog preserves input schema for model prompting"
     (and (eq (plist-get metadata :protocol) 'mcp)
          (equal (plist-get metadata :remote-name) "search")
          (equal (plist-get
                  (plist-get metadata :input-schema) :type)
                 "object")))
    (nl-agent-mcp-test--ck
     "untrusted server annotations do not lower configured risk"
     (eq (plist-get descriptor :risk) 'external)))
  (let* ((policy
          (nl-agent-permission-policy-new
           :mode 'smart :approval (lambda (_request) 'once)))
         (result
          (nl-agent-permission-call
           policy registry "mcp.notes.search" '(:query "agent")
           '(:step 1))))
    (nl-agent-mcp-test--ck
     "approved MCP tool crosses the common permission boundary"
     (and (eq (plist-get result :status) 'ok)
          (equal (plist-get result :text) "one\ntwo")))
    (nl-agent-mcp-test--ck
     "MCP adapter forwards remote name, arguments, and context"
     (equal (car calls)
            '("search" (:query "agent") (:step 1)))))
  (let ((prompt (nl-agent-runtime-system-prompt registry)))
    (nl-agent-mcp-test--ck
     "runtime prompt publishes MCP name and bounded argument schema"
     (and (string-match-p "mcp.notes.search" prompt)
          (string-match-p "input-schema" prompt)
          (string-match-p "query" prompt))))
  (nl-agent-mcp-client-close client)
  (nl-agent-mcp-client-close client)
  (nl-agent-mcp-test--ck
   "MCP client close is idempotent"
   (= closed 1)))

(let* ((client
        (nl-agent-mcp-client-new
         "errors"
         (lambda ()
           '((:name "fail" :inputSchema (:type "object"))))
         (lambda (_name _arguments _context)
           '(:content ((:type "text" :text "retry with another value"))
             :isError t))))
       (registry (nl-agent-tool-registry-new)))
  (nl-agent-mcp-register-tools registry client :risk 'safe)
  (let ((result
         (nl-agent-permission-call
          (nl-agent-permission-policy-new :mode 'smart)
          registry "mcp.errors.fail" nil)))
    (nl-agent-mcp-test--ck
     "MCP execution errors become model-visible structured failures"
     (and (eq (plist-get result :status) 'error)
          (string-match-p "retry with another value"
                          (plist-get result :error))))))

(let* ((client
        (nl-agent-mcp-client-new
         "unsafe"
         (lambda ()
           '((:name "remote-schema"
              :inputSchema
              (:type "object" :$ref "https://attacker.invalid/schema"))))
         (lambda (_name _arguments _context) "unused")))
       (registry (nl-agent-tool-registry-new)))
  (nl-agent-mcp-test--ck
   "remote schema references are rejected without dereferencing"
   (nl-agent-mcp-test--error-p
    (lambda () (nl-agent-mcp-register-tools registry client)))))

(princ (format "NL-AGENT-MCP %s (%d failures)\n"
               (if (= nl-agent-mcp-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-mcp-test--fail))
(kill-emacs (if (= nl-agent-mcp-test--fail 0) 0 1))

;;; mcp-test.el ends here
