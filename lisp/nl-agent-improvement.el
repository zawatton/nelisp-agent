;;; nl-agent-improvement.el --- guarded model evolution tools  -*- lexical-binding: t; -*-

;; The standalone reasoning worker sees only tool descriptors.  The trusted host
;; owns the evaluated proposal queue, its callbacks, training state, and artifact
;; publisher.  Queue mutations therefore cross the ordinary permission boundary.

;;; Code:

(require 'nl-llm-compat)
(require 'nl-llm-evolve-queue)
(require 'nl-agent-tool)

(declare-function nl-agent-training-runner-status "nl-agent-training-runner"
                  (runner))
(declare-function nl-agent-training-runner-start "nl-agent-training-runner"
                  (runner &optional id resuming))
(declare-function nl-agent-training-runner-cancel "nl-agent-training-runner"
                  (runner id))
(declare-function nl-agent-training-runner-task-audit-directory
                  "nl-agent-training-runner" (runner))
(declare-function nl-agent-training-runner-profile
                  "nl-agent-training-runner" (runner))
(declare-function nl-agent-task-audit-summary "nl-agent-task-audit"
                  (directory scope job-id attempt))
(declare-function nl-agent-task-audit--scope "nl-agent-task-audit" (value))
(declare-function nl-agent-task-audit--id "nl-agent-task-audit"
                  (value where))

(defconst nl-agent-improvement-status-schema
  '(:type "object" :additionalProperties nil)
  "Input schema for reading the model improvement queue.")

(defconst nl-agent-improvement-submit-schema
  '(:type "object"
    :properties
    (:kind (:type "string")
     :payload (:description "Data-only allowlisted experiment parameters")
     :id (:type "string")
     :priority (:type "integer" :minimum -1000 :maximum 1000)
     :metadata (:description "Data-only audit metadata"))
    :required ["kind" "payload"]
    :additionalProperties nil)
  "Input schema for submitting a model improvement proposal.")

(defconst nl-agent-improvement-run-schema
  '(:type "object"
    :properties (:id (:type "string"))
    :additionalProperties nil)
  "Input schema for evaluating a queued proposal.")

(defconst nl-agent-improvement-resume-schema
  '(:type "object"
    :properties (:id (:type "string"))
    :required ["id"]
    :additionalProperties nil)
  "Input schema for explicitly resuming an interrupted proposal.")

(defconst nl-agent-improvement-cancel-schema
  '(:type "object"
    :properties (:id (:type "string"))
    :required ["id"]
    :additionalProperties nil)
  "Input schema for cancelling a proposal.")

(defconst nl-agent-improvement-evaluation-schema
  '(:type "object"
    :properties (:scope (:type "string")
                 :id (:type "string")
                 :attempt (:type "string"))
    :required ["scope" "id" "attempt"]
    :additionalProperties nil)
  "Input schema for reading one bounded task-evaluation summary.")

(defun nl-agent-improvement--args (args allowed where)
  "Validate tool ARGS keys against ALLOWED for WHERE."
  (unless (and (listp args) (= (% (length args) 2) 0))
    (error "%s arguments must be a plist" where))
  (let ((tail args))
    (while tail
      (unless (memq (car tail) allowed)
        (error "%s contains unknown argument %S" where (car tail)))
      (setq tail (cddr tail))))
  args)

(defun nl-agent-improvement--required-string (args key where)
  "Return required string KEY from ARGS for WHERE."
  (let ((value (plist-get args key)))
    (unless (and (stringp value) (> (length value) 0))
      (error "%s requires non-empty %S" where key))
    value))

