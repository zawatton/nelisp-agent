;;; background-task-promotion-service-test.el --- JSON task-gate service path -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-llm/lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-photon/lisp"))

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'nl-agent-improvement-config)
(require 'nl-agent-improvement)
(require 'nl-agent-task-audit)
(require 'nl-agent-training-protocol)
(require 'nl-agent-training-runner)
(require 'nl-agent-supervisor)
(require 'nl-agent-host)
(require 'nl-agent-autonomy)
(require 'nl-agent-service-tools)
(require 'nl-llm-agent-provider)
(require 'nl-llm-evolve-queue)

(defun nl-agent-background-task-promotion-service-test--write-config
    (file &optional changed removed)
  "Write the small JSON task-promotion fixture to FILE.
CHANGED alters the policy step bound; REMOVED omits the opt-in policy."
  (let ((policy
         `(("suite"
            ("id" . "service-task-suite")
            ("version" . "1")
            ("cases" .
             [(("id" . "rename-note")
               ("task" . "Read note.txt, replace old with new, then finish.")
               ("files" . [(("path" . "note.txt") ("text" . "old\n"))])
               ("expected" . [(("path" . "note.txt") ("text" . "new\n"))]))]))
           ("grammar" ("type" . "done") ("length" . 1))
           ("maxSequence" . 4096)
           ("maxSteps" . ,(if changed 2 1))
           ("auditDirectory" . "state/task-audit"))))
    (with-temp-file file
      (insert
       (json-encode
        (append
         `(("format" . "nl-agent-improvement-v1")
           ("catalog" . "state/catalog.json")
           ("queueState" . "state/queue.sexp")
           ("providerId" . "native")
           ("providerName" . "JSON task promotion service test")
           ("idPrefix" . "task-service")
           ("grammar" . (("type" . "done") ("length" . 1)))
           ("benchmark" . (("examples" . [" a"])))
           ("model" . (("source" . "new") ("dim" . 2) ("ff" . 2)
                        ("blocks" . 1) ("heads" . 1)
                        ("maxParameters" . 1000)))
           ("training" . (("execution" . "background")
                           ("backend" . "cpu") ("sequence" . 8)
                           ("optimizer" . "sgd")))
           ("minDelta" . 0.0) ("maxSequence" . 4096)
           ("maxPending" . 4) ("maxHistory" . 8))
         (unless removed (list (cons "taskPromotion" policy))))))
      (insert "\n"))))

(defun nl-agent-background-task-promotion-service-test--write-barrier (file)
  "Write a child-only barrier that pauses before real CPU training."
  (with-temp-file file
    (insert
     "(let* ((request-file (car (last command-line-args-left 2)))\n"
     "       (directory (file-name-directory request-file))\n"
     "       (ready (expand-file-name \"child.ready\" directory))\n"
     "       (release (expand-file-name \"child.release\" directory))\n"
     "       (deadline (+ (float-time) 20.0)))\n"
     "  (with-temp-file ready (insert \"ready\\n\"))\n"
     "  (while (and (not (file-exists-p release)) (< (float-time) deadline))\n"
     "    (sleep-for 0.01))\n"
     "  (unless (file-exists-p release) (error \"child barrier timeout\")))\n")))

(defun nl-agent-background-task-promotion-service-test--inject
    (arguments fixture)
  "Load FIXTURE before the worker's --funcall in ARGUMENTS."
  (let ((position (cl-position "--funcall" arguments :test #'equal)))
    (unless position (error "worker command has no --funcall"))
    (append (cl-subseq arguments 0 position)
            (list "-l" fixture)
            (nthcdr position arguments))))

(defun nl-agent-background-task-promotion-service-test--wait-terminal
    (runner timeout)
  "Poll RUNNER until terminal or TIMEOUT expires."
  (let ((deadline (+ (float-time) timeout)))
    (while (and (plist-get (nl-agent-training-runner-status runner)
                           :worker-running)
                (< (float-time) deadline))
      (let ((process (nl-agent-training-runner-process runner)))
        (when process (accept-process-output process 0.05)))
      (nl-agent-training-runner-poll runner))
    (nl-agent-training-runner-status runner)))

(ert-deftest nl-agent-background-task-promotion-json-service-vetoes-done-only-task ()
  "Exercise JSON load, live standalone tools, CPU child, audit, and veto."
  (let* ((project default-directory)
         (nelisp (expand-file-name "../nelisp/target/nelisp" project))
         (worker (expand-file-name "examples/free-models-worker.el" project))
         (directory (make-temp-file "nl-task-promotion-service-" t))
         (config (expand-file-name "config.json" directory))
         (barrier (expand-file-name "barrier.el" directory))
         (queue nil) (runner nil) (supervisor nil)
         (audit-directory nil) (initial-score nil) (initial-weight-digest nil)
         (request nil) (service-process nil) (child-ready nil)
         (child-release nil) (attempt-directory nil) (replies
          (list
           "```tool\n(:name \"model.improvement.submit\" :arguments (:kind \"trajectory-finetune\" :payload (:examples [\" a\"] :lr 0.1 :epochs 4) :id \"task-service-job\"))\n```"
           "```tool\n(:name \"model.improvement.run\" :arguments (:id \"task-service-job\"))\n```"
           "DONE service remained live"))
         (same-process nil))
    (unwind-protect
        (progn
          (nl-agent-background-task-promotion-service-test--write-config config)
          (nl-agent-background-task-promotion-service-test--write-barrier barrier)
          (let ((assembly (nl-agent-improvement-config-load config)))
            (setq queue (plist-get assembly :queue)
                  runner (plist-get assembly :runner)
                  audit-directory (plist-get assembly :task-audit-directory)
                  initial-score
                  (nl-llm-evolution-champion-score
                   (nl-llm-evolve-queue-evolution queue))
                  initial-weight-digest
                  (nl-agent-task-promotion--weight-digest
                   (nl-llm-agent-artifact-export-pav
                    (nl-llm-evolution-champion
                     (nl-llm-evolve-queue-evolution queue)))
                   "service-before")))
          (let* ((registry (nl-llm-agent-provider-registry-new))
                 (tools (nl-agent-tool-registry-new))
                 (permission
                  (nl-agent-permission-policy-new
                   :mode 'smart
                   :approval
                   (nl-agent-autonomy-improvement-approval
                    "native" "task-service")))
                 (router nil)
                 (provider
                  (nl-llm-agent-provider-new
                   "remote" :models '("model")
                   :open (lambda (model-id _options) model-id)
                   :complete
                   (lambda (_state _messages)
                     (let ((reply (pop replies)))
                       (unless reply (error "unexpected service turn"))
                       (cond
                        ((= (length replies) 0)
                         (setq child-ready
                               (expand-file-name
                                "child.ready"
                                (nl-agent-training-runner-workdir runner))
                               child-release
                               (expand-file-name
                                "child.release"
                                (nl-agent-training-runner-workdir runner))
                               attempt-directory
                               (nl-agent-training-runner-workdir runner))
                         (let ((deadline (+ (float-time) 20.0)))
                           (while (and (not (file-exists-p child-ready))
                                       (process-live-p
                                        (nl-agent-training-runner-process runner))
                                       (< (float-time) deadline))
                             (accept-process-output
                              (nl-agent-training-runner-process runner) 0.05)))
                         (unless (file-regular-p child-ready)
                           (error "training child did not reach service barrier"))
                         (setq request
                               (nl-agent-training-protocol-read
                                (nl-agent-training-runner-request-file runner))
                               same-process
                               (eq service-process
                                   (nl-agent-supervisor-process supervisor)))))
                       reply)))))
            (nl-agent-improvement-register-tools tools queue runner)
            (nl-llm-agent-provider-register registry provider)
            (setq router (nl-agent-host-router-new registry))
            (nl-agent-service-tools-register tools router)
            (setq supervisor
                  (nl-agent-supervisor-new
                   (list nelisp "--load" worker)
                   :directory project
                   :startup-config '(:model "remote/model" :fallbacks nil)
                   :await-ready t :max-requests 20 :timeout-sec 10
                   :model-catalog (nl-agent-host-model-catalog-function router)
                   :inference (nl-agent-host-inference-function router)
                   :tool (nl-agent-host-tool-function tools permission)
                   :tool-catalog (nl-agent-host-tool-catalog-function tools)))
            (nl-agent-supervisor-start supervisor)
            (setq service-process (nl-agent-supervisor-process supervisor))
            (let ((real-start-process (symbol-function 'start-process)))
              (cl-letf (((symbol-function 'start-process)
                         (lambda (name buffer program &rest arguments)
                           (apply real-start-process name buffer program
                                  (if (equal name "nl-agent-training-worker")
                                      (nl-agent-background-task-promotion-service-test--inject
                                       arguments barrier)
                                    arguments)))))
                (let ((response
                       (nl-agent-supervisor-call
                        supervisor '(run "submit and run the bounded training job"))))
                  (should (eq (plist-get response :status) 'done))
                  (should (equal (plist-get response :result)
                                 "service remained live")))))
            (should child-ready)
            (should (file-regular-p child-ready))
            (should (process-live-p (nl-agent-training-runner-process runner)))
            (should same-process)
            (should (equal (plist-get request :scope)
                           (plist-get
                            (nl-agent-training-runner-profile runner) :scope)))
            (with-temp-file child-release (insert "release\n"))
            (nl-agent-background-task-promotion-service-test--wait-terminal
             runner 30.0)
            (let* ((job (nl-llm-evolve-queue--job queue "task-service-job"))
                   (status (nl-agent-training-runner-status runner))
                   (audit (nl-agent-task-audit-read
                           audit-directory (plist-get request :scope)
                           (plist-get request :job-id)
                           (plist-get request :attempt))))
              (should-not (plist-get status :worker-running))
              (should (= (plist-get status :generation) 0))
              (should (eq (nl-llm-evolve-queue-job-status job) 'rejected))
              (should-not (file-exists-p
                           (expand-file-name "state/catalog.json" directory)))
              (should (equal (plist-get audit :request) request))
              (should (equal (plist-get (plist-get audit :result) :request-sha256)
                             (plist-get audit :request-sha256)))
              (should (> (plist-get (plist-get audit :result) :score)
                         initial-score))
              (should (equal initial-weight-digest
                             (nl-agent-task-promotion--weight-digest
                              (nl-llm-agent-artifact-export-pav
                               (nl-llm-evolution-champion
                                (nl-llm-evolve-queue-evolution queue)))
                              "service-after")))
              (should-not (file-directory-p attempt-directory))))
          (nl-agent-training-runner-stop runner)
          (setq runner nil)
          ;; Same JSON reload creates a fresh queue/runner and does not resume
          ;; or publish the rejected job automatically.
          (let ((reloaded (nl-agent-improvement-config-load config)))
            (unwind-protect
                (progn
                  (should (nl-agent-training-runner-p
                           (plist-get reloaded :runner)))
                  (should-not
                   (plist-get (nl-agent-training-runner-status
                               (plist-get reloaded :runner)) :worker-running))
                  (should (= (plist-get
                              (nl-agent-training-runner-status
                               (plist-get reloaded :runner)) :generation)
                             0)))
              (nl-agent-training-runner-stop (plist-get reloaded :runner))))
          ;; Changed and removed policy cannot reuse this queue-state sidecar.
          (nl-agent-background-task-promotion-service-test--write-config
           config t)
          (should-error (nl-agent-improvement-config-load config))
          (nl-agent-background-task-promotion-service-test--write-config
           config nil t)
          (should-error (nl-agent-improvement-config-load config)))
      (when (and child-release
                 runner
                 (file-directory-p (file-name-directory child-release))
                 (process-live-p (nl-agent-training-runner-process runner))
                 (not (file-exists-p child-release)))
        (with-temp-file child-release (insert "release\n")))
      (when supervisor (ignore-errors (nl-agent-supervisor-stop supervisor)))
      (when runner (ignore-errors (nl-agent-training-runner-stop runner)))
      (delete-directory directory t))))

(ert-run-tests-batch-and-exit)
