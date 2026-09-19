;;; supervised-file-experiment-test.el --- fixed probe preflight tests -*- lexical-binding: t; -*-

(require 'ert)

(defvar nl-agent-supervised-file-experiment-auto-run nil)
(defvar nl-agent-supervised-file-experiment-grammar)
(defvar nl-agent-supervised-file-experiment-dim)
(defvar nl-agent-supervised-file-experiment-ff)
(defvar nl-agent-supervised-file-experiment-blocks)
(defvar nl-agent-supervised-file-experiment-heads)
(defvar nl-agent-supervised-file-experiment-sequence)
(defvar nl-agent-supervised-file-experiment-epochs)
(defvar nl-agent-supervised-file-experiment-maxseq)
(defvar nl-agent-supervised-file-experiment-maxsteps)
(defvar nl-agent-supervised-file-experiment-format)

(declare-function nl-agent-supervised-file-experiment--training-responses
                  "../examples/evaluate-supervised-file-tasks" ())
(declare-function nl-agent-supervised-file-experiment--records
                  "../examples/evaluate-supervised-file-tasks"
                  (responses grammar))
(declare-function nl-agent-supervised-file-experiment--grammar-accepts-p
                  "../examples/evaluate-supervised-file-tasks"
                  (grammar output))
(declare-function nl-agent-supervised-file-experiment--parameter-count
                  "../examples/evaluate-supervised-file-tasks" (model))
(declare-function nl-agent-supervised-file-experiment--model-digest
                  "../examples/evaluate-supervised-file-tasks" (model))
(declare-function nl-agent-supervised-file-experiment--inference-model
                  "../examples/evaluate-supervised-file-tasks" (model id))
(declare-function nl-agent-supervised-file-experiment--native-registry
                  "../examples/evaluate-supervised-file-tasks"
                  (before after grammar))
(declare-function nl-agent-supervised-file-experiment--evaluate
                  "../examples/evaluate-supervised-file-tasks"
                  (suite registry qualified-model))

(let ((noninteractive nil))
  (load
   (expand-file-name
    "../examples/evaluate-supervised-file-tasks.el"
    (file-name-directory (or load-file-name buffer-file-name)))
   nil nil t))

(ert-deftest nl-agent-supervised-file-experiment-fixed-plan-is-real-and-bounded ()
  (let* ((grammar (nl-llm-agent-grammar-file-actions 64))
         (training
          (nl-agent-supervised-file-experiment--training-responses))
         (responses (cdr training))
         (records
          (nl-agent-supervised-file-experiment--records responses grammar))
         (encoded
          (nl-llm-agent-supervised-encode records "utf8-byte-v1"))
         (trajectories (plist-get encoded :trajectories)))
    (should (= (plist-get (car training) :passed) 4))
    (should (= (plist-get (car training) :total) 4))
    (should (= (length responses) 4))
    (should (= (length records) 12))
    (should
     (equal (plist-get encoded :dataset-sha256)
            "1c2536d677b6280cc34a010cec6573ed9e43c342885aa2e99f99fe4df16a1a42"))
    (should
     (cl-every
      (lambda (trajectory)
        (<= (length trajectory)
            nl-agent-supervised-file-experiment-sequence))
      trajectories))
    (should (= (apply #'max (mapcar #'length trajectories)) 1476))
    ;; The second and third records contain observations produced by actual
    ;; read/edit tools in the runtime loop, not strings assembled by this probe.
    (should
     (string-search
      "user: OBSERVATION:\nstatus: old\n"
      (plist-get (aref records 1) :prompt)))
    (should
     (string-search
      "user: OBSERVATION:\nedit applied to train/status.txt"
      (plist-get (aref records 2) :prompt)))
    (dotimes (index (length records))
      (should
       (nl-agent-supervised-file-experiment--grammar-accepts-p
        grammar (plist-get (aref records index) :completion))))))

(ert-deftest nl-agent-supervised-file-experiment-model-identity-is-fixed ()
  (let* ((base
          (nl-llm-agent-improve-model
           nl-agent-supervised-file-experiment-dim
           nl-agent-supervised-file-experiment-ff 256
           nl-agent-supervised-file-experiment-blocks
           nl-agent-supervised-file-experiment-heads "utf8-byte-v1"))
         (copy (nl-llm-evolve-copy-model base)))
    (should
     (= (nl-agent-supervised-file-experiment--parameter-count base) 27264))
    (should
     (equal
      (nl-agent-supervised-file-experiment--model-digest base)
      (nl-agent-supervised-file-experiment--model-digest copy)))
    (should (equal nl-agent-supervised-file-experiment-grammar
                   '(:type "file-actions-v1" :max-field 64)))
    (should (equal nl-agent-supervised-file-experiment-format
                   "nl-agent-supervised-file-experiment-v2"))
    (should (= nl-agent-supervised-file-experiment-sequence 2048))
    (should (= nl-agent-supervised-file-experiment-epochs 16))
    (should (= nl-agent-supervised-file-experiment-maxseq 4096))
    (should (= nl-agent-supervised-file-experiment-maxsteps 3))))

(ert-deftest nl-agent-supervised-file-experiment-exported-model-runs-service ()
  ;; This is a real unforced native completion through the same confined file
  ;; service used by heldout evaluation.  Its score is irrelevant; it must not
  ;; collapse an inference wiring failure into an ordinary score of zero.
  (let* ((nl-agent-supervised-file-experiment-maxseq 2048)
         (nl-agent-supervised-file-experiment-maxsteps 1)
         (trainable
          (nl-llm-agent-improve-model 2 2 256 1 1 "utf8-byte-v1"))
         (inference
          (nl-agent-supervised-file-experiment--inference-model
           trainable "service-preflight"))
         (grammar (nl-llm-agent-grammar-file-actions 64))
         (registry
          (nl-agent-supervised-file-experiment--native-registry
           inference inference grammar))
         (suite
          '(:id "supervised-file-service-preflight" :version "1"
            :cases
            [(:id "untrained-native"
              :task "Read probe.txt, then finish."
              :files [(:path "probe.txt" :text "probe\n")]
              :expected [(:path "probe.txt" :text "probe\n")])]))
         (report
          (nl-agent-supervised-file-experiment--evaluate
           suite registry "native/before"))
         (case (aref (plist-get report :cases) 0)))
    (should (= (plist-get inference :kvh) 1))
    (should-not (pav-p (plist-get inference :wte)))
    (should (memq (plist-get case :status) '(done limit)))
    (should-not (eq (plist-get case :status) 'error))))

(ert-deftest nl-agent-supervised-file-experiment-raw-pav-error-aborts ()
  ;; Reproduce the invalid v1 route deliberately: a trainable PAV plist is not
  ;; an inference model.  The evaluation guard must propagate that plumbing
  ;; error instead of returning a task-quality report with score zero.
  (let* ((trainable
          (nl-llm-agent-improve-model 2 2 256 1 1 "utf8-byte-v1"))
         (grammar (nl-llm-agent-grammar-file-actions 64))
         (registry
          (nl-agent-supervised-file-experiment--native-registry
           trainable trainable grammar))
         (suite
         '(:id "runtime-error" :version "1"
           :cases
           [(:id "failure" :task "synthetic"
             :files [(:path "x.txt" :text "x")]
             :expected [(:path "x.txt" :text "x")])])))
    (let ((failure
           (should-error
            (nl-agent-supervised-file-experiment--evaluate
             suite registry "native/before")
            :type 'error)))
      (should
       (string-search "kvh must be a positive integer"
                      (error-message-string failure))))))

(provide 'supervised-file-experiment-test)

(ert-run-tests-batch-and-exit)

;;; supervised-file-experiment-test.el ends here
