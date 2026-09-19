;;; trajectory-test.el --- immutable run trajectory store tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'nl-agent-trajectory)

(defun nl-agent-trajectory-test--response ()
  "Return a representative detached agent-run response."
  (list :kind 'agent-run :status 'done :steps 2 :result "claimed complete"
        :messages '((system . "private session") (user . "secret"))
        :trajectory
        (list
         (list :step 1 :model "native/base" :assistant "use tool"
               :action '(tool "lookup" (:query "x"))
               :tool-result '(:status ok :value [1 2 3])
               :observation "OBSERVATION: found")
         (list :step 2 :model "native/base" :assistant "DONE"
               :action '(done "claimed complete")))))

(defmacro nl-agent-trajectory-test--with-directory (binding &rest body)
  "Bind BINDING to an absent child directory and run BODY."
  (declare (indent 1))
  `(let* ((parent (make-temp-file "nl-agent-trajectory-test-" t))
          (,binding (expand-file-name "records" parent)))
     (unwind-protect (progn ,@body)
       (delete-directory parent t))))

(ert-deftest nl-agent-trajectory-roundtrip-is-private-detached-and-minimal ()
  (nl-agent-trajectory-test--with-directory directory
    (let* ((response (nl-agent-trajectory-test--response))
           (source-action
            (plist-get (car (plist-get response :trajectory)) :action))
           (path (nl-agent-trajectory-save directory "audit task" response))
           (record (nl-agent-trajectory-read path)))
      (should (file-name-absolute-p path))
      (should (= (logand (file-modes directory) #o777) #o700))
      (should (= (logand (file-modes path) #o777) #o600))
      (should
       (equal
        (let (keys tail)
          (setq tail record)
          (while tail (setq keys (append keys (list (car tail)))
                            tail (cddr tail)))
          keys)
        '(:format :task :status :steps :result :trajectory :evidence)))
      (should (equal (plist-get record :evidence) "unverified"))
      (should-not (plist-member record :messages))
      (should-not (plist-member record :verified))
      (setcar source-action 'changed)
      (should (eq (car (plist-get (car (plist-get record :trajectory))
                                  :action))
                  'tool))
      (let ((read-again (nl-agent-trajectory-read path)))
        (setf (plist-get record :task) "changed")
        (should (equal (plist-get read-again :task) "audit task"))))))

(ert-deftest nl-agent-trajectory-strips-text-properties-and-their-values ()
  (nl-agent-trajectory-test--with-directory directory
    (let* ((response (nl-agent-trajectory-test--response))
           (assistant (copy-sequence "plain assistant")))
      (put-text-property 0 5 'private-runtime-object
                         (current-buffer) assistant)
      (setf (plist-get (car (plist-get response :trajectory)) :assistant)
            assistant)
      (let* ((path (nl-agent-trajectory-save directory "task" response))
             (record (nl-agent-trajectory-read path))
             (saved
              (plist-get (car (plist-get record :trajectory)) :assistant)))
        (should (equal saved "plain assistant"))
        (should-not (text-properties-at 0 saved))))))

(ert-deftest nl-agent-trajectory-done-remains-an-unverified-claim ()
  (nl-agent-trajectory-test--with-directory directory
    (let ((record
           (nl-agent-trajectory-read
            (nl-agent-trajectory-save
             directory "claim only" (nl-agent-trajectory-test--response)))))
      (should (eq (plist-get record :status) 'done))
      (should (equal (plist-get record :evidence) "unverified")))))

(ert-deftest nl-agent-trajectory-rejects-non-agent-and-malformed-responses ()
  (nl-agent-trajectory-test--with-directory directory
    (let ((response (nl-agent-trajectory-test--response)))
      (dolist (bad
               (list
                (plist-put (copy-tree response) :kind 'status)
                (plist-put (copy-tree response) :status 'success)
                (plist-put (copy-tree response) :steps -1)
                (append (copy-tree response) '(:unknown t))
                (append (copy-tree response) '(:status done))))
        (should-error (nl-agent-trajectory-save directory "task" bad)))
      (let ((bad (copy-tree response)))
        (setf (plist-get (cadr (plist-get bad :trajectory)) :step) 1)
        (should-error (nl-agent-trajectory-save directory "task" bad)))
      (let ((bad (copy-tree response)))
        (setf (plist-get (car (plist-get bad :trajectory)) :extra) t)
        (should-error (nl-agent-trajectory-save directory "task" bad)))
      (let ((bad (copy-tree response)))
        (setcdr (last bad) 'dotted)
        (should-error (nl-agent-trajectory-save directory "task" bad))))))

(ert-deftest nl-agent-trajectory-rejects-unsafe-and-cyclic-nested-data ()
  (nl-agent-trajectory-test--with-directory directory
    (dolist (unsafe (list (current-buffer) (symbol-function 'ignore)
                          (byte-compile (lambda () t))
                          (record 'trajectory-test-record t)
                          (make-hash-table)
                          (read "1.0e+INF") (read "0.0e+NaN")))
      (let ((response (nl-agent-trajectory-test--response)))
        (setf (plist-get (car (plist-get response :trajectory)) :action)
              unsafe)
        (should-error (nl-agent-trajectory-save directory "task" response))))
    (let* ((response (nl-agent-trajectory-test--response))
           (cycle (list 'tool)))
      (setcdr cycle cycle)
      (setf (plist-get (car (plist-get response :trajectory)) :action) cycle)
      (should-error (nl-agent-trajectory-save directory "task" response)))))

(ert-deftest nl-agent-trajectory-enforces-depth-node-byte-and-record-bounds ()
  (nl-agent-trajectory-test--with-directory directory
    (let ((response (nl-agent-trajectory-test--response))
          (deep nil))
      (dotimes (_ 34) (setq deep (vector deep)))
      (setf (plist-get (car (plist-get response :trajectory)) :action) deep)
      (should-error (nl-agent-trajectory-save directory "task" response)))
    (let ((nl-agent-trajectory-max-nodes 20))
      (should-error
       (nl-agent-trajectory-save
        directory "task" (nl-agent-trajectory-test--response))))
    (let ((response
           (list :kind 'agent-run :status 'limit :steps 6 :result nil
                 :messages nil
                 :trajectory
                 (mapcar
                  (lambda (step)
                    (list :step step :model "native/base"
                          :assistant "continue" :action nil))
                  '(1 2 3 4 5 6))))
          (nl-agent-trajectory-max-nodes 100))
      ;; Each event fits independently; only the shared whole-record budget
      ;; rejects their aggregate size.
      (should-error (nl-agent-trajectory-save directory "task" response)))
    (let ((nl-agent-trajectory-max-bytes 100))
      (should-error
       (nl-agent-trajectory-save
        directory "task" (nl-agent-trajectory-test--response))))
    (let* ((response (nl-agent-trajectory-test--response))
           (assistant (make-string 200 ?x))
           (nl-agent-trajectory-max-bytes 100))
      (setf (plist-get (car (plist-get response :trajectory)) :assistant)
            assistant)
      (should-error (nl-agent-trajectory-save directory "task" response))
      (should (= (length assistant) 200)))
    (let ((nl-agent-trajectory-max-records 1))
      (nl-agent-trajectory-save
       directory "first" (nl-agent-trajectory-test--response))
      (should-error
       (nl-agent-trajectory-save
        directory "second" (nl-agent-trajectory-test--response))))))

(ert-deftest nl-agent-trajectory-never-overwrites-an-existing-target ()
  (nl-agent-trajectory-test--with-directory directory
    (make-directory directory t)
    (let ((target (expand-file-name "run-fixed.sexp" directory)))
      (with-temp-file target (insert "original"))
      (cl-letf (((symbol-function 'nl-agent-trajectory--target)
                 (lambda (_directory) target)))
        (should-error
         (nl-agent-trajectory-save
          directory "task" (nl-agent-trajectory-test--response))))
      (with-temp-buffer
        (insert-file-contents target)
        (should (equal (buffer-string) "original"))))))

(ert-deftest nl-agent-trajectory-rejects-directory-and-record-symlinks ()
  (nl-agent-trajectory-test--with-directory directory
    (let ((real (expand-file-name "real" parent)))
      (make-directory real)
      (condition-case nil
          (make-symbolic-link real directory)
        (file-error (ert-skip "symbolic links unavailable")))
      (should-error
       (nl-agent-trajectory-save
        directory "task" (nl-agent-trajectory-test--response)))
      (delete-file directory)
      (let* ((path
              (nl-agent-trajectory-save
               directory "task" (nl-agent-trajectory-test--response)))
             (link (expand-file-name "linked.sexp" directory)))
        (make-symbolic-link path link)
        (should-error (nl-agent-trajectory-read link))))))

(ert-deftest nl-agent-trajectory-reader-is-bounded-data-only-and-exact ()
  (nl-agent-trajectory-test--with-directory directory
    (make-directory directory t)
    (let ((side-effect nil)
          (path (expand-file-name "run-malformed.sexp" directory)))
      (with-temp-file path (insert "#.(setq side-effect t)"))
      (should-error (nl-agent-trajectory-read path))
      (should-not side-effect)
      (let ((valid
             (nl-agent-trajectory-save
              directory "task" (nl-agent-trajectory-test--response))))
        (with-temp-buffer
          (insert-file-contents valid)
          (goto-char (point-max))
          (insert "\n(:trailing t)")
          (write-region (point-min) (point-max) valid nil 'silent))
        (should-error (nl-agent-trajectory-read valid)))
      (let ((nl-agent-trajectory-max-bytes 10))
        (should-error (nl-agent-trajectory-read path))))))

(provide 'trajectory-test)

(ert-run-tests-batch-and-exit)

;;; trajectory-test.el ends here
