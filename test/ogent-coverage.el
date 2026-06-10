;;; ogent-coverage.el --- Coverage measurement for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with:
;;   UNDERCOVER_FORCE=true emacs -Q --batch -L lisp -L lisp/ui -L test -L test/ui \
;;     -l test/ogent-coverage.el -f ogent-run-coverage

;;; Code:

;; undercover is only available when explicitly installed for coverage runs.
;; Guard the require so byte-compilation and `make test' don't fail when it's
;; absent (the coverage entry point ogent-run-coverage checks at runtime).
(when (require 'undercover nil t)
  ;; `undercover' is a macro; evaluate the form at runtime so byte-compiling
  ;; this file without undercover installed does not misread it as a
  ;; function call.
  (eval '(undercover "lisp/*.el"
                     "lisp/ui/*.el"
                     (:report-format 'text)
                     (:send-report nil))
        t))

;; Now load test helper (which loads source files)
(require 'ogent-test-helper)

;;;###autoload
(defun ogent-run-coverage ()
  "Load all test files and run with coverage."
  (interactive)
  (unless (featurep 'undercover)
    (error "undercover package not installed; install it first for coverage"))
  (mapc #'ogent-test-load (ogent-test--files))
  (ert-run-tests-batch-and-exit t))

(provide 'ogent-coverage)

;;; ogent-coverage.el ends here
