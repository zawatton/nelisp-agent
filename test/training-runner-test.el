;;; training-runner-test.el --- real background runner smoke test -*- lexical-binding: t; -*-
(require 'ert)
(require 'nl-agent-training-runner)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-improve)

(defun nl-agent-training-runner-test--fixture ()
  "Return a temporary runner fixture plist."
  (let* ((tmp (make-temp-file "nl-training-runner-" t))
         (catalog (expand-file-name "catalog.json" tmp))
         (checkpoint (expand-file-name "queue.sexp" tmp))
         (model (nl-llm-agent-improve-model 2 2 nl-llm-agent-char-vocab 1 1))
         (grammar '(:type "done" :length 4 :allow "ab "))
         (score (lambda (m)
                  (let* ((x (mapcar #'nl-llm-agent--char->id
                                    (append " a" nil)))
                         (loss (nl-llm-agent--p5-forward
                                m (butlast x) (apply #'vector (cdr x)))))
                    (- (aref (photon-tensor-data (pav-value loss)) 0)))))
         queue runner)
    (nl-llm-agent-artifact-publish
     catalog (nl-llm-agent-artifact-export-pav model)
     :id "base-g0" :name "base" :grammar grammar :maxseq 4096
     :score (funcall score model) :generation 0)
    (setq queue (nl-llm-agent-evolve-p5-queue
                 model score catalog grammar
                 :id-prefix "bg" :max-pending 8 :min-delta 0.0))
    (setf (nl-llm-evolve-queue-checkpoint-file queue) checkpoint)
    (nl-llm-evolve-queue-submit
     queue "trajectory-finetune"
     '(:examples [" a"] :lr 0.1 :epochs 1) :id "pending-job")
    (setq runner
          (nl-agent-training-runner-new
           queue (list :scope (make-string 64 ?0) :benchmark [" a"]
                       :training '(:backend cpu :sequence 8 :optimizer sgd)
                       :directory tmp :catalog-file catalog)))
    (list :tmp tmp :catalog catalog :checkpoint checkpoint :model model
          :queue queue :runner runner)))

(defun nl-agent-training-runner-test--result (runner &optional attempt hash)
  "Return a valid result for RUNNER, optionally overriding ATTEMPT or HASH."
  (list :format nl-agent-training-result-format
        :attempt (or attempt
                     (plist-get (nl-agent-training-runner-request runner)
                                :attempt))
        :request-sha256 (or hash
                            (nl-agent-training-runner-request-sha256 runner))
        :score (plist-get (nl-agent-training-runner-request runner)
                          :parent-score)
        :model (plist-get (nl-agent-training-runner-request runner)
                          :parent-model)))

(defun nl-agent-training-runner-test--quiet-process (&rest _arguments)
  "Return a live inert child suitable for deterministic runner tests."
  (make-process :name "nl-training-test-child" :buffer nil :noquery t
                :command (list shell-file-name shell-command-switch "sleep 30")))

(defun nl-agent-training-runner-test--exited-process (&rest _arguments)
  "Return a child that has already failed."
  (let ((process
         (make-process :name "nl-training-test-exited" :buffer nil :noquery t
                       :command (list shell-file-name shell-command-switch
                                      "exit 1"))))
    (while (process-live-p process)
      (accept-process-output process 0.01))
    process))

(defun nl-agent-training-runner-test--successful-process (&rest _arguments)
  "Return a child that exits successfully after result setup can complete."
  (make-process :name "nl-training-test-success" :buffer nil :noquery t
                :command (list shell-file-name shell-command-switch
                               "sleep 0.05; exit 0")))

(defun nl-agent-training-runner-test--finish-process-for-poll (runner)
  "Wait for RUNNER's child without invoking its installed sentinel."
  (let ((process (nl-agent-training-runner-process runner)))
    (set-process-sentinel process #'ignore)
    (while (process-live-p process)
      (accept-process-output process 0.05))))

(ert-deftest nl-agent-training-runner-real-child-publication ()
  (let* ((fixture (nl-agent-training-runner-test--fixture))
         (tmp (plist-get fixture :tmp))
         (catalog (plist-get fixture :catalog))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner)))
    (unwind-protect
        (progn
          (let ((running (nl-agent-training-runner-start runner)))
            (should (eq (plist-get running :status) 'running)))
          (nl-llm-evolve-queue-submit queue "trajectory-finetune"
                                      '(:examples [" a"] :lr 0.1 :epochs 4) :id "pending-after-start")
          (let ((deadline (+ (float-time) 10.0)))
            (while (and (< (float-time) deadline)
                        (nl-agent-training-runner-process runner))
              (accept-process-output (nl-agent-training-runner-process runner) 0.1)
              (nl-agent-training-runner-poll runner)))
          (nl-agent-training-runner-poll runner)
          (let ((status (nl-agent-training-runner-status runner)))
            (should (= 1 (plist-get status :generation)))
            (should (>= (plist-get status :pending) 1))
            (should (file-regular-p catalog))))
      (ignore-errors (nl-agent-training-runner-stop runner))
      (delete-directory tmp t))))

(ert-deftest nl-agent-training-runner-start-process-failure-fails-claim ()
  (let* ((fixture (nl-agent-training-runner-test--fixture))
         (tmp (plist-get fixture :tmp))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'start-process)
                     (lambda (&rest _arguments) (error "mock spawn failure"))))
            (should-error (nl-agent-training-runner-start runner)))
          (let ((job (nl-llm-evolve-queue--job queue "pending-job")))
            (should (eq (nl-llm-evolve-queue-job-status job) 'error)))
          (should-not (nl-agent-training-runner-process runner))
          (should-not (nl-agent-training-runner-claim runner))
          (should-not (nl-agent-training-runner-workdir runner)))
      (ignore-errors (nl-agent-training-runner-stop runner))
      (delete-directory tmp t))))

(ert-deftest nl-agent-training-runner-repeated-poll-does-not-double-promote ()
  (let* ((fixture (nl-agent-training-runner-test--fixture))
         (tmp (plist-get fixture :tmp))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner))
         (calls 0)
         (complete (symbol-function 'nl-llm-evolve-queue-complete)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'start-process)
                     #'nl-agent-training-runner-test--successful-process))
            (nl-agent-training-runner-start runner))
          (nl-agent-training-protocol-write
           (nl-agent-training-runner-result-file runner)
           (nl-agent-training-runner-test--result runner))
          (nl-agent-training-runner-test--finish-process-for-poll runner)
          (cl-letf (((symbol-function 'nl-llm-evolve-queue-complete)
                     (lambda (&rest arguments)
                       (setq calls (1+ calls))
                       (apply complete arguments))))
            (nl-agent-training-runner-poll runner)
            (nl-agent-training-runner-poll runner))
          (should (= calls 1))
          (should (= (nl-llm-evolution-attempts
                      (nl-llm-evolve-queue-evolution queue))
                     1)))
      (ignore-errors (nl-agent-training-runner-stop runner))
      (delete-directory tmp t))))

(ert-deftest nl-agent-training-runner-immediate-exit-finalizes-once-with-trim ()
  (let* ((fixture (nl-agent-training-runner-test--fixture))
         (tmp (plist-get fixture :tmp))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner))
         (calls 0)
         (fail (symbol-function 'nl-llm-evolve-queue-fail)))
    (unwind-protect
        (progn
          (setf (nl-llm-evolve-queue-max-history queue) 0)
          (cl-letf (((symbol-function 'start-process)
                     #'nl-agent-training-runner-test--exited-process)
                    ((symbol-function 'nl-llm-evolve-queue-fail)
                     (lambda (&rest arguments)
                       (setq calls (1+ calls))
                       (apply fail arguments))))
            (let ((job (nl-agent-training-runner-start runner)))
              (should (eq (plist-get job :status) 'running)))
            (nl-agent-training-runner-poll runner))
          (should (= calls 1))
          (should-not (nl-agent-training-runner-process runner))
          (should-not (nl-llm-evolve-queue-jobs queue)))
      (ignore-errors (nl-agent-training-runner-stop runner))
      (delete-directory tmp t))))

(ert-deftest nl-agent-training-runner-start-after-stop-is-rejected ()
  (let* ((fixture (nl-agent-training-runner-test--fixture))
         (tmp (plist-get fixture :tmp))
         (runner (plist-get fixture :runner)))
    (unwind-protect
        (progn
          (nl-agent-training-runner-stop runner)
          (should-error (nl-agent-training-runner-start runner)))
      (ignore-errors (nl-agent-training-runner-stop runner))
      (delete-directory tmp t))))

(ert-deftest nl-agent-training-runner-stop-live-child-interrupts-without-publish ()
  (let* ((fixture (nl-agent-training-runner-test--fixture))
         (tmp (plist-get fixture :tmp))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner))
         workdir)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'start-process)
                     #'nl-agent-training-runner-test--quiet-process))
            (nl-agent-training-runner-start runner))
          (setq workdir (nl-agent-training-runner-workdir runner))
          (nl-agent-training-protocol-write
           (nl-agent-training-runner-result-file runner)
           (nl-agent-training-runner-test--result runner))
          (nl-agent-training-runner-stop runner)
          (should (eq (nl-llm-evolve-queue-job-status
                       (nl-llm-evolve-queue--job queue "pending-job"))
                      'interrupted))
          (should (= (nl-llm-evolution-generation
                      (nl-llm-evolve-queue-evolution queue))
                     0))
          (should (file-directory-p workdir)))
      (ignore-errors (nl-agent-training-runner-stop runner))
      (delete-directory tmp t))))

(ert-deftest nl-agent-training-runner-rejects-result-attempt-tamper ()
  (nl-agent-training-runner-test--reject-tampered-result
   "wrong-attempt" nil))

(ert-deftest nl-agent-training-runner-rejects-result-hash-tamper ()
  (nl-agent-training-runner-test--reject-tampered-result
   nil (make-string 64 ?f)))

(defun nl-agent-training-runner-test--reject-tampered-result (attempt hash)
  "Assert a result tampered with ATTEMPT or HASH is rejected."
  (let* ((fixture (nl-agent-training-runner-test--fixture))
         (tmp (plist-get fixture :tmp))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'start-process)
                     #'nl-agent-training-runner-test--successful-process))
            (nl-agent-training-runner-start runner))
          (nl-agent-training-protocol-write
           (nl-agent-training-runner-result-file runner)
           (nl-agent-training-runner-test--result runner attempt hash))
          (nl-agent-training-runner-test--finish-process-for-poll runner)
          (nl-agent-training-runner-poll runner)
          (should (eq (nl-llm-evolve-queue-job-status
                       (nl-llm-evolve-queue--job queue "pending-job"))
                      'error))
          (should (= (nl-llm-evolution-generation
                      (nl-llm-evolve-queue-evolution queue))
                     0)))
      (ignore-errors (nl-agent-training-runner-stop runner))
      (delete-directory tmp t))))

(ert-deftest nl-agent-training-runner-terminal-persistence-failure-retains-snapshot ()
  (let* ((fixture (nl-agent-training-runner-test--fixture))
         (tmp (plist-get fixture :tmp))
         (queue (plist-get fixture :queue))
         (runner (plist-get fixture :runner))
         workdir)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'start-process)
                     #'nl-agent-training-runner-test--successful-process))
            (nl-agent-training-runner-start runner))
          (setq workdir (nl-agent-training-runner-workdir runner))
          (nl-agent-training-protocol-write
           (nl-agent-training-runner-result-file runner)
           (nl-agent-training-runner-test--result runner))
          (nl-agent-training-runner-test--finish-process-for-poll runner)
          (cl-letf (((symbol-function 'nl-llm-evolve-queue-save)
                     (lambda (&rest _arguments)
                       (error "mock terminal persistence failure"))))
            (nl-agent-training-runner-poll runner))
          (let* ((job (nl-llm-evolve-queue--job queue "pending-job"))
                 (result (nl-llm-evolve-queue-job-result job)))
            (should (memq (nl-llm-evolve-queue-job-status job)
                          '(promoted rejected)))
            (should (plist-member result :persistence-error)))
          (should (equal (nl-agent-training-runner-workdir runner) workdir))
          (should (file-regular-p
                   (nl-agent-training-runner-request-file runner)))
          (should (file-regular-p
                   (nl-agent-training-runner-result-file runner))))
      (ignore-errors (nl-agent-training-runner-stop runner))
      (delete-directory tmp t))))

(provide 'training-runner-test)

(ert-run-tests-batch-and-exit)
