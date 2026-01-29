;;; ogent-debug-tests.el --- Tests for ogent-debug -*- lexical-binding: t; -*-

;;; Commentary:
;; Test suite for tool call history tracking and debugging utilities.

;;; Code:

(require 'ert)
(require 'ogent-tools)
(require 'ogent-models)
(require 'ogent-tool-render)
(require 'ogent-tool-approval)
(require 'ogent-tool-fsm)
(require 'ogent-debug)

;;; Tool History Tests

(ert-deftest ogent-debug-test-log-tool-call ()
  "Test logging a tool call to history."
  (let ((ogent-debug-tool-history nil))
    (let* ((tool-call '(:id "test-1" :name test-tool :args (:arg1 "value1")))
           (result "Success!")
           (duration 0.123)
           (entry (ogent-debug-log-tool-call tool-call result duration)))
      ;; Check entry structure
      (should (plist-get entry :id))
      (should (eq (plist-get entry :name) 'test-tool))
      (should (plist-get entry :args))
      (should (equal (plist-get entry :result) "Success!"))
      (should (null (plist-get entry :error)))
      (should (equal (plist-get entry :duration) 0.123))
      (should (plist-get entry :timestamp))
      
      ;; Check history list
      (should (= (length ogent-debug-tool-history) 1))
      (should (equal (car ogent-debug-tool-history) entry)))))

(ert-deftest ogent-debug-test-log-tool-call-with-error ()
  "Test logging a failed tool call."
  (let ((ogent-debug-tool-history nil))
    (let* ((tool-call '(:id "test-2"
                            :name failing-tool
                            :args (:arg1 "test")
                            :error "Something went wrong"))
           (result nil)
           (duration 0.050)
           (entry (ogent-debug-log-tool-call tool-call result duration)))
      ;; Check error is recorded
      (should (null (plist-get entry :result)))
      (should (equal (plist-get entry :error) "Something went wrong"))
      (should (equal (plist-get entry :duration) 0.050)))))

(ert-deftest ogent-debug-test-history-max-limit ()
  "Test that history respects max limit."
  (let ((ogent-debug-tool-history nil)
        (ogent-debug-tool-history-max 3))
    ;; Add 5 entries
    (dotimes (i 5)
      (ogent-debug-log-tool-call
       (list :id (format "test-%d" i) :name 'test-tool :args nil)
       "result"
       0.1))
    ;; Should only keep 3 most recent
    (should (= (length ogent-debug-tool-history) 3))
    ;; Most recent should be test-4
    (should (equal (plist-get (car ogent-debug-tool-history) :id) "test-4"))))

(ert-deftest ogent-debug-test-clear-history ()
  "Test clearing tool call history."
  (let ((ogent-debug-tool-history nil))
    ;; Add some entries
    (ogent-debug-log-tool-call
     '(:id "test-1" :name tool1 :args nil)
     "result"
     0.1)
    (ogent-debug-log-tool-call
     '(:id "test-2" :name tool2 :args nil)
     "result"
     0.2)
    (should (= (length ogent-debug-tool-history) 2))
    
    ;; Clear
    (ogent-debug-clear-tool-history)
    (should (null ogent-debug-tool-history))))

(ert-deftest ogent-debug-test-last-tool ()
  "Test retrieving last tool call."
  (let ((ogent-debug-tool-history nil))
    ;; Initially nil
    (should (null (ogent-debug-last-tool)))
    
    ;; Add entries
    (ogent-debug-log-tool-call
     '(:id "first" :name tool1 :args nil)
     "result"
     0.1)
    (ogent-debug-log-tool-call
     '(:id "second" :name tool2 :args nil)
     "result"
     0.2)
    
    ;; Should return most recent
    (let ((last (ogent-debug-last-tool)))
      (should last)
      (should (equal (plist-get last :id) "second")))))

(ert-deftest ogent-debug-test-duration-tracking ()
  "Test that duration is correctly tracked."
  (let ((ogent-debug-tool-history nil))
    (let* ((durations '(0.001 0.123 1.234 10.5))
           (entries nil))
      ;; Log calls with different durations
      (dolist (dur durations)
        (push (ogent-debug-log-tool-call
               (list :id (format "test-%.3f" dur) :name 'test-tool :args nil)
               "result"
               dur)
              entries))
      
      ;; Verify all durations recorded
      (dolist (entry (nreverse entries))
        (let ((expected (plist-get entry :duration)))
          (should (numberp expected))
          (should (member expected durations)))))))

(ert-deftest ogent-debug-test-args-preservation ()
  "Test that complex arguments are preserved."
  (let ((ogent-debug-tool-history nil))
    (let* ((complex-args '(:file_path "/test/path.txt"
				      :content "Multi\nline\ntext"
				      :options (:recursive t :depth 3)))
           (tool-call (list :id "test-args"
                            :name 'complex-tool
                            :args complex-args))
           (entry (ogent-debug-log-tool-call tool-call "result" 0.1)))
      ;; Verify args are preserved exactly
      (should (equal (plist-get entry :args) complex-args))
      (should (equal (plist-get (plist-get entry :args) :file_path)
                     "/test/path.txt"))
      (should (equal (plist-get (plist-get entry :args) :content)
                     "Multi\nline\ntext")))))

(ert-deftest ogent-debug-test-history-buffer-empty ()
  "Test history buffer displays message when empty."
  (let ((ogent-debug-tool-history nil))
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      (should (search-forward "No tool calls recorded" nil t))
      (kill-buffer))))

(ert-deftest ogent-debug-test-history-buffer-content ()
  "Test history buffer displays tool calls."
  (let ((ogent-debug-tool-history nil))
    ;; Add a successful call
    (ogent-debug-log-tool-call
     '(:id "success-1" :name read-file :args (:path "/test.txt"))
     "File content here"
     0.234)
    
    ;; Add a failed call
    (ogent-debug-log-tool-call
     (list :id "fail-1"
           :name 'write-file
           :args '(:path "/test.txt" :content "data")
           :error "Permission denied")
     nil
     0.050)
    
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      ;; Check for content
      (goto-char (point-min))
      (should (search-forward "SUCCESS" nil t))
      (should (search-forward "read-file" nil t))
      (should (search-forward "0.234s" nil t))
      
      (should (search-forward "FAILED" nil t))
      (should (search-forward "write-file" nil t))
      (should (search-forward "Permission denied" nil t))
      
      (kill-buffer))))

(ert-deftest ogent-debug-test-timestamp-present ()
  "Test that timestamps are recorded and formatted."
  (let ((ogent-debug-tool-history nil))
    (let ((before (current-time)))
      (ogent-debug-log-tool-call
       '(:id "time-test" :name test-tool :args nil)
       "result"
       0.1)
      (let* ((entry (car ogent-debug-tool-history))
             (timestamp (plist-get entry :timestamp)))
        (should timestamp)
        ;; Timestamp should be >= before (not strictly greater - could be equal)
        (should (not (time-less-p timestamp before)))
        ;; Should be recent (within 1 second)
        (should (< (float-time (time-subtract (current-time) timestamp)) 1.0))))))

;;; Integration Tests

(ert-deftest ogent-debug-test-multiple-calls-ordering ()
  "Test that multiple calls maintain correct ordering."
  (let ((ogent-debug-tool-history nil))
    ;; Add calls in sequence
    (dotimes (i 5)
      (ogent-debug-log-tool-call
       (list :id (format "call-%d" i) :name 'test-tool :args nil)
       (format "result-%d" i)
       (/ (float i) 10.0))
      ;; Small delay to ensure timestamp differences
      (sleep-for 0.001))
    
    ;; Most recent should be first
    (should (equal (plist-get (nth 0 ogent-debug-tool-history) :id) "call-4"))
    (should (equal (plist-get (nth 1 ogent-debug-tool-history) :id) "call-3"))
    (should (equal (plist-get (nth 4 ogent-debug-tool-history) :id) "call-0"))))

(ert-deftest ogent-debug-test-fsm-integration ()
  "Test that ogent-tool-fsm automatically logs to history."
  (require 'ogent-tool-fsm)
  (require 'ogent-tools)
  (require 'ogent-models)

  ;; Save and restore global state to ensure test isolation
  (let ((saved-history ogent-debug-tool-history)
        (saved-registry ogent-tool-registry))
    (unwind-protect
        (let ((ogent-debug-tool-history nil)
              (ogent-tool-registry
               (list '(:name test-integration-tool
                             :function (lambda (arg) (format "Result: %s" arg))
                             :description "Test tool"
                             :args ((:name "arg" :type "string" :description "Test"))
                             :confirm nil))))
          ;; Execute a tool via FSM
          (let ((callback-invoked nil))
            (ogent-tool-fsm-execute
             '(:id "integration-1" :name test-integration-tool :args (:arg "hello"))
             (lambda (result error)
               (setq callback-invoked t)
               (should (null error))
               (should (stringp result))))

            ;; Callback should have been invoked
            (should callback-invoked)

            ;; History should have one entry
            (should (= (length ogent-debug-tool-history) 1))

            ;; Verify entry details
            (let ((entry (car ogent-debug-tool-history)))
              (should (equal (plist-get entry :id) "integration-1"))
              (should (eq (plist-get entry :name) 'test-integration-tool))
              (should (plist-get entry :result))
              (should (null (plist-get entry :error)))
              (should (numberp (plist-get entry :duration)))
              (should (>= (plist-get entry :duration) 0)))))
      ;; Cleanup: restore global state
      (setq ogent-debug-tool-history saved-history)
      (setq ogent-tool-registry saved-registry))))

(ert-deftest ogent-debug-test-fsm-failure-integration ()
  "Test that failed tool executions are logged correctly."
  (require 'ogent-tool-fsm)
  (require 'ogent-tools)
  (require 'ogent-models)

  ;; Save and restore global state to ensure test isolation
  (let ((saved-history ogent-debug-tool-history)
        (saved-registry ogent-tool-registry))
    (unwind-protect
        (let ((ogent-debug-tool-history nil)
              (ogent-tool-registry
               (list '(:name failing-integration-tool
                             :function (lambda (_arg) (error "Boom!"))
                             :description "Failing test tool"
                             :args ((:name "arg" :type "string" :description "Test"))
                             :confirm nil))))

          ;; Execute a failing tool
          (let ((callback-invoked nil))
            (ogent-tool-fsm-execute
             '(:id "fail-1" :name failing-integration-tool :args (:arg "test"))
             (lambda (result error)
               (setq callback-invoked t)
               (should (null result))
               (should (stringp error))))

            ;; Callback should have been invoked
            (should callback-invoked)

            ;; History should have one entry
            (should (= (length ogent-debug-tool-history) 1))

            ;; Verify error is recorded
            (let ((entry (car ogent-debug-tool-history)))
              (should (equal (plist-get entry :id) "fail-1"))
              (should (null (plist-get entry :result)))
              (should (stringp (plist-get entry :error)))
              (should (string-match-p "Boom!" (plist-get entry :error)))
              (should (numberp (plist-get entry :duration))))))
      ;; Cleanup: restore global state
      (setq ogent-debug-tool-history saved-history)
      (setq ogent-tool-registry saved-registry))))

;;; Debug Mode Tests

(ert-deftest ogent-debug-mode-enables-logging ()
  "Test that ogent-debug-mode enables logging."
  (let ((ogent-debug-mode nil)
        (ogent-debug-log-level nil)
        (ogent-debug-enabled nil))
    ;; Enable mode
    (ogent-debug-mode 1)
    (should ogent-debug-mode)
    (should ogent-debug-log-level)
    (should ogent-debug-enabled)
    ;; Disable mode
    (ogent-debug-mode -1)
    (should-not ogent-debug-mode)
    (should-not ogent-debug-enabled)))

(ert-deftest ogent-debug-log-creates-buffer ()
  "Test that ogent-debug-log creates the debug buffer."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-test*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log 'test "Test message" :key "value")
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "TEST" (buffer-string)))
      (should (string-match-p "Test message" (buffer-string)))
      (should (string-match-p "key=" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-log-respects-level ()
  "Test that logging respects the log level."
  (let ((ogent-debug-log-level nil)
        (ogent-debug-buffer "*ogent-debug-test*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    ;; Should not log when level is nil
    (ogent-debug-log 'test "Should not appear")
    (should-not (get-buffer ogent-debug-buffer))))

(ert-deftest ogent-debug-log-edit-parse-logs-info ()
  "Test edit parsing logging at info level."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-test*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log-edit-parse
     "<<<<<<< SEARCH\nold\n=======\nnew\n>>>>>>> REPLACE"
     '((:file "test.el" :search "old" :replace "new")))
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "EDIT" (buffer-string)))
      (should (string-match-p "Edit parsed" (buffer-string)))
      (should (string-match-p "edits=1" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-log-edit-apply-logs-status ()
  "Test edit application logging."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-test*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log-edit-apply
     '(:file "test.el" :type replace)
     "applied")
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "Edit applied" (buffer-string)))
      (should (string-match-p "file=\"test.el\"" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-log-validation-logs-result ()
  "Test validation logging."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-test*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log-validation "handle" "passed" "all handles resolved")
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "VALIDATION" (buffer-string)))
      (should (string-match-p "handle validation: passed" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-log-context-respects-flag ()
  "Test that context logging respects ogent-debug-log-context."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-log-context nil)
        (ogent-debug-buffer "*ogent-debug-test*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    ;; Should not log when flag is nil
    (ogent-debug-log-context "building" :handles 5)
    (should-not (get-buffer ogent-debug-buffer))
    ;; Should log when flag is t
    (setq ogent-debug-log-context t)
    (ogent-debug-log-context "building" :handles 5)
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "CONTEXT" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-mode-keymap ()
  "Test that debug mode keymap is set up."
  (should (keymapp ogent-debug-mode-map))
  (should (lookup-key ogent-debug-mode-map (kbd "C-c d c")))
  (should (lookup-key ogent-debug-mode-map (kbd "C-c d s")))
  (should (lookup-key ogent-debug-mode-map (kbd "C-c d h"))))

(provide 'ogent-debug-tests)

;;; ogent-debug-tests.el ends here
