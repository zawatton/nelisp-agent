;;; service-test.el --- NeLisp Agent service boundary tests  -*- lexical-binding: t; -*-

;; The service owns conversation state and delegates inference/model lifecycle
;; to nelisp-llm providers.  Keep these tests runnable by both Emacs and NeLisp.
;;   emacs -Q --batch -L lisp -L ../nelisp-llm/lisp -l test/service-test.el

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'cl-lib)
(require 'nl-llm-agent-provider)
(require 'nl-agent-service)

(defvar nl-agent-service-test--fail 0)

(defun nl-agent-service-test--ck (name ok &optional extra)
  (princ (format "%-60s %s  %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-service-test--fail
                         (1+ nl-agent-service-test--fail))
                   "FAIL")
                 (or extra ""))))

(defun nl-agent-service-test--error-p (thunk)
  (condition-case nil
      (progn (funcall thunk) nil)
    (error t)))

(let* ((events nil)
       (make-mock
        (lambda (id models)
          (nl-llm-agent-provider-new
           id
           :models models
           :open
           (lambda (model options)
             (push (list 'open id model options) events)
             (when (equal model "broken")
               (error "intentional open failure"))
             (list :provider id :model model))
           :complete
           (lambda (state messages)
             (let ((model (plist-get state :model)))
               (push (list 'complete id model (copy-tree messages)) events)
               (format "%s/%s saw %d messages"
                       id model (length messages))))
           :close
           (lambda (state)
             (push (list 'close id (plist-get state :model)) events)))))
       (registry (nl-llm-agent-provider-registry-new)))
  (nl-llm-agent-provider-register
   registry
   (funcall make-mock
            "local"
            '((:id "small" :name "Small" :capabilities (generate train)))))
  (nl-llm-agent-provider-register
   registry
   (funcall make-mock
            "remote"
            '((:id "large" :name "Large")
              (:id "poolside/laguna-s-2.1:free" :name "Laguna")
              (:id "broken" :name "Broken"))))

  (let ((service
         (nl-agent-service-new
          registry "local/small"
          :system "You are NeLisp Agent."
          :options '(:temperature 0.1))))
    (nl-agent-service-test--ck
     "service opens the requested provider model"
     (equal (nl-agent-service-current-model service) "local/small"))
    (nl-agent-service-test--ck
     "service status exposes model and provider-neutral counts"
     (equal (nl-agent-service-status service)
            '(:state open :model "local/small" :generation 0
              :message-count 1)))

    (let ((result (nl-agent-service-command service "/models")))
      (nl-agent-service-test--ck
       "/models lists all public model descriptors"
       (and (eq (plist-get result :status) 'ok)
            (eq (plist-get result :kind) 'models)
            (equal (mapcar
                    (lambda (model) (plist-get model :qualified-id))
                    (plist-get result :models))
                   '("local/small"
                     "remote/large"
                     "remote/poolside/laguna-s-2.1:free"
                     "remote/broken")))))

    (let ((first (nl-agent-service-command service "hello")))
      (nl-agent-service-test--ck
       "plain input produces a structured completion"
       (and (eq (plist-get first :status) 'ok)
            (eq (plist-get first :kind) 'completion)
            (equal (plist-get first :model) "local/small")
            (equal (plist-get first :text)
                   "local/small saw 2 messages")))
      (nl-agent-service-test--ck
       "successful completion is appended to service history"
       (equal (nl-agent-service-messages service)
              '((system . "You are NeLisp Agent.")
                (user . "hello")
                (assistant . "local/small saw 2 messages")))))

    (let ((switched
           (nl-agent-service-command
            service "/model remote/poolside/laguna-s-2.1:free")))
      (nl-agent-service-test--ck
       "/model switches through the provider session"
       (and (eq (plist-get switched :status) 'ok)
            (eq (plist-get switched :kind) 'switched)
            (equal (plist-get switched :from) "local/small")
            (equal (plist-get switched :model)
                   "remote/poolside/laguna-s-2.1:free"))))
    (nl-agent-service-test--ck
     "model switching preserves service conversation"
     (= (length (nl-agent-service-messages service)) 3))

    (let ((second (nl-agent-service-command service "continue")))
      (nl-agent-service-test--ck
       "the next completion uses the selected model and full history"
       (and (equal (plist-get second :model)
                   "remote/poolside/laguna-s-2.1:free")
            (equal (plist-get second :text)
                   "remote/poolside/laguna-s-2.1:free saw 4 messages")
            (= (length (nl-agent-service-messages service)) 5))))

    (let ((failed
           (nl-agent-service-command service "/model remote/broken")))
      (nl-agent-service-test--ck
       "a failed switch returns data instead of killing the service"
       (and (eq (plist-get failed :status) 'error)
            (eq (plist-get failed :kind) 'switch)
            (stringp (plist-get failed :error)))))
    (nl-agent-service-test--ck
     "a failed switch leaves the active model unchanged"
     (equal (nl-agent-service-current-model service)
            "remote/poolside/laguna-s-2.1:free"))

    (let ((status (nl-agent-service-command service "/status")))
      (nl-agent-service-test--ck
       "/status reports a machine-readable service snapshot"
       (and (eq (plist-get status :status) 'ok)
            (eq (plist-get status :kind) 'status)
            (equal (plist-get status :model)
                   "remote/poolside/laguna-s-2.1:free")
            (= (plist-get status :generation) 1)
            (= (plist-get status :message-count) 5))))

    (nl-agent-service-test--ck
     "missing /model selector is a command error"
     (eq (plist-get (nl-agent-service-command service "/model") :status)
         'error))
    (nl-agent-service-test--ck
     "unknown slash commands are rejected"
     (eq (plist-get (nl-agent-service-command service "/unknown") :kind)
         'command))

    (let ((closed (nl-agent-service-command service "/quit")))
      (nl-agent-service-test--ck
       "/quit closes the service and provider session"
       (and (eq (plist-get closed :status) 'ok)
            (eq (plist-get closed :kind) 'closed)
            (eq (nl-agent-service-state service) 'closed))))
    (nl-agent-service-test--ck
     "closed services reject later completions as structured errors"
     (eq (plist-get (nl-agent-service-command service "too late") :kind)
         'completion)))

  (nl-agent-service-test--ck
   "provider lifecycle calls crossed the loose service boundary"
   (and (cl-find-if
         (lambda (event)
           (equal (cl-subseq event 0 3)
                  '(open "remote" "poolside/laguna-s-2.1:free")))
         events)
        (cl-find-if
         (lambda (event) (equal event '(close "local" "small")))
         events))))

(let* ((provider
        (nl-llm-agent-provider-new
         "fallback"
         :models '("primary" "broken-open" "bad" "good")
         :open
         (lambda (model _options)
           (when (equal model "broken-open")
             (error "cannot open fallback"))
           model)
         :complete
         (lambda (model messages)
           (if (member model '("primary" "bad"))
               (error "completion failed for %s" model)
             (format "%s:%d" model (length messages))))))
       (registry (nl-llm-agent-provider-registry-new)))
  (nl-llm-agent-provider-register registry provider)
  (let* ((service
          (nl-agent-service-new
           registry "fallback/primary"
           :fallbacks '("fallback/broken-open"
                        "fallback/bad"
                        "fallback/good")))
         (result (nl-agent-service-command service "recover")))
    (nl-agent-service-test--ck
     "completion failure advances through ordered fallback models"
     (and (eq (plist-get result :status) 'ok)
          (equal (plist-get result :text) "good:1")
          (equal (plist-get result :model) "fallback/good")))
    (nl-agent-service-test--ck
     "fallback completion commits one conversation turn only"
     (equal (nl-agent-service-messages service)
            '((user . "recover") (assistant . "good:1"))))
    (nl-agent-service-test--ck
     "fallback audit records every failed candidate"
     (let ((event
            (cl-find-if
             (lambda (entry)
               (eq (plist-get entry :status) 'failed-over))
             (nl-agent-service-history service))))
       (and event
            (equal (plist-get event :from) "fallback/primary")
            (equal (plist-get event :to) "fallback/good")
            (= (length (plist-get event :failures)) 3))))
    (nl-agent-service-test--ck
     "status publishes the configured fallback order"
     (equal (plist-get (nl-agent-service-status service) :fallbacks)
            '("fallback/broken-open" "fallback/bad" "fallback/good"))))

  (let* ((service
          (nl-agent-service-new
           registry "fallback/primary" :fallbacks '("fallback/bad")))
         (result (nl-agent-service-command service "do not commit")))
    (nl-agent-service-test--ck
     "exhausted fallbacks return a structured completion error"
     (and (eq (plist-get result :status) 'error)
          (eq (plist-get result :kind) 'completion)))
    (nl-agent-service-test--ck
     "exhausted fallback attempts leave conversation uncommitted"
     (null (nl-agent-service-messages service)))
    (nl-agent-service-test--ck
     "exhausted fallbacks restore the original model"
     (equal (nl-agent-service-current-model service) "fallback/primary"))))

(let* ((provider
        (nl-llm-agent-provider-new
         "checkpoint"
         :models '("a" "b")
         :open (lambda (model options) (list model options))
         :complete
         (lambda (state messages)
           (format "%s:%d" (car state) (length messages)))))
       (registry (nl-llm-agent-provider-registry-new)))
  (nl-llm-agent-provider-register registry provider)
  (let* ((source
          (nl-agent-service-new
           registry "checkpoint/a"
           :system "system"
           :options '(:temperature 0.2)
           :fallbacks '("checkpoint/b")))
         (_first (nl-agent-service-command source "hello"))
         (_switch (nl-agent-service-switch source "checkpoint/b"))
         (checkpoint (nl-agent-service-checkpoint source))
         (restored (nl-agent-service-new registry "checkpoint/a")))
    (nl-agent-service-test--ck
     "checkpoint contains only portable provider-neutral state"
     (equal checkpoint
            '(:format nl-agent-service-v1
              :model "checkpoint/b"
              :options (:temperature 0.2)
              :fallbacks ("checkpoint/b")
              :messages ((system . "system")
                         (user . "hello")
                         (assistant . "a:2")))))
    (nl-agent-service-restore restored checkpoint)
    (nl-agent-service-test--ck
     "restore replaces model, options, fallbacks, and conversation"
     (and (equal (nl-agent-service-current-model restored) "checkpoint/b")
          (equal (nl-llm-agent-session-options
                  (nl-agent-service-session restored))
                 '(:temperature 0.2))
          (equal (nl-agent-service-fallbacks restored) '("checkpoint/b"))
          (equal (nl-agent-service-messages restored)
                 (nl-agent-service-messages source))))
    (nl-agent-service-test--ck
     "restored conversation continues without losing context"
     (equal (plist-get
             (nl-agent-service-command restored "continue") :text)
            "b:4"))
    (let ((model-before (nl-agent-service-current-model restored))
          (messages-before (copy-tree (nl-agent-service-messages restored))))
      (nl-agent-service-test--ck
       "invalid checkpoint is rejected transactionally"
       (nl-agent-service-test--error-p
        (lambda ()
          (nl-agent-service-restore
           restored '(:format unknown :model "checkpoint/a")))))
      (nl-agent-service-test--ck
       "failed restore leaves the live service unchanged"
       (and (equal (nl-agent-service-current-model restored) model-before)
            (equal (nl-agent-service-messages restored) messages-before))))))

(princ (format "NL-AGENT-SERVICE %s (%d failures)\n"
               (if (= nl-agent-service-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-service-test--fail))
(kill-emacs (if (= nl-agent-service-test--fail 0) 0 1))

;;; service-test.el ends here
