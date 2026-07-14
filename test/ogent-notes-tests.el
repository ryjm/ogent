;;; ogent-notes-tests.el --- Tests for ogent-notes -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the notes capture functionality.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-notes)
(require 'org)

(defvar ogent-mode-map)  ; Defined in ogent-core
(defvar gptel-post-response-hook)
(defvar org-capture-templates)
(declare-function org-capture-expand-file "org-capture" (file))

;;; Response Tracking Tests

(ert-deftest ogent-notes-track-response-stores-text ()
  "Tracking a response stores the text."
  (let ((ogent-notes--last-response nil))
    (ogent-notes-track-response "Hello world" "gpt-4")
    (should (equal (ogent-notes-get-last-response) "Hello world"))))

(ert-deftest ogent-notes-track-response-ignores-empty ()
  "Empty or nil responses are not tracked."
  (let ((ogent-notes--last-response nil))
    (ogent-notes-track-response "" nil)
    (should (null (ogent-notes-get-last-response)))
    (ogent-notes-track-response nil nil)
    (should (null (ogent-notes-get-last-response)))))

(ert-deftest ogent-notes-clear-response-works ()
  "Clearing the response sets it to nil."
  (let ((ogent-notes--last-response nil))
    (ogent-notes-track-response "Test" nil)
    (should (ogent-notes-get-last-response))
    (ogent-notes-clear-last-response)
    (should (null (ogent-notes-get-last-response)))))

;;; Notes Heading Tests

(ert-deftest ogent-notes-find-notes-heading-returns-nil-when-missing ()
  "Finding Notes heading returns nil when it doesn't exist."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent Heading\nSome content\n")
    (goto-char (point-min))
    (org-back-to-heading)
    (should (null (ogent-notes--find-notes-heading)))))

(ert-deftest ogent-notes-find-notes-heading-finds-existing ()
  "Finding Notes heading returns position when it exists."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent Heading\nSome content\n** Notes\nExisting notes\n")
    (goto-char (point-min))
    (org-back-to-heading)
    (let ((pos (ogent-notes--find-notes-heading)))
      (should pos)
      (goto-char pos)
      (should (looking-at "\\*\\* Notes")))))

(ert-deftest ogent-notes-find-notes-heading-ignores-wrong-level ()
  "Finding Notes heading ignores headings at wrong level."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent Heading\n*** Notes\nWrong level\n")
    (goto-char (point-min))
    (org-back-to-heading)
    (should (null (ogent-notes--find-notes-heading)))))

(ert-deftest ogent-notes-create-notes-heading-works ()
  "Creating Notes heading inserts at correct level."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent Heading\nSome content\n")
    (goto-char (point-min))
    (org-back-to-heading)
    (let ((pos (ogent-notes--create-notes-heading)))
      (should pos)
      (goto-char pos)
      (should (looking-at "\\*\\* Notes")))))

(ert-deftest ogent-notes-find-or-create-finds-existing ()
  "Find-or-create returns existing Notes heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent Heading\n** Notes\nExisting\n")
    (goto-char (point-min))
    (org-back-to-heading)
    (let ((pos (ogent-notes--find-or-create-notes-heading)))
      (should pos)
      (goto-char pos)
      (should (looking-at "\\*\\* Notes")))))

(ert-deftest ogent-notes-find-or-create-creates-when-missing ()
  "Find-or-create creates Notes heading when missing."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent Heading\nSome content\n")
    (goto-char (point-min))
    (org-back-to-heading)
    (let ((pos (ogent-notes--find-or-create-notes-heading)))
      (should pos)
      (goto-char pos)
      (should (looking-at "\\*\\* Notes")))))

;;; Capture Tests

(ert-deftest ogent-notes-capture-creates-notes-heading ()
  "Capture creates Notes heading if missing."
  (let ((ogent-notes--last-response nil))
    (ogent-notes-track-response "Test response" nil)
    (with-temp-buffer
      (org-mode)
      (insert "* Parent Heading\nSome content\n")
      (goto-char (point-min))
      (ogent-notes-capture)
      (goto-char (point-min))
      (should (search-forward "** Notes" nil t))
      (should (search-forward "Test response" nil t)))))

(ert-deftest ogent-notes-capture-appends-to-existing ()
  "Capture appends to existing Notes heading."
  (let ((ogent-notes--last-response nil))
    (ogent-notes-track-response "New response" nil)
    (with-temp-buffer
      (org-mode)
      (insert "* Parent Heading\n** Notes\nExisting note\n")
      (goto-char (point-min))
      (ogent-notes-capture)
      (goto-char (point-min))
      (should (search-forward "Existing note" nil t))
      (should (search-forward "New response" nil t)))))

(ert-deftest ogent-notes-capture-includes-timestamp ()
  "Capture includes a timestamp."
  (let ((ogent-notes--last-response nil))
    (ogent-notes-track-response "Test" nil)
    (with-temp-buffer
      (org-mode)
      (insert "* Parent Heading\n")
      (goto-char (point-min))
      (ogent-notes-capture)
      (goto-char (point-min))
      ;; Should have a timestamp like [2025-12-13 Sat 19:30]
      (should (re-search-forward "\\[[-0-9]+ [A-Za-z]+ [0-9:]+\\]" nil t)))))

