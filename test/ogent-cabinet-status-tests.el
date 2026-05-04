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

(ert-deftest ogent-cabinet-status-enter-variants-visit-records ()
  "Main Enter, GUI Return, and keypad Enter all visit records."
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "RET"))
              #'ogent-cabinet-status-visit))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "<return>"))
              #'ogent-cabinet-status-visit))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "<kp-enter>"))
              #'ogent-cabinet-status-visit)))

(ert-deftest ogent-cabinet-status-visit-opens-cabinet-node-file ()
  "Visiting the rendered cabinet node opens its Org source file."
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Zorp" :kind "root" :create-editor nil)
    (let* ((index (ogent-cabinet-index-file dir))
           (buffer (ogent-cabinet-status dir))
           visited-file)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Zorp")
              (call-interactively #'ogent-cabinet-status-visit)
              (setq visited-file buffer-file-name))
            (should (equal (file-truename visited-file)
                           (file-truename index))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (get-file-buffer index)
          (kill-buffer (get-file-buffer index)))))))

(ert-deftest ogent-cabinet-status-graph-includes-sessions-apps-issues-and-hook ()
  "The graph projection includes the full Cabinet relationship vocabulary."
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Zorp" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (ogent-cabinet-write-job
     dir "cto"
     '(:id "weekly-review" :name "Weekly Review" :enabled t)
     "Review notes.")
    (let ((session-dir (ogent-cabinet-sessions-directory dir "cto"))
          (app-file (expand-file-name "apps/dashboard/index.html" dir))
          (issue-file (expand-file-name "issue-link.org" dir))
          (gastown-dir (expand-file-name ".gastown" dir)))
      (make-directory session-dir t)
      (make-directory (file-name-directory app-file) t)
      (make-directory gastown-dir t)
      (ogent-cabinet--write-file app-file "<!doctype html>")
      (ogent-cabinet--write-file
       (expand-file-name "failed.org" session-dir)
       (concat "#+title: Failed\n\n* FAILED Failed\n"
               (ogent-cabinet--format-properties
                '(("OGENT_SESSION" . t)
                  ("OGENT_AGENT" . "cto")
                  ("OGENT_JOB_ID" . "weekly-review")
                  ("OGENT_EXIT_STATUS" . 1)
                  ("OGENT_APP_PATHS" . "apps/dashboard")))
               "\n"))
      (ogent-cabinet--write-file
       issue-file
       (concat "#+title: Issue Link\n\n* Issue Link\n"
               (ogent-cabinet--format-properties
                '(("OGENT_ISSUE_ID" . "ogent-123")
                  ("OGENT_ASSIGNED_WORKER" . "cto")))
               "\n"))
      (let* ((graph (ogent-cabinet-build-graph dir))
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

(ert-deftest ogent-cabinet-status-evil-overrides-dispatch-keymap ()
  "Cabinet status dispatch keys remain active in Evil normal state."
  (let ((ogent-cabinet-status-mode-hook nil)
        states
        maps)
    (cl-letf (((symbol-function 'evil-set-initial-state)
               (lambda (mode state)
                 (push (cons mode state) states)))
              ((symbol-function 'evil-make-overriding-map)
               (lambda (map state)
                 (push (cons map state) maps)))
              ((symbol-function 'evil-normalize-keymaps)
               (lambda (&rest _) nil)))
      (ogent-cabinet-status--setup-evil))
    (should (member (cons 'ogent-cabinet-status-mode 'normal) states))
    (should (member (cons ogent-cabinet-status-mode-map 'all) maps))
    (should (memq #'evil-normalize-keymaps ogent-cabinet-status-mode-hook))))

(provide 'ogent-cabinet-status-tests)

;;; ogent-cabinet-status-tests.el ends here
