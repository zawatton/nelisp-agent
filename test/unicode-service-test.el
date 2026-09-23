;;; unicode-service-test.el --- UTF-8 training and native service wiring -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'ert)
(require 'cl-lib)
(require 'nl-agent-cli)
(require 'nl-agent-supervisor)
(require 'nl-agent-training-worker)
(require 'nl-agent-training-protocol)
(require 'nl-agent-trajectory)
(require 'nl-agent-curation)
(require 'nl-llm-agent-evolve)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-tokenizer)
(require 'nl-llm-agent-openai)

(defun nl-agent-unicode-service-test--worker-source ()
  "Return the training worker source path."
  (concat
   (file-name-sans-extension
    (file-truename (locate-library "nl-agent-training-worker")))
   ".el"))

(defun nl-agent-unicode-service-test--run-child
    (request request-file result-file)
  "Run validated REQUEST in an actual isolated CPU worker."
  (let* ((worker (nl-agent-unicode-service-test--worker-source))
         (directory (file-name-directory worker))
         (output (generate-new-buffer " *unicode-training-worker*"))
         status)
    (unwind-protect
        (progn
          (nl-agent-training-protocol-write request-file request)
          (setq status
                (call-process
                 (or (getenv "EMACS") "emacs") nil output nil
                 "-Q" "--batch" "--eval" "(setq load-prefer-newer t)"
                 "-L" (expand-file-name "../../nelisp-photon/lisp" directory)
                 "-L" (expand-file-name "../../nelisp-llm/lisp" directory)
                 "-L" directory "-l" worker "--funcall"
                 "nl-agent-training-worker-main" request-file result-file))
          (unless (= status 0)
            (error "Unicode training child failed: %s"
                   (with-current-buffer output (buffer-string))))
          (nl-agent-training-protocol-read result-file))
      (kill-buffer output))))

(defun nl-agent-unicode-service-test--subsequence-p (needle haystack)
  "Return non-nil when token list NEEDLE occurs contiguously in HAYSTACK."
  (let ((tail haystack)
        found)
    (while (and tail (not found))
      (when (equal needle (cl-subseq tail 0 (min (length needle)
                                                 (length tail))))
        (setq found (= (length needle)
                       (length (cl-subseq tail 0 (length needle))))))
      (setq tail (cdr tail)))
    found))

(ert-deftest nl-agent-unicode-curation-trains-reloads-and-serves-native ()
  (let* ((project-directory default-directory)
         (nelisp
          (expand-file-name
           (or (getenv "NELISP_BIN") "../nelisp/target/nelisp")
           project-directory))
         (directory (make-temp-file "nl-agent-unicode-service-" t))
         (workspace (expand-file-name "workspace" directory))
         (records (expand-file-name "records" directory))
         (catalog (expand-file-name "catalog.json" directory))
         (bad-catalog (expand-file-name "bad-catalog.json" directory))
         (request-file (expand-file-name "request.sexp" directory))
         (result-file (expand-file-name "result.sexp" directory))
         (tokenizer nl-llm-agent-tokenizer-utf8)
         (initial (nl-llm-agent-improve-model 2 2 nil 1 1 tokenizer))
         (parent (nl-llm-agent-artifact-export-pav initial))
         (request
          (list :format nl-agent-training-protocol-format
                :attempt "unicode-a1" :job-id "unicode-j1"
                :parent-generation 0 :parent-score 0.0
                :scope (make-string 64 ?1)
                :payload '(:examples ["学習"] :lr 0.05 :epochs 1)
                :parent-model parent
                :training '(:backend cpu :sequence 32 :optimizer sgd)
                :benchmark ["評価"] ))
         (worker-result nil)
         (model nil)
         (benchmark (nl-llm-agent-evolve-p5-evaluator ["評価 日本"] tokenizer))
         (initial-score nil)
         (queue nil)
         (curator nil)
         (provider nil)
         (record-id nil)
         (inference-count 0)
         (native-phase nil)
         (native-prefill-ids nil)
         (native-step-ids nil)
         (approvals nil)
         (supervisor nil))
    (unwind-protect
        (progn
          (make-directory workspace)
          (make-directory records)
          (setq worker-result
                (nl-agent-unicode-service-test--run-child
                 request request-file result-file))
          (nl-agent-training-protocol-validate-result worker-result request)
          (should (equal
                   (plist-get (plist-get (plist-get worker-result :model)
                                         :config)
                              :tokenizer)
                   tokenizer))
          (setq model
                (nl-agent-training-protocol-import
                 (plist-get worker-result :model))
                initial-score (funcall benchmark model)
                queue
                (nl-llm-agent-evolve-p5-queue
                 model benchmark catalog
                 '(:type "template" :segments ["DONE 日本"])
                 :id-prefix "unicode" :min-delta 0.0 :maxseq 8192))
          (nl-llm-agent-artifact-publish
           catalog (nl-llm-agent-artifact-export-pav model)
           :id "unicode-g0" :name "Unicode base"
           :grammar '(:type "template" :segments ["DONE 日本"])
           :maxseq 8192 :score initial-score :generation 0)
          (setq curator
                (nl-agent-curation-new
                 records
                 (lambda (record)
                   (let ((accepted
                          (and (equal (plist-get record :task)
                                      "「成功」と答える")
                               (equal (plist-get record :result) "成功"))))
                     (list :accepted (and accepted t)
                           :reason (if accepted
                                       "literal expected Unicode text verified"
                                     "Unicode task mismatch"))))
                 "unicode-policy-v1" :data-use-approved t
                 :tokenizer tokenizer :lr 0.05 :epochs 1)
                provider
                (nl-llm-agent-artifact-provider "native" catalog))
          (let ((real-encode (symbol-function 'nl-llm-agent-tokenizer-encode))
                (real-step-factory
                 (symbol-function 'nl-llm-agent-model-step-fn)))
            (cl-letf
                (((symbol-function 'url-retrieve-synchronously)
                  (lambda (&rest _arguments)
                    (error "Unicode service attempted external HTTP")))
                 ((symbol-function 'nl-llm-agent-tokenizer-encode)
                  (lambda (text &optional id)
                    (let ((tokens (funcall real-encode text id)))
                      (when (and native-phase
                                 (equal (nl-llm-agent-tokenizer-id id) tokenizer)
                                 (string-match-p "日本語で応答" text))
                        (setq native-prefill-ids (copy-sequence tokens)))
                      tokens)))
                 ((symbol-function 'nl-llm-agent-model-step-fn)
                  (lambda (native-model caches)
                    (let ((step (funcall real-step-factory native-model caches)))
                      (lambda (id)
                        (when native-phase
                          (push id native-step-ids))
                        (funcall step id)))))
                 ((symbol-function 'nl-llm-agent-openai-default-transport)
                  (lambda (_event)
                    (setq inference-count (1+ inference-count))
                    (let
                        ((reply
                          (pcase inference-count
                            (1 "DONE 成功")
                            (2
                             (format
                              (concat
                               "```tool\n"
                               "(:name \"model.improvement.curate\" "
                               ":arguments (:record-id %S))\n```")
                              record-id))
                            (3
                             (let* ((jobs
                                     (plist-get
                                      (nl-llm-evolve-queue-status queue) :jobs))
                                    (id (plist-get (car jobs) :id)))
                               (format
                                (concat
                                 "```tool\n"
                                 "(:name \"model.improvement.run\" "
                                 ":arguments (:id %S))\n```")
                                id)))
                            (4 "DONE 学習完了")
                            (_ (error "unexpected remote Unicode inference")))))
                      (list :choices
                            (list (list :message (list :content reply)))))))
                 ((symbol-function 'nl-agent-cli-interactive-approval)
                  (lambda (approval &rest _arguments)
                    (setq approvals
                          (append approvals (list (copy-tree approval))))
                    'once)))
              (setq supervisor
                    (nl-agent-example-free-supervisor
                     nelisp "https://provider.invalid/v1" nil nil
                     #'nl-agent-cli-interactive-approval workspace nil
                     (list provider) queue nil nil curator))
              (let ((captured
                     (nl-agent-supervisor-call
                      supervisor '(run "「成功」と答える"))))
                (should (eq (plist-get captured :status) 'done))
                (should (equal (plist-get captured :result) "成功"))
                (setq record-id
                      (file-name-nondirectory
                       (nl-agent-trajectory-save
                        records "「成功」と答える" captured))))
              (let ((trained
                     (nl-agent-supervisor-call
                      supervisor '(run "検証済み記録を学習"))))
                (should (eq (plist-get trained :status) 'done))
                (should (equal (plist-get trained :result) "学習完了")))
              (let* ((status (nl-llm-evolve-queue-status queue))
                     (job (car (plist-get status :jobs))))
                (should (= (plist-get status :completed) 1))
                (should (eq (plist-get job :status) 'promoted))
                (should (= (plist-get status :generation) 1))
                (should (> (plist-get status :champion-score) initial-score)))
              (let* ((loaded
                      (nl-llm-agent-artifact-load-pav catalog "unicode-g1"))
                     (exported (nl-llm-agent-artifact-export-pav loaded)))
                (should (equal (plist-get loaded :tokenizer) tokenizer))
                (should (= (plist-get loaded :vocab) 256))
                (should (equal
                         (plist-get (plist-get exported :config) :tokenizer)
                         tokenizer))
                (let ((bad (copy-tree exported t)))
                  (plist-put (plist-get bad :config) :tokenizer nil)
                  (should-error
                   (nl-llm-agent-artifact-publish
                    bad-catalog bad :id "bad" :name "bad"
                    :grammar '(:type "done" :length 1 :allow "a")
                    :maxseq 32 :score 0.0 :generation 0))))
              (should-error
               (nl-llm-agent-improve-model
                2 2 96 1 1 nl-llm-agent-tokenizer-utf8))
              (let ((switched
                     (nl-agent-supervisor-call
                      supervisor '(switch "native/unicode-g1"))))
                (should (eq (plist-get switched :status) 'ok)))
              (setq native-phase t)
              (let ((completion
                     (nl-agent-supervisor-call
                      supervisor '(chat "日本語で応答"))))
                (should (eq (plist-get completion :status) 'ok))
                (should (equal (plist-get completion :text) "DONE 日本")))
              (setq native-step-ids (nreverse native-step-ids))
              (let ((needle
                     (funcall real-encode "日本語で応答" tokenizer)))
                (should native-prefill-ids)
                (should (> (length needle) (length "日本語で応答")))
                (should (nl-agent-unicode-service-test--subsequence-p
                         needle native-prefill-ids))
                (should (>= (length native-step-ids)
                            (length native-prefill-ids)))
                (should
                 (equal native-prefill-ids
                        (cl-subseq native-step-ids
                                   0 (length native-prefill-ids)))))
              (should (= inference-count 4))
              (should
               (equal
                (mapcar (lambda (item) (plist-get item :tool)) approvals)
                '("model.improvement.curate" "model.improvement.run"))))))
      (when supervisor (nl-agent-supervisor-stop supervisor))
      (delete-directory directory t))))

(ert-run-tests-batch-and-exit)

;;; unicode-service-test.el ends here
