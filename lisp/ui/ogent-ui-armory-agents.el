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
    (define-key map "D" #'ogent-armory-agents-toggle-details)
    (define-key map "f" #'ogent-armory-agents-filter)
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
    ("f" "Filter / clear" ogent-armory-agents-filter :transient t)
    ("D" "Full / compact table" ogent-armory-agents-toggle-details :transient t)
    ("g" "Refresh" ogent-armory-agents-refresh :transient t)]]
  ["Help"
   ("q" "Quit menu" transient-quit-one)])

(defconst ogent-armory-agents--full-format
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
   ("Tags" 0 t)]
  "Full agent record columns, also accessible through profiles.")

(defvar-local ogent-armory-agents--details nil
  "Non-nil means display the full comparison table.")

(defvar-local ogent-armory-agents--query ""
  "Current literal agent filter.")

(defvar-local ogent-armory-agents--columns nil
  "Indices of the full record shown in the current table.")

(defvar-local ogent-armory-agents--width nil
  "Window width used for the most recent agent layout.")

(defun ogent-armory-agents--layout ()
  "Choose useful agent columns for the current window width."
  (let ((width (ogent-ui-layout-width)))
    (setq ogent-armory-agents--width width
          ogent-armory-agents--columns
          (cond (ogent-armory-agents--details (number-sequence 0 13))
                ((>= width 100) '(0 5 8 6 7))
                (t '(0 8 7))))
    (setq-local tabulated-list-format
                (if ogent-armory-agents--details
                    ogent-armory-agents--full-format
                  (if (>= width 100)
                      [("Name" 22 t) ("Role" 22 t) ("Active" 8 t)
                       ("Provider" 10 t) ("Model" 0 t)]
                    [("Name" 18 t) ("Active" 8 t) ("Model" 0 t)])))
    (unless (assoc (car tabulated-list-sort-key)
                   (append tabulated-list-format nil))
      (setq tabulated-list-sort-key '("Name" . nil)))
    (tabulated-list-init-header)))

(defun ogent-armory-agents--resize (window)
  "Reflow the agent list when its displaying WINDOW resizes."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when (and ogent-armory-agents--root
                 (not (equal ogent-armory-agents--width (ogent-ui-layout-width))))
        (ogent-armory-agents-refresh)))))

(defun ogent-armory-agents-toggle-details ()
  "Toggle compact columns and the full agent comparison table."
  (interactive)
  (setq ogent-armory-agents--details (not ogent-armory-agents--details))
  (ogent-armory-agents-refresh))

(defun ogent-armory-agents-filter (query)
  "Filter agents by literal QUERY across all record fields.
An empty query clears the filter."
  (interactive (list (read-string "Filter agents (empty clears): "
                                  ogent-armory-agents--query)))
  (setq ogent-armory-agents--query query)
  (ogent-armory-agents-refresh))

(define-derived-mode ogent-armory-agents-mode tabulated-list-mode "Armory-Agents"
  "Major mode for Armory agent lists."
  :group 'ogent-ui-armory
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key '("Name" . nil))
  (setq-local revert-buffer-function #'ogent-armory-agents-refresh)
  (setq-local tabulated-list-use-header-line nil)
  (ogent-ui-layout-configure)
  (setq-local truncate-lines t)
  (add-hook 'window-size-change-functions #'ogent-armory-agents--resize nil t)
  (setq header-line-format
        '(:eval (ogent-section-header-line
                 "Agents"
                 (concat (and ogent-armory-agents--root
                              (ogent-armory-ui--root-label ogent-armory-agents--root))
                         (unless (string-empty-p ogent-armory-agents--query)
                           (format " · filter: %s" ogent-armory-agents--query)))
                 '("?" . "menu") '("f" . "filter") '("D" . "details")
                 '("j" . "jump") '("g" . "refresh"))))
  (ogent-armory-agents--layout))

(defun ogent-armory-agents--full-entries ()
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

(defun ogent-armory-agents--entries ()
  "Return filtered entries projected onto the current agent columns."
  (let ((case-fold-search t))
    (mapcar
     (lambda (entry)
       (list (car entry)
             (vconcat (mapcar (lambda (index) (aref (cadr entry) index))
                              ogent-armory-agents--columns))))
     (seq-filter
      (lambda (entry)
        (string-match-p (regexp-quote ogent-armory-agents--query)
                        (string-join (append (cadr entry) nil) " ")))
      (ogent-armory-agents--full-entries)))))

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
      (ogent-armory-agents--layout)
      (ogent-armory-agents-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-agents-refresh (&optional force &rest _)
  "Refresh the Armory agents buffer.
With FORCE non-nil, invalidate cached Armory data first."
  (interactive "P")
  (ogent-armory-ui--invalidate-cache-when-force force ogent-armory-agents--root)
  (ogent-armory-agents--layout)
  (tabulated-list-print t)
  (when (null (ogent-armory-agents--entries))
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (propertize (if (string-empty-p ogent-armory-agents--query)
                              "\n  No agents yet. Use M-x ogent-armory-create-agent.\n"
                            "\n  No matches. Press f and clear the filter.\n")
                          'face 'ogent-theme-muted)))))

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
