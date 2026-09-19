;;; nl-agent-trajectory.el --- immutable host run trajectories -*- lexical-binding: t; -*-

;; This host-owned store records model-claimed run outcomes for later audit and
;; curation.  A `done' status is not a reward, verification, or success label.

;;; Code:

(defvar read-eval)

(defconst nl-agent-trajectory-format "nl-agent-trajectory-v1"
  "Format tag for immutable host run trajectory records.")

(defconst nl-agent-trajectory-max-bytes (* 8 1024 1024)
  "Maximum serialized trajectory record size.")

(defconst nl-agent-trajectory-max-depth 32
  "Maximum nesting depth for trajectory data.")

(defconst nl-agent-trajectory-max-nodes 100000
  "Maximum number of pure-data nodes in one trajectory record.")

(defconst nl-agent-trajectory-max-integer-bits 4096
  "Maximum bit width of an integer in trajectory data.")

(defconst nl-agent-trajectory-max-records 1000
  "Maximum immutable records in one trajectory directory.")

(defconst nl-agent-trajectory--record-keys
  '(:format :task :status :steps :result :trajectory :evidence))

(defconst nl-agent-trajectory--event-required-keys
  '(:step :model :assistant :action))

(defconst nl-agent-trajectory--event-keys
  '(:step :model :assistant :action :tool-result :observation))

(defconst nl-agent-trajectory--response-required-keys
  '(:kind :status :steps :result :messages :trajectory))

(defconst nl-agent-trajectory--response-keys
  '(:kind :status :steps :result :messages :trajectory :error))

(defun nl-agent-trajectory--proper-list-p (value)
  "Return non-nil when VALUE is a finite proper list."
  (let ((slow value) (fast value) done result)
    (while (not done)
      (cond
       ((null fast) (setq result t done t))
       ((not (consp fast)) (setq done t))
       (t
        (setq fast (cdr fast))
        (cond
         ((null fast) (setq result t done t))
         ((not (consp fast)) (setq done t))
         (t
          (setq fast (cdr fast) slow (cdr slow))
          (when (eq fast slow) (setq done t)))))))
    result))

(defun nl-agent-trajectory--keys (value allowed required where)
  "Validate plist VALUE keys against ALLOWED and REQUIRED for WHERE."
  (let ((tail value) seen (pairs 0))
    (while tail
      (when (>= pairs (length allowed))
        (error "%s contains too many fields" where))
      (unless (and (consp tail) (consp (cdr tail)))
        (error "%s must contain key/value pairs" where))
      (let ((key (car tail)))
        (unless (memq key allowed)
          (error "%s has unknown key %S" where key))
        (when (memq key seen)
          (error "%s has duplicate key %S" where key))
        (setq seen (cons key seen)
              tail (cddr tail)
              pairs (1+ pairs))))
    (dolist (key required)
      (unless (memq key seen)
        (error "%s is missing key %S" where key))))
  value)

(defun nl-agent-trajectory--bump (counter)
  "Increment COUNTER and enforce the node bound."
  (setcar counter (1+ (car counter)))
  (when (> (car counter) nl-agent-trajectory-max-nodes)
    (error "trajectory data exceeds %d nodes"
           nl-agent-trajectory-max-nodes)))

(defun nl-agent-trajectory--add-bytes (value bytes)
  "Add VALUE to the source scalar BYTES budget."
  (setcar bytes (+ (car bytes) value))
  (when (> (car bytes) nl-agent-trajectory-max-bytes)
    (error "trajectory scalar data exceeds %d bytes"
           nl-agent-trajectory-max-bytes)))

(defun nl-agent-trajectory--data-copy (value depth active counter bytes)
  "Validate and detach pure data VALUE using bounded traversal state."
  (when (> depth nl-agent-trajectory-max-depth)
    (error "trajectory data exceeds depth %d"
           nl-agent-trajectory-max-depth))
  (cond
   ((stringp value)
    (nl-agent-trajectory--bump counter)
    (nl-agent-trajectory--add-bytes (string-bytes value) bytes)
    ;; Text properties may contain arbitrary runtime objects and have their own
    ;; printed representation.  Trajectories retain plain text only.
    (substring-no-properties value))
   ((or (null value) (symbolp value))
    (nl-agent-trajectory--bump counter)
    (when (symbolp value)
      (nl-agent-trajectory--add-bytes
       (string-bytes (symbol-name value)) bytes))
    value)
   ((integerp value)
    (nl-agent-trajectory--bump counter)
    (let ((limit (ash 1 nl-agent-trajectory-max-integer-bits)))
      (unless (and (< (- limit) value) (< value limit))
        (error "trajectory integer exceeds %d bits"
               nl-agent-trajectory-max-integer-bits)))
    value)
   ((floatp value)
    (nl-agent-trajectory--bump counter)
    (unless (= (- value value) 0.0)
      (error "trajectory data contains a non-finite float"))
    value)
   ((and (functionp value) (not (symbolp value)))
    (error "trajectory data must not contain compiled or lambda functions"))
   ((or (bufferp value) (markerp value) (hash-table-p value)
        (recordp value))
    (error "trajectory data contains an unsupported runtime object"))
   ((consp value)
    (let ((cursor value) head last marked)
      (unwind-protect
          (progn
            (while (consp cursor)
              (nl-agent-trajectory--bump counter)
              (when (gethash cursor active)
                (error "trajectory data contains a cycle"))
              (puthash cursor t active)
              (setq marked (cons cursor marked))
              (let ((cell
                     (cons
                      (nl-agent-trajectory--data-copy
                       (car cursor) (1+ depth) active counter bytes)
                      nil)))
                (if last (setcdr last cell) (setq head cell))
                (setq last cell cursor (cdr cursor))))
            (when cursor
              (setcdr last
                      (nl-agent-trajectory--data-copy
                       cursor (1+ depth) active counter bytes)))
            head)
        (dolist (cell marked) (remhash cell active)))))
   ((vectorp value)
    (when (> (1+ (length value))
             (- nl-agent-trajectory-max-nodes (car counter)))
      (error "trajectory vector exceeds remaining node budget"))
    (nl-agent-trajectory--bump counter)
    (when (gethash value active)
      (error "trajectory data contains a cycle"))
    (puthash value t active)
    (unwind-protect
        (let ((copy (make-vector (length value) nil))
              (index 0))
          (while (< index (length value))
            (aset copy index
                  (nl-agent-trajectory--data-copy
                   (aref value index) (1+ depth) active counter bytes))
            (setq index (1+ index)))
          copy)
      (remhash value active)))
   (t
    (error "trajectory data contains unsupported value %S" value))))

(defun nl-agent-trajectory--pure-copy (value)
  "Return a bounded detached pure-data copy of VALUE."
  (nl-agent-trajectory--data-copy
   value 0 (make-hash-table :test 'eq) (list 0) (list 0)))

(defun nl-agent-trajectory--status (value)
  "Validate and return trajectory status VALUE."
  (unless (memq value '(done limit error))
    (error "trajectory status must be done, limit, or error"))
  value)

(defun nl-agent-trajectory--event (value maximum previous)
  "Validate and detach event VALUE bounded by MAXIMUM after PREVIOUS step."
  (nl-agent-trajectory--keys
   value nl-agent-trajectory--event-keys
   nl-agent-trajectory--event-required-keys "trajectory event")
  (let ((step (plist-get value :step))
        (model (plist-get value :model))
        (assistant (plist-get value :assistant)))
    (unless (and (integerp step) (> step 0) (<= step maximum)
                 (> step previous))
      (error "trajectory event steps must increase within response steps"))
    (unless (stringp model) (error "trajectory event model must be text"))
    (unless (stringp assistant)
      (error "trajectory event assistant must be text"))
    (when (and (plist-member value :observation)
               (not (stringp (plist-get value :observation))))
      (error "trajectory event observation must be text"))
    (let ((event
           (list :step step :model model :assistant assistant
                 :action (plist-get value :action))))
      (when (plist-member value :tool-result)
        (setq event
              (append event
                      (list :tool-result
                            (plist-get value :tool-result)))))
      (when (plist-member value :observation)
        (setq event
              (append event
                      (list :observation (plist-get value :observation)))))
      event)))

(defun nl-agent-trajectory--events (value steps)
  "Validate and detach chronological event list VALUE for STEPS."
  (unless (nl-agent-trajectory--proper-list-p value)
    (error "trajectory must be a finite proper list"))
  (let ((previous 0) result)
    (dolist (event value)
      (let ((copy (nl-agent-trajectory--event event steps previous)))
        (setq previous (plist-get copy :step)
              result (cons copy result))))
    (nreverse result)))

(defun nl-agent-trajectory--validate-record (record)
  "Validate and return a fully detached canonical RECORD."
  ;; Bound and detach the complete selected record before schema processing can
  ;; allocate canonical event lists.  One shared traversal budget therefore
  ;; covers every event and nested action/tool result together.
  (setq record (nl-agent-trajectory--pure-copy record))
  (nl-agent-trajectory--keys
   record nl-agent-trajectory--record-keys
   nl-agent-trajectory--record-keys "trajectory record")
  (unless (equal (plist-get record :format) nl-agent-trajectory-format)
    (error "unsupported trajectory record format"))
  (let ((task (plist-get record :task))
        (status (nl-agent-trajectory--status (plist-get record :status)))
        (steps (plist-get record :steps))
        (result (plist-get record :result)))
    (unless (stringp task) (error "trajectory task must be text"))
    (unless (and (integerp steps) (>= steps 0))
      (error "trajectory steps must be a non-negative integer"))
    (unless (or (null result) (stringp result))
      (error "trajectory result must be text or nil"))
    (unless (equal (plist-get record :evidence) "unverified")
      (error "trajectory evidence must be unverified"))
    (list :format nl-agent-trajectory-format
          :task task
          :status status :steps steps
          :result result
          :trajectory
          (nl-agent-trajectory--events
           (plist-get record :trajectory) steps)
          :evidence "unverified")))

(defun nl-agent-trajectory--record (task response)
  "Extract and validate one privacy-bounded record from TASK and RESPONSE."
  (unless (stringp task) (error "trajectory task must be text"))
  (nl-agent-trajectory--keys
   response nl-agent-trajectory--response-keys
   nl-agent-trajectory--response-required-keys "agent-run response")
  (unless (eq (plist-get response :kind) 'agent-run)
    (error "trajectory save requires an agent-run response"))
  ;; Require the real runtime response shape, but deliberately neither inspect
  ;; nor retain the full session messages.
  (unless (listp (plist-get response :messages))
    (error "agent-run response messages must be a list"))
  (nl-agent-trajectory--validate-record
   (list :format nl-agent-trajectory-format
         :task task
         :status (plist-get response :status)
         :steps (plist-get response :steps)
         :result (plist-get response :result)
         :trajectory (plist-get response :trajectory)
         :evidence "unverified")))

(defun nl-agent-trajectory--directory (directory)
  "Prepare trusted host-configured DIRECTORY and return its absolute name."
  (unless (and (stringp directory) (> (length directory) 0))
    (error "trajectory directory must be non-empty text"))
  (let* ((path (expand-file-name directory))
         (name (directory-file-name path))
         (created (not (file-exists-p name))))
    (when (file-symlink-p name)
      (error "trajectory directory must not be a symlink"))
    (when created
      (make-directory path t)
      (set-file-modes name #o700))
    (when (or (file-symlink-p name) (not (file-directory-p name)))
      (error "trajectory directory must be a real directory"))
    (file-name-as-directory path)))

(defun nl-agent-trajectory--serialize (record)
  "Serialize RECORD at full precision within the byte bound."
  (let ((print-length nil) (print-level nil) (print-circle nil)
        (print-escape-nonascii t) (float-output-format nil))
    (let ((text (prin1-to-string record)))
      (when (> (string-bytes text) nl-agent-trajectory-max-bytes)
        (error "trajectory record exceeds %d bytes"
               nl-agent-trajectory-max-bytes))
      text)))

(defun nl-agent-trajectory--target (directory)
  "Return a unique candidate immutable record path in DIRECTORY."
  (let* ((seed (format "%s:%s:%s:%s" (float-time) (emacs-pid)
                       (random most-positive-fixnum) (current-time)))
         (suffix (substring (secure-hash 'sha256 seed) 0 24)))
    (expand-file-name
     (format "run-%s-%s.sexp" (format-time-string "%Y%m%dT%H%M%S") suffix)
     directory)))

;;;###autoload
(defun nl-agent-trajectory-save (directory task response)
  "Save TASK and actual agent-run RESPONSE as a new immutable record.
Return its absolute file path.  DIRECTORY is trusted host configuration."
  (let* ((record (nl-agent-trajectory--record task response))
         (text (nl-agent-trajectory--serialize record))
         (directory (nl-agent-trajectory--directory directory))
         (lock (expand-file-name ".writer" directory))
         (owned-lock nil)
         (temporary nil)
         target)
    (when (or (file-exists-p lock) (file-symlink-p lock))
      (error "trajectory writer lock already exists"))
    (unwind-protect
        (progn
          (let ((inhibit-quit t))
            (make-directory lock)
            (setq owned-lock t))
          (set-file-modes lock #o700)
          (when (>= (length (directory-files
                             directory nil "\\`run-.*\\.sexp\\'" t))
                    nl-agent-trajectory-max-records)
            (error "trajectory directory contains %d records"
                   nl-agent-trajectory-max-records))
          (setq target (nl-agent-trajectory--target directory))
          (when (or (file-exists-p target) (file-symlink-p target))
            (error "trajectory target already exists"))
          (let ((inhibit-quit t))
            (setq temporary
                  (make-temp-file
                   (expand-file-name ".nl-agent-trajectory-" directory))))
          (let ((coding-system-for-write 'utf-8))
            (write-region text nil temporary nil 'silent))
          (set-file-modes temporary #o600)
          (rename-file temporary target nil)
          (setq temporary nil)
          target)
      (when (and temporary (file-exists-p temporary)
                 (not (file-symlink-p temporary)))
        (delete-file temporary))
      (when (and owned-lock (file-directory-p lock)
                 (not (file-symlink-p lock)))
        (delete-directory lock)))))

;;;###autoload
(defun nl-agent-trajectory-read-snapshot (path)
  "Read PATH once and return (:record RECORD :sha256 EXACT-BYTE-HASH)."
  (unless (and (stringp path) (> (length path) 0))
    (error "trajectory path must be non-empty text"))
  (setq path (expand-file-name path))
  (when (file-symlink-p path)
    (error "trajectory path must not be a symlink"))
  (unless (file-regular-p path)
    (error "trajectory path must be a regular file"))
  (when (> (file-attribute-size (file-attributes path))
           nl-agent-trajectory-max-bytes)
    (error "trajectory file exceeds %d bytes" nl-agent-trajectory-max-bytes))
  (let (bytes digest)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally
       path nil 0 (1+ nl-agent-trajectory-max-bytes))
      (when (> (buffer-size) nl-agent-trajectory-max-bytes)
        (error "trajectory file exceeds %d bytes"
               nl-agent-trajectory-max-bytes))
      (setq digest (secure-hash 'sha256 (current-buffer))
            bytes (buffer-string)))
    (with-temp-buffer
      (let ((read-eval nil))
        (insert (decode-coding-string bytes 'utf-8))
        (goto-char (point-min))
        (let ((record (read (current-buffer))))
          (skip-chars-forward " \t\r\n")
          (unless (eobp) (error "trajectory file has trailing data"))
          (list :record (nl-agent-trajectory--validate-record record)
                :sha256 digest))))))

;;;###autoload
(defun nl-agent-trajectory-read (path)
  "Read and return one validated detached immutable record from PATH."
  (plist-get (nl-agent-trajectory-read-snapshot path) :record))

(provide 'nl-agent-trajectory)
;;; nl-agent-trajectory.el ends here
