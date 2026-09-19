;;; curation-supervised-test.el --- completion-only curation preparation tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(defconst nl-agent-curation-supervised-test--here
  (file-name-directory (or load-file-name buffer-file-name)))

(add-to-list 'load-path
             (expand-file-name "../lisp"
                               nl-agent-curation-supervised-test--here))
(add-to-list 'load-path
             (expand-file-name "../../nelisp-llm/lisp"
                               nl-agent-curation-supervised-test--here))
(add-to-list 'load-path
             (expand-file-name "../../nelisp-photon/lisp"
                               nl-agent-curation-supervised-test--here))

(require 'nl-agent-curation)
(require 'nl-agent-trajectory)
(require 'nl-llm-agent-tokenizer)

(defmacro nl-agent-curation-supervised-test--with-store (directory &rest body)
  "Bind DIRECTORY to a temporary trajectory store while running BODY."
  (declare (indent 1))
  `(let* ((parent (make-temp-file "nl-agent-curation-supervised-" t))
          (,directory (expand-file-name "records" parent)))
     (make-directory ,directory)
     (unwind-protect
         (progn ,@body)
       (delete-directory parent t))))

(defun nl-agent-curation-supervised-test--response (events &optional status)
  "Return a minimal agent response containing EVENTS and STATUS."
  (list :kind 'agent-run
        :status (or status 'done)
        :steps (length events)
        :result "claimed result"
        :messages nil
        :trajectory events))

(defun nl-agent-curation-supervised-test--save (directory task events)
  "Save TASK and EVENTS in DIRECTORY and return its record basename."
  (file-name-nondirectory
   (nl-agent-trajectory-save
    directory task
    (nl-agent-curation-supervised-test--response events))))

(defun nl-agent-curation-supervised-test--event (step assistant &optional observation)
  "Return one valid trajectory event for ASSISTANT and OBSERVATION."
  (let ((event (list :step step :model "native/base"
                     :assistant assistant :action '(none))))
    (when observation
      (setq event (append event (list :observation observation))))
    event))

(defun nl-agent-curation-supervised-test--context
    (directory evaluator &optional tokenizer holdouts)
  "Create a test curator for DIRECTORY and EVALUATOR."
  (nl-agent-curation-new
   directory evaluator "policy/supervised-test"
   :data-use-approved t
   :tokenizer tokenizer
   :holdout-digests holdouts
   :lr 0.1 :epochs 2))

(defun nl-agent-curation-supervised-test--accept (&optional calls)
  "Return an accepting evaluator, incrementing CALLS when supplied."
  (lambda (_record)
    (when calls (setcar calls (1+ (car calls))))
    '(:accepted t :reason "accepted by supervised test")))

(ert-deftest nl-agent-curation-supervised-shares-legacy-rendered-bytes ()
  (nl-agent-curation-supervised-test--with-store directory
    (let* ((events
            (list
             (nl-agent-curation-supervised-test--event
              1 "first" "observed")
             (nl-agent-curation-supervised-test--event 2 "final")))
           (record-id
            (nl-agent-curation-supervised-test--save
             directory "copy task" events))
           (context
            (nl-agent-curation-supervised-test--context
             directory (nl-agent-curation-supervised-test--accept)
             "utf8-byte-v1"))
           (legacy (nl-agent-curation-prepare context record-id))
           (supervised
            (nl-agent-curation-prepare-supervised context record-id))
           (legacy-examples (plist-get (plist-get legacy :payload) :examples))
           (pairs (plist-get supervised :examples)))
      (should (equal
               legacy-examples
               (vconcat
                (mapcar (lambda (pair)
                          (concat (plist-get pair :prompt)
                                  (plist-get pair :completion)))
                        (append pairs nil)))))
      (should (equal (aref pairs 0)
                     (list :prompt (nl-llm-agent--render
                                    '((user . "TASK: copy task")))
                           :completion "first")))
      (should (equal (aref pairs 1)
                     (list :prompt
                           (nl-llm-agent--render
                            '((user . "TASK: copy task")
                              (assistant . "first")
                              (user . "observed")))
                           :completion "final")))
      (should (equal (plist-get legacy :metadata)
                     (plist-get supervised :metadata)))
      (should (equal (plist-get supervised :format)
                     "nl-agent-curation-supervised-v1"))
      (should-not (plist-member supervised :payload))
      (should (equal (plist-get supervised :lr) 0.1))
      (should (= (length (plist-get (plist-get supervised :encoding)
                                    :trajectories))
                 2)))))

(ert-deftest nl-agent-curation-supervised-uses-utf8-byte-loss-boundary ()
  (nl-agent-curation-supervised-test--with-store directory
    (let* ((record-id
            (nl-agent-curation-supervised-test--save
             directory "日本語の課題"
             (list (nl-agent-curation-supervised-test--event 1 "回答"))))
           (context
            (nl-agent-curation-supervised-test--context
             directory (nl-agent-curation-supervised-test--accept)
             "utf8-byte-v1"))
           (prepared
            (nl-agent-curation-prepare-supervised context record-id))
           (pair (aref (plist-get prepared :examples) 0))
           (encoding (plist-get prepared :encoding))
           (prompt (plist-get pair :prompt))
           (prompt-ids
            (nl-llm-agent-tokenizer-encode prompt "utf8-byte-v1")))
      (should (> (length prompt-ids) (length prompt)))
      (should (= (aref (plist-get encoding :loss-starts) 0)
                 (length prompt-ids)))
      (should (equal (car (plist-get encoding :trajectories))
                     (append prompt-ids
                             (nl-llm-agent-tokenizer-encode
                              (plist-get pair :completion)
                              "utf8-byte-v1")))))))

(ert-deftest nl-agent-curation-supervised-encodes-before-detached-evaluator ()
  (nl-agent-curation-supervised-test--with-store directory
    (let* ((events
            (list (nl-agent-curation-supervised-test--event 1 "answer")))
           (record-id
            (nl-agent-curation-supervised-test--save
             directory "immutable task" events))
           (path (expand-file-name record-id directory))
           (before
            (with-temp-buffer
              (insert-file-contents-literally path)
              (buffer-string)))
           (calls 0)
           (context
            (nl-agent-curation-supervised-test--context
             directory
             (lambda (record)
               (setq calls (1+ calls))
               (setf (plist-get record :task) "mutated task")
               (setf (plist-get (car (plist-get record :trajectory))
                                :assistant)
                     "mutated answer")
               '(:accepted t :reason "mutation attempted"))))
           (prepared
            (nl-agent-curation-prepare-supervised context record-id)))
      (should (= calls 1))
      (should (string-match-p
               "immutable task"
               (plist-get (aref (plist-get prepared :examples) 0) :prompt)))
      (should (equal
               (plist-get (aref (plist-get prepared :examples) 0) :completion)
               "answer"))
      (with-temp-buffer
        (insert-file-contents-literally path)
        (should (equal before (buffer-string)))))))

(ert-deftest nl-agent-curation-supervised-holdout-is-before-evaluator ()
  (nl-agent-curation-supervised-test--with-store directory
    (let* ((record-id
            (nl-agent-curation-supervised-test--save
             directory "held out"
             (list (nl-agent-curation-supervised-test--event 1 "answer"))))
           (snapshot
            (nl-agent-trajectory-read-snapshot
             (expand-file-name record-id directory)))
           (calls (list 0))
           (context
            (nl-agent-curation-supervised-test--context
             directory (nl-agent-curation-supervised-test--accept calls)
             "utf8-byte-v1" (list (plist-get snapshot :sha256)))))
      (should-error
       (nl-agent-curation-prepare-supervised context record-id))
      (should (= (car calls) 0)))))

(ert-deftest nl-agent-curation-supervised-rejects-before-evaluator ()
  (nl-agent-curation-supervised-test--with-store directory
    (let ((calls (list 0)))
      (dolist (case
               (list
                (list "unsupported" "日本語"
                      "ascii-char-v1"
                      (list (nl-agent-curation-supervised-test--event
                             1 "answer")))
                (list "empty" "task" "utf8-byte-v1"
                      (list (nl-agent-curation-supervised-test--event
                             1 "")))
                (list "oversize" (make-string 5000 ?x) "utf8-byte-v1"
                      (list (nl-agent-curation-supervised-test--event
                             1 "answer")))
                (list "missing-observation" "task" "utf8-byte-v1"
                      (list
                       (nl-agent-curation-supervised-test--event
                        1 "first")
                       (nl-agent-curation-supervised-test--event
                        2 "final")))))
        (let* ((label (nth 0 case))
               (task (nth 1 case))
               (tokenizer (nth 2 case))
               (events (nth 3 case))
               (record-id
                (nl-agent-curation-supervised-test--save
                 directory task events))
               (context
                (nl-agent-curation-supervised-test--context
                 directory (nl-agent-curation-supervised-test--accept calls)
                 tokenizer)))
          (ignore label)
          (should-error
           (nl-agent-curation-prepare-supervised context record-id))))
      (should (= (car calls) 0)))))

(ert-deftest nl-agent-curation-supervised-reads-one-snapshot-and-denies ()
  (nl-agent-curation-supervised-test--with-store directory
    (let* ((record-id
            (nl-agent-curation-supervised-test--save
             directory "denied"
             (list (nl-agent-curation-supervised-test--event 1 "answer"))))
           (calls 0)
           (reads 0)
           (original-read (symbol-function 'nl-agent-trajectory-read-snapshot))
           (context
            (nl-agent-curation-supervised-test--context
             directory
             (lambda (_record)
               (setq calls (1+ calls))
               '(:accepted nil :reason "policy denied"))
             "utf8-byte-v1")))
      (cl-letf (((symbol-function 'nl-agent-trajectory-read-snapshot)
                 (lambda (&rest args)
                   (setq reads (1+ reads))
                   (apply original-read args))))
        (should-error
         (nl-agent-curation-prepare-supervised context record-id)))
      (should (= reads 1))
      (should (= calls 1)))))

(ert-deftest nl-agent-curation-supervised-reads-one-snapshot-on-success ()
  (nl-agent-curation-supervised-test--with-store directory
    (let* ((record-id
            (nl-agent-curation-supervised-test--save
             directory "accepted"
             (list (nl-agent-curation-supervised-test--event 1 "answer"))))
           (reads 0)
           (original-read (symbol-function 'nl-agent-trajectory-read-snapshot))
           (context
            (nl-agent-curation-supervised-test--context
             directory (nl-agent-curation-supervised-test--accept)
             "utf8-byte-v1")))
      (cl-letf (((symbol-function 'nl-agent-trajectory-read-snapshot)
                 (lambda (&rest args)
                   (setq reads (1+ reads))
                   (apply original-read args))))
        (should (nl-agent-curation-prepare-supervised context record-id)))
      (should (= reads 1)))))

(ert-run-tests-batch-and-exit)

(provide 'curation-supervised-test)
;;; curation-supervised-test.el ends here
