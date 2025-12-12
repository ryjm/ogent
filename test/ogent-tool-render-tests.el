;;; ogent-tool-render-tests.el --- Tests for ogent-tool-render -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for tool rendering functionality.

;;; Code:

(require 'ert)
(require 'ogent-tool-render)
(require 'ogent-test-helper)

;;; Test Data Structure

(ert-deftest ogent-tool-render-test-create-struct ()
  "Test creating a tool-call struct."
  (let ((call (ogent-tool-call-create
               :id "test-123"
               :name "read-file"
               :args '(:file_path "/tmp/test.txt" :limit 100))))
    (should (ogent-tool-call-p call))
    (should (string= (ogent-tool-call-id call) "test-123"))
    (should (string= (ogent-tool-call-name call) "read-file"))
    (should (equal (ogent-tool-call-args call)
                   '(:file_path "/tmp/test.txt" :limit 100)))
    (should (eq (ogent-tool-call-status call) 'pending))
    (should (null (ogent-tool-call-result call)))
    (should (null (ogent-tool-call-error call)))))

;;; Test Rendering

(ert-deftest ogent-tool-render-test-render-pending ()
  "Test rendering a pending tool call."
  (with-temp-buffer
    (org-mode)
    (let ((call (ogent-tool-call-create
                 :id "test-456"
                 :name "glob"
                 :args '(:pattern "**/*.el"))))
      (ogent-tool-render-call call t)
      
      ;; Check drawer was created
      (goto-char (point-min))
      (should (search-forward ":TOOL_CALL_test-456:" nil t))
      (should (search-forward "Status: ⏳ pending" nil t))
      (should (search-forward "Tool: glob" nil t))
      (should (search-forward "Arguments:" nil t))
      (should (search-forward "- pattern: **/*.el" nil t))
      (should (search-forward ":END:" nil t))
      
      ;; Check markers were set
      (should (ogent-tool-call-start-marker call))
      (should (ogent-tool-call-end-marker call)))))

(ert-deftest ogent-tool-render-test-render-with-multiple-args ()
  "Test rendering a tool call with multiple arguments."
  (with-temp-buffer
    (org-mode)
    (let ((call (ogent-tool-call-create
                 :id "test-789"
                 :name "grep"
                 :args '(:pattern "defun"
                         :path "/tmp"
                         :glob_filter "*.el"
                         :context_lines 2))))
      (ogent-tool-render-call call t)
      
      (goto-char (point-min))
      (should (search-forward "- pattern: defun" nil t))
      (should (search-forward "- path: /tmp" nil t))
      (should (search-forward "- glob_filter: *.el" nil t))
      (should (search-forward "- context_lines: 2" nil t)))))

;;; Test Status Updates

(ert-deftest ogent-tool-render-test-update-status-running ()
  "Test updating status to running."
  (with-temp-buffer
    (org-mode)
    (let ((call (ogent-tool-call-create
                 :id "test-run"
                 :name "bash"
                 :args '(:command "ls -la"))))
      (ogent-tool-render-call call t)
      
      ;; Update to running
      (ogent-tool-render-update-status call 'running)
      
      (goto-char (point-min))
      (should (search-forward "Status: 🔄 running" nil t)))))

(ert-deftest ogent-tool-render-test-update-status-completed ()
  "Test updating status to completed."
  (with-temp-buffer
    (org-mode)
    (let ((call (ogent-tool-call-create
                 :id "test-complete"
                 :name "read-file"
                 :args '(:file_path "/tmp/test.txt"))))
      (ogent-tool-render-call call t)
      
      ;; Update to completed
      (ogent-tool-render-update-status call 'completed)
      
      (goto-char (point-min))
      (should (search-forward "Status: ✓ completed" nil t)))))

(ert-deftest ogent-tool-render-test-update-status-failed ()
  "Test updating status to failed."
  (with-temp-buffer
    (org-mode)
    (let ((call (ogent-tool-call-create
                 :id "test-fail"
                 :name "write-file"
                 :args '(:file_path "/tmp/test.txt"))))
      (ogent-tool-render-call call t)
      
      ;; Update to failed
      (ogent-tool-render-update-status call 'failed)
      
      (goto-char (point-min))
      (should (search-forward "Status: ✗ failed" nil t)))))

;;; Test Result Insertion

(ert-deftest ogent-tool-render-test-insert-result ()
  "Test inserting a result into a tool call drawer."
  (with-temp-buffer
    (org-mode)
    (let ((call (ogent-tool-call-create
                 :id "test-result"
                 :name "glob"
                 :args '(:pattern "*.el"))))
      (ogent-tool-render-call call t)
      (ogent-tool-render-update-status call 'running)
      
      ;; Insert result
      (ogent-tool-render-insert-result call "file1.el\nfile2.el\nfile3.el")
      
      (goto-char (point-min))
      (should (search-forward "Status: ✓ completed" nil t))
      (should (search-forward "Result:" nil t))
      (should (search-forward "#+begin_example" nil t))
      (should (search-forward "file1.el" nil t))
      (should (search-forward "file2.el" nil t))
      (should (search-forward "#+end_example" nil t))
      
      ;; Check result was stored
      (should (string= (ogent-tool-call-result call)
                       "file1.el\nfile2.el\nfile3.el")))))

(ert-deftest ogent-tool-render-test-insert-long-result ()
  "Test that long results are truncated."
  (with-temp-buffer
    (org-mode)
    (let ((call (ogent-tool-call-create
                 :id "test-long"
                 :name "read-file"
                 :args '(:file_path "/tmp/big.txt")))
          (long-result (make-string 3000 ?x)))
      (ogent-tool-render-call call t)
      (ogent-tool-render-update-status call 'running)
      
      ;; Insert long result
      (ogent-tool-render-insert-result call long-result)
      
      (goto-char (point-min))
      (should (search-forward "[... truncated" nil t)))))

;;; Test Error Insertion

(ert-deftest ogent-tool-render-test-insert-error ()
  "Test inserting an error into a tool call drawer."
  (with-temp-buffer
    (org-mode)
    (let ((call (ogent-tool-call-create
                 :id "test-error"
                 :name "read-file"
                 :args '(:file_path "/nonexistent.txt"))))
      (ogent-tool-render-call call t)
      (ogent-tool-render-update-status call 'running)
      
      ;; Insert error
      (ogent-tool-render-insert-error call "File not found: /nonexistent.txt")
      
      (goto-char (point-min))
      (should (search-forward "Status: ✗ failed" nil t))
      (should (search-forward "Error:" nil t))
      (should (search-forward "#+begin_example" nil t))
      (should (search-forward "File not found: /nonexistent.txt" nil t))
      (should (search-forward "#+end_example" nil t))
      
      ;; Check error was stored
      (should (string= (ogent-tool-call-error call)
                       "File not found: /nonexistent.txt"))
      (should (eq (ogent-tool-call-status call) 'failed)))))

;;; Test Navigation

(ert-deftest ogent-tool-render-test-navigation ()
  "Test navigation between tool call drawers."
  (with-temp-buffer
    (org-mode)
    ;; Insert some text before tool calls
    (insert "* Test Heading\n\n")
    (let ((call1 (ogent-tool-call-create
                  :id "nav-1"
                  :name "glob"
                  :args '(:pattern "*.el")))
          (call2 (ogent-tool-call-create
                  :id "nav-2"
                  :name "grep"
                  :args '(:pattern "test"))))
      
      ;; Insert two tool calls
      (ogent-tool-render-call call1 t)
      (insert "\n")
      (ogent-tool-render-call call2 t)
      
      ;; Test forward navigation - start before first call
      (goto-char (point-min))
      (ogent-tool-render-next-call)
      (should (looking-at ":TOOL_CALL_nav-1:"))
      
      (ogent-tool-render-next-call)
      (should (looking-at ":TOOL_CALL_nav-2:"))
      
      ;; Test backward navigation
      (ogent-tool-render-prev-call)
      (should (looking-at ":TOOL_CALL_nav-1:")))))

;;; Test Helper Functions

(ert-deftest ogent-tool-render-test-plist-to-pairs ()
  "Test plist to pairs conversion."
  (let ((pairs (ogent-tool-render--plist-to-pairs
                '(:name "test" :value 42 :flag t))))
    (should (equal pairs
                   '(("name" . "test")
                     ("value" . 42)
                     ("flag" . t))))))

(ert-deftest ogent-tool-render-test-format-value ()
  "Test value formatting for display."
  (should (string= (ogent-tool-render--format-value "short") "short"))
  (should (string= (ogent-tool-render--format-value 42) "42"))
  (should (string= (ogent-tool-render--format-value 'symbol) "symbol"))
  
  ;; Long strings should be truncated
  (let ((long-str (make-string 100 ?x)))
    (should (string-match-p "\\.\\.\\.$"
                            (ogent-tool-render--format-value long-str)))))

(ert-deftest ogent-tool-render-test-create-and-insert ()
  "Test convenience function for creating and inserting tool calls."
  (with-temp-buffer
    (org-mode)
    (let ((call (ogent-tool-render-create-and-insert
                 "read-file"
                 '(:file_path "/tmp/test.txt" :limit 50))))
      (should (ogent-tool-call-p call))
      (should (string-match-p "^read-file-[0-9]+" (ogent-tool-call-id call)))
      
      (goto-char (point-min))
      (should (search-forward "Tool: read-file" nil t))
      (should (search-forward "- file_path: /tmp/test.txt" nil t))
      (should (search-forward "- limit: 50" nil t)))))

;;; Test Status Indicator

(ert-deftest ogent-tool-render-test-status-indicators ()
  "Test status indicator mapping."
  (should (string= (ogent-tool-render--status-indicator 'pending) "⏳"))
  (should (string= (ogent-tool-render--status-indicator 'running) "🔄"))
  (should (string= (ogent-tool-render--status-indicator 'completed) "✓"))
  (should (string= (ogent-tool-render--status-indicator 'failed) "✗"))
  (should (string= (ogent-tool-render--status-indicator 'unknown) "?")))

(provide 'ogent-tool-render-tests)

;;; ogent-tool-render-tests.el ends here
