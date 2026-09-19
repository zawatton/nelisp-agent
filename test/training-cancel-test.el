;;; training-cancel-test.el --- bounded live training cancellation tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'nl-agent-training-runner)
(require 'nl-agent-improvement)
(require 'nl-agent-permission)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-improve)

(defun training-cancel--fixture ()
  "Return a durable background training fixture."
  (let* ((directory (make-temp-file "training-cancel-" t))
         (catalog (expand-file-name "catalog.json" directory))
         (checkpoint (expand-file-name "queue.sexp" directory))
         (model (nl-llm-agent-improve-model
                 2 2 nl-llm-agent-char-vocab 1 1))
         (grammar '(:type "done" :length 4 :allow "ab "))
         (score (lambda (candidate)
                  (let* ((x (mapcar #'nl-llm-agent--char->id
                                    (append " a" nil)))
                         (loss (nl-llm-agent--p5-forward
                                candidate (butlast x)
                                (apply #'vector (cdr x)))))
                    (- (aref (photon-tensor-data (pav-value loss)) 0)))))
         queue runner)
    (nl-llm-agent-artifact-publish
     catalog (nl-llm-agent-artifact-export-pav model)
     :id "base-g0" :name "base" :grammar grammar :maxseq 4096
     :score (funcall score model) :generation 0)
    (setq queue (nl-llm-agent-evolve-p5-queue
                 model score catalog grammar
                 :id-prefix "cancel" :max-pending 8 :min-delta 0.0))
    (setf (nl-llm-evolve-queue-checkpoint-file queue) checkpoint)
    (setq runner
          (nl-agent-training-runner-new
           queue (list :scope (make-string 64 ?0) :benchmark [" a"]
                       :training '(:backend cpu :sequence 8 :optimizer sgd)
                       :directory directory :catalog-file catalog)))
    (list :directory directory :catalog catalog :checkpoint checkpoint
          :queue queue :runner runner)))

(defun training-cancel--submit (queue id &optional epochs)
  "Submit ID to QUEUE with a small CPU workload."
  (nl-llm-evolve-queue-submit
   queue "trajectory-finetune"
   (list :examples [" a"] :lr 0.1 :epochs (or epochs 1)) :id id))

(defun training-cancel--waiting-process (&rest _arguments)
  "Return a live child that waits until explicitly stopped."
  (make-process :name "training-cancel-wait" :buffer nil :noquery t
                :command (list shell-file-name shell-command-switch "sleep 30")))

(defmacro training-cancel--with-fixture (binding &rest body)
  "Bind BINDING to a fixture and clean it up after BODY."
  (declare (indent 1) (debug (symbolp body)))
  `(let* ((,binding (training-cancel--fixture))
          (directory (plist-get ,binding :directory))
          (runner (plist-get ,binding :runner)))
     (unwind-protect (progn ,@body)
       (ignore-errors (nl-agent-training-runner-stop runner))
       (delete-directory directory t))))

(ert-deftest training-cancel-live-child-is-dead-before-cancel-and-runner-reuses ()
  (training-cancel--with-fixture fixture
    (let* ((queue (plist-get fixture :queue))
           (checkpoint (plist-get fixture :checkpoint))
           (catalog (plist-get fixture :catalog))
           process late-sentinel)
      (training-cancel--submit queue "live")
      (cl-letf (((symbol-function 'start-process)
                 #'training-cancel--waiting-process))
        (nl-agent-training-runner-start runner "live"))
      (setq process (nl-agent-training-runner-process runner)
            late-sentinel (process-sentinel process))
      (should (process-live-p process))
      (should (eq (plist-get (nl-agent-training-runner-cancel runner "live")
                             :status)
                  'cancelled))
      (should-not (process-live-p process))
      (should (file-locked-p checkpoint))
      (should (file-locked-p catalog))
      (funcall late-sentinel process "late exit")
      (nl-agent-training-runner-poll runner)
      (should (= (nl-llm-evolution-generation
                  (nl-llm-evolve-queue-evolution queue))
                 0))
      (training-cancel--submit queue "next")
      (nl-agent-training-runner-start runner "next")
      (let ((deadline (+ (float-time) 15.0)))
        (while (and (nl-agent-training-runner-process runner)
                    (< (float-time) deadline))
          (accept-process-output (nl-agent-training-runner-process runner) 0.1)
          (nl-agent-training-runner-poll runner)))
      (should-not (nl-agent-training-runner-process runner))
      (should (= (nl-llm-evolution-generation
                  (nl-llm-evolve-queue-evolution queue))
                 1)))))

(ert-deftest training-cancel-unrelated-pending-does-not-stop-live-child ()
  (training-cancel--with-fixture fixture
    (let ((queue (plist-get fixture :queue)))
      (training-cancel--submit queue "active")
      (training-cancel--submit queue "other")
      (cl-letf (((symbol-function 'start-process)
                 #'training-cancel--waiting-process))
        (nl-agent-training-runner-start runner "active"))
      (let ((process (nl-agent-training-runner-process runner)))
        (should (eq (plist-get (nl-agent-training-runner-cancel runner "other")
                               :status)
                    'cancelled))
        (should (eq process (nl-agent-training-runner-process runner)))
        (should (process-live-p process)))
      (nl-agent-training-runner-cancel runner "active"))))

(ert-deftest training-cancel-permission-denial-leaves-child-alive ()
  (training-cancel--with-fixture fixture
    (let* ((queue (plist-get fixture :queue))
           (registry (nl-agent-tool-registry-new))
           (policy (nl-agent-permission-policy-new :mode 'smart)))
      (training-cancel--submit queue "denied")
      (cl-letf (((symbol-function 'start-process)
                 #'training-cancel--waiting-process))
        (nl-agent-training-runner-start runner "denied"))
      (nl-agent-improvement-register-tools registry queue runner)
      (should (eq (plist-get
                   (nl-agent-permission-call
                    policy registry "model.improvement.cancel" '(:id "denied"))
                   :status)
                  'denied))
      (should (process-live-p (nl-agent-training-runner-process runner)))
      (nl-agent-training-runner-cancel runner "denied"))))

(ert-deftest training-cancel-interrupt-save-failure-retains-and-retries ()
  (training-cancel--with-fixture fixture
    (let ((queue (plist-get fixture :queue)) workdir)
      (training-cancel--submit queue "retry-interrupt")
      (cl-letf (((symbol-function 'start-process)
                 #'training-cancel--waiting-process))
        (nl-agent-training-runner-start runner "retry-interrupt"))
      (setq workdir (nl-agent-training-runner-workdir runner))
      (cl-letf (((symbol-function 'nl-llm-evolve-queue-save)
                 (lambda (&rest _arguments) (error "injected interrupt save"))))
        (should-error
         (nl-agent-training-runner-cancel runner "retry-interrupt")))
      (should-not (nl-agent-training-runner-process runner))
      (should (nl-agent-training-runner-claim runner))
      (should (nl-agent-training-runner-cancelling runner))
      (should (file-directory-p workdir))
      (should-error (nl-agent-training-runner-start runner))
      (should (eq (plist-get
                   (nl-agent-training-runner-cancel runner "retry-interrupt")
                   :status)
                  'cancelled))
      (should-not (file-exists-p workdir)))))

(ert-deftest training-cancel-final-save-failure-retains-and-retries ()
  (training-cancel--with-fixture fixture
    (let* ((queue (plist-get fixture :queue))
           (save (symbol-function 'nl-llm-evolve-queue-save))
           workdir)
      (training-cancel--submit queue "retry-final")
      (cl-letf (((symbol-function 'start-process)
                 #'training-cancel--waiting-process))
        (nl-agent-training-runner-start runner "retry-final"))
      (setq workdir (nl-agent-training-runner-workdir runner))
      (cl-letf (((symbol-function 'nl-llm-evolve-queue-save)
                 (lambda (candidate &optional file)
                   (let ((job (nl-llm-evolve-queue--job candidate "retry-final")))
                     (if (and job (eq (nl-llm-evolve-queue-job-status job)
                                      'cancelled))
                         (error "injected final save")
                       (funcall save candidate file))))))
        (should-error (nl-agent-training-runner-cancel runner "retry-final")))
      (should-not (nl-agent-training-runner-claim runner))
      (should (nl-agent-training-runner-cancelling runner))
      (should (file-directory-p workdir))
      (should (eq (nl-llm-evolve-queue-job-status
                   (nl-llm-evolve-queue--job queue "retry-final"))
                  'interrupted))
      (should (eq (plist-get (nl-agent-training-runner-cancel runner "retry-final")
                             :status)
                  'cancelled))
      (should-not (file-exists-p workdir)))))

(ert-deftest training-cancel-final-save-failure-allows-permanent-stop ()
  (training-cancel--with-fixture fixture
    (let* ((queue (plist-get fixture :queue))
           (checkpoint (plist-get fixture :checkpoint))
           (save (symbol-function 'nl-llm-evolve-queue-save)))
      (training-cancel--submit queue "shutdown")
      (cl-letf (((symbol-function 'start-process)
                 #'training-cancel--waiting-process))
        (nl-agent-training-runner-start runner "shutdown"))
      (cl-letf (((symbol-function 'nl-llm-evolve-queue-save)
                 (lambda (candidate &optional file)
                   (let ((job (nl-llm-evolve-queue--job candidate "shutdown")))
                     (if (and job (eq (nl-llm-evolve-queue-job-status job)
                                      'cancelled))
                         (error "injected final save")
                       (funcall save candidate file))))))
        (should-error (nl-agent-training-runner-cancel runner "shutdown")))
      (nl-agent-training-runner-stop runner)
      (nl-agent-training-runner-stop runner)
      (should-not (file-locked-p checkpoint)))))

(ert-deftest training-cancel-max-history-zero-is-safe ()
  (training-cancel--with-fixture fixture
    (let ((queue (plist-get fixture :queue)))
      (setf (nl-llm-evolve-queue-max-history queue) 0)
      (training-cancel--submit queue "trimmed")
      (cl-letf (((symbol-function 'start-process)
                 #'training-cancel--waiting-process))
        (nl-agent-training-runner-start runner "trimmed"))
      (should (eq (plist-get (nl-agent-training-runner-cancel runner "trimmed")
                             :status)
                  'cancelled))
      (should-not (nl-llm-evolve-queue-jobs queue)))))

(ert-deftest training-cancel-cleanup-failure-does-not-wedge-runner ()
  (training-cancel--with-fixture fixture
    (let ((queue (plist-get fixture :queue)) workdir result)
      (training-cancel--submit queue "cleanup-failure")
      (cl-letf (((symbol-function 'start-process)
                 #'training-cancel--waiting-process))
        (nl-agent-training-runner-start runner "cleanup-failure"))
      (setq workdir (nl-agent-training-runner-workdir runner))
      (cl-letf (((symbol-function 'delete-directory)
                 (lambda (&rest _arguments) (error "injected cleanup failure"))))
        (setq result
              (nl-agent-training-runner-cancel runner "cleanup-failure")))
      (should (eq (plist-get result :status) 'cancelled))
      (should (plist-get (plist-get result :result) :cleanup-error))
      (should-not (nl-agent-training-runner-cancelling runner))
      (should (equal
               (plist-get
                (car (nl-agent-training-runner-cleanup-failures runner))
                :workdir)
               workdir))
      (should (file-directory-p workdir))
      (should (= (nl-llm-evolution-generation
                  (nl-llm-evolve-queue-evolution queue))
                 0))
      (training-cancel--submit queue "after-cleanup-failure")
      (cl-letf (((symbol-function 'start-process)
                 #'training-cancel--waiting-process))
        (nl-agent-training-runner-start runner "after-cleanup-failure"))
      (should (process-live-p (nl-agent-training-runner-process runner)))
      (nl-agent-training-runner-cancel runner "after-cleanup-failure"))))

(provide 'training-cancel-test)
;;; training-cancel-test.el ends here
