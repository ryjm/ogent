;;; lint.el --- Batch lint helpers for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides `ogent-lint' which runs checkdoc and byte-compilation
;; across the ogent codebase.

;;; Code:

(require 'cl-lib)
(require 'checkdoc)
(require 'subr-x)

(defconst ogent--project-root
  (file-name-directory (or load-file-name buffer-file-name))
  "Root directory of the ogent project during batch linting.")

(defun ogent--with-source-buffer (file fn)
  "Visit FILE temporarily and call FN.
FN receives the current buffer and must not move point.
Buffer is killed afterwards."
  (with-current-buffer (find-file-noselect file)
    (unwind-protect
        (funcall fn)
      (when (buffer-file-name)
        (kill-buffer (current-buffer))))))

(defun ogent--source-files ()
  "Return a list of every Emacs Lisp file under `lisp/'."
  (directory-files-recursively
   (expand-file-name "lisp" ogent--project-root)
   "\\.el$"))

(defun ogent--lint-checkdoc ()
  "Run checkdoc across every source file."
  (dolist (file (ogent--source-files))
    (ogent--with-source-buffer file
                               (lambda ()
                                 (message "checkdoc %s" file)
                                 (checkdoc-current-buffer t)))))

(defun ogent--lint-byte-compile ()
  "Byte-compile all source files with warnings promoted to errors."
  (let ((load-path (append (list (expand-file-name "lisp" ogent--project-root)
                                 (expand-file-name "lisp/ui" ogent--project-root))
                           load-path))
        (byte-compile-error-on-warn t))
    (dolist (file (ogent--source-files))
      (message "byte-compile %s" file)
      (byte-compile-file file)))
  (message "byte-compilation complete"))

;;;###autoload
(defun ogent-lint ()
  "Run checkdoc and byte-compilation for ogent."
  (interactive)
  (ogent--lint-checkdoc)
  (ogent--lint-byte-compile)
  (message "ogent lint finished"))

(provide 'lint)

;;; lint.el ends here
