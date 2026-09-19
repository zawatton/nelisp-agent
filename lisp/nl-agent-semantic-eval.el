;;; nl-agent-semantic-eval.el --- bounded semantic renderer evaluation -*- lexical-binding: t; -*-

;; This module measures deterministic rendering and optional local model
;; rendering side by side.  Literal checks are screening proxies only; they do
;; not establish semantic preservation, hallucination rates, or model quality.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'nl-agent-jsonl)
(require 'nl-agent-semantic-ir)
(require 'nl-agent-semantic-render)

;; Keep the reader switch special while the data-only binding is active.
(defvar read-eval)

(define-error 'nl-agent-semantic-eval-error "Invalid semantic evaluation corpus")

(defconst nl-agent-semantic-eval--max-corpus-bytes 65536)
(defconst nl-agent-semantic-eval--max-cases 32)
(defconst nl-agent-semantic-eval--max-literals 64)
(defconst nl-agent-semantic-eval--max-literal-chars 8192)
(defconst nl-agent-semantic-eval--max-corpus-depth 16)

;; The renderer owns the authoritative policy declaration.  Keep a temporary
;; fallback so reports do not falsely identify older renderer sources as the
;; current policy.
(defvar nl-agent-semantic-render-policy-version nil)
(defconst nl-agent-semantic-eval-default-policy-version "legacy-unversioned")

(defun nl-agent-semantic-eval--fail (format-string &rest args)
  "Signal a bounded corpus error with FORMAT-STRING and ARGS."
  (signal 'nl-agent-semantic-eval-error
          (list (apply #'format format-string args))))

(defun nl-agent-semantic-eval--proper-list-p (value)
  "Return non-nil when VALUE is a finite proper list.

Use a tortoise and hare walk so this predicate remains safe when callers pass
an object created outside the bounded reader."
  (let ((slow value)
        (fast value)
        (ok t))
    (while (and ok (consp fast))
      (setq fast (cdr fast))
      (when (consp fast)
        (setq fast (cdr fast)
              slow (cdr slow))
        (when (eq slow fast)
          (setq ok nil))))
    (and ok (null fast))))

(defun nl-agent-semantic-eval--whitespace-p (char)
  (memq char '(?\s ?\t ?\n ?\r ?\f ?\v)))

(defun nl-agent-semantic-eval--whitespace-string-p (text)
  (let ((index 0)
        (length (length text))
        (ok t))
    (while (and ok (< index length))
      (setq ok (nl-agent-semantic-eval--whitespace-p (aref text index)))
      (setq index (1+ index)))
    ok))

(defun nl-agent-semantic-eval--fields (tail allowed required context)
  "Validate an exact keyword plist TAIL and return its alist.

Only keyword keys in ALLOWED are accepted, every key must occur once, and all
keys in REQUIRED must be present."
  (unless (nl-agent-semantic-eval--proper-list-p tail)
    (nl-agent-semantic-eval--fail "%s must be a proper field list" context))
  (let ((rest tail)
        (seen nil)
        (fields nil))
    (while rest
      (let ((key (pop rest)))
        (unless (keywordp key)
          (nl-agent-semantic-eval--fail
           "%s field key is not a keyword" context))
        (when (memq key seen)
          (nl-agent-semantic-eval--fail
           "%s contains duplicate field %S" context key))
        (unless (memq key allowed)
          (nl-agent-semantic-eval--fail
           "%s contains unknown field %S" context key))
        (unless rest
          (nl-agent-semantic-eval--fail
           "%s has a missing value for %S" context key))
        (push (cons key (pop rest)) fields)
        (push key seen)))
    (dolist (key required)
      (unless (memq key seen)
        (nl-agent-semantic-eval--fail
         "%s is missing required field %S" context key)))
    fields))

(defun nl-agent-semantic-eval--field (fields key)
  (cdr (assq key fields)))

(defun nl-agent-semantic-eval--string (value name maximum)
  (unless (and (stringp value)
               (> (length value) 0)
               (<= (length value) maximum))
    (nl-agent-semantic-eval--fail
     "%s must be nonempty text of at most %d characters" name maximum))
  (substring-no-properties value))

(defun nl-agent-semantic-eval--literal-list (value name)
  "Validate a required or forbidden literal list VALUE for NAME."
  (unless (nl-agent-semantic-eval--proper-list-p value)
    (nl-agent-semantic-eval--fail "%s must be a proper list" name))
  (when (> (length value) nl-agent-semantic-eval--max-literals)
    (nl-agent-semantic-eval--fail "%s contains too many literals" name))
  (let ((result nil)
        (seen nil))
    (dolist (literal value)
      (setq literal
            (nl-agent-semantic-eval--string
             literal (format "%s literal" name)
             nl-agent-semantic-eval--max-literal-chars))
      (when (member literal seen)
        (nl-agent-semantic-eval--fail
         "%s contains duplicate literal %S" name literal))
      (push literal seen)
      (push literal result))
    (nreverse result)))

(defun nl-agent-semantic-eval--read-data (text)
  "Read exactly one bounded data form from TEXT without evaluating it."
  (unless (stringp text)
    (nl-agent-semantic-eval--fail "Corpus input must be text"))
  (when (> (string-bytes text) nl-agent-semantic-eval--max-corpus-bytes)
    (nl-agent-semantic-eval--fail "Corpus exceeds the UTF-8 byte limit"))
  ;; The semantic IR preflight rejects comments, dispatch macros, quote forms,
  ;; escaped symbols, vectors, and reader evaluation before the reader runs.
  ;; Reuse it here while applying the corpus-specific depth bound as well.
  (condition-case err
      (nl-agent-ir--preflight text)
    (error
     (nl-agent-semantic-eval--fail "Corpus reader preflight failed: %s"
                                   (error-message-string err))))
  (let ((read-eval nil)
        (read-circle nil))
    (condition-case err
        (pcase-let ((`(,form . ,position) (read-from-string text)))
          (unless (nl-agent-semantic-eval--whitespace-string-p
                   (substring text position))
            (nl-agent-semantic-eval--fail
             "Corpus must contain exactly one form"))
          form)
      (error
       (nl-agent-semantic-eval--fail "Corpus data reader failed: %s"
                                     (error-message-string err))))))

(defun nl-agent-semantic-eval--canonical (version cases)
  "Return the canonical printed representation of VERSION and CASES."
  (let ((print-circle nil)
        (print-level nil)
        (print-length nil)
        (print-escape-nonascii t))
    (prin1-to-string (list :version version :cases cases))))

(defun nl-agent-semantic-eval--hash (canonical)
  "Return the SHA-256 digest of canonical corpus text."
  (secure-hash 'sha256 canonical))

(defun nl-agent-semantic-eval--validate (form)
  "Validate raw corpus FORM and return a detached normalized corpus.

Every case IR is parsed before this function returns.  Evaluation callers must
complete this pass before opening a provider or invoking any inference API."
  (unless (and (consp form) (eq (car form) :version))
    (nl-agent-semantic-eval--fail "Corpus must start with :version"))
  (let* ((fields (nl-agent-semantic-eval--fields
                  form '(:version :cases) '(:version :cases)
                  "corpus"))
         (version (nl-agent-semantic-eval--field fields :version))
         (raw-cases (nl-agent-semantic-eval--field fields :cases)))
    (unless (and (integerp version) (= version 1))
      (nl-agent-semantic-eval--fail "Corpus version must be 1"))
    (unless (nl-agent-semantic-eval--proper-list-p raw-cases)
      (nl-agent-semantic-eval--fail "Corpus cases must be a proper list"))
    (unless (<= 1 (length raw-cases) nl-agent-semantic-eval--max-cases)
      (nl-agent-semantic-eval--fail "Corpus must contain 1 through %d cases"
                                    nl-agent-semantic-eval--max-cases))
    (let ((seen-ids nil)
          (cases nil))
      ;; This loop intentionally parses every IR before returning.  No caller
      ;; may begin inference after a prefix of a malformed corpus.
      (dolist (raw-case raw-cases)
        (unless (and (consp raw-case) (eq (car raw-case) :id))
          (nl-agent-semantic-eval--fail "Case must start with :id"))
        (let* ((case-fields
                (nl-agent-semantic-eval--fields
                 raw-case '(:id :ir :required :forbidden)
                 '(:id :ir :required :forbidden) "case"))
               (case-id
                (nl-agent-semantic-eval--string
                 (nl-agent-semantic-eval--field case-fields :id)
                 "Case id" 128))
               (ir
                (nl-agent-semantic-eval--string
                 (nl-agent-semantic-eval--field case-fields :ir)
                 "Case IR" nl-agent-ir--max-input-bytes))
               (required
                (nl-agent-semantic-eval--literal-list
                 (nl-agent-semantic-eval--field case-fields :required)
                 "Required literals"))
               (forbidden
                (nl-agent-semantic-eval--literal-list
                 (nl-agent-semantic-eval--field case-fields :forbidden)
                 "Forbidden literals"))
               ;; The parse is deliberately before the next case and before
               ;; the normalized corpus is made available to the runner.
               (task (condition-case err
                         (nl-agent-ir-parse ir)
                       (error
                        (nl-agent-semantic-eval--fail
                         "Case %s has invalid IR: %s"
                         case-id (error-message-string err))))))
          (when (member case-id seen-ids)
            (nl-agent-semantic-eval--fail
             "Corpus contains duplicate case id %S" case-id))
          (push case-id seen-ids)
          (push (list :id case-id :ir ir :task task
                      :required required :forbidden forbidden)
                cases)))
      (setq cases (nreverse cases))
      (let* ((canonical-cases
              (mapcar (lambda (case)
                        (list :id (plist-get case :id)
                              :ir (plist-get case :ir)
                              :required (copy-sequence
                                         (plist-get case :required))
                              :forbidden (copy-sequence
                                          (plist-get case :forbidden))))
                      cases))
             (canonical (nl-agent-semantic-eval--canonical
                         version canonical-cases)))
        (list :version version :cases cases
              :canonical canonical
              :hash (nl-agent-semantic-eval--hash canonical))))))

;;;###autoload
(defun nl-agent-semantic-eval-load-corpus (path)
  "Read and validate a bounded semantic evaluation corpus from PATH.

The file is parsed as data only.  It must contain one UTF-8 form, and all IR
tasks are validated before the normalized corpus is returned."
  (unless (and (stringp path) (not (string-empty-p path)))
    (error "Corpus path must be non-empty text"))
  (unless (file-regular-p path)
    (error "Corpus path is not a regular file: %s" path))
  (when (> (file-attribute-size (file-attributes path 'string))
           nl-agent-semantic-eval--max-corpus-bytes)
    (error "Corpus file exceeds the byte limit: %s" path))
  (condition-case err
      (with-temp-buffer
        (set-buffer-multibyte t)
        (let ((coding-system-for-read 'utf-8-unix))
          (insert-file-contents path nil 0 nil t))
        (let ((corpus
               (nl-agent-semantic-eval--validate
                (nl-agent-semantic-eval--read-data (buffer-string)))))
          (plist-put corpus :path (expand-file-name path))))
    (nl-agent-semantic-eval-error
     (signal (car err) (cdr err)))
    (error
     (error "Cannot read semantic evaluation corpus: %s"
            (error-message-string err)))))

(defun nl-agent-semantic-eval--corpus (corpus)
  "Return a fully validated detached CORPUS.

Accept a path as a convenience, but revalidate normalized corpus data too so
the all-IR-before-inference invariant cannot be bypassed by callers."
  (if (stringp corpus)
      (nl-agent-semantic-eval-load-corpus corpus)
    (unless (and (nl-agent-semantic-eval--proper-list-p corpus)
                 (plist-member corpus :cases))
      (error "Invalid semantic evaluation corpus"))
    ;; Reconstruct the source schema and parse all IRs again.  This avoids
    ;; trusting a caller-supplied :task object or executable values.
    (let ((raw (list :version (plist-get corpus :version)
                     :cases nil))
          (path (plist-get corpus :path))
          (cases (plist-get corpus :cases)))
      (unless (nl-agent-semantic-eval--proper-list-p cases)
        (error "Invalid semantic evaluation corpus cases"))
      (unless (<= 1 (length cases) nl-agent-semantic-eval--max-cases)
        (error "Invalid semantic evaluation corpus case count"))
      (setq raw
            (list :version (plist-get corpus :version)
                  :cases
                  (mapcar (lambda (case)
                            (list :id (plist-get case :id)
                                  :ir (plist-get case :ir)
                                  :required (plist-get case :required)
                                  :forbidden (plist-get case :forbidden)))
                          cases)))
      (let ((validated (nl-agent-semantic-eval--validate raw)))
        (when (and path (stringp path))
          (plist-put validated :path path))
        validated))))

(defun nl-agent-semantic-eval--elapsed (started)
  (max 0.0 (- (float-time) started)))

(defun nl-agent-semantic-eval--constraints (max-chars text &optional max-bytes)
  "Return output constraint status for MAX-CHARS and optional MAX-BYTES."
  (let ((chars (and (stringp text) (length text)))
        (bytes (and (stringp text)
                    (string-bytes (encode-coding-string text 'utf-8 t)))))
    (list :status (cond ((null chars) 'unavailable)
                        ((or (= chars 0)
                             (nl-agent-semantic-render--blank-p text))
                         'failed)
                        ((and (<= chars max-chars)
                              (or (null max-bytes) (<= bytes max-bytes)))
                         'ok)
                        (t 'failed))
          :max-chars max-chars
          :actual-chars chars
          :actual-bytes bytes)))

(defun nl-agent-semantic-eval--screen (text required forbidden)
  "Return literal screening fields for TEXT and REQUIRED/FORBIDDEN."
  (let ((missing nil)
        (found nil))
    (if (stringp text)
        (let ((case-fold-search nil))
          ;; `regexp-quote' makes these exact literal substring checks.  The
          ;; explicit case-fold binding keeps e.g. A distinct from a.
          (dolist (literal required)
            (unless (string-match-p (regexp-quote literal) text)
              (push literal missing)))
          (dolist (literal forbidden)
            (when (string-match-p (regexp-quote literal) text)
              (push literal found)))
          (list :screening-status 'screened
                :missing-required (nreverse missing)
                :found-forbidden (nreverse found)))
      (list :screening-status 'unavailable
            :missing-required nil
            :found-forbidden nil))))

(defun nl-agent-semantic-eval--baseline (task required forbidden)
  "Evaluate deterministic TASK and return its bounded result."
  (let* ((ir (plist-get task :ir))
         (parsed (plist-get task :task))
         (constraints
          (plist-get (plist-get (cdr parsed) :constraints) :max-chars))
         (claims (plist-get (cdr (plist-get (cdr parsed) :plan)) :claims))
         (text (mapconcat (lambda (claim) (plist-get (cdr claim) :text))
                          claims "\n"))
         (result (nl-agent-ir-run ir))
         (usable (eq (plist-get result :status) 'ok))
         (screen (nl-agent-semantic-eval--screen
                  (and usable (plist-get result :text)) required forbidden)))
    (append
     (list :status (if usable 'usable 'constraint-failure)
           :constraints (nl-agent-semantic-eval--constraints constraints text))
     screen
     (when usable (list :text (plist-get result :text))))))

(defun nl-agent-semantic-eval--renderer-description (renderer)
  "Return fixed selector and generation settings for RENDERER."
  (if (not renderer)
      (list :mode 'baseline :selector nil :options nil
            :policy-version nil)
    (unless (nl-agent-semantic-renderer-p renderer)
      (error "Invalid semantic renderer"))
    (list :mode 'renderer
          :selector (nl-agent-semantic-renderer-selector renderer)
          :policy-version
          (or nl-agent-semantic-render-policy-version
              nl-agent-semantic-eval-default-policy-version)
          :options (list
                    :temperature
                    (nl-agent-semantic-renderer-temperature renderer)
                    :max-tokens
                    (nl-agent-semantic-renderer-max-tokens renderer)
                    :timeout-sec
                    (nl-agent-semantic-renderer-timeout-sec renderer)
                    :max-output-bytes
                    (nl-agent-semantic-renderer-max-output-bytes renderer)))))

(defun nl-agent-semantic-eval--render (renderer ir attempts)
  "Invoke RENDERER once or through the bounded repair API."
  (if (fboundp 'nl-agent-semantic-render-run-with-repair)
      (let* ((result
              (funcall #'nl-agent-semantic-render-run-with-repair
                       renderer ir attempts))
             (fallback-attempts
              (if (member (plist-get result :error-code)
                          '(invalid-ir selector-not-allowlisted))
                  0
                1)))
        (list :attempts (if (plist-member result :attempts)
                            (plist-get result :attempts)
                          fallback-attempts)
              :result result))
    (if (= attempts 1)
        (let ((result (nl-agent-semantic-render-run renderer ir)))
          (list :attempts (if (member (plist-get result :error-code)
                                      '(invalid-ir selector-not-allowlisted))
                              0 1)
                :result result))
      (list :attempts 0
            :result (list :status 'configuration-failure
                          :error-code 'repair-api-unavailable)))))

(defun nl-agent-semantic-eval--rendered
    (task required forbidden renderer attempts)
  "Evaluate one parsed TASK through RENDERER and screen usable output."
  (let* ((parsed (plist-get task :task))
         (max-chars
          (plist-get (plist-get (cdr parsed) :constraints) :max-chars))
         (run (nl-agent-semantic-eval--render renderer (plist-get task :ir)
                                             attempts))
         (result (plist-get run :result))
         (text (plist-get result :text))
         (constraints
          (nl-agent-semantic-eval--constraints
           max-chars text
           (nl-agent-semantic-renderer-max-output-bytes renderer)))
         (usable (and (eq (plist-get result :status) 'needs-review)
                      (stringp text)
                      (eq (plist-get constraints :status) 'ok)))
         (screen (nl-agent-semantic-eval--screen
                  (and usable text) required forbidden))
         (audit nil))
    (dolist (key '(:repair-history :repair-exhausted :repair-request))
      (when (plist-member result key)
        (setq audit (append audit (list key (plist-get result key))))))
    (append
     (list :status (if usable 'usable (or (plist-get result :status)
                                          'failure))
           :attempts (plist-get run :attempts)
           :attempt-metrics (copy-tree
                             (or (plist-get result :attempt-metrics)
                                 (when (plist-member result :attempt-metric)
                                   (list (plist-get result :attempt-metric)))))
           :constraints constraints)
     (when (plist-get result :error-code)
       (list :error-code (plist-get result :error-code)))
     audit
     screen
     (when usable (list :text text)))))

(defun nl-agent-semantic-eval--key-options (keys)
  "Validate evaluation KEYS and return (:attempts N)."
  (unless (= (% (length keys) 2) 0)
    (error "semantic evaluation options must be KEY VALUE pairs"))
  (let ((attempts 1)
        (seen nil))
    (while keys
      (let ((key (pop keys))
            (value (pop keys)))
        (unless (eq key :attempts)
          (error "unknown semantic evaluation option: %S" key))
        (when (memq key seen)
          (error "duplicate semantic evaluation option: %S" key))
        (push key seen)
        (unless (and (integerp value) (<= 1 value 3))
          (error ":attempts must be an integer from 1 through 3"))
        (setq attempts value)))
    (list :attempts attempts)))

(defun nl-agent-semantic-eval--telemetry (metrics expected-attempts)
  "Aggregate bounded renderer METRICS without retaining output text."
  (let ((input 0) (output 0) (output-known t)
        (complete 0) (rejected 0) (failed 0) (elapsed 0.0)
        (input-known t))
    (dolist (metric metrics)
      (if (integerp (plist-get metric :request-content-utf8-bytes))
          (setq input (+ input (plist-get metric :request-content-utf8-bytes)))
        (setq input-known nil))
      (if (integerp (plist-get metric :output-utf8-bytes))
          (setq output (+ output (plist-get metric :output-utf8-bytes)))
        (setq output-known nil))
      (setq elapsed (+ elapsed (or (plist-get metric :elapsed-seconds) 0.0)))
      (pcase (plist-get metric :outcome)
        ('accepted (setq complete (1+ complete)))
        ('rejected (setq rejected (1+ rejected)))
        ('failed (setq failed (1+ failed)))))
    (let* ((status (cond ((null metrics) 'unavailable)
                         ((or (not input-known)
                              (and expected-attempts
                                   (/= expected-attempts (length metrics))))
                          'partial)
                         ((and output-known (= failed 0)) 'complete)
                         (t 'partial))))
      (list :status status
            :attempts expected-attempts
            :measured-attempts (length metrics)
          :accepted complete :rejected rejected :failed failed
          :request-content-utf8-bytes (and (eq status 'complete)
                                           input-known input)
          :output-utf8-bytes (and (eq status 'complete)
                                  output-known output)
          :elapsed-seconds (and (eq status 'complete) elapsed)
          :measured-request-content-utf8-bytes (and input-known input)
          :measured-output-utf8-bytes (and output-known output)
          :measured-elapsed-seconds elapsed
          :token-counts (list :status 'unavailable :input nil :output nil)))))

;;;###autoload
(defun nl-agent-semantic-eval-run (corpus &optional renderer &rest keys)
  "Run deterministic and optional renderer evaluation over CORPUS.

CORPUS may be the normalized result of `nl-agent-semantic-eval-load-corpus', a
corpus path, or equivalent data.  RENDERER nil selects baseline-only mode.
The only option is :attempts, the host-owned total renderer attempt limit;
attempts greater than one use `nl-agent-semantic-render-run-with-repair'."
  (let* ((corpus (nl-agent-semantic-eval--corpus corpus))
         (options (nl-agent-semantic-eval--key-options keys))
         (attempts (plist-get options :attempts))
         ;; Snapshot fixed selector/options before any provider call.
         (renderer-info (nl-agent-semantic-eval--renderer-description renderer))
         (started (float-time))
         (results nil)
         (all-metrics nil)
         (expected-attempts 0)
         (counts (list :total 0 :ok 0 :failed 0
                       :baseline-usable 0 :baseline-failures 0
                       :rendered-usable 0 :rendered-failures 0
                       :screened-cases 0 :screening-unavailable-cases 0
                       :required-miss-cases 0 :forbidden-hit-cases 0
                       :required-missing-literals 0 :forbidden-hit-literals 0)))
    ;; IR verification has completed in `--corpus' before this loop can call a
    ;; renderer.  Baseline and model use each case's identical IR string.
    (dolist (task (plist-get corpus :cases))
      (let* ((case-start (float-time))
             (baseline
              (nl-agent-semantic-eval--baseline
               task (plist-get task :required) (plist-get task :forbidden)))
             (rendered
              (and renderer
                   (nl-agent-semantic-eval--rendered
                    task (plist-get task :required) (plist-get task :forbidden)
                    renderer attempts)))
             (selected (or rendered baseline))
             (missing (plist-get selected :missing-required))
             (found (plist-get selected :found-forbidden))
             (usable (eq (plist-get selected :status) 'usable))
             (case-result
              (append
               (list :id (plist-get task :id)
                     :task-id
                     (plist-get (cdr (plist-get task :task)) :id)
                     :status (if usable 'ok 'failed)
                     :baseline baseline)
               (when rendered (list :rendered rendered))
               (list :attempts (if rendered
                                  (plist-get rendered :attempts)
                                0)
                     :attempt-metrics (copy-tree
                                       (or (and rendered
                                                (plist-get rendered
                                                           :attempt-metrics))
                                           nil))
                     :constraints (plist-get selected :constraints)
                     :screening-status (plist-get selected :screening-status)
                     :missing-required missing
                     :found-forbidden found
                     :elapsed-seconds (nl-agent-semantic-eval--elapsed
                                       case-start)
                     :semantic-review (if rendered 'unreviewed
                                        'not-applicable))
               (when (plist-member selected :text)
                 (list :text (plist-get selected :text))))))
        (push case-result results)
        (setq all-metrics
              (append all-metrics
                      (or (and rendered
                               (plist-get rendered :attempt-metrics)) nil)))
        (setq expected-attempts
              (+ expected-attempts (if rendered
                                      (or (plist-get rendered :attempts) 0)
                                    0)))
        (setq counts (plist-put counts :total
                                (1+ (plist-get counts :total))))
        (setq counts
              (plist-put counts (if usable :ok :failed)
                         (1+ (plist-get counts (if usable :ok :failed)))))
        (if (eq (plist-get baseline :status) 'usable)
            (setq counts (plist-put counts :baseline-usable
                                    (1+ (plist-get counts :baseline-usable))))
          (setq counts (plist-put counts :baseline-failures
                                  (1+ (plist-get counts :baseline-failures)))))
        (when rendered
          (if (eq (plist-get rendered :status) 'usable)
              (setq counts (plist-put counts :rendered-usable
                                      (1+ (plist-get counts :rendered-usable))))
            (setq counts (plist-put counts :rendered-failures
                                    (1+ (plist-get counts :rendered-failures))))))
        (if (eq (plist-get selected :screening-status) 'screened)
            (setq counts (plist-put counts :screened-cases
                                    (1+ (plist-get counts :screened-cases))))
          (setq counts (plist-put counts :screening-unavailable-cases
                                  (1+ (plist-get counts
                                                :screening-unavailable-cases)))))
        (when missing
          (setq counts (plist-put counts :required-miss-cases
                                  (1+ (plist-get counts :required-miss-cases)))
                counts (plist-put counts :required-missing-literals
                                  (+ (plist-get counts :required-missing-literals)
                                     (length missing)))))
        (when found
          (setq counts (plist-put counts :forbidden-hit-cases
                                  (1+ (plist-get counts :forbidden-hit-cases)))
                counts (plist-put counts :forbidden-hit-literals
                                  (+ (plist-get counts :forbidden-hit-literals)
                                     (length found)))))))
    (setq results (nreverse results))
    (list :version 1
          :corpus-path (plist-get corpus :path)
          :corpus-hash (plist-get corpus :hash)
          :renderer renderer-info
          :attempts attempts
          :cases results
          :totals counts
          :telemetry (nl-agent-semantic-eval--telemetry
                      all-metrics
                      (and renderer expected-attempts))
          :elapsed-seconds (nl-agent-semantic-eval--elapsed started)
          ;; This field is deliberately not a quality score or a claim of
          ;; semantic correctness.  A human must inspect usable model text.
          :semantic-review 'manual-required)))

;;;###autoload
(defun nl-agent-semantic-eval-run-file (path &optional renderer &rest keys)
  "Load PATH as a corpus and run `nl-agent-semantic-eval-run'."
  (apply #'nl-agent-semantic-eval-run
         (nl-agent-semantic-eval-load-corpus path) renderer keys))

;;;###autoload
(defun nl-agent-semantic-eval-report-json (report &optional id)
  "Encode REPORT as one bounded JSONL envelope for machine consumers."
  (nl-agent-jsonl-encode (or id "semantic-evaluation") report))

(provide 'nl-agent-semantic-eval)

;;; nl-agent-semantic-eval.el ends here
