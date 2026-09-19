;;; nl-agent-mcp-stdio.el --- modern MCP stdio client for host tools  -*- lexical-binding: t; -*-

;; Implements the stateless MCP 2026-07-28 stdio binding: newline-delimited
;; JSON-RPC, required per-request metadata, tools/list pagination, and
;; tools/call.  Legacy initialize-era negotiation remains a separate concern.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'nl-agent-mcp)

(cl-defstruct (nl-agent-mcp-stdio
               (:constructor nl-agent-mcp-stdio--make))
  id
  command
  directory
  environment
  timeout-sec
  protocol-version
  max-frame-bytes
  process
  stderr-buffer
  pending
  lines
  next-id
  history
  last-error)

(defconst nl-agent-mcp-stdio-protocol-version "2026-07-28"
  "MCP revision implemented by the modern stdio transport.")

(defconst nl-agent-mcp-stdio-safe-environment
  '("PATH" "LANG" "LC_ALL" "TMPDIR" "TEMP" "TMP"
    "SystemRoot" "COMSPEC" "PATHEXT")
  "Host variables inherited by MCP subprocesses without explicit grants.")

(defun nl-agent-mcp-stdio--keys (keys allowed)
  "Validate constructor KEYS against ALLOWED."
  (unless (= (% (length keys) 2) 0)
    (error "nl-agent-mcp-stdio-client-new: options must be pairs"))
  (let ((tail keys))
    (while tail
      (unless (memq (car tail) allowed)
        (error "nl-agent-mcp-stdio-client-new: unknown option %S"
               (car tail)))
      (setq tail (cddr tail))))
  keys)

(defun nl-agent-mcp-stdio--environment-name (entry)
  "Return validated variable name from environment ENTRY."
  (unless (and (stringp entry)
               (string-match
                "\\`\\([A-Za-z_][A-Za-z0-9_]*\\)=" entry))
    (error "invalid MCP environment entry: %S" entry))
  (match-string 1 entry))

