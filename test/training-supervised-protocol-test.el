;;; training-supervised-protocol-test.el --- supervised request wire tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(defconst nl-agent-training-supervised-protocol-test--here
  (file-name-directory (or load-file-name buffer-file-name)))

(let ((here nl-agent-training-supervised-protocol-test--here))
  (load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                          (file-name-directory (or load-file-name buffer-file-name
                                                   default-directory))) nil t)
)

(require 'nl-agent-training-protocol)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-improve)

(defun nl-agent-training-supervised-protocol-test--request
    (&optional kind backend optimizer payload)
  "Return a small valid request, optionally selecting KIND."
  (let ((request
         (list :format nl-agent-training-protocol-format
               :attempt "attempt-1" :job-id "job-1"
               :parent-generation 0 :parent-score 0.0
               :scope (make-string 64 ?a)
               :payload (or payload '(:examples ["ab"] :lr 0.1 :epochs 1))
               :parent-model
               (nl-llm-agent-artifact-export-pav
                (nl-llm-agent-improve-model 4 4 96 1 1))
               :training (list :backend (or backend 'cpu)
                               :sequence 8
                               :optimizer (or optimizer 'sgd))
               :benchmark ["ab"])))
    (if kind (append request (list :kind kind)) request)))

(defun nl-agent-training-supervised-protocol-test--supervised
    (&optional backend optimizer)
  (nl-agent-training-supervised-protocol-test--request
   "supervised-finetune" backend optimizer
   '(:examples [(:prompt "Q:" :completion "A!")]
     :lr 0.1 :epochs 2)))

(ert-deftest nl-agent-training-supervised-protocol-legacy-kind-is-optional ()
  (let* ((legacy
          (nl-agent-training-supervised-protocol-test--request))
         (explicit
          (nl-agent-training-supervised-protocol-test--request
           "trajectory-finetune")))
    (should (eq (nl-agent-training-protocol-validate-request legacy)
                legacy))
    (should (eq (nl-agent-training-protocol-validate-request explicit)
                explicit))
    (should (equal
             (nl-agent-training-protocol-request-binding legacy)
             (nl-agent-training-protocol-request-binding explicit)))))

(ert-deftest nl-agent-training-supervised-protocol-validates-cpu-and-gpu ()
  (dolist (request
           (list
            (nl-agent-training-supervised-protocol-test--supervised
             'cpu 'sgd)
            (nl-agent-training-supervised-protocol-test--supervised
             'gpu 'adam)))
    (should (eq (nl-agent-training-protocol-validate-request request)
                request))))

(ert-deftest nl-agent-training-supervised-protocol-rejects-kind-and-payload-errors ()
  (let ((base (nl-agent-training-supervised-protocol-test--supervised)))
    (dolist (request
             (list
              (nl-agent-training-supervised-protocol-test--request
               'supervised-finetune)
              (plist-put (copy-tree base) :kind 'supervised-finetune)
              (plist-put (copy-tree base) :kind nil)
              (plist-put (copy-tree base) :kind "other-kind")
              (plist-put (copy-tree base) :payload
                         '(:examples ["Q:A"] :lr 0.1 :epochs 1))
              (plist-put (copy-tree base) :payload
                         '(:examples [(:prompt "" :completion "A")]
                           :lr 0.1 :epochs 1))
              (plist-put (copy-tree base) :payload
                         '(:examples [(:prompt "Q" :completion "")]
                           :lr 0.1 :epochs 1))))
      (should-error
       (nl-agent-training-protocol-validate-request request)))))

(ert-deftest nl-agent-training-supervised-protocol-rejects-boundary-and-accepts-checkpoint ()
  (let* ((base (nl-agent-training-supervised-protocol-test--supervised))
         (long
          (plist-put
           (copy-tree base) :payload
           '(:examples [(:prompt "123456789" :completion "A")]
             :lr 0.1 :epochs 1)))
         (string-long (copy-tree long))
         (checkpoint (copy-tree base)))
    (setf (plist-get (plist-get long :training) :backend) 'gpu
          (plist-get (plist-get long :training) :optimizer) 'adam)
    (setf (plist-get (plist-get string-long :training) :backend) "gpu"
          (plist-get (plist-get string-long :training) :optimizer) "adam")
    (setf (plist-get (plist-get checkpoint :training) :checkpoint-every) 2)
    (should-error (nl-agent-training-protocol-validate-request long))
    (should-error (nl-agent-training-protocol-validate-request string-long))
    (setf (plist-get (plist-get checkpoint :training) :backend) 'gpu
          (plist-get (plist-get checkpoint :training) :optimizer) 'adam)
    (should (eq (nl-agent-training-protocol-validate-request checkpoint)
                checkpoint))))

(ert-deftest nl-agent-training-supervised-protocol-rejects-resume-state ()
  (let ((request (copy-tree
                  (nl-agent-training-supervised-protocol-test--supervised))))
    (plist-put request :resume-state '(:unexpected t))
    (should-error (nl-agent-training-protocol-validate-request request))))

(ert-deftest nl-agent-training-supervised-protocol-binding-includes-kind ()
  (let* ((legacy (nl-agent-training-supervised-protocol-test--request))
         (trajectory
          (nl-agent-training-supervised-protocol-test--request
           "trajectory-finetune"))
         (supervised
          (nl-agent-training-supervised-protocol-test--supervised)))
    (should (equal (nl-agent-training-protocol-request-binding legacy)
                   (nl-agent-training-protocol-request-binding trajectory)))
    (should-not (equal (nl-agent-training-protocol-request-binding legacy)
                       (nl-agent-training-protocol-request-binding supervised)))
    (let ((kind-only (plist-put (copy-tree legacy)
                                :kind "supervised-finetune")))
      (should-not (equal (nl-agent-training-protocol-request-binding legacy)
                         (nl-agent-training-protocol-request-binding
                          kind-only))))))

(ert-run-tests-batch-and-exit)
