;;; ogent-cabinet-compose-tests.el --- Tests for Cabinet composer -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for mentions, attachment staging, skill catalogs, and composer plans.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-cabinet)
(require 'ogent-cabinet-compose)
(require 'ogent-cabinet-conversations)
(require 'ogent-cabinet-skills)

(defmacro ogent-cabinet-compose-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary Cabinet directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (file-truename (make-temp-file "ogent-cabinet-compose-" t))))
     (unwind-protect
         (let ((ogent-cabinet-skill-include-user-roots nil))
           ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-cabinet-compose-test--seed (root)
  "Create a Cabinet fixture in ROOT."
  (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
  (ogent-cabinet-write-agent
   root
   '(:slug "cto"
     :name "CTO"
     :role "Architecture"
     :provider "codex"
     :active t)
   "Keep the architecture clear.")
  (ogent-cabinet-write-job
   root "cto"
   '(:id "weekly-review"
     :name "Weekly Review"
     :enabled t)
   "Review the week.")
  (let ((page (expand-file-name "notes/plan.org" root))
        (skill (expand-file-name ".agents/skills/review.org" root)))
    (ogent-cabinet--write-file page "#+title: Plan\n\n* Plan\nShip it.\n")
    (ogent-cabinet--write-file
     skill
     (concat "#+title: Review Skill\n\n"
             "* Review Skill\n"
             ":PROPERTIES:\n"
             ":OGENT_SKILL: t\n"
             ":OGENT_SKILL_KEY: review\n"
             ":END:\n\n"
             "Read carefully.\n")))
  (ogent-cabinet-conversation-create
   root
   '(:id "conv"
     :agent "cto"
     :title "Prior Review"
     :status "done"))
  (ogent-cabinet-conversation-append-turn
   root "conv" "agent" "Prior answer."
   :ts "2026-05-06T10:00:00Z"))

(ert-deftest ogent-cabinet-compose-resolves-all-mention-types ()
  "Mentions resolve across agents, pages, skills, jobs, and conversations."
  (ogent-cabinet-compose-test-with-temp-dir root
    (ogent-cabinet-compose-test--seed root)
    (let* ((mentions (ogent-cabinet-compose-mentions
                      root
                      "Use @agent:cto @page:notes/plan.org @skill:review @job:weekly-review @conversation:conv."))
           (types (mapcar (lambda (mention)
                            (plist-get mention :type))
                          mentions)))
      (dolist (type '(agent page skill job conversation))
        (should (member type types)))
      (should (string-match-p "Ship it"
                              (plist-get
                               (seq-find (lambda (mention)
                                           (eq (plist-get mention :type) 'page))
                                         mentions)
                               :body))))))

(ert-deftest ogent-cabinet-compose-stages-and-finalizes-attachments ()
  "Attachment staging moves files into the canonical conversation folder."
  (ogent-cabinet-compose-test-with-temp-dir root
    (ogent-cabinet-compose-test--seed root)
    (let ((file (expand-file-name "artifact.txt" root)))
      (ogent-cabinet--write-file file "hello\n")
      (let* ((staged (ogent-cabinet-conversation-stage-attachments
                      root (list file)))
             (pending (plist-get staged :pending-id))
             (paths (ogent-cabinet-conversation-finalize-attachments
                     root pending "conv")))
        (should (= 1 (length paths)))
        (should (file-exists-p (expand-file-name (car paths) root)))
        (should-not (file-exists-p
                     (ogent-cabinet-conversation-pending-directory
                      root pending)))))))

(ert-deftest ogent-cabinet-compose-skill-catalog-loads-origins-on-demand ()
  "Skill catalog lists origins and loads bodies only when read."
  (ogent-cabinet-compose-test-with-temp-dir root
    (ogent-cabinet-compose-test--seed root)
    (let ((root-skill (expand-file-name "skills/root-review.org" root)))
      (ogent-cabinet--write-file
       root-skill
       "#+title: Root Review\n\n* Root Review\n:PROPERTIES:\n:OGENT_SKILL_KEY: root-review\n:END:\n\nRoot skill.\n")
      (let ((skills (ogent-cabinet-skill-list root)))
        (should (seq-find (lambda (skill)
                            (and (equal (plist-get skill :key) "review")
                                 (eq (plist-get skill :origin)
                                     'cabinet-scoped)))
                          skills))
        (should (seq-find (lambda (skill)
                            (and (equal (plist-get skill :key) "root-review")
                                 (eq (plist-get skill :origin)
                                     'cabinet-root)))
                          skills))
        (should-not (plist-get (car skills) :body)))
      (let ((skill (ogent-cabinet-skill-read root "review")))
        (should (string-match-p "Read carefully"
                                (plist-get skill :body)))))))

(ert-deftest ogent-cabinet-compose-skill-read-prefers-direct-key-file ()
  "Skill reads prefer canonical key files before nested aliases."
  (ogent-cabinet-compose-test-with-temp-dir root
    (ogent-cabinet-compose-test--seed root)
    (let ((alias (expand-file-name ".agents/skills/nested/alias.org" root)))
      (ogent-cabinet--write-file
       alias
       "#+title: Nested Alias\n\n* Nested Alias\n:PROPERTIES:\n:OGENT_SKILL_KEY: review\n:END:\n\nNested alias.\n")
      (let ((skill (ogent-cabinet-skill-read root "review")))
        (should (string-suffix-p ".agents/skills/review.org"
                                 (plist-get skill :path)))
        (should (string-match-p "Read carefully"
                                (plist-get skill :body)))))))

(ert-deftest ogent-cabinet-compose-skill-read-stops-after-first-match ()
  "Skill reads return cabinet-local matches without walking later roots."
  (let* ((codex-home (file-truename
                      (make-temp-file "ogent-cabinet-codex-home-" t)))
         (blocked-root (expand-file-name "skills/blocked" codex-home)))
    (unwind-protect
        (ogent-cabinet-compose-test-with-temp-dir root
          (ogent-cabinet-compose-test--seed root)
          (make-directory blocked-root t)
          (set-file-modes blocked-root #o000)
          (let ((process-environment
                 (cons (concat "CODEX_HOME=" codex-home)
                       process-environment))
                (ogent-cabinet-skill-include-user-roots t))
            (let ((skill (ogent-cabinet-skill-read root "review")))
              (should (equal (plist-get skill :key) "review"))
              (should (string-match-p "Read carefully"
                                      (plist-get skill :body))))))
      (when (file-directory-p blocked-root)
        (ignore-errors
          (set-file-modes blocked-root #o700)))
      (when (file-directory-p codex-home)
        (delete-directory codex-home t)))))

(ert-deftest ogent-cabinet-compose-prompt-includes-context ()
  "Prompt builder includes mention, attachment, and skill context."
  (ogent-cabinet-compose-test-with-temp-dir root
    (ogent-cabinet-compose-test--seed root)
    (let* ((mentions (ogent-cabinet-compose-mentions
                      root "Review @agent:cto and @skill:review"))
           (prompt (ogent-cabinet-compose-build-prompt
                    root
                    (list :instruction "Review @agent:cto and @skill:review"
                          :mentions mentions
                          :attachment-paths '("file.txt")
                          :skills '("review")))))
      (should (string-match-p "Resolved mentions" prompt))
      (should (string-match-p "Keep the architecture clear" prompt))
      (should (string-match-p "file.txt" prompt))
      (should (string-match-p "Skill instructions" prompt))
      (should (string-match-p "Read carefully" prompt)))))

(ert-deftest ogent-cabinet-compose-builds-runner-plan-with-metadata ()
  "Shared compose command passes mentions, skills, and runtime into runner plans."
  (ogent-cabinet-compose-test-with-temp-dir root
    (ogent-cabinet-compose-test--seed root)
    (let (captured)
      (cl-letf (((symbol-function 'ogent-cabinet-runtime-picker)
                 (lambda (&optional _prompt)
                   '(:adapter-id "codex-cli" :runtime-mode terminal)))
                ((symbol-function 'ogent-cabinet-runner--confirm)
                 (lambda (_plan) t))
                ((symbol-function 'ogent-cabinet-runner-start)
                 (lambda (plan)
                   (setq captured plan)
                   :started)))
        (ogent-cabinet-compose
         root "cto" "Review @agent:cto"
         :skills '("review")))
      (should (equal (plist-get captured :skills) '("review")))
      (should (eq (plist-get captured :runtime-mode) 'terminal))
      (should (plist-get captured :mentions))
      (should (string-match-p "Resolved mentions"
                              (plist-get captured :prompt))))))

(provide 'ogent-cabinet-compose-tests)

;;; ogent-cabinet-compose-tests.el ends here
