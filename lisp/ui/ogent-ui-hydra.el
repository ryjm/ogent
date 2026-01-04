;;; ogent-ui-hydra.el --- Hydra menus for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Provides hydra-based quick menus for common ogent operations:
;;
;; 1. Navigation Hydra (ogent-hydra-navigate):
;;    - n/p: Next/previous response
;;    - N/P: Next/previous request
;;    - j/k: Next/previous heading (vim-style)
;;    - g: Go to dependency graph
;;    - b: Show backlinks
;;
;; 2. Edit Hydra (ogent-hydra-edit):
;;    - a: Accept current edit
;;    - r: Reject current edit
;;    - A: Accept all edits
;;    - R: Reject all edits
;;    - n/p: Navigate between edits
;;    - d: Show diff preview
;;
;; 3. Request Hydra (ogent-hydra-request):
;;    - s: Send request
;;    - a: Abort request
;;    - r: Retry last request
;;    - c: Preview context
;;
;; Hydras provide a "sticky" interface where you can perform multiple
;; actions without re-invoking the prefix key.
;;
;; Usage:
;;   (require 'ogent-ui-hydra)
;;   ;; Hydras are automatically available when hydra is loaded

;;; Code:

(require 'cl-lib)

;; Forward declarations
(declare-function ogent-request "ogent-ui")
(declare-function ogent-abort-request "ogent-ui")
(declare-function ogent-retry-request "ogent-ui")
(declare-function ogent-context-preview "ogent-ui")
(declare-function ogent-show-backlinks "ogent-ui-backlinks")
(declare-function ogent-show-dependency-graph "ogent-ui-graph")
(declare-function ogent-edit-accept-current "ogent-edit-display")
(declare-function ogent-edit-reject-current "ogent-edit-display")
(declare-function ogent-edit-accept-all "ogent-edit-display")
(declare-function ogent-edit-reject-all "ogent-edit-display")
(declare-function ogent-edit-preview-diff "ogent-edit-display")
(declare-function ogent-edit--accept-current-dispatch "ogent-edit")
(declare-function ogent-edit--reject-current-dispatch "ogent-edit")
(declare-function ogent-edit--accept-all-dispatch "ogent-edit")
(declare-function ogent-edit--reject-all-dispatch "ogent-edit")
(declare-function ogent-edit--next-dispatch "ogent-edit")
(declare-function ogent-edit--prev-dispatch "ogent-edit")
(declare-function ogent-edit-overlay-diff "ogent-edit-display")
(declare-function ogent-edit-overlay-ediff "ogent-edit-display")
(declare-function ogent-edit-overlay-merge "ogent-edit-display")
(declare-function ogent-edit-overlay-dispatch "ogent-edit-display")
(declare-function ogent-edit-goto-source "ogent-edit-display")
(declare-function ogent-edit-goto-companion "ogent-edit-display")
(defvar ogent-edit-display-method)

;;; Customization

(defgroup ogent-hydra nil
  "Hydra menus for ogent."
  :group 'ogent)

(defcustom ogent-hydra-hint-display 'posframe
  "How to display hydra hints.
Options: `posframe' (floating), `lv' (echo area), `nil' (none)."
  :type '(choice (const :tag "Posframe (floating)" posframe)
                 (const :tag "Echo area" lv)
                 (const :tag "None" nil))
  :group 'ogent-hydra)

;;; Navigation Functions

(defun ogent-hydra--next-response ()
  "Move to next response heading."
  (interactive)
  (if (re-search-forward "^\\*+ Response" nil t)
      (org-back-to-heading t)
    (message "No more responses")))

(defun ogent-hydra--prev-response ()
  "Move to previous response heading."
  (interactive)
  (if (re-search-backward "^\\*+ Response" nil t)
      (org-back-to-heading t)
    (message "No previous responses")))

(defun ogent-hydra--next-request ()
  "Move to next request heading."
  (interactive)
  (if (re-search-forward "^\\*+ Request:" nil t)
      (org-back-to-heading t)
    (message "No more requests")))

(defun ogent-hydra--prev-request ()
  "Move to previous request heading."
  (interactive)
  (if (re-search-backward "^\\*+ Request:" nil t)
      (org-back-to-heading t)
    (message "No previous requests")))

;;; Hydra Definitions

(defvar ogent-hydra-navigate nil
  "Navigation hydra for ogent.")

(defvar ogent-hydra-edit nil
  "Edit operations hydra for ogent.")

(defvar ogent-hydra-request nil
  "Request operations hydra for ogent.")

(defun ogent-hydra--define-hydras ()
  "Define all ogent hydras. Called when hydra is loaded."
  (require 'hydra)
  
  ;; Navigation Hydra
  (defhydra ogent-hydra-navigate (:color pink :hint nil)
	    "
╭─────────────────────────────────────────────────────────────╮
│ _n_: next response   _N_: next request    _g_: dep graph    │
│ _p_: prev response   _P_: prev request    _b_: backlinks    │
│ _j_: next heading    _k_: prev heading    _o_: open block   │
╰─────────────────────────────────────────────────────────────╯
"
	    ("n" ogent-hydra--next-response)
	    ("p" ogent-hydra--prev-response)
	    ("N" ogent-hydra--next-request)
	    ("P" ogent-hydra--prev-request)
	    ("j" org-next-visible-heading)
	    ("k" org-previous-visible-heading)
	    ("g" ogent-show-dependency-graph :color blue)
	    ("b" ogent-show-backlinks :color blue)
	    ("o" org-open-at-point :color blue)
	    ("q" nil "quit" :color blue)
	    ("<escape>" nil nil :color blue))
  
  ;; Edit Hydra - uses dispatch functions that work with both smerge and overlay modes
  (defhydra ogent-hydra-edit (:color pink :hint nil)
	    "
╭─────────────────────────────────────────────────────────────╮
│ _a_: accept current  _A_: accept ALL     _d_: show diff     │
│ _r_: reject current  _R_: reject ALL     _e_: ediff         │
│ _n_: next edit       _p_: prev edit      _m_: merge (smerge)│
│ _s_: goto source     _c_: goto companion _D_: dispatch menu │
╰─────────────────────────────────────────────────────────────╯
"
	    ("a" ogent-edit--accept-current-dispatch)
	    ("r" ogent-edit--reject-current-dispatch)
	    ("A" ogent-edit--accept-all-dispatch :color blue)
	    ("R" ogent-edit--reject-all-dispatch :color blue)
	    ("n" ogent-edit--next-dispatch)
	    ("p" ogent-edit--prev-dispatch)
	    ("d" ogent-edit-overlay-diff)
	    ("e" ogent-edit-overlay-ediff :color blue)
	    ("m" ogent-edit-overlay-merge)
	    ("D" ogent-edit-overlay-dispatch)
	    ("s" ogent-edit-goto-source :color blue)
	    ("c" ogent-edit-goto-companion :color blue)
	    ("q" nil "quit" :color blue)
	    ("<escape>" nil nil :color blue))
  
  ;; Request Hydra
  (defhydra ogent-hydra-request (:color blue :hint nil)
	    "
╭─────────────────────────────────────────────────────────────╮
│ _s_: send request    _a_: abort          _c_: context       │
│ _r_: retry last      _e_: request edit   _p_: pin dwim      │
╰─────────────────────────────────────────────────────────────╯
"
	    ("s" ogent-request)
	    ("a" ogent-abort-request)
	    ("r" ogent-retry-request)
	    ("e" ogent-request-edit)
	    ("c" ogent-context-preview)
	    ("p" ogent-pin-dwim)
	    ("q" nil "quit")
	    ("<escape>" nil nil)))

;; Define hydras when hydra is loaded
(with-eval-after-load 'hydra
  (ogent-hydra--define-hydras))

;;; Interactive Commands

;;;###autoload
(defun ogent-navigate ()
  "Open the navigation hydra for quick movement."
  (interactive)
  (if (featurep 'hydra)
      (ogent-hydra-navigate/body)
    (message "Hydra not available. Install hydra package for quick navigation.")))

;;;###autoload
(defun ogent-edit-menu ()
  "Open the edit operations hydra."
  (interactive)
  (if (featurep 'hydra)
      (ogent-hydra-edit/body)
    (message "Hydra not available. Install hydra package for edit menu.")))

;;;###autoload
(defun ogent-request-menu ()
  "Open the request operations hydra."
  (interactive)
  (if (featurep 'hydra)
      (ogent-hydra-request/body)
    (message "Hydra not available. Install hydra package for request menu.")))

(provide 'ogent-ui-hydra)

;;; ogent-ui-hydra.el ends here
