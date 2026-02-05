;;; ogent-refinery-tests.el --- Tests for ogent-refinery -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Refinery merge queue viewer.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-refinery)

;;; Test Fixtures

(defconst ogent-refinery-test--sample-mr-ready
  '(:id "mr-001"
    :branch "feature/auth-improvements"
    :worker "polecat-alpha"
    :priority "P1"
    :status "ready"
    :created_at "2026-01-23T10:00:00Z")
  "Sample ready MR plist for testing.")

(defconst ogent-refinery-test--sample-mr-processing
  '(:id "mr-002"
    :branch "fix/memory-leak"
    :worker "polecat-beta"
    :priority "P0"
    :status "in_progress"
    :created_at "2026-01-23T09:00:00Z")
  "Sample processing MR plist for testing.")

(defconst ogent-refinery-test--sample-mr-failed
  '(:id "mr-003"
    :branch "refactor/database"
    :worker "polecat-gamma"
    :priority "P2"
    :status "failed"
    :error "Tests failed: 3 failures"
    :created_at "2026-01-23T08:00:00Z")
  "Sample failed MR plist for testing.")

(defconst ogent-refinery-test--sample-mr-blocked
  '(:id "mr-004"
    :branch "feature/new-api"
    :worker "polecat-delta"
    :priority "P1"
    :status "blocked"
    :blocked_by "mr-002"
    :created_at "2026-01-23T07:00:00Z")
  "Sample blocked MR plist for testing.")

(defconst ogent-refinery-test--sample-queue
  (list ogent-refinery-test--sample-mr-ready
        ogent-refinery-test--sample-mr-processing
        ogent-refinery-test--sample-mr-failed
        ogent-refinery-test--sample-mr-blocked
        '(:id "mr-005"
          :branch "docs/readme"
          :priority "P2"
          :status "pending"
          :created_at "2026-01-23T06:00:00Z")
        '(:id "mr-006"
          :branch "test/integration"
          :priority "P1"
          :status "queued"
          :created_at "2026-01-23T05:00:00Z")
        '(:id "mr-007"
          :branch "fix/race-condition"
          :priority "P0"
          :status "testing"
          :created_at "2026-01-23T04:00:00Z")
        '(:id "mr-008"
          :branch "feature/caching"
          :priority "P2"
          :status "error"
          :reason "Merge conflict"
          :created_at "2026-01-23T03:00:00Z"))
  "Sample queue list with various statuses.")

;;; Mocking Utilities

(defvar ogent-refinery-test--mock-output nil
  "Mock output to return from gt commands.")

(defvar ogent-refinery-test--mock-error nil
  "Mock error to return from gt commands.")

(defvar ogent-refinery-test--captured-args nil
  "Captured arguments from mock gt calls.")

