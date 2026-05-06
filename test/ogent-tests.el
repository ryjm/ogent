;;; ogent-tests.el --- Tests for main ogent entry point -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent)

;;; Feature Tests

(ert-deftest ogent-feature-provided ()
  "ogent feature is provided after loading."
  (should (featurep 'ogent)))

(ert-deftest ogent-dependencies-loaded ()
  "All required dependencies are loaded."
  (should (featurep 'ogent-context))
  (should (featurep 'ogent-models))
  (should (featurep 'ogent-tools))
  (should (featurep 'ogent-companion))
  (should (featurep 'ogent-core))
  (should (featurep 'ogent-codemap))
  (should (featurep 'ogent-ui))
  (should (featurep 'ogent-onboard))
  (should (featurep 'ogent-edit))
  (should (featurep 'ogent-notes))
  (should (featurep 'ogent-session))
  (should (featurep 'ogent-debug))
  (should (featurep 'ogent-anthropic-oauth))
  (should (featurep 'ogent-codex-oauth))
  (should (featurep 'ogent-cabinet-adapter))
  (should (featurep 'ogent-cabinet-skills))
  (should (featurep 'ogent-cabinet-compose))
  (should (featurep 'ogent-cabinet-actions))
  (should (featurep 'ogent-cabinet-conversations)))

(ert-deftest ogent-org-capture-contexts-compat-defines-missing-var ()
  "Compatibility guard defines missing Org capture contexts variable."
  (let ((was-bound (boundp 'org-capture-templates-contexts))
        (old-value (and (boundp 'org-capture-templates-contexts)
                        org-capture-templates-contexts)))
    (unwind-protect
        (progn
          (makunbound 'org-capture-templates-contexts)
          (ogent--ensure-org-capture-templates-contexts)
          (should (boundp 'org-capture-templates-contexts))
          (should (null org-capture-templates-contexts)))
      (if was-bound
          (setq org-capture-templates-contexts old-value)
        (makunbound 'org-capture-templates-contexts)))))

(ert-deftest ogent-org-capture-contexts-compat-preserves-existing-var ()
  "Compatibility guard preserves an existing Org capture contexts value."
  (let ((was-bound (boundp 'org-capture-templates-contexts))
        (old-value (and (boundp 'org-capture-templates-contexts)
                        org-capture-templates-contexts))
        (expected '(("x" ((in-mode . "org-mode"))))))
    (unwind-protect
        (progn
          (set 'org-capture-templates-contexts expected)
          (ogent--ensure-org-capture-templates-contexts)
          (should (equal org-capture-templates-contexts expected)))
      (if was-bound
          (setq org-capture-templates-contexts old-value)
        (makunbound 'org-capture-templates-contexts)))))

(ert-deftest ogent-org-capture-contexts-compat-advises-template-selection ()
  "Compatibility guard wraps Org capture template selection."
  (require 'org-capture)
  (should (advice-member-p #'ogent--with-org-capture-templates-contexts
                           'org-capture-select-template)))

(ert-deftest ogent-org-capture-contexts-compat-wraps-capture-commands ()
  "Compatibility guard wraps Org capture commands that select templates."
  (require 'org-capture)
  (dolist (command '(org-capture
                     org-capture-goto-target
                     org-capture-select-template))
    (should (advice-member-p #'ogent--with-org-capture-templates-contexts
                             command))))

(ert-deftest ogent-org-capture-contexts-compat-recovers-goto-target ()
  "Org capture target navigation recovers from a missing contexts variable."
  (require 'org-capture)
  (let ((test-file (make-temp-file "ogent-capture-target" nil ".org"))
        (was-bound (boundp 'org-capture-templates-contexts))
        (old-value (and (boundp 'org-capture-templates-contexts)
                        org-capture-templates-contexts)))
    (unwind-protect
        (let ((org-capture-templates
               (list (list "x" "Compat test" 'entry
                           (list 'file+headline test-file "Inbox")
                           "* %?"))))
          (with-temp-file test-file
            (insert "* Inbox\n"))
          (makunbound 'org-capture-templates-contexts)
          (save-window-excursion
            (org-capture-goto-target "x"))
          (should (boundp 'org-capture-templates-contexts))
          (should (null org-capture-templates-contexts)))
      (when (get-file-buffer test-file)
        (kill-buffer (get-file-buffer test-file)))
      (when (file-exists-p test-file)
        (delete-file test-file))
      (if was-bound
          (setq org-capture-templates-contexts old-value)
        (makunbound 'org-capture-templates-contexts)))))

;;; Mode Tests

(ert-deftest ogent-mode-defined ()
  "ogent-mode is defined as a minor mode."
  (should (fboundp 'ogent-mode)))

(ert-deftest ogent-global-mode-defined ()
  "ogent-global-mode is defined."
  (should (fboundp 'ogent-global-mode)))

;;; Core Functions Available

(ert-deftest ogent-core-functions-available ()
  "Core interactive functions are available."
  (should (fboundp 'ogent-request))
  (should (fboundp 'ogent-abort-request))
  (should (fboundp 'ogent-retry-request))
  (should (fboundp 'ogent-ask)))

(ert-deftest ogent-context-functions-available ()
  "Context functions are available."
  (should (fboundp 'ogent-context-preview))
  (should (fboundp 'ogent-context-build)))

(ert-deftest ogent-edit-functions-available ()
  "Edit functions are available."
  (should (fboundp 'ogent-request-edit))
  (should (fboundp 'ogent-edit-accept-current))
  (should (fboundp 'ogent-edit-reject-current)))

(ert-deftest ogent-companion-functions-available ()
  "Companion functions are available."
  (should (fboundp 'ogent-companion-get-or-create))
  (should (fboundp 'ogent-companion-display)))

(ert-deftest ogent-codemap-functions-available ()
  "Codemap functions are available."
  (should (fboundp 'ogent-codemap-buffer))
  (should (fboundp 'ogent-codemap-refresh)))

(ert-deftest ogent-session-functions-available ()
  "Session functions are available."
  (should (fboundp 'ogent-session-save))
  (should (fboundp 'ogent-session-load))
  (should (fboundp 'ogent-session-list)))

(ert-deftest ogent-notes-functions-available ()
  "Notes functions are available."
  (should (fboundp 'ogent-notes-capture)))

;;; Tool Installation

(ert-deftest ogent-tools-installed ()
  "Default tools are installed on load."
  ;; ogent-tools-install-defaults is called in ogent.el
  ;; Check that the tool registry has entries (it's a list)
  (should (boundp 'ogent-tool-registry))
  (should (listp ogent-tool-registry))
  (should (> (length ogent-tool-registry) 0)))

;;; Customization Groups

(ert-deftest ogent-customization-group-exists ()
  "Main ogent customization group exists."
  (should (get 'ogent 'custom-group)))

;;; UI Subdirectory Load Path

(ert-deftest ogent-ui-features-loaded ()
  "UI features from subdirectory are loaded."
  ;; ogent-ui is loaded, which requires the sub-features
  ;; The sub-features may be loaded lazily or via autoload
  (should (featurep 'ogent-ui)))

;;; Version Info

(ert-deftest ogent-version-defined ()
  "Package version is defined in header."
  ;; The version is in the file header - check the source file directly
  (let ((ogent-file (locate-library "ogent" nil '("lisp"))))
    (should ogent-file)
    ;; If we got the .elc, find the .el
    (when (string-suffix-p ".elc" ogent-file)
      (setq ogent-file (concat (file-name-sans-extension ogent-file) ".el")))
    (when (file-exists-p ogent-file)
      (with-temp-buffer
        (insert-file-contents ogent-file)
        (should (string-match-p "Version:" (buffer-string)))))))

(provide 'ogent-tests)
;;; ogent-tests.el ends here
