;;; ogent-ui-cabinet-org-chart.el --- Cabinet department and lead org chart -*- lexical-binding: t; -*-

;;; Commentary:
;; Section-folding chart of Cabinet departments and their leads.

;;; Code:

(require 'ogent-ui-cabinet-core)

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

(defvar ogent-cabinet-org-chart-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'ogent-cabinet-org-chart-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-org-chart-refresh)
    (define-key map (kbd "TAB") #'ogent-cabinet-ui-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-cabinet-ui-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-cabinet-ui-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-cabinet-ui-next-section)
    (define-key map (kbd "M-p") #'ogent-cabinet-ui-previous-section)
    (define-key map (kbd "^") #'ogent-cabinet-ui-up-section)
    (define-key map (kbd "C-c u") #'ogent-cabinet-ui-up-section)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-org-chart-mode'.")

(ogent-cabinet-ui--define-section-mode
 ogent-cabinet-org-chart-mode "Cabinet-Org-Chart"
 "Major mode for Cabinet department and lead charts."
 (setq-local revert-buffer-function #'ogent-cabinet-org-chart-refresh)
 (setq-local buffer-read-only t)
 (ogent-cabinet-ui--configure-section-buffer)
 (setq header-line-format
       "C-c g refresh  TAB section  M-n/p sections  C-c u up  q quit"))

(defun ogent-cabinet-org-chart (&optional directory)
  "Open a Cabinet org chart for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   "*ogent-cabinet-org-chart: %s*" root))))
    (with-current-buffer buffer
      (ogent-cabinet-org-chart-mode)
      (setq ogent-cabinet-org-chart--root root)
      (setq default-directory (file-name-as-directory root))
      (ogent-cabinet-org-chart-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-org-chart-refresh (&rest _)
  "Refresh the current Cabinet org chart."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Cabinet Org Chart" 'face 'ogent-cabinet-ui-heading)
            "\n\n")
    (dolist (group (ogent-cabinet-agents-by-department
                    ogent-cabinet-org-chart--root
                    :include-visible t))
      (let ((department (plist-get group :department))
            (lead (plist-get group :lead)))
        (ogent-cabinet-ui--with-section
         (ogent-cabinet-org-chart-department)
         (ogent-cabinet-ui--heading-text department)
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

(provide 'ogent-ui-cabinet-org-chart)
;;; ogent-ui-cabinet-org-chart.el ends here
