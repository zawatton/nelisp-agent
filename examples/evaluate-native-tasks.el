;;; evaluate-native-tasks.el --- evaluate a local native artifact -*- lexical-binding: t; -*-

;; This runner trusts the configured local artifact catalog as executable model
;; data.  It creates only evaluator-owned temporary fixture workspaces and does
;; not train, publish, or contact an external provider.

;;; Code:

(defconst nl-agent-example-task-eval-root
  (let ((source (or load-file-name buffer-file-name)))
    (if source
        (file-name-directory
         (directory-file-name (file-name-directory source)))
      (file-name-as-directory (expand-file-name "."))))
  "Project root resolved relative to this example source.")

(add-to-list 'load-path
             (expand-file-name "lisp" nl-agent-example-task-eval-root))
(add-to-list 'load-path
             (expand-file-name "../nelisp-llm/lisp"
                               nl-agent-example-task-eval-root))
(add-to-list 'load-path
             (expand-file-name "../nelisp-photon/lisp"
                               nl-agent-example-task-eval-root))

(require 'json)
(require 'subr-x)
(require 'nl-agent-task-suite)
(require 'nl-agent-task-eval-service)
(require 'nl-llm-agent-provider)
(require 'nl-llm-agent-artifact)

(defun nl-agent-example-task-eval--options (arguments)
  "Parse evaluator command-line ARGUMENTS into a strict option plist."
  (when (equal (car arguments) "--")
    (setq arguments (cdr arguments)))
  (let (result seen)
    (while arguments
      (let* ((flag (pop arguments))
             (key (pcase flag
                    ("--native-catalog" :native-catalog)
                    ("--model" :model)
                    ("--max-steps" :max-steps)
                    (_ (error "unknown evaluator option: %s" flag)))))
        (when (memq key seen)
          (error "duplicate evaluator option: %s" flag))
        (unless arguments
          (error "missing value for evaluator option: %s" flag))
        (push key seen)
        (setq result (append result (list key (pop arguments))))))
    (dolist (required '(:native-catalog :model))
      (unless (plist-member result required)
        (error "missing required evaluator option: %s" required)))
    (let ((catalog (plist-get result :native-catalog))
          (model (plist-get result :model))
          (steps (if (plist-member result :max-steps)
                     (string-to-number (plist-get result :max-steps))
                   12)))
      (unless (and (stringp catalog) (not (string-empty-p catalog)))
        (error "--native-catalog requires a non-empty path"))
      (unless (and (stringp model)
                   (string-match-p "\\`native/.+\\'" model))
        (error "--model must be an exact native/ID selector"))
      (unless (and (integerp steps) (<= 1 steps) (<= steps 64)
                   (equal (number-to-string steps)
                          (or (plist-get result :max-steps)
                              (number-to-string steps))))
        (error "--max-steps must be an integer in 1..64"))
      (list :native-catalog (expand-file-name catalog)
            :model model :max-steps steps))))

(defun nl-agent-example-evaluate-native-tasks (catalog model max-steps)
  "Evaluate trusted local CATALOG MODEL against the fixed microtask suite."
  (let ((registry (nl-llm-agent-provider-registry-new)))
    (nl-llm-agent-provider-register
     registry (nl-llm-agent-artifact-provider "native" catalog))
    (nl-agent-task-eval-service-run
     (nl-agent-task-suite-representative) registry model
     :max-steps max-steps)))

;;;###autoload
(defun nl-agent-example-evaluate-native-tasks-main ()
  "CLI entry point which prints one JSON evaluation report to stdout."
  (condition-case err
      (let* ((options
              (nl-agent-example-task-eval--options command-line-args-left))
             (report
              (nl-agent-example-evaluate-native-tasks
               (plist-get options :native-catalog)
               (plist-get options :model)
               (plist-get options :max-steps))))
        ;; Score zero is a legitimate measurement, not a process failure.
        (princ (json-encode report))
        (terpri)
        (kill-emacs 0))
    (error
     (princ (format "nelisp-agent-eval: %s\n" (error-message-string err))
            'external-debugging-output)
     (kill-emacs 2))))

(provide 'nl-agent-example-evaluate-native-tasks)
;;; evaluate-native-tasks.el ends here
