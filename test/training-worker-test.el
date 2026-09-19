;;; training-worker-test.el --- protocol and worker smoke tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'nl-agent-training-protocol)
(require 'nl-agent-training-worker)
(require 'nl-llm-agent-improve)
(require 'nl-llm-agent-artifact)

(defvar nl-agent-training-test--read-eval-fired nil)

(defun nl-agent-training-test--checkpoint (&optional dim ff)
  (nl-llm-agent-artifact-export-pav
   (nl-llm-agent-improve-model
    (or dim 4) (or ff 4) nl-llm-agent-char-vocab 1 1)))

(defun nl-agent-training-test--request (&optional backend optimizer model)
  (list :format nl-agent-training-protocol-format
        :attempt "a1" :job-id "j1" :parent-generation 0 :parent-score 0.0
        :scope (make-string 64 ?0)
        :payload '(:examples ["ab"] :lr 0.1 :epochs 1)
        :parent-model (or model (nl-agent-training-test--checkpoint))
        :training (list :backend (or backend 'cpu) :sequence 8
                        :optimizer (or optimizer 'sgd))
        :benchmark ["ab"]))

(defun nl-agent-training-test--result (request &optional model)
  (list :format nl-agent-training-result-format
        :attempt (plist-get request :attempt)
        :request-sha256 (make-string 64 ?a) :score 0.0
        :model (or model (plist-get request :parent-model))))

(defun nl-agent-training-test--without-key (plist omitted)
  (let ((tail plist) result)
    (while tail
      (let ((key (pop tail)) (value (pop tail)))
        (unless (eq key omitted)
          (setq result (append result (list key value))))))
    result))

(defun nl-agent-training-test--parameter-data (checkpoint)
  (mapcar (lambda (tensor)
            (copy-sequence (photon-tensor-data tensor)))
          (nl-agent-training-protocol--model-tensors checkpoint)))

(defun nl-agent-training-test--parameters-changed-p (before after)
  (cl-some (lambda (pair) (not (equal (car pair) (cdr pair))))
           (cl-mapcar #'cons before after)))

(defun nl-agent-training-test--worker-source ()
  (concat (file-name-sans-extension
           (file-truename (locate-library "nl-agent-training-worker")))
          ".el"))

(defun nl-agent-training-test--run-child (request-value request-file result-file)
  (let* ((worker-path (nl-agent-training-test--worker-source))
         (dir (file-name-directory worker-path))
         (output (generate-new-buffer " *training-child-output*"))
         status)
    (unwind-protect
        (progn
          (nl-agent-training-protocol-write request-file request-value)
          (setq status
                (call-process
                 (or (getenv "EMACS") "emacs") nil output nil "-Q" "--batch"
                 "--eval" "(setq load-prefer-newer t)"
                 "-L" (expand-file-name "../../nelisp-photon/lisp" dir)
                 "-L" (expand-file-name "../../nelisp-llm/lisp" dir)
                 "-L" dir "-l" worker-path
                 "--funcall" "nl-agent-training-worker-main"
                 request-file result-file))
          (unless (= 0 status)
            (error "child failed: %s" (with-current-buffer output
                                         (buffer-string)))))
      (kill-buffer output))))

(ert-deftest nl-agent-training-protocol-rejects-invalid-keysets ()
  (let* ((request (nl-agent-training-test--request))
         (result (nl-agent-training-test--result request)))
    (should-error
     (nl-agent-training-protocol-validate-request
      (append request '(:format "duplicate"))))
    (should-error
     (nl-agent-training-protocol-validate-request
      (nl-agent-training-test--without-key request :job-id)))
    (should-error
     (nl-agent-training-protocol-validate-request
      (append request '(:surprise t))))
    (should-error
     (nl-agent-training-protocol-validate-request
      (plist-put (copy-sequence request) :payload
                 '(:examples ["ab"] :examples ["cd"]))))
    (should-error
     (nl-agent-training-protocol-validate-result
      (nl-agent-training-test--without-key result :score) request))
    (should-error
     (nl-agent-training-protocol-validate-result
      (append result '(:surprise t)) request))))

(ert-deftest nl-agent-training-protocol-reuses-canonical-trajectory-bounds ()
  (let ((request (nl-agent-training-test--request)))
    (should-error
     (nl-agent-training-protocol-validate-request
      (plist-put (copy-sequence request) :payload '(:examples ["a"]))))
    (should-error
     (nl-agent-training-protocol-validate-request
      (plist-put (copy-sequence request) :benchmark [])))
    (let ((gpu (plist-put (copy-sequence request) :training
                          '(:backend gpu :sequence 2 :optimizer adam))))
      (should-error
       (nl-agent-training-protocol-validate-request
        (plist-put gpu :payload '(:examples ["abc"])))))))

(ert-deftest nl-agent-training-protocol-reader-is-data-only-and-exactly-one-form ()
  (let ((file (make-temp-file "nl-training-request-")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "(:ok t)\n\t"))
          (should (equal (nl-agent-training-protocol-read file) '(:ok t)))
          (with-temp-file file (insert "(:ok t) (:bad t)"))
          (should-error (nl-agent-training-protocol-read file))
          (setq nl-agent-training-test--read-eval-fired nil)
          (with-temp-file file
            (insert "#.(setq nl-agent-training-test--read-eval-fired t)"))
          (should-error (nl-agent-training-protocol-read file))
          (should-not nl-agent-training-test--read-eval-fired))
      (delete-file file))))

(ert-deftest nl-agent-training-protocol-rejects-non-finite-score-and-tensors ()
  (let ((request (nl-agent-training-test--request)))
    (dolist (bad (list 0.0e+NaN 1.0e+INF -1.0e+INF))
      (let ((result (nl-agent-training-test--result request)))
        (should-error
         (nl-agent-training-protocol-validate-result
          (plist-put result :score bad) request)))
      (let* ((checkpoint (nl-agent-training-test--checkpoint))
             (data (photon-tensor-data (plist-get checkpoint :wte))))
        (aset data 0 bad)
        (should-error (nl-agent-training-protocol-import checkpoint))
        (should-error
         (nl-agent-training-protocol-validate-request
          (nl-agent-training-test--request 'cpu 'sgd checkpoint)))))))

(ert-deftest nl-agent-training-protocol-import-is-detached-trainable-pav ()
  (let* ((checkpoint (nl-agent-training-test--checkpoint))
         (source (plist-get checkpoint :wte))
         (source-first (aref (photon-tensor-data source) 0))
         (model (nl-agent-training-protocol-import checkpoint))
         (imported (plist-get model :wte)))
    (should (cl-every #'pav-p
                      (nl-agent-training-protocol--model-tensors model)))
    (should-not (eq source (pav-value imported)))
    (should-not (eq (photon-tensor-data source)
                    (photon-tensor-data (pav-value imported))))
    (should (vectorp (photon-tensor-data (pav-grad imported))))
    (should-not (pav-backward imported))
    (aset (photon-tensor-data (pav-value imported)) 0 (+ source-first 1.0))
    (should (= source-first (aref (photon-tensor-data source) 0)))))

(ert-deftest nl-agent-training-protocol-result-matches-attempt-and-architecture ()
  (let* ((request (nl-agent-training-test--request))
         (result (nl-agent-training-test--result request)))
    (should-error
     (nl-agent-training-protocol-validate-result
      (plist-put (copy-sequence result) :attempt "other") request))
    (should-error
     (nl-agent-training-protocol-validate-result
      (plist-put (copy-sequence result) :model
                 (nl-agent-training-test--checkpoint 8 4))
      request))))

(ert-deftest nl-agent-training-protocol-write-is-private-and-full-precision ()
  (let ((file (make-temp-file "nl-training-result-"))
        (value '(:format "x" :score 1.2345678901234567)))
    (unwind-protect
        (let ((float-output-format "%.3f"))
          (nl-agent-training-protocol-write file value)
          (should (equal (file-modes file) #o600))
          (should (equal (nl-agent-training-protocol-read file) value))
          (should (equal (length (nl-agent-training-protocol-hash file)) 64)))
      (delete-file file))))

(ert-deftest nl-agent-training-worker-real-child-cpu-training ()
  "The child CPU worker must improve its score and change exact weights."
  (let* ((tmp (make-temp-file "nl-training-child-" t))
         (request-file (expand-file-name "request.sexp" tmp))
         (result-file (expand-file-name "result.sexp" tmp))
         (request (nl-agent-training-test--request))
         (checkpoint (plist-get request :parent-model))
         (before-weights (nl-agent-training-test--parameter-data checkpoint))
         (before-score
          (funcall (nl-llm-agent-evolve-p5-evaluator
                    (plist-get request :benchmark))
                   (nl-agent-training-protocol-import checkpoint))))
    (unwind-protect
        (progn
          (nl-agent-training-test--run-child
           request request-file result-file)
          (let* ((out (nl-agent-training-protocol-read result-file))
                 (after (plist-get out :model)))
            (nl-agent-training-protocol-validate-result out request)
            (should (file-regular-p result-file))
            (should (equal (file-modes request-file) #o600))
            (should (equal (file-modes result-file) #o600))
            (should (> (plist-get out :score) before-score))
            (should
             (nl-agent-training-test--parameters-changed-p
              before-weights
              (nl-agent-training-test--parameter-data after)))))
      (delete-directory tmp t))))

(ert-deftest nl-agent-training-worker-real-child-gpu-adam-smoke ()
  "Run a tiny child GPU Adam update, or explicitly skip without Vulkan."
  (unless (nl-llm-gpu-enable)
    (ert-skip "GPU backend unavailable"))
  (nl-llm-gpu-disable)
  (let* ((tmp (make-temp-file "nl-training-gpu-child-" t))
         (request-file (expand-file-name "request.sexp" tmp))
         (result-file (expand-file-name "result.sexp" tmp))
         (request (nl-agent-training-test--request 'gpu 'adam))
         (before (nl-agent-training-test--parameter-data
                  (plist-get request :parent-model))))
    (setf (plist-get (plist-get request :training) :sequence) 2)
    (unwind-protect
        (progn
          (nl-agent-training-test--run-child request request-file result-file)
          (let ((result (nl-agent-training-protocol-read result-file)))
            (nl-agent-training-protocol-validate-result result request)
            (should
             (nl-agent-training-test--parameters-changed-p
              before
              (nl-agent-training-test--parameter-data
               (plist-get result :model))))))
      (ignore-errors (nl-llm-gpu-disable))
      (delete-directory tmp t))))

(provide 'training-worker-test)
