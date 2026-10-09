;;; validate.el --- Verify warning hygiene and compiled Unicode checks -*- lexical-binding: t; -*-

(require 'ogent-agent-execution-tests)
(require 'checkdoc)
(require 'bytecomp)

(let* ((files '("lisp/ogent-tool-results.el" "lisp/ogent-tool-process.el"
                "test/ogent-agent-execution-tests.el"))
       (compile-root (ogent-test--provision-store-directory 'lint-hygiene-bytecode))
       (byte-compile-error-on-warn t)
       (byte-compile-dest-file-function
        (lambda (file)
          (expand-file-name (concat (file-name-nondirectory file) "c") compile-root)))
       (checkdoc-spellcheck-documentation-flag nil)
       doc-errors
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
  (load (expand-file-name "ogent-tool-results.elc" compile-root) nil t t)
  (load (expand-file-name "ogent-tool-process.elc" compile-root) nil t t)
  (unless (byte-code-function-p (symbol-function 'ogent-tool-results--unicode))
    (error "Unicode validation did not load compiled code"))
  (unless (equal (ogent-tool-results--unicode "lambda: λ") "lambda: λ")
    (error "Compiled Unicode validation changed supported text"))
  (unless (condition-case nil
              (progn (ogent-tool-results--unicode
                      (concat "lambda: λ" (unibyte-string 255))) nil)
            (ogent-tool-results-output-error t))
    (error "Compiled Unicode validation accepted unsupported raw bytes"))
  (princ "Scoped strict compilation, checkdoc, indentation and compiled Unicode boundaries passed\n")
  (ert-run-tests-batch-and-exit "^ogent-agent-execution-\\(glob-\\|process-\\|model-json-unicode-transport$\\)"))
