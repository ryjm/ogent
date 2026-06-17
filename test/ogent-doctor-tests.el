;;; ogent-doctor-tests.el --- Tests for ogent doctor -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-doctor)

(ert-deftest ogent-doctor-version-status-compares-minimum ()
  "Version status passes only when current version meets the minimum."
  (should (eq (ogent-doctor--version-status "29.1" "29.1") 'ok))
  (should (eq (ogent-doctor--version-status "30.2" "29.1") 'ok))
  (should (eq (ogent-doctor--version-status "29.0" "29.1") 'error)))

(ert-deftest ogent-doctor-summary-status-prioritizes-errors ()
  "Summary status reports the worst result severity."
  (should (eq (ogent-doctor-summary-status
               '((:status info) (:status ok)))
              'ok))
  (should (eq (ogent-doctor-summary-status
               '((:status info) (:status warn) (:status ok)))
              'warn))
  (should (eq (ogent-doctor-summary-status
               '((:status warn) (:status error) (:status ok)))
              'error)))

(ert-deftest ogent-doctor-format-matches-golden ()
  "Doctor report formatting is pinned by a golden Org artifact."
  (let* ((results '((:id emacs-version
                         :label "Emacs version"
                         :status ok
                         :detail "Emacs 30.2 (required >= 29.1)")
                    (:id backend
                         :label "gptel backend"
                         :status warn
                         :detail "Backend \"OpenAI\" has not resolved to an object")
                    (:id codex-auth
                         :label "Codex OAuth cache"
                         :status info
                         :detail "No Codex auth file at ~/.codex/auth.json")))
         (golden-file (expand-file-name "data/ogent-doctor-golden.org"
                                        ogent-test-root))
         (expected (with-temp-buffer
                     (insert-file-contents golden-file)
                     (buffer-string))))
    (should (equal (ogent-doctor-format results) expected))))

(ert-deftest ogent-doctor-run-includes-core-checks ()
  "Doctor run returns stable plist entries for core checks."
  (let* ((results (ogent-doctor-run))
         (ids (mapcar (lambda (result) (plist-get result :id)) results)))
    (dolist (id '(emacs-version org-version gptel transient model-registry default-model))
      (should (memq id ids)))
    (dolist (result results)
      (should (plist-get result :label))
      (should (memq (plist-get result :status) '(ok warn error info))))))

(ert-deftest ogent-doctor-command-renders-buffer ()
  "Interactive doctor command renders a report buffer and returns results."
  (let ((ogent-doctor-buffer-name "*ogent-doctor-test*"))
    (unwind-protect
        (let ((results (ogent-doctor)))
          (should results)
          (should (get-buffer ogent-doctor-buffer-name))
          (with-current-buffer ogent-doctor-buffer-name
            (should (derived-mode-p 'org-mode))
            (should (string-match-p "Ogent Doctor" (buffer-string)))))
      (when-let ((buffer (get-buffer ogent-doctor-buffer-name)))
        (kill-buffer buffer)))))

;;; ogent-doctor-tests.el ends here
