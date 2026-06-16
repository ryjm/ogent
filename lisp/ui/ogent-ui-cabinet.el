;;; ogent-ui-cabinet.el --- Richer Org Cabinet buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Interactive Cabinet surfaces over the Org-backed storage layer: agent lists,
;; single-agent profiles, attention lanes, search, and app artifact opening.

;;; Code:

(require 'ogent-ui-cabinet-core)
(require 'ogent-ui-cabinet-home)
(require 'ogent-ui-cabinet-agents)
(require 'ogent-ui-cabinet-org-chart)
(require 'ogent-ui-cabinet-agent)
(require 'ogent-ui-cabinet-jobs)
(require 'ogent-ui-cabinet-tasks)
(require 'ogent-ui-cabinet-conversations)
(require 'ogent-ui-cabinet-search)
(require 'ogent-ui-cabinet-apps)

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

;;;###autoload (autoload 'ogent-cabinet-home "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-home-dispatch "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-agents "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-org-chart "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-agent "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-create-agent "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-clone-agent "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-archive-agent "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-jobs "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-create-job "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-create-task "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-tasks "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-conversations "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-conversation "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-search "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-apps "ogent-ui-cabinet" nil t)
;;;###autoload (autoload 'ogent-cabinet-open-app "ogent-ui-cabinet" nil t)

(defun ogent-cabinet-ui--section-keymaps ()
  "Return Cabinet UI keymaps that contain collapsible sections."
  (list ogent-cabinet-home-mode-map
        ogent-cabinet-org-chart-mode-map
        ogent-cabinet-agent-mode-map
        ogent-cabinet-conversation-mode-map))

(defun ogent-cabinet-ui--setup-section-keymaps ()
  "Wire Magit section parent keymaps into section-capable Cabinet buffers."
  (when (and (ogent-cabinet-ui--magit-section-usable-p)
             (boundp 'magit-section-mode-map))
    (dolist (map (ogent-cabinet-ui--section-keymaps))
      (set-keymap-parent map magit-section-mode-map))))

(ogent-cabinet-ui--setup-section-keymaps)

(with-eval-after-load 'magit-section
  (ogent-cabinet-ui--setup-section-keymaps))

(defun ogent-cabinet-ui--evil-mode-map ()
  "Return the Cabinet UI keymap for the current buffer."
  (pcase major-mode
    ('ogent-cabinet-home-mode ogent-cabinet-home-mode-map)
    ('ogent-cabinet-agents-mode ogent-cabinet-agents-mode-map)
    ('ogent-cabinet-org-chart-mode ogent-cabinet-org-chart-mode-map)
    ('ogent-cabinet-agent-mode ogent-cabinet-agent-mode-map)
    ('ogent-cabinet-jobs-mode ogent-cabinet-jobs-mode-map)
    ('ogent-cabinet-tasks-mode ogent-cabinet-tasks-mode-map)
    ('ogent-cabinet-conversations-mode ogent-cabinet-conversations-mode-map)
    ('ogent-cabinet-conversation-mode ogent-cabinet-conversation-mode-map)
    ('ogent-cabinet-search-mode ogent-cabinet-search-mode-map)
    ('ogent-cabinet-apps-mode ogent-cabinet-apps-mode-map)))

(defun ogent-cabinet-ui--evil-local-keys ()
  "Install local Evil keys for Cabinet UI buffers."
  (when-let ((map (ogent-cabinet-ui--evil-mode-map)))
    (ogent-cabinet-evil-install-local-bindings map)))

(defun ogent-cabinet-ui--evil-mode-specs ()
  "Return Cabinet UI Evil setup specs."
  `((ogent-cabinet-home-mode
     ,ogent-cabinet-home-mode-map
     ogent-cabinet-home-mode-hook)
    (ogent-cabinet-agents-mode
     ,ogent-cabinet-agents-mode-map
     ogent-cabinet-agents-mode-hook)
    (ogent-cabinet-org-chart-mode
     ,ogent-cabinet-org-chart-mode-map
     ogent-cabinet-org-chart-mode-hook)
    (ogent-cabinet-agent-mode
     ,ogent-cabinet-agent-mode-map
     ogent-cabinet-agent-mode-hook)
    (ogent-cabinet-jobs-mode
     ,ogent-cabinet-jobs-mode-map
     ogent-cabinet-jobs-mode-hook)
    (ogent-cabinet-tasks-mode
     ,ogent-cabinet-tasks-mode-map
     ogent-cabinet-tasks-mode-hook)
    (ogent-cabinet-conversations-mode
     ,ogent-cabinet-conversations-mode-map
     ogent-cabinet-conversations-mode-hook)
    (ogent-cabinet-conversation-mode
     ,ogent-cabinet-conversation-mode-map
     ogent-cabinet-conversation-mode-hook)
    (ogent-cabinet-search-mode
     ,ogent-cabinet-search-mode-map
     ogent-cabinet-search-mode-hook)
    (ogent-cabinet-apps-mode
     ,ogent-cabinet-apps-mode-map
     ogent-cabinet-apps-mode-hook)))

(defun ogent-cabinet-ui--setup-evil ()
  "Set up Evil integration for Cabinet UI buffers."
  (dolist (spec (ogent-cabinet-ui--evil-mode-specs))
    (pcase-let ((`(,mode ,map ,hook) spec))
      (ogent-cabinet-evil-setup-mode
       mode map hook #'ogent-cabinet-ui--evil-local-keys))))

(with-eval-after-load 'evil
  (ogent-cabinet-ui--setup-evil))

(provide 'ogent-ui-cabinet)

;;; ogent-ui-cabinet.el ends here
