;;; compiled.el --- Owned bytecode freeze checks -*- lexical-binding: t; -*-
(require 'bytecomp)
(let* ((directory (expand-file-name (concat "compiled/" emacs-version "/")
                                   "/work/agent_ergonomics_audit/audit/evidence/pass_3/review_round13/"))
       (byte-compile-error-on-warn t)
       (byte-compile-dest-file-function
        (lambda (file) (expand-file-name (concat (file-name-base file) ".elc") directory))))
  (make-directory directory t)
  (dolist (file '("ogent-tool-contract" "ogent-tool-results" "ogent-tool-process"
                  "ogent-tool-approval" "ogent-tool-execution" "ogent-models"
                  "ogent-tools" "ogent-agent" "ogent-debug" "ogent-doctor"))
    (unless (byte-compile-file (concat "/work/lisp/" file ".el")) (error "Compile failed: %s" file)))
  (unless (byte-compile-file "/work/lisp/ui/ogent-ui-toolcalls.el") (error "UI compile failed"))
  (dolist (file '("ogent-tool-contract" "ogent-tool-results" "ogent-tool-process"
                  "ogent-tool-approval" "ogent-tool-execution" "ogent-models"
                  "ogent-tools" "ogent-agent" "ogent-debug" "ogent-doctor" "ogent-ui-toolcalls"))
    (load (expand-file-name (concat file ".elc") directory) nil nil t)))
(dolist (symbol '(ogent-tool-results-glob ogent-tool-process-grep-async
                  ogent-tool-execution-call ogent-agent-call ogent-tool-execution-json))
  (unless (byte-code-function-p (symbol-function symbol)) (error "Bytecode not loaded: %s" symbol)))
(message "REVIEW13 11 warning-strict modules compiled; 5 bytecode identities confirmed")
