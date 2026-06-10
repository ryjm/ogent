;;; ogent-analytics-tests.el --- Tests for ogent-analytics -*- lexical-binding: t; -*-

;;; Commentary:
;; Test suite for analytics and benchmarking functionality.

;;; Code:

(require 'ert)
(declare-function ogent-completion-reject "ogent-completions" t t)
(declare-function ogent-completion-accept "ogent-completions" t t)
(require 'cl-lib)

;; Load analytics module
(require 'ogent-analytics)

;;; Token Estimation Tests

(ert-deftest ogent-analytics-test-token-estimation ()
  "Test token estimation from text length."
  ;; Default is ~4 chars per token
  (let ((ogent-analytics-chars-per-token 4.0))
    ;; 40 chars = 10 tokens
    (should (= (ogent-analytics-estimate-tokens (make-string 40 ?a)) 10))
    ;; 8 chars = 2 tokens
    (should (= (ogent-analytics-estimate-tokens "12345678") 2))
    ;; Empty string
    (should (= (ogent-analytics-estimate-tokens "") 0))
    ;; Nil input
    (should (= (ogent-analytics-estimate-tokens nil) 0))))

(ert-deftest ogent-analytics-test-token-estimation-custom ()
  "Test token estimation with custom chars-per-token."
  (let ((ogent-analytics-chars-per-token 3.0))
    ;; 30 chars = 10 tokens at 3 chars/token
    (should (= (ogent-analytics-estimate-tokens (make-string 30 ?a)) 10))))

;;; Completion Structure Tests

(ert-deftest ogent-analytics-test-completion-struct ()
  "Test analytics completion struct creation."
  (let ((completion (make-ogent-analytics-completion
                     :model "claude-3-opus"
                     :prompt-tokens 100
                     :response-tokens 200
                     :outcome 'pending
                     :rating 0)))
    (should (equal (ogent-analytics-completion-model completion) "claude-3-opus"))
    (should (= (ogent-analytics-completion-prompt-tokens completion) 100))
    (should (= (ogent-analytics-completion-response-tokens completion) 200))
    (should (eq (ogent-analytics-completion-outcome completion) 'pending))
    (should (= (ogent-analytics-completion-rating completion) 0))))

(ert-deftest ogent-analytics-test-truncate ()
  "Test text truncation utility."
  ;; Short text unchanged
  (should (equal (ogent-analytics--truncate "short" 10) "short"))
  ;; Long text truncated
  (should (equal (ogent-analytics--truncate "this is a long string" 10) "this is a "))
  ;; Nil input
  (should (null (ogent-analytics--truncate nil 10)))
  ;; Exact length
  (should (equal (ogent-analytics--truncate "12345" 5) "12345")))

;;; Timing Tests

(ert-deftest ogent-analytics-test-timing-tracking ()
  "Test request start/first-token timing."
  (let ((ogent-analytics--request-start-time nil)
        (ogent-analytics--first-token-time nil))
    ;; Start tracking
    (ogent-analytics-start-request)
    (should ogent-analytics--request-start-time)
    (should (null ogent-analytics--first-token-time))
    ;; First token
    (sleep-for 0.01)
    (ogent-analytics-first-token)
    (should ogent-analytics--first-token-time)
    ;; Second call shouldn't change it
    (let ((first-time ogent-analytics--first-token-time))
      (sleep-for 0.01)
      (ogent-analytics-first-token)
      (should (equal ogent-analytics--first-token-time first-time)))))

;;; Rating Tests

(ert-deftest ogent-analytics-test-rating-up ()
  "Test thumbs up rating."
  (let ((ogent-analytics--pending-completion
         (make-ogent-analytics-completion :rating 0)))
    ;; Mock the update function to avoid db access
    (cl-letf (((symbol-function 'ogent-analytics--update-completion) #'ignore))
      (ogent-analytics-rate-up)
      (should (= (ogent-analytics-completion-rating
                  ogent-analytics--pending-completion) 1)))))

(ert-deftest ogent-analytics-test-rating-down ()
  "Test thumbs down rating."
  (let ((ogent-analytics--pending-completion
         (make-ogent-analytics-completion :rating 0)))
    ;; Mock the update function to avoid db access
    (cl-letf (((symbol-function 'ogent-analytics--update-completion) #'ignore))
      (ogent-analytics-rate-down)
      (should (= (ogent-analytics-completion-rating
                  ogent-analytics--pending-completion) -1)))))

(ert-deftest ogent-analytics-test-rating-no-pending ()
  "Test rating when no pending completion."
  (let ((ogent-analytics--pending-completion nil))
    ;; Should not error
    (ogent-analytics-rate-up)
    (ogent-analytics-rate-down)))

;;; Outcome Marking Tests

(ert-deftest ogent-analytics-test-mark-accepted ()
  "Test marking completion as accepted."
  (let ((ogent-analytics--pending-completion
         (make-ogent-analytics-completion :outcome 'pending)))
    ;; Mock the update function to avoid db access
    (cl-letf (((symbol-function 'ogent-analytics--update-completion) #'ignore))
      (ogent-analytics-mark-accepted)
      (should (eq (ogent-analytics-completion-outcome
                   ogent-analytics--pending-completion) 'accepted)))))

(ert-deftest ogent-analytics-test-mark-rejected ()
  "Test marking completion as rejected."
  (let ((ogent-analytics--pending-completion
         (make-ogent-analytics-completion :outcome 'pending)))
    ;; Mock the update function to avoid db access
    (cl-letf (((symbol-function 'ogent-analytics--update-completion) #'ignore))
      (ogent-analytics-mark-rejected)
      (should (eq (ogent-analytics-completion-outcome
                   ogent-analytics--pending-completion) 'rejected)))))

;;; Dashboard Formatting Tests

(ert-deftest ogent-analytics-test-format-number ()
  "Test number formatting for dashboard."
  (should (equal (ogent-analytics--format-number nil) "-"))
  (should (equal (ogent-analytics--format-number 42) "42"))
  (should (equal (ogent-analytics--format-number 3.14159) "3.1")))

(ert-deftest ogent-analytics-test-format-latency ()
  "Test latency formatting for dashboard."
  (should (equal (ogent-analytics--format-latency nil) "-"))
  (should (equal (ogent-analytics--format-latency 500) "500ms"))
  (should (equal (ogent-analytics--format-latency 1000) "1.0s"))
  (should (equal (ogent-analytics--format-latency 2500) "2.5s")))

;;; Database Tests (when sqlite available)

(ert-deftest ogent-analytics-test-db-path ()
  "Test database path generation."
  (let ((default-directory "/test/project/")
        (ogent-analytics-db-name ".ogent-analytics.db"))
    ;; Mock project-current to return nil so we use default-directory
    (cl-letf (((symbol-function 'project-current) (lambda () nil)))
      (should (string-match-p "\\.ogent-analytics\\.db$"
                              (ogent-analytics--db-path))))))

(ert-deftest ogent-analytics-test-project-root-fallback ()
  "Test project root fallback to default-directory."
  (let ((default-directory "/some/path/"))
    (cl-letf (((symbol-function 'project-current) (lambda () nil))
              ((symbol-function 'locate-dominating-file) (lambda (_dir _file) nil)))
      (should (equal (ogent-analytics--project-root) "/some/path/")))))

;;; SQLite Integration Tests

(ert-deftest ogent-analytics-test-db-available ()
  "Test SQLite availability check."
  (if (and (fboundp 'sqlite-available-p) (sqlite-available-p))
      (message "SQLite is available")
    (ert-skip "SQLite not available")))

(ert-deftest ogent-analytics-test-record-completion-no-db ()
  "Test recording completion when db is not available."
  (let ((ogent-analytics-enabled t)
        (ogent-analytics--request-start-time (current-time))
        (ogent-analytics--db-cache (make-hash-table :test 'equal)))
    ;; Mock sqlite to be unavailable
    (cl-letf (((symbol-function 'sqlite-available-p) (lambda () nil)))
      ;; Should not error
      (let ((result (ogent-analytics-record-completion
                     "test-model"
                     "What is 2+2?"
                     "4")))
        ;; Should still create completion struct
        (should result)
        (should (ogent-analytics-completion-p result))
        (should (equal (ogent-analytics-completion-model result) "test-model"))))))

;;; Integration with Completions

(ert-deftest ogent-analytics-test-accept-advice ()
  "Test that accept advice marks completion."
  (let ((ogent-analytics--pending-completion
         (make-ogent-analytics-completion :outcome 'pending))
        (accept-called nil))
    ;; Mock db update and the original function
    (cl-letf (((symbol-function 'ogent-analytics--update-completion) #'ignore)
              ((symbol-function 'ogent-completion-accept)
               (lambda () (setq accept-called t))))
      ;; Call through advice
      (ogent-analytics--completion-accept-advice
       #'ogent-completion-accept)
      (should accept-called)
      (should (eq (ogent-analytics-completion-outcome
                   ogent-analytics--pending-completion) 'accepted)))))

(ert-deftest ogent-analytics-test-reject-advice ()
  "Test that reject advice marks completion."
  (let ((ogent-analytics--pending-completion
         (make-ogent-analytics-completion :outcome 'pending))
        (reject-called nil))
    ;; Mock db update and the original function
    (cl-letf (((symbol-function 'ogent-analytics--update-completion) #'ignore)
              ((symbol-function 'ogent-completion-reject)
               (lambda () (setq reject-called t))))
      ;; Call through advice
      (ogent-analytics--completion-reject-advice
       #'ogent-completion-reject)
      (should reject-called)
      (should (eq (ogent-analytics-completion-outcome
                   ogent-analytics--pending-completion) 'rejected)))))

;;; Dashboard Mode Tests

(ert-deftest ogent-analytics-test-dashboard-mode-keymap ()
  "Test dashboard mode keymap bindings."
  (should (keymapp ogent-analytics-dashboard-mode-map))
  (should (lookup-key ogent-analytics-dashboard-mode-map (kbd "g")))
  (should (lookup-key ogent-analytics-dashboard-mode-map (kbd "e")))
  (should (lookup-key ogent-analytics-dashboard-mode-map (kbd "o")))
  (should (lookup-key ogent-analytics-dashboard-mode-map (kbd "q"))))

(ert-deftest ogent-analytics-test-dashboard-no-db ()
  "Test dashboard handles missing database gracefully."
  (let ((ogent-analytics-enabled t))
    (cl-letf (((symbol-function 'sqlite-available-p) (lambda () nil)))
      ;; Should not error
      (ogent-analytics-dashboard)
      (when (get-buffer "*ogent-analytics*")
        (with-current-buffer "*ogent-analytics*"
          (should (string-match-p "SQLite not available\\|not initialized"
                                  (buffer-string))))
        (kill-buffer "*ogent-analytics*")))))

;;; Export Tests (mocked)

(ert-deftest ogent-analytics-test-export-csv-no-db ()
  "Test CSV export error when no database."
  (let ((ogent-analytics-enabled t))
    (cl-letf (((symbol-function 'sqlite-available-p) (lambda () nil))
              ((symbol-function 'ogent-analytics--get-db) (lambda () nil)))
      (should-error (ogent-analytics-export-csv "/tmp/test.csv")
                    :type 'user-error))))

(ert-deftest ogent-analytics-test-export-org-no-db ()
  "Test Org export error when no database."
  (let ((ogent-analytics-enabled t))
    (cl-letf (((symbol-function 'sqlite-available-p) (lambda () nil))
              ((symbol-function 'ogent-analytics--get-db) (lambda () nil)))
      (should-error (ogent-analytics-export-org "/tmp/test.org")
                    :type 'user-error))))

;;; Setup/Teardown Tests

(ert-deftest ogent-analytics-test-setup-adds-hooks ()
  "Test that setup adds gptel hooks when available."
  (let ((hook-added nil))
    (cl-letf (((symbol-function 'add-hook)
               (lambda (hook _fn)
                 (when (eq hook 'gptel-pre-request-hook)
                   (setq hook-added t)))))
      ;; Pretend gptel is loaded
      (provide 'gptel)
      (ogent-analytics-setup)
      ;; Hook should be added
      (should hook-added))))

(ert-deftest ogent-analytics-test-teardown-removes-hooks ()
  "Test that teardown removes gptel hooks."
  (let ((hook-removed nil))
    (cl-letf (((symbol-function 'remove-hook)
               (lambda (hook _fn)
                 (when (eq hook 'gptel-pre-request-hook)
                   (setq hook-removed t)))))
      ;; Pretend gptel is loaded
      (provide 'gptel)
      (ogent-analytics-teardown)
      ;; Hook should be removed
      (should hook-removed))))

;;; Disabled State Tests

(ert-deftest ogent-analytics-test-disabled ()
  "Test that analytics respects enabled flag."
  (let ((ogent-analytics-enabled nil)
        (ogent-analytics--request-start-time nil))
    ;; Should not set start time when disabled
    (cl-letf (((symbol-function 'ogent-analytics--get-db) (lambda () nil)))
      (ogent-analytics-start-request)
      ;; Should still track timing even when db disabled
      (should ogent-analytics--request-start-time))))

;;; Project Root Tests

(ert-deftest ogent-analytics-test-project-root-uses-project-el ()
  "Test project root detection via project.el."
  (cl-letf (((symbol-function 'project-current)
             (lambda () '(vc Git "/home/user/myproject/")))
            ((symbol-function 'project-root)
             (lambda (_proj) "/home/user/myproject/")))
    (should (equal (ogent-analytics--project-root) "/home/user/myproject/"))))

(ert-deftest ogent-analytics-test-project-root-git-fallback ()
  "Test project root falls back to .git detection."
  (cl-letf (((symbol-function 'project-current) (lambda () nil))
            ((symbol-function 'locate-dominating-file)
             (lambda (_dir _name) "/home/user/gitrepo/")))
    (should (equal (ogent-analytics--project-root) "/home/user/gitrepo/"))))

(ert-deftest ogent-analytics-test-project-root-default-directory ()
  "Test project root falls back to default-directory when no project found."
  (let ((default-directory "/tmp/fallback/"))
    (cl-letf (((symbol-function 'project-current) (lambda () nil))
              ((symbol-function 'locate-dominating-file) (lambda (_d _f) nil)))
      (should (equal (ogent-analytics--project-root) "/tmp/fallback/")))))

;;; Database Path Tests

(ert-deftest ogent-analytics-test-db-path-uses-project-root ()
  "Test db path is built from project root and db name."
  (let ((ogent-analytics-db-name ".my-analytics.db"))
    (cl-letf (((symbol-function 'ogent-analytics--project-root)
               (lambda () "/home/user/project/")))
      (should (equal (ogent-analytics--db-path)
                     "/home/user/project/.my-analytics.db")))))

(ert-deftest ogent-analytics-test-db-path-custom-name ()
  "Test db path respects custom database name."
  (let ((ogent-analytics-db-name "custom.db"))
    (cl-letf (((symbol-function 'ogent-analytics--project-root)
               (lambda () "/tmp/")))
      (should (equal (ogent-analytics--db-path) "/tmp/custom.db")))))

;;; Database Validity Tests

(ert-deftest ogent-analytics-test-db-valid-p-nil ()
  "Test db-valid-p returns nil for nil input."
  (should-not (ogent-analytics--db-valid-p nil)))

(ert-deftest ogent-analytics-test-db-valid-p-with-sqlitep ()
  "Test db-valid-p uses sqlitep when available."
  (let ((fake-db (make-symbol "fake-db")))
    (cl-letf (((symbol-function 'sqlitep) (lambda (x) (eq x fake-db))))
      (should (ogent-analytics--db-valid-p fake-db)))))

(ert-deftest ogent-analytics-test-db-valid-p-non-db ()
  "Test db-valid-p returns nil for non-db objects."
  ;; A plain string is not a user-ptr
  (cl-letf (((symbol-function 'sqlitep) (lambda (_x) nil))
            ((symbol-function 'sqlite-p) (lambda (_x) nil)))
    (should-not (ogent-analytics--db-valid-p "not-a-db"))))

;;; Get DB Tests

(ert-deftest ogent-analytics-test-get-db-disabled ()
  "Test get-db returns nil when analytics is disabled."
  (let ((ogent-analytics-enabled nil))
    (should-not (ogent-analytics--get-db))))

(ert-deftest ogent-analytics-test-get-db-no-sqlite ()
  "Test get-db returns nil when sqlite is unavailable."
  (let ((ogent-analytics-enabled t))
    (cl-letf (((symbol-function 'sqlite-available-p) (lambda () nil)))
      (should-not (ogent-analytics--get-db)))))

(ert-deftest ogent-analytics-test-get-db-returns-cached ()
  "Test get-db returns cached connection when valid."
  (let ((ogent-analytics-enabled t)
        (ogent-analytics--db-cache (make-hash-table :test 'equal))
        (fake-db (make-symbol "cached-db")))
    (cl-letf (((symbol-function 'sqlite-available-p) (lambda () t))
              ((symbol-function 'ogent-analytics--db-path) (lambda () "/test/path.db"))
              ((symbol-function 'ogent-analytics--db-valid-p)
               (lambda (db) (eq db fake-db))))
      (puthash "/test/path.db" fake-db ogent-analytics--db-cache)
      (should (eq (ogent-analytics--get-db) fake-db)))))

(ert-deftest ogent-analytics-test-get-db-opens-new ()
  "Test get-db opens new connection when cache miss."
  (let ((ogent-analytics-enabled t)
        (ogent-analytics--db-cache (make-hash-table :test 'equal))
        (fake-db (make-symbol "new-db"))
        (schema-called nil))
    (cl-letf (((symbol-function 'sqlite-available-p) (lambda () t))
              ((symbol-function 'ogent-analytics--db-path) (lambda () "/test/new.db"))
              ((symbol-function 'ogent-analytics--db-valid-p) (lambda (_db) nil))
              ((symbol-function 'sqlite-open) (lambda (_path) fake-db))
              ((symbol-function 'ogent-analytics--init-schema)
               (lambda (_db) (setq schema-called t))))
      (let ((result (ogent-analytics--get-db)))
        (should (eq result fake-db))
        (should schema-called)
        (should (eq (gethash "/test/new.db" ogent-analytics--db-cache) fake-db))))))

;;; Init Schema Tests

(ert-deftest ogent-analytics-test-init-schema-executes-sql ()
  "Test init-schema calls sqlite-execute for table and views."
  (let ((executed-sqls '()))
    (cl-letf (((symbol-function 'sqlite-execute)
               (lambda (_db sql &rest _args)
                 (push sql executed-sqls))))
      (ogent-analytics--init-schema 'fake-db)
      ;; Should have executed 3 statements: table + 2 views
      (should (= (length executed-sqls) 3))
      ;; Check that CREATE TABLE for completions was executed
      (should (cl-some (lambda (sql) (string-match-p "CREATE TABLE IF NOT EXISTS completions" sql))
                       executed-sqls))
      ;; Check model_stats view
      (should (cl-some (lambda (sql) (string-match-p "CREATE VIEW IF NOT EXISTS model_stats" sql))
                       executed-sqls))
      ;; Check daily_stats view
      (should (cl-some (lambda (sql) (string-match-p "CREATE VIEW IF NOT EXISTS daily_stats" sql))
                       executed-sqls)))))

(ert-deftest ogent-analytics-test-init-schema-completions-columns ()
  "Test init-schema creates completions table with expected columns."
  (let ((table-sql nil))
    (cl-letf (((symbol-function 'sqlite-execute)
               (lambda (_db sql &rest _args)
                 (when (string-match-p "CREATE TABLE" sql)
                   (setq table-sql sql)))))
      (ogent-analytics--init-schema 'fake-db)
      (should table-sql)
      (should (string-match-p "model TEXT NOT NULL" table-sql))
      (should (string-match-p "prompt_tokens INTEGER" table-sql))
      (should (string-match-p "response_tokens INTEGER" table-sql))
      (should (string-match-p "outcome TEXT" table-sql))
      (should (string-match-p "rating INTEGER" table-sql))
      (should (string-match-p "time_to_first_token_ms INTEGER" table-sql)))))

;;; Start Request Tests

(ert-deftest ogent-analytics-test-start-request-sets-time ()
  "Test start-request sets the request start time."
  (let ((ogent-analytics--request-start-time nil)
        (ogent-analytics--first-token-time '(12345 0 0 0)))
    (ogent-analytics-start-request)
    (should ogent-analytics--request-start-time)
    ;; First token time should be cleared
    (should-not ogent-analytics--first-token-time)))

(ert-deftest ogent-analytics-test-start-request-resets-first-token ()
  "Test start-request clears any previous first-token time."
  (let ((ogent-analytics--request-start-time nil)
        (ogent-analytics--first-token-time (current-time)))
    (ogent-analytics-start-request)
    (should-not ogent-analytics--first-token-time)
    (should ogent-analytics--request-start-time)))

;;; First Token Tests

(ert-deftest ogent-analytics-test-first-token-sets-time ()
  "Test first-token records the timestamp."
  (let ((ogent-analytics--first-token-time nil))
    (ogent-analytics-first-token)
    (should ogent-analytics--first-token-time)))

(ert-deftest ogent-analytics-test-first-token-idempotent ()
  "Test first-token only sets time on first call."
  (let* ((ogent-analytics--first-token-time nil))
    (ogent-analytics-first-token)
    (let ((first-time ogent-analytics--first-token-time))
      (sleep-for 0.01)
      (ogent-analytics-first-token)
      (should (equal ogent-analytics--first-token-time first-time)))))

;;; Insert Dashboard Tests

(ert-deftest ogent-analytics-test-insert-dashboard-no-db ()
  "Test dashboard insertion when no database is available."
  (cl-letf (((symbol-function 'ogent-analytics--get-db) (lambda () nil))
            ((symbol-function 'ogent-analytics--project-root) (lambda () "/test/project/")))
    (with-temp-buffer
      (ogent-analytics--insert-dashboard)
      (let ((content (buffer-string)))
        (should (string-match-p "Ogent Analytics Dashboard" content))
        (should (string-match-p "/test/project/" content))
        (should (string-match-p "SQLite not available\\|not initialized" content))))))

(ert-deftest ogent-analytics-test-insert-dashboard-empty-db ()
  "Test dashboard insertion with empty database (no completions)."
  (let ((fake-db (make-symbol "fake-db")))
    (cl-letf (((symbol-function 'ogent-analytics--get-db) (lambda () fake-db))
              ((symbol-function 'ogent-analytics--project-root) (lambda () "/test/"))
              ((symbol-function 'sqlite-select)
               (lambda (_db _sql &rest _args) nil)))
      (with-temp-buffer
        (ogent-analytics--insert-dashboard)
        (let ((content (buffer-string)))
          (should (string-match-p "Ogent Analytics Dashboard" content))
          (should (string-match-p "Overall Statistics" content))
          (should (string-match-p "No completions recorded" content))
          (should (string-match-p "No model data available" content)))))))

(ert-deftest ogent-analytics-test-insert-dashboard-with-data ()
  "Test dashboard insertion with mock data."
  (let ((fake-db (make-symbol "fake-db"))
        (query-count 0))
    (cl-letf (((symbol-function 'ogent-analytics--get-db) (lambda () fake-db))
              ((symbol-function 'ogent-analytics--project-root) (lambda () "/test/"))
              ((symbol-function 'sqlite-select)
               (lambda (_db sql &rest _args)
                 (setq query-count (1+ query-count))
                 (cond
                  ;; Overall stats query (multiline SQL - match single-line part)
                  ((string-match-p "COUNT(\\*)" sql)
                   '((10 7 3 70.0 5000 450 5 1)))
                  ;; Model stats
                  ((string-match-p "FROM model_stats" sql)
                   '(("claude-3" 10 7 3 70.0 500 450 5 1)))
                  ;; Daily stats
                  ((string-match-p "FROM daily_stats" sql)
                   '(("2024-01-15" 5 4 1 2500 400)))
                  ;; Recent completions
                  ((string-match-p "ORDER BY timestamp DESC" sql)
                   '(("2024-01-15 14:30:00" "claude-3" "accepted" 1 500 400 "response preview")))
                  (t nil)))))
      (with-temp-buffer
        (ogent-analytics--insert-dashboard)
        (let ((content (buffer-string)))
          (should (string-match-p "Total Completions" content))
          (should (string-match-p "Model Comparison" content))
          (should (string-match-p "claude-3" content))
          (should (string-match-p "Recent Activity" content))
          (should (string-match-p "2024-01-15" content)))))))

(ert-deftest ogent-analytics-test-insert-dashboard-keybinding-help ()
  "Test dashboard shows keybinding help."
  (cl-letf (((symbol-function 'ogent-analytics--get-db) (lambda () nil))
            ((symbol-function 'ogent-analytics--project-root) (lambda () "/test/")))
    (with-temp-buffer
      (ogent-analytics--insert-dashboard)
      (let ((content (buffer-string)))
        (should (string-match-p "g=refresh" content))
        (should (string-match-p "e=export CSV" content))
        (should (string-match-p "q=quit" content))))))

;;; Additional Coverage Tests

(ert-deftest ogent-analytics-test-record-completion-with-timing ()
  "Test record-completion captures timing data."
  (let ((ogent-analytics-enabled t)
        (ogent-analytics--request-start-time (current-time))
        (ogent-analytics--first-token-time nil)
        (ogent-analytics--pending-completion nil)
        (ogent-analytics-chars-per-token 4.0)
        (save-called nil))
    ;; Set first token time after start
    (sleep-for 0.01)
    (setq ogent-analytics--first-token-time (current-time))
    (cl-letf (((symbol-function 'ogent-analytics--save-completion)
               (lambda (_c) (setq save-called t))))
      (let ((result (ogent-analytics-record-completion
                     "claude-3" "prompt text" "response text" "template-1")))
        (should result)
        (should save-called)
        (should (equal (ogent-analytics-completion-model result) "claude-3"))
        (should (equal (ogent-analytics-completion-prompt-template result) "template-1"))
        (should (ogent-analytics-completion-ttft-ms result))
        (should (> (ogent-analytics-completion-ttft-ms result) 0))
        (should (ogent-analytics-completion-latency-ms result))
        (should (> (ogent-analytics-completion-latency-ms result) 0))
        (should (eq (ogent-analytics-completion-outcome result) 'pending))
        (should (= (ogent-analytics-completion-rating result) 0))
        ;; Pending should be set
        (should (eq ogent-analytics--pending-completion result))
        ;; Timing should be reset
        (should-not ogent-analytics--request-start-time)
        (should-not ogent-analytics--first-token-time)))))

(ert-deftest ogent-analytics-test-record-completion-disabled ()
  "Test record-completion returns nil when disabled."
  (let ((ogent-analytics-enabled nil)
        (ogent-analytics--request-start-time (current-time)))
    (should-not (ogent-analytics-record-completion
                 "model" "prompt" "response"))))

(ert-deftest ogent-analytics-test-record-completion-no-start-time ()
  "Test record-completion with nil start time produces nil ttft and latency."
  (let ((ogent-analytics-enabled t)
        (ogent-analytics--request-start-time nil)
        (ogent-analytics--first-token-time nil)
        (ogent-analytics--pending-completion nil))
    (cl-letf (((symbol-function 'ogent-analytics--save-completion) #'ignore))
      (let ((result (ogent-analytics-record-completion "m" "p" "r")))
        (should result)
        (should-not (ogent-analytics-completion-ttft-ms result))
        (should-not (ogent-analytics-completion-latency-ms result))))))

(ert-deftest ogent-analytics-test-record-completion-sets-previews ()
  "Test record-completion truncates question and response previews."
  (let ((ogent-analytics-enabled t)
        (ogent-analytics--request-start-time (current-time))
        (ogent-analytics--first-token-time nil)
        (ogent-analytics--pending-completion nil)
        (long-prompt (make-string 300 ?x))
        (long-response (make-string 300 ?y)))
    (cl-letf (((symbol-function 'ogent-analytics--save-completion) #'ignore))
      (let ((result (ogent-analytics-record-completion "m" long-prompt long-response)))
        (should (= (length (ogent-analytics-completion-question-preview result)) 200))
        (should (= (length (ogent-analytics-completion-response-preview result)) 200))))))

(ert-deftest ogent-analytics-test-mark-accepted-nil-pending ()
  "Test mark-accepted with nil pending does nothing."
  (let ((ogent-analytics--pending-completion nil))
    ;; Should not error
    (ogent-analytics-mark-accepted)
    (should-not ogent-analytics--pending-completion)))

(ert-deftest ogent-analytics-test-mark-rejected-nil-pending ()
  "Test mark-rejected with nil pending does nothing."
  (let ((ogent-analytics--pending-completion nil))
    ;; Should not error
    (ogent-analytics-mark-rejected)
    (should-not ogent-analytics--pending-completion)))

(ert-deftest ogent-analytics-test-pre-request-hook-enabled ()
  "Test pre-request hook calls start-request when enabled."
  (let ((ogent-analytics-enabled t)
        (ogent-analytics--request-start-time nil)
        (ogent-analytics--first-token-time '(1 2 3 4)))
    (ogent-analytics--pre-request-hook)
    (should ogent-analytics--request-start-time)
    (should-not ogent-analytics--first-token-time)))

(ert-deftest ogent-analytics-test-pre-request-hook-disabled ()
  "Test pre-request hook does nothing when disabled."
  (let ((ogent-analytics-enabled nil)
        (ogent-analytics--request-start-time nil))
    (ogent-analytics--pre-request-hook)
    (should-not ogent-analytics--request-start-time)))

(ert-deftest ogent-analytics-test-dashboard-mode-derives-special ()
  "Test dashboard mode derives from special-mode."
  (with-temp-buffer
    (ogent-analytics-dashboard-mode)
    (should (derived-mode-p 'special-mode))
    (should truncate-lines)))

(ert-deftest ogent-analytics-test-format-number-zero ()
  "Test format-number with zero."
  (should (equal (ogent-analytics--format-number 0) "0"))
  (should (equal (ogent-analytics--format-number 0.0) "0.0")))

(ert-deftest ogent-analytics-test-completion-struct-session-id ()
  "Test completion struct stores session-id correctly."
  (let ((comp (make-ogent-analytics-completion
               :session-id "sess-123"
               :model "test"
               :outcome 'pending
               :rating 0)))
    (should (equal (ogent-analytics-completion-session-id comp) "sess-123"))
    ;; Test setf
    (setf (ogent-analytics-completion-outcome comp) 'accepted)
    (should (eq (ogent-analytics-completion-outcome comp) 'accepted))))

(ert-deftest ogent-analytics-test-dashboard-refresh-calls-dashboard ()
  "Test dashboard-refresh calls dashboard."
  (let ((dashboard-called nil))
    (cl-letf (((symbol-function 'ogent-analytics-dashboard)
               (lambda () (setq dashboard-called t))))
      (ogent-analytics-dashboard-refresh)
      (should dashboard-called))))

(provide 'ogent-analytics-tests)

;;; ogent-analytics-tests.el ends here
