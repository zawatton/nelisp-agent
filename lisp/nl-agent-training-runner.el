;;; nl-agent-training-runner.el --- isolated background training host -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)
(require 'nl-llm-evolve-queue)
(require 'nl-agent-training-protocol)
(require 'nl-llm-agent-supervised-evolve)
(require 'nl-agent-task-promotion)
(require 'nl-agent-task-audit)

(declare-function nl-agent-task-promotion-policy
                  "nl-agent-task-promotion" (policy))
(declare-function nl-agent-task-promotion-validate-evidence
                  "nl-agent-task-promotion"
                  (evidence before-checkpoint after-checkpoint policy))
(declare-function nl-agent-task-promotion--checkpoint-digest
                  "nl-agent-task-promotion" (checkpoint))
(declare-function nl-agent-task-promotion--weight-digest
                  "nl-agent-task-promotion" (checkpoint id))

(declare-function nl-agent-training-recovery-save
                  "nl-agent-training-recovery"
                  (directory request request-sha256 checkpoint
                             &optional expected-attempt))
(declare-function nl-agent-training-recovery-load
                  "nl-agent-training-recovery" (directory scope job-id))
(declare-function nl-agent-training-recovery-remove
                  "nl-agent-training-recovery"
                  (directory scope job-id expected-attempt))
(declare-function nl-agent-training-recovery-path
                  "nl-agent-training-recovery" (directory scope job-id))
(declare-function nl-agent-training-recovery-reserve
                  "nl-agent-training-recovery"
                  (directory scope job-id origin-attempt active-attempt))
(declare-function nl-agent-training-recovery-release
                  "nl-agent-training-recovery"
                  (directory scope job-id active-attempt))
(declare-function nl-agent-training-recovery-marker-path
                  "nl-agent-training-recovery" (directory scope job-id))

(defconst nl-agent-training-runner--lisp-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(cl-defstruct (nl-agent-training-runner (:constructor nl-agent-training-runner--make))
  queue profile process claim request request-file result-file request-sha256
  workdir lock-file lock-files stopping cancelling cancellation-id
  cancellation-workdir cleanup-failures recovery-origin-attempt
  recovery-active-attempt child-terminal-observed
  task-promotion-policy task-promotion-gate task-promotion-gate-state
  task-audit-directory)

(defvar nl-agent-training-runner--owners nil)

(defun nl-agent-training-runner--task-promotion-weight-digest
    (checkpoint id)
  "Return the task gate's canonical weights digest for CHECKPOINT."
  (nl-agent-task-promotion--weight-digest checkpoint id))

(defun nl-agent-training-runner--task-promotion-policy (profile)
  "Return PROFILE's detached task-promotion policy, or nil.
Policy validation is deliberately done before any runner lock or attempt
directory is created."
  (when (plist-member profile :task-promotion)
    (nl-agent-task-promotion-policy
     (plist-get profile :task-promotion))))

(defun nl-agent-training-runner--task-promotion-gate
    (evolution policy state-box)
  "Install and return a fail-closed task gate for EVOLUTION.
STATE-BOX is a mutable one-element list whose value is the runner-owned
receipt.  The gate never evaluates a task itself: it only accepts a receipt
which the host validated against the exact parent and candidate checkpoints."
  (letrec ((gate
            (lambda (before candidate)
              (let ((state (car state-box)))
                ;; A queue-complete transaction consumes its receipt.  This
                ;; prevents a second/re-entrant gate invocation from replaying
                ;; the same worker evidence.
                (when state
                  (setcar state-box nil))
                (condition-case nil
                    (and state
                         (plist-get state :active)
                         (eq (nl-llm-evolution-promotion-gate-fn evolution)
                             gate)
                         (equal
                          (nl-agent-training-runner--task-promotion-weight-digest
                           (nl-llm-agent-artifact-export-pav before) "before")
                          (plist-get state :before-digest))
                         (equal
                          (nl-agent-training-runner--task-promotion-weight-digest
                           (nl-llm-agent-artifact-export-pav candidate) "after")
                          (plist-get state :after-digest))
                         (let ((validated
                                (nl-agent-task-promotion-validate-evidence
                                 (plist-get state :evidence)
                                 (plist-get state :before-checkpoint)
                                 (plist-get state :after-checkpoint)
                                 policy)))
                           (and (listp validated)
                                (eq (plist-get validated :accepted) t))))
                  (error nil))))))
    (setf (nl-llm-evolution-promotion-gate-fn evolution) gate)
    gate))

(defun nl-agent-training-runner--assert-task-promotion-gate (runner)
  "Ensure RUNNER's host-installed task gate is still installed."
  (let ((gate (nl-agent-training-runner-task-promotion-gate runner)))
    (when gate
      (unless (eq (nl-llm-evolution-promotion-gate-fn
                   (nl-llm-evolve-queue-evolution
                    (nl-agent-training-runner-queue runner)))
                  gate)
        (error "task promotion gate was replaced or removed")))))

(defun nl-agent-training-runner--evaluation-reference
    (runner request)
  "Return a detached audit identity from RUNNER REQUEST, or nil.
The reference identifies a possible retained record; it does not read the
record and does not imply that evaluation has completed."
  (when (and (nl-agent-training-runner-task-audit-directory runner)
             (listp request))
    (let ((scope (plist-get request :scope))
          (id (plist-get request :job-id))
          (attempt (plist-get request :attempt)))
      (when (and (stringp scope) (stringp id) (stringp attempt))
        (list :scope (substring-no-properties scope)
              :id (substring-no-properties id)
              :attempt (substring-no-properties attempt))))))

(defun nl-agent-training-runner--task-promotion-receipt
    (runner request result candidate)
  "Validate RESULT's task evidence and install one queue-completion receipt.
The evidence is checked against REQUEST's parent checkpoint and CANDIDATE's
detached checkpoint.  This helper never invokes the task evaluator."
  (let* ((policy (nl-agent-training-runner-task-promotion-policy runner))
         (evidence (plist-get result :task-promotion))
         (before (copy-tree (plist-get request :parent-model) t))
         (after (nl-llm-agent-artifact-export-pav candidate))
         (validated
          (nl-agent-task-promotion-validate-evidence
           evidence before after policy))
         (state (list :active t
                      :evidence (copy-tree validated t)
                      :before-checkpoint before
                      :after-checkpoint after
                      :before-digest
                      (nl-agent-training-runner--task-promotion-weight-digest
                       before "before")
                      :after-digest
                      (nl-agent-training-runner--task-promotion-weight-digest
                       after "after")))
         (state-box (nl-agent-training-runner-task-promotion-gate-state runner)))
    (unless (and (listp validated) (plist-member validated :accepted))
      (error "task promotion evidence validator returned an invalid value"))
    (setcar state-box state)
    validated))

(defun nl-agent-training-runner--lock (file)
  (setq file (file-truename file))
  (when (member file nl-agent-training-runner--owners)
    (error "training runner already owns %s" file))
  (when (file-locked-p file)
    (error "training runner lock already exists: %s" file))
  (make-directory (file-name-directory file) t)
  (lock-file file)
  (unless (file-locked-p file)
    (error "failed to acquire training runner lock: %s" file))
  (push file nl-agent-training-runner--owners))

(defun nl-agent-training-runner--unlock (runner)
  (let ((file (nl-agent-training-runner-lock-file runner)))
    (when (and file (member file nl-agent-training-runner--owners))
      (setq nl-agent-training-runner--owners (delete file nl-agent-training-runner--owners))
      (ignore-errors (unlock-file file)))))

;;;###autoload
(defun nl-agent-training-runner-new (queue profile)
  "Create a background runner for QUEUE using trusted PROFILE.
PROFILE supplies :scope, :benchmark, :training, :directory, and :host.
Optional :recovery-directory is a caller-owned private receipt store."
  (unless (nl-llm-evolve-queue-p queue) (error "invalid training queue"))
  (unless (and (listp profile) (stringp (plist-get profile :directory)))
    (error "training profile requires :directory"))
  (unless (nl-llm-evolve-queue-checkpoint-file queue)
    (error "background training requires a durable queue checkpoint"))
  ;; Canonicalize the optional policy before any lock, directory creation, or
  ;; queue mutation.  A queue already carrying a trusted gate cannot be
  ;; silently replaced by this runner's fail-closed receipt gate.
  (let* ((task-policy
          (nl-agent-training-runner--task-promotion-policy profile))
         (audit-present (plist-member profile :task-audit-directory))
         (audit-directory
          (when audit-present
            (let ((directory (plist-get profile :task-audit-directory)))
              (unless (and (stringp directory) (> (length directory) 0))
                (error "task audit directory must be non-empty text"))
              (setq directory (substring-no-properties directory))
              (nl-agent-task-audit--directory directory))))
         (evolution (nl-llm-evolve-queue-evolution queue))
         (existing-gate (nl-llm-evolution-promotion-gate-fn evolution)))
    (when (and audit-present (not task-policy))
      (error "task audit directory requires a task-promotion policy"))
    (when (and task-policy existing-gate)
      (error "task-promotion policy conflicts with an existing promotion gate"))
    (let* ((recovery-directory (plist-get profile :recovery-directory))
         (training (plist-get profile :training))
         (checkpoint-every (or (plist-get training :checkpoint-every) 0))
         (backend (plist-get training :backend))
         (_recovery-valid
          (when recovery-directory
            (unless (and (stringp recovery-directory)
                         (> (length recovery-directory) 0))
              (error "training recovery directory must be non-empty text"))
            (unless (and (member backend '(gpu "gpu"))
                         (integerp checkpoint-every)
                         (> checkpoint-every 0))
              (error "training recovery requires GPU checkpointing"))
            (require 'nl-agent-training-recovery)
            t))
         (checkpoint (file-truename (nl-llm-evolve-queue-checkpoint-file queue)))
         (catalog (plist-get profile :catalog-file))
         (recovery-lock
          (and recovery-directory
               (file-truename
                (expand-file-name ".owner" recovery-directory))))
         (files (delete-dups
                 (delq nil (list checkpoint
                                 (and catalog (file-truename catalog))
                                 recovery-lock))))
         (owned nil)
         (gate-state (list nil))
         (gate nil)
         (runner nil))
      (condition-case err
          (progn
            (dolist (file files)
              (nl-agent-training-runner--lock file)
              (push file owned))
            (setq runner
                  (nl-agent-training-runner--make
                   :queue queue :profile (copy-tree profile)
                   :lock-file checkpoint :lock-files files
                   :task-promotion-policy (and task-policy
                                               (copy-tree task-policy t))
                   :task-promotion-gate-state gate-state
                   :task-audit-directory audit-directory))
            (when task-policy
              (setq gate
                    (nl-agent-training-runner--task-promotion-gate
                     evolution task-policy gate-state))
              (setf (nl-agent-training-runner-task-promotion-gate runner)
                    gate))
            runner)
        (error
         (when (and gate
                    (eq (nl-llm-evolution-promotion-gate-fn evolution) gate))
           (setf (nl-llm-evolution-promotion-gate-fn evolution) nil))
         (dolist (file owned)
           (ignore-errors (nl-agent-training-runner--unlock
                           (nl-agent-training-runner--make :lock-file file))))
         (signal (car err) (cdr err)))))))

(defun nl-agent-training-runner--request-value
    (runner claim &optional resume-state)
  "Build the validated request value for CLAIM and optional RESUME-STATE."
  (let* ((profile (nl-agent-training-runner-profile runner))
         (kind (plist-get claim :kind))
         (request
          (list :format nl-agent-training-protocol-format
                :attempt (plist-get claim :attempt)
                :job-id (plist-get claim :job-id)
                :parent-generation (plist-get claim :parent-generation)
                :parent-score (plist-get claim :parent-score)
                :scope (plist-get profile :scope)
                :payload (plist-get claim :payload)
                :parent-model
                (nl-llm-agent-artifact-export-pav
                 (nl-llm-evolution-champion
                  (nl-llm-evolve-queue-evolution
                   (nl-agent-training-runner-queue runner))))
                :training (plist-get profile :training)
                :benchmark (plist-get profile :benchmark))))
    ;; Keep the legacy wire form byte-for-byte compatible.  The explicit kind
    ;; is needed only for completion-only supervised workers.
    (when (equal kind "supervised-finetune")
      (setq request (append request (list :kind kind))))
    (when (nl-agent-training-runner-task-promotion-policy runner)
      ;; Use the runner-owned detached value rather than the nested profile
      ;; tree.  Rebuilding a request after caller mutation must retain exactly
      ;; the policy validated at construction time.
      (setq request
            (append request
                    (list :task-promotion
                          (nl-agent-task-promotion-policy
                           (nl-agent-training-runner-task-promotion-policy
                            runner))))))
    (when resume-state
      (setq request (append request (list :resume-state resume-state))))
    (nl-agent-training-protocol-validate-request request)
    request))

(defun nl-agent-training-runner--request
    (runner claim &optional resume-state)
  "Create a private attempt request for CLAIM and optional RESUME-STATE."
  (let ((profile (nl-agent-training-runner-profile runner))
        directory file request)
    (let ((temporary-file-directory
           (file-name-as-directory (expand-file-name (plist-get profile :directory)))))
      (make-directory temporary-file-directory t)
      (setq directory (make-temp-file "attempt-" t)))
    ;; Record the private snapshot directory immediately so a later request
    ;; validation/write failure can be finalized without losing its location.
    (setf (nl-agent-training-runner-workdir runner) directory)
    (setq file (expand-file-name "request.sexp" directory)
          request (nl-agent-training-runner--request-value
                   runner claim resume-state))
    (nl-agent-training-protocol-write file request)
    (list request file directory (nl-agent-training-protocol-hash file))))

(defun nl-agent-training-runner--terminal-process-p (process)
  "Return non-nil when PROCESS has reached a terminal state."
  (and process (memq (process-status process) '(exit signal closed failed))))

(defun nl-agent-training-runner--durably-terminal-p (job)
  "Return non-nil when public JOB records a durable terminal result."
  (and job
       (memq (plist-get job :status) '(promoted rejected error cancelled))
       (not (plist-member (plist-get job :result) :persistence-error))))

(defun nl-agent-training-runner--cleanup-workdir (runner)
  "Delete RUNNER's exact private attempt directory when it is safe to do so."
  (let* ((workdir (nl-agent-training-runner-workdir runner))
         (base (and workdir
                    (file-name-as-directory
                     (file-truename
                      (plist-get (nl-agent-training-runner-profile runner)
                                 :directory)))))
         (directory (and workdir (file-name-as-directory
                                  (expand-file-name workdir)))))
    (when (and directory base
               (not (file-symlink-p (directory-file-name directory)))
               (equal (file-name-directory
                       (directory-file-name (file-truename directory)))
                      base)
               (string-prefix-p "attempt-"
                                (file-name-nondirectory
                                 (directory-file-name directory)))
               (file-directory-p directory))
      (delete-directory directory t))
    (setf (nl-agent-training-runner-request runner) nil
          (nl-agent-training-runner-request-file runner) nil
          (nl-agent-training-runner-result-file runner) nil
          (nl-agent-training-runner-request-sha256 runner) nil
          (nl-agent-training-runner-workdir runner) nil
          (nl-agent-training-runner-recovery-origin-attempt runner) nil
          (nl-agent-training-runner-recovery-active-attempt runner) nil
          (nl-agent-training-runner-child-terminal-observed runner) nil)))

(defun nl-agent-training-runner--finish-start-error
    (runner claim err &optional resuming)
  "Record pre-spawn ERR for CLAIM, retaining state if persistence fails."
  (condition-case nil
      (let ((profile (nl-agent-training-runner-profile runner))
            job)
        (setf (nl-agent-training-runner-child-terminal-observed runner) t)
        (when (and resuming
                   (nl-agent-training-runner-recovery-active-attempt runner))
          ;; The ordinary `start-process' contract either returns a process or
          ;; signals before ownership is transferred.  Hooks which launch and
          ;; then signal are outside this recoverability boundary.
          (nl-agent-training-recovery-release
           (plist-get profile :recovery-directory)
           (plist-get profile :scope)
           (plist-get claim :job-id)
           (nl-agent-training-runner-recovery-active-attempt runner))
          (setf (nl-agent-training-runner-recovery-active-attempt runner) nil))
        (setq job
             (if resuming
                 (nl-llm-evolve-queue-interrupt
                  (nl-agent-training-runner-queue runner) claim)
               (nl-llm-evolve-queue-fail
                (nl-agent-training-runner-queue runner) claim
                (format "training worker start failed: %S" err))))
        (setf (nl-agent-training-runner-claim runner) nil)
        (when (or resuming
                  (nl-agent-training-runner--durably-terminal-p job))
          (nl-agent-training-runner--cleanup-workdir runner)))
    (error nil)))

(defun nl-agent-training-runner--resume-receipt (runner id)
  "Load and validate the durable interrupted receipt for proposal ID."
  (unless (and (stringp id) (> (length id) 0))
    (error "background resume requires a non-empty id"))
  (let* ((profile (nl-agent-training-runner-profile runner))
         (directory (plist-get profile :recovery-directory)))
    (unless directory
      (error "background resume is not configured"))
    (let* ((queue (nl-agent-training-runner-queue runner))
           (job (nl-llm-evolve-queue--job queue id)))
      (unless (and job (eq (nl-llm-evolve-queue-job-status job) 'interrupted))
        (error "improvement proposal %s is not interrupted" id))
      (let* ((receipt
              (nl-agent-training-recovery-load
               directory (plist-get profile :scope) id))
             (request (plist-get receipt :request))
             (request-sha256 (plist-get receipt :request-sha256))
             (checkpoint (plist-get receipt :checkpoint))
             (state (plist-get checkpoint :state))
             (evolution (nl-llm-evolve-queue-evolution queue))
             (preview-claim
              (list :attempt (plist-get checkpoint :attempt)
                    :job-id id
                    :kind (nl-llm-evolve-queue-job-kind job)
                    :payload
                    (nl-llm-evolve-queue--data-copy
                     (nl-llm-evolve-queue-job-payload job)
                     "resume preview payload")
                    :parent-generation
                    (nl-llm-evolution-generation evolution)
                    :parent-score
                    (nl-llm-evolution-champion-score evolution)))
             (preview
              (nl-agent-training-runner--request-value
               runner preview-claim)))
        (nl-agent-training-protocol-validate-request request)
        (nl-agent-training-protocol-validate-checkpoint
         checkpoint request request-sha256)
        (nl-agent-training-protocol-validate-resume-state state preview)
        (list :state (copy-tree state t)
              :origin-attempt (plist-get checkpoint :attempt))))))

(defun nl-agent-training-runner--fresh-job-id (runner id)
  "Return the job id a fresh start would claim, without mutating its queue."
  (let* ((queue (nl-agent-training-runner-queue runner))
         (job (if id
                  (nl-llm-evolve-queue--job queue id)
                (nl-llm-evolve-queue--next-pending queue))))
    (and job (nl-llm-evolve-queue-job-id job))))

(defun nl-agent-training-runner--reject-supervised-job
    (runner id resuming)
  "Validate a supervised proposal before background claim.
The queue and job are inspected without claiming or changing either one."
  (let* ((queue (nl-agent-training-runner-queue runner))
         (job (if id
                  (nl-llm-evolve-queue--job queue id)
                (nl-llm-evolve-queue--next-pending queue)))
         (profile (nl-agent-training-runner-profile runner))
         (training (plist-get profile :training)))
    (when (and job
               (equal (nl-llm-evolve-queue-job-kind job)
                      "supervised-finetune"))
      (let* ((evolution (nl-llm-evolve-queue-evolution queue))
             (model (nl-llm-evolution-champion evolution))
             (tokenizer
              (nl-llm-agent-supervised-evolve--validate-model model))
             (backend
              (nl-llm-agent-evolve--training-backend
               (plist-get training :backend)))
             (optimizer
              (nl-llm-agent-evolve--optimizer
               (plist-get training :optimizer) backend))
             (sequence (plist-get training :sequence))
             (checkpointed-p (plist-member training :checkpoint-every))
             (checkpoint-every (plist-get training :checkpoint-every))
             (recovery-directory (plist-get profile :recovery-directory)))
        ;; Completion-only checkpoints are resumable only when the trusted
        ;; profile supplies the same durable GPU contract as legacy resume.
        ;; Perform this check before claim so invalid CPU/cadence profiles do
        ;; not mutate queue state.  A fresh CPU supervised request without
        ;; checkpointing remains the historical ephemeral path.
        (when (or resuming checkpointed-p)
          (unless (and (eq backend 'gpu)
                       (integerp checkpoint-every)
                       (<= 1 checkpoint-every 1000000)
                       (stringp recovery-directory)
                       (> (length recovery-directory) 0))
            (error "supervised checkpoint/resume requires GPU, positive checkpoint cadence, and recovery directory")))
        ;; Validate the fixed profile binding as well as the hostile payload.
        ;; CPU supervised training still carries a sequence profile because it
        ;; is part of the queue's trusted registration contract.
        (nl-llm-agent-supervised-evolve--sequence sequence)
        (nl-llm-agent-supervised-evolve--payload
         (nl-llm-evolve-queue-job-payload job)
         tokenizer backend sequence optimizer)))))

(defun nl-agent-training-runner--reject-fresh-recovery-collision (runner id)
  "Reject a fresh start when ID already has a private recovery receipt."
  (let* ((profile (nl-agent-training-runner-profile runner))
         (directory (plist-get profile :recovery-directory))
         (job-id (and directory
                      (nl-agent-training-runner--fresh-job-id runner id))))
    (when (and job-id
               (cl-some
                (lambda (path)
                  (or (file-exists-p path) (file-symlink-p path)))
                (list
                 (nl-agent-training-recovery-path
                  directory (plist-get profile :scope) job-id)
                 (nl-agent-training-recovery-marker-path
                  directory (plist-get profile :scope) job-id))))
      (error "training recovery already exists for fresh proposal %s" job-id))))

(defun nl-agent-training-runner--sentinel (runner process _event)
  "Finalize PROCESS for RUNNER once, without leaking sentinel errors."
  (when (and (eq process (nl-agent-training-runner-process runner))
             (not (nl-agent-training-runner-stopping runner))
             (not (nl-agent-training-runner-cancelling runner))
             (nl-agent-training-runner--terminal-process-p process))
    (condition-case nil
        (nl-agent-training-runner-poll runner)
      (error nil))))

;;;###autoload
(defun nl-agent-training-runner-start (runner &optional id resuming)
  "Claim and start one isolated worker, returning its public queue job."
  (unless (nl-agent-training-runner-p runner) (error "invalid training runner"))
  (when (nl-agent-training-runner-process runner) (error "training worker already running"))
  (when (nl-agent-training-runner-stopping runner) (error "training runner is stopping"))
  (when (nl-agent-training-runner-cancelling runner)
    (error "training cancellation requires retry"))
  ;; Validate supervised profile/payload bindings before claim.  The worker
  ;; owns both the historical ephemeral path and the durable completion path;
  ;; malformed checkpoint/resume profiles remain pending and untouched.
  (nl-agent-training-runner--reject-supervised-job runner id resuming)
  (let ((resume
         (when resuming
           ;; Receipt validation precedes the queue claim so any stale or
           ;; mismatched state leaves the interrupted job untouched.
           (nl-agent-training-runner--resume-receipt runner id)))
        (claim nil)
        (process nil)
        (running-job nil))
    (condition-case err
        (progn
          (unless resuming
            (nl-agent-training-runner--reject-fresh-recovery-collision
             runner id))
          (let ((inhibit-quit t))
            (setq claim
                  (nl-llm-evolve-queue-claim
                   (nl-agent-training-runner-queue runner) id resuming))
            (setf (nl-agent-training-runner-claim runner) claim))
          (setf (nl-agent-training-runner-child-terminal-observed runner) nil)
          (setf (nl-agent-training-runner-recovery-origin-attempt runner)
                (plist-get resume :origin-attempt))
          (setq running-job
                (nl-llm-evolve-queue--public-job
                 (nl-llm-evolve-queue--job
                  (nl-agent-training-runner-queue runner)
                  (plist-get claim :job-id))))
          (let* ((parts
                  (nl-agent-training-runner--request
                   runner claim (plist-get resume :state)))
                 (request (nth 0 parts))
                 (request-file (nth 1 parts))
                 (workdir (nth 2 parts))
                 (request-sha256 (nth 3 parts))
                 (result-file (expand-file-name "result.sexp" workdir))
                 (profile (nl-agent-training-runner-profile runner))
                 (host (or (plist-get profile :host) "emacs"))
                 (worker
                  (expand-file-name
                   "nl-agent-training-worker.el"
                   nl-agent-training-runner--lisp-directory)))
            ;; Publish request identity before reservation/spawn so a definite
            ;; pre-spawn failure can release the marker and restore the claim.
            (setf (nl-agent-training-runner-request runner) request
                  (nl-agent-training-runner-request-file runner) request-file
                  (nl-agent-training-runner-result-file runner) result-file
                  (nl-agent-training-runner-request-sha256 runner)
                  request-sha256
                  (nl-agent-training-runner-workdir runner) workdir)
            (when (nl-agent-training-runner-task-audit-directory runner)
              (setq running-job
                    (append running-job
                            (list :evaluation-reference
                                  (nl-agent-training-runner--evaluation-reference
                                   runner request)))))
            (when resume
              ;; Marker creation and publication into runner ownership are one
              ;; non-interruptible handoff.  A deferred quit is handled by the
              ;; pre-spawn cleanup path below before any child can start.
              (let ((inhibit-quit t))
                (nl-agent-training-recovery-reserve
                 (plist-get profile :recovery-directory)
                 (plist-get profile :scope)
                 (plist-get claim :job-id)
                 (plist-get resume :origin-attempt)
                 (plist-get claim :attempt))
                (setf
                 (nl-agent-training-runner-recovery-active-attempt runner)
                 (plist-get claim :attempt))))
            (let ((process-environment
                   (delq nil
                         (mapcar
                          (lambda (name)
                            (let ((value (getenv name)))
                              (and value (concat name "=" value))))
                          '("PATH" "LANG" "LC_ALL"))))
                  (inhibit-quit t))
              (setq process
                    (start-process
                     "nl-agent-training-worker" nil host "-Q" "--batch"
                     "-L" (expand-file-name "../../nelisp-photon/lisp"
                                            nl-agent-training-runner--lisp-directory)
                     "-L" (expand-file-name "../../nelisp-llm/lisp"
                                            nl-agent-training-runner--lisp-directory)
                     "-L" nl-agent-training-runner--lisp-directory
                     "-l" worker
                     "--funcall" "nl-agent-training-worker-main"
                     request-file result-file))
              ;; Publish process ownership before a deferred quit can fire.
              (setf (nl-agent-training-runner-process runner) process))
            (set-process-query-on-exit-flag process nil)
            (set-process-sentinel
             process (apply-partially #'nl-agent-training-runner--sentinel runner))
            ;; Installing a sentinel after an already-observed exit does not
            ;; necessarily generate another event.
            (when (nl-agent-training-runner--terminal-process-p process)
              (nl-agent-training-runner--sentinel runner process "already exited"))
            running-job))
      ((error quit)
       ;; A spawned live child remains observable and stoppable.  Treating it
       ;; as a failed start would release the queue claim while it still runs.
       (unless (and process (process-live-p process))
         (when claim
           (nl-agent-training-runner--finish-start-error
            runner claim err resuming))
         (setf (nl-agent-training-runner-process runner) nil))
       (signal (car err) (cdr err))))))

;;;###autoload
(defun nl-agent-training-runner-poll (runner)
  "Poll RUNNER without blocking and finalize only an exited worker."
  (unless (nl-agent-training-runner-p runner) (error "invalid training runner"))
  (let ((process (nl-agent-training-runner-process runner)))
    (when (and process (not (nl-agent-training-runner-stopping runner))
               (not (nl-agent-training-runner-cancelling runner))
               (nl-agent-training-runner--terminal-process-p process))
      (let* ((queue (nl-agent-training-runner-queue runner))
             (claim (nl-agent-training-runner-claim runner))
             (request (nl-agent-training-runner-request runner))
             (origin
              (nl-agent-training-runner-recovery-origin-attempt runner))
             (successful-result nil)
             (audit-failed nil)
             job)
        ;; A terminal child is no longer ambiguous.  Release its active marker
        ;; before queue finalization; failure leaves the process object and
        ;; claim available for an explicit retry.
        (setf (nl-agent-training-runner-child-terminal-observed runner) t)
        (when (nl-agent-training-runner-recovery-active-attempt runner)
          (let ((profile (nl-agent-training-runner-profile runner)))
            (nl-agent-training-recovery-release
             (plist-get profile :recovery-directory)
             (plist-get profile :scope)
             (plist-get claim :job-id)
             (nl-agent-training-runner-recovery-active-attempt runner))
            (setf (nl-agent-training-runner-recovery-active-attempt runner)
                  nil)))
        ;; Claim the terminal event before any queue operation can invoke a
        ;; nested poll.  Subsequent polls and sentinel deliveries become no-ops.
        (setf (nl-agent-training-runner-process runner) nil)
        (setq job
              (condition-case err
                  (if (and (= (process-exit-status process) 0)
                           (file-regular-p
                            (nl-agent-training-runner-result-file runner)))
                      (let ((result (nl-agent-training-protocol-read
                                     (nl-agent-training-runner-result-file runner))))
                        (nl-agent-training-protocol-validate-result result request)
                        (unless (equal (plist-get result :request-sha256)
                                       (nl-agent-training-runner-request-sha256 runner))
                          (error "training result request hash mismatch"))
                        (let* ((candidate
                                (nl-agent-training-protocol-import
                                 (plist-get result :model)))
                               (task-policy
                                (nl-agent-training-runner-task-promotion-policy
                                 runner))
                               (completed nil))
                          (when task-policy
                            ;; Recheck the installed identity immediately
                            ;; before queue completion: removing the gate must
                            ;; fail closed rather than silently publish.
                            (nl-agent-training-runner--assert-task-promotion-gate
                             runner)
                            (nl-agent-training-runner--task-promotion-receipt
                             runner request result candidate))
                          (unwind-protect
                              (progn
                                (when (nl-agent-training-runner-task-audit-directory
                                       runner)
                                  (condition-case audit-error
                                      (nl-agent-task-audit-save
                                       (nl-agent-training-runner-task-audit-directory
                                        runner)
                                       request result
                                       (nl-agent-training-runner-request-sha256
                                        runner))
                                    (error
                                     (setq audit-failed t)
                                     ;; Keep the private diagnostic bounded;
                                     ;; do not dump request/result contents.
                                     (push
                                      (list :job-id (plist-get claim :job-id)
                                            :attempt
                                            (plist-get request :attempt)
                                            :workdir
                                            (nl-agent-training-runner-workdir
                                             runner)
                                            :kind 'task-audit
                                            :error "audit save failed")
                                      (nl-agent-training-runner-cleanup-failures
                                       runner))
                                     (signal (car audit-error)
                                             (cdr audit-error)))))
                                (setq completed
                                      (nl-llm-evolve-queue-complete
                                       queue claim candidate
                                       (plist-get result :score)))
                                (setq successful-result t)
                                completed)
                            ;; Even a veto or queue error must consume the
                            ;; ephemeral evidence receipt.
                            (setcar
                             (nl-agent-training-runner-task-promotion-gate-state
                              runner)
                             nil))))
                    (nl-llm-evolve-queue-fail queue claim
                                              "training worker failed"))
                (error
                 (condition-case nil
                     (nl-llm-evolve-queue-fail queue claim (format "%S" err))
                   (error nil)))))
        (when job
          (setf (nl-agent-training-runner-claim runner) nil)
          (when (nl-agent-training-runner--durably-terminal-p job)
            (when (and successful-result origin
                       (plist-get (nl-agent-training-runner-profile runner)
                                  :recovery-directory))
              (condition-case err
                  (nl-agent-training-recovery-remove
                   (plist-get (nl-agent-training-runner-profile runner)
                              :recovery-directory)
                   (plist-get (nl-agent-training-runner-profile runner) :scope)
                   (plist-get claim :job-id) origin)
                (error
                 (push
                  (list :job-id (plist-get claim :job-id)
                        :recovery-file
                        (nl-agent-training-recovery-path
                         (plist-get
                          (nl-agent-training-runner-profile runner)
                          :recovery-directory)
                         (plist-get
                          (nl-agent-training-runner-profile runner) :scope)
                         (plist-get claim :job-id))
                        :error (format "%S" err))
                  (nl-agent-training-runner-cleanup-failures runner)))))
            (unless audit-failed
              (nl-agent-training-runner--cleanup-workdir runner))))))
    (nl-agent-training-queue-public-status runner)))

(defun nl-agent-training-queue-public-status (runner)
  (let ((status
         (append (nl-llm-evolve-queue-status
                  (nl-agent-training-runner-queue runner))
                 (list :worker-running
                       (and (nl-agent-training-runner-process runner) t))))
        (reference
         (nl-agent-training-runner--evaluation-reference
          runner (nl-agent-training-runner-request runner))))
    (if reference
        (append status (list :evaluation-reference reference))
      status)))

;;;###autoload
(defun nl-agent-training-runner-status (runner)
  "Return public queue status and worker-running state."
  (nl-agent-training-runner-poll runner)
  (nl-agent-training-queue-public-status runner))

(defun nl-agent-training-runner--stop-child (runner)
  "Stop RUNNER's child and return only after observing its terminal state."
  (let ((process (nl-agent-training-runner-process runner)))
    (when process
      (when (process-live-p process)
        (delete-process process))
      (let ((deadline (+ (float-time) 2.0)))
        (while (and (process-live-p process) (< (float-time) deadline))
          (accept-process-output process 0.05)))
      (when (process-live-p process)
        (error "training worker did not stop within timeout"))
      (setf (nl-agent-training-runner-child-terminal-observed runner) t)
      (setf (nl-agent-training-runner-process runner) nil))))

(defun nl-agent-training-runner--remove-terminal-recovery
    (runner id attempt job)
  "Remove ID's ATTEMPT receipt after durable terminal JOB, recording failure."
  (when (and attempt (nl-agent-training-runner--durably-terminal-p job))
    (let ((profile (nl-agent-training-runner-profile runner)))
      (condition-case err
          (nl-agent-training-recovery-remove
           (plist-get profile :recovery-directory)
           (plist-get profile :scope) id attempt)
        (error
         (push
          (list :job-id id
                :recovery-file
                (nl-agent-training-recovery-path
                 (plist-get profile :recovery-directory)
                 (plist-get profile :scope) id)
                :error (format "%S" err))
          (nl-agent-training-runner-cleanup-failures runner))))))
  job)

;;;###autoload
(defun nl-agent-training-runner-cancel (runner id)
  "Cancel proposal ID, safely stopping RUNNER when ID is its active job.
Pending and unrelated interrupted jobs use the ordinary queue cancellation
path and never affect a child owned by another job.  A partially persisted
active cancellation is retained and can be retried with the same ID."
  (unless (nl-agent-training-runner-p runner) (error "invalid training runner"))
  (unless (and (stringp id) (> (length id) 0))
    (error "training cancellation requires a non-empty id"))
  (when (nl-agent-training-runner-stopping runner)
    (error "training runner is stopping"))
  (let* ((queue (nl-agent-training-runner-queue runner))
         (claim (nl-agent-training-runner-claim runner))
         (claim-id (and claim (plist-get claim :job-id)))
         (retry-id (nl-agent-training-runner-cancellation-id runner))
         (profile (nl-agent-training-runner-profile runner))
         (recovery-directory (plist-get profile :recovery-directory))
         (receipt-path
          (and recovery-directory
               (nl-agent-training-recovery-path
                recovery-directory (plist-get profile :scope) id)))
         (marker-path
          (and recovery-directory
               (nl-agent-training-recovery-marker-path
                recovery-directory (plist-get profile :scope) id)))
         (recovery-attempt
          (or (and (equal id claim-id)
                   (nl-agent-training-runner-recovery-origin-attempt runner))
              (and receipt-path (file-regular-p receipt-path)
                   (not (or (file-exists-p marker-path)
                            (file-symlink-p marker-path)))
                   (plist-get
                    (plist-get
                     (nl-agent-training-recovery-load
                      recovery-directory (plist-get profile :scope) id)
                     :request)
                    :attempt)))))
    (if (or (equal id claim-id) (equal id retry-id))
        (progn
          (unless retry-id
            (setf (nl-agent-training-runner-cancelling runner) t
                  (nl-agent-training-runner-cancellation-id runner) id
                  (nl-agent-training-runner-cancellation-workdir runner)
                  (nl-agent-training-runner-workdir runner)))
          (nl-agent-training-runner--stop-child runner)
          (when (and (nl-agent-training-runner-claim runner)
                     (not (nl-agent-training-runner-child-terminal-observed
                           runner)))
            (error "training child terminal state was not observed"))
          (when (nl-agent-training-runner-recovery-active-attempt runner)
            (nl-agent-training-recovery-release
             recovery-directory (plist-get profile :scope) id
             (nl-agent-training-runner-recovery-active-attempt runner))
            (setf (nl-agent-training-runner-recovery-active-attempt runner) nil))
          (when (nl-agent-training-runner-claim runner)
            (nl-llm-evolve-queue-interrupt
             queue (nl-agent-training-runner-claim runner))
            (setf (nl-agent-training-runner-claim runner) nil))
          (let ((job (nl-llm-evolve-queue-cancel queue id))
                (cancelled-workdir
                 (nl-agent-training-runner-cancellation-workdir runner))
                (cancelled-request
                 (nl-agent-training-runner-request-file runner))
                (cancelled-result
                 (nl-agent-training-runner-result-file runner))
                cleanup-error)
            ;; Only the directory captured from this runner's active attempt is
            ;; ours to remove.  Restored interrupted jobs have no such proof.
            (when (equal (nl-agent-training-runner-workdir runner)
                         (nl-agent-training-runner-cancellation-workdir runner))
              (condition-case err
                  (nl-agent-training-runner--cleanup-workdir runner)
                (error (setq cleanup-error (format "%S" err)))))
            (setf (nl-agent-training-runner-cancelling runner) nil
                  (nl-agent-training-runner-cancellation-id runner) nil
                  (nl-agent-training-runner-cancellation-workdir runner) nil)
            (when cleanup-error
              ;; Cancellation is already durable.  Report the post-commit
              ;; cleanup failure without wedging the reusable service; retain
              ;; the exact directory so operators can recover it deliberately.
              (setq job (copy-tree job))
              (setf (plist-get job :result)
                    (append (plist-get job :result)
                            (list :cleanup-error cleanup-error)))
              (push (list :job-id id :workdir cancelled-workdir
                          :request-file cancelled-request
                          :result-file cancelled-result
                          :error cleanup-error)
                    (nl-agent-training-runner-cleanup-failures runner)))
            (nl-agent-training-runner--remove-terminal-recovery
             runner id recovery-attempt job)))
      (nl-agent-training-runner--remove-terminal-recovery
       runner id recovery-attempt
       (nl-llm-evolve-queue-cancel queue id)))))

;;;###autoload
(defun nl-agent-training-runner-stop (runner)
  "Stop RUNNER and durably interrupt its claim after process termination.
When recovery is configured, a child-produced checkpoint is validated and
saved to the host receipt store before the queue becomes interrupted.  Private
attempt directories are retained; reclaiming them is deferred operational debt."
  (unless (nl-agent-training-runner-p runner) (error "invalid training runner"))
  (setf (nl-agent-training-runner-stopping runner) t)
  (let ((process (nl-agent-training-runner-process runner))
        (claim (nl-agent-training-runner-claim runner))
        (profile (nl-agent-training-runner-profile runner)))
    (when process
      (nl-agent-training-runner--stop-child runner))
    (when claim
      (unless (nl-agent-training-runner-child-terminal-observed runner)
        (error "training child terminal state was not observed"))
      (let* ((recovery-directory (plist-get profile :recovery-directory))
             (checkpoint-file
              (and recovery-directory
                   (nl-agent-training-runner-workdir runner)
                   (expand-file-name
                    "checkpoint.sexp"
                    (nl-agent-training-runner-workdir runner)))))
        (when (and checkpoint-file (file-regular-p checkpoint-file))
          (let* ((request-file
                  (nl-agent-training-runner-request-file runner))
                 (known-hash
                  (nl-agent-training-runner-request-sha256 runner))
                 (actual-hash
                  (nl-agent-training-protocol-hash request-file))
                 (request
                  (nl-agent-training-protocol-read request-file))
                 (checkpoint
                  (nl-agent-training-protocol-read checkpoint-file)))
            (unless (equal actual-hash known-hash)
              (error "stopped training request hash changed"))
            (unless (equal request
                           (nl-agent-training-runner-request runner))
              (error "stopped training request changed"))
            (nl-agent-training-protocol-validate-request request)
            (nl-agent-training-protocol-validate-checkpoint
             checkpoint request known-hash)
            (nl-agent-training-recovery-save
             recovery-directory request known-hash checkpoint
             (nl-agent-training-runner-recovery-origin-attempt runner))
            ;; A retry after queue persistence failure now compares against the
            ;; already installed producing attempt, making stop idempotent.
            (setf (nl-agent-training-runner-recovery-origin-attempt runner)
                  (plist-get checkpoint :attempt))
            (setf (nl-agent-training-runner-recovery-active-attempt runner)
                  nil)))
        (when (nl-agent-training-runner-recovery-active-attempt runner)
          ;; No checkpoint is a valid early stop.  The old receipt becomes
          ;; eligible only after this runner observed the resumed child stop.
          (nl-agent-training-recovery-release
           recovery-directory (plist-get profile :scope)
           (plist-get claim :job-id)
           (nl-agent-training-runner-recovery-active-attempt runner))
          (setf (nl-agent-training-runner-recovery-active-attempt runner) nil)))
      (nl-llm-evolve-queue-interrupt
       (nl-agent-training-runner-queue runner) claim)
      (setf (nl-agent-training-runner-claim runner) nil))
    (dolist (file (or (nl-agent-training-runner-lock-files runner)
                      (list (nl-agent-training-runner-lock-file runner))))
      (nl-agent-training-runner--unlock
       (nl-agent-training-runner--make :lock-file file)))
    (setf (nl-agent-training-runner-lock-files runner) nil
          (nl-agent-training-runner-lock-file runner) nil)))

(provide 'nl-agent-training-runner)
;;; nl-agent-training-runner.el ends here
