;;; diagnose-supervised-file-tasks.el --- inspect learned file actions -*- lexical-binding: t; -*-

;; This manual diagnostic reuses the frozen supervised-file experiment's
;; synthetic training plan, but does not evaluate its capability suite.  It
;; trains once, then inspects unforced native actions on the four training
;; fixtures and two distinct development fixtures.  Nothing is published.

;;; Code:

(defvar nl-agent-supervised-file-experiment-auto-run nil)
(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (experiment
        (expand-file-name "evaluate-supervised-file-tasks.el" here))
       (noninteractive nil))
  (load experiment nil nil t))

(require 'cl-lib)

(defvar nl-agent-task-eval-service-runner-id)
(defvar nl-agent-supervised-file-experiment-format)
(defvar nl-agent-supervised-file-experiment-dim)
(defvar nl-agent-supervised-file-experiment-ff)
(defvar nl-agent-supervised-file-experiment-blocks)
(defvar nl-agent-supervised-file-experiment-heads)
(defvar nl-agent-supervised-file-experiment-sequence)
(defvar nl-agent-supervised-file-experiment-epochs)
(defvar nl-agent-supervised-file-experiment-learning-rate)
(defvar nl-agent-supervised-file-experiment-maxseq)
(defvar nl-agent-supervised-file-experiment-maxsteps)

(declare-function nl-agent-supervised-file-experiment--training-responses
                  "evaluate-supervised-file-tasks" ())
(declare-function nl-agent-supervised-file-experiment--records
                  "evaluate-supervised-file-tasks" (responses grammar))
(declare-function nl-agent-supervised-file-experiment--training-suite
                  "evaluate-supervised-file-tasks" ())
(declare-function nl-agent-supervised-file-experiment--diagnostic
                  "evaluate-supervised-file-tasks" (value))
(declare-function nl-agent-supervised-file-experiment--model-digest
                  "evaluate-supervised-file-tasks" (model))
(declare-function nl-agent-supervised-file-experiment--inference-model
                  "evaluate-supervised-file-tasks" (model id))
(declare-function nl-agent-supervised-file-experiment--native-registry
                  "evaluate-supervised-file-tasks" (before after grammar))
(declare-function nl-agent-supervised-file-experiment--parameter-count
                  "evaluate-supervised-file-tasks" (model))
(declare-function nl-agent-task-eval-service-runner
                  "nl-agent-task-eval-service"
                  (provider-registry qualified-model))
(declare-function nl-agent-task-eval-run "nl-agent-task-eval"
                  (suite run-case &rest keys))
(declare-function nl-llm-agent-grammar-file-actions
                  "nl-llm-agent-action-grammar" (&optional max-field))
(declare-function nl-llm-agent-supervised-encode
                  "nl-llm-agent-supervised" (records &optional tokenizer))
(declare-function nl-llm-agent-improve-model "nl-llm-agent-improve"
                  (&optional dim ff vocab nblocks heads tokenizer))
(declare-function nl-llm-evolve-copy-model "nl-llm-evolve" (model))
(declare-function nl-llm-gpu-enable "nl-llm-gpu" ())
(declare-function nl-llm-gpu-disable "nl-llm-gpu" ())
(declare-function nl-llm-agent-ondevice-from-model
                  "nl-llm-agent-ondevice" (model seq lr &rest keys))
(declare-function nl-llm-agent-ondevice-train
                  "nl-llm-agent-ondevice" (ctx trajs epochs &rest keys))
(declare-function nl-llm-agent-ondevice-sync
                  "nl-llm-agent-ondevice" (ctx))
(declare-function nl-llm-agent-ondevice-free
                  "nl-llm-agent-ondevice" (ctx))

(defconst nl-agent-supervised-file-diagnostic-format
  "nl-agent-supervised-file-diagnostic-v1")

(defconst nl-agent-supervised-file-diagnostic-max-trace-events
  nl-agent-supervised-file-experiment-maxsteps)

(defconst nl-agent-supervised-file-diagnostic-max-trace-chars 512)

(defvar nl-agent-supervised-file-diagnostic-auto-run t
  "When non-nil, loading this example noninteractively runs the diagnostic.")

(defconst nl-agent-supervised-file-diagnostic-development-suite
  '(:id "supervised-file-development" :version "1"
    :cases
    [(:id "development-name"
      :task "Read dev/name.txt, replace `name: alpha` with `name: beta`, then finish."
      :files [(:path "dev/name.txt" :text "name: alpha\n")]
      :expected [(:path "dev/name.txt" :text "name: beta\n")])
     (:id "development-count"
      :task "Read dev/count.txt, replace `count: one` with `count: two`, then finish."
      :files [(:path "dev/count.txt" :text "count: one\n")]
      :expected [(:path "dev/count.txt" :text "count: two\n")])])
  "Synthetic development tasks excluded from supervised training records.")

