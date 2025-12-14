;;; ogent-notes-tests.el --- Tests for ogent-notes -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the notes capture functionality.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-notes)
(require 'org)

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

(provide 'ogent-notes-tests)

;;; ogent-notes-tests.el ends here
