;;; ogent-armory-status-tests.el --- Tests for Armory status -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the operational Armory graph buffer.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-armory)
(require 'ogent-armory-status)

(defmacro ogent-armory-status-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-armory-status-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(ert-deftest ogent-armory-status-renders-armory-graph-and-bridges ()
  "The Armory status buffer renders graph records and operational bridges."
  (ogent-armory-status-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto"
       :name "CTO"
       :role "Architecture"
       :provider "codex-cli"
       :active t)
     "Maintain architecture.")
    (ogent-armory-write-job
     dir "cto"
     '(:id "weekly-review"
       :name "Weekly Review"
       :cron "0 9 * * 1"
       :enabled t)
     "Review architecture notes.")
    (let* ((nested (expand-file-name "engineering" dir))
           (buffer nil))
      (make-directory nested t)
      (setq buffer (ogent-armory-status nested))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-status-mode))
            (should (equal ogent-armory-status--root
                           (file-truename dir)))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "Armory Graph" text))
              (should (string-match-p "Company" text))
              (should (string-match-p "Agents" text))
              (should (string-match-p "CTO" text))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "Operational Bridges" text))
              (should (string-match-p "Ogent Issues" text))
              (should (string-match-p "Gas Town" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-armory-status-enter-variants-visit-records ()
  "Main Enter, GUI Return, and keypad Enter all visit records."
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "RET"))
              #'ogent-armory-status-visit))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "<return>"))
              #'ogent-armory-status-visit))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "<kp-enter>"))
              #'ogent-armory-status-visit)))

(ert-deftest ogent-armory-status-visit-opens-armory-node-file ()
  "Visiting the rendered armory node opens its Org source file."
  (ogent-armory-status-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Zorp" :kind "root" :create-editor nil)
    (let* ((index (ogent-armory-index-file dir))
           (buffer (ogent-armory-status dir))
           visited-file)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Zorp")
              (call-interactively #'ogent-armory-status-visit)
              (setq visited-file buffer-file-name))
            (should (equal (file-truename visited-file)
                           (file-truename index))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (get-file-buffer index)
          (kill-buffer (get-file-buffer index)))))))

(provide 'ogent-armory-status-tests)

;;; ogent-armory-status-tests.el ends here
