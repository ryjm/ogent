;;; compile.el --- Warning strict compilation into owned evidence -*- lexical-binding: t; -*-
(require 'bytecomp)
(require 'ogent-agent)
(require 'ogent-debug)
(require 'ogent-ui-toolcalls)
(let* ((destination (expand-file-name (concat "compiled/" emacs-version "/")
                                     (file-name-directory load-file-name)))
       (byte-compile-error-on-warn t)
       (byte-compile-dest-file-function
        (lambda (source) (expand-file-name (concat (file-name-base source) ".elc") destination))))
  (make-directory destination t)
  (dolist (relative '("lisp/ogent-agent.el" "lisp/ogent-debug.el" "lisp/ogent-doctor.el"
                      "lisp/ogent-models.el" "lisp/ogent-tool-approval.el"
                      "lisp/ogent-tool-contract.el" "lisp/ogent-tool-execution.el"
                      "lisp/ogent-tool-process.el" "lisp/ogent-tool-results.el"
                      "lisp/ogent-tools.el" "lisp/ui/ogent-ui-toolcalls.el"))
    (unless (byte-compile-file (expand-file-name relative "/work"))
      (error "Compilation did not succeed for %s" relative)))
  ;; The helper removes .elc lookup. Explicit load-file proves the new bytecode
  ;; is executed and avoids changing source lookup for unchanged dependencies.
  (dolist (name '(ogent-tool-contract ogent-tools ogent-tool-results ogent-tool-process
                 ogent-tool-approval ogent-tool-execution ogent-models ogent-doctor
                 ogent-agent ogent-debug ogent-ui-toolcalls))
    (load-file (expand-file-name (concat (symbol-name name) ".elc") destination)))
  (dolist (symbol '(ogent-tool-contract--json-text ogent-tools--glob-files
                    ogent-tool-results-format ogent-tool-execution-json
                    ogent-doctor-format-json))
    (unless (byte-code-function-p (symbol-function symbol))
      (error "Not compiled: %s" symbol))
    (message "REVIEW compiled assertion %s=%s" symbol (symbol-file symbol))))
