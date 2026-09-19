;;; evaluate-bulk-policy.el --- bulk delegation policy evaluation with deterministic fixture -*- lexical-binding: t; -*-

;;; Commentary:
;; A deterministic stub runner is the default. Set NELISP_AGENT_BULK_EVAL_LIVE=1
;; to use the explicitly configured loopback provider, or pass an injected
;; (ROUTER MAIN WORKER) triple as the second argument to
;; `nl-agent-example-bulk-policy-run' in tests.
;; The policy module decides whether to delegate. This runner exercises the
;; policy on a four-case corpus and compares against direct and delegated arms.
;; Literal checks are screening proxies; semantic correctness remains a human
;; review of the retained final answers and references.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defconst nl-agent-example-bulk-policy-root
  (let ((source (or load-file-name buffer-file-name)))
    (if source
        (directory-file-name
         (file-name-directory (directory-file-name
                               (file-name-directory source))))
      (expand-file-name ".")))
  "Project root resolved relative to this example source.")

(add-to-list 'load-path (expand-file-name "lisp" nl-agent-example-bulk-policy-root))
(add-to-list 'load-path (expand-file-name "../nelisp-llm/lisp"
                                          nl-agent-example-bulk-policy-root))
(add-to-list 'load-path (expand-file-name "../nelisp-photon/lisp"
                                          nl-agent-example-bulk-policy-root))

(require 'nl-agent-host)
(require 'nl-agent-bulk-reader)
(require 'nl-agent-bulk-policy)

;; The sibling example owns the corpus loader, the prompt builder and the
;; main-call helpers.  Load it by path here so this file also works when it is
;; loaded on its own, not only from the test file which loads both.  Loading the
;; source explicitly also keeps a stale sibling .elc out of the way.
(load (expand-file-name "examples/evaluate-bulk-reader.el"
                        nl-agent-example-bulk-policy-root)
      nil t)

;; Declare functions from evaluate-bulk-reader that are loaded at runtime.
(declare-function nl-agent-example-bulk-eval-load-corpus "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--utf8-bytes "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--numbered "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--prompt "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--message-bytes "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--screen "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--stub-answer "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--verify-sources "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--serialize-tool "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--call-main "evaluate-bulk-reader.el")
(declare-function nl-agent-example-bulk-eval--live-router "evaluate-bulk-reader.el")

(defconst nl-agent-example-bulk-policy--frozen-corpus-hash
  "13a0c00f4bc1b49afaae896fd678628c98a28a8371712b042cf59d0b375e4f40"
  "Expected SHA-256 of the frozen five-case bulk-reader-corpus.sexp.")

(defconst nl-agent-example-bulk-policy--main-options
  '(:temperature 0.0 :max_tokens 512 :timeout-sec 60)
  "Inference options for the main model prompts.")

(defconst nl-agent-example-bulk-policy--review-kinds
  '(("short-factual" . fact)
    ("distractor-tail" . fact)
    ("multi-file-negation" . multi-fact)
    ("absent-answer" . absence)
    ("quoted-instruction" . quoted-instruction)
    ("multi-fact" . multi-fact)
    ("absent-field" . absence)
    ("conflicting-sources" . conflict)
    ("quoted-instruction-embedded" . quoted-instruction))
  "Alist mapping case id to review kind. Conflict cases never report proxy-pass.")

(defun nl-agent-example-bulk-policy-load-cases (&optional frozen-corpus-path policy-corpus-path)
  "Load both frozen and policy corpora, validating the frozen hash.
Signal an error if the frozen corpus hash is not the expected constant.
Returns a list of nine cases in order: frozen five, then policy four."
  (let* ((frozen-path (or frozen-corpus-path
                         (expand-file-name "examples/bulk-reader-corpus.sexp"
                                         nl-agent-example-bulk-policy-root)))
         (policy-path (or policy-corpus-path
                         (expand-file-name "examples/bulk-policy-corpus.sexp"
                                         nl-agent-example-bulk-policy-root)))
         (frozen (nl-agent-example-bulk-eval-load-corpus frozen-path))
         (frozen-hash (plist-get frozen :hash)))
    (unless (equal frozen-hash nl-agent-example-bulk-policy--frozen-corpus-hash)
      (error "frozen corpus hash mismatch: expected %s, got %s"
             nl-agent-example-bulk-policy--frozen-corpus-hash frozen-hash))
    (let* ((policy (nl-agent-example-bulk-eval-load-corpus policy-path))
           (all-cases (append (plist-get frozen :cases)
                             (plist-get policy :cases)))
           (all-ids (mapcar (lambda (c) (plist-get c :id)) all-cases)))
      ;; Validate that every id has a review kind.
      (dolist (id all-ids)
        (unless (assoc id nl-agent-example-bulk-policy--review-kinds)
          (error "case id %S missing from review-kinds table" id)))
      (list :total (length all-cases)
            :frozen (length (plist-get frozen :cases))
            :policy (length (plist-get policy :cases))
            :frozen-hash (plist-get frozen :hash)
            :policy-hash (plist-get policy :hash)
            :cases all-cases))))

(defun nl-agent-example-bulk-policy--get-kind (case-id)
  "Return the review kind for CASE-ID, signaling if not found."
  (let ((pair (assoc case-id nl-agent-example-bulk-policy--review-kinds)))
    (unless pair (error "case id %S not in review table" case-id))
    (cdr pair)))

(defun nl-agent-example-bulk-policy--screen-with-kind (case answer kind)
  "Return screening data for CASE and ANSWER, accounting for CASE KIND.
Conflict cases always yield proxy-review, never proxy-pass."
  (let* ((answer (or answer ""))
         (required (plist-get case :required))
         (missing (cl-remove-if
                   (lambda (literal)
                     (string-match-p (regexp-quote literal) answer))
                   required)))
    (list :required (copy-sequence required) :missing missing
          :missing-required missing
          :absent-expected (and (plist-get case :absent) t)
          :proxy-status
          (if (eq kind 'conflict)
              'proxy-review
            (if (and (plist-get case :absent)
                     (string-match-p "記載されていません\\|利用できません\\|不明" answer))
                'proxy-review
              (if (and (null missing) (not (plist-get case :absent)))
                  'proxy-pass 'proxy-review)))
          :semantic-review 'unreviewed)))

(defconst nl-agent-example-bulk-policy--default-worker-timeout 60
  "Seconds allowed for one worker call unless the environment overrides it.
The shipped value.  A reasoning worker can exceed it: `qwen3:4b' ended five of
nine calls at exactly this limit, which is why the limit is a measurable knob
rather than a constant.")

