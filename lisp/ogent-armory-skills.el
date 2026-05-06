;;; ogent-armory-skills.el --- Armory skill catalog -*- lexical-binding: t; -*-

;;; Commentary:
;; Org-backed skill discovery and bundling for Armory runs.

;;; Code:

(require 'org)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'ogent-armory)
(require 'ogent-armory-evil)

(defgroup ogent-armory-skills nil
  "Skill catalog for Org Armory."
  :group 'ogent-armory
  :prefix "ogent-armory-skill-")

(defcustom ogent-armory-skill-include-user-roots t
  "Whether skill discovery includes user-level skill directories."
  :type 'boolean
  :group 'ogent-armory-skills)

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
     (append
      `((armory-scoped . ,(expand-file-name ".agents/skills" root))
        (armory-root . ,(expand-file-name "skills" root))
        (linked-repo . ,(expand-file-name ".codex/skills" root)))
      (when ogent-armory-skill-include-user-roots
        `(,(when (getenv "CODEX_HOME")
             `(system . ,(expand-file-name "skills" (getenv "CODEX_HOME"))))
          (legacy-home . ,(expand-file-name "~/.agents/skills"))))))))

(defun ogent-armory-skill--org-files (directory)
  "Return readable Org skill files below DIRECTORY."
  (let (files)
    (cl-labels
        ((walk
          (dir)
          (when (and (file-directory-p dir)
                     (file-readable-p dir))
            (dolist (entry (directory-files
                            dir t directory-files-no-dot-files-regexp))
              (cond
               ((and (file-directory-p entry)
                     (not (file-symlink-p entry)))
                (walk entry))
               ((and (file-regular-p entry)
                     (string-match-p "\\.org\\'" entry))
                (push entry files)))))))
      (walk directory))
    (nreverse files)))

(defun ogent-armory-skill--buffer-title ()
  "Return the first heading title in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^\\*+[ \t]+\\(.+?\\)[ \t]*$" nil t)
      (string-trim (match-string 1)))))

(defun ogent-armory-skill--buffer-property (property)
  "Return Org drawer PROPERTY from the first heading."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^\\*+[ \t]+.+$" nil t)
      (forward-line 1)
      (when (looking-at-p "[ \t]*:PROPERTIES:[ \t]*$")
        (let ((end (save-excursion
                     (and (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
                          (point)))))
          (when end
            (let ((regexp (format "^[ \t]*:%s:[ \t]*\\(.+?\\)[ \t]*$"
                                  (regexp-quote property))))
              (when (re-search-forward regexp end t)
                (string-trim (match-string 1))))))))))

(defun ogent-armory-skill--buffer-body ()
  "Return the body text under the first heading in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (if (not (re-search-forward "^\\*+[ \t]+.+$" nil t))
        (string-trim (buffer-string))
      (forward-line 1)
      (when (looking-at-p "[ \t]*:PROPERTIES:[ \t]*$")
        (when (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
          (forward-line 1)))
      (string-trim (buffer-substring-no-properties (point) (point-max))))))

(defun ogent-armory-skill--read-metadata (file origin)
  "Read skill FILE metadata for ORIGIN without loading the full body."
  (with-temp-buffer
    (insert-file-contents file nil 0 4096)
    (let ((title (or (ogent-armory-skill--buffer-title)
                     (file-name-base file)))
          (key (ogent-armory-skill--buffer-property "OGENT_SKILL_KEY")))
      (list :key (ogent-armory-skill--slug
                  (or (ogent-armory--blank-to-nil key)
                      (file-name-base file)))
            :title title
            :origin origin
            :path file))))

(defun ogent-armory-skill--direct-file (directory key)
  "Return the direct Org skill file for KEY below DIRECTORY."
  (expand-file-name (concat (ogent-armory-skill--slug key) ".org")
                    directory))

(defun ogent-armory-skill--direct-match (directory key origin)
  "Return direct skill KEY metadata under DIRECTORY for ORIGIN."
  (let ((file (ogent-armory-skill--direct-file directory key)))
    (when (file-readable-p file)
      (let ((skill (ogent-armory-skill--read-metadata file origin)))
        (when (equal (plist-get skill :key)
                     (ogent-armory-skill--slug key))
          skill)))))

(defun ogent-armory-skill-list (directory)
  "Return skill metadata records for DIRECTORY."
  (let (skills)
    (dolist (root (ogent-armory-skill--roots directory))
      (let ((origin (car root))
            (dir (cdr root)))
        (dolist (file (ogent-armory-skill--org-files dir))
          (push (ogent-armory-skill--read-metadata file origin)
                skills))))
    (seq-sort-by (lambda (skill)
                   (plist-get skill :key))
                 #'string<
                 skills)))

(defun ogent-armory-skill--find (directory key)
  "Return the first skill metadata record matching KEY under DIRECTORY."
  (let ((wanted (ogent-armory-skill--slug key)))
    (catch 'skill
      (dolist (root (ogent-armory-skill--roots directory))
        (let ((origin (car root))
              (dir (cdr root)))
          (when-let ((skill (ogent-armory-skill--direct-match
                             dir wanted origin)))
            (throw 'skill skill))
          (dolist (file (ogent-armory-skill--org-files dir))
            (let ((skill (ogent-armory-skill--read-metadata file origin)))
              (when (equal (plist-get skill :key) wanted)
                (throw 'skill skill)))))))))

(defun ogent-armory-skill-read (directory key)
  "Read skill KEY under DIRECTORY with body text."
  (let ((skill (ogent-armory-skill--find directory key)))
    (unless skill
      (user-error "Armory skill not found: %s" key))
    (with-temp-buffer
      (insert-file-contents (plist-get skill :path))
      (append skill
              (list :body (ogent-armory-skill--buffer-body))))))

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

(defun ogent-armory-skills--evil-local-keys ()
  "Install local Evil keys for Armory skills."
  (ogent-armory-evil-install-local-bindings ogent-armory-skills-mode-map))

(defun ogent-armory-skills--setup-evil ()
  "Set up Evil integration for Armory skills."
  (ogent-armory-evil-setup-mode
   'ogent-armory-skills-mode
   ogent-armory-skills-mode-map
   'ogent-armory-skills-mode-hook
   #'ogent-armory-skills--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-skills--setup-evil))

(provide 'ogent-armory-skills)

;;; ogent-armory-skills.el ends here
