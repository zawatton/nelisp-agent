;;; bench-stdio-encoding.el --- measure stdio response encoding stages -*- lexical-binding: t; -*-

;; Run from the nelisp-agent checkout with either substrate:
;;
;;   emacs -Q --batch -l examples/bench-stdio-encoding.el
;;   NELISP_BIN=../nelisp/target/nelisp
;;   "$NELISP_BIN" --load examples/bench-stdio-encoding.el
;;
;; To retain standalone output with the binary identity, run from the sibling
;; nelisp checkout:
;;
;;   NELISP_BIN=target/nelisp tools/ai/nelisp-ai.sh probe \
;;     '(load "../nelisp-agent/examples/bench-stdio-encoding.el")'
;;
;; The synthetic form resembles an agent-run response and serializes to about
;; 12 KiB.  Its strings deliberately include non-ASCII text, quotes, literal
;; newlines, carriage returns, and backslashes.  Only compact measurements are
;; printed; the response payload itself never goes to stdout.

;;; Code:

(eval-and-compile
  (let ((source-directory
         (file-name-directory
          (or load-file-name buffer-file-name
              (and (boundp 'byte-compile-current-file)
                   (symbol-value 'byte-compile-current-file))))))
    (add-to-list 'load-path (expand-file-name "../lisp" source-directory))))

(require 'nl-agent-wire)

(defconst nelisp-agent-bench-stdio-encoding-format
  "nelisp-agent-stdio-encoding-v2")

(defun nelisp-agent-bench-stdio-encoding--form ()
  "Return a deterministic realistic synthetic agent response."
  (let ((system
         (concat
          "You are a file-editing agent. Preserve exact evidence, \"quotes\",\n"
          "newlines, and paths such as src\\module\\file.el.\r\n"
          (make-string 5900 ?S)))
        (observation
         (concat
          "OBSERVATION:\n検証済みの内容です。\n"
          "escaped path: test\\fixtures\\unicode.txt\r\n"
          (make-string 2850 ?O)))
        (assistant
         (concat
          "task.txt\n<<<<<<< SEARCH\n古い値\n=======\n新しい値\n"
          ">>>>>>> REPLACE\n\"quoted explanation\" \\ done")))
    (list
     :kind 'agent-run :status 'done :steps 3 :result "学習完了"
     :messages
     (list (cons 'system system)
           (cons 'user "TASK: 日本語fixtureを正確に更新してください。")
           (cons 'assistant assistant)
           (cons 'user observation)
           (cons 'assistant "DONE 学習完了"))
     :trajectory
     (list
      (list :step 1 :model "native/unicode-g1" :assistant assistant
            :action '(edit "task.txt" "古い値" "新しい値")
            :observation observation)
      (list :step 2 :model "native/unicode-g1"
            :assistant "DONE 学習完了"
            :action '(done "学習完了"))))))

(defun nelisp-agent-bench-stdio-encoding-main ()
  "Measure legacy encoding stages and the public wire framing path."
  (let* ((form (nelisp-agent-bench-stdio-encoding--form))
         (started (float-time))
         (serialized (prin1-to-string form))
         (serialized-at (float-time))
         (lf-escaped (string-replace "\n" "\\n" serialized))
         (lf-at (float-time))
         (cr-escaped (string-replace "\r" "\\r" lf-escaped))
         (cr-at (float-time))
         ;; Measure the public replacement independently.  It includes its own
         ;; printer pass; do not derive it by subtracting legacy stages.
         (wire-started (float-time))
         (wire-framed (nl-agent-wire-frame form))
         (wire-at (float-time)))
    (unless (equal wire-framed cr-escaped)
      (error "nl-agent-wire-frame differs from legacy framing"))
    (let ((measurement
          (list
           :format nelisp-agent-bench-stdio-encoding-format
           :serialized-chars (length serialized)
           :framed-chars (length cr-escaped)
           :prin1-seconds (- serialized-at started)
           :newline-replace-seconds (- lf-at serialized-at)
           :carriage-return-replace-seconds (- cr-at lf-at)
           :total-seconds (- cr-at started)
           :wire-frame-seconds (- wire-at wire-started)
           :exact-legacy-frame t
           :remaining-newlines
           (if (string-match-p "\n" cr-escaped) t nil)
           :remaining-carriage-returns
           (if (string-match-p "\r" cr-escaped) t nil))))
      (princ "BENCH-STDIO-ENCODING ")
      (prin1 measurement)
      (terpri)
      measurement)))

(provide 'bench-stdio-encoding)

(nelisp-agent-bench-stdio-encoding-main)

;;; bench-stdio-encoding.el ends here
