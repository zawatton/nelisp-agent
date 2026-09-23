;;; curation-service-test.el --- verified trajectory to CPU promotion -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'nl-agent-cli)
(require 'nl-agent-supervisor)
(require 'nl-agent-trajectory)
(require 'nl-agent-curation)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-openai)

(defun nl-agent-curation-service-test--file-text (path)
  "Return plain text from PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun nl-agent-curation-service-test--file-bytes (path)
  "Return the literal serialized contents of PATH."
  (with-temp-buffer
    (insert-file-contents-literally path)
    (buffer-string)))

(ert-deftest nl-agent-curation-service-promotes-only-host-verified-record ()
  (let* ((project-directory default-directory)
         (nelisp
          (expand-file-name
           (or (getenv "NELISP_BIN") "../nelisp/target/nelisp")
           project-directory))
         (directory (make-temp-file "nl-agent-curation-service-" t))
         (workspace (expand-file-name "workspace" directory))
         (records (expand-file-name "records" directory))
         (artifact (expand-file-name "e" workspace))
         (catalog (expand-file-name "catalog.json" directory))
         (task "edit e")
         (model (nl-llm-agent-improve-model 2 2 96 1 1))
         ;; Fixed before capture and distinct from every curated transcript.
         ;; This held-out next-token loss is the real promotion gate.
         (benchmark (nl-llm-agent-evolve-p5-evaluator [" ab"]))
         (initial-score (funcall benchmark model))
         (queue
          (nl-llm-agent-evolve-p5-queue
           model benchmark catalog '(:type "done" :length 2 :allow "ab ")
           :id-prefix "curated" :min-delta 0.0 :maxseq 4096))
         (record-id nil)
         (record-path nil)
         (verifier-calls 0)
         (approvals nil)
         (inference-count 0)
         (transport-calls 0)
         (supervisor nil)
         (curator nil)
         (real-record-bytes nil))
    (unwind-protect
        (progn
          (make-directory workspace)
          (make-directory records)
          (with-temp-file artifact (insert "a\n"))
          ;; This fixed host closure checks the requested task, the exact tool
          ;; action, and current external artifact.  A model-claimed DONE alone
          ;; is deliberately insufficient.
          (setq curator
                (nl-agent-curation-new
                 records
                 (lambda (record)
                   (setq verifier-calls (1+ verifier-calls))
                   (let* ((event (car (plist-get record :trajectory)))
                          (call (plist-get event :action))
                          (arguments (and (eq (car-safe call) 'tool)
                                          (nth 2 call)))
                          (accepted
                           (and (equal (plist-get record :task) task)
                                (equal (nl-agent-curation-service-test--file-text
                                        artifact)
                                       "b\n")
                                (equal (nth 1 call) "edit")
                                (equal arguments
                                       '(:path "e" :search "a"
                                         :replace "b")))))
                     (list :accepted (and accepted t)
                           :reason (if accepted
                                       "fixed artifact and action verified"
                                     "external artifact or action mismatch"))))
                 "fixed-file-edit-v1" :data-use-approved t
                 :lr 0.05 :epochs 1))
          (let ((real-transport
                 (symbol-function 'nl-llm-agent-openai-default-transport)))
            (ignore real-transport)
            (cl-letf
                (((symbol-function 'url-retrieve-synchronously)
                  (lambda (&rest _arguments)
                    (error "curation service attempted external HTTP")))
                 ((symbol-function 'nl-llm-agent-openai-default-transport)
                  (lambda (_request)
                    (setq transport-calls (1+ transport-calls)
                          inference-count (1+ inference-count))
                    (let
                        ((reply
                          (pcase inference-count
                            (1
                             (concat
                              "```tool\n"
                              "(:name \"edit\" :arguments "
                              "(:path \"e\" :search \"a\" :replace \"b\"))\n"
                              "```") )
                            (2 "DONE evidence edited")
                            (3
                             (unless record-id
                               (error "record was not saved before curation"))
                             (format
                              (concat
                               "```tool\n"
                               "(:name \"model.improvement.curate\" "
                               ":arguments (:record-id %S))\n"
                               "```")
                              record-id))
                            (4
                             (let* ((jobs
                                     (plist-get
                                      (nl-llm-evolve-queue-status queue)
                                      :jobs))
                                    (id (plist-get (car jobs) :id)))
                               (unless (and id (= (length jobs) 1))
                                 (error "curated job unavailable to model"))
                               (format
                                (concat
                                 "```tool\n"
                                 "(:name \"model.improvement.run\" "
                                 ":arguments (:id %S))\n"
                                 "```")
                                id)))
                            (5 "DONE curated improvement promoted")
                            (_ (error "unexpected repeated inference")))))
                      (list :choices
                            (list (list :message (list :content reply)))))))
                 ((symbol-function 'nl-agent-cli-interactive-approval)
                  (lambda (request &rest _arguments)
                    (setq approvals
                          (append approvals (list (copy-tree request))))
                    'once)))
              (setq supervisor
                    (nl-agent-example-free-supervisor
                     nelisp "https://provider.invalid/v1"
                     nil nil #'nl-agent-cli-interactive-approval workspace
                     nil nil queue nil nil curator))
              (let* ((worker (progn
                               (nl-agent-supervisor-start supervisor)
                               (nl-agent-supervisor-process supervisor)))
                     (captured
                      (nl-agent-supervisor-call
                       supervisor (list 'run task))))
                (should (eq (plist-get captured :status) 'done))
                (should (equal (plist-get captured :result)
                               "evidence edited"))
                (should (equal
                         (nl-agent-curation-service-test--file-text artifact)
                         "b\n"))
                (setq record-path
                      (nl-agent-trajectory-save records task captured)
                      record-id (file-name-nondirectory record-path)
                      real-record-bytes
                      (nl-agent-curation-service-test--file-bytes record-path))

                ;; The same DONE record is rejected when independently checked
                ;; external state no longer has the claimed successful result.
                (with-temp-file artifact (insert "wrong\n"))
                (should-error (nl-agent-curation-prepare curator record-id))
                (should (= (plist-get (nl-llm-evolve-queue-status queue)
                                      :pending)
                           0))
                (should (= (nl-llm-evolution-generation
                            (nl-llm-evolve-queue-evolution queue))
                           0))
                (with-temp-file artifact (insert "b\n"))

                ;; Exact source holdouts fail before trusted evaluation and do
                ;; not enqueue or train anything.
                (let* ((snapshot
                        (nl-agent-trajectory-read-snapshot record-path))
                       (digest (plist-get snapshot :sha256))
                       (holdout-calls 0)
                       (holdout
                        (nl-agent-curation-new
                         records
                         (lambda (_record)
                           (setq holdout-calls (1+ holdout-calls))
                           '(:accepted t :reason "should not run"))
                         "holdout-v1" :data-use-approved t
                         :holdout-digests (list digest))))
                  (should-error
                   (nl-agent-curation-prepare holdout record-id))
                  (should (= holdout-calls 0))
                  (should (= (plist-get (nl-llm-evolve-queue-status queue)
                                        :pending)
                             0)))

                ;; A hostile verifier receives an independent copy.  Mutating
                ;; it cannot alter the immutable source or rendered examples.
                (let* ((mutation-calls 0)
                       (mutation
                        (nl-agent-curation-new
                         records
                         (lambda (record)
                           (setq mutation-calls (1+ mutation-calls))
                           (aset (plist-get record :task) 0 ?X)
                           (aset (plist-get
                                  (car (plist-get record :trajectory))
                                  :assistant)
                                 0 ?X)
                           '(:accepted t :reason "mutation attempted"))
                         "mutation-v1" :data-use-approved t))
                       (prepared
                        (nl-agent-curation-prepare mutation record-id))
                       (examples
                        (append
                         (plist-get (plist-get prepared :payload) :examples)
                         nil)))
                  (should (= mutation-calls 1))
                  (should (string-match-p
                           (regexp-quote task) (car examples)))
                  (should (string-match-p
                           (regexp-quote
                            "(:name \"edit\" :arguments")
                           (car examples)))
                  (should
                   (equal real-record-bytes
                          (nl-agent-curation-service-test--file-bytes
                           record-path))))

                ;; The model can name only the record.  Curated payload and id
                ;; are produced host-side, then the separately approved run
                ;; performs real CPU fine-tuning, fixed evaluation, and publish.
                (let ((promoted
                       (nl-agent-supervisor-call
                        supervisor '(run "curate and run the verified record"))))
                  (should (eq worker (nl-agent-supervisor-process supervisor)))
                  (should (eq (plist-get promoted :status) 'done))
                  (should (equal (plist-get promoted :result)
                                 "curated improvement promoted"))
                  (should (= (nl-llm-evolution-generation
                              (nl-llm-evolve-queue-evolution queue))
                             1))
                  (should (> (nl-llm-evolution-champion-score
                              (nl-llm-evolve-queue-evolution queue))
                             initial-score))
                  (should
                   (member
                    "curated-g1"
                    (mapcar
                     (lambda (entry) (plist-get entry :id))
                     (nl-llm-agent-artifact-catalog catalog))))
                  (let* ((status (nl-llm-evolve-queue-status queue))
                         (jobs (plist-get status :jobs)))
                    (should (= (plist-get status :completed) 1))
                    (should (eq (plist-get (car jobs) :status) 'promoted)))
                  (should (= verifier-calls 2))
                  (should (= transport-calls 5))
                  (should
                   (equal (mapcar (lambda (request)
                                    (plist-get request :tool))
                                  approvals)
                          '("edit" "model.improvement.curate"
                            "model.improvement.run")))
                  (should
                   (cl-every
                    (lambda (request)
                      (member (plist-get request :risk) '(write execute)))
                    approvals))
                  (should
                   (equal real-record-bytes
                          (nl-agent-curation-service-test--file-bytes
                           record-path))))))))
      (when supervisor (nl-agent-supervisor-stop supervisor))
      (delete-directory directory t))))

(ert-run-tests-batch-and-exit)

;;; curation-service-test.el ends here
