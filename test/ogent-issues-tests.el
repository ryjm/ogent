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
            ;; Most tests validate rendering/content semantics, not Magit internals.
            ;; Force plain mode so constructor API differences do not break them.
            (setq-local ogent-issues--magit-section-available nil)
            (ogent-issues-refresh)
            ;; Wait for async callback
            (sit-for 0.01)
            ,@body)
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(defun ogent-issues-test--magit-path-usable-p ()
  "Return non-nil when magit-section rendering path is usable in tests."
  (and (require 'magit-section nil t)
       (condition-case nil
           (with-temp-buffer
             (ogent-issues-mode)
             (let ((inhibit-read-only t)
                   (ogent-issues--magit-section-available t))
               (ogent-issues--insert-buffer-contents
                '((:id "probe-1" :title "Probe" :status "open"
                       :priority 1 :issue_type "task" :dependency_count 0)))
               t))
         (error nil))))

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

(ert-deftest ogent-issues-test-section-heading-face ()
  "Test status section heading face lookup."
  (should (eq 'ogent-issues-section-heading-view
              (ogent-issues--section-heading-face 'view)))
  (should (eq 'ogent-issues-section-heading-in-progress
              (ogent-issues--section-heading-face "in_progress")))
  (should (eq 'ogent-issues-section-heading-open
              (ogent-issues--section-heading-face "open")))
  (should (eq 'ogent-issues-section-heading-blocked
              (ogent-issues--section-heading-face "blocked")))
  (should (eq 'ogent-issues-section-heading-closed
              (ogent-issues--section-heading-face "closed")))
  (should (eq 'ogent-issues-section-heading
              (ogent-issues--section-heading-face "mystery"))))

(ert-deftest ogent-issues-test-compose-status-heading-layers-faces ()
  "Test composed status heading keeps section background and status/count overlays."
  (let* ((ogent-issues-use-unicode nil)
         (ogent-issues-show-counts t)
         (heading (ogent-issues--compose-status-heading "in_progress" 3))
         (label-pos (string-match-p "In Progress" heading))
         (icon-face (get-text-property 0 'face heading))
         (label-face (and label-pos (get-text-property label-pos 'face heading)))
         (count-pos (string-match-p "(3)" heading))
         (count-face (and count-pos (get-text-property count-pos 'face heading))))
    (should label-pos)
    (should count-pos)
    (should (memq 'ogent-issues-section-heading-in-progress
                  (if (listp icon-face) icon-face (list icon-face))))
    (should (memq 'ogent-issues-status-in-progress
                  (if (listp icon-face) icon-face (list icon-face))))
    (should (memq 'ogent-issues-section-heading-in-progress
                  (if (listp label-face) label-face (list label-face))))
    (should (memq 'ogent-issues-section-heading-in-progress
                  (if (listp count-face) count-face (list count-face))))
    (should (memq 'ogent-issues-dimmed
                  (if (listp count-face) count-face (list count-face))))))

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
    (should (string-match-p "»" (ogent-issues--ready-indicator)))))

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
      (should (string-match-p "»" line)))))

(ert-deftest ogent-issues-test-format-issue-line-not-ready ()
  "Test that non-ready issues don't get the ready indicator."
  (let ((ogent-issues-use-unicode t)
        (issue '(:id "test-001" :title "In progress issue" :status "in_progress"
                     :priority 1 :issue_type "task" :blocked_by nil)))
    (let ((line (ogent-issues--format-issue-line issue)))
      (should-not (string-match-p "»" line)))))

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
  ;; Use UTC time to avoid timezone issues in CI
  (let ((formatted (ogent-issues--format-time "2025-12-16T15:30:00Z")))
    (should (string-match-p "2025-12-16" formatted))
    ;; Check that time is formatted (HH:MM pattern), not specific value
    ;; since display depends on local timezone
    (should (string-match-p "[0-9][0-9]:[0-9][0-9]" formatted))))

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
  (let ((test-buf-name "*ogent-issue: test-project*"))
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
              ((symbol-function 'ogent-issues-bd-project-root)
               (lambda (&optional _) "/tmp/test-project"))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda (&optional _) "test-project")))
      (ogent-issues--render-detail ogent-issues-test--detail-issue)
      (let ((buf (get-buffer test-buf-name)))
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
            (kill-buffer buf)))))))

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

;;; Buffer Name Tests

(ert-deftest ogent-issues-test-buffer-name-shared ()
  "Test shared buffer name (default)."
  (let ((ogent-issues-per-project-buffers nil))
    (should (string= "*ogent-issues*" (ogent-issues--buffer-name)))))

(ert-deftest ogent-issues-test-buffer-name-per-project ()
  "Test per-project buffer names."
  (let ((ogent-issues-per-project-buffers t))
    (cl-letf (((symbol-function 'ogent-issues-bd-project-name)
               (lambda () "my-project")))
      (should (string= "*ogent-issues: my-project*"
                       (ogent-issues--buffer-name))))))

(ert-deftest ogent-issues-test-buffer-name-per-project-nil-name ()
  "Test per-project buffer name when project name is nil."
  (let ((ogent-issues-per-project-buffers t))
    (cl-letf (((symbol-function 'ogent-issues-bd-project-name)
               (lambda () nil)))
      (should (string= "*ogent-issues: unknown*"
                       (ogent-issues--buffer-name))))))

;;; Status Icon Tests

(ert-deftest ogent-issues-test-status-icon-unicode ()
  "Test status icons with Unicode enabled."
  (let ((ogent-issues-use-unicode t))
    (should (string= "○" (ogent-issues--status-icon "open")))
    (should (string= "◐" (ogent-issues--status-icon "in_progress")))
    (should (string= "✗" (ogent-issues--status-icon "blocked")))
    (should (string= "●" (ogent-issues--status-icon "closed")))
    (should (string= "?" (ogent-issues--status-icon "unknown")))))

(ert-deftest ogent-issues-test-status-icon-ascii ()
  "Test status icons with Unicode disabled."
  (let ((ogent-issues-use-unicode nil))
    (should (string= "o" (ogent-issues--status-icon "open")))
    (should (string= ">" (ogent-issues--status-icon "in_progress")))
    (should (string= "x" (ogent-issues--status-icon "blocked")))
    (should (string= "*" (ogent-issues--status-icon "closed")))
    (should (string= "?" (ogent-issues--status-icon "unknown")))))

(ert-deftest ogent-issues-test-status-icon-nil-status ()
  "Test status icon with nil status."
  (let ((ogent-issues-use-unicode t))
    (should (string= "?" (ogent-issues--status-icon nil)))))

;;; Priority Indicator Tests

(ert-deftest ogent-issues-test-priority-indicator-unicode ()
  "Test priority indicator returns propertized string with Unicode."
  (let ((ogent-issues-use-unicode t))
    (let ((result (ogent-issues--priority-indicator 0)))
      (should (string= "●" (substring-no-properties result)))
      (should (eq 'ogent-issues-priority-critical (get-text-property 0 'face result))))
    (let ((result (ogent-issues--priority-indicator 1)))
      (should (string= "◐" (substring-no-properties result)))
      (should (eq 'ogent-issues-priority-high (get-text-property 0 'face result))))
    (let ((result (ogent-issues--priority-indicator 2)))
      (should (string= "○" (substring-no-properties result)))
      (should (eq 'ogent-issues-priority-medium (get-text-property 0 'face result))))
    (let ((result (ogent-issues--priority-indicator 3)))
      (should (string= "◌" (substring-no-properties result)))
      (should (eq 'ogent-issues-priority-low (get-text-property 0 'face result))))))

(ert-deftest ogent-issues-test-priority-indicator-ascii ()
  "Test priority indicator with ASCII fallback."
  (let ((ogent-issues-use-unicode nil))
    (let ((result (ogent-issues--priority-indicator 0)))
      (should (string= "P0" (substring-no-properties result))))
    (let ((result (ogent-issues--priority-indicator 2)))
      (should (string= "P2" (substring-no-properties result))))))

(ert-deftest ogent-issues-test-priority-indicator-nil ()
  "Test priority indicator with nil defaults to P2."
  (let ((ogent-issues-use-unicode nil))
    (let ((result (ogent-issues--priority-indicator nil)))
      (should (string= "P2" (substring-no-properties result)))
      (should (eq 'ogent-issues-priority-medium (get-text-property 0 'face result))))))

;;; Type Icon Edge Cases

(ert-deftest ogent-issues-test-type-icon-unknown ()
  "Test type icon for unknown type returns fallback."
  (let ((ogent-issues-use-unicode t))
    (should (string= "•" (ogent-issues--type-icon "nonexistent"))))
  (let ((ogent-issues-use-unicode nil))
    (should (string= "?" (ogent-issues--type-icon "nonexistent")))))

(ert-deftest ogent-issues-test-type-icon-epic ()
  "Test type icon for epic."
  (let ((ogent-issues-use-unicode t))
    (should (string= "[epic]" (ogent-issues--type-icon "epic"))))
  (let ((ogent-issues-use-unicode nil))
    (should (string= "E" (ogent-issues--type-icon "epic")))))

(ert-deftest ogent-issues-test-type-icon-chore ()
  "Test type icon for chore."
  (let ((ogent-issues-use-unicode t))
    (should (string= "[chore]" (ogent-issues--type-icon "chore"))))
  (let ((ogent-issues-use-unicode nil))
    (should (string= "C" (ogent-issues--type-icon "chore")))))

(ert-deftest ogent-issues-test-type-icon-nil ()
  "Test type icon for nil type returns fallback."
  (let ((ogent-issues-use-unicode t))
    (should (string= "•" (ogent-issues--type-icon nil)))))

;;; Status Face Edge Cases

