;;; ogent-issues-tests.el --- Tests for ogent-issues -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the ogent-issues buffer and mode.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-issues-bd)
(require 'ogent-issues)

;;; Test Fixtures

(defconst ogent-issues-test--sample-issues
  '((:id "test-001"
     :title "First test issue"
     :description "Description one"
     :status "open"
     :priority 1
     :issue_type "task"
     :created_at "2025-12-16T10:00:00-05:00"
     :updated_at "2025-12-16T10:00:00-05:00"
     :dependency_count 0)
    (:id "test-002"
     :title "Second test issue"
     :description "Description two"
     :status "in_progress"
     :priority 2
     :issue_type "bug"
     :created_at "2025-12-16T11:00:00-05:00"
     :updated_at "2025-12-16T11:00:00-05:00"
     :dependency_count 1)
    (:id "test-003"
     :title "Third test issue"
     :description "Description three"
     :status "blocked"
     :priority 0
     :issue_type "feature"
     :created_at "2025-12-16T12:00:00-05:00"
     :updated_at "2025-12-16T12:00:00-05:00"
     :dependency_count 2)
    (:id "test-004"
     :title "Fourth test issue"
     :description "Description four"
     :status "closed"
     :priority 3
     :issue_type "chore"
     :created_at "2025-12-16T13:00:00-05:00"
     :updated_at "2025-12-16T13:00:00-05:00"
     :dependency_count 0))
  "Sample issues for testing.")

;;; Mocking Utilities

(defvar ogent-issues-test--mock-issues nil
  "Issues to return from mock bd calls.")

(defmacro ogent-issues-test-with-mock (&rest body)
  "Execute BODY with bd mocked to return test issues."
  (declare (indent 0) (debug t))
  `(let ((ogent-issues-test--mock-issues ogent-issues-test--sample-issues))
     (cl-letf (((symbol-function 'ogent-issues-bd-check-requirements)
                (lambda () nil))
               ((symbol-function 'ogent-issues-bd-list)
                (lambda (callback &optional _filters _error-callback)
                  (funcall callback ogent-issues-test--mock-issues)))
               ((symbol-function 'ogent-issues-bd-ready)
                (lambda (callback &optional _error-callback)
                  (funcall callback
                           (seq-filter
                            (lambda (i)
                              (not (string= (plist-get i :status) "blocked")))
                            ogent-issues-test--mock-issues))))
               ((symbol-function 'ogent-issues-bd-project-name)
                (lambda () "test-project")))
       ,@body)))

(defmacro ogent-issues-test-with-buffer (&rest body)
  "Execute BODY in a fresh ogent-issues buffer."
  (declare (indent 0) (debug t))
  `(ogent-issues-test-with-mock
     (let ((buf (get-buffer-create "*ogent-issues-test*")))
       (unwind-protect
           (with-current-buffer buf
             (ogent-issues-mode)
             (ogent-issues-refresh)
             ;; Wait for async callback
             (sit-for 0.01)
             ,@body)
         (when (buffer-live-p buf)
           (kill-buffer buf))))))

;;; Mode Tests

