;;; nl-agent-task-eval.el --- host-owned micro-task evaluation -*- lexical-binding: t; -*-

;; This evaluates exact, host-owned file fixtures.  A model's DONE claim is
;; necessary but never sufficient for a passing case.  Reports are unsigned
;; evidence records, not proofs of model identity or general quality.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'nl-llm-agent-tokenizer)

(defconst nl-agent-task-eval-format "nl-agent-task-eval-v1")
(defconst nl-agent-task-eval-comparison-format
  "nl-agent-task-eval-comparison-v1")
(defconst nl-agent-task-eval-max-cases 32)
(defconst nl-agent-task-eval-max-files 32)
(defconst nl-agent-task-eval-max-task-chars 8192)
(defconst nl-agent-task-eval-max-file-bytes 65536)
(defconst nl-agent-task-eval-max-total-bytes (* 1024 1024))
(defconst nl-agent-task-eval-max-path-depth 16)
(defconst nl-agent-task-eval-max-inventory-entries 128)
(defconst nl-agent-task-eval--failure-order
  [callback-error invalid-response runtime-status missing-file extra-file
                  symlink special-file content-mismatch workspace-error
                  inventory-limit])

(defun nl-agent-task-eval--keys (value allowed required where)
  "Validate exact plist VALUE keys for WHERE."
  (let ((tail value) seen (count 0))
    (while tail
      (when (>= count (length allowed))
        (error "%s contains too many fields" where))
      (unless (and (consp tail) (consp (cdr tail)))
        (error "%s must be a proper plist" where))
      (let ((key (car tail)))
        (unless (memq key allowed)
          (error "%s has unknown key %S" where key))
        (when (memq key seen)
          (error "%s has duplicate key %S" where key))
        (push key seen))
      (setq tail (cddr tail)
            count (1+ count)))
    (dolist (key required)
      (unless (memq key seen)
        (error "%s is missing key %S" where key))))
  value)

(defun nl-agent-task-eval--plain-string (value where maximum &optional empty)
  "Validate and detach string VALUE for WHERE within MAXIMUM characters."
  (unless (and (stringp value)
               (or empty (> (length value) 0))
               (<= (length value) maximum))
    (error "%s must be %s text of at most %d characters"
           where (if empty "" "non-empty") maximum))
  (substring-no-properties value))

(defun nl-agent-task-eval--utf8 (text)
  "Return TEXT encoded as detached UTF-8 bytes."
  (apply #'unibyte-string
         (nl-llm-agent-tokenizer-encode text "utf8-byte-v1")))

