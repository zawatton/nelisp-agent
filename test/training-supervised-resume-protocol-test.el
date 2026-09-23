;;; training-supervised-resume-protocol-test.el --- completion checkpoint tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(defconst nl-agent-training-supervised-resume-test--here
  (file-name-directory (or load-file-name buffer-file-name)))

(let ((here nl-agent-training-supervised-resume-test--here))
  (load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                          (file-name-directory (or load-file-name buffer-file-name
                                                   default-directory))) nil t)
)

(require 'nl-agent-training-protocol)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-improve)
(require 'nl-llm-agent-completion-plan)
(require 'nl-llm-agent-training-checkpoint)
(require 'photon-tensor)

(defun nl-agent-training-supervised-resume-test--request
    (&optional payload training)
  "Return a small valid GPU supervised request."
  (list :format nl-agent-training-protocol-format
        :kind "supervised-finetune"
        :attempt "attempt-1" :job-id "job-1"
        :parent-generation 3 :parent-score 0.25
        :scope (make-string 64 ?b)
        :payload (or payload
                     '(:examples [(:prompt "Q:" :completion "A!")
                                  (:prompt "X:" :completion "B!")]
                       :lr 0.1 :epochs 2))
        :parent-model
        (nl-llm-agent-artifact-export-pav
         (nl-llm-agent-improve-model 4 4 96 1 1))
        :training (or training
                      '(:backend gpu :sequence 8 :optimizer adam
                        :checkpoint-every 2))
        :benchmark ["ab"]))

(defun nl-agent-training-supervised-resume-test--zero-like (tensor)
  "Return a zero tensor with TENSOR's shape and data length."
  (photon-tensor
   (copy-sequence (photon-tensor-shape tensor))
   (make-vector (length (photon-tensor-data tensor)) 0.0)))

(defun nl-agent-training-supervised-resume-test--adam-state (model)
  "Return zero Adam moments in resident parameter order."
  (mapcar
   (lambda (parameter)
     (cons
      (nl-agent-training-supervised-resume-test--zero-like parameter)
      (nl-agent-training-supervised-resume-test--zero-like parameter)))
   (reverse (nl-llm-agent-training-checkpoint--model-parameters model))))

(defun nl-agent-training-supervised-resume-test--state (request)
  "Return a valid one-step completion checkpoint state for REQUEST."
  (let* ((plan (nl-agent-training-protocol-completion-plan request))
         (model (copy-tree (plist-get request :parent-model) t)))
    (plist-put model :step 1)
    (list :format nl-llm-agent-training-checkpoint-completion-format
          :job-id (plist-get request :job-id)
          :payload-digest
          (nl-llm-agent-training-checkpoint--completion-payload-digest
           (plist-get request :payload))
          :scope (plist-get request :scope)
          :parent-generation (plist-get request :parent-generation)
          :parent-score (plist-get request :parent-score)
          :sequence (plist-get (plist-get request :training) :sequence)
          :optimizer 'adam :completed-steps 1
          :total-steps (* (plist-get plan :epochs)
                          (length (plist-get plan :trajectories)))
          :optimizer-step 1 :model model
          :optimizer-state
          (nl-agent-training-supervised-resume-test--adam-state model)
          :request-binding
          (nl-agent-training-protocol-request-binding request)
          :completion-plan plan)))

(defun nl-agent-training-supervised-resume-test--envelope
    (request state)
  "Return a progress envelope containing STATE for REQUEST."
  (list :format nl-agent-training-checkpoint-format
        :attempt (plist-get request :attempt)
        :request-sha256 (make-string 64 ?a)
        :state state))

(defun nl-agent-training-supervised-resume-test--without-key (plist key)
  "Return PLIST without KEY."
  (let ((tail plist) result)
    (while tail
      (let ((candidate (pop tail)) (value (pop tail)))
        (unless (eq candidate key)
          (setq result (append result (list candidate value))))))
    result))

(ert-deftest nl-agent-training-supervised-resume-helper-is-canonical-and-detached ()
  (let* ((request (nl-agent-training-supervised-resume-test--request))
         (plan (nl-agent-training-protocol-completion-plan request))
         (again (nl-agent-training-protocol-completion-plan request)))
    (should (equal plan again))
    (should-not (eq plan again))
    (let* ((mutation-request
            (nl-agent-training-supervised-resume-test--request))
           (mutation-model
            (copy-tree (plist-get mutation-request :parent-model) t))
           (mutation-config
            (copy-tree (plist-get mutation-model :config) t))
           (source-tokenizer
            (copy-sequence (plist-get mutation-config :tokenizer))))
      (plist-put mutation-config :tokenizer source-tokenizer)
      (plist-put mutation-model :config mutation-config)
      (plist-put mutation-request :parent-model mutation-model)
      (let ((mutation-plan
             (nl-agent-training-protocol-completion-plan mutation-request)))
        (aset source-tokenizer 0 ?X)
        (should (equal (plist-get mutation-plan :tokenizer)
                       "ascii-char-v1"))))
    (dolist (bad
             (list
              (plist-put (copy-tree request t) :kind nil)
              (plist-put (copy-tree request t) :kind 'supervised-finetune)
              (plist-put (copy-tree request t) :training
                         '(:backend cpu :sequence 8 :optimizer sgd))
              (plist-put (copy-tree request t) :training
                         '(:backend gpu :sequence 8 :optimizer sgd :extra t))
              (plist-put (copy-tree request t) :payload
                         '(:examples [(:prompt "Q" :completion "A")]
                           :lr 0.1 :epochs 1 :extra t))))
      (should-error (nl-agent-training-protocol-completion-plan bad)))))

(ert-deftest nl-agent-training-supervised-resume-helper-preserves-boundaries ()
  (let* ((left (nl-agent-training-supervised-resume-test--request
                '(:examples [(:prompt "Q:" :completion "A!")]
                  :lr 0.1 :epochs 1)))
         (right (nl-agent-training-supervised-resume-test--request
                 '(:examples [(:prompt "Q" :completion ":A!")]
                   :lr 0.1 :epochs 1)))
         (left-plan (nl-agent-training-protocol-completion-plan left))
         (right-plan (nl-agent-training-protocol-completion-plan right)))
    (should (equal (plist-get left-plan :trajectories)
                   (plist-get right-plan :trajectories)))
    (should-not (equal (plist-get left-plan :loss-starts)
                       (plist-get right-plan :loss-starts)))
    (should-not (equal (plist-get left-plan :digest)
                       (plist-get right-plan :digest)))))

(ert-deftest nl-agent-training-supervised-resume-validates-wire-roundtrip ()
  (let* ((request (nl-agent-training-supervised-resume-test--request))
         (state (nl-agent-training-supervised-resume-test--state request))
         (envelope (nl-agent-training-supervised-resume-test--envelope
                    request state))
         (request-with-state (append request (list :resume-state state)))
         (file (make-temp-file "nl-supervised-progress-")))
    (unwind-protect
        (progn
          (should (eq (nl-agent-training-protocol-validate-request
                       request-with-state)
                      request-with-state))
          (should (eq (nl-agent-training-protocol-validate-checkpoint
                       envelope request (make-string 64 ?a))
                      envelope))
          (nl-agent-training-protocol-write file envelope)
          (should (equal
                   (nl-agent-training-protocol-validate-checkpoint
                    (nl-agent-training-protocol-read file)
                    request (make-string 64 ?a))
                   envelope)))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest nl-agent-training-supervised-resume-rejects-plan-and-binding-tamper ()
  (let* ((request (nl-agent-training-supervised-resume-test--request))
         (state (nl-agent-training-supervised-resume-test--state request))
         (plan (plist-get state :completion-plan))
         (altered
          (nl-llm-agent-completion-plan-make
           (plist-get plan :trajectories) (plist-get plan :loss-starts)
           :tokenizer (plist-get plan :tokenizer)
           :sequence (plist-get plan :sequence)
           :learning-rate .2 :epochs (plist-get plan :epochs)
           :optimizer (plist-get plan :optimizer))))
    (should-error
     (nl-agent-training-protocol-validate-resume-state
      (plist-put (copy-tree state t) :completion-plan altered) request))
    (should-error
     (nl-agent-training-protocol-validate-resume-state
      (plist-put (copy-tree state t) :payload-digest (make-string 64 ?c))
      request))
    (let* ((boundary-request
            (nl-agent-training-supervised-resume-test--request
             '(:examples [(:prompt "Q" :completion ":A!")]
               :lr 0.1 :epochs 2)))
           (boundary-plan
            (nl-agent-training-protocol-completion-plan boundary-request))
           (boundary-state (copy-tree state t)))
      (plist-put boundary-state :completion-plan boundary-plan)
      (should-error
       (nl-agent-training-protocol-validate-resume-state
        boundary-state request)))
    (let ((legacy (copy-tree state t)))
      (plist-put legacy :format nl-llm-agent-training-checkpoint-format)
      (should-error
       (nl-agent-training-protocol-validate-resume-state legacy request)))))

(ert-deftest nl-agent-training-supervised-resume-rejects-cross-format-and-conditions ()
  (let* ((request (nl-agent-training-supervised-resume-test--request))
         (state (nl-agent-training-supervised-resume-test--state request))
         (cpu (nl-agent-training-supervised-resume-test--request
               nil '(:backend cpu :sequence 8 :optimizer sgd))))
    (should-error (nl-agent-training-protocol-validate-request
                   (append cpu (list :resume-state state))))
    (should-error (nl-agent-training-protocol-validate-request
                   (append request '(:resume-state nil))))
    (dolist (bad
             (list
              (plist-put (copy-tree request t) :kind "trajectory-finetune")
              (plist-put (copy-tree request t) :training
                         '(:backend gpu :sequence 8 :optimizer adam))
              (plist-put (copy-tree request t) :training
                         '(:backend gpu :sequence 4 :optimizer adam
                           :checkpoint-every 2))))
      (should-error
       (nl-agent-training-protocol-validate-request
        (append bad (list :resume-state state)))))))

(ert-deftest nl-agent-training-supervised-resume-rejects-invalid-state-fields ()
  (let* ((request (nl-agent-training-supervised-resume-test--request))
         (state (nl-agent-training-supervised-resume-test--state request))
         (bad (copy-tree state t)))
    (plist-put bad :total-steps 99)
    (should-error (nl-agent-training-protocol-validate-resume-state bad request))
    (should-error
     (nl-agent-training-protocol-validate-resume-state
      (append state '(:unknown t)) request))
    (should-error
     (nl-agent-training-protocol-validate-resume-state
      (append state '(:job-id "duplicate")) request))
    (should-error
     (nl-agent-training-protocol-validate-resume-state
      (nl-agent-training-supervised-resume-test--without-key
       state :completion-plan)
      request))
    (let ((step-state (copy-tree state t)))
      (plist-put (plist-get step-state :model) :step 0)
      (should-error
       (nl-agent-training-protocol-validate-resume-state step-state request)))))

(ert-run-tests-batch-and-exit)
