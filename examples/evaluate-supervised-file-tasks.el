;;; evaluate-supervised-file-tasks.el --- fixed native learning probe -*- lexical-binding: t; -*-

;; This is a manual engineering experiment, not a benchmark target.  It builds
;; training demonstrations through the real file-task service, trains one
;; isolated native model with completion-only GPU loss, then evaluates fixed
;; before/after models on two unseen host-scored file tasks.  No result changes
;; the frozen training configuration and nothing is published.

;;; Code:

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (agent-root (expand-file-name ".." here))
       (notes-dev (expand-file-name ".." agent-root)))
  (load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                          (file-name-directory (or load-file-name buffer-file-name
                                                   default-directory))) nil t)
)

(require 'cl-lib)
(require 'nl-llm-agent-action-grammar)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-model)
(require 'nl-llm-agent-ondevice)
(require 'nl-llm-agent-provider)
(require 'nl-llm-agent-supervised)
(require 'nl-llm-evolve)
(require 'nl-llm-gpu)
(require 'nl-agent-task-eval)
(require 'nl-agent-task-eval-service)

(defconst nl-agent-supervised-file-experiment-format
  "nl-agent-supervised-file-experiment-v2")

(defvar nl-agent-supervised-file-experiment-auto-run t
  "When non-nil, loading this example noninteractively runs the experiment.")

(defconst nl-agent-supervised-file-experiment-grammar
  '(:type "file-actions-v1" :max-field 64)
  "Frozen syntax-only action grammar for this experiment.")

(defconst nl-agent-supervised-file-experiment-training-specs
  '((:id "train-status"
     :task "Read train/status.txt, replace `status: old` with `status: new`, then finish."
     :path "train/status.txt" :before "status: old\n" :after "status: new\n"
     :search "status: old" :replace "status: new")
    (:id "train-color"
     :task "Read train/color.txt, replace `color: red` with `color: blue`, then finish."
     :path "train/color.txt" :before "color: red\n" :after "color: blue\n"
     :search "color: red" :replace "color: blue")
    (:id "train-mode"
     :task "Read train/mode.txt, replace `mode: slow` with `mode: fast`, then finish."
     :path "train/mode.txt" :before "mode: slow\n" :after "mode: fast\n"
     :search "mode: slow" :replace "mode: fast")
    (:id "train-state"
     :task "Read train/state.txt, replace `state: cold` with `state: warm`, then finish."
     :path "train/state.txt" :before "state: cold\n" :after "state: warm\n"
     :search "state: cold" :replace "state: warm"))
  "Four frozen synthetic training tasks.  Heldout literals do not occur here.")

(defconst nl-agent-supervised-file-experiment-heldout-suite
  '(:id "supervised-file-heldout"
    :version "1"
    :cases
    [(:id "heldout-level"
      :task "Read heldout/level.txt, replace `level: low` with `level: high`, then finish."
      :files [(:path "heldout/level.txt" :text "level: low\n")]
      :expected [(:path "heldout/level.txt" :text "level: high\n")])
     (:id "heldout-flag"
      :task "Read heldout/flag.txt, replace `flag: off` with `flag: on`, then finish."
      :files [(:path "heldout/flag.txt" :text "flag: off\n")]
      :expected [(:path "heldout/flag.txt" :text "flag: on\n")])])
  "Frozen heldout tasks, never used to construct training completions.")

(defconst nl-agent-supervised-file-experiment-dim 32)
(defconst nl-agent-supervised-file-experiment-ff 64)
(defconst nl-agent-supervised-file-experiment-blocks 1)
(defconst nl-agent-supervised-file-experiment-heads 1)
(defconst nl-agent-supervised-file-experiment-sequence 2048)
(defconst nl-agent-supervised-file-experiment-epochs 16)
(defconst nl-agent-supervised-file-experiment-learning-rate 0.003)
(defconst nl-agent-supervised-file-experiment-maxseq 4096)
(defconst nl-agent-supervised-file-experiment-maxsteps 3)

(defun nl-agent-supervised-file-experiment--tool-action
    (name arguments)
  "Return one typed tool action for NAME and ARGUMENTS."
  (let ((fence (make-string 3 ?`)))
    (concat fence "tool\n"
            (prin1-to-string (list :name name :arguments arguments))
            "\n" fence)))

(defun nl-agent-supervised-file-experiment--outputs (spec)
  "Return the fixed teacher actions for training SPEC."
  (vector
   (nl-agent-supervised-file-experiment--tool-action
    "read" (list :path (plist-get spec :path)))
   (nl-agent-supervised-file-experiment--tool-action
    "edit" (list :path (plist-get spec :path)
                 :search (plist-get spec :search)
                 :replace (plist-get spec :replace)))
   "DONE completed\n"))

(defun nl-agent-supervised-file-experiment--grammar-accepts-p
    (grammar output)
  "Return non-nil when GRAMMAR accepts every character of OUTPUT and stops."
  (let ((position 0)
        (accepted t))
    (while (and accepted (< position (length output)))
      (let ((state (funcall grammar (substring output 0 position)))
            (char (aref output position)))
        (setq accepted
              (pcase state
                (`(:force ,forced) (= char forced))
                (`(:allow ,allowed) (and (stringp allowed)
                                         (string-search (string char) allowed)))
                (_ nil))))
      (setq position (1+ position)))
    (and accepted (eq (funcall grammar output) :stop))))

(defun nl-agent-supervised-file-experiment--training-suite ()
  "Return the detached host-scored training fixture suite."
  (list
   :id "supervised-file-training" :version "1" :cases
   (vconcat
    (mapcar
     (lambda (spec)
       (list :id (copy-sequence (plist-get spec :id))
             :task (copy-sequence (plist-get spec :task))
             :files
             (vector
              (list :path (copy-sequence (plist-get spec :path))
                    :text (copy-sequence (plist-get spec :before))))
             :expected
             (vector
              (list :path (copy-sequence (plist-get spec :path))
                    :text (copy-sequence (plist-get spec :after))))))
     nl-agent-supervised-file-experiment-training-specs))))

(defun nl-agent-supervised-file-experiment--spec-for-task (task)
  "Return the frozen training spec matching TASK."
  (or (cl-find-if
       (lambda (spec) (equal task (plist-get spec :task)))
       nl-agent-supervised-file-experiment-training-specs)
      (error "teacher received a non-training task")))

(defun nl-agent-supervised-file-experiment--teacher-provider ()
  "Return a provider that replays only frozen training demonstrations."
  (nl-llm-agent-provider-new
   "teacher" :models '((:id "training-demonstrations"))
   :open (lambda (_model-id _options) (list :position 0))
   :complete
   (lambda (state messages)
     (let* ((user
             (cl-find-if (lambda (message) (eq (car message) 'user))
                         messages))
            (input (and user (cdr user)))
            (task
             (and (stringp input) (string-prefix-p "TASK: " input)
                  (substring input (length "TASK: "))))
            (spec (and task
                       (nl-agent-supervised-file-experiment--spec-for-task
                        task)))
            (outputs (and spec
                          (nl-agent-supervised-file-experiment--outputs spec)))
            (position (plist-get state :position)))
       (unless (and (integerp position) (< position (length outputs)))
         (error "teacher exhausted its fixed training actions"))
       (setf (plist-get state :position) (1+ position))
       (copy-sequence (aref outputs position))))))

(defun nl-agent-supervised-file-experiment--training-responses ()
  "Run real training fixtures and return (REPORT . raw RESPONSES)."
  (let* ((registry (nl-llm-agent-provider-registry-new))
         (_provider
          (nl-llm-agent-provider-register
           registry
           (nl-agent-supervised-file-experiment--teacher-provider)))
         (runner
          (nl-agent-task-eval-service-runner
           registry "teacher/training-demonstrations"))
         responses
         (report
          (nl-agent-task-eval-run
           (nl-agent-supervised-file-experiment--training-suite)
           (lambda (task workspace maxsteps)
             (let ((response (funcall runner task workspace maxsteps)))
               (push (copy-tree response) responses)
               response))
           :model-id "teacher/training-demonstrations"
           :runner-id "real-file-training-demonstrations-v1"
           :max-steps nl-agent-supervised-file-experiment-maxsteps)))
    (unless (= (plist-get report :passed)
               (plist-get report :total))
      (error "a fixed training demonstration failed host file scoring"))
    (cons report (nreverse responses))))

(defun nl-agent-supervised-file-experiment--records (responses grammar)
  "Extract exact provider prompts and completions from RESPONSES."
  (let (records)
    (dolist (response responses)
      (let ((prefix nil))
        (dolist (message (plist-get response :messages))
          (if (eq (car message) 'assistant)
              (let ((completion (cdr message)))
                (unless
                    (nl-agent-supervised-file-experiment--grammar-accepts-p
                     grammar completion)
                  (error "training completion is outside the frozen grammar"))
                (push
                 (list :prompt (nl-llm-agent--render prefix)
                       :completion (copy-sequence completion))
                 records))
            (setq prefix
                  (append prefix
                          (list (cons (car message)
                                      (copy-sequence (cdr message)))))))
          (when (eq (car message) 'assistant)
            (setq prefix
                  (append prefix
                          (list (cons 'assistant
                                      (copy-sequence (cdr message))))))))))
    (vconcat (nreverse records))))

(defun nl-agent-supervised-file-experiment--parameter-count (model)
  "Return MODEL's exact trainable scalar count."
  (apply
   #'+
   (mapcar
    (lambda (parameter)
      (length (photon-tensor-data (pav-value parameter))))
    (nl-llm-agent--p5-params model))))

(defun nl-agent-supervised-file-experiment--model-digest (model)
  "Return a deterministic SHA-256 identity for MODEL configuration and values."
  (let ((print-length nil)
        (print-level nil)
        (print-circle nil)
        (print-escape-nonascii t)
        (float-output-format nil))
    (secure-hash
     'sha256
     (prin1-to-string
      (list
       :tokenizer (plist-get model :tokenizer)
       :dim (plist-get model :dim) :ff (plist-get model :ff)
       :blocks (plist-get model :nblocks) :heads (plist-get model :heads)
       :parameters
       (mapcar
        (lambda (parameter)
          (copy-sequence (photon-tensor-data (pav-value parameter))))
        (nl-llm-agent--p5-params model)))))))

(defun nl-agent-supervised-file-experiment--inference-model (model id)
  "Export trainable PAV MODEL into a detached validated inference model for ID."
  (nl-llm-agent-artifact--checkpoint-model
   (append
    (list :format nl-llm-ckpt-format)
    (nl-llm-agent-artifact-export-pav model))
   id))

(defun nl-agent-supervised-file-experiment--native-registry
    (before after grammar)
  "Expose already-exported inference models BEFORE and AFTER under GRAMMAR."
  (let ((registry (nl-llm-agent-provider-registry-new)))
    (nl-llm-agent-provider-register
     registry
     (nl-llm-agent-model-provider
      "native"
      (list
       (list :id "before" :model before :grammar grammar
             :maxseq nl-agent-supervised-file-experiment-maxseq)
       (list :id "after" :model after :grammar grammar
             :maxseq nl-agent-supervised-file-experiment-maxseq))))
    registry))

(defun nl-agent-supervised-file-experiment--diagnostic (value)
  "Return bounded diagnostic text for synthetic experiment VALUE."
  (let ((text (format "%s" (or value "runtime returned no diagnostic"))))
    (substring-no-properties text 0 (min 512 (length text)))))

(defun nl-agent-supervised-file-experiment--evaluate
    (suite registry qualified-model)
  "Evaluate SUITE with QUALIFIED-MODEL, rejecting runtime plumbing errors."
  (let ((runner
         (nl-agent-task-eval-service-runner registry qualified-model))
        diagnostics)
    (let ((report
           (nl-agent-task-eval-run
            suite
            (lambda (task workspace maxsteps)
              (condition-case err
                  (let ((response (funcall runner task workspace maxsteps)))
                    (when (eq (plist-get response :status) 'error)
                      (push
                       (nl-agent-supervised-file-experiment--diagnostic
                        (plist-get response :error))
                       diagnostics))
                    response)
                ((error quit)
                 (push
                  (nl-agent-supervised-file-experiment--diagnostic err)
                  diagnostics)
                 (signal (car err) (cdr err)))))
            :model-id qualified-model
            :runner-id nl-agent-task-eval-service-runner-id
            :max-steps nl-agent-supervised-file-experiment-maxsteps)))
      (when (cl-some
             (lambda (case) (eq (plist-get case :status) 'error))
             (append (plist-get report :cases) nil))
        (error "heldout runtime plumbing error: %s"
               (mapconcat
                #'identity
                (or (nreverse diagnostics)
                    '("runtime returned no diagnostic"))
                "; ")))
      report)))

;;;###autoload
(defun nl-agent-supervised-file-experiment-run ()
  "Run and return the fixed supervised native file-task experiment."
  (let* ((grammar
          (nl-llm-agent-grammar-file-actions 64))
         (training
          (nl-agent-supervised-file-experiment--training-responses))
         (records
          (nl-agent-supervised-file-experiment--records
           (cdr training) grammar))
         (encoded
          (nl-llm-agent-supervised-encode records "utf8-byte-v1"))
         (trajectories (plist-get encoded :trajectories))
         (loss-starts (plist-get encoded :loss-starts))
         (max-tokens (apply #'max (mapcar #'length trajectories)))
         (base
          (nl-llm-agent-improve-model
           nl-agent-supervised-file-experiment-dim
           nl-agent-supervised-file-experiment-ff 256
           nl-agent-supervised-file-experiment-blocks
           nl-agent-supervised-file-experiment-heads "utf8-byte-v1"))
         (before (nl-llm-evolve-copy-model base))
         (after (nl-llm-evolve-copy-model base))
         (initial-sha256
          (nl-agent-supervised-file-experiment--model-digest base))
         (parameter-count
          (nl-agent-supervised-file-experiment--parameter-count base))
         (before-inference nil)
         (before-report nil)
         context gpu-enabled)
    ;; All host fixtures, exact service-derived messages, grammar membership,
    ;; encoded bounds, geometry, and model clones exist before GPU allocation.
    (unless (= (length records) 12)
      (error "fixed experiment must produce exactly 12 completion records"))
    (when (> max-tokens nl-agent-supervised-file-experiment-sequence)
      (error "training example needs %d tokens, fixed GPU sequence is %d"
             max-tokens nl-agent-supervised-file-experiment-sequence))
    (unless (equal initial-sha256
                   (nl-agent-supervised-file-experiment--model-digest before))
      (error "before model is not the fixed initial snapshot"))
    (unless (equal initial-sha256
                   (nl-agent-supervised-file-experiment--model-digest after))
      (error "training candidate is not the fixed initial snapshot"))
    ;; Export the immutable baseline before training.  Artifact conversion is
    ;; authoritative for decoder metadata such as KV-head count and detaches
    ;; every inference tensor from the trainable PAV model.
    (setq before-inference
          (nl-agent-supervised-file-experiment--inference-model
           before "supervised-file-before"))
    ;; The real heldout baseline is also the end-to-end inference preflight.
    ;; Run it before allocating or training on the GPU so a broken decoder
    ;; route cannot waste training and later masquerade as a zero score.
    (message "supervised-file experiment: heldout before evaluation")
    (setq before-report
          (nl-agent-supervised-file-experiment--evaluate
           nl-agent-supervised-file-experiment-heldout-suite
           (nl-agent-supervised-file-experiment--native-registry
            before-inference before-inference grammar)
           "native/before"))
    (unwind-protect
        (progn
          (message
           "supervised-file experiment: GPU training start (%d records, %d epochs)"
           (length records) nl-agent-supervised-file-experiment-epochs)
          (setq gpu-enabled (nl-llm-gpu-enable))
          (unless gpu-enabled
            (error "fixed supervised experiment requires the local GPU"))
          (setq context
                (nl-llm-agent-ondevice-from-model
                 after nl-agent-supervised-file-experiment-sequence
                 nl-agent-supervised-file-experiment-learning-rate
                 :optimizer 'adam :loss-mode 'completion
                 :transfer-mode 'compact))
          (nl-llm-agent-ondevice-train
           context trajectories nl-agent-supervised-file-experiment-epochs
           :loss-starts loss-starts
           :after-step
           (lambda (_context completed _total)
             (when (= (% completed (length records)) 0)
               (message
                "supervised-file experiment: completed epoch %d/%d"
                (/ completed (length records))
                nl-agent-supervised-file-experiment-epochs))))
          (nl-llm-agent-ondevice-sync context))
      (when context
        (nl-llm-agent-ondevice-free context))
      (when gpu-enabled
        (nl-llm-gpu-disable)))
    (unless (equal initial-sha256
                   (nl-agent-supervised-file-experiment--model-digest before))
      (error "training mutated the immutable before model"))
    (let* ((trained-sha256
            (nl-agent-supervised-file-experiment--model-digest after))
           (after-inference
            (nl-agent-supervised-file-experiment--inference-model
             after "supervised-file-after"))
           (registry
            (nl-agent-supervised-file-experiment--native-registry
             before-inference after-inference grammar))
           (after-report
            (progn
              (message "supervised-file experiment: heldout after evaluation")
              (nl-agent-supervised-file-experiment--evaluate
               nl-agent-supervised-file-experiment-heldout-suite
               registry "native/after")))
           (before-final-sha256
            (nl-agent-supervised-file-experiment--model-digest before))
           (trained-final-sha256
            (nl-agent-supervised-file-experiment--model-digest after)))
      (unless (equal before-final-sha256 initial-sha256)
        (error "heldout evaluation mutated the immutable before model"))
      (unless (equal trained-final-sha256 trained-sha256)
        (error "heldout evaluation mutated the trained model"))
      (list
       :format nl-agent-supervised-file-experiment-format
       :dataset-sha256 (copy-sequence (plist-get encoded :dataset-sha256))
       :grammar (copy-tree nl-agent-supervised-file-experiment-grammar)
       :geometry
       (list :tokenizer "utf8-byte-v1"
             :dim nl-agent-supervised-file-experiment-dim
             :ff nl-agent-supervised-file-experiment-ff
             :blocks nl-agent-supervised-file-experiment-blocks
             :heads nl-agent-supervised-file-experiment-heads
             :parameters parameter-count)
       :training
       (list :backend 'gpu :optimizer 'adam
             :transfer-mode 'compact
             :learning-rate nl-agent-supervised-file-experiment-learning-rate
             :sequence nl-agent-supervised-file-experiment-sequence
             :epochs nl-agent-supervised-file-experiment-epochs
             :examples (length records)
             :steps (* (length records)
                       nl-agent-supervised-file-experiment-epochs)
             :max-example-tokens max-tokens)
       :inference
       (list :maxseq nl-agent-supervised-file-experiment-maxseq
             :max-steps nl-agent-supervised-file-experiment-maxsteps)
       :initial-sha256 initial-sha256
       :trained-sha256 trained-sha256
       :before-identity-preserved t
       :trained-identity-preserved t
       :weights-changed (not (equal trained-sha256 initial-sha256))
       :training-demonstrations (car training)
       :before before-report :after after-report
       :comparison (nl-agent-task-eval-compare before-report after-report)))))

(when (and noninteractive nl-agent-supervised-file-experiment-auto-run)
  (let ((print-length nil)
        (print-level nil)
        (print-circle nil)
        (print-escape-nonascii t))
    (prin1 (nl-agent-supervised-file-experiment-run))
    (terpri)))

(provide 'evaluate-supervised-file-tasks)

;;; evaluate-supervised-file-tasks.el ends here
