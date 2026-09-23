;;; improvement-test.el --- guarded evaluated model improvement tools  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-improvement)
(require 'nl-agent-permission)
(require 'nl-agent-host)
(require 'nl-agent-supervisor)

(defvar nl-agent-improvement-test--fail 0)
(defvar nl-agent-improvement-test--assertions 0)

(defun nl-agent-improvement-test--ck (name ok)
  (setq nl-agent-improvement-test--assertions
        (1+ nl-agent-improvement-test--assertions))
  (princ (format "%-70s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-improvement-test--fail
                         (1+ nl-agent-improvement-test--fail))
                   "FAIL"))))

(let* ((evolution
        (nl-llm-evolution-new
         '(:fitness [1.0])
         (lambda (model) (aref (plist-get model :fitness) 0))))
       (queue (nl-llm-evolve-queue-new evolution))
       (registry (nl-agent-tool-registry-new))
       (smart (nl-agent-permission-policy-new :mode 'smart))
       (trusted (nl-agent-permission-policy-new :mode 'off)))
  (nl-llm-evolve-queue-register
   queue "set-fitness"
   (lambda (candidate payload _state)
     (aset (plist-get candidate :fitness) 0
           (plist-get payload :fitness)))
   :resume
   (lambda (candidate payload _state)
     (aset (plist-get candidate :fitness) 0
           (plist-get payload :fitness)))
   :validate
   (lambda (payload)
     (unless (numberp (plist-get payload :fitness))
       (error "fitness required")))
   :description "Set candidate fitness")
  (nl-agent-improvement-register-tools registry queue)
  (let ((catalog (nl-agent-tool-catalog registry)))
    (nl-agent-improvement-test--ck
     "worker catalog receives five improvement tools without callbacks"
     (and
      (equal
       (mapcar
        (lambda (tool)
          (list (plist-get tool :name) (plist-get tool :risk)))
        catalog)
       '(("model.improvement.status" read)
         ("model.improvement.submit" write)
         ("model.improvement.run" execute)
         ("model.improvement.resume" execute)
         ("model.improvement.cancel" write)))
      (not (string-match-p
            "function\|closure"
            (prin1-to-string catalog))))))
  (let ((status
         (nl-agent-permission-call
          smart registry "model.improvement.status" nil)))
    (nl-agent-improvement-test--ck
     "read-only improvement status is available under smart policy"
     (and (eq (plist-get status :status) 'ok)
          (= (plist-get (plist-get status :value) :generation) 0))))
  (let ((denied
         (nl-agent-permission-call
          smart registry "model.improvement.submit"
          '(:kind "set-fitness" :payload (:fitness 2.0)))))
    (nl-agent-improvement-test--ck
     "a model cannot queue state changes without host approval"
     (and (eq (plist-get denied :status) 'denied)
          (= (plist-get (nl-llm-evolve-queue-status queue) :pending) 0))))
  (let ((submitted
         (nl-agent-permission-call
          trusted registry "model.improvement.submit"
          '(:kind "set-fitness" :payload (:fitness 3.0)
            :id "candidate-1" :metadata (:source model)))))
    (nl-agent-improvement-test--ck
     "approved model proposal becomes inert queued data"
     (and (eq (plist-get submitted :status) 'ok)
          (equal (plist-get (plist-get submitted :value) :id) "candidate-1")
          (= (plist-get (nl-llm-evolve-queue-status queue) :pending) 1))))
  (let ((ran
         (nl-agent-permission-call
          trusted registry "model.improvement.run"
          '(:id "candidate-1"))))
    (nl-agent-improvement-test--ck
     "approved run crosses the fixed evaluator and promotes the challenger"
     (and (eq (plist-get ran :status) 'ok)
          (eq (plist-get (plist-get ran :value) :status) 'promoted)
          (= (nl-llm-evolution-generation evolution) 1)
          (= (aref
              (plist-get (nl-llm-evolution-champion evolution) :fitness)
              0)
             3.0))))
  (let ((invalid
         (nl-agent-permission-call
          trusted registry "model.improvement.submit"
          '(:kind "set-fitness" :payload (:fitness 4.0)
            :callback (lambda () t)))))
    (nl-agent-improvement-test--ck
     "unknown tool arguments cannot smuggle an executable callback"
     (and (eq (plist-get invalid :status) 'error)
          (= (nl-llm-evolution-generation evolution) 1))))
  (nl-agent-improvement-test--ck
   "model-visible schemas describe the guarded state-changing boundary"
   (let* ((catalog (nl-agent-tool-catalog registry))
          (submit (nth 1 catalog))
          (run (nth 2 catalog))
          (resume (nth 3 catalog))
          (cancel (nth 4 catalog)))
     (and (equal
           (plist-get
            (plist-get submit :metadata) :input-schema)
           nl-agent-improvement-submit-schema)
          (equal
           (plist-get
            (plist-get run :metadata) :input-schema)
           nl-agent-improvement-run-schema)
          (equal
           (plist-get
            (plist-get resume :metadata) :input-schema)
           nl-agent-improvement-resume-schema)
          (equal
           (plist-get
            (plist-get cancel :metadata) :input-schema)
           nl-agent-improvement-cancel-schema)
          (string-match-p "pending or interrupted"
                          (plist-get cancel :description)))))
  (nl-llm-evolve-queue-submit
   queue "set-fitness" '(:fitness 4.0) :id "resume-candidate")
  (setf
   (nl-llm-evolve-queue-job-status
    (car
     (cl-remove-if-not
      (lambda (job)
        (equal (nl-llm-evolve-queue-job-id job) "resume-candidate"))
      (nl-llm-evolve-queue-jobs queue))))
   'interrupted)
  (let ((resumed
         (nl-agent-permission-call
          trusted registry "model.improvement.resume"
          '(:id "resume-candidate"))))
    (nl-agent-improvement-test--ck
     "approved resume crosses only the handler registered for interrupted work"
     (and (eq (plist-get resumed :status) 'ok)
          (eq (plist-get (plist-get resumed :value) :status) 'promoted)
          (= (nl-llm-evolution-generation evolution) 2)))))

(let* ((evolution
        (nl-llm-evolution-new
         '(:fitness [1.0])
         (lambda (model) (aref (plist-get model :fitness) 0))))
       (queue (nl-llm-evolve-queue-new evolution :max-pending 1))
       (registry (nl-agent-tool-registry-new))
       (deny (nl-agent-permission-policy-new :mode 'smart))
       (approve
        (nl-agent-permission-policy-new
         :mode 'smart :approval (lambda (_request) 'once))))
  (nl-llm-evolve-queue-register
   queue "set-fitness"
   (lambda (candidate payload _state)
     (aset (plist-get candidate :fitness) 0
           (plist-get payload :fitness))))
  (nl-agent-improvement-register-tools registry queue)
  (nl-llm-evolve-queue-submit
   queue "set-fitness" '(:fitness 2.0) :id "interrupted-candidate")
  (let ((job (cl-find-if
              (lambda (candidate)
                (equal (nl-llm-evolve-queue-job-id candidate)
                       "interrupted-candidate"))
              (nl-llm-evolve-queue-jobs queue))))
    (setf (nl-llm-evolve-queue-job-status job) 'interrupted))
  (let ((denied
         (nl-agent-permission-call
          deny registry "model.improvement.cancel"
          '(:id "interrupted-candidate"))))
    (nl-agent-improvement-test--ck
     "host permission denial leaves interrupted proposal outstanding"
     (and (eq (plist-get denied :status) 'denied)
          (eq (nl-llm-evolve-queue-job-status
               (cl-find-if
                (lambda (job)
                  (equal (nl-llm-evolve-queue-job-id job)
                         "interrupted-candidate"))
                (nl-llm-evolve-queue-jobs queue)))
              'interrupted)
          (= (plist-get (nl-llm-evolve-queue-status queue) :interrupted) 1))))
  (let ((before-generation (nl-llm-evolution-generation evolution))
        (before-score (nl-llm-evolution-champion-score evolution))
        (before-fitness
         (aref (plist-get (nl-llm-evolution-champion evolution) :fitness) 0))
        (cancelled
         (nl-agent-permission-call
          approve registry "model.improvement.cancel"
          '(:id "interrupted-candidate"))))
    (nl-agent-improvement-test--ck
     "approved interrupted cancellation frees capacity without changing champion"
     (and (eq (plist-get cancelled :status) 'ok)
          (eq (plist-get (plist-get cancelled :value) :status) 'cancelled)
          (= (plist-get (nl-llm-evolve-queue-status queue) :pending) 0)
          (= (plist-get (nl-llm-evolve-queue-status queue) :interrupted) 0)
          (= (plist-get (nl-llm-evolve-queue-status queue) :completed) 1)
          (= before-generation (nl-llm-evolution-generation evolution))
          (= before-score (nl-llm-evolution-champion-score evolution))
          (= before-fitness
             (aref (plist-get (nl-llm-evolution-champion evolution) :fitness)
                   0)))))
  (let ((submitted
         (nl-agent-permission-call
          (nl-agent-permission-policy-new :mode 'off)
          registry "model.improvement.submit"
          '(:kind "set-fitness" :payload (:fitness 3.0)
            :id "capacity-reclaimed"))))
    (nl-agent-improvement-test--ck
     "cancelled interrupted proposal releases bounded queue capacity"
     (and (eq (plist-get submitted :status) 'ok)
          (= (plist-get (nl-llm-evolve-queue-status queue) :pending) 1))))
  (let ((job (cl-find-if
              (lambda (candidate)
                (equal (nl-llm-evolve-queue-job-id candidate)
                       "capacity-reclaimed"))
              (nl-llm-evolve-queue-jobs queue))))
    (setf (nl-llm-evolve-queue-job-status job) 'running)
    (let ((rejected
           (nl-agent-permission-call
            (nl-agent-permission-policy-new :mode 'off)
            registry "model.improvement.cancel"
            '(:id "capacity-reclaimed"))))
      (nl-agent-improvement-test--ck
       "running proposal cancellation is rejected by the host tool"
       (and (eq (plist-get rejected :status) 'error)
            (eq (nl-llm-evolve-queue-job-status job) 'running))))))

(let* ((project-directory default-directory)
       (nelisp
        (expand-file-name "../nelisp/target/nelisp" project-directory))
       (fixture
        (expand-file-name
         "test/stdio-agent-worker-fixture.el" project-directory))
       (evolution
        (nl-llm-evolution-new
         '(:fitness [1.0])
         (lambda (model) (aref (plist-get model :fitness) 0))))
       (queue (nl-llm-evolve-queue-new evolution))
       (tools (nl-agent-tool-registry-new))
       (policy (nl-agent-permission-policy-new :mode 'off))
       (responses
        (list
         (concat
          "```tool\n"
          "(:name \"model.improvement.submit\" "
          ":arguments (:kind \"set-fitness\" "
          ":payload (:fitness 5.0) :id \"agent-proposal\"))\n"
          "```")
         "DONE proposal queued"
         (concat
          "```tool\n"
          "(:name \"model.improvement.run\" "
          ":arguments (:id \"agent-proposal\"))\n"
          "```")
         "DONE improvement evaluated"))
       (supervisor nil))
  (nl-llm-evolve-queue-register
   queue "set-fitness"
   (lambda (candidate payload _state)
     (aset (plist-get candidate :fitness) 0
           (plist-get payload :fitness))))
  (nl-agent-improvement-register-tools tools queue)
  (unwind-protect
      (progn
        (setq supervisor
              (nl-agent-supervisor-new
               (list nelisp "--load" fixture)
               :directory project-directory :await-ready t
               :max-requests 20 :timeout-sec 5
               :model-catalog
               (lambda ()
                 '((:provider "remote" :id "model" :name "Model")))
               :inference
               (lambda (_event)
                 (or (pop responses) (error "unexpected inference")))
               :tool (nl-agent-host-tool-function tools policy)
               :tool-catalog (nl-agent-host-tool-catalog-function tools)))
        (let ((result
               (nl-agent-supervisor-call
                supervisor '(run "propose a bounded improvement"))))
          (nl-agent-improvement-test--ck
           "standalone model queues inert improvement data through the host"
           (and (eq (plist-get result :status) 'done)
                (equal (plist-get result :result) "proposal queued")
                (= (plist-get (nl-llm-evolve-queue-status queue) :pending)
                   1))))
        (let ((result
               (nl-agent-supervisor-call
                supervisor '(run "evaluate the queued improvement"))))
          (nl-agent-improvement-test--ck
           "standalone model triggers host evaluation and measured promotion"
           (and (eq (plist-get result :status) 'done)
                (equal (plist-get result :result)
                       "improvement evaluated")
                (= (nl-llm-evolution-generation evolution) 1)
                (= (aref
                    (plist-get
                     (nl-llm-evolution-champion evolution) :fitness)
                    0)
                   5.0)
                (null responses)))))
    (when supervisor (nl-agent-supervisor-stop supervisor))))

(princ (format "NL-AGENT-IMPROVEMENT %s (%d assertions, %d failures)\n"
               (if (= nl-agent-improvement-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-improvement-test--assertions
               nl-agent-improvement-test--fail))
(kill-emacs (if (= nl-agent-improvement-test--fail 0) 0 1))

;;; improvement-test.el ends here