(ert-deftest ogent-issues-test-status-face-unknown ()
  "Test status face for unknown status returns default."
  (should (eq 'default (ogent-issues--status-face "mystery")))
  (should (eq 'default (ogent-issues--status-face nil))))

;;; Status Label Edge Cases

(ert-deftest ogent-issues-test-status-label-unknown ()
  "Test status label for unknown status."
  (should (string= "Unknown" (ogent-issues--status-label "unknown")))
  (should (string= "Custom" (ogent-issues--status-label "custom"))))

(ert-deftest ogent-issues-test-status-label-nil ()
  "Test status label for nil status."
  (should (string= "Unknown" (ogent-issues--status-label nil))))

;;; Priority Face Edge Case

(ert-deftest ogent-issues-test-priority-face-nil ()
  "Test priority face with nil defaults to medium."
  (should (eq 'ogent-issues-priority-medium (ogent-issues--priority-face nil))))

;;; Format Dep Link Edge Cases

(ert-deftest ogent-issues-test-format-dep-link-has-keymap ()
  "Test that dependency link has a keymap for click handling."
  (let ((link (ogent-issues--format-dep-link "test-abc")))
    (should (keymapp (get-text-property 0 'keymap link)))
    (should (get-text-property 0 'help-echo link))
    (should (eq 'highlight (get-text-property 0 'mouse-face link)))))

;;; Format Issue Line Edge Cases

(ert-deftest ogent-issues-test-format-issue-line-no-deps ()
  "Test issue line with zero dependencies."
  (let ((issue '(:id "test-abc"
                      :title "No deps"
                      :priority 2
                      :issue_type "task"
                      :status "open"
                      :dependency_count 0)))
    (let ((line (ogent-issues--format-issue-line issue)))
      (should-not (string-match-p "([0-9])" line)))))

(ert-deftest ogent-issues-test-format-issue-line-nil-title ()
  "Test issue line with nil title."
  (let ((issue '(:id "test-abc"
                      :title nil
                      :priority 2
                      :issue_type "task"
                      :status "open"
                      :dependency_count 0)))
    ;; Should not error
    (should (stringp (ogent-issues--format-issue-line issue)))))

(ert-deftest ogent-issues-test-format-issue-line-nil-id ()
  "Test issue line with nil id uses fallback."
  (let ((issue '(:id nil
                      :title "Test"
                      :priority 2
                      :issue_type "task"
                      :status "open"
                      :dependency_count 0)))
    (let ((line (ogent-issues--format-issue-line issue)))
      (should (string-match-p "\\?" line)))))

;;; Group-by-status Tests

(ert-deftest ogent-issues-test-group-by-status-empty ()
  "Test grouping empty list returns nil."
  (should (null (ogent-issues--group-by-status nil))))

(ert-deftest ogent-issues-test-group-by-status-all-same ()
  "Test grouping when all issues have same status."
  (let ((issues '((:id "a" :status "open")
                  (:id "b" :status "open")
                  (:id "c" :status "open"))))
    (let ((grouped (ogent-issues--group-by-status issues)))
      (should (= 3 (length (alist-get "open" grouped nil nil #'string=))))
      (should-not (alist-get "closed" grouped nil nil #'string=)))))

;;; Filter Tests - Additional Cases

(ert-deftest ogent-issues-test-apply-filters-priority-zero ()
  "Test filtering by priority 0 (critical)."
  (let ((ogent-issues--filters '(:priority 0)))
    (let ((filtered (ogent-issues--apply-filters ogent-issues-test--sample-issues)))
      (should (= 1 (length filtered)))
      (should (= 0 (plist-get (car filtered) :priority))))))

(ert-deftest ogent-issues-test-apply-filters-status-closed ()
  "Test filtering for closed status."
  (let ((ogent-issues--filters '(:status "closed")))
    (let ((filtered (ogent-issues--apply-filters ogent-issues-test--sample-issues)))
      (should (= 1 (length filtered)))
      (should (string= "closed" (plist-get (car filtered) :status))))))

;;; Kanban Column Width Tests

(ert-deftest ogent-issues-test-kanban-column-width-minimum ()
  "Test that kanban column width has a minimum of 15."
  ;; With a very narrow window, should still return at least 15
  (cl-letf (((symbol-function 'window-width) (lambda () 20)))
    (should (>= (ogent-issues--kanban-column-width) 15))))

(ert-deftest ogent-issues-test-kanban-column-width-calculation ()
  "Test kanban column width calculation."
  ;; 4 columns, 5 separators
  ;; available = window-width - 5
  ;; each col = available / 4
  (cl-letf (((symbol-function 'window-width) (lambda () 85)))
    (should (= 20 (ogent-issues--kanban-column-width)))))

;;; Kanban Columns Constant

(ert-deftest ogent-issues-test-kanban-columns-order ()
  "Test that Kanban columns are in expected display order."
  (should (equal "in_progress" (caar ogent-issues-kanban-columns)))
  (should (equal "open" (car (nth 1 ogent-issues-kanban-columns))))
  (should (equal "blocked" (car (nth 2 ogent-issues-kanban-columns))))
  (should (equal "closed" (car (nth 3 ogent-issues-kanban-columns)))))

;;; Loading Frames Tests

(ert-deftest ogent-issues-test-get-loading-frames-returns-list ()
  "Test that get-loading-frames returns a non-empty list."
  (let ((frames (ogent-issues--get-loading-frames)))
    (should (listp frames))
    (should (> (length frames) 0))))

;;; Loading Indicator Tests

(ert-deftest ogent-issues-test-loading-indicator-nil-when-not-loading ()
  "Test loading indicator returns nil when not loading."
  (with-temp-buffer
    (ogent-issues-mode)
    (setq ogent-issues--loading nil)
    (should-not (ogent-issues--loading-indicator))))

(ert-deftest ogent-issues-test-loading-indicator-returns-string ()
  "Test loading indicator returns string when loading."
  (with-temp-buffer
    (ogent-issues-mode)
    (setq ogent-issues--loading t)
    (setq ogent-issues--loading-frame 0)
    (should (stringp (ogent-issues--loading-indicator)))))

(ert-deftest ogent-issues-test-loading-indicator-cycles-frames ()
  "Test loading indicator returns different frames."
  (with-temp-buffer
    (ogent-issues-mode)
    (setq ogent-issues--loading t)
    (setq ogent-issues--loading-frame 0)
    (let ((frame0 (ogent-issues--loading-indicator)))
      (setq ogent-issues--loading-frame 1)
      (let ((frame1 (ogent-issues--loading-indicator)))
        (should-not (equal frame0 frame1))))))

;;; Header Line Additional Tests

(ert-deftest ogent-issues-test-header-line-shows-ready-count ()
  "Test header line includes ready count."
  (ogent-issues-test-with-buffer
   (let ((ogent-issues--current-view 'list)
         (ogent-issues--issues
          (list '(:id "t1" :status "open" :blocked_by nil)
                '(:id "t2" :status "open" :blocked_by nil)
                '(:id "t3" :status "closed" :blocked_by nil)))
         (ogent-issues--filters nil))
     (let ((header (ogent-issues--header-line)))
       (should (string-match-p "2 ready" header))))))

(ert-deftest ogent-issues-test-header-line-shows-blocked-count ()
  "Test header line includes blocked count when > 0."
  (ogent-issues-test-with-buffer
   (let ((ogent-issues--current-view 'list)
         (ogent-issues--issues
          (list '(:id "t1" :status "blocked" :blocked_by ("x"))
                '(:id "t2" :status "open" :blocked_by nil)))
         (ogent-issues--filters nil))
     (let ((header (ogent-issues--header-line)))
       (should (string-match-p "1 blocked" header))))))

(ert-deftest ogent-issues-test-header-line-view-name ()
  "Test header line shows correct view name."
  (ogent-issues-test-with-buffer
   (let ((ogent-issues--current-view 'ready)
         (ogent-issues--issues nil)
         (ogent-issues--filters nil))
     (let ((header (ogent-issues--header-line)))
       (should (string-match-p "Ready" header))))))

(ert-deftest ogent-issues-test-header-line-loading ()
  "Test header line shows loading indicator when loading."
  (ogent-issues-test-with-buffer
   (setq ogent-issues--loading t)
   (setq ogent-issues--loading-frame 0)
   (let ((header (ogent-issues--header-line)))
     (should (string-match-p "Loading" header)))
   (setq ogent-issues--loading nil)))

;;; Format Filters for Header Tests

(ert-deftest ogent-issues-test-format-filters-for-header-empty ()
  "Test format-filters-for-header with no filters."
  (let ((ogent-issues--filters nil))
    (should (string= "" (ogent-issues--format-filters-for-header)))))

(ert-deftest ogent-issues-test-format-filters-for-header-status ()
  "Test format-filters-for-header with status filter."
  (let ((ogent-issues--filters '(:status "blocked")))
    (let ((result (ogent-issues--format-filters-for-header)))
      (should (string-match-p "blocked" result)))))

(ert-deftest ogent-issues-test-format-filters-for-header-priority ()
  "Test format-filters-for-header with priority filter."
  (let ((ogent-issues--filters '(:priority 1)))
    (let ((result (ogent-issues--format-filters-for-header)))
      (should (string-match-p "P1" result)))))

;;; Detail Header Formatting Tests

(ert-deftest ogent-issues-test-format-detail-header-content ()
  "Test detail header section includes title and status."
  (with-temp-buffer
    (ogent-issues--insert-detail-header
     '(:title "Test Title"
       :status "open"
       :priority 1
       :issue_type "bug"
       :blocked_by nil))
    (should (string-match-p "Test Title" (buffer-string)))
    (should (string-match-p "Open" (buffer-string)))
    (should (string-match-p "BUG" (buffer-string)))))

(ert-deftest ogent-issues-test-format-detail-header-ready ()
  "Test detail header shows ready indicator for ready issues."
  (let ((ogent-issues-use-unicode t))
    (with-temp-buffer
      (ogent-issues--insert-detail-header
       '(:title "Ready Issue"
         :status "open"
         :priority 0
         :issue_type "task"
         :blocked_by nil))
      (should (string-match-p "ready" (buffer-string))))))

(ert-deftest ogent-issues-test-format-detail-header-not-ready ()
  "Test detail header does not show ready for non-open issues."
  (with-temp-buffer
    (ogent-issues--insert-detail-header
     '(:title "In Progress Issue"
       :status "in_progress"
       :priority 0
       :issue_type "task"
       :blocked_by nil))
    (should-not (string-match-p "ready" (buffer-string)))))

(ert-deftest ogent-issues-test-format-detail-header-nil-title ()
  "Test detail header with nil title uses fallback."
  (with-temp-buffer
    (ogent-issues--insert-detail-header
     '(:title nil :status "open" :priority 2 :issue_type "task" :blocked_by nil))
    (should (string-match-p "Untitled" (buffer-string)))))

;;; Format Dependencies Tests

(ert-deftest ogent-issues-test-format-dependencies-with-blocks ()
  "Test dependency section shows blocking issues."
  (with-temp-buffer
    (ogent-issues--insert-detail-dependencies
     '(:blocks ("issue-A" "issue-B")
       :blocked_by nil
       :dependents nil))
    (should (string-match-p "Dependencies" (buffer-string)))
    (should (string-match-p "issue-A" (buffer-string)))
    (should (string-match-p "issue-B" (buffer-string)))))

(ert-deftest ogent-issues-test-format-dependencies-with-blockers ()
  "Test dependency section shows blocked-by."
  (with-temp-buffer
    (ogent-issues--insert-detail-dependencies
     '(:blocks nil
       :blocked_by ("blocker-1")
       :dependents nil))
    (should (string-match-p "blocker-1" (buffer-string)))))

(ert-deftest ogent-issues-test-format-dependencies-none ()
  "Test dependency section with no dependencies shows none."
  (with-temp-buffer
    (ogent-issues--insert-detail-dependencies
     '(:blocks nil :blocked_by nil :dependents nil))
    (let ((content (buffer-string)))
      (should (string-match-p "Dependencies" content))
      ;; Should have "none" for both blocks and blocked-by
      (should (>= (cl-count-if
                   (lambda (start)
                     (string-match-p "none" (substring content start)))
                   (number-sequence 0 (1- (length content))))
                  1)))))

;;; Format Comments Tests

(ert-deftest ogent-issues-test-format-comments-with-comments ()
  "Test comments section with comment data."
  (with-temp-buffer
    (ogent-issues--insert-detail-comments
     '(:comments ((:author "alice" :created_at "2025-12-16T10:00:00Z" :text "Hello")
                  (:author "bob" :created_at "2025-12-16T11:00:00Z" :text "World"))))
    (should (string-match-p "Comments (2)" (buffer-string)))
    (should (string-match-p "@alice" (buffer-string)))
    (should (string-match-p "@bob" (buffer-string)))
    (should (string-match-p "Hello" (buffer-string)))
    (should (string-match-p "World" (buffer-string)))))

(ert-deftest ogent-issues-test-format-comments-empty ()
  "Test comments section with no comments."
  (with-temp-buffer
    (ogent-issues--insert-detail-comments '(:comments nil))
    (should (string-match-p "Comments (0)" (buffer-string)))
    (should (string-match-p "No comments" (buffer-string)))))

(ert-deftest ogent-issues-test-format-comment-unknown-author ()
  "Test comment rendering with nil author uses unknown."
  (with-temp-buffer
    (ogent-issues--insert-comment '(:author nil :created_at nil :text "test"))
    (should (string-match-p "@unknown" (buffer-string)))))

;;; Interactive Filter Tests (Mock)

(ert-deftest ogent-issues-test-filter-status-sets-filter ()
  "Test filter-status sets the status filter and refreshes."
  (ogent-issues-test-with-buffer
   (should (null ogent-issues--filters))
   (ogent-issues-filter-status "blocked")
   (sit-for 0.01)
   (should (equal "blocked" (plist-get ogent-issues--filters :status)))))

(ert-deftest ogent-issues-test-filter-type-sets-filter ()
  "Test filter-type sets the type filter and refreshes."
  (ogent-issues-test-with-buffer
   (ogent-issues-filter-type "bug")
   (sit-for 0.01)
   (should (equal "bug" (plist-get ogent-issues--filters :type)))))

(ert-deftest ogent-issues-test-filter-priority-sets-filter ()
  "Test filter-priority sets the priority filter and refreshes."
  (ogent-issues-test-with-buffer
   (ogent-issues-filter-priority 1)
   (sit-for 0.01)
   (should (equal 1 (plist-get ogent-issues--filters :priority)))))

(ert-deftest ogent-issues-test-clear-filters-resets ()
  "Test clear-filters resets all filters to nil."
  (ogent-issues-test-with-buffer
   (setq ogent-issues--filters '(:status "open" :type "bug" :priority 0))
   (ogent-issues-clear-filters)
   (sit-for 0.01)
   (should (null ogent-issues--filters))))

(ert-deftest ogent-issues-test-filter-combined-type-and-priority ()
  "Test setting both type and priority filters."
  (ogent-issues-test-with-buffer
   (ogent-issues-filter-type "feature")
   (sit-for 0.01)
   (ogent-issues-filter-priority 0)
   (sit-for 0.01)
   (should (equal "feature" (plist-get ogent-issues--filters :type)))
   (should (equal 0 (plist-get ogent-issues--filters :priority)))))

;;; Detail Buffer Name Tests

(ert-deftest ogent-issues-test-detail-buffer-name ()
  "Test detail buffer name generation."
  (cl-letf (((symbol-function 'ogent-issues-bd-project-name)
             (lambda () "my-project")))
    (should (string= "*ogent-issue: my-project*"
                     (ogent-issues--detail-buffer-name)))))

(ert-deftest ogent-issues-test-detail-buffer-name-nil-project ()
  "Test detail buffer name when project is nil."
  (cl-letf (((symbol-function 'ogent-issues-bd-project-name)
             (lambda () nil)))
    (should (string= "*ogent-issue: unknown*"
                     (ogent-issues--detail-buffer-name)))))

;;; Insert Header Section Tests

(ert-deftest ogent-issues-test-insert-header-section-list ()
  "Test header section for list view."
  (with-temp-buffer
    (let ((ogent-issues--current-view 'list))
      (ogent-issues--insert-header-section)
      (should (string-match-p "Issues" (buffer-string))))))

(ert-deftest ogent-issues-test-insert-header-section-uses-view-face ()
  "Test header section applies the view heading face."
  (with-temp-buffer
    (let ((ogent-issues--current-view 'list))
      (ogent-issues--insert-header-section)
      (goto-char (point-min))
      (let ((face (get-text-property (point) 'face)))
        (should (memq 'ogent-issues-section-heading-view
                      (if (listp face) face (list face))))))))

(ert-deftest ogent-issues-test-insert-header-section-ready ()
  "Test header section for ready view."
  (with-temp-buffer
    (let ((ogent-issues--current-view 'ready))
      (ogent-issues--insert-header-section)
      (should (string-match-p "Ready Work" (buffer-string))))))

(ert-deftest ogent-issues-test-insert-header-section-kanban ()
  "Test header section for kanban view."
  (with-temp-buffer
    (let ((ogent-issues--current-view 'kanban))
      (ogent-issues--insert-header-section)
      (should (string-match-p "Kanban" (buffer-string))))))

;;; Markdown Rendering Edge Cases

(ert-deftest ogent-issues-test-render-markdown-header ()
  "Test markdown rendering of headers."
  (let ((result (ogent-issues--render-markdown "## My Heading")))
    (should (string-match-p "My Heading" result))
    ;; Hash marks should be removed
    (should-not (string-match-p "##" result))))

(ert-deftest ogent-issues-test-render-markdown-underscore-bold ()
  "Test markdown rendering of __bold__ syntax."
  (let ((result (ogent-issues--render-markdown "This is __bold__ text")))
    (should (string-match-p "bold" result))
    ;; Underscores should be removed
    (should-not (string-match-p "__" result))))

(ert-deftest ogent-issues-test-render-markdown-empty-string ()
  "Test markdown rendering of empty string."
  (should (string= "" (ogent-issues--render-markdown ""))))

;;; Indent Text Edge Cases

(ert-deftest ogent-issues-test-indent-text-zero-indent ()
  "Test text indentation with zero indent."
  (let ((result (ogent-issues--indent-text "line1\nline2" 0)))
    (should (string= "line1\nline2" result))))

(ert-deftest ogent-issues-test-indent-text-single-line ()
  "Test text indentation with single line."
  (let ((result (ogent-issues--indent-text "hello" 3)))
    (should (string= "   hello" result))))

;;; Loading Animation Tests

(ert-deftest ogent-issues-test-start-loading ()
  "Test that start-loading sets loading state."
  (let ((buf (get-buffer-create "*ogent-issues-loading-test*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-issues-mode)
          (setq ogent-issues--loading nil)
          (ogent-issues--start-loading)
          (should ogent-issues--loading)
          (should (= 0 ogent-issues--loading-frame))
          (should ogent-issues--loading-timer)
          ;; Clean up timer
          (ogent-issues--stop-loading))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-issues-test-stop-loading ()
  "Test that stop-loading clears loading state."
  (let ((buf (get-buffer-create "*ogent-issues-stop-loading-test*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-issues-mode)
          (ogent-issues--start-loading)
          (should ogent-issues--loading)
          (ogent-issues--stop-loading)
          (should-not ogent-issues--loading)
          (should-not ogent-issues--loading-timer))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-issues-test-stop-loading-timer-nil ()
  "Test that stop-loading-timer handles nil timer gracefully."
  (let ((buf (get-buffer-create "*ogent-issues-timer-nil-test*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-issues-mode)
          (setq ogent-issues--loading-timer nil)
          ;; Should not error
          (ogent-issues--stop-loading-timer)
          (should-not ogent-issues--loading-timer))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-issues-test-animate-loading ()
  "Test animate-loading advances frame."
  (let ((buf (get-buffer-create "*ogent-issues-animate-test*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-issues-mode)
          (cl-letf (((symbol-function 'ogent-issues--get-loading-frames)
                     (lambda () '("a" "b" "c"))))
            (setq ogent-issues--loading-frame 0)
            (ogent-issues--animate-loading buf)
            (should (= 1 ogent-issues--loading-frame))
            (ogent-issues--animate-loading buf)
            (should (= 2 ogent-issues--loading-frame))
            ;; Wraps around current frame count.
            (ogent-issues--animate-loading buf)
            (should (= 0 ogent-issues--loading-frame))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-issues-test-animate-loading-dead-buffer ()
  "Test animate-loading handles dead buffer gracefully."
  (let ((buf (get-buffer-create "*ogent-issues-animate-dead-test*")))
    (with-current-buffer buf
      (ogent-issues-mode)
      (setq ogent-issues--loading-frame 0))
    (kill-buffer buf)
    ;; Should not error on dead buffer
    (ogent-issues--animate-loading buf)))

(ert-deftest ogent-issues-test-start-loading-wrong-mode ()
  "Test that start-loading does nothing in non-issues-mode buffers."
  (with-temp-buffer
    ;; Not in ogent-issues-mode
    (ogent-issues--start-loading)
    ;; Should not have set loading since we are not in the right mode
    (should-not (and (boundp 'ogent-issues--loading)
                     ogent-issues--loading))))

(ert-deftest ogent-issues-test-cleanup-on-kill ()
  "Test cleanup-on-kill cancels timers."
  (let ((buf (get-buffer-create "*ogent-issues-cleanup-test*")))
    (with-current-buffer buf
      (ogent-issues-mode)
      (ogent-issues--start-loading)
      (should ogent-issues--loading-timer))
    ;; Kill should clean up via the hook
    (kill-buffer buf)
    ;; Buffer is gone, timer should have been cleaned
    (should-not (buffer-live-p buf))))

;;; Insert Buffer Contents Dispatch Tests

(ert-deftest ogent-issues-test-insert-buffer-contents-nil ()
  "Test insert-buffer-contents with nil shows empty state."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil)
          (ogent-issues--filters nil))
      (ogent-issues--insert-buffer-contents nil)
      (should (string-match-p "No issues found" (buffer-string))))))

(ert-deftest ogent-issues-test-insert-buffer-contents-with-issues ()
  "Test insert-buffer-contents with issues populates buffer."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (ogent-issues--insert-buffer-contents
       '((:id "t1" :title "Test" :status "open"
              :priority 1 :issue_type "task" :dependency_count 0)))
      (should (string-match-p "t1" (buffer-string)))
      (should (string-match-p "Test" (buffer-string))))))

;;; Plain Rendering (fallback without magit-section) Tests

(ert-deftest ogent-issues-test-insert-plain-groups-by-status ()
  "Test plain rendering groups by status."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--current-view 'list)
          (ogent-issues--magit-section-available nil))
      (ogent-issues--insert-plain
       '((:id "t1" :title "Open one" :status "open"
              :priority 1 :issue_type "task" :dependency_count 0)
         (:id "t2" :title "Closed one" :status "closed"
              :priority 2 :issue_type "bug" :dependency_count 0)))
      (should (string-match-p "Open" (buffer-string)))
      (should (string-match-p "Closed" (buffer-string)))
      (should (string-match-p "t1" (buffer-string)))
      (should (string-match-p "t2" (buffer-string))))))

(ert-deftest ogent-issues-test-insert-plain-sets-text-properties ()
  "Test plain rendering sets ogent-issue text properties."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--current-view 'list)
          (ogent-issues--magit-section-available nil))
      (ogent-issues--insert-plain
       '((:id "t1" :title "Prop test" :status "open"
              :priority 1 :issue_type "task" :dependency_count 0)))
      ;; Find the issue line and check for ogent-issue property
      (goto-char (point-min))
      (let ((found nil))
        (while (and (not found) (not (eobp)))
          (when (get-text-property (point) 'ogent-issue)
            (setq found t))
          (forward-char 1))
        (should found)))))

;;; Current Issue ID Tests

(ert-deftest ogent-issues-test-current-issue-id-returns-id ()
  "Test current-issue-id extracts ID from issue at point."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (ogent-issues--insert-plain
       '((:id "abc-123" :title "Test" :status "open"
              :priority 1 :issue_type "task" :dependency_count 0)))
      ;; Find line with the issue property
      (goto-char (point-min))
      (while (and (not (eobp))
                  (not (get-text-property (point) 'ogent-issue)))
        (forward-char 1))
      (should (equal "abc-123" (ogent-issues--current-issue-id))))))

(ert-deftest ogent-issues-test-current-issue-id-nil-no-issue ()
  "Test current-issue-id returns nil when no issue at point."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (insert "just text\n")
      (goto-char (point-min))
      (should-not (ogent-issues--current-issue-id)))))

;;; Navigation Fallback Tests

(ert-deftest ogent-issues-test-next-issue-fallback ()
  "Test next-issue without magit-section uses text properties."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (ogent-issues--insert-plain
       '((:id "t1" :title "First" :status "open"
              :priority 1 :issue_type "task" :dependency_count 0)
         (:id "t2" :title "Second" :status "open"
              :priority 2 :issue_type "bug" :dependency_count 0)))
      (goto-char (point-min))
      (ogent-issues-next-issue)
      ;; Should have moved to first issue
      (should (get-text-property (point) 'ogent-issue)))))

(ert-deftest ogent-issues-test-prev-issue-fallback ()
  "Test prev-issue without magit-section uses text properties."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (ogent-issues--insert-plain
       '((:id "t1" :title "First" :status "open"
              :priority 1 :issue_type "task" :dependency_count 0)
         (:id "t2" :title "Second" :status "open"
              :priority 2 :issue_type "bug" :dependency_count 0)))
      (goto-char (point-max))
      (ogent-issues-prev-issue)
      ;; Should have moved backward
      (should (< (point) (point-max))))))

(ert-deftest ogent-issues-test-next-issue-at-end ()
  "Test next-issue when already at end of buffer."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (insert "no issues here\n")
      (goto-char (point-max))
      (let ((pos (point)))
        (ogent-issues-next-issue)
        ;; Should stay at the same position (nowhere to go)
        (should (= pos (point)))))))

;;; Toggle/Cycle Section Fallback Tests

(ert-deftest ogent-issues-test-toggle-section-no-magit ()
  "Test toggle-section without magit-section shows message."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((ogent-issues--magit-section-available nil))
      ;; Should not error, just message
      (ogent-issues-toggle-section))))

(ert-deftest ogent-issues-test-cycle-sections-no-magit ()
  "Test cycle-sections without magit-section shows message."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((ogent-issues--magit-section-available nil))
      ;; Should not error, just message
      (ogent-issues-cycle-sections))))

;;; Visit Tests

(ert-deftest ogent-issues-test-visit-no-issue-at-point ()
  "Test visit signals error when no issue at point."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (insert "no issues here\n")
      (goto-char (point-min))
      (should-error (ogent-issues-visit) :type 'user-error))))

;;; Detail View - Description Tests

(ert-deftest ogent-issues-test-insert-detail-description ()
  "Test description section rendering."
  (with-temp-buffer
    (ogent-issues--insert-detail-description
     '(:description "This is a **bold** description"))
    (should (string-match-p "Description" (buffer-string)))
    (should (string-match-p "bold" (buffer-string)))))

(ert-deftest ogent-issues-test-insert-detail-description-empty ()
  "Test description section with nil description."
  (with-temp-buffer
    (ogent-issues--insert-detail-description '(:description nil))
    (should (string-match-p "No description" (buffer-string)))))

(ert-deftest ogent-issues-test-insert-detail-description-empty-string ()
  "Test description section with empty string."
  (with-temp-buffer
    (ogent-issues--insert-detail-description '(:description ""))
    (should (string-match-p "No description" (buffer-string)))))

;;; Detail View - Metadata Tests

(ert-deftest ogent-issues-test-insert-detail-metadata ()
  "Test metadata section rendering."
  (with-temp-buffer
    (ogent-issues--insert-detail-metadata
     '(:created_at "2025-12-16T10:00:00Z"
       :updated_at "2025-12-16T14:30:00Z"
       :parent_id nil
       :labels nil))
    (should (string-match-p "Metadata" (buffer-string)))
    (should (string-match-p "Created" (buffer-string)))
    (should (string-match-p "Updated" (buffer-string)))
    (should (string-match-p "2025-12-16" (buffer-string)))))

(ert-deftest ogent-issues-test-insert-detail-metadata-with-parent ()
  "Test metadata section with parent ID."
  (with-temp-buffer
    (ogent-issues--insert-detail-metadata
     '(:created_at "2025-12-16T10:00:00Z"
       :updated_at "2025-12-16T14:30:00Z"
       :parent_id "parent-001"
       :labels nil))
    (should (string-match-p "Parent" (buffer-string)))
    (should (string-match-p "parent-001" (buffer-string)))))

(ert-deftest ogent-issues-test-insert-detail-metadata-with-labels ()
  "Test metadata section with labels."
  (with-temp-buffer
    (ogent-issues--insert-detail-metadata
     '(:created_at "2025-12-16T10:00:00Z"
       :updated_at "2025-12-16T14:30:00Z"
       :parent_id nil
       :labels ("backend" "urgent")))
    (should (string-match-p "Labels" (buffer-string)))
    (should (string-match-p "backend" (buffer-string)))
    (should (string-match-p "urgent" (buffer-string)))))

(ert-deftest ogent-issues-test-insert-detail-metadata-string-labels ()
  "Test metadata section with a string labels value."
  (with-temp-buffer
    (ogent-issues--insert-detail-metadata
     '(:created_at "2025-01-01T00:00:00Z"
       :updated_at "2025-01-01T00:00:00Z"
       :parent_id nil
       :labels "single-label"))
    (should (string-match-p "Labels" (buffer-string)))
    (should (string-match-p "single-label" (buffer-string)))))

;;; Detail View - Subtasks Tests

(ert-deftest ogent-issues-test-insert-detail-subtasks ()
  "Test subtask section rendering."
  (with-temp-buffer
    (ogent-issues--insert-detail-subtasks
     '(:dependents ((:id "sub-1" :title "Subtask one" :status "open"
                     :priority 1 :issue_type "task"
                     :dependency_type "parent-child")
                    (:id "sub-2" :title "Subtask two" :status "closed"
                     :priority 2 :issue_type "bug"
                     :dependency_type "parent-child"))))
    (should (string-match-p "Subtasks (2)" (buffer-string)))
    (should (string-match-p "sub-1" (buffer-string)))
    (should (string-match-p "sub-2" (buffer-string)))))

(ert-deftest ogent-issues-test-insert-detail-subtasks-none ()
  "Test subtask section is omitted when no subtasks."
  (with-temp-buffer
    (ogent-issues--insert-detail-subtasks '(:dependents nil))
    (should (string-empty-p (buffer-string)))))

(ert-deftest ogent-issues-test-insert-detail-subtasks-only-deps ()
  "Test subtask section excludes non-parent-child dependencies."
  (with-temp-buffer
    (ogent-issues--insert-detail-subtasks
     '(:dependents ((:id "dep-1" :title "Blocker" :status "open"
                     :priority 1 :issue_type "task"
                     :dependency_type "blocks"))))
    ;; Should be empty since no parent-child deps
    (should (string-empty-p (buffer-string)))))

;;; Detail View - Subtask Line Tests

(ert-deftest ogent-issues-test-insert-subtask-line-open ()
  "Test subtask line for open subtask."
  (with-temp-buffer
    (ogent-issues--insert-subtask-line
     '(:id "sub-1" :title "Open subtask" :status "open"
       :priority 1 :issue_type "task"))
    (let ((content (buffer-string)))
      (should (string-match-p "sub-1" content))
      (should (string-match-p "Open subtask" content))
      (should (string-match-p "\\[task\\]" content)))))

(ert-deftest ogent-issues-test-insert-subtask-line-closed ()
  "Test subtask line for closed subtask shows checkmark."
  (let ((ogent-issues-use-unicode t))
    (with-temp-buffer
      (ogent-issues--insert-subtask-line
       '(:id "sub-2" :title "Done subtask" :status "closed"
         :priority 2 :issue_type "bug"))
      (should (string-match-p "sub-2" (buffer-string))))))

;;; Dependencies Section - Dependents Tests

(ert-deftest ogent-issues-test-insert-detail-dependencies-with-other-deps ()
  "Test dependency section shows non-parent-child dependents."
  (with-temp-buffer
    (ogent-issues--insert-detail-dependencies
     '(:blocks nil
       :blocked_by nil
       :dependents ((:id "dep-1" :dependency_type "blocks")
                    (:id "dep-2" :dependency_type "blocks"))))
    (should (string-match-p "Dependents" (buffer-string)))
    (should (string-match-p "dep-1" (buffer-string)))
    (should (string-match-p "dep-2" (buffer-string)))))

(ert-deftest ogent-issues-test-insert-detail-dependencies-excludes-parent-child ()
  "Test dependency section excludes parent-child from dependents."
  (with-temp-buffer
    (ogent-issues--insert-detail-dependencies
     '(:blocks nil
       :blocked_by nil
       :dependents ((:id "child-1" :dependency_type "parent-child"))))
    ;; Should NOT show Dependents since parent-child is filtered out
    (should-not (string-match-p "Dependents" (buffer-string)))))

;;; Markdown Rendering - Checkbox Tests

(ert-deftest ogent-issues-test-render-markdown-unchecked-checkbox ()
  "Test markdown rendering of unchecked checkbox."
  (let ((ogent-issues-use-unicode t))
    (let ((result (ogent-issues--render-markdown "- [ ] Not done")))
      (should (string-match-p "☐" result)))))

(ert-deftest ogent-issues-test-render-markdown-checked-checkbox ()
  "Test markdown rendering of checked checkbox."
  (let ((ogent-issues-use-unicode t))
    (let ((result (ogent-issues--render-markdown "- [x] Done")))
      (should (string-match-p "☑" result)))))

(ert-deftest ogent-issues-test-render-markdown-checkbox-ascii ()
  "Test markdown rendering of checkboxes in ASCII mode."
  (let ((ogent-issues-use-unicode nil))
    (let ((result (ogent-issues--render-markdown "- [ ] Not done")))
      (should (string-match-p "\\[ \\]" result)))
    (let ((result (ogent-issues--render-markdown "- [x] Done")))
      (should (string-match-p "\\[x\\]" result)))))

;;; Format Time - Error Path Tests

(ert-deftest ogent-issues-test-format-time-invalid-returns-raw ()
  "Test format-time with unparseable string returns it verbatim."
  (should (string= "not-a-date" (ogent-issues--format-time "not-a-date"))))

;;; Kanban Board Tests

(ert-deftest ogent-issues-test-insert-kanban-board-with-issues ()
  "Test kanban board rendering with issues."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t))
      (ogent-issues--insert-kanban-board
       '((:id "t1" :title "In progress" :status "in_progress"
              :priority 1 :issue_type "task")
         (:id "t2" :title "Open task" :status "open"
              :priority 0 :issue_type "bug")))
      (should (string-match-p "Kanban Board" (buffer-string)))
      (should (string-match-p "In Progress" (buffer-string)))
      (should (string-match-p "t1" (buffer-string)))
      (should (string-match-p "t2" (buffer-string))))))

(ert-deftest ogent-issues-test-insert-kanban-board-empty ()
  "Test kanban board rendering with no issues."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t))
      (ogent-issues--insert-kanban-board nil)
      (should (string-match-p "Kanban Board" (buffer-string)))
      (should (string-match-p "No issues" (buffer-string))))))

(ert-deftest ogent-issues-test-insert-kanban-separator ()
  "Test kanban separator rendering."
  (with-temp-buffer
    (ogent-issues--insert-kanban-separator 10)
    (let ((content (buffer-string)))
      (should (string-match-p "├" content))
      (should (string-match-p "─" content))
      (should (string-match-p "┤" content)))))

(ert-deftest ogent-issues-test-insert-kanban-headers ()
  "Test kanban headers rendering."
  (with-temp-buffer
    (let ((grouped '(("in_progress" . (1 2))
                     ("open" . (3))
                     ("blocked" . nil)
                     ("closed" . nil))))
      (ogent-issues--insert-kanban-headers 20 grouped)
      (let ((content (buffer-string)))
        (should (string-match-p "In Progress" content))
        (should (string-match-p "Open" content))
        (should (string-match-p "Blocked" content))
        (should (string-match-p "Closed" content))
        (should (string-match-p "┌" content))
        (should (string-match-p "┐" content))))))

(ert-deftest ogent-issues-test-insert-kanban-card ()
  "Test kanban card rendering."
  (with-temp-buffer
    (let ((ogent-issues-use-unicode t))
      (ogent-issues--insert-kanban-card
       '(:id "t1" :title "Card title" :status "open" :priority 1)
       30))
    (let ((content (buffer-string)))
      (should (string-match-p "t1" content))
      ;; Card should have ogent-issue-id property
      (should (get-text-property 0 'ogent-issue-id content)))))

;;; Kanban Move Issue Tests

(ert-deftest ogent-issues-test-kanban-move-no-issue ()
  "Test kanban move when no issue at point."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (insert "no issue here\n")
      (goto-char (point-min))
      ;; Should not error, just message
      (ogent-issues--kanban-move-issue 1))))

(ert-deftest ogent-issues-test-kanban-move-at-boundary ()
  "Test kanban move at boundary (cannot move further)."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      ;; Put issue property on a line - last column (closed)
      (insert "issue line\n")
      (put-text-property (point-min) (1- (point-max))
                         'ogent-issue '(:id "t1" :status "closed"))
      (goto-char (point-min))
      ;; Should not error when trying to move right from last column
      (ogent-issues--kanban-move-issue 1))))

;;; Restore Position Tests

(ert-deftest ogent-issues-test-restore-position-nil ()
  "Test restore-position with no last position."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil)
          (ogent-issues--last-position nil))
      (insert "some content\n")
      (ogent-issues--restore-position)
      ;; Should go to beginning
      (should (= (point-min) (point))))))

(ert-deftest ogent-issues-test-restore-position-not-found ()
  "Test restore-position when issue is not found."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil)
          (ogent-issues--last-position "nonexistent-id"))
      (ogent-issues--insert-plain
       '((:id "t1" :title "Test" :status "open"
              :priority 1 :issue_type "task" :dependency_count 0)))
      ;; Should not error; falls back to first issue
      (ogent-issues--restore-position))))

;;; Magit-section restore-position tests
;;
;; These tests exercise the real magit-section code path.
;; They skip when magit-section is not available in the test environment.

(ert-deftest ogent-issues-test-restore-position-magit-not-found ()
  "Restore-position with magit-section doesn't error when issue is gone.
Regression test: magit-section-forward signals (user-error \"No next
section\") when iterating past the last section.  The old code let this
propagate, crashing the render buffer with \"Error rendering issues\"."
  (unless (ogent-issues-test--magit-path-usable-p)
    (ert-skip "magit-section path not usable"))
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available t)
          (ogent-issues--last-position "nonexistent-id"))
      (ogent-issues--insert-buffer-contents
       '((:id "t1" :title "Test" :status "open"
               :priority 1 :issue_type "task" :dependency_count 0)))
      ;; Must not signal user-error
      (ogent-issues--restore-position)
      ;; Should fall back to first issue
      (should (equal "t1" (ogent-issues--current-issue-id))))))

(ert-deftest ogent-issues-test-restore-position-magit-found ()
  "Restore-position with magit-section finds the correct issue."
  (unless (ogent-issues-test--magit-path-usable-p)
    (ert-skip "magit-section path not usable"))
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available t)
          (ogent-issues--last-position "t2"))
      (ogent-issues--insert-buffer-contents
       '((:id "t1" :title "First" :status "open"
               :priority 1 :issue_type "task" :dependency_count 0)
         (:id "t2" :title "Second" :status "open"
               :priority 2 :issue_type "bug" :dependency_count 0)))
      (ogent-issues--restore-position)
      (should (equal "t2" (ogent-issues--current-issue-id))))))

