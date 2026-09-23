;;; bulk-policy-calibration.el --- emit rival-screen fires -*- lexical-binding: t; -*-

;;; Commentary:

;; This is the deterministic evaluator used by calibrate-bulk-policy.sh.
;; Each corpus case is screened with its own known-correct stub answer.

;;; Code:

(require 'cl-lib)

(defconst nl-agent-bulk-calibration--corpora
  '("bulk-reader-corpus.sexp" "bulk-policy-corpus.sexp"
    "bulk-excluded-corpus.sexp" "bulk-dense-corpus.sexp"
    "bulk-table-corpus.sexp" "bulk-en-corpus.sexp"
    "bulk-nonnumeric-corpus.sexp" "bulk-sizes-corpus.sexp"
    "bulk-spread-corpus.sexp"))

(defun nl-agent-bulk-calibration--sources (reader paths)
  "Return source plists read by READER for PATHS."
  (mapcar (lambda (source)
            (list :path (plist-get source :path)
                  :text (plist-get source :text)))
          (nl-agent-bulk-reader-sources reader paths)))

(let* ((root (file-name-as-directory
              (or (getenv "NL_AGENT_CALIBRATION_ROOT")
                  (error "NL_AGENT_CALIBRATION_ROOT is required"))))
       (default-directory root))
  (load (expand-file-name "examples/evaluate-bulk-reader.el" root) nil t)
  (require 'nl-agent-bulk-policy)
  (let* ((source-root (expand-file-name "examples/bulk-reader-corpus" root))
         (router
          (nl-agent-host-router-new
           (list (nl-llm-agent-provider-new
                  "stub" :models '("worker")
                  :open (lambda (&rest _) nil)
                  :complete (lambda (&rest _) "")
                  :close (lambda (&rest _) nil)))))
         (reader (nl-agent-bulk-reader-new
                  router "stub/worker" '("stub/worker") source-root))
         (total 0)
         (fired 0))
    (dolist (name nl-agent-bulk-calibration--corpora)
      (let ((corpus
             (nl-agent-example-bulk-eval-load-corpus
              (expand-file-name (concat "examples/" name) root))))
        (dolist (case (plist-get corpus :cases))
          (setq total (1+ total))
          (let* ((answer (nl-agent-example-bulk-eval--stub-answer case))
                 (sources (nl-agent-bulk-calibration--sources
                           reader (plist-get case :paths)))
                 (rivals (nl-agent-bulk-policy--unreported-rivals
                          answer sources)))
            (when rivals
              (setq fired (1+ fired))
              (princ (string-remove-suffix
                      ".sexp" (string-remove-prefix "bulk-" name)))
              (princ "\t")
              (princ (plist-get case :id))
              (princ "\t")
              (prin1 (mapcar (lambda (rival)
                               (list (nth 0 rival) (nth 1 rival) (nth 3 rival)))
                             rivals))
              (terpri))))))
    (princ (format "@summary\t%d\t%d\n" total fired))))

;;; bulk-policy-calibration.el ends here