(defun nl-agent-example-bulk-policy--worker-timeout ()
  "Return the worker timeout in seconds.
`NELISP_AGENT_BULK_EVAL_WORKER_TIMEOUT' overrides the default when it holds a
positive integer of at most 3600.  A malformed value is an error rather than a
silent fallback, because a measurement that quietly used the default would be
reported as if it had used the requested limit."
  (let ((raw (getenv "NELISP_AGENT_BULK_EVAL_WORKER_TIMEOUT")))
    (if (or (null raw) (string-empty-p (string-trim raw)))
        nl-agent-example-bulk-policy--default-worker-timeout
      (let ((value (and (string-match-p "\\`[0-9]+\\'" (string-trim raw))
                        (string-to-number (string-trim raw)))))
        (unless (and value (<= 1 value 3600))
          (error "NELISP_AGENT_BULK_EVAL_WORKER_TIMEOUT must be 1..3600, got %S" raw))
        value))))

(defconst nl-agent-example-bulk-policy--arm-specs
  '((policy-conservative . nil)
    (policy-exercise . (:mode opt-in :min-source-bytes 0 :max-paths 2 :fallback t)))
  "Policy arms run for every case, as (LABEL . CONSTRUCTOR-KEYS).
`policy-conservative' is the shipped default, which is `direct-only'.
`policy-exercise' lowers the admission floor and raises the path ceiling only
so that every case reaches delegation, diagnostics and the bounded fallback.
It is not a recommended configuration and its thresholds are not derived from
measurement.")

(defun nl-agent-example-bulk-policy--arm (label policy request outcomes)
  "Resolve REQUEST under POLICY and record the arm named LABEL.
OUTCOMES is a plist with `:direct', `:worker' and `:delegated-main' results
already obtained for this case.  The thunks replay those results instead of
issuing new inference, so an arm records which legs the policy chose and what
they cost without doubling the model calls.  The replay is reported as
`:replayed t' so no reader mistakes it for additional measurement."
  (let ((direct-calls 0) (delegate-calls 0) (main-calls 0))
    (let ((result
           (nl-agent-bulk-policy-resolve
            policy request
            :direct (lambda ()
                      (setq direct-calls (1+ direct-calls))
                      (plist-get outcomes :direct))
            :delegate (lambda ()
                        (setq delegate-calls (1+ delegate-calls))
                        (plist-get outcomes :worker))
            :delegated-main (lambda (_worker)
                              (setq main-calls (1+ main-calls))
                              (plist-get outcomes :delegated-main)))))
      (list :label label
            :replayed t
            :policy-version (plist-get result :policy-version)
            :mode (plist-get result :mode)
            :decision (plist-get result :decision)
            :diagnostics (plist-get result :diagnostics)
            :disposition (plist-get result :disposition)
            :review-status (plist-get result :review-status)
            :semantic-validation (plist-get result :semantic-validation)
            :fallback (plist-get result :fallback)
            :accounting (plist-get result :accounting)
            :final (plist-get result :final)
            :thunk-calls (list :direct direct-calls :delegate delegate-calls
                               :delegated-main main-calls)))))

