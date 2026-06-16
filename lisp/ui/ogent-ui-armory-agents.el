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
    (define-key map (kbd "C-c v") #'ogent-armory-agents-visit)
    (define-key map "R" #'ogent-armory-agents-run)
    (define-key map (kbd "C-c r") #'ogent-armory-agents-run)
    (define-key map "g" #'ogent-armory-agents-refresh)
    (define-key map (kbd "C-c g") #'ogent-armory-agents-refresh)
    (define-key map "t" #'ogent-armory-tasks)
    (define-key map (kbd "C-c t") #'ogent-armory-tasks)
    (define-key map "s" #'ogent-armory-search)
    (define-key map (kbd "C-c s") #'ogent-armory-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-agents-mode'.")

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

(defun ogent-armory-agents-refresh (&rest _)
  "Refresh the Armory agents buffer."
  (interactive)
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

(provide 'ogent-ui-armory-agents)
;;; ogent-ui-armory-agents.el ends here
