;;; cli-recurrent-test.el --- recurrent CLI startup tests -*- lexical-binding: t; -*-

;;; Code:

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name "../lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-llm/lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-photon/lisp" here)))

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'nl-agent-cli)
(require 'nl-agent-recurrent-config)
(require 'nl-agent-supervisor)
(require 'nl-llm-agent-provider)
(require 'nl-llm-agent-recur-artifact)
(require 'nl-llm-recur)

(defun nl-agent-cli-recurrent-test--error-p (function)
  "Return non-nil when FUNCTION signals an ordinary error."
  (condition-case nil
      (progn (funcall function) nil)
    (error t)))

(defun nl-agent-cli-recurrent-test--model (&optional seed)
  "Build a small UTF-8 recurrent artifact model for integration tests."
  (nl-llm-recur-model-new
   :vocab 256 :dim 2 :heads 1 :kv-heads 1 :ff 2
   :n-prelude 0 :n-core 1 :n-coda 0 :seed (or seed 17) :sigma 0.1))

(defun nl-agent-cli-recurrent-test--config (directory)
  "Create two tiny recurrent artifacts and return the manifest path."
  (let* ((first (expand-file-name "tiny.sexp" directory))
         (second (expand-file-name "tiny-alt.sexp" directory))
         (manifest (expand-file-name "recurrent.json" directory))
         (model (nl-agent-cli-recurrent-test--model))
         (saved-first (nl-llm-agent-recur-artifact-save first model))
         (saved-second
          (nl-llm-agent-recur-artifact-save second
                                            (nl-agent-cli-recurrent-test--model 18))))
    (with-temp-file manifest
      (insert
       (format
        "{\"format\":\"nl-agent-recurrent-config-v1\",\"id\":\"recurrent\",\"name\":\"Tiny recurrent\",\"models\":[{\"id\":\"tiny\",\"path\":\"tiny.sexp\",\"sha256\":\"%s\",\"grammar\":{\"type\":\"template\",\"segments\":[{\"slot\":\"ab\"}]},\"maxseq\":4096},{\"id\":\"tiny-alt\",\"path\":\"tiny-alt.sexp\",\"sha256\":\"%s\",\"grammar\":{\"type\":\"template\",\"segments\":[{\"slot\":\"ab\"}]},\"maxseq\":4096}]}\n"
        (plist-get saved-first :sha256)
        (plist-get saved-second :sha256)))
      (should-not (equal (plist-get saved-first :sha256)
                         (plist-get saved-second :sha256))))
    manifest))

(ert-deftest nl-agent-cli-recurrent-flag-and-environment-boundary ()
  "The explicit recurrent manifest flag wins over its environment fallback."
  (let ((old (getenv "NELISP_AGENT_RECURRENT_CONFIG")))
    (unwind-protect
        (progn
          (setenv "NELISP_AGENT_RECURRENT_CONFIG" "from-environment.json")
          (should
           (equal (plist-get
                   (nl-agent-cli-parse-args
                    '("--recurrent-config" "from-flag.json"))
                   :recurrent-config)
                  "from-flag.json"))
          (should (equal (plist-get
                          (nl-agent-cli-options-with-environment nil)
                          :recurrent-config)
                         "from-environment.json"))
          (should (equal (plist-get
                          (nl-agent-cli-options-with-environment
                           '(:recurrent-config "from-flag.json"))
                          :recurrent-config)
                         "from-flag.json")))
      (setenv "NELISP_AGENT_RECURRENT_CONFIG" old))))

(ert-deftest nl-agent-cli-recurrent-flag-rejects-missing-and-duplicates ()
  "A manifest option has exactly one non-option value."
  (should (nl-agent-cli-recurrent-test--error-p
           (lambda () (nl-agent-cli-parse-args '("--recurrent-config")))))
  (should (nl-agent-cli-recurrent-test--error-p
           (lambda ()
             (nl-agent-cli-parse-args
              '("--recurrent-config" "a.json"
                "--recurrent-config" "b.json")))))
  (should (string-match-p
           "recurrent"
           nl-agent-cli-help)))

(ert-deftest nl-agent-cli-recurrent-config-is-appended-to-native-providers ()
  "CLI loads one validated provider and passes it through the native list."
  (let ((provider
         (nl-llm-agent-provider-new
          "recurrent" :models '("tiny")
          :open (lambda (_id _options) nil)
          :complete (lambda (_state _messages) "a")))
        captured)
    (cl-letf (((symbol-function 'nl-agent-recurrent-config-load)
               (lambda (_file) provider))
              ((symbol-function 'nl-agent-example-free-supervisor)
               (lambda (&rest args)
                 (setq captured args)
                 'fake-supervisor)))
      (should (eq (nl-agent-cli--supervisor
                   '(:recurrent-config "manifest.json"
                     :model "recurrent/tiny") nil)
                  'fake-supervisor))
      (should (eq (car (last (nth 7 captured))) provider)))))

(ert-deftest nl-agent-cli-recurrent-host-rejects-provider-collision ()
  "The generic registry boundary rejects duplicate provider IDs explicitly."
  (let ((one (nl-llm-agent-provider-new
              "recurrent" :models '("one")
              :open (lambda (_id _options) nil)
              :complete (lambda (_state _messages) "a")))
        (two (nl-llm-agent-provider-new
              "recurrent" :models '("two")
              :open (lambda (_id _options) nil)
              :complete (lambda (_state _messages) "b"))))
    (should (nl-agent-cli-recurrent-test--error-p
             (lambda ()
               (nl-agent-example-free-supervisor
                "../nelisp/target/nelisp" nil nil nil nil nil nil
                (list one two) nil nil "recurrent/one"))))))

(ert-deftest nl-agent-cli-recurrent-packaged-worker-is-native-only ()
  "A real tiny recurrent manifest serves the packaged worker without HTTP."
  (let* ((directory (make-temp-file "nl-agent-recurrent-cli-" t))
         (manifest (nl-agent-cli-recurrent-test--config directory))
         (checkpoint (expand-file-name "session.sexp" directory))
         (project (file-name-directory
                   (directory-file-name
                    (file-name-directory
                     (or load-file-name buffer-file-name)))))
         (nelisp (expand-file-name "../nelisp/target/nelisp" project))
         (options
          (list :nelisp nelisp :recurrent-config manifest
                :model "recurrent/tiny" :checkpoint checkpoint
                :workspace directory :unattended t))
         (supervisor nil)
         (restarted nil)
         (history nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _args)
                       (error "recurrent test attempted network access")))
                    ((symbol-function 'nl-llm-agent-openai-provider)
                     (lambda (&rest _args)
                       (error "recurrent test attempted remote provider"))))
            (setq supervisor (nl-agent-cli--supervisor options nil))
            (should (member "free-models-worker.el"
                            (mapcar #'file-name-nondirectory
                                    (nl-agent-supervisor-command supervisor))))
            (let ((models (nl-agent-supervisor-call supervisor '(models)))
                  (status (nl-agent-supervisor-call supervisor '(status))))
              (should (eq (plist-get models :status) 'ok))
              (should (member "recurrent/tiny"
                              (mapcar (lambda (item)
                                        (plist-get item :qualified-id))
                                      (plist-get models :models))))
              (should (equal (plist-get status :model) "recurrent/tiny")))
            (let ((reply (nl-agent-supervisor-call supervisor '(chat "hello"))))
              (should (eq (plist-get reply :status) 'ok))
              (should (string-match-p "\\`[ab]\\'" (plist-get reply :text))))
            (let ((checkpoint
                   (nl-agent-supervisor-call supervisor '(checkpoint))))
              (should (eq (plist-get checkpoint :status) 'ok))
              (setq history
                    (copy-tree
                     (plist-get (plist-get checkpoint :checkpoint) :messages))))
            (let ((switched
                   (nl-agent-supervisor-call
                    supervisor '(switch "recurrent/tiny-alt"))))
              (should (eq (plist-get switched :status) 'ok)))
            (nl-agent-supervisor-stop supervisor)
            (setq supervisor nil)
            (setq restarted (nl-agent-cli--supervisor options nil))
            (let ((status (nl-agent-supervisor-call restarted '(status)))
                  (checkpoint
                   (nl-agent-supervisor-call restarted '(checkpoint))))
              (should (equal (plist-get status :model) "recurrent/tiny-alt"))
              (should (= (plist-get status :message-count) (length history)))
              (should (equal (plist-get
                              (plist-get checkpoint :checkpoint) :messages)
                             history)))
            (let ((reply (nl-agent-supervisor-call restarted '(chat "again"))))
              (should (eq (plist-get reply :status) 'ok))
              (should (string-match-p "\\`[ab]\\'" (plist-get reply :text))))))
      (when supervisor (nl-agent-supervisor-stop supervisor))
      (when restarted (nl-agent-supervisor-stop restarted))
      (delete-directory directory t))))

(ert-run-tests-batch-and-exit)

;;; cli-recurrent-test.el ends here
