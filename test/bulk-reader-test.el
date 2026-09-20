;;; bulk-reader-test.el --- bounded bulk reader tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'nl-llm-agent-provider)
(require 'nl-agent-bulk-reader)

(defmacro nl-agent-bulk-reader-test--file (contents &rest body)
  (declare (indent 1))
  `(let ((directory (make-temp-file "nl-bulk-" t)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "sample.txt" directory)
             (insert ,contents))
           ,@body)
       (delete-directory directory t))))

(ert-deftest nl-agent-bulk-reader-test-path-boundaries ()
  (nl-agent-bulk-reader-test--file "safe\n"
    (let ((reader (nl-agent-bulk-reader--make :root directory)))
      (dolist (path '("../sample.txt" "/tmp/sample.txt" "~/sample.txt" "x/../sample.txt"))
        (should-error (nl-agent-bulk-reader--path reader path))))))

(ert-deftest nl-agent-bulk-reader-test-unicode-snapshot ()
  (nl-agent-bulk-reader-test--file "一行\n二行\n"
    (let* ((reader (nl-agent-bulk-reader--make :root directory))
           (source (car (nl-agent-bulk-reader-sources reader '("sample.txt")))))
      (should (= 2 (plist-get source :line-count)))
      (should (= 64 (length (plist-get source :sha256))))
      (should (equal "一行\n二行\n" (plist-get source :text))))))

(ert-deftest nl-agent-bulk-reader-test-stale-range ()
  (nl-agent-bulk-reader-test--file "one\ntwo\n"
    (let* ((reader (nl-agent-bulk-reader--make :root directory))
           (source (car (nl-agent-bulk-reader-sources reader '("sample.txt")))))
      (with-temp-file (expand-file-name "sample.txt" directory) (insert "changed\n"))
      (should-error (nl-agent-bulk-reader-read-range reader "sample.txt"
                                                     (plist-get source :sha256) 1 1)))))

(ert-deftest nl-agent-bulk-reader-test-range-excerpt-and-bound ()
  (nl-agent-bulk-reader-test--file "one\ntwo\nthree\n"
    (let* ((reader (nl-agent-bulk-reader--make :root directory))
           (source (car (nl-agent-bulk-reader-sources reader '("sample.txt"))))
           (range (nl-agent-bulk-reader-read-range reader "sample.txt"
                                                   (plist-get source :sha256) 2 3)))
      (should (equal (plist-get range :text) "two\nthree"))
      (should-error (nl-agent-bulk-reader-read-range reader "sample.txt"
                                                     (plist-get source :sha256) 1 4)))))

(ert-deftest nl-agent-bulk-reader-test-output-schema ()
  (let ((sources '((:path "sample.txt" :sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                    :text "line\n" :line-count 1))))
    (should-error
     (nl-agent-bulk-reader--validate-output nil
       "{\"answer\":\"x\",\"references\":[{\"path\":\"sample.txt\",\"start_line\":1,\"end_line\":1,\"extra\":1}],\"not_found\":false}"
       sources)))
  (should-error
   (nl-agent-bulk-reader--validate-output nil
     "{\"answer\":\"x\",\"references\":{},\"not_found\":true}" nil))
  (should-error
   (nl-agent-bulk-reader--validate-output nil
     "{\"answer\":\"x\",\"references\":null,\"not_found\":true}" nil)))

(ert-deftest nl-agent-bulk-reader-test-empty-reference-array-is-valid ()
  (should (equal
           (plist-get
            (nl-agent-bulk-reader--validate-output nil
              "{\"answer\":\"none\",\"references\":[],\"not_found\":true}" nil)
            :answer)
           "none")))
  (should-error
   (nl-agent-bulk-reader--validate-output nil
     "{\"answer\":\"none\",\"references\":[],\"not_found\":false}" nil))

(ert-deftest nl-agent-bulk-reader-test-exact-tool-args ()
  (should-error (nl-agent-bulk-reader--args '(:question "x") '(:question :paths) "bulk.read"))
  (should-error (nl-agent-bulk-reader--args '(:question "x" :paths nil :extra 1)
                                             '(:question :paths) "bulk.read")))

(ert-deftest nl-agent-bulk-reader-test-permission-denial-precedes-read ()
  (let* ((registry (nl-agent-tool-registry-new))
         (reader (nl-agent-bulk-reader--make :root (file-name-as-directory temporary-file-directory)))
         (policy (nl-agent-permission-policy-new :mode 'manual :unattended t)))
    (nl-agent-bulk-reader-register-tools registry reader)
    (let ((result (nl-agent-permission-call policy registry "bulk.read"
                                            '(:question "q" :paths ("missing")))))
      (should (eq (plist-get result :status) 'denied)))))

(ert-deftest nl-agent-bulk-reader-test-tool-value-is-complete-string ()
  (let ((value (nl-agent-bulk-reader--tool-value
                '(:status needs-review :references ((:path "a" :text "full"))
                  :answer "answer"))))
    (should (stringp value))
    (should (string-match-p "full" value))))

(ert-deftest nl-agent-bulk-reader-test-registered-roundtrip-under-print-limits ()
  (nl-agent-bulk-reader-test--file "trusted quote\nsecond\n"
    (let ((registry (nl-llm-agent-provider-registry-new)))
      (nl-llm-agent-provider-register
       registry (nl-llm-agent-provider-new "local" :models '((:id "model"))
                                           :open (lambda (_m _o) '(:live t))
                                           :complete (lambda (_s _m)
                                                       "{\"answer\":\"found\",\"references\":[{\"path\":\"sample.txt\",\"start_line\":1,\"end_line\":1}],\"not_found\":false}")
                                           :close (lambda (_s) nil)))
      (let* ((reader (nl-agent-bulk-reader-new (nl-agent-host-router-new registry)
                                                "local/model" '("local/model") directory))
             (tools (nl-agent-tool-registry-new))
             (policy (nl-agent-permission-policy-new :mode 'off)))
        (nl-agent-bulk-reader-register-tools tools reader)
        (let* ((print-length 1) (print-level 1)
               (call (nl-agent-permission-call policy tools "bulk.read"
                                               '(:question "q" :paths ("sample.txt"))))
               (value (read (plist-get call :text)))
               (ref (car (plist-get value :references)))
               (range (nl-agent-permission-call
                       policy tools "bulk.read-range"
                       (list :path (plist-get ref :path) :sha256 (plist-get ref :sha256)
                             :start-line 1 :end-line 1))))
          (should (equal (plist-get ref :text) "trusted quote"))
          (should (string-match-p "trusted quote" (plist-get range :text))))))))

(ert-deftest nl-agent-bulk-reader-test-local-file-rejections ()
  (let ((directory (make-temp-file "nl-bulk-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "bad.txt" directory)
            (set-buffer-multibyte nil) (insert "\xff"))
          (with-temp-file (expand-file-name "big.txt" directory)
            (set-buffer-multibyte nil)
            (insert (make-string (1+ (* 64 1024)) ?x)))
          (let ((reader (nl-agent-bulk-reader--make :root directory)))
            (should-error (nl-agent-bulk-reader-sources reader '("bad.txt")))
            (should-error (nl-agent-bulk-reader-sources reader '("big.txt")))
            (when (fboundp 'make-symbolic-link)
              (make-symbolic-link (expand-file-name "bad.txt" directory)
                                  (expand-file-name "link.txt" directory))
              (should-error (nl-agent-bulk-reader-sources reader '("link.txt"))))))
      (delete-directory directory t))))

(ert-deftest nl-agent-bulk-reader-test-provider-success-and-close ()
  (nl-agent-bulk-reader-test--file "answer line\n"
    (let ((closed nil)
          (registry (nl-llm-agent-provider-registry-new)))
      (nl-llm-agent-provider-register
       registry
       (nl-llm-agent-provider-new "local" :models '((:id "model"))
                                  :open (lambda (_model _options) '(:state live))
                                  :complete (lambda (_state _messages)
                                              "{\"answer\":\"found\",\"references\":[{\"path\":\"sample.txt\",\"start_line\":1,\"end_line\":1}],\"not_found\":false}")
                                  :close (lambda (_state) (setq closed t))))
      (let* ((router (nl-agent-host-router-new registry))
             (reader (nl-agent-bulk-reader-new router "local/model" '("local/model") directory))
             (result (nl-agent-bulk-reader-run reader "where?" '("sample.txt"))))
        (should (eq (plist-get result :status) 'needs-review))
        (should (equal (plist-get result :answer) "found"))
        (should closed)))))

(ert-deftest nl-agent-bulk-reader-test-json-mode-option-is-host-fixed ()
  (nl-agent-bulk-reader-test--file "line\n"
    (let ((options nil) (registry (nl-llm-agent-provider-registry-new)))
      (nl-llm-agent-provider-register
       registry (nl-llm-agent-provider-new "local" :models '((:id "model"))
                                           :open (lambda (_m opts) (setq options opts) '(:live t))
                                           :complete (lambda (_s _m) "{\"answer\":\"x\",\"references\":[{\"path\":\"sample.txt\",\"start_line\":1,\"end_line\":1}],\"not_found\":false}")
                                           :close (lambda (_s) nil)))
      (let ((reader (nl-agent-bulk-reader-new (nl-agent-host-router-new registry)
                                               "local/model" '("local/model") directory :json-mode t)))
        (nl-agent-bulk-reader-run reader "q" '("sample.txt"))
        (should (equal (plist-get options :response_format) '(:type "json_object"))))
      (should-error (nl-agent-bulk-reader-new (nl-agent-host-router-new registry)
                                               "local/model" '("local/model") directory :json-mode 'yes)))))

(ert-deftest nl-agent-bulk-reader-test-files-are-json-array-of-objects ()
  (let* ((messages (nl-agent-bulk-reader--messages
                    "q"
                    '((:path "a.txt" :sha256 "a" :line-count 2 :text "a")
                      (:path "b.txt" :sha256 "b" :line-count 3 :text "b"))))
         (user (cdr (assq 'user messages)))
         (json (substring user (string-match "Files (data JSON):\n" user)))
         (value (json-parse-string (substring json (length "Files (data JSON):\n"))
                                   :object-type 'alist :array-type 'array)))
    (should (vectorp value))
    (should (= (length value) 2))
    (should (equal (alist-get 'path (aref value 0)) "a.txt"))
    (should (equal (alist-get 'sha256 (aref value 1)) "b"))))

(ert-deftest nl-agent-bulk-reader-test-empty-output-is-named-not-a-parse-error ()
  "A provider that returns no content is reported as such.
Observed with qwen3:4b, whose reasoning consumed the whole output budget so the
message content came back empty; reporting that as a JSON parse failure hid the
cause.  The reader does not infer why the content is empty, because the
provider interface does not expose finish_reason."
  (nl-agent-bulk-reader-test--file "data\n"
    (let ((registry (nl-llm-agent-provider-registry-new)))
      (nl-llm-agent-provider-register
       registry
       (nl-llm-agent-provider-new "local" :models '((:id "model"))
                                  :open (lambda (_model _options) '(:state live))
                                  :complete (lambda (_state _messages) "   ")
                                  :close (lambda (_state) nil)))
      (let* ((router (nl-agent-host-router-new registry))
             (reader (nl-agent-bulk-reader-new router "local/model" '("local/model") directory))
             (result (nl-agent-bulk-reader-run reader "where?" '("sample.txt"))))
        (should (eq (plist-get result :status) 'failed))
        (should (eq (plist-get result :error-code) 'empty-provider-output))))))

(ert-deftest nl-agent-bulk-reader-test-malformed-output-keeps-the-generic-code ()
  "Content that is present but unparseable stays a generic failure.
This is the control for the test above: the new code must not swallow every
failure."
  (nl-agent-bulk-reader-test--file "data\n"
    (let ((registry (nl-llm-agent-provider-registry-new)))
      (nl-llm-agent-provider-register
       registry
       (nl-llm-agent-provider-new "local" :models '((:id "model"))
                                  :open (lambda (_model _options) '(:state live))
                                  :complete (lambda (_state _messages) "not json at all")
                                  :close (lambda (_state) nil)))
      (let* ((router (nl-agent-host-router-new registry))
             (reader (nl-agent-bulk-reader-new router "local/model" '("local/model") directory))
             (result (nl-agent-bulk-reader-run reader "where?" '("sample.txt"))))
        (should (eq (plist-get result :status) 'failed))
        (should (eq (plist-get result :error-code) 'bulk-reader-failure))))))

(ert-deftest nl-agent-bulk-reader-test-default-output-budget-fits-reasoning-models ()
  "The default worker budget is large enough for a model that thinks first.
qwen3:4b spent 1024 tokens on reasoning and emitted no answer; the same request
succeeded at 4096 with an answer of 38 completion tokens."
  (nl-agent-bulk-reader-test--file "data\n"
    (let* ((registry (nl-llm-agent-provider-registry-new))
           (_ (nl-llm-agent-provider-register
               registry
               (nl-llm-agent-provider-new "local" :models '((:id "model"))
                                          :open (lambda (_model _options) '(:state live))
                                          :complete (lambda (_state _messages) "{}")
                                          :close (lambda (_state) nil))))
           (router (nl-agent-host-router-new registry))
           (reader (nl-agent-bulk-reader-new router "local/model" '("local/model") directory)))
      (should (= 4096 (nl-agent-bulk-reader-max-tokens reader))))))

(ert-deftest nl-agent-bulk-reader-test-provider-failure-is-sanitized ()
  (nl-agent-bulk-reader-test--file "data\n"
    (let ((registry (nl-llm-agent-provider-registry-new)))
      (nl-llm-agent-provider-register
       registry
       (nl-llm-agent-provider-new "local" :models '((:id "model"))
                                  :open (lambda (_model _options) '(:state live))
                                  :complete (lambda (_state _messages) (error "secret provider detail"))
                                  :close (lambda (_state) nil)))
      (let* ((router (nl-agent-host-router-new registry))
             (reader (nl-agent-bulk-reader-new router "local/model" '("local/model") directory))
             (result (nl-agent-bulk-reader-run reader "where?" '("sample.txt"))))
        (should (eq (plist-get result :status) 'failed))
        (should-not (string-match-p "secret" (prin1-to-string result)))))))

;;; Reference repair.
;;
;; A worker that answers correctly and then pads its citation list used to lose
;; the whole result, so the main model paid for the worker and read the source
;; itself afterwards.  Unverifiable references are now dropped and counted
;; instead, with one rule that is not negotiable: if nothing survives, the
;; result still fails, because an answer with no verifiable citation is exactly
;; what this module exists to refuse.

(defconst nl-agent-bulk-reader-test--repair-sources
  '((:path "sample.txt"
     :sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
     :text "one\ntwo\nthree\n" :line-count 3)))

(defun nl-agent-bulk-reader-test--refs (&rest specs)
  "Build a references JSON array from SPECS, each (START . END)."
  (concat "["
          (mapconcat (lambda (spec)
                       (format "{\"path\":\"sample.txt\",\"start_line\":%d,\"end_line\":%d}"
                               (car spec) (cdr spec)))
                     specs ",")
          "]"))

(defun nl-agent-bulk-reader-test--validate (refs &optional not-found)
  (nl-agent-bulk-reader--validate-output
   nil (format "{\"answer\":\"x\",\"references\":%s,\"not_found\":%s}"
               refs (if not-found "true" "false"))
   nl-agent-bulk-reader-test--repair-sources))

(ert-deftest nl-agent-bulk-reader-test-repair-drops-unverifiable-reference ()
  (let* ((result (nl-agent-bulk-reader-test--validate
                  (nl-agent-bulk-reader-test--refs '(1 . 1) '(9 . 9))))
         (repair (plist-get result :reference-repair)))
    (should (equal "x" (plist-get result :answer)))
    (should (= 1 (length (plist-get result :references))))
    (should (equal "one" (plist-get (car (plist-get result :references)) :text)))
    (should (= 2 (plist-get repair :emitted)))
    (should (= 1 (plist-get repair :kept)))
    (should (memq 'out-of-range (plist-get repair :reasons)))))

(ert-deftest nl-agent-bulk-reader-test-repair-names-an-uncited-file ()
  ;; Citing a file that was never read is a different defect from citing a
  ;; line that does not exist, and the record says which it was.
  (let* ((result (nl-agent-bulk-reader--validate-output
                  nil
                  (concat "{\"answer\":\"x\",\"references\":["
                          "{\"path\":\"sample.txt\",\"start_line\":1,\"end_line\":1},"
                          "{\"path\":\"never-read.txt\",\"start_line\":1,\"end_line\":1}],"
                          "\"not_found\":false}")
                  nl-agent-bulk-reader-test--repair-sources))
         (repair (plist-get result :reference-repair)))
    (should (= 1 (length (plist-get result :references))))
    (should (equal '(unknown-path) (plist-get repair :reasons)))))

(ert-deftest nl-agent-bulk-reader-test-repair-drops-malformed-reference ()
  (let* ((result (nl-agent-bulk-reader--validate-output
                  nil
                  (concat "{\"answer\":\"x\",\"references\":["
                          "{\"path\":\"sample.txt\",\"start_line\":1,\"end_line\":1},"
                          "{\"path\":\"sample.txt\",\"start_line\":1,\"end_line\":1,\"extra\":1}],"
                          "\"not_found\":false}")
                  nl-agent-bulk-reader-test--repair-sources))
         (repair (plist-get result :reference-repair)))
    (should (= 1 (length (plist-get result :references))))
    (should (= 2 (plist-get repair :emitted)))
    (should (memq 'malformed (plist-get repair :reasons)))))

(ert-deftest nl-agent-bulk-reader-test-repair-truncates-overlong-list ()
  ;; The 8.5 KB live case: sixteen references, one of them real.  The old
  ;; length check rejected the result before looking at any of them.
  (let* ((specs (cons '(2 . 2) (make-list 15 '(40 . 47))))
         (result (apply #'nl-agent-bulk-reader-test--refs specs))
         (result (nl-agent-bulk-reader-test--validate result))
         (repair (plist-get result :reference-repair)))
    (should (= 1 (length (plist-get result :references))))
    (should (equal "two" (plist-get (car (plist-get result :references)) :text)))
    (should (= 16 (plist-get repair :emitted)))
    (should (= 1 (plist-get repair :kept)))))

(ert-deftest nl-agent-bulk-reader-test-repair-keeps-the-reference-limit ()
  ;; Ten citations that all verify, spread over five paths so the per-path cap
  ;; does not bind: the total limit still caps the list, but it now truncates
  ;; instead of discarding the answer along with it.
  (let* ((paths '("p1.txt" "p2.txt" "p3.txt" "p4.txt" "p5.txt"))
         (sources (mapcar (lambda (path)
                            (list :path path :sha256 (make-string 64 ?c)
                                  :text "y\ny\n" :line-count 2))
                          paths))
         (refs (concat "["
                       (mapconcat
                        (lambda (path)
                          (mapconcat
                           (lambda (n)
                             (format "{\"path\":\"%s\",\"start_line\":%d,\"end_line\":%d}"
                                     path n n))
                           '(1 2) ","))
                        paths ",")
                       "]"))
         (result (nl-agent-bulk-reader--validate-output
                  nil (format "{\"answer\":\"x\",\"references\":%s,\"not_found\":false}" refs)
                  sources))
         (repair (plist-get result :reference-repair)))
    (should (= nl-agent-bulk-reader-max-references
               (length (plist-get result :references))))
    (should (= 10 (plist-get repair :emitted)))
    (should (memq 'over-reference-limit (plist-get repair :reasons)))
    (should-not (memq 'over-path-limit (plist-get repair :reasons)))))

(ert-deftest nl-agent-bulk-reader-test-per-path-cap-trims-padding ()
  ;; Measured: a worker that answers well cites one span, and on the one
  ;; question written to need two facts all three workers still cited one span
  ;; containing both.  References beyond a couple per path are padding, and
  ;; padding is what the main model pays to read.
  (let* ((sources (list (list :path "many.txt" :sha256 (make-string 64 ?c)
                              :text (mapconcat #'identity (make-list 12 "y") "\n")
                              :line-count 12)))
         (refs (concat "["
                       (mapconcat (lambda (n)
                                    (format "{\"path\":\"many.txt\",\"start_line\":%d,\"end_line\":%d}"
                                            n n))
                                  (number-sequence 1 6) ",")
                       "]"))
         (result (nl-agent-bulk-reader--validate-output
                  nil (format "{\"answer\":\"x\",\"references\":%s,\"not_found\":false}" refs)
                  sources))
         (repair (plist-get result :reference-repair)))
    (should (= nl-agent-bulk-reader-max-references-per-path
               (length (plist-get result :references))))
    (should (= 6 (plist-get repair :emitted)))
    (should (memq 'over-path-limit (plist-get repair :reasons)))
    ;; The spans kept are the first ones, not an arbitrary subset.
    (should (equal '(1 2) (mapcar (lambda (r) (plist-get r :start-line))
                                  (plist-get result :references))))))

(ert-deftest nl-agent-bulk-reader-test-per-path-cap-keeps-every-path ()
  ;; The cap is per path precisely so that it cannot break coverage: dropping
  ;; a whole path turns an accepted multi-file answer into a rejected one.
  (let* ((sources (list (list :path "a.txt" :sha256 (make-string 64 ?a)
                              :text "1\n2\n3\n4\n" :line-count 4)
                        (list :path "b.txt" :sha256 (make-string 64 ?b)
                              :text "1\n2\n3\n4\n" :line-count 4)))
         (refs (concat "["
                       (mapconcat
                        (lambda (spec)
                          (format "{\"path\":\"%s\",\"start_line\":%d,\"end_line\":%d}"
                                  (car spec) (cdr spec) (cdr spec)))
                        '(("a.txt" . 1) ("a.txt" . 2) ("a.txt" . 3)
                          ("b.txt" . 1) ("b.txt" . 2) ("b.txt" . 3))
                        ",")
                       "]"))
         (result (nl-agent-bulk-reader--validate-output
                  nil (format "{\"answer\":\"x\",\"references\":%s,\"not_found\":false}" refs)
                  sources))
         (kept (plist-get result :references)))
    (should (= 4 (length kept)))
    (should (equal '("a.txt" "b.txt")
                   (sort (delete-dups (mapcar (lambda (r) (plist-get r :path)) kept))
                         #'string<)))))

(ert-deftest nl-agent-bulk-reader-test-span-covering-the-file-is-dropped ()
  ;; Measured: one worker cited lines 1-72 of a 72-line file.  The reference
  ;; verifies, it is a single reference so no per-path cap binds, and 72 is
  ;; under the 80-line budget — yet the delegated prompt came out at 109% of
  ;; the direct one.  A citation covering its source points at nothing.
  (let* ((sources (list (list :path "big.txt" :sha256 (make-string 64 ?d)
                              :text (mapconcat #'identity (make-list 72 "y") "\n")
                              :line-count 72)))
         (refs (concat "[{\"path\":\"big.txt\",\"start_line\":1,\"end_line\":72},"
                       "{\"path\":\"big.txt\",\"start_line\":58,\"end_line\":59}]"))
         (result (nl-agent-bulk-reader--validate-output
                  nil (format "{\"answer\":\"x\",\"references\":%s,\"not_found\":false}" refs)
                  sources))
         (repair (plist-get result :reference-repair)))
    (should (= 1 (length (plist-get result :references))))
    (should (= 58 (plist-get (car (plist-get result :references)) :start-line)))
    (should (memq 'over-span-fraction (plist-get repair :reasons)))))

(ert-deftest nl-agent-bulk-reader-test-span-covering-the-file-alone-fails ()
  ;; A worker whose only citation is the whole file has said the answer is in
  ;; there somewhere.  Failing costs a fallback; accepting costs the same read
  ;; plus the worker.
  (let ((sources (list (list :path "big.txt" :sha256 (make-string 64 ?d)
                             :text (mapconcat #'identity (make-list 72 "y") "\n")
                             :line-count 72))))
    (should-error
     (nl-agent-bulk-reader--validate-output
      nil (concat "{\"answer\":\"x\",\"references\":"
                  "[{\"path\":\"big.txt\",\"start_line\":1,\"end_line\":72}],"
                  "\"not_found\":false}")
      sources))))

(ert-deftest nl-agent-bulk-reader-test-span-fraction-boundary ()
  ;; Half the file is kept, one line more is not.  The widest span any worker
  ;; produced legitimately covered 14% of its source, so the boundary sits far
  ;; from anything observed and the exact value is not load-bearing.
  (let ((sources (list (list :path "big.txt" :sha256 (make-string 64 ?d)
                             :text (mapconcat #'identity (make-list 40 "y") "\n")
                             :line-count 40))))
    (cl-flet ((kept (end)
                (length (plist-get
                         (nl-agent-bulk-reader--validate-output
                          nil (format (concat "{\"answer\":\"x\",\"references\":"
                                              "[{\"path\":\"big.txt\",\"start_line\":1,"
                                              "\"end_line\":%d}],\"not_found\":false}")
                                      end)
                          sources)
                         :references))))
      (should (= 1 (kept 20)))
      (should-error (kept 21))))
  ;; And the floor: half of a short file is a couple of lines, which is what a
  ;; normal answer cites, so the fraction must not bite there.
  (let ((sources (list (list :path "tiny.txt" :sha256 (make-string 64 ?e)
                             :text "one\ntwo\nthree\n" :line-count 3))))
    (should (= 1 (length (plist-get
                          (nl-agent-bulk-reader--validate-output
                           nil (concat "{\"answer\":\"x\",\"references\":"
                                       "[{\"path\":\"tiny.txt\",\"start_line\":1,"
                                       "\"end_line\":2}],\"not_found\":false}")
                           sources)
                          :references))))))

(ert-deftest nl-agent-bulk-reader-test-repair-refuses-when-nothing-survives ()
  ;; Every citation invented and the answer claims to have found something:
  ;; repairing this into a success would convert a fabrication into a result.
  (should-error (nl-agent-bulk-reader-test--validate
                 (nl-agent-bulk-reader-test--refs '(7 . 8) '(9 . 9))))
  ;; A not_found answer legitimately carries no references, and the repair
  ;; must not turn that into a failure either.
  (should (equal "x" (plist-get (nl-agent-bulk-reader-test--validate "[]" t) :answer))))

(ert-deftest nl-agent-bulk-reader-test-repair-absent-when-nothing-dropped ()
  ;; The repair record travels to the main model inside the serialized result,
  ;; so a clean worker must not pay bytes for it.
  (let ((result (nl-agent-bulk-reader-test--validate
                 (nl-agent-bulk-reader-test--refs '(1 . 2)))))
    (should (= 1 (length (plist-get result :references))))
    (should-not (plist-member result :reference-repair))))

(ert-deftest nl-agent-bulk-reader-test-repair-stops-at-quoted-line-budget ()
  ;; The budget used to abort the whole result partway through the list.
  (let* ((sources (list (list :path "big.txt"
                              :sha256 (make-string 64 ?b)
                              :text (mapconcat #'identity (make-list 200 "x") "\n")
                              :line-count 200)))
         (refs (concat "[{\"path\":\"big.txt\",\"start_line\":1,\"end_line\":60},"
                       "{\"path\":\"big.txt\",\"start_line\":61,\"end_line\":140}]"))
         (result (nl-agent-bulk-reader--validate-output
                  nil (format "{\"answer\":\"x\",\"references\":%s,\"not_found\":false}" refs)
                  sources))
         (repair (plist-get result :reference-repair)))
    (should (= 1 (length (plist-get result :references))))
    (should (memq 'over-quoted-lines (plist-get repair :reasons)))))

;;; bulk-reader-test.el ends here

(when noninteractive
  (ert-run-tests-batch-and-exit))
