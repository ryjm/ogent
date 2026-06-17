;;; ogent-cabinet-git.el --- Cabinet git commands -*- lexical-binding: t; -*-

;;; Commentary:
;; Magit/VC-aware git wrappers for Cabinet roots and page files.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'vc-git)
(require 'ogent-cabinet)
(require 'ogent-cabinet-evil)
(require 'ogent-cabinet-data)

(defgroup ogent-cabinet-git nil
  "Git commands for Cabinet roots."
  :group 'ogent-cabinet)

(defcustom ogent-cabinet-git-buffer-name-format "*ogent-cabinet-git:%s*"
  "Format string used for Cabinet git status buffers."
  :type 'string
  :group 'ogent-cabinet-git)

(defvar-local ogent-cabinet-git--root nil
  "Git root shown by the current Cabinet git buffer.")

(declare-function magit-status "ext:magit-status")
(declare-function magit-log-buffer-file "ext:magit-log")
(declare-function magit-diff-buffer-file "ext:magit-diff")

(defun ogent-cabinet-git--base-directory (path)
  "Return a directory suitable for git discovery from PATH."
  (let ((expanded (expand-file-name path)))
    (file-name-as-directory
     (if (file-directory-p expanded)
         expanded
       (or (file-name-directory expanded) default-directory)))))

(defun ogent-cabinet-git-root (directory)
  "Return the git root for DIRECTORY or nil."
  (when-let ((root (locate-dominating-file
                    (ogent-cabinet-git--base-directory directory)
                    ".git")))
    (directory-file-name (file-truename root))))

(defun ogent-cabinet-git--require-root (directory)
  "Return git root for DIRECTORY or signal a user-facing error."
  (or (ogent-cabinet-git-root directory)
      (user-error "Cabinet is not inside a git repository: %s" directory)))

(defun ogent-cabinet-git--call (root &rest args)
  "Run git in ROOT with ARGS and return output."
  (let ((buffer (generate-new-buffer " *ogent-cabinet-git*")))
    (unwind-protect
        (let ((exit (apply #'process-file "git" nil buffer nil
                           "-C" root args))
              (output (with-current-buffer buffer
                        (string-trim-right (buffer-string)))))
          (unless (zerop exit)
            (user-error "Git %s failed: %s"
                        (string-join args " ")
                        output))
          output)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ogent-cabinet-git--porcelain-record (root line)
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

(defun ogent-cabinet-git-status-data (directory)
  "Return porcelain git status records for DIRECTORY."
  (let* ((root (ogent-cabinet-git--require-root directory))
         (output (ogent-cabinet-git--call root "status" "--porcelain=v1"))
         records)
    (dolist (line (split-string output "\n" t))
      (when-let ((record (ogent-cabinet-git--porcelain-record root line)))
        (push record records)))
    (nreverse records)))

(defun ogent-cabinet-git-dirty-count (directory)
  "Return the number of dirty git paths for DIRECTORY."
  (length (ogent-cabinet-git-status-data directory)))

(defun ogent-cabinet-git--show-buffer (name root content mode)
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
(defun ogent-cabinet-git-log-page (file)
  "Show git log for Cabinet FILE."
  (interactive "fCabinet page: ")
  (if (and (fboundp 'magit-log-buffer-file)
           (called-interactively-p 'interactive))
      (magit-log-buffer-file)
    (let* ((root (ogent-cabinet-git--require-root file))
           (relative (file-relative-name (expand-file-name file) root))
           (output (ogent-cabinet-git--call
                    root
                    "log"
                    "--oneline"
                    "--decorate"
                    "--"
                    relative)))
      (ogent-cabinet-git--show-buffer
       (format "*ogent-cabinet-git-log:%s*" relative)
       root
       (concat output "\n")
       #'special-mode))))

;;;###autoload
(defun ogent-cabinet-git-diff-page (file)
  "Show git diff for Cabinet FILE."
  (interactive "fCabinet page: ")
  (if (and (fboundp 'magit-diff-buffer-file)
           (called-interactively-p 'interactive))
      (magit-diff-buffer-file)
    (let* ((root (ogent-cabinet-git--require-root file))
           (relative (file-relative-name (expand-file-name file) root))
           (output (ogent-cabinet-git--call root "diff" "--" relative)))
      (ogent-cabinet-git--show-buffer
       (format "*ogent-cabinet-git-diff:%s*" relative)
       root
       (concat output "\n")
       #'diff-mode))))

;;;###autoload
(defun ogent-cabinet-git-restore-page (file &optional force)
  "Restore Cabinet FILE from git.
When FORCE is non-nil, skip confirmation."
  (interactive "fCabinet page: ")
  (let* ((root (ogent-cabinet-git--require-root file))
         (relative (file-relative-name (expand-file-name file) root)))
    (when (or force
              (yes-or-no-p (format "Restore %s from git? " relative)))
      (ogent-cabinet-git--call root "restore" "--" relative)
      relative)))

;;;###autoload
(defun ogent-cabinet-git-commit (directory message &optional files)
  "Commit FILES under DIRECTORY with MESSAGE.
When FILES is nil, all dirty paths are staged."
  (interactive
   (let ((root (or (ogent-cabinet-find-root)
                   (read-directory-name "Cabinet root: "))))
     (list root (read-string "Commit message: ") nil)))
  (let* ((root (ogent-cabinet-git--require-root directory))
         (paths (or files
                    (mapcar (lambda (record)
                              (plist-get record :relative))
                            (ogent-cabinet-git-status-data root)))))
    (unless paths
      (user-error "No Cabinet git changes to commit"))
    (apply #'ogent-cabinet-git--call root "add" "--" paths)
    (ogent-cabinet-git--call root "commit" "-m" message)
    message))

;;;###autoload
(defun ogent-cabinet-git-pull (directory)
  "Pull the git repository containing DIRECTORY with fast-forward only."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let ((root (ogent-cabinet-git--require-root directory)))
    (ogent-cabinet-git--call root "pull" "--ff-only")))

(defvar ogent-cabinet-git-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'ogent-cabinet-git-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-git-refresh)
    (define-key map "c" #'ogent-cabinet-git-commit-from-status)
    (define-key map (kbd "C-c c") #'ogent-cabinet-git-commit-from-status)
    (define-key map "d" #'ogent-cabinet-git-diff-at-point)
    (define-key map (kbd "C-c d") #'ogent-cabinet-git-diff-at-point)
    (define-key map "l" #'ogent-cabinet-git-log-at-point)
    (define-key map (kbd "C-c l") #'ogent-cabinet-git-log-at-point)
    (define-key map "R" #'ogent-cabinet-git-restore-at-point)
    (define-key map (kbd "C-c r") #'ogent-cabinet-git-restore-at-point)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-git-mode'.")

(define-derived-mode ogent-cabinet-git-mode tabulated-list-mode "Cabinet-Git"
  "Major mode for Cabinet git status."
  :group 'ogent-cabinet-git
  (setq-local tabulated-list-format
              [("Status" 8 t)
               ("Path" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-cabinet-git-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-git--entry (record)
  "Return a tabulated entry for git status RECORD."
  (list record
        (vector (or (plist-get record :status) "")
                (plist-get record :relative))))

(defun ogent-cabinet-git--entries ()
  "Return git status entries for the current buffer."
  (let ((records (ogent-cabinet-git-status-data ogent-cabinet-git--root)))
    (if records
        (mapcar #'ogent-cabinet-git--entry records)
      (list (list nil (vector "" "Working tree clean"))))))

;;;###autoload
(defun ogent-cabinet-git-status (&optional directory)
  "Open Cabinet git status for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-git--require-root
                (or directory default-directory)))
         (buffer (get-buffer-create
                  (format ogent-cabinet-git-buffer-name-format
                          (file-name-nondirectory root)))))
    (if (and (called-interactively-p 'interactive)
             (fboundp 'magit-status))
        (magit-status root)
      (with-current-buffer buffer
        (ogent-cabinet-git-mode)
        (setq ogent-cabinet-git--root root)
        (setq default-directory (file-name-as-directory root))
        (setq tabulated-list-entries #'ogent-cabinet-git--entries)
        (tabulated-list-print t))
      (pop-to-buffer buffer)
      buffer)))

(defun ogent-cabinet-git-refresh (&rest _)
  "Refresh the current Cabinet git status buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-git--item ()
  "Return the git status item at point."
  (or (tabulated-list-get-id)
      (user-error "No Cabinet git record at point")))

(defun ogent-cabinet-git-diff-at-point ()
  "Show git diff for the file at point."
  (interactive)
  (ogent-cabinet-git-diff-page
   (plist-get (ogent-cabinet-git--item) :path)))

(defun ogent-cabinet-git-log-at-point ()
  "Show git log for the file at point."
  (interactive)
  (ogent-cabinet-git-log-page
   (plist-get (ogent-cabinet-git--item) :path)))

(defun ogent-cabinet-git-restore-at-point ()
  "Restore the file at point from git."
  (interactive)
  (ogent-cabinet-git-restore-page
   (plist-get (ogent-cabinet-git--item) :path)))

(defun ogent-cabinet-git-commit-from-status ()
  "Commit all dirty paths from the current Cabinet git status buffer."
  (interactive)
  (ogent-cabinet-git-commit
   ogent-cabinet-git--root
   (read-string "Commit message: "))
  (ogent-cabinet-git-refresh))

(defun ogent-cabinet-git--evil-local-keys ()
  "Install local Evil keys for Cabinet git."
  (ogent-cabinet-evil-install-local-bindings ogent-cabinet-git-mode-map))

(defun ogent-cabinet-git--setup-evil ()
  "Set up Evil integration for Cabinet git."
  (ogent-cabinet-evil-setup-mode
   'ogent-cabinet-git-mode
   ogent-cabinet-git-mode-map
   'ogent-cabinet-git-mode-hook
   #'ogent-cabinet-git--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-cabinet-git--setup-evil))

(provide 'ogent-cabinet-git)

;;; ogent-cabinet-git.el ends here
