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
    (define-key map "g" #'ogent-armory-org-chart-refresh)
    (define-key map (kbd "C-c g") #'ogent-armory-org-chart-refresh)
    (define-key map (kbd "TAB") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-armory-ui-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-armory-ui-next-section)
    (define-key map (kbd "M-p") #'ogent-armory-ui-previous-section)
    (define-key map (kbd "^") #'ogent-armory-ui-up-section)
    (define-key map (kbd "C-c u") #'ogent-armory-ui-up-section)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-org-chart-mode'.")

(ogent-armory-ui--define-section-mode
    ogent-armory-org-chart-mode "Armory-Org-Chart"
    "Major mode for Armory department and lead charts."
  (setq-local revert-buffer-function #'ogent-armory-org-chart-refresh)
  (setq-local buffer-read-only t)
  (ogent-armory-ui--configure-section-buffer)
  (setq header-line-format
        "C-c g refresh  TAB section  M-n/p sections  C-c u up  q quit"))

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

(defun ogent-armory-org-chart-refresh (&rest _)
  "Refresh the current Armory org chart."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Armory Org Chart" 'face 'ogent-armory-ui-heading)
            "\n\n")
    (dolist (group (ogent-armory-agents-by-department
                    ogent-armory-org-chart--root
                    :include-visible t))
      (let ((department (plist-get group :department))
            (lead (plist-get group :lead)))
        (ogent-armory-ui--with-section
            (ogent-armory-org-chart-department)
            (ogent-armory-ui--heading-text department)
          (when lead
            (insert (format "  Lead: %s (%s)\n"
                            (or (plist-get lead :display-name)
                                (plist-get lead :name)
                                (plist-get lead :slug))
                            (plist-get lead :slug))))
          (dolist (agent (plist-get group :agents))
            (insert (format "  %s  %s  %s  %s\n"
                            (plist-get agent :slug)
                            (symbol-name (plist-get agent :scope))
                            (or (plist-get agent :type) "agent")
                            (or (plist-get agent :role) "")))))
        (insert "\n")))
    (goto-char (point-min))))

(provide 'ogent-ui-armory-org-chart)
;;; ogent-ui-armory-org-chart.el ends here
