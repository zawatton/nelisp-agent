;;; nl-agent-mcp.el --- transport-neutral MCP tool adapter  -*- lexical-binding: t; -*-

;; MCP servers remain host-owned capabilities.  This module converts their
;; public tool catalog into the same registry used by local tools, preserving
;; schemas for the model while keeping call functions out of the worker-facing
;; descriptors.

;;; Code:

(require 'nl-llm-compat)
(require 'cl-lib)
(require 'subr-x)
(require 'nl-agent-tool)

(cl-defstruct (nl-agent-mcp-client
               (:constructor nl-agent-mcp-client--make))
  id
  list-tools-fn
  call-tool-fn
  close-fn
  metadata
  closed)

(defun nl-agent-mcp--keys (keys allowed where)
  "Validate KEYS against ALLOWED for WHERE."
  (unless (= (% (length keys) 2) 0)
    (error "%s: options must be KEY VALUE pairs" where))
  (let ((tail keys))
    (while tail
      (unless (memq (car tail) allowed)
        (error "%s: unknown option %S" where (car tail)))
      (setq tail (cddr tail))))
  keys)

(defun nl-agent-mcp--name (value where)
  "Return VALUE as a validated MCP name for WHERE."
  (let ((name (cond ((stringp value) value)
                    ((symbolp value) (symbol-name value))
                    (t nil))))
    (unless (and name
                 (<= 1 (length name))
                 (<= (length name) 128)
                 (string-match-p
                  "\\`[A-Za-z0-9_.-]+\\'" name))
      (error "%s: invalid MCP name %S" where value))
    name))

;;;###autoload
(defun nl-agent-mcp-client-new (id list-tools call-tool &rest keys)
  "Create transport-neutral MCP client ID.

LIST-TOOLS returns public MCP tool plists.  CALL-TOOL receives (NAME ARGUMENTS
CONTEXT) and returns an MCP CallToolResult plist or observation text.  KEYS
accepts :CLOSE and :METADATA."
  (nl-agent-mcp--keys keys '(:close :metadata) "nl-agent-mcp-client-new")
  (unless (functionp list-tools)
    (error "nl-agent-mcp-client-new: LIST-TOOLS must be a function"))
  (unless (functionp call-tool)
    (error "nl-agent-mcp-client-new: CALL-TOOL must be a function"))
  (let ((close (plist-get keys :close)))
    (when (and close (not (functionp close)))
      (error "nl-agent-mcp-client-new: :close must be a function"))
    (nl-agent-mcp-client--make
     :id (nl-agent-mcp--name id "nl-agent-mcp-client-new")
     :list-tools-fn list-tools
     :call-tool-fn call-tool
     :close-fn (or close (lambda () nil))
     :metadata (copy-tree (plist-get keys :metadata))
     :closed nil)))

(defun nl-agent-mcp--ensure-open (client where)
  "Validate CLIENT is open for WHERE."
  (unless (nl-agent-mcp-client-p client)
    (error "%s: invalid MCP client" where))
  (when (nl-agent-mcp-client-closed client)
    (error "%s: MCP client is closed" where))
  client)

;;;###autoload
(defun nl-agent-mcp-client-list-tools (client)
  "Return CLIENT's detached MCP tool catalog."
  (nl-agent-mcp--ensure-open client "nl-agent-mcp-client-list-tools")
  (let ((tools (funcall (nl-agent-mcp-client-list-tools-fn client))))
    (unless (listp tools)
      (error "MCP client %s returned a non-list tool catalog"
             (nl-agent-mcp-client-id client)))
    (copy-tree tools)))

;;;###autoload
(defun nl-agent-mcp-client-call (client name arguments &optional context)
  "Call MCP tool NAME with ARGUMENTS and CONTEXT through CLIENT."
  (nl-agent-mcp--ensure-open client "nl-agent-mcp-client-call")
  (funcall
   (nl-agent-mcp-client-call-tool-fn client)
   (nl-agent-mcp--name name "nl-agent-mcp-client-call")
   (copy-tree arguments) (copy-tree context)))

;;;###autoload
(defun nl-agent-mcp-client-close (client)
  "Close CLIENT idempotently and return it."
  (unless (nl-agent-mcp-client-p client)
    (error "nl-agent-mcp-client-close: invalid MCP client"))
  (unless (nl-agent-mcp-client-closed client)
    (funcall (nl-agent-mcp-client-close-fn client))
    (setf (nl-agent-mcp-client-closed client) t))
  client)

(defun nl-agent-mcp--get (object camel kebab)
  "Read CAMEL or KEBAB key from plist or alist OBJECT."
  (cond
   ((not (listp object)) nil)
   ((or (plist-member object camel) (plist-member object kebab))
    (if (plist-member object camel)
        (plist-get object camel)
      (plist-get object kebab)))
   (t
    (let ((camel-name (substring (symbol-name camel) 1))
          (kebab-name (substring (symbol-name kebab) 1)))
      (or (cdr (assoc camel-name object))
          (cdr (assoc kebab-name object)))))))

(defun nl-agent-mcp--schema-walk (value depth counter)
  "Validate schema VALUE bounds at DEPTH using mutable COUNTER."
  (setcar counter (1+ (car counter)))
  (when (> (car counter) 2000)
    (error "MCP schema exceeds 2000 nodes"))
  (when (> depth 32)
    (error "MCP schema exceeds depth 32"))
  (cond
   ((vectorp value)
    (mapc
     (lambda (item)
       (nl-agent-mcp--schema-walk item (1+ depth) counter))
     (append value nil)))
   ((listp value)
    (let ((tail value))
      (while tail
        (let ((key (car tail))
              (child (and (cdr tail) (cadr tail))))
          (when (and child
                     (member key '(:$ref "$ref"))
                     (stringp child)
                     (string-match-p "\\`https?://" child))
            (error "remote MCP schema $ref is disabled: %s" child)))
        (nl-agent-mcp--schema-walk (car tail) (1+ depth) counter)
        (setq tail (cdr tail)))))))

(defun nl-agent-mcp--validate-schema (schema tool-name)
  "Validate bounded, local SCHEMA for TOOL-NAME and return a copy."
  (unless (listp schema)
    (error "MCP tool %s has no object inputSchema" tool-name))
  (nl-agent-mcp--schema-walk schema 0 (list 0))
  (copy-tree schema))

(defun nl-agent-mcp--result-text (result)
  "Return model-visible text from MCP CallToolResult RESULT."
  (if (stringp result)
      result
    (unless (listp result)
      (error "MCP tool returned unsupported result: %S" result))
    (let* ((content (plist-get result :content))
           (structured
            (nl-agent-mcp--get
             result :structuredContent :structured-content))
           (parts nil))
      (dolist (item content)
        (let ((type (plist-get item :type)))
          (cond
           ((or (equal type "text") (eq type 'text))
            (when (stringp (plist-get item :text))
              (setq parts
                    (append parts (list (plist-get item :text))))))
           (type
            (setq parts
                  (append parts
                          (list (format "[%s content]" type))))))))
      (when (and (null parts) structured)
        (setq parts (list (format "%S" structured))))
      (let ((text
             (if parts
                 (string-join parts "\n")
               "(MCP tool returned no model-visible content)")))
        (if (and (plist-get result :isError)
                 (not (eq (plist-get result :isError) :json-false)))
            (error "MCP tool execution error: %s" text)
          text)))))

;;;###autoload
(defun nl-agent-mcp-register-tools (registry client &rest keys)
  "Discover CLIENT tools and register them into REGISTRY.

KEYS accepts :PREFIX and :RISK.  Public names are
`mcp.PREFIX.REMOTE-NAME'; PREFIX defaults to the client id.  RISK is an
explicit risk symbol or a trusted function of the remote descriptor.  Server
annotations are preserved as metadata but never grant lower risk."
  (nl-agent-mcp--keys keys '(:prefix :risk) "nl-agent-mcp-register-tools")
  (unless (nl-agent-tool-registry-p registry)
    (error "nl-agent-mcp-register-tools: invalid tool registry"))
  (nl-agent-mcp--ensure-open client "nl-agent-mcp-register-tools")
  (let ((prefix
         (nl-agent-mcp--name
          (or (plist-get keys :prefix) (nl-agent-mcp-client-id client))
          "nl-agent-mcp-register-tools"))
        (risk-source (or (plist-get keys :risk) 'external))
        (registered nil))
    (unless (or (functionp risk-source)
                (memq risk-source nl-agent-tool-risks))
      (error "nl-agent-mcp-register-tools: invalid :risk %S" risk-source))
    (dolist (descriptor (nl-agent-mcp-client-list-tools client))
      (let* ((remote-name
              (nl-agent-mcp--name
               (plist-get descriptor :name) "MCP tool descriptor"))
             (public-name
              (nl-agent-mcp--name
               (concat "mcp." prefix "." remote-name)
               "aggregated MCP tool"))
             (description (or (plist-get descriptor :description) ""))
             (schema
              (nl-agent-mcp--validate-schema
               (nl-agent-mcp--get
                descriptor :inputSchema :input-schema)
               remote-name))
             (risk
              (if (memq risk-source nl-agent-tool-risks)
                  risk-source
                (funcall risk-source (copy-tree descriptor)))))
        (unless (stringp description)
          (error "MCP tool %s has a non-text description" remote-name))
        (unless (memq risk nl-agent-tool-risks)
          (error "MCP risk resolver returned invalid risk %S" risk))
        (nl-agent-tool-register
         registry
         (nl-agent-tool-new
          public-name
          (lambda (arguments context)
            (nl-agent-mcp--result-text
             (nl-agent-mcp-client-call
              client remote-name arguments context)))
          :description description
          :risk risk
          :metadata
          (list
           :protocol 'mcp
           :server (nl-agent-mcp-client-id client)
           :remote-name remote-name
           :input-schema schema
           :output-schema
           (copy-tree
            (nl-agent-mcp--get
             descriptor :outputSchema :output-schema))
           :annotations (copy-tree (plist-get descriptor :annotations)))))
        (setq registered (append registered (list public-name)))))
    registered))

(provide 'nl-agent-mcp)
;;; nl-agent-mcp.el ends here
