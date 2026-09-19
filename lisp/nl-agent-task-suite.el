;;; nl-agent-task-suite.el --- representative local edit tasks  -*- lexical-binding: t; -*-

;; These fixtures measure exact local file-edit outcomes.  Expected contents
;; remain on the host side and are never placed in an evaluated workspace.

;;; Code:

(defconst nl-agent-task-suite--representative
  '(:id "representative-local-edits"
    :version "1"
    :cases
    [(:id "japanese-doc-typo"
      :task "docs/guide.md の `make strat` だけを `make start` に修正してください。docs/changelog.md は変更しないでください。"
      :files [(:path "docs/guide.md"
               :text "# 起動方法\n\n`make strat` を実行します。\n")
              (:path "docs/changelog.md"
               :text "# 変更履歴\n\n既知の変更はありません。\n")]
      :expected [(:path "docs/guide.md"
                  :text "# 起動方法\n\n`make start` を実行します。\n")
                 (:path "docs/changelog.md"
                  :text "# 変更履歴\n\n既知の変更はありません。\n")])
     (:id "elisp-arithmetic-bug"
      :task "lisp/math.el の double が引数を 2 倍するよう、式 `(+ n 2)` だけを `(* n 2)` に修正してください。README.md は変更しないでください。"
      :files [(:path "lisp/math.el"
               :text ";;; math.el --- tiny arithmetic helper -*- lexical-binding: t; -*-\n\n(defun double (n)\n  (+ n 2))\n")
              (:path "README.md"
               :text "double は数値を 2 倍します。\n")]
      :expected [(:path "lisp/math.el"
                  :text ";;; math.el --- tiny arithmetic helper -*- lexical-binding: t; -*-\n\n(defun double (n)\n  (* n 2))\n")
                 (:path "README.md"
                  :text "double は数値を 2 倍します。\n")])
     (:id "coordinated-function-rename"
      :task "公開関数 old-greeting を current-greeting に改名し、lisp/greet.el の定義と test/greet-test.el の呼び出しを両方更新してください。それ以外は変更しないでください。"
      :files [(:path "lisp/greet.el"
               :text ";;; greet.el -*- lexical-binding: t; -*-\n\n(defun old-greeting (name)\n  (format \"Hello, %s\" name))\n")
              (:path "test/greet-test.el"
               :text ";;; greet-test.el -*- lexical-binding: t; -*-\n\n(ert-deftest greeting-works ()\n  (should (equal (old-greeting \"Ada\") \"Hello, Ada\")))\n")]
      :expected [(:path "lisp/greet.el"
                  :text ";;; greet.el -*- lexical-binding: t; -*-\n\n(defun current-greeting (name)\n  (format \"Hello, %s\" name))\n")
                 (:path "test/greet-test.el"
                  :text ";;; greet-test.el -*- lexical-binding: t; -*-\n\n(ert-deftest greeting-works ()\n  (should (equal (current-greeting \"Ada\") \"Hello, Ada\")))\n")])
     (:id "json-config-value"
      :task "config/app.json の retryCount を 2 から 3 に変更してください。timeoutSeconds と feature は変更しないでください。"
      :files [(:path "config/app.json"
               :text "{\n  \"retryCount\": 2,\n  \"timeoutSeconds\": 10,\n  \"feature\": \"stable\"\n}\n")]
      :expected [(:path "config/app.json"
                  :text "{\n  \"retryCount\": 3,\n  \"timeoutSeconds\": 10,\n  \"feature\": \"stable\"\n}\n")])
     (:id "select-similarly-named-file"
      :task "src/cache.el の `cache-size 10` だけを `cache-size 20` に変更してください。src/cache-test.el と src/cache-old.el は同じ文字列を含みますが変更しないでください。"
      :files [(:path "src/cache.el"
               :text "(defconst cache-size 10)\n")
              (:path "src/cache-test.el"
               :text "(should (= cache-size 10))\n")
              (:path "src/cache-old.el"
               :text "(defconst cache-size 10)\n")]
      :expected [(:path "src/cache.el"
                  :text "(defconst cache-size 20)\n")
                 (:path "src/cache-test.el"
                  :text "(should (= cache-size 10))\n")
                 (:path "src/cache-old.el"
                  :text "(defconst cache-size 10)\n")])
     (:id "unicode-literal-replacement"
      :task "messages/status.txt の Unicode 文字列 `状態: 失敗` を `状態: 成功` に置換してください。messages/status-ascii.txt は変更しないでください。"
      :files [(:path "messages/status.txt"
               :text "処理結果\n状態: 失敗\n")
              (:path "messages/status-ascii.txt"
               :text "status: failed\n")]
      :expected [(:path "messages/status.txt"
                  :text "処理結果\n状態: 成功\n")
                 (:path "messages/status-ascii.txt"
                  :text "status: failed\n")])])
  "Fixed representative microtask suite for local file-edit evaluation.")

(defun nl-agent-task-suite--detach (value)
  "Return a recursive detached copy of fixture VALUE, including strings."
  (cond
   ((stringp value) (substring-no-properties value))
   ((vectorp value)
    (apply #'vector
           (mapcar #'nl-agent-task-suite--detach (append value nil))))
   ((consp value)
    (cons (nl-agent-task-suite--detach (car value))
          (nl-agent-task-suite--detach (cdr value))))
   (t value)))

;;;###autoload
(defun nl-agent-task-suite-representative ()
  "Return a detached fresh copy of the representative local edit suite."
  (nl-agent-task-suite--detach nl-agent-task-suite--representative))

(provide 'nl-agent-task-suite)
;;; nl-agent-task-suite.el ends here
