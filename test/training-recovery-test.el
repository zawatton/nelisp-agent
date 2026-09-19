;;; training-recovery-test.el --- stopped-attempt receipt tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'nl-agent-training-recovery)
(require 'nl-llm-agent-improve)
(require 'nl-llm-agent-artifact)

(defun nl-agent-training-recovery-test--model ()
  "Return a small raw P5 model checkpoint."
  (nl-llm-agent-artifact-export-pav
   (nl-llm-agent-improve-model 4 4 nl-llm-agent-char-vocab 1 1)))

(defun nl-agent-training-recovery-test--request (&optional attempt scope job-id)
  "Return a valid resumable request."
  (list :format nl-agent-training-protocol-format
        :attempt (or attempt "attempt-1") :job-id (or job-id "job-1")
        :parent-generation 2 :parent-score 0.25
        :scope (or scope (make-string 64 ?b))
        :payload '(:examples ["ab" "cd"] :lr 0.1 :epochs 2)
        :parent-model (nl-agent-training-recovery-test--model)
        :training '(:backend gpu :sequence 8 :optimizer sgd
                    :checkpoint-every 2)
        :benchmark ["ab"]))

(defun nl-agent-training-recovery-test--state (request)
  "Return an enriched wire checkpoint state for REQUEST."
  (let ((model (copy-tree (plist-get request :parent-model) t)))
    (plist-put model :step 1)
    (aset (photon-tensor-data (plist-get model :wte)) 0 0.125)
    (list :format nl-llm-agent-training-checkpoint-format
          :job-id (plist-get request :job-id)
          :payload-digest
          (nl-llm-agent-training-checkpoint-payload-digest
           (plist-get request :payload))
          :scope (plist-get request :scope)
          :parent-generation (plist-get request :parent-generation)
          :parent-score (plist-get request :parent-score)
          :sequence 8 :optimizer 'sgd :completed-steps 1 :total-steps 4
          :optimizer-step 1 :model model :optimizer-state nil
          :request-binding
          (nl-agent-training-protocol-request-binding request))))

(defun nl-agent-training-recovery-test--checkpoint (request hash)
  "Return a progress envelope for REQUEST and HASH."
  (list :format nl-agent-training-checkpoint-format
        :attempt (plist-get request :attempt)
        :request-sha256 hash
        :state (nl-agent-training-recovery-test--state request)))

(defun nl-agent-training-recovery-test--receipt (request hash checkpoint)
  "Return a recovery receipt from REQUEST, HASH, and CHECKPOINT."
  (list :format nl-agent-training-recovery-format
        :request request :request-sha256 hash :checkpoint checkpoint))

(defun nl-agent-training-recovery-test--next (request attempt hash-character)
  "Return (REQUEST HASH CHECKPOINT) for a new ATTEMPT."
  (let* ((next (copy-tree request t))
         (_ (plist-put next :attempt attempt))
         (hash (make-string 64 hash-character)))
    (list next hash
          (nl-agent-training-recovery-test--checkpoint next hash))))

(defmacro nl-agent-training-recovery-test--with-fixture
    (bindings &rest body)
  "Bind a temporary recovery fixture according to BINDINGS around BODY."
  (declare (indent 1))
  `(let* ((directory (make-temp-file "nl-training-recovery-" t))
          (request (nl-agent-training-recovery-test--request))
          (hash (make-string 64 ?a))
          (checkpoint
           (nl-agent-training-recovery-test--checkpoint request hash))
          ,@bindings)
     (unwind-protect (progn ,@body)
       (delete-directory directory t))))

(ert-deftest nl-agent-training-recovery-roundtrip-and-continuity ()
  (nl-agent-training-recovery-test--with-fixture
      ((path (nl-agent-training-recovery-save
              directory request hash checkpoint)))
    (should (file-regular-p path))
    (should (= (file-modes path) #o600))
    (should (equal path
                   (nl-agent-training-recovery-save
                    directory request hash checkpoint)))
    (let ((loaded
           (nl-agent-training-recovery-load
            directory (plist-get request :scope) (plist-get request :job-id))))
      (should (equal loaded
                     (nl-agent-training-recovery-test--receipt
                      request hash checkpoint)))
      (should (equal (plist-get (plist-get loaded :checkpoint) :state)
                     (plist-get checkpoint :state))))))

(ert-deftest nl-agent-training-recovery-rejects-request-envelope-mismatch ()
  (nl-agent-training-recovery-test--with-fixture ()
    (should-error
     (nl-agent-training-recovery-save
      directory request (make-string 64 ?f) checkpoint))
    (let ((wrong (copy-tree checkpoint t)))
      (plist-put wrong :attempt "other")
      (should-error
       (nl-agent-training-recovery-save directory request hash wrong)))
    (should-error
     (nl-agent-training-recovery-load
      directory (make-string 64 ?c) (plist-get request :job-id)))
    (should-error
     (nl-agent-training-recovery-load
      directory (plist-get request :scope) "other-job"))))

(ert-deftest nl-agent-training-recovery-rejects-malformed-receipts ()
  (nl-agent-training-recovery-test--with-fixture
      ((path (nl-agent-training-recovery-path
              directory (plist-get request :scope)
              (plist-get request :job-id)))
       (receipt (nl-agent-training-recovery-test--receipt
                 request hash checkpoint)))
    (dolist (bad
             (list (append receipt '(:request nil))
                   (append receipt '(:unknown t))
                   (cdr (cdr receipt))))
      (nl-agent-training-protocol-write path bad)
      (should-error
       (nl-agent-training-recovery-load
        directory (plist-get request :scope) (plist-get request :job-id))))
    (with-temp-file path (insert "#.(error \"read-eval fired\")"))
    (should-error
     (nl-agent-training-recovery-load
      directory (plist-get request :scope) (plist-get request :job-id)))
    (with-temp-file path (insert "(:format nil) (:trailing t)"))
    (should-error
     (nl-agent-training-recovery-load
      directory (plist-get request :scope) (plist-get request :job-id)))
    (with-temp-file path (insert (make-string 128 ?x)))
    (let ((nl-agent-training-protocol-max-bytes 64))
      (should-error
       (nl-agent-training-recovery-load
        directory (plist-get request :scope) (plist-get request :job-id))))))

(ert-deftest nl-agent-training-recovery-load-rejects-stored-identity ()
  (nl-agent-training-recovery-test--with-fixture
      ((path (nl-agent-training-recovery-path
              directory (plist-get request :scope)
              (plist-get request :job-id))))
    (ignore checkpoint)
    (dolist (changed
             (list
              (nl-agent-training-recovery-test--request
               "attempt-1" (make-string 64 ?c) "job-1")
              (nl-agent-training-recovery-test--request
               "attempt-1" (make-string 64 ?b) "other-job")))
      (let* ((changed-hash (make-string 64 ?d))
             (changed-checkpoint
              (nl-agent-training-recovery-test--checkpoint
               changed changed-hash)))
        (nl-agent-training-protocol-write
         path (nl-agent-training-recovery-test--receipt
               changed changed-hash changed-checkpoint))
        (should-error
         (nl-agent-training-recovery-load
          directory (plist-get request :scope) (plist-get request :job-id)))))))

(ert-deftest nl-agent-training-recovery-save-failure-preserves-old ()
  (nl-agent-training-recovery-test--with-fixture
      ((path (nl-agent-training-recovery-save
              directory request hash checkpoint)))
    (let ((before (nl-agent-training-protocol-read path))
          (wrong (copy-tree checkpoint t)))
      (plist-put wrong :request-sha256 (make-string 64 ?f))
      (should-error
       (nl-agent-training-recovery-save
        directory request hash wrong
        (plist-get request :attempt)))
      (should (equal before (nl-agent-training-protocol-read path))))))

(ert-deftest nl-agent-training-recovery-replacement-is-attempt-cas ()
  (nl-agent-training-recovery-test--with-fixture
      ((path (nl-agent-training-recovery-save
              directory request hash checkpoint)))
    (let* ((request-2 (copy-tree request t))
           (_ (plist-put request-2 :attempt "attempt-2"))
           (hash-2 (make-string 64 ?c))
           (checkpoint-2
            (nl-agent-training-recovery-test--checkpoint request-2 hash-2)))
      (should-error
       (nl-agent-training-recovery-save
        directory request-2 hash-2 checkpoint-2 "wrong-attempt"))
      (should (equal (plist-get (plist-get
                                 (nl-agent-training-protocol-read path)
                                 :request)
                                :attempt)
                     "attempt-1"))
      (should (equal path
                     (nl-agent-training-recovery-save
                      directory request-2 hash-2 checkpoint-2 "attempt-1")))
      (should (equal
               (plist-get
                (plist-get
                 (nl-agent-training-recovery-load
                  directory (plist-get request :scope)
                  (plist-get request :job-id))
                 :request)
                :attempt)
               "attempt-2")))))

(ert-deftest nl-agent-training-recovery-remove-is-attempt-scoped ()
  (nl-agent-training-recovery-test--with-fixture
      ((path (nl-agent-training-recovery-save
              directory request hash checkpoint)))
    (should-error
     (nl-agent-training-recovery-remove
      directory (plist-get request :scope) (plist-get request :job-id)
      "wrong-attempt"))
    (should (file-exists-p path))
    (should
     (nl-agent-training-recovery-remove
      directory (plist-get request :scope) (plist-get request :job-id)
      (plist-get request :attempt)))
    (should-not (file-exists-p path))
    (should-not
     (nl-agent-training-recovery-remove
      directory (plist-get request :scope) (plist-get request :job-id)
      (plist-get request :attempt)))))

(ert-deftest nl-agent-training-recovery-rejects-symlink-receipts ()
  (nl-agent-training-recovery-test--with-fixture
      ((path (nl-agent-training-recovery-path
              directory (plist-get request :scope)
              (plist-get request :job-id)))
       (target (expand-file-name "target.sexp" directory)))
    (nl-agent-training-protocol-write
     target (nl-agent-training-recovery-test--receipt request hash checkpoint))
    (make-symbolic-link target path)
    (should-error
     (nl-agent-training-recovery-save directory request hash checkpoint))
    (should-error
     (nl-agent-training-recovery-load
      directory (plist-get request :scope) (plist-get request :job-id)))
    (should-error
     (nl-agent-training-recovery-remove
      directory (plist-get request :scope) (plist-get request :job-id)
      (plist-get request :attempt)))
    (should (file-exists-p target))))

(ert-deftest nl-agent-training-recovery-reservation-fails-closed ()
  (nl-agent-training-recovery-test--with-fixture
      ((_path (nl-agent-training-recovery-save
               directory request hash checkpoint))
       (marker (nl-agent-training-recovery-reserve
                directory (plist-get request :scope)
                (plist-get request :job-id) "attempt-1" "attempt-2")))
    (should (file-regular-p marker))
    (should (= (file-modes marker) #o600))
    (should-error
     (nl-agent-training-recovery-load
      directory (plist-get request :scope) (plist-get request :job-id)))
    ;; The store has no process-local occupancy state: another instance seeing
    ;; the same files fails closed in exactly the same way.
    (should-error
     (nl-agent-training-recovery-load
      directory (plist-get request :scope) (plist-get request :job-id)))
    (should-error
     (nl-agent-training-recovery-reserve
      directory (plist-get request :scope) (plist-get request :job-id)
      "attempt-1" "attempt-3"))))

(ert-deftest nl-agent-training-recovery-wrong-active-cannot-mutate-store ()
  (nl-agent-training-recovery-test--with-fixture
      ((path (nl-agent-training-recovery-save
              directory request hash checkpoint))
       (marker (nl-agent-training-recovery-reserve
                directory (plist-get request :scope)
                (plist-get request :job-id) "attempt-1" "attempt-2"))
       (next (nl-agent-training-recovery-test--next request "attempt-3" ?c)))
    (should-error
     (nl-agent-training-recovery-release
      directory (plist-get request :scope) (plist-get request :job-id)
      "attempt-3"))
    (should-error
     (nl-agent-training-recovery-save
      directory (nth 0 next) (nth 1 next) (nth 2 next) "attempt-1"))
    (should-error
     (nl-agent-training-recovery-remove
      directory (plist-get request :scope) (plist-get request :job-id)
      "attempt-1"))
    (should (file-exists-p path))
    (should (file-exists-p marker))))

(ert-deftest nl-agent-training-recovery-observed-stop-save-clears-marker ()
  (nl-agent-training-recovery-test--with-fixture
      ((path (nl-agent-training-recovery-save
              directory request hash checkpoint))
       (next (nl-agent-training-recovery-test--next request "attempt-2" ?c))
       (marker (nl-agent-training-recovery-reserve
                directory (plist-get request :scope)
                (plist-get request :job-id) "attempt-1" "attempt-2")))
    (should (equal path
                   (nl-agent-training-recovery-save
                    directory (nth 0 next) (nth 1 next) (nth 2 next))))
    (should-not (file-exists-p marker))
    (should (equal
             (plist-get
              (plist-get
               (nl-agent-training-recovery-load
                directory (plist-get request :scope)
                (plist-get request :job-id))
               :request)
              :attempt)
             "attempt-2"))))

(ert-deftest nl-agent-training-recovery-pre-spawn-release-reenables-receipt ()
  (nl-agent-training-recovery-test--with-fixture
      ((_path (nl-agent-training-recovery-save
               directory request hash checkpoint))
       (marker (nl-agent-training-recovery-reserve
                directory (plist-get request :scope)
                (plist-get request :job-id) "attempt-1" "attempt-2")))
    (should
     (nl-agent-training-recovery-release
      directory (plist-get request :scope) (plist-get request :job-id)
      "attempt-2"))
    (should-not (file-exists-p marker))
    (should (equal
             (plist-get
              (plist-get
               (nl-agent-training-recovery-load
                directory (plist-get request :scope)
                (plist-get request :job-id))
               :request)
              :attempt)
             "attempt-1"))))

(ert-deftest nl-agent-training-recovery-failed-save-preserves-marker ()
  (nl-agent-training-recovery-test--with-fixture
      ((_path (nl-agent-training-recovery-save
               directory request hash checkpoint))
       (next (nl-agent-training-recovery-test--next request "attempt-2" ?c))
       (marker (nl-agent-training-recovery-reserve
                directory (plist-get request :scope)
                (plist-get request :job-id) "attempt-1" "attempt-2")))
    (let ((bad (copy-tree (nth 2 next) t)))
      (plist-put bad :request-sha256 (make-string 64 ?f))
      (should-error
       (nl-agent-training-recovery-save
        directory (nth 0 next) (nth 1 next) bad "attempt-1")))
    (should (file-exists-p marker))
    (should-error
     (nl-agent-training-recovery-load
      directory (plist-get request :scope) (plist-get request :job-id)))))

(ert-deftest nl-agent-training-recovery-release-failure-is-retryable ()
  (nl-agent-training-recovery-test--with-fixture
      ((path (nl-agent-training-recovery-save
              directory request hash checkpoint))
       (next (nl-agent-training-recovery-test--next request "attempt-2" ?c))
       (marker (nl-agent-training-recovery-reserve
                directory (plist-get request :scope)
                (plist-get request :job-id) "attempt-1" "attempt-2")))
    (cl-letf (((symbol-function 'nl-agent-training-recovery-release)
               (lambda (&rest _arguments) (error "injected release failure"))))
      (should-error
       (nl-agent-training-recovery-save
        directory (nth 0 next) (nth 1 next) (nth 2 next) "attempt-1")))
    (should (file-exists-p marker))
    (should-error
     (nl-agent-training-recovery-load
      directory (plist-get request :scope) (plist-get request :job-id)))
    ;; The receipt already contains the new attempt.  An identical retry is
    ;; idempotent and performs the pending marker release.
    (should (equal path
                   (nl-agent-training-recovery-save
                    directory (nth 0 next) (nth 1 next) (nth 2 next))))
    (should-not (file-exists-p marker))
    (should (equal
             (plist-get
              (plist-get
               (nl-agent-training-recovery-load
                directory (plist-get request :scope)
                (plist-get request :job-id))
               :request)
              :attempt)
             "attempt-2"))))

(provide 'training-recovery-test)
(ert-run-tests-batch-and-exit)

;;; training-recovery-test.el ends here
