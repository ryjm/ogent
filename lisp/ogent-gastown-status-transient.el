;;; ogent-gastown-status-transient.el --- Transient help for Gas Town status -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a magit-style transient help menu for the Gas Town status buffer.
;; Organized around the war room mental model: Navigate → Inspect → Act.

;;; Code:

(require 'transient)

;; Declare functions from ogent-gastown-status
(declare-function ogent-gastown--in-town-p "ogent-gastown-status")
(declare-function ogent-gastown--workspace-root-display "ogent-gastown-status")
(declare-function ogent-gastown-refresh "ogent-gastown-status")
(declare-function ogent-gastown-refresh-force "ogent-gastown-status")
(declare-function ogent-gastown-next-item "ogent-gastown-status")
(declare-function ogent-gastown-prev-item "ogent-gastown-status")
(declare-function ogent-gastown-cycle-rig-prev "ogent-gastown-status")
(declare-function ogent-gastown-cycle-rig-next "ogent-gastown-status")
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
(declare-function ogent-gastown-nudge "ogent-gastown-status")
(declare-function ogent-gastown-rig-status "ogent-gastown-status")
(declare-function ogent-gastown-refinery-status "ogent-gastown-status")
(declare-function ogent-gastown-issues "ogent-gastown-status")
(declare-function ogent-gastown-issue-close "ogent-gastown-status")
(declare-function ogent-gastown-issue-prioritize "ogent-gastown-status")
(declare-function ogent-gastown-issue-claim "ogent-gastown-status")
(declare-function ogent-gastown-issue-block "ogent-gastown-status")
(declare-function ogent-gastown-bead-create "ogent-gastown-status")
(declare-function ogent-gastown-sling "ogent-gastown-status")
(declare-function ogent-gastown-auto-refresh-mode "ogent-gastown-status")

;; Autoloads
(autoload 'ogent-gastown--in-town-p "ogent-gastown-status" nil nil)
(autoload 'ogent-gastown-refresh "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-refresh-force "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-next-item "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-prev-item "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-cycle-rig-prev "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-cycle-rig-next "ogent-gastown-status" nil t)
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
(autoload 'ogent-gastown-nudge "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-rig-status "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-refinery-status "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-issues "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-issue-close "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-issue-prioritize "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-issue-claim "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-issue-block "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-bead-create "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-sling "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-auto-refresh-mode "ogent-gastown-status" nil t)

(defun ogent-gastown-status-transient--format-header ()
  "Format header for the Gas Town status transient menu."
  (let* ((connected (ignore-errors (ogent-gastown--in-town-p)))
         (workspace (ignore-errors (ogent-gastown--workspace-root-display)))
         (state (if connected "connected" "not in town"))
         (face (if connected 'success 'warning)))
    (concat
     (propertize "Gas Town" 'face 'transient-heading)
     " "
     (propertize state 'face face)
     (if workspace
         (concat " · " (propertize workspace 'face 'shadow))
       ""))))

;;;###autoload (autoload 'ogent-gastown-status-dispatch "ogent-gastown-status-transient" nil t)
(transient-define-prefix ogent-gastown-status-dispatch ()
  "Dispatch menu for Gas Town status buffer."
  [:description ogent-gastown-status-transient--format-header
   ["Navigate"
    ("n" "Next item" ogent-gastown-next-item :transient t)
    ("p" "Previous item" ogent-gastown-prev-item :transient t)
    ("H" "Prev rig" ogent-gastown-cycle-rig-prev :transient t)
    ("L" "Next rig" ogent-gastown-cycle-rig-next :transient t)
    ("RET" "Visit item" ogent-gastown-visit)
    ("TAB" "Toggle section" ogent-gastown-toggle-section :transient t)]
   ["Communicate"
    ("M" "Compose mail" ogent-gastown-mail-compose)
    ("m" "Read mail" ogent-gastown-status-mail-read)
    ("N" "Nudge agent" ogent-gastown-nudge)]
   ["Dispatch"
    ("S" "Sling work" ogent-gastown-sling)
    ("a" "Attach to hook" ogent-gastown-hook-attach)
    ("C" "Create convoy" ogent-gastown-convoy-create)]]
  [["Inspect"
    ("s" "Town stats" ogent-gastown-stats-show)
    ("d" "Deacon" ogent-gastown-deacon-show)
    ("w" "Witness" ogent-gastown-witness-show)
    ("R" "Crew detail" ogent-gastown-crew-status)
    ("P" "Polecat detail" ogent-gastown-polecat-status)
    ("r" "Rig status" ogent-gastown-rig-status)
    ("f" "Refinery" ogent-gastown-refinery-status)]
   ["Triage"
    ("x" "Close issue" ogent-gastown-issue-close)
    ("!" "Set priority" ogent-gastown-issue-prioritize)
    ("X" "Claim issue" ogent-gastown-issue-claim)
    ("b" "Block issue" ogent-gastown-issue-block)]
   ["Other"
    ("i" "Issues list" ogent-gastown-issues)
    ("o" "Show hook" ogent-gastown-hook-show)
    ("c" "Convoy" ogent-gastown-convoy-status)
    ("+" "Create bead" ogent-gastown-bead-create)]
   ["Refresh"
    ("g" "Refresh" ogent-gastown-refresh :transient t)
    ("G" "Force refresh" ogent-gastown-refresh-force :transient t)
    ("A" "Auto-refresh" ogent-gastown-auto-refresh-mode :transient t)
    ("q" "Quit menu" transient-quit-one)
    ("Q" "Quit buffer" quit-window)]])

(provide 'ogent-gastown-status-transient)

;;; ogent-gastown-status-transient.el ends here
