;;; ogent-ui-armory-agents.el --- Tabulated Armory agent list -*- lexical-binding: t; -*-

;;; Commentary:
;; Tabulated list of Armory agents under a root.

;;; Code:

(require 'ogent-ui-armory-core)

(declare-function ogent-armory-agent "ogent-ui-armory-agent")
(declare-function ogent-armory-search "ogent-ui-armory-search")
(declare-function ogent-armory-tasks "ogent-ui-armory-tasks")

(defvar ogent-armory-agents-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-armory-agents-open-agent)
    (define-key map (kbd "<return>") #'ogent-armory-agents-open-agent)
    (define-key map (kbd "<kp-enter>") #'ogent-armory-agents-open-agent)
    (define-key map "v" #'ogent-armory-agents-visit)
    (define-key map "R" #'ogent-armory-agents-run)
    (define-key map "g" #'ogent-armory-agents-refresh)
    (define-key map "?" #'ogent-armory-agents-dispatch)
    (define-key map "n" #'ogent-armory-ui-next-item)
    (define-key map "p" #'ogent-armory-ui-previous-item)
    (define-key map "j" ogent-armory-jump-map)
    (define-key map "," #'ogent-armory-settings)
    (define-key map "/" #'ogent-armory-command-palette)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-agents-mode'.")

(ogent-armory-ui--define-prefix ogent-armory-agents-dispatch ()
  "Dispatch menu for the Armory agent list."
  [["Item"
    ("RET" "Open agent profile" ogent-armory-agents-open-agent)
    ("v" "Visit agent Org file" ogent-armory-agents-visit)
    ("R" "Run with instruction" ogent-armory-agents-run)
    ("c" "Clone agent" ogent-armory-clone-agent)
    ("a" "Archive agent" ogent-armory-archive-agent)]
   ["View"
    ("g" "Refresh" ogent-armory-agents-refresh :transient t)]]
  ["Help"
   ("q" "Quit menu" transient-quit-one)])

(define-derived-mode ogent-armory-agents-mode tabulated-list-mode "Armory-Agents"
  "Major mode for Armory agent lists."
  :group 'ogent-ui-armory
  (setq-local tabulated-list-format
              [("Name" 18 t)
               ("Slug" 14 t)
               ("Scope" 9 t)
               ("Dept" 14 t)
               ("Type" 10 t)
               ("Role" 18 t)
               ("Provider" 10 t)
               ("Model" 12 t)
               ("Active" 8 t)
               ("Jobs" 6 nil :right-align t)
               ("Conversations" 13 nil :right-align t)
               ("Last Run" 18 t)
               ("Workspace" 16 t)
               ("Tags" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key '("Name" . nil))
  (setq-local revert-buffer-function #'ogent-armory-agents-refresh)
  (setq-local tabulated-list-use-header-line nil)
  (setq header-line-format
        '(:eval (ogent-section-header-line
                 "Agents"
                 (and ogent-armory-agents--root
                      (ogent-armory-ui--root-label ogent-armory-agents--root))
                 '("?" . "menu") '("j" . "jump") '("g" . "refresh"))))
  (tabulated-list-init-header))

(defun ogent-armory-agents--entries ()
  "Return tabulated entries for the current Armory agents buffer."
  (mapcar
   (lambda (slug)
     (let* ((agent (ogent-armory-resolve-agent
                    ogent-armory-agents--root slug :include-visible t))
            (jobs (ogent-armory-ui--agent-jobs ogent-armory-agents--root slug))
            (sessions (ogent-armory-ui--agent-sessions ogent-armory-agents--root slug))
            (last-session (ogent-armory-ui--last-session sessions))
            (active (if (plist-get agent :active) "yes" "no")))
       (list
        slug
        (vector
         (or (plist-get agent :display-name)
             (plist-get agent :name)
             slug)
         slug
         (symbol-name (plist-get agent :scope))
         (or (plist-get agent :department) "")
         (or (plist-get agent :type) "")
         (or (plist-get agent :role) "")
         (or (plist-get agent :provider) "")
         (or (plist-get agent :model) "")
         (propertize active
                     'face (if (plist-get agent :active)
                               'ogent-armory-ui-good
                             'ogent-armory-ui-dim))
         (number-to-string (length jobs))
         (number-to-string (length sessions))
         (or (plist-get last-session :finished) "")
         (or (plist-get agent :workspace) "")
         (ogent-armory-ui--format-tags (plist-get agent :tags))))))
   (ogent-armory-ui--agent-slugs ogent-armory-agents--root)))

(defun ogent-armory-agents (&optional directory)
  "Open a tabulated Armory agent list for DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-agents-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-armory-agents-mode)
      (setq ogent-armory-agents--root root)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-armory-agents--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-agents-refresh (&optional force &rest _)
  "Refresh the Armory agents buffer.
With FORCE non-nil, invalidate cached Armory data first."
  (interactive "P")
  (ogent-armory-ui--invalidate-cache-when-force force ogent-armory-agents--root)
  (tabulated-list-print t))

(defun ogent-armory-agents--slug-at-point ()
  "Return the agent slug at point."
  (or (tabulated-list-get-id)
      (user-error "No Armory agent at point")))

(defun ogent-armory-agents-open-agent ()
  "Open the Armory agent profile at point."
  (interactive)
  (ogent-armory-agent
   ogent-armory-agents--root
   (ogent-armory-agents--slug-at-point)))

(defun ogent-armory-agents-visit ()
  "Visit the persona Org file for the Armory agent at point."
  (interactive)
  (let ((agent (ogent-armory-resolve-agent
                ogent-armory-agents--root
                (ogent-armory-agents--slug-at-point)
                :include-visible t)))
    (ogent-armory-ui--visit-path (plist-get agent :path))))

(defun ogent-armory-agents-run ()
  "Run the Armory agent at point with an instruction."
  (interactive)
  (let ((slug (ogent-armory-agents--slug-at-point)))
    (ogent-armory-run-agent
     ogent-armory-agents--root
     slug
     (read-string "Instruction: "))))

(defun ogent-armory-agents--evil-local-keys ()
  "Install local Evil keys for Armory agents buffers."
  (ogent-armory-evil-install-local-bindings ogent-armory-agents-mode-map))

(defun ogent-armory-agents--setup-evil ()
  "Set up Evil integration for Armory agents buffers."
  (ogent-armory-evil-setup-mode
   'ogent-armory-agents-mode
   ogent-armory-agents-mode-map
   'ogent-armory-agents-mode-hook
   #'ogent-armory-agents--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-agents--setup-evil))

(provide 'ogent-ui-armory-agents)
;;; ogent-ui-armory-agents.el ends here
