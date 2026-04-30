;;; ogent-cabinet-tests.el --- Tests for Org-native cabinets -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Org-backed cabinet storage scaffold.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-cabinet)
(require 'org)

(defmacro ogent-cabinet-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-cabinet-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-cabinet-test--slurp (file)
  "Return FILE contents as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(ert-deftest ogent-cabinet-scaffold-creates-org-layout ()
  "Scaffolding creates the cabinet layout using Org files."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold
     dir "Acme Research"
     :kind "root"
     :description "Research lab"
     :create-editor t)
    (should (file-exists-p (expand-file-name "index.org" dir)))
    (should (file-directory-p (expand-file-name ".agents" dir)))
    (should (file-directory-p (expand-file-name ".agents/.conversations" dir)))
    (should (file-directory-p (expand-file-name ".jobs" dir)))
    (should (file-directory-p (expand-file-name ".cabinet-state" dir)))
    (should (file-exists-p (expand-file-name ".agents/editor/persona.org" dir)))
    (should-not (file-exists-p (expand-file-name "index.md" dir)))
    (should-not (directory-files-recursively dir "\\.md\\'"))
    (let ((content (ogent-cabinet-test--slurp
                    (expand-file-name "index.org" dir))))
      (should (string-match-p "#\\+title: Acme Research" content))
      (should (string-match-p ":OGENT_CABINET: t" content))
      (should (string-match-p ":OGENT_KIND: root" content))
      (should (string-match-p ":OGENT_CABINET_ID: acme-research-root" content)))))

(ert-deftest ogent-cabinet-find-root-discovers-parent-cabinet ()
  "Root discovery walks upward from nested directories."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Ops" :kind "root" :create-editor nil)
    (let ((nested (expand-file-name "work/research" dir)))
      (make-directory nested t)
      (let ((default-directory nested))
        (should (equal (file-truename dir)
                       (file-truename (ogent-cabinet-find-root))))))))

(ert-deftest ogent-cabinet-agent-round-trips-org-persona ()
  "Agent personas are written and read as Org headings."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto"
       :name "CTO"
       :role "Architecture"
       :provider "codex-cli"
       :heartbeat "0 9 * * 1-5"
       :active t
       :workspace "engineering"
       :tags ("engineering" "strategy"))
     "Keep the technical plan brutally clear.")
    (let ((agent (ogent-cabinet-read-agent dir "cto")))
      (should (equal (plist-get agent :slug) "cto"))
      (should (equal (plist-get agent :name) "CTO"))
      (should (equal (plist-get agent :role) "Architecture"))
      (should (equal (plist-get agent :provider) "codex-cli"))
      (should (equal (plist-get agent :heartbeat) "0 9 * * 1-5"))
      (should (eq (plist-get agent :active) t))
      (should (equal (plist-get agent :workspace) "engineering"))
      (should (equal (plist-get agent :tags) '("engineering" "strategy")))
      (should (string-match-p "brutally clear" (plist-get agent :body))))
    (should (file-exists-p (expand-file-name ".agents/cto/persona.org" dir)))
    (should (file-directory-p (expand-file-name ".agents/cto/jobs" dir)))
    (should (file-directory-p (expand-file-name ".agents/cto/memory" dir)))))

(ert-deftest ogent-cabinet-job-round-trips-org-file ()
  "Agent jobs are written and read as Org task files."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "editor" :name "Editor" :role "Knowledge editor")
     "Maintain the knowledge base.")
    (ogent-cabinet-write-job
     dir "editor"
     '(:id "weekly-review"
       :name "Weekly Review"
       :cron "0 9 * * 1"
       :enabled t)
     "Review recent Org pages and file a summary.")
    (let ((job (ogent-cabinet-read-job dir "editor" "weekly-review")))
      (should (equal (plist-get job :id) "weekly-review"))
      (should (equal (plist-get job :agent) "editor"))
      (should (equal (plist-get job :name) "Weekly Review"))
      (should (equal (plist-get job :cron) "0 9 * * 1"))
      (should (eq (plist-get job :enabled) t))
      (should (string-match-p "recent Org pages" (plist-get job :body))))
    (should (file-exists-p
             (expand-file-name ".agents/editor/jobs/weekly-review.org" dir)))))

(provide 'ogent-cabinet-tests)

;;; ogent-cabinet-tests.el ends here
