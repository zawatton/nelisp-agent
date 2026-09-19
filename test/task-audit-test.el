;;; task-audit-test.el --- durable task evidence records -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name "../lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-llm/lisp" here))
  (add-to-list 'load-path (expand-file-name "../../nelisp-photon/lisp" here)))
(require 'nl-agent-task-audit)
(require 'nl-agent-task-eval)
(require 'nl-agent-task-eval-service)
(require 'nl-agent-task-promotion)
(require 'nl-agent-training-protocol)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-improve)

(defun nl-agent-task-audit-test--policy ()
  "Return a small valid policy with Unicode task data."
  (nl-agent-task-promotion-policy
   (list :suite
         (list :id "audit-suite-日本" :version "1"
               :cases
               (vector
                (list :id "unicode-case" :task "状態を確認して終了"
                      :files (vector (list :path "メモ.txt" :text "旧"))
                      :expected (vector (list :path "メモ.txt" :text "新")))))
         :grammar '(:type "done" :length 1 :allow "ab")
         :max-sequence 4096 :max-steps 1)))

(defun nl-agent-task-audit-test--request (policy)
  "Return a valid CPU request carrying POLICY and a float score."
  (nl-agent-training-protocol-validate-request
   (list :format nl-agent-training-protocol-format
         :attempt "audit-attempt-1" :job-id "audit-job"
         :parent-generation 0 :parent-score -0.123456789
         :scope (make-string 64 ?c)
         :payload '(:examples [" ab"] :lr 0.0123456789 :epochs 1)
         :parent-model
         (nl-llm-agent-artifact-export-pav
          (nl-llm-agent-improve-model 2 2 96 1 1))
         :training '(:backend cpu :sequence 8 :optimizer sgd)
         :benchmark [" ab"]
         :task-promotion policy)))

(defun nl-agent-task-audit-test--evidence (request policy)
  "Return valid negative evidence without invoking a real task service."
  (let ((model (nl-agent-training-protocol-import
                (plist-get request :parent-model))))
    (cl-letf (((symbol-function 'nl-agent-task-eval-service-run)
               (lambda (suite _registry model-id &rest keys)
                 (nl-agent-task-eval-run
                  suite (lambda (&rest _args)
                          (list :status 'done :steps 1 :result nil
                                :messages nil :trajectory nil))
                  :model-id model-id :runner-id
                  nl-agent-task-eval-service-runner-id
                  :max-steps (plist-get keys :max-steps)))))
      (nl-agent-task-promotion-evaluate
       model model (plist-get policy :suite) (plist-get policy :grammar)
       :max-sequence (plist-get policy :max-sequence)
       :max-steps (plist-get policy :max-steps)))))

(defun nl-agent-task-audit-test--fixture ()
  "Return a temporary audit fixture with protocol-valid request/result."
  (let* ((tmp (make-temp-file "nl-task-audit-test-" t))
         (audit (expand-file-name "audit" tmp))
         (policy (nl-agent-task-audit-test--policy))
         (request (nl-agent-task-audit-test--request policy))
         (request-file (expand-file-name "request.sexp" tmp))
         (request-sha nil)
         (evidence (nl-agent-task-audit-test--evidence request policy))
         (result nil))
    (nl-agent-training-protocol-write request-file request)
    (setq request-sha (nl-agent-training-protocol-hash request-file))
    (setq result
          (list :format nl-agent-training-result-format
                :attempt (plist-get request :attempt)
                :request-sha256 request-sha
                :score -0.123456789
                :model (plist-get request :parent-model)
                :task-promotion evidence))
    (nl-agent-training-protocol-validate-result result request)
    (list :tmp tmp :audit audit :request request :result result
          :request-sha request-sha)))

(defun nl-agent-task-audit-test--cleanup (fixture)
  (when (file-directory-p (plist-get fixture :tmp))
    (delete-directory (plist-get fixture :tmp) t)))

(defun nl-agent-task-audit-test--without-key (plist key)
  "Return PLIST without KEY, preserving the remaining wire order."
  (let (result)
    (while plist
      (let ((name (pop plist)) (value (pop plist)))
        (unless (eq name key)
          (setq result (append result (list name (copy-tree value t)))))))
    result))

(ert-deftest nl-agent-task-audit-save-load-idempotent-and-mode ()
  (let* ((fixture (nl-agent-task-audit-test--fixture))
         (audit (plist-get fixture :audit))
         (request (plist-get fixture :request))
         (result (plist-get fixture :result))
         (hash (plist-get fixture :request-sha)))
    (unwind-protect
        (let* ((path (nl-agent-task-audit-save audit request result hash))
               (again (nl-agent-task-audit-save audit request result hash))
               (record
                (nl-agent-task-audit-read
                 audit (plist-get request :scope)
                 (plist-get request :job-id) (plist-get request :attempt))))
          (should (equal path again))
          (should (equal (plist-get record :format) nl-agent-task-audit-format))
          (should (equal (plist-get record :request) request))
          (should (= (logand (file-modes path) #o777) #o600)))
      (nl-agent-task-audit-test--cleanup fixture))))

(ert-deftest nl-agent-task-audit-rejects-policy-tuple-tamper-and-bounds ()
  (let* ((fixture (nl-agent-task-audit-test--fixture))
         (audit (plist-get fixture :audit))
         (request (plist-get fixture :request))
         (result (plist-get fixture :result))
         (hash (plist-get fixture :request-sha)))
    (unwind-protect
        (progn
          (should-error
           (nl-agent-task-audit-save
            audit (plist-put (copy-tree request t) :task-promotion nil)
            result hash))
          (should-not (file-directory-p audit))
          (nl-agent-task-audit-save audit request result hash)
          (should-error
           (nl-agent-task-audit-read audit (make-string 64 ?d)
                                     (plist-get request :job-id)
                                     (plist-get request :attempt)))
          (let ((path (nl-agent-task-audit--path
                       audit (plist-get request :scope)
                       (plist-get request :job-id)
                       (plist-get request :attempt))))
            (with-temp-file path
              (insert "(:format \"nl-agent-task-audit-v1\")"))
            (should-error
             (nl-agent-task-audit-read audit (plist-get request :scope)
                                       (plist-get request :job-id)
                                       (plist-get request :attempt)))))
      (nl-agent-task-audit-test--cleanup fixture))))

(ert-deftest nl-agent-task-audit-rejects-no-policy-and-record-conflict ()
  (let* ((fixture (nl-agent-task-audit-test--fixture))
         (audit (plist-get fixture :audit))
         (request (plist-get fixture :request))
         (result (plist-get fixture :result))
         (hash (plist-get fixture :request-sha)))
    (unwind-protect
        (progn
          ;; Remove both optional task fields and recompute the canonical
          ;; request hash: this is a true legacy pair, not a malformed policy.
          (let* ((legacy-request
                  (nl-agent-task-audit-test--without-key
                   request :task-promotion))
                 (legacy-result
                  (nl-agent-task-audit-test--without-key
                   result :task-promotion))
                 (request-file (make-temp-file "nl-audit-legacy-"))
                 legacy-hash)
            (unwind-protect
                (progn
                  (nl-agent-training-protocol-write request-file legacy-request)
                  (setq legacy-hash
                        (nl-agent-training-protocol-hash request-file))
                  (setq legacy-result
                        (plist-put legacy-result :request-sha256 legacy-hash))
                  (nl-agent-training-protocol-validate-request legacy-request)
                  (nl-agent-training-protocol-validate-result
                   legacy-result legacy-request)
                  (condition-case err
                      (progn
                        (nl-agent-task-audit-save
                         audit legacy-request legacy-result legacy-hash)
                        (ert-fail "legacy audit unexpectedly accepted"))
                    (error
                     (should (equal
                              (error-message-string err)
                              "task audit requires a task-promotion policy")))))
              (when (file-exists-p request-file)
                (delete-file request-file))))
          (nl-agent-task-audit-save audit request result hash)
          (should-error
           (nl-agent-task-audit-save
            audit request (plist-put (copy-tree result t) :score 99.0) hash)))
      (nl-agent-task-audit-test--cleanup fixture))))

(ert-deftest nl-agent-task-audit-rejects-dangling-symlink ()
  (let* ((fixture (nl-agent-task-audit-test--fixture))
         (audit (plist-get fixture :audit))
         (request (plist-get fixture :request))
         (result (plist-get fixture :result))
         (hash (plist-get fixture :request-sha)))
    (unwind-protect
        (progn
          (make-directory audit t)
          (let ((path (nl-agent-task-audit--path
                       audit (plist-get request :scope)
                       (plist-get request :job-id)
                       (plist-get request :attempt))))
            (make-symbolic-link "missing-record" path)
            (should-error
             (nl-agent-task-audit-save audit request result hash))))
      (nl-agent-task-audit-test--cleanup fixture))))

(provide 'task-audit-test)
(ert-run-tests-batch-and-exit)
;;; task-audit-test.el ends here
