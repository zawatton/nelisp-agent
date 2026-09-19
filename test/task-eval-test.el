;;; task-eval-test.el --- host-owned micro-task evaluator tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'nl-agent-task-eval)

(defun nl-agent-task-eval-test--entry (path text)
  (list :path path :text text))

(defun nl-agent-task-eval-test--case (id task input expected)
  (list :id id :task task
        :files (vector (nl-agent-task-eval-test--entry "src/value.txt" input))
        :expected
        (vector (nl-agent-task-eval-test--entry "src/value.txt" expected))))

(defun nl-agent-task-eval-test--suite (&optional cases)
  (list :id "file-edits" :version "v1"
        :cases
        (or cases
            (vector
             (nl-agent-task-eval-test--case
              "change" "change the value" "before\n" "after\n")
             (nl-agent-task-eval-test--case
              "guard" "leave the value" "guard\n" "guard\n")))))

(defun nl-agent-task-eval-test--response (status steps)
  (list :status status :steps steps
        :result (and (eq status 'done) "claimed")
        :messages nil :trajectory nil))

(defun nl-agent-task-eval-test--write (workspace relative text)
  (let ((path (expand-file-name relative workspace)))
    (make-directory (file-name-directory path) t)
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region text nil path nil 'silent))))

(defun nl-agent-task-eval-test--codes (case)
  (append (plist-get case :failure-codes) nil))

(ert-deftest nl-agent-task-eval-passes-only-done-exact-fixtures ()
  (let ((workspaces nil)
        (tasks nil)
        (suite (nl-agent-task-eval-test--suite)))
    (let ((report
           (nl-agent-task-eval-run
            suite
            (lambda (task workspace max-steps)
              (push workspace workspaces)
              (push task tasks)
              (should (= max-steps 7))
              (should (= (logand (file-modes workspace) #o777) #o700))
              (should (= (logand
                          (file-modes
                           (expand-file-name "src/value.txt" workspace))
                          #o777)
                         #o600))
              (when (string-prefix-p "change" task)
                (nl-agent-task-eval-test--write
                 workspace "src/value.txt" "after\n"))
              (nl-agent-task-eval-test--response 'done 1))
            :model-id "native/before" :max-steps 7
            :runner-id "test-file-runtime-v1")))
      (should (= (plist-get report :passed) 2))
      (should (= (plist-get report :total) 2))
      (should (= (plist-get report :score) 1.0))
      (should (equal (plist-get report :runner-id) "test-file-runtime-v1"))
      (should (= (length (delete-dups workspaces)) 2))
      (dolist (workspace workspaces) (should-not (file-exists-p workspace)))
      (should-not (string-match-p "after\\n" (prin1-to-string report)))
      (should-not (string-match-p "before\\n" (prin1-to-string report)))
      (dotimes (index 2)
        (let* ((case (aref (plist-get report :cases) index))
               (file (aref (plist-get case :files) 0)))
          (should (plist-get case :pass))
          (should (equal (plist-get file :expected-sha256)
                         (plist-get file :actual-sha256))))))))

(ert-deftest nl-agent-task-eval-done-alone-and-partial-status-get-no-credit ()
  (let ((suite
         (nl-agent-task-eval-test--suite
          (vector
           (nl-agent-task-eval-test--case "lie" "lie" "a" "b")
           (nl-agent-task-eval-test--case "limit" "limit" "a" "b")))))
    (let ((report
           (nl-agent-task-eval-run
            suite
            (lambda (task workspace _max-steps)
              (if (equal task "lie")
                  (nl-agent-task-eval-test--response 'done 1)
                (progn
                  (nl-agent-task-eval-test--write
                   workspace "src/value.txt" "b")
                  (nl-agent-task-eval-test--response 'limit 1))))
            :model-id "model/x")))
      (let ((lie (aref (plist-get report :cases) 0))
            (limit (aref (plist-get report :cases) 1)))
        (should-not (plist-get lie :pass))
        (should (memq 'content-mismatch
                      (nl-agent-task-eval-test--codes lie)))
        (should-not (plist-get limit :pass))
        (should (memq 'runtime-status
                      (nl-agent-task-eval-test--codes limit)))
        (should (= (plist-get report :passed) 0))
        (should (= (plist-get report :score) 0.0))))))

(ert-deftest nl-agent-task-eval-detects-unintended-workspace-effects ()
  (let* ((outside (make-temp-file "nl-agent-task-eval-outside-"))
         (suite
          (nl-agent-task-eval-test--suite
           (vector
            (nl-agent-task-eval-test--case "delete" "delete" "a" "a")
            (nl-agent-task-eval-test--case "extra" "extra" "a" "a")
            (nl-agent-task-eval-test--case "link" "link" "a" "a"))))
         report)
    (unwind-protect
        (setq report
              (nl-agent-task-eval-run
               suite
               (lambda (task workspace _max-steps)
                 (cond
                  ((equal task "delete")
                   (delete-file (expand-file-name "src/value.txt" workspace)))
                  ((equal task "extra")
                   (nl-agent-task-eval-test--write workspace "extra.txt" "x"))
                  (t
                   (delete-file (expand-file-name "src/value.txt" workspace))
                   (make-symbolic-link
                    outside (expand-file-name "src/value.txt" workspace))))
                 (nl-agent-task-eval-test--response 'done 1))
               :model-id "model/x"))
      (when (file-exists-p outside) (delete-file outside)))
    (should (= (plist-get report :passed) 0))
    (should (memq 'missing-file
                  (nl-agent-task-eval-test--codes
                   (aref (plist-get report :cases) 0))))
    (should (memq 'extra-file
                  (nl-agent-task-eval-test--codes
                   (aref (plist-get report :cases) 1))))
    (should (memq 'symlink
                  (nl-agent-task-eval-test--codes
                   (aref (plist-get report :cases) 2))))))

(ert-deftest nl-agent-task-eval-root-symlink-never-follows-outside ()
  (let* ((outside (make-temp-file "nl-agent-task-eval-root-outside-" t))
         (marker (expand-file-name "keep" outside))
         (_ (write-region "safe" nil marker nil 'silent))
         (suite (nl-agent-task-eval-test--suite
                 (vector (nl-agent-task-eval-test--case
                          "root" "root" "a" "a"))))
         report)
    (unwind-protect
        (setq report
              (nl-agent-task-eval-run
               suite
               (lambda (_task workspace _max-steps)
                 (delete-directory workspace t)
                 (make-symbolic-link outside workspace)
                 (nl-agent-task-eval-test--response 'done 1))
               :model-id "model/x"))
      (should (file-exists-p marker))
      (delete-directory outside t))
    (should-not (plist-get (aref (plist-get report :cases) 0) :pass))
    (should (memq 'symlink
                  (nl-agent-task-eval-test--codes
                   (aref (plist-get report :cases) 0))))))

(ert-deftest nl-agent-task-eval-callback-cannot-mutate-oracle ()
  (let* ((suite (nl-agent-task-eval-test--suite))
         (run
          (lambda (task workspace _max-steps)
            (aset task 0 ?X)
            (when (string-match-p "change" (downcase task))
              (nl-agent-task-eval-test--write
               workspace "src/value.txt" "after\n"))
            (nl-agent-task-eval-test--response 'done 1)))
         (first (nl-agent-task-eval-run suite run :model-id "model/x"))
         (second
          (nl-agent-task-eval-run
           suite
           (lambda (task workspace _max-steps)
             (when (equal task "change the value")
               (nl-agent-task-eval-test--write
                workspace "src/value.txt" "after\n"))
             (nl-agent-task-eval-test--response 'done 1))
           :model-id "model/x")))
    (should (equal (plist-get first :suite-sha256)
                   (plist-get second :suite-sha256)))
    (should (equal (plist-get suite :id) "file-edits"))))

(ert-deftest nl-agent-task-eval-invalid-manifests-have-no-side-effects ()
  (let* ((calls 0)
        (callback (lambda (&rest _) (setq calls (1+ calls))))
        (valid (nl-agent-task-eval-test--suite))
        invalid)
    (setq invalid
          (list
           (append valid '(:unknown t))
           '(:id "x" :id "y" :version "v" :cases [])
           '(:id "x" :version "v" :cases [])
           (list :id "x" :version "v"
                 :cases
                 (vector
                  (list :id "bad" :task "x"
                        :files [(:path "../escape" :text "x")]
                        :expected [(:path "../escape" :text "x")])))
           (list :id "x" :version "v"
                 :cases
                 (vector
                  (list :id "bad" :task "x"
                        :files [(:path "a" :text "x")
                                (:path "a/b" :text "x")]
                        :expected [(:path "a" :text "x")
                                   (:path "a/b" :text "x")])))
           (list :id "x" :version "v"
                 :cases
                 (vector
                  (list :id "bad" :task "x"
                        :files [(:path "a" :text "x")]
                        :expected [(:path "b" :text "x")])))
           (list :id "x" :version "v"
                 :cases
                 (vector
                  (list :id "bad" :task "x"
                        :files [(:path "bad\0path" :text "x")]
                        :expected [(:path "bad\0path" :text "x")])))))
    ;; Make one otherwise-valid manifest exceed the combined 1 MiB budget.
    (let (files expected)
      (dotimes (index 9)
        (push (nl-agent-task-eval-test--entry
               (format "f%d" index) (make-string 65536 ?x)) files)
        (push (nl-agent-task-eval-test--entry
               (format "f%d" index) (make-string 65536 ?x)) expected))
      (push (list :id "large" :version "v"
                  :cases
                  (vector (list :id "large" :task "x"
                                :files (vconcat files)
                                :expected (vconcat expected))))
            invalid))
    (push
     (list :id "raw" :version "v"
           :cases
           (vector
            (list :id "raw" :task "x"
                  :files
                  (vector (list :path "a" :text (unibyte-string #xff)))
                  :expected
                  (vector (list :path "a" :text (unibyte-string #xff))))))
     invalid)
    (push
     (list :id "surrogate" :version "v"
           :cases
           (vector
            (list :id "surrogate" :task "x"
                  :files (vector (list :path "a" :text (string #xd800)))
                  :expected
                  (vector (list :path "a" :text (string #xd800))))))
     invalid)
    (let ((workspace-calls 0))
      (cl-letf (((symbol-function 'make-temp-file)
                 (lambda (&rest _)
                   (setq workspace-calls (1+ workspace-calls))
                   (error "must not allocate"))))
        (dolist (suite invalid)
          (should-error
           (nl-agent-task-eval-run suite callback :model-id "model/x"))))
      (should (= workspace-calls 0)))
    (should (= calls 0))))

(ert-deftest nl-agent-task-eval-callback-failures-do-not-abort-suite ()
  (let ((calls 0)
        (suite
         (nl-agent-task-eval-test--suite
          (vector
           (nl-agent-task-eval-test--case "one" "one" "a" "a")
           (nl-agent-task-eval-test--case "two" "two" "a" "a")))))
    (let ((report
           (nl-agent-task-eval-run
            suite
            (lambda (&rest _)
              (setq calls (1+ calls))
              (if (= calls 1) (error "callback failed") '(:status done)))
            :model-id "model/x")))
      (should (= calls 2))
      (should (= (plist-get report :passed) 0))
      (should (memq 'callback-error
                    (nl-agent-task-eval-test--codes
                     (aref (plist-get report :cases) 0))))
      (should (memq 'invalid-response
                    (nl-agent-task-eval-test--codes
                     (aref (plist-get report :cases) 1)))))))

(ert-deftest nl-agent-task-eval-bounds-generated-inventory ()
  (let* ((suite
          (nl-agent-task-eval-test--suite
           (vector (nl-agent-task-eval-test--case
                    "inventory" "inventory" "a" "a"))))
         (report
          (nl-agent-task-eval-run
           suite
           (lambda (_task workspace _max-steps)
             (dotimes (index 129)
               (nl-agent-task-eval-test--write
                workspace (format "extra-%03d" index) "x"))
             (nl-agent-task-eval-test--response 'done 1))
           :model-id "model/x"))
         (case (aref (plist-get report :cases) 0)))
    (should-not (plist-get case :pass))
    (should (memq 'inventory-limit
                  (nl-agent-task-eval-test--codes case)))))

(ert-deftest nl-agent-task-eval-compare-validates-protocol-and-aggregates ()
  (let* ((suite
          (nl-agent-task-eval-test--suite
           (vector (nl-agent-task-eval-test--case "one" "one" "a" "b"))))
         (before
          (nl-agent-task-eval-run
           suite (lambda (&rest _) (nl-agent-task-eval-test--response 'done 1))
           :model-id "before" :runner-id "runner/v1"))
         (after
          (nl-agent-task-eval-run
           suite
           (lambda (_task workspace _max-steps)
             (nl-agent-task-eval-test--write workspace "src/value.txt" "b")
             (nl-agent-task-eval-test--response 'done 1))
           :model-id "after" :runner-id "runner/v1"))
         (comparison (nl-agent-task-eval-compare before after)))
    (should (= (plist-get comparison :passed-delta) 1))
    (should (= (plist-get comparison :score-delta) 1.0))
    (let ((forged (copy-tree after t)))
      (setf (plist-get forged :passed) 0)
      (should-error (nl-agent-task-eval-compare before forged)))
    (let ((runner (copy-tree after t)))
      (setf (plist-get runner :runner-id) "runner/v2")
      (should-error (nl-agent-task-eval-compare before runner)))
    (let ((budget
           (nl-agent-task-eval-run
            suite
            (lambda (_task workspace _max-steps)
              (nl-agent-task-eval-test--write workspace "src/value.txt" "b")
              (nl-agent-task-eval-test--response 'done 1))
            :model-id "after" :max-steps 11 :runner-id "runner/v1")))
      (should-error (nl-agent-task-eval-compare before budget)))
    (let* ((oracle (copy-tree before t))
           (file (aref (plist-get (aref (plist-get oracle :cases) 0) :files) 0)))
      (setf (plist-get file :expected-sha256) (make-string 64 ?f))
      (should-error (nl-agent-task-eval-compare oracle after)))))

(provide 'task-eval-test)
(ert-run-tests-batch-and-exit)

;;; task-eval-test.el ends here
