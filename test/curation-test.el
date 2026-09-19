;;; curation-test.el --- host-owned trajectory curation tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'nl-agent-curation)

(defmacro nl-agent-curation-test--with-store (binding &rest body)
  "Bind BINDING to a private trajectory store and run BODY."
  (declare (indent 1))
  `(let* ((parent (make-temp-file "nl-agent-curation-test-" t))
          (,binding (expand-file-name "records" parent)))
     (make-directory ,binding)
     (unwind-protect (progn ,@body)
       (delete-directory parent t))))

(defun nl-agent-curation-test--response (&optional status trajectory)
  "Return an agent-run response with optional STATUS and TRAJECTORY."
  (list
   :kind 'agent-run :status (or status 'done)
   :steps (if trajectory (length trajectory) 2)
   :result (and (eq (or status 'done) 'done) "claimed result")
   :messages '((system . "PRIVATE-SESSION") (user . "do not retain"))
   :trajectory
   (or trajectory
       (list
        (list :step 1 :model "native/base" :assistant "call tool"
              :action '(tool "lookup" (:query "RAW-ARG-SECRET"))
              :tool-result '(:status ok :value "RAW-VALUE-SECRET")
              :observation "OBSERVATION: VISIBLE")
        (list :step 2 :model "native/base" :assistant "DONE claimed result"
              :action '(done "claimed result"))))))

(defun nl-agent-curation-test--save (directory task &optional response)
  "Save TASK and RESPONSE in DIRECTORY and return its basename."
  (file-name-nondirectory
   (nl-agent-trajectory-save
    directory task (or response (nl-agent-curation-test--response)))))

(defun nl-agent-curation-test--accept (&optional reason)
  "Return a trusted accepting evaluator using optional REASON."
  (lambda (_record)
    (list :accepted t :reason (or reason "reviewed by host policy"))))

(ert-deftest nl-agent-curation-prepares-role-examples-and-provenance ()
  (nl-agent-curation-test--with-store directory
    (let* ((record-id (nl-agent-curation-test--save directory "solve it"))
           (path (expand-file-name record-id directory))
           (expected-hash
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally path)
              (secure-hash 'sha256 (current-buffer))))
           (context
            (nl-agent-curation-new
             directory (nl-agent-curation-test--accept) "policy/manual-v1"
             :data-use-approved t :lr 0.1 :epochs 2))
           (prepared (nl-agent-curation-prepare context record-id))
           (payload (plist-get prepared :payload))
           (metadata (plist-get prepared :metadata))
           (examples (plist-get payload :examples)))
      (should (= (length examples) 2))
      (should
       (equal
        (aref examples 0)
        (concat
         (nl-llm-agent--render '((user . "TASK: solve it")))
         "call tool")))
      (should
       (equal
        (aref examples 1)
        (concat
         (nl-llm-agent--render
          '((user . "TASK: solve it")
            (assistant . "call tool")
            (user . "OBSERVATION: VISIBLE")))
         "DONE claimed result")))
      (should-not (string-match-p "RAW-ARG-SECRET" (aref examples 1)))
      (should-not (string-match-p "RAW-VALUE-SECRET" (aref examples 1)))
      (should-not (string-match-p "PRIVATE-SESSION" (aref examples 1)))
      (should (equal payload (list :examples examples :lr 0.1 :epochs 2)))
      (should
       (equal metadata
              (list :source-sha256 expected-hash
                    :policy-id "policy/manual-v1"
                    :evidence '(:accepted t :reason "reviewed by host policy")
                    :renderer-version nl-agent-curation-renderer-version
                    :tokenizer "ascii-char-v1")))
      (should-not (string-match-p (regexp-quote directory)
                                  (prin1-to-string metadata))))))

(ert-deftest nl-agent-curation-evaluator-receives-independent-record ()
  (nl-agent-curation-test--with-store directory
    (let* ((record-id (nl-agent-curation-test--save directory "original task"))
           (seen nil)
           (context
            (nl-agent-curation-new
             directory
             (lambda (record)
               (setq seen record)
               (setf (plist-get record :task) "mutated by evaluator")
               (setf (plist-get (car (plist-get record :trajectory)) :assistant)
                     "mutated assistant")
               '(:accepted t :reason "mutation isolation check"))
             "policy/isolation" :data-use-approved t))
           (prepared (nl-agent-curation-prepare context record-id))
           (example (aref (plist-get (plist-get prepared :payload) :examples) 0))
           (stored
            (nl-agent-trajectory-read (expand-file-name record-id directory))))
      (should seen)
      (should (string-match-p "original task" example))
      (should (string-match-p "call tool" example))
      (should-not (string-match-p "mutated" example))
      (should (equal (plist-get stored :task) "original task")))))

(ert-deftest nl-agent-curation-rejects-holdout-before-evaluation ()
  (nl-agent-curation-test--with-store directory
    (let* ((record-id (nl-agent-curation-test--save directory "holdout"))
           (snapshot
            (nl-agent-trajectory-read-snapshot
             (expand-file-name record-id directory)))
           (calls 0)
           (context
            (nl-agent-curation-new
             directory (lambda (_record) (setq calls (1+ calls))
                         '(:accepted t :reason "should not run"))
             "policy/holdout" :data-use-approved t
             :holdout-digests (list (plist-get snapshot :sha256)))))
      (should-error (nl-agent-curation-prepare context record-id))
      (should (= calls 0)))))

(ert-deftest nl-agent-curation-rejects-nondone-empty-and-missing-observation ()
  (nl-agent-curation-test--with-store directory
    (let ((context
           (nl-agent-curation-new
            directory (nl-agent-curation-test--accept) "policy/status"
            :data-use-approved t)))
      (let ((id
             (nl-agent-curation-test--save
              directory "limited"
              (nl-agent-curation-test--response 'limit nil))))
        (should-error (nl-agent-curation-prepare context id)))
      (let ((id
             (nl-agent-curation-test--save
              directory "empty"
              (list :kind 'agent-run :status 'done :steps 0
                    :result "claim" :messages nil :trajectory nil))))
        (should-error (nl-agent-curation-prepare context id)))
      (let* ((events
              (list
               (list :step 1 :model "native/base" :assistant "first"
                     :action '(none))
               (list :step 2 :model "native/base" :assistant "DONE finish"
                     :action '(done "finish"))))
             (id
              (nl-agent-curation-test--save
               directory "missing observation"
               (nl-agent-curation-test--response 'done events))))
        (should-error (nl-agent-curation-prepare context id))))))

(ert-deftest nl-agent-curation-enforces-evaluator-contract-and-denial ()
  (nl-agent-curation-test--with-store directory
    (let ((record-id (nl-agent-curation-test--save directory "evaluate")))
      (dolist (decision
               '((:accepted nil :reason "quality gate denied")
                 (:accepted yes :reason "not boolean")
                 (:accepted t :reason "")
                 (:accepted t :reason "ok" :extra t)
                 (:accepted t :accepted nil :reason "duplicate")))
        (let ((context
               (nl-agent-curation-new
                directory (lambda (_record) decision) "policy/contract"
                :data-use-approved t)))
          (should-error (nl-agent-curation-prepare context record-id)))))))

(ert-deftest nl-agent-curation-constructor-requires-explicit-consent ()
  (nl-agent-curation-test--with-store directory
    (dolist (keys
             '(nil
               (:data-use-approved nil)
               (:data-use-approved t :unknown t)
               (:data-use-approved t :data-use-approved t)
               (:data-use-approved t :holdout-digests ("bad"))
               (:data-use-approved t :lr 0.0)
               (:data-use-approved t :epochs 33)))
      (should-error
       (apply #'nl-agent-curation-new
              directory (nl-agent-curation-test--accept) "policy/id" keys)))
    (should-error
     (nl-agent-curation-new
      directory (nl-agent-curation-test--accept) (make-string 257 ?p)
      :data-use-approved t))))

(ert-deftest nl-agent-curation-rejects-record-path-injection-without-scan ()
  (nl-agent-curation-test--with-store directory
    (let ((context
           (nl-agent-curation-new
            directory (nl-agent-curation-test--accept) "policy/path"
            :data-use-approved t)))
      (dolist (record-id
               '("../run-20260101T000000-aaaaaaaaaaaaaaaaaaaaaaaa.sexp"
                 "/tmp/run-20260101T000000-aaaaaaaaaaaaaaaaaaaaaaaa.sexp"
                 "run-not-exact.sexp" ".writer"))
        (cl-letf (((symbol-function 'directory-files)
                   (lambda (&rest _args) (error "directory scan forbidden"))))
          (should-error (nl-agent-curation-prepare context record-id)))))))

(ert-deftest nl-agent-curation-revalidates-directory-at-prepare-time ()
  (nl-agent-curation-test--with-store directory
    (let* ((record-id (nl-agent-curation-test--save directory "replace path"))
           (context
            (nl-agent-curation-new
             directory (nl-agent-curation-test--accept) "policy/path-recheck"
             :data-use-approved t))
           (moved (expand-file-name "moved-records" parent)))
      (rename-file directory moved)
      (condition-case nil
          (make-symbolic-link moved directory)
        (file-error
         (rename-file moved directory)
         (ert-skip "symbolic links unavailable")))
      (unwind-protect
          (should-error (nl-agent-curation-prepare context record-id))
        (when (file-symlink-p directory) (delete-file directory))
        (when (file-directory-p moved) (rename-file moved directory))))))

(ert-deftest nl-agent-curation-rejects-unsupported-or-oversize-training-text ()
  (nl-agent-curation-test--with-store directory
    (let* ((calls 0)
           (context
           (nl-agent-curation-new
            directory
            (lambda (_record) (setq calls (1+ calls))
              '(:accepted t :reason "accepted"))
            "policy/ascii"
            :data-use-approved t)))
      (let ((id (nl-agent-curation-test--save directory "日本語")))
        (should-error (nl-agent-curation-prepare context id)))
      (let ((id
             (nl-agent-curation-test--save
              directory (make-string 5000 ?x))))
        (cl-letf (((symbol-function 'nl-llm-agent--render)
                   (lambda (_messages)
                     (error "renderer must not receive oversize input"))))
          (should-error (nl-agent-curation-prepare context id))))
      (should (= calls 0)))))

(ert-deftest nl-agent-curation-bounds-event-count-before-rendering ()
  (nl-agent-curation-test--with-store directory
    (let* ((events
            (mapcar
             (lambda (step)
               (list :step step :model "native/base" :assistant "a"
                     :action '(none) :observation "visible"))
             '(1 2 3)))
           (id
            (nl-agent-curation-test--save
             directory "bounded"
             (nl-agent-curation-test--response 'done events)))
           (context
            (nl-agent-curation-new
             directory (nl-agent-curation-test--accept) "policy/bounds"
             :data-use-approved t))
           (calls 0)
           (nl-llm-agent-evolve-max-examples 2))
      (cl-letf (((symbol-function 'nl-llm-agent--render)
                 (lambda (_messages) (setq calls (1+ calls)) "unexpected")))
        (should-error (nl-agent-curation-prepare context id)))
      (should (= calls 0)))))

(ert-deftest nl-agent-curation-uses-runtime-observation-truncation-only ()
  (nl-agent-curation-test--with-store directory
    (let* ((observation (make-string 4001 ?o))
           (events
            (list
             (list :step 1 :model "native/base" :assistant "a"
                   :action '(none) :observation observation)
             (list :step 2 :model "native/base" :assistant "b"
                   :action '(done "finish"))))
           (id
            (nl-agent-curation-test--save
             directory ""
             (nl-agent-curation-test--response 'done events)))
           (context
            (nl-agent-curation-new
             directory (nl-agent-curation-test--accept) "policy/render"
             :data-use-approved t))
           (examples
            (plist-get
             (plist-get (nl-agent-curation-prepare context id) :payload)
             :examples)))
      (should
       (string-match-p
        (regexp-quote "... [truncated 1 chars]") (aref examples 1)))
      (should (equal (aref examples 0)
                     (concat
                      (nl-llm-agent--render
                       '((user . "TASK: ")))
                      "a"))))))

(provide 'curation-test)

(ert-run-tests-batch-and-exit)

;;; curation-test.el ends here
