;;; recurrent-config-test.el --- recurrent JSON manifest tests -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'nl-llm-recur)
(require 'nl-llm-agent-recur-artifact)
(require 'nl-llm-agent-provider)

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                          (file-name-directory (or load-file-name buffer-file-name
                                                   default-directory))) nil t)
)
(require 'nl-agent-recurrent-config)

(defvar nl-agent-recurrent-config-test-marker nil)

(defun nl-agent-recurrent-config-test--model ()
  "Build the tiny real recurrent model used by the valid-manifest test."
  (nl-llm-recur-model-new
   :vocab 256 :dim 4 :heads 1 :kv-heads 1 :ff 8
   :n-prelude 1 :n-core 1 :n-coda 1 :seed 31 :sigma 0.2))

(defun nl-agent-recurrent-config-test--write (path text)
  "Write UTF-8 TEXT to PATH without invoking a Lisp reader."
  (with-temp-file path
    (insert text)
    (set-buffer-file-coding-system 'utf-8-unix)))

(defun nl-agent-recurrent-config-test--manifest (digest &optional path)
  "Return a valid JSON manifest using DIGEST and relative PATH."
  (format
   "{\"format\":\"nl-agent-recurrent-config-v1\",\"id\":\"recurrent-test\",\"name\":\"日本語\",\"models\":[{\"id\":\"tiny\",\"path\":\"%s\",\"sha256\":\"%s\",\"name\":\"小型\",\"maxseq\":32,\"grammar\":{\"type\":\"done\",\"length\":1,\"allow\":\"a\"}}]}"
   (or path "artifact.sexp") digest))

(defun nl-agent-recurrent-config-test--with-fixture (function)
  "Call FUNCTION with a valid manifest, artifact, and temporary directory."
  (let* ((directory (make-temp-file "recurrent-config-" t))
         (artifact (expand-file-name "artifact.sexp" directory))
         (manifest (expand-file-name "config.json" directory))
         (saved (nl-llm-agent-recur-artifact-save
                 artifact (nl-agent-recurrent-config-test--model)
                 :tokenizer "utf8-byte-v1" :r 2 :s0-seed 7 :step 0)))
    (unwind-protect
        (progn
          (nl-agent-recurrent-config-test--write
           manifest
           (nl-agent-recurrent-config-test--manifest
            (plist-get saved :sha256)))
          (funcall function directory manifest artifact saved))
      (delete-directory directory t))))

(defun nl-agent-recurrent-config-test--invalid (text)
  "Write invalid JSON TEXT to a private file and assert loader failure."
  (let* ((directory (make-temp-file "recurrent-config-invalid-" t))
         (path (expand-file-name "bad.json" directory)))
    (unwind-protect
        (progn
          (nl-agent-recurrent-config-test--write path text)
          (should-error (nl-agent-recurrent-config-load path)))
      (delete-directory directory t))))

(ert-deftest nl-agent-recurrent-config-validates-unicode-and-defers-artifact-load ()
  (nl-agent-recurrent-config-test--with-fixture
   (lambda (_directory manifest _artifact saved)
     (let ((loads 0)
           (original (symbol-function 'nl-llm-agent-recur-artifact-load)))
       (cl-letf (((symbol-function 'nl-llm-agent-recur-artifact-load)
                  (lambda (path digest)
                    (setq loads (1+ loads))
                    (funcall original path digest))))
         (let* ((provider (nl-agent-recurrent-config-load manifest))
                (registry (nl-llm-agent-provider-registry-new)))
           (nl-llm-agent-provider-register registry provider)
           (should (= loads 0))
           (let* ((public (car (nl-llm-agent-provider-models registry)))
                (session
                 (nl-llm-agent-session-open registry "recurrent-test/tiny")))
             (unwind-protect
                 (progn
                   (should (nl-llm-agent-provider-p provider))
                   (should (= loads 1))
                   (should (equal (plist-get public :id) "tiny"))
                   (should (equal (plist-get public :name) "小型"))
                   (should (equal (plist-get public :maxseq) 32))
                   (should (equal (plist-get
                                   (nl-llm-agent-session-backend-state session)
                                   :artifact-id)
                                  "tiny"))
                   (should (equal (plist-get saved :sha256)
                                  (plist-get (plist-get
                                              (nl-llm-agent-session-backend-state
                                               session)
                                              :bundle)
                                             :sha256)))
                   ;; Opening is the first artifact load; the returned
                   ;; provider is usable for an actual recurrent completion.
                   (should (equal
                            (nl-llm-agent-session-complete
                             session '((user . "hello")))
                            "DONE a")))
               (nl-llm-agent-session-close session)))))))))

(ert-deftest nl-agent-recurrent-config-allows-omitted-optional-names ()
  (let* ((directory (make-temp-file "recurrent-config-names-" t))
         (manifest (expand-file-name "config.json" directory))
         (digest (make-string 64 ?a))
         (text (nl-agent-recurrent-config-test--manifest digest)))
    (unwind-protect
        (progn
          (setq text
                (replace-regexp-in-string
                 (regexp-quote ",\"name\":\"日本語\"") "" text))
          (setq text
                (replace-regexp-in-string
                 (regexp-quote ",\"name\":\"小型\"") "" text))
          (nl-agent-recurrent-config-test--write manifest text)
          (let* ((provider (nl-agent-recurrent-config-load manifest))
                 (registry (nl-llm-agent-provider-registry-new)))
            (nl-llm-agent-provider-register registry provider)
            (should (equal
                     (plist-get (car (nl-llm-agent-provider-models registry))
                                :name)
                     "tiny"))))
      (delete-directory directory t))))

(ert-deftest nl-agent-recurrent-config-rejects-unknown-duplicate-and-null-fields ()
  (dolist
      (text
       (list
        "[]"
        "{\"format\":\"nl-agent-recurrent-config-v1\",\"id\":\"x\",\"models\":null}"
        "{\"format\":\"nl-agent-recurrent-config-v1\",\"id\":\"x\",\"models\":[]}"
        "{\"format\":\"nl-agent-recurrent-config-v1\",\"id\":\"x\",\"extra\":1,\"models\":[{\"id\":\"a\",\"path\":\"a\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"grammar\":{\"type\":\"done\",\"length\":1,\"allow\":\"a\"}}]}"
        "{\"format\":\"nl-agent-recurrent-config-v1\",\"id\":\"x\",\"id\":\"y\",\"models\":[{\"id\":\"a\",\"path\":\"a\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"grammar\":{\"type\":\"done\",\"length\":1,\"allow\":\"a\"}}]}"
        "{\"format\":\"nl-agent-recurrent-config-v1\",\"id\":\"x\",\"models\":[{\"id\":\"a\",\"path\":\"a\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"grammar\":{\"type\":\"done\",\"length\":1,\"allow\":\"a\"}},{\"id\":\"a\",\"path\":\"b\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"grammar\":{\"type\":\"done\",\"length\":1,\"allow\":\"a\"}}]}"
        "{\"format\":\"nl-agent-recurrent-config-v1\",\"id\":\"x\",\"models\":[{\"id\":\"a\",\"path\":\"a\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"grammar\":{\"type\":\"done\",\"length\":1,\"allow\":\"a\",\"allow\":\"b\"}}]}"
        "{\"format\":\"nl-agent-recurrent-config-v1\",\"id\":\"x\",\"models\":[{\"id\":\"a\",\"path\":\"a\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"grammar\":null}]}"
        "{\"format\":\"nl-agent-recurrent-config-v1\",\"id\":\"x\",\"models\":[{\"id\":\"a\",\"path\":\"../outside\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"grammar\":{\"type\":\"done\",\"length\":1,\"allow\":\"a\"}}] }"))
    (nl-agent-recurrent-config-test--invalid text)))

(ert-deftest nl-agent-recurrent-config-rejects-unsafe-paths-and-model-bounds ()
  (let* ((directory (make-temp-file "recurrent-config-path-" t))
         (manifest (expand-file-name "config.json" directory))
         (digest (make-string 64 ?a)))
    (unwind-protect
        (progn
          (nl-agent-recurrent-config-test--write
           manifest (nl-agent-recurrent-config-test--manifest digest "../x"))
          (should-error (nl-agent-recurrent-config-load manifest))
          (nl-agent-recurrent-config-test--write
           manifest (nl-agent-recurrent-config-test--manifest digest "/tmp/x"))
          (should-error (nl-agent-recurrent-config-load manifest))
          (nl-agent-recurrent-config-test--write
           manifest (nl-agent-recurrent-config-test--manifest
                     (make-string 64 ?A)))
          (should-error (nl-agent-recurrent-config-load manifest))
          (nl-agent-recurrent-config-test--write
           manifest
           (replace-regexp-in-string
            (regexp-quote "\"maxseq\":32") "\"maxseq\":4097"
            (nl-agent-recurrent-config-test--manifest digest)))
          (should-error (nl-agent-recurrent-config-load manifest))
          (nl-agent-recurrent-config-test--write
           manifest
           (replace-regexp-in-string
            (regexp-quote "\"id\":\"recurrent-test\"")
            "\"id\":\"bad/id\""
            (nl-agent-recurrent-config-test--manifest digest)))
          (should-error (nl-agent-recurrent-config-load manifest)))
      (delete-directory directory t))))

(ert-deftest nl-agent-recurrent-config-rejects-remote-before-filesystem-access ()
  (let ((attributes-calls 0) (truename-calls 0)
        (original-attributes (symbol-function 'file-attributes))
        (original-truename (symbol-function 'file-truename)))
    (cl-letf (((symbol-function 'file-attributes)
               (lambda (&rest arguments)
                 (setq attributes-calls (1+ attributes-calls))
                 (apply original-attributes arguments)))
              ((symbol-function 'file-truename)
               (lambda (&rest arguments)
                 (setq truename-calls (1+ truename-calls))
                 (apply original-truename arguments))))
      (should-error
       (nl-agent-recurrent-config-load "/ssh:unreachable:/tmp/config.json"))
      (should (= attributes-calls 0))
      (should (= truename-calls 0))
      ;; A local control reaches the filesystem checks; the remote rejection
      ;; above must happen before either one.
      (let* ((directory (make-temp-file "recurrent-config-local-" t))
             (path (expand-file-name "config.json" directory)))
        (unwind-protect
            (progn
              (nl-agent-recurrent-config-test--write path "{}")
              (should-error (nl-agent-recurrent-config-load path))
              (should (> attributes-calls 0)))
          (delete-directory directory t))))))

(ert-deftest nl-agent-recurrent-config-rejects-more-than-128-models ()
  (let* ((directory (make-temp-file "recurrent-config-many-models-" t))
         (manifest (expand-file-name "config.json" directory))
         (models (mapconcat (lambda (index)
                              (format "{\"id\":\"m%d\",\"path\":\"a\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"grammar\":{\"type\":\"done\",\"length\":1,\"allow\":\"a\"}}"
                                      index))
                            (number-sequence 1 129) ",")))
    (unwind-protect
        (progn
          (nl-agent-recurrent-config-test--write
           manifest
           (format "{\"format\":\"nl-agent-recurrent-config-v1\",\"id\":\"x\",\"models\":[%s]}"
                   models))
          (should-error (nl-agent-recurrent-config-load manifest)))
      (delete-directory directory t))))

(ert-deftest nl-agent-recurrent-config-rejects-symlink-escape-and-preserves-no-code-execution ()
  (let* ((directory (make-temp-file "recurrent-config-symlink-" t))
         (outside (make-temp-file "recurrent-config-outside-"))
         (manifest (expand-file-name "config.json" directory))
         (link (expand-file-name "escape.sexp" directory))
         (digest (make-string 64 ?a)))
    (unwind-protect
        (progn
          (condition-case nil
              (make-symbolic-link outside link)
            (file-error (ert-skip "symbolic links unavailable")))
          (nl-agent-recurrent-config-test--write
           manifest (nl-agent-recurrent-config-test--manifest digest "escape.sexp"))
          (should-error (nl-agent-recurrent-config-load manifest))
          (nl-agent-recurrent-config-test--write
           manifest
           (replace-regexp-in-string
            (regexp-quote "日本語")
            "#.(setq nl-agent-recurrent-config-test-marker t)"
            (nl-agent-recurrent-config-test--manifest digest "a")))
          (setq nl-agent-recurrent-config-test-marker nil)
          (should (nl-agent-recurrent-config-load manifest))
          (should-not nl-agent-recurrent-config-test-marker))
      (when (file-exists-p link) (delete-file link))
      (when (file-exists-p outside) (delete-file outside))
      (delete-directory directory t))))

(ert-deftest nl-agent-recurrent-config-rejects-size-and-trailing-data-before-assembly ()
  (let* ((directory (make-temp-file "recurrent-config-size-" t))
         (path (expand-file-name "config.json" directory))
         (valid (nl-agent-recurrent-config-test--manifest
                 (make-string 64 ?a))))
    (unwind-protect
        (progn
          (nl-agent-recurrent-config-test--write
           path (concat valid " {}"))
          (should-error (nl-agent-recurrent-config-load path))
          (nl-agent-recurrent-config-test--write
           path (make-string (1+ nl-agent-recurrent-config-max-bytes) ?x))
          (let ((parsed nil))
            (cl-letf (((symbol-function 'json-parse-buffer)
                       (lambda (&rest _)
                         (setq parsed t)
                         nil)))
              (should-error (nl-agent-recurrent-config-load path)))
            (should-not parsed)))
      (delete-directory directory t))))

(ert-run-tests-batch-and-exit)

;;; recurrent-config-test.el ends here
