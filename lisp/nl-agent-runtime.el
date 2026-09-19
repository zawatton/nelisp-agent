;;; nl-agent-runtime.el --- model/tool observation loop for NeLisp Agent  -*- lexical-binding: t; -*-

;; The service owns model state and fallback.  This module only interprets one
;; CodeAct proposal at a time, crosses the permission boundary, and feeds the
;; resulting observation back to the active model.  Its detached trajectory is
;; suitable for audit and later training-data curation.

;;; Code:

(require 'nl-llm-compat)
(require 'cl-lib)
(require 'subr-x)
(require 'nl-llm-agent)
(require 'nl-agent-service)
(require 'nl-agent-permission)

(defun nl-agent-runtime--keys (keys allowed where)
  "Validate KEYS against ALLOWED for WHERE."
  (unless (= (% (length keys) 2) 0)
    (error "%s: options must be KEY VALUE pairs" where))
  (let ((tail keys))
    (while tail
      (unless (memq (car tail) allowed)
        (error "%s: unknown option %S" where (car tail)))
      (setq tail (cddr tail))))
  keys)

(defun nl-agent-runtime--tool-list (registry)
  "Return a compact prompt fragment for REGISTRY."
  (string-join
   (mapcar
    (lambda (tool)
      (let* ((metadata (plist-get tool :metadata))
             (schema (and metadata
                          (plist-get metadata :input-schema)))
             (base
              (format "- %s [%s]: %s"
                      (plist-get tool :name)
                      (plist-get tool :risk)
                      (plist-get tool :description))))
        (if schema
            (concat
             base
             "\n  input-schema: "
             (nl-llm-agent--truncate (prin1-to-string schema) 1200))
          base)))
    (nl-agent-tool-catalog registry))
   "\n"))

;;;###autoload
(defun nl-agent-runtime-system-prompt (registry)
  "Return the CodeAct system prompt specialized for REGISTRY."
  (concat
   nl-llm-agent-system-prompt
   "\n\nRegistered execution capabilities:\n"
   (let ((catalog (nl-agent-runtime--tool-list registry)))
     (if (string-empty-p catalog) "(none)" catalog))
   "\nA syntactically valid action is still subject to host permission policy."))

(defun nl-agent-runtime--action-call (action)
  "Map parsed ACTION to (TOOL ARGS), or nil."
  (pcase action
    (`(shell ,command) (list "shell" (list :command command)))
    (`(edit ,path ,search ,replace)
     (list "edit" (list :path path :search search :replace replace)))
    (`(elisp ,code) (list "elisp" (list :code code)))
    (`(tool ,name ,arguments) (list name arguments))
    (_ nil)))

(defun nl-agent-runtime--observation (tool-result)
  "Turn TOOL-RESULT into model-visible observation text."
  (pcase (plist-get tool-result :status)
    ('ok (concat "OBSERVATION:\n" (plist-get tool-result :text)))
    ('denied
     (concat "OBSERVATION: DENIED -- "
             (or (plist-get tool-result :error) "permission denied")))
    (_
     (concat "OBSERVATION: ERROR -- "
             (or (plist-get tool-result :error) "tool failed")))))

(defun nl-agent-runtime--service-effect
    (service registry tool-name tool-result model-refresh)
  "Apply an authorized TOOL-NAME service directive and return TOOL-RESULT.

The directive type comes from the host-published tool metadata, and the value
comes from the correlated host result.  MODEL-REFRESH may update a broker model
catalog immediately before a switch."
  (if (not (eq (plist-get tool-result :status) 'ok))
      tool-result
    (let* ((tool (nl-agent-tool--resolve registry tool-name))
           (operation
            (plist-get (nl-agent-tool-metadata tool) :service-operation)))
      (pcase operation
        ('model-switch
         (condition-case err
             (let ((selector (plist-get tool-result :value)))
               (unless (and (stringp selector) (> (length selector) 0))
                 (error "host returned an invalid model selector"))
               (when model-refresh (funcall model-refresh))
               (nl-agent-service-switch service selector)
               (let ((updated (copy-tree tool-result)))
                 (setq updated
                       (plist-put updated :service-operation 'model-switch))
                 (setq updated
                       (plist-put
                        updated :model
                        (nl-agent-service-current-model service)))
                 (plist-put
                  updated :text
                  (format "model switched to %s"
                          (nl-agent-service-current-model service)))))
           (error
            (list :status 'error :tool tool-name
                  :authorization
                  (copy-tree (plist-get tool-result :authorization))
                  :error (format "model switch failed: %S" err)))))
        (_ tool-result)))))

(defun nl-agent-runtime--event
    (step model assistant action &optional tool-result observation)
  "Build a detached trajectory event for one STEP."
  (append
   (list :step step :model model :assistant assistant
         :action (copy-tree action))
   (when tool-result (list :tool-result (copy-tree tool-result)))
   (when observation (list :observation observation))))

;;;###autoload
(defun nl-agent-runtime-run (service registry policy task &rest keys)
  "Run TASK as a permission-gated model/tool loop.

SERVICE supplies model completions and transparent fallback.  REGISTRY supplies
tools, and POLICY decides whether each exact call may execute.  KEYS accepts
:MAX-STEPS (default 12), :TRACE, called with (STEP ROLE CONTENT), and
:MODEL-REFRESH, called after host authorization and before a model-switch
service directive.

The return plist contains :STATUS (`done', `limit', or `error'), :STEPS,
:RESULT, :MESSAGES, and chronological :TRAJECTORY."
  (nl-agent-runtime--keys
   keys '(:max-steps :trace :model-refresh) "nl-agent-runtime-run")
  (unless (nl-agent-service-p service)
    (error "nl-agent-runtime-run: invalid service"))
  (unless (nl-agent-tool-registry-p registry)
    (error "nl-agent-runtime-run: invalid tool registry"))
  (unless (nl-agent-permission-policy-p policy)
    (error "nl-agent-runtime-run: invalid permission policy"))
  (unless (stringp task)
    (error "nl-agent-runtime-run: TASK must be text"))
  (let ((max-steps (or (plist-get keys :max-steps) 12))
        (trace (plist-get keys :trace))
        (model-refresh (plist-get keys :model-refresh))
        (input (concat "TASK: " task))
        (step 0)
        (status 'limit)
        (result nil)
        (error-text nil)
        (trajectory nil))
    (unless (and (integerp max-steps) (> max-steps 0))
      (error "nl-agent-runtime-run: :max-steps must be a positive integer"))
    (when trace (funcall trace 0 'user task))
    (when (and model-refresh (not (functionp model-refresh)))
      (error "nl-agent-runtime-run: :MODEL-REFRESH must be a function"))
    (catch 'nl-agent-runtime-finished
      (while (< step max-steps)
        (setq step (1+ step))
        (condition-case err
            (let* ((assistant (nl-agent-service-send service input))
                   (model (nl-agent-service-current-model service))
                   (action (nl-llm-agent-parse-action assistant))
                   (call (nl-agent-runtime--action-call action)))
              (when trace (funcall trace step 'assistant assistant))
              (cond
               ((eq (car action) 'done)
                (setq status 'done)
                (setq result (cadr action))
                (setq trajectory
                      (append trajectory
                              (list
                               (nl-agent-runtime--event
                                step model assistant action))))
                (throw 'nl-agent-runtime-finished t))
               (call
                (let* ((context
                        (list :step step :model model :task task))
                       (tool-result
                        (nl-agent-runtime--service-effect
                         service registry (car call)
                         (nl-agent-permission-call
                          policy registry (car call) (cadr call) context)
                         model-refresh))
                       (observation
                        (nl-agent-runtime--observation tool-result)))
                  (setq trajectory
                        (append trajectory
                                (list
                                 (nl-agent-runtime--event
                                  step model assistant action tool-result
                                  observation))))
                  (setq input (nl-llm-agent--truncate observation 4000))
                  (when trace
                    (funcall trace step 'observation input))))
               (t
                (let ((observation
                       "OBSERVATION: no recognized action found. Emit exactly one action block."))
                  (setq trajectory
                        (append trajectory
                                (list
                                 (nl-agent-runtime--event
                                  step model assistant action nil
                                  observation))))
                  (setq input observation)
                  (when trace
                    (funcall trace step 'observation input))))))
          (error
           (setq status 'error)
           (setq error-text (format "%S" err))
           (setq result error-text)
           (throw 'nl-agent-runtime-finished nil)))))
    (append
     (list :status status
           :steps step
           :result result
           :messages (copy-tree (nl-agent-service-messages service))
           :trajectory (copy-tree trajectory))
     (when error-text (list :error error-text)))))

(provide 'nl-agent-runtime)
;;; nl-agent-runtime.el ends here
