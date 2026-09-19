;;; file-choice-loss-test.el --- tests for file choice-loss comparison -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(defconst nl-agent-file-choice-loss-test--here
  (file-name-directory (or load-file-name buffer-file-name)))

(defvar nl-agent-file-choice-loss-auto-run nil)
(defvar nl-agent-file-teacher-forcing-auto-run nil)
(defvar nl-agent-initialized-file-diagnostic-auto-run nil)
(defvar nl-agent-supervised-file-diagnostic-auto-run nil)

(declare-function nl-agent-file-choice-loss-run
                  "../examples/compare-file-choice-loss" (mode))
(declare-function nl-agent-file-choice-loss--masks
                  "../examples/compare-file-choice-loss"
                  (trajectories loss-starts grammar))
(declare-function nl-agent-file-choice-loss--completion-masks
                  "../examples/compare-file-choice-loss"
                  (trajectories loss-starts))
(declare-function nl-agent-file-choice-loss--mask-digest
                  "../examples/compare-file-choice-loss" (masks))
(declare-function nl-llm-agent-grammar-file-actions
                  "nl-llm-agent-action-grammar" (&optional max-field))
(declare-function nl-agent-supervised-file-experiment--training-responses
                  "evaluate-supervised-file-tasks" ())
(declare-function nl-agent-file-teacher-forcing--records
                  "../examples/diagnose-file-teacher-forcing"
                  (training-responses))
(declare-function nl-llm-agent-supervised-encode
                  "nl-llm-agent-supervised" (records &optional tokenizer))

