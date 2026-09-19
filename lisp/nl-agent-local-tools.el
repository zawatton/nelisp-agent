;;; nl-agent-local-tools.el --- guarded host tools for NeLisp Agent  -*- lexical-binding: t; -*-

;; These implementations run only on the Emacs host.  The standalone worker
;; sees descriptors and sends structured arguments through stdio.  Root
;; confinement is enforced again inside the edit tool, independent of policy.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'nl-llm-agent)
(require 'nl-llm-agent-tokenizer)
(require 'nl-agent-tool)

(defconst nl-agent-local-max-read-bytes (* 64 1024)
  "Maximum UTF-8 file size returned by the local read tool.")

(defconst nl-agent-local-read-schema
  '(:type "object"
    :properties (:path (:type "string" :minLength 1))
    :required ["path"]
    :additionalProperties nil)
  "Exact input schema for the bounded local read tool.")

(defconst nl-agent-local-tool-descriptors
  '((:name "shell" :description "Run one shell command in the workspace"
     :risk execute)
    (:name "edit" :description "Apply an exact SEARCH/REPLACE inside workspace"
     :risk write)
    (:name "elisp" :description "Evaluate Elisp in an isolated batch process"
     :risk execute)
    (:name "read" :description "Read one bounded UTF-8 workspace file"
     :risk read))
  "Public descriptors for the standard host tool set.")

(defconst nl-agent-local-dangerous-shell-patterns
  '("\\_<\\(?:shutdown\\|reboot\\|poweroff\\|halt\\)\\_>"
    "\\_<mkfs\\(?:\\.[[:alnum:]]+\\)?\\_>"
    "\\_<dd\\_>.*\\_<of[ \t]*=[ \t]*/dev/"
    "\\_<rm\\_>.*-[^ \t\n]*r[^ \t\n]*f[^ \t\n]*[ \t]+/\\(?:[ \t]\\|$\\)"
    "\\_<rm\\_>.*-[^ \t\n]*f[^ \t\n]*r[^ \t\n]*[ \t]+/\\(?:[ \t]\\|$\\)")
  "Shell patterns blocked even when an approval callback grants a request.")

(defun nl-agent-local--root (root where)
  "Return existing directory ROOT as a canonical directory for WHERE."
  (unless (and (stringp root) (file-directory-p root))
    (error "%s: workspace root must be an existing directory" where))
  (file-name-as-directory (file-truename root)))

(defun nl-agent-local--inside-root-p (path root)
  "Return non-nil when PATH resolves inside canonical ROOT."
  (and (stringp path)
       (string-prefix-p
        (nl-agent-local--root root "path confinement")
        (file-truename (expand-file-name path root)))))

(defun nl-agent-local--string-arg (args key tool)
  "Return non-empty string KEY from tool ARGS for TOOL."
  (let ((value (plist-get args key)))
    (unless (and (stringp value) (not (string-empty-p value)))
      (error "%s tool requires non-empty %S text" tool key))
    value))

(defun nl-agent-local--read-args (args)
  "Return the path from exact read ARGS."
  (unless (and (listp args)
               (= (length args) 2)
               (eq (car args) :path)
               (stringp (cadr args))
               (not (string-empty-p (cadr args))))
    (error "read tool requires only non-empty :path text"))
  (cadr args))

(defun nl-agent-local--symlink-component-p (path root)
  "Return non-nil when existing PATH beneath ROOT traverses a symlink."
  (let* ((expanded (expand-file-name path root))
         (relative (file-relative-name expanded root))
         (parts (split-string relative "/" t))
         (cursor root)
         found)
    (dolist (part parts)
      (setq cursor (expand-file-name part cursor))
      (when (file-symlink-p cursor)
        (setq found t)))
    found))

(defun nl-agent-local--read-path (root path)
  "Return validated regular read PATH confined beneath canonical ROOT."
  (let* ((root (nl-agent-local--root root "read path confinement"))
         (expanded (expand-file-name path root)))
    (unless (string-prefix-p root expanded)
      (error "read path escapes the workspace: %s" path))
    (when (nl-agent-local--symlink-component-p expanded root)
      (error "read path traverses a symbolic link: %s" path))
    (unless (and (file-exists-p expanded)
                 (nl-agent-local--inside-root-p expanded root))
      (error "read path escapes the workspace: %s" path))
    (unless (file-regular-p expanded)
      (error "read path is not a regular file: %s" path))
    (when (> (file-attribute-size (file-attributes expanded))
             nl-agent-local-max-read-bytes)
      (error "read file exceeds %d bytes: %s"
             nl-agent-local-max-read-bytes path))
    expanded))

