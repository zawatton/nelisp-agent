;;; background-resume-service-test.el --- durable GPU service resume -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'nl-agent-improvement-config)
(require 'nl-agent-improvement)
(require 'nl-agent-permission)
(require 'nl-agent-autonomy)
(require 'nl-agent-training-protocol)
(require 'nl-agent-training-recovery)
(require 'nl-agent-training-runner)
(require 'nl-llm-gpu)

(defun background-resume-service-test--write-config (file &optional objective)
  "Write one tiny resumable background GPU configuration to FILE.
OBJECTIVE selects the optional completion-only worker wire path."
  (let ((completion (equal objective "completion")))
  (with-temp-file file
    (insert
     (json-encode
      `(("format" . "nl-agent-improvement-v1")
        ("catalog" . "state/catalog.json")
        ("queueState" . "state/queue.sexp")
        ("providerId" . "native")
        ("providerName" . "resume test")
        ("idPrefix" . "resume")
        ("grammar" . (("type" . "message") ("length" . 8)))
        ("benchmark" . (("examples" . ,(if completion [" a"] ["ab" "ba"]))))
        ("model" . (("source" . "latest-or-new")
                     ("dim" . 2) ("ff" . 2) ("blocks" . 1)
                     ("heads" . 1) ("maxParameters" . 1000)))
        ("training" . ,(append
                         (when completion '(("objective" . "completion")))
                         `(("execution" . "background")
                           ("backend" . "gpu")
                           ("sequence" . ,(if completion 4 2))
                           ("optimizer" . "adam")
                           ("checkpointEvery" . 1)
                           ("checkpointDirectory" . "state/recovery"))))
        ("minDelta" . 0.0) ("maxSequence" . 16)
        ("maxPending" . 2) ("maxHistory" . 2))))
    (terpri (current-buffer)))))

(defun background-resume-service-test--write-barrier (file)
  "Write a child fixture that pauses after its first durable checkpoint."
  (with-temp-file file
    (insert
     ";;; background-resume-barrier.el --- test-only checkpoint barrier -*- lexical-binding: t; -*-\n"
     "(let* ((request-file (car (last command-line-args-left 2)))\n"
     "       (directory (file-name-directory request-file))\n"
     "       (ready (expand-file-name \"child.ready\" directory))\n"
     "       (release (expand-file-name \"child.release\" directory))\n"
     "       (original (symbol-function 'nl-llm-agent-ondevice-train)))\n"
     "  (fset 'nl-llm-agent-ondevice-train\n"
     "        (lambda (ctx trajs epochs &rest keys)\n"
     "          (let ((callback (plist-get keys :after-step))\n"
     "                (paused nil))\n"
     "            (setq keys\n"
     "                  (plist-put\n"
     "                   keys :after-step\n"
     "                   (lambda (active completed total)\n"
     "                     (when callback\n"
     "                       (funcall callback active completed total))\n"
     "                     (unless paused\n"
     "                       (setq paused t)\n"
     "                       (with-temp-file ready (insert \"ready\\n\"))\n"
     "                       (let ((deadline (+ (float-time) 20.0)))\n"
     "                         (while (and (not (file-exists-p release))\n"
     "                                     (< (float-time) deadline))\n"
     "                           (sleep-for 0.01)))\n"
     "                       (unless (file-exists-p release)\n"
     "                         (error \"checkpoint barrier timeout\"))))))\n"
     "            (apply original ctx trajs epochs keys)))))\n")))

(defun background-resume-service-test--inject-barrier (arguments fixture)
  "Insert a load of FIXTURE before --funcall in process ARGUMENTS."
  (let ((position (cl-position "--funcall" arguments :test #'equal)))
    (unless position
      (error "training worker command lacks --funcall: %S" arguments))
    (append (cl-subseq arguments 0 position)
            (list "-l" fixture)
            (nthcdr position arguments))))

(defun background-resume-service-test--start-with-barrier
    (runner id fixture &optional resuming)
  "Start ID on RUNNER with test FIXTURE injected into the real child."
  (let ((real-start-process (symbol-function 'start-process)))
    (cl-letf (((symbol-function 'start-process)
               (lambda (name buffer program &rest arguments)
                 (apply
                  real-start-process name buffer program
                  (if (equal name "nl-agent-training-worker")
                      (background-resume-service-test--inject-barrier
                       arguments fixture)
                    arguments)))))
      (nl-agent-training-runner-start runner id resuming))))

(defun background-resume-service-test--wait-file (file runner timeout)
  "Wait up to TIMEOUT seconds for FILE from RUNNER's live child."
  (let ((deadline (+ (float-time) timeout)))
    (while (and (not (file-exists-p file))
                (nl-agent-training-runner-process runner)
                (process-live-p (nl-agent-training-runner-process runner))
                (< (float-time) deadline))
      (accept-process-output (nl-agent-training-runner-process runner) 0.05))
    (file-exists-p file)))

(defun background-resume-service-test--wait-terminal (runner timeout)
  "Poll RUNNER for up to TIMEOUT seconds and return its terminal status."
  (let ((deadline (+ (float-time) timeout))
        status)
    (while (and (progn
                  (setq status (nl-agent-training-runner-status runner))
                  (plist-get status :worker-running))
                (< (float-time) deadline))
      (let ((process (nl-agent-training-runner-process runner)))
        (when process (accept-process-output process 0.05))))
    status))

(defun background-resume-service-test--run (&optional objective)
  "Stop, reload, and explicitly resume one GPU job.
OBJECTIVE is nil for the legacy path or `completion' for supervised wire data."
  (unless (nl-llm-gpu-enable)
    (ert-skip "GPU backend unavailable; background resume requires Vulkan"))
  (nl-llm-gpu-disable)
  (let* ((completion (equal objective "completion"))
         (kind (if completion "supervised-finetune" "trajectory-finetune"))
         (payload (if completion
                      '(:examples [(:prompt "  " :completion "a")]
                        :lr 0.1 :epochs 4)
                    '(:examples ["ab" "ba"] :lr 0.01 :epochs 2)))
         (directory (make-temp-file "background-resume-service-" t))
         (config-file (expand-file-name "config.json" directory))
         (fixture (expand-file-name "checkpoint-barrier.el" directory))
         (job-id "durable-job")
         first second first-runner second-runner receipt-path marker-path
         producing-attempt original-sequence original-metadata resumed-request)
    (unwind-protect
        (progn
          (background-resume-service-test--write-config config-file objective)
          (background-resume-service-test--write-barrier fixture)
          (setq first (nl-agent-improvement-config-load config-file)
                first-runner (plist-get first :runner))
          (let* ((queue (plist-get first :queue))
                 (submitted
                  (nl-llm-evolve-queue-submit
                   queue kind payload
                   :id job-id :metadata '(:logical-job "kept"))))
            (setq original-sequence (plist-get submitted :sequence)
                  original-metadata (plist-get submitted :metadata)))
          (background-resume-service-test--start-with-barrier
           first-runner job-id fixture)
          (let* ((workdir (nl-agent-training-runner-workdir first-runner))
                 (ready (expand-file-name "child.ready" workdir)))
            (should
             (background-resume-service-test--wait-file
              ready first-runner 10.0))
            (should (file-regular-p
                     (expand-file-name "checkpoint.sexp" workdir)))
            (let ((request
                   (nl-agent-training-protocol-read
                    (nl-agent-training-runner-request-file first-runner))))
              (if completion
                  (should (equal (plist-get request :kind)
                                 "supervised-finetune"))
                (should-not (plist-member request :kind)))))
          (setq producing-attempt
                (plist-get (nl-agent-training-runner-request first-runner)
                           :attempt))
          ;; Normal stop must persist recovery and queue interruption before
          ;; releasing all host ownership locks.
          (nl-agent-training-runner-stop first-runner)
          (setq first-runner nil)
          (let* ((profile (nl-agent-training-runner-profile
                           (plist-get first :runner)))
                 (scope (plist-get profile :scope))
                 (recovery-directory (plist-get profile :recovery-directory)))
            (setq receipt-path
                  (nl-agent-training-recovery-path
                   recovery-directory scope job-id)
                  marker-path
                  (nl-agent-training-recovery-marker-path
                   recovery-directory scope job-id))
            (should (file-regular-p receipt-path))
            (should-not (file-exists-p marker-path))
            (let ((receipt (nl-agent-training-recovery-load
                            recovery-directory scope job-id)))
              (should
               (equal producing-attempt
                      (plist-get (plist-get receipt :request) :attempt)))
              (when completion
                (let* ((request (plist-get receipt :request))
                       (state (plist-get (plist-get receipt :checkpoint)
                                         :state)))
                  (should (equal (plist-get state :format)
                                 nl-llm-agent-training-checkpoint-completion-format))
                  (should (= (plist-get state :completed-steps) 1))
                  (should (= (plist-get state :total-steps) 4))
                  (should (= (plist-get state :optimizer-step) 1))
                  (should (equal
                           (plist-get state :completion-plan)
                           (nl-agent-training-protocol-completion-plan request)))))))
          (should-not
           (file-locked-p (plist-get first :queue-state-file)))

          ;; Loading the identical service configuration reconstructs the same
          ;; logical interrupted job, but never starts work automatically.
          (setq second (nl-agent-improvement-config-load config-file)
                second-runner (plist-get second :runner))
          (let* ((queue (plist-get second :queue))
                 (job (nl-llm-evolve-queue--public-job
                       (nl-llm-evolve-queue--job queue job-id))))
            (should (eq (plist-get job :status) 'interrupted))
            (should (= (plist-get job :sequence) original-sequence))
            (should (equal (plist-get job :metadata) original-metadata))
            (should-not (nl-agent-training-runner-process second-runner)))

          (let* ((registry (nl-agent-tool-registry-new))
                 (denied-policy
                  (nl-agent-permission-policy-new :mode 'smart))
                 (approved-policy
                  (nl-agent-permission-policy-new
                   :mode 'smart
                   :approval
                   (nl-agent-autonomy-improvement-approval
                    "native" "resume")))
                 denied approved)
            (nl-agent-improvement-register-tools
             registry (plist-get second :queue) second-runner)
            (setq denied
                  (nl-agent-permission-call
                   denied-policy registry "model.improvement.resume"
                   (list :id job-id)))
            (should (eq (plist-get denied :status) 'denied))
            (should-not (nl-agent-training-runner-process second-runner))
            (should
             (eq (plist-get
                  (nl-llm-evolve-queue--public-job
                   (nl-llm-evolve-queue--job
                    (plist-get second :queue) job-id))
                  :status)
                 'interrupted))

            ;; Keep using the real tool dispatcher, but inject a barrier only
            ;; into this real child so its private resume request is observable.
            (let ((real-start-process (symbol-function 'start-process)))
              (cl-letf (((symbol-function 'start-process)
                         (lambda (name buffer program &rest arguments)
                           (apply
                            real-start-process name buffer program
                            (if (equal name "nl-agent-training-worker")
                                (background-resume-service-test--inject-barrier
                                 arguments fixture)
                              arguments)))))
                (setq approved
                      (nl-agent-permission-call
                       approved-policy registry "model.improvement.resume"
                       (list :id job-id)))))
            (should (eq (plist-get approved :status) 'ok))
            (should
             (eq (plist-get (plist-get approved :authorization) :source)
                 'autonomous-scope)))
          (let* ((workdir (nl-agent-training-runner-workdir second-runner))
                 (ready (expand-file-name "child.ready" workdir))
                 (release (expand-file-name "child.release" workdir)))
            (should
             (background-resume-service-test--wait-file
              ready second-runner 10.0))
            (setq resumed-request
                  (nl-agent-training-protocol-read
                   (nl-agent-training-runner-request-file second-runner)))
            (if completion
                (progn
                  (should (equal (plist-get resumed-request :kind)
                                 "supervised-finetune"))
                  (should (equal
                           (plist-get (plist-get resumed-request :resume-state)
                                      :format)
                           nl-llm-agent-training-checkpoint-completion-format))
                  (should (= (plist-get (plist-get resumed-request :resume-state)
                                        :completed-steps)
                             1))
                  (should (= (plist-get (plist-get resumed-request :resume-state)
                                        :total-steps)
                             4))
                  (should (= (plist-get (plist-get resumed-request :resume-state)
                                        :optimizer-step)
                             1))
                  (should (plist-member
                           (plist-get resumed-request :resume-state)
                           :completion-plan))
                  (should (equal
                           (plist-get (plist-get resumed-request :resume-state)
                                      :completion-plan)
                           (nl-agent-training-protocol-completion-plan
                            resumed-request))))
              (should-not (plist-member resumed-request :kind)))
            (should (plist-member resumed-request :resume-state))
            (should
             (equal (plist-get resumed-request :job-id) job-id))
            (should-not
             (equal (plist-get resumed-request :attempt) producing-attempt))
            (should (file-regular-p marker-path))
            (with-temp-file release (insert "release\n")))

          (let* ((status
                  (background-resume-service-test--wait-terminal
                   second-runner 20.0))
                 (queue (plist-get second :queue))
                 (job (nl-llm-evolve-queue--public-job
                       (nl-llm-evolve-queue--job queue job-id)))
                 (history (nl-llm-evolve-queue-history queue)))
            (should-not (plist-get status :worker-running))
            (should (= (plist-get status :generation) 1))
            (should (eq (plist-get job :status) 'promoted))
            (should (= (plist-get job :sequence) original-sequence))
            (should (equal (plist-get job :metadata) original-metadata))
            (should (= (length history) 1))
            (should (equal (plist-get (car history) :id) job-id))
            (should
             (plist-get
              (plist-get (plist-get job :result) :metadata)
              :resumed))
            (should
             (member
              "resume-g1"
              (mapcar
               (lambda (entry) (plist-get entry :id))
               (nl-llm-agent-artifact-catalog
                (plist-get second :catalog-file)))))
            (should-not (file-exists-p receipt-path))
            (should-not (file-exists-p marker-path))))
      (when first-runner
        (ignore-errors (nl-agent-training-runner-stop first-runner)))
      (when second-runner
        (ignore-errors (nl-agent-training-runner-stop second-runner)))
      (delete-directory directory t))))

(ert-deftest background-resume-service-restores-legacy-after-authorization ()
  "Stop at a real legacy GPU checkpoint and explicitly resume the job."
  (background-resume-service-test--run))

(ert-deftest background-resume-service-restores-completion-after-authorization ()
  "Stop at a supervised GPU checkpoint and explicitly resume the job."
  (background-resume-service-test--run "completion"))

(provide 'background-resume-service-test)

(ert-run-tests-batch-and-exit)

;;; background-resume-service-test.el ends here