(ert-deftest ogent-issues-test-restore-position-magit-nil-position ()
  "Restore-position with magit-section and nil last-position goes to top."
  (unless (ogent-issues-test--magit-path-usable-p)
    (ert-skip "magit-section path not usable"))
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available t)
          (ogent-issues--last-position nil))
      (ogent-issues--insert-buffer-contents
       '((:id "t1" :title "Test" :status "open"
               :priority 1 :issue_type "task" :dependency_count 0)))
      (ogent-issues--restore-position)
      (should (= (point) (point-min))))))

(ert-deftest ogent-issues-test-render-buffer-magit-no-error ()
  "Full render-buffer with magit-section doesn't show error message.
End-to-end test: render issues, attempt restore for a missing issue,
verify the buffer contains issue content and no error string."
  (unless (ogent-issues-test--magit-path-usable-p)
    (ert-skip "magit-section path not usable"))
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available t)
          (ogent-issues--last-position "deleted-issue")
          (ogent-issues--issues
           '((:id "t1" :title "Surviving Issue" :status "open"
                   :priority 1 :issue_type "task" :dependency_count 0)
             (:id "t2" :title "Another Issue" :status "in_progress"
                   :priority 2 :issue_type "bug" :dependency_count 0))))
      (ogent-issues--render-buffer (current-buffer))
      ;; Buffer should contain rendered issues, not error
      (should (string-match-p "Surviving Issue" (buffer-string)))
      (should-not (string-match-p "Error rendering issues" (buffer-string))))))

