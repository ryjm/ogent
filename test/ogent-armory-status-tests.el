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

(ert-deftest ogent-armory-status-graph-includes-sessions-apps-issues-and-hook ()
  "The graph projection includes the full Armory relationship vocabulary."
  (ogent-armory-status-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Zorp" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (ogent-armory-write-job
     dir "cto"
     '(:id "weekly-review" :name "Weekly Review" :enabled t)
     "Review notes.")
    (let ((session-dir (ogent-armory-sessions-directory dir "cto"))
          (app-file (expand-file-name "apps/dashboard/index.html" dir))
          (issue-file (expand-file-name "issue-link.org" dir))
          (gastown-dir (expand-file-name ".gastown" dir)))
      (make-directory session-dir t)
      (make-directory (file-name-directory app-file) t)
      (make-directory gastown-dir t)
      (ogent-armory--write-file app-file "<!doctype html>")
      (ogent-armory--write-file
       (expand-file-name "failed.org" session-dir)
       (concat "#+title: Failed\n\n* FAILED Failed\n"
               (ogent-armory--format-properties
                '(("OGENT_SESSION" . t)
                  ("OGENT_AGENT" . "cto")
                  ("OGENT_JOB_ID" . "weekly-review")
                  ("OGENT_EXIT_STATUS" . 1)
                  ("OGENT_APP_PATHS" . "apps/dashboard")))
               "\n"))
      (ogent-armory--write-file
       issue-file
       (concat "#+title: Issue Link\n\n* Issue Link\n"
               (ogent-armory--format-properties
                '(("OGENT_ISSUE_ID" . "ogent-123")
                  ("OGENT_ASSIGNED_WORKER" . "cto")))
               "\n"))
      (let* ((graph (ogent-armory-build-graph dir))
             (nodes (plist-get graph :nodes))
             (edges (plist-get graph :edges)))
        (dolist (kind '(session app issue gastown-hook))
          (should (seq-find (lambda (node)
                              (eq (plist-get node :kind) kind))
                            nodes)))
        (dolist (edge-kind '(produced failed-from linked-issue assigned-worker))
          (should (seq-find (lambda (edge)
                              (eq (plist-get edge :kind) edge-kind))
                            edges)))))))

(provide 'ogent-armory-status-tests)

;;; ogent-armory-status-tests.el ends here
