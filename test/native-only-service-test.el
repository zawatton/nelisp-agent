;;; native-only-service-test.el --- packaged native-only CLI service -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'nl-agent-cli)
(require 'nl-agent-supervisor)
(require 'nl-llm-agent-improve)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-openai)

(defun nl-agent-native-only-service-test--clear-environment ()
  "Remove every ambient NeLisp Agent setting from `process-environment'."
  (dolist (entry (copy-sequence process-environment))
    (when (string-prefix-p "NELISP_AGENT_" entry)
      (setenv (car (split-string entry "=")) nil))))

(defun nl-agent-native-only-service-test--publish
    (catalog model id generation)
  "Publish MODEL as ID and GENERATION to CATALOG for real CPU decoding."
  (nl-llm-agent-artifact-publish
   catalog (nl-llm-agent-artifact-export-pav model generation)
   :id id :name (format "Tiny native generation %d" generation)
   :grammar '(:type "done" :length 2 :allow "ab ")
   :maxseq 8192 :score (float generation) :generation generation))

(defun nl-agent-native-only-service-test--options
    (nelisp catalog checkpoint workspace chat)
  "Return real parsed CLI options for the native-only test fixture."
  (nl-agent-cli-parse-args
   (append
    (list "--nelisp" nelisp
          "--native-catalog" catalog
          "--model" "native/tiny-g1"
          "--checkpoint" checkpoint
          "--workspace" workspace
          "--unattended")
    (and chat (list "--chat" chat)))))

(defun nl-agent-native-only-service-test--checkpoint (supervisor)
  "Return a detached service checkpoint from SUPERVISOR."
  (copy-tree
   (plist-get (nl-agent-supervisor-call supervisor '(checkpoint))
              :checkpoint)))

(ert-deftest nl-agent-native-only-packaged-cli-preserves-local-session ()
  (let* ((project-directory default-directory)
         (nelisp
          (expand-file-name
           (or (getenv "NELISP_BIN") "../nelisp/target/nelisp")
           project-directory))
         (worker
          (expand-file-name "examples/free-models-worker.el"
                            project-directory))
         (directory (make-temp-file "nl-agent-native-only-" t))
         (catalog (expand-file-name "catalog.json" directory))
         (checkpoint (expand-file-name "session.sexp" directory))
         (model (nl-llm-agent-improve-model 2 2 96 1 1))
         (process-environment (copy-sequence process-environment))
         (cli-output nil)
         (after-switch-history nil)
         (supervisor nil)
         (restarted nil))
    (unwind-protect
        (progn
          (nl-agent-native-only-service-test--clear-environment)
          (nl-agent-native-only-service-test--publish
           catalog model "tiny-g1" 1)
          ;; Any accidental remote-provider assembly or HTTP fallback makes the
          ;; integration fail at its actual boundary.
          (cl-letf
              (((symbol-function 'nl-llm-agent-openai-provider)
                (lambda (&rest _arguments)
                  (error "native-only CLI attempted to construct OpenAI")))
               ((symbol-function 'nl-llm-agent-openai-default-transport)
                (lambda (&rest _arguments)
                  (error "native-only CLI attempted HTTP transport")))
               ((symbol-function 'url-retrieve-synchronously)
                (lambda (&rest _arguments)
                  (error "native-only CLI attempted a network request")))
               ((symbol-function 'nl-agent-cli--write-line)
                (lambda (text) (setq cli-output (append cli-output (list text))))))
            (let ((exit
                   (nl-agent-cli-run-options
                    (nl-agent-native-only-service-test--options
                     nelisp catalog checkpoint directory "local hello"))))
              (should (= exit 0))
              (should (= (length cli-output) 1))
              (should (string-match-p "\\`DONE [ab ]\\{2\\}\\'"
                                      (car cli-output))))
            (should (file-exists-p checkpoint))

            ;; Re-enter through the same CLI assembler.  This must launch the
            ;; packaged worker and restore the session written by --chat.
            (setq supervisor
                  (nl-agent-cli--supervisor
                   (nl-agent-native-only-service-test--options
                    nelisp catalog checkpoint directory nil)
                   nil))
            (should (member worker (nl-agent-supervisor-command supervisor)))
            (let* ((restored-before
                    (nl-agent-native-only-service-test--checkpoint supervisor))
                   (history (plist-get restored-before :messages)))
              (should (equal (plist-get restored-before :model)
                             "native/tiny-g1"))
              (should (= (length history) 3))
              (should (equal (cdr (nth 1 history)) "local hello"))
              (should (string-match-p "\\`DONE [ab ]\\{2\\}\\'"
                                      (cdr (nth 2 history))))

              (nl-agent-native-only-service-test--publish
               catalog model "tiny-g2" 2)
              (let* ((route (nl-agent-cli-route-line "/models"))
                     (models
                      (nl-agent-supervisor-call
                       supervisor (plist-get route :request)))
                     (descriptors (plist-get models :models))
                     (ids
                      (mapcar (lambda (entry)
                                (plist-get entry :qualified-id))
                              descriptors)))
                (should (equal ids '("native/tiny-g1" "native/tiny-g2")))
                (should (= (plist-get (cadr descriptors) :generation) 2)))

              (let ((before-switch
                     (nl-agent-native-only-service-test--checkpoint supervisor))
                    (switched
                     (nl-agent-supervisor-call
                      supervisor '(switch "native/tiny-g2"))))
                (should (eq (plist-get switched :status) 'ok))
                (should (equal (plist-get switched :model) "native/tiny-g2"))
                (let ((after-switch
                       (nl-agent-native-only-service-test--checkpoint supervisor)))
                  (setq after-switch-history
                        (copy-tree (plist-get after-switch :messages)))
                  (should (equal (plist-get after-switch :messages)
                                 (plist-get before-switch :messages)))
                  (should (equal (plist-get after-switch :model)
                                 "native/tiny-g2")))))

            (nl-agent-supervisor-stop supervisor)
            (setq supervisor nil)
            (setq restarted
                  (nl-agent-cli--supervisor
                   (nl-agent-native-only-service-test--options
                    nelisp catalog checkpoint directory nil)
                   nil))
            (should (member worker (nl-agent-supervisor-command restarted)))
            (let* ((restored-after
                    (nl-agent-native-only-service-test--checkpoint restarted))
                   (status (nl-agent-supervisor-call restarted '(status))))
              (should (equal (plist-get restored-after :model)
                             "native/tiny-g2"))
              (should (equal (plist-get restored-after :messages)
                             after-switch-history))
              (should (equal (plist-get status :model) "native/tiny-g2"))
              (should (= (plist-get status :message-count)
                         (length (plist-get restored-after :messages)))))))
      (when supervisor (nl-agent-supervisor-stop supervisor))
      (when restarted (nl-agent-supervisor-stop restarted))
      (delete-directory directory t))))

(ert-run-tests-batch-and-exit)

;;; native-only-service-test.el ends here