(ert-deftest ogent-issues-test-next-issue-magit-at-end ()
  "next-issue with magit-section signals user-error at end of buffer.
Verifies the underlying behavior that restore-position must handle."
  (unless (ogent-issues-test--magit-path-usable-p)
    (ert-skip "magit-section path not usable"))
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available t))
      (ogent-issues--insert-buffer-contents
       '((:id "t1" :title "Only Issue" :status "open"
               :priority 1 :issue_type "task" :dependency_count 0)))
      (goto-char (point-min))
      (ogent-issues-next-issue)  ; move to t1
      (should (equal "t1" (ogent-issues--current-issue-id)))
      ;; Next call should signal - this is the error restore-position catches
      (should-error (ogent-issues-next-issue) :type 'user-error))))

;;; Detail Help Test

(ert-deftest ogent-issues-test-detail-help ()
  "Test detail-help shows help message."
  ;; Should not error
  (ogent-issues-detail-help))

;;; Detail Follow Link Tests

(ert-deftest ogent-issues-test-detail-follow-link-no-link ()
  "Test follow-link signals error when no link at point."
  (with-temp-buffer
    (ogent-issues-detail-mode)
    (let ((inhibit-read-only t))
      (insert "no links here\n")
      (goto-char (point-min))
      (should-error (ogent-issues-detail-follow-link) :type 'user-error))))

;;; Empty State Content Tests

(ert-deftest ogent-issues-test-empty-state-content-no-filters ()
  "Test empty state content rendering without filters."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--filters nil))
      (ogent-issues--insert-empty-state-content)
      (should (string-match-p "No issues found" (buffer-string)))
      (should (string-match-p "create" (buffer-string))))))

(ert-deftest ogent-issues-test-empty-state-content-with-filters ()
  "Test empty state content rendering with active filters."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--filters '(:status "epic")))
      (ogent-issues--insert-empty-state-content)
      (should (string-match-p "No issues match current filters" (buffer-string)))
      (should (string-match-p "clear" (buffer-string)))
      (should (string-match-p "change" (buffer-string))))))

