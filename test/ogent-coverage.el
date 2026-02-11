;;; ogent-coverage.el --- Coverage measurement for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with:
;;   UNDERCOVER_FORCE=true emacs -Q --batch -L lisp -L lisp/ui -L test -L test/ui \
;;     -l test/ogent-coverage.el -f ogent-run-coverage

;;; Code:

(require 'undercover)

;; Configure undercover BEFORE loading any source files
(undercover "lisp/*.el"
            "lisp/ui/*.el"
            (:report-format 'text)
            (:send-report nil))

;; Now load test helper (which loads source files)
(require 'ogent-test-helper)

;;;###autoload
(defun ogent-run-coverage ()
  "Load all test files and run with coverage."
  (interactive)
  (mapc #'ogent-test-load (ogent-test--files))
  (ert-run-tests-batch-and-exit t))

(provide 'ogent-coverage)

;;; ogent-coverage.el ends here
