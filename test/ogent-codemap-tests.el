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

(provide 'ogent-codemap-tests)
;;; ogent-codemap-tests.el ends here
