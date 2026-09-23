;;; stdio-test.el --- NeLisp Agent stdio protocol tests  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'cl-lib)
(require 'nl-llm-agent-provider)
(require 'nl-agent-service)
(require 'nl-agent-stdio)

(defvar nl-agent-stdio-test--fail 0)

(defun nl-agent-stdio-test--ck (name ok)
  (princ (format "%-58s %s\n" name
                 (if ok "PASS"
                   (setq nl-agent-stdio-test--fail
                         (1+ nl-agent-stdio-test--fail))
                   "FAIL"))))

(defun nl-agent-stdio-test--error-p (thunk)
  (condition-case nil
      (progn (funcall thunk) nil)
    (error t)))

(defun nl-agent-stdio-test--unique-keys-p (plist)
  "Return non-nil when PLIST contains no duplicate keys."
  (let ((tail plist) seen ok)
    (setq ok t)
    (while (and tail ok)
      (unless (and (consp tail) (consp (cdr tail)))
        (setq ok nil tail nil))
      (when ok
        (let ((key (car tail)))
          (when (memq key seen)
            (setq ok nil))
          (push key seen)
          (setq tail (cddr tail)))))
    ok))

(let* ((provider
        (nl-llm-agent-provider-new
         "mock"
         :models '((:id "a" :name "A") (:id "b" :name "B"))
         :open (lambda (model _options) model)
         :complete
         (lambda (model messages)
           (format "%s:%s" model (cdr (car (last messages)))))))
       (registry (nl-llm-agent-provider-registry-new)))
  (nl-llm-agent-provider-register registry provider)
  (let ((service (nl-agent-service-new registry "mock/a")))
    (nl-agent-stdio-test--ck
     "(models) maps to the public model catalog"
     (eq (plist-get
          (nl-agent-stdio-handle service '(models)) :kind)
         'models))
    (nl-agent-stdio-test--ck
     "(models) exposes unique public descriptor keys"
     (cl-every #'nl-agent-stdio-test--unique-keys-p
               (plist-get (nl-agent-stdio-handle service '(models))
                          :models)))
    (nl-agent-stdio-test--ck
     "(chat TEXT) produces a completion"
     (equal (plist-get
             (nl-agent-stdio-handle service '(chat "hello")) :text)
            "a:hello"))
    (nl-agent-stdio-test--ck
     "(switch SELECTOR) selects another model"
     (and (eq (plist-get
               (nl-agent-stdio-handle service '(switch "mock/b")) :status)
              'ok)
          (equal (nl-agent-service-current-model service) "mock/b")))
    (let ((model-before (nl-agent-service-current-model service))
          (quit-text
           (nl-agent-stdio-handle service '(chat "/quit")))
          (model-text
           (nl-agent-stdio-handle service '(chat "/model mock/b"))))
      (nl-agent-stdio-test--ck
       "(chat TEXT) treats /quit as literal model input"
       (and (equal (plist-get quit-text :text) "b:/quit")
            (eq (nl-agent-service-state service) 'open)))
      (nl-agent-stdio-test--ck
       "(chat TEXT) treats /model as literal model input"
       (and (equal (plist-get model-text :text) "b:/model mock/b")
            (equal (nl-agent-service-current-model service) model-before))))
    (nl-agent-stdio-test--ck
     "(command TEXT) exposes the same command surface"
     (eq (plist-get
          (nl-agent-stdio-handle service '(command "/status")) :kind)
         'status))
    (nl-agent-stdio-test--ck
     "invalid arity is a protocol error"
     (eq (plist-get
          (nl-agent-stdio-handle service '(chat "one" "two")) :kind)
         'protocol))
    (nl-agent-stdio-test--ck
     "unknown operations are protocol errors"
     (eq (plist-get
          (nl-agent-stdio-handle service '(erase-everything)) :status)
         'error))
    (nl-agent-stdio-test--ck
     "(run TASK) fails closed when no runtime is configured"
     (eq (plist-get
          (nl-agent-stdio-handle service '(run "work")) :kind)
         'protocol))
    (nl-agent-stdio-test--ck
     "(run TASK) delegates to an explicitly configured runtime"
     (equal
      (nl-agent-stdio-handle
       service '(run "work")
       (lambda (task) (list :status 'done :result task)))
      '(:kind agent-run :status done :result "work")))
    (nl-agent-stdio-test--ck
     "line parser rejects trailing forms without evaluating them"
     (eq (plist-get
         (nl-agent-stdio-parse-line "(status) (quit)") :status)
         'error))
    (let ((side-effect nil))
      (nl-agent-stdio-test--ck
       "line parser disables read-time evaluation"
       (and (eq (plist-get
                 (nl-agent-stdio-parse-line
                  "#.(setq side-effect t)") :status)
                'error)
            (null side-effect))))
    (nl-agent-stdio-test--ck
     "line parser accepts one complete data form"
     (equal (nl-agent-stdio-parse-line "  (chat \"safe\")  ")
            '(:status ok :request (chat "safe"))))
    (let ((wire
           (with-temp-buffer
             (let ((standard-output (current-buffer)))
               (nl-agent-stdio-write '(:text "first\nsecond")))
             (buffer-string))))
      (nl-agent-stdio-test--ck
       "stdio writer keeps multiline strings inside one wire frame"
       (and (= (length (split-string wire "\n")) 2)
            (equal
             (nl-agent-stdio-parse-line (string-trim-right wire))
             '(:status ok :request (:text "first\nsecond"))))))
    (let ((writes nil)
          (lines '("(inference-result 1 \"from host\")")))
      (setq nl-agent-stdio--next-request-id 0)
      (cl-letf (((symbol-function 'nl-agent-stdio-write)
                 (lambda (form) (setq writes (list form))))
                ((symbol-function 'nl-agent-stdio-next-line)
                 (lambda () (let ((line (car lines)))
                              (setq lines (cdr lines))
                              line))))
        (nl-agent-stdio-test--ck
         "stdio broker performs a correlated inference round trip"
         (and
          (equal
           (nl-agent-stdio-broker-call
            '(:kind inference :provider "remote" :model "a"
              :options nil :messages ((user . "hello"))))
           "from host")
          (equal
           (car writes)
           '(:event inference :request-id 1 :provider "remote" :model "a"
             :options nil :messages ((user . "hello"))))))))
    (let ((lines '("(inference-error 1 \"upstream unavailable\")")))
      (setq nl-agent-stdio--next-request-id 0)
      (cl-letf (((symbol-function 'nl-agent-stdio-write) (lambda (_form) nil))
                ((symbol-function 'nl-agent-stdio-next-line)
                 (lambda () (car lines))))
        (nl-agent-stdio-test--ck
         "stdio broker turns host errors into provider failures"
         (nl-agent-stdio-test--error-p
          (lambda ()
            (nl-agent-stdio-broker-call
             '(:kind inference :provider "remote" :model "a"
               :options nil :messages nil)))))))
    (let ((writes nil)
          (lines '("(tool-result 1 \"host observation\")")))
      (setq nl-agent-stdio--next-request-id 0)
      (cl-letf (((symbol-function 'nl-agent-stdio-write)
                 (lambda (form) (setq writes (list form))))
                ((symbol-function 'nl-agent-stdio-next-line)
                 (lambda () (car lines))))
        (nl-agent-stdio-test--ck
         "stdio tool broker performs a correlated host round trip"
         (and (equal
               (nl-agent-stdio-tool-call
                "shell" '(:command "pwd") '(:step 1))
               "host observation")
              (equal
               (car writes)
               '(:event tool :request-id 1 :tool "shell"
                 :args (:command "pwd") :context (:step 1)))))))
    (let ((lines '("(tool-error 1 \"permission denied\")")))
      (setq nl-agent-stdio--next-request-id 0)
      (cl-letf (((symbol-function 'nl-agent-stdio-write) (lambda (_form) nil))
                ((symbol-function 'nl-agent-stdio-next-line)
                 (lambda () (car lines))))
        (nl-agent-stdio-test--ck
         "stdio tool broker turns host denial into a tool failure"
         (nl-agent-stdio-test--error-p
          (lambda ()
            (nl-agent-stdio-tool-call
             "shell" '(:command "pwd") nil))))))
    (let ((writes nil)
          (lines
           '("(model-catalog-result 1 ((:provider \"remote\" :id \"a\")))")))
      (setq nl-agent-stdio--next-request-id 0)
      (cl-letf (((symbol-function 'nl-agent-stdio-write)
                 (lambda (form) (setq writes (list form))))
                ((symbol-function 'nl-agent-stdio-next-line)
                 (lambda () (car lines))))
        (nl-agent-stdio-test--ck
         "stdio requests a correlated public host model catalog"
         (and
          (equal
           (nl-agent-stdio-host-model-catalog)
           '((:provider "remote" :id "a")))
          (equal (car writes)
                 '(:event model-catalog :request-id 1))))))
    (let* ((events nil)
           (broker-registry
            (nl-agent-stdio-broker-provider-registry
             '((:provider "remote" :id "a" :name "Remote A")
               (:provider "native" :id "champion" :name "Champion"))
             (lambda (event)
               (setq events (append events (list event)))
               "native reply")))
           (catalog
            (nl-llm-agent-provider-models broker-registry)))
      (nl-agent-stdio-test--ck
       "broker registry preserves dynamic host provider namespaces"
       (equal
        (mapcar (lambda (item) (plist-get item :qualified-id)) catalog)
        '("remote/a" "native/champion")))
      (let ((session
             (nl-llm-agent-session-open
              broker-registry "native/champion")))
        (nl-agent-stdio-test--ck
         "dynamic native selection routes inference back to its host provider"
         (and
          (equal
           (nl-llm-agent-session-complete
            session '((user . "hello")))
           "native reply")
          (equal (plist-get (car events) :provider) "native")
          (equal (plist-get (car events) :model) "champion")))))
    (let* ((bridge
            (nl-agent-stdio-model-bridge-new
             '((:provider "remote" :id "a"))
             (lambda (_event) "reply")))
           (same-registry
            (nl-agent-stdio-model-bridge-registry bridge)))
      (nl-agent-stdio-model-bridge-refresh
       bridge
       '((:provider "remote" :id "b")
         (:provider "native" :id "champion")))
      (nl-agent-stdio-test--ck
       "model bridge refreshes catalogs and adds providers in place"
       (equal
        (mapcar
         (lambda (item) (plist-get item :qualified-id))
         (nl-llm-agent-provider-models same-registry))
        '("remote/b" "native/champion"))))
    (let ((writes nil)
          (lines
           '("(tool-catalog-result 1 ((:name \"shell\" :risk execute)))")))
      (setq nl-agent-stdio--next-request-id 0)
      (cl-letf (((symbol-function 'nl-agent-stdio-write)
                 (lambda (form) (setq writes (list form))))
                ((symbol-function 'nl-agent-stdio-next-line)
                 (lambda () (car lines))))
        (nl-agent-stdio-test--ck
         "stdio requests a correlated public host tool catalog"
         (and
          (equal
           (nl-agent-stdio-host-tool-catalog)
           '((:name "shell" :risk execute)))
          (equal (car writes)
                 '(:event tool-catalog :request-id 1))))))
    (let* ((saved-response
            (nl-agent-stdio-handle service '(checkpoint)))
           (saved (plist-get saved-response :checkpoint)))
      (nl-agent-stdio-test--ck
       "(checkpoint) exports portable service state"
       (and (eq (plist-get saved-response :status) 'ok)
            (eq (plist-get saved-response :kind) 'checkpoint)
            (eq (plist-get saved :format) 'nl-agent-service-v1)))
      (nl-agent-service-switch service "mock/a")
      (let ((restored
             (nl-agent-stdio-handle service (list 'restore saved))))
        (nl-agent-stdio-test--ck
         "(restore SNAPSHOT) transactionally resumes a worker"
         (and (eq (plist-get restored :status) 'ok)
              (eq (plist-get restored :kind) 'restored)
              (equal (nl-agent-service-current-model service) "mock/b")))))
    (nl-agent-stdio-test--ck
     "(quit) closes the service"
     (and (eq (plist-get
               (nl-agent-stdio-handle service '(quit)) :kind)
              'closed)
          (eq (nl-agent-service-state service) 'closed)))))

(princ (format "NL-AGENT-STDIO %s (%d failures)\n"
               (if (= nl-agent-stdio-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")
               nl-agent-stdio-test--fail))
(kill-emacs (if (= nl-agent-stdio-test--fail 0) 0 1))

;;; stdio-test.el ends here
