;;; ogent-tool-approval-tests.el --- Tests for ogent-tool-approval -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for tool approval workflow.

;;; Code:

(require 'ert)
(require 'ogent-tool-approval)

(ert-deftest ogent-tool-approval-required-p/without-confirm-flag ()
  "Tools without :confirm flag don't require approval."
  (let ((spec '(:name read-file :function ogent-tool--read-file)))
    (should-not (ogent-tool-approval-required-p spec))))

(ert-deftest ogent-tool-approval-required-p/with-confirm-nil ()
  "Tools with :confirm nil don't require approval."
  (let ((spec '(:name read-file :function ogent-tool--read-file :confirm nil)))
    (should-not (ogent-tool-approval-required-p spec))))

(ert-deftest ogent-tool-approval-required-p/with-confirm-t ()
  "Tools with :confirm t require approval."
  (let ((spec '(:name bash :function ogent-tool--bash :confirm t)))
    (should (ogent-tool-approval-required-p spec))))

(ert-deftest ogent-tool-approval-request/no-confirm-executes-immediately ()
  "Tools without :confirm execute callback immediately with t."
  (let ((spec '(:name read-file :function ogent-tool--read-file))
        (callback-called nil)
        (callback-arg nil))
    (ogent-tool-approval-request
     spec
     '(:file-path "/tmp/test.txt")
     (lambda (approved)
       (setq callback-called t
             callback-arg approved)))
    (should callback-called)
    (should (eq callback-arg t))))

(ert-deftest ogent-tool-approval-request/session-cache-approval ()
  "Approved tools in session cache execute without prompting."
  (let ((spec '(:name bash :function ogent-tool--bash :confirm t))
        (callback-called nil)
        (callback-arg nil))
    ;; Clear cache first
    (clrhash ogent-tool-approval--session-approved)
    ;; Manually add to cache
    (puthash 'bash t ogent-tool-approval--session-approved)
    ;; Request should use cache
    (ogent-tool-approval-request
     spec
     '(:command "echo test")
     (lambda (approved)
       (setq callback-called t
             callback-arg approved)))
    (should callback-called)
    (should (eq callback-arg t))))

(ert-deftest ogent-tool-approval-request/session-cache-rejection ()
  "Rejected tools in session cache don't execute."
  (let ((spec '(:name bash :function ogent-tool--bash :confirm t))
        (callback-called nil)
        (callback-arg nil))
    ;; Clear cache first
    (clrhash ogent-tool-approval--session-approved)
    ;; Manually add rejection to cache
    (puthash 'bash 'rejected ogent-tool-approval--session-approved)
    ;; Request should use cache
    (ogent-tool-approval-request
     spec
     '(:command "rm -rf /")
     (lambda (approved)
       (setq callback-called t
             callback-arg approved)))
    (should callback-called)
    (should-not callback-arg)))

(ert-deftest ogent-tool-approval-reset/clears-cache ()
  "Reset clears all session approvals."
  (clrhash ogent-tool-approval--session-approved)
  (puthash 'bash t ogent-tool-approval--session-approved)
  (puthash 'write-file t ogent-tool-approval--session-approved)
  (should (= (hash-table-count ogent-tool-approval--session-approved) 2))
  (ogent-tool-approval-reset)
  (should (= (hash-table-count ogent-tool-approval--session-approved) 0)))

(ert-deftest ogent-tool-approval--format-args/empty-args ()
  "Format empty args list."
  (should (string-match-p "no arguments"
                          (ogent-tool-approval--format-args nil))))

(ert-deftest ogent-tool-approval--format-args/single-arg ()
  "Format single argument."
  (let ((result (ogent-tool-approval--format-args '(:file-path "/tmp/test.txt"))))
    (should (string-match-p "file-path:" result))
    (should (string-match-p "/tmp/test.txt" result))))

(ert-deftest ogent-tool-approval--format-args/multiple-args ()
  "Format multiple arguments."
  (let ((result (ogent-tool-approval--format-args
                 '(:command "echo test" :working-directory "/tmp"))))
    (should (string-match-p "command:" result))
    (should (string-match-p "echo test" result))
    (should (string-match-p "working-directory:" result))
    (should (string-match-p "/tmp" result))))

(ert-deftest ogent-tool-approval--format-args/long-value-truncates ()
  "Long argument values are truncated."
  (let* ((long-string (make-string 300 ?x))
         (result (ogent-tool-approval--format-args
                  (list :content long-string))))
    (should (string-match-p "\\.\\.\\." result))
    (should (< (length result) 250))))

(provide 'ogent-tool-approval-tests)

;;; ogent-tool-approval-tests.el ends here
