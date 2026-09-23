;;; read-only-shell-test.el --- read-only shell approval tests  -*- lexical-binding: t; -*-

(load (expand-file-name "../lisp/nl-agent-stack-paths.el"
                        (file-name-directory (or load-file-name buffer-file-name
                                                 default-directory))) nil t)
(require 'nl-agent-local-tools)

(defvar nl-agent-read-only-shell-test--fail 0)

(defun nl-agent-read-only-shell-test--ck (name actual expected)
  (princ (format "%-65s %s\n" name
                 (if (eq actual expected)
                     "PASS"
                   (setq nl-agent-read-only-shell-test--fail
                         (1+ nl-agent-read-only-shell-test--fail))
                   "FAIL"))))

(dolist (command
         '("rg -n 'defun foo' lisp"
           "rg -n \"nelisp-json-parse-string\" packages"
           "grep -rn foo lisp | head -20"
           "sed -n '10,20p' lisp/a.el"
           "sed -n 5p a.el"
           "git log --oneline -5"
           "git diff --stat"
           "find lisp -name '*.el'"
           "ls -la"
           "wc -l lisp/*.el"
           "cat README.org | head -5"
           "rg -n 'x$' lisp"
           "rg foo \"a|b\""
           "rg '[a-z]+' lisp"
           "rg '.*foo' lisp"))
  (nl-agent-read-only-shell-test--ck
   (format "accept %S" command)
   (nl-agent-local-read-only-command-p command)
   t))

(dolist (command
         '("rm -rf lisp"
           "rg foo > out"
           "rg foo; rm x"
           "rg foo && rm x"
           "echo $(id)"
           "cat `id`"
           "cat ~/.hermes/.env"
           "cat /etc/passwd"
           "cat ../secret"
           "cat a/../../x"
           "rg --pre=sh foo"
           "rg -z foo"
           "find . -exec rm {} ;"
           "find . -delete"
           "sed -i s/a/b/ f"
           "sed -n 'w out' f"
           "sed '1p' f"
           "tail -f log"
           "git push"
           "git -c core.pager=sh log"
           "git diff --output=x"
           "git grep -O foo"
           "rg \"$HOME\" ."
           "rg foo\nrm x"
           "rg 'unbalanced"
           "rg foo |"
           "rg foo || rm x"
           "(rm x)"
           "python3 -c 1"
           "cat .*/x"
           "cat ?./x"
           "cat [.][.]/x"
           "cat lisp/.*"
           "rg \"a|\" --pre=sh ."
           "\"rm\" x"
           ""))
  (nl-agent-read-only-shell-test--ck
   (format "reject %S" command)
   (nl-agent-local-read-only-command-p command)
   nil))

(nl-agent-read-only-shell-test--ck
 "approval allows read-only shell once"
 (nl-agent-local-read-only-shell-approval
  (list :tool "shell" :args (list :command "ls")))
 'once)
(nl-agent-read-only-shell-test--ck
 "approval denies destructive shell"
 (nl-agent-local-read-only-shell-approval
  (list :tool "shell" :args (list :command "rm x")))
 'deny)
(nl-agent-read-only-shell-test--ck
 "approval denies edit"
 (nl-agent-local-read-only-shell-approval
  (list :tool "edit" :args (list :path "a")))
 'deny)
(nl-agent-read-only-shell-test--ck
 "approval denies elisp"
 (nl-agent-local-read-only-shell-approval
  (list :tool "elisp" :args (list :code "1")))
 'deny)

(princ (format "NL-AGENT-READ-ONLY-SHELL %s\n"
               (if (= nl-agent-read-only-shell-test--fail 0)
                   "ALL-PASS"
                 "HAS-FAILURES")))
(kill-emacs (if (= nl-agent-read-only-shell-test--fail 0) 0 1))

;;; read-only-shell-test.el ends here
