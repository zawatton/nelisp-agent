;;; improvement-config-test.el --- packaged self-evolution config tests  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'json)
(require 'nl-agent-improvement-config)
(require 'nl-agent-cli)

(defvar nl-agent-improvement-config-test--fail 0)

(defun nl-agent-improvement-config-test--ck (name ok)
  (princ (format "%-70s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-improvement-config-test--fail
                         (1+ nl-agent-improvement-config-test--fail))
                   "FAIL"))))

(defun nl-agent-improvement-config-test--error-p (thunk)
  (condition-case nil
      (progn (funcall thunk) nil)
    (error t)))

(defun nl-agent-improvement-config-test--write (path data)
  (with-temp-file path
    (insert (json-encode data))
    (terpri (current-buffer))))

(defun nl-agent-improvement-config-test--data ()
  `(("format" . ,nl-agent-improvement-config-format)
    ("catalog" . "state/catalog.json")
    ("queueState" . "state/queue.sexp")
    ("providerId" . "native")
    ("providerName" . "Self-evolved test models")
    ("idPrefix" . "self")
    ("grammar" . (("type" . "done") ("length" . 4)
                   ("allow" . "ab ")))
    ("benchmark" . (("examples" . [" a"])))
    ("model" . (("source" . "latest-or-new")
                 ("dim" . 2) ("ff" . 2) ("blocks" . 1)
                 ("heads" . 1) ("maxParameters" . 1000)))
    ("training" . (("backend" . "cpu")))
    ("minDelta" . 0.0)
    ("maxSequence" . 128)
    ("maxPending" . 4)
    ("maxHistory" . 8)))

(let* ((directory (make-temp-file "nl-agent-improvement-config-" t))
       (config-file (expand-file-name "improvement.json" directory)))
  (unwind-protect
      (progn
        (nl-agent-improvement-config-test--write
         config-file (nl-agent-improvement-config-test--data))
        (let* ((assembly (nl-agent-improvement-config-load config-file))
               (queue (plist-get assembly :queue))
               (provider (plist-get assembly :provider))
               (registry (nl-llm-agent-provider-registry-new)))
          (nl-llm-agent-provider-register registry provider)
          (nl-agent-improvement-config-test--ck
           "one data file assembles an initially empty native provider and queue"
           (and (nl-llm-evolve-queue-p queue)
                (equal (plist-get assembly :model-source) "new")
                (eq (plist-get assembly :training-backend) 'cpu)
                (eq (plist-get assembly :optimizer) 'sgd)
                (= (plist-get assembly :parameter-count) 528)
                (null (nl-llm-agent-provider-models registry))))
          (nl-llm-evolve-queue-submit
           queue "trajectory-finetune"
           '(:examples [" a"] :lr 0.1 :epochs 4)
           :id "learn-a")
          (let ((result (nl-llm-evolve-queue-run queue "learn-a")))
            (nl-agent-improvement-config-test--ck
             "configured fixed benchmark publishes only a measured improvement"
             (and (eq (plist-get result :status) 'promoted)
                  (equal
                   (mapcar
                    (lambda (model) (plist-get model :qualified-id))
                    (nl-llm-agent-provider-models registry))
                   '("native/self-g1")))))
          (nl-agent-improvement-config-test--ck
           "configuration-relative catalog and queue state are private durable files"
           (let ((catalog (plist-get assembly :catalog-file))
                 (state (plist-get assembly :queue-state-file)))
             (and (file-regular-p catalog) (file-regular-p state)
                  (= (logand (file-modes catalog) #o777) #o600)
                  (= (logand (file-modes state) #o777) #o600))))
          (let* ((resumed (nl-agent-improvement-config-load config-file))
                 (resumed-queue (plist-get resumed :queue))
                 (evolution (nl-llm-evolve-queue-evolution resumed-queue)))
            (nl-agent-improvement-config-test--ck
             "restart resumes the latest trainable champion and queue audit"
             (and (equal (plist-get resumed :model-source) "self-g1")
                  (= (nl-llm-evolution-generation evolution) 1)
                  (pav-p
                   (plist-get (nl-llm-evolution-champion evolution) :wh))
                  (= (plist-get
                      (nl-llm-evolve-queue-status resumed-queue) :completed)
                     1))))
          (let ((supervisor
                 (nl-agent-cli--supervisor
                  (list :base-url "https://provider.invalid/v1"
                        :improvement-config config-file
                        :autonomous-improvement t
                        :workspace directory)
                  nil)))
            (unwind-protect
                (nl-agent-improvement-config-test--ck
                 "CLI exposes remote, evolved model, and guarded evolution on one service"
                 (let ((models
                        (funcall
                         (nl-agent-supervisor-model-catalog-fn supervisor)))
                       (tools
                        (funcall
                         (nl-agent-supervisor-tool-catalog-fn supervisor))))
                   (and
                    (member "native/self-g1"
                            (mapcar
                             (lambda (item)
                               (plist-get item :qualified-id))
                             models))
                    (member "model.improvement.submit"
                            (mapcar
                             (lambda (item) (plist-get item :name)) tools))
                    (member "model.improvement.resume"
                            (mapcar
                             (lambda (item) (plist-get item :name)) tools))
                    (member "service.model.switch"
                            (mapcar
                             (lambda (item) (plist-get item :name)) tools)))))
              (nl-agent-improvement-config-test--ck
               "host autonomy executes bounded evolution but still denies shell and remote switch"
               (let ((call (nl-agent-supervisor-tool-fn supervisor)))
                 (and
                  (string-match-p
                   "autonomous-probe"
                   (funcall
                    call
                    '(:event tool :tool "model.improvement.submit"
                      :args
                      (:kind "trajectory-finetune"
                       :payload (:examples [" a"] :lr 0.1 :epochs 1)
                       :id "autonomous-probe"))))
                  (equal
                   (funcall
                    call
                    '(:event tool :tool "service.model.switch"
                      :args (:selector "native/self-g1")))
                   "native/self-g1")
                  (nl-agent-improvement-config-test--error-p
                   (lambda ()
                     (funcall
                      call
                      '(:event tool :tool "shell"
                        :args (:command "pwd")))))
                  (nl-agent-improvement-config-test--error-p
                   (lambda ()
                     (funcall
                      call
                      '(:event tool :tool "service.model.switch"
                        :args
                        (:selector
                         "remote/poolside/laguna-s-2.1:free"))))))))
              (nl-agent-supervisor-stop supervisor))))
        (let ((gpu-data (nl-agent-improvement-config-test--data)))
          (setcdr (assoc "training" gpu-data)
                  '(("backend" . "gpu") ("sequence" . 64)
                    ("optimizer" . "adam")
                    ("checkpointDirectory" . "state/training")
                    ("checkpointEvery" . 2)))
          (nl-agent-improvement-config-test--write config-file gpu-data)
          (let ((gpu-assembly
                 (nl-agent-improvement-config-load config-file)))
            (nl-agent-improvement-config-test--ck
             "data-only config selects resumable lightweight GPU training without callbacks"
             (and (eq (plist-get gpu-assembly :training-backend) 'gpu)
                  (= (plist-get gpu-assembly :training-sequence) 64)
                  (eq (plist-get gpu-assembly :optimizer) 'adam)
                  (= (plist-get gpu-assembly :checkpoint-every) 2)
                  (equal
                   (nl-llm-evolve-queue-catalog
                    (plist-get gpu-assembly :queue))
                   '((:kind "trajectory-finetune"
                      :description
                      "Fine-tune a resumable GPU-resident P5 challenger with bounded checkpoints"
                      :resumable t)))))))
        (let ((invalid-checkpoint
               (nl-agent-improvement-config-test--data)))
          (setcdr
           (assoc "training" invalid-checkpoint)
           '(("backend" . "cpu")
             ("checkpointDirectory" . "state/training")
             ("checkpointEvery" . 1)))
          (nl-agent-improvement-config-test--write
           config-file invalid-checkpoint)
          (nl-agent-improvement-config-test--ck
           "checkpoint recovery cannot be enabled on a non-resident CPU trainer"
           (nl-agent-improvement-config-test--error-p
            (lambda ()
              (nl-agent-improvement-config-load config-file)))))
        (let ((unsafe (nl-agent-improvement-config-test--data)))
          (setq unsafe (append unsafe '(("trainer" . "eval-user-code"))))
          (nl-agent-improvement-config-test--write config-file unsafe)
          (nl-agent-improvement-config-test--ck
           "configuration cannot name or inject a training callback"
           (nl-agent-improvement-config-test--error-p
            (lambda ()
              (nl-agent-improvement-config-load config-file)))))
        (let* ((limited (nl-agent-improvement-config-test--data))
               (model (cdr (assoc "model" limited))))
          (setcdr (assoc "maxParameters" model) 100)
          (nl-agent-improvement-config-test--write config-file limited)
          (nl-agent-improvement-config-test--ck
           "declared parameter budget is enforced before model allocation"
           (nl-agent-improvement-config-test--error-p
            (lambda ()
              (nl-agent-improvement-config-load config-file))))))
    (delete-directory directory t)))

(let* ((directory (make-temp-file "nl-agent-improvement-utf8-config-" t))
       (config-file (expand-file-name "improvement.json" directory))
       (data (nl-agent-improvement-config-test--data))
       (model (cdr (assoc "model" data))))
  (unwind-protect
      (progn
        (setq model (append model '(("tokenizer" . "utf8-byte-v1"))))
        (setcdr (assoc "maxParameters" model) 2000)
        (setcdr (assoc "model" data) model)
        (setcdr (assoc "training" data) '(("backend" . "cpu")))
        (setcdr (assoc "benchmark" data)
                '(("examples" . ["評価 日本"])))
        (nl-agent-improvement-config-test--write config-file data)
        (let ((assembly (nl-agent-improvement-config-load config-file)))
          (nl-agent-improvement-config-test--ck
           "UTF-8 tokenizer selects vocab 256 and its exact parameter budget"
           (and
            (equal (plist-get assembly :tokenizer) "utf8-byte-v1")
            (= (plist-get assembly :parameter-count)
               (nl-agent-improvement-config--parameter-count 2 2 1 256))
            (equal
             (plist-get
              (nl-llm-evolution-champion
              (nl-llm-evolve-queue-evolution
                (plist-get assembly :queue)))
              :tokenizer)
             "utf8-byte-v1")))
          (nl-llm-agent-artifact-publish
           (plist-get assembly :catalog-file)
           (nl-llm-agent-artifact-export-pav
            (nl-llm-agent-improve-model 2 2 nil 1 1))
           :id "self-g1" :name "Legacy ASCII candidate"
           :grammar '(:type "done" :length 1 :allow "a")
           :maxseq 128 :score 0.0 :generation 1)
          (nl-agent-improvement-config-test--ck
           "latest artifact tokenizer must match configured model identity"
           (nl-agent-improvement-config-test--error-p
            (lambda ()
              (nl-agent-improvement-config-load config-file))))))
    (delete-directory directory t)))

(princ (format "NL-AGENT-IMPROVEMENT-CONFIG %s (%d failures)\n"
               (if (= nl-agent-improvement-config-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-improvement-config-test--fail))
(kill-emacs (if (= nl-agent-improvement-config-test--fail 0) 0 1))

;;; improvement-config-test.el ends here
