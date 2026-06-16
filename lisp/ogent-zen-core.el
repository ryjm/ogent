;;; ogent-zen-core.el --- Shared base for Zen Org interaction -*- lexical-binding: t; -*-

;;; Commentary:
;; Customization, faces, shared state, and the foundational heading,
;; transcript, review-read, formatter, and response-navigation primitives
;; shared by every Zen module.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'subr-x)

(declare-function ogent-zen--preferred-response-heading "ogent-zen")
(declare-function ogent-zen--transcript-request-or-error "ogent-zen")

(defgroup ogent-zen nil
  "Zen Org interaction for ogent."
  :group 'ogent)

(defcustom ogent-zen-enable-in-org t
  "When non-nil, enable `ogent-zen-mode' with `ogent-mode' in Org buffers."
  :type 'boolean
  :group 'ogent-zen)

(defcustom ogent-zen-pretty-headings t
  "When non-nil, visually compact ogent Request/Response headings with overlays."
  :type 'boolean
  :group 'ogent-zen)

(defcustom ogent-zen-show-breadcrumbs nil
  "When non-nil, show parent breadcrumb metadata in Zen request overlays.
Generated transcripts still persist `OGENT_PATH' either way; this only
controls the extra visible breadcrumb suffix on compact run-card headings."
  :type 'boolean
  :group 'ogent-zen)

(defcustom ogent-zen-heading-actions nil
  "When non-nil, install direct action bindings on Zen heading overlays.
This experimental affordance adds overlay-local `RET', `r', `e', and
`mouse-1' bindings plus matching action hints.  Leave it nil when Evil or
other modal keymaps should own those keys."
  :type 'boolean
  :group 'ogent-zen)

(defcustom ogent-zen-bullet "•"
  "Glyph composed over leading heading stars in `ogent-zen-mode'.
Every heading level shares this quiet glyph; depth is conveyed by
`org-indent-mode' indentation.  Set to nil or an empty string to keep
plain Org stars.  Ignored when another star-styling package
\(org-modern, org-bullets, or org-superstar) is active in the buffer."
  :type '(choice (const :tag "Keep Org stars" nil) string)
  :group 'ogent-zen)

(defcustom ogent-zen-center-column nil
  "When an integer, center the notebook page at that text column.
Window margins grow symmetrically whenever a window showing the buffer
is wider than this value.  nil disables centering."
  :type '(choice (const :tag "Off" nil) integer)
  :group 'ogent-zen)

(defcustom ogent-zen-fold-noise t
  "When non-nil, fold transcript plumbing out of sight.
Property drawers, tool drawers, and prompt src blocks of Zen-generated
requests are folded on mode enable and when a new run is inserted.
User-authored drawers are never touched."
  :type 'boolean
  :group 'ogent-zen)

(defcustom ogent-zen-collapse-previous-runs t
  "When non-nil, collapse earlier runs when a new run starts.
Only sibling Zen transcripts under the same bullet are folded; the new
run stays expanded."
  :type 'boolean
  :group 'ogent-zen)

(defcustom ogent-zen-tool-calls-inline nil
  "When non-nil, render tool calls as inline `:TOOL:' drawers in Zen buffers.
The default nil records tool calls out of band and keeps them out of the
notebook buffer, so repeated prompt submissions stay responsive; inspect
them with `ogent-zen-show-tool-calls'.  Set to t to restore the legacy
inline drawers, which embed full arguments and results and bloat the
buffer as runs accumulate."
  :type 'boolean
  :group 'ogent-zen)


(defcustom ogent-zen-workspace-directives '("Context" "Workspace" "Project" "Repo")
  "Ancestor/body line labels that declare a Zen workspace root.
A line like \"Context: ~/vault/projects/ogent\" makes the path the
request workspace: it appears in the prompt, and relative ogent tool
paths resolve from it while handling tool calls."
  :type '(repeat string)
  :group 'ogent-zen)


(defcustom ogent-zen-infer-workspace-from-prose t
  "When non-nil, infer Zen workspaces from ordinary path-like prose.
For example, a bullet that says \"look in ~/repo for ideas\" selects
~/repo as the request workspace without requiring a `Context:' line."
  :type 'boolean
  :group 'ogent-zen)

(defcustom ogent-zen-force-tools-for-workspace-intent t
  "When non-nil, workspace-inspection wording asks gptel to force tool use.
This only affects requests where Zen inferred or found a workspace root
and the bullet/parents ask to look, inspect, search, ground, or reason
from the repository."
  :type 'boolean
  :group 'ogent-zen)

(defcustom ogent-zen-workspace-brief-directories
  '("lisp" "test" "docs" "specs")
  "Workspace subdirectories sampled for Zen workspace briefs."
  :type '(repeat directory)
  :group 'ogent-zen)

(defcustom ogent-zen-workspace-brief-max-files 24
  "Maximum number of recent files listed in a Zen workspace brief."
  :type 'integer
  :group 'ogent-zen)

(defcustom ogent-zen-response-summary-width 72
  "Maximum width for folded Zen response summaries in run-card headings."
  :type 'integer
  :group 'ogent-zen)

(defcustom ogent-zen-folded-result-preview t
  "When non-nil, show a muted virtual preview line under folded results."
  :type 'boolean
  :group 'ogent-zen)

(defcustom ogent-zen-result-headline-density 'rich
  "Amount of metadata shown in Zen request and response overlays.
`minimal' shows icon and title only.  `balanced' keeps outcome badges,
model chips, model, and latency.  `rich' also shows workspace, tool,
fold, selection, and action metadata.  `debug' includes raw status and
diagnostic counts."
  :type '(choice (const :tag "Minimal" minimal)
                 (const :tag "Balanced" balanced)
                 (const :tag "Rich" rich)
                 (const :tag "Debug" debug))
  :group 'ogent-zen)

(defcustom ogent-zen-right-align-metadata t
  "When non-nil, push low-priority Zen headline metadata to the right.
Right alignment is used only in graphical windows with enough columns;
small or terminal windows fall back to the normal inline suffix."
  :type 'boolean
  :group 'ogent-zen)

(defcustom ogent-zen-visual-lanes nil
  "When non-nil, also render Zen request status icons in the left margin.
Inline icons remain the canonical fallback so terminals and buffers
without margins keep the same scan targets."
  :type 'boolean
  :group 'ogent-zen)

(defcustom ogent-zen-active-animation-delay 0.4
  "Seconds between active Zen run-card animation refreshes.
Only visible buffers with waiting, tool, or typing runs are refreshed."
  :type 'number
  :group 'ogent-zen)
(defface ogent-zen-run-face
  '((t :inherit org-level-3 :weight semi-bold))
  "Face for Zen run bullets."
  :group 'ogent-zen)

(defface ogent-zen-response-face
  '((t :inherit default))
  "Face for Zen response bullets."
  :group 'ogent-zen)

(defface ogent-zen-muted-face
  '((t :inherit shadow))
  "Face for Zen secondary metadata."
  :group 'ogent-zen)

(defface ogent-zen-review-face
  '((t :inherit font-lock-constant-face :weight semi-bold))
  "Face for Zen review state badges."
  :group 'ogent-zen)

(defvar-local ogent-zen--overlays nil
  "List of active Zen presentation overlays in the current buffer.")

(defvar-local ogent-zen--enabled-org-indent nil
  "Non-nil when `ogent-zen-mode' enabled `org-indent-mode' in this buffer.")

(defvar-local ogent-zen--bullet-keywords nil
  "Font-lock keywords installed by `ogent-zen-mode' for star bullets.")

(defvar-local ogent-zen--stream-frame 0
  "Current animation frame for active Zen request overlays.")

(defvar ogent-zen--animation-timer nil
  "Timer refreshing visible active Zen request overlays.")

(cl-defstruct ogent-zen-scope
  "A Zen operation scope.
Headings define context and transcript placement; scope markers define
the text operated on by region and rewrite commands."
  kind heading-point start-marker end-marker original-text prompt-text
  breadcrumb instruction edit-p)

;;; Heading predicates

(defun ogent-zen--request-heading-p ()
  "Return non-nil when the Org heading at point is a Zen request."
  (and (org-at-heading-p)
       (string-prefix-p "Request:" (org-get-heading t t t t))
       (equal (org-entry-get (point) "OGENT_STYLE") "zen")))

(defun ogent-zen--generated-heading-p ()
  "Return non-nil when the Org heading at point is ogent-generated."
  (when (org-at-heading-p)
    (let ((heading (org-get-heading t t t t)))
      (or (equal (org-entry-get (point) "OGENT_STYLE") "zen")
          (let ((kind (org-entry-get (point) "OGENT_KIND")))
            (and kind (not (string-empty-p kind))))
          (string-prefix-p "Request:" heading)
          (string-prefix-p "Response (" heading)))))

(defun ogent-zen--heading-point ()
  "Return the user bullet heading point for the subtree at point.
When point sits inside ogent-generated transcript content, climb to the
nearest enclosing user-authored heading so running \"this bullet\" from
anywhere inside its transcript re-runs the bullet.  Return nil when
there is no heading, or no user heading above generated content."
  (save-excursion
    (condition-case nil
        (progn
          (org-back-to-heading t)
          (while (and (ogent-zen--generated-heading-p)
                      (org-up-heading-safe)))
          (and (not (ogent-zen--generated-heading-p))
               (point)))
      (error nil))))

(defun ogent-zen--transcript-request-heading ()
  "Return the position of the Zen request heading owning point, or nil."
  (save-excursion
    (condition-case nil
        (progn
          (org-back-to-heading t)
          (while (and (not (ogent-zen--request-heading-p))
                      (ogent-zen--generated-heading-p)
                      (org-up-heading-safe)))
          (when (ogent-zen--request-heading-p)
            (point)))
      (error nil))))

(defun ogent-zen--parent-zen-request-p ()
  "Return non-nil when the immediate parent is a Zen request heading."
  (save-excursion
    (when (org-up-heading-safe)
      (ogent-zen--request-heading-p))))

;;; Transcript inspection

(defun ogent-zen--subtree-end ()
  "Return the end position of the current Org subtree."
  (save-excursion
    (org-end-of-subtree t t)
    (point)))

(defun ogent-zen--subtree-error-p (end)
  "Return non-nil when the current subtree before END has ogent error output."
  (save-excursion
    (re-search-forward "^[ \t]*#\\+begin_quote[ \t]+ogent-error\\b" end t)))

(defun ogent-zen--src-meta (end)
  "Return metadata plist parsed from the request src block before END."
  (save-excursion
    (forward-line 1)
    (when (re-search-forward "^#\\+begin_src text \\(.*\\)$" end t)
      (let ((tokens (split-string (match-string-no-properties 1) "[ \t]+" t))
            meta)
        (while tokens
          (let ((key (pop tokens)))
            (when (and (string-prefix-p ":" key) tokens)
              (setq meta
                    (plist-put meta (intern key)
                               (substring-no-properties (pop tokens)))))))
        meta))))

(defun ogent-zen--src-info (end)
  "Return (STATUS . LATENCY) parsed from the request src block before END.
Both values are strings; LATENCY is nil until the run completes.
Return nil when no src block header is found."
  (let ((meta (ogent-zen--src-meta end)))
    (when meta
      (cons (plist-get meta :status) (plist-get meta :latency)))))

(defun ogent-zen--response-body-nonempty-p ()
  "Return non-nil when the Response heading at point has body text."
  (let ((body-start (save-excursion
                      (forward-line 1)
                      (point)))
        (body-end (ogent-zen--subtree-end)))
    (and (< body-start body-end)
         (not (string-empty-p
               (string-trim
                (buffer-substring-no-properties body-start body-end)))))))

(defun ogent-zen--request-has-response-body-p (end)
  "Return non-nil when the current request subtree before END has response text."
  (save-excursion
    (let (found)
      (forward-line 1)
      (while (and (not found)
                  (re-search-forward org-heading-regexp end t))
        (beginning-of-line)
        (when (string-prefix-p "Response (" (org-get-heading t t t t))
          (setq found (ogent-zen--response-body-nonempty-p)))
        (forward-line 1))
      found)))

(defun ogent-zen--request-status ()
  "Return display status for the Zen request at point.
Tool-call failures are diagnostic metadata, not catastrophic request
failures; the request turns red only when the request itself errors or
is aborted."
  (let* ((end (ogent-zen--subtree-end))
         (info (ogent-zen--src-info end))
         (src-status (car-safe info))
         (has-body (ogent-zen--request-has-response-body-p end)))
    (cond
     ((or (ogent-zen--subtree-error-p end)
          (member src-status '("error" "aborted")))
      'error)
     ((and (equal src-status "done") (not has-body))
      'empty)
     ((equal src-status "tool")
      'tool)
     ((equal src-status "typing")
      'type)
     ((and has-body (or (null src-status) (equal src-status "done")))
      'done)
     (t 'wait))))

(defun ogent-zen--response-state ()
  "Return (STATUS . LATENCY) for the Zen response at point.
STATUS is one of the symbols `wait', `tool', `type', `done',
`empty', or `error'."
  (let* ((end (ogent-zen--subtree-end))
         (has-body (ogent-zen--response-body-nonempty-p))
         (info (save-excursion
                 (when (org-up-heading-safe)
                   (ogent-zen--src-info (ogent-zen--subtree-end)))))
         (src-status (car-safe info)))
    (cons
     (cond
      ((or (ogent-zen--subtree-error-p end)
           (member src-status '("error" "aborted")))
       'error)
      ((and (equal src-status "done") (not has-body))
       'empty)
      ((equal src-status "tool")
       'tool)
      ((and has-body (or (null src-status) (equal src-status "done")))
       'done)
      ((equal src-status "typing")
       'type)
      (t 'wait))
     (cdr-safe info))))

(defun ogent-zen--response-model-id (heading)
  "Return response model id parsed from HEADING."
  (if (string-match "\\`Response (\\([^)]*\\))" heading)
      (match-string 1 heading)
    heading))


(defun ogent-zen--path-leaf (path)
  "Return the leaf component of a Zen breadcrumb PATH."
  (substring-no-properties
   (or (car (last (split-string (or path "") "[ \t]*›[ \t]*" t))) "")))

(defun ogent-zen--request-display-title (fallback)
  "Return best compact title for FALLBACK request text."
  (let ((path-leaf (ogent-zen--path-leaf (org-entry-get (point) "OGENT_PATH"))))
    (truncate-string-to-width
     (if (and path-leaf (not (string-empty-p path-leaf)))
         path-leaf
       fallback)
     72 nil nil "...")))

(defun ogent-zen--path-parent-label (path)
  "Return a compact parent breadcrumb label for PATH."
  (let ((parts (split-string (or path "") "[ \t]*›[ \t]*" t)))
    (when (> (length parts) 1)
      (truncate-string-to-width
       (string-join (butlast parts) " › ") 36 nil nil "..."))))

(defconst ogent-zen--review-states
  '((accepted . ("◆" "accepted"))
    (useful . ("◆" "useful"))
    (needs-review . ("◇" "review"))
    (stale . ("◇" "stale"))
    (superseded . ("◇" "superseded"))
    (rejected . ("◇" "rejected"))
    (failed . ("✗" "failed")))
  "Legacy review badges rendered in Zen result headlines.")

(defun ogent-zen--entry-symbol (property &optional target)
  "Return PROPERTY as a normalized symbol at TARGET or point."
  (let ((raw (org-entry-get (or target (point)) property)))
    (when raw
      (intern (downcase (string-trim raw))))))

(defun ogent-zen--review-decision (&optional target)
  "Return `OGENT_DECISION' at TARGET or point."
  (ogent-zen--entry-symbol "OGENT_DECISION" target))

(defun ogent-zen--review-status-value (&optional target)
  "Return `OGENT_REVIEW_STATUS' at TARGET or point."
  (ogent-zen--entry-symbol "OGENT_REVIEW_STATUS" target))

(defun ogent-zen--review-usefulness (&optional target)
  "Return `OGENT_USEFULNESS' at TARGET or point."
  (ogent-zen--entry-symbol "OGENT_USEFULNESS" target))

(defun ogent-zen--review-lineage (&optional target)
  "Return `OGENT_LINEAGE' at TARGET or point."
  (or (ogent-zen--entry-symbol "OGENT_LINEAGE" target)
      (let ((legacy (ogent-zen--entry-symbol "OGENT_REVIEW" target)))
        (and (memq legacy '(stale superseded)) legacy))))

(defun ogent-zen--review-outcome (&optional target)
  "Return `OGENT_OUTCOME' at TARGET or point."
  (or (ogent-zen--entry-symbol "OGENT_OUTCOME" target)
      (save-excursion
        (when target
          (goto-char target))
        (pcase (if (ogent-zen--response-heading-p)
                   (car (ogent-zen--response-state))
                 (ogent-zen--request-status))
          ('error 'failed)
          ('empty 'empty)
          (_ nil)))))

(defun ogent-zen--legacy-review-state (&optional target)
  "Return legacy `OGENT_REVIEW' at TARGET or point."
  (let ((state (ogent-zen--entry-symbol "OGENT_REVIEW" target)))
    (when (assq state ogent-zen--review-states)
      state)))

(defun ogent-zen--effective-review-state (&optional target)
  "Return the primary review state at TARGET or point."
  (or (let ((decision (ogent-zen--review-decision target)))
        (and (memq decision '(accepted rejected)) decision))
      (let ((usefulness (ogent-zen--review-usefulness target)))
        (and (eq usefulness 'useful) usefulness))
      (let ((status (ogent-zen--review-status-value target)))
        (and (eq status 'needs-review) status))
      (let ((lineage (ogent-zen--review-lineage target)))
        (and (memq lineage '(stale superseded)) lineage))
      (let ((outcome (ogent-zen--review-outcome target)))
        (and (eq outcome 'failed) outcome))
      (ogent-zen--legacy-review-state target)))

(defun ogent-zen--review-state ()
  "Return the primary review state at point."
  (ogent-zen--effective-review-state))

(defun ogent-zen--review-badge (state)
  "Return a propertized review badge for STATE."
  (when-let ((entry (cdr (assq state ogent-zen--review-states))))
    (propertize (format "%s %s" (car entry) (cadr entry))
                'face 'ogent-zen-review-face)))

(defun ogent-zen--response-review-badge (model state)
  "Return a propertized review badge for response MODEL in STATE."
  (when-let ((entry (cdr (assq state ogent-zen--review-states))))
    (propertize (format "%s %s %s" (car entry) model (cadr entry))
                'face 'ogent-zen-review-face)))

(defun ogent-zen--review-badges (&optional target)
  "Return visible review badges for TARGET or point."
  (let* ((states (delq nil
                       (list (let ((decision (ogent-zen--review-decision target)))
                               (and (memq decision '(accepted rejected))
                                    decision))
                             (let ((usefulness
                                    (ogent-zen--review-usefulness target)))
                               (and (eq usefulness 'useful) usefulness))
                             (let ((status
                                    (ogent-zen--review-status-value target)))
                               (and (eq status 'needs-review) status))
                             (let ((lineage (ogent-zen--review-lineage target)))
                               (and (memq lineage '(stale superseded)) lineage))
                             (let ((outcome (ogent-zen--review-outcome target)))
                               (and (eq outcome 'failed) outcome)))))
         (states (if states
                     (cl-delete-duplicates states :test #'eq)
                   (let ((legacy (ogent-zen--legacy-review-state target)))
                     (and legacy (list legacy))))))
    (mapcar #'ogent-zen--review-badge states)))

(defun ogent-zen--suffix (parts)
  "Return a propertized suffix from PARTS."
  (when-let ((parts (delq nil
                          (mapcar (lambda (part)
                                    (and (stringp part)
                                         (not (string-empty-p part))
                                         part))
                                  parts))))
    (string-join
     (mapcar (lambda (part)
               (if (get-text-property 0 'face part)
                   part
                 (propertize part 'face 'ogent-zen-muted-face)))
             parts)
     (propertize " · " 'face 'ogent-zen-muted-face))))

(defun ogent-zen--status-label (status &optional tool-error)
  "Return a short text label for STATUS.
When TOOL-ERROR is non-nil, describe `error' as a tool failure."
  (pcase status
    ('wait "waiting")
    ('tool "using tools")
    ('type "writing")
    ('empty "empty response")
    ('error (if tool-error "tool error" "failed"))
    (_ nil)))

(defun ogent-zen--stream-icon-name ()
  "Return the current stream icon symbol for active Zen requests."
  (intern (format "stream-%d" (mod ogent-zen--stream-frame 4))))

(defun ogent-zen--status-icon-parts (status)
  "Return (ICON-NAME FALLBACK FACE-STATUS) for STATUS."
  (pcase status
    ('done '(done "✓" done))
    ('error '(error "✗" error))
    ('empty '(warning "⚠" warning))
    ('tool (list (ogent-zen--stream-icon-name) "◐" 'type))
    ('type (list (ogent-zen--stream-icon-name) "✎" 'type))
    (_ '(priority-3 "○" wait))))

(defun ogent-zen--tool-context-area (context)
  "Return the first path component from tool CONTEXT, or nil."
  (when (and (stringp context)
             (string-match "\\`\\([^~/[:space:]:][^/:[:space:]]+\\)/" context))
    (match-string 1 context)))

(defun ogent-zen--workspace-label (&optional tool-infos)
  "Return a compact workspace label for the current Zen request.
When TOOL-INFOS mostly point into one top-level directory, include that
area as `repo:area/'."
  (when-let ((root (org-entry-get (point) "OGENT_WORKSPACE_ROOT")))
    (let* ((repo (file-name-nondirectory (directory-file-name root)))
           (areas (delq nil
                        (mapcar (lambda (info)
                                  (ogent-zen--tool-context-area
                                   (plist-get info :context)))
                                tool-infos)))
           (area (and areas
                      (car areas)
                      (cl-every (lambda (candidate)
                                  (equal candidate (car areas)))
                                (cdr areas))
                      (car areas))))
      (if area
          (format "%s:%s/" repo area)
        (concat repo "/")))))

(defun ogent-zen--tool-status-from-icon (icon)
  "Return a tool status symbol for status ICON."
  (pcase icon
    ("✗" 'error)
    ("◐" 'running)
    ("○" 'pending)
    ("✓" 'done)
    (_ nil)))

(defun ogent-zen--char-count-label (chars)
  "Return a compact label for CHARS characters."
  (cond
   ((not (natnump chars)) nil)
   ((>= chars 1000) (format "%.1fk chars" (/ chars 1000.0)))
   (t (format "%d chars" chars))))

(defun ogent-zen--detail-snippet (text &optional width)
  "Return a compact single-line diagnostic snippet from TEXT.
WIDTH defaults to 48 columns."
  (when (stringp text)
    (let ((snippet (string-trim
                    (replace-regexp-in-string
                     "[ \t\n\r]+" " " text))))
      (unless (string-empty-p snippet)
        (truncate-string-to-width snippet (or width 48) nil nil "...")))))

(defun ogent-zen--skip-drawer-at-point (end &optional names)
  "Skip an Org drawer at point before END when its name is in NAMES.
When NAMES is nil, skip any drawer.  Return non-nil when point moved."
  (when (looking-at "^[ \t]*:\\([[:alnum:]_-]+\\):[ \t]*$")
    (let ((name (upcase (match-string-no-properties 1)))
          (start (point)))
      (if (and (or (null names) (member name names))
               (re-search-forward "^[ \t]*:END:[ \t]*$" end t))
          (progn
            (forward-line 1)
            t)
        (goto-char start)
        nil))))

(defun ogent-zen--skip-source-block-at-point (end)
  "Skip an Org source block at point before END.
Return non-nil when point moved."
  (when (looking-at "^[ \t]*#\\+begin_src\\b")
    (let ((start (point)))
      (if (re-search-forward "^[ \t]*#\\+end_src\\b" end t)
          (progn
            (forward-line 1)
            t)
        (goto-char start)
        nil))))

(defun ogent-zen--strip-summary-quotes (summary)
  "Return SUMMARY without surrounding smart or plain quotes."
  (when (stringp summary)
    (let ((plain (substring-no-properties summary)))
      (if (string-match "\\`[“\"]\\(.*\\)[”\"]\\'" plain)
          (match-string 1 plain)
        plain))))

(defun ogent-zen--result-title-clean (text)
  "Return TEXT as a compact result title."
  (when-let ((title (ogent-zen--detail-snippet
                    (replace-regexp-in-string
                     "[`*_~=]" "" (or text ""))
                    ogent-zen-response-summary-width)))
    (unless (string-empty-p title)
      title)))

(defun ogent-zen--response-title-from-text (text)
  "Return a deterministic local title derived from response TEXT."
  (when (stringp text)
    (let* ((lines (split-string text "\n"))
           (heading
            (cl-loop for line in lines
                     when (string-match
                           "^[ \t]*\\(?:#+\\|\\*+\\)[ \t]+\\(.+\\)$" line)
                     return (match-string 1 line)))
           (flat (string-trim
                  (replace-regexp-in-string "[ \t\n\r]+" " " text)))
           (sentence
            (when (string-match
                   "\\`\\(.+?[.!?]\\)\\(?:[ \t\n\r]\\|\\'\\)" flat)
              (match-string 1 flat)))
           (first-line
            (cl-loop for line in lines
                     for trimmed = (string-trim line)
                     unless (or (string-empty-p trimmed)
                                (string-prefix-p "#+" trimmed)
                                (string-prefix-p ":" trimmed))
                     return trimmed)))
      (ogent-zen--result-title-clean
       (or heading sentence first-line)))))

(defun ogent-zen--breadcrumb (point)
  "Return a display breadcrumb for the Org heading at POINT."
  (save-excursion
    (goto-char point)
    (org-back-to-heading t)
    (let ((parts (list (substring-no-properties (org-get-heading t t t t)))))
      (while (org-up-heading-safe)
        (push (substring-no-properties (org-get-heading t t t t)) parts))
      (string-join parts " › "))))

(defun ogent-zen--marker-position (marker)
  "Return MARKER's live position, or nil."
  (and (markerp marker)
       (marker-buffer marker)
       (marker-position marker)))

(defun ogent-zen--scope-text (beg end)
  "Return buffer text between BEG and END without text properties."
  (buffer-substring-no-properties beg end))

(defun ogent-zen--own-body (content)
  "Return CONTENT trimmed to the heading's own body text.
Everything from the first child heading onward is dropped — child
bullets and generated transcripts alike — and a leading property
drawer is removed.  This keeps each parent bullet's contribution to
the payload flat: without it, nested ancestors would repeat each
other's subtrees and re-runs would embed prior transcripts."
  (let ((own (if (string-match "^\\*+ " content)
                 (substring content 0 (match-beginning 0))
               content)))
    (when (string-match
           "\\`[ \t]*:PROPERTIES:[ \t]*\n\\(?:.*\n\\)*?[ \t]*:END:[ \t]*\n?"
           own)
      (setq own (replace-match "" t t own)))
    (string-trim own)))

;;; Commands

(defun ogent-zen--response-heading-p ()
  "Return non-nil when the Org heading at point is a Zen response."
  (and (org-at-heading-p)
       (string-prefix-p "Response (" (org-get-heading t t t t))
       (ogent-zen--parent-zen-request-p)))

(defun ogent-zen--current-response-heading ()
  "Return the Zen response heading containing point, or nil."
  (save-excursion
    (condition-case nil
        (progn
          (org-back-to-heading t)
          (when (ogent-zen--response-heading-p)
            (point)))
      (error nil))))

(defun ogent-zen--first-response-heading (request)
  "Return the first response child heading under Zen REQUEST, or nil."
  (save-excursion
    (goto-char request)
    (let ((end (ogent-zen--subtree-end))
          (level (org-current-level))
          response)
      (forward-line 1)
      (while (and (not response)
                  (re-search-forward org-heading-regexp end t))
        (beginning-of-line)
        (when (and (= (org-current-level) (1+ level))
                   (string-prefix-p "Response (" (org-get-heading t t t t)))
          (setq response (point)))
        (forward-line 1))
      response)))

(defun ogent-zen--response-heading-or-error ()
  "Return the Zen response heading relevant to point, or signal an error."
  (or (ogent-zen--current-response-heading)
      (let ((request (ogent-zen--transcript-request-or-error)))
        (or (ogent-zen--first-response-heading request)
            (user-error "This Zen transcript has no response")))))

(defun ogent-zen--response-body-text (response)
  "Return RESPONSE body text without generated tool drawers."
  (save-excursion
    (goto-char response)
    (let ((start (progn
                   (forward-line 1)
                   (point)))
          (end (save-excursion
                 (goto-char response)
                 (org-end-of-subtree t t)
                 (point)))
          chunks)
      (goto-char start)
      (while (< (point) end)
        (cond
         ((ogent-zen--skip-drawer-at-point end '("TOOL")))
         (t
          (push (buffer-substring-no-properties
                 (line-beginning-position)
                 (min end (1+ (line-end-position))))
                chunks)
          (forward-line 1))))
      (let ((text (string-trim-right (apply #'concat (nreverse chunks)))))
        (replace-regexp-in-string "\\`\\(?:[ \t]*\n\\)+" "" text)))))

(defun ogent-zen-store-result-title (request)
  "Store a deterministic `OGENT_RESULT_TITLE' for Zen REQUEST.
The title is derived locally from the selected response when present, or
the first response otherwise.  Existing transcripts keep working because
display code falls back when this property is absent."
  (save-excursion
    (goto-char request)
    (when (ogent-zen--request-heading-p)
      (let* ((end (ogent-zen--subtree-end))
             (response (ogent-zen--preferred-response-heading end))
             (title (and response
                         (ogent-zen--response-title-from-text
                          (ogent-zen--response-body-text response)))))
        (when title
          (org-entry-put request "OGENT_RESULT_TITLE" title))
        title))))

(provide 'ogent-zen-core)
;;; ogent-zen-core.el ends here
