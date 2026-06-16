;;; ogent-ui-armory.el --- Richer Org Armory buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Interactive Armory surfaces over the Org-backed storage layer: agent lists,
;; single-agent profiles, attention lanes, search, and app artifact opening.

;;; Code:

(require 'ogent-ui-armory-core)
(require 'ogent-ui-armory-home)
(require 'ogent-ui-armory-agents)
(require 'ogent-ui-armory-org-chart)
(require 'ogent-ui-armory-agent)
(require 'ogent-ui-armory-jobs)
(require 'ogent-ui-armory-tasks)
(require 'ogent-ui-armory-conversations)
(require 'ogent-ui-armory-search)
(require 'ogent-ui-armory-apps)

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

;;;###autoload (autoload 'ogent-armory-home "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-home-dispatch "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-agents "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-org-chart "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-agent "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-create-agent "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-clone-agent "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-archive-agent "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-jobs "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-create-job "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-create-task "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-tasks "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-conversations "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-conversation "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-search "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-apps "ogent-ui-armory" nil t)
;;;###autoload (autoload 'ogent-armory-open-app "ogent-ui-armory" nil t)

(defun ogent-armory-ui--section-keymaps ()
  "Return Armory UI keymaps that contain collapsible sections."
  (list ogent-armory-home-mode-map
        ogent-armory-org-chart-mode-map
        ogent-armory-agent-mode-map
        ogent-armory-conversation-mode-map))

(defun ogent-armory-ui--setup-section-keymaps ()
  "Wire Magit section parent keymaps into section-capable Armory buffers."
  (when (and (ogent-armory-ui--magit-section-usable-p)
             (boundp 'magit-section-mode-map))
    (dolist (map (ogent-armory-ui--section-keymaps))
      (set-keymap-parent map magit-section-mode-map))))

(ogent-armory-ui--setup-section-keymaps)

(with-eval-after-load 'magit-section
  (ogent-armory-ui--setup-section-keymaps))

(defun ogent-armory-ui--evil-mode-map ()
  "Return the Armory UI keymap for the current buffer."
  (pcase major-mode
    ('ogent-armory-home-mode ogent-armory-home-mode-map)
    ('ogent-armory-agents-mode ogent-armory-agents-mode-map)
    ('ogent-armory-org-chart-mode ogent-armory-org-chart-mode-map)
    ('ogent-armory-agent-mode ogent-armory-agent-mode-map)
    ('ogent-armory-jobs-mode ogent-armory-jobs-mode-map)
    ('ogent-armory-tasks-mode ogent-armory-tasks-mode-map)
    ('ogent-armory-conversations-mode ogent-armory-conversations-mode-map)
    ('ogent-armory-conversation-mode ogent-armory-conversation-mode-map)
    ('ogent-armory-search-mode ogent-armory-search-mode-map)
    ('ogent-armory-apps-mode ogent-armory-apps-mode-map)))

(defun ogent-armory-ui--evil-local-keys ()
  "Install local Evil keys for Armory UI buffers."
  (when-let ((map (ogent-armory-ui--evil-mode-map)))
    (ogent-armory-evil-install-local-bindings map)))

(defun ogent-armory-ui--evil-mode-specs ()
  "Return Armory UI Evil setup specs."
  `((ogent-armory-home-mode
     ,ogent-armory-home-mode-map
     ogent-armory-home-mode-hook)
    (ogent-armory-agents-mode
     ,ogent-armory-agents-mode-map
     ogent-armory-agents-mode-hook)
    (ogent-armory-org-chart-mode
     ,ogent-armory-org-chart-mode-map
     ogent-armory-org-chart-mode-hook)
    (ogent-armory-agent-mode
     ,ogent-armory-agent-mode-map
     ogent-armory-agent-mode-hook)
    (ogent-armory-jobs-mode
     ,ogent-armory-jobs-mode-map
     ogent-armory-jobs-mode-hook)
    (ogent-armory-tasks-mode
     ,ogent-armory-tasks-mode-map
     ogent-armory-tasks-mode-hook)
    (ogent-armory-conversations-mode
     ,ogent-armory-conversations-mode-map
     ogent-armory-conversations-mode-hook)
    (ogent-armory-conversation-mode
     ,ogent-armory-conversation-mode-map
     ogent-armory-conversation-mode-hook)
    (ogent-armory-search-mode
     ,ogent-armory-search-mode-map
     ogent-armory-search-mode-hook)
    (ogent-armory-apps-mode
     ,ogent-armory-apps-mode-map
     ogent-armory-apps-mode-hook)))

(defun ogent-armory-ui--setup-evil ()
  "Set up Evil integration for Armory UI buffers."
  (dolist (spec (ogent-armory-ui--evil-mode-specs))
    (pcase-let ((`(,mode ,map ,hook) spec))
      (ogent-armory-evil-setup-mode
       mode map hook #'ogent-armory-ui--evil-local-keys))))

(with-eval-after-load 'evil
  (ogent-armory-ui--setup-evil))

(provide 'ogent-ui-armory)

;;; ogent-ui-armory.el ends here
