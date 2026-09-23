;;; background-config-test.el --- background training assembly tests -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'ert)
(require 'json)
(require 'nl-agent-improvement-config)
(require 'nl-agent-training-runner)

(defun background-config-test--write
    (file execution &optional extra training)
  (with-temp-file file
    (insert (json-encode
             `(("format" . "nl-agent-improvement-v1")
               ("catalog" . "state/catalog.json")
               ("queueState" . "state/queue.sexp")
               ("providerId" . "native")
               ("providerName" . "test")
               ("idPrefix" . "test")
               ("grammar" . (("type" . "message") ("length" . 8)))
               ("benchmark" . (("examples" . ["ab"])))
               ("model" . (("source" . "new") ("dim" . 2) ("ff" . 2)
                            ("blocks" . 1) ("heads" . 1)
                            ("maxParameters" . 1000)))
               ("training" . ,(append
                                `(("execution" . ,execution))
                                (or training
                                    '(("backend" . "cpu")
                                      ("sequence" . 8)
                                      ("optimizer" . "sgd")))))
               ("minDelta" . 0.0) ("maxSequence" . 16)
               ("maxPending" . 2) ("maxHistory" . 2)
               ,@extra)))
    (terpri (current-buffer))))

(ert-deftest background-config-defaults-to-synchronous-cpu-sgd ()
  (let* ((dir (make-temp-file "background-config-" t))
         (file (expand-file-name "config.json" dir))
         assembly)
    (unwind-protect
        (progn
          (background-config-test--write file "synchronous")
          (setq assembly (nl-agent-improvement-config-load file))
          (should (eq (plist-get assembly :training-execution) 'synchronous))
          (should (eq (plist-get assembly :training-backend) 'cpu))
          (should (eq (plist-get assembly :optimizer) 'sgd))
          (should-not (plist-get assembly :runner)))
      (when (and assembly (plist-get assembly :runner))
        (nl-agent-training-runner-stop (plist-get assembly :runner)))
      (delete-directory dir t))))

(ert-deftest background-config-assembles-private-cpu-runner-lock ()
  (let* ((dir (make-temp-file "background-config-" t))
         (file (expand-file-name "config.json" dir))
         assembly runner lock)
    (unwind-protect
        (progn
          (background-config-test--write file "background")
          (setq assembly (nl-agent-improvement-config-load file)
                runner (plist-get assembly :runner)
                lock (plist-get assembly :queue-state-file))
          (should (nl-agent-training-runner-p runner))
          (should (file-locked-p lock)))
      (when runner (nl-agent-training-runner-stop runner))
      (delete-directory dir t))))

(ert-deftest background-config-rejects-duplicate-ownership ()
  (let* ((dir (make-temp-file "background-config-" t))
         (file (expand-file-name "config.json" dir))
         (second (expand-file-name "second.json" dir))
         assembly)
    (unwind-protect
        (progn
          (background-config-test--write file "background")
          (setq assembly (nl-agent-improvement-config-load file))
          ;; A synchronous loader cannot restore the same queue while the
          ;; background owner is alive.
          (background-config-test--write second "synchronous")
          (should-error (nl-agent-improvement-config-load second))
          ;; Nor may a second queue share the artifact catalog.
          (with-temp-buffer
            (insert-file-contents second)
            (goto-char (point-min))
            (search-forward "state/queue.sexp")
            (replace-match "state/other-queue.sexp" t t)
            (write-region (point-min) (point-max) second nil 'silent))
          (should-error (nl-agent-improvement-config-load second)))
      (when (and assembly (plist-get assembly :runner))
        (nl-agent-training-runner-stop (plist-get assembly :runner)))
      (delete-directory dir t))))

(ert-deftest background-config-rejects-unsupported-execution ()
  (let* ((dir (make-temp-file "background-config-" t))
         (file (expand-file-name "config.json" dir)))
    (unwind-protect
        (progn
          (background-config-test--write file "threaded")
          (should-error (nl-agent-improvement-config-load file)))
      (delete-directory dir t))))

(ert-deftest background-config-accepts-resumable-gpu-runner-profile ()
  (let* ((dir (make-temp-file "background-config-" t))
         (file (expand-file-name "config.json" dir))
         (recovery (expand-file-name "state/train" dir))
         assembly runner)
    (unwind-protect
        (progn
          (background-config-test--write
           file "background" nil
           '(("backend" . "gpu") ("sequence" . 8)
             ("optimizer" . "adam") ("checkpointEvery" . 2)
             ("checkpointDirectory" . "state/train")))
          (setq assembly (nl-agent-improvement-config-load file)
                runner (plist-get assembly :runner))
          (let* ((profile (nl-agent-training-runner-profile runner))
                 (queue (plist-get assembly :queue))
                 (handler
                  (nl-llm-evolve-queue--handler
                   queue "trajectory-finetune")))
            (should (equal (plist-get profile :recovery-directory) recovery))
            (should (equal (plist-get profile :training)
                           '(:backend gpu :sequence 8 :optimizer adam
                             :checkpoint-every 2)))
            (should (equal (nl-llm-evolve-queue-catalog queue)
                           '((:kind "trajectory-finetune"
                              :description
                              "Fine-tune an isolated GPU-resident P5 challenger and read back once"
                              :resumable t))))
            (should (functionp
                     (nl-llm-evolve-queue-handler-resume-fn handler)))
            (should-not (nl-llm-evolve-queue-handler-finish-fn handler))
            (should-error
             (funcall (nl-llm-evolve-queue-handler-resume-fn handler)
                      nil nil nil))))
      (when runner (nl-agent-training-runner-stop runner))
      (delete-directory dir t))))

(ert-deftest background-config-rejects-cpu-checkpointing ()
  (let* ((dir (make-temp-file "background-config-" t))
         (file (expand-file-name "config.json" dir)))
    (unwind-protect
        (progn
          (background-config-test--write
           file "background" nil
           '(("backend" . "cpu") ("sequence" . 8)
             ("optimizer" . "sgd") ("checkpointEvery" . 1)
             ("checkpointDirectory" . "state/train")))
          (should-error (nl-agent-improvement-config-load file)))
      (delete-directory dir t))))

(ert-deftest background-config-rejects-checkpoint-without-directory ()
  (let* ((dir (make-temp-file "background-config-" t))
         (file (expand-file-name "config.json" dir)))
    (unwind-protect
        (progn
          (background-config-test--write
           file "background" nil
           '(("backend" . "gpu") ("sequence" . 8)
             ("optimizer" . "adam") ("checkpointEvery" . 1)))
          (should-error (nl-agent-improvement-config-load file)))
      (delete-directory dir t))))

(ert-deftest background-config-preserves-synchronous-gpu-checkpointing ()
  (let* ((dir (make-temp-file "background-config-" t))
         (file (expand-file-name "config.json" dir))
         assembly)
    (unwind-protect
        (progn
          (background-config-test--write
           file "synchronous" nil
           '(("backend" . "gpu") ("sequence" . 8)
             ("optimizer" . "adam") ("checkpointEvery" . 2)
             ("checkpointDirectory" . "state/train")))
          (setq assembly (nl-agent-improvement-config-load file))
          (let* ((queue (plist-get assembly :queue))
                 (handler
                  (nl-llm-evolve-queue--handler
                   queue "trajectory-finetune")))
            (should-not (plist-get assembly :runner))
            (should (= (plist-get assembly :checkpoint-every) 2))
            (should (functionp
                     (nl-llm-evolve-queue-handler-resume-fn handler)))
            (should (functionp
                     (nl-llm-evolve-queue-handler-finish-fn handler)))))
      (delete-directory dir t))))

(ert-run-tests-batch-and-exit)

;;; background-config-test.el ends here
