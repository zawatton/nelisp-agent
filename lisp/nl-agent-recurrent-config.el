;;; nl-agent-recurrent-config.el --- data-only recurrent provider config -*- lexical-binding: t; -*-

;;; Commentary:
;; A recurrent provider manifest is deliberately data-only.  It validates and
;; compiles constrained-decoding grammars, but leaves pinned artifact loading
;; to the provider's normal model-open boundary.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-recur-provider)

(defconst nl-agent-recurrent-config-format
  "nl-agent-recurrent-config-v1")
(defconst nl-agent-recurrent-config-max-bytes (* 1024 1024))
(defconst nl-agent-recurrent-config-max-models 128)
(defconst nl-agent-recurrent-config-max-id-length 128)
(defconst nl-agent-recurrent-config-max-name-length 256)
(defconst nl-agent-recurrent-config-max-path-length 4096)

(defconst nl-agent-recurrent-config--top-keys
  '(:format :id :name :models))
(defconst nl-agent-recurrent-config--model-keys
  '(:id :path :sha256 :name :maxseq :grammar))

(defun nl-agent-recurrent-config--proper-list-p (value)
  "Return non-nil when VALUE is a finite proper list."
  (let ((slow value) (fast value) (ok t))
    (while (and ok (consp fast))
      (setq fast (cdr fast))
      (when (consp fast)
        (setq fast (cdr fast)
              slow (cdr slow))
        (when (eq fast slow)
          (setq ok nil))))
    (and ok (null fast))))

(defun nl-agent-recurrent-config--walk-json (value where)
  "Validate JSON-shaped VALUE recursively, including duplicate keys."
  (cond
   ((vectorp value)
    (dotimes (index (length value))
      (nl-agent-recurrent-config--walk-json
       (aref value index) where)))
   ((listp value)
    (unless (nl-agent-recurrent-config--proper-list-p value)
      (error "%s contains a circular or dotted object" where))
    (let ((tail value) (seen nil))
      (while tail
        (let ((key (pop tail)))
          (unless (and (keywordp key) tail)
            (error "%s contains malformed JSON object data" where))
          (when (memq key seen)
            (error "%s contains duplicate key %S" where key))
          (push key seen)
          (nl-agent-recurrent-config--walk-json (pop tail) where)))))
   ((or (stringp value) (numberp value) (keywordp value)
        (eq value :json-null) (eq value :json-false) (null value))
    value)
   (t
    (error "%s contains an unsupported JSON value" where))))

(defun nl-agent-recurrent-config--keys (value allowed required where)
  "Validate object VALUE keys against ALLOWED and REQUIRED for WHERE."
  (unless (nl-agent-recurrent-config--proper-list-p value)
    (error "%s must be a JSON object" where))
  (let ((tail value) (seen nil))
    (while tail
      (let ((key (pop tail)))
        (unless tail
          (error "%s contains an unpaired key" where))
        (unless (and (keywordp key) (memq key allowed))
          (error "%s contains unknown key %S" where key))
        (when (memq key seen)
          (error "%s contains duplicate key %S" where key))
        (push key seen)
        (pop tail))))
  (dolist (key required)
    (unless (plist-member value key)
      (error "%s requires key %S" where key)))
  value)

(defun nl-agent-recurrent-config--text (value where maximum)
  "Return detached bounded text VALUE for WHERE."
  (unless (and (stringp value) (> (length value) 0)
               (<= (length value) maximum))
    (error "%s must be non-empty text of at most %d characters"
           where maximum))
  (substring-no-properties value))

(defun nl-agent-recurrent-config--id (value where)
  "Return a safe detached identifier VALUE for WHERE."
  (let ((id (nl-agent-recurrent-config--text
             value where nl-agent-recurrent-config-max-id-length)))
    (unless (string-match-p "\\`[A-Za-z0-9_.-]+\\'" id)
      (error "%s has an unsafe identifier" where))
    id))

(defun nl-agent-recurrent-config--sha256 (value where)
  "Return a detached lowercase SHA-256 VALUE for WHERE."
  (let ((digest (nl-agent-recurrent-config--text value where 64)))
    (let ((case-fold-search nil))
      (unless (string-match-p
               (rx string-start (= 64 (in "a-f0-9")) string-end)
               digest)
        (error "%s must be lowercase hexadecimal SHA-256" where))
      digest)))

(defun nl-agent-recurrent-config--path (value directory where)
  "Resolve safe relative artifact VALUE beneath DIRECTORY for WHERE."
  (let ((relative (nl-agent-recurrent-config--text
                   value where nl-agent-recurrent-config-max-path-length)))
    (when (or (file-name-absolute-p relative) (file-remote-p relative))
      (error "%s must be a local relative path" where))
    (let* ((root (file-name-as-directory (file-truename directory)))
           (candidate (expand-file-name relative root))
           ;; `file-truename' also resolves an artifact symlink, so an escape
           ;; through a symlink cannot pass the containment check.
           (real (file-truename candidate)))
      (unless (file-in-directory-p real root)
        (error "%s escapes the configuration directory" where))
      real)))

(defun nl-agent-recurrent-config--grammar (value where)
  "Normalize data-only grammar VALUE and compile its trusted closure."
  (unless (listp value)
    (error "%s must be a JSON object" where))
  ;; Walk before the existing normalizer: its public shape is intentionally
  ;; retained, while this manifest additionally rejects every duplicate JSON
  ;; object key, including nested template slot objects.
  (nl-agent-recurrent-config--walk-json value where)
  (let ((normalized
         (nl-llm-agent-artifact-normalize-grammar value where)))
    (nl-llm-agent-artifact--grammar normalized)))

(defun nl-agent-recurrent-config--model (value directory)
  "Validate and build one provider spec from JSON model VALUE."
  (nl-agent-recurrent-config--keys
   value nl-agent-recurrent-config--model-keys
   '(:id :path :sha256 :grammar) "recurrent config model")
  (let* ((id (nl-agent-recurrent-config--id
              (plist-get value :id) "recurrent config model id"))
         (path (nl-agent-recurrent-config--path
                (plist-get value :path) directory
                (format "recurrent config model %s path" id)))
         (digest (nl-agent-recurrent-config--sha256
                  (plist-get value :sha256)
                  (format "recurrent config model %s sha256" id)))
         (name (when (plist-member value :name)
                 (nl-agent-recurrent-config--text
                  (plist-get value :name)
                  (format "recurrent config model %s name" id)
                  nl-agent-recurrent-config-max-name-length)))
         (maxseq (if (plist-member value :maxseq)
                     (plist-get value :maxseq)
                   128))
         (grammar
          (nl-agent-recurrent-config--grammar
           (plist-get value :grammar)
           (format "recurrent config model %s grammar" id))))
    (unless (and (integerp maxseq) (<= 1 maxseq) (<= maxseq 4096))
      (error "recurrent config model %s maxseq must be in 1..4096" id))
    (append (list :id id :path path :sha256 digest :grammar grammar
                  :maxseq maxseq)
            (when name (list :name name)))))

(defun nl-agent-recurrent-config--read (file)
  "Read one bounded JSON value from local FILE."
  (unless (and (stringp file) (not (file-remote-p file)))
    (error "recurrent config file must be local"))
  (let ((path (expand-file-name file)))
    (unless (and (file-regular-p path) (not (file-directory-p path)))
      (error "recurrent config file must be a regular file"))
    (when (> (file-attribute-size (file-attributes path))
             nl-agent-recurrent-config-max-bytes)
      (error "recurrent config exceeds its byte bound"))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally
       path nil 0 (1+ nl-agent-recurrent-config-max-bytes))
      (when (> (buffer-size) nl-agent-recurrent-config-max-bytes)
        (error "recurrent config exceeds its byte bound"))
      (decode-coding-region (point-min) (point-max) 'utf-8)
      (goto-char (point-min))
      ;; Parse one JSON value, then explicitly reject non-whitespace trailing
      ;; input; `json-parse-buffer' itself leaves such input unread.
      (let ((value
             (json-parse-buffer
              :object-type 'plist :array-type 'array
              :null-object :json-null :false-object :json-false)))
        (skip-chars-forward " \t\r\n")
        (unless (= (point) (point-max))
          (error "recurrent config contains trailing data"))
        value))))

;;;###autoload
(defun nl-agent-recurrent-config-load (file)
  "Load data-only recurrent provider manifest FILE.

This validates and compiles grammar data but does not open or load any pinned
artifact.  Artifact SHA verification remains at the provider model-open
boundary."
  (let* ((path (expand-file-name file))
         ;; Read performs the local-file check before this canonicalization;
         ;; a rejected remote/TRAMP name must never reach file-truename.
         (data (nl-agent-recurrent-config--read path))
         (directory (file-name-directory (file-truename path))))
    (nl-agent-recurrent-config--walk-json data "recurrent config")
    (nl-agent-recurrent-config--keys
     data nl-agent-recurrent-config--top-keys '(:format :id :models)
     "recurrent config")
    (unless (equal (plist-get data :format)
                   nl-agent-recurrent-config-format)
      (error "unsupported recurrent config format"))
    (nl-agent-recurrent-config--id
     (plist-get data :id) "recurrent config id")
    (when (plist-member data :name)
      (nl-agent-recurrent-config--text
       (plist-get data :name) "recurrent config name"
       nl-agent-recurrent-config-max-name-length))
    (let ((models (plist-get data :models)))
      (unless (and (vectorp models)
                   (> (length models) 0)
                   (<= (length models) nl-agent-recurrent-config-max-models))
        (error "recurrent config models must be a nonempty array of at most 128"))
      (let ((specs nil) (seen nil))
        (dotimes (index (length models))
          (let* ((spec (nl-agent-recurrent-config--model
                        (aref models index) directory))
                 (id (plist-get spec :id)))
            (when (member id seen)
              (error "recurrent config has duplicate model id %s" id))
            (push id seen)
            (push spec specs)))
        (nl-llm-agent-recur-provider
         (plist-get data :id) (nreverse specs)
         (when (plist-member data :name)
           (substring-no-properties (plist-get data :name))))))))

(provide 'nl-agent-recurrent-config)
;;; nl-agent-recurrent-config.el ends here
