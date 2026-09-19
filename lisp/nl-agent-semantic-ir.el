;;; nl-agent-semantic-ir.el --- Bounded semantic IR parser and renderer -*- lexical-binding: t; -*-

;; This first milestone is host Emacs-only.  It is deliberately not a
;; standalone NeLisp compatibility claim.

(require 'cl-lib)

;; Declare the reader evaluation switch special so the protective binding is
;; retained by byte compilation; the preflight scan is the primary boundary.
(defvar read-eval)

(define-error 'nl-agent-ir-error "Invalid semantic IR")

(defconst nl-agent-ir--max-input-bytes 65536)
(defconst nl-agent-ir--max-depth 16)
(defconst nl-agent-ir--max-claims 64)
(defconst nl-agent-ir--max-id-chars 128)
(defconst nl-agent-ir--max-claim-text-chars 8192)
(defconst nl-agent-ir--max-chars 65536)

(defun nl-agent-ir--fail (format-string &rest args)
  (signal 'nl-agent-ir-error
          (list (apply #'format format-string args))))

(defun nl-agent-ir--utf8-bytes (text)
  "Return the number of UTF-8 encoded bytes in TEXT."
  (string-bytes (encode-coding-string text 'utf-8 t)))

(defun nl-agent-ir--whitespace-p (char)
  (memq char '(?\s ?\t ?\n ?\r ?\f ?\v)))

(defun nl-agent-ir--whitespace-string-p (text)
  (let ((index 0)
        (length (length text))
        (ok t))
    (while (and ok (< index length))
      (setq ok (nl-agent-ir--whitespace-p (aref text index)))
      (setq index (1+ index)))
    ok))

(defun nl-agent-ir--preflight (text)
  "Reject reader syntax outside strings before invoking the Lisp reader."
  (unless (stringp text)
    (nl-agent-ir--fail "Input must be a string"))
  (when (> (nl-agent-ir--utf8-bytes text) nl-agent-ir--max-input-bytes)
    (nl-agent-ir--fail "Input exceeds the UTF-8 byte limit"))
  (let ((index 0)
        (length (length text))
        (depth 0)
        (in-string nil)
        (escaped nil))
    (while (< index length)
      (let ((char (aref text index)))
        (if in-string
            (cond
             (escaped (setq escaped nil))
             ((= char ?\\) (setq escaped t))
             ((= char ?\") (setq in-string nil)))
          (cond
           ((= char ?\") (setq in-string t))
           ((= char ?\\)
            (nl-agent-ir--fail "Escaped symbols are not allowed"))
           ;; # dispatch, quote, backquote, comma, comments, vectors, and
           ;; Emacs escaped-symbol bars are outside the data subset.
           ((or (= char ?#) (= char ?') (= char 96) (= char ?,)
                (= char ?\;) (= char ?\[) (= char ?\]) (= char ?|)
                (= char ??)
                (and (< char 32) (not (nl-agent-ir--whitespace-p char))))
            (nl-agent-ir--fail "Unsupported reader syntax"))
           ((= char ?\()
            (setq depth (1+ depth))
            (when (> depth nl-agent-ir--max-depth)
              (nl-agent-ir--fail "List nesting exceeds the depth limit")))
           ((= char ?\))
            (setq depth (1- depth))
            (when (< depth 0)
              (nl-agent-ir--fail "Unbalanced closing parenthesis"))))))
      (setq index (1+ index)))
    (when in-string
      (nl-agent-ir--fail "Unterminated string"))
    (when escaped
      (nl-agent-ir--fail "Unterminated string escape"))
    (unless (= depth 0)
      (nl-agent-ir--fail "Unbalanced parentheses"))))

(defun nl-agent-ir--proper-list-p (value)
  "Return non-nil when VALUE is a finite proper list."
  ;; Floyd's cycle check keeps this predicate safe even if it is reused with
  ;; an object that did not come from the bounded reader.
  (let ((slow value)
        (fast value)
        (ok t))
    (while (and ok (consp fast))
      (setq fast (cdr fast))
      (when (consp fast)
        (setq fast (cdr fast)
              slow (cdr slow))
        (when (eq slow fast)
          (setq ok nil))))
    (and ok (null fast))))

(defun nl-agent-ir--fields (tail allowed required context)
  "Parse an exact keyword plist TAIL into an alist.
ALLOWED and REQUIRED contain keyword symbols."
  (unless (nl-agent-ir--proper-list-p tail)
    (nl-agent-ir--fail "%s fields must be a proper list" context))
  (let ((rest tail)
        (seen nil)
        (fields nil))
    (while rest
      (let ((key (pop rest)))
        (unless (keywordp key)
          (nl-agent-ir--fail "%s field key is not a keyword" context))
        (when (memq key seen)
          (nl-agent-ir--fail "%s has a duplicate field" context))
        (unless (memq key allowed)
          (nl-agent-ir--fail "%s has an unknown field" context))
        (unless rest
          (nl-agent-ir--fail "%s has a missing field value" context))
        (push (cons key (pop rest)) fields)
        (push key seen)))
    (dolist (key required)
      (unless (memq key seen)
        (nl-agent-ir--fail "%s is missing a required field" context)))
    fields))

(defun nl-agent-ir--field (fields key)
  (cdr (assq key fields)))

(defun nl-agent-ir--string (value name maximum)
  (unless (and (stringp value) (> (length value) 0))
    (nl-agent-ir--fail "%s must be a nonempty string" name))
  (when (> (length value) maximum)
    (nl-agent-ir--fail "%s exceeds its character limit" name))
  value)

(defun nl-agent-ir--parse-claim (claim)
  (unless (and (consp claim) (eq (car claim) 'claim))
    (nl-agent-ir--fail "Each claim must start with claim"))
  (let* ((fields (nl-agent-ir--fields
                  (cdr claim) '(:id :text) '(:id :text) "claim"))
         (id (nl-agent-ir--string (nl-agent-ir--field fields :id)
                                  "Claim id" nl-agent-ir--max-id-chars))
         (text (nl-agent-ir--string (nl-agent-ir--field fields :text)
                                    "Claim text" nl-agent-ir--max-claim-text-chars)))
    (list 'claim :id id :text text)))

(defun nl-agent-ir--parse-task (task)
  (unless (and (consp task) (eq (car task) 'task))
    (nl-agent-ir--fail "Top-level form must start with task"))
  (let* ((fields (nl-agent-ir--fields
                  (cdr task) '(:version :id :plan :constraints)
                  '(:version :id :plan :constraints) "task"))
         (version (nl-agent-ir--field fields :version))
         (id (nl-agent-ir--string (nl-agent-ir--field fields :id)
                                  "Task id" nl-agent-ir--max-id-chars))
         (plan (nl-agent-ir--field fields :plan))
         (constraints (nl-agent-ir--field fields :constraints)))
    (unless (and (integerp version) (= version 1))
      (nl-agent-ir--fail "Task version must be 1"))
    (unless (and (consp plan) (eq (car plan) 'render))
      (nl-agent-ir--fail "Task plan must start with render"))
    (let* ((plan-fields (nl-agent-ir--fields
                         (cdr plan) '(:language :claims)
                         '(:language :claims) "render"))
           (language (nl-agent-ir--field plan-fields :language))
           (claims (nl-agent-ir--field plan-fields :claims)))
      (unless (eq language 'ja)
        (nl-agent-ir--fail "Render language must be ja"))
      (unless (nl-agent-ir--proper-list-p claims)
        (nl-agent-ir--fail "Claims must be a proper list"))
      (unless (<= 1 (length claims) nl-agent-ir--max-claims)
        (nl-agent-ir--fail "The claim count exceeds the limit"))
      (let ((parsed-claims nil)
            (ids nil))
        (dolist (claim claims)
          (let ((parsed (nl-agent-ir--parse-claim claim)))
            (let ((parsed-id (plist-get (cdr parsed) :id)))
              (when (member parsed-id ids)
                (nl-agent-ir--fail "Claim ids must be unique"))
              (push parsed-id ids)
              (push parsed parsed-claims))))
        (setq parsed-claims (nreverse parsed-claims))
        (unless (nl-agent-ir--proper-list-p constraints)
          (nl-agent-ir--fail "Constraints must be a proper list"))
        (let* ((constraint-fields
                (nl-agent-ir--fields
                 constraints '(:allow-new-claims :max-chars)
                 '(:allow-new-claims :max-chars) "constraints"))
               (allow-new-claims
                (nl-agent-ir--field constraint-fields :allow-new-claims))
               (max-chars (nl-agent-ir--field constraint-fields :max-chars)))
          (unless (null allow-new-claims)
            (nl-agent-ir--fail ":allow-new-claims must be nil"))
          (unless (and (integerp max-chars)
                       (<= 1 max-chars nl-agent-ir--max-chars))
            (nl-agent-ir--fail ":max-chars is outside its allowed range"))
          ;; Return a normalized, validated task.  The renderer never
          ;; evaluates or otherwise interprets claim text.
          (list 'task :version 1 :id id :plan
                (list 'render :language language :claims parsed-claims)
                :constraints
                (list :allow-new-claims nil :max-chars max-chars)))))))

;;;###autoload
(defun nl-agent-ir-parse (text)
  "Parse and validate one bounded semantic IR task from TEXT."
  (condition-case err
      (progn
        (nl-agent-ir--preflight text)
        (let ((read-eval nil)
              (read-circle nil))
          (pcase-let ((`(,form . ,position) (read-from-string text)))
            (unless (nl-agent-ir--whitespace-string-p (substring text position))
              (nl-agent-ir--fail "Input must contain exactly one form"))
            (nl-agent-ir--parse-task form))))
    (nl-agent-ir-error (signal (car err) (cdr err)))
    (error (nl-agent-ir--fail "Reader or schema error: %s"
                              (error-message-string err)))))

;;;###autoload
(defun nl-agent-ir-run (text)
  "Validate TEXT, render its claims, and return a bounded result plist."
  (let* ((task (nl-agent-ir-parse text))
         (plan (plist-get (cdr task) :plan))
         (claims (plist-get (cdr plan) :claims))
         (constraint-fields
          (nl-agent-ir--fields
           (plist-get (cdr task) :constraints)
           '(:allow-new-claims :max-chars)
           '(:allow-new-claims :max-chars) "constraints"))
         (max-chars (nl-agent-ir--field constraint-fields :max-chars))
         (claim-ids (mapcar (lambda (claim)
                              (plist-get (cdr claim) :id))
                            claims))
         (text-output
          (mapconcat (lambda (claim)
                       (plist-get (cdr claim) :text))
                     claims "\n"))
         (actual (length text-output)))
    (if (> actual max-chars)
        (list :status 'validation-failure
              :repair-request
              (list 'repair-request :version 1
                    :task (plist-get (cdr task) :id)
                    :constraint 'max-chars
                    :expected max-chars
                    :actual actual))
      (list :status 'ok :text text-output :claim-ids claim-ids
            :task (plist-get (cdr task) :id)))))

(provide 'nl-agent-semantic-ir)

;;; nl-agent-semantic-ir.el ends here
