;;; ogent-prompts-yasnippet.el --- Yasnippet integration for ogent prompts -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides yasnippet integration for ogent prompt templates.
;; Prompts can be expanded as snippets using @handle syntax.
;;
;; Usage:
;;   1. Enable `ogent-prompts-yasnippet-mode' in org-mode buffers
;;   2. Type @code-review and press TAB to expand
;;   3. Or run `ogent-prompts-install-snippets' to create snippet files

;;; Code:

(require 'ogent-prompts)

;; Yasnippet is optional - gracefully handle when not available
(declare-function yas-minor-mode "ext:yasnippet")
(declare-function yas-expand-snippet "ext:yasnippet")
(declare-function yas-reload-all "ext:yasnippet")
(defvar yas-snippet-dirs)
(defvar yas-minor-mode)

(defgroup ogent-prompts-yasnippet nil
  "Yasnippet integration for ogent prompts."
  :group 'ogent-prompts)

(defcustom ogent-prompts-snippet-dir
  (expand-file-name "ogent-snippets" user-emacs-directory)
  "Directory where ogent prompt snippets are stored.
Snippets are created here by `ogent-prompts-install-snippets'."
  :type 'directory
  :group 'ogent-prompts-yasnippet)

(defcustom ogent-prompts-yasnippet-auto-install t
  "Whether to auto-install snippets when enabling yasnippet mode.
When non-nil, `ogent-prompts-install-snippets' is called automatically
when `ogent-prompts-yasnippet-mode' is enabled."
  :type 'boolean
  :group 'ogent-prompts-yasnippet)

;;; Snippet Generation

(defun ogent-prompt-to-snippet (id)
  "Convert prompt with ID to yasnippet format.
Return the snippet string, or nil if prompt not found."
  (let ((prompt (ogent-prompt-get id)))
    (when prompt
      (let ((title (ogent-prompt-title prompt))
            (content (ogent-prompt-content prompt)))
        (format "# -*- mode: snippet -*-
# name: %s
# key: @%s
# --
%s
$0" title id content)))))

(defun ogent-prompts-install-snippets ()
  "Install all registered prompt templates as yasnippet snippets.
Create snippet files in `ogent-prompts-snippet-dir'."
  (interactive)
  (unless (file-directory-p ogent-prompts-snippet-dir)
    (make-directory ogent-prompts-snippet-dir t))
  (let ((count 0))
    (dolist (prompt (ogent-prompt-list))
      (let* ((id (ogent-prompt-id prompt))
             (snippet (ogent-prompt-to-snippet id))
             (file (expand-file-name id ogent-prompts-snippet-dir)))
        (when snippet
          (with-temp-file file
            (insert snippet))
          (setq count (1+ count)))))
    (message "Installed %d ogent prompt snippets to %s"
             count ogent-prompts-snippet-dir)
    count))

(defun ogent-prompts-uninstall-snippets ()
  "Remove all ogent prompt snippets from `ogent-prompts-snippet-dir'."
  (interactive)
  (when (file-directory-p ogent-prompts-snippet-dir)
    (let ((count 0))
      (dolist (prompt (ogent-prompt-list))
        (let ((file (expand-file-name (ogent-prompt-id prompt)
                                      ogent-prompts-snippet-dir)))
          (when (file-exists-p file)
            (delete-file file)
            (setq count (1+ count)))))
      (message "Removed %d ogent prompt snippets" count)
      count)))

;;; Expansion

(defun ogent-prompts-expand-at-point ()
  "Expand @handle at point as a prompt snippet.
Return t if expansion occurred, nil otherwise."
  (interactive)
  (when (and (looking-back "@\\([a-zA-Z0-9_-]+\\)" (line-beginning-position))
             (require 'yasnippet nil t))
    (let* ((id (match-string 1))
           (snippet (ogent-prompt-to-snippet id)))
      (when snippet
        ;; Delete the @handle text
        (delete-region (match-beginning 0) (match-end 0))
        ;; Expand the snippet
        (yas-expand-snippet snippet)
        t))))

;;; Minor Mode

(defvar ogent-prompts-yasnippet-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Could add keybindings here if needed
    map)
  "Keymap for `ogent-prompts-yasnippet-mode'.")

;;;###autoload
(define-minor-mode ogent-prompts-yasnippet-mode
  "Minor mode for yasnippet integration with ogent prompts.
When enabled, adds ogent prompt snippets to yasnippet and allows
expansion of @handle syntax."
  :lighter " OgentYas"
  :keymap ogent-prompts-yasnippet-mode-map
  (if ogent-prompts-yasnippet-mode
      (ogent-prompts-yasnippet--enable)
    (ogent-prompts-yasnippet--disable)))

(defun ogent-prompts-yasnippet--enable ()
  "Enable yasnippet integration."
  (when (require 'yasnippet nil t)
    ;; Ensure snippet directory exists and is in path
    (unless (file-directory-p ogent-prompts-snippet-dir)
      (make-directory ogent-prompts-snippet-dir t))
    (unless (member ogent-prompts-snippet-dir yas-snippet-dirs)
      (push ogent-prompts-snippet-dir yas-snippet-dirs))
    ;; Auto-install snippets if configured
    (when ogent-prompts-yasnippet-auto-install
      (ogent-prompts-install-snippets))
    ;; Enable yas-minor-mode if not already
    (unless (bound-and-true-p yas-minor-mode)
      (yas-minor-mode 1))
    ;; Reload to pick up new snippets
    (when (fboundp 'yas-reload-all)
      (yas-reload-all))))

(defun ogent-prompts-yasnippet--disable ()
  "Disable yasnippet integration."
  (when (require 'yasnippet nil t)
    ;; Remove our snippet dir from the path
    (setq yas-snippet-dirs (delete ogent-prompts-snippet-dir yas-snippet-dirs))))

;;; Hooks

(defun ogent-prompts-yasnippet-setup-org-mode ()
  "Set up yasnippet integration for `org-mode'.
Add this to `org-mode-hook' for automatic setup."
  (when (and (derived-mode-p 'org-mode)
             (require 'yasnippet nil t))
    (ogent-prompts-yasnippet-mode 1)))

(provide 'ogent-prompts-yasnippet)

;;; ogent-prompts-yasnippet.el ends here
