;;; nl-agent-improvement-config.el --- data-only self-evolution assembly  -*- lexical-binding: t; -*-

;; Keep product configuration separate from training implementation.  This
;; host-only loader turns bounded JSON data into one fixed P5 evaluator, durable
;; proposal queue, immutable artifact publisher, and dynamic native provider.
;; No function name or callback is accepted from the configuration file.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'nl-llm-agent-improve)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-tokenizer)
(require 'nl-llm-agent-supervised-evolve)
(require 'nl-agent-task-promotion)
(require 'nl-agent-task-audit)
(defvar read-eval)

(defvar nl-agent-training-protocol-max-parameters)
(declare-function nl-agent-training-runner-new "nl-agent-training-runner"
                  (queue profile))
(declare-function nl-agent-training-runner-stop "nl-agent-training-runner"
                  (runner))
(declare-function nl-llm-gpu-enable "nl-llm-gpu" ())

(defconst nl-agent-improvement-config-format
  "nl-agent-improvement-v1"
  "Supported data-only improvement configuration format.")

(defconst nl-agent-improvement-config-max-bytes (* 1024 1024)
  "Maximum accepted improvement configuration size.")

(defconst nl-agent-improvement-config-hard-parameter-limit 250000000
  "Hard upper parameter budget accepted by this CPU P5 assembler.")

(defconst nl-agent-improvement-config--task-manifest-format
  "nl-agent-task-promotion-manifest-v1")

(defun nl-agent-improvement-config--stable-digest (value)
  "Return a deterministic digest for bounded data VALUE."
  (let ((print-length nil)
        (print-level nil)
        (print-circle nil)
        (print-escape-nonascii t)
        (float-output-format "%.17g"))
    (secure-hash 'sha256 (prin1-to-string value))))

(defun nl-agent-improvement-config--task-promotion-spec
    (spec training directory)
  "Validate JSON task-promotion SPEC and return canonical settings, or nil.

The returned plist contains the detached policy and the configuration-relative
audit directory.  This helper performs no model, queue, lock, or filesystem
mutation."
  (when (plist-member spec :taskPromotion)
    (let ((value (plist-get spec :taskPromotion)))
      (unless (and (listp value) value)
        (error "taskPromotion must be a JSON object"))
      (nl-agent-improvement-config--keys
       value '(:suite :grammar :maxSequence :maxSteps :auditDirectory)
       "improvement taskPromotion")
      (dolist (key '(:suite :grammar :maxSequence :maxSteps :auditDirectory))
        (unless (plist-member value key)
          (error "improvement taskPromotion requires %S" key)))
      (unless (eq (plist-get training :execution) 'background)
        (error "taskPromotion requires background training"))
      (let* ((max-sequence
              (nl-agent-improvement-config--integer
               value :maxSequence 1 nl-agent-task-promotion-max-sequence
               "improvement taskPromotion"))
             (max-steps
              (nl-agent-improvement-config--integer
               value :maxSteps 1 nl-agent-task-promotion-max-steps
               "improvement taskPromotion"))
             (policy
              (nl-agent-task-promotion-policy
               (list :suite (plist-get value :suite)
                     :grammar (plist-get value :grammar)
                     :max-sequence max-sequence
                     :max-steps max-steps)))
             (audit-directory
              (nl-agent-improvement-config--path
               (plist-get value :auditDirectory) directory
               "improvement taskPromotion auditDirectory")))
        (nl-agent-task-audit--directory audit-directory)
        (when (and (file-exists-p audit-directory)
                   (not (file-directory-p audit-directory)))
          (error "taskPromotion auditDirectory is not a directory"))
        (list :policy policy :audit-directory audit-directory)))))

(defun nl-agent-improvement-config--task-manifest-path (queue-state-file)
  "Return canonical sidecar path for QUEUE-STATE-FILE."
  (concat (file-truename queue-state-file) ".task-promotion"))

(defun nl-agent-improvement-config--read-task-manifest (file)
  "Read and validate immutable task policy manifest FILE."
  (when (file-symlink-p file)
    (error "task-promotion manifest may not be a symlink: %s" file))
  (unless (file-regular-p file)
    (error "task-promotion manifest is not a regular file: %s" file))
  (when (> (file-attribute-size (file-attributes file)) 65536)
    (error "task-promotion manifest is too large"))
  (with-temp-buffer
    (let ((read-eval nil)
          (coding-system-for-read 'utf-8))
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((manifest (read (current-buffer))))
        (skip-chars-forward " \t\r\n")
        (unless (eobp)
          (error "task-promotion manifest has trailing data"))
        (nl-agent-improvement-config--keys
         manifest '(:format :policy-digest :audit-directory)
         "task-promotion manifest")
        (dolist (key '(:format :policy-digest :audit-directory))
          (unless (plist-member manifest key)
            (error "task-promotion manifest requires %S" key)))
        manifest))))

(defun nl-agent-improvement-config--task-manifest-state
    (queue-state-file task-spec)
  "Preflight task policy sidecar for QUEUE-STATE-FILE.

Return a plist containing :path and :write when a first immutable manifest
must be installed.  Existing policy sidecars must match exactly."
  (let* ((path (nl-agent-improvement-config--task-manifest-path
                queue-state-file))
         (has-manifest (or (file-exists-p path) (file-symlink-p path)))
         (policy (and task-spec (plist-get task-spec :policy)))
         (audit (and task-spec (plist-get task-spec :audit-directory)))
         (policy-digest (and policy
                             (nl-agent-improvement-config--stable-digest
                              policy)))
         (expected
          (and task-spec
               (list :format nl-agent-improvement-config--task-manifest-format
                     :policy-digest policy-digest
                     :audit-directory audit))))
    (cond
     ((not task-spec)
      (when has-manifest
        (error "queue has a task-promotion manifest; taskPromotion is required")))
     (has-manifest
      (unless (equal (nl-agent-improvement-config--read-task-manifest path)
                     expected)
        (error "task-promotion manifest does not match this configuration")))
     ((file-exists-p queue-state-file)
      ;; An old queue has no trustworthy policy binding.  Reusing it would
      ;; allow a changed/removed policy to govern an outstanding job.
      (error "taskPromotion requires a new queueState when no policy manifest exists")))
    (list :path path :write (and task-spec (not has-manifest)) :manifest expected)))

(defun nl-agent-improvement-config--write-task-manifest (file manifest)
  "Atomically install immutable MANIFEST at FILE without overwriting it."
  (when (or (file-exists-p file) (file-symlink-p file))
    (error "task-promotion manifest already exists: %s" file))
  (let ((temporary (make-temp-file (expand-file-name ".task-promotion-"
                                                      (file-name-directory file)))))
    (unwind-protect
        (progn
          (set-file-modes temporary #o600)
          (with-temp-file temporary
            (let ((print-length nil) (print-level nil) (print-circle nil)
                  (print-escape-nonascii t))
              (insert (prin1-to-string manifest))
              (insert "\n")))
          (rename-file temporary file nil))
      (when (file-exists-p temporary)
        (delete-file temporary)))))

(defun nl-agent-improvement-config--keys (value allowed where)
  "Validate JSON object VALUE against ALLOWED keys for WHERE."
  (unless (and (listp value) (= (% (length value) 2) 0))
    (error "%s must be a JSON object" where))
  (let ((tail value) seen)
    (while tail
      (let ((key (car tail)))
        (when (memq key seen)
          (error "%s contains duplicate key %S" where key))
        (push key seen)
        (unless (memq key allowed)
          (error "%s contains unknown key %S" where key)))
      (setq tail (cddr tail))))
  value)

(defun nl-agent-improvement-config--required-string (object key where)
  "Return non-empty string KEY from OBJECT for WHERE."
  (let ((value (plist-get object key)))
    (unless (and (stringp value) (not (string-empty-p value)))
      (error "%s requires non-empty %S" where key))
    value))

(defun nl-agent-improvement-config--identifier (value where)
  "Return bounded service identifier VALUE for WHERE."
  (unless (and (stringp value)
               (<= 1 (length value)) (<= (length value) 128)
               (string-match-p "\\`[A-Za-z0-9_.-]+\\'" value))
    (error "%s has invalid identifier %S" where value))
  value)

(defun nl-agent-improvement-config--integer
    (object key minimum maximum where)
  "Return required integer KEY from OBJECT within bounds for WHERE."
  (let ((value (plist-get object key)))
    (unless (and (integerp value) (<= minimum value) (<= value maximum))
      (error "%s %S must be an integer in [%d, %d]"
             where key minimum maximum))
    value))

(defun nl-agent-improvement-config--number
    (object key default minimum where)
  "Return numeric KEY from OBJECT or DEFAULT, bounded below by MINIMUM."
  (let ((value (if (plist-member object key)
                   (plist-get object key)
                 default)))
    (unless (and (numberp value) (= value value) (>= value minimum))
      (error "%s %S must be a finite number >= %s"
             where key minimum))
    value))

(defun nl-agent-improvement-config--path (value directory where)
  "Resolve non-empty path VALUE relative to DIRECTORY for WHERE."
  (unless (and (stringp value) (not (string-empty-p value)))
    (error "%s must be a non-empty path" where))
  (expand-file-name value directory))

(defun nl-agent-improvement-config--parameter-count
    (dim ff blocks vocab)
  "Return exact dense P5 parameter count for DIM, FF, BLOCKS, and VOCAB."
  (+ (* 2 vocab dim) vocab dim
     (* blocks
        (+ (* 4 dim dim) (* 3 ff dim) (* 7 dim) (* 2 ff)))))

(defun nl-agent-improvement-config--model-spec (spec)
  "Validate JSON model SPEC and return normalized settings."
  (nl-agent-improvement-config--keys
   spec '(:source :dim :ff :blocks :heads :tokenizer :maxParameters)
   "improvement model")
  (let* ((source
          (or (plist-get spec :source) "latest-or-new"))
         (tokenizer
          (nl-llm-agent-tokenizer-id (plist-get spec :tokenizer)))
         (vocab (nl-llm-agent-tokenizer-vocab tokenizer))
         (dim
          (nl-agent-improvement-config--integer
           spec :dim 1 4096 "improvement model"))
         (ff
          (nl-agent-improvement-config--integer
           spec :ff 1 16384 "improvement model"))
         (blocks
          (nl-agent-improvement-config--integer
           spec :blocks 1 128 "improvement model"))
         (heads
          (nl-agent-improvement-config--integer
           spec :heads 1 128 "improvement model"))
         (budget
          (nl-agent-improvement-config--integer
           spec :maxParameters 1
           nl-agent-improvement-config-hard-parameter-limit
           "improvement model"))
         (parameters
          (nl-agent-improvement-config--parameter-count
           dim ff blocks vocab)))
    (unless (member source '("latest-or-new" "latest" "new"))
      (error "improvement model has unsupported source %S" source))
    (unless (= (% dim heads) 0)
      (error "improvement model heads must divide dim"))
    (when (> parameters budget)
      (error "improvement model requires %d parameters, budget is %d"
             parameters budget))
    (list :source source :dim dim :ff ff :blocks blocks :heads heads
          :tokenizer tokenizer :vocab vocab
          :max-parameters budget :parameters parameters)))

(defun nl-agent-improvement-config--training-spec (spec model directory)
  "Validate data-only training SPEC for normalized MODEL settings."
  (setq spec (or spec '()))
  (nl-agent-improvement-config--keys
   spec '(:backend :sequence :optimizer :execution
          :checkpointDirectory :checkpointEvery :objective)
   "improvement training")
  (let* ((objective
          (if (plist-member spec :objective)
              (let ((value (plist-get spec :objective)))
                (cond ((equal value "trajectory") 'trajectory)
                      ((equal value "completion") 'completion)
                      (t (error "improvement training has unsupported objective %S"
                                value))))
            'trajectory))
         ;; Completion checkpoints are supported only by the isolated
         ;; background GPU worker.  Reject every other combination before
         ;; queue/path assembly or any state write.
         (_completion-checkpoint-guard
          (when (and (eq objective 'completion)
                     (or (plist-member spec :checkpointEvery)
                         (plist-member spec :checkpointDirectory)))
            (unless (and (equal (plist-get spec :backend) "gpu")
                         (equal (plist-get spec :execution) "background")
                         (plist-member spec :checkpointEvery)
                         (integerp (plist-get spec :checkpointEvery))
                         (> (plist-get spec :checkpointEvery) 0)
                         (plist-member spec :checkpointDirectory)
                         (stringp (plist-get spec :checkpointDirectory))
                         (not (string-empty-p
                               (plist-get spec :checkpointDirectory))))
              (error "completion checkpoints require background GPU training, positive checkpointEvery, and checkpointDirectory"))))
         (backend-text (or (plist-get spec :backend) "cpu"))
         (execution-text (or (plist-get spec :execution) "synchronous"))
         (execution
          (cond ((equal execution-text "synchronous") 'synchronous)
                ((equal execution-text "background") 'background)
                (t (error "unsupported training execution %S" execution-text))))
         (optimizer-text (or (plist-get spec :optimizer) "sgd"))
         (backend
          (cond ((equal backend-text "cpu") 'cpu)
                ((equal backend-text "gpu") 'gpu)
                (t (error "improvement training has unsupported backend %S"
                          backend-text))))
         (optimizer
          (cond ((equal optimizer-text "sgd") 'sgd)
                ((equal optimizer-text "adam") 'adam)
                (t (error "improvement training has unsupported optimizer %S"
                          optimizer-text))))
         (sequence
          (if (plist-member spec :sequence)
              (nl-agent-improvement-config--integer
               spec :sequence 2 nl-llm-agent-evolve-max-training-sequence
               "improvement training")
            256))
         (checkpoint-every
          (if (plist-member spec :checkpointEvery)
              (nl-agent-improvement-config--integer
               spec :checkpointEvery 0 1000000 "improvement training")
            0))
         (checkpoint-value (plist-get spec :checkpointDirectory))
         (checkpoint-directory
          (and checkpoint-value
               (nl-agent-improvement-config--path
                checkpoint-value directory
                "improvement training checkpoint directory"))))
    (when (and (eq backend 'cpu) (not (eq optimizer 'sgd)))
      (error "improvement CPU training supports only SGD"))
    (when (and (eq backend 'gpu)
               (/= (% (/ (plist-get model :dim)
                            (plist-get model :heads))
                         2)
                   0))
      (error "improvement GPU training requires an even head dimension"))
    (when (and (> checkpoint-every 0) (not (eq backend 'gpu)))
      (error "resumable improvement checkpoints require GPU training"))
    (when (and (> checkpoint-every 0) (not checkpoint-directory))
      (error "resumable improvement training requires checkpointDirectory"))
    (when (and checkpoint-directory (= checkpoint-every 0))
      (error "checkpointDirectory requires a positive checkpointEvery"))
    (when (eq execution 'background)
      (require 'nl-agent-training-runner)
      (when (> (plist-get model :parameters)
               nl-agent-training-protocol-max-parameters)
        (error "background model exceeds the worker parameter budget")))
    (list :objective objective :backend backend :sequence sequence :optimizer optimizer
          :execution execution
          :checkpoint-directory checkpoint-directory
          :checkpoint-every checkpoint-every)))

(defun nl-agent-improvement-config--latest (catalog-file id-prefix)
  "Return newest public artifact in CATALOG-FILE for ID-PREFIX, or nil."
  (let ((best nil)
        (seen-generations nil)
        (pattern
         (concat "\\`" (regexp-quote id-prefix) "-g\\([0-9]+\\)\\'")))
    (dolist (entry
             (nl-llm-agent-artifact-catalog catalog-file t))
      (let ((id (plist-get entry :id)))
        (when (string-match pattern id)
          (let ((suffix (string-to-number (match-string 1 id)))
                (generation (plist-get entry :generation)))
            (unless (= suffix generation)
              (error "artifact %s generation metadata is inconsistent" id))
            (when (member generation seen-generations)
              (error "artifact prefix %s has duplicate generation %d"
                     id-prefix generation))
            (setq seen-generations (cons generation seen-generations))
            (when (or (null best)
                      (> generation (plist-get best :generation)))
              (setq best entry))))))
    best))

(defun nl-agent-improvement-config--model
    (settings catalog-file id-prefix)
  "Return (MODEL . SOURCE) selected by SETTINGS and artifact state."
  (let* ((source (plist-get settings :source))
         (latest
          (nl-agent-improvement-config--latest catalog-file id-prefix)))
    (when (and (equal source "latest") (null latest))
      (error "improvement model requires an existing %s generation"
             id-prefix))
    (when (and (equal source "new") latest)
      (error "improvement model source new conflicts with existing %s"
             (plist-get latest :id)))
    (let ((model
           (if latest
               (nl-llm-agent-artifact-load-pav
                catalog-file (plist-get latest :id))
             (nl-llm-agent-improve-model
              (plist-get settings :dim)
              (plist-get settings :ff)
              (plist-get settings :vocab)
              (plist-get settings :blocks)
              (plist-get settings :heads)
              (plist-get settings :tokenizer)))))
      (dolist (mapping
               '((:dim . :dim) (:ff . :ff) (:nblocks . :blocks)
                 (:heads . :heads) (:vocab . :vocab)))
        (unless (= (plist-get model (car mapping))
                   (plist-get settings (cdr mapping)))
          (error "resumed artifact architecture differs at %S"
                 (cdr mapping))))
      (unless (equal (nl-llm-agent-tokenizer-id
                      (plist-get model :tokenizer))
                     (plist-get settings :tokenizer))
        (error "resumed artifact tokenizer differs from configuration"))
      (cons model (if latest (plist-get latest :id) "new")))))

;;;###autoload
(defun nl-agent-improvement-config-load (file)
  "Load data-only improvement configuration FILE and assemble its boundaries.

Return a plist containing :queue, :provider, :provider-id, :id-prefix,
:catalog-file, :queue-state-file, :model-source, and :parameter-count.  Relative
paths resolve from FILE."
  (unless (and (stringp file) (file-regular-p file))
    (error "improvement configuration file does not exist: %S" file))
  (when (> (file-attribute-size (file-attributes file))
           nl-agent-improvement-config-max-bytes)
    (error "improvement configuration exceeds %d bytes"
           nl-agent-improvement-config-max-bytes))
  (let* ((path (expand-file-name file))
         (directory (file-name-directory path))
         (config-text
          (with-temp-buffer
            (insert-file-contents path)
            (buffer-string)))
         (config-digest (secure-hash 'sha256 config-text))
         (data
          (json-parse-string
           config-text :object-type 'plist :array-type 'array
           :null-object :json-null :false-object :json-false)))
    (nl-agent-improvement-config--keys
     data
     '(:format :catalog :queueState :providerId :providerName :idPrefix
       :artifactName :grammar :benchmark :model :training :minDelta :maxSequence
       :maxPending :maxHistory :taskPromotion)
     "improvement configuration")
    (unless (equal (plist-get data :format)
                   nl-agent-improvement-config-format)
      (error "unsupported improvement configuration format %S"
             (plist-get data :format)))
    (let* ((catalog-file
            (nl-agent-improvement-config--path
             (plist-get data :catalog) directory "improvement catalog"))
           (queue-state-file
            (nl-agent-improvement-config--path
             (plist-get data :queueState) directory
             "improvement queue state"))
           (provider-id
            (nl-agent-improvement-config--identifier
             (or (plist-get data :providerId) "native")
             "improvement provider"))
           (provider-name
            (or (plist-get data :providerName) "Self-evolved NeLisp models"))
           (id-prefix
            (nl-agent-improvement-config--identifier
             (or (plist-get data :idPrefix) "self")
             "improvement artifact prefix"))
           (artifact-name (plist-get data :artifactName))
           (grammar (plist-get data :grammar))
           (benchmark (plist-get data :benchmark))
           (settings
            (nl-agent-improvement-config--model-spec
             (plist-get data :model)))
           (training
            (nl-agent-improvement-config--training-spec
             (plist-get data :training) settings directory))
           (task-promotion
            (nl-agent-improvement-config--task-promotion-spec
             data training directory))
           (min-delta
            (nl-agent-improvement-config--number
             data :minDelta 0.0 0.0 "improvement configuration"))
           (maxseq
            (nl-agent-improvement-config--integer
             data :maxSequence 1 10000000 "improvement configuration"))
           (max-pending
            (nl-agent-improvement-config--integer
             data :maxPending 1 1024 "improvement configuration"))
           (max-history
            (nl-agent-improvement-config--integer
             data :maxHistory 0 10000 "improvement configuration")))
      (let ((task-manifest
             (nl-agent-improvement-config--task-manifest-state
              queue-state-file task-promotion)))
      ;; Both synchronous and background assemblies must respect active host
      ;; ownership before reading artifacts or restoring queue state.
      (dolist (locked (list queue-state-file catalog-file))
        (when (file-locked-p (file-truename locked))
          (error "improvement configuration file is locked: %s" locked)))
      (when (equal provider-id "remote")
        (error "improvement provider id remote is reserved"))
      (unless (and (stringp provider-name) (not (string-empty-p provider-name)))
        (error "improvement providerName must be non-empty text"))
      (when (and artifact-name
                 (not (and (stringp artifact-name)
                           (not (string-empty-p artifact-name)))))
        (error "improvement artifactName must be non-empty text"))
      (nl-agent-improvement-config--keys
       benchmark '(:examples) "improvement benchmark")
      (unless (plist-member benchmark :examples)
        (error "improvement benchmark requires examples"))
      ;; The publisher performs the final grammar normalization and rejection.
      (setq grammar
            (nl-llm-agent-artifact-normalize-grammar
             grammar "improvement configuration"))
      (let* ((evaluate
              (nl-llm-agent-evolve-p5-evaluator
               (plist-get benchmark :examples)
               (plist-get settings :tokenizer)))
             (selected
              (nl-agent-improvement-config--model
               settings catalog-file id-prefix))
             (model (car selected))
             (model-source (cdr selected))
             (queue
              (nl-llm-agent-evolve-p5-queue
               model evaluate catalog-file grammar
               :id-prefix id-prefix :name artifact-name
               :min-delta min-delta :maxseq maxseq
               :max-pending max-pending :max-history max-history
               :training-backend (plist-get training :backend)
               :training-sequence (plist-get training :sequence)
               :optimizer (plist-get training :optimizer)
               :training-checkpoint-directory
               (and (eq (plist-get training :execution) 'synchronous)
                    (plist-get training :checkpoint-directory))
               :checkpoint-every
               (if (eq (plist-get training :execution) 'synchronous)
                   (plist-get training :checkpoint-every)
                 0)
               :checkpoint-scope
               (and (eq (plist-get training :execution) 'synchronous)
                    (> (plist-get training :checkpoint-every) 0)
                    config-digest)
               :checkpoint-file queue-state-file))
             (_supervised-handler
              (when (eq (plist-get training :objective) 'completion)
                ;; Register before restore so a detached supervised proposal
                ;; is validated by the same trusted handler after restart.
                (nl-llm-agent-supervised-evolve-register
                 queue
                 :training-backend (plist-get training :backend)
                 :training-sequence (plist-get training :sequence)
                 :optimizer (plist-get training :optimizer))
                (let ((handler
                       (nl-llm-evolve-queue--handler
                        queue "supervised-finetune")))
                  ;; Synchronous GPU callers own the host device lifetime.
                  ;; Keep enablement lazy: loading/restoring configuration must
                  ;; not start a GPU server.
                  (when (and (eq (plist-get training :execution) 'synchronous)
                             (eq (plist-get training :backend) 'gpu))
                    (let ((trainer
                           (nl-llm-evolve-queue-handler-train-fn handler)))
                      (setf (nl-llm-evolve-queue-handler-train-fn handler)
                            (lambda (candidate payload state)
                              (require 'nl-llm-gpu)
                              (unless (nl-llm-gpu-enable)
                                (error "synchronous supervised GPU backend unavailable"))
                              (funcall trainer candidate payload state)))))
                  handler)))
             (provider
              (nl-llm-agent-artifact-provider
               provider-id catalog-file provider-name t))
             (runner
              (when (eq (plist-get training :execution) 'background)
                ;; Acquire ownership before restore can rewrite running jobs.
                (nl-agent-training-runner-new
                 queue
                 (append
                  (list :scope config-digest
                        :benchmark (plist-get benchmark :examples)
                        :training
                        (append
                         (list :backend (plist-get training :backend)
                               :sequence (plist-get training :sequence)
                               :optimizer (plist-get training :optimizer))
                         (when (> (plist-get training :checkpoint-every) 0)
                           (list :checkpoint-every
                                 (plist-get training :checkpoint-every))))
                        :catalog-file catalog-file
                        :directory
                        (expand-file-name
                         "training-jobs"
                         (file-name-directory queue-state-file)))
                  (when task-promotion
                    (list :task-promotion
                          (plist-get task-promotion :policy)
                          :task-audit-directory
                          (plist-get task-promotion :audit-directory)))
                  (when (> (plist-get training :checkpoint-every) 0)
                    (list :recovery-directory
                          (plist-get training :checkpoint-directory))))))))
        (condition-case err
            (progn
              ;; Background recovery is executed only by the isolated runner.
              ;; This truthy callback marks restored jobs resumable without
              ;; installing synchronous checkpoint or cleanup callbacks.
              (when (and (eq (plist-get training :execution) 'background)
                         (> (plist-get training :checkpoint-every) 0))
                (dolist (kind
                         (if (eq (plist-get training :objective) 'completion)
                             '("trajectory-finetune" "supervised-finetune")
                           '("trajectory-finetune")))
                  (let ((handler (nl-llm-evolve-queue--handler queue kind)))
                    (unless handler
                      (error "background %s handler is unavailable" kind))
                    (setf (nl-llm-evolve-queue-handler-resume-fn handler)
                          (lambda (_candidate _payload _state)
                            (error "Background resume must use the background training runner"))
                          (nl-llm-evolve-queue-handler-finish-fn handler) nil))))
              ;; The runner has installed its receipt gate and acquired the
              ;; queue lock.  Persist the policy binding before restore can
              ;; expose any pending job to a caller.
              (when (plist-get task-manifest :write)
                (nl-agent-improvement-config--write-task-manifest
                 (plist-get task-manifest :path)
                 (plist-get task-manifest :manifest)))
              (nl-llm-evolve-queue-restore queue nil t)
              (list :queue queue :provider provider :runner runner
              :provider-id provider-id :id-prefix id-prefix
              :catalog-file catalog-file
              :queue-state-file queue-state-file
              :model-source model-source
              :training-execution (plist-get training :execution)
              :training-objective (plist-get training :objective)
              :training-backend (plist-get training :backend)
              :training-sequence (plist-get training :sequence)
              :optimizer (plist-get training :optimizer)
              :training-checkpoint-directory
              (plist-get training :checkpoint-directory)
              :checkpoint-every (plist-get training :checkpoint-every)
              :task-promotion
              (and task-promotion
                   (copy-tree (plist-get task-promotion :policy) t))
              :task-audit-directory
              (and task-promotion
                   (plist-get task-promotion :audit-directory))
              :task-promotion-manifest
              (and task-promotion (plist-get task-manifest :path))
              :tokenizer (plist-get settings :tokenizer)
              :parameter-count (plist-get settings :parameters)))
          (error
           (when runner (nl-agent-training-runner-stop runner))
           (signal (car err) (cdr err)))))))))

(provide 'nl-agent-improvement-config)
;;; nl-agent-improvement-config.el ends here
