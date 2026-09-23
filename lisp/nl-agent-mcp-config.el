;;; nl-agent-mcp-config.el --- data-only MCP server configuration  -*- lexical-binding: t; -*-

;; Configuration is JSON data, never evaluated Lisp.  Secret values are not
;; stored in the file: each environment entry maps a child variable name to an
;; existing host variable name and is resolved only during assembly.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'nl-agent-mcp-stdio)

(defconst nl-agent-mcp-config-max-bytes (* 1024 1024)
  "Maximum accepted MCP configuration file size.")

(defun nl-agent-mcp-config--keys (value allowed where)
  "Validate plist VALUE against ALLOWED keys for WHERE."
  (unless (listp value)
    (error "%s must be a JSON object" where))
  (unless (= (% (length value) 2) 0)
    (error "%s contains malformed object data" where))
  (let ((tail value))
    (while tail
      (unless (memq (car tail) allowed)
        (error "%s contains unknown key %S" where (car tail)))
      (setq tail (cddr tail))))
  value)

(defun nl-agent-mcp-config--environment (value id)
  "Resolve child-to-host environment mapping VALUE for server ID."
  (when value
    (unless (and (listp value) (= (% (length value) 2) 0))
      (error "MCP server %s environment must be an object" id))
    (let ((tail value) (result nil))
      (while tail
        (let* ((child-key (car tail))
               (child
                (if (keywordp child-key)
                    (substring (symbol-name child-key) 1)
                  (format "%s" child-key)))
               (host (cadr tail)))
          (unless (string-match-p
                   "\\`[A-Za-z_][A-Za-z0-9_]*\\'" child)
            (error "MCP server %s has invalid child variable %S" id child))
          (unless (and (stringp host)
                       (string-match-p
                        "\\`[A-Za-z_][A-Za-z0-9_]*\\'" host))
            (error "MCP server %s has invalid host variable %S" id host))
          (let ((secret (getenv host)))
            (unless secret
              (error "MCP server %s requires unset host variable %s"
                     id host))
            (setq result
                  (append result (list (concat child "=" secret))))))
        (setq tail (cddr tail)))
      result)))

(defun nl-agent-mcp-config--risk (value id)
  "Return trusted risk symbol VALUE for server ID."
  (let ((risk
         (cond ((null value) 'external)
               ((stringp value) (intern (downcase value)))
               ((symbolp value) value)
               (t nil))))
    (unless (memq risk nl-agent-tool-risks)
      (error "MCP server %s has invalid risk %S" id value))
    risk))

(defun nl-agent-mcp-config--entry (spec directory)
  "Build one client entry from JSON SPEC relative to DIRECTORY."
  (nl-agent-mcp-config--keys
   spec
   '(:id :command :directory :environment :risk :timeoutSec
     :protocolVersion :maxFrameBytes :era :legacyProtocolVersion
     :probeTimeoutSec :tools)
   "MCP server")
  (let ((id (plist-get spec :id))
        (command (plist-get spec :command)))
    (unless (and (stringp id) (not (string-empty-p id)))
      (error "MCP server requires a non-empty id"))
    (unless (and (vectorp command) (> (length command) 0)
                 (cl-every #'stringp (append command nil)))
      (error "MCP server %s command must be a non-empty string array" id))
    (let ((tools (plist-get spec :tools)))
      (when (plist-member spec :tools)
        (unless (and (vectorp tools) (> (length tools) 0)
                     (cl-every #'stringp (append tools nil)))
          (error "MCP server %s tools must be a non-empty string array" id))))
    (let* ((risk
            (nl-agent-mcp-config--risk (plist-get spec :risk) id))
           (server-directory
            (expand-file-name
             (or (plist-get spec :directory) ".") directory))
           (environment
            (nl-agent-mcp-config--environment
             (plist-get spec :environment) id))
           (args
            (list :directory server-directory
                  :environment environment)))
      (dolist (mapping
               '((:timeoutSec . :timeout-sec)
                 (:protocolVersion . :protocol-version)
                 (:maxFrameBytes . :max-frame-bytes)
                 (:legacyProtocolVersion . :legacy-protocol-version)
                 (:probeTimeoutSec . :probe-timeout-sec)))
        (when (plist-member spec (car mapping))
          (setq args
                (append args
                        (list (cdr mapping)
                              (plist-get spec (car mapping)))))))
      (when (plist-member spec :tools)
        (setq args
              (append args
                      (list :include-tools
                            (append (plist-get spec :tools) nil)))))
      (when (plist-member spec :era)
        (let ((era (plist-get spec :era)))
          (setq args
                (append args
                        (list :era (if (stringp era) (intern era) era))))))
      (let ((client
             (apply #'nl-agent-mcp-stdio-client-new
                    id (append command nil) args)))
        (list :id id :client client :risk risk)))))

;;;###autoload
(defun nl-agent-mcp-config-load (file)
  "Load data-only MCP configuration FILE and return client entry plists."
  (unless (and (stringp file) (file-regular-p file))
    (error "MCP configuration file does not exist: %S" file))
  (let ((size (file-attribute-size (file-attributes file))))
    (when (> size nl-agent-mcp-config-max-bytes)
      (error "MCP configuration exceeds %d bytes"
             nl-agent-mcp-config-max-bytes)))
  (let* ((path (expand-file-name file))
         (directory (file-name-directory path))
         (data
          (with-temp-buffer
            (insert-file-contents path)
            (json-parse-buffer
             :object-type 'plist :array-type 'array
             :null-object :json-null :false-object :json-false)))
         (entries nil)
         (seen nil))
    (nl-agent-mcp-config--keys data '(:servers) "MCP configuration")
    (unless (plist-member data :servers)
      (error "MCP configuration requires a servers array"))
    (let ((servers (plist-get data :servers)))
      (unless (vectorp servers)
        (error "MCP configuration requires a servers array"))
      (condition-case err
          (progn
            (dolist (spec (append servers nil))
              (let ((entry
                     (nl-agent-mcp-config--entry spec directory)))
                ;; Own the client before any later entry-level validation can
                ;; fail, so the assembly cleanup covers this entry as well.
                (setq entries (append entries (list entry)))
                (when (member (plist-get entry :id) seen)
                  (error "duplicate MCP server id: %s"
                         (plist-get entry :id)))
                (setq seen (cons (plist-get entry :id) seen))))
            entries)
        (error
         (condition-case nil
             (nl-agent-mcp-config-close entries)
           (error nil))
         (signal (car err) (cdr err)))))))

;;;###autoload
(defun nl-agent-mcp-config-close (entries)
  "Attempt to close every MCP client in ENTRIES.
After all clients have received a close attempt, signal the first close error."
  (let ((first-error nil))
    (dolist (entry entries)
      (let ((client (plist-get entry :client)))
        (when (nl-agent-mcp-client-p client)
          (condition-case err
              (nl-agent-mcp-client-close client)
            (error
             (unless first-error
               (setq first-error err)))))))
    (when first-error
      (signal (car first-error) (cdr first-error)))))

(provide 'nl-agent-mcp-config)
;;; nl-agent-mcp-config.el ends here
