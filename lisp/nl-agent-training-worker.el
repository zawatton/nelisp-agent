;;; nl-agent-training-worker.el --- one-shot isolated trainer -*- lexical-binding: t; -*-

;;; Code:
(load (expand-file-name "nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'cl-lib)
(require 'nl-agent-training-protocol)
(require 'nl-llm-agent-improve)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-ondevice)
(require 'nl-llm-agent-supervised)
(require 'nl-llm-agent-training-checkpoint)
(require 'nl-llm-agent-tokenizer)
(require 'nl-llm-gpu)

(defun nl-agent-training-worker--trajectories (payload tokenizer)
  "Extract bounded integer token trajectories from PAYLOAD." 
  (let ((xs (plist-get payload :examples)))
    (unless (vectorp xs) (error "training payload :examples must be a vector"))
    (let ((out nil))
      (dolist (x (append xs nil))
        (unless (and (stringp x) (<= 2 (length x) 4096)) (error "invalid trajectory"))
        (push (nl-llm-agent-tokenizer-encode x tokenizer) out))
      (unless out (error "training payload has no trajectories")) (nreverse out))))

(defun nl-agent-training-worker--benchmark (benchmark tokenizer)
  "Construct the fixed evaluator for BENCHMARK text." 
  (nl-llm-agent-evolve-p5-evaluator benchmark tokenizer))

(defun nl-agent-training-worker--completion-plan (request)
  "Return the canonical completion plan for supervised REQUEST.

The protocol owns preparation so the worker cannot silently derive a plan
whose tokenizer, sequence, or optimizer differs from the request binding."
  (unless (fboundp 'nl-agent-training-protocol-completion-plan)
    (error "completion plan helper is unavailable"))
  (nl-agent-training-protocol-completion-plan request))

(defun nl-agent-training-worker--checkpoint-file (result-file)
  "Return the fixed private progress file beside RESULT-FILE."
  (expand-file-name "checkpoint.sexp"
                    (file-name-directory (expand-file-name result-file))))

(defun nl-agent-training-worker--reject-path-aliases
    (request-file result-file checkpoint-file)
  "Reject canonical aliases among worker protocol paths."
  (let ((paths (mapcar #'file-truename
                       (list request-file result-file checkpoint-file))))
    (unless (= (length paths) (length (delete-dups (copy-sequence paths))))
      (error "training request, result, and checkpoint paths must be distinct"))))

(defun nl-agent-training-worker--checkpoint-state
    (request snapshot completed total &optional completion-plan)
  "Build validated wire progress state for REQUEST from SNAPSHOT."
  (let* ((kind (or (plist-get request :kind) "trajectory-finetune"))
         (supervised-p (equal kind "supervised-finetune"))
         (snapshot-plan (plist-get snapshot :completion-plan))
         (training (plist-get request :training))
         (optimizer (intern (format "%s" (plist-get training :optimizer))))
         (step (plist-get snapshot :step))
         (completionp supervised-p)
         (state
          (list
           :format (if completionp
                       nl-llm-agent-training-checkpoint-completion-format
                     nl-llm-agent-training-checkpoint-format)
           :job-id (plist-get request :job-id)
           :payload-digest
           (if completionp
               (nl-llm-agent-training-checkpoint--completion-payload-digest
                (plist-get request :payload))
             (nl-llm-agent-training-checkpoint-payload-digest
              (plist-get request :payload)))
           :scope (plist-get request :scope)
           :parent-generation (plist-get request :parent-generation)
           :parent-score (plist-get request :parent-score)
           :sequence (plist-get training :sequence)
           :optimizer optimizer
           :completed-steps completed
           :total-steps total
           :optimizer-step step
           :model
           (nl-llm-agent-artifact-export-pav
            (plist-get snapshot :model) step)
           :optimizer-state (plist-get snapshot :optimizer-state)
           :request-binding
           (nl-agent-training-protocol-request-binding request))))
    (if completionp
        (progn
          (unless completion-plan
            (error "supervised checkpoint requires a completion plan"))
          (unless (and (fboundp 'nl-agent-training-protocol-completion-plan)
                       (equal completion-plan
                              (nl-agent-training-worker--completion-plan
                               request)))
            (error "supervised checkpoint plan does not match request"))
          (unless (and snapshot-plan
                       (equal completion-plan
                              (nl-llm-agent-completion-plan-validate
                               snapshot-plan)))
            (error "supervised checkpoint snapshot plan mismatch"))
          (setq state (append state (list :completion-plan completion-plan))))
      (when (or completion-plan snapshot-plan)
        (error "legacy checkpoint cannot carry a completion plan")))
    (unless (= step completed)
      (error "training snapshot step %d differs from completed step %d"
             step completed))
    ;; The resume validator strips the wire-only binding after checking every
    ;; immutable request field and the underlying training state.
    (nl-agent-training-protocol-validate-resume-state state request)
    state))

(defun nl-agent-training-worker--write-checkpoint
    (file request request-hash snapshot completed total &optional completion-plan)
  "Validate and atomically write one private worker progress checkpoint."
  (let ((envelope
         (list :format nl-agent-training-checkpoint-format
               :attempt (plist-get request :attempt)
               :request-sha256 request-hash
               :state
               (nl-agent-training-worker--checkpoint-state
                request snapshot completed total completion-plan))))
    (nl-agent-training-protocol-validate-checkpoint
     envelope request request-hash)
    (nl-agent-training-protocol-write file envelope)))

(defun nl-agent-training-worker-run (request-file result-file)
  "Run one validated request and atomically produce RESULT-FILE.
The caller owns a fresh private attempt directory.  When checkpointing is
enabled, `checkpoint.sexp' beside RESULT-FILE is reserved for direct worker
recovery state; service-level resume orchestration remains a host concern." 
  (let* ((request (nl-agent-training-protocol-validate-request
                   (nl-agent-training-protocol-read request-file)))
         (request-hash (nl-agent-training-protocol-hash request-file))
         (kind (or (plist-get request :kind) "trajectory-finetune"))
         (supervised-p (equal kind "supervised-finetune"))
         (promotion-policy
          (and (plist-member request :task-promotion)
               (nl-agent-task-promotion-policy
                (plist-get request :task-promotion))))
         (training (plist-get request :training))
         (backend (intern (format "%s" (plist-get training :backend))))
         (optimizer (intern (format "%s" (plist-get training :optimizer))))
         (checkpoint-every (or (plist-get training :checkpoint-every) 0))
         (checkpoint-file
          (and (> checkpoint-every 0)
               (nl-agent-training-worker--checkpoint-file result-file)))
         (completion-bound-p
          (and supervised-p (or checkpoint-file
                                (plist-get request :resume-state))))
         (payload (plist-get request :payload))
         (lr (or (plist-get payload :lr) 0.05))
         (epochs (or (plist-get payload :epochs) 1))
         (sequence (plist-get training :sequence))
         (model
          (nl-agent-training-protocol-import
           (plist-get request :parent-model)))
         (tokenizer (plist-get model :tokenizer))
         ;; Completion-only payloads are prompt/completion plists and must not
         ;; pass through the legacy concatenated-string tokenizer path.
         (legacy-trajs
          (unless supervised-p
            (nl-agent-training-worker--trajectories payload tokenizer)))
         (examples (and supervised-p (plist-get payload :examples)))
         (encoded
          (when supervised-p
            (nl-llm-agent-supervised-encode examples tokenizer)))
         (resume-state
          (when (plist-get request :resume-state)
            (nl-agent-training-protocol-validate-resume-state
             (plist-get request :resume-state) request)))
         (completion-plan
          (when completion-bound-p
            (nl-agent-training-worker--completion-plan request)))
         (trajs
          (if completion-plan
              (append (plist-get completion-plan :trajectories) nil)
            (or (and supervised-p
                     (plist-get encoded :trajectories))
                legacy-trajs)))
         (loss-starts (and completion-plan
                           (plist-get completion-plan :loss-starts)))
         (loss-masks (and completion-plan
                          (plist-get completion-plan :loss-masks)))
         (shuffle-seed (and completion-plan
                            (plist-get completion-plan :shuffle-seed)))
         (total (* epochs (length trajs)))
         (start-step (or (plist-get resume-state :completed-steps) 0))
         (optimizer-step (or (plist-get resume-state :optimizer-step) 0))
         (evaluator
          (nl-agent-training-worker--benchmark
           (plist-get request :benchmark) tokenizer))
         result context checkpoint-written-step)
    (when checkpoint-file
      (nl-agent-training-worker--reject-path-aliases
       request-file result-file checkpoint-file))
    ;; Validate every prompt/completion pair before invoking the trainer or
    ;; enabling a GPU.  This is deliberately the supervised encoder, never the
    ;; legacy concatenated trajectory tokenizer.
    (when (and supervised-p (not encoded))
      (setq encoded (nl-llm-agent-supervised-encode examples tokenizer)))
    (when (and completion-plan resume-state
               (not (equal completion-plan
                           (plist-get resume-state :completion-plan))))
      (error "supervised resume completion plan mismatch"))
    ;; Resume data is fully validated before candidate mutation or GPU setup.
    (when resume-state
      (nl-llm-agent-training-checkpoint-restore-model model resume-state))
    (unwind-protect
        (progn
          (cond
           ((eq backend 'cpu)
            (if supervised-p
                (nl-llm-agent-supervised-train
                 model examples :backend 'cpu :lr lr :epochs epochs
                 :optimizer optimizer)
              ;; The CPU reference trainer currently implements SGD.  Keep the
              ;; requested optimizer in the protocol even when the reference
              ;; implementation uses its deterministic SGD primitive.
              (nl-llm-agent-p5-finetune model trajs lr epochs)))
           ((eq backend 'gpu)
            (unless (nl-llm-gpu-enable) (error "GPU backend unavailable"))
            (cond
             ((and supervised-p completion-plan)
              (setq context
                    (nl-llm-agent-ondevice-from-model
                     model sequence lr :optimizer optimizer
                     :loss-mode 'completion
                     :transfer-mode (plist-get completion-plan
                                                :transfer-mode)
                     :completion-plan completion-plan))
              (when resume-state
                (nl-llm-agent-ondevice-restore-training-state
                 context optimizer-step
                 (plist-get resume-state :optimizer-state)
                 completion-plan))
              (nl-llm-agent-ondevice-train
               context trajs epochs :start-step start-step
               :loss-starts loss-starts :loss-masks loss-masks
               :shuffle-seed shuffle-seed
               :after-step
               (when checkpoint-file
                 (lambda (active completed planned)
                   (when (or (= completed planned)
                             (= (% completed checkpoint-every) 0))
                     (nl-agent-training-worker--write-checkpoint
                      checkpoint-file request request-hash
                      (nl-llm-agent-ondevice-snapshot active)
                      completed planned completion-plan)
                     (setq checkpoint-written-step completed)))))
              (nl-llm-agent-ondevice-sync context)
              ;; A completed resume has no callback; still persist a fresh
              ;; attempt-bound checkpoint for the new lineage.
              (when checkpoint-file
                (unless (equal checkpoint-written-step total)
                  (nl-agent-training-worker--write-checkpoint
                   checkpoint-file request request-hash
                   (nl-llm-agent-ondevice-snapshot context) total total
                   completion-plan))))
             (supervised-p
              ;; The public supervised trainer owns its resident context and
              ;; cleanup.  The worker owns only device enablement here.
              (nl-llm-agent-supervised-train
               model examples :backend 'gpu :lr lr :epochs epochs
               :optimizer optimizer :sequence sequence))
             (t
                (setq context
                      (nl-llm-agent-ondevice-from-model
                       model sequence lr :optimizer optimizer))
                (when resume-state
                  (nl-llm-agent-ondevice-restore-training-state
                   context optimizer-step
                   (plist-get resume-state :optimizer-state)))
                (nl-llm-agent-ondevice-train
                 context trajs epochs :start-step start-step
                 :after-step
                 (when checkpoint-file
                   (lambda (active completed planned)
                     (when (or (= completed planned)
                               (= (% completed checkpoint-every) 0))
                       (nl-agent-training-worker--write-checkpoint
                        checkpoint-file request request-hash
                        (nl-llm-agent-ondevice-snapshot active)
                        completed planned)
                       (setq checkpoint-written-step completed)))))
                ;; Without checkpointing there was no interval snapshot.  A fully
                ;; completed resume also executes no callback but still emits a new
                ;; attempt-bound checkpoint for its lineage.
                (if checkpoint-file
                    (unless (equal checkpoint-written-step total)
                  (nl-agent-training-worker--write-checkpoint
                       checkpoint-file request request-hash
                       (nl-llm-agent-ondevice-snapshot context) total total))
                  (nl-llm-agent-ondevice-sync context)))))
           (t (error "unsupported training backend %S" backend)))
          ;; Evaluation is deliberately after training and in this child.
          ;; Re-import the parent after training because MODEL is mutated by
          ;; the trainer; promotion must compare the trained model with a
          ;; fresh copy of the exact request parent.
          (let* ((result-model
                  (if checkpoint-file
                      (nl-llm-agent-artifact-export-pav
                       model (plist-get context :step))
                    (nl-llm-agent-artifact-export-pav model)))
                 (promotion-evidence
                  (when promotion-policy
                    (nl-agent-task-promotion-evaluate
                     (nl-agent-training-protocol-import
                      (plist-get request :parent-model))
                     model
                     (plist-get promotion-policy :suite)
                     (plist-get promotion-policy :grammar)
                     :max-sequence
                     (plist-get promotion-policy :max-sequence)
                     :max-steps
                     (plist-get promotion-policy :max-steps)))))
            (setq result
                  (append
                   (list :format nl-agent-training-result-format
                         :attempt (plist-get request :attempt)
                         :request-sha256 request-hash
                         :score (funcall evaluator model)
                         :model result-model)
                   (when promotion-evidence
                     (list :task-promotion promotion-evidence)))))
          (nl-agent-training-protocol-validate-result result request)
          (nl-agent-training-protocol-write result-file result)
          result)
      (when context (ignore-errors (nl-llm-agent-ondevice-free context))))))

;;;###autoload
(defun nl-agent-training-worker-main ()
  "Batch entry point; exactly two paths are accepted in command-line-args-left." 
  (condition-case err
      (if (= (length command-line-args-left) 2)
          (progn (apply #'nl-agent-training-worker-run command-line-args-left) (kill-emacs 0))
        (error "expected request-file and result-file"))
    (error (princ (format "nl-agent-training-worker: %s\n" (error-message-string err)) t) (kill-emacs 1))))

(provide 'nl-agent-training-worker)
