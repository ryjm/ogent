;;; ogent-test-helper.el --- Test bootstrap for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides helper utilities to load project code and execute ert suites.

;;; Code:

(require 'ert)
(require 'subr-x)
(require 'org)

(defconst ogent-test-root
  (file-name-directory (or load-file-name buffer-file-name))
  "Absolute path to the ogent/test directory.")

(defconst ogent-project-root
  (expand-file-name ".." ogent-test-root)
  "Absolute path to the ogent project root from tests.")

(add-to-list 'load-path (expand-file-name "lisp" ogent-project-root))
(add-to-list 'load-path (expand-file-name "lisp/ui" ogent-project-root))
(add-to-list 'load-path ogent-test-root)
(add-to-list 'load-path (expand-file-name "ui" ogent-test-root))

(defun ogent-test-with-org-file (file fn)
  "Open FILE contents in a temporary Org buffer and run FN."
  (let ((buffer (generate-new-buffer " *ogent-test*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert-file-contents file)
          (org-mode)
          (funcall fn))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ogent-test-with-fixture (relative-path fn)
  "Execute FN inside the Org fixture at RELATIVE-PATH."
  (ogent-test-with-org-file
   (expand-file-name relative-path ogent-test-root)
   fn))

(defun ogent-test--files ()
  "Return every ert test file under `test/'."
  (directory-files-recursively ogent-test-root "-tests\\.el$"))

(defun ogent-test-load (file)
  "Load FILE relative to the project root."
  (load file nil 'nomessage))

;;;###autoload
(defun ogent-run-tests ()
  "Load every ogent test file then run ert suites."
  (interactive)
  (mapc #'ogent-test-load (ogent-test--files))
  (ert-run-tests-batch-and-exit t))

(provide 'ogent-test-helper)

;;; ogent-test-helper.el ends here
