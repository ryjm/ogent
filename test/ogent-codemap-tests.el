;;; ogent-codemap-tests.el --- Tests for ogent codemap -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-codemap)
(require 'cl-lib)

(ert-deftest ogent-codemap-finds-context-file ()
  "The codemap scans known source files."
  (let ((files (ogent-codemap--source-files)))
    (should (cl-some (lambda (file)
                       (string-match-p "ogent-context\\.el$" file))
                     files))))

(ert-deftest ogent-codemap-extracts-definitions ()
  "Definitions are extracted with correct names."
  (let* ((ctx-file (cl-find-if (lambda (file)
                                 (string-match-p "ogent-context\\.el$" file))
                               (ogent-codemap--source-files)))
         (defs (ogent-codemap--definitions ctx-file)))
    (should (member "ogent-context-build" defs))
    (should (member "ogent-resolve-handle" defs))))

(ert-deftest ogent-codemap-buffer-renders-org ()
  "Rendering produces an Org buffer with expected headings."
  (let ((buf (ogent-codemap-refresh)))
    (unwind-protect
        (with-current-buffer buf
          (should (derived-mode-p 'org-mode))
          (goto-char (point-min))
          (should (looking-at "\\* Codemap")))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-codemap-detects-file-types ()
  "File type detection works for all supported types."
  (should (eq (ogent-codemap--file-type "lisp/ogent-core.el") 'elisp))
  (should (eq (ogent-codemap--file-type "test/ogent-core-tests.el") 'elisp-test))
  (should (eq (ogent-codemap--file-type "test/ogent-test.el") 'elisp-test))
  (should (eq (ogent-codemap--file-type "specs/architecture.org") 'org))
  (should (eq (ogent-codemap--file-type "docs/guide.md") 'markdown))
  (should-not (ogent-codemap--file-type "README.txt")))

(ert-deftest ogent-codemap-extracts-test-definitions ()
  "Test definitions are extracted from test files."
  (let* ((test-file (cl-find-if (lambda (file)
                                  (string-match-p "ogent-core-tests\\.el$" file))
                                (ogent-codemap--source-files)))
         (tests (ogent-codemap--test-definitions test-file)))
    (should test-file)
    (should (cl-some (lambda (t) (string-match-p "^ogent-" t)) tests))))

(ert-deftest ogent-codemap-extracts-org-headings ()
  "Org headings are extracted from .org files."
  (let* ((org-file (cl-find-if (lambda (file)
                                 (string-match-p "architecture\\.org$" file))
                               (ogent-codemap--source-files)))
         (headings (ogent-codemap--org-headings org-file)))
    (should org-file)
    (should (> (length headings) 0))
    ;; Each heading is (level . text)
    (should (numberp (caar headings)))
    (should (stringp (cdar headings)))))

(ert-deftest ogent-codemap-scans-all-directories ()
  "Source files include test, specs, and docs directories."
  (let ((files (ogent-codemap--source-files)))
    ;; Should have files from each configured directory
    (should (cl-some (lambda (f) (string-match-p "/lisp/" f)) files))
    (should (cl-some (lambda (f) (string-match-p "/test/" f)) files))
    (should (cl-some (lambda (f) (string-match-p "/specs/" f)) files))
    (should (cl-some (lambda (f) (string-match-p "/docs/" f)) files))))

(provide 'ogent-codemap-tests)
;;; ogent-codemap-tests.el ends here
