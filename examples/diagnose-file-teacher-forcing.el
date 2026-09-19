;;; diagnose-file-teacher-forcing.el --- bounded teacher-forcing diagnostic -*- lexical-binding: t; -*-

;; Runs the frozen initialized-file diagnostic, then scores the same twelve
;; training completions with gold-prefix teacher forcing.  This is a
;; diagnostic of the trained model's conditional distributions, not a
;; capability measurement.

;;; Code:

(require 'cl-lib)

(defconst nl-agent-file-teacher-forcing-source-sha256
  "a66db977a9f81b57a9c5f7666167abb1211ba93491709606f4425b63732e81bb")

(defconst nl-agent-file-teacher-forcing-format
  "nl-agent-file-teacher-forcing-v1")

(defvar nl-agent-file-teacher-forcing-auto-run nil
  "When non-nil, loading this example noninteractively runs the diagnostic.")

(defvar nl-agent-initialized-file-diagnostic-auto-run)
(defvar nl-agent-supervised-file-diagnostic-auto-run)

(defun nl-agent-file-teacher-forcing--file-sha256 (path)
  "Return the byte SHA-256 digest of PATH without text decoding."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (secure-hash 'sha256 (current-buffer))))

;; Load the frozen runner without allowing either file's top-level autorun.
;; The source guard is intentionally byte exact: this probe must not silently
;; drift with a changed baseline.
(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (source (expand-file-name "diagnose-initialized-file-tasks.el" here)))
  (unless (equal (nl-agent-file-teacher-forcing--file-sha256 source)
                 nl-agent-file-teacher-forcing-source-sha256)
    (error "frozen initialized-file diagnostic source SHA mismatch: %s"
           (nl-agent-file-teacher-forcing--file-sha256 source)))
  (let ((nl-agent-initialized-file-diagnostic-auto-run nil)
        (nl-agent-supervised-file-diagnostic-auto-run nil))
    (load source nil nil t)))

(require 'nl-llm-agent-action-grammar)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-model)
(require 'nl-llm-agent-tokenizer)
(require 'nl-llm-decode)
(require 'nl-llm-inference-runtime)
(require 'nl-llm-agent-supervised)

(declare-function nl-agent-initialized-file-diagnostic-run
                  "diagnose-initialized-file-tasks" ())
(declare-function nl-agent-supervised-file-experiment--training-responses
                  "evaluate-supervised-file-tasks" ())
(declare-function nl-agent-supervised-file-experiment--records
                  "evaluate-supervised-file-tasks" (responses grammar))
(declare-function nl-agent-supervised-file-experiment--model-digest
                  "evaluate-supervised-file-tasks" (model))
(declare-function nl-agent-supervised-file-experiment--inference-model
                  "evaluate-supervised-file-tasks" (model id))
(declare-function nl-agent-supervised-file-experiment--native-registry
                  "evaluate-supervised-file-tasks" (before after grammar))
(declare-function nl-llm-agent-model-step-fn "nl-llm-agent-model"
                  (model caches))
(declare-function nl-llm-agent--argmax-among "nl-llm-agent-model"
                  (logits ids))
(declare-function nl-llm-agent-tokenizer-encode "nl-llm-agent-tokenizer"
                  (text &optional identifier))
(declare-function nl-llm-agent-tokenizer-decode "nl-llm-agent-tokenizer"
                  (ids &optional identifier))
(declare-function nl-llm-agent-tokenizer-vocab "nl-llm-agent-tokenizer"
                  (&optional identifier))
(declare-function nl-llm-agent-grammar-file-actions
                  "nl-llm-agent-action-grammar" (&optional max-field))
(declare-function nl-llm-agent-supervised-encode
                  "nl-llm-agent-supervised" (records &optional tokenizer))
(declare-function nl-llm-inference-runtime-prepare
                  "nl-llm-inference-runtime" (&optional mode))
(declare-function nl-llm-gpu-available-p "nl-llm-gpu" ())
(declare-function nl-llm-dcache-new "nl-llm-decode"
                  (max-seq dim heads kvh))

(defconst nl-agent-file-teacher-forcing--tokenizer "utf8-byte-v1")
(defconst nl-agent-file-teacher-forcing--vocab 256)

(defun nl-agent-file-teacher-forcing--finite-number-p (value)
  "Return non-nil when VALUE is a finite number suitable as a logit."
  (and (numberp value)
       (= value value)                    ; rejects NaN
       (condition-case nil
           (< (abs (float value)) 1.0e300) ; rejects infinities
         (error nil))))

(defun nl-agent-file-teacher-forcing--validate-logits (logits)
  "Validate and return a 256-entry finite LOGITS vector."
  (unless (and (vectorp logits)
               (= (length logits) nl-agent-file-teacher-forcing--vocab))
    (error "teacher-forcing logits must be a 256-entry vector, got %S"
           (and (vectorp logits) (length logits))))
  (dotimes (index (length logits))
    (unless (nl-agent-file-teacher-forcing--finite-number-p
             (aref logits index))
      (error "teacher-forcing logits[%d] is not finite: %S"
             index (aref logits index))))
  logits)

(defun nl-agent-file-teacher-forcing--validate-prompt-ids (ids)
  "Validate nonempty prompt token ID list IDS and return a detached copy."
  (unless (and (listp ids) ids)
    (error "teacher-forcing prompt token list must be nonempty"))
  (let ((copy nil)
        (tail ids))
    (while (consp tail)
      (let ((id (car tail)))
        (unless (and (integerp id) (<= 0 id) (< id 256))
          (error "teacher-forcing prompt token is invalid: %S" id))
        (push id copy))
      (setq tail (cdr tail)))
    (unless (null tail)
      (error "teacher-forcing prompt token list must be proper"))
    (nreverse copy)))

(defun nl-agent-file-teacher-forcing--logsumexp (logits)
  "Return stable log-sum-exp of validated LOGITS."
  (let ((maximum (aref logits 0))
        (sum 0.0))
    (dotimes (index (1- (length logits)))
      (let ((value (aref logits (1+ index))))
        (when (> value maximum) (setq maximum value))))
    (dotimes (index (length logits))
      (setq sum (+ sum (exp (- (aref logits index) maximum)))))
    (+ maximum (log sum))))

(defun nl-agent-file-teacher-forcing--grammar-state (grammar prefix)
  "Validate GRAMMAR's state at gold PREFIX and return it."
  (let ((state (funcall grammar prefix)))
    (unless (or (eq state :stop)
                (and (listp state)
                     (memq (car state) '(:force :allow))))
      (error "teacher-forcing grammar returned invalid state %S" state))
    state))

(defun nl-agent-file-teacher-forcing--choice-result
    (state completion position prefix logits gold-id)
  "Score one grammar STATE and return its optional choice result.
The UTF-8 byte tokenizer uses the ASCII character code itself as the token ID;
in particular `A' is 65 and newline is 10, unlike the legacy ASCII tokenizer."
  (cond
   ((eq state :stop)
    (error "grammar stopped before completion end at %d" position))
   ((and (listp state) (eq (car state) :force))
    (let ((forced (cadr state)))
      (unless (and (integerp forced)
                   (= forced (aref completion position)))
        (error "grammar force disagrees with gold at %d" position)))
    nil)
   ((and (listp state) (eq (car state) :allow))
    (let ((allowed (cadr state)))
      (unless (stringp allowed)
        (error "grammar allow set is not a string at %d" position))
      (let ((allowed-ids nil))
        (dolist (char (string-to-list allowed))
          (unless (and (integerp char) (<= 0 char) (<= char 127))
            (error "grammar allow set is not ASCII at %d" position))
          (cl-pushnew char allowed-ids))
        (setq allowed-ids (nreverse allowed-ids))
        (unless (memq gold-id allowed-ids)
          (error "gold token %d is outside grammar at %d"
                 gold-id position))
        (let ((choice (nl-llm-agent--argmax-among logits allowed-ids)))
          (list :correct (= choice gold-id)
                :first-wrong
                (unless (= choice gold-id)
                  (list :index position
                        :expected (string (aref completion position))
                        :predicted
                        (nl-llm-agent-tokenizer-decode
                         (list choice)
                         nl-agent-file-teacher-forcing--tokenizer)
                        :gold-prefix (copy-sequence prefix))))))))
   (t
    (error "grammar returned invalid state %S" state))))

(defun nl-agent-file-teacher-forcing-score
    (prompt-ids completion step-fn grammar)
  "Score COMPLETION after PROMPT-IDS with gold-prefix teacher forcing.
STEP-FN consumes one token ID and returns the next 256 logits vector.  GRAMMAR
is called with the already-consumed gold completion prefix.  Every completion
token is scored unrestricted; only `:allow' positions contribute to the
grammar-choice counters.  The gold token, never the prediction, is fed back.
This helper has no model or cache knowledge and is suitable for deterministic
unit tests."
  (let ((prompt-ids
         (nl-agent-file-teacher-forcing--validate-prompt-ids prompt-ids)))
    (unless (and (stringp completion) (> (length completion) 0))
      (error "teacher-forcing completion must be a nonempty string"))
    (dolist (char (string-to-list completion))
      (when (> char 127)
        (error "teacher-forcing completion must be ASCII: U+%04X" char)))
    (let ((completion-ids
           (nl-llm-agent-tokenizer-encode
            completion nl-agent-file-teacher-forcing--tokenizer))
          (logits nil)
          (prefix "")
          (position 0)
          (nll 0.0)
          (top1-correct 0)
          (choice-correct 0)
          (choice-total 0)
          (first-wrong nil)
          (all-ids (number-sequence 0 255)))
      ;; Prefill the complete prompt before any completion token is scored.
      (dolist (id prompt-ids)
        (setq logits
              (nl-agent-file-teacher-forcing--validate-logits
               (funcall step-fn id))))
      (unless logits
        (error "teacher-forcing prompt produced no logits"))
      (dolist (gold-id completion-ids)
        (setq logits (nl-agent-file-teacher-forcing--validate-logits logits))
        (let* ((state
                (nl-agent-file-teacher-forcing--grammar-state grammar prefix))
               (top1 (nl-llm-agent--argmax-among logits all-ids))
               (gold-logit (aref logits gold-id))
               (correct (= top1 gold-id)))
          (when correct (setq top1-correct (1+ top1-correct)))
          (setq nll (+ nll (- (nl-agent-file-teacher-forcing--logsumexp logits)
                              gold-logit)))
          (let ((choice
                 (nl-agent-file-teacher-forcing--choice-result
                  state completion position prefix logits gold-id)))
            (when choice
              (setq choice-total (1+ choice-total))
              (if (plist-get choice :correct)
                  (setq choice-correct (1+ choice-correct))
                (unless first-wrong
                  (setq first-wrong (plist-get choice :first-wrong))))))
          ;; The gold byte is deliberately fed after scoring, including the
          ;; final byte, so no sampled prediction can affect a later position.
          (setq logits
                (nl-agent-file-teacher-forcing--validate-logits
                 (funcall step-fn gold-id)))
          (setq prefix (concat prefix (string (aref completion position)))
                position (1+ position))))
      (unless (eq (nl-agent-file-teacher-forcing--grammar-state grammar prefix)
                  :stop)
        (error "grammar did not stop exactly at completion end"))
      (list :prompt-bytes (length prompt-ids)
            :completion-bytes (length completion-ids)
            :unrestricted256-top1-correct top1-correct
            :unrestricted256-top1-total (length completion-ids)
            :grammar-choice-correct choice-correct
            :grammar-choice-total choice-total
            :first-wrong-grammar-choice first-wrong
            :gold-prefix (copy-sequence prefix)
            :expected-completion (copy-sequence completion)
            :all-choices-correct (= choice-correct choice-total)
            :nll nll))))

(defun nl-agent-file-teacher-forcing--score-record (model record)
  "Score one RECORD using native MODEL and fresh CPU KV caches."
  (let* ((prompt (plist-get record :prompt))
         (completion (plist-get record :completion))
         (prompt-ids
          (nl-llm-agent-tokenizer-encode
           prompt nl-agent-file-teacher-forcing--tokenizer))
         (completion-ids
          (nl-llm-agent-tokenizer-encode
           completion nl-agent-file-teacher-forcing--tokenizer))
         (capacity (+ (length prompt-ids) (length completion-ids)))
         (dim (plist-get model :dim))
         (heads (plist-get model :heads))
         (kvh (or (plist-get model :kvh) heads))
         (caches
          (mapcar (lambda (_block)
                    (nl-llm-dcache-new capacity dim heads kvh))
                  (plist-get model :blocks)))
         (step (nl-llm-agent-model-step-fn model caches)))
    (nl-agent-file-teacher-forcing-score
     prompt-ids completion step
     (nl-llm-agent-grammar-file-actions 64))))

(defun nl-agent-file-teacher-forcing--score-records (model records)
  "Score RECORDS under MODEL after explicitly preparing byte-code inference."
  (let (results)
    (unwind-protect
        (progn
          (when (nl-llm-gpu-available-p)
            (error "teacher-forcing requires the frozen runner's GPU to be disabled"))
          ;; This explicit mode is intentional: fallback to source would make
          ;; the diagnostic's native path ambiguous.
          (nl-llm-inference-runtime-prepare 'byte-code)
          (dotimes (index (length records))
            (message "file teacher forcing: record %d/%d"
                     (1+ index) (length records))
            (push (nl-agent-file-teacher-forcing--score-record
                   model (aref records index))
                  results)))
      ;; Never leave process-global byte-code replacements installed.
      (ignore-errors (nl-llm-inference-runtime-prepare 'source)))
    (nreverse results)))

(defun nl-agent-file-teacher-forcing--records (training-responses)
  "Reconstruct and encode the frozen twelve training records."
  (let* ((grammar (nl-llm-agent-grammar-file-actions 64))
         (records
          (nl-agent-supervised-file-experiment--records
           (cdr training-responses) grammar))
         (encoded
          (nl-llm-agent-supervised-encode
           records nl-agent-file-teacher-forcing--tokenizer)))
    (unless (= (length records) 12)
      (error "teacher-forcing requires exactly 12 training records, got %d"
             (length records)))
    (list :records records :encoded encoded)))

;;;###autoload
(defun nl-agent-file-teacher-forcing-run ()
  "Run the frozen diagnostic and append bounded teacher-forcing metrics.
The underlying diagnostic remains the complete report and is run unchanged;
this function only intercepts its inference export to retain the trained PAV
model.  No GPU operation is initiated here beyond the frozen runner itself."
  (let* ((exporter 'nl-agent-supervised-file-experiment--inference-model)
         (original (symbol-function exporter))
         (capture-count 0)
         (trained nil)
         (diagnostic nil))
    (cl-letf (((symbol-function exporter)
               (lambda (model id)
                 (setq capture-count (1+ capture-count))
                 (unless trained (setq trained model))
                 ;; Preserve the exact original call and return value.
                 (funcall original model id))))
      (setq diagnostic (nl-agent-initialized-file-diagnostic-run)))
    (unless (= capture-count 1)
      (error "teacher-forcing captured %d inference exports, expected 1"
             capture-count))
    (unless trained
      (error "teacher-forcing did not capture the trained model"))
    (let* ((parts
            (nl-agent-file-teacher-forcing--records
             (nl-agent-supervised-file-experiment--training-responses)))
           (records (plist-get parts :records))
           (encoded (plist-get parts :encoded))
           (dataset-sha256 (plist-get encoded :dataset-sha256))
           (base-report (plist-get diagnostic :diagnostic))
           (base-dataset-sha256 (plist-get base-report :dataset-sha256))
           (trained-sha256
            (nl-agent-supervised-file-experiment--model-digest trained)))
      (unless (equal dataset-sha256 base-dataset-sha256)
        (error "teacher-forcing dataset digest mismatch: %s != %s"
               dataset-sha256 base-dataset-sha256))
      (unless (equal trained-sha256 (plist-get base-report :trained-sha256))
        (error "teacher-forcing trained model digest mismatch: %s != %s"
               trained-sha256 (plist-get base-report :trained-sha256)))
      ;; Export only after the interception scope has restored the original
      ;; function.  This detached model is used for native byte-code scoring.
      (let* ((inference (funcall original trained "file-teacher-forcing"))
             (before-score
              (nl-agent-supervised-file-experiment--model-digest trained))
             (scores (nl-agent-file-teacher-forcing--score-records
                      inference records))
             (after-score
              (nl-agent-supervised-file-experiment--model-digest trained)))
        (unless (equal before-score trained-sha256)
          (error "teacher-forcing model changed before scoring: %s != %s"
                 before-score trained-sha256))
        (unless (equal before-score after-score)
          (error "teacher-forcing scoring mutated the trained model"))
        (list :format nl-agent-file-teacher-forcing-format
              :diagnostic diagnostic
              :dataset-sha256 dataset-sha256
              :trained-sha256 trained-sha256
              :model-unchanged-after-scoring t
              :teacher-forcing
              (list :records scores
                    :examples (length scores)
                    :capability-metric nil))))))

(when (and noninteractive nl-agent-file-teacher-forcing-auto-run)
  (let ((print-length nil)
        (print-level nil)
        (print-circle nil)
        (print-escape-nonascii t))
    (prin1 (nl-agent-file-teacher-forcing-run))
    (terpri)))

(provide 'diagnose-file-teacher-forcing)

;;; diagnose-file-teacher-forcing.el ends here
