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

(ert-deftest ogent-cabinet-graph-build-ignores-user-org-hooks ()
  "Machine readers tolerate Org docs containing drawer-like examples."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Ops" :kind "root" :create-editor t)
    (make-directory (expand-file-name "specs" dir) t)
    (ogent-cabinet--write-file
     (expand-file-name "specs/parity.org" dir)
     (concat
      "#+title: Cabinet Parity\n\n"
      "* Notes\n"
      "#+begin_example\n"
      ":OGENT_AGENT_SCOPE: cabinet | global\n"
      ":OGENT_DISPLAY_NAME:\n"
      "#+end_example\n"))
    (let ((org-mode-hook (cons (lambda ()
                                 (org-cycle-hide-drawers 'all))
                               org-mode-hook)))
      (let ((graph (ogent-cabinet-build-graph dir)))
        (should (plist-get graph :nodes))
        (should (plist-get graph :edges))))))

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

(ert-deftest ogent-cabinet-agent-round-trips-cabinet-identity ()
  "Agent personas include Cabinet identity, dispatch, and skill fields."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto"
       :name "CTO"
       :display-name "Chief Architect"
       :icon "lambda"
       :color "#2255ff"
       :avatar "avatars/cto.png"
       :role "Architecture"
       :department "Engineering"
       :type "lead"
       :scope "cabinet"
       :can-dispatch t
       :provider "codex-cli"
       :adapter "codex-cli"
       :adapter-config "sandbox=workspace-write"
       :model "gpt-5.4"
       :effort "high"
       :runtime-mode "terminal"
       :budget "200000"
       :focus ("lisp" "specs")
       :goals ("ship parity" "keep Org durable")
       :channels ("org" "mail")
       :skills ("review" "planning")
       :recommended-skills ("security")
       :setup-complete t
       :last-heartbeat "2026-05-06T09:00:00-0700"
       :next-heartbeat "2026-05-07T09:00:00-0700"
       :active t
       :workspace "engineering"
       :tags ("engineering" "strategy"))
     "Keep the technical plan brutally clear.")
    (let ((agent (ogent-cabinet-read-agent dir "cto")))
      (should (equal (plist-get agent :display-name) "Chief Architect"))
      (should (equal (plist-get agent :icon) "lambda"))
      (should (equal (plist-get agent :department) "Engineering"))
      (should (equal (plist-get agent :type) "lead"))
      (should (equal (plist-get agent :scope) "cabinet"))
      (should (plist-get agent :can-dispatch))
      (should (equal (plist-get agent :adapter) "codex-cli"))
      (should (equal (plist-get agent :effort) "high"))
      (should (equal (plist-get agent :runtime-mode) "terminal"))
      (should (equal (plist-get agent :focus) '("lisp" "specs")))
      (should (equal (plist-get agent :skills) '("review" "planning")))
      (should (equal (plist-get agent :recommended-skills) '("security")))
      (should (plist-get agent :setup-complete)))))

(ert-deftest ogent-cabinet-agent-resolution-prefers-local-then-global ()
  "Agent resolution prefers cabinet-local personas before global personas."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-global-agent
     dir
     '(:slug "cto" :name "Global CTO" :department "Executive")
     "Global guidance.")
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto" :name "Local CTO" :department "Engineering")
     "Local guidance.")
    (let ((agent (ogent-cabinet-resolve-agent dir "cto")))
      (should (equal (plist-get agent :name) "Local CTO"))
      (should (eq (plist-get agent :scope) 'cabinet)))
    (delete-directory (ogent-cabinet-agent-directory dir "cto") t)
    (let ((agent (ogent-cabinet-resolve-agent dir "cto")))
      (should (equal (plist-get agent :name) "Global CTO"))
      (should (eq (plist-get agent :scope) 'global)))))

(ert-deftest ogent-cabinet-agent-resolution-uses-visible-unique-cabinets ()
  "Agent resolution can fall through to slug-unique visible child cabinets."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Root" :kind "root" :create-editor nil)
    (let ((child (expand-file-name "research" dir)))
      (ogent-cabinet-scaffold
       child "Research" :kind "child" :description "Lab" :create-editor nil)
      (ogent-cabinet-write-agent
       child
       '(:slug "analyst" :name "Analyst" :department "Research")
       "Analyze notes.")
      (let ((agent (ogent-cabinet-resolve-agent
                    dir "analyst" :include-visible t)))
        (should (equal (plist-get agent :name) "Analyst"))
        (should (eq (plist-get agent :scope) 'visible))
        (should (equal (file-truename child)
                       (file-truename (plist-get agent :source-root))))))))

(ert-deftest ogent-cabinet-agents-group-by-department-and-lead ()
  "Department projection groups agents and identifies dispatch-capable leads."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto" :name "CTO" :department "Engineering" :type "lead"
       :can-dispatch t)
     "Lead engineering.")
    (ogent-cabinet-write-agent
     dir
     '(:slug "builder" :name "Builder" :department "Engineering"
       :type "specialist")
     "Build systems.")
    (ogent-cabinet-write-global-agent
     dir
     '(:slug "ops" :name "Ops" :department "Operations" :type "support")
     "Handle ops.")
    (let* ((groups (ogent-cabinet-agents-by-department dir))
           (engineering (seq-find
                         (lambda (group)
                           (equal (plist-get group :department)
                                  "Engineering"))
                         groups))
           (operations (seq-find
                        (lambda (group)
                          (equal (plist-get group :department)
                                 "Operations"))
                        groups)))
      (should engineering)
      (should operations)
      (should (equal (plist-get (plist-get engineering :lead) :slug) "cto"))
      (should (= 2 (length (plist-get engineering :agents))))
      (should (= 1 (length (plist-get operations :agents)))))))

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

(ert-deftest ogent-cabinet-session-detail-treats-success-error-as-trace ()
  "Older successful transcripts with Error sections read as runtime traces."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (let* ((session-dir (ogent-cabinet-sessions-directory dir "cto"))
           (file (expand-file-name "successful.org" session-dir)))
      (make-directory session-dir t)
      (ogent-cabinet--write-file
       file
       (concat
        "#+title: Successful Run\n\n"
        "* DONE Successful Run\n"
        (ogent-cabinet--format-properties
         '(("OGENT_SESSION" . t)
           ("OGENT_AGENT" . "cto")
           ("OGENT_PROVIDER" . "codex")
           ("OGENT_EXIT_STATUS" . 0)
           ("OGENT_FINISHED" . "2026-05-04T09:00:00-0700")))
        "\n** Prompt\n#+begin_src text\nCheck the plan.\n#+end_src\n"
        "\n** Output\n#+begin_src text\nDone.\n#+end_src\n"
        "\n** Error\n#+begin_src text\nCodex trace.\n#+end_src\n"))
      (let ((detail (ogent-cabinet-session-detail file "cto")))
        (should-not (plist-get detail :error))
        (should (string-match-p "Codex trace"
                                (plist-get detail :runtime-trace)))))))

(ert-deftest ogent-cabinet-session-detail-keeps-src-block-headings-in-trace ()
  "Runtime trace parsing survives Org-looking text inside the log."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (let* ((session-dir (ogent-cabinet-sessions-directory dir "cto"))
           (file (expand-file-name "successful.org" session-dir)))
      (make-directory session-dir t)
      (ogent-cabinet--write-file
       file
       (concat
        "#+title: Successful Run\n\n"
        "* DONE Successful Run\n"
        (ogent-cabinet--format-properties
         '(("OGENT_SESSION" . t)
           ("OGENT_AGENT" . "cto")
           ("OGENT_PROVIDER" . "codex")
           ("OGENT_EXIT_STATUS" . 0)
           ("OGENT_FINISHED" . "2026-05-04T09:00:00-0700")))
        "\n** Prompt\n#+begin_src text\nCheck the plan.\n#+end_src\n"
        "\n** Output\n#+begin_src text\nDone.\n#+end_src\n"
        "\n** Runtime Trace\n#+begin_src text\n"
        "first line\n"
        "** Output\n"
        "#+begin_src text\n"
        "inner block text\n"
        ",#+end_src\n"
        "last line\n"
        "#+end_src\n"))
      (let ((trace (plist-get (ogent-cabinet-session-detail file "cto")
                              :runtime-trace)))
        (should (string-prefix-p "first line" trace))
        (should (string-match-p "inner block text" trace))
        (should (string-match-p "last line" trace))
        (should-not (string-prefix-p "#+begin_src" trace))))))

(ert-deftest ogent-cabinet-session-detail-keeps-legacy-failed-error ()
  "Older failed transcripts without exit status keep Error sections as errors."
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
           ("OGENT_FINISHED" . "2026-05-04T09:00:00-0700")))
        "\n** Output\n#+begin_src text\nNope.\n#+end_src\n"
        "\n** Error\n#+begin_src text\nProvider failed.\n#+end_src\n"))
      (let ((detail (ogent-cabinet-session-detail file "cto")))
        (should (string-match-p "Provider failed"
                                (plist-get detail :error)))
        (should-not (plist-get detail :runtime-trace))))))

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

