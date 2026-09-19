;;; curation-supervised-tools-test.el --- supervised curation tool tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(defconst nl-agent-curation-supervised-tools-test--here
  (file-name-directory (or load-file-name buffer-file-name)))

(add-to-list 'load-path
             (expand-file-name "../lisp"
                               nl-agent-curation-supervised-tools-test--here))
(add-to-list 'load-path
             (expand-file-name "../../nelisp-llm/lisp"
                               nl-agent-curation-supervised-tools-test--here))
(add-to-list 'load-path
             (expand-file-name "../../nelisp-photon/lisp"
                               nl-agent-curation-supervised-tools-test--here))

(require 'nl-agent-curation-tools)
(require 'nl-agent-permission)
(require 'nl-agent-trajectory)
(require 'nl-llm-agent-supervised)

(defmacro nl-agent-curation-supervised-tools-test--with-store
    (directory &rest body)
  "Bind DIRECTORY to a temporary record store while running BODY."
  (declare (indent 1))
  `(let* ((parent (make-temp-file "nl-curation-supervised-tools-" t))
          (,directory (expand-file-name "records" parent)))
     (make-directory ,directory)
     (unwind-protect
         (progn ,@body)
       (delete-directory parent t))))

(defun nl-agent-curation-supervised-tools-test--queue
    (&optional tokenizer both)
  "Return a synthetic queue for TOKENIZER, optionally with both handlers."
  (let* ((tokenizer (nl-llm-agent-tokenizer-id tokenizer))
         (model (list :tokenizer tokenizer
                      :vocab (nl-llm-agent-tokenizer-vocab tokenizer)
                      :fitness 1.0))
         (evolution
          (nl-llm-evolution-new model (lambda (_model) 1.0)
                                :clone #'copy-tree))
         (queue (nl-llm-evolve-queue-new evolution :max-pending 8)))
    (dolist (kind (if both '("trajectory-finetune" "supervised-finetune")
                       '("trajectory-finetune")))
      (nl-llm-evolve-queue-register
       queue kind (lambda (_candidate _payload _state) nil)
       :validate (lambda (_payload) nil)
       :description "test curation handler"))
    queue))

(defun nl-agent-curation-supervised-tools-test--context
    (directory evaluator &optional tokenizer holdouts)
  "Return an explicitly approved host curator."
  (nl-agent-curation-new
   directory evaluator "supervised-tools-policy"
   :data-use-approved t :tokenizer tokenizer :holdout-digests holdouts
   :lr 0.2 :epochs 2))

(defun nl-agent-curation-supervised-tools-test--record (directory)
  "Save one small valid done trajectory and return its record id."
  (file-name-nondirectory
   (nl-agent-trajectory-save
    directory "tool task"
    '(:kind agent-run :status done :steps 1 :result "claim"
      :messages ((user . "tool task"))
      :trajectory
      ((:step 1 :model "native/base" :assistant "answer"
        :action (done "answer")))))))

(defun nl-agent-curation-supervised-tools-test--accept ()
  "Return the trusted accepting evaluator."
  (lambda (_record) '(:accepted t :reason "approved")))

(defun nl-agent-curation-supervised-tools-test--register
    (queue directory &optional evaluator tokenizer)
  "Register supervised tooling for QUEUE and DIRECTORY."
  (let ((registry (nl-agent-tool-registry-new)))
    (nl-agent-curation-register-tools
     registry queue
     (nl-agent-curation-supervised-tools-test--context
      directory (or evaluator
                    (nl-agent-curation-supervised-tools-test--accept))
      tokenizer)
     "supervised-finetune")
    registry))

(defun nl-agent-curation-supervised-tools-test--job (queue)
  "Return the one retained private queue job."
  (aref (plist-get (nl-llm-evolve-queue-snapshot queue) :jobs) 0))

(ert-deftest nl-agent-curation-supervised-tools-requires-handler-at-registration ()
  (nl-agent-curation-supervised-tools-test--with-store directory
    (let ((queue (nl-agent-curation-supervised-tools-test--queue)))
      (should-error
       (nl-agent-curation-register-tools
        (nl-agent-tool-registry-new) queue
        (nl-agent-curation-supervised-tools-test--context
         directory
         (nl-agent-curation-supervised-tools-test--accept))
        "supervised-finetune")))))

(ert-deftest nl-agent-curation-supervised-tools-rejects-tokenizer-before-tool ()
  (nl-agent-curation-supervised-tools-test--with-store directory
    (let ((queue
           (nl-agent-curation-supervised-tools-test--queue
            "utf8-byte-v1" t)))
      (should-error
       (nl-agent-curation-register-tools
        (nl-agent-tool-registry-new) queue
        (nl-agent-curation-supervised-tools-test--context
         directory
         (nl-agent-curation-supervised-tools-test--accept)
         "ascii-char-v1")
        "supervised-finetune")))))

(ert-deftest nl-agent-curation-supervised-tools-submits-exact-payload-and-digest ()
  (nl-agent-curation-supervised-tools-test--with-store directory
    (let* ((queue
            (nl-agent-curation-supervised-tools-test--queue
             "ascii-char-v1" t))
           (registry
            (nl-agent-curation-supervised-tools-test--register
             queue directory))
           (record-id
            (nl-agent-curation-supervised-tools-test--record directory))
           (result
            (nl-agent-permission-call
             (nl-agent-permission-policy-new :mode 'off)
             registry "model.improvement.curate"
             (list :record-id record-id)))
           (job (nl-agent-curation-supervised-tools-test--job queue))
           (payload (plist-get job :payload))
           (metadata (plist-get job :metadata))
           (encoded
            (nl-llm-agent-supervised-encode
             (plist-get payload :examples) "ascii-char-v1")))
      (should (eq (plist-get result :status) 'ok))
      (should (eq (plist-get (plist-get result :value) :status) 'pending))
      (should (equal (plist-get job :kind) "supervised-finetune"))
      (should (equal (sort (copy-sequence
                            (let (keys) (while payload
                                           (push (car payload) keys)
                                           (setq payload (cddr payload)))
                                         keys))
                          (lambda (left right)
                            (string< (symbol-name left)
                                     (symbol-name right))))
                     '(:epochs :examples :lr)))
      (should (= (plist-get (plist-get job :payload) :lr) 0.2))
      (should (= (plist-get (plist-get job :payload) :epochs) 2))
      (should (equal (plist-get metadata :dataset-sha256)
                     (plist-get encoded :dataset-sha256)))
      (should (stringp (plist-get metadata :source-sha256)))
      (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                 1)))))

(ert-deftest nl-agent-curation-supervised-tools-denial-holdout-and-record-id-only ()
  (nl-agent-curation-supervised-tools-test--with-store directory
    (let* ((queue
            (nl-agent-curation-supervised-tools-test--queue
             "ascii-char-v1" t))
           (record-id
            (nl-agent-curation-supervised-tools-test--record directory))
           (digest
            (plist-get
             (nl-agent-trajectory-read-snapshot
              (expand-file-name record-id directory))
             :sha256))
           (calls 0)
           (context
            (nl-agent-curation-supervised-tools-test--context
             directory
             (lambda (_record)
               (setq calls (1+ calls))
               '(:accepted nil :reason "denied"))))
           (registry (nl-agent-tool-registry-new)))
      (nl-agent-curation-register-tools
       registry queue context "supervised-finetune")
      (should
       (eq (plist-get
            (nl-agent-permission-call
             (nl-agent-permission-policy-new :mode 'off)
             registry "model.improvement.curate"
             (list :record-id record-id))
            :status)
           'error))
      (should (= calls 1))
      (should
       (eq (plist-get
            (nl-agent-permission-call
             (nl-agent-permission-policy-new :mode 'off)
             registry "model.improvement.curate"
             (list :record-id record-id :path "forbidden"))
            :status)
           'error))
      (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                 0))
      (let ((holdout
             (nl-agent-curation-supervised-tools-test--context
              directory (nl-agent-curation-supervised-tools-test--accept)
              "ascii-char-v1" (list digest)))
            (holdout-registry (nl-agent-tool-registry-new)))
        (nl-agent-curation-register-tools
         holdout-registry queue holdout "supervised-finetune")
        (should
         (eq (plist-get
              (nl-agent-permission-call
               (nl-agent-permission-policy-new :mode 'off)
               holdout-registry "model.improvement.curate"
               (list :record-id record-id))
              :status)
             'error))
        (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                   0))))))

(ert-deftest nl-agent-curation-supervised-tools-permission-denial-does-not-prepare ()
  (nl-agent-curation-supervised-tools-test--with-store directory
    (let* ((queue
            (nl-agent-curation-supervised-tools-test--queue
             "ascii-char-v1" t))
           (registry
            (nl-agent-curation-supervised-tools-test--register
             queue directory))
           (prepared 0)
           (record-id
            (nl-agent-curation-supervised-tools-test--record directory)))
      (cl-letf (((symbol-function 'nl-agent-curation-prepare-supervised)
                 (lambda (&rest _args) (setq prepared (1+ prepared)))))
        (should (eq
                 (plist-get
                  (nl-agent-permission-call
                   (nl-agent-permission-policy-new :mode 'smart)
                   registry "model.improvement.curate"
                   (list :record-id record-id))
                  :status)
                 'denied)))
      (should (= prepared 0))
      (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                 0)))))

(ert-deftest nl-agent-curation-supervised-tools-runtime-handler-removal-rejects-before-prepare ()
  (nl-agent-curation-supervised-tools-test--with-store directory
    (let* ((queue
            (nl-agent-curation-supervised-tools-test--queue
             "ascii-char-v1" t))
           (registry
            (nl-agent-curation-supervised-tools-test--register
             queue directory))
           (record-id
            (nl-agent-curation-supervised-tools-test--record directory))
           (prepared 0))
      (setf (nl-llm-evolve-queue-handlers queue)
            (cl-remove-if
             (lambda (handler)
               (equal (nl-llm-evolve-queue-handler-kind handler)
                      "supervised-finetune"))
             (nl-llm-evolve-queue-handlers queue)))
      (cl-letf (((symbol-function 'nl-agent-curation-prepare-supervised)
                 (lambda (&rest _args) (setq prepared (1+ prepared)))))
        (should
         (eq (plist-get
              (nl-agent-permission-call
               (nl-agent-permission-policy-new :mode 'off)
               registry "model.improvement.curate"
               (list :record-id record-id))
              :status)
             'error)))
      (should (= prepared 0))
      (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                 0)))))

(ert-deftest nl-agent-curation-supervised-tools-dedup-binds-kind ()
  (let* ((source (make-string 64 ?a))
         (payload '(:examples [(:prompt "Q:" :completion "A")]
                    :lr 0.2 :epochs 2))
         (legacy-id
          (nl-agent-curation-tools--submission-id source "policy" payload))
         (supervised-id
          (nl-agent-curation-tools--submission-id
           source "policy" payload "supervised-finetune"))
         (same-supervised
          (nl-agent-curation-tools--submission-id
           source "policy" payload "supervised-finetune")))
    (should (not (equal legacy-id supervised-id)))
    (should (equal supervised-id same-supervised))))

(ert-deftest nl-agent-curation-supervised-tools-dedups-identical-record ()
  (nl-agent-curation-supervised-tools-test--with-store directory
    (let* ((queue
            (nl-agent-curation-supervised-tools-test--queue
             "ascii-char-v1" t))
           (registry
            (nl-agent-curation-supervised-tools-test--register
             queue directory))
           (record-id
            (nl-agent-curation-supervised-tools-test--record directory))
           (policy (nl-agent-permission-policy-new :mode 'off))
           (arguments (list :record-id record-id))
           (first
            (nl-agent-permission-call
             policy registry "model.improvement.curate" arguments))
           (second
            (nl-agent-permission-call
             policy registry "model.improvement.curate" arguments))
           (first-job (plist-get first :value))
           (second-job (plist-get second :value))
           (job (nl-agent-curation-supervised-tools-test--job queue)))
      (should (eq (plist-get first :status) 'ok))
      (should (eq (plist-get second :status) 'ok))
      (should (equal (plist-get first-job :id)
                     (plist-get second-job :id)))
      (should (equal (plist-get first-job :id)
                     (plist-get job :id)))
      (should (equal (plist-get job :kind) "supervised-finetune"))
      (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                 1)))))

(provide 'curation-supervised-tools-test)

(ert-run-tests-batch-and-exit)

;;; curation-supervised-tools-test.el ends here
