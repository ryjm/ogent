;;; ogent-cabinet-skills.el --- Cabinet skill catalog -*- lexical-binding: t; -*-

;;; Commentary:
;; Org-backed skill discovery and bundling for Cabinet runs.

;;; Code:

(require 'org)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'ogent-cabinet)
(require 'ogent-cabinet-evil)

(defgroup ogent-cabinet-skills nil
  "Skill catalog for Org Cabinet."
  :group 'ogent-cabinet
  :prefix "ogent-cabinet-skill-")

(defcustom ogent-cabinet-skill-include-user-roots t
  "Whether skill discovery includes user-level skill directories."
  :type 'boolean
  :group 'ogent-cabinet-skills)

(defvar ogent-cabinet-skills-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-cabinet-skill-open)
    (define-key map "g" #'ogent-cabinet-skills-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-skills-mode'.")

(defvar-local ogent-cabinet-skills--root nil
  "Cabinet root for the current skills buffer.")

(define-derived-mode ogent-cabinet-skills-mode tabulated-list-mode
  "Cabinet-Skills"
  "Major mode for Cabinet skill catalog entries."
  :group 'ogent-cabinet-skills
  (setq-local tabulated-list-format
              [("Key" 24 t)
               ("Title" 28 t)
               ("Origin" 16 t)
               ("Path" 42 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-cabinet-skills-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-skill--slug (value)
  "Return VALUE as a skill key."
  (ogent-cabinet--slug value "skill"))

(defun ogent-cabinet-skill--roots (directory)
  "Return skill roots for DIRECTORY with origins."
  (let ((root (ogent-cabinet--directory directory)))
    (delq
     nil
     (append
      `((cabinet-scoped . ,(expand-file-name ".agents/skills" root))
        (cabinet-root . ,(expand-file-name "skills" root))
        (linked-repo . ,(expand-file-name ".codex/skills" root)))
      (when ogent-cabinet-skill-include-user-roots
        `(,(when (getenv "CODEX_HOME")
             `(system . ,(expand-file-name "skills" (getenv "CODEX_HOME"))))
          (legacy-home . ,(expand-file-name "~/.agents/skills"))))))))

(defun ogent-cabinet-skill--org-files (directory)
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

(defun ogent-cabinet-skill--buffer-title ()
  "Return the first heading title in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^\\*+[ \t]+\\(.+?\\)[ \t]*$" nil t)
      (string-trim (match-string 1)))))

(defun ogent-cabinet-skill--buffer-property (property)
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

(defun ogent-cabinet-skill--buffer-body ()
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

(defun ogent-cabinet-skill--read-metadata (file origin)
  "Read skill FILE metadata for ORIGIN without loading the full body."
  (with-temp-buffer
    (insert-file-contents file nil 0 4096)
    (let ((title (or (ogent-cabinet-skill--buffer-title)
                     (file-name-base file)))
          (key (ogent-cabinet-skill--buffer-property "OGENT_SKILL_KEY")))
      (list :key (ogent-cabinet-skill--slug
                  (or (ogent-cabinet--blank-to-nil key)
                      (file-name-base file)))
            :title title
            :origin origin
            :path file))))

(defun ogent-cabinet-skill-list (directory)
  "Return skill metadata records for DIRECTORY."
  (let (skills)
    (dolist (root (ogent-cabinet-skill--roots directory))
      (let ((origin (car root))
            (dir (cdr root)))
        (dolist (file (ogent-cabinet-skill--org-files dir))
          (push (ogent-cabinet-skill--read-metadata file origin)
                skills))))
    (seq-sort-by (lambda (skill)
                   (plist-get skill :key))
                 #'string<
                 skills)))

(defun ogent-cabinet-skill--find (directory key)
  "Return the first skill metadata record matching KEY under DIRECTORY."
  (let ((wanted (ogent-cabinet-skill--slug key)))
    (catch 'skill
      (dolist (root (ogent-cabinet-skill--roots directory))
        (let ((origin (car root))
              (dir (cdr root)))
          (dolist (file (ogent-cabinet-skill--org-files dir))
            (let ((skill (ogent-cabinet-skill--read-metadata file origin)))
              (when (equal (plist-get skill :key) wanted)
                (throw 'skill skill)))))))))

(defun ogent-cabinet-skill-read (directory key)
  "Read skill KEY under DIRECTORY with body text."
  (let ((skill (ogent-cabinet-skill--find directory key)))
    (unless skill
      (user-error "Cabinet skill not found: %s" key))
    (with-temp-buffer
      (insert-file-contents (plist-get skill :path))
      (append skill
              (list :body (ogent-cabinet-skill--buffer-body))))))

(defun ogent-cabinet-skill-import (directory file &optional key origin)
  "Import skill FILE into DIRECTORY and return the new skill path.
KEY overrides the derived skill key.  ORIGIN records provenance."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))
         (read-file-name "Skill file: ")))
  (let* ((root (ogent-cabinet--directory directory))
         (skill-key (ogent-cabinet-skill--slug
                     (or key (file-name-base file))))
         (target (expand-file-name
                  (concat skill-key ".org")
                  (expand-file-name ".agents/skills" root)))
         (body (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string))))
    (make-directory (file-name-directory target) t)
    (ogent-cabinet--write-file
     target
     (concat "#+title: " skill-key "\n\n"
             "* " skill-key "\n"
             (ogent-cabinet--format-properties
              `(("OGENT_SKILL" . t)
                ("OGENT_SKILL_KEY" . ,skill-key)
                ("OGENT_SKILL_ORIGIN" . ,(or origin "import"))))
             "\n"
             (string-trim body)
             "\n"))
    target))

(defun ogent-cabinet-skill-bundle (directory keys)
  "Return skill instructions for KEYS under DIRECTORY."
  (string-join
   (mapcar
    (lambda (key)
      (let ((skill (ogent-cabinet-skill-read directory key)))
        (format "Skill %s (%s, %s):\n%s"
                (plist-get skill :key)
                (plist-get skill :origin)
                (plist-get skill :path)
                (string-trim (or (plist-get skill :body) "")))))
    keys)
   "\n\n"))

(defun ogent-cabinet-skills--entry (skill)
  "Return tabulated entry for SKILL."
  (list skill
        (vector
         (plist-get skill :key)
         (plist-get skill :title)
         (symbol-name (plist-get skill :origin))
         (plist-get skill :path))))

(defun ogent-cabinet-skills--entries ()
  "Return skill entries for the current buffer."
  (mapcar #'ogent-cabinet-skills--entry
          (ogent-cabinet-skill-list ogent-cabinet-skills--root)))

;;;###autoload
(defun ogent-cabinet-skills (&optional directory)
  "Open Cabinet skill catalog for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet--directory directory))
         (buffer (get-buffer-create
                  (format "*ogent-cabinet-skills: %s*"
                          (abbreviate-file-name root)))))
    (with-current-buffer buffer
      (ogent-cabinet-skills-mode)
      (setq ogent-cabinet-skills--root root)
      (setq tabulated-list-entries #'ogent-cabinet-skills--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-skills-refresh (&rest _)
  "Refresh the Cabinet skills buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-skill-open ()
  "Open the skill at point."
  (interactive)
  (let ((skill (or (tabulated-list-get-id)
                   (user-error "No Cabinet skill at point"))))
    (find-file (plist-get skill :path))))

(defun ogent-cabinet-skills--evil-local-keys ()
  "Install local Evil keys for Cabinet skills."
  (ogent-cabinet-evil-install-local-bindings ogent-cabinet-skills-mode-map))

(defun ogent-cabinet-skills--setup-evil ()
  "Set up Evil integration for Cabinet skills."
  (ogent-cabinet-evil-setup-mode
   'ogent-cabinet-skills-mode
   ogent-cabinet-skills-mode-map
   'ogent-cabinet-skills-mode-hook
   #'ogent-cabinet-skills--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-cabinet-skills--setup-evil))

(provide 'ogent-cabinet-skills)

;;; ogent-cabinet-skills.el ends here
