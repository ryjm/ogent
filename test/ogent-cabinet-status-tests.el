;;; ogent-cabinet-status-tests.el --- Tests for Cabinet status -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the operational Cabinet graph buffer.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-cabinet)
(require 'ogent-cabinet-status)

(defmacro ogent-cabinet-status-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-cabinet-status-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(ert-deftest ogent-cabinet-status-renders-cabinet-graph-and-bridges ()
  "The Cabinet status buffer renders graph records and operational bridges."
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto"
       :name "CTO"
       :role "Architecture"
       :provider "codex-cli"
       :active t)
     "Maintain architecture.")
    (ogent-cabinet-write-job
     dir "cto"
     '(:id "weekly-review"
       :name "Weekly Review"
       :cron "0 9 * * 1"
       :enabled t)
     "Review architecture notes.")
    (let* ((nested (expand-file-name "engineering" dir))
           (buffer nil))
      (make-directory nested t)
      (setq buffer (ogent-cabinet-status nested))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-status-mode))
            (should (equal ogent-cabinet-status--root
                           (file-truename dir)))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "Cabinet Graph" text))
              (should (string-match-p "Company" text))
              (should (string-match-p "Agents" text))
              (should (string-match-p "CTO" text))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "Operational Bridges" text))
              (should (string-match-p "Ogent Issues" text))
              (should (string-match-p "Gas Town" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(provide 'ogent-cabinet-status-tests)

;;; ogent-cabinet-status-tests.el ends here