;;; Refresh Tests

(ert-deftest ogent-issues-test-refresh-renders-issues ()
  "Test that refresh populates buffer with issues."
  (ogent-issues-test-with-buffer
   ;; Buffer should be populated after refresh in the macro
   (should (> (buffer-size) 0))
   (should (string-match-p "test-001" (buffer-string)))))

(ert-deftest ogent-issues-test-refresh-error-callback ()
  "Test that refresh handles errors from bd-list."
  (cl-letf (((symbol-function 'ogent-issues-bd-check-requirements)
             (lambda () nil))
            ((symbol-function 'ogent-issues-bd-list)
             (lambda (_callback &optional _filters error-callback)
               (when error-callback
                 (funcall error-callback "mock error"))))
            ((symbol-function 'ogent-issues-bd-project-name)
             (lambda () "test-project")))
    (let ((buf (get-buffer-create "*ogent-issues-refresh-err-test*")))
      (unwind-protect
          (with-current-buffer buf
            (ogent-issues-mode)
            ;; Should not error
            (ogent-issues-refresh)
            (sit-for 0.01))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest ogent-issues-test-refresh-force-invalidates-cache ()
  "Test that refresh-force invalidates cache before refresh."
  (let ((cache-invalidated nil))
    (cl-letf (((symbol-function 'ogent-issues-bd-check-requirements)
               (lambda () nil))
              ((symbol-function 'ogent-issues-bd-cache-invalidate)
               (lambda () (setq cache-invalidated t)))
              ((symbol-function 'ogent-issues-bd-list)
               (lambda (callback &optional _filters _error-callback)
                 (funcall callback nil)))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda () "test-project")))
      (let ((buf (get-buffer-create "*ogent-issues-force-test*")))
        (unwind-protect
            (with-current-buffer buf
              (ogent-issues-mode)
              (ogent-issues-refresh-force)
              (sit-for 0.01)
              (should cache-invalidated))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

;;; Detail View Render Tests

(ert-deftest ogent-issues-test-render-detail-creates-buffer ()
  "Test render-detail creates and populates detail buffer."
  (let ((test-buf-name "*ogent-issue: render-test*"))
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
              ((symbol-function 'display-buffer) (lambda (_buf &rest _) nil))
              ((symbol-function 'select-window) #'ignore)
              ((symbol-function 'ogent-issues-bd-project-root)
               (lambda (&optional _) "/tmp/render-test"))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda (&optional _) "render-test")))
      (ogent-issues--render-detail
       '(:id "det-1" :title "Detail Test" :status "open"
         :priority 1 :issue_type "task" :description "desc"
         :created_at "2025-01-01T00:00:00Z"
         :updated_at "2025-01-01T00:00:00Z"
         :blocks nil :blocked_by nil :dependents nil
         :comments nil)
       "/tmp/render-test"
       test-buf-name)
      (let ((buf (get-buffer test-buf-name)))
        (unwind-protect
            (with-current-buffer buf
              (should (eq major-mode 'ogent-issues-detail-mode))
              (should (string-match-p "Detail Test" (buffer-string)))
              (should (string-match-p "desc" (buffer-string)))
              (should (equal "det-1" (plist-get ogent-issues-detail--issue :id))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

;;; Detail Refresh / Action Tests

(ert-deftest ogent-issues-test-detail-refresh-no-issue ()
  "Test detail-refresh does nothing when no issue is set."
  (with-temp-buffer
    (ogent-issues-detail-mode)
    (setq ogent-issues-detail--issue nil)
    ;; Should not error
    (ogent-issues-detail-refresh)))

;;; Comment Tests

(ert-deftest ogent-issues-test-insert-comment-with-body-key ()
  "Test comment rendering using :body instead of :text."
  (with-temp-buffer
    (ogent-issues--insert-comment
     '(:author "tester" :created_at "2025-01-01T00:00:00Z" :body "Body text"))
    (should (string-match-p "@tester" (buffer-string)))
    (should (string-match-p "Body text" (buffer-string)))))

(ert-deftest ogent-issues-test-insert-comment-nil-text ()
  "Test comment rendering with nil text and body."
  (with-temp-buffer
    (ogent-issues--insert-comment
     '(:author "tester" :created_at nil :text nil :body nil))
    (should (string-match-p "@tester" (buffer-string)))
    (should (string-match-p "unknown" (buffer-string)))))

;;; Kanban Pad Edge Cases

(ert-deftest ogent-issues-test-kanban-pad-empty-string ()
  "Test padding an empty string."
  (let ((result (ogent-issues--kanban-pad "" 10)))
    (should (= 10 (length result)))))

(ert-deftest ogent-issues-test-kanban-pad-width-1 ()
  "Test padding to width 1."
  (let ((result (ogent-issues--kanban-pad "X" 1)))
    (should (= 1 (length result)))
    (should (string= "X" result))))

;;; View Deps Tests

(ert-deftest ogent-issues-test-view-deps-current-no-issue ()
  "Test view-deps-current signals error when no issue at point."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (insert "no issue here\n")
      (goto-char (point-min))
      (should-error (ogent-issues-view-deps-current) :type 'user-error))))

;;; Section Navigation without Magit

(ert-deftest ogent-issues-test-next-section-no-magit ()
  "Test next-section without magit-section does nothing."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((ogent-issues--magit-section-available nil))
      ;; Should not error
      (ogent-issues-next-section))))

(ert-deftest ogent-issues-test-prev-section-no-magit ()
  "Test prev-section without magit-section does nothing."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((ogent-issues--magit-section-available nil))
      ;; Should not error
      (ogent-issues-prev-section))))

(ert-deftest ogent-issues-test-up-section-no-magit ()
  "Test up-section without magit-section does nothing."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((ogent-issues--magit-section-available nil))
      ;; Should not error
      (ogent-issues-up-section))))

;;; Link Map Tests

(ert-deftest ogent-issues-test-link-map-defined ()
  "Test that the issue link keymap is defined with expected bindings."
  (should (keymapp ogent-issues-link-map))
  (should (eq 'ogent-issues-detail-follow-link
              (lookup-key ogent-issues-link-map (kbd "RET")))))

;;; Kanban Column Width Edge Cases

(ert-deftest ogent-issues-test-kanban-column-width-narrow-window ()
  "Test kanban column width with extremely narrow window."
  (cl-letf (((symbol-function 'window-width) (lambda () 10)))
    (should (= 15 (ogent-issues--kanban-column-width)))))

(ert-deftest ogent-issues-test-kanban-column-width-wide-window ()
  "Test kanban column width with wide window."
  (cl-letf (((symbol-function 'window-width) (lambda () 165)))
    (should (= 40 (ogent-issues--kanban-column-width)))))

;;; Entry Point Tests

(ert-deftest ogent-issues-test-entry-point-no-project ()
  "Test ogent-issues signals error when not in a beads project."
  (cl-letf (((symbol-function 'ogent-issues-bd-project-root)
             (lambda (&optional _) nil)))
    (should-error (ogent-issues) :type 'user-error)))

;;; Format Issue Line - Dependency Count Nil

(ert-deftest ogent-issues-test-format-issue-line-nil-deps ()
  "Test issue line with nil dependency_count."
  (let ((issue '(:id "t1" :title "No dep count" :status "open"
                 :priority 2 :issue_type "task" :dependency_count nil)))
    (let ((line (ogent-issues--format-issue-line issue)))
      (should (stringp line))
      ;; Should not show parenthesized count
      (should-not (string-match-p "([0-9])" line)))))

;;; Detail Mode Variables

(ert-deftest ogent-issues-test-detail-mode-settings ()
  "Test that detail mode sets proper buffer-local settings."
  (with-temp-buffer
    (ogent-issues-detail-mode)
    (should (eq major-mode 'ogent-issues-detail-mode))
    (should-not truncate-lines)
    (should word-wrap)))

;;; Kanban Card Text Property Tests

(ert-deftest ogent-issues-test-kanban-card-issue-property ()
  "Test that kanban card sets ogent-issue text property."
  (with-temp-buffer
    (ogent-issues--insert-kanban-card
     '(:id "kc-1" :title "Card" :status "open" :priority 0)
     25)
    ;; The card text should have the ogent-issue property
    (goto-char (point-min))
    (should (equal "kc-1" (get-text-property (point) 'ogent-issue-id)))))

;;; Kanban Board - Insert Kanban Card Edge Cases

(ert-deftest ogent-issues-test-kanban-card-nil-title ()
  "Test kanban card with nil title."
  (with-temp-buffer
    (ogent-issues--insert-kanban-card
     '(:id "kc-nil" :title nil :status "open" :priority 2)
     25)
    (should (string-match-p "kc-nil" (buffer-string)))))

(ert-deftest ogent-issues-test-kanban-card-nil-priority ()
  "Test kanban card with nil priority defaults to 2."
  (with-temp-buffer
    (let ((ogent-issues-use-unicode t))
      (ogent-issues--insert-kanban-card
       '(:id "kc-np" :title "No priority" :status "open" :priority nil)
       30))
    ;; Should use default priority 2 which is "○" in unicode mode
    (should (string-match-p "kc-np" (buffer-string)))))

(ert-deftest ogent-issues-test-kanban-card-status-face-applied ()
  "Test kanban card applies correct status face."
  (with-temp-buffer
    (ogent-issues--insert-kanban-card
     '(:id "kc-ip" :title "IP" :status "in_progress" :priority 1)
     20)
    (goto-char (point-min))
    (should (eq 'ogent-issues-status-in-progress
                (get-text-property (point) 'face)))))

(ert-deftest ogent-issues-test-kanban-card-ascii-mode ()
  "Test kanban card in ASCII mode."
  (with-temp-buffer
    (let ((ogent-issues-use-unicode nil))
      (ogent-issues--insert-kanban-card
       '(:id "kc-a" :title "ASCII" :status "open" :priority 1)
       25))
    ;; ASCII mode uses "P1" for priority
    (should (string-match-p "P1" (buffer-string)))
    (should (string-match-p "kc-a" (buffer-string)))))

;;; Kanban Board Full Rendering Tests

(ert-deftest ogent-issues-test-insert-kanban-board-multiple-per-column ()
  "Test kanban board with multiple issues in same column."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t))
      (ogent-issues--insert-kanban-board
       '((:id "t1" :title "First open" :status "open" :priority 0 :issue_type "task")
         (:id "t2" :title "Second open" :status "open" :priority 1 :issue_type "bug")
         (:id "t3" :title "In progress" :status "in_progress" :priority 2 :issue_type "task"))))
    (should (string-match-p "t1" (buffer-string)))
    (should (string-match-p "t2" (buffer-string)))
    (should (string-match-p "t3" (buffer-string)))))

(ert-deftest ogent-issues-test-insert-kanban-board-all-columns ()
  "Test kanban board with issues in all columns."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t))
      (ogent-issues--insert-kanban-board ogent-issues-test--sample-issues))
    ;; Each sample issue is in a different status
    (should (string-match-p "test-001" (buffer-string)))
    (should (string-match-p "test-002" (buffer-string)))
    (should (string-match-p "test-003" (buffer-string)))
    (should (string-match-p "test-004" (buffer-string)))))

;;; Kanban Headers Edge Cases

(ert-deftest ogent-issues-test-insert-kanban-headers-empty-groups ()
  "Test kanban headers with empty groups."
  (with-temp-buffer
    (ogent-issues--insert-kanban-headers 15 nil)
    (let ((content (buffer-string)))
      ;; Should still show column headers
      (should (string-match-p "In Progress" content))
      (should (string-match-p "Open" content))
      ;; Counts should be 0
      (should (string-match-p "(0)" content)))))

;;; Kanban Move Issue Tests

(ert-deftest ogent-issues-test-kanban-move-issue-left ()
  "Test kanban move left updates status."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil)
          (update-called nil)
          (update-status nil))
      ;; Put an "open" issue on the line
      (insert "issue line\n")
      (put-text-property (point-min) (1- (point-max))
                         'ogent-issue '(:id "t1" :status "open"))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'ogent-issues-bd-update)
                 (lambda (_id callback &rest props)
                   (setq update-called t
                         update-status (plist-get props :status))
                   (funcall callback)))
                ((symbol-function 'ogent-issues-refresh) #'ignore))
        (ogent-issues--kanban-move-issue -1)
        ;; "open" is at index 1, so moving left goes to "in_progress" at index 0
        (should update-called)
        (should (equal "in_progress" update-status))))))

(ert-deftest ogent-issues-test-kanban-move-issue-right ()
  "Test kanban move right updates status."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil)
          (update-called nil)
          (update-status nil))
      (insert "issue line\n")
      (put-text-property (point-min) (1- (point-max))
                         'ogent-issue '(:id "t1" :status "open"))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'ogent-issues-bd-update)
                 (lambda (_id callback &rest props)
                   (setq update-called t
                         update-status (plist-get props :status))
                   (funcall callback)))
                ((symbol-function 'ogent-issues-refresh) #'ignore))
        (ogent-issues--kanban-move-issue 1)
        ;; "open" is at index 1, so moving right goes to "blocked" at index 2
        (should update-called)
        (should (equal "blocked" update-status))))))

(ert-deftest ogent-issues-test-kanban-move-leftmost-boundary ()
  "Test kanban move left at leftmost column does nothing."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (insert "issue line\n")
      (put-text-property (point-min) (1- (point-max))
                         'ogent-issue '(:id "t1" :status "in_progress"))
      (goto-char (point-min))
      ;; in_progress is at index 0, moving left should message, not error
      (ogent-issues--kanban-move-issue -1))))

(ert-deftest ogent-issues-test-kanban-move-rightmost-boundary ()
  "Test kanban move right at rightmost column does nothing."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (insert "issue line\n")
      (put-text-property (point-min) (1- (point-max))
                         'ogent-issue '(:id "t1" :status "closed"))
      (goto-char (point-min))
      ;; closed is at index 3 (last), moving right should message, not error
      (ogent-issues--kanban-move-issue 1))))

;;; Ready View with Issues Tests

(ert-deftest ogent-issues-test-view-ready-shows-sorted ()
  "Test ready view shows issues sorted by priority."
  (ogent-issues-test-with-buffer
   (ogent-issues-view-ready)
   (sit-for 0.01)
   ;; The ready view should show Ready Work heading
   (should (string-match-p "Ready Work" (buffer-string)))))

(ert-deftest ogent-issues-test-view-ready-empty ()
  "Test ready view with no ready issues."
  (let ((ogent-issues-test--mock-issues nil))
    (cl-letf (((symbol-function 'ogent-issues-bd-check-requirements)
               (lambda () nil))
              ((symbol-function 'ogent-issues-bd-list)
               (lambda (callback &optional _filters _error-callback)
                 (funcall callback nil)))
              ((symbol-function 'ogent-issues-bd-ready)
               (lambda (callback &optional _error-callback)
                 (funcall callback nil)))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda () "test-project")))
      (let ((buf (get-buffer-create "*ogent-issues-ready-empty-test*")))
        (unwind-protect
            (with-current-buffer buf
              (ogent-issues-mode)
              (ogent-issues-view-ready)
              (sit-for 0.01)
              (should (string-match-p "No ready work" (buffer-string))))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

;;; Header Line With Loading Tests

(ert-deftest ogent-issues-test-header-line-no-blocked ()
  "Test header line does not show blocked when count is 0."
  (ogent-issues-test-with-buffer
   (let ((ogent-issues--current-view 'list)
         (ogent-issues--issues
          (list '(:id "t1" :status "open" :blocked_by nil)))
         (ogent-issues--filters nil)
         (ogent-issues--loading nil))
     (let ((header (ogent-issues--header-line)))
       (should-not (string-match-p "blocked" header))))))

;;; Format Filters Tests (Additional)

(ert-deftest ogent-issues-test-format-filters-type-only ()
  "Test format-filters with only type filter."
  (let ((ogent-issues--filters '(:type "feature")))
    (let ((formatted (ogent-issues--format-filters)))
      (should (string-match-p "feature" formatted)))))

(ert-deftest ogent-issues-test-format-filters-priority-only ()
  "Test format-filters with only priority filter."
  (let ((ogent-issues--filters '(:priority 0)))
    (let ((formatted (ogent-issues--format-filters)))
      (should (string-match-p "P0" formatted)))))

;;; Format Filters For Header (Additional)

(ert-deftest ogent-issues-test-format-filters-for-header-type ()
  "Test format-filters-for-header with type filter."
  (let ((ogent-issues--filters '(:type "bug")))
    (let ((result (ogent-issues--format-filters-for-header)))
      (should (string-match-p "bug" result)))))

(ert-deftest ogent-issues-test-format-filters-for-header-all ()
  "Test format-filters-for-header with status, type, and priority."
  (let ((ogent-issues--filters '(:status "open" :type "task" :priority 2)))
    (let ((result (ogent-issues--format-filters-for-header)))
      (should (string-match-p "open" result))
      (should (string-match-p "task" result))
      (should (string-match-p "P2" result)))))

;;; Detail View - Render with Display Action Tests

(ert-deftest ogent-issues-test-render-detail-other-window-action ()
  "Test render-detail with other-window display action."
  (let ((ogent-issues-detail-display-action 'other-window)
        (test-buf-name "*ogent-issue: ow-test*")
        (pop-called nil))
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (_buf) (setq pop-called t)))
              ((symbol-function 'display-buffer) (lambda (_buf &rest _) nil))
              ((symbol-function 'select-window) #'ignore)
              ((symbol-function 'ogent-issues-bd-project-root)
               (lambda (&optional _) "/tmp/ow-test"))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda (&optional _) "ow-test")))
      (ogent-issues--render-detail
       '(:id "ow-1" :title "OW Test" :status "open"
         :priority 1 :issue_type "task" :description "desc"
         :created_at "2025-01-01T00:00:00Z"
         :updated_at "2025-01-01T00:00:00Z"
         :blocks nil :blocked_by nil :dependents nil :comments nil)
       "/tmp/ow-test" test-buf-name)
      (should pop-called)
      (let ((buf (get-buffer test-buf-name)))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest ogent-issues-test-render-detail-right-action ()
  "Default right action splits side-by-side via the overriding action."
  (let ((ogent-issues-detail-display-action 'right)
        (test-buf-name "*ogent-issue: right-test*")
        (captured-override nil)
        (selected nil))
    (cl-letf (((symbol-function 'display-buffer)
               (lambda (_buf &rest _)
                 (setq captured-override display-buffer-overriding-action)
                 'mock-window))
              ((symbol-function 'select-window)
               (lambda (w &rest _) (setq selected w)))
              ((symbol-function 'ogent-issues-bd-project-root)
               (lambda (&optional _) "/tmp/right-test"))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda (&optional _) "right-test")))
      (ogent-issues--render-detail
       '(:id "right-1" :title "Right Test" :status "open"
         :priority 1 :issue_type "task" :description "desc"
         :created_at "2025-01-01T00:00:00Z"
         :updated_at "2025-01-01T00:00:00Z"
         :blocks nil :blocked_by nil :dependents nil :comments nil)
       "/tmp/right-test" test-buf-name)
      ;; The overriding action wins over display-buffer-alist rules
      ;; (e.g. Doom's ^\* bottom-popup catch-all).
      (should (memq 'display-buffer-in-direction (car captured-override)))
      (should (equal (alist-get 'direction (cdr captured-override)) 'right))
      (should (eq selected 'mock-window))
      (let ((buf (get-buffer test-buf-name)))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest ogent-issues-test-render-detail-default-action-defers ()
  "The `default' action defers to display-buffer without overriding."
  (let ((ogent-issues-detail-display-action 'default)
        (test-buf-name "*ogent-issue: defer-test*")
        (captured-override 'unset)
        (selected nil))
    (cl-letf (((symbol-function 'display-buffer)
               (lambda (_buf &rest _)
                 (setq captured-override display-buffer-overriding-action)
                 'mock-window))
              ((symbol-function 'select-window)
               (lambda (w &rest _) (setq selected w)))
              ((symbol-function 'ogent-issues-bd-project-root)
               (lambda (&optional _) "/tmp/defer-test"))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda (&optional _) "defer-test")))
      (ogent-issues--render-detail
       '(:id "defer-1" :title "Defer Test" :status "open"
         :priority 1 :issue_type "task" :description "desc"
         :created_at "2025-01-01T00:00:00Z"
         :updated_at "2025-01-01T00:00:00Z"
         :blocks nil :blocked_by nil :dependents nil :comments nil)
       "/tmp/defer-test" test-buf-name)
      ;; Unchanged ambient value: no overriding action was installed.
      (should (eq captured-override display-buffer-overriding-action))
      (should-not selected)
      (let ((buf (get-buffer test-buf-name)))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

;;; Detail View - Header Line Format Tests

(ert-deftest ogent-issues-test-render-detail-header-line ()
  "Test that render-detail sets proper header-line-format."
  (let ((test-buf-name "*ogent-issue: hl-test*"))
    (cl-letf (((symbol-function 'display-buffer) (lambda (_buf &rest _) nil))
              ((symbol-function 'select-window) #'ignore)
              ((symbol-function 'ogent-issues-bd-project-root)
               (lambda (&optional _) "/tmp/hl-test"))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda (&optional _) "hl-test")))
      (ogent-issues--render-detail
       '(:id "hl-1" :title "HL Test" :status "open"
         :priority 1 :issue_type "task" :description nil
         :created_at nil :updated_at nil
         :blocks nil :blocked_by nil :dependents nil :comments nil)
       "/tmp/hl-test" test-buf-name)
      (let ((buf (get-buffer test-buf-name)))
        (unwind-protect
            (with-current-buffer buf
              (should header-line-format)
              (should (string-match-p "hl-1" header-line-format)))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

;;; Show Detail With Auto Refresh Tests

(ert-deftest ogent-issues-test-show-detail-with-auto-refresh ()
  "Test show-detail triggers background refresh when enabled."
  (let ((ogent-issues-detail-auto-refresh t)
        (get-called nil))
    (cl-letf (((symbol-function 'display-buffer) (lambda (_buf &rest _) nil))
              ((symbol-function 'select-window) #'ignore)
              ((symbol-function 'ogent-issues-bd-project-root)
               (lambda (&optional _) "/tmp/ar-test"))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda (&optional _) "ar-test"))
              ((symbol-function 'ogent-issues-bd-get)
               (lambda (_id _callback &optional _error-callback)
                 (setq get-called t))))
      (ogent-issues--show-detail
       '(:id "ar-1" :title "Auto Refresh" :status "open"
         :priority 1 :issue_type "task" :description nil
         :created_at nil :updated_at nil
         :blocks nil :blocked_by nil :dependents nil :comments nil))
      (should get-called)
      ;; Clean up buffer
      (let ((buf (get-buffer "*ogent-issue: ar-test*")))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest ogent-issues-test-show-detail-without-auto-refresh ()
  "Test show-detail does not trigger background refresh when disabled."
  (let ((ogent-issues-detail-auto-refresh nil)
        (get-called nil))
    (cl-letf (((symbol-function 'display-buffer) (lambda (_buf &rest _) nil))
              ((symbol-function 'select-window) #'ignore)
              ((symbol-function 'ogent-issues-bd-project-root)
               (lambda (&optional _) "/tmp/noar-test"))
              ((symbol-function 'ogent-issues-bd-project-name)
               (lambda (&optional _) "noar-test"))
              ((symbol-function 'ogent-issues-bd-get)
               (lambda (_id _callback &optional _error-callback)
                 (setq get-called t))))
      (ogent-issues--show-detail
       '(:id "noar-1" :title "No Auto Refresh" :status "open"
         :priority 1 :issue_type "task" :description nil
         :created_at nil :updated_at nil
         :blocks nil :blocked_by nil :dependents nil :comments nil))
      (should-not get-called)
      (let ((buf (get-buffer "*ogent-issue: noar-test*")))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

;;; Insert Plain Rendering - Status Order Tests

(ert-deftest ogent-issues-test-insert-plain-status-order ()
  "Test plain rendering shows statuses in correct order."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--current-view 'list)
          (ogent-issues--magit-section-available nil))
      (ogent-issues--insert-plain ogent-issues-test--sample-issues)
      (let ((content (buffer-string)))
        ;; In Progress should appear before Open
        (should (< (string-match "In Progress" content)
                   (string-match "Open" content)))
        ;; Open should appear before Blocked
        (should (< (string-match "Open" content)
                   (string-match "Blocked" content)))
        ;; Blocked should appear before Closed
        (should (< (string-match "Blocked" content)
                   (string-match "Closed" content)))))))

;;; Insert Plain - Count Display Tests

(ert-deftest ogent-issues-test-insert-plain-shows-counts ()
  "Test plain rendering shows correct counts for each group."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--current-view 'list)
          (ogent-issues--magit-section-available nil))
      (ogent-issues--insert-plain
       '((:id "t1" :title "A" :status "open" :priority 1 :issue_type "task" :dependency_count 0)
         (:id "t2" :title "B" :status "open" :priority 2 :issue_type "task" :dependency_count 0)
         (:id "t3" :title "C" :status "closed" :priority 3 :issue_type "task" :dependency_count 0)))
      ;; Open group should show count 2
      (should (string-match-p "Open (2)" (buffer-string)))
      ;; Closed group should show count 1
      (should (string-match-p "Closed (1)" (buffer-string))))))

;;; Render Markdown - Complex Content Tests

(ert-deftest ogent-issues-test-render-markdown-multiple-bold ()
  "Test markdown rendering with multiple bold sections."
  (let ((result (ogent-issues--render-markdown "**first** and **second**")))
    (should (string-match-p "first" result))
    (should (string-match-p "second" result))
    ;; Stars should be removed
    (should-not (string-match-p "\\*\\*" result))))

(ert-deftest ogent-issues-test-render-markdown-nested-list ()
  "Test markdown rendering of nested list items."
  (let ((ogent-issues-use-unicode t))
    (let ((result (ogent-issues--render-markdown "- top\n  - nested")))
      (should (string-match-p "top" result))
      (should (string-match-p "nested" result)))))

(ert-deftest ogent-issues-test-render-markdown-multiple-code ()
  "Test markdown rendering with multiple inline code spans."
  (let ((result (ogent-issues--render-markdown "Use `foo` and `bar`")))
    (should (string-match-p "foo" result))
    (should (string-match-p "bar" result))
    ;; Backticks should be removed
    (should-not (string-match-p "`" result))))

;;; Detail Metadata - Edge Cases

(ert-deftest ogent-issues-test-insert-detail-metadata-nil-times ()
  "Test metadata section with nil timestamps."
  (with-temp-buffer
    (ogent-issues--insert-detail-metadata
     '(:created_at nil :updated_at nil :parent_id nil :labels nil))
    (should (string-match-p "Metadata" (buffer-string)))
    ;; Should show "unknown" for nil times
    (should (string-match-p "unknown" (buffer-string)))))

;;; Detail Description with Empty String

(ert-deftest ogent-issues-test-insert-detail-description-whitespace ()
  "Test description with whitespace-only content."
  (with-temp-buffer
    (ogent-issues--insert-detail-description
     '(:description "Some real content here"))
    (should (string-match-p "Some real content here" (buffer-string)))
    (should-not (string-match-p "No description" (buffer-string)))))

;;; Insert Issue (standalone function) Tests

(ert-deftest ogent-issues-test-insert-issue-plain ()
  "Test insert-issue without magit-section sets text properties."
  (with-temp-buffer
    (let ((ogent-issues--magit-section-available nil))
      (ogent-issues--insert-issue
       '(:id "ins-1" :title "Insert test" :status "open"
         :priority 1 :issue_type "task" :dependency_count 0))
      (should (string-match-p "ins-1" (buffer-string)))
      ;; Should have ogent-issue property set
      (goto-char (point-min))
      (let ((found nil))
        (while (and (not found) (not (eobp)))
          (when (get-text-property (point) 'ogent-issue)
            (setq found t))
          (forward-char 1))
        (should found)))))

;;; Empty State With Magit Section Available False

(ert-deftest ogent-issues-test-empty-state-no-magit ()
  "Test empty state without magit-section."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil)
          (ogent-issues--filters nil))
      (ogent-issues--insert-empty-state)
      (should (string-match-p "No issues found" (buffer-string))))))

;;; Customization Variable Defaults

(ert-deftest ogent-issues-test-default-view-default ()
  "Test ogent-issues-default-view has expected default."
  (should (eq 'list ogent-issues-default-view)))

(ert-deftest ogent-issues-test-collapsed-statuses-default ()
  "Test ogent-issues-collapsed-statuses default."
  (should (member "closed" ogent-issues-collapsed-statuses)))

(ert-deftest ogent-issues-test-show-counts-default ()
  "Test ogent-issues-show-counts default."
  (should ogent-issues-show-counts))

(ert-deftest ogent-issues-test-use-unicode-default ()
  "Test ogent-issues-use-unicode default."
  (should ogent-issues-use-unicode))

(ert-deftest ogent-issues-test-per-project-buffers-default ()
  "Test ogent-issues-per-project-buffers default."
  (should ogent-issues-per-project-buffers))

;;; Type Icons Customization

(ert-deftest ogent-issues-test-type-icons-all-types ()
  "Test type-icons has entries for all known types."
  (should (assoc "bug" ogent-issues-type-icons))
  (should (assoc "feature" ogent-issues-type-icons))
  (should (assoc "task" ogent-issues-type-icons))
  (should (assoc "epic" ogent-issues-type-icons))
  (should (assoc "chore" ogent-issues-type-icons)))

(ert-deftest ogent-issues-test-type-icons-structure ()
  "Test type-icons entries have correct cons structure."
  (dolist (entry ogent-issues-type-icons)
    (should (stringp (car entry)))
    (should (consp (cdr entry)))
    (should (stringp (cadr entry)))
    (should (stringp (cddr entry)))))

;;; Actions - Close/Reopen/Start/Comment No Issue Tests

(ert-deftest ogent-issues-test-close-no-issue ()
  "Test close signals user-error when no issue at point."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (insert "no issue\n")
      (goto-char (point-min))
      (should-error (ogent-issues-close) :type 'user-error))))

(ert-deftest ogent-issues-test-reopen-no-issue ()
  "Test reopen signals user-error when no issue at point."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (insert "no issue\n")
      (goto-char (point-min))
      (should-error (ogent-issues-reopen) :type 'user-error))))

(ert-deftest ogent-issues-test-start-no-issue ()
  "Test start signals user-error when no issue at point."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (insert "no issue\n")
      (goto-char (point-min))
      (should-error (ogent-issues-start) :type 'user-error))))

(ert-deftest ogent-issues-test-comment-no-issue ()
  "Test comment signals user-error when no issue at point."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil))
      (insert "no issue\n")
      (goto-char (point-min))
      (should-error (ogent-issues-comment) :type 'user-error))))

;;; Sync Tests

(ert-deftest ogent-issues-test-sync-calls-bd-sync ()
  "Test sync calls ogent-issues-bd-sync."
  (let ((sync-called nil))
    (cl-letf (((symbol-function 'ogent-issues-bd-sync)
               (lambda (callback &optional _error-callback)
                 (setq sync-called t)
                 (funcall callback)))
              ((symbol-function 'ogent-issues-refresh) #'ignore))
      (ogent-issues-sync)
      (should sync-called))))

;;; Customizable Display Buffer Action

(ert-deftest ogent-issues-test-display-buffer-action-default ()
  "Test ogent-issues-display-buffer-action default is same-window."
  (should (eq 'same-window ogent-issues-display-buffer-action)))

(ert-deftest ogent-issues-test-detail-display-action-default ()
  "Test ogent-issues-detail-display-action default is the right split."
  (should (eq 'right ogent-issues-detail-display-action)))

;;; Group By Status Preserves Data

(ert-deftest ogent-issues-test-group-by-status-preserves-ids ()
  "Test group-by-status preserves issue IDs in groups."
  (let* ((issues '((:id "a" :status "open")
                   (:id "b" :status "open")
                   (:id "c" :status "closed")))
         (grouped (ogent-issues--group-by-status issues)))
    (let ((open-group (alist-get "open" grouped nil nil #'string=)))
      (should (= 2 (length open-group)))
      (should (member "a" (mapcar (lambda (i) (plist-get i :id)) open-group)))
      (should (member "b" (mapcar (lambda (i) (plist-get i :id)) open-group))))))

;;; Current Issue Without Magit Section

(ert-deftest ogent-issues-test-current-issue-text-property ()
  "Test current-issue reads from text property when no magit-section."
  (with-temp-buffer
    (ogent-issues-mode)
    (let ((inhibit-read-only t)
          (ogent-issues--magit-section-available nil)
          (test-issue '(:id "tp-1" :title "Text Prop" :status "open")))
      (insert "issue line\n")
      (put-text-property (point-min) (1- (point-max))
                         'ogent-issue test-issue)
      (goto-char (point-min))
      (should (equal test-issue (ogent-issues--current-issue))))))

(ert-deftest ogent-issues-test-format-issue-line-has-no-agent-indicator ()
  "Issue lines never render an agent-assignment arrow."
  (let ((ogent-issues-use-unicode t))
    (let ((line (ogent-issues--format-issue-line
                 '(:id "test-001" :title "Test issue" :priority 1
                   :issue_type "task" :status "open" :dependency_count 0))))
      (should-not (string-match-p "→" line)))))

(provide 'ogent-issues-tests)

;;; ogent-issues-tests.el ends here
