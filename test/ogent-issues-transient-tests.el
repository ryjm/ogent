;;; ogent-issues-transient-tests.el --- Tests for ogent-issues-transient -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the transient menus in ogent-issues.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-issues-bd)
(require 'ogent-issues)
(require 'ogent-issues-transient)

;;; Test Fixtures

(defconst ogent-issues-transient-test--sample-issue
  '(:id "test-001"
        :title "Test issue"
        :status "open"
        :priority 1
        :issue_type "task")
  "Sample issue for testing.")

;;; Header Formatting Tests

(ert-deftest ogent-issues-transient-test-format-header-no-issue ()
  "Test header formatting when no issue at point."
  (cl-letf (((symbol-function 'ogent-issues--current-issue)
             (lambda () nil))
            ((symbol-function 'ogent-issues-bd-project-name)
             (lambda () "test-project")))
    (let ((ogent-issues--current-view 'list)
          (ogent-issues--issues nil))
      (let ((header (ogent-issues-transient--format-header)))
        (should (string-match-p "Issues" header))
        (should (string-match-p "List" header))
        (should-not (string-match-p "At:" header))))))

(ert-deftest ogent-issues-transient-test-format-header-with-issue ()
  "Test header formatting when issue at point."
  (cl-letf (((symbol-function 'ogent-issues--current-issue)
             (lambda () ogent-issues-transient-test--sample-issue))
            ((symbol-function 'ogent-issues-bd-project-name)
             (lambda () "test-project")))
    (let ((ogent-issues--current-view 'list)
          (ogent-issues--issues (list ogent-issues-transient-test--sample-issue)))
      (let ((header (ogent-issues-transient--format-header)))
        (should (string-match-p "Issues" header))
        (should (string-match-p "List" header))
        (should (string-match-p "At:" header))
        (should (string-match-p "test-001" header))
        (should (string-match-p "open" header))))))

(ert-deftest ogent-issues-transient-test-format-header-ready-view ()
  "Test header formatting in ready view."
  (cl-letf (((symbol-function 'ogent-issues--current-issue)
             (lambda () nil))
            ((symbol-function 'ogent-issues-bd-project-name)
             (lambda () "test-project")))
    (let ((ogent-issues--current-view 'ready)
          (ogent-issues--issues nil))
      (let ((header (ogent-issues-transient--format-header)))
        (should (string-match-p "Ready" header))))))

;;; Create Mode Tests

(ert-deftest ogent-issues-transient-test-create-mode-keymap ()
  "Test that create mode has correct keybindings."
  (should (keymapp ogent-issues-create-mode-map))
  (should (commandp (lookup-key ogent-issues-create-mode-map (kbd "C-c C-c"))))
  (should (commandp (lookup-key ogent-issues-create-mode-map (kbd "C-c C-k")))))

(ert-deftest ogent-issues-transient-test-create-mode-activation ()
  "Test that create mode activates correctly."
  (with-temp-buffer
    (ogent-issues-create-mode)
    (should (eq major-mode 'ogent-issues-create-mode))
    (should header-line-format)))

;;; Transient Definition Tests

(ert-deftest ogent-issues-transient-test-dispatch-defined ()
  "Test that main dispatch transient is defined."
  (should (fboundp 'ogent-issues-dispatch)))

(ert-deftest ogent-issues-transient-test-create-dispatch-defined ()
  "Test that create dispatch transient is defined."
  (should (fboundp 'ogent-issues-create-dispatch)))

(ert-deftest ogent-issues-transient-test-filter-dispatch-defined ()
  "Test that filter dispatch transient is defined."
  (should (fboundp 'ogent-issues-filter-dispatch)))

;;; Create Functions Tests

(ert-deftest ogent-issues-transient-test-create-quick-defined ()
  "Test that quick create function is defined."
  (should (fboundp 'ogent-issues-create-quick)))

(ert-deftest ogent-issues-transient-test-create-full-defined ()
  "Test that full create function is defined."
  (should (fboundp 'ogent-issues-create-full)))

(ert-deftest ogent-issues-transient-test-create-epic-defined ()
  "Test that epic create function is defined."
  (should (fboundp 'ogent-issues-create-epic)))

(ert-deftest ogent-issues-transient-test-create-submit-defined ()
  "Test that create submit function is defined."
  (should (fboundp 'ogent-issues-create-submit)))

(ert-deftest ogent-issues-transient-test-create-cancel-defined ()
  "Test that create cancel function is defined."
  (should (fboundp 'ogent-issues-create-cancel)))

;;; Filter Apply Tests

(ert-deftest ogent-issues-transient-test-filter-apply-defined ()
  "Test that filter apply function is defined."
  (should (fboundp 'ogent-issues-filter-apply)))

;;; Context Capture Tests

(ert-deftest ogent-issues-transient-test-capture-context-nil-no-file ()
  "Test that context capture returns nil when not visiting a file."
  (with-temp-buffer
    (should-not (ogent-issues--capture-context))))

(ert-deftest ogent-issues-transient-test-capture-context-with-file ()
  "Test that context capture works with a file buffer."
  (let ((temp-file (make-temp-file "ogent-test" nil ".el")))
    (unwind-protect
        (with-current-buffer (find-file-noselect temp-file)
          (insert "(defun test-func ()\n  \"Test.\")\n")
          (goto-char (point-min))
          (forward-line 1)
          (let ((context (ogent-issues--capture-context)))
            (should context)
            (should (plist-get context :file))
            (should (= (plist-get context :line) 2))
            (should (plist-get context :formatted))
            (should (string-match-p ":2" (plist-get context :formatted)))))
      (delete-file temp-file))))

(ert-deftest ogent-issues-transient-test-format-context-nil ()
  "Test that format context handles nil gracefully."
  (should-not (ogent-issues--format-context-for-description nil)))

(ert-deftest ogent-issues-transient-test-format-context-basic ()
  "Test context formatting produces markdown."
  (let ((context '(:file "src/foo.el" :line 42 :function nil :formatted "src/foo.el:42")))
    (let ((formatted (ogent-issues--format-context-for-description context)))
      (should (string-match-p "\\*\\*Context:\\*\\*" formatted))
      (should (string-match-p "src/foo.el:42" formatted)))))

(ert-deftest ogent-issues-transient-test-format-context-with-function ()
  "Test context formatting includes function name."
  (let ((context '(:file "src/foo.el" :line 42 :function "my-func" :formatted "src/foo.el:42 (my-func)")))
    (let ((formatted (ogent-issues--format-context-for-description context)))
      (should (string-match-p "my-func" formatted)))))

(ert-deftest ogent-issues-transient-test-create-full-sets-context ()
  "Test that create-full sets the context local variable."
  ;; Mock transient-args to avoid transient dependency in test
  (cl-letf (((symbol-function 'transient-args) (lambda (_) nil))
            ((symbol-function 'transient-arg-value) (lambda (_ _) nil)))
    (with-temp-buffer
      (let ((temp-file (make-temp-file "ogent-test" nil ".el")))
        (unwind-protect
            (progn
              (find-file temp-file)
              (insert "test content")
              (ogent-issues-create-full)
              (with-current-buffer "*ogent-issue-create*"
                ;; Context should be set
                (should (boundp 'ogent-issues-create--context))
                ;; Buffer should contain context section
                (should (string-match-p "Context" (buffer-string)))
                (kill-buffer)))
          (delete-file temp-file))))))

;;; Stats Refresh Tests

(ert-deftest ogent-issues-transient-test-refresh-stats-counts ()
  "Test refresh-stats counts issues by status."
  (let ((ogent-issues--issues
         (list '(:id "a" :status "open" :deps nil)
               '(:id "b" :status "open" :deps nil)
               '(:id "c" :status "in_progress")
               '(:id "d" :status "blocked")
               '(:id "e" :status "closed")))
        (ogent-issues-transient--cached-stats nil))
    (cl-letf (((symbol-function 'ogent-issues--issue-ready-p)
               (lambda (issue) (equal (plist-get issue :status) "open"))))
      (ogent-issues-transient--refresh-stats)
      (should ogent-issues-transient--cached-stats)
      (should (= (plist-get ogent-issues-transient--cached-stats :open) 2))
      (should (= (plist-get ogent-issues-transient--cached-stats :in-progress) 1))
      (should (= (plist-get ogent-issues-transient--cached-stats :blocked) 1))
      (should (= (plist-get ogent-issues-transient--cached-stats :closed) 1))
      (should (= (plist-get ogent-issues-transient--cached-stats :ready) 2))
      (should (= (plist-get ogent-issues-transient--cached-stats :total) 5)))))

(ert-deftest ogent-issues-transient-test-refresh-stats-nil-issues ()
  "Test refresh-stats handles nil issues list."
  (let ((ogent-issues--issues nil)
        (ogent-issues-transient--cached-stats nil))
    (ogent-issues-transient--refresh-stats)
    ;; Should not have set stats
    (should-not ogent-issues-transient--cached-stats)))

(ert-deftest ogent-issues-transient-test-refresh-stats-no-blocked ()
  "Test refresh-stats works with zero blocked issues."
  (let ((ogent-issues--issues
         (list '(:id "a" :status "open")
               '(:id "b" :status "closed")))
        (ogent-issues-transient--cached-stats nil))
    (cl-letf (((symbol-function 'ogent-issues--issue-ready-p)
               (lambda (_) nil)))
      (ogent-issues-transient--refresh-stats)
      (should (= (plist-get ogent-issues-transient--cached-stats :blocked) 0)))))

;;; Create Submit Tests

(ert-deftest ogent-issues-transient-test-create-submit-parses-content ()
  "Test create-submit parses buffer content for title and type."
  (let ((created-title nil)
        (created-type nil))
    (with-temp-buffer
      (ogent-issues-create-mode)
      (insert "# New Issue\n\n")
      (insert "Title: My Test Issue\n")
      (insert "Type: bug\n")
      (insert "Priority: 1\n")
      (insert "Labels: \n")
      (insert "Parent: \n")
      (insert "\n## Description\n\n")
      (insert "A bug description\n\n")
      (insert "<!-- C-c C-c to create, C-c C-k to cancel -->\n")
      (cl-letf (((symbol-function 'ogent-issues-bd-create)
                 (lambda (title callback &rest props)
                   (setq created-title title)
                   (setq created-type (plist-get props :type))
                   (funcall callback '(:id "new-001"))))
                ((symbol-function 'ogent-issues-bd-check-requirements)
                 (lambda () nil))
                ((symbol-function 'ogent-issues-refresh)
                 (lambda () nil))
                ((symbol-function 'message)
                 (lambda (&rest _) nil)))
        (ogent-issues-create-submit)
        (should (equal created-title "My Test Issue"))
        (should (equal created-type "bug"))))))

(ert-deftest ogent-issues-transient-test-create-submit-empty-title ()
  "Test create-submit errors on empty title."
  (with-temp-buffer
    (ogent-issues-create-mode)
    (insert "# New Issue\n\nTitle: \nType: task\nPriority: 2\n")
    (insert "Labels: \nParent: \n\n## Description\n\n\n\n<!-- end -->\n")
    (should-error (ogent-issues-create-submit) :type 'user-error)))

;;; Create Epic Test

(ert-deftest ogent-issues-transient-test-create-epic-empty-title ()
  "Test create-epic errors on empty title."
  (cl-letf (((symbol-function 'read-string)
             (lambda (_prompt &rest _) "")))
    (should-error (ogent-issues-create-epic) :type 'user-error)))

;;; Header Formatting with Stats

(ert-deftest ogent-issues-transient-test-format-header-with-stats ()
  "Test header formatting includes stats when available."
  (let ((ogent-issues--issues
         (list '(:id "a" :status "open")
               '(:id "b" :status "in_progress")))
        (ogent-issues--current-view 'list))
    (cl-letf (((symbol-function 'ogent-issues--current-issue)
               (lambda () nil))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda () "test-project"))
              ((symbol-function 'ogent-issues--issue-ready-p)
               (lambda (_) nil)))
      (let ((header (ogent-issues-transient--format-header)))
        ;; Should contain stats
        (should (string-match-p "open" header))
        (should (string-match-p "in-progress" header))))))

(provide 'ogent-issues-transient-tests)

;;; ogent-issues-transient-tests.el ends here