(defun nl-agent-supervised-file-diagnostic--bounded-text (value)
  "Bound VALUE from the trusted synthetic runtime, marking any truncation.
This presentation bound is not a resource guard for arbitrary input."
  (let* ((print-length nil)
         (print-level nil)
         (print-circle t)
         (print-escape-nonascii t)
         (text (if (stringp value)
                   (substring-no-properties value)
                 (prin1-to-string value)))
         (length (length text))
         (limit nl-agent-supervised-file-diagnostic-max-trace-chars))
    (list :text (substring text 0 (min length limit))
          :truncated (> length limit)
          :original-chars length)))

(defun nl-agent-supervised-file-diagnostic--trace (response)
  "Project RESPONSE's chronological trajectory into bounded trace evidence."
  (let* ((trajectory (plist-get response :trajectory))
         (available (if (listp trajectory) (length trajectory) 0))
         (count (min available
                     nl-agent-supervised-file-diagnostic-max-trace-events))
         (events (make-vector count nil)))
    (dotimes (index count)
      (let* ((event (nth index trajectory))
             (tool-result (plist-get event :tool-result)))
        (aset
         events index
         (list
          :step (plist-get event :step)
          :assistant
          (nl-agent-supervised-file-diagnostic--bounded-text
           (plist-get event :assistant))
          :action
          (nl-agent-supervised-file-diagnostic--bounded-text
           (plist-get event :action))
          :tool-status (and tool-result (plist-get tool-result :status))
          :observation
          (nl-agent-supervised-file-diagnostic--bounded-text
           (plist-get event :observation))))))
    (list :status (plist-get response :status)
          :steps (plist-get response :steps)
          :events events
          :events-available available
          :events-truncated (> available count))))

