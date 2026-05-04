;;; ogent-ui-armory-tests.el --- Tests for richer Armory UI -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for Armory agent lists, profile buffers, task lanes, search, and app
;; entry points.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory)
(require 'ogent-armory-status)
(require 'ogent-ui-armory)

(defmacro ogent-ui-armory-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary Armory directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-ui-armory-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-ui-armory-test--write-session (root agent-slug name status exit-status &optional job-id)
  "Write a Armory session fixture for AGENT-SLUG under ROOT."
  (let* ((session-dir (expand-file-name
                       "sessions"
                       (ogent-armory-agent-directory root agent-slug)))
         (file (expand-file-name (concat name ".org") session-dir)))
    (make-directory session-dir t)
    (ogent-armory--write-file
     file
     (concat
      (format "#+title: %s\n\n" name)
      (format "* %s %s\n" status name)
      (ogent-armory--format-properties
       `(("OGENT_SESSION" . t)
         ("OGENT_AGENT" . ,agent-slug)
         ("OGENT_PROVIDER" . "codex")
         ("OGENT_JOB_ID" . ,(or job-id ""))
         ("OGENT_EXIT_STATUS" . ,exit-status)
         ("OGENT_WORKSPACE" . ,root)
         ("OGENT_FINISHED" . "2026-05-04T09:00:00-0700")))
      "\n** Output\n#+begin_src text\nDone.\n#+end_src\n"))
    file))

(defun ogent-ui-armory-test--seed (root)
  "Create a Armory fixture in ROOT."
  (ogent-armory-scaffold root "Zorp" :kind "root" :create-editor nil)
  (ogent-armory-write-agent
   root
   '(:slug "cto"
     :name "CTO"
     :role "Architecture"
     :provider "codex"
     :model "gpt-5.4"
     :active t
     :workspace "engineering"
     :tags ("strategy" "architecture"))
   "Keep the technical plan clear.")
  (ogent-armory-write-job
   root "cto"
   '(:id "weekly-review"
     :name "Weekly Review"
     :cron "0 9 * * 1"
     :enabled t)
   "Review architecture notes.")
  (ogent-armory-write-job
   root "cto"
   '(:id "old-report"
     :name "Old Report"
     :cron ""
     :enabled nil)
   "Archived job.")
  (ogent-ui-armory-test--write-session
   root "cto" "weekly-review-run" "DONE" 0 "weekly-review")
  (ogent-ui-armory-test--write-session
   root "cto" "failed-run" "FAILED" 1 "weekly-review"))

(ert-deftest ogent-ui-armory-agents-mode-keybindings ()
  "Agent list mode exposes expected Armory navigation actions."
  (should (eq (lookup-key ogent-armory-agents-mode-map (kbd "RET"))
              #'ogent-armory-agents-open-agent))
  (should (eq (lookup-key ogent-armory-agents-mode-map (kbd "v"))
              #'ogent-armory-agents-visit))
  (should (eq (lookup-key ogent-armory-agents-mode-map (kbd "R"))
              #'ogent-armory-agents-run)))

(ert-deftest ogent-ui-armory-agents-lists-personas ()
  "The Armory agents buffer lists personas with job and session counts."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-agents root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-agents-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "CTO" text))
              (should (string-match-p "Architecture" text))
              (should (string-match-p "codex" text))
              (should (string-match-p "2" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-agent-profile-renders-sections ()
  "The single-agent profile includes the richer Armory sections."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-agent root "cto")))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-agent-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (label '("Composer" "Inbox" "Conversations" "Recent Work"
                               "Schedule" "Details" "Persona Instructions"))
                (should (string-match-p label text)))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "Keep the technical plan clear" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-agent-edit-property-updates-persona ()
  "Editing an agent identity property updates the Org persona drawer."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-agent root "cto")))
      (unwind-protect
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) "OGENT_ROLE"))
                      ((symbol-function 'read-string)
                       (lambda (&rest _) "Systems Architecture")))
              (ogent-armory-agent-edit-property))
            (should (equal (plist-get (ogent-armory-read-agent root "cto") :role)
                           "Systems Architecture")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-tasks-renders-attention-lanes ()
  "The Armory tasks buffer groups jobs and sessions into attention lanes."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-tasks-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (lane '("Inbox" "Needs Reply" "Running" "Just Finished" "Archive"))
                (should (string-match-p lane text)))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "failed-run" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-search-finds-org-records ()
  "Armory search finds matching Org records and opens a result buffer."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-search root "architecture")))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-search-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "architecture" (downcase text)))
              (should (string-match-p "persona.org" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-open-app-browses-index-html ()
  "Opening a Armory app browses an index.html artifact."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((app-file (expand-file-name "apps/dashboard/index.html" root))
          opened)
      (make-directory (file-name-directory app-file) t)
      (ogent-armory--write-file app-file "<!doctype html><title>Zorp</title>")
      (cl-letf (((symbol-function 'browse-url-of-file)
                 (lambda (file &rest _)
                   (setq opened file))))
        (ogent-armory-open-app root)
        (should (equal opened (file-truename app-file)))))))

(ert-deftest ogent-ui-armory-status-links-richer-commands ()
  "Armory status mode links to the richer UI entry points."
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "a"))
              #'ogent-armory-agents))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "t"))
              #'ogent-armory-tasks))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "s"))
              #'ogent-armory-search))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "o"))
              #'ogent-armory-open-app)))

(provide 'ogent-ui-armory-tests)

;;; ogent-ui-armory-tests.el ends here
