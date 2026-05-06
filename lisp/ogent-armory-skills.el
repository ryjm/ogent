;;; ogent-armory-skills.el --- Armory skill catalog -*- lexical-binding: t; -*-

;;; Commentary:
;; Org-backed skill discovery and bundling for Armory runs.

;;; Code:

(require 'org)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'ogent-armory)

(defgroup ogent-armory-skills nil
  "Skill catalog for Org Armory."
  :group 'ogent-armory
  :prefix "ogent-armory-skill-")

(defvar ogent-armory-skills-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-armory-skill-open)
    (define-key map "g" #'ogent-armory-skills-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-skills-mode'.")

(defvar-local ogent-armory-skills--root nil
  "Armory root for the current skills buffer.")

(define-derived-mode ogent-armory-skills-mode tabulated-list-mode
  "Armory-Skills"
  "Major mode for Armory skill catalog entries."
  :group 'ogent-armory-skills
  (setq-local tabulated-list-format
              [("Key" 24 t)
               ("Title" 28 t)
               ("Origin" 16 t)
               ("Path" 42 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-armory-skills-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-skill--slug (value)
  "Return VALUE as a skill key."
  (ogent-armory--slug value "skill"))

(defun ogent-armory-skill--roots (directory)
  "Return skill roots for DIRECTORY with origins."
  (let ((root (ogent-armory--directory directory)))
    (delq
     nil
     `((armory-scoped . ,(expand-file-name ".agents/skills" root))
       (armory-root . ,(expand-file-name "skills" root))
       (linked-repo . ,(expand-file-name ".codex/skills" root))
       ,(when (getenv "CODEX_HOME")
          `(system . ,(expand-file-name "skills" (getenv "CODEX_HOME"))))
       (legacy-home . ,(expand-file-name "~/.agents/skills"))))))

(defun ogent-armory-skill--read-metadata (file origin)
  "Read skill FILE metadata for ORIGIN without loading the full body."
  (with-temp-buffer
    (insert-file-contents file nil 0 4096)
    (org-mode)
    (let ((title (or (ogent-armory--first-heading-title)
                     (file-name-base file))))
      (list :key (ogent-armory-skill--slug
                  (or (ogent-armory--blank-to-nil
                       (org-entry-get nil "OGENT_SKILL_KEY"))
                      (file-name-base file)))
            :title title
            :origin origin
            :path file))))

(defun ogent-armory-skill-list (directory)
  "Return skill metadata records for DIRECTORY."
  (let (skills)
    (dolist (root (ogent-armory-skill--roots directory))
      (let ((origin (car root))
            (dir (cdr root)))
        (when (file-directory-p dir)
          (dolist (file (directory-files-recursively dir "\\.org\\'"))
            (push (ogent-armory-skill--read-metadata file origin)
                  skills)))))
    (seq-sort-by (lambda (skill)
                   (plist-get skill :key))
                 #'string<
                 skills)))

(defun ogent-armory-skill-read (directory key)
  "Read skill KEY under DIRECTORY with body text."
  (let ((skill (seq-find
                (lambda (record)
                  (equal (plist-get record :key)
                         (ogent-armory-skill--slug key)))
                (ogent-armory-skill-list directory))))
    (unless skill
      (user-error "Armory skill not found: %s" key))
    (with-temp-buffer
      (insert-file-contents (plist-get skill :path))
      (org-mode)
      (ogent-armory--first-heading-title)
      (append skill
              (list :body (ogent-armory--heading-body))))))

(defun ogent-armory-skill-import (directory file &optional key origin)
  "Import skill FILE into DIRECTORY and return the new skill path.
KEY overrides the derived skill key.  ORIGIN records provenance."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))
         (read-file-name "Skill file: ")))
  (let* ((root (ogent-armory--directory directory))
         (skill-key (ogent-armory-skill--slug
                     (or key (file-name-base file))))
         (target (expand-file-name
                  (concat skill-key ".org")
                  (expand-file-name ".agents/skills" root)))
         (body (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string))))
    (make-directory (file-name-directory target) t)
    (ogent-armory--write-file
     target
     (concat "#+title: " skill-key "\n\n"
             "* " skill-key "\n"
             (ogent-armory--format-properties
              `(("OGENT_SKILL" . t)
                ("OGENT_SKILL_KEY" . ,skill-key)
                ("OGENT_SKILL_ORIGIN" . ,(or origin "import"))))
             "\n"
             (string-trim body)
             "\n"))
    target))

(defun ogent-armory-skill-bundle (directory keys)
  "Return skill instructions for KEYS under DIRECTORY."
  (string-join
   (mapcar
    (lambda (key)
      (let ((skill (ogent-armory-skill-read directory key)))
        (format "Skill %s (%s, %s):\n%s"
                (plist-get skill :key)
                (plist-get skill :origin)
                (plist-get skill :path)
                (string-trim (or (plist-get skill :body) "")))))
    keys)
   "\n\n"))

(defun ogent-armory-skills--entry (skill)
  "Return tabulated entry for SKILL."
  (list skill
        (vector
         (plist-get skill :key)
         (plist-get skill :title)
         (symbol-name (plist-get skill :origin))
         (plist-get skill :path))))

(defun ogent-armory-skills--entries ()
  "Return skill entries for the current buffer."
  (mapcar #'ogent-armory-skills--entry
          (ogent-armory-skill-list ogent-armory-skills--root)))

;;;###autoload
(defun ogent-armory-skills (&optional directory)
  "Open Armory skill catalog for DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory--directory directory))
         (buffer (get-buffer-create
                  (format "*ogent-armory-skills: %s*"
                          (abbreviate-file-name root)))))
    (with-current-buffer buffer
      (ogent-armory-skills-mode)
      (setq ogent-armory-skills--root root)
      (setq tabulated-list-entries #'ogent-armory-skills--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-skills-refresh (&rest _)
  "Refresh the Armory skills buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-armory-skill-open ()
  "Open the skill at point."
  (interactive)
  (let ((skill (or (tabulated-list-get-id)
                   (user-error "No Armory skill at point"))))
    (find-file (plist-get skill :path))))

(provide 'ogent-armory-skills)

;;; ogent-armory-skills.el ends here
