;;; cli-native-test.el --- native-only CLI assembly tests -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'ert)
(require 'cl-lib)
(require 'photon-tensor)
(require 'nl-agent-cli)

(defun nl-agent-cli-native-test--tensor (shape value)
  "Return a detached tensor with SHAPE filled by VALUE."
  (let ((size 1))
    (dolist (dimension shape)
      (setq size (* size dimension)))
    (photon-tensor shape (make-vector size (float value)))))

(defun nl-agent-cli-native-test--model ()
  "Return a tiny valid native artifact model."
  (let ((tensor (lambda (shape)
                  (nl-agent-cli-native-test--tensor shape 0.1))))
    (list
     :config '(:dim 2 :heads 1 :kv-heads 1 :ff 2 :vocab 96 :nblocks 1)
     :step 0
     :wte (funcall tensor '(96 2))
     :lnfg (funcall tensor '(2))
     :wh (funcall tensor '(96 2))
     :bh (funcall tensor '(96))
     :blocks
     (list
      (list :ln1g (funcall tensor '(2))
            :wq (funcall tensor '(2 2)) :bq (funcall tensor '(2))
            :wk (funcall tensor '(2 2)) :bk (funcall tensor '(2))
            :wv (funcall tensor '(2 2)) :bv (funcall tensor '(2))
            :wo (funcall tensor '(2 2)) :bo (funcall tensor '(2))
            :ln2g (funcall tensor '(2))
            :wg (funcall tensor '(2 2)) :bg (funcall tensor '(2))
            :wu (funcall tensor '(2 2)) :bu (funcall tensor '(2))
            :wd (funcall tensor '(2 2)) :bd (funcall tensor '(2)))))))

(ert-deftest nl-agent-cli-native-starts-without-remote-provider ()
  "A selected native artifact bootstraps the shipped standalone worker."
  (let* ((project-directory default-directory)
         (nelisp (expand-file-name "../nelisp/target/nelisp"
                                   project-directory))
         (directory (make-temp-file "nl-agent-cli-native-" t))
         (catalog (expand-file-name "catalog.json" directory))
         supervisor openai-called)
    (unwind-protect
        (progn
          (nl-llm-agent-artifact-publish
           catalog (nl-agent-cli-native-test--model)
           :id "native-g1" :name "Native only"
           :grammar '(:type "message" :length 8)
           :maxseq 64 :score 1.0 :generation 1)
          (cl-letf
              (((symbol-function 'nl-llm-agent-openai-provider)
                (lambda (&rest _args)
                  (setq openai-called t)
                  (error "remote provider must not be constructed")))
               ((symbol-function 'nl-llm-agent-model-policy)
                (lambda (_model _grammar _maxseq)
                  (lambda (_messages) "native reply"))))
            (setq supervisor
                  (nl-agent-cli--supervisor
                   (list :nelisp nelisp
                         :workspace project-directory
                         :native-catalog catalog
                         :model "native/native-g1")
                   nil))
            (let ((status
                   (nl-agent-supervisor-call supervisor '(status)))
                  (reply
                   (nl-agent-supervisor-call supervisor '(chat "hello"))))
              (should-not openai-called)
              (should (equal (plist-get status :model)
                             "native/native-g1"))
              (should (equal (plist-get reply :text) "native reply")))))
      (when supervisor (nl-agent-supervisor-stop supervisor))
      (delete-directory directory t))))

(ert-deftest nl-agent-cli-native-rejects-missing-or-empty-selection ()
  "Native-only startup fails before spawning when no artifact is selectable."
  (let* ((directory (make-temp-file "nl-agent-cli-native-empty-" t))
         (catalog (expand-file-name "catalog.json" directory))
         spawned)
    (unwind-protect
        (cl-letf (((symbol-function 'nl-agent-supervisor-new)
                   (lambda (&rest _args)
                     (setq spawned t)
                     'unexpected-supervisor)))
          (should-error
           (nl-agent-cli--supervisor
            (list :native-catalog catalog) nil)
           :type 'error)
          (should-error
           (nl-agent-cli--supervisor
            (list :native-catalog catalog :model "native/missing") nil)
           :type 'error)
          (should-not spawned))
      (delete-directory directory t))))

(ert-deftest nl-agent-cli-native-rejects-unqualified-model-and-orphan-key ()
  "Startup selectors are explicit and credentials require an endpoint."
  (let* ((directory (make-temp-file "nl-agent-cli-native-options-" t))
         (catalog (expand-file-name "catalog.json" directory)))
    (unwind-protect
        (progn
          (nl-llm-agent-artifact-publish
           catalog (nl-agent-cli-native-test--model)
           :id "native-g1" :name "Native only"
           :grammar '(:type "message" :length 8)
           :maxseq 64 :score 1.0 :generation 1)
          (should-error
           (nl-agent-cli--supervisor
            (list :native-catalog catalog :model "native-g1") nil)
           :type 'error)
          (should-error
           (nl-agent-cli--supervisor
            (list :native-catalog catalog :model "native/native-g1"
                  :api-key-env "UNUSED_SECRET")
            nil)
           :type 'error))
      (delete-directory directory t))))

(ert-deftest nl-agent-cli-explicit-native-disables-remote-fallbacks ()
  "An available endpoint does not opt a selected native model into billing."
  (let* ((directory (make-temp-file "nl-agent-cli-mixed-" t))
         (catalog (expand-file-name "catalog.json" directory))
         startup)
    (unwind-protect
        (progn
          (nl-llm-agent-artifact-publish
           catalog (nl-agent-cli-native-test--model)
           :id "native-g1" :name "Native only"
           :grammar '(:type "message" :length 8)
           :maxseq 64 :score 1.0 :generation 1)
          (cl-letf (((symbol-function 'nl-agent-supervisor-new)
                     (lambda (_command &rest keys)
                       (setq startup (plist-get keys :startup-config))
                       'fake-supervisor)))
            (should
             (eq
              (nl-agent-cli--supervisor
               (list :base-url "https://provider.invalid/v1"
                     :native-catalog catalog
                     :model "native/native-g1")
               nil)
              'fake-supervisor)))
          (should
           (equal startup '(:model "native/native-g1" :fallbacks nil))))
      (delete-directory directory t))))

(ert-deftest nl-agent-cli-legacy-remote-keeps-default-and-fallbacks ()
  "Remote startup without --model retains the established model ordering."
  (let (startup)
    (cl-letf (((symbol-function 'nl-agent-supervisor-new)
               (lambda (_command &rest keys)
                 (setq startup (plist-get keys :startup-config))
                 'fake-supervisor)))
      (should
       (eq
        (nl-agent-cli--supervisor
         '(:base-url "https://provider.invalid/v1") nil)
        'fake-supervisor)))
    (should
     (equal
      startup
      (list :model nl-agent-example-default-model
            :fallbacks nl-agent-example-fallback-models)))))

(ert-deftest nl-agent-native-provider-named-remote-has-no-implicit-fallbacks ()
  "A provider id alone never implies that a remote endpoint was configured."
  (let* ((provider
          (nl-llm-agent-provider-new
           "remote" :models '("local-g1")
           :open (lambda (_id _options) nil)
           :complete (lambda (_state _messages) "local")))
         startup)
    (cl-letf (((symbol-function 'nl-agent-supervisor-new)
               (lambda (_command &rest keys)
                 (setq startup (plist-get keys :startup-config))
                 'fake-supervisor)))
      (should
       (eq
        (nl-agent-example-free-supervisor
         "unused" nil nil nil nil default-directory nil
         (list provider) nil nil "remote/local-g1")
        'fake-supervisor)))
    (should
     (equal startup '(:model "remote/local-g1" :fallbacks nil)))))

(provide 'cli-native-test)

(ert-run-tests-batch-and-exit)

;;; cli-native-test.el ends here
