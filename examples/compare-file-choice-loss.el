;;; compare-file-choice-loss.el --- compare completion and grammar-choice loss -*- lexical-binding: t; -*-

;; This wrapper keeps the frozen teacher-forcing diagnostic as the complete
;; experiment.  It changes only the loss mask passed to its one on-device
;; training call when MODE is `grammar-choice'.

;;; Code:

(require 'cl-lib)

(defconst nl-agent-file-choice-loss-source-sha256
  "7b7ffda31315b48d02871652970554490b6db04a44b4e5096ad427d96f03638d"
  "SHA-256 of the frozen teacher-forcing diagnostic source.")

(defconst nl-agent-file-choice-loss-format
  "nl-agent-file-choice-loss-v1")

(defvar nl-agent-file-choice-loss-auto-run nil
  "When non-nil, loading this example noninteractively runs the comparison.")

;; Declare every source guard before loading the frozen file.  The bindings are
;; intentionally scoped to this load so callers' autorun variables survive.
(defvar nl-agent-file-teacher-forcing-auto-run nil)
(defvar nl-agent-initialized-file-diagnostic-auto-run nil)
(defvar nl-agent-supervised-file-diagnostic-auto-run nil)

(defun nl-agent-file-choice-loss--file-sha256 (path)
  "Return byte SHA-256 digest of PATH without text decoding."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (secure-hash 'sha256 (current-buffer))))

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (source (expand-file-name "diagnose-file-teacher-forcing.el" here)))
  (unless (equal (nl-agent-file-choice-loss--file-sha256 source)
                 nl-agent-file-choice-loss-source-sha256)
    (error "frozen teacher-forcing source SHA mismatch: %s"
           (nl-agent-file-choice-loss--file-sha256 source)))
  (let ((nl-agent-file-teacher-forcing-auto-run nil)
        (nl-agent-initialized-file-diagnostic-auto-run nil)
        (nl-agent-supervised-file-diagnostic-auto-run nil))
    (load source nil nil t)))

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-llm-agent-action-grammar)
(require 'nl-llm-agent-ondevice)
(require 'nl-llm-agent-supervised)

(declare-function nl-agent-file-teacher-forcing-run
                  "diagnose-file-teacher-forcing" ())
(declare-function nl-llm-agent-tokenizer-decode
                  "nl-llm-agent-tokenizer" (ids &optional identifier))
(declare-function nl-llm-agent-ondevice-train
                  "nl-llm-agent-ondevice" (ctx trajs epochs &rest keys))

(defun nl-agent-file-choice-loss--completion-string (trajectory loss-start)
  "Return ASCII UTF-8 gold suffix from TRAJECTORY at LOSS-START."
  (unless (and (or (listp trajectory) (vectorp trajectory))
               (integerp loss-start) (<= 1 loss-start)
               (< loss-start (length trajectory)))
    (error "invalid trajectory/loss-start pair: %S %S"
           trajectory loss-start))
  (let ((ids nil))
    (dotimes (index (- (length trajectory) loss-start))
      (let ((id (if (vectorp trajectory)
                    (aref trajectory (+ loss-start index))
                  (nth (+ loss-start index) trajectory))))
        (unless (and (integerp id) (<= 0 id) (<= id 127))
          (error "gold completion is not fixed ASCII byte data: %S" id))
        ;; UTF8-byte-v1 uses the ASCII byte ID itself.  Do not subtract the
        ;; legacy tokenizer's historical offset here.
        (push id ids)))
    (apply #'string (nreverse ids))))

(defun nl-agent-file-choice-loss--grammar-state (grammar prefix)
  "Return and validate GRAMMAR state at gold PREFIX."
  (let ((state (funcall grammar prefix)))
    (unless (or (eq state :stop)
                (and (listp state)
                     (memq (car state) '(:force :allow))))
      (error "grammar returned invalid state %S" state))
    state))

(defun nl-agent-file-choice-loss--masks (trajectories loss-starts grammar)
  "Build per-trajectory 0/1 masks from actual TRAJECTORIES and LOSS-STARTS.

Return a plist containing ordinary vectors under `:masks' and counts under
`:selected-targets' and `:completion-targets'.  A mask index is the target
token index in the original trajectory; prompt targets and forced targets are
zero, while `:allow' targets are one."
  (unless (and (vectorp loss-starts)
               (= (length loss-starts) (length trajectories)))
    (error "loss-starts must align with actual trajectories"))
  (let ((masks nil)
        (selected 0)
        (completion-targets 0)
        (example 0))
    (dolist (trajectory trajectories)
      (unless (or (listp trajectory) (vectorp trajectory))
        (error "trajectory %d is not a token sequence" example))
      (let* ((length (length trajectory))
             (loss-start (aref loss-starts example))
             (completion
              (nl-agent-file-choice-loss--completion-string
               trajectory loss-start))
             (mask (make-vector length 0))
             (prefix "")
             (choices 0))
        (unless (and (>= length 2) (< loss-start length))
          (error "trajectory %d has invalid completion boundary" example))
        (setq completion-targets (+ completion-targets (- length loss-start)))
        ;; The grammar sees only the gold completion prefix, exactly as the
        ;; frozen teacher-forcing scorer does.
        (dotimes (offset (length completion))
          (let* ((target-index (+ loss-start offset))
                 (gold (aref completion offset))
                 (state (nl-agent-file-choice-loss--grammar-state
                         grammar prefix)))
            (cond
             ((eq state :stop)
              (error "grammar stopped before completion end for example %d"
                     example))
             ((eq (car state) :force)
              (unless (and (integerp (cadr state))
                           (= (cadr state) gold))
                (error "grammar force disagrees with gold for example %d"
                       example)))
             ((eq (car state) :allow)
              (let ((allowed (cadr state)))
                (unless (stringp allowed)
                  (error "grammar allow set is not a string for example %d"
                         example))
                (dolist (id (string-to-list allowed))
                  (unless (and (integerp id) (<= 0 id) (<= id 127))
                    (error "grammar allow set is not ASCII for example %d"
                           example)))
                (unless (memq gold (string-to-list allowed))
                  (error "gold byte is outside grammar allow set for example %d"
                         example))
                (aset mask target-index 1)
                (setq selected (1+ selected)
                      choices (1+ choices))))
             (t
              (error "invalid grammar state %S" state)))
            (setq prefix (concat prefix (string gold)))))
        (unless (eq (nl-agent-file-choice-loss--grammar-state grammar prefix)
                    :stop)
          (error "grammar did not stop exactly at completion end for example %d"
                 example))
        (when (= choices 0)
          (error "example %d has no grammar-choice target" example))
        (push mask masks))
      (setq example (1+ example)))
    (list :masks (vconcat (nreverse masks))
          :selected-targets selected
          :completion-targets completion-targets)))

(defun nl-agent-file-choice-loss--completion-masks (trajectories loss-starts)
  "Return ordinary all-completion-target masks for actual training inputs."
  (unless (and (vectorp loss-starts)
               (= (length loss-starts) (length trajectories)))
    (error "loss-starts must align with actual trajectories"))
  (let ((masks nil)
        (targets 0)
        (index 0))
    (dolist (trajectory trajectories)
      (let* ((length (length trajectory))
             (start (aref loss-starts index)))
        (unless (and (integerp start) (<= 1 start) (< start length))
          (error "trajectory %d has invalid completion boundary" index))
        (let ((mask (make-vector length 0)))
          (dotimes (offset (- length start))
            (aset mask (+ start offset) 1))
          (push mask masks)
          (setq targets (+ targets (- length start)))))
      (setq index (1+ index)))
    (list :masks (vconcat (nreverse masks))
          :selected-targets targets
          :completion-targets targets)))

(defun nl-agent-file-choice-loss--mask-digest (masks)
  "Return a stable SHA-256 digest of ordinary vector MASKS."
  (let ((print-length nil) (print-level nil) (print-circle nil))
    (secure-hash 'sha256 (prin1-to-string masks))))

(defun nl-agent-file-choice-loss--mode (mode)
  "Validate and return comparison MODE."
  (unless (memq mode '(completion grammar-choice))
    (error "file choice loss mode must be `completion' or `grammar-choice': %S"
           mode))
  mode)

