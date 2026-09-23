;;; nl-agent-stack-paths.el --- find this repo's lisp and its sibling substrate  -*- lexical-binding: t; -*-

;; Tests, examples and the CLI each used to compute the same sibling paths,
;; in a dozen spellings: `(expand-file-name "../nelisp-llm/lisp")' against the
;; working directory, `"../../nelisp-photon/lisp"' against a per-file `here'
;; constant, and a couple that already consulted NELISP_LLM_LISP.  This
;; resolves them once, from the location of this file rather than from the
;; working directory, so a file runs from anywhere.
;;
;; Resolution order per dependency, first existing wins:
;;
;;   1. its environment variable (NELISP_LLM_LISP / NELISP_PHOTON_LISP /
;;      NELISP_GPU_LISP), which is how a Makefile or CI pins a checkout;
;;   2. `vendor/<repo>/lisp' inside this repository, where a submodule or a
;;      vendored copy would land;
;;   3. the sibling checkout `../<repo>/lisp', which is the working layout.
;;
;; No `locate-dominating-file' and no `seq': this file is also read by the
;; NeLisp standalone reader, which does not provide the former.

;;; Code:

(defun nl-agent-stack-paths--root-from (dir)
  "Walk up from DIR to the checkout that holds a `lisp' directory."
  (let ((cur (directory-file-name (expand-file-name dir)))
        (found nil)
        (climbing t))
    (while (and climbing (not found))
      (if (file-directory-p (expand-file-name "lisp" cur))
          (setq found cur)
        (let ((up (directory-file-name (file-name-directory cur))))
          (if (equal up cur)
              (setq climbing nil)
            (setq cur up)))))
    (or found (directory-file-name (expand-file-name ".." dir)))))

(defconst nl-agent-stack-paths-root
  (nl-agent-stack-paths--root-from
   (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "Absolute path of the nelisp-agent checkout this file belongs to.")

(defconst nl-agent-stack-paths-dependencies
  '(("nelisp-llm"    . "NELISP_LLM_LISP")
    ("nelisp-photon" . "NELISP_PHOTON_LISP")
    ("nelisp-gpu"    . "NELISP_GPU_LISP"))
  "Sibling repositories whose `lisp' directory this repo loads from.
Each entry is (REPO-NAME . ENVIRONMENT-VARIABLE).")

(defun nl-agent-stack-paths--first-existing (dirs)
  "Return the first directory in DIRS that exists, or nil."
  (let (found)
    (dolist (dir dirs found)
      (when (and (not found) dir (file-directory-p dir))
        (setq found dir)))))

(defun nl-agent-stack-paths-locate (repo &optional env-var)
  "Return REPO's `lisp' directory, or nil when no candidate exists.
ENV-VAR defaults to the one registered in
`nl-agent-stack-paths-dependencies'."
  (let* ((env (or env-var (cdr (assoc repo nl-agent-stack-paths-dependencies))))
         (from-env (and env (getenv env))))
    (nl-agent-stack-paths--first-existing
     (list (and from-env (not (string-empty-p from-env))
                (expand-file-name from-env))
           (expand-file-name (concat "vendor/" repo "/lisp")
                             nl-agent-stack-paths-root)
           (expand-file-name (concat "../" repo "/lisp")
                             nl-agent-stack-paths-root)))))

;;;###autoload
(defun nl-agent-stack-paths-ensure ()
  "Put this repo's `lisp' and every dependency found on `load-path'.
Returns the directories added or already present.  A missing dependency
is skipped silently; the caller's own `require' is what names one that
is genuinely absent."
  (let ((dirs (list (expand-file-name "lisp" nl-agent-stack-paths-root))))
    (dolist (dep nl-agent-stack-paths-dependencies)
      (let ((dir (nl-agent-stack-paths-locate (car dep) (cdr dep))))
        (when dir (push dir dirs))))
    (setq dirs (nreverse dirs))
    (dolist (dir dirs) (add-to-list 'load-path dir))
    dirs))

(nl-agent-stack-paths-ensure)

(provide 'nl-agent-stack-paths)
;;; nl-agent-stack-paths.el ends here
