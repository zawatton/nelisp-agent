;;; client-test.el --- asynchronous JSONL client tests -*- lexical-binding: t; -*-

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                          (file-name-directory (or load-file-name buffer-file-name
                                                   default-directory))) nil t)
)

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'nl-agent-client)

(defun nl-agent-client-test--process ()
  "Return a harmless owned process for direct filter tests." 
  (make-process :name "nl-agent-client-test-cat"
                :command (list "cat") :connection-type 'pipe
                :coding 'utf-8-unix :noquery t))

(defun nl-agent-client-test--client (process events closes)
  "Build a CLIENT around PROCESS for direct protocol tests." 
  (let ((client
         (nl-agent-client--make
          :process process :pending (list :id "request-1" :method "run")
          :approval nil :closed nil
          :stderr-buffer nil
          :on-event (lambda (_client packet) (setcar events (cons packet (car events))))
          :on-close (lambda (_client reason) (setcar closes (cons reason (car closes))))
          :next-id 0 :inflight (list :id "request-1" :method "run")
          :used-approval-tokens nil :close-notified nil :input-buffer "")))
    (process-put process 'nl-agent-client client)
    client))

(ert-deftest nl-agent-client-filter-validates-fragments-approval-and-final ()
  (let ((process (nl-agent-client-test--process))
        (events (list nil)) (closes (list nil)) client)
    (unwind-protect
        (progn
          (setq client
                (nl-agent-client-test--client process events closes))
          (nl-agent-client--filter
           process
           "{\"id\":\"request-1\",\"event\":\"approval\",\"approvalId\":\"approval-1\",\"request\":")
          (should-not (nl-agent-client-approval client))
          (nl-agent-client--filter
           process
           "{\"tool\":\"shell\",\"risk\":\"execute\",\"description\":\"Run\",\"args\":{\"command\":\"pwd\"},\"argsLisp\":\"(:command \\\"pwd\\\")\"}}\n")
          (should (equal (plist-get (nl-agent-client-approval client) :token)
                         "approval-1"))
          (should-error
           (nl-agent-client-approve client "request-1" "stale" 'once))
          (nl-agent-client-approve client "request-1" "approval-1" 'once)
          (should-not (nl-agent-client-approval client))
          (nl-agent-client--filter
           process
           "{\"id\":\"request-1\",\"ok\":true,\"result\":{}}\n")
          (should-not (nl-agent-client-inflight client))
          (should (= (length (car events)) 2))
          (should (equal (alist-get 'event (car (car events))) nil))
          (should (equal (alist-get 'ok (car (car events))) t)))
      (when (and client (not (nl-agent-client-closed client)))
        (nl-agent-client-close client))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest nl-agent-client-rejects-unsolicited-and-truncated-packets ()
  (let ((process (nl-agent-client-test--process))
        (events (list nil)) (closes (list nil)) client)
    (unwind-protect
        (progn
          (setq client
                (nl-agent-client-test--client process events closes))
          (setf (nl-agent-client-inflight client) nil)
          (nl-agent-client--filter
           process "{\"id\":\"request-1\",\"ok\":true,\"result\":{}}\n")
          (should (nl-agent-client-closed client))
          (should-not (nl-agent-client-inflight client))
          (should-not (nl-agent-client-approval client)))
      (when (and client (not (nl-agent-client-closed client)))
        (nl-agent-client-close client))
      (when (process-live-p process)
        (delete-process process))))
  (let ((process (nl-agent-client-test--process))
        (events (list nil)) (closes (list nil)) client)
    (unwind-protect
        (progn
          (setq client
                (nl-agent-client-test--client process events closes))
          (nl-agent-client--filter process "{\"id\":\"request-1\"")
          (should-not (nl-agent-client-closed client))
          (nl-agent-client--filter process "\n")
          (should (nl-agent-client-closed client))
          (should-not (nl-agent-client-inflight client))
          (should-not (nl-agent-client-approval client)))
      (when (and client (not (nl-agent-client-closed client)))
        (nl-agent-client-close client))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest nl-agent-client-request-enforces-single-flight-and-method-shapes ()
  (let* ((process (nl-agent-client-test--process))
         (client (nl-agent-client--make
                  :process process :pending nil :approval nil :closed nil
                  :stderr-buffer nil :on-event #'ignore :on-close nil
                  :next-id 0 :inflight nil :used-approval-tokens nil
                  :close-notified nil :input-buffer ""))
         sent)
    (process-put process 'nl-agent-client client)
    (unwind-protect
        (cl-letf (((symbol-function 'process-send-string)
                   (lambda (_process text) (setq sent text))))
          (should (equal (nl-agent-client-request client 'chat '(:text "hi"))
                         "request-1"))
          (should (string-match-p
                   "\\\"method\\\":\\\"chat\\\"" sent))
          (should-error (nl-agent-client-request client 'status))
          (should-error
           (nl-agent-client-approve client "request-1" "approval-1" 'once))
          (nl-agent-client--filter
           process "{\"id\":\"request-1\",\"ok\":true,\"result\":{}}\n")
          (should-not (nl-agent-client-inflight client))
          (should-error
           (nl-agent-client-request
            client 'run '(:text 7)))
          (should-not (nl-agent-client-closed client))
          (let ((nl-agent-client-max-text-chars 2))
            (should-error
             (nl-agent-client-request client 'chat '(:text "long"))))
          (let ((nl-agent-client-max-selector-chars 3))
            (should-error
             (nl-agent-client-request client 'switch '(:selector "a/long"))))
          (should-error (nl-agent-client-request client 'switch nil)))
      (when (and client (not (nl-agent-client-closed client)))
        (nl-agent-client-close client))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest nl-agent-client-rejects-replay-duplicates-and-bad-params ()
  (let ((process (nl-agent-client-test--process))
        (events (list nil)) (closes (list nil)) client)
    (unwind-protect
        (progn
          (setq client (nl-agent-client-test--client process events closes))
          (nl-agent-client--filter
           process
           "{\"id\":\"request-1\",\"event\":\"approval\",\"approvalId\":\"approval-1\",\"request\":{\"tool\":\"shell\",\"risk\":\"execute\",\"description\":\"\",\"args\":{\"command\":\"pwd\",\"command\":\"id\"},\"argsLisp\":\"(:command \\\"pwd\\\")\"}}\n")
          (should (nl-agent-client-closed client))
          (setq process (nl-agent-client-test--process)
                client (nl-agent-client-test--client process events closes))
          (nl-agent-client--filter
           process
           "{\"id\":\"request-1\",\"event\":\"approval\",\"approvalId\":\"approval-1\",\"request\":{\"tool\":\"shell\",\"risk\":\"execute\",\"description\":\"\",\"args\":{},\"argsLisp\":\"()\"}}\n")
          (nl-agent-client-approve client "request-1" "approval-1" 'once)
          (setf (nl-agent-client-inflight client)
                (list :id "request-1" :method "run"))
          (nl-agent-client--filter
           process
           "{\"id\":\"request-1\",\"event\":\"approval\",\"approvalId\":\"approval-1\",\"request\":{\"tool\":\"shell\",\"risk\":\"execute\",\"description\":\"\",\"args\":{},\"argsLisp\":\"()\"}}\n")
          (should (nl-agent-client-closed client)))
      (when (and client (not (nl-agent-client-closed client)))
        (nl-agent-client-close client))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest nl-agent-client-sends-before-a-synchronous-response ()
  (let* ((process (nl-agent-client-test--process))
         (client
          (nl-agent-client--make
           :process process :pending nil :approval nil :closed nil
           :stderr-buffer nil :on-event #'ignore :on-close nil :next-id 0
           :inflight nil :used-approval-tokens nil :close-notified nil
           :input-buffer ""))
         sent)
    (process-put process 'nl-agent-client client)
    (unwind-protect
        (cl-letf (((symbol-function 'process-send-string)
                   (lambda (_process text)
                     (setq sent text)
                     (nl-agent-client--filter
                      process
                      "{\"id\":\"request-1\",\"ok\":true,\"result\":{}}\n"))))
          (should (equal (nl-agent-client-request client 'status)
                         "request-1"))
          (should (string-match-p "request-1" sent))
          (should-not (nl-agent-client-pending client))
          (should-not (nl-agent-client-inflight client)))
      (when (and client (not (nl-agent-client-closed client)))
        (nl-agent-client-close client))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest nl-agent-client-owned-process-returns-a-real-response ()
  (let* ((directory (make-temp-file "nl-agent-client-real-" t))
         (events nil) (closes nil) (client nil))
    (unwind-protect
        (progn
          (setq client
                (nl-agent-client-open
                 (list "sh" "-c"
                       "IFS= read -r line; printf '%s\\n' '{\"id\":\"request-1\",\"ok\":true,\"result\":{}}'")
                 directory
                 (lambda (_client packet) (push packet events))
                 (lambda (_client reason) (push reason closes))))
          (should (equal (nl-agent-client-request client 'status) "request-1"))
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (null events) (< (float-time) deadline))
              (accept-process-output (nl-agent-client-process client) 0.05)))
          (should (= (length events) 1))
          (should (equal (alist-get 'id (car events)) "request-1"))
          (should (eq (alist-get 'ok (car events)) t))
          (should-not (nl-agent-client-inflight client)))
      (when client (nl-agent-client-close client))
      (delete-directory directory t))))

(ert-deftest nl-agent-client-sentinel-uses-terminal-process-statuses ()
  (dolist (status '(stop continue))
    (let ((process (nl-agent-client-test--process))
          (events (list nil)) (closes (list nil)) client)
      (unwind-protect
          (progn
            (setq client (nl-agent-client-test--client process events closes))
            (setf (nl-agent-client-approval client)
                  (list :id "request-1" :token "approval-1"))
            (cl-letf (((symbol-function 'process-live-p)
                       (lambda (_process) nil))
                      ((symbol-function 'process-status)
                       (lambda (_process) status)))
              (nl-agent-client--sentinel process "segmentation fault"))
            (should-not (nl-agent-client-closed client)))
        (when (and client (not (nl-agent-client-closed client)))
          (nl-agent-client-close client))
        (when (process-live-p process)
          (delete-process process)))))
  (let ((process (nl-agent-client-test--process))
        (events (list nil)) (closes (list nil)) client)
    (unwind-protect
        (progn
          (setq client (nl-agent-client-test--client process events closes))
          (setf (nl-agent-client-approval client)
                (list :id "request-1" :token "approval-1"))
          (cl-letf (((symbol-function 'process-live-p)
                     (lambda (_process) nil))
                    ((symbol-function 'process-status)
                     (lambda (_process) 'signal)))
            (nl-agent-client--sentinel process "arbitrary event"))
          (should (nl-agent-client-closed client))
          (should-not (nl-agent-client-pending client))
          (should-not (nl-agent-client-inflight client))
          (should-not (nl-agent-client-approval client))
          (should (= (length (car closes)) 1))
          (nl-agent-client--sentinel process "another event")
          (should (= (length (car closes)) 1)))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest nl-agent-client-sentinel-rejects-truncated-frame-and-stops-after-close ()
  (let ((process (nl-agent-client-test--process))
        (events (list nil)) (closes (list nil)) client)
    (unwind-protect
        (progn
          (setq client (nl-agent-client-test--client process events closes))
          (nl-agent-client--filter process "{\"id\":\"request-1\"")
          (cl-letf (((symbol-function 'process-live-p)
                     (lambda (_process) nil))
                    ((symbol-function 'process-status)
                     (lambda (_process) 'exit)))
            (nl-agent-client--sentinel process "arbitrary"))
          (should (nl-agent-client-closed client))
          (should-not (nl-agent-client-pending client)))
      (when (process-live-p process)
        (delete-process process))))
  (let ((process (nl-agent-client-test--process)) client (events 0))
    (unwind-protect
        (progn
          (setq client
                (nl-agent-client--make
                 :process process :pending (list :id "request-1" :method "status")
                 :approval nil :closed nil :stderr-buffer nil
                 :on-event (lambda (_client _packet)
                             (setq events (1+ events))
                             (nl-agent-client-close client))
                 :on-close nil :next-id 0
                 :inflight (list :id "request-1" :method "status")
                 :used-approval-tokens nil :close-notified nil
                 :input-buffer ""))
          (process-put process 'nl-agent-client client)
          (nl-agent-client--filter
           process
           "{\"id\":\"request-1\",\"ok\":true,\"result\":{}}\n{\"id\":\"request-2\",\"ok\":true,\"result\":{}}\n")
          (should (nl-agent-client-closed client))
          (should (= events 1))
          (should (equal (nl-agent-client-input-buffer client) "")))
      (when (and client (not (nl-agent-client-closed client)))
        (nl-agent-client-close client))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest nl-agent-client-rejects-wrong-id-and-duplicate-envelope ()
  (dolist (line
           '("{\"id\":\"other\",\"ok\":true,\"result\":{}}\n"
             "{\"id\":\"request-1\",\"ok\":true,\"ok\":true,\"result\":{}}\n"))
    (let ((process (nl-agent-client-test--process))
          (events (list nil)) (closes (list nil)) client)
      (unwind-protect
          (progn
            (setq client (nl-agent-client-test--client process events closes))
            (nl-agent-client--filter process line)
            (should (nl-agent-client-closed client))
            (should-not (nl-agent-client-pending client))
            (should-not (nl-agent-client-inflight client)))
        (when (and client (not (nl-agent-client-closed client)))
          (nl-agent-client-close client))
        (when (process-live-p process)
          (delete-process process))))))

(provide 'client-test)
(ert-run-tests-batch-and-exit)

;;; client-test.el ends here