(defun nl-agent-supervised-file-diagnostic--evaluate
    (label suite registry qualified-model)
  "Evaluate SUITE for LABEL and return file score plus bounded traces."
  (let* ((runner
          (nl-agent-task-eval-service-runner registry qualified-model))
         (cases (plist-get suite :cases))
         (index 0)
         traces
         diagnostics)
    (let ((report
           (nl-agent-task-eval-run
            suite
            (lambda (task workspace maxsteps)
              (let ((case-id (plist-get (aref cases index) :id)))
                (message
                 "supervised-file diagnostic: %s case %d/%d (%s)"
                 label (1+ index) (length cases) case-id)
                (setq index (1+ index))
                (condition-case err
                    (let ((response (funcall runner task workspace maxsteps)))
                      (push
                       (list :id (copy-sequence case-id)
                             :runtime
                             (nl-agent-supervised-file-diagnostic--trace
                              response))
                       traces)
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
                   (signal (car err) (cdr err))))))
            :model-id qualified-model
            :runner-id nl-agent-task-eval-service-runner-id
            :max-steps nl-agent-supervised-file-experiment-maxsteps)))
      (when (cl-some
             (lambda (case) (eq (plist-get case :status) 'error))
             (append (plist-get report :cases) nil))
        (error "%s runtime plumbing error: %s"
               label
               (mapconcat
                #'identity
                (or (nreverse diagnostics)
                    '("runtime returned no diagnostic"))
                "; ")))
      (list :file-score report :traces (vconcat (nreverse traces))))))

;;;###autoload
(defun nl-agent-supervised-file-diagnostic-run ()
  "Train the fixed synthetic model and return bounded action diagnostics."
  (let* ((grammar (nl-llm-agent-grammar-file-actions 64))
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
         (trained (nl-llm-evolve-copy-model base))
         (initial-sha256
          (nl-agent-supervised-file-experiment--model-digest base))
         context gpu-enabled)
    (unless (= (length records) 12)
      (error "diagnostic requires exactly 12 fixed completion records"))
    (when (> max-tokens nl-agent-supervised-file-experiment-sequence)
      (error "diagnostic record needs %d tokens, fixed sequence is %d"
             max-tokens nl-agent-supervised-file-experiment-sequence))
    (unless (equal initial-sha256
                   (nl-agent-supervised-file-experiment--model-digest trained))
      (error "diagnostic training clone does not match its initial model"))
    (unwind-protect
        (progn
          (message
           "supervised-file diagnostic: GPU training start (%d records, %d epochs)"
           (length records) nl-agent-supervised-file-experiment-epochs)
          (setq gpu-enabled (nl-llm-gpu-enable))
          (unless gpu-enabled
            (error "supervised-file diagnostic requires the local GPU"))
          (setq context
                (nl-llm-agent-ondevice-from-model
                 trained nl-agent-supervised-file-experiment-sequence
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
                "supervised-file diagnostic: completed epoch %d/%d"
                (/ completed (length records))
                nl-agent-supervised-file-experiment-epochs))))
          (nl-llm-agent-ondevice-sync context))
      (when context
        (nl-llm-agent-ondevice-free context))
      (when gpu-enabled
        (nl-llm-gpu-disable)))
    (unless (equal initial-sha256
                   (nl-agent-supervised-file-experiment--model-digest base))
      (error "diagnostic training mutated the immutable initial model"))
    (let* ((trained-sha256
            (nl-agent-supervised-file-experiment--model-digest trained))
           (inference
            (nl-agent-supervised-file-experiment--inference-model
             trained "supervised-file-diagnostic"))
           (registry
            (nl-agent-supervised-file-experiment--native-registry
             inference inference grammar))
           (training-evaluation
            (progn
              (message
               "supervised-file diagnostic: training-task inference start")
              (nl-agent-supervised-file-diagnostic--evaluate
               "training-task"
               (nl-agent-supervised-file-experiment--training-suite)
               registry "native/after")))
           (development-evaluation
            (progn
              (message
               "supervised-file diagnostic: development inference start")
              (nl-agent-supervised-file-diagnostic--evaluate
               "development"
               nl-agent-supervised-file-diagnostic-development-suite
               registry "native/after")))
           (final-sha256
            (nl-agent-supervised-file-experiment--model-digest trained)))
      (unless (equal trained-sha256 final-sha256)
        (error "diagnostic inference mutated the trained model"))
      (list
       :format nl-agent-supervised-file-diagnostic-format
       :source-experiment-format nl-agent-supervised-file-experiment-format
       :dataset-sha256 (copy-sequence (plist-get encoded :dataset-sha256))
       :geometry
       (list :tokenizer "utf8-byte-v1"
             :dim nl-agent-supervised-file-experiment-dim
             :ff nl-agent-supervised-file-experiment-ff
             :blocks nl-agent-supervised-file-experiment-blocks
             :heads nl-agent-supervised-file-experiment-heads
             :parameters
             (nl-agent-supervised-file-experiment--parameter-count base))
       :training
       (list :backend 'gpu :optimizer 'adam :transfer-mode 'compact
             :learning-rate nl-agent-supervised-file-experiment-learning-rate
             :sequence nl-agent-supervised-file-experiment-sequence
             :epochs nl-agent-supervised-file-experiment-epochs
             :examples (length records)
             :steps (* (length records)
                       nl-agent-supervised-file-experiment-epochs)
             :max-example-tokens max-tokens)
       :inference
       (list :maxseq nl-agent-supervised-file-experiment-maxseq
             :max-steps nl-agent-supervised-file-experiment-maxsteps
             :trace-events-limit
             nl-agent-supervised-file-diagnostic-max-trace-events
             :trace-field-chars-limit
             nl-agent-supervised-file-diagnostic-max-trace-chars)
       :initial-sha256 initial-sha256
       :trained-sha256 trained-sha256
       :initial-identity-preserved t
       :trained-identity-preserved t
       :weights-changed (not (equal trained-sha256 initial-sha256))
       :training-task-evaluation training-evaluation
       :development-task-evaluation development-evaluation))))

(when (and noninteractive nl-agent-supervised-file-diagnostic-auto-run)
  (let ((print-length nil)
        (print-level nil)
        (print-circle nil)
        (print-escape-nonascii t))
    (prin1 (nl-agent-supervised-file-diagnostic-run))
    (terpri)))

(provide 'diagnose-supervised-file-tasks)

;;; diagnose-supervised-file-tasks.el ends here