(defun nl-agent-local--read (root args)
  "Read exact ARGS as bounded strict UTF-8 beneath ROOT."
  (let ((path
         (nl-agent-local--read-path
          root (nl-agent-local--read-args args))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      ;; Bound the actual read as well as the metadata preflight: the file may
      ;; grow between `file-attributes' and opening it.
      (insert-file-contents-literally
       path nil 0 (1+ nl-agent-local-max-read-bytes))
      (when (> (buffer-size) nl-agent-local-max-read-bytes)
        (error "read file grew beyond %d bytes"
               nl-agent-local-max-read-bytes))
      (nl-llm-agent-tokenizer-decode
       (append (buffer-string) nil) nl-llm-agent-tokenizer-utf8))))

(defun nl-agent-local--edit (root args)
  "Apply an edit described by ARGS under ROOT."
  (let ((path (nl-agent-local--string-arg args :path "edit"))
        (search (plist-get args :search))
        (replace (plist-get args :replace)))
    (unless (and (stringp search) (stringp replace))
      (error "edit tool requires text :search and :replace"))
    (unless (nl-agent-local--inside-root-p path root)
      (error "edit path escapes the workspace: %s" path))
    (let ((result (nl-llm-agent--apply-edit path search replace root)))
      (if (car result)
          (cdr result)
        (error "%s" (cdr result))))))

(defun nl-agent-local--shell (root args)
  "Run the shell command in ARGS under ROOT."
  (nl-llm-agent--shell
   (nl-agent-local--string-arg args :command "shell") root))

(defun nl-agent-local--elisp (args)
  "Run the Elisp code in ARGS in an isolated Emacs process."
  (nl-llm-agent--eval-elisp-sandbox
   (nl-agent-local--string-arg args :code "elisp") 5))

(defun nl-agent-local--read-tool (root)
  "Return the production bounded read tool confined to ROOT."
  (nl-agent-tool-new
   "read" (lambda (args _context) (nl-agent-local--read root args))
   :description "Read one bounded UTF-8 workspace file" :risk 'read
   :metadata (list :input-schema nl-agent-local-read-schema)))

(defun nl-agent-local--edit-tool (root)
  "Return the production exact edit tool confined to ROOT."
  (nl-agent-tool-new
   "edit" (lambda (args _context) (nl-agent-local--edit root args))
   :description "Apply an exact SEARCH/REPLACE inside workspace" :risk 'write))

;;;###autoload
(defun nl-agent-local-tool-registry (root)
  "Return the standard host tool registry confined to workspace ROOT."
  (let ((root (nl-agent-local--root root "nl-agent-local-tool-registry"))
        (registry (nl-agent-tool-registry-new)))
    (nl-agent-tool-register
     registry
     (nl-agent-tool-new
      "shell" (lambda (args _context) (nl-agent-local--shell root args))
      :description "Run one shell command in the workspace" :risk 'execute))
    (nl-agent-tool-register
     registry
     (nl-agent-local--edit-tool root))
    (nl-agent-tool-register
     registry
     (nl-agent-tool-new
      "elisp" (lambda (args _context) (nl-agent-local--elisp args))
      :description "Evaluate Elisp in an isolated batch process" :risk 'execute))
    (nl-agent-tool-register registry (nl-agent-local--read-tool root))
    registry))

;;;###autoload
(defun nl-agent-local-file-tool-registry (root)
  "Return a workspace-confined registry containing only read and edit."
  (let ((root
         (nl-agent-local--root root "nl-agent-local-file-tool-registry"))
        (registry (nl-agent-tool-registry-new)))
    (nl-agent-tool-register registry (nl-agent-local--read-tool root))
    (nl-agent-tool-register registry (nl-agent-local--edit-tool root))
    registry))

;;;###autoload
(defun nl-agent-local-hard-deny (root)
  "Return an unoverrideable safety-floor callback for workspace ROOT."
  (let ((root (nl-agent-local--root root "nl-agent-local-hard-deny")))
    (lambda (request)
      (let ((tool (plist-get request :tool))
            (args (plist-get request :args)))
        (cond
         ((equal tool "read")
          (condition-case err
              (progn
                (nl-agent-local--read-path
                 root (nl-agent-local--read-args args))
                nil)
            (error (error-message-string err))))
         ((equal tool "edit")
          (let ((path (plist-get args :path)))
            (when (or (not (stringp path))
                      (not (nl-agent-local--inside-root-p path root)))
              "edit path escapes the workspace")))
         ((equal tool "elisp")
          (let* ((code (plist-get args :code))
                 (operation
                  (and (stringp code)
                       (nl-llm-agent--denylisted
                        code nl-llm-agent-default-denylist))))
            (when operation
              (format "forbidden Elisp operation `%s'" operation))))
         ((equal tool "shell")
          (let ((command (plist-get args :command)))
            (when (and (stringp command)
                       (cl-find-if
                        (lambda (pattern)
                          (string-match-p pattern command))
                        nl-agent-local-dangerous-shell-patterns))
              "command matches the destructive-operation blocklist")))
         (t nil))))))

(provide 'nl-agent-local-tools)
;;; nl-agent-local-tools.el ends here
