;;; cli-jsonl-service-test.el --- packaged JSONL CLI integration -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'seq)
(require 'photon-tensor)
(require 'nl-agent-cli)
(require 'nl-llm-agent-artifact)
(require 'nl-llm-agent-improve)

(defun nl-agent-cli-jsonl-service-test--clear-environment ()
  "Remove ambient Agent settings from the child process environment."
  (dolist (entry (copy-sequence process-environment))
    (when (string-prefix-p "NELISP_AGENT_" entry)
      (setenv (car (split-string entry "=")) nil))))

(defun nl-agent-cli-jsonl-service-test--model ()
  "Return a detached tiny model suitable for native artifact fixtures."
  (nl-llm-agent-improve-model 2 2 96 1 1))

(defun nl-agent-cli-jsonl-service-test--publish (catalog id generation)
  "Publish tiny native artifact ID at GENERATION into CATALOG."
  (nl-llm-agent-artifact-publish
   catalog (nl-llm-agent-artifact-export-pav
            (nl-agent-cli-jsonl-service-test--model) generation)
   :id id :name (format "JSONL fixture generation %d" generation)
   :grammar '(:type "done" :length 2 :allow "ab ")
   :maxseq 8192 :score (float generation) :generation generation))

(defun nl-agent-cli-jsonl-service-test--read-one
    (process lines buffer deadline)
  "Wait for one complete JSON line from PROCESS.
LINES and BUFFER are mutable one-element cells; signal on timeout or exit."
  (while (and (null (car lines))
              (< (float-time) deadline))
    (accept-process-output process 0.05)
    (when (and (not (process-live-p process))
               (null (car lines)))
      (error "JSONL child exited before reply: stdout=%S stderr=%S"
             (car buffer)
             (with-current-buffer (process-get process 'stderr-buffer)
               (buffer-string)))))
  (or (pop (car lines))
      (error "timed out waiting for JSONL reply: %s" (car buffer))))

(defun nl-agent-cli-jsonl-service-test--send
    (process request lines buffer)
  "Send one REQUEST line to PROCESS and parse its one JSON reply."
  (process-send-string process (concat request "\n"))
  (json-parse-string
   (nl-agent-cli-jsonl-service-test--read-one
    process lines buffer (+ (float-time) 20.0))
   :object-type 'alist :array-type 'array
   :null-object nil :false-object :json-false))

(ert-deftest nl-agent-cli-packaged-jsonl-preserves-native-session ()
  "Exercise the shipped process boundary with one persistent JSONL session."
  (let* ((project-directory default-directory)
         (nelisp (expand-file-name
                  (or (getenv "NELISP_BIN") "../nelisp/target/nelisp")
                  project-directory))
         (launcher (expand-file-name "bin/nelisp-agent" project-directory))
         (directory (make-temp-file "nl-agent-jsonl-service-" t))
         (catalog (expand-file-name "catalog.json" directory))
         (checkpoint (expand-file-name "session.sexp" directory))
         (workspace (expand-file-name "workspace" directory))
         (stdout (generate-new-buffer " *nl-agent-jsonl-stdout*"))
         (stderr (generate-new-buffer " *nl-agent-jsonl-stderr*"))
         (lines (list nil))
         (buffer (list ""))
         (process nil)
         (process-environment (copy-sequence process-environment)))
    (make-directory workspace t)
    (unwind-protect
        (progn
          (nl-agent-cli-jsonl-service-test--clear-environment)
          (nl-agent-cli-jsonl-service-test--publish catalog "tiny-g1" 1)
          (nl-agent-cli-jsonl-service-test--publish catalog "tiny-g2" 2)
          (setq process
                (make-process
                 :name "nl-agent-jsonl-service-fixture"
                 :command
                 (list "sh" launcher "--jsonl"
                       "--nelisp" nelisp
                       "--native-catalog" catalog
                       "--model" "native/tiny-g1"
                       "--workspace" workspace
                       "--checkpoint" checkpoint
                       "--unattended")
                 :coding 'utf-8
                 :connection-type 'pipe
                 :buffer stdout
                 :stderr stderr
                 :filter
                 (lambda (_process chunk)
                   (setcar buffer (concat (car buffer) chunk))
                   (while (string-search "\n" (car buffer))
                     (let* ((end (string-search "\n" (car buffer)))
                            (line (substring (car buffer) 0 end)))
                       (setcar buffer (substring (car buffer) (1+ end)))
                       (setcar lines (append (car lines) (list line))))))
                 :sentinel (lambda (_process _event) nil)))
          (process-put process 'stderr-buffer stderr)
          (let* ((status-1
                  (nl-agent-cli-jsonl-service-test--send
                   process
                   "{\"id\":\"status-1\",\"method\":\"status\"}"
                   lines buffer))
                 (chat-1
                  (nl-agent-cli-jsonl-service-test--send
                   process
                   "{\"id\":\"chat-1\",\"method\":\"chat\",\"params\":{\"text\":\"hello\\nworld\"}}"
                   lines buffer))
                 (models
                  (nl-agent-cli-jsonl-service-test--send
                   process
                   "{\"id\":\"models-1\",\"method\":\"models\"}"
                   lines buffer))
                 (switched
                  (nl-agent-cli-jsonl-service-test--send
                   process
                   "{\"id\":\"switch-1\",\"method\":\"switch\",\"params\":{\"selector\":\"native/tiny-g2\"}}"
                   lines buffer))
                 (checkpoint-reply
                  (nl-agent-cli-jsonl-service-test--send
                   process
                   "{\"id\":\"checkpoint-1\",\"method\":\"checkpoint\"}"
                   lines buffer))
                 (literal-quit
                  (nl-agent-cli-jsonl-service-test--send
                   process
                   "{\"id\":\"chat-slash-quit\",\"method\":\"chat\",\"params\":{\"text\":\"/quit\"}}"
                   lines buffer))
                 (invalid
                  (nl-agent-cli-jsonl-service-test--send
                   process "not json" lines buffer))
                 (status-2
                  (nl-agent-cli-jsonl-service-test--send
                   process
                   "{\"id\":\"status-2\",\"method\":\"status\"}"
                   lines buffer))
                 (quit
                  (nl-agent-cli-jsonl-service-test--send
                   process
                   "{\"id\":\"quit-1\",\"method\":\"quit\"}"
                   lines buffer)))
            (should
             (equal
              (mapcar (lambda (reply) (alist-get 'id reply))
                      (list status-1 chat-1 models switched checkpoint-reply
                            literal-quit invalid status-2 quit))
              '("status-1" "chat-1" "models-1" "switch-1" "checkpoint-1"
                "chat-slash-quit" nil "status-2" "quit-1")))
            (should (equal (alist-get 'id status-1) "status-1"))
            (should (eq (alist-get 'ok status-1) t))
            (should (eq (alist-get 'ok chat-1) t))
            (should (equal (alist-get 'kind (alist-get 'result chat-1))
                           "completion"))
            (should (equal (alist-get 'status (alist-get 'result chat-1))
                           "ok"))
            (should (string-match-p "\\`DONE [ab ]\\{2\\}\\'"
                                    (alist-get 'text
                                               (alist-get 'result chat-1))))
            (let* ((result (alist-get 'result models))
                   (descriptors (alist-get 'models result))
                   (ids (mapcar (lambda (entry) (alist-get 'qualified-id entry))
                                descriptors)))
              (should (eq (alist-get 'ok models) t))
              (should (member "native/tiny-g1" ids))
              (should (member "native/tiny-g2" ids)))
            (should (eq (alist-get 'ok switched) t))
            (should (equal (alist-get 'model (alist-get 'result switched))
                           "native/tiny-g2"))
            (should (eq (alist-get 'ok checkpoint-reply) t))
            (should (file-exists-p checkpoint))
            (should
             (seq-some
              (lambda (message)
                (and (vectorp message)
                     (>= (length message) 2)
                     (equal (aref message 1) "hello\nworld")))
              (alist-get
               'messages
               (alist-get 'checkpoint (alist-get 'result checkpoint-reply)))))
            (should (eq (alist-get 'ok literal-quit) t))
            (should (equal (alist-get 'kind (alist-get 'result literal-quit))
                           "completion"))
            (should (equal (alist-get 'status
                                      (alist-get 'result literal-quit))
                           "ok"))
            (should (eq (alist-get 'ok invalid) :json-false))
            (should-not (alist-get 'id invalid))
            (should (eq (alist-get 'ok status-2) t))
            (should (equal (alist-get 'model (alist-get 'result status-2))
                           "native/tiny-g2"))
            (should (>= (alist-get 'message-count
                                   (alist-get 'result status-2))
                        3))
            (should (equal (alist-get 'kind (alist-get 'result quit)) "closed"))
            (should (eq (alist-get 'ok quit) t))
            (let ((deadline (+ (float-time) 20.0)))
              (while (and (process-live-p process)
                          (< (float-time) deadline))
                (accept-process-output process 0.1)))
            (should-not (process-live-p process))
            (should (= (process-exit-status process) 0))
            (should-not (car lines))
            (should (string-empty-p (car buffer)))))
      (when process
        (set-process-query-on-exit-flag process nil)
        (when (process-live-p process)
          (delete-process process)))
      (when (buffer-live-p stdout) (kill-buffer stdout))
      (when (buffer-live-p stderr) (kill-buffer stderr))
      (delete-directory directory t))))

(ert-run-tests-batch-and-exit)

;;; cli-jsonl-service-test.el ends here