(let ((here nl-agent-file-choice-loss-test--here))
  (add-to-list 'load-path (expand-file-name "../lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-llm/lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-photon/lisp" here))
  (load (expand-file-name "../examples/compare-file-choice-loss.el" here)
        nil nil t))

(defun nl-agent-file-choice-loss-test--grammar ()
  "Allow A, force B, then allow newline and stop."
  (lambda (prefix)
    (pcase prefix
      ("" '(:allow "A"))
      ("A" '(:force 66))
      ("AB" '(:allow "\n"))
      (_ :stop))))

(defun nl-agent-file-choice-loss-test--trajectory ()
  "Return prompt byte 9 followed by the gold ASCII completion AB newline."
  [9 65 66 10])

(ert-deftest nl-agent-file-choice-loss-masks-selects-noncontiguous-choices ()
  (let* ((trajectories (list (nl-agent-file-choice-loss-test--trajectory)))
         (info
          (nl-agent-file-choice-loss--masks
           trajectories [1] (nl-agent-file-choice-loss-test--grammar)))
         (masks (plist-get info :masks)))
    (should (vectorp masks))
    (should (= (length masks) 1))
    (should (vectorp (aref masks 0)))
    (should (equal (append (aref masks 0) nil) '(0 1 0 1)))
    (should (= (plist-get info :selected-targets) 2))
    (should (= (plist-get info :completion-targets) 3))))

(ert-deftest nl-agent-file-choice-loss-completion-masks-cover-targets-only ()
  (let* ((trajectories (list [7 65 66] [8 67 10]))
         (info
          (nl-agent-file-choice-loss--completion-masks trajectories [1 1]))
         (masks (plist-get info :masks)))
    (should (equal (append (aref masks 0) nil) '(0 1 1)))
    (should (equal (append (aref masks 1) nil) '(0 1 1)))
    (should (= (plist-get info :selected-targets) 4))
    (should (= (plist-get info :completion-targets) 4))))

(ert-deftest nl-agent-file-choice-loss-actual-frozen-training-counts ()
  (let* ((grammar (nl-llm-agent-grammar-file-actions 64))
         (parts
          (nl-agent-file-teacher-forcing--records
           (nl-agent-supervised-file-experiment--training-responses)))
         (records (plist-get parts :records))
         (encoded (plist-get parts :encoded))
         (trajectories (plist-get encoded :trajectories))
         (loss-starts (plist-get encoded :loss-starts))
         (choice
          (nl-agent-file-choice-loss--masks
           trajectories loss-starts grammar))
         (completion
          (nl-agent-file-choice-loss--completion-masks
           trajectories loss-starts)))
    (should (= (length records) 12))
    (should (= (plist-get choice :selected-targets) 281))
    (should (= (plist-get completion :selected-targets) 741))
    (should (= (plist-get choice :completion-targets) 741))
    (should (equal
             (nl-agent-file-choice-loss--mask-digest
              (plist-get choice :masks))
             "052cc27f334ab2e6932084658380d66472d7b3196c8ca7d5d9d0e08bf72e2d43"))
    (should (equal
             (nl-agent-file-choice-loss--mask-digest
              (plist-get completion :masks))
             "313e7b86ca08f1233889c42f8f9bfeec8950f785084d630d3a190926c5f0b47f"))))

(ert-deftest nl-agent-file-choice-loss-rejects-invalid-gold-and-grammar ()
  (let ((grammar (nl-agent-file-choice-loss-test--grammar)))
    (should-error
     (nl-agent-file-choice-loss--masks (list [9 65 67 10]) [1] grammar))
    (should-error
     (nl-agent-file-choice-loss--masks (list [9 65 66 11]) [1] grammar))
    (should-error
     (nl-agent-file-choice-loss--masks (list [9 65 66 10]) [1]
                                       (lambda (_prefix) '(:allow "B"))))
    (should-error
     (nl-agent-file-choice-loss--masks (list [9 200]) [1]
                                       (lambda (_prefix) :stop)))
    (should-error
     (nl-agent-file-choice-loss--masks (list [9 65 66 10]) [2]
                                       (lambda (_prefix) :stop)))))

(defun nl-agent-file-choice-loss-test--mock-helper-bindings ()
  "Return deterministic helper substitutions for wrapper forwarding tests."
  (list
   (list 'nl-agent-file-choice-loss--masks
         (lambda (_trajectories _starts _grammar)
           (list :masks (vector (vector 0 1))
                 :selected-targets 1 :completion-targets 2)))
   (list 'nl-agent-file-choice-loss--completion-masks
         (lambda (_trajectories _starts)
           (list :masks (vector (vector 0 1))
                 :selected-targets 2 :completion-targets 2)))))

(ert-deftest nl-agent-file-choice-loss-wrapper-forwards-completion-call ()
  (let* ((trajectory (vector 7 65))
         (starts (vector 1))
         (callback (lambda (&rest _args) 'callback))
         (calls nil)
         (diagnostic (list :format 'frozen :full-report t))
         (original-train (symbol-function 'nl-llm-agent-ondevice-train))
         (original-masks (symbol-function 'nl-agent-file-choice-loss--masks))
         (original-completion-masks
          (symbol-function 'nl-agent-file-choice-loss--completion-masks))
         result)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'nl-llm-agent-ondevice-train)
                     (lambda (&rest args)
                       (push args calls)
                       'train-result))
                    ((symbol-function 'nl-agent-file-teacher-forcing-run)
                     (lambda ()
                       (funcall 'nl-llm-agent-ondevice-train
                                'ctx (list trajectory) 2
                                :start-step 0 :after-step callback
                                :loss-starts starts :shuffle-seed 123)
                       diagnostic)))
            (dolist (binding
                     (nl-agent-file-choice-loss-test--mock-helper-bindings))
              (setf (symbol-function (car binding)) (cadr binding)))
            (setq result (nl-agent-file-choice-loss-run 'completion)))
          (let ((arguments (car calls)))
            (should (= (length calls) 1))
            (should (equal arguments
                           (list 'ctx (list trajectory) 2
                                 :start-step 0 :after-step callback
                                 :loss-starts starts :shuffle-seed 123)))
            (should-not (plist-member arguments :loss-masks)))
          (should (eq (plist-get result :diagnostic) diagnostic))
          (should (eq (plist-get result :loss-selection) 'completion))
          (should (= (plist-get result :selected-targets) 2))
          (should (= (plist-get result :completion-targets) 2))
          (should (= (plist-get result :training-call-count) 1)))
      (fset 'nl-llm-agent-ondevice-train original-train)
      (fset 'nl-agent-file-choice-loss--masks original-masks)
      (fset 'nl-agent-file-choice-loss--completion-masks
            original-completion-masks))))

(ert-deftest nl-agent-file-choice-loss-wrapper-appends-grammar-mask-once ()
  (let* ((trajectory (vector 7 65))
         (starts (vector 1))
         (callback (lambda (&rest _args) 'callback))
         (calls nil)
         (diagnostic (list :format 'frozen :full-report t))
         (original-train (symbol-function 'nl-llm-agent-ondevice-train))
         (original-masks (symbol-function 'nl-agent-file-choice-loss--masks))
         (original-completion-masks
          (symbol-function 'nl-agent-file-choice-loss--completion-masks))
         result)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'nl-llm-agent-ondevice-train)
                     (lambda (&rest args) (push args calls) 'train-result))
                    ((symbol-function 'nl-agent-file-teacher-forcing-run)
                     (lambda ()
                       (funcall 'nl-llm-agent-ondevice-train
                                'ctx (list trajectory) 2
                                :start-step 0 :after-step callback
                                :loss-starts starts :shuffle-seed 123)
                       diagnostic)))
            (dolist (binding
                     (nl-agent-file-choice-loss-test--mock-helper-bindings))
              (setf (symbol-function (car binding)) (cadr binding)))
            (setq result (nl-agent-file-choice-loss-run 'grammar-choice)))
          (let ((arguments (car calls)))
            (should (= (length calls) 1))
            (let ((keywords (nthcdr 3 arguments)))
              (should (eq (plist-get keywords :after-step) callback))
              (should (equal (plist-get keywords :loss-starts) starts))
              (should (equal (plist-get keywords :shuffle-seed) 123))
              (should (equal (plist-get keywords :loss-masks)
                             (vector (vector 0 1))))))
          (should (eq (plist-get result :diagnostic) diagnostic))
          (should (eq (plist-get result :loss-selection) 'grammar-choice))
          (should (= (plist-get result :selected-targets) 1))
          (should (= (plist-get result :completion-targets) 2)))
      (fset 'nl-llm-agent-ondevice-train original-train)
      (fset 'nl-agent-file-choice-loss--masks original-masks)
      (fset 'nl-agent-file-choice-loss--completion-masks
            original-completion-masks))))

(ert-deftest nl-agent-file-choice-loss-wrapper-restores-on-error ()
  (let* ((original (symbol-function 'nl-llm-agent-ondevice-train))
         (called nil))
    (cl-letf (((symbol-function 'nl-llm-agent-ondevice-train)
               (lambda (&rest _args) (setq called t)))
              ((symbol-function 'nl-agent-file-teacher-forcing-run)
               (lambda () (error "intentional frozen-runner failure"))))
      (should-error (nl-agent-file-choice-loss-run 'completion)))
    (should-not called)
    (should (eq original (symbol-function 'nl-llm-agent-ondevice-train)))))

(ert-deftest nl-agent-file-choice-loss-rejects-existing-mask-and-mode ()
  (should-error (nl-agent-file-choice-loss-run nil))
  (let ((original (symbol-function 'nl-llm-agent-ondevice-train)))
    (cl-letf (((symbol-function 'nl-agent-file-teacher-forcing-run)
               (lambda ()
                 (funcall 'nl-llm-agent-ondevice-train
                          'ctx '([7 65]) 1 :loss-starts [1]
                          :loss-masks (vector (vector 1)))))
              ((symbol-function 'nl-llm-agent-ondevice-train)
               (lambda (&rest _args) (error "must reject before train"))))
      (should-error (nl-agent-file-choice-loss-run 'grammar-choice)))
    (should (eq original (symbol-function 'nl-llm-agent-ondevice-train)))))

(ert-run-tests-batch-and-exit)

;;; file-choice-loss-test.el ends here
