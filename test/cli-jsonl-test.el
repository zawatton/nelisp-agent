;;; cli-jsonl-test.el --- persistent JSONL CLI session -*- lexical-binding: t; -*-

(add-to-list 'load-path (expand-file-name "lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-llm/lisp"))
(add-to-list 'load-path (expand-file-name "../nelisp-photon/lisp"))

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'seq)
(require 'nl-agent-cli)
(require 'nl-agent-jsonl)

(defun nl-agent-cli-jsonl-test--parse-output (line)
  "Parse one emitted JSON LINE as a string-key alist."
  (json-parse-string line :object-type 'alist :array-type 'array
                     :null-object nil :false-object :json-false))

(ert-deftest nl-agent-cli-jsonl-parser-is-explicit-and-mutually-exclusive ()
  (should (equal (nl-agent-cli-parse-args '(
                            "--jsonl" "--unattended"))
                 '(:jsonl t :unattended t)))
  (should-error
   (nl-agent-cli-parse-args '(
                            "--jsonl" "--task" "run this")))
  (should-error
   (nl-agent-cli-parse-args '(
                            "--jsonl" "--chat" "say this")))
  (should-error (nl-agent-cli-parse-args '("--jsonl" "--help")))
  (should-error (nl-agent-cli-parse-args '("--jsonl" "--version")))
  (let ((old (getenv "NELISP_AGENT_JSONL")))
    (unwind-protect
        (progn
          (setenv "NELISP_AGENT_JSONL" "1")
          (should-not (plist-get
                       (nl-agent-cli-options-with-environment nil)
                       :jsonl)))
      (setenv "NELISP_AGENT_JSONL" old))))

(ert-deftest nl-agent-cli-jsonl-loop-correlates-and-keeps-one-supervisor ()
  (let ((inputs
         (list
          "{\"id\":\"run-1\",\"method\":\"run\",\"params\":{\"text\":\"first\"}}"
          "{\"id\":\"chat-1\",\"method\":\"chat\",\"params\":{\"text\":\"hello\"}}"
          "{\"id\":\"quit-1\",\"method\":\"quit\"}"))
        (prompts nil) (outputs nil)
        (calls nil)
        (supervisor (list :persistent t)))
    (cl-letf (((symbol-function 'nl-agent-supervisor-call)
               (lambda (given request)
                 (push (list given request) calls)
                 (pcase (car request)
                   ('run '(:kind agent-run :status done :result "ran"))
                   ('chat '(:kind completion :status ok :text "replied"))
                   ('quit '(:kind closed :status ok)))))
              ((symbol-function 'nl-agent-supervisor-p)
               (lambda (_value) t)))
      (should (= (nl-agent-cli-run-jsonl
                  supervisor
                  (lambda (prompt)
                    (push prompt prompts)
                    (prog1 (car inputs) (setq inputs (cdr inputs))))
                  (lambda (line) (push line outputs)))
                 0)))
    (setq outputs (nreverse outputs)
          calls (nreverse calls)
          prompts (nreverse prompts))
    (should (= (length calls) 3))
    (should (cl-every (lambda (call) (eq (car call) supervisor)) calls))
    (should (equal (mapcar #'car (mapcar #'cadr calls))
                   '(run chat quit)))
    (should (equal prompts '("" "" "")))
    (should (equal (mapcar (lambda (line)
                            (alist-get 'id
                                       (nl-agent-cli-jsonl-test--parse-output
                                        line)))
                          outputs)
                   '("run-1" "chat-1" "quit-1")))
    (should (cl-every
             (lambda (line)
               (eq (alist-get 'ok
                              (nl-agent-cli-jsonl-test--parse-output line))
                   t))
             outputs))))

(ert-deftest nl-agent-cli-jsonl-invalid-continues-with-null-id ()
  (let ((inputs
         (list
          "not json"
          "{\"id\":\"bad\",\"method\":\"explode\"}"
          "{\"id\":\"status-1\",\"method\":\"status\"}"
          "{\"id\":\"quit-1\",\"method\":\"quit\"}"))
        outputs calls)
    (cl-letf (((symbol-function 'nl-agent-supervisor-call)
               (lambda (_supervisor request)
                 (push request calls)
                 (if (eq (car request) 'status)
                     '(:kind status :status ok :state ready)
                   '(:kind closed :status ok)))))
      (nl-agent-cli-run-jsonl
       'service
       (lambda (_prompt)
         (prog1 (car inputs) (setq inputs (cdr inputs))))
       (lambda (line) (push line outputs))))
    (setq outputs (nreverse outputs)
          calls (nreverse calls))
    (should (= (length calls) 2))
    (should (equal (mapcar (lambda (line)
                            (alist-get 'id
                                       (nl-agent-cli-jsonl-test--parse-output
                                        line)))
                          (seq-take outputs 2))
                   '(nil nil)))
    (should (equal (alist-get 'id
                             (nl-agent-cli-jsonl-test--parse-output
                              (nth 2 outputs)))
                   "status-1"))))

(ert-deftest nl-agent-cli-jsonl-dispatch-error-is-not-replayed ()
  (let ((inputs
         (list
          "{\"id\":\"one\",\"method\":\"run\",\"params\":{\"text\":\"x\"}}"
          "{\"id\":\"quit\",\"method\":\"quit\"}"))
        outputs calls)
    (cl-letf (((symbol-function 'nl-agent-supervisor-call)
               (lambda (_supervisor request)
                 (push request calls)
                 (if (eq (car request) 'run)
                     (error "private path should not escape")
                   '(:kind closed :status ok)))))
      (nl-agent-cli-run-jsonl
       'service
       (lambda (_prompt)
         (prog1 (car inputs) (setq inputs (cdr inputs))))
       (lambda (line) (push line outputs))))
    (setq outputs (nreverse outputs)
          calls (nreverse calls))
    (should (= (length calls) 2))
    (let ((reply (nl-agent-cli-jsonl-test--parse-output (car outputs))))
      (should (equal (alist-get 'id reply) "one"))
      (should (eq (alist-get 'ok reply) :json-false))
      (should (equal (alist-get 'code (alist-get 'error reply))
                     "request_failed")))))

(ert-deftest nl-agent-cli-jsonl-writer-failure-is-single-shot ()
  (let ((writes 0)
        (input "{\"id\":\"one\",\"method\":\"status\"}"))
    (cl-letf (((symbol-function 'nl-agent-supervisor-call)
               (lambda (_supervisor _request)
                 '(:kind status :status ok))))
      (should-error
       (nl-agent-cli-run-jsonl
        'service
        (lambda (_prompt) (prog1 input (setq input nil)))
        (lambda (_line)
          (setq writes (1+ writes))
          (error "closed stdout")))))
    (should (= writes 1))))

(ert-deftest nl-agent-cli-jsonl-main-does-not-reply-after-session-io-failure ()
  (let ((command-line-args-left '("--jsonl"))
        (outputs nil) (exit-code nil))
    (cl-letf (((symbol-function 'nl-agent-cli-run-options)
               (lambda (_options)
                 (signal 'nl-agent-cli-jsonl-session-error
                         '("JSONL output failed"))))
              ((symbol-function 'nl-agent-cli--write-line)
               (lambda (line) (push line outputs)))
              ((symbol-function 'kill-emacs)
               (lambda (code) (setq exit-code code))))
      (nl-agent-cli-main))
    (should (= exit-code 2))
    (should-not outputs)))

(ert-deftest nl-agent-cli-jsonl-shutdown-failure-is-terminal-error ()
  (let ((outputs nil))
    (cl-letf (((symbol-function 'nl-agent-cli--supervisor)
               (lambda (_options _approval) 'service))
              ((symbol-function 'nl-agent-cli-run-jsonl)
               (lambda (&rest _args) 0))
              ((symbol-function 'nl-agent-supervisor-stop)
               (lambda (_supervisor) (error "shutdown fixture")))
              ((symbol-function 'nl-agent-cli--write-line)
               (lambda (line) (push line outputs))))
      (should (= (nl-agent-cli-run-options '(:jsonl t)) 2)))
    (should (= (length outputs) 1))
    (let ((reply (nl-agent-cli-jsonl-test--parse-output (car outputs))))
      (should-not (alist-get 'id reply))
      (should (equal (alist-get 'code (alist-get 'error reply))
                     "shutdown_error")))))

(ert-deftest nl-agent-cli-jsonl-session-failure-is-not-masked-by-shutdown ()
  (let ((outputs nil))
    (cl-letf (((symbol-function 'nl-agent-cli--supervisor)
               (lambda (_options _approval) 'service))
              ((symbol-function 'nl-agent-cli-run-jsonl)
               (lambda (&rest _args)
                 (signal 'nl-agent-cli-jsonl-session-error
                         '("closed stdout"))))
              ((symbol-function 'nl-agent-supervisor-stop)
               (lambda (_supervisor) (error "shutdown fixture")))
              ((symbol-function 'nl-agent-cli--write-line)
               (lambda (line) (push line outputs))))
      (should-error
       (nl-agent-cli-run-options '(:jsonl t))
       :type 'nl-agent-cli-jsonl-session-error))
    (should-not outputs)))

(ert-deftest nl-agent-cli-jsonl-preserves-explicit-trajectory-capture ()
  (let ((input "{\"id\":\"run\",\"method\":\"run\",\"params\":{\"text\":\"capture\"}}")
        (captured nil)
        (outputs nil))
    (require 'nl-agent-trajectory)
    (cl-letf (((symbol-function 'nl-agent-supervisor-call)
               (lambda (_supervisor _request)
                 '(:kind agent-run :status done :result "captured")))
              ((symbol-function 'nl-agent-trajectory-save)
               (lambda (directory task response)
                 (setq captured (list directory task response))
                 "trajectory-record")))
      (nl-agent-cli-run-jsonl
       'service
       (lambda (_prompt) (prog1 input (setq input nil)))
       (lambda (line) (push line outputs))
       "capture-directory"))
    (should (equal (car captured) "capture-directory"))
    (should (equal (cadr captured) "capture"))
    (should (equal (plist-get (caddr captured) :result) "captured"))
    (should (equal (alist-get 'ok
                    (nl-agent-cli-jsonl-test--parse-output (car outputs))
                    )
                   t))))

(ert-deftest nl-agent-cli-jsonl-forces-unattended-approval ()
  (let (approval run-called stopped)
    (cl-letf (((symbol-function 'nl-agent-cli--supervisor)
               (lambda (_options given-approval)
                 (setq approval given-approval)
                 'service))
              ((symbol-function 'nl-agent-cli-run-jsonl)
               (lambda (_supervisor &rest _args)
                 (setq run-called t)
                 0))
              ((symbol-function 'nl-agent-supervisor-stop)
               (lambda (_supervisor) (setq stopped t))))
      (should (= (nl-agent-cli-run-options
                  '(:jsonl t :unattended nil))
                 0)))
    (should run-called)
    (should-not approval)
    (should stopped)))

(ert-deftest nl-agent-cli-jsonl-startup-error-is-one-json-line ()
  (let ((command-line-args-left '(
                                  "--jsonl" "--unknown-option"))
        (outputs nil) (exit-code nil))
    (cl-letf (((symbol-function 'nl-agent-cli--write-line)
               (lambda (line) (push line outputs)))
              ((symbol-function 'kill-emacs)
               (lambda (code) (setq exit-code code))))
      (nl-agent-cli-main))
    (setq outputs (nreverse outputs))
    (should (= exit-code 2))
    (should (= (length outputs) 1))
    (let ((reply (nl-agent-cli-jsonl-test--parse-output (car outputs))))
      (should-not (alist-get 'id reply))
      (should (eq (alist-get 'ok reply) :json-false))
      (should (equal (alist-get 'code (alist-get 'error reply))
                     "startup_error")))))

(provide 'cli-jsonl-test)

(ert-run-tests-batch-and-exit)
;;; cli-jsonl-test.el ends here
