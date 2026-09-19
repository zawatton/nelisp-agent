;;; nl-agent-bulk-policy.el --- host-side bulk delegation policy -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst nl-agent-bulk-policy-version "bulk-policy-v1")
(defconst nl-agent-bulk-policy-max-attempts 3)
(defconst nl-agent-bulk-policy-default-absence-markers
  '("記載されていません" "記載がありません" "記載なし" "該当なし"
    "not recorded" "no record" "not listed" "not available"))

(defconst nl-agent-bulk-policy-default-excluded-question-kinds
  '(conflict quoted-instruction)
  "Question kinds that may not be delegated, whatever the diagnostics say.

Both shapes were observed to fail delegation while producing valid citations,
so no diagnostic in this module can detect them: the cited ranges are real and
complete, and only the inference drawn from them is wrong.

- `conflict': the answer must resolve a disagreement between sources.  A worker
  answered with the revision the sources themselves mark invalid and stated
  that no disagreement exists.
- `quoted-instruction': the answer must judge an instruction quoted inside the
  document.  A worker concluded the instruction should be followed while citing
  the line that says it is a past transcription error.

Excluding them at admission is a deliberate refusal to route a class of
question, not a claim that the class has been made safe.  See
`docs/bulk-policy.md'.")

(cl-defstruct (nl-agent-bulk-policy (:constructor nl-agent-bulk-policy--make))
  mode min-source-bytes max-paths max-question-bytes fallback absence-markers
  numeral-screen excluded-question-kinds require-question-kind
  uncited-absence-screen coverage-overlap-chars rival-value-screen
  rival-uncalibrated-severity)

(defun nl-agent-bulk-policy--validate-keys (keys allowed where)
  (unless (and (listp keys) (proper-list-p keys) (= 0 (% (length keys) 2)))
    (error "%s: options must be pairs" where))
  (let ((seen nil) (tail keys))
    (while tail
      (let ((key (pop tail)))
        (unless (memq key allowed) (error "%s: unknown option %S" where key))
        (when (memq key seen) (error "%s: duplicate option %S" where key))
        (push key seen) (pop tail))))
  keys)

;;;###autoload
(defun nl-agent-bulk-policy-new (&rest keys)
  "Create a new delegation policy with validated settings."
  (let ((mode 'direct-only) (min-source-bytes 8192) (max-paths 1) (max-question-bytes 4096)
        (fallback t) (absence-markers (copy-sequence nl-agent-bulk-policy-default-absence-markers))
        (numeral-screen 'note)
        (excluded-question-kinds
         (copy-sequence nl-agent-bulk-policy-default-excluded-question-kinds))
        (require-question-kind t)
        (uncited-absence-screen 'reject)
        (coverage-overlap-chars 8)
        (rival-value-screen 'reject)
        (rival-uncalibrated-severity 'note))
    (nl-agent-bulk-policy--validate-keys keys
      '(:mode :min-source-bytes :max-paths :max-question-bytes :fallback :absence-markers
        :numeral-screen :excluded-question-kinds :require-question-kind
        :uncited-absence-screen :coverage-overlap-chars :rival-value-screen
        :rival-uncalibrated-severity)
      "nl-agent-bulk-policy-new")
    (while keys
      (pcase (pop keys)
        (:mode (setq mode (pop keys)))
        (:min-source-bytes (setq min-source-bytes (pop keys)))
        (:max-paths (setq max-paths (pop keys)))
        (:max-question-bytes (setq max-question-bytes (pop keys)))
        (:fallback (setq fallback (pop keys)))
        (:absence-markers (setq absence-markers (pop keys)))
        (:numeral-screen (setq numeral-screen (pop keys)))
        (:excluded-question-kinds (setq excluded-question-kinds (pop keys)))
        (:require-question-kind (setq require-question-kind (pop keys)))
        (:uncited-absence-screen (setq uncited-absence-screen (pop keys)))
        (:coverage-overlap-chars (setq coverage-overlap-chars (pop keys)))
        (:rival-value-screen (setq rival-value-screen (pop keys)))
        (:rival-uncalibrated-severity
         (setq rival-uncalibrated-severity (pop keys)))))
    (unless (memq mode '(direct-only opt-in)) (error "mode must be direct-only or opt-in, got %S" mode))
    (unless (and (integerp min-source-bytes) (>= min-source-bytes 0) (<= min-source-bytes 131072))
      (error "min-source-bytes must be 0..131072, got %S" min-source-bytes))
    (unless (and (integerp max-paths) (>= max-paths 1) (<= max-paths 8))
      (error "max-paths must be 1..8, got %S" max-paths))
    (unless (and (integerp max-question-bytes) (>= max-question-bytes 1) (<= max-question-bytes 4096))
      (error "max-question-bytes must be 1..4096, got %S" max-question-bytes))
    (unless (or (null fallback) (eq fallback t)) (error "fallback must be t or nil, got %S" fallback))
    (unless (and (listp absence-markers) (not (null absence-markers)))
      (error "absence-markers must be non-empty"))
    (dolist (marker absence-markers)
      (unless (and (stringp marker) (not (string-empty-p marker)))
        (error "absence-markers must contain non-empty strings")))
    (setq absence-markers (copy-sequence absence-markers))
    (unless (memq numeral-screen '(note reject)) (error "numeral-screen must be note or reject, got %S" numeral-screen))
    (unless (and (listp excluded-question-kinds) (proper-list-p excluded-question-kinds))
      (error "excluded-question-kinds must be a proper list, got %S" excluded-question-kinds))
    (dolist (kind excluded-question-kinds)
      (unless (and kind (symbolp kind) (not (keywordp kind)))
        (error "excluded-question-kinds must contain non-nil non-keyword symbols, got %S" kind)))
    (setq excluded-question-kinds (copy-sequence excluded-question-kinds))
    (unless (or (null require-question-kind) (eq require-question-kind t))
      (error "require-question-kind must be t or nil, got %S" require-question-kind))
    (unless (memq uncited-absence-screen '(reject note nil))
      (error "uncited-absence-screen must be reject, note or nil, got %S" uncited-absence-screen))
    (unless (or (null coverage-overlap-chars)
                (and (integerp coverage-overlap-chars)
                     (<= 2 coverage-overlap-chars 256)))
      (error "coverage-overlap-chars must be an integer 2..256 or nil, got %S"
             coverage-overlap-chars))
    (unless (memq rival-value-screen '(reject note nil))
      (error "rival-value-screen must be reject, note or nil, got %S" rival-value-screen))
    (unless (memq rival-uncalibrated-severity '(reject note nil))
      (error "rival-uncalibrated-severity must be reject, note or nil, got %S"
             rival-uncalibrated-severity))
    (nl-agent-bulk-policy--make :mode mode :min-source-bytes min-source-bytes :max-paths max-paths
                                 :max-question-bytes max-question-bytes :fallback fallback
                                 :absence-markers absence-markers :numeral-screen numeral-screen
                                 :excluded-question-kinds excluded-question-kinds
                                 :require-question-kind require-question-kind
                                 :uncited-absence-screen uncited-absence-screen
                                 :coverage-overlap-chars coverage-overlap-chars
                                 :rival-value-screen rival-value-screen
                                 :rival-uncalibrated-severity rival-uncalibrated-severity)))

(defun nl-agent-bulk-policy--validate-request (request)
  (unless (and (listp request) (proper-list-p request)) (error "request must be a proper list"))
  (let ((keys (copy-sequence request)) (seen nil))
    (unless (= (% (length keys) 2) 0) (error "request must have even number of elements"))
    (while keys
      (let ((key (pop keys)))
        (unless (memq key '(:question :paths :source-bytes :question-kind :sources))
          (error "request has unexpected key %S" key))
        (when (memq key seen) (error "request has duplicate key %S" key))
        (push key seen) (pop keys)))
    (dolist (required '(:question :paths :source-bytes))
      (unless (memq required seen)
        (error "request must have keys :question :paths :source-bytes, missing %S" required))))
  (let ((kind (plist-get request :question-kind)))
    (unless (or (null kind) (and (symbolp kind) (not (keywordp kind))))
      (error "request :question-kind must be a non-keyword symbol or nil, got %S" kind)))
  (let ((question (plist-get request :question)))
    (unless (and (stringp question) (not (string-empty-p question)))
      (error "request :question must be a non-empty string")))
  (let ((paths (plist-get request :paths)))
    (unless (and (listp paths) (proper-list-p paths) (not (null paths)))
      (error "request :paths must be a non-empty proper list"))
    (let ((seen-paths nil))
      (dolist (path paths)
        (unless (and (stringp path) (not (string-empty-p path)))
          (error "request :paths must contain non-empty strings"))
        (when (member path seen-paths) (error "request :paths contains duplicate: %S" path))
        (push path seen-paths))))
  (let ((bytes (plist-get request :source-bytes)))
    (unless (and (integerp bytes) (>= bytes 0))
      (error "request :source-bytes must be non-negative integer, got %S" bytes)))
  ;; Optional snapshot of the requested sources, supplied by the host so the
  ;; absence screen can look beyond the excerpts the worker chose to cite.  The
  ;; module never reads the filesystem: whatever it inspects is passed in.
  (let ((sources (plist-get request :sources)))
    (unless (or (null sources) (proper-list-p sources))
      (error "request :sources must be a proper list or nil, got %S" sources))
    (dolist (source sources)
      (unless (and (listp source) (proper-list-p source)
                   (stringp (plist-get source :path))
                   (not (string-empty-p (plist-get source :path)))
                   (stringp (plist-get source :text)))
        (error "request :sources entries need string :path and :text, got %S" source))))
  request)

;;;###autoload
(defun nl-agent-bulk-policy-admit (policy request)
  "Evaluate REQUEST against POLICY and return the routing decision.

The checks run in this fixed order, so the recorded reason is deterministic:

1. `mode-direct-only' — the policy is not opted in.
2. `excluded-question-kind' — REQUEST declares a `:question-kind' the policy
   refuses to delegate at all.  See
   `nl-agent-bulk-policy-default-excluded-question-kinds'.
3. `question-kind-unknown' — the policy requires a declared kind and REQUEST
   has none.  Delegation requires the caller to have classified the question;
   an unclassified question is not assumed safe.
4. `too-many-paths'.
5. `question-too-large'.
6. `too-few-source-bytes'.
7. `admitted'.

Checks 2 and 3 are refusals to route a class of question, not evidence that
the class has been made safe."
  (unless (nl-agent-bulk-policy-p policy) (error "invalid policy"))
  (nl-agent-bulk-policy--validate-request request)
  (let ((question (plist-get request :question)) (paths (plist-get request :paths))
        (source-bytes (plist-get request :source-bytes))
        (kind (plist-get request :question-kind)))
    (cond
     ((not (eq (nl-agent-bulk-policy-mode policy) 'opt-in))
      (list :path 'direct :reason 'mode-direct-only :detail "Policy mode is direct-only"))
     ((and kind (memq kind (nl-agent-bulk-policy-excluded-question-kinds policy)))
      (list :path 'direct :reason 'excluded-question-kind
            :detail (format "Question kind %s is excluded from delegation" kind)))
     ((and (null kind) (nl-agent-bulk-policy-require-question-kind policy))
      (list :path 'direct :reason 'question-kind-unknown
            :detail "Request declares no :question-kind and the policy requires one"))
     ((> (length paths) (nl-agent-bulk-policy-max-paths policy))
      (list :path 'direct :reason 'too-many-paths
            :detail (format "Request has %d paths, max is %d" (length paths)
                            (nl-agent-bulk-policy-max-paths policy))))
     ((> (string-bytes (encode-coding-string question 'utf-8 t))
         (nl-agent-bulk-policy-max-question-bytes policy))
      (list :path 'direct :reason 'question-too-large
            :detail (format "Question is %d UTF-8 bytes, max is %d"
                            (string-bytes (encode-coding-string question 'utf-8 t))
                            (nl-agent-bulk-policy-max-question-bytes policy))))
     ((< source-bytes (nl-agent-bulk-policy-min-source-bytes policy))
      (list :path 'direct :reason 'too-few-source-bytes
            :detail (format "Source is %d bytes, min is %d" source-bytes
                            (nl-agent-bulk-policy-min-source-bytes policy))))
     (t (list :path 'delegated :reason 'admitted :detail "Admitted for delegation")))))

(defun nl-agent-bulk-policy--collapse-whitespace (text)
  "Return TEXT with every run of whitespace collapsed to one space.
Source text carries line breaks an answer does not reproduce, so spans are
compared in this normalised form."
  (string-trim (replace-regexp-in-string "[ \t\n\r\f\v　]+" " " text)))

(defun nl-agent-bulk-policy--shared-span-p (answer text span)
  "Return non-nil when ANSWER and TEXT share a run of SPAN characters.

Both are whitespace-normalised first.  Every window of the answer is searched
for in the source rather than the reverse, because the answer is bounded at
2048 characters while a source may be 64 KiB."
  (let* ((needle-source (nl-agent-bulk-policy--collapse-whitespace answer))
         (haystack (nl-agent-bulk-policy--collapse-whitespace text))
         (limit (- (length needle-source) span))
         (index 0)
         (found nil))
    (while (and (not found) (<= index limit))
      (when (string-search (substring needle-source index (+ index span)) haystack)
        (setq found t))
      (setq index (1+ index)))
    found))

(defun nl-agent-bulk-policy--answer-uses-source-p (policy answer path sources)
  "Return non-nil when ANSWER visibly reuses the text of PATH within SOURCES.

The evidence required is an exact shared span of `coverage-overlap-chars'
characters.  A span that long is unlikely to coincide by chance, which matters
because suppressing a coverage rejection on weak evidence would let a genuinely
incomplete answer through.  When the slot is nil, or the source text is not
available, there is no evidence and the answer counts as not using it."
  (let ((span (nl-agent-bulk-policy-coverage-overlap-chars policy)))
    (and span (stringp answer)
         (let ((source (cl-find path sources
                                :key (lambda (entry) (plist-get entry :path))
                                :test #'equal)))
           (and source
                (nl-agent-bulk-policy--shared-span-p
                 answer (plist-get source :text) span))))))

(defconst nl-agent-bulk-policy-rival-context-chars 32
  "How much text before a number is taken as its context, in characters.

Wide enough to reach the subject qualifier, which is what tells one reading of
a value from another.  At sixteen 「第2回路の絶縁抵抗は」 fits but
\"Circuit 2 insulation resistance is\" does not, so two English readings looked
identical and the parallel-subject rule never saw the qualifier that separates
them.")

(defconst nl-agent-bulk-policy--rival-copula
  (regexp-opt '(" is" " are" " was" " were" " of") t)
  "Words that link a field name to its value, stripped like a separator.

Japanese marks the link with 「は」, a character, so it belongs in the separator
set.  English marks it with a word.  Without this a table cell reading
\"Contract demand,250 kW\" cannot be matched against the prose \"the correct
contract demand is 180 kW\", because stripping removes the comma from one side
and leaves \"is\" on the other.")

(defconst nl-agent-bulk-policy--rival-separator "[ \t,、|｜:：=＝は]"
  "Characters that separate a field name from its value.

A table writes 契約電力,250kW and prose writes 契約電力は 180kW.  The wording
that names the field is the same; only the separator differs, and comparing
raw suffixes would find nothing in common because the comparison starts at
that separator.  Both contexts are stripped of a trailing run of these before
being compared, which is what lets a table cell be matched against a footnote
that contradicts it.")

(defconst nl-agent-bulk-policy-rival-match-chars 4
  "How many characters two contexts must share, ending at the number.

Two numbers whose immediately preceding text agrees for this many characters
are treated as candidates for the same slot: 点検間隔は6か月 and 点検間隔は12か月
share 「点検間隔は」.  Shorter matches make unrelated numbers look like rivals;
longer ones miss a rival phrased slightly differently.

Four was chosen by measurement, not by argument, and it counts characters of
the context after its trailing separators are stripped.  On the raw context
four was too loose -- 絶縁抵抗は 85MΩ and 接地抵抗は 8.5Ω pair up on 「抵抗は 」
-- but stripping removes 「は 」 from both, leaving 「抵抗」, so the same pair now
needs only two.  Meanwhile the shortest genuine contradiction is 「契約電力」,
exactly four.  A domain whose field names are shorter may need another value.")

(defconst nl-agent-bulk-policy--rival-boundary "[。．\\.!?！？\n\r]"
  "Characters that end the phrase introducing a number.

The context is cut at the nearest one.  Without this a match can run past a
sentence end and pair numbers that only share the tail of the previous
sentence: 「…です。 手順2」 and 「…ます。 手順3」 share 「。 手順」 although the
numbers are list labels rather than rival readings of one value.  Measured
against the recorded runs, that single rule removed seven false positives and
kept the one true positive.")

(defun nl-agent-bulk-policy--numeral-contexts (text)
  "Return ((VALUE . LEFT-CONTEXT) ...) for every digit run in TEXT.
Fullwidth digits are normalised first.  LEFT-CONTEXT reaches back at most
`nl-agent-bulk-policy-rival-context-chars' characters and stops at the nearest
sentence boundary, so it holds the wording that introduces this number and
nothing from the sentence before it."
  (let* ((norm (nl-agent-bulk-policy--normalize-fullwidth-digits text))
         (result nil)
         (start 0))
    (while (and (< start (length norm)) (string-match "[0-9]+" norm start))
      (let* ((begin (match-beginning 0))
             (end (match-end 0))
             ;; A number glued to an identifier is a label, not a measurement:
             ;; T-1, B-2, D-3301, 第1回路.  Comparing labels pairs every item of
             ;; an enumeration with every other.
             (label (and (> begin 0)
                         (string-match-p "[-_A-Za-z第]"
                                         (substring norm (1- begin) begin))))
             (window (substring norm (max 0 (- begin nl-agent-bulk-policy-rival-context-chars))
                                begin))
             (cut (let ((last nil) (index 0))
                    (while (string-match nl-agent-bulk-policy--rival-boundary window index)
                      (setq last (match-end 0) index (match-end 0)))
                    last)))
        (unless label
          (push (cons (substring norm begin end)
                      (string-trim-left (if cut (substring window cut) window)))
                result))
        (setq start end)))
    (nreverse result)))

(defun nl-agent-bulk-policy--shared-tail (left right)
  "Return how many characters LEFT and RIGHT share, counting back from the end."
  (let ((shared 0)
        (index-left (length left))
        (index-right (length right)))
    (while (and (> index-left 0) (> index-right 0)
                (eq (aref left (1- index-left)) (aref right (1- index-right))))
      (setq shared (1+ shared) index-left (1- index-left) index-right (1- index-right)))
    shared))

(defun nl-agent-bulk-policy--parallel-subjects-p (left right)
  "Return non-nil when LEFT and RIGHT name parallel subjects rather than one.

Two contexts that agree except for a single character are describing different
members of a series — 第1回路 beside 第2回路, A事業場 beside B事業場 — and their
numbers are separate readings rather than competing ones.  Measured on a
number-dense corpus this distinction removed every false positive while keeping
the contradictions, because a real contradiction restates the same subject."
  (and (> (length left) 0)
       (= (length left) (length right))
       (not (equal left right))
       (= 1 (cl-count nil (cl-mapcar #'eq (append left nil) (append right nil))))))

(defun nl-agent-bulk-policy--strip-separator-run (text)
  "Return TEXT without its trailing run of separator characters."
  (let ((end (length text)))
    (while (and (> end 0)
                (string-match-p nl-agent-bulk-policy--rival-separator
                                (substring text (1- end) end)))
      (setq end (1- end)))
    (substring text 0 end)))

(defun nl-agent-bulk-policy--strip-separators (text)
  "Return TEXT without the separators and copula that link it to a value."
  (let* ((trimmed (nl-agent-bulk-policy--strip-separator-run text))
         (lowered (downcase trimmed))
         (copula (let ((case-fold-search t))
                   (when (string-match
                          (concat nl-agent-bulk-policy--rival-copula "\\'") lowered)
                     (match-beginning 0)))))
    (nl-agent-bulk-policy--strip-separator-run
     (if copula (substring trimmed 0 copula) trimmed))))

(defun nl-agent-bulk-policy--rival-contexts-p (raw-mine raw-other)
  "Return non-nil when the contexts introduce competing readings of one slot."
  (let* ((mine (nl-agent-bulk-policy--strip-separators raw-mine))
         (other (nl-agent-bulk-policy--strip-separators raw-other))
         (shared (nl-agent-bulk-policy--shared-tail mine other)))
    (and (>= shared nl-agent-bulk-policy-rival-match-chars)
         (not (nl-agent-bulk-policy--parallel-subjects-p
               (substring mine 0 (- (length mine) shared))
               (substring other 0 (- (length other) shared)))))))

(defun nl-agent-bulk-policy--calibrated-script-p (text)
  "Return non-nil when TEXT contains a character the screen was calibrated on.

The rival screen's thresholds were measured on Japanese, where a compound such
as 絶縁抵抗 separates itself from 接地抵抗 in two characters.  A language that
spreads the same distinction across a shared word defeats a character count,
which was measured: see `examples/bulk-en-corpus.sexp'.  Outside the script it
was calibrated on, the screen still reports but does not reject by default."
  (and (stringp text)
       (string-match-p "[぀-ゟ゠-ヿ一-鿿＀-￟]" text)))

(defun nl-agent-bulk-policy--unreported-rivals (answer sources)
  "Return rivals of ANSWER's numbers that SOURCES state and ANSWER omits.

For every number the answer asserts, the sources are searched for a different
number introduced by the same wording.  Such a number is a rival reading of the
same slot, and an answer that states one without the other has resolved a
disagreement silently.  A rival the answer also mentions is not reported: an
answer carrying both values is engaging with the disagreement rather than
hiding it, which is checked by value rather than by looking for words like
\"conflict\" because an answer may contain such a word while denying the
disagreement.

Each element is (VALUE RIVAL PATH CONTEXT BOTH-CONTEXTS), the last being the
two contexts joined so the caller can judge what script they are written in."
  (let* ((answer-values (mapcar #'car (nl-agent-bulk-policy--numeral-contexts answer)))
         (entries nil)
         (found nil))
    ;; One flat list across every source: a disagreement usually lies between
    ;; two files, so comparing only within a file would miss the common case.
    (dolist (source sources)
      (dolist (context (nl-agent-bulk-policy--numeral-contexts
                        (or (plist-get source :text) "")))
        (push (list (car context) (cdr context) (plist-get source :path)) entries)))
    (setq entries (nreverse entries))
    (when answer-values
      (dolist (mine entries)
        (when (member (car mine) answer-values)
          (dolist (other entries)
            (unless (or (equal (car other) (car mine))
                        (member (car other) answer-values)
                        (assoc (car mine) found))
              (when (nl-agent-bulk-policy--rival-contexts-p (nth 1 mine) (nth 1 other))
                (push (list (car mine) (car other) (nth 2 other)
                            (substring (nth 1 other)
                                       (max 0 (- (length (nth 1 other))
                                                 nl-agent-bulk-policy-rival-match-chars)))
                            (concat (nth 1 mine) (nth 1 other)))
                      found)))))))
    (nreverse found)))

(defun nl-agent-bulk-policy--absence-reported-p (policy text)
  "Return non-nil when TEXT itself reports an absence under POLICY's markers.

An answer that says the value is not recorded is agreeing with a source that
says so, not contradicting it, so the absence screens exempt it.  The exemption
is deliberately literal: an answer that reports the absence and then supplies a
value anyway is exempt too, which is a known limitation recorded in
`docs/bulk-policy.md'."
  (and (stringp text)
       (cl-some (lambda (marker) (string-match-p marker text))
                (nl-agent-bulk-policy-absence-markers policy))))

(defun nl-agent-bulk-policy--normalize-fullwidth-digits (text)
  "Convert fullwidth digits to ASCII."
  (dolist (pair '(("０" "0") ("１" "1") ("２" "2") ("３" "3") ("４" "4")
                  ("５" "5") ("６" "6") ("７" "7") ("８" "8") ("９" "9")))
    (setq text (replace-regexp-in-string (car pair) (cadr pair) text)))
  text)

(defun nl-agent-bulk-policy--extract-numerals (text)
  "Extract maximal runs of [0-9０-９]+ from TEXT."
  (let ((normalized (nl-agent-bulk-policy--normalize-fullwidth-digits text)) (numerals nil))
    (with-temp-buffer
      (insert normalized)
      (goto-char (point-min))
      (while (re-search-forward "[0-9]+" nil t)
        (push (match-string 0) numerals)))
    (nreverse numerals)))

(defun nl-agent-bulk-policy--unsupported-numerals (answer references _markers)
  "Find numerals in ANSWER that do not appear in REFERENCES."
  (let ((numerals (nl-agent-bulk-policy--extract-numerals answer)) (unsupported nil))
    (dolist (numeral numerals)
      (unless (cl-some (lambda (ref)
                         (let ((ref-text (nl-agent-bulk-policy--normalize-fullwidth-digits (plist-get ref :text))))
                           (string-match-p (regexp-quote numeral) ref-text)))
                       references)
        (push numeral unsupported)))
    (nreverse unsupported)))

;;;###autoload
(defun nl-agent-bulk-policy-diagnose (policy request result)
  "Evaluate RESULT against POLICY and return diagnostics plist."
  (unless (nl-agent-bulk-policy-p policy) (error "invalid policy"))
  (nl-agent-bulk-policy--validate-request request)
  (let ((diagnostics nil) (disposition 'accept-for-review) (status (plist-get result :status)))
    (if (not (eq status 'needs-review))
      ;; Carry the reader's error code through, so a report says which way the
      ;; worker failed instead of only that it did.
      (progn (push (list :code 'worker-failed :severity 'reject
                         :detail (format "Worker failed: status %s, error-code %s"
                                         status (or (plist-get result :error-code) 'none)))
                   diagnostics)
             (setq disposition 'reject))
      (let ((answer (plist-get result :answer)) (references (plist-get result :references))
            (not-found (plist-get result :not-found)) (paths (plist-get request :paths))
            (sources (plist-get request :sources)))
        (unless (and (stringp answer) (not (string-empty-p answer)))
          (push (list :code 'malformed-result :severity 'reject :detail "Answer is not a non-empty string") diagnostics)
          (setq disposition 'reject))
        (unless (and (listp references) (proper-list-p references))
          (push (list :code 'malformed-result :severity 'reject :detail "References is not a proper list") diagnostics)
          (setq disposition 'reject))
        (let ((valid-refs nil))
          (dolist (ref references)
            (cond
             ((not (and (listp ref) (proper-list-p ref)))
(push (list :code 'malformed-result :severity 'reject :detail "Reference is not a plist") diagnostics)
(setq disposition 'reject))
((not (equal (sort (seq-filter #'keywordp ref) #'string<) '(:end-line :path :sha256 :start-line :text)))
(push (list :code 'malformed-result :severity 'reject :detail "Reference has wrong keys") diagnostics)
(setq disposition 'reject))
((not (and (stringp (plist-get ref :path)) (not (string-empty-p (plist-get ref :path)))))
(push (list :code 'malformed-result :severity 'reject :detail "Reference path is not a non-empty string") diagnostics)
(setq disposition 'reject))
((not (and (integerp (plist-get ref :start-line)) (> (plist-get ref :start-line) 0)))
(push (list :code 'malformed-result :severity 'reject :detail "Reference start-line is not a positive integer") diagnostics)
(setq disposition 'reject))
((not (and (integerp (plist-get ref :end-line)) (>= (plist-get ref :end-line) (plist-get ref :start-line))))
(push (list :code 'malformed-result :severity 'reject :detail "Reference end-line is invalid") diagnostics)
(setq disposition 'reject))
((not (and (stringp (plist-get ref :sha256)) (= (length (plist-get ref :sha256)) 64)
(string-match-p "^[a-f0-9]\\{64\\}$" (plist-get ref :sha256))))
(push (list :code 'malformed-result :severity 'reject :detail "Reference sha256 is invalid") diagnostics)
(setq disposition 'reject))
((not (stringp (plist-get ref :text)))
(push (list :code 'malformed-result :severity 'reject :detail "Reference text is not a string") diagnostics)
(setq disposition 'reject))
(t (push ref valid-refs))))
          (setq references (nreverse valid-refs)))
        (when (and (not not-found) (> (length paths) 1))
          (let ((ref-paths (delete-dups (mapcar (lambda (ref) (plist-get ref :path)) references)))
                (uncovered nil))
            (dolist (path paths) (unless (member path ref-paths) (push path uncovered)))
            (setq uncovered (nreverse uncovered))
            ;; An uncovered path whose text the answer visibly reuses was read
            ;; and left uncited: that is a citation defect, not a missing fact.
            ;; Separating the two stops a complete answer from being rejected
            ;; for citing narrowly, which was observed: see docs/bulk-policy.md.
            ;; Without :sources the split cannot be made, and the strict reading
            ;; is kept because it is the conservative one.
            (let ((unused nil) (used-uncited nil))
              (dolist (path uncovered)
                (if (nl-agent-bulk-policy--answer-uses-source-p policy answer path sources)
                    (push path used-uncited)
                  (push path unused)))
              (setq unused (nreverse unused) used-uncited (nreverse used-uncited))
              (when used-uncited
                (push (list :code 'uncited-source-used :severity 'note
                            :detail (format "Answer reuses text from uncited sources: %s"
                                            (string-join used-uncited ", ")))
                      diagnostics))
              (when unused
                (push (list :code 'partial-source-coverage :severity 'reject
                            :detail (format "Uncovered paths: %s" (string-join unused ", ")))
                      diagnostics)
                (setq disposition 'reject)))))
        ;; Absence screening.  An answer that itself reports an absence agrees
        ;; with the source and is not in conflict with it, so it is exempt: that
        ;; is what stops a correct absence answer from being rejected for citing
        ;; the very line that states the absence.
        (when (and (not not-found)
                   (stringp answer)
                   (not (nl-agent-bulk-policy--absence-reported-p policy answer)))
          (let ((cited nil))
            (dolist (ref references)
              (let ((ref-text (plist-get ref :text)))
                (dolist (marker (nl-agent-bulk-policy-absence-markers policy))
                  (when (and (stringp ref-text) (string-match-p marker ref-text))
                    (setq cited t)
                    (push (list :code 'absence-marker-conflict :severity 'reject
                                :detail (format "Reference %s:%d-%d contains marker: %s"
                                                (plist-get ref :path) (plist-get ref :start-line)
                                                (plist-get ref :end-line) marker)) diagnostics)
                    (setq disposition 'reject)))))
            ;; A worker can evade the check above by citing narrowly, which was
            ;; observed: see docs/bulk-policy.md, worker comparison.  When the
            ;; screen is enabled the requested sources are scanned too, and a
            ;; policy configured for a check it cannot perform is a reject
            ;; rather than a silent skip.
            (let ((screen (nl-agent-bulk-policy-uncited-absence-screen policy)))
              (when (and screen (not cited))
                (if (null sources)
                    (progn
                      (push (list :code 'absence-scope-unavailable :severity 'reject
                                  :detail "uncited-absence-screen is enabled but the request supplied no :sources")
                            diagnostics)
                      (setq disposition 'reject))
                  (catch 'nl-agent-bulk-policy--found
                    (dolist (source sources)
                      (let ((text (plist-get source :text)))
                        (dolist (marker (nl-agent-bulk-policy-absence-markers policy))
                          (when (and (stringp text) (string-match-p marker text))
                            (push (list :code 'uncited-absence-marker :severity screen
                                        :detail (format "Source %s states an absence the answer does not report: %s"
                                                        (plist-get source :path) marker))
                                  diagnostics)
                            (when (eq screen 'reject) (setq disposition 'reject))
                            (throw 'nl-agent-bulk-policy--found t)))))))))))
        ;; A value the sources contradict, where the answer names one reading
        ;; and not the other.  No citation-shaped check can see this: every
        ;; cited line is real and only the reading is wrong.
        (let ((screen (nl-agent-bulk-policy-rival-value-screen policy)))
          (when (and screen (not not-found) (stringp answer))
            (if (null sources)
                (progn
                  (push (list :code 'rival-scope-unavailable :severity 'reject
                              :detail "rival-value-screen is enabled but the request supplied no :sources")
                        diagnostics)
                  (setq disposition 'reject))
              (dolist (rival (nl-agent-bulk-policy--unreported-rivals answer sources))
                (let* ((calibrated (nl-agent-bulk-policy--calibrated-script-p (nth 4 rival)))
                       (severity (if (or calibrated (not (eq screen 'reject)))
                                     screen
                                   (nl-agent-bulk-policy-rival-uncalibrated-severity policy))))
                  (when severity
                    (push (list :code 'unreported-rival-value :severity severity
                                :detail (format "Answer states %s but %s states %s after %S%s"
                                                (nth 0 rival) (nth 2 rival) (nth 1 rival)
                                                (nth 3 rival)
                                                (if calibrated ""
                                                  " (severity reduced: outside the script the screen was calibrated on)")))
                          diagnostics)
                    (when (eq severity 'reject) (setq disposition 'reject))))))))
        (let ((unsupported (nl-agent-bulk-policy--unsupported-numerals answer references
                                                                        (nl-agent-bulk-policy-absence-markers policy))))
          (when unsupported
            (let ((severity (nl-agent-bulk-policy-numeral-screen policy)))
              (push (list :code 'unsupported-numeral :severity severity
                          :detail (format "Unsupported numerals: %s" (string-join unsupported ", "))) diagnostics)
              (when (eq severity 'reject) (setq disposition 'reject)))))
        (when (and not-found (null references))
          (push (list :code 'absence-unevidenced :severity 'note :detail "Not-found claim has no cited evidence") diagnostics))))
    (list :diagnostics (nreverse diagnostics) :disposition disposition :review-status 'needs-review
          :semantic-validation 'unverified)))

(defun nl-agent-bulk-policy--sum-metric (attempts key)
  "Sum KEY across ATTEMPTS, returning nil if any value is nil."
  (let ((total nil) (any-nil nil))
    (dolist (attempt attempts)
      (let ((value (plist-get attempt key)))
        (if (null value) (setq any-nil t)
          (if (null total) (setq total value) (setq total (+ total value))))))
    (if any-nil nil total)))

;###autoload
(defun nl-agent-bulk-policy-resolve (policy request &rest keys)
  "Execute REQUEST against POLICY, invoking thunks as needed."
  (unless (nl-agent-bulk-policy-p policy) (error "invalid policy"))
  (nl-agent-bulk-policy--validate-request request)
  (nl-agent-bulk-policy--validate-keys keys '(:direct :delegate :delegated-main) "resolve")
  (let ((direct-fn (plist-get keys :direct)) (delegate-fn (plist-get keys :delegate))
        (delegated-main-fn (plist-get keys :delegated-main)))
    (unless (functionp direct-fn) (error "resolve :direct must be a function"))
    (when delegate-fn (unless (functionp delegate-fn) (error "resolve :delegate must be a function")))
    (when delegated-main-fn (unless (functionp delegated-main-fn) (error "resolve :delegated-main must be a function")))
    (let ((decision (nl-agent-bulk-policy-admit policy request)) (attempts nil) (attempt-count 0)
          (diagnostics nil) (disposition nil) (fallback-used nil) (fallback-reason nil)
          (fallback-from nil) (fallback-to nil) (final-path nil) (final-status nil)
          (final-answer nil) (final-error-code nil) (paths-taken nil) (total-request-bytes nil)
          (total-output-bytes nil) (total-elapsed nil))
      (let ((path (plist-get decision :path)))
        (cond
         ((eq path 'direct)
          (let ((attempt (condition-case _err (funcall direct-fn) (error (list :status 'failed :error-code 'direct-failure)))))
            (when (< attempt-count nl-agent-bulk-policy-max-attempts)
              (setq attempt-count (1+ attempt-count))
              (push (append (list :index 0 :path 'direct :role 'main) attempt) attempts)
              (push 'direct paths-taken)
              (setq final-path 'direct) (setq final-status (plist-get attempt :status))
              (setq final-answer (plist-get attempt :answer)) (setq final-error-code (plist-get attempt :error-code))
              (setq total-request-bytes (plist-get attempt :request-content-utf8-bytes))
              (setq total-output-bytes (plist-get attempt :output-utf8-bytes))
              (setq total-elapsed (plist-get attempt :elapsed-seconds)))))
         ((not delegate-fn)
          (let ((attempt (condition-case _err (funcall direct-fn) (error (list :status 'failed :error-code 'direct-failure)))))
            (when (< attempt-count nl-agent-bulk-policy-max-attempts)
              (setq attempt-count (1+ attempt-count)) (push (append (list :index 0 :path 'direct :role 'main) attempt) attempts)
              (push 'direct paths-taken) (setq final-path 'direct) (setq final-status (plist-get attempt :status))
              (setq final-answer (plist-get attempt :answer)) (setq final-error-code (plist-get attempt :error-code))
              (setq total-request-bytes (plist-get attempt :request-content-utf8-bytes))
              (setq total-output-bytes (plist-get attempt :output-utf8-bytes))
              (setq total-elapsed (plist-get attempt :elapsed-seconds)))))
         (t
          (let ((worker (condition-case _err (funcall delegate-fn) (error (list :status 'failed :error-code 'delegate-failure)))))
            (when (< attempt-count nl-agent-bulk-policy-max-attempts)
              (setq attempt-count (1+ attempt-count))
              (let ((metrics (plist-get worker :metrics)))
                (push (append (list :index 0 :path 'delegated :role 'worker
                                    :request-content-utf8-bytes (plist-get metrics :request-content-utf8-bytes)
                                    :output-utf8-bytes (plist-get metrics :output-utf8-bytes)
                                    :elapsed-seconds (plist-get metrics :elapsed-seconds))
                              (list :status (plist-get worker :status)
                                    :answer (plist-get worker :answer)
                                    :error-code (plist-get worker :error-code)))
                      attempts))
              (push 'delegated paths-taken))
            (let ((diag (nl-agent-bulk-policy-diagnose policy request worker)))
              (setq diagnostics (plist-get diag :diagnostics)) (setq disposition (plist-get diag :disposition))
              (if (eq disposition 'reject)
                (if (nl-agent-bulk-policy-fallback policy)
                  (progn (setq fallback-used t) (setq fallback-from 'delegated) (setq fallback-to 'direct)
                         (setq fallback-reason (if (eq (plist-get worker :status) 'needs-review) 'diagnostic-reject 'delegate-failure))
                         (let ((direct (condition-case _err (funcall direct-fn) (error (list :status 'failed :error-code 'direct-failure)))))
                           (when (< attempt-count nl-agent-bulk-policy-max-attempts)
                             (setq attempt-count (1+ attempt-count))
                             (push (append (list :index 1 :path 'direct :role 'main) direct) attempts)
                             (push 'direct paths-taken))
                           (setq final-path 'direct) (setq final-status (plist-get direct :status))
                           (setq final-answer (plist-get direct :answer)) (setq final-error-code (plist-get direct :error-code)))
                           (setq total-request-bytes (nl-agent-bulk-policy--sum-metric attempts :request-content-utf8-bytes))
                           (setq total-output-bytes (nl-agent-bulk-policy--sum-metric attempts :output-utf8-bytes))
                           (setq total-elapsed (nl-agent-bulk-policy--sum-metric attempts :elapsed-seconds)))
                  (progn (setq final-path 'delegated) (setq final-status 'failed) (setq final-error-code 'delegation-rejected) (setq final-answer nil)))
                (if delegated-main-fn
                  (let ((main (condition-case _err (funcall delegated-main-fn worker) (error (list :status 'failed :error-code 'delegated-main-failure)))))
                    (when (< attempt-count nl-agent-bulk-policy-max-attempts)
                      (setq attempt-count (1+ attempt-count)) (push (append (list :index 1 :path 'delegated :role 'main) main) attempts)
                      (push 'delegated paths-taken))
                    (if (eq (plist-get main :status) 'usable)
                      (progn (setq final-path 'delegated) (setq final-status 'usable) (setq final-answer (plist-get main :answer)) (setq final-error-code nil)
                             (setq total-request-bytes (nl-agent-bulk-policy--sum-metric attempts :request-content-utf8-bytes))
                             (setq total-output-bytes (nl-agent-bulk-policy--sum-metric attempts :output-utf8-bytes))
                             (setq total-elapsed (nl-agent-bulk-policy--sum-metric attempts :elapsed-seconds)))
                      (if (nl-agent-bulk-policy-fallback policy)
                        (progn (setq fallback-used t) (setq fallback-from 'delegated) (setq fallback-to 'direct) (setq fallback-reason 'delegated-main-failed)
                               (let ((direct (condition-case _err (funcall direct-fn) (error (list :status 'failed :error-code 'direct-failure)))))
                                 (when (< attempt-count nl-agent-bulk-policy-max-attempts)
                                   (setq attempt-count (1+ attempt-count)) (push (append (list :index 2 :path 'direct :role 'main) direct) attempts)
                                   (push 'direct paths-taken))
                                 (setq final-path 'direct) (setq final-status (plist-get direct :status)) (setq final-answer (plist-get direct :answer))
                                 (setq final-error-code (plist-get direct :error-code))
                                 (setq total-request-bytes (nl-agent-bulk-policy--sum-metric attempts :request-content-utf8-bytes))
                                 (setq total-output-bytes (nl-agent-bulk-policy--sum-metric attempts :output-utf8-bytes))
                                 (setq total-elapsed (nl-agent-bulk-policy--sum-metric attempts :elapsed-seconds))))
                        (progn (setq final-path 'delegated) (setq final-status 'failed) (setq final-error-code 'delegated-main-failed) (setq final-answer nil)
                               (setq total-request-bytes (nl-agent-bulk-policy--sum-metric attempts :request-content-utf8-bytes))
                               (setq total-output-bytes (nl-agent-bulk-policy--sum-metric attempts :output-utf8-bytes))
                               (setq total-elapsed (nl-agent-bulk-policy--sum-metric attempts :elapsed-seconds))))))
                  (progn (setq final-path 'delegated) (setq final-status 'usable) (setq final-answer (plist-get worker :answer)) (setq final-error-code nil))))))))
      (list :policy-version nl-agent-bulk-policy-version :mode (nl-agent-bulk-policy-mode policy)
            :decision decision :attempts (nreverse attempts) :diagnostics diagnostics :disposition disposition
            :review-status 'needs-review :semantic-validation 'unverified
            :final (list :path final-path :status final-status :answer final-answer :error-code final-error-code)
            :fallback (list :used fallback-used :reason fallback-reason :from fallback-from :to fallback-to)
            :accounting (list :attempt-count attempt-count :paths-taken (nreverse paths-taken)
                              :includes-failed-attempts t
                              :total-request-content-utf8-bytes total-request-bytes :total-output-utf8-bytes total-output-bytes
                              :total-elapsed-seconds total-elapsed :token-counts (list :status 'unavailable :input nil :output nil)
                              :cost (list :status 'unavailable)))))))

(provide 'nl-agent-bulk-policy)
; nl-agent-bulk-policy.el ends here
