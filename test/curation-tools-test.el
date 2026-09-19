;;; curation-tools-test.el --- guarded curation submission tests -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-llm/lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-photon/lisp"))
(require 'ert)
(require 'cl-lib)
(require 'nl-agent-curation-tools)
(require 'nl-agent-permission)
(require 'nl-agent-autonomy)

(defun nl-agent-curation-tools-test--queue ()
  "Return (QUEUE . COUNTERS) with a trajectory handler.
COUNTERS holds evaluator calls at index zero and train calls at index one."
  (let* ((counters (vector 0 0))
         (evolution
          (nl-llm-evolution-new
           '(:fitness 1.0)
           (lambda (model)
             (aset counters 0 (1+ (aref counters 0)))
             (plist-get model :fitness))
           :clone #'copy-tree))
         (queue (nl-llm-evolve-queue-new evolution)))
    (nl-llm-evolve-queue-register
     queue "trajectory-finetune"
     (lambda (_candidate _payload _state) nil)
     :train
     (lambda (_candidate _payload _state)
       (aset counters 1 (1+ (aref counters 1))))
     :validate
     (lambda (payload)
       (unless (and (vectorp (plist-get payload :examples))
                    (numberp (plist-get payload :lr))
                    (integerp (plist-get payload :epochs)))
         (error "invalid trajectory fine-tune payload")))
     :description "Fine-tune curated trajectories")
    (cons queue counters)))

(defun nl-agent-curation-tools-test--curator (directory)
  "Return a trusted curator rooted at DIRECTORY."
  (nl-agent-curation-new
   directory
   (lambda (_record) '(:accepted t :reason "approved"))
   "policy-v1" :data-use-approved t))

(defun nl-agent-curation-tools-test--prepared ()
  "Return one detached prepared curation value."
  (list
   :payload '(:examples ["task transcript"] :lr 0.05 :epochs 1)
   :metadata
   (list :source-sha256 (make-string 64 ?a)
         :policy-id "policy-v1"
         :evidence '(:accepted t :reason "approved")
         :renderer-version "nl-agent-curation-role-v1"
         :tokenizer "ascii-char-v1")))

(defun nl-agent-curation-tools-test--snapshot-job (queue id)
  "Return retained snapshot job ID from QUEUE."
  (cl-find-if
   (lambda (job) (equal (plist-get job :id) id))
   (append (plist-get (nl-llm-evolve-queue-snapshot queue) :jobs) nil)))

(ert-deftest nl-agent-curation-tool-is-write-risk-and-narrowly-scoped ()
  (let* ((directory (make-temp-file "nl-agent-curation-tool-" t))
         (pair (nl-agent-curation-tools-test--queue))
         (queue (car pair))
         (registry (nl-agent-tool-registry-new)))
    (unwind-protect
        (progn
          (nl-agent-curation-register-tools
           registry queue
           (nl-agent-curation-tools-test--curator directory))
          (let* ((descriptor (car (nl-agent-tool-catalog registry)))
                 (schema
                  (plist-get (plist-get descriptor :metadata) :input-schema)))
            (should (equal (plist-get descriptor :name)
                           "model.improvement.curate"))
            (should (eq (plist-get descriptor :risk) 'write))
            (should (equal schema nl-agent-curation-tool-schema))
            (should (eq (plist-get schema :additionalProperties) nil)))
          (should
           (eq
            (funcall
             (nl-agent-autonomy-improvement-approval "native" "self")
             '(:tool "model.improvement.curate"
               :args (:record-id "record")))
            'deny)))
      (delete-directory directory t))))

(ert-deftest nl-agent-curation-tool-rejects-mismatched-tokenizer-context ()
  (let* ((directory (make-temp-file "nl-agent-curation-tokenizer-" t))
         (pair (nl-agent-curation-tools-test--queue))
         (queue (car pair))
         (evaluations 0)
         (curator
          (nl-agent-curation-new
           directory
           (lambda (_record)
             (setq evaluations (1+ evaluations))
             '(:accepted t :reason "accepted"))
           "utf8-policy" :data-use-approved t
           :tokenizer "utf8-byte-v1")))
    (unwind-protect
        (progn
          ;; Even an ASCII-only record cannot make UTF-8 provenance coherent
          ;; with this legacy ASCII queue.
          (nl-agent-trajectory-save
           directory "ascii task"
           '(:kind agent-run :status done :steps 1 :result "done"
             :messages ((user . "ascii task") (assistant . "DONE done"))
             :trajectory
             ((:step 1 :model "remote/model" :assistant "DONE done"
               :action (done "done")))))
          (should-error
           (nl-agent-curation-register-tools
            (nl-agent-tool-registry-new) queue curator))
          (should (= evaluations 0))
          (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                     0)))
      (delete-directory directory t))))

(ert-deftest nl-agent-curation-tool-denial-does-not-prepare-or-mutate-queue ()
  (let* ((directory (make-temp-file "nl-agent-curation-denied-" t))
         (pair (nl-agent-curation-tools-test--queue))
         (queue (car pair))
         (counters (cdr pair))
         (registry (nl-agent-tool-registry-new))
         (policy (nl-agent-permission-policy-new :mode 'smart))
         (prepared 0))
    (unwind-protect
        (progn
          (nl-agent-curation-register-tools
           registry queue
           (nl-agent-curation-tools-test--curator directory))
          (cl-letf (((symbol-function 'nl-agent-curation-prepare)
                     (lambda (&rest _args)
                       (setq prepared (1+ prepared))
                       (nl-agent-curation-tools-test--prepared))))
            (let ((result
                   (nl-agent-permission-call
                    policy registry "model.improvement.curate"
                    '(:record-id "record"))))
              (should (eq (plist-get result :status) 'denied))))
          (should (= prepared 0))
          (should (= (aref counters 0) 1))
          (should (= (aref counters 1) 0))
          (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                     0)))
      (delete-directory directory t))))

(ert-deftest nl-agent-curation-tool-rejects-injected-fields-before-prepare ()
  (let* ((directory (make-temp-file "nl-agent-curation-args-" t))
         (queue (car (nl-agent-curation-tools-test--queue)))
         (registry (nl-agent-tool-registry-new))
         (policy (nl-agent-permission-policy-new :mode 'off))
         (prepared 0))
    (unwind-protect
        (progn
          (nl-agent-curation-register-tools
           registry queue
           (nl-agent-curation-tools-test--curator directory))
          (dolist (args
                   '((:record-id "record" :path "/tmp/escape")
                     (:record-id "record" :evaluator "replace")
                     (:record-id "record" :reward 1.0)
                     (:record-id "record" :metadata (:trusted t))
                     (:record-id "record" :lr 1.0)
                     (:record-id "")))
            (cl-letf (((symbol-function 'nl-agent-curation-prepare)
                       (lambda (&rest _args)
                         (setq prepared (1+ prepared)))))
              (should
               (eq
                (plist-get
                 (nl-agent-permission-call
                  policy registry "model.improvement.curate" args)
                 :status)
                'error))))
          (should (= prepared 0))
          (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                     0)))
      (delete-directory directory t))))

(ert-deftest nl-agent-curation-tool-submits-immutable-pending-provenance ()
  (let* ((directory (make-temp-file "nl-agent-curation-submit-" t))
         (pair (nl-agent-curation-tools-test--queue))
         (queue (car pair))
         (counters (cdr pair))
         (registry (nl-agent-tool-registry-new))
         (policy (nl-agent-permission-policy-new :mode 'off))
         (prepared (nl-agent-curation-tools-test--prepared)))
    (unwind-protect
        (progn
          (nl-agent-curation-register-tools
           registry queue
           (nl-agent-curation-tools-test--curator directory))
          (cl-letf (((symbol-function 'nl-agent-curation-prepare)
                     (lambda (&rest _args) prepared)))
            (let* ((result
                    (nl-agent-permission-call
                     policy registry "model.improvement.curate"
                     '(:record-id "record")))
                   (public (plist-get result :value))
                   (id (plist-get public :id))
                   (job (nl-agent-curation-tools-test--snapshot-job queue id)))
              (should (eq (plist-get result :status) 'ok))
              (should (string-match-p "\\`curated-[a-f0-9]\\{64\\}\\'" id))
              (should (eq (plist-get public :status) 'pending))
              (aset (plist-get (plist-get prepared :payload) :examples)
                    0 "mutated")
              (setf (plist-get
                     (plist-get (plist-get prepared :metadata) :evidence)
                     :reason)
                    "mutated")
              (should
               (equal (aref (plist-get (plist-get job :payload) :examples) 0)
                      "task transcript"))
              (should
               (equal
                (plist-get
                 (plist-get (plist-get job :metadata) :evidence) :reason)
                "approved"))))
          (should (= (aref counters 0) 1))
          (should (= (aref counters 1) 0))
          (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                     1)))
      (delete-directory directory t))))

(ert-deftest nl-agent-curation-tool-rejection-leaves-no-job ()
  (let* ((directory (make-temp-file "nl-agent-curation-reject-" t))
         (queue (car (nl-agent-curation-tools-test--queue)))
         (registry (nl-agent-tool-registry-new))
         (policy (nl-agent-permission-policy-new :mode 'off))
         (record-id
          (file-name-nondirectory
           (nl-agent-trajectory-save
            directory "rejected task"
            (list
             :kind 'agent-run :status 'done :steps 1 :result "claim"
             :messages '((user . "private"))
             :trajectory
             (list
              (list :step 1 :model "native/base"
                    :assistant "DONE claim"
                    :action '(done "claim"))))))))
    (unwind-protect
        (progn
          (nl-agent-curation-register-tools
           registry queue
           (nl-agent-curation-new
            directory
            (lambda (_record)
              '(:accepted nil :reason "host evaluator rejected"))
            "policy/reject" :data-use-approved t))
          (should
           (eq
            (plist-get
             (nl-agent-permission-call
              policy registry "model.improvement.curate"
              (list :record-id record-id))
             :status)
            'error))
          (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                     0)))
      (delete-directory directory t))))

(ert-deftest nl-agent-curation-tool-is-idempotent-only-for-exact-retained-job ()
  (let* ((directory (make-temp-file "nl-agent-curation-repeat-" t))
         (queue (car (nl-agent-curation-tools-test--queue)))
         (registry (nl-agent-tool-registry-new))
         (policy (nl-agent-permission-policy-new :mode 'off))
         (prepared (nl-agent-curation-tools-test--prepared)))
    (unwind-protect
        (progn
          (nl-agent-curation-register-tools
           registry queue
           (nl-agent-curation-tools-test--curator directory))
          (cl-letf (((symbol-function 'nl-agent-curation-prepare)
                     (lambda (&rest _args) prepared)))
            (let* ((first
                    (nl-agent-permission-call
                     policy registry "model.improvement.curate"
                     '(:record-id "same")))
                   (second
                    (nl-agent-permission-call
                     policy registry "model.improvement.curate"
                     '(:record-id "same"))))
              (should (eq (plist-get first :status) 'ok))
              (should (eq (plist-get second :status) 'ok))
              (should (equal (plist-get (plist-get first :value) :id)
                             (plist-get (plist-get second :value) :id)))
              (should
               (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                  1)))))
      (delete-directory directory t))))

(ert-deftest nl-agent-curation-tool-deterministic-id-conflict-fails-closed ()
  (let* ((directory (make-temp-file "nl-agent-curation-conflict-" t))
         (queue (car (nl-agent-curation-tools-test--queue)))
         (registry (nl-agent-tool-registry-new))
         (policy (nl-agent-permission-policy-new :mode 'off))
         (prepared (nl-agent-curation-tools-test--prepared))
         (payload (plist-get prepared :payload))
         (metadata (plist-get prepared :metadata))
         (id
          (nl-agent-curation-tools--submission-id
           (plist-get metadata :source-sha256)
           (plist-get metadata :policy-id) payload)))
    (unwind-protect
        (progn
          (nl-agent-curation-register-tools
           registry queue
           (nl-agent-curation-tools-test--curator directory))
          (nl-llm-evolve-queue-submit
           queue "trajectory-finetune"
           '(:examples ["different"] :lr 0.05 :epochs 1)
           :id id :metadata metadata)
          (cl-letf (((symbol-function 'nl-agent-curation-prepare)
                     (lambda (&rest _args) prepared)))
            (should
             (eq
              (plist-get
               (nl-agent-permission-call
                policy registry "model.improvement.curate"
                '(:record-id "collision"))
               :status)
              'error)))
          (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                     1)))
      (delete-directory directory t))))

(provide 'curation-tools-test)

(ert-run-tests-batch-and-exit)

;;; curation-tools-test.el ends here
