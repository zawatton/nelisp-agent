;;; nl-agent-jsonl.el --- bounded JSONL service facade -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'json)

(defvar nl-agent-jsonl-max-line-bytes (* 1024 1024)
  "Maximum UTF-8 input line size accepted by the JSONL decoder.")
(defvar nl-agent-jsonl-max-text-chars 65536
  "Maximum character count for chat, run, and encoded error text.")
(defvar nl-agent-jsonl-max-selector-chars 256
  "Maximum character count for a provider-qualified model selector.")
(defvar nl-agent-jsonl-max-depth 64
  "Maximum recursive depth accepted by the public-data encoder.")
(defvar nl-agent-jsonl-max-nodes 100000
  "Maximum number of public-data values visited by the encoder.")
(defvar nl-agent-jsonl-max-output-bytes (* 1024 1024)
  "Maximum UTF-8 size emitted by the JSONL encoder.")

(defconst nl-agent-jsonl--methods
  '("models" "status" "chat" "run" "switch" "checkpoint" "quit"))

(defun nl-agent-jsonl--object (value allowed required where)
  "Validate JSON alist VALUE and return it for WHERE.
ALLOWED and REQUIRED contain symbol keys.  Duplicate keys are rejected rather
than being silently resolved according to the JSON parser's duplicate policy."
  (unless (listp value)
    (error "%s must be a JSON object" where))
  (let ((tail value) seen)
    (while tail
      (unless (consp (car tail))
        (error "%s contains an invalid member" where))
      (let ((key (car (car tail))))
        (unless (symbolp key)
          (error "%s contains a non-symbol key" where))
        (when (memq key seen)
          (error "%s contains duplicate key %S" where key))
        (unless (memq key allowed)
          (error "%s contains unknown key %S" where key))
        (push key seen))
      (setq tail (cdr tail)))
    (dolist (key required)
      (unless (memq key seen)
        (error "%s is missing required key %S" where key)))
    value))

(defun nl-agent-jsonl--string (value where maximum &optional empty)
  "Validate and detach string VALUE for WHERE within MAXIMUM characters."
  (unless (and (stringp value)
               (or empty (> (length value) 0))
               (<= (length value) maximum))
    (error "%s must be %s text of at most %d characters"
           where (if empty "" "non-empty") maximum))
  (substring-no-properties value))

(defun nl-agent-jsonl--params (params method)
  "Validate PARAMS for METHOD and return its detached command argument."
  (unless (listp params)
    (error "%s params must be a JSON object" method))
  (pcase method
    ((or "models" "status" "checkpoint" "quit")
     (nl-agent-jsonl--object params nil nil
                              (format "%s params" method))
     nil)
    ((or "chat" "run")
     (nl-agent-jsonl--object params '(text) '(text)
                              (format "%s params" method))
     (nl-agent-jsonl--string (alist-get 'text params) "text"
                             nl-agent-jsonl-max-text-chars))
    ("switch"
     (nl-agent-jsonl--object params '(selector) '(selector)
                              "switch params")
     (let ((selector
            (nl-agent-jsonl--string
             (alist-get 'selector params) "selector"
             nl-agent-jsonl-max-selector-chars)))
       (unless (string-match-p "\\`[^/]+/.+\\'" selector)
         (error "selector must be a provider-qualified model string"))
       selector))))

;;;###autoload
(defun nl-agent-jsonl-decode (line)
  "Decode one bounded JSONL LINE into a supervisor request.

Return an exact plist `(:id ID :request FORM)'.  FORM uses the existing
supervisor command convention and is data only; this function never evaluates,
restores, reads files, or contacts a service."
  (unless (stringp line)
    (error "JSONL line must be text"))
  (when (> (string-bytes line) nl-agent-jsonl-max-line-bytes)
    (error "JSONL line exceeds the UTF-8 size limit"))
  (when (string-match-p "[\r\n]" line)
    (error "JSONL line must not contain a newline"))
  (condition-case err
      (let* ((object
              (json-parse-string
               line :object-type 'alist :array-type 'array
               :null-object :json-null :false-object :json-false))
             (_checked
              (nl-agent-jsonl--object
               object '(id method params) '(id method) "JSONL request"))
             (id (nl-agent-jsonl--string
                  (alist-get 'id object) "id" 128))
             (method (nl-agent-jsonl--string
                      (alist-get 'method object) "method" 32))
             (params-cell (assq 'params object))
             (params (if params-cell (cdr params-cell) nil)))
        (unless (member method nl-agent-jsonl--methods)
          (error "unknown JSONL method %s" method))
        (let ((argument (nl-agent-jsonl--params params method)))
          (list :id id
                :request
                (pcase method
                  ((or "models" "status" "checkpoint" "quit")
                   (list (intern method)))
                  ("chat" (list 'chat argument))
                  ("run" (list 'run argument))
                  ("switch" (list 'switch argument))))))
    (error
     (signal (car err)
             (list "invalid JSONL request: %s" (error-message-string err))))))

(defun nl-agent-jsonl--finite-number-p (value)
  "Return non-nil when numeric VALUE is JSON-finite."
  (or (integerp value)
      (and (floatp value)
           (= value value)
           (= (- value value) 0.0))))

(defun nl-agent-jsonl--node (state depth)
  "Account for one encoded value in STATE at DEPTH."
  (when (> depth nl-agent-jsonl-max-depth)
    (error "JSONL response exceeds maximum nesting depth"))
  (setcar state (1+ (car state)))
  (when (> (car state) nl-agent-jsonl-max-nodes)
    (error "JSONL response exceeds maximum node count")))

(defun nl-agent-jsonl--keyword-plist-p (value)
  "Return non-nil when non-empty proper VALUE is a keyword plist."
  (and (consp value) (keywordp (car value))))

(defun nl-agent-jsonl--convert-list (value depth state active)
  "Convert list or dotted pair VALUE into JSON-safe data."
  (when (gethash value active)
    (error "JSONL response contains a cycle"))
  (puthash value t active)
  (unwind-protect
      (let ((tail value)
            (seen (make-hash-table :test 'eq))
            cells)
        ;; Walk cons cells once, without `length' or `listp', so a circular
        ;; list cannot hang before the node budget is consulted.
        (while (consp tail)
          (when (gethash tail seen)
            (error "JSONL response contains a cycle"))
          (puthash tail t seen)
          (nl-agent-jsonl--node state depth)
          (push tail cells)
          (setq tail (cdr tail)))
        (setq cells (nreverse cells))
        (cond
         ;; A dotted pair is represented as a two-element JSON array.  This
         ;; supports public checkpoint/status data such as message alists.
         ((not (null tail))
          (when (nl-agent-jsonl--keyword-plist-p value)
            (error "JSONL response plist is not a proper plist"))
          (vector
           (nl-agent-jsonl--convert (car value) (1+ depth) state active)
           (nl-agent-jsonl--convert (cdr value) (1+ depth) state active)))
         ((nl-agent-jsonl--keyword-plist-p value)
          (let ((remaining cells) keys result)
            (while remaining
              (unless (cdr remaining)
                (error "JSONL response plist is not a proper plist"))
              (let* ((key-cell (car remaining))
                     (value-cell (cadr remaining))
                     (key (car key-cell)))
                (unless (keywordp key)
                  (error "JSONL response plist key is not a keyword"))
                (when (memq key keys)
                  (error "JSONL response plist contains duplicate key %S"
                         key))
                (push key keys)
                (push (cons (intern (substring (symbol-name key) 1))
                            (nl-agent-jsonl--convert
                             (car value-cell) (1+ depth) state active))
                      result))
              (setq remaining (cddr remaining)))
            (nreverse result)))
         (t
          (vconcat
           (mapcar (lambda (cell)
                     (nl-agent-jsonl--convert
                      (car cell) (1+ depth) state active))
                   cells)))))
    (remhash value active)))

(defun nl-agent-jsonl--convert (value depth state active)
  "Convert public Lisp VALUE to JSON-safe data, bounded by STATE."
  (nl-agent-jsonl--node state depth)
  (cond
   ((null value) :json-null)
   ((eq value :json-null) :json-null)
   ((eq value :json-false) :json-false)
   ((eq value t) t)
   ((stringp value)
    (when (> (string-bytes value) nl-agent-jsonl-max-output-bytes)
      (error "JSONL response string exceeds the UTF-8 size limit"))
    (substring-no-properties value))
   ((nl-agent-jsonl--finite-number-p value) value)
   ((vectorp value)
    (when (gethash value active)
      (error "JSONL response contains a cycle"))
    (when (> (+ (car state) (length value)) nl-agent-jsonl-max-nodes)
      (error "JSONL response exceeds maximum node count"))
    (puthash value t active)
    (unwind-protect
        (let ((result (make-vector (length value) nil)))
          (let ((index 0))
            (while (< index (length value))
            (aset result index
                  (nl-agent-jsonl--convert
                   (aref value index) (1+ depth) state active))
              (setq index (1+ index)))
            result))
      (remhash value active)))
   ((and (consp value) (functionp value))
    (error "JSONL response contains an executable value"))
   ((consp value) (nl-agent-jsonl--convert-list value depth state active))
   ((symbolp value) (substring-no-properties (symbol-name value)))
   (t (error "JSONL response contains an unsupported value"))))

(defun nl-agent-jsonl--serialize (value)
  "Serialize bounded JSON-safe VALUE as one line."
  (let* ((state (list 0))
         (active (make-hash-table :test 'eq))
         (converted (nl-agent-jsonl--convert value 0 state active))
         (text (json-serialize converted
                               :null-object :json-null
                               :false-object :json-false)))
    (when (> (string-bytes text) nl-agent-jsonl-max-output-bytes)
      (error "JSONL response exceeds the UTF-8 size limit"))
    (when (string-match-p "[\r\n]" text)
      (error "JSONL response contains a raw newline"))
    text))

;;;###autoload
(defun nl-agent-jsonl-encode (id response)
  "Encode ID and public RESPONSE as one JSONL success envelope."
  (setq id (nl-agent-jsonl--string id "id" 128))
  (nl-agent-jsonl--serialize
   (list :id id :ok t :result response)))

;;;###autoload
(defun nl-agent-jsonl-error (id code message)
  "Encode an error envelope for ID with bounded CODE and MESSAGE text."
  (unless (or (null id) (stringp id))
    (error "id must be nil or text"))
  (setq id (and id (nl-agent-jsonl--string id "id" 128))
        code (nl-agent-jsonl--string code "error code" 128)
        message (nl-agent-jsonl--string message "error message"
                                        nl-agent-jsonl-max-text-chars))
  (nl-agent-jsonl--serialize
   (list :id id :ok :json-false
         :error (list :code code :message message))))

(provide 'nl-agent-jsonl)
;;; nl-agent-jsonl.el ends here
