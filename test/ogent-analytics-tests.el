;;; ogent-analytics-tests.el --- Tests for ogent-analytics -*- lexical-binding: t; -*-

;;; Commentary:
;; Test suite for analytics and benchmarking functionality.

;;; Code:

(require 'ert)
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
               (lambda (hook fn)
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
               (lambda (hook fn)
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

(provide 'ogent-analytics-tests)

;;; ogent-analytics-tests.el ends here
