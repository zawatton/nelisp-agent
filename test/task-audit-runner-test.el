;;; task-audit-runner-test.el --- runner audit integration -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                          (file-name-directory (or load-file-name buffer-file-name
                                                   default-directory))) nil t)
)
(require 'nl-agent-task-audit)
(require 'nl-agent-task-eval)
(require 'nl-agent-task-eval-service)
(require 'nl-agent-task-promotion)
(require 'nl-agent-training-protocol)
(require 'nl-agent-training-runner)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-improve)

(defun nl-agent-task-audit-runner-test--policy ()
  "Return a deliberately non-improving task policy."
  (nl-agent-task-promotion-policy
   (list :suite
         (list :id "runner-audit-suite" :version "1"
               :cases
               (vector
                (list :id "rename" :task
                      "Replace old with new in note.txt, then finish."
                      :files (vector (list :path "note.txt" :text "old"))
                      :expected (vector (list :path "note.txt" :text "new")))))
         :grammar '(:type "done" :length 1)
         :max-sequence 4096 :max-steps 1)))

(defun nl-agent-task-audit-runner-test--fixture ()
  "Create a queue, runner, and audit directory for the integration tests."
  (let* ((tmp (make-temp-file "nl-task-audit-runner-" t))
         (catalog (expand-file-name "catalog.json" tmp))
         (queue-file (expand-file-name "queue.sexp" tmp))
         (audit (expand-file-name "audit" tmp))
         (model (nl-llm-agent-improve-model 2 2 96 1 1))
         (benchmark [" ab"])
         (grammar '(:type "done" :length 1))
         (score (lambda (candidate)
                  (let* ((ids (mapcar #'nl-llm-agent--char->id
                                      (append " ab" nil)))
                         (loss (nl-llm-agent--p5-forward
                                candidate (butlast ids)
                                (apply #'vector (cdr ids)))))
                    (- (aref (photon-tensor-data (pav-value loss)) 0)))))
         (queue (nl-llm-agent-evolve-p5-queue
                 model score catalog grammar :id-prefix "audit-runner"
                 :max-pending 8 :min-delta 0.0))
         (policy (nl-agent-task-audit-runner-test--policy))
         (profile (list :scope (make-string 64 ?e)
                        :benchmark benchmark
                        :training '(:backend cpu :sequence 8 :optimizer sgd)
                        :directory tmp :catalog-file catalog
                        :task-promotion policy
                        :task-audit-directory audit)))
    (setf (nl-llm-evolve-queue-checkpoint-file queue) queue-file)
    (nl-llm-evolve-queue-submit
     queue "trajectory-finetune" '(:examples [" ab"] :lr 0.01 :epochs 1)
     :id "audit-runner-job")
    (list :tmp tmp :audit audit :catalog catalog :queue queue :profile profile
          :runner (nl-agent-training-runner-new queue profile))))

(defun nl-agent-task-audit-runner-test--cleanup (fixture)
  (ignore-errors (nl-agent-training-runner-stop
                  (plist-get fixture :runner)))
  (when (file-directory-p (plist-get fixture :tmp))
    (delete-directory (plist-get fixture :tmp) t)))

(defun nl-agent-task-audit-runner-test--write-expected (suite workspace)
  "Write the first suite case's expected files to WORKSPACE."
  (let ((case (aref (plist-get suite :cases) 0)))
    (dolist (entry (append (plist-get case :expected) nil))
      (let ((path (expand-file-name (plist-get entry :path) workspace)))
        (make-directory (file-name-directory path) t)
        (with-temp-file path
          (insert (plist-get entry :text)))))))

(defun nl-agent-task-audit-runner-test--evidence
    (request policy &optional positive)
  "Return valid deterministic evidence, optionally positively accepted."
  (let ((model (nl-agent-training-protocol-import
                (plist-get request :parent-model))))
    (let ((suite-data (plist-get policy :suite)))
    (cl-letf (((symbol-function 'nl-agent-task-eval-service-run)
               (lambda (suite _registry model-id &rest keys)
                 (nl-agent-task-eval-run
                  suite (lambda (_task workspace _steps)
                          (when (and positive (equal model-id "native/after"))
                            (nl-agent-task-audit-runner-test--write-expected
                             suite-data workspace))
                          (list :status 'done :steps 1 :result nil
                                :messages nil :trajectory nil))
                  :model-id model-id :runner-id
                  nl-agent-task-eval-service-runner-id
                  :max-steps (plist-get keys :max-steps)))))
      (nl-agent-task-promotion-evaluate
       model model (plist-get policy :suite) (plist-get policy :grammar)
       :max-sequence (plist-get policy :max-sequence)
       :max-steps (plist-get policy :max-steps))))))

(defun nl-agent-task-audit-runner-test--result
    (runner policy &optional positive)
  "Return a protocol-valid result for RUNNER with synthetic evidence."
  (let* ((request (nl-agent-training-runner-request runner))
         (model (plist-get request :parent-model))
         (evidence (nl-agent-task-audit-runner-test--evidence
                    request policy positive)))
    (list :format nl-agent-training-result-format
          :attempt (plist-get request :attempt)
          :request-sha256
          (nl-agent-training-runner-request-sha256 runner)
          :score (1+ (plist-get request :parent-score))
          :model model :task-promotion evidence)))

(defun nl-agent-task-audit-runner-test--successful-process (&rest _args)
  "Return a short-lived child for deterministic result polling."
  (make-process :name "nl-task-audit-runner-child" :buffer nil :noquery t
                :command (list shell-file-name shell-command-switch
                               "sleep 0.05; exit 0")))

(defun nl-agent-task-audit-runner-test--finish-process (runner)
  "Wait for RUNNER's child without invoking its sentinel."
  (let ((process (nl-agent-training-runner-process runner)))
    (set-process-sentinel process #'ignore)
    (while (process-live-p process)
      (accept-process-output process 0.05))))

(ert-deftest nl-agent-task-audit-runner-veto-survives-workdir-cleanup ()
  (let* ((fixture (nl-agent-task-audit-runner-test--fixture))
         (runner (plist-get fixture :runner))
         (queue (plist-get fixture :queue))
         (job-id "audit-runner-job")
         workdir request)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'start-process)
                     #'nl-agent-task-audit-runner-test--successful-process))
            (nl-agent-training-runner-start runner)
            (setq workdir (nl-agent-training-runner-workdir runner)
                  request (copy-tree (nl-agent-training-runner-request runner)
                                     t))
            (nl-agent-training-protocol-write
             (nl-agent-training-runner-result-file runner)
             (nl-agent-task-audit-runner-test--result
              runner (nl-agent-training-runner-task-promotion-policy runner)))
            (nl-agent-task-audit-runner-test--finish-process runner)
            (nl-agent-training-runner-poll runner))
          (let* ((job (nl-llm-evolve-queue--job queue job-id))
                 (record
                  (nl-agent-task-audit-read
                   (plist-get fixture :audit)
                   (plist-get request :scope) job-id
                   (plist-get request :attempt))))
            (should (eq (nl-llm-evolve-queue-job-status job) 'rejected))
            (should (eq (plist-get (nl-llm-evolve-queue-job-result job)
                                   :promotion-gate)
                        'rejected))
            (should (equal (plist-get record :request) request)))
          (should-not (file-directory-p workdir))
          (should (= (nl-llm-evolution-generation
                      (nl-llm-evolve-queue-evolution queue)) 0)))
      (nl-agent-task-audit-runner-test--cleanup fixture))))

(ert-deftest nl-agent-task-audit-runner-validates-and-detaches-directory ()
  (let* ((fixture (nl-agent-task-audit-runner-test--fixture))
         (runner (plist-get fixture :runner))
         (queue (plist-get fixture :queue))
         (profile (plist-get fixture :profile))
         (original (copy-sequence (plist-get profile :task-audit-directory))))
    (unwind-protect
        (progn
          (aset (plist-get profile :task-audit-directory) 0 ?X)
          (should (equal (nl-agent-training-runner-task-audit-directory runner)
                         original))
          (nl-agent-training-runner-stop runner)
          (setf (plist-get profile :task-audit-directory) nil)
          (should-error (nl-agent-training-runner-new queue profile)))
      (nl-agent-task-audit-runner-test--cleanup fixture))))

(ert-deftest nl-agent-task-audit-runner-positive-control-saves-before-publish ()
  "Synthetic positive evidence tests audit ordering, not learned competence."
  (let* ((fixture (nl-agent-task-audit-runner-test--fixture))
         (runner (plist-get fixture :runner))
         (queue (plist-get fixture :queue))
         (request nil)
         (complete (symbol-function 'nl-llm-evolve-queue-complete))
         (complete-called 0))
    (unwind-protect
        (cl-letf (((symbol-function 'start-process)
                   #'nl-agent-task-audit-runner-test--successful-process)
                  ((symbol-function 'nl-llm-evolve-queue-complete)
                   (lambda (queue-value claim candidate score)
                     (setq complete-called (1+ complete-called))
                     ;; This runs inside the publisher call, proving audit
                     ;; persistence precedes queue publication.
                     (nl-agent-task-audit-read
                      (plist-get fixture :audit)
                      (plist-get request :scope) "audit-runner-job"
                      (plist-get request :attempt))
                     (funcall complete queue-value claim candidate score)))
                  )
          (nl-agent-training-runner-start runner)
          (setq request (copy-tree (nl-agent-training-runner-request runner)
                                   t))
          (nl-agent-training-protocol-write
           (nl-agent-training-runner-result-file runner)
           (nl-agent-task-audit-runner-test--result
            runner (nl-agent-training-runner-task-promotion-policy runner)
            t))
          (nl-agent-task-audit-runner-test--finish-process runner)
          (nl-agent-training-runner-poll runner)
          (should (= complete-called 1))
          (let* ((job (nl-llm-evolve-queue--job queue "audit-runner-job"))
                 (record
                  (nl-agent-task-audit-read
                   (plist-get fixture :audit)
                   (plist-get request :scope) "audit-runner-job"
                   (plist-get request :attempt))))
            (should (eq (nl-llm-evolve-queue-job-status job) 'promoted))
            (should (= (nl-llm-evolution-generation
                        (nl-llm-evolve-queue-evolution queue)) 1))
            (should (file-regular-p (plist-get fixture :catalog)))
            (should (equal (plist-get record :request) request))))
      (nl-agent-task-audit-runner-test--cleanup fixture))))

(ert-deftest nl-agent-task-audit-runner-save-failure-keeps-attempt ()
  (let* ((fixture (nl-agent-task-audit-runner-test--fixture))
         (runner (plist-get fixture :runner))
         (queue (plist-get fixture :queue))
         workdir)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'start-process)
                     #'nl-agent-task-audit-runner-test--successful-process)
                    ((symbol-function 'nl-agent-task-audit-save)
                     (lambda (&rest _args) (error "injected audit failure"))))
            (nl-agent-training-runner-start runner)
            (setq workdir (nl-agent-training-runner-workdir runner))
            (nl-agent-training-protocol-write
             (nl-agent-training-runner-result-file runner)
             (nl-agent-task-audit-runner-test--result
              runner (nl-agent-training-runner-task-promotion-policy runner)
              t))
            (nl-agent-task-audit-runner-test--finish-process runner)
            (nl-agent-training-runner-poll runner))
          (should (file-directory-p workdir))
          (should (= (nl-llm-evolution-generation
                      (nl-llm-evolve-queue-evolution queue)) 0))
          (should-not (file-exists-p (plist-get fixture :catalog)))
          (should (eq (nl-llm-evolve-queue-job-status
                       (nl-llm-evolve-queue--job queue "audit-runner-job"))
                      'error))
          (should (cl-some
                   (lambda (entry)
                     (and (equal (plist-get entry :kind) 'task-audit)
                          (equal (plist-get entry :workdir) workdir)))
                   (nl-agent-training-runner-cleanup-failures runner)))
          (should-not
           (car (nl-agent-training-runner-task-promotion-gate-state runner))))
      (nl-agent-task-audit-runner-test--cleanup fixture))))

(provide 'task-audit-runner-test)
(ert-run-tests-batch-and-exit)
;;; task-audit-runner-test.el ends here
