;;; training-lock-test.el --- background training ownership tests -*- lexical-binding: t; -*-

(require 'ert)
(add-to-list 'load-path (expand-file-name "../lisp"))
(add-to-list 'load-path (expand-file-name "../../nelisp-llm/lisp"))
(add-to-list 'load-path (expand-file-name "../../nelisp-photon/lisp"))
(require 'nl-agent-training-runner)

(defun training-lock--queue (file)
  (let ((q (nl-llm-evolve-queue-new
            (nl-llm-evolution-new '(:fitness [0.0]) (lambda (_m) 0))
            :checkpoint-file file)))
    (nl-llm-evolve-queue-register q "set"
     (lambda (_candidate _payload _state) nil))
    (nl-llm-evolve-queue-save q)
    q))

(defun training-lock--profile (directory catalog)
  (list :scope (make-string 64 ?a) :benchmark []
        :training '(:backend cpu :sequence 2 :optimizer sgd)
        :directory directory :catalog-file catalog))

(ert-deftest training-lock-idle-ownership-and-double-stop ()
  (let* ((directory (make-temp-file "training-lock-" t))
         (checkpoint (expand-file-name "queue.sexp" directory))
         (catalog (expand-file-name "catalog.sexp" directory))
         (queue (training-lock--queue checkpoint))
         (runner (nl-agent-training-runner-new
                  queue (training-lock--profile directory catalog))))
    (unwind-protect
        (progn
          (should (file-locked-p checkpoint))
          (should (file-locked-p catalog))
          (nl-agent-training-runner-stop runner)
          (should-not (file-locked-p checkpoint))
          (should-not (file-locked-p catalog))
          (nl-agent-training-runner-stop runner))
      (ignore-errors (nl-agent-training-runner-stop runner))
      (delete-directory directory t))))

(ert-deftest training-lock-duplicate-and-shared-catalog-rollback ()
  (let* ((directory (make-temp-file "training-lock-" t))
         (cp1 (expand-file-name "one.sexp" directory))
         (cp2 (expand-file-name "two.sexp" directory))
         (catalog (expand-file-name "catalog.sexp" directory))
         (q1 (training-lock--queue cp1))
         (q2 (training-lock--queue cp2))
         (p1 (training-lock--profile directory catalog))
         (p2 (training-lock--profile directory catalog))
         (r1 (nl-agent-training-runner-new q1 p1)))
    (unwind-protect
        (progn
          (should-error (nl-agent-training-runner-new q1 p1))
          (should-error (nl-agent-training-runner-new q2 p2))
          (should (file-locked-p cp1))
          (should (file-locked-p catalog))
          (should-not (file-locked-p cp2)))
      (ignore-errors (nl-agent-training-runner-stop r1))
      (delete-directory directory t))))

(ert-deftest training-lock-interrupt-save-failure-retains-locks ()
  (let* ((directory (make-temp-file "training-lock-" t))
         (checkpoint (expand-file-name "queue.sexp" directory))
         (catalog (expand-file-name "catalog.sexp" directory))
         (queue (training-lock--queue checkpoint))
         (runner (nl-agent-training-runner-new
                  queue (training-lock--profile directory catalog))))
    (unwind-protect
        (progn
          (nl-llm-evolve-queue-submit queue "set" nil :id "claimed")
          (let ((claim (nl-llm-evolve-queue-claim queue "claimed")))
            (setf (nl-agent-training-runner-claim runner) claim)
            (cl-letf (((symbol-function 'nl-llm-evolve-queue-save)
                       (lambda (&rest _) (error "injected save failure"))))
              (should-error (nl-agent-training-runner-stop runner)))
            (should (file-locked-p checkpoint))
            (should (file-locked-p catalog))))
      (setf (nl-agent-training-runner-claim runner) nil)
      (ignore-errors (nl-agent-training-runner-stop runner))
      (delete-directory directory t))))

(ert-run-tests-batch-and-exit)

;;; training-lock-test.el ends here
