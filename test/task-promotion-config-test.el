;;; task-promotion-config-test.el --- JSON task-promotion assembly -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'nl-agent-improvement-config)
(require 'nl-agent-training-runner)

(defun nl-agent-task-promotion-config-test--suite ()
  "Return a detached one-file task suite for configuration tests."
  `(("id" . "config-task-suite")
    ("version" . "1")
    ("cases" .
     ,(vector
       '(("id" . "rename-note")
         ("task" . "Read note.txt, replace old with new, then finish.")
         ("files" . [( ("path" . "note.txt") ("text" . "old\n"))])
         ("expected" . [( ("path" . "note.txt") ("text" . "new\n"))]))))))

(defun nl-agent-task-promotion-config-test--policy ()
  "Return JSON taskPromotion data."
  `(("suite" . ,(nl-agent-task-promotion-config-test--suite))
    ("grammar" . (("type" . "file-actions-v1") ("max-field" . 64)))
    ("maxSequence" . 4096)
    ("maxSteps" . 1)
    ("auditDirectory" . "state/task-audit")))

(defun nl-agent-task-promotion-config-test--data (&optional directory)
  "Return a tiny background JSON configuration rooted at DIRECTORY."
  (ignore directory)
  (let ((data
         (json-parse-string
          "{\"format\":\"nl-agent-improvement-v1\",\"catalog\":\"state/catalog.json\",\"queueState\":\"state/queue.sexp\",\"providerId\":\"native\",\"providerName\":\"test\",\"idPrefix\":\"config-test\",\"grammar\":{\"type\":\"done\",\"length\":1},\"benchmark\":{\"examples\":[\" a\"]},\"model\":{\"source\":\"new\",\"dim\":2,\"ff\":2,\"blocks\":1,\"heads\":1,\"maxParameters\":1000},\"training\":{\"execution\":\"background\",\"backend\":\"cpu\",\"sequence\":64,\"optimizer\":\"sgd\"},\"minDelta\":0.0,\"maxSequence\":4096,\"maxPending\":4,\"maxHistory\":8}"
          :object-type 'alist :array-type 'array)))
    (push (cons "taskPromotion"
                (nl-agent-task-promotion-config-test--policy))
          data)
    data))

(defun nl-agent-task-promotion-config-test--write (file data)
  "Write DATA as JSON to FILE."
  (with-temp-file file
    (insert (json-encode data))
    (insert "\n")))

(defun nl-agent-task-promotion-config-test--without (data key)
  "Return DATA without string KEY."
  (cl-remove-if (lambda (entry) (equal (car entry) key)) data))

(ert-deftest nl-agent-task-promotion-config-valid-background-installs-manifest ()
  (let* ((directory (make-temp-file "nl-task-promotion-config-" t))
         (file (expand-file-name "config.json" directory))
         (assembly nil)
         (manifest nil)
         (data (nl-agent-task-promotion-config-test--data)))
    (unwind-protect
        (progn
          (nl-agent-task-promotion-config-test--write file data)
          (setq assembly (nl-agent-improvement-config-load file))
          (let* ((runner (plist-get assembly :runner))
                 (profile (nl-agent-training-runner-profile runner)))
            (setq manifest (plist-get assembly :task-promotion-manifest))
            (should (nl-agent-training-runner-p runner))
            (should (equal (plist-get assembly :task-promotion)
                           (plist-get profile :task-promotion)))
            (should (equal (plist-get assembly :task-audit-directory)
                           (expand-file-name "state/task-audit" directory)))
            (should (equal (plist-get profile :task-audit-directory)
                           (plist-get assembly :task-audit-directory)))
            (should (file-regular-p manifest))
            (should (= (logand (file-modes manifest) #o777) #o600)))
          (nl-agent-training-runner-stop (plist-get assembly :runner))
          (with-temp-buffer
            (insert-file-contents manifest)
            (goto-char (point-max))
            (insert "(:extra \"拒否\")\n")
            (write-region (point-min) (point-max) manifest nil 'silent))
          (should-error (nl-agent-improvement-config-load file)))
      (when (and assembly (plist-get assembly :runner))
        (ignore-errors (nl-agent-training-runner-stop
                        (plist-get assembly :runner))))
      (delete-directory directory t))))

(ert-deftest nl-agent-task-promotion-config-invalid-before-model-or-state ()
  (let* ((directory (make-temp-file "nl-task-promotion-invalid-" t))
         (file (expand-file-name "config.json" directory))
         (data (nl-agent-task-promotion-config-test--data))
         (calls 0))
    (unwind-protect
        (progn
          ;; A synchronous profile is invalid before model construction.
          (setcdr (assq 'execution (cdr (assq 'training data)))
                  "synchronous")
          (nl-agent-task-promotion-config-test--write file data)
          (cl-letf (((symbol-function 'nl-llm-agent-improve-model)
                     (lambda (&rest _args) (setq calls (1+ calls)) nil)))
            (should-error (nl-agent-improvement-config-load file)))
          (should (= calls 0))
          (should-not (file-exists-p (expand-file-name "state/queue.sexp" directory)))
          (should-not (directory-files directory nil "\\.task-promotion\\'")))
      (delete-directory directory t))))

(ert-deftest nl-agent-task-promotion-config-invalid-json-policy-shapes ()
  (should-error
   (nl-agent-improvement-config--keys
    '(:suite 1 :grammar 2 :maxSequence 1 :maxSequence 2)
    '(:suite :grammar :maxSequence) "duplicate taskPromotion"))
  (dolist (bad
           (list
            (cons "false" :json-false)
            (cons "missing-audit"
                  (let ((p (nl-agent-task-promotion-config-test--policy)))
                    (cl-remove-if (lambda (x) (equal (car x) "auditDirectory")) p)))
            (cons "bad-sequence"
                  (let ((p (nl-agent-task-promotion-config-test--policy)))
                    (mapcar (lambda (x) (if (equal (car x) "maxSequence")
                                       '("maxSequence" . 0) x)) p)))))
    (let* ((directory (make-temp-file "nl-task-promotion-shape-" t))
           (file (expand-file-name "config.json" directory))
           (data (nl-agent-task-promotion-config-test--data)))
      (unwind-protect
          (progn
            (setcdr (assoc "taskPromotion" data) (cdr bad))
            (nl-agent-task-promotion-config-test--write file data)
            (should-error (nl-agent-improvement-config-load file))
            (should-not (file-exists-p
                         (expand-file-name "state/queue.sexp" directory))))
        (delete-directory directory t)))))

(ert-deftest nl-agent-task-promotion-config-manifest-fails-closed-on-change-or-removal ()
  (let* ((directory (make-temp-file "nl-task-promotion-manifest-" t))
         (file (expand-file-name "config.json" directory))
         (data (nl-agent-task-promotion-config-test--data))
         (assembly nil))
    (unwind-protect
        (progn
          (nl-agent-task-promotion-config-test--write file data)
          (setq assembly (nl-agent-improvement-config-load file))
          (nl-agent-training-runner-stop (plist-get assembly :runner))
          ;; A changed policy cannot reuse the same queue-state path.
          (let ((policy (cdr (assoc "taskPromotion" data))))
            (setcdr (assoc "maxSteps" policy) 2))
          (nl-agent-task-promotion-config-test--write file data)
          (should-error (nl-agent-improvement-config-load file))
          ;; Removing the policy is also fail-closed while its manifest exists.
          (nl-agent-task-promotion-config-test--write
           file (nl-agent-task-promotion-config-test--without data "taskPromotion"))
          (should-error (nl-agent-improvement-config-load file)))
      (when (and assembly (plist-get assembly :runner))
        (ignore-errors (nl-agent-training-runner-stop
                        (plist-get assembly :runner))))
      (delete-directory directory t))))

(ert-run-tests-batch-and-exit)
