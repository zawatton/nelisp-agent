;;; training-supervised-runner-resume-test.el --- supervised runner resume -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'nl-agent-training-runner)
(require 'nl-agent-training-recovery)
(require 'nl-agent-training-protocol)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-improve)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-supervised-evolve)
(require 'nl-llm-gpu)

(defun nl-agent-training-supervised-runner-resume-test--queue
    (model catalog queue-file &optional restore)
  "Create a GPU supervised queue, optionally restoring QUEUE-FILE."
  (let* ((score (nl-llm-agent-evolve-p5-evaluator ["ab"]))
         (queue
          (nl-llm-agent-evolve-p5-queue
           model score catalog '(:type "done" :length 2 :allow "ab ")
           :id-prefix "supervised-resume" :min-delta 0.0 :maxseq 64)))
    (setf (nl-llm-evolve-queue-checkpoint-file queue) queue-file)
    (nl-llm-agent-supervised-evolve-register
     queue :training-backend 'gpu :training-sequence 8 :optimizer 'adam)
    ;; The production supervised adapter is synchronous-only by design.  This
    ;; test explicitly installs the runner's authorized resume marker.
    (setf (nl-llm-evolve-queue-handler-resume-fn
           (nl-llm-evolve-queue--handler queue "supervised-finetune"))
          (lambda (&rest _arguments)
            (error "background runner owns supervised resume execution")))
    (when restore (nl-llm-evolve-queue-restore queue))
    queue))

(defun nl-agent-training-supervised-runner-resume-test--profile
    (directory catalog recovery)
  "Return the trusted GPU checkpoint profile used by the child test."
  (list :scope (make-string 64 ?0) :benchmark ["ab"]
        :training '(:backend gpu :sequence 8 :optimizer adam
                    :checkpoint-every 1)
        :directory directory :catalog-file catalog
        :recovery-directory recovery))

(defun nl-agent-training-supervised-runner-resume-test--write-pause (file)
  "Write a fixture that pauses after the first durable checkpoint."
  (let ((form
         `(let* ((original (symbol-function
                            'nl-llm-agent-ondevice-train))
                 (base (file-name-directory load-file-name)))
            (fset 'nl-llm-agent-ondevice-train
                  (lambda (ctx trajs epochs &rest keys)
                    (let ((after (plist-get keys :after-step))
                          (paused nil))
                      (setq keys
                            (plist-put
                             keys :after-step
                             (lambda (active completed total)
                               (when after
                                 (funcall after active completed total))
                               (when (not paused)
                                 (setq paused t)
                                 (with-temp-file
                                     (expand-file-name "pause.ready" base)
                                   (insert "ready"))
                                 (let ((deadline (+ (float-time) 20.0)))
                                   (while
                                       (and
                                        (not
                                         (file-exists-p
                                          (expand-file-name
                                           "pause.release" base)))
                                        (< (float-time) deadline))
                                     (sleep-for 0.01))
                                   (unless
                                       (file-exists-p
                                        (expand-file-name
                                         "pause.release" base))
                                     (error
                                      "supervised runner pause timed out")))))))
                      (apply original ctx trajs epochs keys)))))))
    (with-temp-file file
      (insert ";;; supervised-runner-pause.el --- test-only pause -*- lexical-binding: t; -*-\n"
              (let ((print-escape-nonascii t)
                    (print-length nil)
                    (print-level nil))
                (prin1-to-string form))
              "\n"))))

(defun nl-agent-training-supervised-runner-resume-test--inject
    (arguments fixture)
  "Insert FIXTURE load before the worker's --funcall."
  (let ((position (cl-position "--funcall" arguments :test #'equal)))
    (append (cl-subseq arguments 0 position)
            (list "-l" fixture) (nthcdr position arguments))))

(defun nl-agent-training-supervised-runner-resume-test--start
    (runner fixture &optional id resuming)
  "Start RUNNER while injecting FIXTURE into the worker process."
  (if fixture
      (let ((real-start (symbol-function 'start-process)))
        (cl-letf (((symbol-function 'start-process)
                   (lambda (name buffer program &rest arguments)
                     (apply real-start name buffer program
                            (if (equal name "nl-agent-training-worker")
                                (nl-agent-training-supervised-runner-resume-test--inject
                                 arguments fixture)
                              arguments)))))
          (nl-agent-training-runner-start runner id resuming)))
    (nl-agent-training-runner-start runner id resuming)))

(defun nl-agent-training-supervised-runner-resume-test--wait-file
    (file runner &optional timeout)
  "Wait for FILE while RUNNER owns a live child."
  (let ((deadline (+ (float-time) (or timeout 20.0))))
    (while (and (not (file-exists-p file))
                (nl-agent-training-runner-process runner)
                (process-live-p (nl-agent-training-runner-process runner))
                (< (float-time) deadline))
      (accept-process-output (nl-agent-training-runner-process runner) 0.05))
    (file-exists-p file)))

(defun nl-agent-training-supervised-runner-resume-test--wait-terminal
    (runner &optional timeout)
  "Poll RUNNER until its child is terminal or TIMEOUT expires."
  (let ((deadline (+ (float-time) (or timeout 30.0))))
    (while (and (nl-agent-training-runner-process runner)
                (< (float-time) deadline))
      (accept-process-output (nl-agent-training-runner-process runner) 0.05)
      (nl-agent-training-runner-poll runner))
    (nl-agent-training-runner-poll runner)))

(ert-deftest nl-agent-training-runner-supervised-pause-fixture-is-readable ()
  "Keep the generated child barrier syntactically loadable without a GPU."
  (let ((file (make-temp-file "nl-supervised-pause-syntax-")))
    (unwind-protect
        (progn
          (nl-agent-training-supervised-runner-resume-test--write-pause file)
          (with-temp-buffer
            (insert-file-contents file)
            (check-parens)
            (goto-char (point-min))
            (read (current-buffer))))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest nl-agent-training-runner-supervised-real-child-stop-resume ()
  "Stop after a supervised GPU checkpoint and explicitly resume the receipt."
  (unless (nl-llm-gpu-enable)
    (ert-skip "GPU backend unavailable; supervised runner resume requires Vulkan"))
  (nl-llm-gpu-disable)
  (let* ((temporary (make-temp-file "nl-supervised-runner-resume-" t))
         (catalog (expand-file-name "catalog.json" temporary))
         (queue-file (expand-file-name "queue.sexp" temporary))
         (recovery (expand-file-name "recovery" temporary))
         (fixture (expand-file-name "pause.el" temporary))
         (ready (expand-file-name "pause.ready" temporary))
         (release (expand-file-name "pause.release" temporary))
         (model (nl-llm-agent-improve-model
                 4 4 nl-llm-agent-char-vocab 1 1))
         (profile (nl-agent-training-supervised-runner-resume-test--profile
                   temporary catalog recovery))
         (score (nl-llm-agent-evolve-p5-evaluator ["ab"]))
         queue runner1 runner2 first-workdir)
    (unwind-protect
        (progn
          (nl-llm-agent-artifact-publish
           catalog (nl-llm-agent-artifact-export-pav model)
           :id "base-g0" :name "base"
           :grammar '(:type "done" :length 2 :allow "ab ")
           :maxseq 64 :score (funcall score model) :generation 0)
          (setq queue
                (nl-agent-training-supervised-runner-resume-test--queue
                 model catalog queue-file))
          (nl-llm-evolve-queue-submit
           queue "supervised-finetune"
           '(:examples [(:prompt "a" :completion "bb")
                       (:prompt "b" :completion "aa")
                       (:prompt "a" :completion "ab")]
             :lr 0.01 :epochs 2)
           :id "supervised-resume-job")
          (nl-agent-training-supervised-runner-resume-test--write-pause fixture)
          (setq runner1 (nl-agent-training-runner-new queue profile))
          (nl-agent-training-supervised-runner-resume-test--start
           runner1 fixture "supervised-resume-job")
          (setq first-workdir (nl-agent-training-runner-workdir runner1))
          (should
           (nl-agent-training-supervised-runner-resume-test--wait-file
            ready runner1))
          (should (file-regular-p
                   (expand-file-name "checkpoint.sexp" first-workdir)))
          (should-not (file-exists-p (expand-file-name "result.sexp" first-workdir)))
          (nl-agent-training-runner-stop runner1)
          (should (eq (nl-llm-evolve-queue-job-status
                       (nl-llm-evolve-queue--job queue "supervised-resume-job"))
                      'interrupted))
          (should (file-regular-p
                   (nl-agent-training-recovery-path
                    recovery (plist-get profile :scope)
                    "supervised-resume-job")))
          (setq runner2
                (nl-agent-training-runner-new
                 (nl-agent-training-supervised-runner-resume-test--queue
                  model catalog queue-file t)
                 profile))
          (nl-agent-training-supervised-runner-resume-test--start
           runner2 nil "supervised-resume-job" t)
          (should (equal (plist-get
                          (nl-agent-training-runner-request runner2) :kind)
                         "supervised-finetune"))
          (should (plist-member
                   (nl-agent-training-runner-request runner2) :resume-state))
          (nl-agent-training-supervised-runner-resume-test--wait-terminal runner2)
          (should (= (plist-get
                      (nl-agent-training-runner-status runner2) :generation)
                     1))
          (should (eq (nl-llm-evolve-queue-job-status
                       (nl-llm-evolve-queue--job
                        (nl-agent-training-runner-queue runner2)
                        "supervised-resume-job"))
                      'promoted))
          (should-not
           (file-exists-p
            (nl-agent-training-recovery-path
             recovery (plist-get profile :scope) "supervised-resume-job"))))
      (when (file-exists-p release) (delete-file release))
      (dolist (runner (list runner1 runner2))
        (when runner (ignore-errors (nl-agent-training-runner-stop runner))))
      (ignore-errors (nl-llm-gpu-disable))
      (when (file-directory-p temporary) (delete-directory temporary t)))))

(provide 'training-supervised-runner-resume-test)

(ert-run-tests-batch-and-exit)

;;; training-supervised-runner-resume-test.el ends here
