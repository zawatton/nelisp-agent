;;; task-promotion-test.el --- native task promotion gate tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name "../lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-llm/lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-photon/lisp" here)))
(require 'nl-agent-task-promotion)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-improve)
(require 'photon-tensor)

(defun nl-agent-task-promotion-test--suite ()
  "Return four small host-scored cases."
  (nl-agent-task-eval--suite
   (list :id "promotion-suite" :version "1"
         :cases
         [(:id "keep-a" :task "keep-a"
           :files [(:path "a.txt" :text "before")]
           :expected [(:path "a.txt" :text "after")])
          (:id "keep-b" :task "keep-b"
           :files [(:path "b.txt" :text "before")]
           :expected [(:path "b.txt" :text "after")])
          (:id "new-c" :task "new-c"
           :files [(:path "c.txt" :text "before")]
           :expected [(:path "c.txt" :text "after")])
          (:id "new-d" :task "new-d"
           :files [(:path "d.txt" :text "before")]
           :expected [(:path "d.txt" :text "after")])])))

(defun nl-agent-task-promotion-test--model ()
  "Return a tiny trainable native model."
  (nl-llm-agent-improve-model 2 2 96 1 1))

(defun nl-agent-task-promotion-test--model-digest (model)
  "Return a stable digest of trainable MODEL weights."
  (secure-hash 'sha256 (prin1-to-string
                        (nl-llm-agent-artifact-export-pav model))))

(defun nl-agent-task-promotion-test--write-expected (suite task workspace)
  "Write TASK's expected files into WORKSPACE."
  (let ((case
         (cl-find-if (lambda (candidate)
                       (equal task (plist-get candidate :task)))
                     (append (plist-get suite :cases) nil))))
    (dolist (entry (append (plist-get case :expected) nil))
      (let ((path (expand-file-name (plist-get entry :path) workspace)))
        (make-directory (file-name-directory path) t)
        (with-temp-file path
          (insert (plist-get entry :text)))))))

(defun nl-agent-task-promotion-test--fake-report
    (suite model-id max-steps passing)
  "Return a valid host report passing case IDs in PASSING."
  (nl-agent-task-eval-run
   suite
   (lambda (task workspace _steps)
     (when (member task passing)
       (nl-agent-task-promotion-test--write-expected suite task workspace))
     (list :status 'done :steps 1 :result nil :messages nil :trajectory nil))
   :model-id model-id
   :runner-id nl-agent-task-eval-service-runner-id
   :max-steps max-steps))

(defun nl-agent-task-promotion-test--infrastructure-report
    (suite model-id max-steps)
  "Return a valid report containing a callback-error case."
  (nl-agent-task-eval-run
   suite
   (lambda (&rest _args) (error "fixture callback failure"))
   :model-id model-id
   :runner-id nl-agent-task-eval-service-runner-id
   :max-steps max-steps))

(defmacro nl-agent-task-promotion-test--with-fake-service
    (before-passing after-passing &rest body)
  "Run BODY with deterministic fake BEFORE and AFTER service reports."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'nl-agent-task-eval-service-run)
              (lambda (suite _registry model-id &rest keys)
                (nl-agent-task-promotion-test--fake-report
                 suite model-id (plist-get keys :max-steps)
                 (if (equal model-id "native/before")
                     ,before-passing
                   ,after-passing)))))
     ,@body))

