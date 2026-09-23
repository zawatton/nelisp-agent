;;; training-task-promotion-worker-test.el --- worker promotion integration -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                          (file-name-directory (or load-file-name buffer-file-name
                                                   default-directory))) nil t)
)

(require 'nl-agent-training-protocol)
(require 'nl-agent-training-worker)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-improve)

(defun nl-agent-training-task-promotion-worker-test--policy ()
  "Return a deliberately unlearnable tiny promotion policy fixture."
  (list :suite
        (list :id (concat "worker-promotion-suite") :version (concat "1")
              :cases
              (vector
               (list :id (concat "done-case")
                     :task (concat "Replace before with never-match in input.txt, then finish.")
                     :files (vector (list :path (concat "input.txt")
                                             :text (concat "before")))
                     :expected (vector (list :path (concat "input.txt")
                                                :text (concat "never-match"))))))
        :grammar (list :type (concat "done") :length 1
                       :allow (concat "ab"))
        :max-sequence 4096 :max-steps 1))

(defun nl-agent-training-task-promotion-worker-test--request ()
  "Return a tiny CPU worker request with task promotion enabled."
  (list :format nl-agent-training-protocol-format
        :attempt "worker-promotion-attempt" :job-id "worker-promotion-job"
        :parent-generation 0 :parent-score 0.0
        :scope (make-string 64 ?b)
        :payload '(:examples ["ab"] :lr 0.01 :epochs 1)
        :parent-model
        (nl-llm-agent-artifact-export-pav
         (nl-llm-agent-improve-model 2 2 96 1 1))
        :training '(:backend cpu :sequence 8 :optimizer sgd)
        :benchmark ["ab"]
        :task-promotion
        (nl-agent-training-task-promotion-worker-test--policy)))

(defun nl-agent-training-task-promotion-worker-test--worker-source ()
  "Return the source path of the worker loaded by this test."
  (concat (file-name-sans-extension
           (file-truename (locate-library "nl-agent-training-worker")))
          ".el"))

(defun nl-agent-training-task-promotion-worker-test--run-child
    (request-file result-file request)
  "Run the real CPU worker child for REQUEST."
  (let* ((worker-path
          (nl-agent-training-task-promotion-worker-test--worker-source))
         (dir (file-name-directory worker-path))
         (output (generate-new-buffer " *task-promotion-worker-child*"))
         status)
    (unwind-protect
        (progn
          (nl-agent-training-protocol-write request-file request)
          (setq status
                (call-process
                 (or (getenv "EMACS") "emacs") nil output nil "-Q" "--batch"
                 "--eval" "(setq load-prefer-newer t)"
                 "-L" (expand-file-name "../../nelisp-photon/lisp" dir)
                 "-L" (expand-file-name "../../nelisp-llm/lisp" dir)
                 "-L" dir "-l" worker-path
                 "--funcall" "nl-agent-training-worker-main"
                 request-file result-file))
          (unless (= status 0)
            (error "worker child failed: %s"
                   (with-current-buffer output (buffer-string)))))
      (kill-buffer output))))

(ert-deftest nl-agent-training-task-promotion-worker-real-cpu-negative-gate ()
  "Real CPU training emits validated negative promotion evidence."
  (let* ((tmp (make-temp-file "nl-task-promotion-worker-" t))
         (request-file (expand-file-name "request.sexp" tmp))
         (result-file (expand-file-name "result.sexp" tmp))
         (request (nl-agent-training-task-promotion-worker-test--request)))
    (unwind-protect
        (progn
          (nl-agent-training-task-promotion-worker-test--run-child
           request-file result-file request)
          (let* ((result (nl-agent-training-protocol-read result-file))
                 (evidence (plist-get result :task-promotion))
                 (before (plist-get evidence :before))
                 (after (plist-get evidence :after)))
            (should (eq (nl-agent-training-protocol-validate-result result request)
                        result))
            (should (null (plist-get evidence :accepted)))
            (should (= (plist-get before :passed) 0))
            (should (= (plist-get after :passed) 0))
            (should (eq (plist-get (aref (plist-get before :cases) 0)
                          :status)
                        'done))
            (should (eq (plist-get (aref (plist-get after :cases) 0)
                          :status)
                        'done))
            (should (memq 'content-mismatch
                          (append (plist-get (aref (plist-get before :cases) 0)
                                             :failure-codes)
                                  nil)))
            (should (memq 'content-mismatch
                          (append (plist-get (aref (plist-get after :cases) 0)
                                             :failure-codes)
                                  nil)))
            (should-not (equal (plist-get evidence :before-model-sha256)
                               (plist-get evidence :after-model-sha256)))))
      (delete-directory tmp t))))

(ert-run-tests-batch-and-exit)