(ert-deftest ogent-cabinet-record-metadata-classifies-specific-records ()
  "Record metadata does not mistake jobs or sessions for agents."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto"
       :name "CTO"
       :role "Architecture"
       :provider "codex")
     "Keep the plan direct.")
    (ogent-cabinet-write-job
     dir "cto"
     '(:id "weekly-review"
       :name "Weekly Review"
       :enabled t)
     "Find risks.")
    (let ((session-file (expand-file-name
                         "20260504T120000-run.org"
                         (ogent-cabinet-sessions-directory dir "cto"))))
      (ogent-cabinet--write-file
       session-file
       (concat
        "#+title: CTO Run\n\n"
        "* DONE CTO Run\n"
        ":PROPERTIES:\n"
        ":OGENT_SESSION: t\n"
        ":OGENT_AGENT: cto\n"
        ":OGENT_EXIT_STATUS: 0\n"
        ":END:\n"))
      (should (eq (ogent-cabinet-record-kind
                   (ogent-cabinet-agent-file dir "cto"))
                  'agent))
      (should (equal (plist-get
                      (ogent-cabinet-record-metadata
                       (ogent-cabinet-agent-file dir "cto"))
                      :agent)
                     "cto"))
      (should (eq (ogent-cabinet-record-kind
                   (ogent-cabinet-job-file dir "cto" "weekly-review"))
                  'job))
      (should (eq (ogent-cabinet-record-kind session-file) 'session)))))

(ert-deftest ogent-cabinet-list-apps-includes-linked-state-artifacts ()
  "Session-linked app artifacts under Cabinet state are discoverable."
  (ogent-cabinet-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto"
       :name "CTO"
       :role "Architecture"
       :provider "codex")
     "Keep the plan direct.")
    (let* ((app-dir ".cabinet-state/dogfood-app")
           (app-file (expand-file-name "index.html" (expand-file-name app-dir dir)))
           (session-file (expand-file-name
                          "20260504T120000-run.org"
                          (ogent-cabinet-sessions-directory dir "cto"))))
      (ogent-cabinet--write-file app-file "<!doctype html>")
      (ogent-cabinet--write-file
       session-file
       (concat
        "#+title: CTO Run\n\n"
        "* DONE CTO Run\n"
        ":PROPERTIES:\n"
        ":OGENT_SESSION: t\n"
        ":OGENT_AGENT: cto\n"
        ":OGENT_EXIT_STATUS: 0\n"
        ":OGENT_APP_PATHS: .cabinet-state/dogfood-app\n"
        ":END:\n"))
      (let ((app (car (ogent-cabinet-list-apps dir))))
        (should app)
        (should (equal (plist-get app :label) app-dir))
        (should (equal (plist-get app :agent) "cto"))
        (should (equal (plist-get app :session-id)
                       "20260504T120000-run"))))))

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
