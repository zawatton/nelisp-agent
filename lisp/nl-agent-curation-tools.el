;;; nl-agent-curation-tools.el --- guarded trajectory curation tool -*- lexical-binding: t; -*-

;; Curation selects an immutable host record under a fixed host policy.  The
;; model may name only that record; it cannot supply paths, evaluators, training
;; settings, or provenance.  Accepted examples become an inert pending queue
;; job and require a separate permissioned run operation to train.

;;; Code:

(require 'cl-lib)
(require 'nl-agent-tool)
(require 'nl-agent-curation)
(require 'nl-llm-evolve-queue)
(require 'nl-llm-agent-tokenizer)

(defconst nl-agent-curation-tool-schema
  '(:type "object"
    :properties (:record-id (:type "string" :minLength 1))
    :required ["record-id"]
    :additionalProperties nil)
  "Input schema for submitting one host-curated trajectory record.")

(defun nl-agent-curation-tools--args (args)
  "Validate exact tool ARGS and return its record id."
  (unless (and (listp args)
               (= (length args) 2)
               (eq (car args) :record-id)
               (stringp (cadr args))
               (> (length (cadr args)) 0))
    (error "improvement curation requires only non-empty :record-id"))
  (cadr args))

(defun nl-agent-curation-tools--prepared (value)
  "Validate prepared curation VALUE and return payload and metadata."
  (unless (and (listp value)
               (= (length value) 4)
               (plist-member value :payload)
               (plist-member value :metadata))
    (error "curation preparation returned invalid data"))
  (let* ((payload (plist-get value :payload))
         (metadata (plist-get value :metadata))
         (source (and (listp metadata)
                      (plist-get metadata :source-sha256)))
         (policy (and (listp metadata)
                      (plist-get metadata :policy-id))))
    (unless (and (stringp source)
                 (string-match-p "\\`[a-f0-9]\\{64\\}\\'" source))
      (error "curation metadata requires source SHA-256"))
    (unless (and (stringp policy) (> (length policy) 0))
      (error "curation metadata requires policy id"))
    (list payload metadata source policy)))

(defun nl-agent-curation-tools--kind (&optional kind)
  "Return canonical proposal KIND, defaulting to legacy trajectory curation."
  (unless (or (null kind) (stringp kind))
    (error "curation proposal kind must be text"))
  (cond
   ((null kind) "trajectory-finetune")
   ((member kind '("trajectory-finetune" "supervised-finetune")) kind)
   (t (error "unsupported curation proposal kind: %s" kind))))

(defun nl-agent-curation-tools--handler-p (queue kind)
  "Return non-nil when QUEUE exposes trusted handler KIND."
  (cl-find-if (lambda (entry) (equal (plist-get entry :kind) kind))
              (nl-llm-evolve-queue-catalog queue)))

(defun nl-agent-curation-tools--prepared-supervised (value)
  "Validate supervised VALUE and return pairs, metadata, source, and policy."
  (unless (and (listp value)
               (plist-member value :examples)
               (plist-member value :lr)
               (plist-member value :epochs)
               (plist-member value :metadata)
               (plist-member value :encoding))
    (error "supervised curation preparation returned invalid data"))
  (let* ((metadata (plist-get value :metadata))
         (encoding (plist-get value :encoding))
         (source (and (listp metadata)
                      (plist-get metadata :source-sha256)))
         (policy (and (listp metadata)
                      (plist-get metadata :policy-id)))
         (digest (and (listp encoding)
                      (plist-get encoding :dataset-sha256))))
    (unless (and (vectorp (plist-get value :examples))
                 (> (length (plist-get value :examples)) 0))
      (error "supervised curation requires prompt/completion pairs"))
    (unless (and (stringp source)
                 (string-match-p "\\`[a-f0-9]\\{64\\}\\'" source))
      (error "curation metadata requires source SHA-256"))
    (unless (and (stringp policy) (> (length policy) 0))
      (error "curation metadata requires policy id"))
    (unless (and (stringp digest)
                 (string-match-p "\\`[a-f0-9]\\{64\\}\\'" digest))
      (error "supervised encoding requires dataset SHA-256"))
    (list (plist-get value :examples)
          (list :examples (copy-tree (plist-get value :examples) t)
                :lr (plist-get value :lr)
                :epochs (plist-get value :epochs))
          (append (copy-tree metadata t)
                  (list :dataset-sha256 (copy-sequence digest)))
          source policy)))

(defun nl-agent-curation-tools--submission-id
    (source-sha256 policy-id payload &optional kind)
  "Return the deterministic retained-queue id for curated inputs."
  (let ((print-length nil)
        (print-level nil)
        (print-circle nil)
        (print-escape-nonascii t)
        (float-output-format nil))
    (concat
     "curated-"
     (secure-hash
      'sha256
      (prin1-to-string
       (append (list :source-sha256 source-sha256
                     :policy-id policy-id
                     :payload payload)
               (when kind (list :kind kind))))))))

(defun nl-agent-curation-tools--check-tokenizer (queue curator)
  "Require QUEUE and CURATOR to use the same canonical tokenizer."
  (let* ((model
          (nl-llm-evolution-champion
           (nl-llm-evolve-queue-evolution queue)))
         (queue-tokenizer
          (nl-llm-agent-tokenizer-id (plist-get model :tokenizer)))
         (curator-tokenizer (nl-agent-curation-tokenizer curator)))
    (unless (equal queue-tokenizer curator-tokenizer)
      (error "curator tokenizer %s differs from queue tokenizer %s"
             curator-tokenizer queue-tokenizer))
    queue-tokenizer))

(defun nl-agent-curation-tools--snapshot-job (queue id)
  "Return retained private snapshot job ID from QUEUE, or nil."
  (cl-find-if
   (lambda (job) (equal (plist-get job :id) id))
   (append (plist-get (nl-llm-evolve-queue-snapshot queue) :jobs) nil)))

(defun nl-agent-curation-tools--public-job (queue id)
  "Return retained public job ID from QUEUE, or signal."
  (or
   (cl-find-if
    (lambda (job) (equal (plist-get job :id) id))
    (plist-get (nl-llm-evolve-queue-status queue) :jobs))
   (error "curated queue job disappeared: %s" id)))

(defun nl-agent-curation-tools--submit
    (queue payload metadata id &optional kind)
  "Submit curated data or return the exactly matching retained job."
  (let ((kind (or kind "trajectory-finetune"))
        (existing (nl-agent-curation-tools--snapshot-job queue id)))
    (if existing
        (if (and (equal (plist-get existing :kind) kind)
                 (equal (plist-get existing :payload) payload)
                 (equal (plist-get existing :metadata) metadata))
            (nl-agent-curation-tools--public-job queue id)
          (error "curated submission id conflicts with retained queue job: %s"
                 id))
      (nl-llm-evolve-queue-submit
       queue kind payload :id id :metadata metadata))))

;;;###autoload
(defun nl-agent-curation-register-tools (registry queue curator &optional kind)
  "Register optional CURATOR submission tooling for QUEUE in REGISTRY.

The registered write-risk tool only prepares and submits pending data.  It
never runs training, invokes the queue evaluator, or publishes a model.
Optional KIND selects `trajectory-finetune' (the default) or
`supervised-finetune'; the model-facing tool input remains record-id only."
  (unless (nl-agent-tool-registry-p registry)
    (error "nl-agent-curation-register-tools: invalid tool registry"))
  (unless (nl-llm-evolve-queue-p queue)
    (error "nl-agent-curation-register-tools: invalid improvement queue"))
  (unless (nl-agent-curation-p curator)
    (error "nl-agent-curation-register-tools: invalid curator"))
  (setq kind (nl-agent-curation-tools--kind kind))
  (nl-agent-curation-tools--check-tokenizer queue curator)
  (when (and (equal kind "supervised-finetune")
             (not (nl-agent-curation-tools--handler-p queue kind)))
    (error "supervised-finetune queue handler is not registered"))
  (nl-agent-tool-register
   registry
   (nl-agent-tool-new
    "model.improvement.curate"
    (lambda (args _context)
      (nl-agent-curation-tools--check-tokenizer queue curator)
      (when (and (equal kind "supervised-finetune")
                 (not (nl-agent-curation-tools--handler-p queue kind)))
        (error "supervised-finetune queue handler is not registered"))
      (let ((record-id (nl-agent-curation-tools--args args)))
        (if (equal kind "supervised-finetune")
            (let* ((prepared
                    (nl-agent-curation-tools--prepared-supervised
                     (nl-agent-curation-prepare-supervised
                      curator record-id)))
                   (payload (nth 1 prepared))
                   (metadata (nth 2 prepared))
                   (id
                    (nl-agent-curation-tools--submission-id
                     (nth 3 prepared) (nth 4 prepared) payload kind)))
              (nl-agent-curation-tools--submit
               queue payload metadata id kind))
          (let* ((prepared
                  (nl-agent-curation-tools--prepared
                   (nl-agent-curation-prepare curator record-id)))
                 (payload (nth 0 prepared))
                 (metadata (nth 1 prepared))
                 (id
                  (nl-agent-curation-tools--submission-id
                   (nth 2 prepared) (nth 3 prepared) payload)))
            (nl-agent-curation-tools--submit queue payload metadata id)))))
    :description
    "Submit one immutable host-curated trajectory as a pending experiment"
    :risk 'write
    :metadata (list :input-schema nl-agent-curation-tool-schema)))
  registry)

(provide 'nl-agent-curation-tools)
;;; nl-agent-curation-tools.el ends here