(ert-deftest ogent-notes-capture-clears-response ()
  "Capture clears the tracked response after use."
  (let ((ogent-notes--last-response nil))
    (ogent-notes-track-response "Test" nil)
    (with-temp-buffer
      (org-mode)
      (insert "* Parent Heading\n")
      (goto-char (point-min))
      (ogent-notes-capture)
      (should (null (ogent-notes-get-last-response))))))

(ert-deftest ogent-notes-capture-errors-without-response ()
  "Capture signals error when no response is available."
  (let ((ogent-notes--last-response nil))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent Heading\n")
      (goto-char (point-min))
      (should-error (ogent-notes-capture) :type 'user-error))))

(ert-deftest ogent-notes-capture-errors-in-non-org ()
  "Capture signals error in non-Org buffers."
  (let ((ogent-notes--last-response nil))
    (ogent-notes-track-response "Test" nil)
    (with-temp-buffer
      (fundamental-mode)
      (should-error (ogent-notes-capture) :type 'user-error))))

;;; Keybinding Tests

(ert-deftest ogent-notes-keybinding-exists ()
  "C-c . d is bound to ogent-notes-capture."
  (require 'ogent-core)
  (should (eq (lookup-key ogent-mode-map (kbd "C-c . d"))
              #'ogent-notes-capture)))

;;; Require Purity Tests

(ert-deftest ogent-notes-require-does-not-install-gptel-hook ()
  "Requiring ogent-notes installs no gptel response hook."
  (should (featurep 'ogent-notes))
  (should-not (and (boundp 'gptel-post-response-hook)
                   (memq #'ogent-notes--gptel-post-response-hook
                         gptel-post-response-hook))))

(ert-deftest ogent-notes-enable-tracking-installs-hook-idempotently ()
  "Enabling tracking installs the gptel hook exactly once."
  (let ((gptel-post-response-hook nil))
    (ogent-notes-enable-tracking)
    (ogent-notes-enable-tracking)
    (should (equal gptel-post-response-hook
                   (list #'ogent-notes--gptel-post-response-hook)))))

(ert-deftest ogent-notes-disable-tracking-removes-hook-idempotently ()
  "Disabling tracking removes the gptel hook and tolerates repeats."
  (let ((gptel-post-response-hook nil))
    (ogent-notes-enable-tracking)
    (ogent-notes-disable-tracking)
    (should-not (memq #'ogent-notes--gptel-post-response-hook
                      gptel-post-response-hook))
    ;; A second disable is a quiet no-op.
    (ogent-notes-disable-tracking)
    (should-not (memq #'ogent-notes--gptel-post-response-hook
                      gptel-post-response-hook))))

;;; Org Capture Template Tests

(ert-deftest ogent-notes-require-does-not-register-capture-templates ()
  "Templates reach `org-capture-templates' only via explicit setup."
  (require 'org-capture)
  (dolist (template ogent-capture-templates)
    (should-not (assoc (car template) org-capture-templates))))

(ert-deftest ogent-notes-setup-capture-registers-once-across-calls ()
  "Two setup calls register each template exactly once."
  (require 'org-capture)
  (let ((org-capture-templates nil))
    (ogent-notes-setup-capture)
    (ogent-notes-setup-capture)
    (should (= (length org-capture-templates)
               (length ogent-capture-templates)))
    (dolist (template ogent-capture-templates)
      (should (= 1 (cl-count (car template) org-capture-templates
                             :key #'car :test #'equal))))))

(ert-deftest ogent-notes-setup-capture-preserves-user-templates ()
  "Setup appends after user templates and never clobbers a taken key."
  (require 'org-capture)
  (let ((org-capture-templates
         '(("x" "User" entry (file "/tmp/x.org") "* %?")
           ("on" "User note" entry (file "/tmp/y.org") "* %?"))))
    (ogent-notes-setup-capture)
    ;; The user's "on" entry wins; ours is skipped, not merged over it.
    (should (equal (assoc "on" org-capture-templates)
                   '("on" "User note" entry (file "/tmp/y.org") "* %?")))
    ;; Remaining ogent entries are appended after user entries.
    (should (assoc "op" org-capture-templates))
    (should (equal (caar org-capture-templates) "x"))))

(ert-deftest ogent-notes-capture-template-targets-resolve ()
  "Registered templates target resolvable files and non-empty headlines."
  (require 'org-capture)
  (let ((org-capture-templates nil))
    (ogent-notes-setup-capture)
    (dolist (key '("on" "op"))
      (let* ((template (assoc key org-capture-templates))
             (target (nth 3 template)))
        (should template)
        (should (eq (car target) 'file+headline))
        (let ((file (org-capture-expand-file (nth 1 target)))
              (headline (nth 2 target)))
          (should (stringp file))
          (should (> (length file) 0))
          (should (stringp headline))
          (should (> (length headline) 0)))))))

(provide 'ogent-notes-tests)

;;; ogent-notes-tests.el ends here
