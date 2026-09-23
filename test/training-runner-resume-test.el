;;; training-runner-resume-test.el --- durable runner resume -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-training-runner)
(require 'nl-agent-training-recovery)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-improve)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-gpu)

(defun nl-agent-training-runner-resume-test--queue
    (model catalog queue-file &optional restore)
  "Create a resumable queue around MODEL, optionally RESTORE its durable state."
  (let* ((score (nl-llm-agent-evolve-p5-evaluator ["ab"]))
         (queue (nl-llm-agent-evolve-p5-queue
                 model score catalog '(:type "done" :length 2 :allow "ab ")
                 :id-prefix "resume" :min-delta 0.0 :maxseq 64)))
    (setf (nl-llm-evolve-queue-checkpoint-file queue) queue-file)
    (setf (nl-llm-evolve-queue-handler-resume-fn
           (car (nl-llm-evolve-queue-handlers queue)))
          (lambda (&rest _arguments)
            (error "background runner owns resume execution")))
    (when restore (nl-llm-evolve-queue-restore queue))
    queue))

(defun nl-agent-training-runner-resume-test--profile
    (directory catalog recovery)
  "Return one trusted GPU checkpoint profile."
  (list :scope (make-string 64 ?0) :benchmark ["ab"]
        :training '(:backend gpu :sequence 2 :optimizer adam
                    :checkpoint-every 1)
        :directory directory :catalog-file catalog
        :recovery-directory recovery))

(defun nl-agent-training-runner-resume-test--write-pause (file)
  "Write a test-only worker pause after its first durable checkpoint."
  (with-temp-file file
    (insert
     ";;; pause-after-checkpoint.el --- test-only pause -*- lexical-binding: t; -*-\n"
     "(let ((original (symbol-function 'nl-llm-agent-ondevice-train))\n"
     "      (base (file-name-directory load-file-name)))\n"
     "  (fset 'nl-llm-agent-ondevice-train\n"
     "        (lambda (ctx trajs epochs &rest keys)\n"
     "          (let ((after (plist-get keys :after-step)) (paused nil))\n"
     "            (setq keys (plist-put keys :after-step\n"
     "              (lambda (active completed total)\n"
     "                (when after (funcall after active completed total))\n"
     "                (when (not paused)\n"
     "                  (setq paused t)\n"
     "                  (with-temp-file (expand-file-name \"pause.ready\" base)\n"
     "                    (insert \"ready\"))\n"
     "                  (while (not (file-exists-p\n"
     "                               (expand-file-name \"pause.release\" base)))\n"
     "                    (sleep-for 0.01))))))\n"
     "            (apply original ctx trajs epochs keys)))))\n")))

