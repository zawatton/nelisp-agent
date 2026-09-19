;;; file-teacher-forcing-test.el --- tests for bounded teacher forcing -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(defconst nl-agent-file-teacher-forcing-test--here
  (file-name-directory (or load-file-name buffer-file-name)))

(defvar nl-agent-file-teacher-forcing-auto-run)

(declare-function nl-agent-file-teacher-forcing-run
                  "../examples/diagnose-file-teacher-forcing" ())
(declare-function nl-agent-file-teacher-forcing-score
                  "../examples/diagnose-file-teacher-forcing"
                  (prompt-ids completion step-fn grammar))

(let ((here nl-agent-file-teacher-forcing-test--here))
  (add-to-list 'load-path (expand-file-name "../lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-llm/lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-photon/lisp" here))
  (load (expand-file-name
         "../examples/diagnose-file-teacher-forcing.el" here)
        nil nil t))

(defun nl-agent-file-teacher-forcing-test--grammar ()
  "Force A, then allow B or newline, then stop."
  (lambda (prefix)
    (pcase (length prefix)
      (0 '(:force 65))
      (1 '(:allow "B\n"))
      (_ :stop))))

(defun nl-agent-file-teacher-forcing-test--uniform-step (calls)
  "Return a step function with all 256 logits equal to zero."
  (lambda (id)
    (push id (car calls))
    (make-vector 256 0.0)))

(ert-deftest nl-agent-file-teacher-forcing-score-uniform-and-byte-ids ()
  (let* ((calls (list nil))
         (result
          (nl-agent-file-teacher-forcing-score
           '(7) "AB"
           (nl-agent-file-teacher-forcing-test--uniform-step calls)
           (nl-agent-file-teacher-forcing-test--grammar))))
    ;; Full prompt, then gold A and gold B: no off-by-one or sampled feed.
    (should (equal (nreverse (car calls)) '(7 65 66)))
    (should (= (plist-get result :prompt-bytes) 1))
    (should (= (plist-get result :completion-bytes) 2))
    (should (= (plist-get result :unrestricted256-top1-correct) 0))
    (should (= (plist-get result :unrestricted256-top1-total) 2))
    (should (= (plist-get result :grammar-choice-correct) 1))
    (should (= (plist-get result :grammar-choice-total) 1))
    (should (plist-get result :all-choices-correct))
    (should (< (abs (- (plist-get result :nll)
                       (* 2.0 (log 256.0)))) 1.0e-8))))

(ert-deftest nl-agent-file-teacher-forcing-score-feeds-gold-on-choice-error ()
  (let* ((calls nil)
         (step
          (lambda (id)
            (push id calls)
            (let ((logits (make-vector 256 0.0)))
              ;; The second completion distribution prefers C over gold B.
              ;; If the prediction were fed, the final call would be 67.
              (when (= (length calls) 3)
                (aset logits 67 1.0))
              logits)))
         (result
          (nl-agent-file-teacher-forcing-score
           '(7 8) "AB" step
           (lambda (prefix)
             (pcase (length prefix)
               (0 '(:force 65))
               (1 '(:allow "BC"))
               (_ :stop))))))
    (should (equal (nreverse calls) '(7 8 65 66)))
    (should (= (plist-get result :grammar-choice-correct) 0))
    (should (= (plist-get result :grammar-choice-total) 1))
    (should-not (plist-get result :all-choices-correct))
    (let ((wrong (plist-get result :first-wrong-grammar-choice)))
      (should (= (plist-get wrong :index) 1))
      (should (equal (plist-get wrong :expected) "B"))
      (should (equal (plist-get wrong :predicted) "C"))
      (should (equal (plist-get wrong :gold-prefix) "A")))))

(ert-deftest nl-agent-file-teacher-forcing-score-rejects-bad-inputs ()
  (let ((step (lambda (_id) (make-vector 256 0.0))))
    (should-error
     (nl-agent-file-teacher-forcing-score
      nil "A" step (lambda (_prefix) :stop)))
    (should-error
     (nl-agent-file-teacher-forcing-score
      '(1) "é" step (lambda (_prefix) :stop)))
    (should-error
     (nl-agent-file-teacher-forcing-score
      '(1) "A" step (lambda (_prefix) :stop)))
    (should-error
     (nl-agent-file-teacher-forcing-score
      '(1) "A" step (lambda (_prefix) '(:allow "B"))))
    (should-error
     (nl-agent-file-teacher-forcing-score
      '(1) "A" (lambda (_id) (make-vector 255 0.0))
      (lambda (_prefix) '(:force 65))))
    (let ((nan (/ 0.0 0.0))
          (inf (/ 1.0 0.0)))
      (dolist (bad (list nan inf))
        (should-error
         (nl-agent-file-teacher-forcing-score
          '(1) "A"
          (lambda (_id)
            (let ((logits (make-vector 256 0.0)))
              (aset logits 0 bad)
              logits))
          (lambda (_prefix) '(:force 65))))))))

(ert-deftest nl-agent-file-teacher-forcing-load-does-not-run ()
  (let ((called nil)
        (nl-agent-file-teacher-forcing-auto-run nil))
    ;; The example load chain redefines its own runner, so observe a stable
    ;; library primitive instead of an example-defined function.
    (cl-letf (((symbol-function 'nl-llm-gpu-enable)
               (lambda ()
                 (setq called t)
                 (error "load unexpectedly started GPU training"))))
      (load (expand-file-name
             "../examples/diagnose-file-teacher-forcing.el"
             nl-agent-file-teacher-forcing-test--here)
            nil nil t))
    (should-not called)))

(ert-deftest nl-agent-file-teacher-forcing-score-maps-newline-byte ()
  (let ((result
         (nl-agent-file-teacher-forcing-score
          '(7) "A\n"
          (lambda (id)
            (let ((logits (make-vector 256 0.0)))
              (when (= id 65) (aset logits 10 1.0))
              logits))
          (lambda (prefix)
            (pcase (length prefix)
              (0 '(:force 65))
              (1 '(:allow "\n"))
              (_ :stop))))))
    (should (= (plist-get result :grammar-choice-correct) 1))
    (should (= (plist-get result :grammar-choice-total) 1))
    (should (plist-get result :all-choices-correct))))

(defun nl-agent-file-teacher-forcing-test--fake-parts (digest)
  (list :records [] :encoded (list :dataset-sha256 digest)))

(ert-deftest nl-agent-file-teacher-forcing-wrapper-restores-and-checks-digests ()
  (let* ((exporter 'nl-agent-supervised-file-experiment--inference-model)
         (old-exporter (symbol-function exporter))
         (export-calls nil)
         (model (list :model t))
         (original
          (lambda (value id)
            (push (list value id) export-calls)
            :detached)))
    (cl-letf (((symbol-function exporter) original)
              ((symbol-function 'nl-agent-initialized-file-diagnostic-run)
               (lambda ()
                 (funcall exporter model "native")
                 (list :diagnostic
                       (list :dataset-sha256 "data"
                             :trained-sha256 "trained"))))
              ((symbol-function
                'nl-agent-supervised-file-experiment--model-digest)
               (lambda (_model) "trained"))
              ((symbol-function
                'nl-agent-supervised-file-experiment--training-responses)
               (lambda () (cons nil nil)))
              ((symbol-function
                'nl-agent-file-teacher-forcing--records)
               (lambda (_responses) (nl-agent-file-teacher-forcing-test--fake-parts
                                     "data")))
              ((symbol-function
                'nl-agent-file-teacher-forcing--score-records)
               (lambda (_model _records) nil)))
      (let ((report (nl-agent-file-teacher-forcing-run)))
        (should (equal (plist-get report :dataset-sha256) "data"))
        (should (equal (plist-get report :trained-sha256) "trained")))
      (should (eq (symbol-function exporter) original))
      (should (equal (mapcar #'cadr (nreverse export-calls))
                     '("native" "file-teacher-forcing"))))
    (should (eq (symbol-function exporter) old-exporter))))

(ert-deftest nl-agent-file-teacher-forcing-wrapper-restores-on-error ()
  (let* ((exporter 'nl-agent-supervised-file-experiment--inference-model)
         (old-exporter (symbol-function exporter))
         (original (lambda (_model _id) :detached)))
    (cl-letf (((symbol-function exporter) original)
              ((symbol-function 'nl-agent-initialized-file-diagnostic-run)
               (lambda ()
                 (funcall exporter :model "native")
                 (error "intentional diagnostic error"))))
      (should-error (nl-agent-file-teacher-forcing-run)))
    (should (eq (symbol-function exporter) old-exporter))))

(ert-deftest nl-agent-file-teacher-forcing-wrapper-rejects-dataset-mismatch ()
  (let* ((exporter 'nl-agent-supervised-file-experiment--inference-model)
         (old-exporter (symbol-function exporter))
         (original (lambda (_model _id) :detached)))
    (cl-letf (((symbol-function exporter) original)
              ((symbol-function 'nl-agent-initialized-file-diagnostic-run)
               (lambda ()
                 (funcall exporter :model "native")
                 (list :diagnostic
                       (list :dataset-sha256 "base"
                             :trained-sha256 "trained"))))
              ((symbol-function
                'nl-agent-supervised-file-experiment--model-digest)
               (lambda (_model) "trained"))
              ((symbol-function
                'nl-agent-supervised-file-experiment--training-responses)
               (lambda () (cons nil nil)))
              ((symbol-function
                'nl-agent-file-teacher-forcing--records)
               (lambda (_responses)
                 (nl-agent-file-teacher-forcing-test--fake-parts "different"))))
      (should-error (nl-agent-file-teacher-forcing-run)))
    (should (eq (symbol-function exporter) old-exporter))))

(ert-deftest nl-agent-file-teacher-forcing-wrapper-rejects-model-mutation ()
  (let* ((exporter 'nl-agent-supervised-file-experiment--inference-model)
         (old-exporter (symbol-function exporter))
         (original (lambda (_model _id) :detached))
         (model (list :mutated nil)))
    (cl-letf (((symbol-function exporter) original)
              ((symbol-function 'nl-agent-initialized-file-diagnostic-run)
               (lambda ()
                 (funcall exporter model "native")
                 (list :diagnostic
                       (list :dataset-sha256 "data"
                             :trained-sha256 "trained"))))
              ((symbol-function
                'nl-agent-supervised-file-experiment--model-digest)
               (lambda (value)
                 (if (plist-get value :mutated) "changed" "trained")))
              ((symbol-function
                'nl-agent-supervised-file-experiment--training-responses)
               (lambda () (cons nil nil)))
              ((symbol-function
                'nl-agent-file-teacher-forcing--records)
               (lambda (_responses)
                 (nl-agent-file-teacher-forcing-test--fake-parts "data")))
              ((symbol-function
                'nl-agent-file-teacher-forcing--score-records)
               (lambda (_model _records)
                 (setf (plist-get model :mutated) t)
                 nil)))
      (should-error (nl-agent-file-teacher-forcing-run)))
    (should (eq (symbol-function exporter) old-exporter))))

(provide 'file-teacher-forcing-test)

(ert-run-tests-batch-and-exit)

;;; file-teacher-forcing-test.el ends here
