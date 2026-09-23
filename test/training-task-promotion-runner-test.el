;;; training-task-promotion-runner-test.el --- runner task-gate boundary -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                          (file-name-directory (or load-file-name buffer-file-name
                                                   default-directory))) nil t)
)
(require 'nl-agent-training-runner)
(require 'nl-agent-task-promotion)
(require 'nl-agent-task-eval)
(require 'nl-agent-task-eval-service)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-improve)

(defun nl-agent-training-task-promotion-runner-test--suite ()
  "Return a small DONE-only task suite whose candidate is expected to fail."
  (nl-agent-task-eval--suite
   (list :id "runner-promotion-suite" :version "1"
         :cases
         [(:id "finish" :task "Replace old with new in note.txt, then finish."
           :files [(:path "note.txt" :text "old")]
           :expected [(:path "note.txt" :text "new")])])) )

(defun nl-agent-training-task-promotion-runner-test--policy ()
  "Return a detached policy fixture."
  (nl-agent-task-promotion-policy
   (list :suite (nl-agent-training-task-promotion-runner-test--suite)
         :grammar '(:type "done" :length 1)
         :max-sequence 4096 :max-steps 1)))

(defun nl-agent-training-task-promotion-runner-test--score (model)
  "Return the fixed benchmark score used by the runner fixture."
  (let* ((ids (mapcar #'nl-llm-agent--char->id (append " ab" nil)))
         (loss (nl-llm-agent--p5-forward
                model (butlast ids) (apply #'vector (cdr ids)))))
    (- (aref (photon-tensor-data (pav-value loss)) 0))))

(defun nl-agent-training-task-promotion-runner-test--fixture
    (&optional task-policy)
  "Create a disposable runner fixture, optionally with TASK-POLICY."
  (let* ((tmp (make-temp-file "nl-task-promotion-runner-" t))
         (catalog (expand-file-name "catalog.json" tmp))
         (queue-file (expand-file-name "queue.sexp" tmp))
         (model (nl-llm-agent-improve-model 2 2 96 1 1))
         (benchmark [" ab"])
         (grammar '(:type "done" :length 1))
         (score #'nl-agent-training-task-promotion-runner-test--score)
         (queue (nl-llm-agent-evolve-p5-queue
                 model score catalog grammar :id-prefix "runner-task"
                 :max-pending 8 :min-delta 0.0))
         (profile (list :scope (make-string 64 ?0)
                        :benchmark benchmark
                        :training '(:backend cpu :sequence 8 :optimizer sgd)
                        :directory tmp :catalog-file catalog))
         runner)
    (setf (nl-llm-evolve-queue-checkpoint-file queue) queue-file)
    (nl-llm-evolve-queue-submit
     queue "trajectory-finetune" '(:examples [" ab"] :lr 0.01 :epochs 1)
     :id "runner-task-job")
    (when task-policy
      (setq profile (append profile (list :task-promotion task-policy))))
    (setq runner (nl-agent-training-runner-new queue profile))
    (list :tmp tmp :catalog catalog :queue queue :runner runner
          :model model :policy task-policy)))

(defun nl-agent-training-task-promotion-runner-test--cleanup (fixture)
  (ignore-errors (nl-agent-training-runner-stop (plist-get fixture :runner)))
  (when (file-directory-p (plist-get fixture :tmp))
    (delete-directory (plist-get fixture :tmp) t)))

(defun nl-agent-training-task-promotion-runner-test--failed-evidence
    (policy before-model after-model)
  "Make valid, non-accepting evidence without invoking a real task service."
  (cl-letf (((symbol-function 'nl-agent-task-eval-service-run)
             (lambda (suite _registry model-id &rest keys)
               (nl-agent-task-eval-run
                suite (lambda (&rest _args)
                        (list :status 'done :steps 1 :result nil
                              :messages nil :trajectory nil))
                :model-id model-id :runner-id
                nl-agent-task-eval-service-runner-id
                :max-steps (plist-get keys :max-steps)))))
    (nl-agent-task-promotion-evaluate
     before-model after-model
     (plist-get policy :suite) (plist-get policy :grammar)
     :max-sequence (plist-get policy :max-sequence)
     :max-steps (plist-get policy :max-steps))))

(defun nl-agent-training-task-promotion-runner-test--accepted-evidence
    (policy before-model after-model)
  "Make valid positive evidence using a synthetic report, not a gate stub."
  (let ((suite-data (plist-get policy :suite)))
    (cl-letf (((symbol-function 'nl-agent-task-eval-service-run)
               (lambda (suite _registry model-id &rest keys)
                 (nl-agent-task-eval-run
                  suite
                  (lambda (_task workspace _steps)
                    (when (equal model-id "native/after")
                      (let* ((case (aref (plist-get suite-data :cases) 0))
                             (entry (aref (plist-get case :expected) 0)))
                        (with-temp-file
                            (expand-file-name (plist-get entry :path)
                                              workspace)
                          (insert (plist-get entry :text)))))
                    (list :status 'done :steps 1 :result nil
                          :messages nil :trajectory nil))
                  :model-id model-id :runner-id
                  nl-agent-task-eval-service-runner-id
                  :max-steps (plist-get keys :max-steps)))))
      (nl-agent-task-promotion-evaluate
       before-model after-model (plist-get policy :suite)
       (plist-get policy :grammar)
       :max-sequence (plist-get policy :max-sequence)
       :max-steps (plist-get policy :max-steps)))))

(ert-deftest nl-agent-training-task-promotion-runner-policy-is-detached-and-bound ()
  (let* ((policy (nl-agent-training-task-promotion-runner-test--policy))
         (fixture (nl-agent-training-task-promotion-runner-test--fixture policy))
         (runner (plist-get fixture :runner))
         (queue (plist-get fixture :queue))
         (claim (nl-llm-evolve-queue-claim queue "runner-task-job"))
         (request (nl-agent-training-runner--request-value runner claim))
         (original (plist-get request :task-promotion)))
    (unwind-protect
        (progn
          (setf (plist-get (plist-get policy :suite) :id) "mutated")
          (setf (plist-get (plist-get policy :grammar) :length) 9)
          (should (equal original
                         (nl-agent-training-runner-task-promotion-policy runner)))
          (should (equal (plist-get request :task-promotion) original))
          (nl-llm-evolve-queue-interrupt queue claim))
      (nl-agent-training-task-promotion-runner-test--cleanup fixture))))

(ert-deftest nl-agent-training-task-promotion-runner-rejects-gate-collision-before-lock ()
  (let* ((policy (nl-agent-training-task-promotion-runner-test--policy))
         (fixture (nl-agent-training-task-promotion-runner-test--fixture))
         (queue (plist-get fixture :queue))
         (profile (nl-agent-training-runner-profile (plist-get fixture :runner)))
         (existing (lambda (&rest _args) t)))
    (unwind-protect
        (progn
          (nl-agent-training-runner-stop (plist-get fixture :runner))
          (setf (nl-llm-evolution-promotion-gate-fn
                 (nl-llm-evolve-queue-evolution queue)) existing)
          (setf profile (append profile (list :task-promotion policy)))
          (should-error (nl-agent-training-runner-new queue profile))
          (should-not (member (file-truename (nl-llm-evolve-queue-checkpoint-file queue))
                              nl-agent-training-runner--owners)))
      (nl-agent-training-task-promotion-runner-test--cleanup fixture))))

(ert-deftest nl-agent-training-task-promotion-runner-veto-clears-receipt ()
  (let* ((policy (nl-agent-training-task-promotion-runner-test--policy))
         (fixture (nl-agent-training-task-promotion-runner-test--fixture policy))
         (runner (plist-get fixture :runner))
         (queue (plist-get fixture :queue))
         (claim (nl-llm-evolve-queue-claim queue "runner-task-job"))
         (request (nl-agent-training-runner--request-value runner claim))
         (before-model (nl-llm-evolution-champion
                       (nl-llm-evolve-queue-evolution queue)))
         (after-model (nl-llm-evolve-copy-model before-model))
         (after (nl-llm-agent-artifact-export-pav
                 after-model))
         (result (list :task-promotion
                       (nl-agent-training-task-promotion-runner-test--failed-evidence
                        policy before-model after-model)))
         (candidate (nl-agent-training-protocol-import after)))
    (unwind-protect
        (progn
          (nl-agent-training-runner--task-promotion-receipt
           runner request result candidate)
          (nl-llm-evolve-queue-complete queue claim candidate 1.0)
          (should (eq (nl-llm-evolve-queue-job-status
                       (nl-llm-evolve-queue--job queue "runner-task-job"))
                      'rejected))
          (should (= (nl-llm-evolution-generation
                      (nl-llm-evolve-queue-evolution queue)) 0))
          (let ((gate (nl-agent-training-runner-task-promotion-gate runner)))
            (should-not (funcall gate
                                 (nl-llm-evolve-copy-model candidate)
                                 (nl-llm-evolve-copy-model candidate)))
            (should-not (funcall gate
                                 (nl-llm-evolve-copy-model candidate)
                                 (nl-llm-evolve-copy-model candidate))))
          (should-not (car (nl-agent-training-runner-task-promotion-gate-state
                            runner))))
      (nl-agent-training-task-promotion-runner-test--cleanup fixture))))

(ert-deftest nl-agent-training-task-promotion-runner-positive-evidence-promotes ()
  "Synthetic positive evidence exercises the real validator and queue gate.
This is plumbing coverage, not a learned task-capability claim."
  (let* ((policy (nl-agent-training-task-promotion-runner-test--policy))
         (fixture (nl-agent-training-task-promotion-runner-test--fixture policy))
         (runner (plist-get fixture :runner))
         (queue (plist-get fixture :queue))
         (claim (nl-llm-evolve-queue-claim queue "runner-task-job"))
         (request (nl-agent-training-runner--request-value runner claim))
         (before-model (nl-llm-evolution-champion
                        (nl-llm-evolve-queue-evolution queue)))
         (after-model (nl-llm-evolve-copy-model before-model))
         (after (nl-llm-agent-artifact-export-pav after-model))
         (candidate (nl-agent-training-protocol-import after))
         (result (list :task-promotion
                       (nl-agent-training-task-promotion-runner-test--accepted-evidence
                        policy before-model after-model))))
    (unwind-protect
        (progn
          (nl-agent-training-runner--task-promotion-receipt
           runner request result candidate)
          (nl-llm-evolve-queue-complete
           queue claim candidate (1+ (plist-get claim :parent-score)))
          (should (eq (nl-llm-evolve-queue-job-status
                       (nl-llm-evolve-queue--job queue "runner-task-job"))
                      'promoted))
          (should (= (nl-llm-evolution-generation
                      (nl-llm-evolve-queue-evolution queue)) 1))
          (should (file-exists-p (plist-get fixture :catalog)))
          (should-not (car (nl-agent-training-runner-task-promotion-gate-state
                            runner))))
      (nl-agent-training-task-promotion-runner-test--cleanup fixture))))

(ert-deftest nl-agent-training-task-promotion-runner-real-cpu-child-is-nonblocking ()
  "A real worker child remains independent while the host keeps polling.
The host evaluator is replaced with an erroring function: runner completion
must use only the worker's validated evidence, never evaluate tasks itself."
  (let* ((policy (nl-agent-training-task-promotion-runner-test--policy))
         (fixture (nl-agent-training-task-promotion-runner-test--fixture policy))
         (runner (plist-get fixture :runner))
         (queue (plist-get fixture :queue))
         (initial-digest
          (secure-hash
           'sha256
           (prin1-to-string
            (nl-llm-agent-artifact-export-pav
             (nl-llm-evolution-champion
              (nl-llm-evolve-queue-evolution queue))))))
         (host-evaluator-called nil))
    (unwind-protect
        (cl-letf (((symbol-function 'nl-agent-task-promotion-evaluate)
                   (lambda (&rest _args)
                     (setq host-evaluator-called t)
                     (error "host task inference is forbidden"))))
          (let ((job (nl-agent-training-runner-start runner)))
            (should (eq (plist-get job :status) 'running))
            (should (process-live-p (nl-agent-training-runner-process runner)))
            ;; Polling while the child trains must remain a normal host action.
            (nl-agent-training-runner-poll runner)
            (should (plist-get (nl-agent-training-queue-public-status runner)
                               :worker-running))
            ;; A live training child does not block ordinary queue intake.
            (nl-llm-evolve-queue-submit
             queue "trajectory-finetune" '(:examples [" ab"] :lr 0.01 :epochs 1)
             :id "runner-task-pending-while-live")
            (should (>= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                        1)))
          (let ((deadline (+ (float-time) 30.0)))
            (while (and (< (float-time) deadline)
                        (nl-agent-training-runner-process runner))
              (accept-process-output
               (nl-agent-training-runner-process runner) 0.1)
              (nl-agent-training-runner-poll runner)))
          (nl-agent-training-runner-poll runner)
          (should-not host-evaluator-called)
          (should-not (nl-agent-training-runner-process runner))
          (let* ((job (nl-llm-evolve-queue--job queue "runner-task-job"))
                 (result (nl-llm-evolve-queue-job-result job))
                 (candidate-digest
                  (secure-hash
                   'sha256
                   (prin1-to-string
                    (nl-llm-agent-artifact-export-pav
                     (nl-llm-evolution-champion
                      (nl-llm-evolve-queue-evolution queue)))))))
            (should (eq (nl-llm-evolve-queue-job-status job) 'rejected))
            (should (eq (plist-get result :promotion-gate) 'rejected))
            (should (> (plist-get result :delta) 0.0))
            (should (equal initial-digest candidate-digest))
            (should-not (file-exists-p (plist-get fixture :catalog))))
          (should (= (plist-get (nl-agent-training-queue-public-status runner)
                                :generation)
                     0)))
      (nl-agent-training-task-promotion-runner-test--cleanup fixture))))

(provide 'training-task-promotion-runner-test)

(ert-run-tests-batch-and-exit)

;;; training-task-promotion-runner-test.el ends here
