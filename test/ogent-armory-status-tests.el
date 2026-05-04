;;; ogent-armory-status-tests.el --- Tests for Armory status -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the operational Armory graph buffer.

;;; Code:

(require 'ogent-test-helper)
(require 'transient)
(require 'ogent-armory)
(require 'ogent-armory-status)
(require 'ogent-ui-armory)

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

(ert-deftest ogent-armory-status-action-keys-are-discoverable ()
  "The Armory status buffer exposes edit, run, menu, and help actions."
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "m"))
              #'ogent-armory-status-dispatch))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "?"))
              #'ogent-armory-status-help))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "e"))
              #'ogent-armory-status-edit))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "E"))
              #'ogent-armory-status-edit-body))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "P"))
              #'ogent-armory-status-open-agent-profile))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "J"))
              #'ogent-armory-status-open-agent-jobs))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "C"))
              #'ogent-armory-status-create-job))
  (ogent-armory-status-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (let ((buffer (ogent-armory-status dir)))
      (unwind-protect
          (with-current-buffer buffer
            (let ((header (ogent-armory-status--header-line)))
              (dolist (key '("m menu" "? help" "e edit" "E body"
                             "P profile" "J jobs" "C job" "R run"))
                (should (string-match-p (regexp-quote key) header)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-armory-status-transient-renders ()
  "The Armory status transient menu sets up without display errors."
  (unwind-protect
      (progn
        (transient-setup 'ogent-armory-status-dispatch)
        (should (get 'ogent-armory-status-dispatch 'transient--prefix)))
    (when transient-current-prefix
      (transient-quit-one))))

(ert-deftest ogent-armory-status-help-documents-dwim-actions ()
  "The Armory status help buffer documents node-specific workflows."
  (save-window-excursion
    (ogent-armory-status-help)
    (with-current-buffer "*Ogent Armory Status Help*"
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Armory Status" text))
        (should (string-match-p "Agent" text))
        (should (string-match-p "Job" text))
        (should (string-match-p "R runs" text))
        (should (string-match-p "e edits" text))
        (should (string-match-p "m opens this Transient menu" text))))))

(defun ogent-armory-status-test--seed-agent-and-job (dir)
  "Create a Armory with one agent and one job under DIR."
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
   "Review architecture notes."))

(ert-deftest ogent-armory-status-edits-agent-and-job-properties ()
  "Status edit changes real Org property drawers for agents and jobs."
  (ogent-armory-status-test-with-temp-dir dir
    (ogent-armory-status-test--seed-agent-and-job dir)
    (let ((buffer (ogent-armory-status dir)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "CTO")
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _) "OGENT_ROLE"))
                        ((symbol-function 'read-string)
                         (lambda (&rest _) "Systems")))
                (ogent-armory-status-edit))
              (should (equal (plist-get (ogent-armory-read-agent dir "cto")
                                        :role)
                             "Systems"))
              (ogent-armory-status-refresh)
              (goto-char (point-min))
              (search-forward "Weekly Review")
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _) "OGENT_ENABLED"))
                        ((symbol-function 'read-string)
                         (lambda (&rest _) "nil")))
                (ogent-armory-status-edit))
              (should-not (plist-get (ogent-armory-read-job dir
                                                              "cto"
                                                              "weekly-review")
                                      :enabled))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-armory-status-runs-job-at-point ()
  "Running from a job line dispatches the real Armory job identity."
  (ogent-armory-status-test-with-temp-dir dir
    (ogent-armory-status-test--seed-agent-and-job dir)
    (let ((buffer (ogent-armory-status dir))
          called)
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (cl-letf (((symbol-function 'ogent-armory-run-job)
                       (lambda (root agent job-id)
                         (setq called (list root agent job-id)))))
              (ogent-armory-status-run))
            (should (equal called (list (file-truename dir)
                                        "cto"
                                        "weekly-review"))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-armory-status-opens-profile-jobs-and-bodies ()
  "Status node actions jump to the profile, jobs list, and Org body."
  (ogent-armory-status-test-with-temp-dir dir
    (ogent-armory-status-test--seed-agent-and-job dir)
    (let ((buffer (ogent-armory-status dir))
          profile-buffer
          jobs-buffer
          body-file)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "CTO")
              (setq profile-buffer (ogent-armory-status-open-agent-profile)))
            (with-current-buffer profile-buffer
              (should (eq major-mode 'ogent-armory-agent-mode))
              (should (equal ogent-armory-agent--slug "cto")))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Weekly Review")
              (setq jobs-buffer (ogent-armory-status-open-agent-jobs)))
            (with-current-buffer jobs-buffer
              (should (eq major-mode 'ogent-armory-jobs-mode))
              (should (equal (plist-get (tabulated-list-get-id) :job-id)
                             "weekly-review")))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Weekly Review")
              (ogent-armory-status-edit-body)
              (setq body-file buffer-file-name)
              (should (looking-at-p "Review architecture notes")))
            (should (equal (file-truename body-file)
                           (file-truename
                            (ogent-armory-job-file dir
                                                    "cto"
                                                    "weekly-review")))))
        (dolist (buf (list buffer profile-buffer jobs-buffer))
          (when (buffer-live-p buf)
            (kill-buffer buf)))
        (when (get-file-buffer (ogent-armory-job-file dir "cto" "weekly-review"))
          (kill-buffer (get-file-buffer
                        (ogent-armory-job-file dir "cto" "weekly-review"))))))))

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

(ert-deftest ogent-armory-status-evil-overrides-dispatch-keymap ()
  "Armory status dispatch keys remain active in Evil normal state."
  (let ((ogent-armory-status-mode-hook nil)
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
      (ogent-armory-status--setup-evil))
    (should (member (cons 'ogent-armory-status-mode 'normal) states))
    (should (member (cons ogent-armory-status-mode-map 'all) maps))
    (should (memq #'evil-normalize-keymaps ogent-armory-status-mode-hook))))

(provide 'ogent-armory-status-tests)

;;; ogent-armory-status-tests.el ends here
