;;; ogent-ui-cabinet-agents.el --- Tabulated Cabinet agent list -*- lexical-binding: t; -*-

;;; Commentary:
;; Tabulated list of Cabinet agents under a root.

;;; Code:

(require 'ogent-ui-cabinet-core)

(declare-function ogent-cabinet-agent "ogent-ui-cabinet-agent")
(declare-function ogent-cabinet-search "ogent-ui-cabinet-search")
(declare-function ogent-cabinet-tasks "ogent-ui-cabinet-tasks")

(defvar ogent-cabinet-agents-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-cabinet-agents-open-agent)
    (define-key map (kbd "<return>") #'ogent-cabinet-agents-open-agent)
    (define-key map (kbd "<kp-enter>") #'ogent-cabinet-agents-open-agent)
    (define-key map "v" #'ogent-cabinet-agents-visit)
    (define-key map (kbd "C-c v") #'ogent-cabinet-agents-visit)
    (define-key map "R" #'ogent-cabinet-agents-run)
    (define-key map (kbd "C-c r") #'ogent-cabinet-agents-run)
    (define-key map "g" #'ogent-cabinet-agents-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-agents-refresh)
    (define-key map "t" #'ogent-cabinet-tasks)
    (define-key map (kbd "C-c t") #'ogent-cabinet-tasks)
    (define-key map "s" #'ogent-cabinet-search)
    (define-key map (kbd "C-c s") #'ogent-cabinet-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-agents-mode'.")

(define-derived-mode ogent-cabinet-agents-mode tabulated-list-mode "Cabinet-Agents"
  "Major mode for Cabinet agent lists."
  :group 'ogent-ui-cabinet
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
  (setq-local revert-buffer-function #'ogent-cabinet-agents-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-agents--entries ()
  "Return tabulated entries for the current Cabinet agents buffer."
  (mapcar
   (lambda (slug)
     (let* ((agent (ogent-cabinet-resolve-agent
                    ogent-cabinet-agents--root slug :include-visible t))
            (jobs (ogent-cabinet-ui--agent-jobs ogent-cabinet-agents--root slug))
            (sessions (ogent-cabinet-ui--agent-sessions ogent-cabinet-agents--root slug))
            (last-session (ogent-cabinet-ui--last-session sessions))
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
                               'ogent-cabinet-ui-good
                             'ogent-cabinet-ui-dim))
         (number-to-string (length jobs))
         (number-to-string (length sessions))
         (or (plist-get last-session :finished) "")
         (or (plist-get agent :workspace) "")
         (ogent-cabinet-ui--format-tags (plist-get agent :tags))))))
   (ogent-cabinet-ui--agent-slugs ogent-cabinet-agents--root)))

(defun ogent-cabinet-agents (&optional directory)
  "Open a tabulated Cabinet agent list for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-agents-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-cabinet-agents-mode)
      (setq ogent-cabinet-agents--root root)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-cabinet-agents--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-agents-refresh (&rest _)
  "Refresh the Cabinet agents buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-agents--slug-at-point ()
  "Return the agent slug at point."
  (or (tabulated-list-get-id)
      (user-error "No Cabinet agent at point")))

(defun ogent-cabinet-agents-open-agent ()
  "Open the Cabinet agent profile at point."
  (interactive)
  (ogent-cabinet-agent
   ogent-cabinet-agents--root
   (ogent-cabinet-agents--slug-at-point)))

(defun ogent-cabinet-agents-visit ()
  "Visit the persona Org file for the Cabinet agent at point."
  (interactive)
  (let ((agent (ogent-cabinet-resolve-agent
                ogent-cabinet-agents--root
                (ogent-cabinet-agents--slug-at-point)
                :include-visible t)))
    (ogent-cabinet-ui--visit-path (plist-get agent :path))))

(defun ogent-cabinet-agents-run ()
  "Run the Cabinet agent at point with an instruction."
  (interactive)
  (let ((slug (ogent-cabinet-agents--slug-at-point)))
    (ogent-cabinet-run-agent
     ogent-cabinet-agents--root
     slug
     (read-string "Instruction: "))))

(provide 'ogent-ui-cabinet-agents)
;;; ogent-ui-cabinet-agents.el ends here