(defmacro ogent-refinery-test-with-mock (output &rest body)
  "Execute BODY with gt mocked to return OUTPUT."
  (declare (indent 1) (debug t))
  `(let ((ogent-refinery-test--mock-output ,output)
         (ogent-refinery-test--mock-error nil)
         (ogent-refinery-test--captured-args nil)
         (ogent-refinery-gt-executable "gt")
         ;; Clear cache
         (ogent-refinery--cache (make-hash-table :test 'equal)))
     (cl-letf (((symbol-function 'ogent-refinery--run-async)
                (lambda (args callback &optional error-callback)
                  (setq ogent-refinery-test--captured-args args)
                  (if ogent-refinery-test--mock-error
                      (when error-callback
                        (funcall error-callback ogent-refinery-test--mock-error))
                    (funcall callback ogent-refinery-test--mock-output))
                  nil)))
       ,@body)))

(defmacro ogent-refinery-test-with-error (error-msg &rest body)
  "Execute BODY with gt mocked to return ERROR-MSG."
  (declare (indent 1) (debug t))
  `(let ((ogent-refinery-test--mock-output nil)
         (ogent-refinery-test--mock-error ,error-msg)
         (ogent-refinery-test--captured-args nil)
         (ogent-refinery-gt-executable "gt")
         (ogent-refinery--cache (make-hash-table :test 'equal)))
     (cl-letf (((symbol-function 'ogent-refinery--run-async)
                (lambda (args callback &optional error-callback)
                  (setq ogent-refinery-test--captured-args args)
                  (if ogent-refinery-test--mock-error
                      (when error-callback
                        (funcall error-callback ogent-refinery-test--mock-error))
                    (funcall callback ogent-refinery-test--mock-output))
                  nil)))
       ,@body)))

;;; Cache Tests

(ert-deftest ogent-refinery-test-cache-key ()
  "Test cache key generation."
  (should (equal "ogent:(\"mq\" \"list\")"
                 (ogent-refinery--cache-key "ogent" '("mq" "list"))))
  (should (equal "beads:(\"mq\" \"status\" \"mr-001\")"
                 (ogent-refinery--cache-key "beads" '("mq" "status" "mr-001")))))

(ert-deftest ogent-refinery-test-cache-key-different-rigs ()
  "Test that different rigs produce different cache keys."
  (let ((key1 (ogent-refinery--cache-key "rig1" '("mq" "list")))
        (key2 (ogent-refinery--cache-key "rig2" '("mq" "list"))))
    (should-not (equal key1 key2))))

(ert-deftest ogent-refinery-test-cache-set-and-get ()
  "Test setting and getting cache values."
  (let ((ogent-refinery--cache (make-hash-table :test 'equal))
        (ogent-refinery-cache-ttl 60))
    (ogent-refinery--cache-set "test-rig" '("cmd") '(:result "value"))
    (let ((result (ogent-refinery--cache-get "test-rig" '("cmd"))))
      (should result)
      (should (equal '(:result "value") result)))))

(ert-deftest ogent-refinery-test-cache-get-returns-nil-when-empty ()
  "Test that cache get returns nil for uncached values."
  (let ((ogent-refinery--cache (make-hash-table :test 'equal))
        (ogent-refinery-cache-ttl 60))
    (should-not (ogent-refinery--cache-get "test-rig" '("cmd")))))

(ert-deftest ogent-refinery-test-cache-disabled-when-ttl-zero ()
  "Test that cache is disabled when TTL is 0."
  (let ((ogent-refinery--cache (make-hash-table :test 'equal))
        (ogent-refinery-cache-ttl 0))
    ;; Set should be a no-op
    (ogent-refinery--cache-set "test-rig" '("cmd") '(:result "value"))
    ;; Get should return nil
    (should-not (ogent-refinery--cache-get "test-rig" '("cmd")))))

(ert-deftest ogent-refinery-test-cache-invalidate ()
  "Test cache invalidation clears all entries."
  (let ((ogent-refinery--cache (make-hash-table :test 'equal))
        (ogent-refinery-cache-ttl 60))
    ;; Add some entries
    (ogent-refinery--cache-set "rig1" '("cmd1") '(:result "1"))
    (ogent-refinery--cache-set "rig2" '("cmd2") '(:result "2"))
    ;; Verify they exist
    (should (ogent-refinery--cache-get "rig1" '("cmd1")))
    (should (ogent-refinery--cache-get "rig2" '("cmd2")))
    ;; Invalidate
    (ogent-refinery-cache-invalidate)
    ;; Verify they're gone
    (should-not (ogent-refinery--cache-get "rig1" '("cmd1")))
    (should-not (ogent-refinery--cache-get "rig2" '("cmd2")))))

;;; Rig Detection Tests

(ert-deftest ogent-refinery-test-detect-rig-in-rig ()
  "Test rig detection when in a rig directory."
  ;; Use dynamic gt-root to work in any environment (including CI)
  (let* ((gt-root (expand-file-name "~/gt"))
         (default-directory (concat gt-root "/ogent/polecats/alpha/")))
    (should (equal "ogent" (ogent-refinery--detect-rig)))))

(ert-deftest ogent-refinery-test-detect-rig-in-crew ()
  "Test rig detection when in a crew directory."
  (let* ((gt-root (expand-file-name "~/gt"))
         (default-directory (concat gt-root "/beads/crew/ritchie/")))
    (should (equal "beads" (ogent-refinery--detect-rig)))))

(ert-deftest ogent-refinery-test-detect-rig-outside-gt ()
  "Test rig detection returns nil outside gt."
  (let ((default-directory "/some/other/path/"))
    (should-not (ogent-refinery--detect-rig))))

(ert-deftest ogent-refinery-test-detect-rig-at-gt-root ()
  "Test rig detection at the gt root returns first path component."
  (let* ((gt-root (expand-file-name "~/gt"))
         (default-directory (concat gt-root "/gastown/")))
    (should (equal "gastown" (ogent-refinery--detect-rig)))))

;;; Queue Status Filtering Tests

(ert-deftest ogent-refinery-test-filter-queue-waiting ()
  "Test filtering for waiting (ready/pending/queued) MRs."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data ogent-refinery-test--sample-queue)
    (let ((waiting (ogent-refinery--filter-queue-status 'waiting)))
      (should (equal 3 (length waiting)))
      ;; Check that all have waiting statuses
      (dolist (mr waiting)
        (should (member (plist-get mr :status) '("ready" "pending" "queued")))))))

(ert-deftest ogent-refinery-test-filter-queue-processing ()
  "Test filtering for processing MRs."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data ogent-refinery-test--sample-queue)
    (let ((processing (ogent-refinery--filter-queue-status 'processing)))
      (should (equal 2 (length processing)))
      ;; Check that all have processing statuses
      (dolist (mr processing)
        (should (member (plist-get mr :status)
                        '("in_progress" "processing" "testing" "rebasing")))))))

(ert-deftest ogent-refinery-test-filter-queue-failed ()
  "Test filtering for failed MRs."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data ogent-refinery-test--sample-queue)
    (let ((failed (ogent-refinery--filter-queue-status 'failed)))
      (should (equal 2 (length failed)))
      ;; Check that all have failed statuses
      (dolist (mr failed)
        (should (member (plist-get mr :status) '("failed" "error")))))))

(ert-deftest ogent-refinery-test-filter-queue-blocked ()
  "Test filtering for blocked MRs."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data ogent-refinery-test--sample-queue)
    (let ((blocked (ogent-refinery--filter-queue-status 'blocked)))
      (should (equal 1 (length blocked)))
      (should (equal "blocked" (plist-get (car blocked) :status))))))

(ert-deftest ogent-refinery-test-filter-queue-nil-data ()
  "Test filtering with nil queue data returns nil."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data nil)
    (should-not (ogent-refinery--filter-queue-status 'waiting))
    (should-not (ogent-refinery--filter-queue-status 'processing))
    (should-not (ogent-refinery--filter-queue-status 'failed))
    (should-not (ogent-refinery--filter-queue-status 'blocked))))

(ert-deftest ogent-refinery-test-filter-queue-empty-list ()
  "Test filtering with empty queue data returns empty list."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data '())
    (should (null (ogent-refinery--filter-queue-status 'waiting)))))

;;; Priority Face Tests

(ert-deftest ogent-refinery-test-priority-face-p0 ()
  "Test P0/critical priority face."
  (should (eq 'ogent-refinery-priority-p0 (ogent-refinery--priority-face "P0")))
  (should (eq 'ogent-refinery-priority-p0 (ogent-refinery--priority-face "critical"))))

(ert-deftest ogent-refinery-test-priority-face-p1 ()
  "Test P1/high priority face."
  (should (eq 'ogent-refinery-priority-p1 (ogent-refinery--priority-face "P1")))
  (should (eq 'ogent-refinery-priority-p1 (ogent-refinery--priority-face "high"))))

(ert-deftest ogent-refinery-test-priority-face-p2-default ()
  "Test P2/medium/unknown priority face defaults to p2."
  (should (eq 'ogent-refinery-priority-p2 (ogent-refinery--priority-face "P2")))
  (should (eq 'ogent-refinery-priority-p2 (ogent-refinery--priority-face "medium")))
  (should (eq 'ogent-refinery-priority-p2 (ogent-refinery--priority-face "unknown")))
  (should (eq 'ogent-refinery-priority-p2 (ogent-refinery--priority-face nil))))

;;; Status Icon Tests

(ert-deftest ogent-refinery-test-status-icon-unicode ()
  "Test status icons with Unicode enabled."
  (let ((ogent-refinery-use-unicode t))
    (should (equal "⚙" (ogent-refinery--status-icon 'processing)))
    (should (equal "○" (ogent-refinery--status-icon 'waiting)))
    (should (equal "◌" (ogent-refinery--status-icon 'blocked)))
    (should (equal "✗" (ogent-refinery--status-icon 'failed)))
    (should (equal "✓" (ogent-refinery--status-icon 'merged)))
    (should (equal "·" (ogent-refinery--status-icon 'unknown)))))

(ert-deftest ogent-refinery-test-status-icon-ascii ()
  "Test status icons with Unicode disabled."
  (let ((ogent-refinery-use-unicode nil))
    (should (equal "*" (ogent-refinery--status-icon 'processing)))
    (should (equal "o" (ogent-refinery--status-icon 'waiting)))
    (should (equal "-" (ogent-refinery--status-icon 'blocked)))
    (should (equal "x" (ogent-refinery--status-icon 'failed)))
    (should (equal "+" (ogent-refinery--status-icon 'merged)))
    (should (equal "." (ogent-refinery--status-icon 'unknown)))))

;;; Age Formatting Tests

(ert-deftest ogent-refinery-test-format-age-now ()
  "Test age formatting for recent timestamps."
  ;; Use numeric timestamp to avoid timezone issues
  (let ((recent (float-time)))
    (should (equal "now" (ogent-refinery--format-age recent)))))

(ert-deftest ogent-refinery-test-format-age-minutes ()
  "Test age formatting for minutes ago."
  (let* ((now (float-time))
         ;; 5 minutes ago
         (past (- now 300)))
    (should (equal "5m" (ogent-refinery--format-age past)))))

(ert-deftest ogent-refinery-test-format-age-hours ()
  "Test age formatting for hours ago."
  (let* ((now (float-time))
         ;; 3 hours ago
         (past (- now (* 3 3600))))
    (should (equal "3h" (ogent-refinery--format-age past)))))

(ert-deftest ogent-refinery-test-format-age-days ()
  "Test age formatting for days ago."
  (let* ((now (float-time))
         ;; 2 days ago
         (past (- now (* 2 86400))))
    (should (equal "2d" (ogent-refinery--format-age past)))))

(ert-deftest ogent-refinery-test-format-age-nil ()
  "Test age formatting for nil timestamp."
  (should (equal "?" (ogent-refinery--format-age nil))))

(ert-deftest ogent-refinery-test-format-age-numeric ()
  "Test age formatting with numeric timestamp."
  (let* ((now (float-time))
         (past (- now 120))) ;; 2 minutes ago
    (should (equal "2m" (ogent-refinery--format-age past)))))

;;; Loading Animation Tests

(ert-deftest ogent-refinery-test-loading-indicator-nil-when-not-loading ()
  "Test loading indicator returns nil when not loading."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--loading nil)
    (should-not (ogent-refinery--loading-indicator))))

(ert-deftest ogent-refinery-test-loading-indicator-returns-frame ()
  "Test loading indicator returns current animation frame."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--loading t)
    (setq ogent-refinery--loading-frame 0)
    (should (ogent-refinery--loading-indicator))
    (should (stringp (ogent-refinery--loading-indicator)))))

(ert-deftest ogent-refinery-test-loading-start-stop ()
  "Test loading animation start/stop functions."
  (with-temp-buffer
    (ogent-refinery-mode)
    ;; Initially not loading
    (should-not ogent-refinery--loading)
    ;; Start loading
    (ogent-refinery--start-loading)
    (should ogent-refinery--loading)
    (should ogent-refinery--loading-timer)
    ;; Stop loading
    (ogent-refinery--stop-loading)
    (should-not ogent-refinery--loading)
    (should-not ogent-refinery--loading-timer)))

;;; Plain Text Section Rendering Tests

(ert-deftest ogent-refinery-test-insert-processing-section-plain ()
  "Test processing section plain text rendering."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data
          (list ogent-refinery-test--sample-mr-processing))
    (let ((inhibit-read-only t))
      (ogent-refinery--insert-processing-section-plain))
    (should (string-match-p "Processing" (buffer-string)))
    (should (string-match-p "mr-002" (buffer-string)))
    (should (string-match-p "fix/memory-leak" (buffer-string)))))

(ert-deftest ogent-refinery-test-insert-processing-section-plain-empty ()
  "Test processing section with no processing items."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data nil)
    (let ((inhibit-read-only t))
      (ogent-refinery--insert-processing-section-plain))
    (should (string-match-p "No active processing" (buffer-string)))))

(ert-deftest ogent-refinery-test-insert-queue-section-plain ()
  "Test queue section plain text rendering."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data
          (list ogent-refinery-test--sample-mr-ready))
    (let ((inhibit-read-only t))
      (ogent-refinery--insert-queue-section-plain))
    (should (string-match-p "Queue" (buffer-string)))
    (should (string-match-p "mr-001" (buffer-string)))
    (should (string-match-p "feature/auth-improvements" (buffer-string)))))

(ert-deftest ogent-refinery-test-insert-queue-section-plain-empty ()
  "Test queue section with empty queue."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data nil)
    (let ((inhibit-read-only t))
      (ogent-refinery--insert-queue-section-plain))
    (should (string-match-p "Queue is empty" (buffer-string)))))

(ert-deftest ogent-refinery-test-insert-failed-section-plain ()
  "Test failed section plain text rendering."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data
          (list ogent-refinery-test--sample-mr-failed))
    (let ((inhibit-read-only t))
      (ogent-refinery--insert-failed-section-plain))
    (should (string-match-p "Failed" (buffer-string)))
    (should (string-match-p "mr-003" (buffer-string)))
    (should (string-match-p "refactor/database" (buffer-string)))))

(ert-deftest ogent-refinery-test-insert-failed-section-plain-empty ()
  "Test failed section with no failures."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data nil)
    (let ((inhibit-read-only t))
      (ogent-refinery--insert-failed-section-plain))
    (should (string-match-p "No failures" (buffer-string)))))

(ert-deftest ogent-refinery-test-insert-history-section-plain ()
  "Test history section plain text rendering."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--history-data
          (list '(:id "mr-100" :branch "feature/complete" :status "merged")))
    (let ((inhibit-read-only t))
      (ogent-refinery--insert-history-section-plain))
    (should (string-match-p "Recent Merges" (buffer-string)))
    (should (string-match-p "mr-100" (buffer-string)))))

(ert-deftest ogent-refinery-test-insert-history-section-plain-empty ()
  "Test history section with no merges."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--history-data nil)
    (let ((inhibit-read-only t))
      (ogent-refinery--insert-history-section-plain))
    (should (string-match-p "No recent merges" (buffer-string)))))

;;; MR Item Rendering Tests (Plain)

(ert-deftest ogent-refinery-test-insert-mr-item-plain ()
  "Test MR item plain text rendering."
  (with-temp-buffer
    (ogent-refinery--insert-mr-item-plain ogent-refinery-test--sample-mr-ready)
    (should (string-match-p "mr-001" (buffer-string)))
    (should (string-match-p "feature/auth-improvements" (buffer-string)))
    (should (string-match-p "ready" (buffer-string)))))

(ert-deftest ogent-refinery-test-insert-mr-item-plain-minimal ()
  "Test MR item rendering with minimal data."
  (with-temp-buffer
    (ogent-refinery--insert-mr-item-plain '(:status "pending"))
    ;; Should use defaults
    (should (string-match-p "\\?" (buffer-string)))  ;; ??? for id
    (should (string-match-p "(unknown)" (buffer-string)))))

;;; Data Fetching Tests

(ert-deftest ogent-refinery-test-fetch-all ()
  "Test fetching all data for the buffer."
  (ogent-refinery-test-with-mock ogent-refinery-test--sample-queue
    (with-temp-buffer
      (ogent-refinery-mode)
      (setq ogent-refinery--rig "test-rig")
      (let ((done nil))
        (ogent-refinery--fetch-all
         (lambda ()
           (setq done t)))
        (should done)
        (should ogent-refinery--queue-data)
        (should (equal (length ogent-refinery--queue-data)
                       (length ogent-refinery-test--sample-queue)))))))

(ert-deftest ogent-refinery-test-fetch-all-error ()
  "Test fetching handles errors gracefully."
  (ogent-refinery-test-with-error "Command failed"
    (with-temp-buffer
      (ogent-refinery-mode)
      (setq ogent-refinery--rig "test-rig")
      (let ((done nil))
        (ogent-refinery--fetch-all
         (lambda ()
           (setq done t)))
        (should done)
        ;; Queue data should be nil on error
        (should-not ogent-refinery--queue-data)))))

;;; Mode Tests

(ert-deftest ogent-refinery-test-mode-enables ()
  "Test that refinery mode enables properly."
  (with-temp-buffer
    (ogent-refinery-mode)
    (should (derived-mode-p 'ogent-refinery-mode))
    (should buffer-read-only)
    (should truncate-lines)
    (should header-line-format)))

(ert-deftest ogent-refinery-test-mode-keymap ()
  "Test that keymap is set up correctly."
  (with-temp-buffer
    (ogent-refinery-mode)
    ;; Check some key bindings
    (should (eq 'ogent-refinery-refresh
                (lookup-key ogent-refinery-mode-map "g")))
    (should (eq 'ogent-refinery-refresh-force
                (lookup-key ogent-refinery-mode-map "G")))
    (should (eq 'ogent-refinery-next-item
                (lookup-key ogent-refinery-mode-map "n")))
    (should (eq 'ogent-refinery-prev-item
                (lookup-key ogent-refinery-mode-map "p")))
    (should (eq 'quit-window
                (lookup-key ogent-refinery-mode-map "q")))))

;;; Buffer State Tests

(ert-deftest ogent-refinery-test-buffer-local-variables ()
  "Test that buffer-local variables are set up."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--rig "test-rig")
    (setq ogent-refinery--queue-data '((:id "test")))
    ;; Each buffer should have its own state
    (let ((rig1 ogent-refinery--rig)
          (queue1 ogent-refinery--queue-data))
      (with-temp-buffer
        (ogent-refinery-mode)
        (setq ogent-refinery--rig "other-rig")
        (setq ogent-refinery--queue-data nil)
        ;; Verify independent
        (should-not (equal rig1 ogent-refinery--rig))
        (should-not (equal queue1 ogent-refinery--queue-data))))))

;;; Header Line Tests

(ert-deftest ogent-refinery-test-header-line-format ()
  "Test header line shows rig name."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--rig "test-rig")
    (setq ogent-refinery--queue-data nil)
    (setq ogent-refinery--loading nil)
    (let ((header (ogent-refinery--header-line)))
      (should (string-match-p "Refinery" header))
      (should (string-match-p "test-rig" header)))))

(ert-deftest ogent-refinery-test-header-line-loading ()
  "Test header line shows loading indicator."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--rig "test-rig")
    (setq ogent-refinery--loading t)
    (setq ogent-refinery--loading-frame 0)
    (let ((header (ogent-refinery--header-line)))
      (should (string-match-p "Loading" header)))))

(ert-deftest ogent-refinery-test-header-line-counts ()
  "Test header line shows queue counts."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--rig "test-rig")
    (setq ogent-refinery--queue-data ogent-refinery-test--sample-queue)
    (setq ogent-refinery--loading nil)
    (let ((header (ogent-refinery--header-line)))
      ;; Should show counts for various statuses
      (should (string-match-p "queued" header))
      (should (string-match-p "processing" header))
      (should (string-match-p "failed" header)))))

;;; Integration Tests

(ert-deftest ogent-refinery-test-full-render ()
  "Test full buffer rendering."
  (ogent-refinery-test-with-mock ogent-refinery-test--sample-queue
    (with-temp-buffer
      (ogent-refinery-mode)
      (setq ogent-refinery--rig "test-rig")
      (setq ogent-refinery--queue-data ogent-refinery-test--sample-queue)
      (let ((inhibit-read-only t))
        (ogent-refinery--insert-plain))
      ;; Should have all sections
      (should (string-match-p "Processing" (buffer-string)))
      (should (string-match-p "Queue" (buffer-string)))
      (should (string-match-p "Failed" (buffer-string)))
      (should (string-match-p "Recent Merges" (buffer-string))))))

;;; Format Age Additional Tests

(ert-deftest ogent-refinery-test-format-age-string-timestamp ()
  "Test age formatting with ISO string timestamp."
  ;; A timestamp far in the past should show days
  (should (string-match-p "[0-9]+d" (ogent-refinery--format-age "2020-01-01T00:00:00Z"))))

(ert-deftest ogent-refinery-test-format-age-boundary-60-seconds ()
  "Test age formatting at the 60 second boundary."
  (let ((past (- (float-time) 59)))
    (should (equal "now" (ogent-refinery--format-age past))))
  (let ((past (- (float-time) 61)))
    (should (equal "1m" (ogent-refinery--format-age past)))))

(ert-deftest ogent-refinery-test-format-age-boundary-1-hour ()
  "Test age formatting at the 1 hour boundary."
  (let ((past (- (float-time) 3599)))
    (should (string-match-p "^[0-9]+m$" (ogent-refinery--format-age past))))
  (let ((past (- (float-time) 3601)))
    (should (equal "1h" (ogent-refinery--format-age past)))))

;;; Format Priority Tests

(ert-deftest ogent-refinery-test-format-priority-display ()
  "Test that priority values get correct display text."
  ;; The format-queue-item uses priority in its rendering
  ;; Testing the priority-face mapping covers the key logic
  (should (eq 'ogent-refinery-priority-p0 (ogent-refinery--priority-face "P0")))
  (should (eq 'ogent-refinery-priority-p0 (ogent-refinery--priority-face "critical")))
  (should (eq 'ogent-refinery-priority-p1 (ogent-refinery--priority-face "P1")))
  (should (eq 'ogent-refinery-priority-p1 (ogent-refinery--priority-face "high")))
  (should (eq 'ogent-refinery-priority-p2 (ogent-refinery--priority-face "P2")))
  (should (eq 'ogent-refinery-priority-p2 (ogent-refinery--priority-face "low")))
  (should (eq 'ogent-refinery-priority-p2 (ogent-refinery--priority-face ""))))

;;; Status Icon Additional Tests

(ert-deftest ogent-refinery-test-status-icon-nil ()
  "Test status icon with nil status type."
  (let ((ogent-refinery-use-unicode t))
    (should (equal "·" (ogent-refinery--status-icon nil))))
  (let ((ogent-refinery-use-unicode nil))
    (should (equal "." (ogent-refinery--status-icon nil)))))

;;; Filter Queue Status Additional Tests

(ert-deftest ogent-refinery-test-filter-queue-unknown-status ()
  "Test filtering for an unrecognized status returns empty."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data ogent-refinery-test--sample-queue)
    (should (null (ogent-refinery--filter-queue-status 'completed)))))

(ert-deftest ogent-refinery-test-filter-queue-all-statuses-covered ()
  "Test that all queue items are reachable through some filter."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data ogent-refinery-test--sample-queue)
    (let ((waiting (ogent-refinery--filter-queue-status 'waiting))
          (processing (ogent-refinery--filter-queue-status 'processing))
          (failed (ogent-refinery--filter-queue-status 'failed))
          (blocked (ogent-refinery--filter-queue-status 'blocked)))
      (should (= (length ogent-refinery-test--sample-queue)
                 (+ (length waiting) (length processing)
                    (length failed) (length blocked)))))))

;;; Header Line Additional Tests

(ert-deftest ogent-refinery-test-header-line-no-rig ()
  "Test header line with nil rig shows question mark."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--rig nil)
    (setq ogent-refinery--queue-data nil)
    (setq ogent-refinery--loading nil)
    (let ((header (ogent-refinery--header-line)))
      (should (string-match-p "Refinery: \\?" header)))))

(ert-deftest ogent-refinery-test-header-line-empty-queue ()
  "Test header line with empty queue shows refresh/quit hints."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--rig "test-rig")
    (setq ogent-refinery--queue-data nil)
    (setq ogent-refinery--loading nil)
    (let ((header (ogent-refinery--header-line)))
      (should (string-match-p "refresh" header))
      (should (string-match-p "quit" header))
      ;; Should NOT show any counts
      (should-not (string-match-p "queued" header))
      (should-not (string-match-p "processing" header))
      (should-not (string-match-p "failed" header)))))

(ert-deftest ogent-refinery-test-header-line-only-queued ()
  "Test header line with only queued items."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--rig "test-rig")
    (setq ogent-refinery--queue-data
          (list '(:id "mr-1" :status "ready")))
    (setq ogent-refinery--loading nil)
    (let ((header (ogent-refinery--header-line)))
      (should (string-match-p "1 queued" header))
      (should-not (string-match-p "processing" header))
      (should-not (string-match-p "failed" header)))))

;;; Cache Key Tests

(ert-deftest ogent-refinery-test-cache-key-nil-args ()
  "Test cache key with nil args."
  (should (equal "rig:nil" (ogent-refinery--cache-key "rig" nil))))

(ert-deftest ogent-refinery-test-cache-key-empty-args ()
  "Test cache key with empty args list."
  (should (equal "rig:nil" (ogent-refinery--cache-key "rig" nil))))

;;; Loading Animation Additional Tests

(ert-deftest ogent-refinery-test-animate-loading-frame-wraps ()
  "Test that loading frame wraps around after 3."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--loading-frame 3)
    (ogent-refinery--animate-loading (current-buffer))
    (should (= 0 ogent-refinery--loading-frame))))

(ert-deftest ogent-refinery-test-animate-loading-dead-buffer ()
  "Test animate-loading does nothing for dead buffer."
  ;; Should not error when called with a killed buffer
  (let ((buf (generate-new-buffer " *test-dead*")))
    (kill-buffer buf)
    (ogent-refinery--animate-loading buf)))

(ert-deftest ogent-refinery-test-loading-frames-list ()
  "Test that loading frames is a list of 4 strings."
  (should (listp ogent-refinery--loading-frames))
  (should (= 4 (length ogent-refinery--loading-frames)))
  (dolist (frame ogent-refinery--loading-frames)
    (should (stringp frame))))

;;; MR Item Plain Rendering Additional Tests

(ert-deftest ogent-refinery-test-insert-mr-item-plain-all-fields ()
  "Test MR item plain rendering shows id, branch, status."
  (with-temp-buffer
    (ogent-refinery--insert-mr-item-plain
     '(:id "mr-xyz" :branch "feature/widgets" :status "ready"))
    (let ((content (buffer-string)))
      (should (string-match-p "mr-xyz" content))
      (should (string-match-p "feature/widgets" content))
      (should (string-match-p "ready" content)))))

(ert-deftest ogent-refinery-test-insert-mr-item-plain-no-id ()
  "Test MR item plain with no ID uses fallback ???."
  (with-temp-buffer
    (ogent-refinery--insert-mr-item-plain '(:branch "test" :status "?"))
    (should (string-match-p "\\?" (buffer-string)))))

;;; Refinery Status Entry Point Tests

(ert-deftest ogent-refinery-test-status-creates-buffer ()
  "Test ogent-refinery-status creates buffer with correct name."
  (ogent-refinery-test-with-mock nil
    (let ((buf nil))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'pop-to-buffer-same-window) #'ignore))
              (ogent-refinery-status "test-rig"))
            (setq buf (get-buffer "*Refinery: test-rig*"))
            (should buf)
            (with-current-buffer buf
              (should (derived-mode-p 'ogent-refinery-mode))
              (should (equal "test-rig" ogent-refinery--rig))))
        (when (and buf (buffer-live-p buf))
          (kill-buffer buf))))))

(ert-deftest ogent-refinery-test-status-no-rig-errors ()
  "Test ogent-refinery-status errors with no rig."
  (should-error (ogent-refinery-status nil) :type 'user-error))

;;; Mock Action Tests (merge, retry, drop, log)

(ert-deftest ogent-refinery-test-merge-no-mr-errors ()
  "Test that merge errors when no MR at point."
  (with-temp-buffer
    (ogent-refinery-mode)
    (cl-letf (((symbol-function 'ogent-refinery--current-mr) (lambda () nil)))
      (should-error (ogent-refinery-merge) :type 'user-error))))

(ert-deftest ogent-refinery-test-retry-no-mr-errors ()
  "Test that retry errors when no MR at point."
  (with-temp-buffer
    (ogent-refinery-mode)
    (cl-letf (((symbol-function 'ogent-refinery--current-mr) (lambda () nil)))
      (should-error (ogent-refinery-retry) :type 'user-error))))

(ert-deftest ogent-refinery-test-drop-no-mr-errors ()
  "Test that drop errors when no MR at point."
  (with-temp-buffer
    (ogent-refinery-mode)
    (cl-letf (((symbol-function 'ogent-refinery--current-mr) (lambda () nil)))
      (should-error (ogent-refinery-drop) :type 'user-error))))

(ert-deftest ogent-refinery-test-log-no-mr-errors ()
  "Test that log errors when no MR at point."
  (with-temp-buffer
    (ogent-refinery-mode)
    (cl-letf (((symbol-function 'ogent-refinery--current-mr) (lambda () nil)))
      (should-error (ogent-refinery-log) :type 'user-error))))

;;; Visit Tests

(ert-deftest ogent-refinery-test-visit-no-mr-errors ()
  "Test that visit errors when no MR at point."
  (with-temp-buffer
    (ogent-refinery-mode)
    (cl-letf (((symbol-function 'ogent-refinery--current-mr) (lambda () nil)))
      (should-error (ogent-refinery-visit) :type 'user-error))))

;;; Full Plain Rendering Tests

(ert-deftest ogent-refinery-test-insert-plain-all-sections ()
  "Test that insert-plain renders all four sections."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data nil)
    (setq ogent-refinery--history-data nil)
    (let ((inhibit-read-only t))
      (ogent-refinery--insert-plain))
    (let ((content (buffer-string)))
      (should (string-match-p "Processing" content))
      (should (string-match-p "Queue" content))
      (should (string-match-p "Failed" content))
      (should (string-match-p "Recent Merges" content)))))

(ert-deftest ogent-refinery-test-insert-plain-with-data ()
  "Test plain rendering with queue and history data."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data ogent-refinery-test--sample-queue)
    (setq ogent-refinery--history-data
          (list '(:id "mr-99" :branch "done/feature" :status "merged")))
    (let ((inhibit-read-only t))
      (ogent-refinery--insert-plain))
    (let ((content (buffer-string)))
      ;; Should show processing items
      (should (string-match-p "mr-002" content))
      ;; Should show waiting items
      (should (string-match-p "mr-001" content))
      ;; Should show failed items
      (should (string-match-p "mr-003" content))
      ;; Should show history items
      (should (string-match-p "mr-99" content)))))

;;; Navigation Tests (without magit-section)

(ert-deftest ogent-refinery-test-next-item-plain ()
  "Test next-item falls back to forward-line without magit-section."
  (with-temp-buffer
    (ogent-refinery-mode)
    (let ((inhibit-read-only t))
      (insert "line1\nline2\nline3\n"))
    (goto-char (point-min))
    (cl-letf (((symbol-value 'ogent-refinery--magit-section-available) nil))
      (ogent-refinery-next-item)
      (should (= 2 (line-number-at-pos))))))

(ert-deftest ogent-refinery-test-prev-item-plain ()
  "Test prev-item falls back to forward-line -1 without magit-section."
  (with-temp-buffer
    (ogent-refinery-mode)
    (let ((inhibit-read-only t))
      (insert "line1\nline2\nline3\n"))
    (goto-char (point-min))
    (forward-line 2)
    (cl-letf (((symbol-value 'ogent-refinery--magit-section-available) nil))
      (ogent-refinery-prev-item)
      (should (= 2 (line-number-at-pos))))))

;;; Refresh Tests

(ert-deftest ogent-refinery-test-refresh-in-mode ()
  "Test refresh fetches data and re-renders buffer."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--rig "test-rig")
    (let ((fetch-called nil)
          (inhibit-read-only t))
      (cl-letf (((symbol-function 'ogent-refinery--fetch-all)
                 (lambda (callback)
                   (setq fetch-called t)
                   (funcall callback)))
                ((symbol-function 'ogent-refinery--start-loading) #'ignore)
                ((symbol-function 'ogent-refinery--stop-loading) #'ignore)
                ((symbol-value 'ogent-refinery--magit-section-available) nil))
        (ogent-refinery-refresh)
        (should fetch-called)))))

(ert-deftest ogent-refinery-test-refresh-not-in-mode ()
  "Test refresh does nothing when not in refinery mode."
  (with-temp-buffer
    (let ((fetch-called nil))
      (cl-letf (((symbol-function 'ogent-refinery--fetch-all)
                 (lambda (_cb) (setq fetch-called t))))
        (ogent-refinery-refresh)
        (should-not fetch-called)))))

(ert-deftest ogent-refinery-test-refresh-force-clears-cache ()
  "Test force refresh clears cache then refreshes."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--rig "test-rig")
    (let ((ogent-refinery--cache (make-hash-table :test 'equal))
          (ogent-refinery-cache-ttl 60)
          (cache-cleared nil))
      (ogent-refinery--cache-set "test-rig" '("cmd") '(:val 1))
      (cl-letf (((symbol-function 'ogent-refinery-refresh) #'ignore)
                ((symbol-function 'ogent-refinery-cache-invalidate)
                 (lambda ()
                   (setq cache-cleared t)
                   (clrhash ogent-refinery--cache))))
        (ogent-refinery-refresh-force)
        (should cache-cleared)))))

;;; Visit/Merge/Retry/Drop/Log with MR data

(ert-deftest ogent-refinery-test-visit-with-mr ()
  "Test visit calls shell-command with MR id."
  (with-temp-buffer
    (ogent-refinery-mode)
    (let ((shell-cmd nil))
      (cl-letf (((symbol-function 'ogent-refinery--current-mr)
                 (lambda () '(:id "mr-123" :branch "feat/x")))
                ((symbol-function 'shell-command)
                 (lambda (cmd) (setq shell-cmd cmd))))
        (ogent-refinery-visit)
        (should (string-match-p "mr-123" shell-cmd))))))

(ert-deftest ogent-refinery-test-log-with-mr ()
  "Test log calls shell-command with branch name."
  (with-temp-buffer
    (ogent-refinery-mode)
    (let ((shell-cmd nil))
      (cl-letf (((symbol-function 'ogent-refinery--current-mr)
                 (lambda () '(:id "mr-456" :branch "fix/bug")))
                ((symbol-function 'shell-command)
                 (lambda (cmd) (setq shell-cmd cmd))))
        (ogent-refinery-log)
        (should (string-match-p "fix/bug" shell-cmd))))))

(ert-deftest ogent-refinery-test-merge-with-mr-confirmed ()
  "Test merge bumps priority when confirmed."
  (with-temp-buffer
    (ogent-refinery-mode)
    (let ((refresh-called nil))
      (cl-letf (((symbol-function 'ogent-refinery--current-mr)
                 (lambda () '(:id "mr-789" :branch "feat/y")))
                ((symbol-function 'yes-or-no-p) (lambda (_prompt) t))
                ((symbol-function 'ogent-refinery-refresh)
                 (lambda (&rest _) (setq refresh-called t))))
        (ogent-refinery-merge)
        (should refresh-called)))))

(ert-deftest ogent-refinery-test-merge-with-mr-declined ()
  "Test merge does nothing when user declines."
  (with-temp-buffer
    (ogent-refinery-mode)
    (let ((refresh-called nil))
      (cl-letf (((symbol-function 'ogent-refinery--current-mr)
                 (lambda () '(:id "mr-789" :branch "feat/y")))
                ((symbol-function 'yes-or-no-p) (lambda (_prompt) nil))
                ((symbol-function 'ogent-refinery-refresh)
                 (lambda (&rest _) (setq refresh-called t))))
        (ogent-refinery-merge)
        (should-not refresh-called)))))

(ert-deftest ogent-refinery-test-retry-with-mr-confirmed ()
  "Test retry runs async command when confirmed."
  (with-temp-buffer
    (ogent-refinery-mode)
    (let ((async-args nil))
      (cl-letf (((symbol-function 'ogent-refinery--current-mr)
                 (lambda () '(:id "mr-111" :branch "fix/z")))
                ((symbol-function 'yes-or-no-p) (lambda (_prompt) t))
                ((symbol-function 'ogent-refinery--run-async)
                 (lambda (args _cb &optional _ecb)
                   (setq async-args args))))
        (ogent-refinery-retry)
        (should async-args)
        (should (member "retry" async-args))
        (should (member "mr-111" async-args))))))

(ert-deftest ogent-refinery-test-drop-with-mr-confirmed ()
  "Test drop runs async reject command when confirmed."
  (with-temp-buffer
    (ogent-refinery-mode)
    (let ((async-args nil))
      (cl-letf (((symbol-function 'ogent-refinery--current-mr)
                 (lambda () '(:id "mr-222" :branch "feat/q")))
                ((symbol-function 'yes-or-no-p) (lambda (_prompt) t))
                ((symbol-function 'ogent-refinery--run-async)
                 (lambda (args _cb &optional _ecb)
                   (setq async-args args))))
        (ogent-refinery-drop)
        (should async-args)
        (should (member "reject" async-args))
        (should (member "mr-222" async-args))))))

;;; Stop Loading Timer Tests

(ert-deftest ogent-refinery-test-stop-loading-timer-nil ()
  "Test stop-loading-timer is safe when timer is nil."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--loading-timer nil)
    ;; Should not error
    (ogent-refinery--stop-loading-timer)
    (should-not ogent-refinery--loading-timer)))

(ert-deftest ogent-refinery-test-stop-loading-timer-active ()
  "Test stop-loading-timer cancels active timer."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--loading-timer
          (run-at-time 999 nil #'ignore))
    (ogent-refinery--stop-loading-timer)
    (should-not ogent-refinery--loading-timer)))

;;; Insert Buffer Contents Dispatch

(ert-deftest ogent-refinery-test-insert-buffer-contents-plain ()
  "Test insert-buffer-contents dispatches to plain when no magit-section."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--queue-data nil)
    (setq ogent-refinery--history-data nil)
    (let ((inhibit-read-only t))
      (cl-letf (((symbol-value 'ogent-refinery--magit-section-available) nil))
        (ogent-refinery--insert-buffer-contents)))
    (should (string-match-p "Processing" (buffer-string)))
    (should (string-match-p "Queue" (buffer-string)))))

;;; MR Item Plain Rendering - Edge Cases

(ert-deftest ogent-refinery-test-insert-mr-item-plain-missing-branch ()
  "Test MR item plain with no branch field uses fallback."
  (with-temp-buffer
    (ogent-refinery--insert-mr-item-plain '(:id "mr-x" :status "ready"))
    (should (string-match-p "(unknown)" (buffer-string)))))

(ert-deftest ogent-refinery-test-insert-mr-item-plain-missing-status ()
  "Test MR item plain with no status field uses ? fallback."
  (with-temp-buffer
    (ogent-refinery--insert-mr-item-plain '(:id "mr-x" :branch "b"))
    (should (string-match-p "\\?" (buffer-string)))))

;;; Header Line - Partial Counts

(ert-deftest ogent-refinery-test-header-line-only-failed ()
  "Test header line with only failed items."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--rig "test-rig")
    (setq ogent-refinery--queue-data
          (list '(:id "mr-1" :status "failed")))
    (setq ogent-refinery--loading nil)
    (let ((header (ogent-refinery--header-line)))
      (should (string-match-p "1 failed" header))
      (should-not (string-match-p "queued" header))
      (should-not (string-match-p "[0-9]+ processing" header)))))

(ert-deftest ogent-refinery-test-header-line-only-processing ()
  "Test header line with only processing items."
  (with-temp-buffer
    (ogent-refinery-mode)
    (setq ogent-refinery--rig "test-rig")
    (setq ogent-refinery--queue-data
          (list '(:id "mr-1" :status "in_progress")))
    (setq ogent-refinery--loading nil)
    (let ((header (ogent-refinery--header-line)))
      (should (string-match-p "1 processing" header))
      (should-not (string-match-p "queued" header))
      (should-not (string-match-p "[0-9]+ failed" header)))))

;;; Cache Expiry Test

(ert-deftest ogent-refinery-test-cache-expired-entry ()
  "Test that expired cache entries are removed."
  (let ((ogent-refinery--cache (make-hash-table :test 'equal))
        (ogent-refinery-cache-ttl 1))
    ;; Set cache with a timestamp far in the past
    (let ((key (ogent-refinery--cache-key "rig" '("cmd"))))
      (puthash key (cons (time-subtract (current-time) 10) '(:old t))
               ogent-refinery--cache))
    ;; Should return nil for expired entry
    (should-not (ogent-refinery--cache-get "rig" '("cmd")))
    ;; Should have removed the entry
    (should (= 0 (hash-table-count ogent-refinery--cache)))))

;;; Status Entry Point - Additional

(ert-deftest ogent-refinery-test-status-reuses-existing-buffer ()
  "Test ogent-refinery-status reuses buffer if already in mode."
  (ogent-refinery-test-with-mock nil
    (let ((buf nil))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'pop-to-buffer-same-window) #'ignore))
              (ogent-refinery-status "reuse-rig")
              (setq buf (get-buffer "*Refinery: reuse-rig*"))
              (should buf)
              ;; Call again - should reuse same buffer
              (ogent-refinery-status "reuse-rig")
              (should (eq buf (get-buffer "*Refinery: reuse-rig*")))))
        (when (and buf (buffer-live-p buf))
          (kill-buffer buf))))))

(provide 'ogent-refinery-tests)

;;; ogent-refinery-tests.el ends here
