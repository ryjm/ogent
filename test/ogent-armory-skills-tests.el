;;; ogent-armory-skills-tests.el --- External skill discovery tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Verify read-only external packages and authoritative Org records.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-armory-skills)

(ert-deftest ogent-armory-skills-markdown-packages-keep-distinct-keys ()
  "Discover packages lazily, preserve provenance and prefer an Org override."
  (let ((root (make-temp-file "ogent-skills" t))
        (ogent-armory-skill-include-user-roots nil))
    (unwind-protect
        (progn
          (dolist (name '("review" "audit"))
            (ogent-armory--write-file
             (expand-file-name (concat ".codex/skills/" name "/SKILL.md") root)
             (concat "---\nname: " name "\ndescription: >\n  Read carefully.\n---\n"
                     "Read references/checks.md before acting.\n")))
          (let ((skills (ogent-armory-skill-list root)))
            (should (equal (mapcar (lambda (skill) (plist-get skill :key)) skills)
                           '("audit" "review")))
            (should-not (plist-get (car skills) :body))
            (should (equal (plist-get (car skills) :description) "Read carefully.")))
          (let ((skill (ogent-armory-skill-read root "review")))
            (should (string-match-p "references/checks.md" (plist-get skill :body)))
            (should (string-suffix-p "/review/" (plist-get skill :reference-root))))
          (should (string-match-p "SKILL.md" (ogent-armory-skill-bundle root '("review"))))
          (ogent-armory--write-file
           (expand-file-name ".agents/skills/review.org" root)
           "* Review\n:PROPERTIES:\n:OGENT_SKILL_KEY: review\n:END:\nOrg authority.\n")
          (should (= (length (ogent-armory-skill-list root)) 2))
          (should (string-match-p "Org authority" (ogent-armory-skill-bundle root '("review"))))
          (let ((file (ogent-armory-skill-import
                       root (expand-file-name ".codex/skills/audit/SKILL.md" root))))
            (should (string-suffix-p "/audit.org" file))
            (with-temp-buffer
              (insert-file-contents file)
              (should (string-match-p "OGENT_SKILL_SOURCE" (buffer-string))))))
      (delete-directory root t))))

(ert-deftest ogent-armory-skills-skip-symlink-packages ()
  "Do not discover external packages through symlinked directories."
  (let ((root (make-temp-file "ogent-skills" t))
        (target (make-temp-file "ogent-external" t))
        (ogent-armory-skill-include-user-roots nil))
    (unwind-protect
        (progn
          (ogent-armory--write-file (expand-file-name "SKILL.md" target) "External body")
          (make-directory (expand-file-name ".codex/skills" root) t)
          (make-symbolic-link target (expand-file-name ".codex/skills/external" root))
          (should-not (ogent-armory-skill-list root)))
      (delete-directory root t) (delete-directory target t))))

(provide 'ogent-armory-skills-tests)
;;; ogent-armory-skills-tests.el ends here
