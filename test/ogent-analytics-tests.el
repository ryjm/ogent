;;; ogent-analytics-tests.el --- Tests for ogent-analytics -*- lexical-binding: t; -*-

;;; Commentary:
;; Test suite for analytics and benchmarking functionality.

;;; Code:

(require 'ert)
(declare-function ogent-completion-reject "ogent-completions" t t)
(declare-function ogent-completion-accept "ogent-completions" t t)
(require 'cl-lib)
;; The store-guard fixture macro (ogent-test-with-real-store) must be
;; available at load AND compile time under bare -l invocation.
(require 'ogent-test-helper)

;; Load analytics module
(require 'ogent-analytics)
;; The ogent-edit struct carries the completion id linking an edit
;; resolution back to its completions row (bead ogent-z0k.2).
(require 'ogent-edit-format)
;; The resolved-hook variable lives in ogent-edit-display, which this
;; suite does not load; declare it special so let-binding works.
(defvar ogent-edit-resolved-hook)

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
  ;; Zero-FS: every collaborator is stubbed and the fake DB path is
  ;; never created; it lives under `temporary-file-directory' so the
  ;; store tripwire classifies it as sanctioned.
  (let ((ogent-analytics-enabled t)
        (ogent-analytics--db-cache (make-hash-table :test 'equal))
        (fake-db (make-symbol "cached-db"))
        (fake-path (expand-file-name "ogent-analytics-fake/path.db"
                                     temporary-file-directory)))
    (cl-letf (((symbol-function 'sqlite-available-p) (lambda () t))
              ((symbol-function 'ogent-analytics--db-path)
               (lambda () fake-path))
              ((symbol-function 'ogent-analytics--db-valid-p)
               (lambda (db) (eq db fake-db))))
      (puthash fake-path fake-db ogent-analytics--db-cache)
      (should (eq (ogent-analytics--get-db) fake-db)))))

(ert-deftest ogent-analytics-test-get-db-opens-new ()
  "Test get-db opens new connection when cache miss."
  ;; Zero-FS: every collaborator is stubbed and the fake DB path is
  ;; never created; it lives under `temporary-file-directory' so the
  ;; store tripwire classifies it as sanctioned.
  (let ((ogent-analytics-enabled t)
        (ogent-analytics--db-cache (make-hash-table :test 'equal))
        (fake-db (make-symbol "new-db"))
        (schema-called nil)
        (fake-path (expand-file-name "ogent-analytics-fake/new.db"
                                     temporary-file-directory)))
    (cl-letf (((symbol-function 'sqlite-available-p) (lambda () t))
              ((symbol-function 'ogent-analytics--db-path)
               (lambda () fake-path))
              ((symbol-function 'ogent-analytics--db-valid-p)
               (lambda (_db) nil))
              ((symbol-function 'sqlite-open) (lambda (_path) fake-db))
              ((symbol-function 'ogent-analytics--init-schema)
               (lambda (_db) (setq schema-called t))))
      (let ((result (ogent-analytics--get-db)))
        (should (eq result fake-db))
        (should schema-called)
        (should (eq (gethash fake-path ogent-analytics--db-cache)
                    fake-db))))))

;;; Init Schema Tests

(ert-deftest ogent-analytics-test-init-schema-executes-sql ()
  "Test init-schema calls sqlite-execute for table and views.
The user_version stub reports an up-to-date schema so
`ogent-analytics--migrate-schema' is a no-op; migration statements
have their own tests."
  (let ((executed-sqls '()))
    (cl-letf (((symbol-function 'sqlite-execute)
               (lambda (_db sql &rest _args)
                 (push sql executed-sqls)))
              ((symbol-function 'sqlite-select)
               (lambda (_db _sql &rest _args)
                 (list (list ogent-analytics--schema-version)))))
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
  "Test init-schema creates completions table with expected columns.
The user_version stub reports an up-to-date schema so the only CREATE
TABLE seen is the base completions table."
  (let ((table-sql nil))
    (cl-letf (((symbol-function 'sqlite-execute)
               (lambda (_db sql &rest _args)
                 (when (string-match-p "CREATE TABLE" sql)
                   (setq table-sql sql))))
              ((symbol-function 'sqlite-select)
               (lambda (_db _sql &rest _args)
                 (list (list ogent-analytics--schema-version)))))
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

;;; Schema Migration Tests (bead ogent-z0k.3)

(ert-deftest ogent-analytics-test-migration-idempotent ()
  "Running init-schema twice on one connection is a no-op second time."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (let ((db (sqlite-open nil)))
    (unwind-protect
        (progn
          (ogent-analytics--init-schema db)
          (ogent-analytics--init-schema db)
          (should (= (caar (sqlite-select db "PRAGMA user_version"))
                     ogent-analytics--schema-version))
          (let ((columns (mapcar (lambda (row) (nth 1 row))
                                 (sqlite-select
                                  db "PRAGMA table_info(completions)"))))
            (should (member "cost_usd" columns))
            (should (member "fanout_group" columns)))
          ;; Views survive the migrate-then-create ordering (querying
          ;; them would error if the migration left them dangling).
          (should (equal (sqlite-select db "
                            SELECT name FROM sqlite_master
                            WHERE type = 'view' ORDER BY name")
                         '(("daily_stats") ("model_stats"))))
          (should-not (sqlite-select db "SELECT * FROM model_stats")))
      (sqlite-close db))))

(ert-deftest ogent-analytics-test-migration-preserves-legacy-rows ()
  "Migrating a version-0 database keeps rows and widens the CHECKs."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (let ((db (sqlite-open nil)))
    (unwind-protect
        (progn
          ;; Hand-build the legacy (version 0) shape with one row.
          (sqlite-execute db "
            CREATE TABLE completions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              timestamp TEXT NOT NULL DEFAULT (datetime('now')),
              session_id TEXT,
              model TEXT NOT NULL,
              prompt_template TEXT,
              prompt_tokens INTEGER,
              response_tokens INTEGER,
              total_tokens INTEGER,
              time_to_first_token_ms INTEGER,
              completion_latency_ms INTEGER,
              outcome TEXT CHECK(outcome IN ('accepted', 'rejected', 'pending')),
              rating INTEGER CHECK(rating IN (-1, 0, 1)),
              question_preview TEXT,
              response_preview TEXT
            )")
          (sqlite-execute db "
            INSERT INTO completions (model, outcome, rating) VALUES
            ('legacy-model', 'accepted', -1)")
          (ogent-analytics--init-schema db)
          ;; The legacy thumb rating survives untouched, new columns NULL.
          (should (equal (sqlite-select db "
                            SELECT model, outcome, rating, cost_usd, fanout_group
                            FROM completions")
                         '(("legacy-model" "accepted" -1 nil nil))))
          ;; The widened CHECKs accept the new rating scale and outcome.
          (sqlite-execute db "
            UPDATE completions SET rating = 5, outcome = 'rated' WHERE id = 1")
          (should (equal (sqlite-select
                          db "SELECT rating, outcome FROM completions")
                         '((5 "rated")))))
      (sqlite-close db))))

(ert-deftest ogent-analytics-test-migration-v1-statements ()
  "The v1 migration adds the new columns via ALTER TABLE and bumps the pragma."
  (let ((executed '()))
    (cl-letf (((symbol-function 'sqlite-execute)
               (lambda (_db sql &rest _args)
                 (push sql executed)))
              ((symbol-function 'sqlite-select)
               (lambda (_db _sql &rest _args) '((0)))))
      (ogent-analytics--migrate-schema 'fake-db)
      (should (cl-some (lambda (sql)
                         (string-match-p
                          "ALTER TABLE completions ADD COLUMN cost_usd REAL" sql))
                       executed))
      (should (cl-some (lambda (sql)
                         (string-match-p
                          "ALTER TABLE completions ADD COLUMN fanout_group TEXT" sql))
                       executed))
      (should (cl-some (lambda (sql)
                         (string-match-p "RENAME TO completions" sql))
                       executed))
      (should (cl-some (lambda (sql)
                         (string-match-p "PRAGMA user_version = 1" sql))
                       executed)))))

;;; Pricing Tests (bead ogent-z0k.3)

(ert-deftest ogent-analytics-test-pricing-longest-prefix ()
  "The longest matching prefix wins over shorter family entries."
  (let ((ogent-analytics-model-pricing
         '(("gpt-5"      . (:input-per-mtok 1.0 :output-per-mtok 2.0))
           ("gpt-5.4"    . (:input-per-mtok 3.0 :output-per-mtok 4.0))
           ("gpt-5.4-mini" . (:input-per-mtok 5.0 :output-per-mtok 6.0)))))
    (should (equal (ogent-analytics--model-pricing "gpt-5.5")
                   '(:input-per-mtok 1.0 :output-per-mtok 2.0)))
    (should (equal (ogent-analytics--model-pricing "gpt-5.4-turbo")
                   '(:input-per-mtok 3.0 :output-per-mtok 4.0)))
    (should (equal (ogent-analytics--model-pricing "gpt-5.4-mini-2027")
                   '(:input-per-mtok 5.0 :output-per-mtok 6.0)))))

(ert-deftest ogent-analytics-test-pricing-covers-suffixed-registry-ids ()
  "The shipped starter table prices dated registry variants by prefix."
  (should (ogent-analytics--model-pricing "claude-haiku-4-5-20251001"))
  (should (ogent-analytics--model-pricing "gpt-5.6-sol")))

(ert-deftest ogent-analytics-test-pricing-unknown-model-nil ()
  "Unknown or non-string models have no pricing and a nil cost."
  (should-not (ogent-analytics--model-pricing "mystery-model-9000"))
  (should-not (ogent-analytics--model-pricing nil))
  (should-not (ogent-analytics--completion-cost "mystery-model-9000" 100 100)))

(ert-deftest ogent-analytics-test-cost-arithmetic ()
  "Cost is tokens times per-mtok USD rate, divided by one million."
  (let ((ogent-analytics-model-pricing
         '(("m" . (:input-per-mtok 2.0 :output-per-mtok 10.0)))))
    ;; 1000 in * $2/M + 500 out * $10/M = 0.002 + 0.005
    (should (< (abs (- (ogent-analytics--completion-cost "m" 1000 500)
                       0.007))
               1e-9))
    ;; nil token counts are treated as zero.
    (should (= (ogent-analytics--completion-cost "m" nil nil) 0.0))))

(ert-deftest ogent-analytics-test-cost-stored-at-record-time ()
  "Recording stores the computed cost; unpriced models store NULL."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (let ((ogent-analytics-model-pricing
           '(("priced-model" . (:input-per-mtok 2.0 :output-per-mtok 10.0))))
          (ogent-analytics-chars-per-token 4.0))
      ;; 400 chars -> 100 prompt tokens; 800 chars -> 200 response tokens.
      (ogent-analytics-record-completion
       "priced-model" (make-string 400 ?a) (make-string 800 ?b))
      (ogent-analytics-record-completion "unpriced-model" "p" "r")
      (let ((rows (sqlite-select
                   (ogent-analytics--get-db)
                   "SELECT model, cost_usd FROM completions ORDER BY id")))
        ;; 100 * $2/M + 200 * $10/M = $0.0022, stored as REAL.
        (should (equal (caar rows) "priced-model"))
        (should (< (abs (- (cadar rows) 0.0022)) 1e-9))
        (should (equal (cadr rows) '("unpriced-model" nil)))))))

;;; Fan-out Group Tests (bead ogent-z0k.3, moved from ogent-pje.1)

(ert-deftest ogent-analytics-test-fanout-group-round-trip ()
  "A :fanout-group keyword lands in the fanout_group column; plain is NULL."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (ogent-analytics-record-completion "m1" "p" "r" nil
                                       :fanout-group "grp-42")
    (ogent-analytics-record-completion "m2" "p" "r")
    (let ((rows (sqlite-select
                 (ogent-analytics--get-db)
                 "SELECT model, fanout_group FROM completions ORDER BY id")))
      (should (equal rows '(("m1" "grp-42") ("m2" nil)))))))

(ert-deftest ogent-analytics-test-record-completion-arity-accepts-keywords ()
  "The recorder's arity advertises the keyword tail to the engine sniff."
  (let ((max (cdr (func-arity
                   (indirect-function 'ogent-analytics-record-completion)))))
    (should (eq max 'many))))

;;; One-Key Rating Tests (bead ogent-z0k.1)

(defun ogent-analytics-tests--make-rated-buffer (id)
  "Return a live Org test buffer whose request drawer carries ID.
Point is left on the Response headline.  The caller kills the buffer."
  (let ((buffer (generate-new-buffer " *ogent-analytics-rate*")))
    (with-current-buffer buffer
      (insert "* Request: test prompt\n"
              ":PROPERTIES:\n"
              (format ":OGENT_COMPLETION_ID: %d\n" id)
              ":END:\n"
              "** Response (test-model)\nA response body\n")
      (org-mode)
      (goto-char (point-min))
      (search-forward "** Response")
      (beginning-of-line))
    buffer))

(ert-deftest ogent-analytics-test-rate-response-round-trip ()
  "Rating via the drawer id updates the row's rating and outcome."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (let* ((completion (ogent-analytics-record-completion "m" "p" "r"))
           (id (ogent-analytics-completion-id completion))
           (buffer (ogent-analytics-tests--make-rated-buffer id)))
      (unwind-protect
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'read-char-choice)
                       (lambda (_prompt _chars) ?4)))
              (ogent-analytics-rate-response))
            (should (equal (sqlite-select
                            (ogent-analytics--get-db)
                            "SELECT rating, outcome FROM completions WHERE id = ?"
                            (list id))
                           '((4 "rated")))))
        (kill-buffer buffer)))))

(ert-deftest ogent-analytics-test-rate-response-re-rating-updates ()
  "Re-rating updates the same row instead of inserting another."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (let* ((completion (ogent-analytics-record-completion "m" "p" "r"))
           (id (ogent-analytics-completion-id completion))
           (buffer (ogent-analytics-tests--make-rated-buffer id)))
      (unwind-protect
          (with-current-buffer buffer
            (dolist (key '(?5 ?2))
              (cl-letf (((symbol-function 'read-char-choice)
                         (lambda (_prompt _chars) key)))
                (ogent-analytics-rate-response)))
            (should (equal (sqlite-select
                            (ogent-analytics--get-db)
                            "SELECT COUNT(*), MAX(rating) FROM completions")
                           '((1 2)))))
        (kill-buffer buffer)))))

(ert-deftest ogent-analytics-test-rate-response-updates-pending-struct ()
  "Rating the row tracked as pending keeps the in-memory struct coherent."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (let* ((completion (ogent-analytics-record-completion "m" "p" "r"))
           (id (ogent-analytics-completion-id completion))
           (buffer (ogent-analytics-tests--make-rated-buffer id)))
      (unwind-protect
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'read-char-choice)
                       (lambda (_prompt _chars) ?3)))
              (ogent-analytics-rate-response))
            (should (= (ogent-analytics-completion-rating completion) 3))
            (should (eq (ogent-analytics-completion-outcome completion)
                        'rated)))
        (kill-buffer buffer)))))

(ert-deftest ogent-analytics-test-rate-response-no-id-user-error ()
  "Rating without a stamped completion id names the likely cause."
  (let ((buffer (generate-new-buffer " *ogent-analytics-rate*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert "* Request: never recorded\n** Response (m)\nbody\n")
          (org-mode)
          (goto-char (point-min))
          (let ((err (should-error (ogent-analytics-rate-response)
                                   :type 'user-error)))
            (should (string-match-p "analytics was disabled"
                                    (cadr err)))))
      (kill-buffer buffer))))

(ert-deftest ogent-analytics-test-completion-id-at-point-inherits ()
  "The drawer id is visible from the Response headline via inheritance."
  (let ((buffer (ogent-analytics-tests--make-rated-buffer 77)))
    (unwind-protect
        (with-current-buffer buffer
          (should (= (ogent-analytics--completion-id-at-point) 77))
          ;; Also from inside the response body.
          (goto-char (point-max))
          (should (= (ogent-analytics--completion-id-at-point) 77)))
      (kill-buffer buffer))))

(ert-deftest ogent-analytics-test-completion-id-at-point-non-org ()
  "Outside Org buffers there is no completion id."
  (with-temp-buffer
    (fundamental-mode)
    (should-not (ogent-analytics--completion-id-at-point))))

;;; Auto-Outcome Tests (bead ogent-z0k.2)

(ert-deftest ogent-analytics-test-edit-resolved-hook-registered ()
  "Loading analytics registers the auto-outcome handler on the hook."
  (should (memq #'ogent-analytics--edit-resolved ogent-edit-resolved-hook)))

(ert-deftest ogent-analytics-test-edit-accept-sets-outcome ()
  "Accepting a linked edit sets outcome accepted; rating is untouched."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (let* ((completion (ogent-analytics-record-completion "m" "p" "r"))
           (id (ogent-analytics-completion-id completion)))
      (ogent-analytics--edit-resolved
       (make-ogent-edit :id "e" :completion-id id :status 'accepted))
      (should (equal (sqlite-select
                      (ogent-analytics--get-db)
                      "SELECT outcome, rating FROM completions WHERE id = ?"
                      (list id))
                     '(("accepted" 0)))))))

(ert-deftest ogent-analytics-test-edit-reject-sets-outcome ()
  "Rejecting a linked edit sets outcome rejected on the row."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (let* ((completion (ogent-analytics-record-completion "m" "p" "r"))
           (id (ogent-analytics-completion-id completion)))
      (ogent-analytics--edit-resolved
       (make-ogent-edit :id "e" :completion-id id :status 'rejected))
      (should (equal (sqlite-select
                      (ogent-analytics--get-db)
                      "SELECT outcome FROM completions WHERE id = ?"
                      (list id))
                     '(("rejected")))))))

(ert-deftest ogent-analytics-test-explicit-rating-survives-auto-outcome ()
  "An explicit rating always wins over a later auto-outcome."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (let* ((completion (ogent-analytics-record-completion "m" "p" "r"))
           (id (ogent-analytics-completion-id completion)))
      (ogent-analytics-rate-completion id 4)
      (ogent-analytics--edit-resolved
       (make-ogent-edit :id "e" :completion-id id :status 'accepted))
      (should (equal (sqlite-select
                      (ogent-analytics--get-db)
                      "SELECT outcome, rating FROM completions WHERE id = ?"
                      (list id))
                     '(("rated" 4)))))))

(ert-deftest ogent-analytics-test-unlinked-edit-silently-skipped ()
  "An edit without a completion id records nothing and stays silent."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (let* ((completion (ogent-analytics-record-completion "m" "p" "r"))
           (id (ogent-analytics-completion-id completion))
           (messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (ogent-analytics--edit-resolved
         (make-ogent-edit :id "e" :status 'accepted)))
      (should-not messages)
      (should (equal (sqlite-select
                      (ogent-analytics--get-db)
                      "SELECT outcome FROM completions WHERE id = ?"
                      (list id))
                     '(("pending")))))))

(ert-deftest ogent-analytics-test-ambiguous-resolution-skipped ()
  "A plain smerge \\='resolved status is ambiguous and records nothing."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (let* ((completion (ogent-analytics-record-completion "m" "p" "r"))
           (id (ogent-analytics-completion-id completion)))
      (ogent-analytics--edit-resolved
       (make-ogent-edit :id "e" :completion-id id :status 'resolved))
      (should (equal (sqlite-select
                      (ogent-analytics--get-db)
                      "SELECT outcome FROM completions WHERE id = ?"
                      (list id))
                     '(("pending")))))))

(ert-deftest ogent-analytics-test-rate-completion-programmatic ()
  "The programmatic rating core updates the row without prompting."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (let* ((completion (ogent-analytics-record-completion "m" "p" "r"))
           (id (ogent-analytics-completion-id completion)))
      (ogent-analytics-rate-completion id 5)
      (should (equal (sqlite-select
                      (ogent-analytics--get-db)
                      "SELECT rating, outcome FROM completions WHERE id = ?"
                      (list id))
                     '((5 "rated"))))
      (should (= (ogent-analytics-completion-rating completion) 5))
      (should (eq (ogent-analytics-completion-outcome completion) 'rated)))))

;;; Dashboard Cost/Rating Tests (bead ogent-z0k.4)

(defun ogent-analytics-tests--insert-dashboard-fixture ()
  "Insert the golden dashboard fixture rows into the fixture database.
Four rows across two models and two days; the literal aggregate
values asserted by the ogent-z0k.4 tests derive from these."
  (let ((db (ogent-analytics--get-db)))
    (dolist (row '(("2026-07-01 10:00:00" "model-a" "rated" 5 100 200 300 0.01)
                   ("2026-07-01 11:00:00" "model-a" "rated" 4 100 200 300 0.03)
                   ("2026-07-02 09:00:00" "model-b" "pending" 0 50 50 100 nil)
                   ("2026-07-02 12:00:00" "model-a" "rejected" 0 100 100 200 0.02)))
      (sqlite-execute db "
        INSERT INTO completions (timestamp, model, outcome, rating,
                                 prompt_tokens, response_tokens,
                                 total_tokens, cost_usd)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)" row))))

(ert-deftest ogent-analytics-test-dashboard-cost-and-rating-golden ()
  "Dashboard cost/rating sections render golden aggregate values."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (ogent-analytics-tests--insert-dashboard-fixture)
    (with-temp-buffer
      (ogent-analytics--insert-dashboard)
      (let ((content (buffer-string)))
        ;; Cost by model: model-a 0.01+0.03+0.02, model-b unpriced NULL.
        (should (string-match-p "## Cost by Model" content))
        (should (string-match-p
                 (regexp-quote "| model-a | 3 | $0.0600 | $0.0200 |") content))
        (should (string-match-p
                 (regexp-quote "| model-b | 1 | - | - |") content))
        ;; Cost by day, newest first.
        (should (string-match-p "## Cost by Day" content))
        (should (string-match-p
                 (regexp-quote "| 2026-07-02 | 2 | $0.0200 | $0.0200 |") content))
        (should (string-match-p
                 (regexp-quote "| 2026-07-01 | 2 | $0.0400 | $0.0200 |") content))
        ;; Rating distribution: model-a one 4 and one 5, average 4.5.
        (should (string-match-p "## Ratings by Model" content))
        (should (string-match-p
                 (regexp-quote "| model-a | 0 | 0 | 0 | 1 | 1 | 4.5 |") content))
        (should (string-match-p
                 (regexp-quote "| model-b | 0 | 0 | 0 | 0 | 0 | - |") content))
        ;; Unrated nudge names the * rating key.
        (should (string-match-p
                 (regexp-quote
                  "Unrated completions: 2 (press * on a response headline to rate)")
                 content))))))

(ert-deftest ogent-analytics-test-dashboard-empty-db-renders ()
  "An empty database renders the new sections without error."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (with-temp-buffer
      (ogent-analytics--insert-dashboard)
      (let ((content (buffer-string)))
        (should (string-match-p "No cost data available" content))
        (should (string-match-p "No rating data available" content))
        (should (string-match-p
                 (regexp-quote
                  "Unrated completions: 0 (press * on a response headline to rate)")
                 content))))))

(ert-deftest ogent-analytics-test-dashboard-keeps-existing-keys ()
  "The g/e/o dashboard keys keep their bindings alongside the new views."
  (should (eq (lookup-key ogent-analytics-dashboard-mode-map (kbd "g"))
              #'ogent-analytics-dashboard-refresh))
  (should (eq (lookup-key ogent-analytics-dashboard-mode-map (kbd "e"))
              #'ogent-analytics-export-csv))
  (should (eq (lookup-key ogent-analytics-dashboard-mode-map (kbd "o"))
              #'ogent-analytics-export-org)))

(ert-deftest ogent-analytics-test-export-csv-new-columns ()
  "CSV export carries the cost_usd and fanout_group columns."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (ogent-analytics-tests--insert-dashboard-fixture)
    ;; Retained temp file: the OS owns its lifecycle.
    (let ((file (make-temp-file "ogent-analytics-csv-test-")))
      (ogent-analytics-export-csv file)
      (let ((content (with-temp-buffer
                       (insert-file-contents file)
                       (buffer-string))))
        (should (string-prefix-p
                 (concat "timestamp,model,outcome,rating,prompt_tokens,"
                         "response_tokens,total_tokens,ttft_ms,latency_ms,"
                         "template,cost_usd,fanout_group\n")
                 content))
        (should (string-match-p "0\\.01" content))
        (should (string-match-p "0\\.03" content))))))

(ert-deftest ogent-analytics-test-export-org-new-columns ()
  "Org export model/daily tables carry cost and rating columns."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (ogent-analytics-tests--insert-dashboard-fixture)
    ;; Retained temp file: the OS owns its lifecycle.
    (let ((file (make-temp-file "ogent-analytics-org-test-")))
      (ogent-analytics-export-org file)
      (let ((content (with-temp-buffer
                       (insert-file-contents file)
                       (buffer-string))))
        (should (string-match-p
                 (regexp-quote "| Total Cost | Avg Rating |") content))
        (should (string-match-p (regexp-quote "$0.0600") content))
        (should (string-match-p (regexp-quote "| 4.5 |") content))
        (should (string-match-p
                 (regexp-quote "| Avg Latency | Cost |") content))
        (should (string-match-p (regexp-quote "$0.0400") content))))))

;;; Eval-Loop E2E (bead ogent-z0k.5)

(ert-deftest ogent-analytics-test-eval-loop-e2e ()
  "End-to-end eval loop: record, drawer id, rate, then edit accept.

Living documentation of the eval loop's state machine.  The test
emits one log line per transition; the STABLE format (keep it -- it
is greppable documentation) is

  completion <ID>: recorded
  completion <ID>: rated <N>
  completion <ID>: outcome <accepted|rejected> (rating wins)

and the full chain, asserted literally below, joins the transitions
with \" -> \":

  completion 1: recorded -> rated 4 -> outcome accepted (rating wins)

\"(rating wins)\" documents the precedence rule: the auto-outcome
arrived after an explicit rating, so the row keeps outcome
\\='rated and the rating value."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (ogent-test-with-real-store 'analytics
    (let ((ogent-analytics-model-pricing
           '(("e2e-model" . (:input-per-mtok 2.0 :output-per-mtok 10.0))))
          (ogent-analytics-chars-per-token 4.0)
          (transitions nil))
      ;; 1. Record a completion via a stubbed request: 400 prompt chars
      ;; -> 100 tokens, 800 response chars -> 200 tokens, so the
      ;; record-time cost is 100*$2/M + 200*$10/M = $0.0022.
      (let* ((completion (ogent-analytics-record-completion
                          "e2e-model"
                          (make-string 400 ?p) (make-string 800 ?r)))
             (id (ogent-analytics-completion-id completion))
             (db (ogent-analytics--get-db)))
        (push "recorded" transitions)
        (message "completion %d: recorded" id)
        (should (equal (sqlite-select
                        db "SELECT outcome, rating FROM completions WHERE id = ?"
                        (list id))
                       '(("pending" 0))))
        ;; 2. The request drawer carries the completion id; rate it 4
        ;; from the Response headline (the * registry chord).
        (let ((buffer (ogent-analytics-tests--make-rated-buffer id)))
          (unwind-protect
              (with-current-buffer buffer
                (cl-letf (((symbol-function 'read-char-choice)
                           (lambda (_prompt _chars) ?4)))
                  (ogent-analytics-rate-response)))
            (kill-buffer buffer)))
        (push "rated 4" transitions)
        (message "completion %d: rated 4" id)
        (should (equal (sqlite-select
                        db "SELECT outcome, rating FROM completions WHERE id = ?"
                        (list id))
                       '(("rated" 4))))
        ;; 3. Accept an edit linked to the completion.  The struct
        ;; carries the id exactly as `ogent-edit--process-response'
        ;; stamps it; the resolved hook drives the auto-outcome.
        (let ((edit (make-ogent-edit :id "ogent-edit-e2e"
                                     :completion-id id
                                     :status 'accepted))
              (ogent-edit-resolved-hook
               (list #'ogent-analytics--edit-resolved)))
          (run-hook-with-args 'ogent-edit-resolved-hook edit))
        (push "outcome accepted (rating wins)" transitions)
        (message "completion %d: outcome accepted (rating wins)" id)
        ;; 4. Final row state: the explicit rating wins the outcome,
        ;; the rating survives, and the record-time cost is untouched.
        (let ((row (car (sqlite-select
                         db
                         "SELECT outcome, rating, cost_usd FROM completions WHERE id = ?"
                         (list id)))))
          (should (equal (nth 0 row) "rated"))
          (should (equal (nth 1 row) 4))
          (should (< (abs (- (nth 2 row) 0.0022)) 1e-9)))
        ;; 5. The whole transition chain, oldest first, in the stable
        ;; log format.  Fresh in-memory fixture => the row id is 1.
        (should (equal (format "completion %d: %s" id
                               (mapconcat #'identity
                                          (nreverse transitions) " -> "))
                       "completion 1: recorded -> rated 4 -> outcome accepted (rating wins)"))))))

(provide 'ogent-analytics-tests)

;;; ogent-analytics-tests.el ends here
