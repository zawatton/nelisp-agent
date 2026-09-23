;;; initialized-file-diagnostic-test.el --- tests for deterministic diagnostic -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(defconst nl-agent-initialized-file-diagnostic-test--here
  (file-name-directory (or load-file-name buffer-file-name)))

(defvar nl-agent-initialized-file-diagnostic-auto-run nil)
(defvar nl-agent-supervised-file-diagnostic-auto-run nil)

(let ((here nl-agent-initialized-file-diagnostic-test--here))
  (load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                          (file-name-directory (or load-file-name buffer-file-name
                                                   default-directory))) nil t)
  (load (expand-file-name "../examples/diagnose-initialized-file-tasks.el" here)
        nil nil t))

(declare-function nl-agent-initialized-file-diagnostic-run
                  "../examples/diagnose-initialized-file-tasks" ())
(declare-function nl-agent-initialized-file-diagnostic--file-sha256
                  "../examples/diagnose-initialized-file-tasks" (path))
(declare-function nl-llm-agent--p5-params "nl-llm-agent-improve" (model))
(declare-function nl-llm-agent-improve-model
                  "nl-llm-agent-improve"
                  (&optional dim ff vocab nblocks heads tokenizer))
(declare-function nl-llm-agent-initialization-create
                  "nl-llm-agent-initialization"
                  (&rest keys))
(declare-function pav-value "photon-autograd" (parameter))
(declare-function photon-tensor-data "photon-tensor" (tensor))

(defun nl-agent-initialized-file-diagnostic-test--signature (model)
  (mapcar
   (lambda (parameter)
     (copy-sequence (photon-tensor-data (pav-value parameter))))
   (nl-llm-agent--p5-params model)))

(defun nl-agent-initialized-file-diagnostic-test--source ()
  (expand-file-name
   "../examples/diagnose-supervised-file-tasks.el"
   nl-agent-initialized-file-diagnostic-test--here))

(ert-deftest nl-agent-initialized-file-diagnostic-source-guard-is-byte-exact ()
  (should
   (equal
    (nl-agent-initialized-file-diagnostic--file-sha256
     (nl-agent-initialized-file-diagnostic-test--source))
    "a400847d318e81ff7219ec77a05db07a1dd16137584521e2ccf19be4bee0d2ba")))

(ert-deftest nl-agent-initialized-file-diagnostic-forwards-geometry-and-seed ()
  (let (arguments)
    (cl-letf (((symbol-function 'nl-agent-supervised-file-diagnostic-run)
               (lambda ()
                 (funcall 'nl-llm-agent-improve-model
                          2 2 256 1 1 "utf8-byte-v1")
                 '(:status ok)))
              ((symbol-function 'nl-llm-agent-initialization-create)
               (lambda (&rest args)
                 (setq arguments args)
                 :initialized-model)))
      (let ((report (nl-agent-initialized-file-diagnostic-run)))
        (should (equal arguments
                       '(:initializer xorshift32 :seed 439041101
                         :dim 2 :ff 2 :vocab 256 :nblocks 1 :heads 1
                         :tokenizer "utf8-byte-v1")))
        (should (eq (plist-get report :initializer) 'xorshift32))
        (should (= (plist-get report :seed) #x1A2B3C4D))
        (should (= (plist-get report :constructor-count) 1))
        (should (equal (plist-get report :diagnostic) '(:status ok)))))))

(ert-deftest nl-agent-initialized-file-diagnostic-model-matches-direct-api ()
  (let (constructed)
    (cl-letf (((symbol-function 'nl-agent-supervised-file-diagnostic-run)
               (lambda ()
                 (setq constructed
                       (funcall 'nl-llm-agent-improve-model
                                2 2 256 1 1 "utf8-byte-v1"))
                 '(:status ok))))
      (nl-agent-initialized-file-diagnostic-run))
    (let ((direct (nl-llm-agent-initialization-create
                   :initializer 'xorshift32 :seed #x1A2B3C4D
                   :dim 2 :ff 2 :vocab 256 :nblocks 1 :heads 1
                   :tokenizer "utf8-byte-v1")))
      (should
       (equal
        (nl-agent-initialized-file-diagnostic-test--signature constructed)
        (nl-agent-initialized-file-diagnostic-test--signature direct))))))

(ert-deftest nl-agent-initialized-file-diagnostic-restores-constructor-on-success ()
  (let* ((constructor 'nl-llm-agent-improve-model)
         (original (symbol-function constructor)))
    (cl-letf (((symbol-function 'nl-agent-supervised-file-diagnostic-run)
               (lambda ()
                 (funcall constructor 2 2 256 1 1 "utf8-byte-v1")
                 '(:status ok))))
      (should (= (plist-get (nl-agent-initialized-file-diagnostic-run)
                            :constructor-count)
                 1)))
    (should (eq original (symbol-function constructor)))))

(ert-deftest nl-agent-initialized-file-diagnostic-restores-constructor-on-error ()
  (let* ((constructor 'nl-llm-agent-improve-model)
         (original (symbol-function constructor)))
    (cl-letf (((symbol-function 'nl-agent-supervised-file-diagnostic-run)
               (lambda ()
                 (funcall constructor 2 2 256 1 1 "utf8-byte-v1")
                 (error "intentional diagnostic failure"))))
      (should-error (nl-agent-initialized-file-diagnostic-run)))
    (should (eq original (symbol-function constructor)))))

(ert-deftest nl-agent-initialized-file-diagnostic-rejects-zero-constructor-calls ()
  (cl-letf (((symbol-function 'nl-agent-supervised-file-diagnostic-run)
             (lambda () '(:status ok))))
    (should-error (nl-agent-initialized-file-diagnostic-run))))

(ert-deftest nl-agent-initialized-file-diagnostic-rejects-multiple-constructor-calls ()
  (let* ((constructor 'nl-llm-agent-improve-model)
         (original (symbol-function constructor)))
    (cl-letf (((symbol-function 'nl-agent-supervised-file-diagnostic-run)
               (lambda ()
                 (funcall constructor 2 2 256 1 1 "utf8-byte-v1")
                 (funcall constructor 2 2 256 1 1 "utf8-byte-v1"))))
      (should-error (nl-agent-initialized-file-diagnostic-run)))
    (should (eq original (symbol-function constructor)))))

(ert-deftest nl-agent-initialized-file-diagnostic-load-does-not-run-gpu ()
  (let ((called nil)
        (nl-agent-initialized-file-diagnostic-auto-run nil))
    (cl-letf (((symbol-function 'nl-llm-gpu-enable)
               (lambda () (setq called t)))
              ((symbol-function 'nl-agent-supervised-file-diagnostic-run)
               (lambda () (setq called t))))
      (load (expand-file-name
             "../examples/diagnose-initialized-file-tasks.el"
             nl-agent-initialized-file-diagnostic-test--here)
            nil nil t))
    (should-not called)))

(provide 'initialized-file-diagnostic-test)

(ert-run-tests-batch-and-exit)

;;; initialized-file-diagnostic-test.el ends here
