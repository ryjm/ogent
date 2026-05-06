;;; ogent-armory-settings-tests.el --- Tests for Armory settings -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for settings Org round-trip, onboarding, registry import, backups, help,
;; and demo Armory creation.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory)
(require 'ogent-armory-settings)

(defmacro ogent-armory-settings-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary Armory directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-armory-settings-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-armory-settings-test--slurp (file)
  "Return FILE contents."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(ert-deftest ogent-armory-settings-round-trips-through-org ()
  "Settings write, update, export, import, and buffer rendering use Org state."
  (ogent-armory-settings-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-settings-write
     root
     '(:profile-name "Operator"
       :default-provider "claude"
       :default-model "sonnet"
       :default-effort "high"
       :skill-paths ("skills/a" "skills/b")
       :notifications t)
     :merge t)
    (let ((settings (ogent-armory-settings-read root)))
      (should (equal (plist-get settings :profile-name) "Operator"))
      (should (equal (plist-get settings :default-provider) "claude"))
      (should (equal (plist-get settings :skill-paths)
                     '("skills/a" "skills/b")))
      (should (plist-get settings :notifications)))
    (ogent-armory-settings-update root :theme "dark")
    (should (equal (plist-get (ogent-armory-settings-read root) :theme)
                   "dark"))
    (let ((buffer (ogent-armory-settings root)))
      (with-current-buffer buffer
        (should (string-match-p "Default provider" (buffer-string)))
        (should (string-match-p "claude" (buffer-string))))
      (kill-buffer buffer))
    (let* ((exported (expand-file-name "settings-export.org" root))
           (other (expand-file-name "other" root)))
      (ogent-armory-scaffold other "Other" :kind "root" :create-editor nil)
      (ogent-armory-settings-export root exported)
      (should (string-match-p "OGENT_DEFAULT_PROVIDER"
                              (ogent-armory-settings-test--slurp exported)))
      (ogent-armory-settings-import other exported)
      (should (equal (plist-get (ogent-armory-settings-read other)
                                :default-provider)
                     "claude")))))

(ert-deftest ogent-armory-onboard-writes-settings-and-team ()
  "Armory onboarding writes defaults and an initial team as Org records."
  (ogent-armory-settings-test-with-temp-dir root
    (ogent-armory-onboard
     root
     :name "Acme"
     :default-provider "codex"
     :default-model "gpt-5.4"
     :default-effort "medium"
     :runtime "native"
     :team '((:slug "planner"
              :name "Planner"
              :role "Plan project work"
              :department "Ops"
              :type "lead"
              :can-dispatch t
              :tags ("planning"))))
    (let ((settings (ogent-armory-settings-read root))
          (agent (ogent-armory-read-agent root "planner")))
      (should (equal (plist-get settings :profile-name) "Acme"))
      (should (equal (plist-get settings :default-model) "gpt-5.4"))
      (should (equal (plist-get agent :provider) "codex"))
      (should (equal (plist-get agent :runtime-mode) "native"))
      (should (plist-get agent :can-dispatch)))))

(ert-deftest ogent-armory-registry-import-creates-org-records ()
  "Registry import reads a template manifest and creates Armory Org records."
  (ogent-armory-settings-test-with-temp-dir root
    (let ((manifest (expand-file-name "template.json" root))
          (target (expand-file-name "imported" root)))
      (with-temp-file manifest
        (insert "{\n"
                "  \"name\": \"Template Armory\",\n"
                "  \"kind\": \"root\",\n"
                "  \"description\": \"Imported template.\",\n"
                "  \"settings\": {\n"
                "    \"default_provider\": \"claude\",\n"
                "    \"default_model\": \"claude-sonnet\",\n"
                "    \"default_effort\": \"high\",\n"
                "    \"default_runtime\": \"terminal\",\n"
                "    \"notifications\": true\n"
                "  },\n"
                "  \"agents\": [{\n"
                "    \"slug\": \"architect\",\n"
                "    \"name\": \"Architect\",\n"
                "    \"role\": \"Design systems\",\n"
                "    \"department\": \"Engineering\",\n"
                "    \"tags\": [\"design\", \"systems\"],\n"
                "    \"jobs\": [{\"id\": \"review\", \"name\": \"Review\", \"cron\": \"0 9 * * 1\", \"body\": \"Review architecture.\"}]\n"
                "  }],\n"
                "  \"jobs\": [{\"agent\": \"architect\", \"id\": \"daily\", \"name\": \"Daily\", \"body\": \"Check status.\"}],\n"
                "  \"pages\": [{\"title\": \"Plan\", \"path\": \"docs/plan.org\", \"tags\": [\"plan\"], \"body\": \"Template plan.\"}]\n"
                "}\n"))
      (let ((result (ogent-armory-registry-import manifest target)))
        (should (equal (plist-get result :agents) 1))
        (should (equal (plist-get result :jobs) 2))
        (should (equal (plist-get result :pages) 1)))
      (let ((settings (ogent-armory-settings-read target))
            (agent (ogent-armory-read-agent target "architect"))
            (job (ogent-armory-read-job target "architect" "review")))
        (should (equal (plist-get settings :default-provider) "claude"))
        (should (equal (plist-get agent :model) "claude-sonnet"))
        (should (member "systems" (plist-get agent :tags)))
        (should (equal (plist-get job :cron) "0 9 * * 1"))
        (should (file-exists-p (expand-file-name "docs/plan.org" target)))))))

(ert-deftest ogent-armory-backup-excludes-transient-state ()
  "Backup copies durable Org state and excludes transient process state."
  (ogent-armory-settings-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-settings-write root '(:default-provider "codex") :merge t)
    (ogent-armory-page-create root "Notes" :path "notes.org" :body "Keep me.")
    (make-directory (expand-file-name ".git" root) t)
    (with-temp-file (expand-file-name ".git/config" root)
      (insert "[core]\n"))
    (make-directory (expand-file-name ".armory-state/process" root) t)
    (with-temp-file (expand-file-name ".armory-state/process/run.log" root)
      (insert "running\n"))
    (with-temp-file (expand-file-name ".armory-state/search.el" root)
      (insert "derived\n"))
    (let ((destination (expand-file-name "backup-copy" root)))
      (ogent-armory-backup root destination)
      (should (file-exists-p (expand-file-name "index.org" destination)))
      (should (file-exists-p
               (expand-file-name ".armory-state/settings.org" destination)))
      (should (file-exists-p (expand-file-name "notes.org" destination)))
      (should-not (file-exists-p (expand-file-name ".git/config" destination)))
      (should-not (file-exists-p
                   (expand-file-name ".armory-state/process/run.log"
                                     destination)))
      (should-not (file-exists-p
                   (expand-file-name ".armory-state/search.el"
                                     destination))))))

(ert-deftest ogent-armory-help-and-demo-render ()
  "Help and demo commands produce a usable demo Armory."
  (ogent-armory-settings-test-with-temp-dir root
    (let ((result (ogent-armory-demo root)))
      (should (equal (plist-get result :agents) 2))
      (should (equal (plist-get result :jobs) 2))
      (should (equal (plist-get result :pages) 2))
      (should (file-exists-p (ogent-armory-settings-file root))))
    (let ((buffer (ogent-armory-help root)))
      (with-current-buffer buffer
        (should (string-match-p "Ogent Armory Help" (buffer-string)))
        (should (string-match-p "ogent-armory-onboard" (buffer-string)))
        (should (string-match-p "ogent-armory-demo" (buffer-string))))
      (kill-buffer buffer))))

(provide 'ogent-armory-settings-tests)

;;; ogent-armory-settings-tests.el ends here