(defun nl-agent-mcp-stdio--filtered-environment (explicit)
  "Return a minimal process environment plus EXPLICIT entries."
  (unless (or (null explicit)
              (and (listp explicit) (cl-every #'stringp explicit)))
    (error "MCP :environment must be a list of NAME=VALUE strings"))
  (let ((result nil))
    (dolist (name nl-agent-mcp-stdio-safe-environment)
      (let ((value (getenv name)))
        (when value
          (setq result (append result (list (concat name "=" value)))))))
    (dolist (entry explicit)
      (let ((name (nl-agent-mcp-stdio--environment-name entry)))
        (setq result
              (cl-remove-if
               (lambda (existing)
                 (equal (nl-agent-mcp-stdio--environment-name existing)
                        name))
               result))
        (setq result (append result (list entry)))))
    result))

(defun nl-agent-mcp-stdio--record (transport event)
  "Record detached EVENT in TRANSPORT history."
  (setf (nl-agent-mcp-stdio-history transport)
        (cons (copy-tree event) (nl-agent-mcp-stdio-history transport))))

(defun nl-agent-mcp-stdio--filter (transport chunk)
  "Frame MCP process output CHUNK into TRANSPORT lines."
  (let ((pending (concat (nl-agent-mcp-stdio-pending transport) chunk))
        (lines (nl-agent-mcp-stdio-lines transport))
        (index nil)
        (maximum (nl-agent-mcp-stdio-max-frame-bytes transport)))
    (setq index (string-search "\n" pending))
    (while index
      (let ((line (substring pending 0 index)))
        (when (string-suffix-p "\r" line)
          (setq line (substring line 0 (1- (length line)))))
        (if (> (string-bytes line) maximum)
            (setf (nl-agent-mcp-stdio-last-error transport)
                  (format "MCP frame exceeds %d bytes" maximum))
          (setq lines (append lines (list line)))))
      (setq pending (substring pending (1+ index)))
      (setq index (string-search "\n" pending)))
    (when (> (string-bytes pending) maximum)
      (setf (nl-agent-mcp-stdio-last-error transport)
            (format "MCP pending frame exceeds %d bytes" maximum))
      (setq pending ""))
    (setf (nl-agent-mcp-stdio-pending transport) pending)
    (setf (nl-agent-mcp-stdio-lines transport) lines)))

(defun nl-agent-mcp-stdio--dispose (transport)
  "Release TRANSPORT process and buffers."
  (let ((process (nl-agent-mcp-stdio-process transport))
        (stderr-buffer (nl-agent-mcp-stdio-stderr-buffer transport)))
    (when (process-live-p process)
      (delete-process process))
    (when (and stderr-buffer (buffer-live-p stderr-buffer))
      (kill-buffer stderr-buffer))
    (setf (nl-agent-mcp-stdio-process transport) nil)
    (setf (nl-agent-mcp-stdio-stderr-buffer transport) nil)
    (setf (nl-agent-mcp-stdio-pending transport) "")
    (setf (nl-agent-mcp-stdio-lines transport) nil)))

(defun nl-agent-mcp-stdio--stderr (transport)
  "Return bounded diagnostic stderr for TRANSPORT."
  (let ((buffer (nl-agent-mcp-stdio-stderr-buffer transport)))
    (if (and buffer (buffer-live-p buffer))
        (with-current-buffer buffer
          (let ((text (buffer-string)))
            (substring text (max 0 (- (length text) 2000)))))
      "")))

(defun nl-agent-mcp-stdio--start (transport)
  "Start TRANSPORT's MCP server when needed."
  (unless (process-live-p (nl-agent-mcp-stdio-process transport))
    (when (nl-agent-mcp-stdio-process transport)
      (nl-agent-mcp-stdio--dispose transport))
    (setf (nl-agent-mcp-stdio-pending transport) "")
    (setf (nl-agent-mcp-stdio-lines transport) nil)
    (setf (nl-agent-mcp-stdio-last-error transport) nil)
    (let* ((default-directory (nl-agent-mcp-stdio-directory transport))
           (process-environment
            (nl-agent-mcp-stdio-environment transport))
           (stderr-buffer (generate-new-buffer " *nl-agent-mcp-stderr*"))
           (process
            (make-process
             :name (generate-new-buffer-name "nl-agent-mcp")
             :command (nl-agent-mcp-stdio-command transport)
             :connection-type 'pipe
             :coding 'utf-8-unix
             :noquery t
             :stderr stderr-buffer
             :filter
             (lambda (_process chunk)
               (nl-agent-mcp-stdio--filter transport chunk)))))
      (set-process-query-on-exit-flag process nil)
      (setf (nl-agent-mcp-stdio-process transport) process)
      (setf (nl-agent-mcp-stdio-stderr-buffer transport) stderr-buffer)
      (nl-agent-mcp-stdio--record transport '(:status started))))
  transport)

(defun nl-agent-mcp-stdio--next-line (transport)
  "Wait for and return TRANSPORT's next JSON-RPC line."
  (let ((deadline (+ (float-time)
                     (nl-agent-mcp-stdio-timeout-sec transport))))
    (while (and (null (nl-agent-mcp-stdio-lines transport))
                (null (nl-agent-mcp-stdio-last-error transport))
                (< (float-time) deadline)
                (process-live-p (nl-agent-mcp-stdio-process transport)))
      (accept-process-output
       (nl-agent-mcp-stdio-process transport) 0.05))
    (when (nl-agent-mcp-stdio-last-error transport)
      (error "%s" (nl-agent-mcp-stdio-last-error transport)))
    (let ((lines (nl-agent-mcp-stdio-lines transport)))
      (unless lines
        (error "MCP response timeout or exit: %s"
               (nl-agent-mcp-stdio--stderr transport)))
      (setf (nl-agent-mcp-stdio-lines transport) (cdr lines))
      (car lines))))

(defun nl-agent-mcp-stdio--json-key (value)
  "Return VALUE as a JSON object key string."
  (cond ((keywordp value) (substring (symbol-name value) 1))
        ((symbolp value) (symbol-name value))
        ((stringp value) value)
        (t (error "unsupported JSON object key: %S" value))))

(defun nl-agent-mcp-stdio--alist-p (value)
  "Return non-nil when VALUE is a non-empty alist."
  (and (consp value) (cl-every #'consp value)))

(defun nl-agent-mcp-stdio--plist-p (value)
  "Return non-nil when VALUE is a keyword/string/symbol plist."
  (and (listp value)
       (= (% (length value) 2) 0)
       (let ((tail value) (ok t))
         (while (and tail ok)
           (unless (or (keywordp (car tail))
                       (symbolp (car tail))
                       (stringp (car tail)))
             (setq ok nil))
           (setq tail (cddr tail)))
         ok)))

(defun nl-agent-mcp-stdio--json-value (value)
  "Convert Lisp VALUE into data accepted by `json-encode'."
  (cond
   ((or (null value) (stringp value) (numberp value)
        (eq value t) (eq value :json-false))
    value)
   ((vectorp value)
    (apply #'vector
           (mapcar #'nl-agent-mcp-stdio--json-value
                   (append value nil))))
   ((nl-agent-mcp-stdio--alist-p value)
    (mapcar
     (lambda (pair)
       (cons (nl-agent-mcp-stdio--json-key (car pair))
             (nl-agent-mcp-stdio--json-value (cdr pair))))
     value))
   ((nl-agent-mcp-stdio--plist-p value)
    (let ((tail value) (result nil))
      (while tail
        (setq result
              (append
               result
               (list
                (cons
                 (nl-agent-mcp-stdio--json-key (car tail))
                 (nl-agent-mcp-stdio--json-value (cadr tail))))))
        (setq tail (cddr tail)))
      result))
   ((listp value)
    (apply #'vector (mapcar #'nl-agent-mcp-stdio--json-value value)))
   (t (error "unsupported MCP JSON value: %S" value))))

(defun nl-agent-mcp-stdio--metadata (transport)
  "Return required modern per-request metadata for TRANSPORT."
  (let ((empty-capabilities (make-hash-table :test 'equal)))
    (list
     (cons "io.modelcontextprotocol/protocolVersion"
           (nl-agent-mcp-stdio-protocol-version transport))
     (cons "io.modelcontextprotocol/clientInfo"
           '(("name" . "nelisp-agent") ("version" . "0.1.0-dev")))
     (cons "io.modelcontextprotocol/clientCapabilities"
           empty-capabilities))))

(defun nl-agent-mcp-stdio--send (transport form)
  "Send one JSON FORM to TRANSPORT's MCP server."
  (unless (process-live-p (nl-agent-mcp-stdio-process transport))
    (error "MCP server is not live"))
  (let ((wire (json-encode form)))
    (when (string-match-p "[\n\r]" wire)
      (error "MCP JSON encoder emitted an embedded newline"))
    (process-send-string
     (nl-agent-mcp-stdio-process transport) (concat wire "\n"))))

(defun nl-agent-mcp-stdio--request (transport method params)
  "Send METHOD with PARAMS through TRANSPORT and return result data."
  (nl-agent-mcp-stdio--start transport)
  (setf (nl-agent-mcp-stdio-next-id transport)
        (1+ (nl-agent-mcp-stdio-next-id transport)))
  (let* ((request-id (nl-agent-mcp-stdio-next-id transport))
         (params
          (append params
                  (list (cons "_meta"
                              (nl-agent-mcp-stdio--metadata transport)))))
         (request
          (list (cons "jsonrpc" "2.0")
                (cons "id" request-id)
                (cons "method" method)
                (cons "params" params))))
    (nl-agent-mcp-stdio--send transport request)
    (catch 'nl-agent-mcp-response
      (while t
        (let* ((line (nl-agent-mcp-stdio--next-line transport))
               (message
                (condition-case err
                    (json-parse-string
                     line :object-type 'plist :array-type 'list
                     :null-object nil :false-object :json-false)
                  (error
                   (error "invalid MCP JSON response: %S" err))))
               (response-id (plist-get message :id)))
          (cond
           ((and response-id (equal response-id request-id))
            (let ((protocol-error (plist-get message :error)))
              (if protocol-error
                  (error "MCP %s error %s: %s"
                         method
                         (plist-get protocol-error :code)
                         (plist-get protocol-error :message))
                (nl-agent-mcp-stdio--record
                 transport (list :status 'completed :method method))
                (throw 'nl-agent-mcp-response
                       (copy-tree (plist-get message :result))))))
           ((plist-get message :method)
            (nl-agent-mcp-stdio--record
             transport
             (list :status 'notification
                   :method (plist-get message :method))))
           (t
            (error "uncorrelated MCP response: %S" message))))))))

(defun nl-agent-mcp-stdio--list-tools (transport)
  "Return all paginated tools exposed through TRANSPORT."
  (let ((cursor nil) (seen nil) (tools nil) (pages 0) (running t))
    (while running
      (setq pages (1+ pages))
      (when (> pages 100)
        (error "MCP tools/list exceeded 100 pages"))
      (let* ((params (if cursor (list (cons "cursor" cursor)) nil))
             (result
              (nl-agent-mcp-stdio--request
               transport "tools/list" params))
             (page-tools (plist-get result :tools))
             (next (plist-get result :nextCursor)))
        (unless (listp page-tools)
          (error "MCP tools/list returned no tool list"))
        (setq tools (append tools (copy-tree page-tools)))
        (cond
         ((null next) (setq running nil))
         ((not (stringp next))
          (error "MCP tools/list returned invalid cursor %S" next))
         ((member next seen)
          (error "MCP tools/list repeated cursor %S" next))
         (t
          (setq seen (cons next seen))
          (setq cursor next)))))
    tools))

(defun nl-agent-mcp-stdio--call-tool
    (transport name arguments _context)
  "Call NAME with ARGUMENTS through TRANSPORT."
  (let ((params (list (cons "name" name))))
    (when arguments
      (unless (or (nl-agent-mcp-stdio--plist-p arguments)
                  (nl-agent-mcp-stdio--alist-p arguments))
        (error "MCP tool arguments must be an object-like list"))
      (setq params
            (append
             params
             (list
              (cons "arguments"
                    (nl-agent-mcp-stdio--json-value arguments))))))
    (nl-agent-mcp-stdio--request transport "tools/call" params)))

(defun nl-agent-mcp-stdio--close (transport)
  "Close TRANSPORT using stdio EOF, then release its process."
  (let ((process (nl-agent-mcp-stdio-process transport)))
    (when (process-live-p process)
      (process-send-eof process)
      (let ((deadline (+ (float-time) 0.5)))
        (while (and (process-live-p process)
                    (< (float-time) deadline))
          (accept-process-output process 0.05)))))
  (nl-agent-mcp-stdio--dispose transport)
  (nl-agent-mcp-stdio--record transport '(:status closed)))

;;;###autoload
(defun nl-agent-mcp-stdio-client-new (id command &rest keys)
  "Create a modern MCP stdio client ID for subprocess COMMAND.

KEYS accepts :DIRECTORY, :ENVIRONMENT, :TIMEOUT-SEC, :PROTOCOL-VERSION, and
:MAX-FRAME-BYTES.  The child inherits only a small safe environment plus
explicit NAME=VALUE entries.  The default protocol revision is 2026-07-28."
  (nl-agent-mcp-stdio--keys
   keys '(:directory :environment :timeout-sec :protocol-version
          :max-frame-bytes))
  (unless (and (consp command) (cl-every #'stringp command))
    (error "nl-agent-mcp-stdio-client-new: COMMAND must be a string list"))
  (let ((directory (or (plist-get keys :directory) default-directory))
        (timeout (or (plist-get keys :timeout-sec) 10))
        (version
         (or (plist-get keys :protocol-version)
             nl-agent-mcp-stdio-protocol-version))
        (maximum (or (plist-get keys :max-frame-bytes) (* 2 1024 1024))))
    (unless (and (stringp directory) (file-directory-p directory))
      (error "nl-agent-mcp-stdio-client-new: directory must exist"))
    (unless (and (numberp timeout) (> timeout 0))
      (error "nl-agent-mcp-stdio-client-new: timeout must be positive"))
    (unless (and (stringp version) (not (string-empty-p version)))
      (error "nl-agent-mcp-stdio-client-new: protocol version is invalid"))
    (unless (and (integerp maximum) (> maximum 0))
      (error "nl-agent-mcp-stdio-client-new: frame limit must be positive"))
    (let ((transport
           (nl-agent-mcp-stdio--make
            :id (nl-agent-mcp--name id "nl-agent-mcp-stdio-client-new")
            :command (copy-sequence command)
            :directory
            (file-name-as-directory (expand-file-name directory))
            :environment
            (nl-agent-mcp-stdio--filtered-environment
             (plist-get keys :environment))
            :timeout-sec timeout
            :protocol-version version
            :max-frame-bytes maximum
            :process nil :stderr-buffer nil :pending "" :lines nil
            :next-id 0 :history nil :last-error nil)))
      (nl-agent-mcp-client-new
       id
       (lambda () (nl-agent-mcp-stdio--list-tools transport))
       (lambda (name arguments context)
         (nl-agent-mcp-stdio--call-tool
          transport name arguments context))
       :close (lambda () (nl-agent-mcp-stdio--close transport))
       :metadata
       (list :transport 'stdio
             :protocol-version version
             :transport-object transport)))))

(provide 'nl-agent-mcp-stdio)
;;; nl-agent-mcp-stdio.el ends here
