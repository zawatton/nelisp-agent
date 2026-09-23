;;; training-resume-protocol-test.el --- background resume protocol tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-training-protocol)
(require 'nl-llm-agent-improve)
(require 'nl-llm-agent-artifact)

(defun nl-agent-training-resume-test--model (&optional dim)
  "Return a small raw P5 checkpoint with optional DIM."
  (nl-llm-agent-artifact-export-pav
   (nl-llm-agent-improve-model
    (or dim 4) 4 nl-llm-agent-char-vocab 1 1)))

(defun nl-agent-training-resume-test--without-key (plist omitted)
  "Return PLIST without OMITTED."
  (let ((tail plist) result)
    (while tail
      (let ((key (pop tail)) (value (pop tail)))
        (unless (eq key omitted)
          (setq result (append result (list key value))))))
    result))

(defun nl-agent-training-resume-test--request (&optional backend)
  "Return a valid request for BACKEND, defaulting to resumable GPU Adam."
  (list :format nl-agent-training-protocol-format
        :attempt "attempt-1" :job-id "job-1"
        :parent-generation 3 :parent-score 0.25
        :scope (make-string 64 ?b)
        :payload '(:examples ["ab" "cd"] :lr 0.1 :epochs 2)
        :parent-model (nl-agent-training-resume-test--model)
        :training (if (eq backend 'cpu)
                      '(:backend cpu :sequence 8 :optimizer sgd)
                    '(:backend gpu :sequence 8 :optimizer adam
                      :checkpoint-every 2))
        :benchmark ["ab"]))

(defun nl-agent-training-resume-test--legacy-request-binding (request)
  "Return the pre-tokenizer implementation's raw semantic REQUEST digest."
  (let* ((training (plist-get request :training))
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
                :parent-model (plist-get request :parent-model)
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
    (secure-hash 'sha256 (prin1-to-string semantics))))

(defun nl-agent-training-resume-test--zero-like (tensor)
  "Return a zero tensor with TENSOR's exact shape and data length."
  (photon-tensor
   (copy-sequence (photon-tensor-shape tensor))
   (make-vector (length (photon-tensor-data tensor)) 0.0)))

(defun nl-agent-training-resume-test--optimizer-state (model)
  "Return strict Adam state in the checkpoint's resident parameter order."
  (mapcar
   (lambda (parameter)
     (cons (nl-agent-training-resume-test--zero-like parameter)
           (nl-agent-training-resume-test--zero-like parameter)))
   (reverse
    (nl-llm-agent-training-checkpoint--model-parameters model))))

(defun nl-agent-training-resume-test--state (request)
  "Return a valid checkpoint state bound to REQUEST."
  (let ((model (copy-tree (plist-get request :parent-model))))
    ;; Resumed weights need not equal the parent snapshot.
    (aset (photon-tensor-data (plist-get model :wte)) 0 0.125)
    (plist-put model :step 1)
    (list :format nl-llm-agent-training-checkpoint-format
          :job-id (plist-get request :job-id)
          :payload-digest
          (nl-llm-agent-training-checkpoint-payload-digest
           (plist-get request :payload))
          :scope (plist-get request :scope)
          :parent-generation (plist-get request :parent-generation)
          :parent-score (plist-get request :parent-score)
          :sequence (plist-get (plist-get request :training) :sequence)
          :optimizer 'adam :completed-steps 1 :total-steps 4
          :optimizer-step 1 :model model
          :optimizer-state
          (nl-agent-training-resume-test--optimizer-state model)
          :request-binding
          (nl-agent-training-protocol-request-binding request))))

(ert-deftest nl-agent-training-protocol-canonicalizes-legacy-ascii-tokenizer ()
  (let* ((request (nl-agent-training-resume-test--request 'cpu))
         (explicit (copy-tree (plist-get request :parent-model) t))
         (legacy (copy-tree explicit t)))
    (plist-put legacy :config
               (nl-agent-training-resume-test--without-key
                (plist-get legacy :config) :tokenizer))
    (setq request (plist-put request :parent-model legacy))
    (should (eq (nl-agent-training-protocol-validate-request request)
                request))
    (let ((result
           (list :format nl-agent-training-result-format
                 :attempt (plist-get request :attempt)
                 :request-sha256 (make-string 64 ?a)
                 :score 0.0 :model explicit)))
      (should (eq (nl-agent-training-protocol-validate-result result request)
                  result)))))

(ert-deftest nl-agent-training-request-binding-preserves-legacy-ascii-digest ()
  (let* ((explicit-request (nl-agent-training-resume-test--request 'cpu))
         (legacy-request (copy-tree explicit-request t))
         (legacy-model (plist-get legacy-request :parent-model)))
    (should
     (equal
      (plist-get (plist-get (plist-get explicit-request :parent-model) :config)
                 :tokenizer)
      "ascii-char-v1"))
    (plist-put legacy-model :config
               (nl-agent-training-resume-test--without-key
                (plist-get legacy-model :config) :tokenizer))
    (let ((historical
           (nl-agent-training-resume-test--legacy-request-binding
            legacy-request)))
      (should
       (equal historical
              (nl-agent-training-protocol-request-binding legacy-request)))
      (should
       (equal historical
              (nl-agent-training-protocol-request-binding explicit-request))))
    ;; Digest normalization must not rewrite either persisted request object.
    (should-not
     (plist-member
      (plist-get (plist-get legacy-request :parent-model) :config) :tokenizer))
    (should
     (equal
      (plist-get (plist-get (plist-get explicit-request :parent-model) :config)
                 :tokenizer)
      "ascii-char-v1"))
    (let* ((utf8-request (copy-tree explicit-request t))
           (utf8-model
            (nl-llm-agent-artifact-export-pav
             (nl-llm-agent-improve-model
              4 4 nil 1 1 "utf8-byte-v1"))))
      (plist-put utf8-request :parent-model utf8-model)
      (plist-put utf8-request :payload
                 '(:examples ["日本" "成功"] :lr 0.1 :epochs 2))
      (plist-put utf8-request :benchmark ["評価"])
      (should-not
       (equal
        (nl-agent-training-protocol-request-binding explicit-request)
        (nl-agent-training-protocol-request-binding utf8-request))))))

(defun nl-agent-training-resume-test--envelope (request state hash)
  "Return a progress envelope for REQUEST, STATE, and HASH."
  (list :format nl-agent-training-checkpoint-format
        :attempt (plist-get request :attempt)
        :request-sha256 hash :state state))

(defun nl-agent-training-resume-test--without (plist key)
  "Return PLIST without KEY."
  (let ((tail plist) result)
    (while tail
      (let ((candidate (pop tail)) (value (pop tail)))
        (unless (eq candidate key)
          (setq result (append result (list candidate value))))))
    result))

(ert-deftest nl-agent-training-resume-protocol-accepts-v1-and-valid-resume ()
  (let ((legacy (nl-agent-training-resume-test--request 'cpu)))
    (should (eq legacy
                (nl-agent-training-protocol-validate-request legacy))))
  (let* ((request (nl-agent-training-resume-test--request))
         (state (nl-agent-training-resume-test--state request))
         (hash (make-string 64 ?a))
         (envelope
          (nl-agent-training-resume-test--envelope request state hash)))
    (setq request (append request (list :resume-state state)))
    (should (eq request
                (nl-agent-training-protocol-validate-request request)))
    (let ((plain (nl-agent-training-protocol-validate-resume-state
                  state request)))
      (should-not (plist-member plain :request-binding))
      (should (equal (plist-get plain :job-id) "job-1"))
      (aset (photon-tensor-data (plist-get (plist-get plain :model) :wte))
            0 99.0)
      (should-not
       (= (aref (photon-tensor-data
                 (plist-get (plist-get state :model) :wte)) 0)
          99.0)))
    (should (eq envelope
                (nl-agent-training-protocol-validate-checkpoint
                 envelope request hash)))))

(ert-deftest nl-agent-training-resume-request-binding-survives-wire-roundtrip ()
  (let* ((request (nl-agent-training-resume-test--request))
         (block (car (plist-get (plist-get request :parent-model) :blocks)))
         (shared (plist-get block :bq))
         (file (make-temp-file "nl-training-binding-")))
    ;; The writer expands harmless shared structure because print-circle is nil.
    (plist-put block :bk shared)
    (unwind-protect
        (let ((before (nl-agent-training-protocol-request-binding request)))
          (nl-agent-training-protocol-write file request)
          (let ((after
                 (nl-agent-training-protocol-request-binding
                  (nl-agent-training-protocol-read file))))
            (should (equal before after))))
      (delete-file file))))

(ert-deftest nl-agent-training-resume-protocol-rejects-request-misuse ()
  (let ((gpu (nl-agent-training-resume-test--request))
        (cpu (nl-agent-training-resume-test--request 'cpu)))
    (should-error
     (nl-agent-training-protocol-validate-request
      (append gpu '(:resume-state nil))))
    (should-error
     (nl-agent-training-protocol-validate-request
      (plist-put (copy-tree cpu) :training
                 '(:backend cpu :sequence 8 :optimizer sgd
                   :checkpoint-every 2))))
    (let ((state (nl-agent-training-resume-test--state gpu)))
      (should-error
       (nl-agent-training-protocol-validate-request
        (append cpu (list :resume-state state))))
      (should-error
       (nl-agent-training-protocol-validate-request
        (append
         (plist-put (copy-tree gpu) :training
                    '(:backend gpu :sequence 8 :optimizer adam))
         (list :resume-state state)))))
    (dolist (bad '(0 -1 1000001 1.5 nil))
      (should-error
       (nl-agent-training-protocol-validate-request
        (plist-put (copy-tree gpu) :training
                   (list :backend 'gpu :sequence 8 :optimizer 'adam
                         :checkpoint-every bad)))))))

(ert-deftest nl-agent-training-resume-protocol-rejects-state-keysets ()
  (let* ((request (nl-agent-training-resume-test--request))
         (state (nl-agent-training-resume-test--state request)))
    (should-error
     (nl-agent-training-protocol-validate-resume-state nil request))
    (should-error
     (nl-agent-training-protocol-validate-resume-state
      (append state '(:job-id "duplicate")) request))
    (should-error
     (nl-agent-training-protocol-validate-resume-state
      (append state '(:unknown t)) request))
    (should-error
     (nl-agent-training-protocol-validate-resume-state
      (nl-agent-training-resume-test--without state :optimizer-step)
      request))))

(ert-deftest nl-agent-training-resume-protocol-rejects-binding-mismatch ()
  (let* ((request (nl-agent-training-resume-test--request))
         (state (nl-agent-training-resume-test--state request)))
    (dolist (change
             (list
              (lambda (copy) (plist-put copy :job-id "other-job"))
              (lambda (copy) (plist-put copy :payload-digest
                                        (make-string 64 ?c)))
              (lambda (copy) (plist-put copy :scope (make-string 64 ?d)))
              (lambda (copy) (plist-put copy :parent-generation 4))
              (lambda (copy) (plist-put copy :parent-score 0.5))
              (lambda (copy) (plist-put copy :sequence 16))
              (lambda (copy) (plist-put copy :optimizer 'sgd))
              (lambda (copy) (plist-put copy :total-steps 3))))
      (should-error
       (nl-agent-training-protocol-validate-resume-state
        (funcall change (copy-tree state)) request)))
    (let ((wrong (copy-tree state)))
      (plist-put wrong :model (nl-agent-training-resume-test--model 8))
      (plist-put wrong :optimizer-state
                 (nl-agent-training-resume-test--optimizer-state
                  (plist-get wrong :model)))
      (should-error
       (nl-agent-training-protocol-validate-resume-state wrong request)))
    (dolist (key '(:benchmark :parent-model))
      (let ((changed (copy-tree request)))
        (if (eq key :benchmark)
            (plist-put changed key ["cd"])
          (let ((parent (copy-tree (plist-get changed :parent-model))))
            (aset (photon-tensor-data (plist-get parent :wte)) 0 0.75)
            (plist-put changed key parent)))
        (should-error
         (nl-agent-training-protocol-validate-resume-state state changed))))))

(ert-deftest nl-agent-training-resume-protocol-rejects-optimizer-corruption ()
  (let* ((request (nl-agent-training-resume-test--request))
         (state (nl-agent-training-resume-test--state request))
         (optimizer-state (plist-get state :optimizer-state)))
    (let ((wrong (copy-tree state)))
      (setf (plist-get wrong :optimizer-state)
            (cons (cadr optimizer-state)
                  (cons (car optimizer-state) (cddr optimizer-state))))
      (should-error
       (nl-agent-training-protocol-validate-resume-state wrong request)))
    (let* ((wrong (copy-tree state))
           (tensor (caar (plist-get wrong :optimizer-state)))
           (data (photon-tensor-data tensor)))
      (aset data 0 0.0e+NaN)
      (should-error
       (nl-agent-training-protocol-validate-resume-state wrong request)))
    (let* ((wrong (copy-tree state))
           (tensor (caar (plist-get wrong :optimizer-state))))
      (aset tensor 1 (vector 0.0))
      (should-error
       (nl-agent-training-protocol-validate-resume-state wrong request)))
    (let ((wrong (copy-tree state)))
      (plist-put (plist-get wrong :model) :step 0)
      (should-error
       (nl-agent-training-protocol-validate-resume-state wrong request)))))

(ert-deftest nl-agent-training-resume-protocol-rejects-envelope-tamper ()
  (let* ((request (nl-agent-training-resume-test--request))
         (state (nl-agent-training-resume-test--state request))
         (hash (make-string 64 ?a))
         (envelope
          (nl-agent-training-resume-test--envelope request state hash)))
    (should-error
     (nl-agent-training-protocol-validate-checkpoint
      (plist-put (copy-tree envelope) :attempt "other") request hash))
    (should-error
     (nl-agent-training-protocol-validate-checkpoint
      (plist-put (copy-tree envelope) :request-sha256 (make-string 64 ?f))
      request hash))
    (should-error
     (nl-agent-training-protocol-validate-checkpoint
      envelope request "not-a-hash"))
    (should-error
     (nl-agent-training-protocol-validate-checkpoint
      (append envelope '(:state nil)) request hash))
    (should-error
     (nl-agent-training-protocol-validate-checkpoint
      (nl-agent-training-resume-test--without envelope :state)
      request hash))))

(ert-deftest nl-agent-training-resume-protocol-bounds-validation-and-write ()
  (let* ((request (nl-agent-training-resume-test--request))
         (state (nl-agent-training-resume-test--state request))
         (hash (make-string 64 ?a))
         (envelope
          (nl-agent-training-resume-test--envelope request state hash))
         (directory (make-temp-file "nl-training-size-" t))
         (file (expand-file-name "oversized.sexp" directory)))
    (unwind-protect
        (let ((nl-agent-training-protocol-max-bytes 32))
          (should-error
           (nl-agent-training-protocol-validate-checkpoint
            envelope request hash))
          (should-error
           (nl-agent-training-protocol-write
            file (list :blob (make-string 128 ?x))))
          (should-not (file-exists-p file)))
      (delete-directory directory t))))

(provide 'training-resume-protocol-test)
(ert-run-tests-batch-and-exit)

;;; training-resume-protocol-test.el ends here
