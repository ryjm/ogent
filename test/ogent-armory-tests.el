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

(ert-deftest ogent-armory-job-metadata-and-archive-preserve-org-body ()
  "Job metadata edits update the property drawer without rewriting body text."
  (ogent-armory-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (ogent-armory-write-job
     dir "cto"
     '(:id "weekly-review"
       :name "Weekly Review"
       :cron "0 9 * * 1"
       :provider "claude"
       :model "sonnet"
       :workspace "engineering"
       :tags ("strategy" "weekly")
       :enabled t)
     "Review architecture notes.\n\nManual edits stay here.")
    (ogent-armory-update-job-property dir "cto" "weekly-review" "OGENT_ENABLED" "nil")
    (ogent-armory-update-job-property dir "cto" "weekly-review" "OGENT_MODEL" "opus")
    (let ((job (ogent-armory-read-job dir "cto" "weekly-review"))
          (content (ogent-armory-test--slurp
                    (ogent-armory-job-file dir "cto" "weekly-review"))))
      (should-not (plist-get job :enabled))
      (should (equal (plist-get job :provider) "claude"))
      (should (equal (plist-get job :model) "opus"))
      (should (equal (plist-get job :workspace) "engineering"))
      (should (equal (plist-get job :tags) '("strategy" "weekly")))
      (should (string-match-p "Manual edits stay here" content)))))

(ert-deftest ogent-armory-job-validation-reports-friendly-errors ()
  "Malformed job metadata reports all user-fixable errors."
  (ogent-armory-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (ogent-armory-write-job
     dir "cto"
     '(:id "weekly-review"
       :name "Weekly Review"
       :cron "bad cron"
       :enabled t)
     "Review architecture notes.")
    (ogent-armory-update-job-property
     dir "cto" "weekly-review" "OGENT_ENABLED" "maybe")
    (let* ((job (ogent-armory-read-job dir "cto" "weekly-review"))
           (error (should-error (ogent-armory-validate-job job)
                                :type 'user-error))
           (message (cadr error)))
      (should (string-match-p "Malformed Armory job metadata" message))
      (should (string-match-p "OGENT_ENABLED" message))
      (should (string-match-p "OGENT_CRON" message)))))

(ert-deftest ogent-armory-session-detail-parses-transcript-sections ()
  "Conversation detail parsing extracts prompt, output, error, and tool blocks."
  (ogent-armory-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (let* ((session-dir (ogent-armory-sessions-directory dir "cto"))
           (file (expand-file-name "failed.org" session-dir)))
      (make-directory session-dir t)
      (ogent-armory--write-file
       file
       (concat
        "#+title: Failed Run\n\n"
        "* FAILED Failed Run\n"
        (ogent-armory--format-properties
         '(("OGENT_SESSION" . t)
           ("OGENT_AGENT" . "cto")
           ("OGENT_PROVIDER" . "codex")
           ("OGENT_MODEL" . "gpt-5.4")
           ("OGENT_JOB_ID" . "weekly-review")
           ("OGENT_EXIT_STATUS" . 1)
           ("OGENT_DURATION" . "3.2s")
           ("OGENT_WORKSPACE" . "/tmp")
           ("OGENT_FINISHED" . "2026-05-04T09:00:00-0700")))
        "\n** Prompt\n#+begin_src text\nCheck the plan.\n#+end_src\n"
        "\n** Output\n#+begin_src text\nNope.\n#+end_src\n"
        "\n** Tool\n#+begin_tool shell :status failed\nexit 1\n#+end_tool\n"
        "\n** Error\n#+begin_src text\nBoom.\n#+end_src\n"))
      (let ((detail (ogent-armory-session-detail file "cto")))
        (should (equal (plist-get detail :status) "FAILED"))
        (should (equal (plist-get detail :duration) "3.2s"))
        (should (string-match-p "Check the plan" (plist-get detail :prompt)))
        (should (string-match-p "Nope" (plist-get detail :output)))
        (should (string-match-p "Boom" (plist-get detail :error)))
        (should (= 1 (length (plist-get detail :tools))))))))

(ert-deftest ogent-armory-search-filters-kind-agent-status-tag-and-archive ()
  "Armory search narrows matches by record metadata."
  (ogent-armory-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto"
       :name "CTO"
       :role "Architecture"
       :tags ("strategy"))
     "Searchable strategy text.")
    (ogent-armory-write-agent
     dir
     '(:slug "editor"
       :name "Editor"
       :role "Writing"
       :tags ("docs"))
     "Searchable docs text.")
    (ogent-armory-write-job
     dir "cto"
     '(:id "weekly-review"
       :name "Weekly Review"
       :tags ("strategy")
       :enabled t)
     "Searchable job text.")
    (let ((agent-results (ogent-armory-search-records
                          dir "Searchable" :kind 'agent :agent "cto"))
          (tag-results (ogent-armory-search-records
                        dir "Searchable" :tag "strategy")))
      (should (= 1 (length agent-results)))
      (should (equal (plist-get (car agent-results) :agent) "cto"))
      (should (= 2 (length tag-results)))
      (dolist (result tag-results)
        (should (member "strategy" (plist-get result :tags)))))))

(ert-deftest ogent-armory-import-artifacts-writes-org-records ()
  "Importing Markdown, HTML, and text artifacts creates durable Org records."
  (ogent-armory-test-with-temp-dir dir
    (let ((source (expand-file-name "incoming" dir))
          (root (expand-file-name "armory" dir)))
      (make-directory source t)
      (ogent-armory--write-file
       (expand-file-name "notes.md" source)
       "# Notes\n\nUseful Armory material.")
      (ogent-armory--write-file
       (expand-file-name "page.html" source)
       "<!doctype html><title>App</title>")
      (ogent-armory--write-file
       (expand-file-name "plain.txt" source)
       "Plain text material.")
      (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
      (let ((records (ogent-armory-import-artifacts root source)))
        (should (= 3 (length records)))
        (dolist (record records)
          (should (string-suffix-p ".org" (plist-get record :path)))
          (should (file-exists-p (plist-get record :path))))
        (should (file-exists-p (expand-file-name "notes.md" source)))
        (should-not (directory-files-recursively root "\\.md\\'"))
        (should (string-match-p
                 "\\* Notes"
                 (ogent-armory-test--slurp
                  (expand-file-name "imports/notes.org" root))))))))

(provide 'ogent-armory-tests)

;;; ogent-armory-tests.el ends here
