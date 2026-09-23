;;; supervisor-test.el --- live NeLisp Agent host supervisor tests  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-supervisor)
(require 'nl-agent-host)
(require 'nl-agent-mcp-stdio)

(defvar nl-agent-supervisor-test--fail 0)

(defun nl-agent-supervisor-test--ck (name ok)
  (princ (format "%-63s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-supervisor-test--fail
                         (1+ nl-agent-supervisor-test--fail))
                   "FAIL"))))

(let* ((project-directory default-directory)
       (nelisp
        (expand-file-name
         (or (getenv "NELISP_BIN") "../nelisp/target/nelisp")
         project-directory))
       (fixture
        (expand-file-name "test/stdio-worker-fixture.el" project-directory))
       (supervisor
        (nl-agent-supervisor-new
         (list nelisp "--load" fixture)
         :directory project-directory
         :max-requests 2
         :timeout-sec 5)))
  (unwind-protect
      (progn
        (nl-agent-supervisor-start supervisor)
        (nl-agent-supervisor-test--ck
         "supervisor starts a live standalone NeLisp worker"
         (nl-agent-supervisor-live-p supervisor))
        (let ((first (nl-agent-supervisor-call supervisor '(chat "hello")))
              (switched nil))
          (nl-agent-supervisor-test--ck
           "supervisor checkpoints each successful state-changing request"
           (eq (plist-get
                (nl-agent-supervisor-checkpoint supervisor) :format)
               'nl-agent-service-v1))
          (setq switched
                (nl-agent-supervisor-call
                 supervisor '(switch "fixture/beta")))
          (nl-agent-supervisor-test--ck
           "supervisor returns ordinary service responses"
           (and (equal (plist-get first :text) "alpha:1")
                (eq (plist-get switched :kind) 'switched)))
          (nl-agent-supervisor-test--ck
           "request threshold restarts the worker exactly once"
           (and (= (nl-agent-supervisor-restart-count supervisor) 1)
                (nl-agent-supervisor-live-p supervisor))))
        (let ((continued
               (nl-agent-supervisor-call supervisor '(chat "continue"))))
          (nl-agent-supervisor-test--ck
           "checkpoint restore preserves model and conversation across restart"
           (and (equal (plist-get continued :model) "fixture/beta")
                (equal (plist-get continued :text) "beta:3"))))
        (let ((worker (nl-agent-supervisor-process supervisor)))
          (delete-process worker)
          (let ((recovered
                 (nl-agent-supervisor-call supervisor '(status))))
            (nl-agent-supervisor-test--ck
             "a crashed worker is restarted from the latest checkpoint"
             (and (= (nl-agent-supervisor-restart-count supervisor) 2)
                  (equal (plist-get recovered :model) "fixture/beta")
                  (= (plist-get recovered :message-count) 4))))))
    (nl-agent-supervisor-stop supervisor)))

(let* ((project-directory default-directory)
       (nelisp
        (expand-file-name
         (or (getenv "NELISP_BIN") "../nelisp/target/nelisp")
         project-directory))
       (worker-fixture
        (expand-file-name
         "test/stdio-agent-worker-fixture.el" project-directory))
       (mcp-fixture
        (expand-file-name
         "test/mcp-modern-server-fixture.el" project-directory))
       (emacs-binary
        (expand-file-name invocation-name invocation-directory))
       (mcp-client
        (nl-agent-mcp-stdio-client-new
         "fixture"
         (list emacs-binary "-Q" "--batch" "-l" mcp-fixture)
         :directory project-directory :timeout-sec 3))
       (mcp-transport
        (plist-get (nl-agent-mcp-client-metadata mcp-client)
                   :transport-object))
       (host-tools (nl-agent-tool-registry-new))
       (_ (nl-agent-mcp-register-tools host-tools mcp-client :risk 'read))
       (host-policy (nl-agent-permission-policy-new :mode 'smart))
       (inference-events nil)
       (shutdown-count 0)
       (supervisor
        (nl-agent-supervisor-new
         (list nelisp "--load" worker-fixture)
         :directory project-directory
         :await-ready t
         :max-requests 20
         :timeout-sec 5
         :model-catalog
         (lambda ()
           '((:provider "remote" :id "model" :name "Model")))
         :inference
         (lambda (event)
           (setq inference-events
                 (append inference-events (list event)))
           (if (= (length inference-events) 1)
               (concat
                "```tool\n"
                "(:name \"mcp.fixture.echo\" "
                ":arguments (:text \"from agent\"))\n"
                "```")
             "DONE mcp complete"))
         :tool (nl-agent-host-tool-function host-tools host-policy)
         :tool-catalog (nl-agent-host-tool-catalog-function host-tools)
         :shutdown
         (lambda ()
           (setq shutdown-count (1+ shutdown-count))
           (nl-agent-mcp-client-close mcp-client)))))
  (unwind-protect
      (let ((response
             (nl-agent-supervisor-call supervisor '(run "use MCP"))))
        (nl-agent-supervisor-test--ck
         "standalone agent completes a real host-owned MCP tool round trip"
         (and (eq (plist-get response :status) 'done)
              (equal (plist-get response :result) "mcp complete")
              (= (length inference-events) 2)
              (string-match-p
               "echo:from agent"
               (plist-get
                (car (plist-get response :trajectory)) :observation)))))
    (nl-agent-supervisor-stop supervisor)
    (nl-agent-supervisor-stop supervisor)
    (nl-agent-supervisor-test--ck
     "supervisor closes its MCP subprocess exactly once"
     (and (= shutdown-count 1)
          (nl-agent-mcp-client-closed mcp-client)
          (not (process-live-p
                (nl-agent-mcp-stdio-process mcp-transport)))))))

(let* ((project-directory default-directory)
       (nelisp
        (expand-file-name
         (or (getenv "NELISP_BIN") "../nelisp/target/nelisp")
         project-directory))
       (fixture
        (expand-file-name
         "test/stdio-agent-worker-fixture.el" project-directory))
       (inference-events nil)
       (model-catalog-requests 0)
       (tool-events nil)
       (catalog-requests 0)
       (host-tools (nl-agent-tool-registry-new))
       (host-policy
        (nl-agent-permission-policy-new
         :mode 'smart :approval (lambda (_request) 'once)))
       (_
        (nl-agent-tool-register
         host-tools
         (nl-agent-tool-new
          "shell"
          (lambda (args _context)
            (setq tool-events (append tool-events (list args)))
            "[exit 0]\nready")
          :risk 'execute)))
       (supervisor
        (nl-agent-supervisor-new
         (list nelisp "--load" fixture)
         :directory project-directory
         :await-ready t
         :max-requests 20
         :timeout-sec 5
         :model-catalog
         (lambda ()
           (setq model-catalog-requests (1+ model-catalog-requests))
           '((:provider "remote" :id "model" :name "Model")))
         :inference
         (lambda (event)
           (setq inference-events
                 (append inference-events (list event)))
           (if (= (length inference-events) 1)
               "```sh\nprintf ready\n```"
             "DONE standalone agent finished"))
         :tool (nl-agent-host-tool-function host-tools host-policy)
         :tool-catalog
         (lambda ()
           (setq catalog-requests (1+ catalog-requests))
           (nl-agent-tool-catalog host-tools)))))
  (unwind-protect
      (progn
        (let ((response
               (nl-agent-supervisor-call
                supervisor '(run "verify the host tool"))))
          (nl-agent-supervisor-test--ck
           "standalone runtime completes nested inference and tool events"
           (and (eq (plist-get response :status) 'done)
                (eq (plist-get response :kind) 'agent-run)
                (equal (plist-get response :result)
                       "standalone agent finished")
                (= (length inference-events) 2)
                (= (length tool-events) 1)
                (= catalog-requests 1)
                (= model-catalog-requests 1)))
          (nl-agent-supervisor-test--ck
           "host receives only the structured tool arguments"
           (equal (car tool-events) '(:command "printf ready")))
          (nl-agent-supervisor-test--ck
           "standalone trajectory records the brokered observation"
           (string-match-p
            "ready"
            (plist-get
             (car (plist-get response :trajectory)) :observation)))))
    (nl-agent-supervisor-stop supervisor)))

(let* ((project-directory default-directory)
       (nelisp
        (expand-file-name
         (or (getenv "NELISP_BIN") "../nelisp/target/nelisp")
         project-directory))
       (fixture
        (expand-file-name
         "test/stdio-broker-worker-fixture.el" project-directory))
       (events nil)
       (supervisor
        (nl-agent-supervisor-new
         (list nelisp "--load" fixture)
         :directory project-directory
         :max-requests 20
         :timeout-sec 5
         :inference
         (lambda (event)
           (setq events (append events (list event)))
           (if (equal (plist-get event :model) "primary")
               (error "primary unavailable at host")
             "host fallback reply")))))
  (unwind-protect
      (progn
        (nl-agent-supervisor-start supervisor)
        (let ((response
               (nl-agent-supervisor-call supervisor '(chat "hello"))))
          (nl-agent-supervisor-test--ck
           "supervisor services nested broker events until final response"
           (and (= (length events) 2)
                (equal (mapcar
                        (lambda (event) (plist-get event :model))
                        events)
                       '("primary" "fallback"))
                (equal (plist-get response :model) "remote/fallback")
                (equal (plist-get response :text) "host fallback reply")))))
    (nl-agent-supervisor-stop supervisor)))

(let* ((project-directory default-directory)
       (nelisp
        (expand-file-name
         (or (getenv "NELISP_BIN") "../nelisp/target/nelisp")
         project-directory))
       (fixture
        (expand-file-name
         "test/stdio-broker-worker-fixture.el" project-directory))
       (http-requests nil)
       (router
        (nl-agent-host-router-new
         (list
          (list :id "remote" :type 'openai
                :base-url "https://provider.invalid/v1"
                :models '("primary" "fallback")
                :transport
                (lambda (request)
                  (setq http-requests
                        (append http-requests (list request)))
                  '(:choices
                    ((:message (:content "end-to-end reply")))))))))
       (supervisor
        (nl-agent-supervisor-new
         (list nelisp "--load" fixture)
         :directory project-directory
         :max-requests 20
         :timeout-sec 5
         :inference (nl-agent-host-inference-function router))))
  (unwind-protect
      (progn
        (nl-agent-supervisor-start supervisor)
        (let ((response
               (nl-agent-supervisor-call supervisor '(chat "integrate"))))
          (nl-agent-supervisor-test--ck
           "client-to-worker-to-OpenAI-provider round trip is integrated"
           (and (equal (plist-get response :text) "end-to-end reply")
                (= (length http-requests) 1)
                (equal
                 (plist-get (plist-get (car http-requests) :body) :model)
                 "primary")))))
    (nl-agent-supervisor-stop supervisor)))

(let* ((project-directory default-directory)
       (nelisp
        (expand-file-name
         (or (getenv "NELISP_BIN") "../nelisp/target/nelisp")
         project-directory))
       (fixture
        (expand-file-name "test/stdio-worker-fixture.el" project-directory))
       (temporary-directory (make-temp-file "nl-agent-checkpoint-" t))
       (checkpoint-file
        (expand-file-name "session.checkpoint" temporary-directory))
       (command (list nelisp "--load" fixture))
       (first
        (nl-agent-supervisor-new
         command :directory project-directory :max-requests 20
         :timeout-sec 5 :checkpoint-file checkpoint-file))
       (second nil))
  (unwind-protect
      (progn
        (nl-agent-supervisor-call first '(chat "persist"))
        (nl-agent-supervisor-stop first)
        (nl-agent-supervisor-test--ck
         "checkpoint file is written with private permissions"
         (and (file-exists-p checkpoint-file)
              (= (logand (file-modes checkpoint-file) #o777) #o600)))
        (setq second
              (nl-agent-supervisor-new
               command :directory project-directory :max-requests 20
               :timeout-sec 5 :checkpoint-file checkpoint-file))
        (let ((continued
               (nl-agent-supervisor-call second '(chat "resume host"))))
          (nl-agent-supervisor-test--ck
           "a new host instance restores the durable checkpoint"
           (equal (plist-get continued :text) "alpha:3"))))
    (nl-agent-supervisor-stop first)
    (when second (nl-agent-supervisor-stop second))
    (delete-directory temporary-directory t)))

(princ (format "NL-AGENT-SUPERVISOR %s (%d failures)\n"
               (if (= nl-agent-supervisor-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-supervisor-test--fail))
(kill-emacs (if (= nl-agent-supervisor-test--fail 0) 0 1))

;;; supervisor-test.el ends here
