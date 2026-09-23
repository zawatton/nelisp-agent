;;; native-artifact-service-test.el --- promoted model service integration  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'cl-lib)
(require 'photon-tensor)
(require 'nl-llm-agent-artifact)
(require 'nl-agent-host)
(require 'nl-agent-supervisor)

(defvar nl-agent-native-artifact-test--fail 0)

(defun nl-agent-native-artifact-test--ck (name ok)
  (princ (format "%-69s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-native-artifact-test--fail
                         (1+ nl-agent-native-artifact-test--fail))
                   "FAIL"))))

(defun nl-agent-native-artifact-test--tensor (shape value)
  (let ((size 1))
    (dolist (dimension shape)
      (setq size (* size dimension)))
    (photon-tensor shape (make-vector size (float value)))))

(defun nl-agent-native-artifact-test--model ()
  (let ((tensor (lambda (shape)
                  (nl-agent-native-artifact-test--tensor shape 0.1))))
    (list
     :config '(:dim 2 :heads 1 :kv-heads 1 :ff 2 :vocab 96 :nblocks 1)
     :step 11
     :wte (funcall tensor '(96 2))
     :lnfg (funcall tensor '(2))
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

(let* ((project-directory default-directory)
       (nelisp
        (expand-file-name
         (or (getenv "NELISP_BIN") "../nelisp/target/nelisp")
         project-directory))
       (fixture
        (expand-file-name
         "test/stdio-agent-worker-fixture.el" project-directory))
       (directory (make-temp-file "nl-agent-native-artifact-" t))
       (catalog-file (expand-file-name "catalog.json" directory))
       (native-provider nil)
       (router nil)
       (tools (nl-agent-tool-registry-new))
       (policy (nl-agent-permission-policy-new :mode 'smart))
       (supervisor nil))
  (unwind-protect
      (progn
        (nl-llm-agent-artifact-publish
         catalog-file (nl-agent-native-artifact-test--model)
         :id "champion-g1" :name "Promoted champion"
         :grammar '(:type "done" :length 8 :allow "abc ")
         :maxseq 256 :score 0.8 :generation 1)
        (setq native-provider
              (nl-llm-agent-artifact-provider "native" catalog-file))
        (setq router
              (nl-agent-host-router-new
               (list
                (list :id "remote" :type 'openai
                      :base-url "https://provider.invalid/v1"
                      :models '("model")
                      :transport
                      (lambda (_request)
                        '(:choices
                          ((:message (:content "remote reply"))))))
                native-provider)))
        (setq supervisor
              (nl-agent-supervisor-new
               (list nelisp "--load" fixture)
               :directory project-directory :await-ready t
               :max-requests 20 :timeout-sec 5
               :model-catalog
               (nl-agent-host-model-catalog-function router)
               :inference (nl-agent-host-inference-function router)
               :tool (nl-agent-host-tool-function tools policy)
               :tool-catalog (nl-agent-host-tool-catalog-function tools)))
        (cl-letf
            (((symbol-function 'nl-llm-agent-model-policy)
              (lambda (_model _grammar _maxseq)
                (lambda (_messages) "DONE promoted native"))))
          (let ((models (nl-agent-supervisor-call supervisor '(models))))
            (nl-agent-native-artifact-test--ck
             "standalone service catalog includes the promoted native artifact"
             (member
              "native/champion-g1"
              (mapcar
               (lambda (item) (plist-get item :qualified-id))
               (plist-get models :models)))))
          (let ((worker (nl-agent-supervisor-process supervisor)))
            (nl-llm-agent-artifact-publish
             catalog-file (nl-agent-native-artifact-test--model)
             :id "champion-g2" :name "Promoted champion 2"
             :grammar '(:type "done" :length 8 :allow "abc ")
             :maxseq 256 :score 0.9 :generation 2)
            (let ((models (nl-agent-supervisor-call supervisor '(models))))
              (nl-agent-native-artifact-test--ck
               "live worker discovers a newly published generation in place"
               (and
                (eq worker (nl-agent-supervisor-process supervisor))
                (member
                 "native/champion-g2"
                 (mapcar
                  (lambda (item) (plist-get item :qualified-id))
                  (plist-get models :models)))))))
          (let ((switched
                 (nl-agent-supervisor-call
                  supervisor '(switch "native/champion-g2"))))
            (nl-agent-native-artifact-test--ck
             "service transactionally switches from remote to promoted native"
             (and (eq (plist-get switched :status) 'ok)
                  (equal (plist-get switched :model)
                         "native/champion-g2"))))
          (let ((response
                 (nl-agent-supervisor-call
                  supervisor '(run "use the promoted model"))))
            (nl-agent-native-artifact-test--ck
             "promoted checkpoint drives the standalone agent through host inference"
             (and (eq (plist-get response :status) 'done)
                  (equal (plist-get response :result)
                         "promoted native")
                  (= (plist-get response :steps) 1))))))
    (when supervisor (nl-agent-supervisor-stop supervisor))
    (delete-directory directory t)))

(princ (format "NL-AGENT-NATIVE-ARTIFACT %s (%d failures)\n"
               (if (= nl-agent-native-artifact-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-native-artifact-test--fail))
(kill-emacs (if (= nl-agent-native-artifact-test--fail 0) 0 1))

;;; native-artifact-service-test.el ends here
