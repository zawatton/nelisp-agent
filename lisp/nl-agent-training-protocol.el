;;; nl-agent-training-protocol.el --- isolated training wire format -*- lexical-binding: t; -*-

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'photon-tensor)
(require 'photon-autograd)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-training-checkpoint)
(require 'nl-llm-agent-tokenizer)
(require 'nl-llm-agent-completion-plan)
(require 'nl-agent-task-promotion)
(defvar read-eval)

(declare-function nl-llm-agent-supervised-evolve--payload
                  "nl-llm-agent-supervised-evolve"
                  (payload tokenizer backend sequence optimizer))

(defconst nl-agent-training-protocol-format "nl-agent-training-request-v1")
(defconst nl-agent-training-result-format "nl-agent-training-result-v1")
(defconst nl-agent-training-checkpoint-format
  "nl-agent-training-progress-v1"
  "Format tag for a background-training progress envelope.")
(defconst nl-agent-training-protocol-max-bytes (* 256 1024 1024))
(defconst nl-agent-training-protocol-max-parameters 1000000)
(defconst nl-agent-training-protocol--request-keys
  '(:format :kind :attempt :job-id :parent-generation :parent-score :scope :payload
    :parent-model :training :benchmark :resume-state :task-promotion))
(defconst nl-agent-training-protocol--request-required-keys
  '(:format :attempt :job-id :parent-generation :parent-score :scope :payload
    :parent-model :training :benchmark))
(defconst nl-agent-training-protocol--result-keys
  '(:format :attempt :request-sha256 :score :model :task-promotion))
(defconst nl-agent-training-protocol--result-required-keys
  '(:format :attempt :request-sha256 :score :model))
(defconst nl-agent-training-protocol--checkpoint-keys
  '(:format :attempt :request-sha256 :state))
(defconst nl-agent-training-protocol--resume-state-keys
  '(:format :job-id :payload-digest :scope :parent-generation
    :parent-score :sequence :optimizer :completed-steps :total-steps
    :optimizer-step :model :optimizer-state :request-binding))
(defconst nl-agent-training-protocol--completion-resume-state-keys
  (append nl-agent-training-protocol--resume-state-keys '(:completion-plan)))

(defun nl-agent-training-protocol--kind (value where)
  "Return normalized proposal kind VALUE, or signal for unsupported input."
  (let ((kind
         (cond
          ((equal value "trajectory-finetune") 'trajectory-finetune)
          ((equal value "supervised-finetune") 'supervised-finetune))))
    (unless kind
      (error "%s must be trajectory-finetune or supervised-finetune" where))
    kind))

(defun nl-agent-training-protocol--keys (x allowed where &optional required)
  (unless (and (listp x) (zerop (% (length x) 2))) (error "%s must be a plist" where))
  (let ((p x) (seen nil))
    (while p (let ((key (pop p)))
                (when (memq key seen) (error "%s contains duplicate key %S" where key))
                (push key seen)
                (unless (memq key allowed) (error "%s contains unknown key %S" where key)))
          (pop p))
    (dolist (key required)
      (unless (memq key seen) (error "%s is missing required key %S" where key)))
    x))

(defun nl-agent-training-protocol--finite (x where)
  (unless (and (numberp x) (= x x) (< (abs (float x)) 1.0e300)) (error "%s must be finite" where)) x)
(defun nl-agent-training-protocol--id (x where)
  (unless (and (stringp x) (<= 1 (length x) 128) (string-match-p "\\`[A-Za-z0-9_.-]+\\'" x)) (error "%s has invalid identifier" where)) x)
(defun nl-agent-training-protocol--model-config (model)
  "Return the normalized architecture tuple for MODEL."
  (let ((config (plist-get model :config)))
    (list (plist-get config :dim) (plist-get config :ff)
          (plist-get config :vocab) (plist-get config :nblocks)
          (plist-get config :heads)
          (or (plist-get config :kv-heads) (plist-get config :kvh))
          (nl-llm-agent-tokenizer-id (plist-get config :tokenizer)))))

(defun nl-agent-training-protocol--validate-model (model where)
  "Validate finite bounded P5 MHA checkpoint MODEL for WHERE."
  (nl-llm-agent-artifact--checkpoint-model model where)
  (unless (plist-get model :wh) (error "%s requires independent wh" where))
  (let* ((architecture (nl-agent-training-protocol--model-config model))
         (heads (nth 4 architecture))
         (kv-heads (nth 5 architecture))
         (count 0))
    (unless (= heads kv-heads) (error "%s requires MHA" where))
    (dolist (tensor (nl-agent-training-protocol--model-tensors model))
      (dolist (number (append (photon-tensor-data tensor) nil))
        (nl-agent-training-protocol--finite number
                                            (format "%s tensor value" where)))
      (setq count (+ count (length (photon-tensor-data tensor)))))
    (when (> count nl-agent-training-protocol-max-parameters)
      (error "%s parameter budget exceeded" where)))
  model)

;;;###autoload
(defun nl-agent-training-protocol-completion-plan (request)
  "Return the detached canonical completion plan bound to GPU REQUEST.

This pure helper validates the supervised request's kind, tokenizer/vocabulary,
training bindings, and payload without recursively calling
`nl-agent-training-protocol-validate-request' or allocating a GPU.  Full parent
model weight validation remains the responsibility of request validation."
  (unless (and (plist-member request :kind)
               (equal (plist-get request :kind) "supervised-finetune"))
    (error "completion plan requires supervised-finetune request kind"))
  (let* ((model (plist-get request :parent-model))
         (config (plist-get model :config))
         (tokenizer (nl-llm-agent-tokenizer-id
                     (plist-get config :tokenizer)))
         (vocab (plist-get config :vocab))
         (training (plist-get request :training))
         (payload (plist-get request :payload))
         (backend-value (plist-get training :backend))
         (optimizer-value (plist-get training :optimizer))
         (backend (if (stringp backend-value)
                      (intern backend-value) backend-value))
         (optimizer (if (stringp optimizer-value)
                        (intern optimizer-value) optimizer-value))
         (sequence (plist-get training :sequence))
         (lr (if (plist-member payload :lr)
                 (plist-get payload :lr) 0.05))
         (epochs (if (plist-member payload :epochs)
                     (plist-get payload :epochs) 1)))
    (nl-agent-training-protocol--keys
     training '(:backend :sequence :optimizer :checkpoint-every)
     "completion training" '(:backend :sequence :optimizer))
    (nl-agent-training-protocol--keys
     payload '(:examples :lr :epochs) "completion payload" '(:examples))
    (unless (eq backend 'gpu)
      (error "completion plan helper requires GPU training"))
    (unless (and (integerp sequence) (<= 2 sequence) (<= sequence 4096))
      (error "invalid completion training sequence"))
    (unless (memq optimizer '(sgd adam))
      (error "invalid completion training optimizer"))
    (unless (and (integerp vocab)
                 (= vocab (nl-llm-agent-tokenizer-vocab tokenizer)))
      (error "completion request tokenizer and vocabulary differ"))
    (require 'nl-llm-agent-supervised-evolve)
    (let ((encoded
           (nl-llm-agent-supervised-evolve--payload
            payload tokenizer backend sequence optimizer)))
      (nl-llm-agent-completion-plan-make
       (plist-get encoded :trajectories)
       (plist-get encoded :loss-starts)
       :tokenizer tokenizer :sequence sequence :learning-rate lr
       :epochs epochs :optimizer optimizer
       :transfer-mode nil :loss-masks nil :shuffle-seed nil))))

(defun nl-agent-training-protocol-validate-request (value)
  "Validate and return a training request data plist."
  (nl-agent-training-protocol--keys value nl-agent-training-protocol--request-keys
                                    "training request"
                                    nl-agent-training-protocol--request-required-keys)
  (unless (equal (plist-get value :format) nl-agent-training-protocol-format)
    (error "unsupported training request format"))
  (let* ((kind (if (plist-member value :kind)
                   (nl-agent-training-protocol--kind
                    (plist-get value :kind) "training request :kind")
                 'trajectory-finetune))
         (payload (plist-get value :payload))
         (model (plist-get value :parent-model))
         (_validated
          (nl-agent-training-protocol--validate-model
           model "training request parent"))
         (tokenizer
          (nl-llm-agent-tokenizer-id
           (plist-get (plist-get model :config) :tokenizer)))
         (training (plist-get value :training))
         (backend-value (plist-get training :backend))
         (optimizer-value (plist-get training :optimizer))
         (backend (if (stringp backend-value)
                      (intern backend-value)
                    backend-value))
         (optimizer (if (stringp optimizer-value)
                        (intern optimizer-value)
                      optimizer-value)))
    (nl-agent-training-protocol--id (plist-get value :attempt) "attempt")
    (nl-agent-training-protocol--id (plist-get value :job-id) "job-id")
    (let ((generation (plist-get value :parent-generation)))
      (unless (and (integerp generation) (>= generation 0))
        (error "invalid parent-generation")))
    (nl-agent-training-protocol--finite
     (plist-get value :parent-score) "parent-score")
    (let ((scope (plist-get value :scope)))
      (unless (and (stringp scope)
                   (string-match-p "\\`[a-f0-9]\\{64\\}\\'" scope))
        (error "scope must be SHA-256")))
    (when (> (string-bytes (prin1-to-string payload))
             nl-agent-training-protocol-max-bytes)
      (error "payload too large"))
    (nl-agent-training-protocol--keys
     payload '(:examples :lr :epochs) "training payload" '(:examples))
    (nl-agent-training-protocol--keys
     training '(:backend :sequence :optimizer :checkpoint-every)
     "training" '(:backend :sequence :optimizer))
    (unless (memq backend '(cpu gpu))
      (error "invalid training backend"))
    (unless (and (integerp (plist-get training :sequence))
                 (<= 2 (plist-get training :sequence) 4096))
      (error "invalid training sequence"))
    (unless (memq optimizer '(sgd adam))
      (error "invalid optimizer"))
    (when (and (eq backend 'cpu) (eq optimizer 'adam))
      (error "CPU backend does not support Adam"))
    (when (plist-member training :checkpoint-every)
      (let ((interval (plist-get training :checkpoint-every)))
        (unless (and (integerp interval) (<= 1 interval 1000000))
          (error "training checkpoint interval must be in [1, 1000000]"))
        (unless (eq backend 'gpu)
          (error "training checkpoints require the GPU backend"))))
    (if (eq kind 'supervised-finetune)
        (progn
          (require 'nl-llm-agent-supervised-evolve)
          (nl-llm-agent-supervised-evolve--payload
           payload tokenizer backend (plist-get training :sequence) optimizer)
          ;; A durable supervised checkpoint carries the canonical plan.  The
          ;; helper is GPU-only; ordinary CPU supervised requests remain the
          ;; historical ephemeral path.
          (when (or (plist-member training :checkpoint-every)
                    (plist-member value :resume-state))
            (nl-agent-training-protocol-completion-plan value)))
      (if (eq backend 'gpu)
          (nl-llm-agent-evolve--validate-gpu-finetune
           payload (plist-get training :sequence) tokenizer)
        (nl-llm-agent-evolve--validate-finetune payload tokenizer)))
    (when (plist-member value :task-promotion)
      (nl-agent-task-promotion-policy
       (plist-get value :task-promotion)))
    (nl-llm-agent-evolve--validate-finetune
     (list :examples (plist-get value :benchmark) :lr 0.05 :epochs 1)
     tokenizer)
    (when (plist-member value :resume-state)
      (unless (plist-get value :resume-state)
        (error "training request resume state must not be nil"))
      (unless (and (eq backend 'gpu)
                   (plist-member training :checkpoint-every)
                   (integerp (plist-get training :checkpoint-every))
                   (> (plist-get training :checkpoint-every) 0))
        (error "resume state requires GPU training and checkpoint interval"))
      (nl-agent-training-protocol-validate-resume-state
       (plist-get value :resume-state) value)))
  value)

(defun nl-agent-training-protocol--model-tensors (m)
  (append (list (plist-get m :wte) (plist-get m :wh))
          (apply #'append (mapcar (lambda (b) (mapcar (lambda (k) (plist-get b k))
                                                       '(:ln1g :wq :bq :wk :bk :wv :bv :wo :bo :ln2g :wg :bg :wu :bu :wd :bd))) (plist-get m :blocks)))
          (list (plist-get m :lnfg) (plist-get m :bh))))

(defun nl-agent-training-protocol--binding-model (model)
  "Return MODEL's stable semantic form for request binding.
Explicit legacy ASCII is omitted so pre-tokenizer requests retain their exact
historical binding.  Non-legacy tokenizer identity remains explicit."
  (let* ((result (copy-tree model t))
         (config (copy-tree (plist-get result :config)))
         (tokenizer
          (nl-llm-agent-tokenizer-id (plist-get config :tokenizer)))
         (tail config)
         normalized)
    (while tail
      (let ((key (pop tail)) (item (pop tail)))
        (unless (eq key :tokenizer)
          (setq normalized (append normalized (list key item))))))
    (unless (equal tokenizer nl-llm-agent-tokenizer-ascii)
      (setq normalized (append normalized (list :tokenizer tokenizer))))
    (plist-put result :config normalized)))

;;;###autoload
(defun nl-agent-training-protocol-request-binding (request)
  "Return a stable digest of REQUEST semantics which resume must preserve.
The attempt, resume state, and checkpoint cadence are deliberately excluded.
Backend and optimizer spellings are normalized before hashing."
  (let* ((training (plist-get request :training))
         (kind (and (plist-member request :kind)
                     (nl-agent-training-protocol--kind
                      (plist-get request :kind) "training request :kind")))
         (backend (if (stringp (plist-get training :backend))
                      (intern (plist-get training :backend))
                    (plist-get training :backend)))
         (optimizer (if (stringp (plist-get training :optimizer))
                        (intern (plist-get training :optimizer))
                      (plist-get training :optimizer)))
         (semantics
          (list :job-id (plist-get request :job-id)
                :payload (plist-get request :payload)
                :scope (plist-get request :scope)
                :parent-generation (plist-get request :parent-generation)
                :parent-score (plist-get request :parent-score)
                :parent-model
                (nl-agent-training-protocol--binding-model
                 (plist-get request :parent-model))
                :training
                (list :backend backend
                      :sequence (plist-get training :sequence)
                      :optimizer optimizer)
                :benchmark (plist-get request :benchmark)))
         (print-length nil)
         (print-level nil)
         (print-circle nil)
         (print-escape-nonascii t)
         (float-output-format nil))
    (when (eq kind 'supervised-finetune)
      (setq semantics (append semantics (list :kind kind))))
    (when (plist-member request :task-promotion)
      (setq semantics
            (append semantics
                    (list :task-promotion
                          (nl-agent-task-promotion-policy
                           (plist-get request :task-promotion))))))
    (secure-hash 'sha256 (prin1-to-string semantics))))

(defun nl-agent-training-protocol--without-key (plist omitted)
  "Return a detached copy of PLIST without OMITTED."
  (let ((tail plist) result)
    (while tail
      (let ((key (pop tail)) (value (pop tail)))
        (unless (eq key omitted)
          (setq result (append result (list key (copy-tree value t)))))))
    result))

(defun nl-agent-training-protocol--strict-tensor-p (tensor shape)
  "Return non-nil when TENSOR has exact SHAPE, data length, and finite values."
  (condition-case nil
      (let ((size 1))
        (dolist (dimension shape)
          (unless (and (integerp dimension) (> dimension 0))
            (error "invalid tensor shape"))
          (setq size (* size dimension)))
        (and (vectorp tensor) (= (length tensor) 2)
             (equal (photon-tensor-shape tensor) shape)
             (vectorp (photon-tensor-data tensor))
             (= (length (photon-tensor-data tensor)) size)
             (cl-every
              (lambda (number)
                (and (numberp number) (= number number)
                     (< (abs (float number)) 1.0e300)))
              (append (photon-tensor-data tensor) nil))))
    (error nil)))

(defun nl-agent-training-protocol--validate-optimizer-state
    (state optimizer model)
  "Validate strict optimizer tensor layout in STATE for OPTIMIZER and MODEL."
  (if (eq optimizer 'sgd)
      (when state
        (error "SGD resume state cannot contain optimizer tensors"))
    (let ((parameters
           (reverse
            (nl-llm-agent-training-checkpoint--model-parameters model))))
      (unless (and (listp state) (= (length state) (length parameters)))
        (error "Adam resume state has the wrong parameter count"))
      (cl-mapc
       (lambda (pair parameter)
         (let ((shape (photon-tensor-shape parameter)))
           (unless (and (consp pair)
                        (nl-agent-training-protocol--strict-tensor-p
                         (car pair) shape)
                        (nl-agent-training-protocol--strict-tensor-p
                         (cdr pair) shape))
             (error "Adam resume state has incompatible optimizer tensors"))))
       state parameters)))
  state)

;;;###autoload
(defun nl-agent-training-protocol-validate-resume-state (state request)
  "Validate enriched checkpoint STATE against REQUEST and return a plain copy.
The returned detached plist has :request-binding removed and is accepted by the
existing `nl-llm-agent-training-checkpoint' APIs.  This helper has no prior
attempt or request hash; those belong to the enclosing progress envelope."
  (let* ((supervisedp
          (and (plist-member request :kind)
               (equal (plist-get request :kind) "supervised-finetune")))
         (state-keys
          (if supervisedp
              nl-agent-training-protocol--completion-resume-state-keys
            nl-agent-training-protocol--resume-state-keys))
         (expected-format
          (if supervisedp
              nl-llm-agent-training-checkpoint-completion-format
            nl-llm-agent-training-checkpoint-format)))
    (nl-agent-training-protocol--keys
     state state-keys "training resume state" state-keys)
    ;; Reuse the checkpoint's structural checks, then strengthen its duplicate,
    ;; missing-key, bounded-model, and exact optimizer data-length guarantees.
    (let* ((plain
            (nl-agent-training-protocol--without-key state :request-binding))
           (training (plist-get request :training))
           (payload (plist-get request :payload))
           (backend (if (stringp (plist-get training :backend))
                        (intern (plist-get training :backend))
                      (plist-get training :backend)))
           (optimizer (if (stringp (plist-get training :optimizer))
                          (intern (plist-get training :optimizer))
                        (plist-get training :optimizer)))
           (completion-plan
            (when supervisedp
              (nl-agent-training-protocol-completion-plan request)))
           (examples (plist-get payload :examples))
           (epochs (or (plist-get payload :epochs) 1))
           (expected-total
            (if completion-plan
                (* (plist-get completion-plan :epochs)
                   (length (plist-get completion-plan :trajectories)))
              (* epochs (length examples))))
           (model (plist-get plain :model)))
      (unless (equal (plist-get state :format) expected-format)
        (error "resume state has the wrong checkpoint format"))
      (nl-llm-agent-training-checkpoint--validate plain)
      (unless (eq backend 'gpu)
        (error "resume state requires GPU training"))
      (unless (and (plist-member training :checkpoint-every)
                   (integerp (plist-get training :checkpoint-every))
                   (<= 1 (plist-get training :checkpoint-every) 1000000))
        (error "resume state requires a positive checkpoint interval"))
      (unless (and
               (equal (plist-get state :job-id) (plist-get request :job-id))
               (equal (plist-get state :payload-digest)
                      (if supervisedp
                          (nl-llm-agent-training-checkpoint--completion-payload-digest
                           payload)
                        (nl-llm-agent-training-checkpoint-payload-digest
                         payload)))
               (equal (plist-get state :scope) (plist-get request :scope))
               (= (plist-get state :parent-generation)
                  (plist-get request :parent-generation))
               (= (plist-get state :parent-score)
                  (plist-get request :parent-score))
               (= (plist-get state :sequence) (plist-get training :sequence))
               (eq (plist-get state :optimizer) optimizer)
               (= (plist-get state :total-steps) expected-total))
        (error "resume state does not match this training request"))
      (unless (equal (plist-get state :request-binding)
                     (nl-agent-training-protocol-request-binding request))
        (error "resume state request binding mismatch"))
      (when supervisedp
        (unless (equal (plist-get state :completion-plan) completion-plan)
          (error "resume completion plan does not match this request")))
      (nl-agent-training-protocol--validate-model model "training resume model")
      (unless (equal (nl-agent-training-protocol--model-config model)
                     (nl-agent-training-protocol--model-config
                      (plist-get request :parent-model)))
        (error "resume model architecture differs from request parent"))
      (unless (and (integerp (plist-get model :step))
                   (= (plist-get model :step)
                      (plist-get plain :completed-steps))
                   (= (plist-get model :step)
                      (plist-get plain :optimizer-step)))
        (error "resume model step differs from training progress"))
      (nl-agent-training-protocol--validate-optimizer-state
       (plist-get plain :optimizer-state) optimizer model)
      plain)))

;;;###autoload
(defun nl-agent-training-protocol-validate-checkpoint
    (value request request-sha256)
  "Validate progress envelope VALUE for REQUEST and REQUEST-SHA256.
The envelope has exactly :format, :attempt, :request-sha256, and :state."
  (nl-agent-training-protocol--keys
   value nl-agent-training-protocol--checkpoint-keys
   "training progress checkpoint" nl-agent-training-protocol--checkpoint-keys)
  (unless (equal (plist-get value :format)
                 nl-agent-training-checkpoint-format)
    (error "unsupported training progress checkpoint format"))
  (unless (equal (plist-get value :attempt) (plist-get request :attempt))
    (error "training progress checkpoint attempt mismatch"))
  (unless (and (stringp request-sha256)
               (string-match-p "\\`[a-f0-9]\\{64\\}\\'" request-sha256)
               (equal (plist-get value :request-sha256) request-sha256))
    (error "training progress checkpoint request hash mismatch"))
  (nl-agent-training-protocol-validate-resume-state
   (plist-get value :state) request)
  (let ((print-length nil) (print-level nil) (print-circle nil)
        (float-output-format nil))
    (when (> (string-bytes (prin1-to-string value))
             nl-agent-training-protocol-max-bytes)
      (error "training progress checkpoint exceeds protocol size limit")))
  value)

(defun nl-agent-training-protocol-validate-result (value request)
  "Validate result VALUE against REQUEST."
  (nl-agent-training-protocol--keys value nl-agent-training-protocol--result-keys
                                    "training result"
                                    nl-agent-training-protocol--result-required-keys)
  (unless (equal (plist-get value :format) nl-agent-training-result-format) (error "unsupported training result format"))
  (unless (equal (plist-get value :attempt) (plist-get request :attempt)) (error "result attempt mismatch"))
  (unless (string-match-p "\\`[a-f0-9]\\{64\\}\\'" (or (plist-get value :request-sha256) "")) (error "invalid request hash"))
  (nl-agent-training-protocol--finite (plist-get value :score) "score")
  (let ((model (plist-get value :model)))
    (nl-agent-training-protocol--validate-model model "training result")
    (unless (equal (nl-agent-training-protocol--model-config
                    (plist-get request :parent-model))
                   (nl-agent-training-protocol--model-config model))
      (error "result model architecture mismatch")))
  (let ((request-policy-present (plist-member request :task-promotion))
        (result-policy-present (plist-member value :task-promotion)))
    (cond
     ((and request-policy-present result-policy-present)
      (nl-agent-task-promotion-validate-evidence
       (plist-get value :task-promotion)
       (plist-get request :parent-model)
       (plist-get value :model)
       (plist-get request :task-promotion)))
     (request-policy-present
      (error "training result is missing task promotion evidence"))
     (result-policy-present
      (error "training result has unsolicited task promotion evidence"))))
  value)

(defun nl-agent-training-protocol-read (file)
  "Read one data-only bounded S-expression from FILE."
  (unless (and (file-regular-p file) (<= (file-attribute-size (file-attributes file)) nl-agent-training-protocol-max-bytes)) (error "protocol file missing or too large"))
  (with-temp-buffer
    (let ((read-eval nil) (coding-system-for-read 'utf-8)) (insert-file-contents file) (goto-char (point-min))
          (let* ((value (read (current-buffer))) (trailing (buffer-substring-no-properties (point) (point-max))))
            (unless (string-match-p "\\`[[:space:]]*\\'" trailing) (error "protocol has trailing forms")) value))))

(defun nl-agent-training-protocol-write (file value)
  "Atomically write VALUE as private full-precision text to FILE."
  (let* ((dir (file-name-directory (expand-file-name file))) (tmp nil)
         (print-length nil) (print-level nil) (print-circle nil) (print-escape-nonascii t)
         (float-output-format nil)
         (text (prin1-to-string value)))
    (when (> (string-bytes text) nl-agent-training-protocol-max-bytes)
      (error "protocol value exceeds %d bytes"
             nl-agent-training-protocol-max-bytes))
    (make-directory dir t)
    (setq tmp (make-temp-file (expand-file-name ".nl-agent-training-" dir)))
    (unwind-protect (progn (let ((coding-system-for-write 'utf-8)) (write-region text nil tmp nil 'silent))
                            (set-file-modes tmp #o600) (rename-file tmp file t) file)
      (when (file-exists-p tmp) (delete-file tmp)))))

(defun nl-agent-training-protocol-hash (file)
  "Return SHA-256 of raw FILE bytes."
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (secure-hash 'sha256 (current-buffer))))

(defun nl-agent-training-protocol-import (model-checkpoint)
  "Validate checkpoint and convert all tensors to detached PAV leaves."
  (nl-agent-training-protocol--validate-model model-checkpoint "training import")
  (let* ((copy #'nl-llm-agent-artifact--trainable-parameter)
         (config (copy-tree (plist-get model-checkpoint :config)))
         (tokenizer
          (nl-llm-agent-tokenizer-id (plist-get config :tokenizer))))
    (setq config (plist-put config :tokenizer tokenizer))
    (list :config config
          :wte (funcall copy (plist-get model-checkpoint :wte)) :wh (funcall copy (plist-get model-checkpoint :wh))
          :lnfg (funcall copy (plist-get model-checkpoint :lnfg)) :bh (funcall copy (plist-get model-checkpoint :bh))
          :blocks (mapcar (lambda (b) (let (out) (dolist (k '(:ln1g :wq :bq :wk :bk :wv :bv :wo :bo :ln2g :wg :bg :wu :bu :wd :bd)) (setq out (append out (list k (funcall copy (plist-get b k)))))) out)) (plist-get model-checkpoint :blocks))
          :dim (plist-get (plist-get model-checkpoint :config) :dim) :ff (plist-get (plist-get model-checkpoint :config) :ff)
          :vocab (plist-get (plist-get model-checkpoint :config) :vocab) :heads (plist-get (plist-get model-checkpoint :config) :heads)
          :kv-heads (or (plist-get (plist-get model-checkpoint :config) :kv-heads) (plist-get (plist-get model-checkpoint :config) :kvh))
          :nblocks (plist-get (plist-get model-checkpoint :config) :nblocks)
          :tokenizer tokenizer
          :step (or (plist-get model-checkpoint :step) 0))))

(provide 'nl-agent-training-protocol)
