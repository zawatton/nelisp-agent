;;; self-evolution-service-test.el --- full promoted self-switch flow  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-llm-agent-evolve)
(require 'nl-agent-improvement)
(require 'nl-agent-service-tools)
(require 'nl-agent-autonomy)
(require 'nl-agent-supervisor)

(defvar nl-agent-self-evolution-test--fail 0)

(defun nl-agent-self-evolution-test--ck (name ok)
  (princ (format "%-72s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-self-evolution-test--fail
                         (1+ nl-agent-self-evolution-test--fail))
                   "FAIL"))))

(defun nl-agent-self-evolution-test--score (model)
  "Return negative loss on a fixed benchmark trajectory."
  (let* ((tokens
          (mapcar #'nl-llm-agent--char->id (append " a" nil)))
         (loss
          (nl-llm-agent--p5-forward
           model (butlast tokens) (apply #'vector (cdr tokens)))))
    (- (aref (photon-tensor-data (pav-value loss)) 0))))

(let* ((project-directory default-directory)
       (nelisp
        (expand-file-name "../nelisp/target/nelisp" project-directory))
       (fixture
        (expand-file-name
         "test/stdio-agent-worker-fixture.el" project-directory))
       (directory (make-temp-file "nl-agent-self-evolution-" t))
       (catalog-file (expand-file-name "catalog.json" directory))
       (grammar '(:type "done" :length 4 :allow "ab "))
       (model (nl-llm-agent-improve-model 2 2 96 1 1))
       (initial-score (nl-agent-self-evolution-test--score model))
       (queue nil)
       (provider-registry (nl-llm-agent-provider-registry-new))
       (router nil)
       (tools (nl-agent-tool-registry-new))
       (policy
        (nl-agent-permission-policy-new
         :mode 'smart
         :approval
         (nl-agent-autonomy-improvement-approval "native" "self")))
       (remote-replies
        (list
         (concat
          "```tool\n"
          "(:name \"model.improvement.submit\" "
          ":arguments (:kind \"trajectory-finetune\" "
          ":payload (:examples [\" a\"] :lr 0.1 :epochs 4) "
          ":id \"self-train\"))\n"
          "```")
         (concat
          "```tool\n"
          "(:name \"model.improvement.run\" "
          ":arguments (:id \"self-train\"))\n"
          "```")
         (concat
          "```tool\n"
          "(:name \"service.model.switch\" "
          ":arguments (:selector \"native/self-g1\"))\n"
          "```")))
       (inference-providers nil)
       (loaded-model nil)
       (supervisor nil))
  (unwind-protect
      (progn
        (nl-llm-agent-artifact-publish
         catalog-file (nl-llm-agent-artifact-export-pav model)
         :id "baseline-g0" :name "Initial local model"
         :grammar grammar :maxseq 4096
         :score initial-score :generation 0)
        (setq queue
              (nl-llm-agent-evolve-p5-queue
               model #'nl-agent-self-evolution-test--score
               catalog-file grammar :id-prefix "self"
               :min-delta 0.0 :maxseq 4096))
        (nl-llm-agent-provider-register
         provider-registry
         (nl-llm-agent-provider-new
          "remote" :models '("model")
          :open (lambda (model-id _options) model-id)
          :complete
          (lambda (_state _messages)
            (or (pop remote-replies)
                (error "unexpected remote completion")))))
        (nl-llm-agent-provider-register
         provider-registry
         (nl-llm-agent-artifact-provider "native" catalog-file))
        (setq router (nl-agent-host-router-new provider-registry))
        (nl-agent-improvement-register-tools tools queue)
        (nl-agent-service-tools-register tools router)
        (cl-letf
            (((symbol-function 'nl-llm-agent-model-policy)
              (lambda (native-model _native-grammar _maxseq)
                (setq loaded-model native-model)
                (lambda (_messages) "DONE self activated"))))
          (setq supervisor
                (nl-agent-supervisor-new
                 (list nelisp "--load" fixture)
                 :directory project-directory :await-ready t
                 :max-requests 20 :timeout-sec 20
                 :model-catalog
                 (nl-agent-host-model-catalog-function router)
                 :inference
                 (lambda (event)
                   (setq inference-providers
                         (append inference-providers
                                 (list (plist-get event :provider))))
                   (funcall (nl-agent-host-inference-function router) event))
                 :tool (nl-agent-host-tool-function tools policy)
                 :tool-catalog (nl-agent-host-tool-catalog-function tools)))
          (nl-agent-supervisor-call supervisor '(status))
          (let* ((worker (nl-agent-supervisor-process supervisor))
                 (result
                  (nl-agent-supervisor-call
                   supervisor '(run "improve and activate yourself")))
                 (status (nl-agent-supervisor-call supervisor '(status)))
                 (trajectory (plist-get result :trajectory))
                 (publication-observation
                  (plist-get (nth 1 trajectory) :observation)))
            (nl-agent-self-evolution-test--ck
             "one agent run submits, evaluates, activates, and finishes on new model"
             (and (eq (plist-get result :status) 'done)
                  (equal (plist-get result :result) "self activated")
                  (equal (plist-get status :model) "native/self-g1")))
            (nl-agent-self-evolution-test--ck
             "measured challenger is committed and published before activation"
             (and (= (nl-llm-evolution-generation
                      (nl-llm-evolve-queue-evolution queue))
                     1)
                  (> (nl-llm-evolution-champion-score
                      (nl-llm-evolve-queue-evolution queue))
                     initial-score)
                  (member
                   "self-g1"
                   (mapcar
                    (lambda (entry) (plist-get entry :id))
                    (nl-llm-agent-artifact-catalog catalog-file)))))
            (nl-agent-self-evolution-test--ck
             "publication provenance becomes model-visible before its switch request"
             (and (stringp publication-observation)
                  (string-match-p ":publication" publication-observation)
                  (string-match-p "self-g1" publication-observation)))
            (nl-agent-self-evolution-test--ck
             "live worker refreshes catalog and next inference uses exported generation"
             (and (eq worker (nl-agent-supervisor-process supervisor))
                  (null remote-replies)
                  (equal inference-providers
                         '("remote" "remote" "remote" "native"))
                  loaded-model
                  (plist-get loaded-model :wh)
                  (= (length (nl-agent-permission-policy-history policy)) 3)
                  (cl-every
                   (lambda (entry)
                     (eq (plist-get entry :source) 'autonomous-scope))
                   (nl-agent-permission-policy-history policy)))))))
    (when supervisor (nl-agent-supervisor-stop supervisor))
    (delete-directory directory t)))

(princ (format "NL-AGENT-SELF-EVOLUTION %s (%d failures)\n"
               (if (= nl-agent-self-evolution-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-self-evolution-test--fail))
(kill-emacs (if (= nl-agent-self-evolution-test--fail 0) 0 1))

;;; self-evolution-service-test.el ends here
