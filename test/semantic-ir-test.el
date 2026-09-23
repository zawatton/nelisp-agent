;;; semantic-ir-test.el --- Semantic IR boundary tests -*- lexical-binding: t; -*-

(require 'ert)
(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-semantic-ir)

(defvar nl-agent-ir-test--executed nil)

(defconst nl-agent-ir-test--task
  '(task :version 1 :id "demo" :plan
         (render :language ja :claims
                 ((claim :id "c1" :text "推論はクラウドで行います。")
                  (claim :id "c2" :text "結果はローカルで検証します。")))
         :constraints (:allow-new-claims nil :max-chars 100)))

(defun nl-agent-ir-test--text (&optional task)
  (prin1-to-string (or task nl-agent-ir-test--task)))

(defun nl-agent-ir-test--set-constraint (task key value)
  (let ((constraints (plist-get (cdr task) :constraints)))
    (plist-put constraints key value)
    task))

(ert-deftest nl-agent-ir-render-preserves-claims ()
  (let ((result (nl-agent-ir-run (nl-agent-ir-test--text))))
    (should (eq (plist-get result :status) 'ok))
    (should (equal (plist-get result :text)
                   "推論はクラウドで行います。\n結果はローカルで検証します。"))
    (should (equal (plist-get result :claim-ids) '("c1" "c2")))
    (should (equal (plist-get result :task) "demo"))))

(ert-deftest nl-agent-ir-parse-result-round-trips ()
  (let ((parsed (nl-agent-ir-parse (nl-agent-ir-test--text))))
    (should (equal (car (plist-get (cdr (plist-get (cdr parsed) :plan)) :claims))
                   '(claim :id "c1" :text "推論はクラウドで行います。")))
    (should (equal (nl-agent-ir-parse (prin1-to-string parsed)) parsed))))

(ert-deftest nl-agent-ir-rejects-unsafe-reader-input ()
  (setq nl-agent-ir-test--executed nil)
  (dolist (text '("#.(error \"executed\")" "#1=(task . #1#)"
                  "'task" "`task" ",task" "[task]" "(task"
                  "(task) (task)" "; comment\n(task)" "|task|" "\\task"
                  "?a" "#.(setq nl-agent-ir-test--executed t)"))
    (should-error (nl-agent-ir-parse text) :type 'nl-agent-ir-error))
  (should-not nl-agent-ir-test--executed))

(ert-deftest nl-agent-ir-rejects-invalid-schema ()
  (dolist (form '((task :version 2 :id "x" :plan nil :constraints nil)
                  (task :version 1 :version 1)
                  (task :version 1 :id "x" :plan nil)
                  (task :version 1 :id "x" :plan nil :constraints nil :unknown t)
                  (task . bad)
                  (shell :command "echo unsafe")))
    (should-error (nl-agent-ir-parse (prin1-to-string form))
                  :type 'nl-agent-ir-error)))

(ert-deftest nl-agent-ir-rejects-invalid-nested-fields ()
  (dolist (change '((:language en) (:claims nil) (:unknown t)))
    (let* ((task (copy-tree nl-agent-ir-test--task))
           (plan (plist-get (cdr task) :plan)))
      (setcdr plan (plist-put (cdr plan) (car change) (cadr change)))
      (should-error (nl-agent-ir-parse (nl-agent-ir-test--text task))
                    :type 'nl-agent-ir-error)))
  (let ((task (copy-tree nl-agent-ir-test--task)))
    (let ((plan (plist-get (cdr task) :plan)))
      (setcdr plan (plist-put (cdr plan) :claims nil)))
    (should-error (nl-agent-ir-parse (nl-agent-ir-test--text task))
                  :type 'nl-agent-ir-error))
  (let ((task (copy-tree nl-agent-ir-test--task)))
    (let* ((claims (plist-get (cdr (plist-get (cdr task) :plan)) :claims))
           (second (cadr claims)))
      (setcdr second (list :id "c1" :text "重複")))
    (should-error (nl-agent-ir-parse (nl-agent-ir-test--text task))
                  :type 'nl-agent-ir-error)))

(ert-deftest nl-agent-ir-constraints-are-enforced ()
  (dolist (value '(t false 0))
    (let ((task (copy-tree nl-agent-ir-test--task)))
      (nl-agent-ir-test--set-constraint task :allow-new-claims value)
      (should-error (nl-agent-ir-parse (nl-agent-ir-test--text task))
                    :type 'nl-agent-ir-error)))
  (dolist (value '(-1 0 65537 1.5 "100"))
    (let ((task (copy-tree nl-agent-ir-test--task)))
      (nl-agent-ir-test--set-constraint task :max-chars value)
      (should-error (nl-agent-ir-parse (nl-agent-ir-test--text task))
                    :type 'nl-agent-ir-error))))

(ert-deftest nl-agent-ir-failure-is-compact-and-counts-characters ()
  (let ((task (nl-agent-ir-test--set-constraint
               (copy-tree nl-agent-ir-test--task) :max-chars 28)))
    (should (eq (plist-get (nl-agent-ir-run (nl-agent-ir-test--text task))
                           :status)
                'ok)))
  (let* ((task (nl-agent-ir-test--set-constraint
                (copy-tree nl-agent-ir-test--task) :max-chars 1))
         (result (nl-agent-ir-run (nl-agent-ir-test--text task)))
         (repair (plist-get result :repair-request)))
    (should (eq (plist-get result :status) 'validation-failure))
    (should (equal repair '(repair-request :version 1 :task "demo"
                           :constraint max-chars :expected 1 :actual 28)))
    (should-not (plist-member result :text))))

(ert-deftest nl-agent-ir-reader-limits-and-string-escapes ()
  (should-error (nl-agent-ir-parse (make-string 65537 ?x))
                :type 'nl-agent-ir-error)
  (let ((oversized (make-string 22000 ?あ)))
    (should (< (length oversized) 65536))
    (should (> (nl-agent-ir--utf8-bytes oversized) 65536))
    (should-error (nl-agent-ir-parse oversized) :type 'nl-agent-ir-error))
  (let ((base (nl-agent-ir-test--text)))
    (let ((exact (concat base
                         (make-string (- 65536 (nl-agent-ir--utf8-bytes base))
                                      ?\s))))
      (should (= (nl-agent-ir--utf8-bytes exact) 65536))
      (should (equal (plist-get (nl-agent-ir-run exact) :status) 'ok))))
  (should (eq (plist-get (nl-agent-ir-run
                          (concat (nl-agent-ir-test--text) "\n\t"))
                         :status)
              'ok))
  (should-error (nl-agent-ir--preflight
                 (concat (make-string 17 ?\() "x" (make-string 17 ?\))))
                :type 'nl-agent-ir-error)
  (should-not (nl-agent-ir--preflight
               (concat (make-string 16 ?\() "x" (make-string 16 ?\)))))
  (let* ((task (copy-tree nl-agent-ir-test--task))
         (claims (plist-get (cdr (plist-get (cdr task) :plan)) :claims))
         (literal "#.(do-not-run) [text]; \"quoted\" \\\\ 日本語"))
    (setcdr (car claims) (list :id "c1" :text literal))
    (should (string-prefix-p literal
                             (plist-get (nl-agent-ir-run
                                         (nl-agent-ir-test--text task))
                                        :text)))))

(ert-deftest nl-agent-ir-rejects-too-many-claims ()
  (let ((claims nil))
    (dotimes (index 65)
      (push (list 'claim :id (format "c%d" index) :text "x") claims))
    (let ((task (list 'task :version 1 :id "many" :plan
                      (list 'render :language 'ja :claims claims)
                      :constraints '(:allow-new-claims nil :max-chars 1000))))
      (should-error (nl-agent-ir-parse (nl-agent-ir-test--text task))
                    :type 'nl-agent-ir-error))))

(ert-run-tests-batch-and-exit)
