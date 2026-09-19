;;; nl-agent-task-audit.el --- durable task-promotion evidence -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'nl-agent-task-promotion)
(require 'nl-agent-training-protocol)
(defvar read-eval)

(defconst nl-agent-task-audit-format "nl-agent-task-audit-v1")
(defconst nl-agent-task-audit-summary-format
  "nl-agent-task-evaluation-v1")

(defun nl-agent-task-audit--keys (value where)
  "Validate the exact audit envelope keys in VALUE."
  (unless (and (listp value) (zerop (% (length value) 2)))
    (error "%s must be a plist" where))
  (let ((tail value) seen)
    (while tail
      (let ((key (pop tail)))
        (when (memq key seen)
          (error "%s contains duplicate key %S" where key))
        (push key seen)
        (unless (memq key '(:format :request :result :request-sha256))
          (error "%s contains unknown key %S" where key)))
      (pop tail)))
  (dolist (key '(:format :request :result :request-sha256))
    (unless (plist-member value key)
      (error "%s is missing required key %S" where key)))
  value)

(defun nl-agent-task-audit--print (value)
  "Serialize VALUE using the protocol's full-precision UTF-8 contract."
  (let ((print-length nil)
        (print-level nil)
        (print-circle nil)
        (print-escape-nonascii t)
        (float-output-format nil))
    (encode-coding-string (prin1-to-string value) 'utf-8 t)))

(defun nl-agent-task-audit--request-hash (request)
  "Return the raw protocol-write-compatible SHA-256 of REQUEST."
  (secure-hash 'sha256 (nl-agent-task-audit--print request)))

(defun nl-agent-task-audit--id (value where)
  "Validate a protocol identifier VALUE for WHERE."
  (unless (and (stringp value)
               (<= 1 (length value) 128)
               (string-match-p "\\`[A-Za-z0-9_.-]+\\'" value))
    (error "%s has invalid identifier" where))
  value)

(defun nl-agent-task-audit--scope (value)
  "Validate and return a SHA-256 scope VALUE."
  (unless (and (stringp value)
               (string-match-p "\\`[a-f0-9]\\{64\\}\\'" value))
    (error "scope must be SHA-256"))
  value)

(defun nl-agent-task-audit--directory (directory &optional require-existing)
  "Validate DIRECTORY without creating it.
When REQUIRE-EXISTING is non-nil, require an existing non-symlink directory."
  (unless (and (stringp directory) (> (length directory) 0))
    (error "task audit directory must be non-empty text"))
  (when (file-symlink-p directory)
    (error "task audit directory may not be a symlink"))
  (when (and (file-exists-p directory)
             (not (file-directory-p directory)))
    (error "task audit directory is not a directory"))
  (when (and require-existing (not (file-directory-p directory)))
    (error "task audit directory does not exist"))
  directory)

(defun nl-agent-task-audit--path (directory scope job-id attempt)
  "Return the opaque audit path for the expected tuple."
  (let ((name
         (secure-hash
          'sha256
          (nl-agent-task-audit--print
           (list :scope scope :job-id job-id :attempt attempt)))))
    (expand-file-name (concat name ".sexp") directory)))

(defun nl-agent-task-audit--validate-envelope
    (envelope expected-request-sha256 &optional expected-scope expected-job-id
              expected-attempt)
  "Validate ENVELOPE and return its detached canonical copy."
  (nl-agent-task-audit--keys envelope "task audit envelope")
  (unless (equal (plist-get envelope :format) nl-agent-task-audit-format)
    (error "unsupported task audit format"))
  (let* ((request (plist-get envelope :request))
         (result (plist-get envelope :result))
         (request-sha256 (plist-get envelope :request-sha256)))
    (unless (and (stringp request-sha256)
                 (string-match-p "\\`[a-f0-9]\\{64\\}\\'" request-sha256)
                 (equal request-sha256 expected-request-sha256))
      (error "task audit request hash mismatch"))
    (nl-agent-training-protocol-validate-request request)
    (unless (plist-member request :task-promotion)
      (error "task audit requires a task-promotion policy"))
    (unless (equal (nl-agent-task-audit--request-hash request)
                   request-sha256)
      (error "task audit request serialization hash mismatch"))
    (nl-agent-training-protocol-validate-result result request)
    (unless (equal (plist-get result :request-sha256) request-sha256)
      (error "task audit result request hash mismatch"))
    (when expected-scope
      (unless (equal (plist-get request :scope) expected-scope)
        (error "task audit scope mismatch")))
    (when expected-job-id
      (unless (equal (plist-get request :job-id) expected-job-id)
        (error "task audit job-id mismatch")))
    (when expected-attempt
      (unless (equal (plist-get request :attempt) expected-attempt)
        (error "task audit attempt mismatch")))
    (copy-tree envelope t)))

(defun nl-agent-task-audit--read-file (file)
  "Read one bounded data-only envelope from FILE."
  (unless (and (file-regular-p file)
               (<= (file-attribute-size (file-attributes file))
                   nl-agent-training-protocol-max-bytes))
    (error "task audit file missing or too large"))
  (with-temp-buffer
    (let ((read-eval nil) (coding-system-for-read 'utf-8))
      (insert-file-contents file)
      (goto-char (point-min))
      (let* ((value (read (current-buffer)))
             (trailing (buffer-substring-no-properties
                        (point) (point-max))))
        (unless (string-match-p "\\`[[:space:]]*\\'" trailing)
          (error "task audit has trailing forms"))
        value))))

(defun nl-agent-task-audit--envelope-text (envelope)
  "Return bounded UTF-8 text bytes for ENVELOPE."
  (let ((bytes (nl-agent-task-audit--print envelope)))
    (when (> (length bytes) nl-agent-training-protocol-max-bytes)
      (error "task audit envelope exceeds protocol size limit"))
    bytes))

;;;###autoload
(defun nl-agent-task-audit-save
    (directory request result request-sha256)
  "Validate and atomically save one task-promotion audit record.
The record path is opaque and derived from the request tuple.  Existing
identical validated records are idempotent; conflicting records and symlinks
are rejected without replacement."
  (nl-agent-task-audit--directory directory)
  (unless (and (stringp request-sha256)
               (string-match-p "\\`[a-f0-9]\\{64\\}\\'" request-sha256))
    (error "task audit request hash must be SHA-256"))
  (let* ((envelope
          (nl-agent-task-audit--validate-envelope
           (list :format nl-agent-task-audit-format
                 :request request :result result
                 :request-sha256 request-sha256)
           request-sha256))
         (request-copy (plist-get envelope :request))
         (scope (nl-agent-task-audit--scope
                 (plist-get request-copy :scope)))
         (job-id (nl-agent-task-audit--id
                  (plist-get request-copy :job-id) "job-id"))
         (attempt (nl-agent-task-audit--id
                   (plist-get request-copy :attempt) "attempt"))
         (path (nl-agent-task-audit--path directory scope job-id attempt))
         (text (nl-agent-task-audit--envelope-text envelope))
         (existing (and (file-exists-p path) path)))
    (when (file-symlink-p path)
      (error "task audit record may not be a symlink"))
    (if existing
        (progn
          (unless (file-regular-p existing)
            (error "task audit record path is not a regular file"))
          (unless (equal envelope
                         (nl-agent-task-audit--validate-envelope
                          (nl-agent-task-audit--read-file existing)
                          request-sha256 scope job-id attempt))
            (error "conflicting task audit record"))
          path)
      ;; No directory or file is created before all validation above succeeds.
      (make-directory directory t)
      (let ((tmp (make-temp-file
                  (expand-file-name ".task-audit-" directory))))
        (unwind-protect
            (progn
              (set-file-modes tmp #o600)
              (let ((coding-system-for-write 'binary))
                (write-region text nil tmp nil 'silent))
              (set-file-modes tmp #o600)
              ;; nil means do not replace a concurrent record.
              (rename-file tmp path nil)
              path)
          (when (file-exists-p tmp)
            (delete-file tmp)))))))

;;;###autoload
(defun nl-agent-task-audit-read (directory scope job-id attempt)
  "Read and validate the opaque task audit record for TUPLE."
  (nl-agent-task-audit--directory directory t)
  (setq scope (nl-agent-task-audit--scope scope)
        job-id (nl-agent-task-audit--id job-id "job-id")
        attempt (nl-agent-task-audit--id attempt "attempt"))
  (let ((path (nl-agent-task-audit--path directory scope job-id attempt)))
    (when (file-symlink-p path)
      (error "task audit record may not be a symlink"))
    (let* ((envelope (nl-agent-task-audit--read-file path))
           (request-sha256 (plist-get envelope :request-sha256)))
      (nl-agent-task-audit--validate-envelope
       envelope request-sha256 scope job-id attempt))))

(defun nl-agent-task-audit--regressions (before after)
  "Count cases passing in BEFORE but failing in AFTER.
Both reports have already been canonicalized by task-promotion validation."
  (let ((count 0)
        (before-cases (plist-get before :cases))
        (after-cases (plist-get after :cases)))
    (unless (= (length before-cases) (length after-cases))
      (error "task audit reports have incompatible case counts"))
    (let ((index 0))
      (while (< index (length before-cases))
        (when (and (plist-get (aref before-cases index) :pass)
                   (not (plist-get (aref after-cases index) :pass)))
          (setq count (1+ count)))
        (setq index (1+ index))))
    count))

;;;###autoload
(defun nl-agent-task-audit-summary (directory scope job-id attempt)
  "Return a bounded evaluation summary for audit record TUPLE.

The full audit envelope is read and validated first.  The returned plist is an
allowlisted verdict only: it contains no suite cases, task text, fixture paths,
model checkpoints, payloads, or free-form error data.  It does not publish or
adopt a model."
  (let* ((envelope (nl-agent-task-audit-read directory scope job-id attempt))
         (request (plist-get envelope :request))
         (result (plist-get envelope :result))
         ;; `nl-agent-task-audit-read' has already run the full protocol and
         ;; task-evidence validators.  Keep this projection read-only and do
         ;; not repeat model/hash validation or task evaluation here.
         (evidence (plist-get result :task-promotion))
         (before (plist-get evidence :before))
         (after (plist-get evidence :after)))
    (list
     :format (substring-no-properties nl-agent-task-audit-summary-format)
     :reference
     (list :scope (substring-no-properties (plist-get request :scope))
           :id (substring-no-properties (plist-get request :job-id))
           :attempt (substring-no-properties (plist-get request :attempt)))
     :task-accepted (eq (plist-get evidence :accepted) t)
     :before-passed (plist-get before :passed)
     :after-passed (plist-get after :passed)
     :total (plist-get before :total)
     :regressions (nl-agent-task-audit--regressions before after)
     :parent-score (plist-get request :parent-score)
     :candidate-score (plist-get result :score)
     :parent-generation (plist-get request :parent-generation)
     :request-sha256
     (substring-no-properties (plist-get envelope :request-sha256)))))

(provide 'nl-agent-task-audit)
;;; nl-agent-task-audit.el ends here
