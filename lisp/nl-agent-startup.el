;;; nl-agent-startup.el --- provider-neutral startup selection data -*- lexical-binding: t; -*-

;; Startup selection crosses the host/worker boundary as data only.  This
;; module intentionally has no provider, process, filesystem, or service
;; dependency so the same validator runs under Emacs and standalone NeLisp.

;;; Code:

(defun nl-agent-startup--proper-list-p (value)
  "Return non-nil when VALUE is a finite proper list."
  (let ((slow value)
        (fast value)
        done result)
    (while (not done)
      (cond
       ((null fast)
        (setq result t done t))
       ((not (consp fast))
        (setq done t))
       (t
        (setq fast (cdr fast))
        (cond
         ((null fast)
          (setq result t done t))
         ((not (consp fast))
          (setq done t))
         (t
          (setq fast (cdr fast)
                slow (cdr slow))
          (when (eq fast slow)
            (setq done t)))))))
    result))

(defun nl-agent-startup--qualified-model (value where)
  "Validate and detach qualified model selector VALUE for WHERE."
  (unless (and (stringp value)
               (string-match-p "\\`[^/]+/.+\\'" value))
    (error "%s must be a non-empty provider-qualified model string" where))
  (copy-sequence value))

;;;###autoload
(defun nl-agent-startup-validate-config (value)
  "Validate and detach provider-neutral startup selection VALUE.

VALUE is nil for legacy worker defaults, or an exact plist containing
`:model' and `:fallbacks'.  The model and every fallback must be a non-empty
provider-qualified string.  Unknown, duplicate, missing, dotted, and circular
data are rejected."
  (if (null value)
      nil
    (unless (nl-agent-startup--proper-list-p value)
      (error "startup config must be a finite proper plist or nil"))
    (let ((tail value)
          (seen nil))
      (while tail
        (unless (consp (cdr tail))
          (error "startup config must contain key/value pairs"))
        (let ((key (car tail)))
          (unless (memq key '(:model :fallbacks))
            (error "startup config has unknown key %S" key))
          (when (memq key seen)
            (error "startup config has duplicate key %S" key))
          (setq seen (cons key seen)
                tail (cddr tail))))
      (unless (and (memq :model seen) (memq :fallbacks seen))
        (error "startup config requires :model and :fallbacks")))
    (let ((fallbacks (plist-get value :fallbacks)))
      (unless (nl-agent-startup--proper-list-p fallbacks)
        (error "startup config :fallbacks must be a finite proper list"))
      (list :model
            (nl-agent-startup--qualified-model
             (plist-get value :model) "startup config :model")
            :fallbacks
            (mapcar
             (lambda (selector)
               (nl-agent-startup--qualified-model
                selector "startup config fallback"))
             fallbacks)))))

(provide 'nl-agent-startup)
;;; nl-agent-startup.el ends here
