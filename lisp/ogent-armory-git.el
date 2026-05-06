;;; ogent-armory-git.el --- Armory git commands -*- lexical-binding: t; -*-

;;; Commentary:
;; Magit/VC-aware git wrappers for Armory roots and page files.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'vc-git)
(require 'ogent-armory)
(require 'ogent-armory-evil)
(require 'ogent-armory-data)

(defgroup ogent-armory-git nil
  "Git commands for Armory roots."
  :group 'ogent-armory)

(defcustom ogent-armory-git-buffer-name-format "*ogent-armory-git:%s*"
  "Format string used for Armory git status buffers."
  :type 'string
  :group 'ogent-armory-git)

(defvar-local ogent-armory-git--root nil
  "Git root shown by the current Armory git buffer.")

(declare-function magit-status "ext:magit-status")
(declare-function magit-log-buffer-file "ext:magit-log")
(declare-function magit-diff-buffer-file "ext:magit-diff")

(defun ogent-armory-git--base-directory (path)
  "Return a directory suitable for git discovery from PATH."
  (let ((expanded (expand-file-name path)))
    (file-name-as-directory
     (if (file-directory-p expanded)
         expanded
       (or (file-name-directory expanded) default-directory)))))

(defun ogent-armory-git-root (directory)
  "Return the git root for DIRECTORY or nil."
  (when-let ((root (locate-dominating-file
                    (ogent-armory-git--base-directory directory)
                    ".git")))
    (directory-file-name (file-truename root))))

(defun ogent-armory-git--require-root (directory)
  "Return git root for DIRECTORY or signal a user-facing error."
  (or (ogent-armory-git-root directory)
      (user-error "Armory is not inside a git repository: %s" directory)))

(defun ogent-armory-git--call (root &rest args)
  "Run git in ROOT with ARGS and return output."
  (let ((buffer (generate-new-buffer " *ogent-armory-git*")))
    (unwind-protect
        (let ((exit (apply #'process-file "git" nil buffer nil
                           "-C" root args))
              (output (with-current-buffer buffer
                        (string-trim-right (buffer-string)))))
          (unless (zerop exit)
            (user-error "git %s failed: %s"
                        (string-join args " ")
                        output))
          output)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ogent-armory-git--porcelain-record (root line)
  "Return a status plist for porcelain LINE under ROOT."
  (when (string-match "\\`\\(.\\)\\(.\\) \\(.+\\)\\'" line)
    (let* ((index (match-string 1 line))
           (worktree (match-string 2 line))
           (path-text (match-string 3 line))
           (path (if (string-match " -> \\(.+\\)\\'" path-text)
                     (match-string 1 path-text)
                   path-text)))
      (list :index index
            :worktree worktree
            :status (string-trim (concat index worktree))
            :relative path
            :path (expand-file-name path root)))))

(defun ogent-armory-git-status-data (directory)
  "Return porcelain git status records for DIRECTORY."
  (let* ((root (ogent-armory-git--require-root directory))
         (output (ogent-armory-git--call root "status" "--porcelain=v1"))
         records)
    (dolist (line (split-string output "\n" t))
      (when-let ((record (ogent-armory-git--porcelain-record root line)))
        (push record records)))
    (nreverse records)))

(defun ogent-armory-git-dirty-count (directory)
  "Return the number of dirty git paths for DIRECTORY."
  (length (ogent-armory-git-status-data directory)))

(defun ogent-armory-git--show-buffer (name root content mode)
  "Display CONTENT in NAME with MODE and ROOT as `default-directory'."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert content)
        (funcall mode)
        (setq default-directory (file-name-as-directory root))
        (setq buffer-read-only t)))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun ogent-armory-git-log-page (file)
  "Show git log for Armory FILE."
  (interactive "fArmory page: ")
  (if (and (fboundp 'magit-log-buffer-file)
           (called-interactively-p 'interactive))
      (magit-log-buffer-file)
    (let* ((root (ogent-armory-git--require-root file))
           (relative (file-relative-name (expand-file-name file) root))
           (output (ogent-armory-git--call
                    root
                    "log"
                    "--oneline"
                    "--decorate"
                    "--"
                    relative)))
      (ogent-armory-git--show-buffer
       (format "*ogent-armory-git-log:%s*" relative)
       root
       (concat output "\n")
       #'special-mode))))

;;;###autoload
(defun ogent-armory-git-diff-page (file)
  "Show git diff for Armory FILE."
  (interactive "fArmory page: ")
  (if (and (fboundp 'magit-diff-buffer-file)
           (called-interactively-p 'interactive))
      (magit-diff-buffer-file)
    (let* ((root (ogent-armory-git--require-root file))
           (relative (file-relative-name (expand-file-name file) root))
           (output (ogent-armory-git--call root "diff" "--" relative)))
      (ogent-armory-git--show-buffer
       (format "*ogent-armory-git-diff:%s*" relative)
       root
       (concat output "\n")
       #'diff-mode))))

;;;###autoload
(defun ogent-armory-git-restore-page (file &optional force)
  "Restore Armory FILE from git.
When FORCE is non-nil, skip confirmation."
  (interactive "fArmory page: ")
  (let* ((root (ogent-armory-git--require-root file))
         (relative (file-relative-name (expand-file-name file) root)))
    (when (or force
              (yes-or-no-p (format "Restore %s from git? " relative)))
      (ogent-armory-git--call root "restore" "--" relative)
      relative)))

;;;###autoload
(defun ogent-armory-git-commit (directory message &optional files)
  "Commit FILES under DIRECTORY with MESSAGE.
When FILES is nil, all dirty paths are staged."
  (interactive
   (let ((root (or (ogent-armory-find-root)
                   (read-directory-name "Armory root: "))))
     (list root (read-string "Commit message: ") nil)))
  (let* ((root (ogent-armory-git--require-root directory))
         (paths (or files
                    (mapcar (lambda (record)
                              (plist-get record :relative))
                            (ogent-armory-git-status-data root)))))
    (unless paths
      (user-error "No Armory git changes to commit"))
    (apply #'ogent-armory-git--call root "add" "--" paths)
    (ogent-armory-git--call root "commit" "-m" message)
    message))

;;;###autoload
(defun ogent-armory-git-pull (directory)
  "Pull the git repository containing DIRECTORY with fast-forward only."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let ((root (ogent-armory-git--require-root directory)))
    (ogent-armory-git--call root "pull" "--ff-only")))

(defvar ogent-armory-git-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'ogent-armory-git-refresh)
    (define-key map (kbd "C-c g") #'ogent-armory-git-refresh)
    (define-key map "c" #'ogent-armory-git-commit-from-status)
    (define-key map (kbd "C-c c") #'ogent-armory-git-commit-from-status)
    (define-key map "d" #'ogent-armory-git-diff-at-point)
    (define-key map (kbd "C-c d") #'ogent-armory-git-diff-at-point)
    (define-key map "l" #'ogent-armory-git-log-at-point)
    (define-key map (kbd "C-c l") #'ogent-armory-git-log-at-point)
    (define-key map "R" #'ogent-armory-git-restore-at-point)
    (define-key map (kbd "C-c r") #'ogent-armory-git-restore-at-point)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-git-mode'.")

(define-derived-mode ogent-armory-git-mode tabulated-list-mode "Armory-Git"
  "Major mode for Armory git status."
  :group 'ogent-armory-git
  (setq-local tabulated-list-format
              [("Status" 8 t)
               ("Path" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-armory-git-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-git--entry (record)
  "Return a tabulated entry for git status RECORD."
  (list record
        (vector (or (plist-get record :status) "")
                (plist-get record :relative))))

(defun ogent-armory-git--entries ()
  "Return git status entries for the current buffer."
  (let ((records (ogent-armory-git-status-data ogent-armory-git--root)))
    (if records
        (mapcar #'ogent-armory-git--entry records)
      (list (list nil (vector "" "Working tree clean"))))))

;;;###autoload
(defun ogent-armory-git-status (&optional directory)
  "Open Armory git status for DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-git--require-root
                (or directory default-directory)))
         (buffer (get-buffer-create
                  (format ogent-armory-git-buffer-name-format
                          (file-name-nondirectory root)))))
    (if (and (called-interactively-p 'interactive)
             (fboundp 'magit-status))
        (magit-status root)
      (with-current-buffer buffer
        (ogent-armory-git-mode)
        (setq ogent-armory-git--root root)
        (setq default-directory (file-name-as-directory root))
        (setq tabulated-list-entries #'ogent-armory-git--entries)
        (tabulated-list-print t))
      (pop-to-buffer buffer)
      buffer)))

(defun ogent-armory-git-refresh (&rest _)
  "Refresh the current Armory git status buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-armory-git--item ()
  "Return the git status item at point."
  (or (tabulated-list-get-id)
      (user-error "No Armory git record at point")))

(defun ogent-armory-git-diff-at-point ()
  "Show git diff for the file at point."
  (interactive)
  (ogent-armory-git-diff-page
   (plist-get (ogent-armory-git--item) :path)))

(defun ogent-armory-git-log-at-point ()
  "Show git log for the file at point."
  (interactive)
  (ogent-armory-git-log-page
   (plist-get (ogent-armory-git--item) :path)))

(defun ogent-armory-git-restore-at-point ()
  "Restore the file at point from git."
  (interactive)
  (ogent-armory-git-restore-page
   (plist-get (ogent-armory-git--item) :path)))

(defun ogent-armory-git-commit-from-status ()
  "Commit all dirty paths from the current Armory git status buffer."
  (interactive)
  (ogent-armory-git-commit
   ogent-armory-git--root
   (read-string "Commit message: "))
  (ogent-armory-git-refresh))

(defun ogent-armory-git--evil-local-keys ()
  "Install local Evil keys for Armory git."
  (ogent-armory-evil-install-local-bindings ogent-armory-git-mode-map))

(defun ogent-armory-git--setup-evil ()
  "Set up Evil integration for Armory git."
  (ogent-armory-evil-setup-mode
   'ogent-armory-git-mode
   ogent-armory-git-mode-map
   'ogent-armory-git-mode-hook
   #'ogent-armory-git--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-git--setup-evil))

(provide 'ogent-armory-git)

;;; ogent-armory-git.el ends here