(defun nl-agent-improvement--exact-evaluation-args (args)
  "Validate and return the exact argument plist for evaluation lookup."
  (unless (and (listp args)
               (condition-case nil
                   (zerop (% (length args) 2))
                 (error nil)))
    (error "improvement evaluation arguments must be a plist"))
  (let ((tail args) seen)
    (while tail
      (let ((key (pop tail)))
        (pop tail)
        (unless (memq key '(:scope :id :attempt))
          (error "improvement evaluation contains unknown argument"))
        (when (memq key seen)
          (error "improvement evaluation contains duplicate argument"))
        (push key seen)))
    (dolist (key '(:scope :id :attempt))
      (unless (plist-member args key)
        (error "improvement evaluation is missing a required argument"))))
  args)

(defun nl-agent-improvement--detach-evaluation-value (value)
  "Detach bounded summary VALUE without exposing host-owned objects."
  (cond ((stringp value) (substring-no-properties value))
        ((consp value)
         (cons (nl-agent-improvement--detach-evaluation-value (car value))
               (nl-agent-improvement--detach-evaluation-value (cdr value))))
        ((vectorp value)
         (let ((copy (copy-sequence value)))
           (dotimes (i (length copy))
             (aset copy i
                   (nl-agent-improvement--detach-evaluation-value
                    (aref copy i))))
           copy))
        (t value)))

(defun nl-agent-improvement--evaluation-tool
    (runner audit-directory)
  "Return the read-only evaluation tool for RUNNER and AUDIT-DIRECTORY."
  (nl-agent-tool-new
   "model.improvement.evaluation"
   (lambda (args _context)
     (nl-agent-improvement--exact-evaluation-args args)
     ;; Validate identities and enforce runner scope before touching the
     ;; audit directory.  The caller never supplies a path.
     (require 'nl-agent-task-audit)
     (let ((scope (nl-agent-task-audit--scope (plist-get args :scope)))
           (id (nl-agent-task-audit--id
                (plist-get args :id) "improvement evaluation id"))
           (attempt (nl-agent-task-audit--id
                     (plist-get args :attempt)
                     "improvement evaluation attempt"))
           (runner-scope
            (nl-agent-task-audit--scope
             (plist-get (nl-agent-training-runner-profile runner) :scope))))
       (unless (equal scope runner-scope)
         (error "improvement evaluation scope denied"))
       (condition-case nil
           (nl-agent-improvement--detach-evaluation-value
            (nl-agent-task-audit-summary audit-directory scope id attempt))
         (error (error "model improvement evaluation unavailable")))))
   :description
   "Read a bounded task-evaluation summary by its stable audit reference"
   :risk 'read
   :metadata (list :input-schema nl-agent-improvement-evaluation-schema)))

;;;###autoload
(defun nl-agent-improvement-register-tools (registry queue &optional runner)
  "Register guarded model improvement QUEUE tools into REGISTRY.

Status is read-only.  Submit/cancel are write-risk operations and running or
resuming an experiment is execute-risk, so smart policy requires explicit host
approval for every state-changing request.  Optional RUNNER executes training
in a separate process and returns a running job immediately.  Return REGISTRY."
  (unless (nl-agent-tool-registry-p registry)
    (error "nl-agent-improvement-register-tools: invalid tool registry"))
  (unless (nl-llm-evolve-queue-p queue)
    (error "nl-agent-improvement-register-tools: invalid improvement queue"))
  (nl-agent-tool-register
   registry
   (nl-agent-tool-new
    "model.improvement.status"
    (lambda (args _context)
      (nl-agent-improvement--args args nil "improvement status")
      (if runner
          (nl-agent-training-runner-status runner)
        (nl-llm-evolve-queue-status queue)))
    :description
    "Inspect allowlisted model experiments and champion evaluation state"
    :risk 'read
    :metadata (list :input-schema nl-agent-improvement-status-schema)))
  (nl-agent-tool-register
   registry
   (nl-agent-tool-new
    "model.improvement.submit"
    (lambda (args _context)
      (nl-agent-improvement--args
       args '(:kind :payload :id :priority :metadata)
       "improvement submit")
      (unless (plist-member args :payload)
        (error "improvement submit requires :payload"))
      (nl-llm-evolve-queue-submit
       queue
       (nl-agent-improvement--required-string
        args :kind "improvement submit")
       (plist-get args :payload)
       :id (plist-get args :id)
       :priority (or (plist-get args :priority) 0)
       :metadata (plist-get args :metadata)))
    :description
    "Queue data for a trusted, allowlisted challenger experiment"
    :risk 'write
    :metadata (list :input-schema nl-agent-improvement-submit-schema)))
  (nl-agent-tool-register
   registry
   (nl-agent-tool-new
    "model.improvement.run"
    (lambda (args _context)
      (nl-agent-improvement--args args '(:id) "improvement run")
      (let ((id (plist-get args :id)))
        (when (and id (not (stringp id)))
          (error "improvement run :id must be text"))
        (if runner
            (nl-agent-training-runner-start runner id)
          (nl-llm-evolve-queue-run queue id))))
    :description
    (if runner
        "Start background training; poll status for evaluation and publication"
      "Evaluate one queued challenger and publish it only if the fixed gate passes")
    :risk 'execute
    :metadata (list :input-schema nl-agent-improvement-run-schema)))
  (nl-agent-tool-register
   registry
   (nl-agent-tool-new
    "model.improvement.resume"
    (lambda (args _context)
      (nl-agent-improvement--args args '(:id) "improvement resume")
      (let ((id (nl-agent-improvement--required-string
                 args :id "improvement resume")))
        (if runner
            (nl-agent-training-runner-start runner id t)
          (nl-llm-evolve-queue-resume queue id))))
    :description
    "Resume one interrupted challenger from its transaction-bound checkpoint"
    :risk 'execute
    :metadata (list :input-schema nl-agent-improvement-resume-schema)))
  (nl-agent-tool-register
   registry
   (nl-agent-tool-new
    "model.improvement.cancel"
    (lambda (args _context)
      (nl-agent-improvement--args args '(:id) "improvement cancel")
      (let ((id (nl-agent-improvement--required-string
                 args :id "improvement cancel")))
        (if runner
            (nl-agent-training-runner-cancel runner id)
          (nl-llm-evolve-queue-cancel queue id))))
    :description
    (if runner
        "Cancel a challenger, stopping matching background training first"
      "Cancel a pending or interrupted challenger before execution or resumption")
    :risk 'write
    :metadata (list :input-schema nl-agent-improvement-cancel-schema)))
  (when (and runner
             (nl-agent-training-runner-task-audit-directory runner))
    ;; Keep the legacy five-tool catalog unchanged when no audit directory is
    ;; configured.  Task-audit is loaded only for this opt-in read tool.
    (require 'nl-agent-task-audit)
    (nl-agent-tool-register
     registry
     (nl-agent-improvement--evaluation-tool
      runner
      (substring-no-properties
       (nl-agent-training-runner-task-audit-directory runner)))))
  registry)

(provide 'nl-agent-improvement)
;;; nl-agent-improvement.el ends here
