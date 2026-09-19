;;; nl-agent-task-promotion.el --- guarded native task promotion -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'nl-agent-task-eval)
(require 'nl-agent-task-eval-service)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-model)
(require 'nl-llm-agent-provider)

(declare-function nl-llm-agent-artifact--grammar
                  "nl-llm-agent-artifact" (spec))
(declare-function nl-llm-agent-artifact--checkpoint-model
                  "nl-llm-agent-artifact" (checkpoint id))
(declare-function nl-agent-task-eval--suite
                  "nl-agent-task-eval" (suite))
(declare-function nl-agent-task-eval--digest
                  "nl-agent-task-eval" (suite max-steps runner-id))
(declare-function nl-agent-task-eval--validate-report
                  "nl-agent-task-eval" (report))
(declare-function nl-agent-task-eval--oracle-shape
                  "nl-agent-task-eval" (cases))
(declare-function nl-agent-task-eval--utf8
                  "nl-agent-task-eval" (text))
(declare-function nl-llm-agent-artifact--trainable-parameter
                  "nl-llm-agent-artifact" (tensor))

(defconst nl-agent-task-promotion-max-sequence 4096)
(defconst nl-agent-task-promotion-max-steps 64)
(defconst nl-agent-task-promotion--policy-keys
  '(:suite :grammar :max-sequence :max-steps))
(defconst nl-agent-task-promotion--evidence-keys
  '(:accepted :grammar :max-sequence :max-steps
    :before-model-sha256 :after-model-sha256 :before :after :comparison))

(defun nl-agent-task-promotion--plist-keys (value allowed required where)
  "Validate exact plist keys VALUE and return VALUE."
  (unless (and (listp value) (zerop (% (length value) 2)))
    (error "%s must be a plist" where))
  (let ((tail value) seen)
    (while tail
      (let ((key (pop tail)))
        (when (memq key seen)
          (error "%s contains duplicate key %S" where key))
        (push key seen)
        (unless (memq key allowed)
          (error "%s contains unknown key %S" where key)))
      (pop tail))
    (dolist (key required)
      (unless (memq key seen)
        (error "%s is missing required key %S" where key))))
  value)

(defun nl-agent-task-promotion--copy-grammar (spec)
  "Return a detached canonical copy of validated grammar SPEC.

Only fields with grammar semantics are copied.  This avoids traversing
unvalidated extension data while ensuring every string and template container
retained by the promotion gate is independent of its caller."
  (let ((type (substring-no-properties (plist-get spec :type))))
    (cond
     ((member type '("done" "message"))
      (append (list :type type :length (plist-get spec :length))
              (when (plist-get spec :allow)
                (list :allow
                      (substring-no-properties (plist-get spec :allow))))))
     ((equal type "template")
      (list :type type
            :segments
            (vconcat
             (mapcar
              (lambda (segment)
                (if (stringp segment)
                    (substring-no-properties segment)
                  (list :slot
                        (substring-no-properties
                         (plist-get segment :slot)))))
              (append (plist-get spec :segments) nil)))))
     ((equal type "file-actions-v1")
      (append (list :type type :max-field (plist-get spec :max-field))
              (when (plist-member spec :allow)
                (list :allow
                      (substring-no-properties (plist-get spec :allow))))))
     (t (error "unsupported normalized promotion grammar %S" type)))))

(defun nl-agent-task-promotion--bounds (max-sequence max-steps)
  "Validate and return MAX-SEQUENCE and MAX-STEPS."
  (unless (and (integerp max-sequence)
               (<= 1 max-sequence nl-agent-task-promotion-max-sequence))
    (error "task promotion max-sequence must be in 1..%d"
           nl-agent-task-promotion-max-sequence))
  (unless (and (integerp max-steps)
               (<= 1 max-steps nl-agent-task-promotion-max-steps))
    (error "task promotion max-steps must be in 1..%d"
           nl-agent-task-promotion-max-steps))
  (list max-sequence max-steps))

;;;###autoload
(defun nl-agent-task-promotion-policy (policy)
  "Validate POLICY and return its detached canonical form.

POLICY contains only the immutable task-evaluation suite, grammar, sequence
bound, and evaluation step bound.  This function performs no model or file
I/O, so callers can validate it before creating a worker attempt."
  (nl-agent-task-promotion--plist-keys
   policy nl-agent-task-promotion--policy-keys
   nl-agent-task-promotion--policy-keys "task promotion policy")
  (let* ((suite (nl-agent-task-eval--suite (plist-get policy :suite)))
         (grammar
          (nl-llm-agent-artifact-normalize-grammar
           (plist-get policy :grammar) "task promotion policy grammar"))
         (bounds
          (nl-agent-task-promotion--bounds
           (plist-get policy :max-sequence)
           (plist-get policy :max-steps))))
    (list :suite (copy-tree suite t)
          :grammar (nl-agent-task-promotion--copy-grammar grammar)
          :max-sequence (car bounds)
          :max-steps (cadr bounds))))

(defun nl-agent-task-promotion--model-checkpoint (model id)
  "Export trainable PAV MODEL as a detached validated checkpoint."
  (unless (and (listp model)
               (plist-get model :wte)
               (plist-get model :blocks)
               (plist-get model :lnfg)
               (plist-get model :bh))
    (error "task promotion %s model is not a trainable PAV model" id))
  (nl-llm-agent-artifact-export-pav model))

(defun nl-agent-task-promotion--checkpoint-digest (checkpoint)
  "Return a stable full-precision weight digest of CHECKPOINT.

The training step is metadata, not model identity, and is normalized to zero
before hashing."
  (let ((canonical (copy-tree checkpoint t))
        (print-length nil)
        (print-level nil)
        (print-circle nil)
        (print-escape-nonascii t)
        (float-output-format "%.17g"))
    (plist-put canonical :step 0)
    (secure-hash 'sha256 (prin1-to-string canonical))))

(defun nl-agent-task-promotion--checkpoint-pav (checkpoint id)
  "Convert validated CHECKPOINT to detached trainable PAV leaves.

This local artifact-equivalent import keeps promotion independent from the
training protocol at load time."
  (nl-llm-agent-artifact--checkpoint-model checkpoint id)
  (let* ((config (copy-tree (plist-get checkpoint :config) t))
         (copy #'nl-llm-agent-artifact--trainable-parameter)
         (block-keys
          '(:ln1g :wq :bq :wk :bk :wv :bv :wo :bo
            :ln2g :wg :bg :wu :bu :wd :bd)))
    (list :config config
          :wte (funcall copy (plist-get checkpoint :wte))
          :wh (when (plist-get checkpoint :wh)
                (funcall copy (plist-get checkpoint :wh)))
          :lnfg (funcall copy (plist-get checkpoint :lnfg))
          :bh (funcall copy (plist-get checkpoint :bh))
          :blocks
          (mapcar
           (lambda (block)
             (let (result)
               (dolist (key block-keys)
                 (setq result
                       (append result
                               (list key (funcall copy (plist-get block key))))))
               result))
           (plist-get checkpoint :blocks))
          :dim (plist-get config :dim)
          :ff (plist-get config :ff)
          :vocab (plist-get config :vocab)
          :heads (plist-get config :heads)
          :kv-heads (or (plist-get config :kv-heads)
                        (plist-get config :kvh))
          :nblocks (plist-get config :nblocks)
          :tokenizer (plist-get config :tokenizer)
          :step 0)))

(defun nl-agent-task-promotion--weight-digest (checkpoint id)
  "Return the canonical round-trip weight digest for CHECKPOINT."
  (nl-agent-task-promotion--checkpoint-digest
   (nl-llm-agent-artifact-export-pav
    (nl-agent-task-promotion--checkpoint-pav checkpoint id)
    0)))

(defun nl-agent-task-promotion--suite-oracle-shape (suite)
  "Return SUITE's ordered case/path/expected-hash shape."
  (let (result)
    (dolist (case (append (plist-get suite :cases) nil))
      (let (files)
        (dolist (file (append (plist-get case :expected) nil))
          (push
           (list (plist-get file :path)
                 (secure-hash 'sha256
                              (nl-agent-task-eval--utf8
                               (plist-get file :text))))
           files))
        (push (list (plist-get case :id) (nreverse files)) result)))
    (nreverse result)))

(defun nl-agent-task-promotion--native-registry
    (before after grammar max-sequence)
  "Build a private native registry for BEFORE and AFTER checkpoints."
  (let ((registry (nl-llm-agent-provider-registry-new)))
    (nl-llm-agent-provider-register
     registry
     (nl-llm-agent-model-provider
      "native"
      (list (list :id "before" :model before :grammar grammar
                  :maxseq max-sequence)
            (list :id "after" :model after :grammar grammar
                  :maxseq max-sequence))))
    registry))

(defun nl-agent-task-promotion--no-regressions-p (before after)
  "Return non-nil when every passing BEFORE case passes in AFTER."
  (let ((after-cases (plist-get after :cases))
        (result t))
    (dolist (before-case (append (plist-get before :cases) nil))
      (when (plist-get before-case :pass)
        (let ((after-case
               (cl-find-if
                (lambda (candidate)
                  (equal (plist-get candidate :id)
                         (plist-get before-case :id)))
                (append after-cases nil))))
          (unless (and after-case (plist-get after-case :pass))
            (setq result nil)))))
    result))

(defun nl-agent-task-promotion--infrastructure-failure-p (report)
  "Return non-nil when REPORT contains a host plumbing failure."
  (cl-some
   (lambda (case)
     (cl-some (lambda (failure)
                (memq failure '(callback-error workspace-error invalid-response)))
              (append (plist-get case :failure-codes) nil)))
   (append (plist-get report :cases) nil)))

(defun nl-agent-task-promotion--report
    (report suite model-id max-steps)
  "Validate REPORT and bind it to SUITE, MODEL-ID, and MAX-STEPS."
  (let ((canonical (nl-agent-task-eval--validate-report report))
        (expected-digest
         (nl-agent-task-eval--digest
          suite max-steps nl-agent-task-eval-service-runner-id)))
    (unless (and (equal (plist-get canonical :suite-id)
                        (plist-get suite :id))
                 (equal (plist-get canonical :suite-version)
                        (plist-get suite :version))
                 (= (plist-get canonical :max-steps) max-steps)
                 (equal (plist-get canonical :model-id) model-id)
                 (equal (plist-get canonical :runner-id)
                        nl-agent-task-eval-service-runner-id)
                 (equal (plist-get canonical :suite-sha256) expected-digest)
                 (equal (nl-agent-task-eval--oracle-shape
                         (plist-get canonical :cases))
                        (nl-agent-task-promotion--suite-oracle-shape
                         suite)))
      (error "task promotion report binding mismatch"))
    canonical))

;;;###autoload
(defun nl-agent-task-promotion-validate-evidence
    (evidence before-checkpoint after-checkpoint policy)
  "Validate detached task-promotion EVIDENCE against POLICY and checkpoints.

The claimed acceptance bit and comparison are treated as untrusted wire data:
reports, oracle hashes, no-regression semantics, and round-trip weight hashes
are all recomputed before a canonical evidence plist is returned."
  (let* ((canonical-policy (nl-agent-task-promotion-policy policy))
         (suite (plist-get canonical-policy :suite))
         (grammar (plist-get canonical-policy :grammar))
         (max-sequence (plist-get canonical-policy :max-sequence))
         (max-steps (plist-get canonical-policy :max-steps)))
    (nl-agent-task-promotion--plist-keys
     evidence nl-agent-task-promotion--evidence-keys
     nl-agent-task-promotion--evidence-keys "task promotion evidence")
    (unless (memq (plist-get evidence :accepted) '(t nil))
      (error "task promotion evidence :accepted must be boolean"))
    (unless (and (equal (plist-get evidence :grammar) grammar)
                 (= (plist-get evidence :max-sequence) max-sequence)
                 (= (plist-get evidence :max-steps) max-steps))
      (error "task promotion evidence policy mismatch"))
    (let* ((before
            (nl-agent-task-promotion--report
             (plist-get evidence :before) suite "native/before" max-steps))
           (after
            (nl-agent-task-promotion--report
             (plist-get evidence :after) suite "native/after" max-steps))
           (comparison (nl-agent-task-eval-compare before after))
           (accepted
            (and (> (plist-get comparison :passed-delta) 0)
                 (nl-agent-task-promotion--no-regressions-p before after)))
           (before-hash
            (nl-agent-task-promotion--weight-digest
             before-checkpoint "promotion evidence before"))
           (after-hash
            (nl-agent-task-promotion--weight-digest
             after-checkpoint "promotion evidence after")))
      (when (or (nl-agent-task-promotion--infrastructure-failure-p before)
                (nl-agent-task-promotion--infrastructure-failure-p after))
        (error "task promotion evidence has infrastructure failures"))
      (unless (equal (plist-get evidence :comparison) comparison)
        (error "task promotion evidence comparison mismatch"))
      (unless (eq (plist-get evidence :accepted) (and accepted t))
        (error "task promotion evidence acceptance mismatch"))
      (unless (and (equal (plist-get evidence :before-model-sha256)
                         before-hash)
                   (equal (plist-get evidence :after-model-sha256)
                          after-hash))
        (error "task promotion evidence model hash mismatch"))
      (list :accepted (and accepted t)
            :grammar (copy-tree grammar t)
            :max-sequence max-sequence
            :max-steps max-steps
            :before-model-sha256 before-hash
            :after-model-sha256 after-hash
            :before (copy-tree before t)
            :after (copy-tree after t)
            :comparison (copy-tree comparison t)))))

;;;###autoload
(cl-defun nl-agent-task-promotion-evaluate
    (before after suite grammar &key (max-sequence 4096) (max-steps 3))
  "Evaluate BEFORE and AFTER native PAV models on host-owned SUITE.

Both models are exported into private inference descriptors and evaluated by
the confined native task service.  No catalog, filesystem artifact, or remote
provider is published.  Acceptance requires a positive passed-case delta and
no regression of any case that passed before training.  A failed native
evaluation is evidence of failure, never evidence of ability."
  (let* ((bounds (nl-agent-task-promotion--bounds max-sequence max-steps))
         ;; Complete validation and detachment precede model export, registry
         ;; construction, workspace creation, and service invocation.
         (canonical-suite (nl-agent-task-eval--suite suite))
         (grammar-spec
          (nl-llm-agent-artifact-normalize-grammar
           grammar "task promotion grammar"))
         (grammar-function (nl-llm-agent-artifact--grammar grammar-spec))
         (before-checkpoint
          (nl-agent-task-promotion--model-checkpoint before "before"))
         (after-checkpoint
          (nl-agent-task-promotion--model-checkpoint after "after"))
         (before-model
          (nl-llm-agent-artifact--checkpoint-model
           (append (list :format nl-llm-ckpt-format) before-checkpoint)
           "task-promotion-before"))
         (after-model
          (nl-llm-agent-artifact--checkpoint-model
           (append (list :format nl-llm-ckpt-format) after-checkpoint)
           "task-promotion-after"))
         (registry
          (nl-agent-task-promotion--native-registry
           before-model after-model grammar-function (car bounds)))
         (before-raw
          (nl-agent-task-eval-service-run
           canonical-suite registry "native/before"
           :max-steps (cadr bounds)))
         (after-raw
          (nl-agent-task-eval-service-run
           canonical-suite registry "native/after"
           :max-steps (cadr bounds)))
         (before-report
          (nl-agent-task-promotion--report
           before-raw canonical-suite "native/before" (cadr bounds)))
         (after-report
          (nl-agent-task-promotion--report
           after-raw canonical-suite "native/after" (cadr bounds)))
         (_infra-check
          (when (or (nl-agent-task-promotion--infrastructure-failure-p
                     before-report)
                    (nl-agent-task-promotion--infrastructure-failure-p
                     after-report))
            (error "task promotion evaluation has infrastructure failures")))
         (comparison (nl-agent-task-eval-compare before-report after-report))
         (accepted
          (and (> (plist-get comparison :passed-delta) 0)
               (nl-agent-task-promotion--no-regressions-p
                before-report after-report))))
    (list :accepted (and accepted t)
          :grammar (nl-agent-task-promotion--copy-grammar grammar-spec)
          :max-sequence (car bounds)
          :max-steps (cadr bounds)
          :before-model-sha256
          (nl-agent-task-promotion--checkpoint-digest before-checkpoint)
          :after-model-sha256
          (nl-agent-task-promotion--checkpoint-digest after-checkpoint)
          :before (copy-tree before-report t)
          :after (copy-tree after-report t)
          :comparison (copy-tree comparison t))))

;;;###autoload
(cl-defun nl-agent-task-promotion-gate
    (suite grammar &key (max-sequence 4096) (max-steps 3))
  "Return an immutable native task promotion gate for SUITE and GRAMMAR."
  (let* ((bounds (nl-agent-task-promotion--bounds max-sequence max-steps))
         (canonical-suite (nl-agent-task-eval--suite suite))
         (grammar-spec
          (nl-llm-agent-artifact-normalize-grammar
           grammar "task promotion grammar"))
         (frozen-suite (copy-tree canonical-suite t))
         (frozen-grammar
          (nl-agent-task-promotion--copy-grammar grammar-spec))
         (sequence (car bounds))
         (steps (cadr bounds)))
    (lambda (before after)
      (plist-get
       (nl-agent-task-promotion-evaluate
        before after frozen-suite frozen-grammar
        :max-sequence sequence :max-steps steps)
       :accepted))))

(provide 'nl-agent-task-promotion)
;;; nl-agent-task-promotion.el ends here