(ert-deftest nl-agent-task-promotion-accepts-positive-delta-without-regression ()
  (let ((before (nl-agent-task-promotion-test--model))
        (after (nl-agent-task-promotion-test--model))
        (suite (nl-agent-task-promotion-test--suite))
        before-digest after-digest)
    (setq before-digest (nl-agent-task-promotion-test--model-digest before)
          after-digest (nl-agent-task-promotion-test--model-digest after))
    (nl-agent-task-promotion-test--with-fake-service
        '("keep-a" "keep-b") '("keep-a" "keep-b" "new-c")
      (let ((result
             (nl-agent-task-promotion-evaluate
              before after suite '(:type "done" :length 1))))
        (should (eq (plist-get result :accepted) t))
        (should (= (plist-get (plist-get result :comparison) :passed-delta) 1))
        (should (= (plist-get (plist-get result :before) :passed) 2))
        (should (= (plist-get (plist-get result :after) :passed) 3))
        (should (equal (plist-get result :grammar)
                       '(:type "done" :length 1)))
        (should (= (plist-get result :max-sequence) 4096))
        (should (= (plist-get result :max-steps) 3))
        (should (equal (plist-get result :before-model-sha256)
                       before-digest))
        (should (equal (plist-get result :after-model-sha256)
                       after-digest))
        (should (stringp (plist-get result :before-model-sha256)))
        (should (stringp (plist-get result :after-model-sha256))))
    (should (equal before-digest
                   (nl-agent-task-promotion-test--model-digest before)))
    (should (equal after-digest
                   (nl-agent-task-promotion-test--model-digest after)))
    (let ((changed (nl-agent-task-promotion-test--model)))
      (aset (photon-tensor-data (pav-value (plist-get changed :wte)))
            0 0.25)
      (should-not (equal after-digest
                         (nl-agent-task-promotion-test--model-digest changed)))))))

(ert-deftest nl-agent-task-promotion-rejects-regression-after-aggregate-gain ()
  (let ((before (nl-agent-task-promotion-test--model))
        (after (nl-agent-task-promotion-test--model))
        (suite (nl-agent-task-promotion-test--suite)))
    (nl-agent-task-promotion-test--with-fake-service
        '("keep-a" "keep-b") '("keep-b" "new-c" "new-d")
      (should-not
       (plist-get
        (nl-agent-task-promotion-evaluate
         before after suite '(:type "done" :length 1))
        :accepted)))))

(ert-deftest nl-agent-task-promotion-rejects-equal-and-infrastructure-failure ()
  (let ((before (nl-agent-task-promotion-test--model))
        (after (nl-agent-task-promotion-test--model))
        (suite (nl-agent-task-promotion-test--suite))
        (calls 0))
    (nl-agent-task-promotion-test--with-fake-service
        '("keep-a" "keep-b") '("keep-a" "keep-b")
      (should-not
       (plist-get
        (nl-agent-task-promotion-evaluate
         before after suite '(:type "done" :length 1))
        :accepted)))
    (cl-letf (((symbol-function 'nl-agent-task-eval-service-run)
               (lambda (run-suite _registry model-id &rest keys)
                 (setq calls (1+ calls))
                 (if (equal model-id "native/before")
                     (nl-agent-task-promotion-test--fake-report
                      run-suite model-id (plist-get keys :max-steps)
                      '("keep-a" "keep-b"))
                   (nl-agent-task-promotion-test--infrastructure-report
                    run-suite model-id (plist-get keys :max-steps))))))
      ;; A callback-error is infrastructure failure, not a model regression or
      ;; improvement signal.
      (should-error
       (nl-agent-task-promotion-evaluate
        before after suite '(:type "done" :length 1))))
    (should (= calls 2))))

(ert-deftest nl-agent-task-promotion-rejects-infrastructure-before-after-pass ()
  (let ((before (nl-agent-task-promotion-test--model))
        (after (nl-agent-task-promotion-test--model))
        (suite (nl-agent-task-promotion-test--suite)))
    (cl-letf (((symbol-function 'nl-agent-task-eval-service-run)
               (lambda (run-suite _registry model-id &rest keys)
                 (if (equal model-id "native/before")
                     (nl-agent-task-promotion-test--infrastructure-report
                      run-suite model-id (plist-get keys :max-steps))
                   (nl-agent-task-promotion-test--fake-report
                    run-suite model-id (plist-get keys :max-steps)
                    '("keep-a" "keep-b" "new-c"))))))
      (should-error
       (nl-agent-task-promotion-evaluate
        before after suite '(:type "done" :length 1))))))

(ert-deftest nl-agent-task-promotion-rejects-report-binding-tampering ()
  (let ((before (nl-agent-task-promotion-test--model))
        (after (nl-agent-task-promotion-test--model))
        (suite (nl-agent-task-promotion-test--suite)))
    (dolist (mutation
             '((:model-id . "native/wrong")
               (:suite-id . "wrong-suite")
               (:runner-id . "wrong-runner")
               (:suite-sha256 .
                "0000000000000000000000000000000000000000000000000000000000000000")
               (:max-steps . 4)))
      (cl-letf (((symbol-function 'nl-agent-task-eval-service-run)
                 (lambda (run-suite _registry model-id &rest keys)
                   (let ((report
                          (nl-agent-task-promotion-test--fake-report
                           run-suite model-id (plist-get keys :max-steps)
                           '("keep-a" "keep-b" "new-c" "new-d"))))
                     (should (nl-agent-task-eval--validate-report report))
                     (plist-put report (car mutation) (cdr mutation))))))
        ;; Every report remains structurally valid and keeps its case evidence;
        ;; only the binding metadata is changed.
        (let ((condition
               (should-error
                (nl-agent-task-promotion-evaluate
                 before after suite '(:type "done" :length 1)))))
          (should (equal (error-message-string condition)
                         "task promotion report binding mismatch")))))))

(ert-deftest nl-agent-task-promotion-validates-before-side-effects ()
  (let ((model-calls 0) (service-calls 0)
        (model (nl-agent-task-promotion-test--model))
        (suite (nl-agent-task-promotion-test--suite)))
    (cl-letf (((symbol-function 'nl-llm-agent-artifact-export-pav)
               (lambda (&rest _args)
                 (setq model-calls (1+ model-calls))
                 (error "model export should not run")))
              ((symbol-function 'nl-agent-task-eval-service-run)
               (lambda (&rest _args)
                 (setq service-calls (1+ service-calls))
                 (error "service should not run"))))
      (dolist (call
               (list
                (list (plist-put (copy-tree suite t) :cases nil)
                      '(:type "done" :length 1) nil nil)
                (list suite '(:type "bogus" :length 1) nil nil)
                (list suite '(:type "done" :length 1) 0 nil)
                (list suite '(:type "done" :length 1) 4097 nil)
                (list suite '(:type "done" :length 1) nil 0)
                (list suite '(:type "done" :length 1) nil 65)))
        (should-error
         (apply #'nl-agent-task-promotion-evaluate
                model model (car call) (cadr call)
                (append (when (nth 2 call)
                          (list :max-sequence (nth 2 call)))
                        (when (nth 3 call)
                          (list :max-steps (nth 3 call)))))))
      (should (= model-calls 0))
      (should (= service-calls 0)))))

(ert-deftest nl-agent-task-promotion-gate-freezes-inputs ()
  (let* ((suite (nl-agent-task-promotion-test--suite))
         (grammar (list :type (concat "template")
                        :segments (vector (concat "prefix ")
                                          (list :slot (concat "abc")))))
         (expected-suite (copy-tree suite t))
         (gate (nl-agent-task-promotion-gate suite grammar))
         (before (nl-agent-task-promotion-test--model))
         (after (nl-agent-task-promotion-test--model))
         captured-suite captured-grammar captured-keys)
    (cl-letf (((symbol-function 'nl-agent-task-promotion-evaluate)
               (lambda (_before _after frozen-suite frozen-grammar &rest keys)
                 (setq captured-suite frozen-suite
                       captured-grammar frozen-grammar
                       captured-keys keys)
                 '(:accepted t))))
      (setf (plist-get (aref (plist-get suite :cases) 0) :task) "mutated")
      (aset (aref (plist-get grammar :segments) 0) 0 ?X)
      (aset (plist-get (aref (plist-get grammar :segments) 1) :slot) 0 ?X)
      (should (funcall gate before after)))
    (should (equal captured-suite expected-suite))
    (should (equal captured-grammar
                   '(:type "template"
                     :segments ["prefix " (:slot "abc")])) )
    (should-not (eq captured-suite suite))
    (should-not (eq captured-grammar grammar))
    (should-not (eq (aref (plist-get captured-grammar :segments) 0)
                    (aref (plist-get grammar :segments) 0)))
    (should-not (eq (plist-get (aref (plist-get captured-grammar :segments) 1)
                             :slot)
                    (plist-get (aref (plist-get grammar :segments) 1)
                               :slot)))
    (should (equal captured-keys '(:max-sequence 4096 :max-steps 3)))))

(ert-deftest nl-agent-task-promotion-gate-detaches-legacy-allow ()
  (let* ((suite (nl-agent-task-promotion-test--suite))
         (grammar (list :type (concat "done") :length 1
                        :allow (concat "ab")))
         (gate (nl-agent-task-promotion-gate suite grammar))
         captured-grammar)
    (cl-letf (((symbol-function 'nl-agent-task-promotion-evaluate)
               (lambda (_before _after _suite frozen-grammar &rest _keys)
                 (setq captured-grammar frozen-grammar)
                 '(:accepted t))))
      (aset (plist-get grammar :allow) 0 ?z)
      (should (funcall gate nil nil)))
    (should (equal captured-grammar
                   '(:type "done" :length 1 :allow "ab")))
    (should-not (eq captured-grammar grammar))
    (should-not (eq (plist-get captured-grammar :allow)
                    (plist-get grammar :allow)))))

(ert-deftest nl-agent-task-promotion-native-failure-is-rejected ()
  (let* ((model (nl-agent-task-promotion-test--model))
         (suite (nl-agent-task-promotion-test--suite))
         (digest (nl-agent-task-promotion-test--model-digest model)))
    (let ((result
           (nl-agent-task-promotion-evaluate
            model model suite '(:type "done" :length 1))))
      (should-not (plist-get result :accepted))
      (should (= (plist-get (plist-get result :before) :passed) 0))
      (should (= (plist-get (plist-get result :after) :passed) 0))
      (should (equal (plist-get result :before-model-sha256)
                     (plist-get result :after-model-sha256)))
      (should (equal digest
                     (nl-agent-task-promotion-test--model-digest model))))))

(ert-run-tests-batch-and-exit)
