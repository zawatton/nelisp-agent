;;; nl-agent-wire.el --- chunked one-line wire framing  -*- lexical-binding: t; -*-

;; The protocol serializes with the caller's ambient printer settings, then
;; escapes literal line breaks emitted inside strings.  Scan characters
;; directly and join once so large responses do not repeatedly copy an
;; ever-growing prefix or pay regular-expression matching overhead.

;;; Code:

;;;###autoload
(defun nl-agent-wire-frame (form)
  "Serialize FORM and escape literal CR/LF characters for one-line framing."
  (let* ((serialized (prin1-to-string form))
         (size (length serialized))
         (start 0)
         (index 0)
         chunks)
    (while (< index size)
      (let ((character (aref serialized index)))
        (when (or (= character 13) (= character 10))
          (push (substring serialized start index) chunks)
          (push (if (= character 13) "\\r" "\\n") chunks)
          (setq start (1+ index))))
      (setq index (1+ index)))
    (if chunks
        (progn
          (push (substring serialized start) chunks)
          (apply #'concat (nreverse chunks)))
      serialized)))

(provide 'nl-agent-wire)
;;; nl-agent-wire.el ends here
