;;; supervised-config-test.el --- completion objective config tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'json)
(require 'nl-agent-improvement-config)
(require 'nl-agent-improvement)
(require 'nl-agent-permission)
(require 'nl-agent-training-runner)
(require 'nl-llm-evolve-queue)

(defun nl-agent-supervised-config-test--data (&optional objective execution)
  "Return a small JSON-alist configuration for OBJECTIVE and EXECUTION."
  `(("format" . ,nl-agent-improvement-config-format)
    ("catalog" . "state/catalog.json")
    ("queueState" . "state/queue.sexp")
    ("providerId" . "native")
    ("providerName" . "Supervised config test")
    ("idPrefix" . "config")
    ("grammar" . (("type" . "done") ("length" . 4)
                  ("allow" . "ab ")))
    ("benchmark" . (("examples" . ["ab"])))
    ("model" . (("source" . "new") ("dim" . 2) ("ff" . 2)
                 ("blocks" . 1) ("heads" . 1)
                 ("maxParameters" . 1000)))
    ("training" . ,(append
                     (when objective `(("objective" . ,objective)))
                     (when execution `(("execution" . ,execution)))
                     '(("backend" . "cpu") ("sequence" . 8)
                       ("optimizer" . "sgd"))))
    ("minDelta" . 0.0)
    ("maxSequence" . 16)
    ("maxPending" . 4)
    ("maxHistory" . 8)))

(defun nl-agent-supervised-config-test--write (file data)
  "Write JSON DATA to FILE."
  (with-temp-file file
    (insert (json-encode data))
    (terpri (current-buffer))))

(defun nl-agent-supervised-config-test--kinds (queue)
  "Return the registered proposal kinds in QUEUE."
  (mapcar (lambda (item) (plist-get item :kind))
          (nl-llm-evolve-queue-catalog queue)))

(defmacro nl-agent-supervised-config-test--with-config
    (bindings &rest body)
  "Bind a temporary JSON config FILE under DIRECTORY and run BODY."
  (declare (indent 1))
  (let ((directory (nth 0 bindings))
        (file (nth 1 bindings))
        (objective (nth 2 bindings))
        (execution (nth 3 bindings)))
    `(let* ((,directory (make-temp-file "nl-supervised-config-" t))
            (,file (expand-file-name "config.json" ,directory)))
     (unwind-protect
         (progn
           (nl-agent-supervised-config-test--write
            ,file
            (nl-agent-supervised-config-test--data ,objective ,execution))
           ,@body)
       (delete-directory ,directory t)))))

(ert-deftest nl-agent-supervised-config-defaults-to-trajectory-objective ()
  (nl-agent-supervised-config-test--with-config (directory file nil nil)
    (let* ((assembly (nl-agent-improvement-config-load file))
           (queue (plist-get assembly :queue)))
      (should (eq (plist-get assembly :training-objective) 'trajectory))
      (should (equal (nl-agent-supervised-config-test--kinds queue)
                     '("trajectory-finetune"))))))

(ert-deftest nl-agent-supervised-config-registers-completion-sync-and-background ()
  (dolist (execution '("synchronous" "background"))
    (nl-agent-supervised-config-test--with-config
        (directory file "completion" execution)
      (let* ((assembly (nl-agent-improvement-config-load file))
             (queue (plist-get assembly :queue))
             (runner (plist-get assembly :runner)))
        (unwind-protect
            (progn
              (should (eq (plist-get assembly :training-objective) 'completion))
              (should (equal (nl-agent-supervised-config-test--kinds queue)
                             '("trajectory-finetune" "supervised-finetune")))
              (if (equal execution "background")
                  (should (nl-agent-training-runner-p runner))
                (should-not runner)))
          (when runner (nl-agent-training-runner-stop runner)))))))

(ert-deftest nl-agent-supervised-config-allows-background-gpu-checkpoints ()
  (nl-agent-supervised-config-test--with-config
      (directory file "completion" "background")
    (let ((data (nl-agent-supervised-config-test--data
                 "completion" "background"))
          assembly)
      (setcdr (assoc "training" data)
              '(("objective" . "completion")
                ("execution" . "background")
                ("backend" . "gpu") ("sequence" . 8)
                ("optimizer" . "adam") ("checkpointEvery" . 2)
                ("checkpointDirectory" . "recovery")))
      (nl-agent-supervised-config-test--write file data)
      (let ((enable-calls 0))
        (cl-letf (((symbol-function 'nl-llm-gpu-enable)
                   (lambda () (setq enable-calls (1+ enable-calls)) t)))
          (setq assembly (nl-agent-improvement-config-load file))
          (should (= enable-calls 0))))
      (unwind-protect
          (let* ((queue (plist-get assembly :queue))
                 (runner (plist-get assembly :runner))
                 (handler (nl-llm-evolve-queue--handler
                           queue "supervised-finetune"))
                 (legacy-handler (nl-llm-evolve-queue--handler
                                  queue "trajectory-finetune")))
            (should (nl-agent-training-runner-p runner))
            (should (functionp
                     (nl-llm-evolve-queue-handler-resume-fn handler)))
            (should-not (nl-llm-evolve-queue-handler-finish-fn handler))
            (should (functionp
                     (nl-llm-evolve-queue-handler-resume-fn legacy-handler)))
            (should-not (nl-llm-evolve-queue-handler-finish-fn legacy-handler)))
        (when (plist-get assembly :runner)
          (nl-agent-training-runner-stop (plist-get assembly :runner)))))))

(ert-deftest nl-agent-supervised-config-restores-interrupted-job-as-resumable ()
  (nl-agent-supervised-config-test--with-config
      (directory file "completion" "background")
    (let ((data (nl-agent-supervised-config-test--data
                 "completion" "background"))
          first second)
      (setcdr (assoc "training" data)
              '(("objective" . "completion")
                ("execution" . "background")
                ("backend" . "gpu") ("sequence" . 8)
                ("optimizer" . "adam") ("checkpointEvery" . 2)
                ("checkpointDirectory" . "recovery")))
      (nl-agent-supervised-config-test--write file data)
      (setq first (nl-agent-improvement-config-load file))
      (let* ((queue (plist-get first :queue))
             (runner (plist-get first :runner))
             (claim nil))
        (unwind-protect
            (progn
              (nl-llm-evolve-queue-submit
               queue "supervised-finetune"
               '(:examples [(:prompt "a" :completion "b")]
                 :lr 0.1 :epochs 1)
               :id "interrupted-supervised")
              (setq claim
                    (nl-llm-evolve-queue-claim
                     queue "interrupted-supervised"))
              (nl-llm-evolve-queue-interrupt queue claim))
          (when runner (nl-agent-training-runner-stop runner)))
        (setq second (nl-agent-improvement-config-load file))
        (let* ((restored (plist-get second :queue))
               (job (nl-llm-evolve-queue--job
                     restored "interrupted-supervised"))
               (handler (nl-llm-evolve-queue--handler
                         restored "supervised-finetune")))
          (should (eq (nl-llm-evolve-queue-job-status job) 'interrupted))
          (should (functionp
                   (nl-llm-evolve-queue-handler-resume-fn handler)))
          (should-not (nl-llm-evolve-queue-handler-finish-fn handler))
          (should (functionp
                   (nl-llm-evolve-queue-handler-resume-fn
                    (nl-llm-evolve-queue--handler
                     restored "trajectory-finetune"))))
          (when (plist-get second :runner)
            (nl-agent-training-runner-stop (plist-get second :runner))))))))

(ert-deftest nl-agent-supervised-config-sync-gpu-enables-lazily-at-run ()
  (let* ((directory (make-temp-file "nl-supervised-config-gpu-" t))
         (file (expand-file-name "config.json" directory))
         (data (nl-agent-supervised-config-test--data
                "completion" "synchronous"))
         (calls 0)
         (trainer-calls 0)
         (trainer-args nil)
         (enabled t)
         assembly)
    (unwind-protect
        (progn
          (require 'nl-llm-gpu)
          (setcdr (assoc "training" data)
                  '(("objective" . "completion")
                    ("backend" . "gpu") ("sequence" . 8)
                    ("optimizer" . "adam")))
          (nl-agent-supervised-config-test--write file data)
          (cl-letf (((symbol-function 'nl-llm-gpu-enable)
                     (lambda ()
                       (setq calls (1+ calls))
                       enabled))
                    ((symbol-function 'nl-llm-agent-supervised-train)
                     (lambda (candidate examples &rest keys)
                       (setq trainer-calls (1+ trainer-calls)
                             trainer-args (list candidate examples keys))
                       :trained)))
            (setq assembly (nl-agent-improvement-config-load file))
            (should (= calls 0))
            (let* ((queue (plist-get assembly :queue))
                   (handler
                    (nl-llm-evolve-queue--handler
                     queue "supervised-finetune"))
                   (model
                    (nl-llm-evolution-champion
                     (nl-llm-evolve-queue-evolution queue)))
                   (payload
                    '(:examples [(:prompt "a" :completion "b")]
                      :lr 0.1 :epochs 1))
                   (result
                    (funcall (nl-llm-evolve-queue-handler-train-fn handler)
                             model payload nil)))
              (should (functionp
                       (nl-llm-evolve-queue-handler-train-fn handler)))
              (should (eq result :trained))
              (should (= calls 1))
              (should (= trainer-calls 1))
              (should (eq (nth 0 trainer-args) model))
              (should (equal (nth 1 trainer-args)
                             (plist-get payload :examples)))
              (should (equal (nth 2 trainer-args)
                             '(:backend gpu :lr 0.1 :epochs 1
                               :optimizer adam :sequence 8)))
              (setq enabled nil)
              (should-error
               (funcall (nl-llm-evolve-queue-handler-train-fn handler)
                        model payload nil))
              (should (= calls 2))
              (should (= trainer-calls 1)))))
      (when (and assembly (plist-get assembly :runner))
        (nl-agent-training-runner-stop (plist-get assembly :runner)))
      (delete-directory directory t))))

(ert-deftest nl-agent-supervised-config-restores-pending-supervised-job ()
  (nl-agent-supervised-config-test--with-config
      (directory file "completion" "synchronous")
    (let* ((first (nl-agent-improvement-config-load file))
           (queue (plist-get first :queue)))
      (nl-llm-evolve-queue-submit
       queue "supervised-finetune"
       '(:examples [(:prompt "a" :completion "b")] :lr 0.1 :epochs 1)
       :id "pending-supervised")
      (let* ((second (nl-agent-improvement-config-load file))
             (restored (plist-get second :queue))
             (job (nl-llm-evolve-queue--job restored "pending-supervised")))
        (should (eq (plist-get (nl-llm-evolve-queue-status restored) :pending)
                    1))
        (should (eq (nl-llm-evolve-queue-job-status job) 'pending))
        (should (equal (nl-agent-supervised-config-test--kinds restored)
                       '("trajectory-finetune" "supervised-finetune")))))))

(ert-deftest nl-agent-supervised-config-tools-submit-and-run-completion-job ()
  (nl-agent-supervised-config-test--with-config
      (directory file "completion" "synchronous")
    (let* ((assembly (nl-agent-improvement-config-load file))
           (queue (plist-get assembly :queue))
           (registry (nl-agent-tool-registry-new))
           (policy (nl-agent-permission-policy-new :mode 'off)))
      (nl-agent-improvement-register-tools registry queue)
      (let ((submitted
             (nl-agent-permission-call
              policy registry "model.improvement.submit"
              '(:kind "supervised-finetune"
                :payload (:examples [(:prompt "a" :completion "b")]
                           :lr 0.1 :epochs 4)
                :id "tool-supervised")))
            ran)
        (setq ran
              (nl-agent-permission-call
               policy registry "model.improvement.run"
               '(:id "tool-supervised")))
        (should (eq (plist-get submitted :status) 'ok))
        (should (eq (plist-get ran :status) 'ok))
        (should (memq (plist-get (plist-get ran :value) :status)
                      '(promoted rejected)))))))

(ert-deftest nl-agent-supervised-config-rejects-invalid-objective-values ()
  (dolist (value '("unknown"))
    (nl-agent-supervised-config-test--with-config
        (directory file value "synchronous")
      (should-error (nl-agent-improvement-config-load file))))
  (nl-agent-supervised-config-test--with-config
      (directory file nil "synchronous")
    (let ((data (nl-agent-supervised-config-test--data
                 nil "synchronous")))
      (setcdr (assoc "training" data)
              '(("objective" . nil) ("backend" . "cpu")))
      (nl-agent-supervised-config-test--write file data)
      (should-error (nl-agent-improvement-config-load file))))
  ;; JSON only carries strings; the private normalizer still rejects symbols.
  (should-error
   (nl-agent-improvement-config--training-spec
    '(:objective completion) '(:dim 2 :heads 1) ".")))

(ert-deftest nl-agent-supervised-config-rejects-completion-checkpoint-keys-before-state ()
  (dolist (training
           '(((:backend . "cpu") (:checkpointEvery . 0))
             ((:backend . "cpu") (:checkpointDirectory . "state/train"))
             ((:backend . "gpu") (:execution . "synchronous")
              (:optimizer . "adam") (:checkpointEvery . 2)
              (:checkpointDirectory . "state/train"))
             ((:backend . "gpu") (:execution . "background")
              (:optimizer . "adam") (:checkpointEvery . 0)
              (:checkpointDirectory . "state/train"))
             ((:backend . "gpu") (:execution . "background")
              (:optimizer . "adam") (:checkpointEvery . 2))
             ((:backend . "cpu") (:execution . "background")
              (:checkpointEvery . 2)
              (:checkpointDirectory . "state/train"))))
    (nl-agent-supervised-config-test--with-config
        (directory file "completion" "synchronous")
      (let ((alist-training
            (mapcar (lambda (pair)
                       (cons (substring (symbol-name (car pair)) 1)
                             (cdr pair)))
                     training))
            data)
        (setq data (nl-agent-supervised-config-test--data
                    "completion" "synchronous"))
        (setcdr (assoc "training" data)
                (cons '("objective" . "completion") alist-training))
        (nl-agent-supervised-config-test--write file data)
        (should-error (nl-agent-improvement-config-load file))
        (should-not (file-directory-p (expand-file-name "state" directory)))))))

(provide 'supervised-config-test)

(ert-run-tests-batch-and-exit)

;;; supervised-config-test.el ends here
