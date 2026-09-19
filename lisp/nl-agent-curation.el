;;; nl-agent-curation.el --- host-owned trajectory curation -*- lexical-binding: t; -*-

;; A curator can approve an immutable, unverified trajectory for a bounded
;; fine-tune proposal.  It cannot choose paths, replace examples, or turn the
;; model's `done' claim into an evaluation result.

;;; Code:

(require 'cl-lib)
(require 'nl-agent-trajectory)
(require 'nl-llm-agent-model)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-supervised)
(require 'nl-llm-agent-tokenizer)

(defconst nl-agent-curation-renderer-version "nl-agent-curation-role-v1"
  "Version of the task-local role transcript renderer.")

(defconst nl-agent-curation-supervised-format
  "nl-agent-curation-supervised-v1"
  "Format tag for completion-only supervised curation data.")

(defconst nl-agent-curation-max-policy-id-length 256)
(defconst nl-agent-curation-max-reason-length 1024)

(cl-defstruct (nl-agent-curation
               (:constructor nl-agent-curation--make))
  directory evaluator policy-id holdout-digests lr epochs tokenizer)

(defun nl-agent-curation--keys (value allowed required where)
  "Validate bounded plist VALUE keys for WHERE."
  (let ((tail value) seen (pairs 0))
    (while tail
      (when (>= pairs (length allowed))
        (error "%s contains too many fields" where))
      (unless (and (consp tail) (consp (cdr tail)))
        (error "%s must contain key/value pairs" where))
      (let ((key (car tail)))
        (unless (memq key allowed)
          (error "%s has unknown key %S" where key))
        (when (memq key seen)
          (error "%s has duplicate key %S" where key))
        (setq seen (cons key seen)
              tail (cddr tail)
              pairs (1+ pairs))))
    (dolist (key required)
      (unless (memq key seen)
        (error "%s is missing key %S" where key))))
  value)

(defun nl-agent-curation--digest (value where)
  "Validate and detach SHA-256 VALUE for WHERE."
  (unless (and (stringp value)
               (string-match-p "\\`[a-f0-9]\\{64\\}\\'" value))
    (error "%s must be a lowercase SHA-256 digest" where))
  (substring-no-properties value))

(defun nl-agent-curation--holdouts (value)
  "Validate and detach exact holdout digest list VALUE."
  (unless (nl-agent-trajectory--proper-list-p value)
    (error "curation holdout digests must be a finite proper list"))
  (let (seen result)
    (dolist (value value)
      (let ((digest (nl-agent-curation--digest value "curation holdout")))
        (when (member digest seen)
          (error "duplicate curation holdout digest"))
        (setq seen (cons digest seen)
              result (cons digest result))))
    (nreverse result)))

(defun nl-agent-curation--directory (directory)
  "Validate trusted trajectory DIRECTORY and return its absolute name."
  (unless (and (stringp directory) (> (length directory) 0))
    (error "curation directory must be non-empty text"))
  (let* ((path (expand-file-name directory))
         (name (directory-file-name path)))
    (when (file-symlink-p name)
      (error "curation directory must not be a symlink"))
    (unless (file-directory-p name)
      (error "curation directory must be an existing real directory"))
    (file-name-as-directory path)))

;;;###autoload
(defun nl-agent-curation-new (directory evaluator policy-id &rest keys)
  "Create a host-owned trajectory curator.

EVALUATOR is trusted host code receiving one detached validated record and
returning exact `(:accepted BOOL :reason STRING)' data.  KEYS requires explicit
`:data-use-approved t' and accepts `:holdout-digests', `:lr', `:epochs', and a
trusted model `:tokenizer'.  The tokenizer defaults to legacy ASCII."
  (nl-agent-curation--keys
   keys '(:data-use-approved :holdout-digests :lr :epochs :tokenizer)
   '(:data-use-approved) "nl-agent-curation-new options")
  (unless (eq (plist-get keys :data-use-approved) t)
    (error "curation requires explicit :data-use-approved t"))
  (unless (functionp evaluator)
    (error "curation evaluator must be trusted host code"))
  (unless (and (stringp policy-id) (> (length policy-id) 0)
               (<= (length policy-id)
                   nl-agent-curation-max-policy-id-length))
    (error "curation policy id must be non-empty bounded text"))
  (let ((lr (if (plist-member keys :lr) (plist-get keys :lr) 0.05))
        (epochs (if (plist-member keys :epochs) (plist-get keys :epochs) 1)))
    (unless (and (numberp lr) (= (- lr lr) 0.0)
                 (> lr 0.0) (<= lr 1.0))
      (error "curation :lr must be finite and in (0, 1]"))
    (unless (and (integerp epochs) (<= 1 epochs) (<= epochs 32))
      (error "curation :epochs must be in [1, 32]"))
    (nl-agent-curation--make
     :directory (nl-agent-curation--directory directory)
     :evaluator evaluator
     :policy-id (substring-no-properties policy-id)
     :holdout-digests
     (nl-agent-curation--holdouts (plist-get keys :holdout-digests))
     :lr lr :epochs epochs
     :tokenizer
     (nl-llm-agent-tokenizer-id (plist-get keys :tokenizer)))))

(defun nl-agent-curation--record-path (context record-id)
  "Resolve exact immutable RECORD-ID within CONTEXT's directory."
  (unless (and
           (stringp record-id)
           (string-match-p
            "\\`run-[0-9]\\{8\\}T[0-9]\\{6\\}-[a-f0-9]\\{24\\}\\.sexp\\'"
            record-id)
           (equal record-id (file-name-nondirectory record-id)))
    (error "curation record id must be an exact run filename"))
  (expand-file-name record-id (nl-agent-curation-directory context)))

(defun nl-agent-curation--decision (context record)
  "Evaluate an independent copy of RECORD and return a valid decision."
  (let ((decision
         (funcall
          (nl-agent-curation-evaluator context)
          (nl-agent-trajectory--validate-record record))))
    (nl-agent-curation--keys
     decision '(:accepted :reason) '(:accepted :reason)
     "curation evaluator result")
    (unless (memq (plist-get decision :accepted) '(t nil))
      (error "curation evaluator :accepted must be t or nil"))
    (unless (and (stringp (plist-get decision :reason))
                 (> (length (plist-get decision :reason)) 0)
                 (<= (length (plist-get decision :reason))
                     nl-agent-curation-max-reason-length))
      (error "curation evaluator reason must be non-empty bounded text"))
    (list :accepted (plist-get decision :accepted)
          :reason (substring-no-properties (plist-get decision :reason)))))

(defun nl-agent-curation--supervised-examples (record)
  "Render prompt/completion pairs from validated RECORD."
  (let* ((events (plist-get record :trajectory))
         (past
          (list
           (cons 'user (concat "TASK: " (plist-get record :task)))))
         (total 0)
         examples)
    (when (> (length events) nl-llm-agent-evolve-max-examples)
      (error "curation trajectory exceeds %d assistant events"
             nl-llm-agent-evolve-max-examples))
    (while events
      (let* ((event (car events))
             (assistant (plist-get event :assistant))
             (prompt-length
              (+ (length "\nassistant:\n")
                 (max 0 (1- (length past)))
                 (apply
                  #'+
                  (mapcar
                   (lambda (message)
                     (+ (length (symbol-name (car message))) 2
                        (length (cdr message))))
                   past))))
             (example-length (+ prompt-length (length assistant))))
        (when (> example-length nl-llm-agent-evolve-max-example-length)
          (error "curation rendered example exceeds %d characters"
                 nl-llm-agent-evolve-max-example-length))
        (setq total (+ total example-length))
        (when (> total nl-llm-agent-evolve-max-total-characters)
          (error "curation rendered examples exceed %d total characters"
                 nl-llm-agent-evolve-max-total-characters))
        (let ((example
               (list :prompt (nl-llm-agent--render past)
                     :completion (substring-no-properties assistant))))
          (setq examples (cons example examples)
                past (append past (list (cons 'assistant assistant))))
          (when (cdr events)
            (unless (plist-member event :observation)
              (error
               "curation requires an observation between assistant events"))
            (setq past
                  (append
                   past
                   (list
                    (cons 'user
                          (nl-llm-agent--truncate
                           (plist-get event :observation) 4000))))))
          (setq events (cdr events)))))
    (vconcat (nreverse examples))))

(defun nl-agent-curation--examples (record)
  "Render legacy concatenated examples from validated RECORD.

The prompt/completion renderer is shared with the completion-only API; this
function deliberately preserves the historical concatenated bytes."
  (vconcat
   (mapcar (lambda (example)
             (concat (plist-get example :prompt)
                     (plist-get example :completion)))
           (append (nl-agent-curation--supervised-examples record) nil))))

(defun nl-agent-curation--prepare (context record-id supervised)
  "Prepare legacy or supervised data from one immutable RECORD-ID snapshot."
  (unless (nl-agent-curation-p context)
    (error "nl-agent-curation-prepare: invalid context"))
  ;; The trusted configured path may have been replaced since construction.
  (nl-agent-curation--directory (nl-agent-curation-directory context))
  (let* ((snapshot
          (nl-agent-trajectory-read-snapshot
           (nl-agent-curation--record-path context record-id)))
         (record (plist-get snapshot :record))
         (digest
          (nl-agent-curation--digest
           (plist-get snapshot :sha256) "trajectory snapshot")))
    (unless (eq (plist-get record :status) 'done)
      (error "only model-claimed done trajectories can be curated"))
    (unless (consp (plist-get record :trajectory))
      (error "empty trajectories cannot be curated"))
    (when (member digest (nl-agent-curation-holdout-digests context))
      (error "trajectory is in the exact-hash holdout set"))
    (let* ((examples
            (if supervised
                (nl-agent-curation--supervised-examples record)
              (nl-agent-curation--examples record)))
           (payload
            (list :examples examples
                  :lr (nl-agent-curation-lr context)
                  :epochs (nl-agent-curation-epochs context)))
           ;; Complete supervised validation and encoding before trusted
           ;; evaluator code receives its independent record copy.
           (encoding
            (when supervised
              (nl-llm-agent-supervised-encode
               examples (nl-agent-curation-tokenizer context)))))
      ;; Reject unsupported characters or oversize examples; never truncate
      ;; task/assistant text merely to make a proposal fit.
      (unless supervised
        (nl-llm-agent-evolve--validate-finetune
         payload (nl-agent-curation-tokenizer context)))
      (let* ((decision (nl-agent-curation--decision context record))
             (accepted (plist-get decision :accepted)))
        (unless accepted
          (error "curation evaluator denied trajectory: %s"
                 (plist-get decision :reason)))
        (let ((metadata
               (list :source-sha256 digest
                     :policy-id
                     (substring-no-properties
                      (nl-agent-curation-policy-id context))
                     :evidence decision
                     :renderer-version
                     (substring-no-properties
                      nl-agent-curation-renderer-version)
                     :tokenizer
                     (nl-agent-curation-tokenizer context))))
          (if supervised
              (list :format nl-agent-curation-supervised-format
                    :examples (copy-tree examples t)
                    :lr (plist-get payload :lr)
                    :epochs (plist-get payload :epochs)
                    :metadata (copy-tree metadata t)
                    :encoding (copy-tree encoding t))
            (list :payload (copy-tree payload t)
                  :metadata (copy-tree metadata t))))))))

;;;###autoload
(defun nl-agent-curation-prepare (context record-id)
  "Prepare a bounded full-sequence fine-tune proposal from RECORD-ID.

The original record remains unverified.  Holdout matching is exact file-hash
matching only and does not claim semantic leakage prevention.  Examples use
the trainer's ordinary full-sequence language-model loss, not assistant masks."
  (nl-agent-curation--prepare context record-id nil))

;;;###autoload
(defun nl-agent-curation-prepare-supervised (context record-id)
  "Prepare completion-only supervised data from immutable RECORD-ID.

This preparation-only API does not train, enqueue, or publish.  It returns
  explicit prompt/completion pairs and detached encoded trajectories without a
  legacy `:payload' key."
  (nl-agent-curation--prepare context record-id t))

;;;###autoload
(defun nl-agent-curation-submit-supervised
    (context queue record-id &optional id)
  "Submit supervised curation for RECORD-ID as a pending QUEUE job.

CONTEXT supplies the host-owned data-use approval and evaluator.  QUEUE must
already have its trusted `supervised-finetune' handler registered, and its
champion tokenizer must match CONTEXT's tokenizer.  This host-side helper
only prepares and submits a pending proposal; it never claims, trains, or
publishes a job.  Optional ID is passed unchanged to the queue's normal id
validation."
  (unless (nl-agent-curation-p context)
    (error "nl-agent-curation-submit-supervised: invalid context"))
  (nl-agent-curation--directory (nl-agent-curation-directory context))
  (unless (nl-llm-evolve-queue-p queue)
    (error "nl-agent-curation-submit-supervised: invalid queue"))
  (unless
      (cl-find-if
       (lambda (entry)
         (equal (plist-get entry :kind) "supervised-finetune"))
       (nl-llm-evolve-queue-catalog queue))
    (error "supervised-finetune queue handler is not registered"))
  (let* ((champion
          (nl-llm-evolution-champion
           (nl-llm-evolve-queue-evolution queue)))
         (queue-tokenizer
          (nl-llm-agent-evolve--model-tokenizer
           champion "supervised queue champion"))
         (curator-tokenizer (nl-agent-curation-tokenizer context)))
    (unless (equal queue-tokenizer curator-tokenizer)
      (error "curator tokenizer %s differs from queue tokenizer %s"
             curator-tokenizer queue-tokenizer))
    (let* ((prepared
            (nl-agent-curation-prepare-supervised context record-id))
           (pairs (plist-get prepared :examples))
           (payload
            (list :examples (copy-tree pairs t)
                  :lr (plist-get prepared :lr)
                  :epochs (plist-get prepared :epochs)))
           (metadata
            (append (copy-tree (plist-get prepared :metadata) t)
                    (list :dataset-sha256
                          (copy-sequence
                           (plist-get (plist-get prepared :encoding)
                                      :dataset-sha256))))))
      (nl-llm-evolve-queue-submit
       queue "supervised-finetune" payload :id id :metadata metadata))))

(provide 'nl-agent-curation)
;;; nl-agent-curation.el ends here