(defun nl-agent-task-eval--path (value)
  "Validate and detach one portable relative fixture path VALUE."
  (setq value (nl-agent-task-eval--plain-string value "fixture path" 1024))
  (when (or (file-name-absolute-p value)
            (string-prefix-p "~" value)
            (string-match-p "\\\\" value)
            (cl-some (lambda (char) (or (< char 32) (= char 127)))
                     (string-to-list value)))
    (error "fixture path must be relative and use forward slashes: %S" value))
  (let ((parts (split-string value "/" nil)))
    (when (or (> (length parts) nl-agent-task-eval-max-path-depth)
              (cl-some (lambda (part)
                         (or (string-empty-p part)
                             (member part '("." ".."))
                             (string-match-p ":" part)))
                       parts)
              (not (equal value (mapconcat #'identity parts "/"))))
      (error "fixture path is not lexically normalized and safe: %S" value)))
  value)

(defun nl-agent-task-eval--entry (value kind total)
  "Validate one fixture VALUE of KIND and add its bytes to TOTAL."
  (nl-agent-task-eval--keys value '(:path :text) '(:path :text) kind)
  (let* ((path (nl-agent-task-eval--path (plist-get value :path)))
         (text (nl-agent-task-eval--plain-string
                (plist-get value :text) (format "%s text" kind) 65536 t))
         (bytes (nl-agent-task-eval--utf8 text)))
    (when (> (length bytes) nl-agent-task-eval-max-file-bytes)
      (error "%s %s exceeds %d UTF-8 bytes"
             kind path nl-agent-task-eval-max-file-bytes))
    (setcar total (+ (car total) (length bytes)))
    (when (> (car total) nl-agent-task-eval-max-total-bytes)
      (error "suite fixture text exceeds %d total UTF-8 bytes"
             nl-agent-task-eval-max-total-bytes))
    (list :path path :text text)))

(defun nl-agent-task-eval--entries (value kind total)
  "Validate fixture entry vector VALUE of KIND using TOTAL budget."
  (unless (and (vectorp value) (> (length value) 0)
               (<= (length value) nl-agent-task-eval-max-files))
    (error "%s must contain 1..%d entries"
           kind nl-agent-task-eval-max-files))
  (let ((seen (make-hash-table :test 'equal))
        result)
    (dotimes (index (length value))
      (let* ((entry (nl-agent-task-eval--entry
                     (aref value index) kind total))
             (path (plist-get entry :path)))
        (when (gethash path seen)
          (error "%s has duplicate path %s" kind path))
        (puthash path t seen)
        (push entry result)))
    (vconcat
     (sort result
           (lambda (left right)
             (string< (plist-get left :path) (plist-get right :path)))))))

(defun nl-agent-task-eval--path-prefix-p (left right)
  "Return non-nil when fixture path LEFT is a directory prefix of RIGHT."
  (string-prefix-p (concat left "/") right))

(defun nl-agent-task-eval--case (value total)
  "Validate and detach one suite case VALUE using TOTAL byte budget."
  (nl-agent-task-eval--keys
   value '(:id :task :files :expected) '(:id :task :files :expected)
   "task-eval case")
  (let* ((id (nl-agent-task-eval--plain-string
              (plist-get value :id) "case id" 256))
         (task (nl-agent-task-eval--plain-string
                (plist-get value :task) "case task"
                nl-agent-task-eval-max-task-chars t))
         (files (nl-agent-task-eval--entries
                 (plist-get value :files) "case files" total))
         (expected (nl-agent-task-eval--entries
                    (plist-get value :expected) "case expected" total)))
    (dotimes (left (length files))
      (dotimes (right (length files))
        (when (and (/= left right)
                   (nl-agent-task-eval--path-prefix-p
                    (plist-get (aref files left) :path)
                    (plist-get (aref files right) :path)))
          (error "case %s has a file/directory path collision" id))))
    (unless (= (length files) (length expected))
      (error "case %s expected paths must exactly match input paths" id))
    (dotimes (index (length files))
      (unless (equal (plist-get (aref files index) :path)
                     (plist-get (aref expected index) :path))
        (error "case %s expected paths must exactly match input paths" id)))
    (list :id id :task task :files files :expected expected)))

(defun nl-agent-task-eval--suite (suite)
  "Validate and fully detach host-owned SUITE before any side effects."
  (nl-agent-task-eval--keys suite '(:id :version :cases)
                            '(:id :version :cases) "task-eval suite")
  (let* ((id (nl-agent-task-eval--plain-string
              (plist-get suite :id) "suite id" 256))
         (version (nl-agent-task-eval--plain-string
                   (plist-get suite :version) "suite version" 256))
         (cases (plist-get suite :cases))
         (total (list 0))
         (seen (make-hash-table :test 'equal))
         result)
    (unless (and (vectorp cases) (> (length cases) 0)
                 (<= (length cases) nl-agent-task-eval-max-cases))
      (error "suite must contain 1..%d cases"
             nl-agent-task-eval-max-cases))
    (dotimes (index (length cases))
      (let* ((case (nl-agent-task-eval--case (aref cases index) total))
             (case-id (plist-get case :id)))
        (when (gethash case-id seen)
          (error "suite has duplicate case id %s" case-id))
        (puthash case-id t seen)
        (push case result)))
    (list :id id :version version :cases (vconcat (nreverse result)))))

(defun nl-agent-task-eval--digest (suite max-steps runner-id)
  "Hash canonical SUITE semantics, MAX-STEPS, and RUNNER-ID protocol."
  (let ((print-length nil) (print-level nil) (print-circle nil)
        (print-escape-nonascii t) (float-output-format nil))
    (secure-hash
     'sha256
     (prin1-to-string
      (list :format nl-agent-task-eval-format
            :max-steps max-steps :runner-id runner-id :suite suite)))))

(defun nl-agent-task-eval--options (keys)
  "Validate run KEYS and return (MODEL-ID MAX-STEPS RUNNER-ID)."
  (nl-agent-task-eval--keys
   keys '(:model-id :max-steps :runner-id) '(:model-id)
                            "task-eval options")
  (let ((model-id (nl-agent-task-eval--plain-string
                   (plist-get keys :model-id) "model id" 256))
        (max-steps (if (plist-member keys :max-steps)
                       (plist-get keys :max-steps)
                     12))
        (runner-id
         (nl-agent-task-eval--plain-string
          (if (plist-member keys :runner-id)
              (plist-get keys :runner-id)
            "host-callback-v1")
          "runner id" 256)))
    (unless (and (integerp max-steps) (>= max-steps 1) (<= max-steps 64))
      (error "task-eval max-steps must be an integer in 1..64"))
    (list model-id max-steps runner-id)))

(defun nl-agent-task-eval--expected-directories (files)
  "Return a set of lexical parent directories required by FILES."
  (let ((directories (make-hash-table :test 'equal))
        (index 0))
    (while (< index (length files))
      (let* ((path (plist-get (aref files index) :path))
             (parts (butlast (split-string path "/")))
             (prefix nil))
        (dolist (part parts)
          (setq prefix (if prefix (concat prefix "/" part) part))
          (puthash prefix t directories)))
      (setq index (1+ index)))
    directories))

(defun nl-agent-task-eval--ensure-parent (workspace path)
  "Create private parent directories for PATH inside WORKSPACE."
  (let ((parts (butlast (split-string path "/")))
        (current workspace))
    (dolist (part parts)
      (setq current (expand-file-name part current))
      (unless (file-directory-p current)
        (make-directory current)
        (set-file-modes current #o700)))))

(defun nl-agent-task-eval--write-files (workspace files)
  "Write canonical input FILES into fresh WORKSPACE."
  (dotimes (index (length files))
    (let* ((entry (aref files index))
           (relative (plist-get entry :path))
           (path (expand-file-name relative workspace))
           (bytes (nl-agent-task-eval--utf8 (plist-get entry :text))))
      (nl-agent-task-eval--ensure-parent workspace relative)
      (when (or (file-exists-p path) (file-symlink-p path))
        (error "fixture target unexpectedly exists: %s" relative))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert bytes)
        (let ((coding-system-for-write 'binary))
          (write-region (point-min) (point-max) path nil 'silent)))
      (set-file-modes path #o600))))

(defun nl-agent-task-eval--hash-file (path)
  "Return bounded exact-byte SHA256 of regular fixture PATH."
  (let ((attributes (file-attributes path 'string)))
    (unless (and attributes (null (car attributes)))
      (error "not a regular file"))
    (when (> (file-attribute-size attributes)
             nl-agent-task-eval-max-file-bytes)
      (error "file exceeds output byte bound"))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally
       path nil 0 (1+ nl-agent-task-eval-max-file-bytes))
      (when (> (buffer-size) nl-agent-task-eval-max-file-bytes)
        (error "file grew beyond output byte bound"))
      (secure-hash 'sha256 (current-buffer)))))

(defun nl-agent-task-eval--failure-vector (failures)
  "Canonicalize FAILURE symbols into deterministic unique order."
  (let (result)
    (dotimes (index (length nl-agent-task-eval--failure-order))
      (let ((failure (aref nl-agent-task-eval--failure-order index)))
        (when (memq failure failures) (push failure result))))
    (vconcat (nreverse result))))

(defun nl-agent-task-eval--inspect (workspace root-id expected)
  "Inspect WORKSPACE against EXPECTED and return (EVIDENCE . FAILURES)."
  (let ((expected-paths (make-hash-table :test 'equal))
        (expected-dirs (nl-agent-task-eval--expected-directories expected))
        (actual (make-hash-table :test 'equal))
        (failures nil)
        (entries 0))
    (dotimes (index (length expected))
      (puthash (plist-get (aref expected index) :path) t expected-paths))
    (cond
     ((file-symlink-p workspace)
      (push 'symlink failures))
     ((not (file-directory-p workspace))
      (push 'missing-file failures))
     ((not (equal root-id
                  (file-attribute-file-identifier
                   (file-attributes workspace 'string))))
      (push 'workspace-error failures))
     (t
      (catch 'bounded
        (cl-labels
            ((walk
              (directory relative depth)
              (when (> depth nl-agent-task-eval-max-path-depth)
                (push 'inventory-limit failures)
                (throw 'bounded nil))
              (dolist (name
                       (directory-files
                        directory t directory-files-no-dot-files-regexp t
                        (+ 2 (- nl-agent-task-eval-max-inventory-entries
                                entries))))
                (setq entries (1+ entries))
                (when (> entries nl-agent-task-eval-max-inventory-entries)
                  (push 'inventory-limit failures)
                  (throw 'bounded nil))
                (let ((rel (if (string-empty-p relative)
                               (file-name-nondirectory name)
                             (concat relative "/"
                                     (file-name-nondirectory name)))))
                  (cond
                   ((file-symlink-p name)
                    (push 'symlink failures))
                   ((file-directory-p name)
                    (if (gethash rel expected-dirs)
                        (walk name rel (1+ depth))
                      (push 'extra-file failures)))
                   ((file-regular-p name)
                    (if (gethash rel expected-paths)
                        (condition-case nil
                            (puthash rel
                                     (nl-agent-task-eval--hash-file name)
                                     actual)
                          (error (push 'content-mismatch failures)))
                      (push 'extra-file failures)))
                   (t (push 'special-file failures)))))))
          (walk workspace "" 0)))))
    (let (evidence)
      (dotimes (index (length expected))
        (let* ((entry (aref expected index))
               (path (plist-get entry :path))
               (expected-hash
                (secure-hash 'sha256
                             (nl-agent-task-eval--utf8
                              (plist-get entry :text))))
               (actual-hash (gethash path actual)))
          (unless actual-hash (push 'missing-file failures))
          (when (and actual-hash (not (equal actual-hash expected-hash)))
            (push 'content-mismatch failures))
          (push (list :path (substring-no-properties path)
                      :expected-sha256 expected-hash
                      :actual-sha256 actual-hash)
                evidence)))
      (cons (vconcat (nreverse evidence))
            (nl-agent-task-eval--failure-vector failures)))))

(defun nl-agent-task-eval--valid-response (response max-steps)
  "Return (STATUS STEPS) for a valid runtime RESPONSE, or nil."
  (condition-case nil
      (progn
        (nl-agent-task-eval--keys
         response '(:kind :status :steps :result :messages :trajectory :error)
         '(:status :steps :result :messages :trajectory)
         "task-eval callback response")
        (let ((kind-present (plist-member response :kind))
              (kind (plist-get response :kind))
              (status (plist-get response :status))
              (steps (plist-get response :steps))
              (result (plist-get response :result)))
          (and (or (not kind-present) (eq kind 'agent-run))
               (memq status '(done limit error))
               (integerp steps) (>= steps 0) (<= steps max-steps)
               (or (null result) (stringp result))
               (listp (plist-get response :messages))
               (listp (plist-get response :trajectory))
               (list status steps))))
    (error nil)))

(defun nl-agent-task-eval--safe-delete-tree (directory)
  "Delete owned DIRECTORY recursively without following child symlinks."
  (dolist (name (directory-files
                 directory t directory-files-no-dot-files-regexp t))
    (cond
     ((file-symlink-p name) (delete-file name))
     ((file-directory-p name)
      (nl-agent-task-eval--safe-delete-tree name))
     (t (delete-file name))))
  (delete-directory directory))

(defun nl-agent-task-eval--cleanup (workspace root-id)
  "Best-effort cleanup of original owned WORKSPACE without following links."
  (condition-case nil
      (cond
       ((file-symlink-p workspace) (delete-file workspace))
       ((and (file-directory-p workspace)
             (equal root-id
                    (file-attribute-file-identifier
                     (file-attributes workspace 'string))))
        (nl-agent-task-eval--safe-delete-tree workspace)))
    (error nil)))

(defun nl-agent-task-eval--failed-evidence (expected)
  "Return missing-file evidence for EXPECTED without plaintext."
  (let (result)
    (dotimes (index (length expected))
      (let ((entry (aref expected index)))
        (push (list :path (substring-no-properties (plist-get entry :path))
                    :expected-sha256
                    (secure-hash
                     'sha256
                     (nl-agent-task-eval--utf8 (plist-get entry :text)))
                    :actual-sha256 nil)
              result)))
    (vconcat (nreverse result))))

(defun nl-agent-task-eval--run-case (case run-case max-steps)
  "Run one canonical CASE through trusted host callback RUN-CASE."
  (let ((workspace nil) (root-id nil) (response nil) (callback-error nil)
        (setup-error nil) inspection)
    (unwind-protect
        (condition-case nil
            (progn
              (setq workspace (make-temp-file "nl-agent-task-eval-" t))
              (set-file-modes workspace #o700)
              (setq root-id
                    (file-attribute-file-identifier
                     (file-attributes workspace 'string)))
              (nl-agent-task-eval--write-files
               workspace (plist-get case :files))
              (condition-case nil
                  (setq response
                        (funcall run-case
                                 (substring-no-properties
                                  (plist-get case :task))
                                 (substring-no-properties workspace)
                                 max-steps))
                ((error quit) (setq callback-error t)))
              (setq inspection
                    (nl-agent-task-eval--inspect
                     workspace root-id (plist-get case :expected))))
          ((error quit) (setq setup-error t)))
      (when workspace (nl-agent-task-eval--cleanup workspace root-id)))
    (let* ((valid (nl-agent-task-eval--valid-response response max-steps))
           (status (if valid (car valid) 'error))
           (steps (if valid (cadr valid) 0))
           (files (if inspection (car inspection)
                    (nl-agent-task-eval--failed-evidence
                     (plist-get case :expected))))
           (failures (if inspection (append (cdr inspection) nil)
                       '(workspace-error))))
      (when callback-error (push 'callback-error failures))
      (unless (or callback-error valid) (push 'invalid-response failures))
      (unless (eq status 'done) (push 'runtime-status failures))
      (when setup-error (push 'workspace-error failures))
      (setq failures (nl-agent-task-eval--failure-vector failures))
      (list :id (substring-no-properties (plist-get case :id))
            :status status :steps steps
            :pass (and (eq status 'done) (= (length failures) 0))
            :failure-codes failures :files files))))

;;;###autoload
(defun nl-agent-task-eval-run (suite run-case &rest keys)
  "Run validated host SUITE through trusted callback RUN-CASE.

RUN-CASE receives only detached TASK text, a fresh owned WORKSPACE, and
MAX-STEPS.  It must return the raw `nl-agent-runtime-run' response; an optional
existing :kind must be `agent-run'.  Required :model-id is a host label for
reporting, not authenticated proof of the selected model.  Optional :max-steps
defaults to 12; optional :runner-id defaults to `host-callback-v1' and names the
host-owned execution profile rather than a signed code identity."
  (unless (functionp run-case)
    (error "task-eval run-case must be a trusted host function"))
  ;; Validate and detach everything before creating a workspace or invoking the
  ;; callback.  Expected values never cross the callback boundary.
  (let* ((options (nl-agent-task-eval--options keys))
         (model-id (car options))
         (max-steps (cadr options))
         (runner-id (nth 2 options))
         (suite (nl-agent-task-eval--suite suite))
         (digest (nl-agent-task-eval--digest suite max-steps runner-id))
         (suite-cases (plist-get suite :cases))
         (reports (make-vector (length suite-cases) nil))
         (passed 0))
    (dotimes (index (length suite-cases))
      (let ((report (nl-agent-task-eval--run-case
                     (aref suite-cases index) run-case max-steps)))
        (aset reports index report)
        (when (plist-get report :pass) (setq passed (1+ passed)))))
    (let ((total (length reports)))
      (list :format nl-agent-task-eval-format
            :suite-id (substring-no-properties (plist-get suite :id))
            :suite-version
            (substring-no-properties (plist-get suite :version))
            :suite-sha256 digest
            :model-id (substring-no-properties model-id)
            :max-steps max-steps
            :runner-id (substring-no-properties runner-id)
            :cases reports
            :passed passed :total total
            :score (/ (float passed) total)))))

(defun nl-agent-task-eval--sha256-p (value)
  "Return non-nil when VALUE is a lowercase SHA256 string."
  (and (stringp value)
       (string-match-p "\\`[a-f0-9]\\{64\\}\\'" value)))

(defun nl-agent-task-eval--validate-file-evidence (value)
  "Validate and detach one report file evidence VALUE."
  (nl-agent-task-eval--keys
   value '(:path :expected-sha256 :actual-sha256)
   '(:path :expected-sha256 :actual-sha256) "task-eval file evidence")
  (let ((path (nl-agent-task-eval--path (plist-get value :path)))
        (expected (plist-get value :expected-sha256))
        (actual (plist-get value :actual-sha256)))
    (unless (nl-agent-task-eval--sha256-p expected)
      (error "task-eval expected file hash is invalid"))
    (unless (or (null actual) (nl-agent-task-eval--sha256-p actual))
      (error "task-eval actual file hash is invalid"))
    (list :path path :expected-sha256 (substring-no-properties expected)
          :actual-sha256 (and actual (substring-no-properties actual)))))

(defun nl-agent-task-eval--validate-case-report (value max-steps)
  "Validate and detach case report VALUE under MAX-STEPS."
  (nl-agent-task-eval--keys
   value '(:id :status :steps :pass :failure-codes :files)
   '(:id :status :steps :pass :failure-codes :files) "task-eval case report")
  (let ((id (nl-agent-task-eval--plain-string
             (plist-get value :id) "report case id" 256))
        (status (plist-get value :status))
        (steps (plist-get value :steps))
        (pass (plist-get value :pass))
        (failures (plist-get value :failure-codes))
        (files (plist-get value :files)))
    (unless (memq status '(done limit error))
      (error "task-eval report status is invalid"))
    (unless (and (integerp steps) (>= steps 0) (<= steps max-steps))
      (error "task-eval report steps are invalid"))
    (unless (memq pass '(t nil))
      (error "task-eval report pass must be boolean"))
    (unless (vectorp failures)
      (error "task-eval failure codes must be a vector"))
    (let ((seen nil))
      (dotimes (index (length failures))
        (let ((failure (aref failures index)))
          (unless (memq failure (append nl-agent-task-eval--failure-order nil))
            (error "task-eval report has unknown failure code"))
          (when (memq failure seen)
            (error "task-eval report has duplicate failure code"))
          (push failure seen)))
      (unless (equal failures (nl-agent-task-eval--failure-vector seen))
        (error "task-eval failure codes are not canonical")))
    (unless (and (vectorp files) (> (length files) 0)
                 (<= (length files) nl-agent-task-eval-max-files))
      (error "task-eval report files are invalid"))
    (let ((seen (make-hash-table :test 'equal)) result all-match)
      (setq all-match t)
      (dotimes (index (length files))
        (let* ((file (nl-agent-task-eval--validate-file-evidence
                      (aref files index)))
               (path (plist-get file :path)))
          (when (gethash path seen)
            (error "task-eval report has duplicate file path"))
          (puthash path t seen)
          (unless (equal (plist-get file :expected-sha256)
                         (plist-get file :actual-sha256))
            (setq all-match nil))
          (push file result)))
      (let ((should-pass (and (eq status 'done) (= (length failures) 0)
                              all-match)))
        (unless (eq pass should-pass)
          (error "task-eval case pass contradicts evidence"))
        (when (and (not pass) (= (length failures) 0))
          (error "failed task-eval case lacks a failure code")))
      (list :id id :status status :steps steps :pass pass
            :failure-codes (copy-sequence failures)
            :files (vconcat (nreverse result))))))

(defun nl-agent-task-eval--validate-report (report)
  "Validate REPORT structure and recompute aggregate consistency."
  (nl-agent-task-eval--keys
   report '(:format :suite-id :suite-version :suite-sha256 :model-id
                    :max-steps :runner-id :cases :passed :total :score)
   '(:format :suite-id :suite-version :suite-sha256 :model-id
             :max-steps :runner-id :cases :passed :total :score)
   "task-eval report")
  (unless (equal (plist-get report :format) nl-agent-task-eval-format)
    (error "unsupported task-eval report format"))
  (let* ((suite-id (nl-agent-task-eval--plain-string
                    (plist-get report :suite-id) "report suite id" 256))
         (version (nl-agent-task-eval--plain-string
                   (plist-get report :suite-version) "report suite version" 256))
         (digest (plist-get report :suite-sha256))
         (model-id (nl-agent-task-eval--plain-string
                    (plist-get report :model-id) "report model id" 256))
         (max-steps (plist-get report :max-steps))
         (runner-id (nl-agent-task-eval--plain-string
                     (plist-get report :runner-id) "report runner id" 256))
         (cases (plist-get report :cases)))
    (unless (nl-agent-task-eval--sha256-p digest)
      (error "task-eval suite hash is invalid"))
    (unless (and (integerp max-steps) (>= max-steps 1) (<= max-steps 64))
      (error "task-eval report max-steps is invalid"))
    (unless (and (vectorp cases) (> (length cases) 0)
                 (<= (length cases) nl-agent-task-eval-max-cases))
      (error "task-eval report cases are invalid"))
    (let ((seen (make-hash-table :test 'equal))
          (validated (make-vector (length cases) nil))
          (passed 0))
      (dotimes (index (length cases))
        (let* ((case (nl-agent-task-eval--validate-case-report
                      (aref cases index) max-steps))
               (id (plist-get case :id)))
          (when (gethash id seen)
            (error "task-eval report has duplicate case id"))
          (puthash id t seen)
          (aset validated index case)
          (when (plist-get case :pass) (setq passed (1+ passed)))))
      (let ((total (length validated))
            (score (/ (float passed) (length validated))))
        (unless (and (equal (plist-get report :passed) passed)
                     (equal (plist-get report :total) total)
                     (numberp (plist-get report :score))
                     (= (- (plist-get report :score)
                           (plist-get report :score)) 0.0)
                     (= (plist-get report :score) score))
          (error "task-eval report aggregates contradict case evidence"))
        (list :format nl-agent-task-eval-format
              :suite-id suite-id :suite-version version
              :suite-sha256 (substring-no-properties digest)
              :model-id model-id :max-steps max-steps
              :runner-id runner-id :cases validated
              :passed passed :total total :score score)))))

(defun nl-agent-task-eval--oracle-shape (cases)
  "Return ordered case/file expected-hash shape from report CASES."
  (let (result)
    (dotimes (index (length cases))
      (let ((case (aref cases index)) files)
        (dotimes (file-index (length (plist-get case :files)))
          (let ((file (aref (plist-get case :files) file-index)))
            (push (list (plist-get file :path)
                        (plist-get file :expected-sha256))
                  files)))
        (push (list (plist-get case :id) (nreverse files)) result)))
    (nreverse result)))

;;;###autoload
(defun nl-agent-task-eval-compare (before after)
  "Validate and compare compatible task-eval reports BEFORE and AFTER."
  (setq before (nl-agent-task-eval--validate-report before)
        after (nl-agent-task-eval--validate-report after))
  (unless (and (equal (plist-get before :suite-id)
                      (plist-get after :suite-id))
               (equal (plist-get before :suite-version)
                      (plist-get after :suite-version))
               (equal (plist-get before :suite-sha256)
                      (plist-get after :suite-sha256))
               (= (plist-get before :max-steps)
                  (plist-get after :max-steps))
               (equal (plist-get before :runner-id)
                      (plist-get after :runner-id))
               (equal (nl-agent-task-eval--oracle-shape
                       (plist-get before :cases))
                      (nl-agent-task-eval--oracle-shape
                       (plist-get after :cases))))
    (error "task-eval reports do not describe the same ordered suite"))
  (let ((before-passed (plist-get before :passed))
        (after-passed (plist-get after :passed))
        (before-score (plist-get before :score))
        (after-score (plist-get after :score)))
    (list :format nl-agent-task-eval-comparison-format
          :suite-sha256 (substring-no-properties
                         (plist-get before :suite-sha256))
          :before-model-id (substring-no-properties
                            (plist-get before :model-id))
          :after-model-id (substring-no-properties
                           (plist-get after :model-id))
          :runner-id (substring-no-properties
                      (plist-get before :runner-id))
          :before-passed before-passed :after-passed after-passed
          :passed-delta (- after-passed before-passed)
          :before-score before-score :after-score after-score
          :score-delta (- after-score before-score))))

(provide 'nl-agent-task-eval)
;;; nl-agent-task-eval.el ends here
