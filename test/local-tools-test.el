;;; local-tools-test.el --- guarded host tool tests  -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path
             (or (getenv "NELISP_LLM_LISP")
                 (expand-file-name "../nelisp-llm/lisp")))
(require 'nl-agent-permission)
(require 'nl-agent-local-tools)

(defvar nl-agent-local-test--fail 0)

(defun nl-agent-local-test--ck (name ok)
  (princ (format "%-65s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-local-test--fail
                         (1+ nl-agent-local-test--fail))
                   "FAIL"))))

(let* ((root (make-temp-file "nl-agent-local-" t))
       (outside-directory (make-temp-file "nl-agent-outside-" t))
       (file (expand-file-name "sample.el" root))
       (unicode-file (expand-file-name "unicode.txt" root))
       (oversized-file (expand-file-name "oversized.txt" root))
       (invalid-file (expand-file-name "invalid.txt" root))
       (link-file (expand-file-name "linked.txt" root))
       (outside (expand-file-name "outside.el" outside-directory))
       (registry (nl-agent-local-tool-registry root))
       (policy
        (nl-agent-permission-policy-new
         :mode 'off :hard-deny (nl-agent-local-hard-deny root))))
  (unwind-protect
      (progn
        (write-region "(defun sample () \"old\")\n" nil file nil 'silent)
        (write-region "日本語のfixture\n" nil unicode-file nil 'silent)
        (write-region
         (make-string (1+ nl-agent-local-max-read-bytes) ?x)
         nil oversized-file nil 'silent)
        (let ((coding-system-for-write 'no-conversion))
          (write-region (unibyte-string #xff) nil invalid-file nil 'silent))
        (make-symbolic-link unicode-file link-file)
        (write-region "outside\n" nil outside nil 'silent)
        (nl-agent-local-test--ck
         "standard registry preserves old tools and appends bounded read"
         (equal
          (mapcar (lambda (item) (plist-get item :name))
                  (nl-agent-tool-catalog registry))
          '("shell" "edit" "elisp" "read")))
        (let ((result
               (nl-agent-permission-call
                policy registry "read" '(:path "unicode.txt"))))
          (nl-agent-local-test--ck
           "bounded read returns an immutable UTF-8 text snapshot"
           (and (eq (plist-get result :status) 'ok)
                (equal (plist-get result :value) "日本語のfixture\n")
                (progn
                  (aset (plist-get result :value)
                        (1- (length (plist-get result :value))) ?x)
                  (with-temp-buffer
                    (insert-file-contents unicode-file)
                    (equal (buffer-string) "日本語のfixture\n"))))))
        (dolist (case
                 '(("outside read" (:path "../outside.el") denied)
                   ("symlink read" (:path "linked.txt") denied)
                   ("directory read" (:path ".") denied)
                   ("oversized read" (:path "oversized.txt") denied)
                   ("invalid UTF-8 read" (:path "invalid.txt") error)
                   ("injected read field"
                    (:path "unicode.txt" :command "escape") denied)))
          (let ((result
                 (nl-agent-permission-call
                  policy registry "read" (nth 1 case))))
            (nl-agent-local-test--ck
             (car case) (eq (plist-get result :status) (nth 2 case)))))
        (cl-letf (((symbol-function 'file-attribute-size)
                   (lambda (_attributes) 0)))
          (let ((result
                 (nl-agent-permission-call
                  (nl-agent-permission-policy-new :mode 'smart)
                  registry "read" '(:path "oversized.txt"))))
            (nl-agent-local-test--ck
             "bounded read rejects growth after a stale size preflight"
             (eq (plist-get result :status) 'error))))
        (let* ((files (nl-agent-local-file-tool-registry root))
               (names
                (mapcar
                 (lambda (item) (plist-get item :name))
                 (nl-agent-tool-catalog files))))
          (nl-agent-local-test--ck
           "file-only registry exposes read/edit without shell or Elisp"
           (and (equal names '("read" "edit"))
                (eq
                 (plist-get
                  (nl-agent-permission-call
                   policy files "shell" '(:command "printf unsafe"))
                  :status)
                 'error))))
        (let ((result
               (nl-agent-permission-call
                policy registry "edit"
                '(:path "sample.el"
                  :search "(defun sample () \"old\")"
                  :replace "(defun sample () \"new\")"))))
          (nl-agent-local-test--ck
           "approved edit changes an existing file inside workspace"
           (and (eq (plist-get result :status) 'ok)
                (with-temp-buffer
                  (insert-file-contents file)
                  (string-match-p "new" (buffer-string))))))
        (let ((result
               (nl-agent-permission-call
                policy registry "edit"
                (list :path outside :search "outside" :replace "changed"))))
          (nl-agent-local-test--ck
           "hard-deny rejects an absolute edit outside workspace"
           (and (eq (plist-get result :status) 'denied)
                (with-temp-buffer
                  (insert-file-contents outside)
                  (equal (buffer-string) "outside\n")))))
        (let ((result
               (nl-agent-permission-call
                policy registry "shell" '(:command "printf safe"))))
          (nl-agent-local-test--ck
           "host shell runs an allowed command in workspace"
           (and (eq (plist-get result :status) 'ok)
                (string-match-p "safe" (plist-get result :text)))))
        (let ((result
               (nl-agent-permission-call
                policy registry "shell" '(:command "rm -rf /"))))
          (nl-agent-local-test--ck
           "hard-deny blocks destructive shell even in mode off"
           (and (eq (plist-get result :status) 'denied)
                (eq (plist-get
                     (plist-get result :authorization) :source)
                    'hard-deny))))
        (let ((result
               (nl-agent-permission-call
                policy registry "elisp"
                '(:code "(delete-file \"sample.el\")"))))
          (nl-agent-local-test--ck
           "hard-deny blocks filesystem Elisp before sandbox launch"
           (eq (plist-get result :status) 'denied)))
        (let ((result
               (nl-agent-permission-call
                policy registry "edit"
                '(:path "sample.el" :search "missing" :replace "x"))))
          (nl-agent-local-test--ck
           "tool implementation failures return structured errors"
           (eq (plist-get result :status) 'error))))
    (delete-directory root t)
    (delete-directory outside-directory t)))

(princ (format "NL-AGENT-LOCAL-TOOLS %s (%d failures)\n"
               (if (= nl-agent-local-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-local-test--fail))
(kill-emacs (if (= nl-agent-local-test--fail 0) 0 1))

;;; local-tools-test.el ends here
