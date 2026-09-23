;;; training-supervised-resume-worker-test.el --- supervised worker resume -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-training-protocol)
(require 'nl-agent-training-worker)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-completion-plan)
(require 'nl-llm-agent-improve)
(require 'nl-llm-gpu)
(require 'photon-tensor)

(defun nl-agent-training-supervised-resume-worker-test--checkpoint ()
  "Return a deterministic tiny trainable P5 checkpoint."
  (nl-llm-agent-artifact-export-pav
   (nl-llm-agent-improve-model 4 4 256 1 1 "utf8-byte-v1")))

(defun nl-agent-training-supervised-resume-worker-test--request
    (checkpoint attempt &optional resume-state)
  "Build the fixed GPU Adam request for ATTEMPT and RESUME-STATE."
  (append
   (list :format nl-agent-training-protocol-format
         :kind "supervised-finetune"
         :attempt attempt
         :job-id "supervised-resume-job"
         :parent-generation 0
         :parent-score 0.0
         :scope (make-string 64 ?0)
         :payload
         (list :examples
               [(:prompt "QQ" :completion "A")
                (:prompt "RR" :completion "BC")
                (:prompt "SS" :completion "CDE")]
               :lr 0.01 :epochs 2)
         :parent-model checkpoint
         :training
         (list :backend 'gpu :sequence 8 :optimizer 'adam
               :checkpoint-every 1)
         :benchmark ["ab"])
   (when resume-state
     (list :resume-state resume-state))))

(defun nl-agent-training-supervised-resume-worker-test--parameters (model)
  "Return detached parameter data from exported MODEL."
  (mapcar (lambda (tensor)
            (copy-sequence (photon-tensor-data tensor)))
          (nl-agent-training-protocol--model-tensors model)))

(defun nl-agent-training-supervised-resume-worker-test--max-diff (left right)
  "Return the maximum absolute difference between numeric vectors."
  (unless (= (length left) (length right))
    (error "resume parameter lengths differ"))
  (let ((maximum 0.0)
        (index 0))
    (while (< index (length left))
      (setq maximum (max maximum
                         (abs (- (aref left index) (aref right index)))))
      (setq index (1+ index)))
    maximum))

(defun nl-agent-training-supervised-resume-worker-test--optimizer-diff
    (left right)
  "Return the maximum absolute difference between Adam moment tensors."
  (cond
   ((and (null left) (null right)) 0.0)
   ((or (null left) (null right)
        (/= (length left) (length right)))
    (error "resume optimizer-state lengths differ"))
   (t
    (let ((maximum 0.0)
          (left-tail left)
          (right-tail right))
      (while left-tail
        (let ((left-pair (pop left-tail))
              (right-pair (pop right-tail)))
          (setq maximum
                (max maximum
                     (nl-agent-training-supervised-resume-worker-test--max-diff
                      (photon-tensor-data (car left-pair))
                      (photon-tensor-data (car right-pair)))
                     (nl-agent-training-supervised-resume-worker-test--max-diff
                      (photon-tensor-data (cdr left-pair))
                      (photon-tensor-data (cdr right-pair))))))
      maximum)))))

(defun nl-agent-training-supervised-resume-worker-test--child
    (request directory &optional interrupt-step count-file)
  "Run REQUEST in a fresh worker child rooted at DIRECTORY.

When INTERRUPT-STEP is non-nil, the child raises after that completed update,
after the worker callback has persisted its checkpoint."
  (let* ((request-file (expand-file-name "request.sexp" directory))
         (result-file (expand-file-name "result.sexp" directory))
         (worker-path
          (file-truename (locate-library "nl-agent-training-worker")))
         (worker-directory (file-name-directory worker-path))
         (output (generate-new-buffer " *supervised-resume-worker-child*"))
         (args (list "-Q" "--batch"
                     "--eval" "(setq load-prefer-newer t)"
                     "-L" (expand-file-name "../../nelisp-photon/lisp"
                                             worker-directory)
                     "-L" (expand-file-name "../../nelisp-llm/lisp"
                                             worker-directory)
                     "-L" worker-directory
                     "-l" worker-path))
         status)
    (unwind-protect
        (progn
          (nl-agent-training-protocol-write request-file request)
          (when (or interrupt-step count-file)
            (let ((advice-form
                   `(progn
                      (advice-add
                       'nl-llm-agent-ondevice-train :around
                       (lambda (original context trajectories epochs &rest keys)
                         (let ((callback (plist-get keys :after-step))
                               (executed 0))
                           (setq keys
                                 (plist-put
                                  (copy-sequence keys) :after-step
                                  (lambda (active completed total)
                                    (when callback
                                      (funcall callback active completed total))
                                    (setq executed (1+ executed))
                                    (when ,count-file
                                      (with-temp-file ,count-file
                                        (insert (number-to-string executed))))
                                    (when (and ,interrupt-step
                                               (= completed ,interrupt-step))
                                      (error "test interruption at step %d"
                                             ,interrupt-step)))))
                           (apply original context trajectories epochs keys))))
                      )))
              (setq args
                    (append args
                            (list "--eval"
                                  (prin1-to-string advice-form))))))
          (setq args
                (append args
                        (list "--funcall" "nl-agent-training-worker-main"
                              request-file result-file)))
          (setq status
                (apply #'call-process (or (getenv "EMACS") "emacs")
                       nil output nil args))
          (list :status status
                :output (with-current-buffer output (buffer-string))
                :request-file request-file
                :result-file result-file
                :count-file count-file
                :checkpoint-file
                (nl-agent-training-worker--checkpoint-file result-file)))
      (kill-buffer output))))

(ert-deftest nl-agent-training-worker-supervised-checkpoint-binds-plan ()
  (let* ((checkpoint (nl-agent-training-supervised-resume-worker-test--checkpoint))
         (request
          (nl-agent-training-supervised-resume-worker-test--request
           checkpoint "attempt-plan"))
         (_optimizer
          (setf (plist-get (plist-get request :training) :optimizer) 'sgd))
         (plan (nl-agent-training-protocol-completion-plan request))
         (model (nl-agent-training-protocol-import checkpoint))
         (snapshot (list :step 0 :model model :optimizer-state nil
                         :completion-plan plan))
         (state
          (nl-agent-training-worker--checkpoint-state
           request snapshot 0 6 plan)))
    (should (equal (plist-get state :format)
                   nl-llm-agent-training-checkpoint-completion-format))
    (should (equal (plist-get state :completion-plan) plan))
    (should (equal (plist-get state :payload-digest)
                   (nl-llm-agent-training-checkpoint--completion-payload-digest
                    (plist-get request :payload))))))

(ert-deftest nl-agent-training-worker-supervised-checkpoint-rejects-plan-boundary-mismatch ()
  (let* ((checkpoint (nl-agent-training-supervised-resume-worker-test--checkpoint))
         (request
          (nl-agent-training-supervised-resume-worker-test--request
           checkpoint "attempt-plan-mismatch"))
         (_optimizer
          (setf (plist-get (plist-get request :training) :optimizer) 'sgd))
         (plan (nl-agent-training-protocol-completion-plan request))
         (wrong-plan
          (nl-llm-agent-completion-plan-make
           (plist-get plan :trajectories) [1 2 3]
           :tokenizer (plist-get plan :tokenizer)
           :sequence (plist-get plan :sequence)
           :learning-rate (plist-get plan :learning-rate)
           :epochs (plist-get plan :epochs)
           :optimizer (plist-get plan :optimizer)
           :transfer-mode (plist-get plan :transfer-mode)))
         (model (nl-agent-training-protocol-import checkpoint))
         (root (make-temp-file "nl-supervised-plan-mismatch-" t))
         (file (expand-file-name "nested/checkpoint.sexp" root)))
    (should (equal wrong-plan
                   (nl-llm-agent-completion-plan-validate wrong-plan)))
    (unwind-protect
        (progn
          (should-error
           (nl-agent-training-worker--checkpoint-state
            request (list :step 0 :model model :optimizer-state nil
                          :completion-plan wrong-plan)
            0 6 plan))
          (should-error
           (nl-agent-training-worker--write-checkpoint
            file request (make-string 64 ?a)
            (list :step 0 :model model :optimizer-state nil
                  :completion-plan wrong-plan)
            0 6 plan))
          (should-not (file-directory-p (file-name-directory file))))
      (delete-directory root t))))

(ert-deftest nl-agent-training-worker-legacy-checkpoint-rejects-completion-plan ()
  (let* ((checkpoint (nl-agent-training-supervised-resume-worker-test--checkpoint))
         (request
          (nl-agent-training-supervised-resume-worker-test--request
           checkpoint "attempt-legacy-reject"))
         (_optimizer
          (setf (plist-get (plist-get request :training) :optimizer) 'sgd))
         (plan (nl-agent-training-protocol-completion-plan request))
         (model (nl-agent-training-protocol-import checkpoint)))
    (setf (plist-get request :kind) "trajectory-finetune")
    (should-error
     (nl-agent-training-worker--checkpoint-state
      request (list :step 0 :model model :optimizer-state nil
                    :completion-plan plan)
      0 6 nil))))

(ert-deftest nl-agent-training-worker-supervised-resume-plan-rejects-before-gpu ()
  (let* ((checkpoint (nl-agent-training-supervised-resume-worker-test--checkpoint))
         (request
          (nl-agent-training-supervised-resume-worker-test--request
           checkpoint "attempt-invalid-resume"))
         (_optimizer
          (setf (plist-get (plist-get request :training) :optimizer) 'sgd))
         (plan (nl-agent-training-protocol-completion-plan request))
         (wrong-plan
          (nl-llm-agent-completion-plan-make
           (plist-get plan :trajectories) [1 2 3]
           :tokenizer (plist-get plan :tokenizer)
           :sequence (plist-get plan :sequence)
           :learning-rate (plist-get plan :learning-rate)
           :epochs (plist-get plan :epochs)
           :optimizer (plist-get plan :optimizer)
           :transfer-mode (plist-get plan :transfer-mode)))
         (model (nl-agent-training-protocol-import checkpoint))
         (state
          (nl-agent-training-worker--checkpoint-state
           request (list :step 0 :model model :optimizer-state nil
                         :completion-plan plan)
           0 6 plan))
         (directory (make-temp-file "nl-supervised-resume-invalid-" t))
         (request-file (expand-file-name "request.sexp" directory))
         (result-file (expand-file-name "result.sexp" directory))
         (enabled 0) (restored 0))
    (setf (plist-get state :completion-plan) wrong-plan)
    (setf (plist-get request :resume-state) state)
    (unwind-protect
        (progn
          (nl-agent-training-protocol-write request-file request)
          (cl-letf (((symbol-function 'nl-llm-gpu-enable)
                     (lambda () (setq enabled (1+ enabled)) t))
                    ((symbol-function
                      'nl-llm-agent-training-checkpoint-restore-model)
                     (lambda (&rest _args) (setq restored (1+ restored)))))
            (should-error
             (nl-agent-training-worker-run request-file result-file)))
          (should (= enabled 0))
          (should (= restored 0))
          (should-not (file-exists-p result-file)))
      (delete-directory directory t))))

(ert-deftest nl-agent-training-worker-supervised-real-gpu-child-resume ()
  "Compare uninterrupted, interrupted, and restored Adam child training."
  (unless (nl-llm-gpu-enable)
    (ert-skip "GPU backend unavailable"))
  (nl-llm-gpu-disable)
  (let* ((checkpoint (nl-agent-training-supervised-resume-worker-test--checkpoint))
         (baseline-request
          (nl-agent-training-supervised-resume-worker-test--request
           checkpoint "attempt-baseline"))
         (interrupt-request
          (nl-agent-training-supervised-resume-worker-test--request
           checkpoint "attempt-interrupt"))
         (baseline-dir (make-temp-file "nl-supervised-resume-baseline-" t))
         (interrupt-dir (make-temp-file "nl-supervised-resume-interrupt-" t))
         (baseline-count (expand-file-name "updates" baseline-dir))
         (interrupt-count (expand-file-name "updates" interrupt-dir))
         baseline interrupt resumed-state resume-request resume-dir resume
         interrupted-envelope resume-count final-request final-dir final
         resume-final resume-result
         final-count)
    (unwind-protect
        (progn
          (setq baseline
                (nl-agent-training-supervised-resume-worker-test--child
                 baseline-request baseline-dir nil baseline-count))
          (should (= (plist-get baseline :status) 0))
          (should (file-regular-p (plist-get baseline :result-file)))
          (should (equal (with-temp-buffer
                           (insert-file-contents baseline-count)
                           (string-to-number (buffer-string)))
                         6))
          (setq interrupt
                (nl-agent-training-supervised-resume-worker-test--child
                 interrupt-request interrupt-dir 2 interrupt-count))
          (should (/= (plist-get interrupt :status) 0))
          (should (string-match-p "test interruption"
                                 (plist-get interrupt :output)))
          (should (file-regular-p (plist-get interrupt :checkpoint-file)))
          (should-not (file-exists-p (plist-get interrupt :result-file)))
          (should (equal (with-temp-buffer
                           (insert-file-contents interrupt-count)
                           (string-to-number (buffer-string)))
                         2))
          (setq interrupted-envelope
                (nl-agent-training-protocol-read
                 (plist-get interrupt :checkpoint-file))
                resumed-state (plist-get interrupted-envelope :state)
                resume-request
                (nl-agent-training-supervised-resume-worker-test--request
                 checkpoint "attempt-resume" resumed-state)
                resume-dir (make-temp-file "nl-supervised-resume-final-" t)
                resume-count (expand-file-name "updates" resume-dir)
                resume
                (nl-agent-training-supervised-resume-worker-test--child
                 resume-request resume-dir nil resume-count))
          (should (= (plist-get resume :status) 0))
          (should (file-regular-p (plist-get resume :result-file)))
          (should (equal (with-temp-buffer
                           (insert-file-contents resume-count)
                           (string-to-number (buffer-string)))
                         4))
          (setq resume-final
                (nl-agent-training-protocol-read
                 (plist-get resume :checkpoint-file)))
          (let* ((baseline-result
                  (nl-agent-training-protocol-read
                   (plist-get baseline :result-file)))
                 (baseline-final
                  (nl-agent-training-protocol-read
                   (plist-get baseline :checkpoint-file)))
                 (baseline-model (plist-get baseline-result :model))
                 (resume-model nil))
            (setq resume-result
                  (nl-agent-training-protocol-read
                   (plist-get resume :result-file)))
            (setq resume-model (plist-get resume-result :model))
            (should (equal (plist-get baseline-result :request-sha256)
                           (nl-agent-training-protocol-hash
                            (plist-get baseline :request-file))))
            (should (equal (plist-get resume-result :request-sha256)
                           (nl-agent-training-protocol-hash
                            (plist-get resume :request-file))))
            (should (> (nl-agent-training-supervised-resume-worker-test--max-diff
                        (apply #'vconcat
                               (nl-agent-training-supervised-resume-worker-test--parameters
                                checkpoint))
                        (apply #'vconcat
                               (nl-agent-training-supervised-resume-worker-test--parameters
                                baseline-model)))
                       1.0e-10))
            (should (= (plist-get (plist-get resume-final :state)
                                  :completed-steps)
                       6))
            (should (= (plist-get (plist-get resume-final :state)
                                  :optimizer-step)
                       6))
            (should (equal
                     (nl-agent-training-supervised-resume-worker-test--parameters
                      baseline-model)
                     (nl-agent-training-supervised-resume-worker-test--parameters
                      resume-model)))
            (should (equal
                     (plist-get (plist-get baseline-final :state)
                                :optimizer-state)
                     (plist-get (plist-get resume-final :state)
                                :optimizer-state)))
                           (should (equal (plist-get (plist-get baseline-final :state)
                                      :completion-plan)
                           (plist-get (plist-get resume-final :state)
                                      :completion-plan))))
          (setq final-request
                (nl-agent-training-supervised-resume-worker-test--request
                 checkpoint "attempt-final" (plist-get resume-final :state))
                final-dir (make-temp-file "nl-supervised-resume-noop-" t)
                final-count (expand-file-name "updates" final-dir)
                final
                (nl-agent-training-supervised-resume-worker-test--child
                 final-request final-dir nil final-count))
          (should (= (plist-get final :status) 0))
          (should (file-regular-p (plist-get final :result-file)))
          (should-not (file-exists-p final-count))
          (let* ((final-result
                  (nl-agent-training-protocol-read
                   (plist-get final :result-file)))
                 (final-envelope
                  (nl-agent-training-protocol-read
                   (plist-get final :checkpoint-file))))
            (should (equal (plist-get (plist-get final-envelope :state)
                                      :optimizer-state)
                           (plist-get (plist-get resume-final :state)
                                      :optimizer-state)))
            (should (equal
                     (nl-agent-training-supervised-resume-worker-test--parameters
                      (plist-get final-result :model))
                     (nl-agent-training-supervised-resume-worker-test--parameters
                      (plist-get resume-result :model))))
            (should (equal (plist-get final-envelope :attempt)
                           (plist-get final-request :attempt)))))
      (dolist (directory (list baseline-dir interrupt-dir resume-dir final-dir))
        (when (and directory (file-directory-p directory))
          (delete-directory directory t))))))

(provide 'training-supervised-resume-worker-test)

(ert-run-tests-batch-and-exit)

;;; training-supervised-resume-worker-test.el ends here
