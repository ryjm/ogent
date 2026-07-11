;;; ogent-ui-armory-org-chart.el --- Armory department and lead org chart -*- lexical-binding: t; -*-

;;; Commentary:
;; Section-folding chart of Armory departments and their leads.

;;; Code:

(require 'ogent-ui-armory-core)

(declare-function magit-current-section "ext:magit-section")
(declare-function magit-insert-heading "ext:magit-section")
(declare-function magit-insert-section--create "ext:magit-section")
(declare-function magit-insert-section--finish "ext:magit-section")
(declare-function magit-section-backward-sibling "ext:magit-section")
(declare-function magit-section-cycle-global "ext:magit-section")
(declare-function magit-section-forward-sibling "ext:magit-section")
(declare-function magit-section-toggle "ext:magit-section")
(declare-function magit-section-up "ext:magit-section")
(defvar magit-section-mode-map)
(defvar magit-section-visibility-indicator)
(defvar magit-insert-section--current)
(defvar magit-insert-section--oldroot)
(defvar magit-insert-section--parent)
(defvar magit-root-section)

(defvar ogent-armory-org-chart-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-armory-org-chart-visit))
    (define-key map "g" #'ogent-armory-org-chart-refresh)
    (define-key map "?" #'ogent-armory-org-chart-dispatch)
    (define-key map "n" #'ogent-armory-ui-next-item)
    (define-key map "p" #'ogent-armory-ui-previous-item)
    (define-key map (kbd "TAB") #'ogent-section-toggle)
    (define-key map (kbd "<tab>") #'ogent-section-toggle)
    (define-key map (kbd "<backtab>") #'ogent-section-cycle)
    (define-key map (kbd "M-n") #'ogent-section-next)
    (define-key map (kbd "M-p") #'ogent-section-prev)
    (define-key map (kbd "^") #'ogent-section-up)
    (define-key map "j" ogent-armory-jump-map)
    (define-key map "," #'ogent-armory-settings)
    (define-key map "/" #'ogent-armory-command-palette)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-org-chart-mode'.")

(ogent-armory-ui--define-prefix ogent-armory-org-chart-dispatch ()
  "Dispatch menu for the Armory org chart."
  [["Item"
    ("RET" "Visit agent Org file" ogent-armory-org-chart-visit)]
   ["View"
    ("g" "Refresh" ogent-armory-org-chart-refresh :transient t)
    ("n" "Next agent" ogent-armory-ui-next-item :transient t)
    ("p" "Previous agent" ogent-armory-ui-previous-item :transient t)
    ("TAB" "Toggle section" ogent-section-toggle :transient t)
    ("M-n" "Next section" ogent-section-next :transient t)
    ("M-p" "Previous section" ogent-section-prev :transient t)]]
  ["Help"
   ("q" "Quit menu" transient-quit-one)])

(ogent-armory-ui--define-section-mode
    ogent-armory-org-chart-mode "Armory-Org-Chart"
    "Major mode for Armory department and lead charts."
  (setq-local revert-buffer-function #'ogent-armory-org-chart-refresh)
  (setq-local buffer-read-only t)
  (ogent-armory-ui--configure-section-buffer)
  (setq header-line-format
        '(:eval (ogent-section-header-line
                 "Org Chart"
                 (and ogent-armory-org-chart--root
                      (ogent-armory-ui--root-label
                       ogent-armory-org-chart--root))
                 '("?" . "menu") '("j" . "jump") '("g" . "refresh")))))

(defun ogent-armory-org-chart (&optional directory)
  "Open a Armory org chart for DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   "*ogent-armory-org-chart: %s*" root))))
    (with-current-buffer buffer
      (ogent-armory-org-chart-mode)
      (setq ogent-armory-org-chart--root root)
      (setq default-directory (file-name-as-directory root))
      (ogent-armory-org-chart-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-org-chart-refresh (&optional force &rest _)
  "Refresh the current Armory org chart.
With FORCE non-nil, invalidate cached Armory data first."
  (interactive "P")
  (ogent-armory-ui--invalidate-cache-when-force force ogent-armory-org-chart--root)
  (let ((inhibit-read-only t))
    (ogent-section-preserve-point
        ((lambda ()
           (when-let ((item (ogent-section-item-at-point 'ogent-armory-item)))
             (plist-get item :slug))))
      (erase-buffer)
      (dolist (group (ogent-armory-agents-by-department
                      ogent-armory-org-chart--root
                      :include-visible t))
        (let ((department (plist-get group :department))
              (lead (plist-get group :lead)))
          (ogent-armory-ui--with-section
              (ogent-armory-org-chart-department)
              (ogent-armory-ui--heading-text department)
            (when lead
              (ogent-armory-ui--insert-item-line
               lead
               (format "  Lead: %s (%s)"
                       (or (plist-get lead :display-name)
                           (plist-get lead :name)
                           (plist-get lead :slug))
                       (plist-get lead :slug))))
            (dolist (agent (plist-get group :agents))
              (ogent-armory-ui--insert-item-line
               agent
               (format "  %s  %s  %s  %s"
                       (plist-get agent :slug)
                       (symbol-name (plist-get agent :scope))
                       (or (plist-get agent :type) "agent")
                       (or (plist-get agent :role) "")))))
          (insert "\n"))))))

(defun ogent-armory-org-chart-visit ()
  "Visit the Armory agent Org file at point."
  (interactive)
  (let ((agent (ogent-armory-ui--item-at-point)))
    (unless agent
      (user-error "No Armory agent at point"))
    (ogent-armory-ui--visit-path (plist-get agent :path))))

(defun ogent-armory-org-chart--evil-local-keys ()
  "Install local Evil keys for Armory org chart buffers."
  (ogent-armory-evil-install-local-bindings
   ogent-armory-org-chart-mode-map))

(defun ogent-armory-org-chart--setup-evil ()
  "Set up Evil integration for Armory org chart buffers."
  (ogent-armory-evil-setup-mode
   'ogent-armory-org-chart-mode
   ogent-armory-org-chart-mode-map
   'ogent-armory-org-chart-mode-hook
   #'ogent-armory-org-chart--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-org-chart--setup-evil))

(provide 'ogent-ui-armory-org-chart)
;;; ogent-ui-armory-org-chart.el ends here
