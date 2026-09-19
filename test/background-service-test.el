;;; background-service-test.el --- live service during real training -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'nl-agent-training-runner)
(require 'nl-agent-supervisor)
(require 'nl-agent-host)
(require 'nl-agent-improvement)
(require 'nl-agent-service-tools)
(require 'nl-agent-autonomy)
(require 'nl-agent-improvement-config)
(require 'nl-agent-training-protocol)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-inference-runtime)
(require 'nl-llm-agent-provider)
(require 'json)

(defun nl-agent-background-service-test--write-handshake-fixture (file)
  "Write the test-only child readiness handshake to FILE."
  (with-temp-file file
    (insert
     ";;; training-child-handshake.el --- test-only child barrier -*- lexical-binding: t; -*-\n"
     "(let* ((request-file (car (last command-line-args-left 2)))\n"
     "       (directory (file-name-directory request-file))\n"
     "       (ready (expand-file-name \"child.ready\" directory))\n"
     "       (release (expand-file-name \"child.release\" directory))\n"
     "       (deadline (+ (float-time) 10.0)))\n"
     "  (when (getenv \"NL_AGENT_BACKGROUND_TEST_SECRET\")\n"
     "    (error \"training child inherited host-only secret sentinel\"))\n"
     "  (with-temp-file ready (insert \"ready\\n\"))\n"
     "  (while (and (not (file-exists-p release)) (< (float-time) deadline))\n"
     "    (sleep-for 0.01))\n"
     "  (unless (file-exists-p release)\n"
     "    (error \"training child release timeout\")))\n")))

(defun nl-agent-background-service-test--inject-fixture (arguments fixture)
  "Insert a load of FIXTURE before --funcall in process ARGUMENTS."
  (let ((position (cl-position "--funcall" arguments :test #'equal)))
    (unless position
      (error "training worker command lacks --funcall: %S" arguments))
    (append (cl-subseq arguments 0 position)
            (list "-l" fixture)
            (nthcdr position arguments))))

(defun nl-agent-background-service-test--wait-for-file
    (file process timeout)
  "Wait up to TIMEOUT seconds for FILE while PROCESS remains live."
  (let ((deadline (+ (float-time) timeout)))
    (while (and (not (file-exists-p file))
                (process-live-p process)
                (< (float-time) deadline))
      (accept-process-output process 0.05))
    (file-exists-p file)))

(defun nl-agent-background-service-test--model-weights (model)
  "Return a comparable snapshot of MODEL's inference tensors."
  (let ((keys '(:ln1g :wq :bq :wk :bk :wv :bv :wo :bo
                :ln2g :wg :bg :wu :bu :wd :bd)))
    (list
     :wte (plist-get model :wte)
     :wh (plist-get model :wh)
     :lnfg (plist-get model :lnfg)
     :bh (plist-get model :bh)
     :blocks
     (mapcar
      (lambda (block)
        (mapcar (lambda (key) (plist-get block key)) keys))
      (plist-get model :blocks)))))

(defun nl-agent-background-service-test--write-completion-config (file)
  "Write the bounded background completion configuration to FILE."
  (with-temp-file file
    (insert
     (json-encode
      `(("format" . ,nl-agent-improvement-config-format)
        ("catalog" . "state/catalog.json")
        ("queueState" . "state/queue.sexp")
        ("providerId" . "native")
        ("providerName" . "Background completion test")
        ("idPrefix" . "background")
        ("grammar" . (("type" . "done") ("length" . 4)
                      ("allow" . "ab ")))
        ("benchmark" . (("examples" . [" a"])))
        ("model" . (("source" . "new") ("dim" . 2) ("ff" . 2)
                     ("blocks" . 1) ("heads" . 1)
                     ("maxParameters" . 1000)))
        ("training" . (("objective" . "completion")
                        ("execution" . "background")
                        ("backend" . "cpu") ("sequence" . 8)
                        ("optimizer" . "sgd")))
        ("minDelta" . 0.0) ("maxSequence" . 4096)
        ("maxPending" . 4) ("maxHistory" . 8))))
    (terpri (current-buffer))))

(defun nl-agent-background-service-test--run-case (&optional objective)
  "Run the live-service background training case for OBJECTIVE."
  (let* ((project-directory default-directory)
         (nelisp (expand-file-name "../nelisp/target/nelisp"
                                   project-directory))
         (worker-fixture
          (expand-file-name "test/stdio-agent-worker-fixture.el"
                            project-directory))
         (temporary (make-temp-file "nl-agent-background-service-" t))
         (catalog-file (expand-file-name "catalog.json" temporary))
         (checkpoint-file (expand-file-name "queue.sexp" temporary))
         (config-file (expand-file-name "improvement.json" temporary))
         (handshake-fixture
          (expand-file-name "training-child-handshake.el" temporary))
         (grammar '(:type "done" :length 4 :allow "ab "))
         (model (nl-llm-agent-improve-model
                 2 2 nl-llm-agent-char-vocab 1 1))
         (evaluate (nl-llm-agent-evolve-p5-evaluator [" a"]))
         (initial-score (funcall evaluate model))
         (registry (nl-llm-agent-provider-registry-new))
         (tools (nl-agent-tool-registry-new))
         (policy
          (nl-agent-permission-policy-new
           :mode 'smart
           :approval
           (nl-agent-autonomy-improvement-approval "native" "background")))
         (remote-replies
          (list
           (concat
            "```tool\n"
            "(:name \"model.improvement.run\" "
            ":arguments (:id \"background-job\"))\n"
            "```")
           "DONE service remained live"
           (concat
            "```tool\n"
            "(:name \"service.model.switch\" "
            ":arguments (:selector \"native/background-g1\"))\n"
            "```")))
         router queue runner supervisor service-worker
         child-ready child-release ready-observed child-live-observed
         request-kind-observed request-payload-observed
         same-worker-observed inference-events loaded-native-model
         native-prompt-length native-maxseq native-inference-seconds
         native-decode-block-compiled native-decode-step-compiled)
    (unwind-protect
        (progn
          (nl-agent-background-service-test--write-handshake-fixture
           handshake-fixture)
          (when (eq objective 'completion)
            (setq catalog-file
                  (expand-file-name "state/catalog.json" temporary)
                  checkpoint-file
                  (expand-file-name "state/queue.sexp" temporary))
            (make-directory (file-name-directory catalog-file) t)
            (nl-agent-background-service-test--write-completion-config
             config-file))
          (nl-llm-agent-artifact-publish
           catalog-file (nl-llm-agent-artifact-export-pav model)
           :id "baseline-g0" :name "Initial local model"
           :grammar grammar :maxseq 4096
           :score initial-score :generation 0)
          (if (eq objective 'completion)
              (let ((assembly
                     (nl-agent-improvement-config-load config-file)))
                (setq queue (plist-get assembly :queue)
                      runner (plist-get assembly :runner)))
            (setq queue
                  (nl-llm-agent-evolve-p5-queue
                   model evaluate catalog-file grammar
                   :id-prefix "background" :min-delta 0.0 :maxseq 4096))
            (setf (nl-llm-evolve-queue-checkpoint-file queue) checkpoint-file)
            (nl-llm-evolve-queue-submit
             queue "trajectory-finetune"
             '(:examples [" a"] :lr 0.1 :epochs 4)
             :id "background-job")
            (setq runner
                  (nl-agent-training-runner-new
                   queue
                   (list :scope (make-string 64 ?0)
                         :benchmark [" a"]
                         :training '(:backend cpu :sequence 8 :optimizer sgd)
                         :directory temporary
                         :catalog-file catalog-file))))
          (when (eq objective 'completion)
            (nl-llm-evolve-queue-submit
             queue "supervised-finetune"
             '(:examples [(:prompt "  " :completion "a")]
               :lr 0.1 :epochs 4)
             :id "background-job"))
          (nl-agent-improvement-register-tools tools queue runner)
          (nl-llm-agent-provider-register
           registry
           (nl-llm-agent-provider-new
            "remote" :models '("model")
            :open (lambda (model-id _options) model-id)
            :complete
            (lambda (_state _messages)
              (let ((reply (pop remote-replies)))
                (unless reply (error "unexpected remote completion"))
                ;; The tool result is visible to this second turn of the same
                ;; conversation.  Observe the child before returning DONE.
                (when (= (length remote-replies) 1)
                  (setq child-ready
                        (expand-file-name
                         "child.ready"
                         (nl-agent-training-runner-workdir runner))
                        child-release
                        (expand-file-name
                         "child.release"
                         (nl-agent-training-runner-workdir runner))
                        ready-observed
                        (nl-agent-background-service-test--wait-for-file
                         child-ready
                         (nl-agent-training-runner-process runner) 5.0)
                        child-live-observed
                        (process-live-p
                         (nl-agent-training-runner-process runner))
                        request-kind-observed
                        (plist-get
                         (nl-agent-training-protocol-read
                          (nl-agent-training-runner-request-file runner))
                         :kind)
                        request-payload-observed
                        (plist-get
                         (nl-agent-training-protocol-read
                          (nl-agent-training-runner-request-file runner))
                         :payload)
                        same-worker-observed
                        (eq service-worker
                            (nl-agent-supervisor-process supervisor))))
                reply))))
          (nl-llm-agent-provider-register
           registry
           (nl-llm-agent-artifact-provider "native" catalog-file))
          (setq router (nl-agent-host-router-new registry))
          (nl-agent-service-tools-register tools router)
          (setq supervisor
                (nl-agent-supervisor-new
                 (list nelisp "--load" worker-fixture)
                 :directory project-directory
                 :await-ready t
                 :max-requests 20
                 :timeout-sec 10
                 :model-catalog
                 (nl-agent-host-model-catalog-function router)
                 :inference
                 (lambda (event)
                   (setq inference-events
                         (append inference-events
                                 (list (copy-tree event))))
                   (funcall (nl-agent-host-inference-function router) event))
                 :tool (nl-agent-host-tool-function tools policy)
                 :tool-catalog
                 (nl-agent-host-tool-catalog-function tools)))
          ;; Establish the service process before the training child exists.
          (nl-agent-supervisor-start supervisor)
          (setq service-worker (nl-agent-supervisor-process supervisor))
          (let ((real-start-process (symbol-function 'start-process))
                (process-environment
                 (cons
                  "NL_AGENT_BACKGROUND_TEST_SECRET=must-not-reach-child"
                  process-environment)))
            (cl-letf
                (((symbol-function 'start-process)
                  (lambda (name buffer program &rest arguments)
                    (apply
                     real-start-process name buffer program
                       (if (equal name "nl-agent-training-worker")
                         (nl-agent-background-service-test--inject-fixture
                          arguments handshake-fixture)
                       arguments)))))
              (let ((response
                     (nl-agent-supervisor-call
                      supervisor
                      '(run "start background training and continue"))))
                (should (eq (plist-get response :status) 'done))
                (should (equal (plist-get response :result)
                               "service remained live")))))
          (should ready-observed)
          (should child-live-observed)
          (should same-worker-observed)
          (if (eq objective 'completion)
              (progn
                (should (equal request-kind-observed "supervised-finetune"))
                (should
                 (equal request-payload-observed
                        '(:examples [(:prompt "  " :completion "a")]
                          :lr 0.1 :epochs 4))))
            (should-not request-kind-observed))
          (should (= (length remote-replies) 1))
          (should (nl-agent-supervisor-live-p supervisor))
          (should (process-live-p
                   (nl-agent-training-runner-process runner)))
          (with-temp-file child-release (insert "release\n"))
          (let ((deadline (+ (float-time) 10.0)))
            (while (and (nl-agent-training-runner-process runner)
                        (< (float-time) deadline))
              (accept-process-output
               (nl-agent-training-runner-process runner) 0.1)
              (nl-agent-training-runner-poll runner)))
          (let ((status (nl-agent-training-runner-status runner)))
            (should-not (plist-get status :worker-running))
            (should (= (plist-get status :generation) 1))
            (should
             (member
              "background-g1"
              (mapcar
               (lambda (entry) (plist-get entry :id))
               (nl-llm-agent-artifact-catalog catalog-file)))))
          (let* ((worker-before-activation
                  (nl-agent-supervisor-process supervisor))
                 (models (nl-agent-supervisor-call supervisor '(models)))
                 (qualified-models
                  (mapcar
                   (lambda (entry) (plist-get entry :qualified-id))
                   (plist-get models :models)))
                 (checkpoint-before
                  (plist-get
                   (nl-agent-supervisor-call supervisor '(checkpoint))
                   :checkpoint))
                 (failed
                  (nl-agent-supervisor-call
                   supervisor '(switch "native/background-g999")))
                 (checkpoint-after-failure
                  (plist-get
                   (nl-agent-supervisor-call supervisor '(checkpoint))
                   :checkpoint)))
            (should (member "native/background-g1" qualified-models))
            (should (eq (plist-get failed :status) 'error))
            (should (equal (plist-get checkpoint-after-failure :model)
                           "remote/model"))
            (should
             (equal (plist-get checkpoint-after-failure :messages)
                    (plist-get checkpoint-before :messages)))
            (let ((real-model-policy
                   (symbol-function 'nl-llm-agent-model-policy)))
              (cl-letf
                  (((symbol-function 'nl-llm-agent-model-policy)
                    (lambda (native-model native-grammar &optional maxseq)
                      (setq loaded-native-model native-model)
                      (setq native-maxseq maxseq)
                      (let ((delegate
                             (funcall real-model-policy
                                      native-model native-grammar maxseq)))
                        (lambda (messages)
                          (setq native-prompt-length
                                (length (nl-llm-agent--render messages)))
                          (let ((started (float-time)))
                            (prog1
                                (funcall delegate messages)
                              (setq native-inference-seconds
                                    (- (float-time) started))
                              (setq native-decode-block-compiled
                                    (byte-code-function-p
                                     (symbol-function
                                      'nl-llm-decode-block)))
                              (setq native-decode-step-compiled
                                    (byte-code-function-p
                                     (symbol-function
                                      'nl-llm-decode-step))))))))))
                (let* ((activation
                        (nl-agent-supervisor-call
                         supervisor
                         '(run "activate the published native generation")))
                       (status
                        (nl-agent-supervisor-call supervisor '(status)))
                       (checkpoint-after
                        (plist-get
                         (nl-agent-supervisor-call supervisor '(checkpoint))
                         :checkpoint))
                       (before-messages
                        (plist-get checkpoint-before :messages))
                       (after-messages
                        (plist-get checkpoint-after :messages))
                       (promoted
                        (nl-llm-agent-artifact-export-pav
                         (nl-llm-agent-artifact-load-pav
                          catalog-file "background-g1")))
                       (native-event (car (last inference-events))))
                  (should (eq nl-llm-agent-model-inference-mode 'auto))
                  (should (eq (plist-get activation :status) 'done))
                  (should (eq worker-before-activation
                              (nl-agent-supervisor-process supervisor)))
                  (should (equal (plist-get status :model)
                                 "native/background-g1"))
                  (should (= (plist-get status :generation) 1))
                  (should (equal (plist-get native-event :provider) "native"))
                  (should (equal (plist-get native-event :model)
                                 "background-g1"))
                  (should (null remote-replies))
                  (should
                   (equal
                    (mapcar (lambda (event) (plist-get event :provider))
                            inference-events)
                    '("remote" "remote" "remote" "native")))
                  (should loaded-native-model)
                  (should (and (integerp native-prompt-length)
                               (> native-prompt-length 0)))
                  (should (= native-maxseq 4096))
                  (should (and (numberp native-inference-seconds)
                               (>= native-inference-seconds 0.0)))
                  (should native-decode-block-compiled)
                  (should native-decode-step-compiled)
                  (message
                   (concat
                    "background native inference: prompt=%d maxseq=%d "
                    "elapsed=%.3fs decode-block=byte-code decode-step=byte-code")
                   native-prompt-length native-maxseq
                   native-inference-seconds)
                  (should
                   (equal
                    (nl-agent-background-service-test--model-weights promoted)
                    (nl-agent-background-service-test--model-weights
                     loaded-native-model)))
                  (should (<= (length before-messages)
                              (length after-messages)))
                  (should
                   (equal before-messages
                          (cl-subseq after-messages
                                     0 (length before-messages)))))))))
      (when (and child-release
                 (file-directory-p (file-name-directory child-release))
                 (not (file-exists-p child-release)))
        (with-temp-file child-release (insert "release\n")))
      (when supervisor (ignore-errors (nl-agent-supervisor-stop supervisor)))
      (when runner (ignore-errors (nl-agent-training-runner-stop runner)))
      (when (fboundp 'nl-llm-inference-runtime-prepare)
        (ignore-errors (nl-llm-inference-runtime-prepare 'source)))
      (delete-directory temporary t))))

(ert-deftest nl-agent-background-training-keeps-service-conversation-live ()
  (nl-agent-background-service-test--run-case))

(ert-deftest nl-agent-background-supervised-training-keeps-service-conversation-live ()
  (nl-agent-background-service-test--run-case 'completion))

(provide 'background-service-test)

(ert-run-tests-batch-and-exit)

;;; background-service-test.el ends here
