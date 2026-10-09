;;; load-compiled.el --- Load already frozen owned bytecode -*- lexical-binding: t; -*-
(let ((directory (expand-file-name (concat "compiled/" emacs-version "/")
                                  "/work/agent_ergonomics_audit/audit/evidence/pass_3/review_round13/")))
  (dolist (file '("ogent-tool-contract" "ogent-tool-results" "ogent-tool-process"
                  "ogent-tool-approval" "ogent-tool-execution" "ogent-models"
                  "ogent-tools" "ogent-agent" "ogent-debug" "ogent-doctor" "ogent-ui-toolcalls"))
    (load (expand-file-name (concat file ".elc") directory) nil nil t)))
(dolist (symbol '(ogent-tool-results-glob ogent-tool-process-grep-async
                  ogent-tool-execution-call ogent-agent-call ogent-tool-execution-json))
  (unless (byte-code-function-p (symbol-function symbol)) (error "Bytecode not loaded: %s" symbol)))
(message "REVIEW13 existing frozen bytecode loaded; 5 identities confirmed")
