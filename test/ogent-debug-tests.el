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

;;; Enable/Disable/Toggle Tests

(ert-deftest ogent-debug-test-enable ()
  "Test ogent-debug-enable sets the flag."
  (let ((ogent-debug-enabled nil))
    (ogent-debug-enable)
    (should ogent-debug-enabled)))

(ert-deftest ogent-debug-test-disable ()
  "Test ogent-debug-disable clears the flag."
  (let ((ogent-debug-enabled t))
    (ogent-debug-disable)
    (should-not ogent-debug-enabled)))

(ert-deftest ogent-debug-test-toggle-on ()
  "Test ogent-debug-toggle turns on when off."
  (let ((ogent-debug-enabled nil))
    (ogent-debug-toggle)
    (should ogent-debug-enabled)))

(ert-deftest ogent-debug-test-toggle-off ()
  "Test ogent-debug-toggle turns off when on."
  (let ((ogent-debug-enabled t))
    (ogent-debug-toggle)
    (should-not ogent-debug-enabled)))

(ert-deftest ogent-debug-test-toggle-round-trip ()
  "Test that toggling twice restores original state."
  (let ((ogent-debug-enabled nil))
    (ogent-debug-toggle)
    (ogent-debug-toggle)
    (should-not ogent-debug-enabled)))

;;; ogent-debug-show Tests

