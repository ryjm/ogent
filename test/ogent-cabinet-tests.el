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
       :model "gpt-5.4"
       :permission-mode "default"
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

(ert-deftest ogent-cabinet-build-graph-connects-cabinet-agents-and-jobs ()
  "The cabinet graph connects cabinet, agent, and job records."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (ogent-cabinet-write-job
     dir "cto"
     '(:id "weekly-review" :name "Weekly Review" :cron "0 9 * * 1")
     "Review architecture notes.")
    (let* ((nested (expand-file-name "work/planning" dir))
           (_ (make-directory nested t))
           (graph (ogent-cabinet-build-graph nested))
           (nodes (plist-get graph :nodes))
           (edges (plist-get graph :edges)))
      (should (equal (plist-get graph :root) (file-truename dir)))
      (should (seq-find (lambda (node)
                          (equal (plist-get node :id) "cabinet:."))
                        nodes))
      (should (seq-find (lambda (node)
                          (equal (plist-get node :id) "agent:cto"))
                        nodes))
      (should (seq-find (lambda (node)
                          (equal (plist-get node :id) "job:cto/weekly-review"))
                        nodes))
      (should (seq-find (lambda (edge)
                          (and (equal (plist-get edge :from) "cabinet:.")
                               (equal (plist-get edge :to) "agent:cto")
                               (eq (plist-get edge :kind) 'contains)))
                        edges))
      (should (seq-find (lambda (edge)
                          (and (equal (plist-get edge :from) "agent:cto")
                               (equal (plist-get edge :to) "job:cto/weekly-review")
                               (eq (plist-get edge :kind) 'owns)))
                        edges)))))

(ert-deftest ogent-cabinet-job-metadata-and-archive-preserve-org-body ()
  "Job metadata edits update the property drawer without rewriting body text."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (ogent-cabinet-write-job
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
    (ogent-cabinet-update-job-property dir "cto" "weekly-review" "OGENT_ENABLED" "nil")
    (ogent-cabinet-update-job-property dir "cto" "weekly-review" "OGENT_MODEL" "opus")
    (let ((job (ogent-cabinet-read-job dir "cto" "weekly-review"))
          (content (ogent-cabinet-test--slurp
                    (ogent-cabinet-job-file dir "cto" "weekly-review"))))
      (should-not (plist-get job :enabled))
      (should (equal (plist-get job :provider) "claude"))
      (should (equal (plist-get job :model) "opus"))
      (should (equal (plist-get job :workspace) "engineering"))
      (should (equal (plist-get job :tags) '("strategy" "weekly")))
      (should (string-match-p "Manual edits stay here" content)))))

(ert-deftest ogent-cabinet-job-validation-reports-friendly-errors ()
  "Malformed job metadata reports all user-fixable errors."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (ogent-cabinet-write-job
     dir "cto"
     '(:id "weekly-review"
       :name "Weekly Review"
       :cron "bad cron"
       :enabled t)
     "Review architecture notes.")
    (ogent-cabinet-update-job-property
     dir "cto" "weekly-review" "OGENT_ENABLED" "maybe")
    (let* ((job (ogent-cabinet-read-job dir "cto" "weekly-review"))
           (error (should-error (ogent-cabinet-validate-job job)
                                :type 'user-error))
           (message (cadr error)))
      (should (string-match-p "Malformed Cabinet job metadata" message))
      (should (string-match-p "OGENT_ENABLED" message))
      (should (string-match-p "OGENT_CRON" message)))))

(ert-deftest ogent-cabinet-session-detail-parses-transcript-sections ()
  "Conversation detail parsing extracts prompt, output, error, and tool blocks."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (let* ((session-dir (ogent-cabinet-sessions-directory dir "cto"))
           (file (expand-file-name "failed.org" session-dir)))
      (make-directory session-dir t)
      (ogent-cabinet--write-file
       file
       (concat
        "#+title: Failed Run\n\n"
        "* FAILED Failed Run\n"
        (ogent-cabinet--format-properties
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
      (let ((detail (ogent-cabinet-session-detail file "cto")))
        (should (equal (plist-get detail :status) "FAILED"))
        (should (equal (plist-get detail :duration) "3.2s"))
        (should (string-match-p "Check the plan" (plist-get detail :prompt)))
        (should (string-match-p "Nope" (plist-get detail :output)))
        (should (string-match-p "Boom" (plist-get detail :error)))
        (should (= 1 (length (plist-get detail :tools))))))))

(ert-deftest ogent-cabinet-search-filters-kind-agent-status-tag-and-archive ()
  "Cabinet search narrows matches by record metadata."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto"
       :name "CTO"
       :role "Architecture"
       :tags ("strategy"))
     "Searchable strategy text.")
    (ogent-cabinet-write-agent
     dir
     '(:slug "editor"
       :name "Editor"
       :role "Writing"
       :tags ("docs"))
     "Searchable docs text.")
    (ogent-cabinet-write-job
     dir "cto"
     '(:id "weekly-review"
       :name "Weekly Review"
       :tags ("strategy")
       :enabled t)
     "Searchable job text.")
    (let ((agent-results (ogent-cabinet-search-records
                          dir "Searchable" :kind 'agent :agent "cto"))
          (tag-results (ogent-cabinet-search-records
                        dir "Searchable" :tag "strategy")))
      (should (= 1 (length agent-results)))
      (should (equal (plist-get (car agent-results) :agent) "cto"))
      (should (= 2 (length tag-results)))
      (dolist (result tag-results)
        (should (member "strategy" (plist-get result :tags)))))))

(ert-deftest ogent-cabinet-import-artifacts-writes-org-records ()
  "Importing Markdown, HTML, and text artifacts creates durable Org records."
  (ogent-cabinet-test-with-temp-dir dir
    (let ((source (expand-file-name "incoming" dir))
          (root (expand-file-name "cabinet" dir)))
      (make-directory source t)
      (ogent-cabinet--write-file
       (expand-file-name "notes.md" source)
       "# Notes\n\nUseful Cabinet material.")
      (ogent-cabinet--write-file
       (expand-file-name "page.html" source)
       "<!doctype html><title>App</title>")
      (ogent-cabinet--write-file
       (expand-file-name "plain.txt" source)
       "Plain text material.")
      (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
      (let ((records (ogent-cabinet-import-artifacts root source)))
        (should (= 3 (length records)))
        (dolist (record records)
          (should (string-suffix-p ".org" (plist-get record :path)))
          (should (file-exists-p (plist-get record :path))))
        (should (file-exists-p (expand-file-name "notes.md" source)))
        (should-not (directory-files-recursively root "\\.md\\'"))
        (should (string-match-p
                 "\\* Notes"
                 (ogent-cabinet-test--slurp
                  (expand-file-name "imports/notes.org" root))))))))

(provide 'ogent-cabinet-tests)

;;; ogent-cabinet-tests.el ends here
