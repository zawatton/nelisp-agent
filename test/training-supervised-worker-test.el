;;; training-supervised-worker-test.el --- supervised worker boundary tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-training-protocol)
(require 'nl-agent-training-worker)
(require 'nl-llm-agent-improve)
(require 'nl-llm-agent-supervised)
(require 'nl-llm-agent-artifact)

(defun nl-agent-training-supervised-worker-test--checkpoint ()
  "Return a small deterministic trainable P5 checkpoint."
  (nl-llm-agent-artifact-export-pav
   (nl-llm-agent-improve-model 4 4 nl-llm-agent-char-vocab 1 1)))

(defun nl-agent-training-supervised-worker-test--request
    (checkpoint kind backend payload)
  "Build a request for KIND, BACKEND, and PAYLOAD around CHECKPOINT."
  (append
   (list :format nl-agent-training-protocol-format
         :attempt "supervised-attempt"
         :job-id "supervised-job"
         :parent-generation 0
         :parent-score 0.0
         :scope (make-string 64 ?0)
         :payload payload
         :parent-model checkpoint
         :training (list :backend backend :sequence 8 :optimizer 'sgd)
         :benchmark ["ab"])
   (when kind (list :kind kind))))

(defun nl-agent-training-supervised-worker-test--run
    (request directory)
  "Write REQUEST in DIRECTORY, run the worker, and return its result."
  (let ((request-file (expand-file-name "request.sexp" directory))
        (result-file (expand-file-name "result.sexp" directory)))
    (nl-agent-training-protocol-write request-file request)
    (nl-agent-training-worker-run request-file result-file)
    (nl-agent-training-protocol-read result-file)))

(defun nl-agent-training-supervised-worker-test--parameter-data (model)
  "Return detached parameter data from exported MODEL."
  (mapcar (lambda (tensor)
            (copy-sequence (photon-tensor-data tensor)))
          (nl-agent-training-protocol--model-tensors model)))

(defun nl-agent-training-supervised-worker-test--run-child
    (request directory)
  "Run REQUEST in a fresh worker child rooted at DIRECTORY."
  (let* ((request-file (expand-file-name "request.sexp" directory))
         (result-file (expand-file-name "result.sexp" directory))
         (worker-path
          (file-truename (locate-library "nl-agent-training-worker")))
         (worker-directory (file-name-directory worker-path))
         (output (generate-new-buffer " *supervised-worker-gpu-child*"))
         status)
    (unwind-protect
        (progn
          (nl-agent-training-protocol-write request-file request)
          (setq status
                (call-process
                 (or (getenv "EMACS") "emacs") nil output nil
                 "-Q" "--batch"
                 "--eval" "(setq load-prefer-newer t)"
                 "-L" (expand-file-name "../../nelisp-photon/lisp"
                                         worker-directory)
                 "-L" (expand-file-name "../../nelisp-llm/lisp"
                                         worker-directory)
                 "-L" worker-directory
                 "-l" worker-path "--funcall"
                 "nl-agent-training-worker-main"
                 request-file result-file))
          (unless (and (= status 0) (file-regular-p result-file))
            (error "supervised GPU child failed: %s"
                   (with-current-buffer output (buffer-string))))
          (nl-agent-training-protocol-read result-file))
      (kill-buffer output))))

(ert-deftest nl-agent-training-worker-supervised-cpu-matches-public-trainer ()
  (let* ((pairs [(:prompt "Q:" :completion "A")])
         (checkpoint (nl-agent-training-supervised-worker-test--checkpoint))
         (request
          (nl-agent-training-supervised-worker-test--request
           checkpoint "supervised-finetune" 'cpu
           (list :examples pairs :lr 0.1 :epochs 1)))
         (direct (nl-agent-training-protocol-import checkpoint))
         (directory (make-temp-file "nl-supervised-worker-cpu-" t)))
    (unwind-protect
        (progn
          ;; The direct reference uses the same public API and prompt boundary.
          (nl-llm-agent-supervised-train
           direct pairs :backend 'cpu :lr 0.1 :epochs 1 :optimizer 'sgd)
          (let* ((result
                  (nl-agent-training-supervised-worker-test--run
                   request directory))
                 (worker-model (plist-get result :model))
                 (direct-export
                  (nl-llm-agent-artifact-export-pav direct)))
            (nl-agent-training-protocol-validate-result result request)
            (should (equal
                     (nl-agent-training-supervised-worker-test--parameter-data
                      worker-model)
                     (nl-agent-training-supervised-worker-test--parameter-data
                      direct-export)))))
      (delete-directory directory t))))

(ert-deftest nl-agent-training-worker-legacy-kind-keeps-string-trajectory-path ()
  (let* ((checkpoint (nl-agent-training-supervised-worker-test--checkpoint))
         (request
          (nl-agent-training-supervised-worker-test--request
           checkpoint nil 'cpu
           '(:examples ["Q:A"] :lr 0.1 :epochs 1)))
         (seen nil)
         (directory (make-temp-file "nl-supervised-worker-legacy-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'nl-llm-agent-p5-finetune)
                   (lambda (_model trajectories lr epochs)
                     (setq seen (list trajectories lr epochs)))))
          (nl-agent-training-supervised-worker-test--run request directory)
          (should (equal (car seen)
                         (list (nl-llm-agent-tokenizer-encode
                                "Q:A" "ascii-char-v1"))))
          (should (= (nth 1 seen) 0.1))
          (should (= (nth 2 seen) 1)))
      (delete-directory directory t))))

(ert-deftest nl-agent-training-worker-supervised-gpu-passes-transfer-boundary-to-public-api ()
  (let* ((pairs [(:prompt "Q:" :completion "A")])
         (checkpoint (nl-agent-training-supervised-worker-test--checkpoint))
         (request
          (nl-agent-training-supervised-worker-test--request
           checkpoint "supervised-finetune" 'gpu
           (list :examples pairs :lr 0.1 :epochs 1)))
         (enabled 0)
         (call nil)
         (directory (make-temp-file "nl-supervised-worker-gpu-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'nl-llm-gpu-enable)
                   (lambda () (setq enabled (1+ enabled)) t))
                  ((symbol-function 'nl-llm-agent-supervised-train)
                   (lambda (model examples &rest keys)
                     (setq call (list model examples keys))
                     '(:backend gpu))))
          (nl-agent-training-supervised-worker-test--run request directory)
          (should (= enabled 1))
          (should (equal (nth 1 call) pairs))
          (should (eq (plist-get (nth 2 call) :backend) 'gpu))
          (should (= (plist-get (nth 2 call) :sequence) 8))
          (should (= (plist-get (nth 2 call) :epochs) 1)))
      (delete-directory directory t))))

(ert-deftest nl-agent-training-worker-supervised-invalid-pairs-reject-before-trainer ()
  (let* ((checkpoint (nl-agent-training-supervised-worker-test--checkpoint))
         (request
          (nl-agent-training-supervised-worker-test--request
           checkpoint "supervised-finetune" 'cpu
           '(:examples [(:prompt "Q:" :completion "")] :lr 0.1 :epochs 1)))
         (calls 0)
         (directory (make-temp-file "nl-supervised-worker-invalid-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'nl-llm-agent-supervised-train)
                   (lambda (&rest _args)
                     (setq calls (1+ calls)))))
          (should-error
           (nl-agent-training-supervised-worker-test--run request directory))
          (should (= calls 0)))
      (delete-directory directory t))))

(ert-deftest nl-agent-training-worker-supervised-real-gpu-child-adam ()
  "Run one supervised GPU Adam child update when Vulkan is available."
  (unless (nl-llm-gpu-enable)
    (ert-skip "GPU backend unavailable"))
  ;; The child owns its own GPU lifecycle; leave the parent dispatcher clean.
  (nl-llm-gpu-disable)
  (let* ((pairs [(:prompt "Q:" :completion "A")])
         (checkpoint (nl-agent-training-supervised-worker-test--checkpoint))
         (request
          (nl-agent-training-supervised-worker-test--request
           checkpoint "supervised-finetune" 'gpu
           (list :examples pairs :lr 0.01 :epochs 1)))
         (before
          (nl-agent-training-supervised-worker-test--parameter-data checkpoint))
         (directory (make-temp-file "nl-supervised-worker-gpu-child-" t)))
    (setf (plist-get (plist-get request :training) :optimizer) 'adam)
    (unwind-protect
        (let* ((result
                (nl-agent-training-supervised-worker-test--run-child
                 request directory))
               (after (plist-get result :model)))
          ;; Bind the child result to the exact request bytes and architecture.
          (should
           (equal (plist-get result :request-sha256)
                  (nl-agent-training-protocol-hash
                   (expand-file-name "request.sexp" directory))))
          (nl-agent-training-protocol-validate-result result request)
          (should
           (cl-some
            (lambda (pair) (not (equal (car pair) (cdr pair))))
            (cl-mapcar #'cons before
                       (nl-agent-training-supervised-worker-test--parameter-data
                        after)))))
      (delete-directory directory t))))

(provide 'training-supervised-worker-test)

(ert-run-tests-batch-and-exit)

;;; training-supervised-worker-test.el ends here
