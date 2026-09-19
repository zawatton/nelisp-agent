;;; curation-supervised-queue-test.el --- supervised curation queue tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(defconst nl-agent-curation-supervised-queue-test--here
  (file-name-directory (or load-file-name buffer-file-name)))

(add-to-list 'load-path
             (expand-file-name "../lisp"
                               nl-agent-curation-supervised-queue-test--here))
(add-to-list 'load-path
             (expand-file-name "../../nelisp-llm/lisp"
                               nl-agent-curation-supervised-queue-test--here))
(add-to-list 'load-path
             (expand-file-name "../../nelisp-photon/lisp"
                               nl-agent-curation-supervised-queue-test--here))

(require 'nl-agent-curation)
(require 'nl-agent-training-runner)
(require 'nl-agent-trajectory)
(require 'nl-llm-agent-tokenizer)
(require 'nl-llm-evolve-queue)

(defmacro nl-agent-curation-supervised-queue-test--with-store
    (directory &rest body)
  "Bind DIRECTORY to a temporary trajectory store while running BODY."
  (declare (indent 1))
  `(let* ((parent (make-temp-file "nl-agent-supervised-queue-" t))
          (,directory (expand-file-name "records" parent)))
     (make-directory ,directory)
     (unwind-protect
         (progn ,@body)
       (delete-directory parent t))))

(defun nl-agent-curation-supervised-queue-test--queue
    (&optional tokenizer with-handler)
  "Return a synthetic queue for TOKENIZER, optionally with its handler."
  (let* ((tokenizer (nl-llm-agent-tokenizer-id tokenizer))
         (model (list :tokenizer tokenizer
                      :vocab (nl-llm-agent-tokenizer-vocab tokenizer)
                      :fitness 1.0))
         (evolution
          (nl-llm-evolution-new
           model (lambda (_model) 1.0) :clone #'copy-tree))
         (queue (nl-llm-evolve-queue-new evolution :max-pending 4)))
    (when with-handler
      (nl-llm-evolve-queue-register
       queue "supervised-finetune"
       (lambda (_candidate _payload _state) nil)
       :validate
       (lambda (payload)
         (unless (equal (sort (copy-sequence (let (keys) (while payload
                                                            (push (car payload) keys)
                                                            (setq payload (cddr payload)))
                                                  keys))
                              (lambda (left right)
                                (string< (symbol-name left)
                                         (symbol-name right))))
                        '(:epochs :examples :lr))
           (error "unexpected supervised payload keys")))
       :description "Synchronous supervised fine-tune proposal"))
    queue))

(defun nl-agent-curation-supervised-queue-test--record
    (directory &optional task)
  "Save one small successful trajectory and return its record id."
  (file-name-nondirectory
   (nl-agent-trajectory-save
    directory (or task "queue task")
    '(:kind agent-run :status done :steps 1 :result "claim"
      :messages ((user . "queue task"))
      :trajectory
      ((:step 1 :model "native/base" :assistant "answer"
        :action (done "answer")))))))

(defun nl-agent-curation-supervised-queue-test--context
    (directory evaluator &optional tokenizer holdouts)
  "Create a test curator with explicit host approval."
  (nl-agent-curation-new
   directory evaluator "queue-supervised-test"
   :data-use-approved t :tokenizer tokenizer :holdout-digests holdouts
   :lr 0.2 :epochs 3))

(defun nl-agent-curation-supervised-queue-test--accept ()
  "Return the trusted accepting evaluator used by queue tests."
  (lambda (_record) '(:accepted t :reason "approved")))

(ert-deftest nl-agent-curation-submit-supervised-rejects-missing-handler-before-prepare ()
  (nl-agent-curation-supervised-queue-test--with-store directory
    (let* ((queue (nl-agent-curation-supervised-queue-test--queue))
           (context
            (nl-agent-curation-supervised-queue-test--context
             directory (nl-agent-curation-supervised-queue-test--accept)))
           (record-id
            (nl-agent-curation-supervised-queue-test--record directory))
           (prepared 0))
      (cl-letf (((symbol-function 'nl-agent-curation-prepare-supervised)
                 (lambda (&rest _args) (setq prepared (1+ prepared)))))
        (should-error
         (nl-agent-curation-submit-supervised context queue record-id)))
      (should (= prepared 0))
      (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                 0)))))

(ert-deftest nl-agent-curation-submit-supervised-rejects-tokenizer-mismatch-before-evaluator ()
  (nl-agent-curation-supervised-queue-test--with-store directory
    (let* ((queue
            (nl-agent-curation-supervised-queue-test--queue
             "utf8-byte-v1" t))
           (evaluations 0)
           (context
            (nl-agent-curation-supervised-queue-test--context
             directory
             (lambda (_record)
               (setq evaluations (1+ evaluations))
               '(:accepted t :reason "unexpected"))))
           (record-id
            (nl-agent-curation-supervised-queue-test--record directory))
           (prepared 0))
      ;; The record is ASCII, but the queue's model tokenizer is UTF-8.  The
      ;; mismatch must be rejected before preparation or evaluator code.
      (cl-letf (((symbol-function 'nl-agent-curation-prepare-supervised)
                 (lambda (&rest _args) (setq prepared (1+ prepared)))))
        (should-error
         (nl-agent-curation-submit-supervised context queue record-id)))
      (should (= prepared 0))
      (should (= evaluations 0))
      (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                 0)))))

(ert-deftest nl-agent-curation-submit-supervised-holdout-leaves-queue-empty ()
  (nl-agent-curation-supervised-queue-test--with-store directory
    (let* ((record-id
            (nl-agent-curation-supervised-queue-test--record directory))
           (path (expand-file-name record-id directory))
           (digest (plist-get (nl-agent-trajectory-read-snapshot path)
                              :sha256))
           (queue
            (nl-agent-curation-supervised-queue-test--queue
             "ascii-char-v1" t))
           (context
            (nl-agent-curation-supervised-queue-test--context
             directory (nl-agent-curation-supervised-queue-test--accept)
             "ascii-char-v1" (list digest))))
      (should-error
       (nl-agent-curation-submit-supervised context queue record-id))
      (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                 0)))))

(ert-deftest nl-agent-curation-submit-supervised-denial-leaves-queue-empty ()
  (nl-agent-curation-supervised-queue-test--with-store directory
    (let* ((queue
            (nl-agent-curation-supervised-queue-test--queue
             "ascii-char-v1" t))
           (context
            (nl-agent-curation-supervised-queue-test--context
             directory
             (lambda (_record) '(:accepted nil :reason "hold"))))
           (record-id
            (nl-agent-curation-supervised-queue-test--record directory)))
      (should-error
       (nl-agent-curation-submit-supervised context queue record-id))
      (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                 0)))))

(ert-deftest nl-agent-curation-submit-supervised-submits-detached-pending-payload ()
  (nl-agent-curation-supervised-queue-test--with-store directory
    (let* ((queue
            (nl-agent-curation-supervised-queue-test--queue
             "ascii-char-v1" t))
           (context
            (nl-agent-curation-supervised-queue-test--context
             directory (nl-agent-curation-supervised-queue-test--accept)))
           (record-id
            (nl-agent-curation-supervised-queue-test--record directory))
           (calls 0)
           (original (symbol-function 'nl-agent-curation-prepare-supervised))
           prepared)
      (cl-letf (((symbol-function 'nl-agent-curation-prepare-supervised)
                 (lambda (&rest args)
                   (setq calls (1+ calls))
                   (setq prepared (apply original args)))))
        (let* ((public
               (nl-agent-curation-submit-supervised
                 context queue record-id "supervised-job"))
               (job
                (aref (plist-get (nl-llm-evolve-queue-snapshot queue) :jobs)
                      0))
               (payload (plist-get job :payload))
               (metadata (plist-get job :metadata))
               (pairs (plist-get prepared :examples)))
          (should (equal (plist-get public :id) "supervised-job"))
          (should (eq (plist-get public :status) 'pending))
          (should (= calls 1))
          (should (equal (plist-get payload :examples) pairs))
          (should (= (plist-get payload :lr) 0.2))
          (should (= (plist-get payload :epochs) 3))
          (should (equal (plist-get metadata :source-sha256)
                         (plist-get (plist-get prepared :metadata)
                                    :source-sha256)))
          (should (equal (plist-get metadata :dataset-sha256)
                         (plist-get (plist-get prepared :encoding)
                                    :dataset-sha256)))
          ;; Queue submission owns a detached snapshot, not PREPARED's data.
          (setf (plist-get (aref (plist-get prepared :examples) 0)
                           :completion)
                "caller mutation")
          (setf (plist-get (plist-get prepared :metadata) :policy-id)
                "caller mutation")
          (should (equal (plist-get (aref (plist-get payload :examples) 0)
                                    :completion)
                         "answer"))
          (should (equal (plist-get metadata :policy-id)
                         "queue-supervised-test")))))))

(ert-deftest nl-agent-training-runner-rejects-supervised-checkpoint-profile-before-claim ()
  (let* ((queue
          (nl-agent-curation-supervised-queue-test--queue
           "ascii-char-v1" t))
         (runner (nl-agent-training-runner--make
                  :queue queue
                  :profile '(:training (:backend cpu :sequence 8
                                         :optimizer sgd :checkpoint-every 1)))))
    (nl-llm-evolve-queue-submit
     queue "supervised-finetune"
     '(:examples [] :lr 0.2 :epochs 3) :id "sync-only")
    (should-error (nl-agent-training-runner-start runner))
    (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
               1))
    (should-not (nl-agent-training-runner-claim runner))))

(provide 'curation-supervised-queue-test)

(ert-run-tests-batch-and-exit)

;;; curation-supervised-queue-test.el ends here
