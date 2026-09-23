;;; wire-framing-test.el --- cross-substrate wire framing corpus -*- lexical-binding: t; -*-
;; emacs -Q --batch -L lisp -l test/wire-framing-test.el
;; ../nelisp/target/nelisp --load test/wire-framing-test.el

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-wire)

(defvar read-eval)
(defvar nl-agent-wire-framing-test--fail 0)

(defun nl-agent-wire-framing-test--ck (name ok &optional extra)
  (princ
   (format "%-64s %s  %s\n" name
           (if ok "PASS"
             (setq nl-agent-wire-framing-test--fail
                   (1+ nl-agent-wire-framing-test--fail))
             "FAIL")
           (or extra ""))))

(defun nl-agent-wire-framing-test--legacy (form)
  "Return the existing inline wire representation of FORM."
  (string-replace
   "\r" "\\r"
   (string-replace "\n" "\\n" (prin1-to-string form))))

(defun nl-agent-wire-framing-test--read (line)
  "Read exactly one data form from LINE with evaluation disabled."
  (let* ((read-eval nil)
         (parsed (read-from-string line)))
    (unless (= (cdr parsed) (length line))
      (error "wire frame contains trailing data"))
    parsed))

(let* ((actual-lines "actual LF:\nactual CR:\ractual CRLF:\r\n")
       (literal-lines "literal \\n and \\r and \\r\\n")
       (corpus
        (list nil t 'alpha :keyword 'done
              "" "plain ASCII"
              "日本語と補助平面🙂����"
              "quote: \" backslash: \\"
              literal-lines actual-lines
              (vector "vector" 7 :ok '(dotted . pair))
              '(left . right)
              (list :nested
                    (vector
                     (concat (make-string 255 ?界)
                             "\n🙂\r"
                             (make-string 17 ?終))))
              (list :tab "\t" :nul (string 0)
                    :controls (string 1 8 11 12 31 127))
              (list :safe-data "#.(setq wire-framing-side-effect t)"))))
  (let ((case-index 0))
    (dolist (form corpus)
      (setq case-index (1+ case-index))
      (let* ((legacy (nl-agent-wire-framing-test--legacy form))
             (framed (nl-agent-wire-frame form))
             (legacy-read (nl-agent-wire-framing-test--read legacy))
             (framed-read (nl-agent-wire-framing-test--read framed)))
        (nl-agent-wire-framing-test--ck
         (format "corpus %02d legacy parity" case-index)
         (equal framed legacy))
        (nl-agent-wire-framing-test--ck
         (format "corpus %02d single physical line" case-index)
         (not (string-match-p "[\r\n]" framed)))
        ;; The corpus contains only forms supported by both existing printers.
        ;; Every frame parses as exactly one form with identical data/no eval.
        (nl-agent-wire-framing-test--ck
         (format "corpus %02d data-only round trip" case-index)
         (and (consp legacy-read)
              (consp framed-read)
              (equal (car legacy-read) form)
              (equal (car framed-read) form)))))
  (nl-agent-wire-framing-test--ck
   "literal backslash escapes remain distinct from actual line endings"
   (not (equal (nl-agent-wire-frame literal-lines)
               (nl-agent-wire-frame actual-lines))))))

(let ((print-length 2)
      (form '(one two three four)))
  (nl-agent-wire-framing-test--ck
   "dynamic printer settings retain exact legacy behavior"
   (equal (nl-agent-wire-frame form)
          (nl-agent-wire-framing-test--legacy form))))

(let* ((print-length nil)
       (print-level nil)
       (long (make-string 12000 ?x))
       (expected (concat "\"" long "\""))
       (framed (nl-agent-wire-frame long)))
  (nl-agent-wire-framing-test--ck
   "12K string has an independently authored untruncated frame"
   (and (= (length framed) 12002)
        (equal framed expected))))

(let (before after)
  (string-match "\\(b\\)" "abc")
  (setq before (match-data t))
  (nl-agent-wire-frame '(:text "a\nb\r"))
  (setq after (match-data t))
  (nl-agent-wire-framing-test--ck
   "wire framing preserves caller match data"
   (equal after before)))

(princ
 (format "NL-AGENT-WIRE-FRAMING %s (%d failures)\n"
         (if (= nl-agent-wire-framing-test--fail 0)
             "ALL-PASS"
           "HAS-FAILURES")
         nl-agent-wire-framing-test--fail))
(kill-emacs (if (= nl-agent-wire-framing-test--fail 0) 0 1))

;;; wire-framing-test.el ends here