(ert-deftest ogent-debug-test-show-creates-buffer ()
  "Test ogent-debug-show creates and displays the debug buffer."
  (let ((ogent-debug-buffer "*ogent-debug-show-test*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-show)
    (should (get-buffer ogent-debug-buffer))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-test-show-nil-buffer ()
  "Test ogent-debug-show falls back to *Messages* when buffer is nil."
  (let ((ogent-debug-buffer nil))
    ;; Should not error when buffer name is nil
    (ogent-debug-show)))

;;; Export JSON Tests

(ert-deftest ogent-debug-test-export-json-format ()
  "Test JSON export produces valid JSON with version, count, and exported fields."
  (let ((ogent-debug-tool-history nil)
        (export-file (make-temp-file "ogent-export-" nil ".json")))
    (unwind-protect
        (progn
          ;; Add a tool call
          (ogent-debug-log-tool-call
           '(:id "export-1" :name test-export :args (:key "val"))
           "result-data"
           0.456)
          (ogent-debug-export-tool-history-json export-file)
          ;; Read and parse the JSON
          (with-temp-buffer
            (insert-file-contents export-file)
            (let* ((json-object-type 'plist)
                   (json-array-type 'list)
                   (json-key-type 'keyword)
                   (data (json-read-from-string (buffer-string))))
              (should (eq (plist-get data :version) 1))
              (should (plist-get data :exported))
              (should (eq (plist-get data :count) 1))
              ;; :calls is present in the output
              (should (plist-get data :calls)))))
      (delete-file export-file))))

(ert-deftest ogent-debug-test-export-json-empty-history ()
  "Test JSON export signals error on empty history."
  (let ((ogent-debug-tool-history nil))
    (should-error (ogent-debug-export-tool-history-json "/tmp/nope.json")
                  :type 'user-error)))

(ert-deftest ogent-debug-test-export-json-multiple-entries ()
  "Test JSON export with multiple tool history entries."
  (let ((ogent-debug-tool-history nil)
        (export-file (make-temp-file "ogent-export-" nil ".json")))
    (unwind-protect
        (progn
          (dotimes (i 3)
            (ogent-debug-log-tool-call
             (list :id (format "multi-%d" i) :name 'multi-tool :args nil)
             (format "result-%d" i)
             (* i 0.1)))
          (ogent-debug-export-tool-history-json export-file)
          (with-temp-buffer
            (insert-file-contents export-file)
            (let* ((json-object-type 'plist)
                   (json-array-type 'list)
                   (json-key-type 'keyword)
                   (data (json-read-from-string (buffer-string))))
              (should (eq (plist-get data :count) 3)))))
      (delete-file export-file))))

;;; Export Text Tests

(ert-deftest ogent-debug-test-export-text-format ()
  "Test text export contains correct content."
  (let ((ogent-debug-tool-history nil)
        (export-file (make-temp-file "ogent-export-" nil ".txt")))
    (unwind-protect
        (progn
          (ogent-debug-log-tool-call
           '(:id "text-1" :name text-export-tool :args (:file "/tmp/x"))
           "text result"
           0.789)
          (ogent-debug-export-tool-history-text export-file)
          (with-temp-buffer
            (insert-file-contents export-file)
            (let ((content (buffer-string)))
              ;; Should have header
              (should (string-match-p "# Ogent Tool Call History" content))
              (should (string-match-p "# Exported:" content))
              (should (string-match-p "# Entries: 1" content))
              ;; Should have entry
              (should (string-match-p "text-export-tool" content))
              (should (string-match-p "SUCCESS" content))
              (should (string-match-p "0\\.789s" content))
              (should (string-match-p "ID: text-1" content)))))
      (delete-file export-file))))

(ert-deftest ogent-debug-test-export-text-empty-history ()
  "Test text export signals error on empty history."
  (let ((ogent-debug-tool-history nil))
    (should-error (ogent-debug-export-tool-history-text "/tmp/nope.txt")
                  :type 'user-error)))

(ert-deftest ogent-debug-test-export-text-error-entry ()
  "Test text export correctly formats failed tool calls."
  (let ((ogent-debug-tool-history nil)
        (export-file (make-temp-file "ogent-export-" nil ".txt")))
    (unwind-protect
        (progn
          (ogent-debug-log-tool-call
           (list :id "fail-text" :name 'fail-tool :args nil
                 :error "disk full")
           nil
           0.01)
          (ogent-debug-export-tool-history-text export-file)
          (with-temp-buffer
            (insert-file-contents export-file)
            (let ((content (buffer-string)))
              (should (string-match-p "FAILED" content))
              (should (string-match-p "disk full" content)))))
      (delete-file export-file))))

;;; Import Tool History Tests

(ert-deftest ogent-debug-test-import-tool-history ()
  "Test importing tool history from JSON file."
  (let ((ogent-debug-tool-history nil)
        (ogent-debug-tool-history-max 100)
        (import-file (make-temp-file "ogent-import-" nil ".json")))
    (unwind-protect
        (progn
          ;; Write a valid JSON file with proper array-of-objects syntax
          (with-temp-file import-file
            (insert "{\"version\":1,\"exported\":\"2025-01-01\",\"count\":2,\"calls\":[")
            (insert "{\"id\":\"imp-1\",\"name\":\"imported-tool\",\"args\":null,\"result\":\"ok\",\"error\":null,\"duration\":0.1,\"timestamp\":\"2025-01-01\"},")
            (insert "{\"id\":\"imp-2\",\"name\":\"imported-tool-2\",\"args\":null,\"result\":null,\"error\":\"fail\",\"duration\":0.2,\"timestamp\":\"2025-01-01\"}")
            (insert "]}"))
          (ogent-debug-import-tool-history import-file)
          ;; Should have 2 entries
          (should (= (length ogent-debug-tool-history) 2))
          ;; Check names are interned symbols
          (should (symbolp (plist-get (car ogent-debug-tool-history) :name)))
          ;; Most recent push is last in file = imp-2
          (should (equal (plist-get (car ogent-debug-tool-history) :id) "imp-2")))
      (delete-file import-file))))

(ert-deftest ogent-debug-test-import-merges-with-existing ()
  "Test that import merges with existing history."
  (let ((ogent-debug-tool-history nil)
        (ogent-debug-tool-history-max 100)
        (import-file (make-temp-file "ogent-import-" nil ".json")))
    (unwind-protect
        (progn
          ;; Add an existing entry
          (ogent-debug-log-tool-call
           '(:id "existing-1" :name existing-tool :args nil)
           "result"
           0.1)
          (should (= (length ogent-debug-tool-history) 1))
          ;; Import one more with proper JSON array syntax
          (with-temp-file import-file
            (insert "{\"version\":1,\"count\":1,\"calls\":[")
            (insert "{\"id\":\"imported-1\",\"name\":\"new-tool\",\"args\":null,\"result\":\"ok\",\"error\":null,\"duration\":0.5,\"timestamp\":\"2025-01-01\"}")
            (insert "]}"))
          (ogent-debug-import-tool-history import-file)
          ;; Should have 2 total
          (should (= (length ogent-debug-tool-history) 2)))
      (delete-file import-file))))

;;; Replay Tool Tests

(ert-deftest ogent-debug-test-replay-last-tool-empty ()
  "Test replay-last-tool signals error when history is empty."
  (let ((ogent-debug-tool-history nil))
    (should-error (ogent-debug-replay-last-tool)
                  :type 'user-error)))

(ert-deftest ogent-debug-test-replay-tool-calls-fsm ()
  "Test replay-tool invokes ogent-tool-fsm-execute with correct args."
  (let ((ogent-debug-tool-history nil)
        (fsm-called nil)
        (fsm-tool-call nil))
    ;; Add a history entry
    (ogent-debug-log-tool-call
     '(:id "replay-test" :name some-tool :args (:x 1))
     "old-result"
     0.1)
    ;; Mock ogent-tool-fsm-execute
    (cl-letf (((symbol-function 'ogent-tool-fsm-execute)
               (lambda (tool-call callback)
                 (setq fsm-called t)
                 (setq fsm-tool-call tool-call)
                 (funcall callback "replayed" nil))))
      (ogent-debug-replay-tool (car ogent-debug-tool-history))
      (should fsm-called)
      ;; The replayed call should have same name and args
      (should (eq (plist-get fsm-tool-call :name) 'some-tool))
      (should (equal (plist-get fsm-tool-call :args) '(:x 1)))
      ;; ID should be a replay ID
      (should (string-match-p "^replay-" (plist-get fsm-tool-call :id))))))

;;; Show Approval Status Tests

(ert-deftest ogent-debug-test-show-approval-status-no-session ()
  "Test show-approval-status when no session is active."
  (let ((ogent-tool-approval--session-approved nil))
    ;; Mock require to avoid loading real module
    (cl-letf (((symbol-function 'require)
               (lambda (feature &rest _)
                 (when (eq feature 'ogent-tool-approval)
                   ;; Already bound above
                   nil))))
      (ogent-debug-show-approval-status)
      (let ((buf (get-buffer "*ogent-approval-status*")))
        (should buf)
        (with-current-buffer buf
          (should (string-match-p "Inactive" (buffer-string)))
          (should (string-match-p "No tools approved" (buffer-string))))
        (kill-buffer buf)))))

(ert-deftest ogent-debug-test-show-approval-status-with-approvals ()
  "Test show-approval-status when tools are approved."
  (let ((ogent-tool-approval--session-approved (make-hash-table :test 'equal)))
    (puthash 'read_file t ogent-tool-approval--session-approved)
    (puthash 'write_file t ogent-tool-approval--session-approved)
    (cl-letf (((symbol-function 'require)
               (lambda (feature &rest _)
                 (when (eq feature 'ogent-tool-approval)
                   nil))))
      (ogent-debug-show-approval-status)
      (let ((buf (get-buffer "*ogent-approval-status*")))
        (should buf)
        (with-current-buffer buf
          (should (string-match-p "Active" (buffer-string)))
          (should (string-match-p "Approved tools:" (buffer-string))))
        (kill-buffer buf)))))

;;; Tool History Navigation Tests

(ert-deftest ogent-debug-test-tool-history-next ()
  "Test navigation to next tool entry in history buffer."
  (let ((ogent-debug-tool-history nil))
    ;; Add two entries
    (ogent-debug-log-tool-call
     '(:id "nav-1" :name tool-a :args nil) "r1" 0.1)
    (ogent-debug-log-tool-call
     '(:id "nav-2" :name tool-b :args nil) "r2" 0.2)
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      (goto-char (point-min))
      ;; Find first entry
      (should (re-search-forward "^## \\[" nil t))
      (let ((first-pos (line-beginning-position)))
        ;; Navigate to next
        (ogent-tool-history-next)
        ;; Should be on a different entry line
        (should (> (point) first-pos))
        (beginning-of-line)
        (should (looking-at "^## \\[")))
      (kill-buffer))))

(ert-deftest ogent-debug-test-tool-history-prev ()
  "Test navigation to previous tool entry in history buffer."
  (let ((ogent-debug-tool-history nil))
    ;; Add two entries
    (ogent-debug-log-tool-call
     '(:id "nav-1" :name tool-a :args nil) "r1" 0.1)
    (ogent-debug-log-tool-call
     '(:id "nav-2" :name tool-b :args nil) "r2" 0.2)
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      (goto-char (point-max))
      ;; Navigate backward
      (ogent-tool-history-prev)
      (should (looking-at "^## \\["))
      ;; Navigate backward again to first
      (ogent-tool-history-prev)
      (should (looking-at "^## \\["))
      (kill-buffer))))

;;; Tool History Refresh Tests

(ert-deftest ogent-debug-test-tool-history-refresh ()
  "Test that refresh re-renders the history buffer."
  (let ((ogent-debug-tool-history nil))
    (ogent-debug-log-tool-call
     '(:id "refresh-1" :name tool-r :args nil) "r" 0.1)
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      ;; Should have one entry
      (goto-char (point-min))
      (should (search-forward "tool-r" nil t))
      ;; Add another entry
      (ogent-debug-log-tool-call
       '(:id "refresh-2" :name tool-r2 :args nil) "r2" 0.2)
      ;; Refresh
      (ogent-tool-history-refresh)
      ;; Should now have both entries
      (goto-char (point-min))
      (should (search-forward "tool-r" nil t))
      (should (search-forward "tool-r2" nil t))
      (kill-buffer))))

;;; Tool History Help Test

(ert-deftest ogent-debug-test-tool-history-help ()
  "Test that help displays a message."
  (let ((last-msg nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq last-msg (apply #'format fmt args)))))
      (ogent-tool-history-help)
      (should last-msg)
      (should (string-match-p "n/p" last-msg))
      (should (string-match-p "replay" last-msg))
      (should (string-match-p "refresh" last-msg)))))

;;; Tool History Mode Tests

(ert-deftest ogent-debug-test-tool-history-mode-keymap ()
  "Test that tool history mode keymap has expected bindings."
  (should (keymapp ogent-tool-history-mode-map))
  (should (eq (lookup-key ogent-tool-history-mode-map "n")
              'ogent-tool-history-next))
  (should (eq (lookup-key ogent-tool-history-mode-map "p")
              'ogent-tool-history-prev))
  (should (eq (lookup-key ogent-tool-history-mode-map "g")
              'ogent-tool-history-refresh))
  (should (eq (lookup-key ogent-tool-history-mode-map "q")
              'quit-window))
  (should (eq (lookup-key ogent-tool-history-mode-map "?")
              'ogent-tool-history-help))
  (should (eq (lookup-key ogent-tool-history-mode-map "j")
              'ogent-debug-export-tool-history-json))
  (should (eq (lookup-key ogent-tool-history-mode-map "t")
              'ogent-debug-export-tool-history-text)))

(ert-deftest ogent-debug-test-tool-history-buffer-mode ()
  "Test that tool history buffer uses the correct major mode."
  (let ((ogent-debug-tool-history nil))
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      (should (eq major-mode 'ogent-tool-history-mode))
      (should truncate-lines)
      (kill-buffer))))

;;; Debug Log Function Tests

(ert-deftest ogent-debug-test-debug-log-function ()
  "Test ogent-debug--log writes to debug buffer."
  (let ((ogent-debug-buffer "*ogent-debug-log-test*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug--log 'test-fn "test message %s" "arg1")
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "\\[ogent\\] test-fn:" (buffer-string)))
      (should (string-match-p "test message arg1" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-test-debug-log-to-messages ()
  "Test ogent-debug--log writes to *Messages* when buffer is nil."
  (let ((ogent-debug-buffer nil)
        (last-msg nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq last-msg (apply #'format fmt args)))))
      (ogent-debug--log 'test-fn "hello %s" "world")
      (should last-msg)
      (should (string-match-p "\\[ogent\\] test-fn: hello world" last-msg)))))

;;; Export Round-Trip Test

(ert-deftest ogent-debug-test-import-respects-max-limit ()
  "Test that import respects the history max limit."
  (let ((ogent-debug-tool-history nil)
        (ogent-debug-tool-history-max 2)
        (import-file (make-temp-file "ogent-import-limit-" nil ".json")))
    (unwind-protect
        (progn
          ;; Import 3 entries but max is 2
          (with-temp-file import-file
            (insert "{\"version\":1,\"count\":3,\"calls\":[")
            (insert "{\"id\":\"lim-1\",\"name\":\"t1\",\"args\":null,\"result\":\"ok\",\"error\":null,\"duration\":0.1,\"timestamp\":\"2025-01-01\"},")
            (insert "{\"id\":\"lim-2\",\"name\":\"t2\",\"args\":null,\"result\":\"ok\",\"error\":null,\"duration\":0.2,\"timestamp\":\"2025-01-02\"},")
            (insert "{\"id\":\"lim-3\",\"name\":\"t3\",\"args\":null,\"result\":\"ok\",\"error\":null,\"duration\":0.3,\"timestamp\":\"2025-01-03\"}")
            (insert "]}"))
          (ogent-debug-import-tool-history import-file)
          ;; Should be trimmed to max
          (should (= (length ogent-debug-tool-history) 2)))
      (delete-file import-file))))

;;; Debug Clear Tests

(ert-deftest ogent-debug-test-clear-debug-buffer ()
  "Test ogent-debug-clear erases the debug buffer."
  (let ((ogent-debug-buffer "*ogent-debug-clear-test*"))
    (with-current-buffer (get-buffer-create ogent-debug-buffer)
      (insert "Some debug output\nMore output\n"))
    (ogent-debug-clear)
    (with-current-buffer ogent-debug-buffer
      (should (= (buffer-size) 0)))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-test-clear-nil-buffer ()
  "Test ogent-debug-clear when buffer name is nil."
  (let ((ogent-debug-buffer nil))
    ;; Should not error
    (ogent-debug-clear)))

;;; Insert Log Tests

(ert-deftest ogent-debug-test-insert-log-creates-buffer ()
  "Test ogent-debug--insert-log creates buffer and inserts text."
  (let ((ogent-debug-buffer "*ogent-debug-insert-test*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug--insert-log "Test log line")
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "Test log line" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-test-insert-log-nil-buffer ()
  "Test ogent-debug--insert-log does nothing when buffer is nil."
  (let ((ogent-debug-buffer nil))
    ;; Should not error, and should not create any buffer
    (ogent-debug--insert-log "Should go nowhere")))

(ert-deftest ogent-debug-test-insert-log-appends ()
  "Test ogent-debug--insert-log appends to existing content."
  (let ((ogent-debug-buffer "*ogent-debug-append-test*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug--insert-log "First line")
    (ogent-debug--insert-log "Second line")
    (with-current-buffer ogent-debug-buffer
      (let ((content (buffer-string)))
        (should (string-match-p "First line" content))
        (should (string-match-p "Second line" content))
        ;; First should appear before second
        (should (< (string-match "First line" content)
                   (string-match "Second line" content)))))
    (kill-buffer ogent-debug-buffer)))

;;; Setup/Teardown Hooks Tests

(defvar gptel-log-level nil
  "Test stub for gptel-log-level.")
(defvar gptel-pre-request-hook nil
  "Test stub for gptel-pre-request-hook.")
(defvar gptel-post-response-hook nil
  "Test stub for gptel-post-response-hook.")

(ert-deftest ogent-debug-test-setup-hooks ()
  "Test ogent-debug--setup-hooks adds hooks when variables are bound."
  (let ((gptel-pre-request-hook nil)
        (gptel-post-response-hook nil))
    (ogent-debug--setup-hooks)
    (should (memq 'ogent-debug--log-pre-request gptel-pre-request-hook))
    (should (memq 'ogent-debug--log-post-response gptel-post-response-hook))
    ;; Cleanup
    (ogent-debug--teardown-hooks)))

(ert-deftest ogent-debug-test-teardown-hooks ()
  "Test ogent-debug--teardown-hooks removes hooks."
  (let ((gptel-pre-request-hook (list 'ogent-debug--log-pre-request))
        (gptel-post-response-hook (list 'ogent-debug--log-post-response)))
    (ogent-debug--teardown-hooks)
    (should-not (memq 'ogent-debug--log-pre-request gptel-pre-request-hook))
    (should-not (memq 'ogent-debug--log-post-response gptel-post-response-hook))))

;;; Log Pre-Request Tests

(ert-deftest ogent-debug-test-log-pre-request ()
  "Test ogent-debug--log-pre-request sets start time and logs."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-prereq-test*")
        (ogent-debug--request-start-time nil)
        (gptel-model "test-model"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (cl-letf (((symbol-function 'gptel-backend-name)
               (lambda (_backend) "test-backend")))
      (let ((gptel-backend 'mock-backend))
        (ogent-debug--log-pre-request)))
    (should ogent-debug--request-start-time)
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "REQUEST STARTED" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

;;; Log Post-Response Tests

(ert-deftest ogent-debug-test-log-post-response ()
  "Test ogent-debug--log-post-response logs elapsed time."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-postresp-test*")
        (ogent-debug--request-start-time (current-time)))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug--log-post-response 1 100)
    (should-not ogent-debug--request-start-time) ; Should be cleared
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "RESPONSE RECEIVED" (buffer-string)))
      (should (string-match-p "length=99" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-test-log-post-response-no-start-time ()
  "Test ogent-debug--log-post-response handles nil start time."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-postresp-nil-test*")
        (ogent-debug--request-start-time nil))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug--log-post-response 1 50)
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "RESPONSE RECEIVED" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

;;; Edit Parse Logging at Debug Level

(ert-deftest ogent-debug-test-log-edit-parse-debug-level ()
  "Test edit parsing logging at debug level includes preview."
  (let ((ogent-debug-log-level 'debug)
        (ogent-debug-buffer "*ogent-debug-editparse-debug*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log-edit-parse
     "<<<<<<< SEARCH\nold content\n=======\nnew content\n>>>>>>> REPLACE"
     '((:file "test.el" :search "old" :replace "new")))
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (let ((content (buffer-string)))
        (should (string-match-p "Source preview:" content))
        (should (string-match-p "Parsed:" content))))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-test-log-edit-parse-nil-level ()
  "Test edit parsing logging does nothing when level is nil."
  (let ((ogent-debug-log-level nil)
        (ogent-debug-buffer "*ogent-debug-editparse-nil*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log-edit-parse "source" '((:file "test.el")))
    (should-not (get-buffer ogent-debug-buffer))))

(ert-deftest ogent-debug-test-log-edit-parse-non-list-result ()
  "Test edit parsing logging handles non-list result."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-editparse-nonlist*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log-edit-parse "source" "not a list")
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "edits=0" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

;;; Edit Apply Logging Tests

(ert-deftest ogent-debug-test-log-edit-apply-with-error ()
  "Test edit apply logging with error."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-editapply-err*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log-edit-apply
     '(:file "fail.el" :type replace)
     "failed"
     "File not found")
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (let ((content (buffer-string)))
        (should (string-match-p "Edit failed" content))
        (should (string-match-p "error=\"File not found\"" content))))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-test-log-edit-apply-nil-level ()
  "Test edit apply logging does nothing when level is nil."
  (let ((ogent-debug-log-level nil)
        (ogent-debug-buffer "*ogent-debug-editapply-nil*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log-edit-apply '(:file "x.el" :type replace) "ok")
    (should-not (get-buffer ogent-debug-buffer))))

;;; Log Properties Formatting

(ert-deftest ogent-debug-test-log-no-props ()
  "Test ogent-debug-log with no additional properties."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-noprops*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log 'test "Simple message")
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (let ((content (buffer-string)))
        (should (string-match-p "Simple message" content))
        ;; Should not have pipe separator when no props
        (should-not (string-match-p "|" content))))
    (kill-buffer ogent-debug-buffer)))

;;; Tool History Entry At Point Tests

(ert-deftest ogent-debug-test-entry-at-point-found ()
  "Test ogent-tool-history--entry-at-point finds entry by ID."
  (let ((ogent-debug-tool-history nil))
    (ogent-debug-log-tool-call
     '(:id "entry-at-pt" :name test-tool :args nil) "result" 0.1)
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      ;; Navigate to an entry heading
      (goto-char (point-min))
      (re-search-forward "^## \\[" nil t)
      (let ((entry (ogent-tool-history--entry-at-point)))
        (should entry)
        (should (equal (plist-get entry :id) "entry-at-pt")))
      (kill-buffer))))

(ert-deftest ogent-debug-test-entry-at-point-nil-outside ()
  "Test ogent-tool-history--entry-at-point returns nil outside entries."
  (let ((ogent-debug-tool-history nil))
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      (goto-char (point-min))
      ;; At the header line, no entry
      (should-not (ogent-tool-history--entry-at-point))
      (kill-buffer))))

;;; Tool History Replay At Point Tests

(ert-deftest ogent-debug-test-replay-at-point-no-entry ()
  "Test replay-at-point errors when no entry at point."
  (let ((ogent-debug-tool-history nil))
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      (goto-char (point-min))
      (should-error (ogent-tool-history-replay-at-point) :type 'user-error)
      (kill-buffer))))

;;; Tool History Revert Function

(ert-deftest ogent-debug-test-tool-history-revert ()
  "Test that revert-buffer-function is set in tool history mode."
  (let ((ogent-debug-tool-history nil))
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      (should (eq revert-buffer-function #'ogent-tool-history--revert))
      (kill-buffer))))

;;; History Buffer Long Args/Result Truncation

(ert-deftest ogent-debug-test-history-buffer-truncates-long-args ()
  "Test history buffer truncates long argument strings."
  (let ((ogent-debug-tool-history nil))
    (ogent-debug-log-tool-call
     (list :id "long-args"
           :name 'verbose-tool
           :args (list :data (make-string 500 ?x)))
     "result"
     0.1)
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      (goto-char (point-min))
      ;; Should contain truncation marker
      (should (search-forward "..." nil t))
      (kill-buffer))))

(ert-deftest ogent-debug-test-history-buffer-truncates-long-result ()
  "Test history buffer truncates long result strings."
  (let ((ogent-debug-tool-history nil))
    (ogent-debug-log-tool-call
     '(:id "long-result" :name result-tool :args nil)
     (make-string 300 ?y)
     0.1)
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      (goto-char (point-min))
      ;; Should contain truncation marker
      (should (search-forward "..." nil t))
      (kill-buffer))))

;;; Debug Mode Round-trip

(ert-deftest ogent-debug-test-mode-round-trip ()
  "Test enabling and disabling ogent-debug-mode restores state."
  (let ((ogent-debug-mode nil)
        (ogent-debug-log-level nil)
        (ogent-debug-enabled nil)
        (gptel-pre-request-hook nil)
        (gptel-post-response-hook nil))
    ;; Enable
    (ogent-debug-mode 1)
    (should ogent-debug-mode)
    (should ogent-debug-log-level)
    (should ogent-debug-enabled)
    ;; Disable
    (ogent-debug-mode -1)
    (should-not ogent-debug-mode)
    (should-not ogent-debug-enabled)))

;;; Export JSON Truncates Long Results

(ert-deftest ogent-debug-test-export-json-truncates-result ()
  "Test JSON export truncates results longer than 1000 chars."
  (let ((ogent-debug-tool-history nil)
        (export-file (make-temp-file "ogent-export-trunc-" nil ".json")))
    (unwind-protect
        (progn
          (ogent-debug-log-tool-call
           '(:id "trunc-1" :name long-result :args nil)
           (make-string 2000 ?z)
           0.5)
          (ogent-debug-export-tool-history-json export-file)
          (with-temp-buffer
            (insert-file-contents export-file)
            (let* ((json-object-type 'plist)
                   (json-array-type 'list)
                   (json-key-type 'keyword)
                   (data (json-read-from-string (buffer-string)))
                   (calls (plist-get data :calls))
                   (result (plist-get (car calls) :result)))
              ;; Result should be truncated to 1000 chars
              (should (<= (length result) 1000)))))
      (delete-file export-file))))

;;; Export Text With Long Args/Result

(ert-deftest ogent-debug-test-export-text-truncates-long-args ()
  "Test text export truncates long argument strings."
  (let ((ogent-debug-tool-history nil)
        (export-file (make-temp-file "ogent-export-long-" nil ".txt")))
    (unwind-protect
        (progn
          (ogent-debug-log-tool-call
           (list :id "long-txt" :name 'verbose
                 :args (list :data (make-string 1000 ?q)))
           "short result"
           0.1)
          (ogent-debug-export-tool-history-text export-file)
          (with-temp-buffer
            (insert-file-contents export-file)
            (let ((content (buffer-string)))
              ;; Should contain truncation
              (should (string-match-p "\\.\\.\\." content)))))
      (delete-file export-file))))

;;; ================================================================
;;; NEW COVERAGE TESTS - Phase 2 (targeting 80%+ coverage)
;;; ================================================================

;;; --- Debug Log Properties Formatting ---

(ert-deftest ogent-debug-test-log-multiple-props ()
  "Test ogent-debug-log formats multiple properties correctly."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-multiprops*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log 'test "Multi-prop message"
                     :key1 "val1" :key2 42 :key3 t)
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (let ((content (buffer-string)))
        (should (string-match-p "key1=" content))
        (should (string-match-p "key2=" content))
        (should (string-match-p "key3=" content))
        (should (string-match-p "|" content))))
    (kill-buffer ogent-debug-buffer)))

;;; --- Debug Macro Compile-away Behavior ---

(ert-deftest ogent-debug-test-debug-macro-nil-when-disabled ()
  "Test ogent-debug macro expands to nil when debug is disabled."
  (let ((ogent-debug-enabled nil))
    ;; The macro should expand to nil when disabled
    (should-not (macroexpand '(ogent-debug "test %s" "arg")))))

;;; --- Context Logging Tests ---

(ert-deftest ogent-debug-test-log-context-with-flag-and-level ()
  "Test context logging works when both flag and level are set."
  (let ((ogent-debug-log-level 'debug)
        (ogent-debug-log-context t)
        (ogent-debug-buffer "*ogent-debug-ctx-test*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log-context "building context" :files 3 :tokens 1500)
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (let ((content (buffer-string)))
        (should (string-match-p "CONTEXT" content))
        (should (string-match-p "building context" content))))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-test-log-context-nil-level ()
  "Test context logging does nothing when level is nil."
  (let ((ogent-debug-log-level nil)
        (ogent-debug-log-context t)
        (ogent-debug-buffer "*ogent-debug-ctx-nil*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log-context "should not log")
    (should-not (get-buffer ogent-debug-buffer))))

;;; --- Validation Logging Tests ---

(ert-deftest ogent-debug-test-log-validation-nil-details ()
  "Test validation logging with nil details."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-val-nil*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log-validation "path" "ok")
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "VALIDATION" (buffer-string)))
      (should (string-match-p "path validation: ok" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

(ert-deftest ogent-debug-test-log-validation-nil-level ()
  "Test validation logging does nothing when level is nil."
  (let ((ogent-debug-log-level nil)
        (ogent-debug-buffer "*ogent-debug-val-nolevel*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log-validation "syntax" "failed")
    (should-not (get-buffer ogent-debug-buffer))))

;;; --- Tool History Max Behavior ---

(ert-deftest ogent-debug-test-history-max-exact ()
  "Test that history at exact max size does not trim."
  (let ((ogent-debug-tool-history nil)
        (ogent-debug-tool-history-max 5))
    (dotimes (i 5)
      (ogent-debug-log-tool-call
       (list :id (format "exact-%d" i) :name 'tool :args nil)
       "result" 0.1))
    (should (= 5 (length ogent-debug-tool-history)))))

(ert-deftest ogent-debug-test-history-max-one ()
  "Test that max of 1 keeps only the latest entry."
  (let ((ogent-debug-tool-history nil)
        (ogent-debug-tool-history-max 1))
    (ogent-debug-log-tool-call
     '(:id "first" :name tool1 :args nil) "r1" 0.1)
    (ogent-debug-log-tool-call
     '(:id "second" :name tool2 :args nil) "r2" 0.2)
    (should (= 1 (length ogent-debug-tool-history)))
    (should (equal "second" (plist-get (car ogent-debug-tool-history) :id)))))

;;; --- Debug Mode gptel Integration ---

(ert-deftest ogent-debug-test-mode-sets-gptel-log-level ()
  "Test that enabling debug mode sets gptel-log-level."
  (let ((ogent-debug-mode nil)
        (ogent-debug-log-level nil)
        (ogent-debug-enabled nil)
        (gptel-log-level nil)
        (gptel-pre-request-hook nil)
        (gptel-post-response-hook nil))
    (ogent-debug-mode 1)
    (should (eq gptel-log-level ogent-debug-log-level))
    (ogent-debug-mode -1)
    (should-not gptel-log-level)))

(ert-deftest ogent-debug-test-mode-preserves-existing-log-level ()
  "Test that enabling debug mode preserves existing log level if set."
  (let ((ogent-debug-mode nil)
        (ogent-debug-log-level 'debug)
        (ogent-debug-enabled nil)
        (gptel-log-level nil)
        (gptel-pre-request-hook nil)
        (gptel-post-response-hook nil))
    (ogent-debug-mode 1)
    ;; Should use the existing debug level
    (should (eq 'debug ogent-debug-log-level))
    (ogent-debug-mode -1)))

;;; --- Debug Log Insert Tests ---

(ert-deftest ogent-debug-test-insert-log-multiple ()
  "Test inserting multiple log lines preserves order."
  (let ((ogent-debug-buffer "*ogent-debug-multi-insert*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug--insert-log "AAA first")
    (ogent-debug--insert-log "BBB second")
    (ogent-debug--insert-log "CCC third")
    (with-current-buffer ogent-debug-buffer
      (let ((content (buffer-string)))
        (should (< (string-match "AAA" content)
                   (string-match "BBB" content)))
        (should (< (string-match "BBB" content)
                   (string-match "CCC" content)))))
    (kill-buffer ogent-debug-buffer)))

;;; --- Debug Log Function with Multiple Args ---

(ert-deftest ogent-debug-test-debug-log-multiple-format-args ()
  "Test ogent-debug--log with multiple format arguments."
  (let ((ogent-debug-buffer "*ogent-debug-multi-args*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug--log 'my-func "x=%d y=%s z=%S" 42 "hello" '(a b))
    (with-current-buffer ogent-debug-buffer
      (let ((content (buffer-string)))
        (should (string-match-p "x=42" content))
        (should (string-match-p "y=hello" content))
        (should (string-match-p "z=(a b)" content))))
    (kill-buffer ogent-debug-buffer)))

;;; --- Tool History Buffer With Nil Result ---

(ert-deftest ogent-debug-test-history-buffer-nil-result ()
  "Test history buffer handles entry with nil result."
  (let ((ogent-debug-tool-history nil))
    (ogent-debug-log-tool-call
     '(:id "nil-res" :name some-tool :args nil)
     nil
     0.1)
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      (goto-char (point-min))
      (should (search-forward "SUCCESS" nil t))
      ;; Should not have a Result: line since result is nil
      (goto-char (point-min))
      (should-not (search-forward "Result:" nil t))
      (kill-buffer))))

(ert-deftest ogent-debug-test-history-buffer-non-string-result ()
  "Test history buffer formats non-string results."
  (let ((ogent-debug-tool-history nil))
    (ogent-debug-log-tool-call
     '(:id "plist-res" :name some-tool :args nil)
     '(:key "value" :num 42)
     0.1)
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      (goto-char (point-min))
      (should (search-forward "Result:" nil t))
      (kill-buffer))))

;;; --- Export Text Long Result ---

(ert-deftest ogent-debug-test-export-text-truncates-long-result ()
  "Test text export truncates long result strings."
  (let ((ogent-debug-tool-history nil)
        (export-file (make-temp-file "ogent-export-long-res-" nil ".txt")))
    (unwind-protect
        (progn
          (ogent-debug-log-tool-call
           '(:id "long-r" :name tool :args nil)
           (make-string 1000 ?r)
           0.1)
          (ogent-debug-export-tool-history-text export-file)
          (with-temp-buffer
            (insert-file-contents export-file)
            (should (string-match-p "\\.\\.\\." (buffer-string)))))
      (delete-file export-file))))

;;; --- Export Text With Nil Args ---

(ert-deftest ogent-debug-test-export-text-nil-args ()
  "Test text export handles entry with nil args."
  (let ((ogent-debug-tool-history nil)
        (export-file (make-temp-file "ogent-export-nilargs-" nil ".txt")))
    (unwind-protect
        (progn
          (ogent-debug-log-tool-call
           '(:id "nil-a" :name tool :args nil)
           "ok"
           0.1)
          (ogent-debug-export-tool-history-text export-file)
          (with-temp-buffer
            (insert-file-contents export-file)
            (let ((content (buffer-string)))
              ;; Should not have Args: section
              (should (string-match-p "SUCCESS" content))
              (should-not (string-match-p "Args:" content)))))
      (delete-file export-file))))

;;; --- Post Response with Elapsed Calculation ---

(ert-deftest ogent-debug-test-log-post-response-elapsed ()
  "Test post response calculates elapsed time correctly."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-elapsed*")
        (ogent-debug--request-start-time
         (time-subtract (current-time) (seconds-to-time 2))))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug--log-post-response 1 101)
    (with-current-buffer ogent-debug-buffer
      (let ((content (buffer-string)))
        ;; Should show ~2 seconds elapsed
        (should (string-match-p "elapsed=" content))
        (should (string-match-p "length=100" content))))
    (kill-buffer ogent-debug-buffer)))

;;; --- Edit Parse Logging Edge Cases ---

(ert-deftest ogent-debug-test-log-edit-parse-empty-result-list ()
  "Test edit parse logging with empty result list."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-empty-edits*"))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    (ogent-debug-log-edit-parse "source text" nil)
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "edits=0" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

;;; --- Pre-Request Logging Without Model/Backend ---

(ert-deftest ogent-debug-test-log-pre-request-no-model ()
  "Test pre-request logging when gptel-model is unbound."
  (let ((ogent-debug-log-level 'info)
        (ogent-debug-buffer "*ogent-debug-nomodel*")
        (ogent-debug--request-start-time nil))
    (when (get-buffer ogent-debug-buffer)
      (kill-buffer ogent-debug-buffer))
    ;; Make sure gptel-model and gptel-backend are nil/unbound
    (let ((gptel-model nil)
          (gptel-backend nil))
      (cl-letf (((symbol-function 'gptel-backend-name)
                 (lambda (_b) nil)))
        (ogent-debug--log-pre-request)))
    (should ogent-debug--request-start-time)
    (should (get-buffer ogent-debug-buffer))
    (with-current-buffer ogent-debug-buffer
      (should (string-match-p "REQUEST STARTED" (buffer-string))))
    (kill-buffer ogent-debug-buffer)))

;;; --- History Buffer Args Rendering ---

(ert-deftest ogent-debug-test-history-buffer-short-args ()
  "Test history buffer renders short args without truncation."
  (let ((ogent-debug-tool-history nil))
    (ogent-debug-log-tool-call
     '(:id "short-a" :name test :args (:x 1))
     "ok"
     0.1)
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      (goto-char (point-min))
      (should (search-forward "Args:" nil t))
      ;; Short args should NOT have truncation
      (goto-char (point-min))
      ;; The full (:x 1) should be present
      (should (search-forward ":x 1" nil t))
      (kill-buffer))))

;;; --- Tool History Entry Ordering Verification ---

(ert-deftest ogent-debug-test-history-buffer-reverse-display ()
  "Test history buffer displays entries in chronological order."
  (let ((ogent-debug-tool-history nil))
    (ogent-debug-log-tool-call
     '(:id "older" :name tool-old :args nil) "r1" 0.1)
    (ogent-debug-log-tool-call
     '(:id "newer" :name tool-new :args nil) "r2" 0.1)
    (ogent-debug-tool-history-buffer)
    (with-current-buffer "*ogent-tool-history*"
      (goto-char (point-min))
      ;; Entries are displayed in chronological order (reversed from internal list)
      ;; So "older" should appear before "newer"
      (let ((old-pos (search-forward "tool-old" nil t))
            (new-pos (progn (goto-char (point-min))
                            (search-forward "tool-new" nil t))))
        (should old-pos)
        (should new-pos)
        (should (< old-pos new-pos)))
      (kill-buffer))))

(provide 'ogent-debug-tests)

;;; ogent-debug-tests.el ends here