(defun nl-agent-example-bulk-policy--arms (request outcomes)
  "Return every policy arm for REQUEST, replaying OUTCOMES."
  (mapcar (lambda (spec)
            (nl-agent-example-bulk-policy--arm
             (car spec)
             (apply #'nl-agent-bulk-policy-new (copy-sequence (cdr spec)))
             request outcomes))
          nl-agent-example-bulk-policy--arm-specs))

(defun nl-agent-example-bulk-policy--case-record
    (prepared router reader main-selector worker-selector live)
  (let* ((case (plist-get prepared :case))
         (case-id (plist-get case :id))
         (paths (plist-get prepared :paths))
         (sources (plist-get prepared :sources))
         (question (plist-get case :question))
         (kind (nl-agent-example-bulk-policy--get-kind case-id))
         (direct-prompt (nl-agent-example-bulk-eval--prompt
                         question (nl-agent-example-bulk-eval--numbered sources)))
         (direct (if live
                     (nl-agent-example-bulk-eval--call-main
                      router main-selector direct-prompt)
                   (list :status 'usable :answer
                         (nl-agent-example-bulk-eval--stub-answer case)
                         :elapsed-seconds 0.0
                         :output-utf8-bytes
                         (nl-agent-example-bulk-eval--utf8-bytes
                          (nl-agent-example-bulk-eval--stub-answer case)))))
         (bulk (if live
                   (nl-agent-bulk-reader-run reader question paths)
                 (list :status 'needs-review
                       :answer (nl-agent-example-bulk-eval--stub-answer case)
                       :references nil :not-found (and (plist-get case :absent) t)
                       :semantic-validation 'unverified
                       :metrics (list :role 'bulk-reader :selector worker-selector
                                      :request-content-utf8-bytes nil
                                      :output-utf8-bytes nil :elapsed-seconds 0.0
                                      :token-counts 'unavailable :cost 'unavailable
                                      :metrics-source 'mocked))))
         (bulk (or bulk (list :status 'failed :error-code 'bulk-reader-failure
                              :references nil :metrics nil)))
         (bulk (if (nl-agent-example-bulk-eval--verify-sources
                    reader paths sources)
                   bulk
                 (let ((copy (copy-tree bulk)))
                   (plist-put copy :status 'failed)
                   (plist-put copy :error-code 'source-changed)
                   copy)))
         (worker-status (plist-get bulk :status))
         (worker-usable (eq worker-status 'needs-review))
         (serialized (nl-agent-example-bulk-eval--serialize-tool bulk))
         (delegated-prompt
          (nl-agent-example-bulk-eval--prompt
           question (concat "Bulk-reader result:\n" serialized)))
         (delegated-main
          (cond (worker-usable
                 (if live
                     (nl-agent-example-bulk-eval--call-main
                      router main-selector delegated-prompt)
                   (list :status 'usable :answer
                         (nl-agent-example-bulk-eval--stub-answer case)
                         :elapsed-seconds 0.0
                         :output-utf8-bytes
                         (nl-agent-example-bulk-eval--utf8-bytes
                          (nl-agent-example-bulk-eval--stub-answer case)))))
                (t (list :status 'not-run :answer nil :error nil
                         :elapsed-seconds 0.0 :output-utf8-bytes nil))))
         (direct-status (plist-get direct :status))
         (delegated-status
          (if (not worker-usable) 'not-run
            (if (eq (plist-get delegated-main :status) 'usable)
                'usable 'failed)))
         (worker-metrics (plist-get bulk :metrics))
         (worker-elapsed (plist-get worker-metrics :elapsed-seconds))
         (direct-result (append
                         (list :status direct-status
                               :request-content-utf8-bytes
                               (nl-agent-example-bulk-eval--message-bytes direct-prompt)
                               :elapsed-seconds (plist-get direct :elapsed-seconds)
                               :selector main-selector :options
                               nl-agent-example-bulk-policy--main-options
                               :answer (plist-get direct :answer)
                               :output-utf8-bytes (plist-get direct :output-utf8-bytes)
                               :token-counts 'unavailable :cost 'unavailable)
                         (list :screening
                               (nl-agent-example-bulk-policy--screen-with-kind
                                case (plist-get direct :answer) kind))))
         (delegated-result
          (list :status delegated-status
                :worker-status worker-status
                :worker-usable worker-usable
                :worker-metrics worker-metrics
                :worker-elapsed-seconds worker-elapsed
                :main-status (plist-get delegated-main :status)
                :main-elapsed-seconds (plist-get delegated-main :elapsed-seconds)
                :worker-plus-main-elapsed-seconds
                (and (numberp worker-elapsed)
                     (+ worker-elapsed (or (plist-get delegated-main :elapsed-seconds)
                                           0.0)))
                :serialized-input-utf8-bytes
                (nl-agent-example-bulk-eval--utf8-bytes serialized)
                :request-content-utf8-bytes
                (and worker-usable
                     (nl-agent-example-bulk-eval--message-bytes delegated-prompt))
                :selector main-selector :options nl-agent-example-bulk-policy--main-options
                :answer (plist-get delegated-main :answer)
                :output-utf8-bytes (plist-get delegated-main :output-utf8-bytes)
                :token-counts 'unavailable :cost 'unavailable
                :screening (nl-agent-example-bulk-policy--screen-with-kind
                            case (plist-get delegated-main :answer) kind)))
         (source-bytes (apply #'+ (mapcar (lambda (source)
                                            (nl-agent-example-bulk-eval--utf8-bytes
                                             (plist-get source :text)))
                                          sources)))
         ;; The review kind doubles as the question kind the policy admits on,
         ;; so a conflict or quoted-instruction case is refused delegation
         ;; rather than relying on a diagnostic that cannot see those shapes.
         (request (list :question question :paths paths
                        :source-bytes source-bytes
                        :question-kind kind
                        ;; The host already holds the snapshot, so the absence
                        ;; screen can look past the excerpts the worker cited.
                        :sources sources))
         (outcomes
          (list :direct
                (list :status direct-status
                      :answer (plist-get direct :answer)
                      :request-content-utf8-bytes
                      (plist-get direct-result :request-content-utf8-bytes)
                      :output-utf8-bytes (plist-get direct :output-utf8-bytes)
                      :elapsed-seconds (plist-get direct :elapsed-seconds))
                :worker bulk
                :delegated-main
                (list :status (if (eq (plist-get delegated-main :status) 'usable)
                                  'usable 'failed)
                      :answer (plist-get delegated-main :answer)
                      :request-content-utf8-bytes
                      (nl-agent-example-bulk-eval--message-bytes delegated-prompt)
                      :output-utf8-bytes (plist-get delegated-main :output-utf8-bytes)
                      :elapsed-seconds (plist-get delegated-main :elapsed-seconds))))
         (policy-arms (nl-agent-example-bulk-policy--arms request outcomes)))
    (list :id case-id
          :kind kind
          :category (if (> (length paths) 1) 'multi-file 'single-file)
          :question question :sources sources
          :source-utf8-bytes source-bytes
          :direct direct-result
          :delegated delegated-result
          :policy-arms policy-arms
          :bulk-result bulk)))

(defun nl-agent-example-bulk-policy--sum-numbers (values)
  (when (and values (cl-every #'integerp values)) (apply #'+ values)))

(defun nl-agent-example-bulk-policy--sum-values (values)
  "Sum VALUES, returning nil when VALUES is empty or holds a non-number.
Used for elapsed seconds, which are floats.  An unknown contribution keeps the
total unknown rather than turning it into a smaller number."
  (when (and values (cl-every #'numberp values)) (apply #'+ values)))

(defun nl-agent-example-bulk-policy--arm-of (case label)
  "Return CASE's policy arm named LABEL, or nil."
  (cl-find label (plist-get case :policy-arms)
           :key (lambda (arm) (plist-get arm :label))))

(defun nl-agent-example-bulk-policy--diagnostic-histogram (arms)
  "Return an alist of diagnostic code to occurrence count across ARMS.
Sorted by code name so the report is stable between runs."
  (let ((counts nil))
    (dolist (arm arms)
      (dolist (diagnostic (plist-get arm :diagnostics))
        (let* ((code (plist-get diagnostic :code))
               (cell (assq code counts)))
          (if cell
              (setcdr cell (1+ (cdr cell)))
            (push (cons code 1) counts)))))
    (sort counts (lambda (left right)
                   (string< (symbol-name (car left))
                            (symbol-name (car right)))))))

(defun nl-agent-example-bulk-policy--arm-summary (cases label)
  "Summarise the policy arm named LABEL across CASES."
  (let* ((arms (delq nil (mapcar (lambda (case)
                                   (nl-agent-example-bulk-policy--arm-of case label))
                                 cases)))
         (finals (mapcar (lambda (arm) (plist-get arm :final)) arms))
         (statuses (mapcar (lambda (final) (plist-get final :status)) finals))
         (paths (mapcar (lambda (final) (plist-get final :path)) finals))
         (accountings (mapcar (lambda (arm) (plist-get arm :accounting)) arms)))
    (list :label label
          :cases (length arms)
          :usable (cl-count 'usable statuses)
          :failed (cl-count 'failed statuses)
          :final-direct (cl-count 'direct paths)
          :final-delegated (cl-count 'delegated paths)
          :rejected (cl-count 'reject arms
                              :key (lambda (arm) (plist-get arm :disposition)))
          :fallbacks-used
          (cl-count-if (lambda (arm)
                         (plist-get (plist-get arm :fallback) :used))
                       arms)
          :decision-reasons
          (nl-agent-example-bulk-policy--diagnostic-histogram
           ;; Reuse the counter by presenting each decision as a diagnostic.
           (mapcar (lambda (arm)
                     (list :diagnostics
                           (list (list :code (plist-get (plist-get arm :decision)
                                                        :reason)))))
                   arms))
          :diagnostic-histogram
          (nl-agent-example-bulk-policy--diagnostic-histogram arms)
          :total-request-content-utf8-bytes
          (nl-agent-example-bulk-policy--sum-numbers
           (mapcar (lambda (acct)
                     (plist-get acct :total-request-content-utf8-bytes))
                   accountings))
          :total-output-utf8-bytes
          (nl-agent-example-bulk-policy--sum-numbers
           (mapcar (lambda (acct) (plist-get acct :total-output-utf8-bytes))
                   accountings))
          :total-elapsed-seconds
          (nl-agent-example-bulk-policy--sum-values
           (mapcar (lambda (acct) (plist-get acct :total-elapsed-seconds))
                   accountings))
          :attempts
          (nl-agent-example-bulk-policy--sum-numbers
           (mapcar (lambda (acct) (plist-get acct :attempt-count)) accountings))
          :token-counts 'unavailable :cost 'unavailable)))

(defun nl-agent-example-bulk-policy--paired-p (case)
  (and (eq (plist-get (plist-get case :direct) :status) 'usable)
       (eq (plist-get (plist-get case :delegated) :status) 'usable)))

(defun nl-agent-example-bulk-policy--summary (cases)
  (let* ((total (length cases))
         (direct-usable (cl-count 'usable cases
                                  :key (lambda (case)
                                         (plist-get (plist-get case :direct) :status))))
         (delegated-usable (cl-count 'usable cases
                                     :key (lambda (case)
                                            (plist-get (plist-get case :delegated) :status))))
         (paired (cl-remove-if-not #'nl-agent-example-bulk-policy--paired-p cases))
         (direct-all (mapcar (lambda (case)
                              (plist-get (plist-get case :direct)
                                         :request-content-utf8-bytes)) cases))
         (delegated-all (mapcar (lambda (case)
                                 (plist-get (plist-get case :delegated)
                                            :request-content-utf8-bytes)) cases))
         (serialized-all (mapcar (lambda (case)
                                  (plist-get (plist-get case :delegated)
                                             :serialized-input-utf8-bytes)) cases))
         (paired-direct (mapcar (lambda (case)
                                 (plist-get (plist-get case :direct)
                                            :request-content-utf8-bytes)) paired))
         (paired-main (mapcar (lambda (case)
                               (plist-get (plist-get case :delegated)
                                          :request-content-utf8-bytes)) paired))
         (paired-worker (mapcar (lambda (case)
                                 (plist-get (plist-get
                                             (plist-get case :delegated)
                                             :worker-metrics)
                                            :request-content-utf8-bytes)) paired))
         (direct-bytes (nl-agent-example-bulk-policy--sum-numbers paired-direct))
         (main-bytes (nl-agent-example-bulk-policy--sum-numbers paired-main))
         (worker-bytes (nl-agent-example-bulk-policy--sum-numbers paired-worker))
         (combined (and worker-bytes main-bytes (+ worker-bytes main-bytes)))
         (coverage (cond ((null paired) 'none)
                         ((and worker-bytes combined) 'complete)
                         (t 'unavailable))))
    (list :total total
          :direct-usable direct-usable :direct-failed (- total direct-usable)
          :delegated-usable delegated-usable
          :delegated-failed (cl-count 'failed cases
                                      :key (lambda (case)
                                             (plist-get (plist-get case :delegated)
                                                        :status)))
          :delegated-not-run (cl-count 'not-run cases
                                       :key (lambda (case)
                                              (plist-get (plist-get case :delegated)
                                                         :status)))
          :all-direct-request-bytes (nl-agent-example-bulk-policy--sum-numbers direct-all)
          :all-delegated-request-bytes (nl-agent-example-bulk-policy--sum-numbers delegated-all)
          :all-delegated-serialized-bytes
          (nl-agent-example-bulk-policy--sum-numbers serialized-all)
          :paired-cases (length paired)
          :paired-direct-main-request-bytes direct-bytes
          :paired-delegated-main-request-bytes main-bytes
          :paired-worker-request-bytes worker-bytes
          :paired-combined-input-bytes combined
          :paired-metrics-coverage coverage
          :paired-savings-bytes (and direct-bytes combined (- direct-bytes combined))
          :paired-savings-percent
          (and direct-bytes combined (> direct-bytes 0)
               (* 100.0 (/ (float (- direct-bytes combined)) direct-bytes)))
          :direct-request-bytes direct-bytes
          :delegated-request-bytes main-bytes
          :delegated-serialized-bytes
          (and (eq coverage 'complete)
               (nl-agent-example-bulk-policy--sum-numbers
                (mapcar (lambda (case)
                          (plist-get (plist-get case :delegated)
                                     :serialized-input-utf8-bytes)) paired)))
          :main-token-counts 'unavailable :main-cost 'unavailable
          :worker-token-counts 'unavailable :worker-cost 'unavailable
          :policy-arms
          (mapcar (lambda (spec)
                    (nl-agent-example-bulk-policy--arm-summary cases (car spec)))
                  nl-agent-example-bulk-policy--arm-specs))))

(defun nl-agent-example-bulk-policy-run (&optional output live-router frozen-corpus-path policy-corpus-path)
  "Run policy evaluation on nine cases: frozen five plus policy four.
Emits a detailed report with direct, delegated, and policy arms.
LIVE-ROUTER, when supplied, is a (ROUTER MAIN WORKER) triple for tests.
FROZEN-CORPUS-PATH and POLICY-CORPUS-PATH are optional validation paths."
  (let* ((cases-data (nl-agent-example-bulk-policy-load-cases
                     frozen-corpus-path policy-corpus-path))
         (root (expand-file-name "examples/bulk-reader-corpus"
                                nl-agent-example-bulk-policy-root))
         (live (equal (getenv "NELISP_AGENT_BULK_EVAL_LIVE") "1"))
         (live-parts (and live (or live-router
                                   (nl-agent-example-bulk-eval--live-router))))
         (router (car live-parts))
         (main-selector (or (cadr live-parts) "stub/main"))
         (worker-selector (or (caddr live-parts) "stub/worker"))
         (router (or router
                     (nl-agent-host-router-new
                      (list (nl-llm-agent-provider-new
                             "stub" :models '("main" "worker")
                             :open (lambda (&rest _) nil)
                             :complete (lambda (&rest _) "")
                             :close (lambda (&rest _) nil))))))
         (reader (nl-agent-bulk-reader-new
                  router worker-selector (list worker-selector) root
                  :max-tokens 4096
                  :timeout-sec (nl-agent-example-bulk-policy--worker-timeout)
                  :temperature 0.0
                  :json-mode (and live t)))
         (started (float-time))
         (prepared nil))
    ;; Read every case snapshot before opening any inference session.
    (dolist (case (plist-get cases-data :cases))
      (let ((paths (plist-get case :paths)))
        (push (list :case case :paths paths
                    :sources (nl-agent-bulk-reader-sources reader paths)) prepared)))
    (setq prepared (nreverse prepared))
    (let* ((cases (mapcar (lambda (item)
                            (nl-agent-example-bulk-policy--case-record
                             item router reader main-selector worker-selector live))
                          prepared))
           (summary (nl-agent-example-bulk-policy--summary cases))
           (report (list :format "nl-agent-bulk-policy-eval-v1"
                         :mode (if live 'live 'stub)
                         :metrics-source (if live 'empirical 'mocked)
                         :frozen-corpus-hash (plist-get cases-data :frozen-hash)
                         :policy-corpus-hash (plist-get cases-data :policy-hash)
                         :corpus-root "examples/bulk-reader-corpus"
                         :main-selector main-selector :worker-selector worker-selector
                         :elapsed-seconds (max 0.0 (- (float-time) started))
                         :summary summary :cases cases
                         :notes '("literal screening is a proxy, not semantic truth"
                                  "conflict cases never report proxy-pass: no literal check can show that an answer reported a disagreement"
                                  "token counts and cost are unavailable unless the provider reports them"
                                  "stub-mode metrics are mocked and are not empirical"
                                  "policy arms replay the direct, worker and delegated-main results already recorded for the case; they issue no additional model calls and are marked :replayed t"
                                  "policy-exercise lowers the admission floor and raises the path ceiling only to reach delegation, diagnostics and fallback on every case; its thresholds are not an empirical routing threshold"
                                  "this report alone establishes no quality, cost or latency result; docs/bulk-policy.md records what has and has not been measured"
                                  "elapsed seconds include model swapping when the host GPU cannot hold both models, so they are not a latency measurement"))))
      (when output
        (with-temp-file output
          (let ((print-length nil) (print-level nil))
            (prin1 report (current-buffer))
            (insert "\n"))))
      report)))

(defun nl-agent-example-evaluate-bulk-policy-main ()
  "CLI entry point for the bulk-policy evaluation."
  (condition-case err
      (let ((output nil) (args command-line-args-left))
        (when (equal (car args) "--") (setq args (cdr args)))
        (while args
          (let ((flag (pop args)))
            (unless (and (equal flag "--output") args)
              (error "unknown option: %s" flag))
            (setq output (expand-file-name (pop args)))))
        (princ (let ((print-length nil) (print-level nil))
                 (concat (prin1-to-string
                          (nl-agent-example-bulk-policy-run output)) "\n")))
        (kill-emacs 0))
    (error (princ (format "bulk-policy-eval: %s\n" (error-message-string err))
                  'external-debugging-output)
           (kill-emacs 2))))

(provide 'evaluate-bulk-policy)
;;; evaluate-bulk-policy.el ends here
