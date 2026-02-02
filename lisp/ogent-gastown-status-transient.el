;;; ogent-gastown-status-transient.el --- Transient help for Gas Town status -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a magit-style transient help menu for the Gas Town status buffer.

;;; Code:

(require 'transient)

(declare-function ogent-gastown--in-town-p "ogent-gastown-status")
(declare-function ogent-gastown-refresh "ogent-gastown-status")
(declare-function ogent-gastown-refresh-force "ogent-gastown-status")
(declare-function ogent-gastown-next-item "ogent-gastown-status")
(declare-function ogent-gastown-prev-item "ogent-gastown-status")
(declare-function ogent-gastown-toggle-section "ogent-gastown-status")
(declare-function ogent-gastown-visit "ogent-gastown-status")
(declare-function ogent-gastown-status-mail-read "ogent-gastown-status")
(declare-function ogent-gastown-mail-compose "ogent-gastown-status")
(declare-function ogent-gastown-hook-show "ogent-gastown-status")
(declare-function ogent-gastown-hook-attach "ogent-gastown-status")
(declare-function ogent-gastown-convoy-status "ogent-gastown-status")
(declare-function ogent-gastown-convoy-create "ogent-gastown-status")
(declare-function ogent-gastown-stats-show "ogent-gastown-status")
(declare-function ogent-gastown-deacon-show "ogent-gastown-status")
(declare-function ogent-gastown-witness-show "ogent-gastown-status")
(declare-function ogent-gastown-crew-status "ogent-gastown-status")
(declare-function ogent-gastown-polecat-status "ogent-gastown-status")
(declare-function ogent-gastown-rig-status "ogent-gastown-status")
(declare-function ogent-gastown-refinery-status "ogent-gastown-status")
(declare-function ogent-gastown-rig-issues "ogent-gastown-status")

(autoload 'ogent-gastown--in-town-p "ogent-gastown-status" nil nil)
(autoload 'ogent-gastown-refresh "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-refresh-force "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-next-item "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-prev-item "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-toggle-section "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-visit "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-status-mail-read "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-mail-compose "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-hook-show "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-hook-attach "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-convoy-status "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-convoy-create "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-stats-show "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-deacon-show "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-witness-show "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-crew-status "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-polecat-status "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-rig-status "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-refinery-status "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-rig-issues "ogent-gastown-status" nil t)

(defun ogent-gastown-status-transient--format-header ()
  "Format header for the Gas Town status transient menu."
  (let* ((connected (ignore-errors (ogent-gastown--in-town-p)))
         (state (if connected "connected" "not in town"))
         (face (if connected 'success 'warning)))
    (concat
     (propertize "Gas Town" 'face 'transient-heading)
     " "
     (propertize state 'face face))))

;;;###autoload (autoload 'ogent-gastown-status-dispatch "ogent-gastown-status-transient" nil t)
(transient-define-prefix ogent-gastown-status-dispatch ()
  "Dispatch menu for Gas Town status buffer."
  [:description ogent-gastown-status-transient--format-header
   ["Navigation"
    ("n" "Next item" ogent-gastown-next-item :transient t)
    ("p" "Previous item" ogent-gastown-prev-item :transient t)
    ("RET" "Visit item" ogent-gastown-visit)
    ("TAB" "Toggle section" ogent-gastown-toggle-section :transient t)]
   ["Mail"
    ("m" "Read mail" ogent-gastown-status-mail-read)
    ("M" "Compose" ogent-gastown-mail-compose)]
   ["Hook"
    ("H" "Show hook" ogent-gastown-hook-show)
    ("a" "Attach work" ogent-gastown-hook-attach)]]
  [["Convoy"
    ("c" "Convoy status" ogent-gastown-convoy-status)
    ("C" "Create convoy" ogent-gastown-convoy-create)]
   ["Status"
    ("s" "Town stats" ogent-gastown-stats-show)
    ("d" "Deacon" ogent-gastown-deacon-show)
    ("w" "Witness" ogent-gastown-witness-show)]
   ["Crew"
    ("R" "Crew status" ogent-gastown-crew-status)
    ("P" "Polecat status" ogent-gastown-polecat-status)]]
  [["Rig"
    ("r" "Rig status" ogent-gastown-rig-status)
    ("f" "Refinery status" ogent-gastown-refinery-status)
    ("i" "Rig issues" ogent-gastown-rig-issues)]
   ["Refresh"
    ("g" "Refresh" ogent-gastown-refresh :transient t)
    ("G" "Force refresh" ogent-gastown-refresh-force :transient t)]
   ["Quit"
    ("q" "Quit menu" transient-quit-one)
    ("Q" "Quit buffer" quit-window)]])

(provide 'ogent-gastown-status-transient)

;;; ogent-gastown-status-transient.el ends here
