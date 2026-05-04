;;; ogent-ui-cabinet-tests.el --- Tests for richer Cabinet UI -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for Cabinet agent lists, profile buffers, task lanes, search, and app
;; entry points.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-cabinet)
(require 'ogent-cabinet-status)
(require 'ogent-ui-cabinet)

(defmacro ogent-ui-cabinet-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary Cabinet directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-ui-cabinet-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-ui-cabinet-test--write-session (root agent-slug name status exit-status &optional job-id)
  "Write a Cabinet session fixture for AGENT-SLUG under ROOT."
  (let* ((session-dir (expand-file-name
                       "sessions"
                       (ogent-cabinet-agent-directory root agent-slug)))
         (file (expand-file-name (concat name ".org") session-dir)))
    (make-directory session-dir t)
    (ogent-cabinet--write-file
     file
     (concat
      (format "#+title: %s\n\n" name)
      (format "* %s %s\n" status name)
      (ogent-cabinet--format-properties
       `(("OGENT_SESSION" . t)
         ("OGENT_AGENT" . ,agent-slug)
         ("OGENT_PROVIDER" . "codex")
         ("OGENT_JOB_ID" . ,(or job-id ""))
         ("OGENT_EXIT_STATUS" . ,exit-status)
         ("OGENT_WORKSPACE" . ,root)
         ("OGENT_FINISHED" . "2026-05-04T09:00:00-0700")))
      "\n** Output\n#+begin_src text\nDone.\n#+end_src\n"))
    file))

(defun ogent-ui-cabinet-test--seed (root)
  "Create a Cabinet fixture in ROOT."
  (ogent-cabinet-scaffold root "Zorp" :kind "root" :create-editor nil)
  (ogent-cabinet-write-agent
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
  (ogent-cabinet-write-job
   root "cto"
   '(:id "weekly-review"
     :name "Weekly Review"
     :cron "0 9 * * 1"
     :enabled t)
   "Review architecture notes.")
  (ogent-cabinet-write-job
   root "cto"
   '(:id "old-report"
     :name "Old Report"
     :cron ""
     :enabled nil)
   "Archived job.")
  (ogent-ui-cabinet-test--write-session
   root "cto" "weekly-review-run" "DONE" 0 "weekly-review")
  (ogent-ui-cabinet-test--write-session
   root "cto" "failed-run" "FAILED" 1 "weekly-review"))

(ert-deftest ogent-ui-cabinet-agents-mode-keybindings ()
  "Agent list mode exposes expected Cabinet navigation actions."
  (should (eq (lookup-key ogent-cabinet-agents-mode-map (kbd "RET"))
              #'ogent-cabinet-agents-open-agent))
  (should (eq (lookup-key ogent-cabinet-agents-mode-map (kbd "v"))
              #'ogent-cabinet-agents-visit))
  (should (eq (lookup-key ogent-cabinet-agents-mode-map (kbd "R"))
              #'ogent-cabinet-agents-run)))

(ert-deftest ogent-ui-cabinet-agents-lists-personas ()
  "The Cabinet agents buffer lists personas with job and session counts."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-agents root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-agents-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "CTO" text))
              (should (string-match-p "Architecture" text))
              (should (string-match-p "codex" text))
              (should (string-match-p "2" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-agent-profile-renders-sections ()
  "The single-agent profile includes the richer Cabinet sections."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-agent root "cto")))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-agent-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (label '("Composer" "Inbox" "Conversations" "Recent Work"
                               "Schedule" "Details" "Persona Instructions"))
                (should (string-match-p label text)))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "Keep the technical plan clear" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-agent-edit-property-updates-persona ()
  "Editing an agent identity property updates the Org persona drawer."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-agent root "cto")))
      (unwind-protect
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) "OGENT_ROLE"))
                      ((symbol-function 'read-string)
                       (lambda (&rest _) "Systems Architecture")))
              (ogent-cabinet-agent-edit-property))
            (should (equal (plist-get (ogent-cabinet-read-agent root "cto") :role)
                           "Systems Architecture")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-tasks-renders-attention-lanes ()
  "The Cabinet tasks buffer groups jobs and sessions into attention lanes."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-tasks-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (lane '("Inbox" "Needs Reply" "Running" "Just Finished" "Archive"))
                (should (string-match-p lane text)))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "failed-run" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-search-finds-org-records ()
  "Cabinet search finds matching Org records and opens a result buffer."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-search root "architecture")))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-search-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "architecture" (downcase text)))
              (should (string-match-p "persona.org" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-open-app-browses-index-html ()
  "Opening a Cabinet app browses an index.html artifact."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((app-file (expand-file-name "apps/dashboard/index.html" root))
          opened)
      (make-directory (file-name-directory app-file) t)
      (ogent-cabinet--write-file app-file "<!doctype html><title>Zorp</title>")
      (cl-letf (((symbol-function 'browse-url-of-file)
                 (lambda (file &rest _)
                   (setq opened file))))
        (ogent-cabinet-open-app root)
        (should (equal opened (file-truename app-file)))))))

(ert-deftest ogent-ui-cabinet-status-links-richer-commands ()
  "Cabinet status mode links to the richer UI entry points."
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "a"))
              #'ogent-cabinet-agents))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "t"))
              #'ogent-cabinet-tasks))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "s"))
              #'ogent-cabinet-search))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "o"))
              #'ogent-cabinet-open-app)))

(provide 'ogent-ui-cabinet-tests)

;;; ogent-ui-cabinet-tests.el ends here
