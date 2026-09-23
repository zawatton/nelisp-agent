;;; training-resume-worker-test.el --- isolated GPU resume worker -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-training-protocol)
(require 'nl-agent-training-worker)
(require 'nl-llm-agent-improve)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-gpu)

(defun nl-agent-training-resume-test--model ()
  "Return a tiny detached P5 checkpoint for worker tests."
  (nl-llm-agent-artifact-export-pav
   (nl-llm-agent-improve-model
    2 2 nl-llm-agent-char-vocab 1 1)))

(defun nl-agent-training-resume-test--request (attempt parent &optional resume)
  "Return one GPU Adam request for ATTEMPT and PARENT, optionally RESUME state."
  (append
   (list :format nl-agent-training-protocol-format
         :attempt attempt :job-id "resume-job"
         :parent-generation 0 :parent-score 0.0
         :scope (make-string 64 ?0)
         :payload '(:examples ["ab" "ba"] :lr 0.1 :epochs 2)
         :parent-model parent
         :training '(:backend gpu :sequence 2 :optimizer adam
                     :checkpoint-every 1)
         :benchmark ["ab"])
   (when resume (list :resume-state resume))))

(defun nl-agent-training-resume-test--worker-source ()
  "Return the source path of the isolated training worker."
  (concat
   (file-name-sans-extension
    (file-truename (locate-library "nl-agent-training-worker")))
   ".el"))

(defun nl-agent-training-resume-test--write-fixture (file)
  "Write a test-only AFTER-STEP observer and interrupter to FILE."
  (with-temp-file file
    (insert
     ";;; training-resume-fixture.el --- test-only interruption -*- lexical-binding: t; -*-\n"
     "(let ((original (symbol-function 'nl-llm-agent-ondevice-train)))\n"
     "  (fset 'nl-llm-agent-ondevice-train\n"
     "        (lambda (ctx trajs epochs &rest keys)\n"
     "          (let ((callback (plist-get keys :after-step))\n"
     "                (count-file (getenv \"NL_AGENT_RESUME_COUNT_FILE\"))\n"
     "                (stop-text (getenv \"NL_AGENT_RESUME_INTERRUPT_STEP\"))\n"
     "                (executed 0))\n"
     "            (setq keys\n"
     "                  (plist-put\n"
     "                   keys :after-step\n"
     "                   (lambda (active completed total)\n"
     "                     (setq executed (1+ executed))\n"
     "                     (when callback\n"
     "                       (funcall callback active completed total))\n"
     "                     (when count-file\n"
     "                       (with-temp-file count-file\n"
     "                         (insert (number-to-string executed))))\n"
     "                     (when (and stop-text\n"
     "                                (= completed (string-to-number stop-text)))\n"
     "                       (error \"test interruption after checkpoint\")))))\n"
     "            (apply original ctx trajs epochs keys)))))\n")))

(defun nl-agent-training-resume-test--run-child
    (request directory fixture count-file &optional interrupt-step)
  "Run REQUEST in private DIRECTORY and return child process observations."
  (let* ((request-file (expand-file-name "request.sexp" directory))
         (result-file (expand-file-name "result.sexp" directory))
         (checkpoint-file (expand-file-name "checkpoint.sexp" directory))
         (worker (nl-agent-training-resume-test--worker-source))
         (worker-directory (file-name-directory worker))
         (output (generate-new-buffer " *training-resume-child*"))
         (process-environment
          (append
           (list (concat "NL_AGENT_RESUME_COUNT_FILE=" count-file)
                 (concat "NL_AGENT_RESUME_INTERRUPT_STEP="
                         (if interrupt-step
                             (number-to-string interrupt-step)
                           "")))
           process-environment))
         status)
    (unwind-protect
        (progn
          (nl-agent-training-protocol-write request-file request)
          (setq status
                (call-process
                 (or (getenv "EMACS") "emacs") nil output nil
                 "-Q" "--batch" "--eval" "(setq load-prefer-newer t)"
                 "-L" (expand-file-name "../../nelisp-photon/lisp"
                                        worker-directory)
                 "-L" (expand-file-name "../../nelisp-llm/lisp"
                                        worker-directory)
                 "-L" worker-directory
                 "-l" worker "-l" fixture
                 "--funcall" "nl-agent-training-worker-main"
                 request-file result-file))
          (list :status status
                :output (with-current-buffer output (buffer-string))
                :request-file request-file
                :result-file result-file
                :checkpoint-file checkpoint-file))
      (kill-buffer output))))

(defun nl-agent-training-resume-test--checkpoint (run request)
  "Read and validate RUN's progress envelope for REQUEST."
  (let* ((request-file (plist-get run :request-file))
         (hash (nl-agent-training-protocol-hash request-file))
         (envelope
          (nl-agent-training-protocol-read
           (plist-get run :checkpoint-file))))
    (nl-agent-training-protocol-validate-checkpoint envelope request hash)
    envelope))

(ert-deftest nl-agent-training-worker-rejects-checkpoint-path-alias ()
  (let* ((directory (make-temp-file "nl-training-alias-" t))
         (request-file (expand-file-name "checkpoint.sexp" directory))
         (result-file (expand-file-name "result.sexp" directory))
         (request
          (nl-agent-training-resume-test--request
           "alias" (nl-agent-training-resume-test--model))))
    (unwind-protect
        (progn
          (nl-agent-training-protocol-write request-file request)
          (cl-letf (((symbol-function 'nl-llm-gpu-enable)
                     (lambda () (error "GPU allocation must not be reached"))))
            (should-error
             (nl-agent-training-worker-run request-file result-file)))
          (should (equal (nl-agent-training-protocol-read request-file)
                         request))
          (should-not (file-exists-p result-file)))
      (delete-directory directory t))))

(ert-deftest nl-agent-training-worker-real-child-gpu-adam-resume ()
  "Resume a killed private GPU attempt and match uninterrupted Adam state."
  (unless (nl-llm-gpu-enable)
    (ert-skip "GPU backend unavailable; resume worker requires Vulkan"))
  (nl-llm-gpu-disable)
  (let* ((temporary (make-temp-file "nl-training-resume-" t))
         (fixture (expand-file-name "training-resume-fixture.el" temporary))
         (parent (nl-agent-training-resume-test--model))
         (baseline-directory (expand-file-name "baseline" temporary))
         (interrupted-directory (expand-file-name "interrupted" temporary))
         (resumed-directory (expand-file-name "resumed" temporary))
         (complete-directory (expand-file-name "complete" temporary)))
    (dolist (directory
             (list baseline-directory interrupted-directory resumed-directory
                   complete-directory))
      (make-directory directory))
    (nl-agent-training-resume-test--write-fixture fixture)
    (unwind-protect
        (let* ((baseline-request
                (nl-agent-training-resume-test--request "baseline" parent))
               (baseline-count
                (expand-file-name "steps" baseline-directory))
               (baseline-run
                (nl-agent-training-resume-test--run-child
                 baseline-request baseline-directory fixture baseline-count))
               (_baseline-ok
                (should (= (plist-get baseline-run :status) 0)))
               (baseline-envelope
                (nl-agent-training-resume-test--checkpoint
                 baseline-run baseline-request))
               (baseline-state (plist-get baseline-envelope :state))
               (interrupted-request
                (nl-agent-training-resume-test--request "interrupted" parent))
               (interrupted-count
                (expand-file-name "steps" interrupted-directory))
               (interrupted-run
                (nl-agent-training-resume-test--run-child
                 interrupted-request interrupted-directory fixture
                 interrupted-count 1))
               (_interrupted
                (should-not (= (plist-get interrupted-run :status) 0)))
               (interrupted-envelope
                (nl-agent-training-resume-test--checkpoint
                 interrupted-run interrupted-request))
               (interrupted-state (plist-get interrupted-envelope :state))
               (resumed-request
                (nl-agent-training-resume-test--request
                 "resumed" parent interrupted-state))
               (resumed-count (expand-file-name "steps" resumed-directory))
               (resumed-run
                (nl-agent-training-resume-test--run-child
                 resumed-request resumed-directory fixture resumed-count))
               (_resumed-ok (should (= (plist-get resumed-run :status) 0)))
               (resumed-envelope
                (nl-agent-training-resume-test--checkpoint
                 resumed-run resumed-request))
               (resumed-state (plist-get resumed-envelope :state))
               (complete-request
                (nl-agent-training-resume-test--request
                 "complete" parent resumed-state))
               (complete-count (expand-file-name "steps" complete-directory))
               (complete-run
                (nl-agent-training-resume-test--run-child
                 complete-request complete-directory fixture complete-count))
               (_complete-ok
                (should (= (plist-get complete-run :status) 0)))
               (complete-envelope
                (nl-agent-training-resume-test--checkpoint
                 complete-run complete-request))
               (complete-state (plist-get complete-envelope :state))
               (resumed-result
                (nl-agent-training-protocol-read
                 (plist-get resumed-run :result-file)))
               (complete-result
                (nl-agent-training-protocol-read
                 (plist-get complete-run :result-file))))
          (should (= (plist-get interrupted-state :completed-steps) 1))
          (should (= (string-to-number
                      (with-temp-buffer
                        (insert-file-contents interrupted-count)
                        (buffer-string)))
                     1))
          (should (= (string-to-number
                      (with-temp-buffer
                        (insert-file-contents resumed-count)
                        (buffer-string)))
                     3))
          (should-not (file-exists-p complete-count))
          (should (= (plist-get resumed-state :completed-steps) 4))
          (should (= (plist-get resumed-state :optimizer-step) 4))
          (should (= (plist-get baseline-state :optimizer-step)
                     (plist-get resumed-state :optimizer-step)))
          (should (equal (plist-get baseline-state :model)
                         (plist-get resumed-state :model)))
          (should (equal (plist-get baseline-state :optimizer-state)
                         (plist-get resumed-state :optimizer-state)))
          (should (equal (plist-get resumed-state :model)
                         (plist-get complete-state :model)))
          (should (equal (plist-get resumed-state :optimizer-state)
                         (plist-get complete-state :optimizer-state)))
          (should (equal (plist-get resumed-result :model)
                         (plist-get complete-result :model)))
          (should (equal (plist-get resumed-result :model)
                         (plist-get resumed-state :model)))
          (should (equal (plist-get complete-result :model)
                         (plist-get complete-state :model)))
          (should (= (plist-get (plist-get resumed-result :model) :step) 4))
          (should (= (plist-get (plist-get complete-result :model) :step) 4))
          (should (equal (plist-get resumed-result :attempt) "resumed"))
          (should
           (equal (plist-get resumed-result :request-sha256)
                  (nl-agent-training-protocol-hash
                   (plist-get resumed-run :request-file))))
          (should (equal (plist-get complete-result :attempt) "complete"))
          (should
           (equal (plist-get complete-result :request-sha256)
                  (nl-agent-training-protocol-hash
                   (plist-get complete-run :request-file))))
          (should (equal (plist-get complete-envelope :attempt) "complete"))
          (should
           (equal (plist-get complete-envelope :request-sha256)
                  (nl-agent-training-protocol-hash
                   (plist-get complete-run :request-file)))))
      (ignore-errors (nl-llm-gpu-disable))
      (delete-directory temporary t))))

(provide 'training-resume-worker-test)

(ert-run-tests-batch-and-exit)

;;; training-resume-worker-test.el ends here