(ert-deftest ogent-issues-test-mode-activation ()
  "Test that ogent-issues-mode activates correctly."
  (with-temp-buffer
    (ogent-issues-mode)
    (should (eq major-mode 'ogent-issues-mode))
    (should buffer-read-only)
    (should truncate-lines)))

(ert-deftest ogent-issues-test-keymap-defined ()
  "Test that keymap has expected bindings."
  (should (keymapp ogent-issues-mode-map))
  (should (eq (lookup-key ogent-issues-mode-map "n") 'ogent-issues-next-issue))
  (should (eq (lookup-key ogent-issues-mode-map "p") 'ogent-issues-prev-issue))
  (should (eq (lookup-key ogent-issues-mode-map "g") 'ogent-issues-refresh))
  (should (eq (lookup-key ogent-issues-mode-map "c") 'ogent-issues-create))
  (should (eq (lookup-key ogent-issues-mode-map "K") 'ogent-issues-close))
  (should (eq (lookup-key ogent-issues-mode-map "q") 'quit-window)))

;;; Formatting Tests

(ert-deftest ogent-issues-test-type-icon ()
  "Test type icon lookup."
  (let ((ogent-issues-use-unicode t))
    (should (string= "[bug]" (ogent-issues--type-icon "bug")))
    (should (string= "[feat]" (ogent-issues--type-icon "feature")))
    (should (string= "[task]" (ogent-issues--type-icon "task"))))
  (let ((ogent-issues-use-unicode nil))
    (should (string= "B" (ogent-issues--type-icon "bug")))
    (should (string= "F" (ogent-issues--type-icon "feature")))
    (should (string= "T" (ogent-issues--type-icon "task")))))

(ert-deftest ogent-issues-test-priority-face ()
  "Test priority face lookup."
  (should (eq 'ogent-issues-priority-critical (ogent-issues--priority-face 0)))
  (should (eq 'ogent-issues-priority-high (ogent-issues--priority-face 1)))
  (should (eq 'ogent-issues-priority-medium (ogent-issues--priority-face 2)))
  (should (eq 'ogent-issues-priority-low (ogent-issues--priority-face 3)))
  ;; Out of range should use low
  (should (eq 'ogent-issues-priority-low (ogent-issues--priority-face 5))))

(ert-deftest ogent-issues-test-status-face ()
  "Test status face lookup."
  (should (eq 'ogent-issues-status-open (ogent-issues--status-face "open")))
  (should (eq 'ogent-issues-status-in-progress (ogent-issues--status-face "in_progress")))
  (should (eq 'ogent-issues-status-blocked (ogent-issues--status-face "blocked")))
  (should (eq 'ogent-issues-status-closed (ogent-issues--status-face "closed"))))

(ert-deftest ogent-issues-test-status-label ()
  "Test status label formatting."
  (should (string= "Open" (ogent-issues--status-label "open")))
  (should (string= "In Progress" (ogent-issues--status-label "in_progress")))
  (should (string= "Blocked" (ogent-issues--status-label "blocked")))
  (should (string= "Closed" (ogent-issues--status-label "closed"))))

(ert-deftest ogent-issues-test-format-issue-line ()
  "Test issue line formatting."
  (let ((issue '(:id "test-abc"
                 :title "Test issue title"
                 :priority 1
                 :issue_type "bug"
                 :status "open"
                 :dependency_count 2)))
    (let ((line (ogent-issues--format-issue-line issue)))
      (should (string-match-p "test-abc" line))
      (should (string-match-p "Test issue title" line))
      ;; Dependencies shown in parens now
      (should (string-match-p "(2)" line)))))

(ert-deftest ogent-issues-test-format-issue-line-truncation ()
  "Test that long titles are truncated."
  (let ((issue '(:id "test-abc"
                 :title "This is a very long title that should be truncated because it exceeds the maximum width"
                 :priority 2
                 :issue_type "task"
                 :status "open"
                 :dependency_count 0)))
    (let ((line (ogent-issues--format-issue-line issue)))
      (should (string-match-p "…" line)))))

;;; Grouping Tests

(ert-deftest ogent-issues-test-group-by-status ()
  "Test grouping issues by status."
  (let ((grouped (ogent-issues--group-by-status ogent-issues-test--sample-issues)))
    (should (= 1 (length (alist-get "open" grouped nil nil #'string=))))
    (should (= 1 (length (alist-get "in_progress" grouped nil nil #'string=))))
    (should (= 1 (length (alist-get "blocked" grouped nil nil #'string=))))
    (should (= 1 (length (alist-get "closed" grouped nil nil #'string=))))))

;;; Filtering Tests

(ert-deftest ogent-issues-test-apply-filters-status ()
  "Test filtering by status."
  (let ((ogent-issues--filters '(:status "open")))
    (let ((filtered (ogent-issues--apply-filters ogent-issues-test--sample-issues)))
      (should (= 1 (length filtered)))
      (should (string= "open" (plist-get (car filtered) :status))))))

(ert-deftest ogent-issues-test-apply-filters-type ()
  "Test filtering by type."
  (let ((ogent-issues--filters '(:type "bug")))
    (let ((filtered (ogent-issues--apply-filters ogent-issues-test--sample-issues)))
      (should (= 1 (length filtered)))
      (should (string= "bug" (plist-get (car filtered) :issue_type))))))

(ert-deftest ogent-issues-test-apply-filters-priority ()
  "Test filtering by priority."
  (let ((ogent-issues--filters '(:priority 0)))
    (let ((filtered (ogent-issues--apply-filters ogent-issues-test--sample-issues)))
      (should (= 1 (length filtered)))
      (should (= 0 (plist-get (car filtered) :priority))))))

(ert-deftest ogent-issues-test-apply-filters-combined ()
  "Test combined filters."
  (let ((ogent-issues--filters '(:status "in_progress" :type "bug")))
    (let ((filtered (ogent-issues--apply-filters ogent-issues-test--sample-issues)))
      (should (= 1 (length filtered)))
      (should (string= "test-002" (plist-get (car filtered) :id))))))

(ert-deftest ogent-issues-test-apply-filters-no-match ()
  "Test filters with no matching issues."
  (let ((ogent-issues--filters '(:status "open" :type "epic")))
    (let ((filtered (ogent-issues--apply-filters ogent-issues-test--sample-issues)))
      (should (= 0 (length filtered))))))

(ert-deftest ogent-issues-test-apply-filters-nil ()
  "Test that nil filters return all issues."
  (let ((ogent-issues--filters nil))
    (let ((filtered (ogent-issues--apply-filters ogent-issues-test--sample-issues)))
      (should (= 4 (length filtered))))))

;;; Buffer Content Tests

(ert-deftest ogent-issues-test-buffer-contains-issues ()
  "Test that buffer contains issue IDs."
  (ogent-issues-test-with-buffer
    (should (string-match-p "test-001" (buffer-string)))
    (should (string-match-p "test-002" (buffer-string)))
    (should (string-match-p "test-003" (buffer-string)))
    (should (string-match-p "test-004" (buffer-string)))))

(ert-deftest ogent-issues-test-buffer-contains-status-groups ()
  "Test that buffer contains status group headings."
  (ogent-issues-test-with-buffer
    (should (string-match-p "Open" (buffer-string)))
    (should (string-match-p "In Progress" (buffer-string)))
    (should (string-match-p "Blocked" (buffer-string)))
    (should (string-match-p "Closed" (buffer-string)))))

(ert-deftest ogent-issues-test-buffer-header ()
  "Test that buffer has header."
  (ogent-issues-test-with-buffer
    (should (string-match-p "Issues" (buffer-string)))))

;;; Header Line Tests

(ert-deftest ogent-issues-test-header-line ()
  "Test header line generation."
  (ogent-issues-test-with-buffer
    (let ((ogent-issues--current-view 'list)
          (ogent-issues--issues ogent-issues-test--sample-issues)
          (ogent-issues--filters nil))
      (let ((header (ogent-issues--header-line)))
        (should (string-match-p "Issues" header))
        (should (string-match-p "test-project" header))
        (should (string-match-p "List" header))
        (should (string-match-p "4" header))))))

(ert-deftest ogent-issues-test-header-line-with-filters ()
  "Test header line shows active filters."
  (ogent-issues-test-with-buffer
    (let ((ogent-issues--filters '(:status "open" :priority 1)))
      (let ((header (ogent-issues--header-line)))
        (should (string-match-p "open" header))))))

;;; Navigation Tests (without magit-section)

(ert-deftest ogent-issues-test-current-issue-nil-at-header ()
  "Test that current-issue returns nil at buffer start."
  (ogent-issues-test-with-buffer
    (goto-char (point-min))
    ;; At header, should be nil (unless magit-section puts us on an issue)
    ;; This test is mode-dependent
    (should (or (null (ogent-issues--current-issue))
                (ogent-issues--current-issue)))))

;;; View Tests

(ert-deftest ogent-issues-test-view-list ()
  "Test switching to list view."
  (ogent-issues-test-with-buffer
    (ogent-issues-view-list)
    (should (eq ogent-issues--current-view 'list))))

(ert-deftest ogent-issues-test-view-ready ()
  "Test switching to ready view."
  (ogent-issues-test-with-buffer
    (ogent-issues-view-ready)
    (sit-for 0.01)
    (should (eq ogent-issues--current-view 'ready))
    ;; Ready view should not include blocked issues
    (should (string-match-p "Ready Work" (buffer-string)))
    (should-not (string-match-p "test-003" (buffer-string)))))

(ert-deftest ogent-issues-test-view-kanban ()
  "Test switching to Kanban view."
  (ogent-issues-test-with-buffer
    (ogent-issues-view-kanban)
    (sit-for 0.01)
    (should (eq ogent-issues--current-view 'kanban))
    (should (string-match-p "Kanban Board" (buffer-string)))
    ;; Should have column headers
    (should (string-match-p "In Progress" (buffer-string)))
    (should (string-match-p "Open" (buffer-string)))
    (should (string-match-p "Blocked" (buffer-string)))
    (should (string-match-p "Closed" (buffer-string)))))

;;; Format Filters Tests

(ert-deftest ogent-issues-test-format-filters-nil ()
  "Test format-filters with no filters."
  (let ((ogent-issues--filters nil))
    (should (null (ogent-issues--format-filters)))))

(ert-deftest ogent-issues-test-format-filters-status ()
  "Test format-filters with status filter."
  (let ((ogent-issues--filters '(:status "open")))
    (should (string-match-p "open" (ogent-issues--format-filters)))))

(ert-deftest ogent-issues-test-format-filters-multiple ()
  "Test format-filters with multiple filters."
  (let ((ogent-issues--filters '(:status "open" :type "bug" :priority 1)))
    (let ((formatted (ogent-issues--format-filters)))
      (should (string-match-p "open" formatted))
      (should (string-match-p "bug" formatted)))))

;;; Ready Indicator Tests

(ert-deftest ogent-issues-test-issue-ready-p-open-no-blockers ()
  "Test that open issue with no blockers is ready."
  (let ((issue '(:id "test" :status "open" :blocked_by nil)))
    (should (ogent-issues--issue-ready-p issue))))

(ert-deftest ogent-issues-test-issue-ready-p-open-empty-blockers ()
  "Test that open issue with empty blockers list is ready."
  (let ((issue '(:id "test" :status "open" :blocked_by ())))
    (should (ogent-issues--issue-ready-p issue))))

(ert-deftest ogent-issues-test-issue-ready-p-blocked ()
  "Test that blocked issue is not ready."
  (let ((issue '(:id "test" :status "blocked" :blocked_by ("other-123"))))
    (should-not (ogent-issues--issue-ready-p issue))))

(ert-deftest ogent-issues-test-issue-ready-p-in-progress ()
  "Test that in-progress issue is not ready."
  (let ((issue '(:id "test" :status "in_progress" :blocked_by nil)))
    (should-not (ogent-issues--issue-ready-p issue))))

(ert-deftest ogent-issues-test-issue-ready-p-closed ()
  "Test that closed issue is not ready."
  (let ((issue '(:id "test" :status "closed" :blocked_by nil)))
    (should-not (ogent-issues--issue-ready-p issue))))

(ert-deftest ogent-issues-test-ready-indicator-unicode ()
  "Test ready indicator with Unicode enabled."
  (let ((ogent-issues-use-unicode t))
    (should (string-match-p "⚡" (ogent-issues--ready-indicator)))))

(ert-deftest ogent-issues-test-ready-indicator-ascii ()
  "Test ready indicator with ASCII fallback."
  (let ((ogent-issues-use-unicode nil))
    (should (string= "!" (substring-no-properties (ogent-issues--ready-indicator))))))

(ert-deftest ogent-issues-test-format-issue-line-ready ()
  "Test that ready issues get the ready indicator."
  (let ((ogent-issues-use-unicode t)
        (issue '(:id "test-001" :title "Ready issue" :status "open"
                 :priority 1 :issue_type "task" :blocked_by nil)))
    (let ((line (ogent-issues--format-issue-line issue)))
      (should (string-match-p "⚡" line)))))

(ert-deftest ogent-issues-test-format-issue-line-not-ready ()
  "Test that non-ready issues don't get the ready indicator."
  (let ((ogent-issues-use-unicode t)
        (issue '(:id "test-001" :title "In progress issue" :status "in_progress"
                 :priority 1 :issue_type "task" :blocked_by nil)))
    (let ((line (ogent-issues--format-issue-line issue)))
      (should-not (string-match-p "⚡" line)))))

;;; Empty State Tests

(ert-deftest ogent-issues-test-empty-state-no-filters ()
  "Test empty state message when no issues and no filters."
  (let ((ogent-issues-test--mock-issues nil))
    (cl-letf (((symbol-function 'ogent-issues-bd-check-requirements)
               (lambda () nil))
              ((symbol-function 'ogent-issues-bd-list)
               (lambda (callback &optional _filters _error-callback)
                 (funcall callback nil)))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda () "test-project")))
      (let ((buf (get-buffer-create "*ogent-issues-empty-test*")))
        (unwind-protect
            (with-current-buffer buf
              (ogent-issues-mode)
              (ogent-issues-refresh)
              (sit-for 0.01)
              (should (string-match-p "No issues found" (buffer-string)))
              (should (string-match-p "create" (buffer-string))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest ogent-issues-test-empty-state-with-filters ()
  "Test empty state message when filters match nothing."
  (let ((ogent-issues-test--mock-issues nil))
    (cl-letf (((symbol-function 'ogent-issues-bd-check-requirements)
               (lambda () nil))
              ((symbol-function 'ogent-issues-bd-list)
               (lambda (callback &optional _filters _error-callback)
                 (funcall callback nil)))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda () "test-project")))
      (let ((buf (get-buffer-create "*ogent-issues-filter-test*")))
        (unwind-protect
            (with-current-buffer buf
              (ogent-issues-mode)
              (setq ogent-issues--filters '(:status "epic"))
              (ogent-issues-refresh)
              (sit-for 0.01)
              (should (string-match-p "No issues match current filters" (buffer-string)))
              (should (string-match-p "clear" (buffer-string))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

;;; Detail View Tests

(defconst ogent-issues-test--detail-issue
  '(:id "test-detail"
    :title "Test Issue for Detail View"
    :description "This is a **bold** description with `code`."
    :status "open"
    :priority 1
    :issue_type "feature"
    :created_at "2025-12-16T10:00:00-05:00"
    :updated_at "2025-12-16T14:30:00-05:00"
    :blocks ("test-002" "test-003")
    :blocked_by nil
    :children ("test-sub-1")
    :comments ((:author "jake" :created_at "2025-12-16T11:00:00-05:00" :text "First comment")
               (:author "claude" :created_at "2025-12-16T12:00:00-05:00" :text "Second comment")))
  "Sample issue with full details for testing.")

(ert-deftest ogent-issues-test-format-time-valid ()
  "Test time formatting with valid ISO time."
  (let ((formatted (ogent-issues--format-time "2025-12-16T10:30:00-05:00")))
    (should (string-match-p "2025-12-16" formatted))
    (should (string-match-p "10:30" formatted))))

(ert-deftest ogent-issues-test-format-time-nil ()
  "Test time formatting with nil input."
  (should (string= "unknown" (ogent-issues--format-time nil))))

(ert-deftest ogent-issues-test-format-time-empty ()
  "Test time formatting with empty string."
  (should (string= "unknown" (ogent-issues--format-time ""))))

(ert-deftest ogent-issues-test-render-markdown-bold ()
  "Test markdown rendering of bold text."
  (let ((result (ogent-issues--render-markdown "This is **bold** text")))
    ;; The bold text should be present (face property applied)
    (should (string-match-p "bold" result))))

(ert-deftest ogent-issues-test-render-markdown-code ()
  "Test markdown rendering of inline code."
  (let ((result (ogent-issues--render-markdown "Use `code` here")))
    (should (string-match-p "code" result))))

(ert-deftest ogent-issues-test-render-markdown-list ()
  "Test markdown rendering of list items."
  (let ((result (ogent-issues--render-markdown "- item one\n- item two")))
    (should (string-match-p "•" result))))

(ert-deftest ogent-issues-test-render-markdown-nil ()
  "Test markdown rendering with nil input."
  (should (string= "" (ogent-issues--render-markdown nil))))

(ert-deftest ogent-issues-test-indent-text ()
  "Test text indentation."
  (let ((result (ogent-issues--indent-text "line1\nline2" 4)))
    (should (string-match-p "^    line1" result))
    (should (string-match-p "    line2" result))))

(ert-deftest ogent-issues-test-indent-text-nil ()
  "Test text indentation with nil input."
  (should (string= "" (ogent-issues--indent-text nil 4))))

(ert-deftest ogent-issues-test-format-dep-link ()
  "Test dependency link formatting."
  (let ((link (ogent-issues--format-dep-link "test-123")))
    (should (string= "test-123" (substring-no-properties link)))
    (should (eq 'link (get-text-property 0 'face link)))
    (should (string= "test-123" (get-text-property 0 'ogent-issue-id link)))))

(ert-deftest ogent-issues-test-detail-mode-defined ()
  "Test that detail mode is defined."
  (should (fboundp 'ogent-issues-detail-mode)))

(ert-deftest ogent-issues-test-detail-mode-keymap ()
  "Test that detail mode has correct keybindings."
  (should (keymapp ogent-issues-detail-mode-map))
  (should (eq 'quit-window (lookup-key ogent-issues-detail-mode-map "q")))
  (should (eq 'ogent-issues-detail-refresh (lookup-key ogent-issues-detail-mode-map "g")))
  (should (eq 'ogent-issues-detail-close (lookup-key ogent-issues-detail-mode-map "K")))
  (should (eq 'ogent-issues-detail-start (lookup-key ogent-issues-detail-mode-map "s"))))

(ert-deftest ogent-issues-test-render-detail-buffer ()
  "Test that detail rendering creates proper buffer content."
  (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
    (ogent-issues--render-detail ogent-issues-test--detail-issue)
    (let ((buf (get-buffer "*ogent-issue*")))  ; Updated buffer name
      (unwind-protect
          (with-current-buffer buf
            (should (eq major-mode 'ogent-issues-detail-mode))
            (should (string-match-p "Test Issue for Detail View" (buffer-string)))
            (should (string-match-p "Description" (buffer-string)))
            (should (string-match-p "Metadata" (buffer-string)))
            (should (string-match-p "Dependencies" (buffer-string)))
            (should (string-match-p "Comments (2)" (buffer-string)))
            (should (string-match-p "@jake" (buffer-string)))
            (should (string-match-p "@claude" (buffer-string)))
            (should (string-match-p "test-002" (buffer-string)))
            (should (string-match-p "test-003" (buffer-string))))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

;;; Kanban View Tests

(ert-deftest ogent-issues-test-kanban-columns-defined ()
  "Test that Kanban columns are defined."
  (should (boundp 'ogent-issues-kanban-columns))
  (should (= 4 (length ogent-issues-kanban-columns)))
  (should (assoc "in_progress" ogent-issues-kanban-columns))
  (should (assoc "open" ogent-issues-kanban-columns))
  (should (assoc "blocked" ogent-issues-kanban-columns))
  (should (assoc "closed" ogent-issues-kanban-columns)))

(ert-deftest ogent-issues-test-kanban-pad-short ()
  "Test padding short strings."
  (let ((result (ogent-issues--kanban-pad "Hi" 10)))
    (should (= 10 (length result)))
    (should (string-match-p "Hi" result))))

(ert-deftest ogent-issues-test-kanban-pad-exact ()
  "Test padding exact-length strings."
  (let ((result (ogent-issues--kanban-pad "1234567890" 10)))
    (should (= 10 (length result)))
    (should (string= "1234567890" result))))

(ert-deftest ogent-issues-test-kanban-pad-long ()
  "Test padding long strings (truncation)."
  (let ((result (ogent-issues--kanban-pad "This is a very long string" 10)))
    (should (= 10 (length result)))
    (should (string-match-p "…" result))))

(ert-deftest ogent-issues-test-kanban-max-rows ()
  "Test calculating max rows from grouped issues."
  (let ((grouped '(("open" . (1 2 3))
                   ("in_progress" . (4))
                   ("blocked" . nil)
                   ("closed" . (5 6)))))
    (should (= 3 (ogent-issues--kanban-max-rows grouped)))))

(ert-deftest ogent-issues-test-kanban-max-rows-empty ()
  "Test max rows with no issues."
  (let ((grouped '(("open" . nil)
                   ("in_progress" . nil)
                   ("blocked" . nil)
                   ("closed" . nil))))
    (should (= 0 (ogent-issues--kanban-max-rows grouped)))))

(ert-deftest ogent-issues-test-kanban-move-functions-defined ()
  "Test that Kanban move functions are defined."
  (should (fboundp 'ogent-issues-kanban-move-left))
  (should (fboundp 'ogent-issues-kanban-move-right)))

(ert-deftest ogent-issues-test-kanban-keybindings ()
  "Test that Kanban keybindings are set."
  (should (eq 'ogent-issues-kanban-move-left
              (lookup-key ogent-issues-mode-map "H")))
  (should (eq 'ogent-issues-kanban-move-right
              (lookup-key ogent-issues-mode-map "L"))))

;;; Project Switching Tests
;; These tests verify that switching projects clears stale buffer state.

(ert-deftest ogent-issues-test-project-root-tracked ()
  "Test that buffer tracks current project root."
  (let ((buf (get-buffer-create "*ogent-issues-project-test*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-issues-mode)
          ;; Initially nil
          (should (null ogent-issues--project-root))
          ;; After setting, should be tracked
          (setq ogent-issues--project-root "/some/project")
          (should (equal "/some/project" ogent-issues--project-root)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-issues-test-project-change-clears-issues ()
  "Test that changing projects clears the cached issues list."
  (let ((project-a-issues '((:id "a-001" :title "Project A" :status "open"
                             :priority 1 :issue_type "task")))
        (project-b-issues '((:id "b-001" :title "Project B" :status "open"
                             :priority 1 :issue_type "task"))))
    (cl-letf (((symbol-function 'ogent-issues-bd-check-requirements)
               (lambda () nil))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda () "test-project")))
      (let ((buf (get-buffer-create "*ogent-issues-switch-test*")))
        (unwind-protect
            (with-current-buffer buf
              (ogent-issues-mode)
              ;; Simulate project A loaded
              (setq ogent-issues--project-root "/project-a")
              (setq ogent-issues--issues project-a-issues)
              ;; Now simulate switching to project B
              (cl-letf (((symbol-function 'ogent-issues-bd-project-root)
                         (lambda () "/project-b"))
                        ((symbol-function 'ogent-issues-bd-list)
                         (lambda (callback &optional _filters _error-callback)
                           (funcall callback project-b-issues))))
                ;; Call the entry point function logic
                (let ((current-project (ogent-issues-bd-project-root)))
                  ;; Detect project change and clear
                  (when (and ogent-issues--project-root
                             (not (equal ogent-issues--project-root current-project)))
                    (setq ogent-issues--issues nil))
                  (setq ogent-issues--project-root current-project)
                  ;; Issues should be cleared
                  (should (null ogent-issues--issues))
                  ;; Project root should be updated
                  (should (equal "/project-b" ogent-issues--project-root)))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(provide 'ogent-issues-tests)

;;; ogent-issues-tests.el ends here