(defun nl-agent-training-runner-resume-test--inject (arguments fixture)
  "Insert FIXTURE load before --funcall in process ARGUMENTS."
  (let ((position (cl-position "--funcall" arguments :test #'equal)))
    (append (cl-subseq arguments 0 position)
            (list "-l" fixture) (nthcdr position arguments))))

(defun nl-agent-training-runner-resume-test--start-paused
    (runner fixture &optional id)
  "Start RUNNER's ID through real process creation with FIXTURE injected."
  (setq id (or id "resume-job"))
  (let ((real-start (symbol-function 'start-process)))
    (cl-letf (((symbol-function 'start-process)
               (lambda (name buffer program &rest arguments)
                 (apply real-start name buffer program
                        (nl-agent-training-runner-resume-test--inject
                         arguments fixture)))))
      (nl-agent-training-runner-start
       runner id
       (eq (nl-llm-evolve-queue-job-status
            (nl-llm-evolve-queue--job
             (nl-agent-training-runner-queue runner) id))
           'interrupted)))))

(defun nl-agent-training-runner-resume-test--wait-file
    (file runner &optional timeout)
  "Wait for FILE while RUNNER owns a live child."
  (let ((deadline (+ (float-time) (or timeout 10.0))))
    (while (and (not (file-exists-p file))
                (process-live-p (nl-agent-training-runner-process runner))
                (< (float-time) deadline))
      (accept-process-output (nl-agent-training-runner-process runner) 0.05))
    (file-exists-p file)))

(defun nl-agent-training-runner-resume-test--restored-runner
    (model catalog queue-file profile)
  "Return a new locked runner over a freshly restored queue."
  (nl-agent-training-runner-new
   (nl-agent-training-runner-resume-test--queue
    model catalog queue-file t)
   profile))

(ert-deftest nl-agent-training-runner-real-gpu-normal-stop-resume ()
  (unless (nl-llm-gpu-enable)
    (ert-skip "GPU backend unavailable; runner resume requires Vulkan"))
  (nl-llm-gpu-disable)
  (let* ((temporary (make-temp-file "nl-runner-resume-" t))
         (catalog (expand-file-name "catalog.json" temporary))
         (queue-file (expand-file-name "queue.sexp" temporary))
         (recovery (expand-file-name "recovery" temporary))
         (fixture (expand-file-name "pause-after-checkpoint.el" temporary))
         (ready (expand-file-name "pause.ready" temporary))
         (release (expand-file-name "pause.release" temporary))
         (model (nl-llm-agent-improve-model
                 2 2 nl-llm-agent-char-vocab 1 1))
         (score (funcall (nl-llm-agent-evolve-p5-evaluator ["ab"]) model))
         (profile (nl-agent-training-runner-resume-test--profile
                   temporary catalog recovery))
         queue runner1 runner2 runner3 runner4 runner5 runner6
         first-attempt first-request first-request-hash old-workdir
         final-workdir)
    (unwind-protect
        (progn
          (nl-llm-agent-artifact-publish
           catalog (nl-llm-agent-artifact-export-pav model)
           :id "base-g0" :name "base"
           :grammar '(:type "done" :length 2 :allow "ab ")
           :maxseq 64 :score score :generation 0)
          (setq queue
                (nl-agent-training-runner-resume-test--queue
                 model catalog queue-file))
          (nl-llm-evolve-queue-submit
           queue "trajectory-finetune"
           '(:examples ["ab" "ba"] :lr 0.1 :epochs 2)
           :id "resume-job")
          (nl-agent-training-runner-resume-test--write-pause fixture)
          (setq runner1 (nl-agent-training-runner-new queue profile))
          (nl-agent-training-runner-resume-test--start-paused runner1 fixture)
          (setq first-attempt
                (plist-get (nl-agent-training-runner-request runner1) :attempt)
                first-request
                (copy-tree (nl-agent-training-runner-request runner1) t)
                first-request-hash
                (nl-agent-training-runner-request-sha256 runner1)
                old-workdir (nl-agent-training-runner-workdir runner1))
          (should (nl-agent-training-runner-resume-test--wait-file
                   ready runner1))
          (cl-letf (((symbol-function 'nl-agent-training-recovery-save)
                     (lambda (&rest _args) (error "simulated save failure"))))
            (should-error (nl-agent-training-runner-stop runner1)))
          (should (nl-agent-training-runner-claim runner1))
          (should (nl-agent-training-runner-lock-files runner1))
          (let ((interrupt
                 (symbol-function 'nl-llm-evolve-queue-interrupt)))
            (cl-letf (((symbol-function 'nl-llm-evolve-queue-interrupt)
                       (lambda (&rest _args)
                         (error "simulated queue interrupt failure"))))
              (should-error (nl-agent-training-runner-stop runner1)))
            (should
             (nl-agent-training-recovery-load
              recovery (plist-get profile :scope) "resume-job"))
            (should (nl-agent-training-runner-claim runner1))
            (should (nl-agent-training-runner-lock-files runner1))
            (cl-letf (((symbol-function 'nl-llm-evolve-queue-interrupt)
                       interrupt))
              (nl-agent-training-runner-stop runner1)))
          (should (eq (nl-llm-evolve-queue-job-status
                       (nl-llm-evolve-queue--job queue "resume-job"))
                      'interrupted))
          (should (file-directory-p old-workdir))
          (nl-agent-training-protocol-write
           (expand-file-name "result.sexp" old-workdir)
           (list :format nl-agent-training-result-format
                 :attempt first-attempt
                 :request-sha256 first-request-hash
                 :score (plist-get first-request :parent-score)
                 :model (plist-get first-request :parent-model)))

          (setq runner2
                (nl-agent-training-runner-resume-test--restored-runner
                 model catalog queue-file profile))
          (cl-letf (((symbol-function 'start-process)
                     (lambda (&rest _args)
                       (should inhibit-quit)
                       (signal 'quit nil))))
            (let ((quit-observed nil))
              (condition-case nil
                  (nl-agent-training-runner-start runner2 "resume-job" t)
                (quit (setq quit-observed t)))
              (should quit-observed)))
          (should
           (nl-agent-training-recovery-load
            recovery (plist-get profile :scope) "resume-job"))
          (nl-agent-training-runner-stop runner2)

          (delete-file ready)
          (setq runner3
                (nl-agent-training-runner-resume-test--restored-runner
                 model catalog queue-file profile))
          (nl-agent-training-runner-resume-test--start-paused runner3 fixture)
          (should (nl-agent-training-runner-resume-test--wait-file
                   ready runner3))
          (should-error
           (nl-agent-training-recovery-load
            recovery (plist-get profile :scope) "resume-job"))
          (let ((resumed-attempt
                 (plist-get (nl-agent-training-runner-request runner3)
                            :attempt)))
            (should-not (equal resumed-attempt first-attempt))
            (nl-agent-training-runner-stop runner3)
            (let ((receipt
                   (nl-agent-training-recovery-load
                    recovery (plist-get profile :scope) "resume-job")))
              (should (equal (plist-get (plist-get receipt :request) :attempt)
                             resumed-attempt))))

          (setq runner4
                (nl-agent-training-runner-resume-test--restored-runner
                 model catalog queue-file profile))
          (nl-agent-training-runner-start runner4 "resume-job" t)
          (setq final-workdir (nl-agent-training-runner-workdir runner4))
          (should-not (equal old-workdir final-workdir))
          (should (plist-get (nl-agent-training-runner-request runner4)
                             :resume-state))
          (let ((deadline (+ (float-time) 15.0)))
            (while (and (nl-agent-training-runner-process runner4)
                        (< (float-time) deadline))
              (accept-process-output
               (nl-agent-training-runner-process runner4) 0.05)
              (nl-agent-training-runner-poll runner4)))
          (let ((status (nl-agent-training-runner-status runner4)))
            (should (= (plist-get status :generation) 1)))
          (should (file-regular-p
                   (expand-file-name "result.sexp" old-workdir)))
          (should-not
           (file-exists-p
            (nl-agent-training-recovery-path
             recovery (plist-get profile :scope) "resume-job")))

          ;; A deliberate cancellation after an owned resumed child is stopped
          ;; releases its marker and removes the origin receipt.
          (let ((queue4 (nl-agent-training-runner-queue runner4)))
            (nl-llm-evolve-queue-submit
             queue4 "trajectory-finetune"
             '(:examples ["ab" "ba"] :lr 0.1 :epochs 2)
             :id "cancel-job"))
          (setq model
                (nl-llm-agent-artifact-load-pav catalog "resume-g1"))
          (nl-agent-training-runner-stop runner4)
          (delete-file ready)
          (setq runner5
                (nl-agent-training-runner-resume-test--restored-runner
                 model catalog queue-file profile))
          (nl-agent-training-runner-resume-test--start-paused
           runner5 fixture "cancel-job")
          (should (nl-agent-training-runner-resume-test--wait-file
                   ready runner5))
          (nl-agent-training-runner-stop runner5)
          (delete-file ready)
          (setq runner6
                (nl-agent-training-runner-resume-test--restored-runner
                 model catalog queue-file profile))
          (nl-agent-training-runner-resume-test--start-paused
           runner6 fixture "cancel-job")
          (should (nl-agent-training-runner-resume-test--wait-file
                   ready runner6))
          (nl-agent-training-runner-cancel runner6 "cancel-job")
          (should-not
           (file-exists-p
            (nl-agent-training-recovery-path
             recovery (plist-get profile :scope) "cancel-job")))
          (should-not
           (file-exists-p
            (nl-agent-training-recovery-marker-path
             recovery (plist-get profile :scope) "cancel-job"))))
      (when (file-exists-p release) (delete-file release))
      (dolist (runner (list runner1 runner2 runner3 runner4 runner5 runner6))
        (when runner (ignore-errors (nl-agent-training-runner-stop runner))))
      (ignore-errors (nl-llm-gpu-disable))
      (delete-directory temporary t))))

(provide 'training-runner-resume-test)

(ert-run-tests-batch-and-exit)

;;; training-runner-resume-test.el ends here
