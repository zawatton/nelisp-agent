;;; nl-agent-training-recovery.el --- stopped training attempt receipts -*- lexical-binding: t; -*-

;; This is a host-owned durable store for a single stopped attempt per
;; (scope, job-id).  It neither observes process state nor claims authorization
;; to resume work: callers must first observe that the child is terminal and
;; separately decide whether execution is allowed.  The store never writes a
;; child file or queue state and never scans DIRECTORY.

;;; Code:

(require 'nl-agent-training-protocol)

(defconst nl-agent-training-recovery-format
  "nl-agent-training-recovery-v1"
  "Format tag for a host-owned stopped-attempt receipt.")

(defconst nl-agent-training-recovery-active-format
  "nl-agent-training-active-v1"
  "Format tag for a host-owned active-attempt reservation.")

(defconst nl-agent-training-recovery--keys
  '(:format :request :request-sha256 :checkpoint)
  "Exact keys in a recovery receipt.")

(defconst nl-agent-training-recovery--active-keys
  '(:format :scope :job-id :origin-attempt :active-attempt)
  "Exact keys in an active-attempt reservation.")

(defun nl-agent-training-recovery--scope (scope)
  "Validate and return protocol SCOPE."
  (unless (and (stringp scope)
               (string-match-p "\\`[a-f0-9]\\{64\\}\\'" scope))
    (error "training recovery scope must be SHA-256"))
  scope)

(defun nl-agent-training-recovery--job-id (job-id)
  "Validate and return recovery JOB-ID."
  (nl-agent-training-protocol--id job-id "training recovery job"))

(defun nl-agent-training-recovery--digest (scope job-id)
  "Return an unambiguous deterministic digest for SCOPE and JOB-ID."
  (let ((print-length nil) (print-level nil) (print-circle nil)
        (print-escape-nonascii t) (float-output-format nil))
    (secure-hash 'sha256 (prin1-to-string (list scope job-id)))))

;;;###autoload
(defun nl-agent-training-recovery-path (directory scope job-id)
  "Return the deterministic receipt path for DIRECTORY, SCOPE, and JOB-ID.
DIRECTORY is trusted host configuration.  Neither SCOPE nor JOB-ID becomes a
literal path component."
  (unless (and (stringp directory) (> (length directory) 0))
    (error "training recovery directory must be a non-empty string"))
  (setq scope (nl-agent-training-recovery--scope scope)
        job-id (nl-agent-training-recovery--job-id job-id))
  (expand-file-name
   (format "recovery-%s.sexp"
           (nl-agent-training-recovery--digest scope job-id))
   directory))

;;;###autoload
(defun nl-agent-training-recovery-marker-path (directory scope job-id)
  "Return the deterministic active-marker path for DIRECTORY, SCOPE, and JOB-ID."
  (unless (and (stringp directory) (> (length directory) 0))
    (error "training recovery directory must be a non-empty string"))
  (setq scope (nl-agent-training-recovery--scope scope)
        job-id (nl-agent-training-recovery--job-id job-id))
  (expand-file-name
   (format "active-%s.sexp"
           (nl-agent-training-recovery--digest scope job-id))
   directory))

(defun nl-agent-training-recovery--reject-symlink (path)
  "Signal when receipt PATH is a symbolic link."
  (when (file-symlink-p path)
    (error "training recovery receipt must not be a symlink")))

(defun nl-agent-training-recovery--marker-present-p (path)
  "Return non-nil for any marker occupancy at PATH, including a dangling link."
  (or (file-exists-p path) (file-symlink-p path)))

(defun nl-agent-training-recovery--validate-marker
    (marker scope job-id)
  "Validate exact MARKER data for SCOPE and JOB-ID."
  (nl-agent-training-protocol--keys
   marker nl-agent-training-recovery--active-keys
   "training recovery active marker" nl-agent-training-recovery--active-keys)
  (unless (equal (plist-get marker :format)
                 nl-agent-training-recovery-active-format)
    (error "unsupported training recovery active marker format"))
  (nl-agent-training-recovery--scope (plist-get marker :scope))
  (nl-agent-training-recovery--job-id (plist-get marker :job-id))
  (nl-agent-training-protocol--id
   (plist-get marker :origin-attempt) "training recovery origin attempt")
  (nl-agent-training-protocol--id
   (plist-get marker :active-attempt) "training recovery active attempt")
  (unless (and (equal (plist-get marker :scope) scope)
               (equal (plist-get marker :job-id) job-id))
    (error "training recovery active marker identity mismatch"))
  marker)

(defun nl-agent-training-recovery--read-marker (directory scope job-id)
  "Read and validate the marker for DIRECTORY, SCOPE, and JOB-ID."
  (let ((path (nl-agent-training-recovery-marker-path directory scope job-id)))
    (nl-agent-training-recovery--reject-symlink path)
    (unless (file-regular-p path)
      (error "training recovery active marker is not regular"))
    (nl-agent-training-recovery--validate-marker
     (nl-agent-training-protocol-read path) scope job-id)))

(defun nl-agent-training-recovery--validate
    (receipt &optional expected-scope expected-job-id)
  "Validate RECEIPT and optional expected identity, then return RECEIPT."
  (nl-agent-training-protocol--keys
   receipt nl-agent-training-recovery--keys
   "training recovery receipt" nl-agent-training-recovery--keys)
  (unless (equal (plist-get receipt :format)
                 nl-agent-training-recovery-format)
    (error "unsupported training recovery receipt format"))
  (let ((request (plist-get receipt :request))
        (request-sha256 (plist-get receipt :request-sha256))
        (checkpoint (plist-get receipt :checkpoint)))
    (nl-agent-training-protocol-validate-request request)
    (nl-agent-training-protocol-validate-checkpoint
     checkpoint request request-sha256)
    (when expected-scope
      (unless (equal (plist-get request :scope) expected-scope)
        (error "training recovery receipt scope mismatch")))
    (when expected-job-id
      (unless (equal (plist-get request :job-id) expected-job-id)
        (error "training recovery receipt job mismatch"))))
  receipt)

(defun nl-agent-training-recovery--load-receipt (directory scope job-id)
  "Load the exact receipt while deliberately ignoring active-marker occupancy."
  (let ((path (nl-agent-training-recovery-path directory scope job-id)))
    (nl-agent-training-recovery--reject-symlink path)
    (unless (file-regular-p path)
      (error "training recovery receipt does not exist"))
    (nl-agent-training-recovery--validate
     (nl-agent-training-protocol-read path) scope job-id)))

;;;###autoload
(defun nl-agent-training-recovery-load (directory scope job-id)
  "Load and validate the exact receipt for DIRECTORY, SCOPE, and JOB-ID.
No directory scan or automatic execution is performed."
  (setq scope (nl-agent-training-recovery--scope scope)
        job-id (nl-agent-training-recovery--job-id job-id))
  (let ((marker
         (nl-agent-training-recovery-marker-path directory scope job-id)))
    (when (nl-agent-training-recovery--marker-present-p marker)
      (error "training recovery attempt is actively reserved"))
    (nl-agent-training-recovery--load-receipt directory scope job-id)))

;;;###autoload
(defun nl-agent-training-recovery-reserve
    (directory scope job-id origin-attempt active-attempt)
  "Reserve a stopped receipt for ACTIVE-ATTEMPT and return the marker path.
ORIGIN-ATTEMPT must match the stopped receipt.  The caller must hold its
exclusive owner lock and call this after creating the new claim/request but
before spawn.  Existing marker occupancy always fails closed; it is never
automatically reclaimed."
  (setq scope (nl-agent-training-recovery--scope scope)
        job-id (nl-agent-training-recovery--job-id job-id))
  (nl-agent-training-protocol--id origin-attempt
                                  "training recovery origin attempt")
  (nl-agent-training-protocol--id active-attempt
                                  "training recovery active attempt")
  (let* ((path
          (nl-agent-training-recovery-marker-path directory scope job-id))
         (receipt
          (nl-agent-training-recovery--load-receipt directory scope job-id)))
    (when (nl-agent-training-recovery--marker-present-p path)
      (error "training recovery attempt is already reserved"))
    (unless (equal origin-attempt
                   (plist-get (plist-get receipt :request) :attempt))
      (error "training recovery reservation origin mismatch"))
    (nl-agent-training-protocol-write
     path (list :format nl-agent-training-recovery-active-format
                :scope scope :job-id job-id
                :origin-attempt origin-attempt
                :active-attempt active-attempt))
    path))

;;;###autoload
(defun nl-agent-training-recovery-release
    (directory scope job-id active-attempt)
  "Release the exact marker only when it belongs to ACTIVE-ATTEMPT.
Return nil when absent and t when deleted; signal on mismatch or malformed
occupancy.  The caller must hold its owner lock and prove either that no child
was spawned or that the spawned child has reached a terminal state."
  (setq scope (nl-agent-training-recovery--scope scope)
        job-id (nl-agent-training-recovery--job-id job-id))
  (nl-agent-training-protocol--id active-attempt
                                  "training recovery active attempt")
  (let ((path
         (nl-agent-training-recovery-marker-path directory scope job-id)))
    (if (not (nl-agent-training-recovery--marker-present-p path))
        nil
      (let ((marker
             (nl-agent-training-recovery--read-marker
              directory scope job-id)))
        (unless (equal active-attempt (plist-get marker :active-attempt))
          (error "training recovery marker release CAS mismatch"))
        (nl-agent-training-recovery--reject-symlink path)
        (delete-file path)
        t))))

;;;###autoload
(defun nl-agent-training-recovery-save
    (directory request request-sha256 checkpoint &optional expected-attempt)
  "Atomically save a stopped-attempt recovery receipt and return its path.
REQUEST and CHECKPOINT are fully validated against REQUEST-SHA256 before any
write.  Saving identical content is idempotent.  Different existing content is
replaced only when EXPECTED-ATTEMPT equals the stored request attempt (CAS).

The caller must first observe that the associated child is terminal.  This
function cannot prove process state and grants no authorization to resume.
The caller must also hold its exclusive recovery-directory owner lock; the
read/check/write sequence is not a cross-process atomic CAS primitive."
  (nl-agent-training-protocol-validate-request request)
  (nl-agent-training-protocol-validate-checkpoint
   checkpoint request request-sha256)
  (let* ((scope (plist-get request :scope))
         (job-id (plist-get request :job-id))
         (path (nl-agent-training-recovery-path directory scope job-id))
         (receipt
          (list :format nl-agent-training-recovery-format
                :request request
                :request-sha256 request-sha256
                :checkpoint checkpoint))
         (same nil)
         (marker-path
          (nl-agent-training-recovery-marker-path directory scope job-id))
         (marker nil))
    (nl-agent-training-recovery--validate receipt scope job-id)
    (nl-agent-training-recovery--reject-symlink path)
    (when (nl-agent-training-recovery--marker-present-p marker-path)
      (setq marker
            (nl-agent-training-recovery--read-marker
             directory scope job-id))
      (unless (equal (plist-get marker :active-attempt)
                     (plist-get request :attempt))
        (error "training recovery active attempt mismatch"))
      (when (and expected-attempt
                 (not (equal expected-attempt
                             (plist-get marker :origin-attempt))))
        (error "training recovery expected origin mismatch")))
    (when (file-exists-p path)
      (let ((existing
             (nl-agent-training-recovery--load-receipt
              directory scope job-id)))
        (if (equal existing receipt)
            (setq same t)
          (unless (if marker
                      (equal (plist-get marker :origin-attempt)
                             (plist-get (plist-get existing :request) :attempt))
                    (and expected-attempt
                         (equal expected-attempt
                                (plist-get (plist-get existing :request)
                                           :attempt))))
            (error "training recovery receipt CAS mismatch")))))
    (unless same
      (nl-agent-training-recovery--reject-symlink path)
      (nl-agent-training-protocol-write path receipt))
    (when marker
      (nl-agent-training-recovery-release
       directory scope job-id (plist-get request :attempt)))
    path))

;;;###autoload
(defun nl-agent-training-recovery-remove
    (directory scope job-id expected-attempt)
  "Remove the exact receipt only when its attempt is EXPECTED-ATTEMPT.
Return non-nil when removed and nil when absent.  Signal on an attempt mismatch,
leaving the receipt intact.  No broad cleanup or directory scan is performed."
  (setq scope (nl-agent-training-recovery--scope scope)
        job-id (nl-agent-training-recovery--job-id job-id))
  (let ((path (nl-agent-training-recovery-path directory scope job-id)))
    (when (nl-agent-training-recovery--marker-present-p
           (nl-agent-training-recovery-marker-path directory scope job-id))
      (error "cannot remove an actively reserved training recovery receipt"))
    (nl-agent-training-recovery--reject-symlink path)
    (if (not (file-exists-p path))
        nil
      (let ((receipt
             (nl-agent-training-recovery-load directory scope job-id)))
        (if (not (equal expected-attempt
                        (plist-get (plist-get receipt :request) :attempt)))
            (error "training recovery receipt removal CAS mismatch")
          (nl-agent-training-recovery--reject-symlink path)
          (delete-file path)
          t)))))

(provide 'nl-agent-training-recovery)
;;; nl-agent-training-recovery.el ends here
