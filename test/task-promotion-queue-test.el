;;; task-promotion-queue-test.el --- task gate queue plumbing -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'nl-agent-task-promotion)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-improve)
(require 'nl-llm-evolve-queue)

(defun nl-agent-task-promotion-queue-test--suite ()
  "Return one deterministic one-file task for the native gate."
  (list :id "queue-promotion-suite" :version "1"
        :cases
        [(:id "rename" :task "Replace old with new in note.txt, then finish."
          :files [(:path "note.txt" :text "old")]
          :expected [(:path "note.txt" :text "new")])]))

(defun nl-agent-task-promotion-queue-test--model ()
  "Return the tiny ASCII-compatible P5 model used by this test."
  (nl-llm-agent-improve-model 2 2 96 1 1))

(defun nl-agent-task-promotion-queue-test--digest (model)
  "Return a detached model weight digest."
  (secure-hash 'sha256
               (prin1-to-string
                (nl-llm-agent-artifact-export-pav model))))

(defun nl-agent-task-promotion-queue-test--fixture (gate)
  "Create a disposable P5 queue using GATE and a constant trusted score."
  (let* ((directory (make-temp-file "nl-task-promotion-queue-" t))
         (catalog (expand-file-name "catalog.json" directory))
         (queue-file (expand-file-name "queue.sexp" directory))
         (model (nl-agent-task-promotion-queue-test--model))
         (grammar '(:type "done" :length 1))
         (queue
          (nl-llm-agent-evolve-p5-queue
           model (lambda (_candidate) 0.0) catalog grammar
           :maxseq 4096 :min-delta 0.0
           :checkpoint-file queue-file :promotion-gate gate)))
    (list :directory directory :catalog catalog :queue-file queue-file
          :model model :grammar grammar :queue queue)))

(defun nl-agent-task-promotion-queue-test--submit-and-claim (queue id)
  "Submit a valid inert trajectory proposal and return its claim."
  (nl-llm-evolve-queue-submit
   queue "trajectory-finetune"
   '(:examples ["aa"] :lr 0.1 :epochs 1) :id id)
  (nl-llm-evolve-queue-claim queue id))

(ert-deftest nl-agent-task-promotion-queue-native-gate-vetoes ()
  "The real native DONE-only gate vetoes a non-improving task candidate."
  (let* ((suite (nl-agent-task-promotion-queue-test--suite))
         (grammar '(:type "done" :length 1))
         (gate (nl-agent-task-promotion-gate
                suite grammar :max-sequence 4096 :max-steps 1))
         (fixture (nl-agent-task-promotion-queue-test--fixture gate))
         (directory (plist-get fixture :directory))
         (catalog (plist-get fixture :catalog))
         (queue-file (plist-get fixture :queue-file))
         (queue (plist-get fixture :queue))
         (before (nl-agent-task-promotion-queue-test--digest
                  (nl-llm-evolution-champion
                   (nl-llm-evolve-queue-evolution queue))))
         (claim nil))
    (unwind-protect
        (progn
          (setq claim
                (nl-agent-task-promotion-queue-test--submit-and-claim
                 queue "native-veto"))
          (nl-llm-evolve-queue-complete
           queue claim
           (nl-llm-evolve-copy-model
           (nl-llm-evolution-champion
             (nl-llm-evolve-queue-evolution queue)))
           ;; Synthetic trusted worker result; this test performs no training.
           1.0)
          (let* ((job (nl-llm-evolve-queue--job queue "native-veto"))
                 (result (nl-llm-evolve-queue-job-result job))
                 (state (nl-llm-evolve-queue-evolution queue)))
            (should (eq (nl-llm-evolve-queue-job-status job) 'rejected))
            (should (eq (plist-get result :promotion-gate) 'rejected))
            (should (= (nl-llm-evolution-generation state) 0))
            (should (equal before
                           (nl-agent-task-promotion-queue-test--digest
                            (nl-llm-evolution-champion state))))
            (should-not (file-exists-p catalog))
            (should (file-regular-p queue-file))
            (let* ((snapshot (nl-llm-evolve-queue--checkpoint-read queue-file))
                   (saved-job
                    (cl-find-if
                     (lambda (candidate)
                       (equal (plist-get candidate :id) "native-veto"))
                     (append (plist-get snapshot :jobs) nil))))
              (should saved-job)
              (should (eq (plist-get saved-job :status) 'rejected))
              (should (eq (plist-get (plist-get saved-job :result)
                                     :promotion-gate)
                          'rejected)))))
      (when (file-directory-p directory)
        (delete-directory directory t)))))

(ert-deftest nl-agent-task-promotion-queue-synthetic-gate-promotes ()
  "Synthetic acceptance verifies queue gate plumbing, not task capability."
  (let* ((suite (nl-agent-task-promotion-queue-test--suite))
         (grammar '(:type "done" :length 1))
         (gate (nl-agent-task-promotion-gate
                suite grammar :max-sequence 4096 :max-steps 1))
         (fixture (nl-agent-task-promotion-queue-test--fixture gate))
         (directory (plist-get fixture :directory))
         (catalog (plist-get fixture :catalog))
         (queue (plist-get fixture :queue))
         (calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'nl-agent-task-promotion-evaluate)
                   (lambda (&rest _arguments)
                     (setq calls (1+ calls))
                     (list :accepted t))))
          (let ((claim
                 (nl-agent-task-promotion-queue-test--submit-and-claim
                  queue "synthetic-pass")))
            (nl-llm-evolve-queue-complete
             queue claim
             (nl-llm-evolve-copy-model
              (nl-llm-evolution-champion
               (nl-llm-evolve-queue-evolution queue)))
             1.0))
          (let* ((job (nl-llm-evolve-queue--job queue "synthetic-pass"))
                 (result (nl-llm-evolve-queue-job-result job))
                 (state (nl-llm-evolve-queue-evolution queue)))
            (should (= calls 1))
            (should (eq (nl-llm-evolve-queue-job-status job) 'promoted))
            (should (eq (plist-get result :promotion-gate) 'passed))
            (should (= (nl-llm-evolution-generation state) 1))
            (should (file-regular-p catalog))))
      (when (file-directory-p directory)
        (delete-directory directory t)))))

(provide 'task-promotion-queue-test)

(ert-run-tests-batch-and-exit)

;;; task-promotion-queue-test.el ends here
