;;; training-supervised-runner-test.el --- supervised runner integration -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'nl-agent-training-runner)
(require 'nl-agent-training-protocol)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-improve)
(require 'nl-llm-agent-supervised-evolve)

(defun nl-agent-training-supervised-runner-test--fixture
    (&optional backend checkpoint-every recovery optimizer)
  "Return a small durable queue and runner for a supervised child.
When CHECKPOINT-EVERY and RECOVERY are supplied, use the durable GPU profile."
  (setq backend (or backend 'cpu)
        optimizer (or optimizer 'sgd))
  (let* ((tmp (make-temp-file "nl-supervised-runner-" t))
         (catalog (expand-file-name "catalog.json" tmp))
         (checkpoint (expand-file-name "queue.sexp" tmp))
         (model (nl-llm-agent-improve-model
                 4 4 nl-llm-agent-char-vocab 1 1))
         (grammar '(:type "done" :length 4 :allow "ab "))
         (benchmark ["ab"])
         (score (nl-llm-agent-evolve-p5-evaluator benchmark))
         queue runner)
    (nl-llm-agent-artifact-publish
     catalog (nl-llm-agent-artifact-export-pav model)
     :id "base-g0" :name "base" :grammar grammar :maxseq 4096
     :score (funcall score model) :generation 0)
    (setq queue
          (nl-llm-agent-evolve-p5-queue
           model score catalog grammar :id-prefix "supervised"
           :max-pending 8 :min-delta 0.0))
    (setf (nl-llm-evolve-queue-checkpoint-file queue) checkpoint)
    (nl-llm-agent-supervised-evolve-register
     queue :training-backend backend :training-sequence 8 :optimizer optimizer)
    (nl-llm-evolve-queue-submit
     queue "supervised-finetune"
     '(:examples [(:prompt "a" :completion "bb")] :lr 0.1 :epochs 4)
     :id "supervised-child")
    (setq runner
          (nl-agent-training-runner-new
           queue
           (list :scope (make-string 64 ?0)
                 :benchmark benchmark
                 :training (append (list :backend backend :sequence 8
                                         :optimizer optimizer)
                                   (when checkpoint-every
                                     (list :checkpoint-every checkpoint-every)))
                 :directory tmp :catalog-file catalog
                 :recovery-directory recovery)))
    (list :tmp tmp :catalog catalog :queue queue :runner runner)))

(defun nl-agent-training-supervised-runner-test--cleanup (fixture)
  "Stop the runner in FIXTURE and remove its private test files."
  (let ((runner (plist-get fixture :runner))
        (tmp (plist-get fixture :tmp)))
    (ignore-errors (nl-agent-training-runner-stop runner))
    (when (file-directory-p tmp)
      (delete-directory tmp t))))

(ert-deftest nl-agent-training-runner-supervised-real-child-publishes-and-propagates-kind ()
  (let* ((fixture (nl-agent-training-supervised-runner-test--fixture))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner)))
    (unwind-protect
        (progn
          (let ((running (nl-agent-training-runner-start runner)))
            (should (eq (plist-get running :status) 'running))
            (should (equal (plist-get
                            (nl-agent-training-runner-request runner) :kind)
                           "supervised-finetune")))
          (let ((deadline (+ (float-time) 20.0)))
            (while (and (< (float-time) deadline)
                        (nl-agent-training-runner-process runner))
              (accept-process-output
               (nl-agent-training-runner-process runner) 0.1)
              (nl-agent-training-runner-poll runner)))
          (nl-agent-training-runner-poll runner)
          (let ((status (nl-agent-training-runner-status runner)))
            (should (= (plist-get status :generation) 1))
            (should (= (plist-get status :pending) 0))
            (should-not (nl-agent-training-runner-process runner))
            (should-not (nl-agent-training-runner-claim runner))
            (should (eq (nl-llm-evolve-queue-job-status
                         (nl-llm-evolve-queue--job queue "supervised-child"))
                        'promoted))
            (should (= (length
                        (nl-llm-agent-artifact-catalog
                         (plist-get fixture :catalog)))
                       2))))
      (nl-agent-training-supervised-runner-test--cleanup fixture))))

(ert-deftest nl-agent-training-runner-supervised-checkpoint-profile-leaves-pending ()
  (let* ((fixture (nl-agent-training-supervised-runner-test--fixture))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner))
         (profile (copy-tree (nl-agent-training-runner-profile runner))))
    (unwind-protect
        (progn
          (setf (plist-get profile :training)
                '(:backend cpu :sequence 8 :optimizer sgd :checkpoint-every 1))
          (setf (nl-agent-training-runner-profile runner) profile)
          (should-error (nl-agent-training-runner-start runner))
          (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                     1))
          (should (eq (nl-llm-evolve-queue-job-status
                       (nl-llm-evolve-queue--job queue "supervised-child"))
                      'pending)))
      (nl-agent-training-supervised-runner-test--cleanup fixture))))

(ert-deftest nl-agent-training-runner-supervised-valid-gpu-checkpoint-preclaims ()
  "A trusted GPU cadence/recovery profile reaches claim without GPU I/O here."
  (let* ((recovery (make-temp-file "nl-supervised-recovery-" t))
         (fixture
          (nl-agent-training-supervised-runner-test--fixture
           'gpu 1 recovery 'sgd))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner)))
    (unwind-protect
        (cl-letf (((symbol-function 'start-process)
                   (lambda (&rest _arguments)
                     (make-process
                      :name "nl-supervised-runner-test-child" :buffer nil
                      :noquery t :command
                      (list shell-file-name shell-command-switch "sleep 30")))))
          (let ((job (nl-agent-training-runner-start runner)))
            (should (eq (plist-get job :status) 'running))
            (should (equal (plist-get
                            (nl-agent-training-runner-request runner) :kind)
                           "supervised-finetune"))
            (should (eq (nl-llm-evolve-queue-job-status
                         (nl-llm-evolve-queue--job queue "supervised-child"))
                        'running)))
          (nl-agent-training-runner-stop runner)
          (should (eq (nl-llm-evolve-queue-job-status
                       (nl-llm-evolve-queue--job queue "supervised-child"))
                      'interrupted)))
      (nl-agent-training-supervised-runner-test--cleanup fixture)
      (when (file-directory-p recovery) (delete-directory recovery t)))))

(ert-deftest nl-agent-training-runner-supervised-invalid-cadence-leaves-pending ()
  "Cadence outside the protocol bound is rejected before queue claim."
  (let* ((recovery (make-temp-file "nl-supervised-invalid-recovery-" t))
         (fixture
          (nl-agent-training-supervised-runner-test--fixture
           'gpu 1 recovery 'sgd))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner))
         (profile (copy-tree (nl-agent-training-runner-profile runner))))
    (unwind-protect
        (progn
          (setf (plist-get profile :training)
                '(:backend gpu :sequence 8 :optimizer sgd
                  :checkpoint-every 1000001))
          (setf (nl-agent-training-runner-profile runner) profile)
          (should-error (nl-agent-training-runner-start runner))
          (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                     1))
          (should (eq (nl-llm-evolve-queue-job-status
                       (nl-llm-evolve-queue--job queue "supervised-child"))
                      'pending))
          (should-not (nl-agent-training-runner-claim runner)))
      (nl-agent-training-supervised-runner-test--cleanup fixture)
      (when (file-directory-p recovery) (delete-directory recovery t)))))

(ert-deftest nl-agent-training-runner-supervised-resume-preview-preserves-kind ()
  "The preclaim resume preview must retain the queue's supervised kind."
  (let* ((recovery (make-temp-file "nl-supervised-preview-recovery-" t))
         (fixture
          (nl-agent-training-supervised-runner-test--fixture
           'gpu 1 recovery 'sgd))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner))
         (job (nl-llm-evolve-queue--job queue "supervised-child"))
         (seen nil))
    (unwind-protect
        (progn
          (setf (nl-llm-evolve-queue-job-status job) 'interrupted)
          (cl-letf (((symbol-function 'nl-agent-training-recovery-load)
                     (lambda (&rest _args)
                       (list :request '(:placeholder t)
                             :request-sha256 (make-string 64 ?0)
                             :checkpoint
                             '(:attempt "attempt" :state (:placeholder t)))))
                    ((symbol-function 'nl-agent-training-runner--request-value)
                     (lambda (_runner claim &optional _state)
                       (setq seen (copy-tree claim t))
                       '(:preview t)))
                    ((symbol-function 'nl-agent-training-protocol-validate-request)
                     (lambda (request) request))
                    ((symbol-function 'nl-agent-training-protocol-validate-checkpoint)
                     (lambda (&rest args) (car (last args))))
                    ((symbol-function 'nl-agent-training-protocol-validate-resume-state)
                     (lambda (state _request) state)))
            (nl-agent-training-runner--resume-receipt runner
                                                     "supervised-child"))
          (should (equal (plist-get seen :kind) "supervised-finetune")))
      (nl-agent-training-supervised-runner-test--cleanup fixture)
      (when (file-directory-p recovery) (delete-directory recovery t)))))

(ert-deftest nl-agent-training-runner-supervised-resume-leaves-interrupted ()
  (let* ((fixture (nl-agent-training-supervised-runner-test--fixture))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner))
         (job (nl-llm-evolve-queue--job queue "supervised-child")))
    (unwind-protect
        (progn
          (setf (nl-llm-evolve-queue-job-status job) 'interrupted)
          (should-error
           (nl-agent-training-runner-start runner "supervised-child" t))
          (should (eq (nl-llm-evolve-queue-job-status job) 'interrupted))
          (should-not (nl-agent-training-runner-claim runner)))
      (nl-agent-training-supervised-runner-test--cleanup fixture))))

(ert-deftest nl-agent-training-runner-supervised-sequence-mismatch-leaves-pending ()
  (let* ((fixture (nl-agent-training-supervised-runner-test--fixture))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner))
         (profile (copy-tree (nl-agent-training-runner-profile runner))))
    (unwind-protect
        (progn
          ;; The encoded pair is three tokens; a fixed two-token profile must
          ;; fail in the preclaim payload check, without a GPU or queue claim.
          (setf (plist-get profile :training)
                '(:backend gpu :sequence 2 :optimizer adam))
          (setf (nl-agent-training-runner-profile runner) profile)
          (should-error (nl-agent-training-runner-start runner))
          (should (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                     1))
          (should-not (nl-agent-training-runner-claim runner)))
      (nl-agent-training-supervised-runner-test--cleanup fixture))))

(provide 'training-supervised-runner-test)

(ert-run-tests-batch-and-exit)

;;; training-supervised-runner-test.el ends here
