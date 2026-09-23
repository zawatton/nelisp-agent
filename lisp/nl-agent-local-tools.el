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

(defconst nl-agent-local-read-only-programs
  '("rg" "grep" "cat" "head" "tail" "wc" "ls" "find" "sed" "git"
    "nl" "cut" "tr" "pwd")
  "Programs an unattended read-only shell command may run.")

(defun nl-agent-local--dot-component-p (command index)
  "Return non-nil when the path component at INDEX in COMMAND starts with `.'.
The component starts after the nearest preceding space, tab, `/' or `|'."
  (let ((start index))
    (while (and (> start 0)
                (not (memq (aref command (1- start)) '(?\s ?\t ?/ ?|))))
      (setq start (1- start)))
    (eq (aref command start) ?.)))

(defun nl-agent-local--read-only-segments (command)
  "Return COMMAND as a list of pipeline segments, each an argv list.

Quotes are removed exactly as sh would for the accepted subset, so the
argv checked is the argv executed.  Return nil when COMMAND contains shell
syntax this conservative read-only policy does not recognize, contains a
newline or carriage return, has unbalanced quotes, or has an empty segment."
  (let ((length (length command))
        (index 0)
        (state nil)
        (token nil)
        (token-started nil)
        (argv nil)
        (segments nil))
    (cl-flet ((finish-token ()
                (when token-started
                  (push (apply #'string (nreverse token)) argv))
                (setq token nil token-started nil))
              (finish-segment ()
                (unless argv (throw 'reject nil))
                (push (nreverse argv) segments)
                (setq argv nil)))
      (catch 'reject
        (while (< index length)
          (let ((character (aref command index)))
            (cond
             ((memq character '(?\n ?\r)) (throw 'reject nil))
             ((eq state ?')
              (if (eq character ?')
                  (setq state nil)
                (push character token)))
             ((eq state ?\")
              (cond
               ((memq character '(?$ ?` ?\\)) (throw 'reject nil))
               ((eq character ?\") (setq state nil))
               (t (push character token))))
             ((memq character '(?\; ?& ?< ?> ?\( ?\) ?\{ ?\} ?$ ?` ?\\ ?? ?\[))
              ;; `?' and `[' are rejected unquoted because a glob such as
              ;; `?./x' or `[.][.]/x' expands to a parent-directory path
              ;; after this check has run.
              (throw 'reject nil))
             ((and (eq character ?*)
                   (nl-agent-local--dot-component-p command index))
              ;; `.*' can expand to `..'; a `*' elsewhere never matches a
              ;; leading dot in POSIX sh.
              (throw 'reject nil))
             ((memq character '(?\s ?\t)) (finish-token))
             ((eq character ?|) (finish-token) (finish-segment))
             ((eq character ?') (setq state ?' token-started t))
             ((eq character ?\") (setq state ?\" token-started t))
             (t (push character token) (setq token-started t))))
          (setq index (1+ index)))
        (when state (throw 'reject nil))
        (finish-token)
        (finish-segment)
        (nreverse segments)))))

(defun nl-agent-local--read-only-argv-p (argv)
  "Return non-nil when shell ARGV names a conservative read-only command."
  (let ((program (car argv))
        (arguments (cdr argv)))
    (and (member program nl-agent-local-read-only-programs)
         (not (cl-find-if
               (lambda (argument)
                 (or (string-prefix-p "/" argument)
                     (string-prefix-p "~" argument)
                     (equal argument "..")
                     (string-prefix-p "../" argument)
                     (string-match-p "/\\.\\./" argument)
                     (string-suffix-p "/.." argument)))
               arguments))
         (pcase program
           ("rg"
            (not (cl-find-if
                  (lambda (argument)
                    (or (string-prefix-p "--pre" argument)
                        (member argument '("-z" "--search-zip"))
                        (string-prefix-p "--hostname-bin" argument)))
                  arguments)))
           ("find"
            (not (cl-intersection
                  '("-exec" "-execdir" "-ok" "-okdir" "-delete"
                    "-fprint" "-fprint0" "-fprintf" "-fls")
                  arguments :test #'equal)))
           ("sed"
            ;; Only `-n' and a line-range print script, then file operands:
            ;; this excludes -i, w/W (write) and e (execute) scripts.
            (let ((options
                   (cl-remove-if-not
                    (lambda (argument) (string-prefix-p "-" argument))
                    arguments))
                  (operands
                   (cl-remove-if
                    (lambda (argument) (string-prefix-p "-" argument))
                    arguments)))
              (and (member "-n" options)
                   (cl-every (lambda (option) (equal option "-n")) options)
                   operands
                   (string-match-p
                    "\\`\\(?:[0-9]+\\|\\$\\)\\(?:,\\(?:[0-9]+\\|\\$\\)\\)?p\\'"
                    (car operands)))))
           ("tail"
            (not (cl-find-if
                  (lambda (argument)
                    (or (member argument '("-f" "-F"))
                        (string-prefix-p "--follow" argument)))
                  arguments)))
           ("git"
            (let ((subcommand (cadr argv)))
              (and (member subcommand
                           '("status" "log" "show" "diff" "grep"
                             "ls-files" "blame" "rev-parse"))
                   (not (cl-find-if
                         (lambda (argument)
                           (or (string-prefix-p "--output" argument)
                               (string-prefix-p "--ext-diff" argument)
                               (string-prefix-p "--textconv" argument)
                               (string-prefix-p "--open-files-in-pager"
                                                argument)
                               (equal argument "-O")))
                         arguments)))))
           (_ t)))))

(defun nl-agent-local-read-only-command-p (command)
  "Return non-nil when shell COMMAND only performs conservative reads.

The command may contain pipelines, but each segment must name an
allowlisted program and satisfy that program's read-only argument rules.
Anything outside the recognized shell subset is a rejection."
  (and
   (stringp command)
   (let ((segments (nl-agent-local--read-only-segments command)))
     (and segments
          (cl-every #'nl-agent-local--read-only-argv-p segments)))))

(defun nl-agent-local-read-only-shell-approval (request)
  "Allow a `shell' REQUEST once when its command is read-only."
  (if (and (equal (plist-get request :tool) "shell")
           (nl-agent-local-read-only-command-p
            (plist-get (plist-get request :args) :command)))
      'once
    'deny))

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
