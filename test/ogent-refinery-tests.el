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

(provide 'ogent-refinery-tests)

;;; ogent-refinery-tests.el ends here
