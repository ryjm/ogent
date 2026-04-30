;;; ogent-armory-tests.el --- Tests for Org-native armories -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Org-backed armory storage scaffold.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory)
(require 'org)

(defmacro ogent-armory-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-armory-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-armory-test--slurp (file)
  "Return FILE contents as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(ert-deftest ogent-armory-scaffold-creates-org-layout ()
  "Scaffolding creates the armory layout using Org files."
  (ogent-armory-test-with-temp-dir dir
    (ogent-armory-scaffold
     dir "Acme Research"
     :kind "root"
     :description "Research lab"
     :create-editor t)
    (should (file-exists-p (expand-file-name "index.org" dir)))
    (should (file-directory-p (expand-file-name ".agents" dir)))
    (should (file-directory-p (expand-file-name ".agents/.conversations" dir)))
    (should (file-directory-p (expand-file-name ".jobs" dir)))
    (should (file-directory-p (expand-file-name ".armory-state" dir)))
    (should (file-exists-p (expand-file-name ".agents/editor/persona.org" dir)))
    (should-not (file-exists-p (expand-file-name "index.md" dir)))
    (should-not (directory-files-recursively dir "\\.md\\'"))
    (let ((content (ogent-armory-test--slurp
                    (expand-file-name "index.org" dir))))
      (should (string-match-p "#\\+title: Acme Research" content))
      (should (string-match-p ":OGENT_ARMORY: t" content))
      (should (string-match-p ":OGENT_KIND: root" content))
      (should (string-match-p ":OGENT_ARMORY_ID: acme-research-root" content)))))

(ert-deftest ogent-armory-find-root-discovers-parent-armory ()
  "Root discovery walks upward from nested directories."
  (ogent-armory-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Ops" :kind "root" :create-editor nil)
    (let ((nested (expand-file-name "work/research" dir)))
      (make-directory nested t)
      (let ((default-directory nested))
        (should (equal (file-truename dir)
                       (file-truename (ogent-armory-find-root))))))))

(ert-deftest ogent-armory-agent-round-trips-org-persona ()
  "Agent personas are written and read as Org headings."
  (ogent-armory-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto"
       :name "CTO"
       :role "Architecture"
       :provider "codex-cli"
       :model "gpt-5.4"
       :permission-mode "default"
       :heartbeat "0 9 * * 1-5"
       :active t
       :workspace "engineering"
       :tags ("engineering" "strategy"))
     "Keep the technical plan brutally clear.")
    (let ((agent (ogent-armory-read-agent dir "cto")))
      (should (equal (plist-get agent :slug) "cto"))
      (should (equal (plist-get agent :name) "CTO"))
      (should (equal (plist-get agent :role) "Architecture"))
      (should (equal (plist-get agent :provider) "codex-cli"))
      (should (equal (plist-get agent :model) "gpt-5.4"))
      (should (equal (plist-get agent :permission-mode) "default"))
      (should (equal (plist-get agent :heartbeat) "0 9 * * 1-5"))
      (should (eq (plist-get agent :active) t))
      (should (equal (plist-get agent :workspace) "engineering"))
      (should (equal (plist-get agent :tags) '("engineering" "strategy")))
      (should (string-match-p "brutally clear" (plist-get agent :body))))
    (should (file-exists-p (expand-file-name ".agents/cto/persona.org" dir)))
    (should (file-directory-p (expand-file-name ".agents/cto/jobs" dir)))
    (should (file-directory-p (expand-file-name ".agents/cto/memory" dir)))))

(ert-deftest ogent-armory-job-round-trips-org-file ()
  "Agent jobs are written and read as Org task files."
  (ogent-armory-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "editor" :name "Editor" :role "Knowledge editor")
     "Maintain the knowledge base.")
    (ogent-armory-write-job
     dir "editor"
     '(:id "weekly-review"
       :name "Weekly Review"
       :cron "0 9 * * 1"
       :enabled t)
     "Review recent Org pages and file a summary.")
    (let ((job (ogent-armory-read-job dir "editor" "weekly-review")))
      (should (equal (plist-get job :id) "weekly-review"))
      (should (equal (plist-get job :agent) "editor"))
      (should (equal (plist-get job :name) "Weekly Review"))
      (should (equal (plist-get job :cron) "0 9 * * 1"))
      (should (eq (plist-get job :enabled) t))
      (should (string-match-p "recent Org pages" (plist-get job :body))))
    (should (file-exists-p
             (expand-file-name ".agents/editor/jobs/weekly-review.org" dir)))))

(ert-deftest ogent-armory-build-graph-connects-armory-agents-and-jobs ()
  "The armory graph connects armory, agent, and job records."
  (ogent-armory-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (ogent-armory-write-job
     dir "cto"
     '(:id "weekly-review" :name "Weekly Review" :cron "0 9 * * 1")
     "Review architecture notes.")
    (let* ((nested (expand-file-name "work/planning" dir))
           (_ (make-directory nested t))
           (graph (ogent-armory-build-graph nested))
           (nodes (plist-get graph :nodes))
           (edges (plist-get graph :edges)))
      (should (equal (plist-get graph :root) (file-truename dir)))
      (should (seq-find (lambda (node)
                          (equal (plist-get node :id) "armory:."))
                        nodes))
      (should (seq-find (lambda (node)
                          (equal (plist-get node :id) "agent:cto"))
                        nodes))
      (should (seq-find (lambda (node)
                          (equal (plist-get node :id) "job:cto/weekly-review"))
                        nodes))
      (should (seq-find (lambda (edge)
                          (and (equal (plist-get edge :from) "armory:.")
                               (equal (plist-get edge :to) "agent:cto")
                               (eq (plist-get edge :kind) 'contains)))
                        edges))
      (should (seq-find (lambda (edge)
                          (and (equal (plist-get edge :from) "agent:cto")
                               (equal (plist-get edge :to) "job:cto/weekly-review")
                               (eq (plist-get edge :kind) 'owns)))
                        edges)))))

(provide 'ogent-armory-tests)

;;; ogent-armory-tests.el ends here
