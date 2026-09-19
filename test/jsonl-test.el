;;; jsonl-test.el --- bounded JSONL facade tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)
(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (add-to-list 'load-path (expand-file-name "../lisp" here)))
(require 'nl-agent-jsonl)

(ert-deftest nl-agent-jsonl-decode-valid-commands ()
  (should (equal (nl-agent-jsonl-decode
                  "{\"id\":\"a\",\"method\":\"models\"}")
                 '(:id "a" :request (models))))
  (should (equal (nl-agent-jsonl-decode
                  "{\"id\":\"b\",\"method\":\"status\",\"params\":{}}")
                 '(:id "b" :request (status))))
  (should (equal (nl-agent-jsonl-decode
                  "{\"id\":\"c\",\"method\":\"chat\",\"params\":{\"text\":\"hello\"}}")
                 '(:id "c" :request (chat "hello"))))
  (should (equal (nl-agent-jsonl-decode
                  "{\"id\":\"d\",\"method\":\"run\",\"params\":{\"text\":\"task\"}}")
                 '(:id "d" :request (run "task"))))
  (should (equal (nl-agent-jsonl-decode
                  "{\"id\":\"e\",\"method\":\"switch\",\"params\":{\"selector\":\"mock/model\"}}")
                 '(:id "e" :request (switch "mock/model"))))
  (should (equal (nl-agent-jsonl-decode
                  "{\"id\":\"f\",\"method\":\"checkpoint\"}")
                 '(:id "f" :request (checkpoint))))
  (should (equal (nl-agent-jsonl-decode
                  "{\"id\":\"g\",\"method\":\"quit\",\"params\":{}}")
                 '(:id "g" :request (quit)))))

(ert-deftest nl-agent-jsonl-decode-rejects-ambiguous-or-invalid-input ()
  (dolist (line
           '("[]"
             "null"
             "{\"id\":\"\",\"method\":\"status\"}"
             "{\"id\":\"x\",\"method\":\"unknown\"}"
             "{\"id\":\"x\",\"method\":\"status\",\"params\":null}"
             "{\"id\":\"x\",\"method\":\"status\",\"params\":[] }"
             "{\"id\":\"x\",\"method\":\"chat\",\"params\":{}}"
             "{\"id\":\"x\",\"method\":\"chat\",\"params\":{\"text\":\"\"}}"
             "{\"id\":\"x\",\"method\":\"switch\",\"params\":{\"selector\":\"model\"}}"
             "{\"id\":\"x\",\"method\":\"status\",\"extra\":1}"
             "{\"id\":\"x\",\"method\":\"status\",\"method\":\"quit\"}"
             "{\"id\":\"x\",\"method\":\"status\",\"params\":{\"text\":1,\"text\":2}}"))
    (should-error (nl-agent-jsonl-decode line)))
  (let ((valid "{\"id\":\"x\",\"method\":\"status\"}"))
    (let ((nl-agent-jsonl-max-line-bytes (1+ (string-bytes valid))))
      (should (equal (plist-get (nl-agent-jsonl-decode valid) :id) "x")))
    (let ((nl-agent-jsonl-max-line-bytes (1- (string-bytes valid))))
      (should-error (nl-agent-jsonl-decode valid)))))

(ert-deftest nl-agent-jsonl-encode-is-bounded-data-only ()
  (let* ((wire
          (nl-agent-jsonl-encode
           "r1"
           (list :status 'ok
                 :messages '((user . "hello") (assistant . "world"))
                 :items '(alpha beta)
                 :empty nil
                 :false :json-false
                 :vector [1 "two"])))
         (value
          (json-parse-string
           wire :object-type 'alist :array-type 'array
           :null-object :json-null :false-object :json-false)))
    (should-not (string-match-p "[\r\n]" wire))
    (should (equal (alist-get 'id value) "r1"))
    (should (eq (alist-get 'ok value) t))
    (let ((result (alist-get 'result value)))
      (should (equal (alist-get 'status result) "ok"))
      (should (equal (alist-get 'messages result)
                     [["user" "hello"] ["assistant" "world"]]))
      (should (equal (alist-get 'items result) ["alpha" "beta"]))
      (should (eq (alist-get 'empty result) :json-null))
      (should (eq (alist-get 'false result) :json-false))))
  (let* ((wire (nl-agent-jsonl-error nil "bad-request" "line 1\nline 2"))
         (value
          (json-parse-string
           wire :object-type 'alist :array-type 'array
           :null-object :json-null :false-object :json-false)))
    (should (eq (alist-get 'id value) :json-null))
    (should (eq (alist-get 'ok value) :json-false))
    (should (equal (alist-get 'message (alist-get 'error value))
                   "line 1\nline 2"))))

(ert-deftest nl-agent-jsonl-encode-rejects-cycles-opaque-and-duplicates ()
  (let ((cycle (list :value 1)))
    (setcdr (last cycle) cycle)
    (should-error (nl-agent-jsonl-encode "x" cycle)))
  (should-error (nl-agent-jsonl-encode "x" (list :a 1 :a 2)))
  (should-error (nl-agent-jsonl-encode "x" (make-hash-table)))
  (should-error (nl-agent-jsonl-encode "x" (lambda () nil)))
  (should-error (nl-agent-jsonl-encode "x" (byte-compile '(lambda () nil))))
  (should-error (nl-agent-jsonl-encode nil '(:ok t)))
  (should-error (nl-agent-jsonl-encode "x" (read "1.0e+NaN")))
  (should-error (nl-agent-jsonl-encode "x" (read "1.0e+INF")))
  (should-error (nl-agent-jsonl-encode "x" (read "-1.0e+INF")))
  (let ((vector-cycle (vector nil)))
    (aset vector-cycle 0 vector-cycle)
    (should-error (nl-agent-jsonl-encode "x" vector-cycle)))
  (let ((shared (vector "shared")))
    (should (stringp (nl-agent-jsonl-encode
                      "x" (list :left shared :right shared)))))
  (let ((nl-agent-jsonl-max-depth 1))
    (should-error (nl-agent-jsonl-encode "x" (list :a (list :b 1)))))
  (let ((nl-agent-jsonl-max-nodes 2))
    (should-error (nl-agent-jsonl-encode "x" [1 2 3])))
  (let ((nl-agent-jsonl-max-output-bytes 4))
    (should-error (nl-agent-jsonl-encode "x" (list :text "long")))))

(provide 'jsonl-test)
(ert-run-tests-batch-and-exit)
;;; jsonl-test.el ends here