;;;###autoload
(defun nl-agent-file-choice-loss-run (mode)
  "Run frozen teacher forcing with completion or grammar-choice loss.

MODE is explicitly `completion' or `grammar-choice'.
Both modes execute `nl-agent-file-teacher-forcing-run' unchanged.  The one
underlying training call is observed only to derive counts from its actual
trajectories and loss starts; grammar-choice appends the generated
`:loss-masks' keyword while preserving every existing argument object."
  (setq mode (nl-agent-file-choice-loss--mode mode))
  (let* ((trainer 'nl-llm-agent-ondevice-train)
         (original (symbol-function trainer))
         (training-call-count 0)
         (mask-info nil)
         (masks nil)
         (diagnostic nil))
    (cl-letf (((symbol-function trainer)
               (lambda (ctx trajectories epochs &rest args)
                 (setq training-call-count (1+ training-call-count))
                 (when (> training-call-count 1)
                   (error "file choice loss observed %d training calls"
                          training-call-count))
                 (when (plist-member args :loss-masks)
                   (error "frozen training call already supplied :loss-masks"))
                 (let* ((loss-starts (plist-get args :loss-starts))
                        (grammar (nl-llm-agent-grammar-file-actions 64))
                        (info
                         (nl-agent-file-choice-loss--masks
                          trajectories loss-starts grammar)))
                   (let ((completion-info
                          (nl-agent-file-choice-loss--completion-masks
                           trajectories loss-starts)))
                     (setq mask-info (list :choice info
                                           :completion completion-info)
                           masks (plist-get
                                  (if (eq mode 'grammar-choice)
                                      info completion-info)
                                  :masks)))
                   (if (eq mode 'grammar-choice)
                       (apply original ctx trajectories epochs
                              (append args (list :loss-masks masks)))
                     (apply original ctx trajectories epochs args))))))
      (setq diagnostic (nl-agent-file-teacher-forcing-run)))
    (unless (= training-call-count 1)
      (error "expected exactly one frozen training call, got %d"
             training-call-count))
    (unless mask-info
      (error "frozen training call did not expose trajectories"))
    (let* ((selected-info (plist-get mask-info
                                     (if (eq mode 'grammar-choice)
                                         :choice :completion)))
           (selected (plist-get selected-info :selected-targets))
           (completion-targets
            (plist-get selected-info :completion-targets))
           (digest (nl-agent-file-choice-loss--mask-digest masks)))
      (list :format nl-agent-file-choice-loss-format
            :mode mode
            :source-sha256 nl-agent-file-choice-loss-source-sha256
            :training-call-count training-call-count
            :mask-digest digest
            :selected-targets selected
            :completion-targets completion-targets
            ;; The complete frozen report remains available once, under
            ;; :diagnostic; this outer marker identifies the selected loss.
            :loss-selection mode
            :diagnostic diagnostic))))

(when (and noninteractive nl-agent-file-choice-loss-auto-run)
  (let ((print-length nil)
        (print-level nil)
        (print-circle nil)
        (print-escape-nonascii t))
    (prin1 (nl-agent-file-choice-loss-run 'completion))
    (terpri)))

(provide 'compare-file-choice-loss)
;;; compare-file-choice-loss.el ends here
