;;; scoped-validation.el --- Validate captured tool ledger context -*- lexical-binding: t; -*-

(require 'ogent-agent-execution-tests)
(require 'ogent-ui-toolcalls-tests)
(require 'checkdoc)
(require 'bytecomp)

(let* ((files '("lisp/ogent-tool-execution.el"
                "lisp/ui/ogent-ui-toolcalls.el"
                "test/ogent-agent-execution-tests.el"
                "test/ui/ogent-ui-toolcalls-tests.el"))
       (compile-root (ogent-test--provision-store-directory 'ledger-context-bytecode))
       (byte-compile-error-on-warn t)
       (byte-compile-dest-file-function
        (lambda (file)
          (expand-file-name (concat (file-name-nondirectory file) "c") compile-root)))
       (checkdoc-spellcheck-documentation-flag nil)
       (doc-errors nil)
       (checkdoc-create-error-function
        (lambda (message-text start _end &optional _unfixable)
          (push (format "%s:%s: %s" (checkdoc-buffer-label)
                        (line-number-at-pos (or start (point-min))) message-text)
                doc-errors)
          nil)))
  (dolist (file files)
    (with-temp-buffer
      (insert-file-contents file)
      (emacs-lisp-mode)
      (let ((source (buffer-string)) (inhibit-message t))
        (indent-region (point-min) (point-max))
        (unless (equal source (buffer-string))
          (error "Noncanonical indentation: %s" file))))
    (unless (byte-compile-file file)
      (error "Warning-strict compilation failed: %s" file))
    (checkdoc-file file))
  (when doc-errors
    (error "Checkdoc failed: %s" (string-join (nreverse doc-errors) "; ")))
  (princ "Scoped warning-strict compilation, checkdoc and canonical indentation passed\n"))
