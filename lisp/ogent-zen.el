;;; ogent-zen.el --- Zen Org interaction for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; ogent-zen turns a plain Org buffer into a quiet notebook: write normal
;; bullets, run any bullet as a prompt with `ogent-run-subtree', and read
;; the result as a compact nested transcript.  Parent bullets travel with
;; the run as explicit context.  All presentation is overlays, folds, and
;; star compositions; the stored text remains a standard `Request:' /
;; `Response (...)' transcript so history replay and regex helpers keep
;; working unchanged.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'subr-x)
(require 'ogent-context)
(require 'ogent-ui-theme)
(require 'inline-diff)
(require 'ogent-zen-core)
(require 'ogent-zen-tools)

(declare-function ogent-ui--dispatch-request "ui/ogent-ui"
                  (source-buffer region-start region-end raw-prompt
                                 models preset templates
                                 &optional org-point context-transform))
(declare-function ogent-status--get-face "ui/ogent-ui-status" (status))
(declare-function org-fold-region "org-fold" (from to flag &optional spec))
(declare-function org-fold-hide-subtree "org-fold")
(declare-function org-fold-show-subtree "org-fold")
(declare-function ogent-completion-next "ogent-completions")
(declare-function ogent-completion-prev "ogent-completions")
(declare-function ogent-completion-reject "ogent-completions")

;; Autoloaded entry points relocated to extracted Zen modules.
;;;###autoload (autoload 'ogent-zen-show-tool-calls "ogent-zen" nil t)

(cl-defstruct ogent-zen-edit-preview
  "A pending inline edit preview created from a Zen response."
  request-marker target-start-marker target-end-marker old-text new-text
  status scope-kind)

(defvar-local ogent-zen-edit--pending-preview nil
  "Latest pending Zen inline edit preview in the current buffer.")

(defun ogent-zen--tool-active-label (info)
  "Return an active tool label for tool INFO."
  (let* ((name (or (plist-get info :name) "tool"))
         (context (truncate-string-to-width
                   (or (plist-get info :context) "") 32 nil nil "..."))
         (target (if (string-empty-p context) name context))
         (lower (downcase name)))
    (cond
     ((member lower '("read" "read-file")) (format "reading %s" target))
     ((member lower '("grep" "search")) (format "searching %s" target))
     ((string= lower "bash") (format "bash %s" target))
     ((string= lower "edit") (format "editing %s" target))
     ((string= lower "write") (format "writing %s" target))
     (t (if (string-empty-p context)
            name
          (format "%s %s" name context))))))

(defun ogent-zen--request-tool-label (status infos end)
  "Return a concrete tool-use label for STATUS, tool INFOS, and END."
  (let* ((error-info (cl-find-if
                      (lambda (info)
                        (eq (plist-get info :status) 'error))
                      infos))
         (active-info (car (last (cl-remove-if-not
                                  (lambda (info)
                                    (memq (plist-get info :status)
                                          '(running pending)))
                                  infos))))
         (count (length infos))
         (explicit (ogent-zen--request-tool-grounded-p end)))
    (cond
     (error-info
      (let ((detail (plist-get error-info :error-detail)))
        (if (and detail (not (string-empty-p detail)))
            (format "tool error: %s · %s"
                    (plist-get error-info :name) detail)
          (format "tool error: %s" (plist-get error-info :name)))))
     ((and active-info (memq status '(wait tool type)))
      (ogent-zen--tool-active-label active-info))
     ((> count 1)
      (format "%d tools" count))
     ((= count 1)
      "1 tool")
     (explicit "tools"))))

(defun ogent-zen--subtree-folded-p ()
  "Return non-nil when the current Org subtree is folded at its heading."
  (save-excursion
    (end-of-line)
    (and (< (point) (point-max))
         (invisible-p (1+ (point))))))

(defun ogent-zen--request-error-message (end)
  "Return the first ogent error quote body in the current request before END."
  (save-excursion
    (forward-line 1)
    (when (re-search-forward
           "^[ \t]*#\\+begin_quote[ \t]+ogent-error\\b.*$" end t)
      (let ((start (progn
                     (forward-line 1)
                     (point))))
        (when (re-search-forward "^[ \t]*#\\+end_quote\\b" end t)
          (string-trim
           (buffer-substring-no-properties
            start (line-beginning-position))))))))

(defun ogent-zen--request-error-labels (src-status end)
  "Return diagnostic labels for SRC-STATUS and error content before END."
  (let* ((message (ogent-zen--request-error-message end))
         (detail (ogent-zen--detail-snippet message))
         (lower (downcase (or message ""))))
    (cond
     ((or (equal src-status "aborted")
          (string-match-p "abort\\|cancel" lower))
      (list "aborted" (or (and detail
                               (if (string-match-p "aborted by user" lower)
                                   "user cancelled"
                                 detail))
                          "user cancelled")))
     ((string-match-p
       "network\\|transport\\|econn\\|connection\\|timeout\\|dns\\|tls\\|ssl"
       lower)
      (list "network error" detail))
     ((or detail (string-match-p "\\b429\\b\\|rate limit\\|quota" lower))
      (list "model error" detail))
     (t
      (list "failed")))))

(defun ogent-zen--request-status-labels (status meta end)
  "Return diagnostic status labels for request STATUS, META, and END."
  (pcase status
    ('empty
     (list (or (ogent-zen--char-count-label
                (ogent-zen--request-response-char-count end))
               "0 chars")))
    ('error
     (ogent-zen--request-error-labels (plist-get meta :status) end))
    (_
     (list (ogent-zen--status-label status)))))

(defun ogent-zen--request-response-char-count (end)
  "Return the trimmed response body length in the current request before END."
  (save-excursion
    (let (count)
      (forward-line 1)
      (while (and (not count)
                  (re-search-forward org-heading-regexp end t))
        (beginning-of-line)
        (when (string-prefix-p "Response (" (org-get-heading t t t t))
          (setq count
                (length
                 (string-trim
                  (ogent-zen--response-body-text (point))))))
        (forward-line 1))
      count)))

(defun ogent-zen--preferred-response-heading (end)
  "Return the selected or first response child before END for this request."
  (save-excursion
    (let ((request-level (org-current-level))
          (selected-model (org-entry-get (point) "OGENT_SELECTED_MODEL"))
          first selected)
      (forward-line 1)
      (while (and (not selected)
                  (re-search-forward org-heading-regexp end t))
        (beginning-of-line)
        (when (and (= (org-current-level) (1+ request-level))
                   (string-prefix-p "Response (" (org-get-heading t t t t)))
          (let ((model (ogent-zen--response-model-id
                        (org-get-heading t t t t))))
            (unless first
              (setq first (point)))
            (when (and selected-model (equal selected-model model))
              (setq selected (point)))))
        (forward-line 1))
      (or selected first))))

(defun ogent-zen--response-summary-at (response)
  "Return a quoted compact semantic summary for RESPONSE."
  (save-excursion
    (goto-char response)
    (let ((body-end (ogent-zen--subtree-end))
          summary)
      (forward-line 1)
      (while (and (not summary) (< (point) body-end))
        (cond
         ((ogent-zen--skip-drawer-at-point body-end '("TOOL" "PROPERTIES")))
         ((ogent-zen--skip-source-block-at-point body-end))
         (t
          (let ((line (string-trim
                       (buffer-substring-no-properties
                        (line-beginning-position)
                        (line-end-position)))))
            (unless (or (string-empty-p line)
                        (string-prefix-p "*" line)
                        (string-prefix-p "#+" line)
                        (string-prefix-p ":" line))
              (setq summary
                    (format "“%s”"
                            (truncate-string-to-width
                             line ogent-zen-response-summary-width
                             nil nil "...")))))
          (forward-line 1))))
      summary)))

(defun ogent-zen--response-summary (end)
  "Return a compact semantic summary from the preferred response before END."
  (when-let ((response (ogent-zen--preferred-response-heading end)))
    (ogent-zen--response-summary-at response)))

(defun ogent-zen--folded-result-title (end stats)
  "Return the unquoted result title for current request before END and STATS."
  (or (ogent-zen--result-title-clean
       (org-entry-get (point) "OGENT_RESULT_TITLE"))
      (ogent-zen--response-aggregate-label 'done stats)
      (ogent-zen--result-title-clean
       (ogent-zen--strip-summary-quotes
        (ogent-zen--response-summary end)))
      (ogent-zen--char-count-label
       (ogent-zen--request-response-char-count end))))

(defun ogent-zen--response-stats (end)
  "Return aggregate response stats for the current request before END."
  (save-excursion
    (let ((request-level (org-current-level))
          (selected-model (org-entry-get (point) "OGENT_SELECTED_MODEL"))
          (count 0)
          (done 0)
          (failed 0)
          (active 0)
          (empty 0)
          selected
          models)
      (forward-line 1)
      (while (re-search-forward org-heading-regexp end t)
        (beginning-of-line)
        (when (and (= (org-current-level) (1+ request-level))
                   (string-prefix-p "Response (" (org-get-heading t t t t)))
          (let* ((heading (org-get-heading t t t t))
                 (model (ogent-zen--response-model-id heading))
                 (review (ogent-zen--effective-review-state))
                 (state (car (ogent-zen--response-state)))
                 (selectedp (and selected-model
                                 (equal selected-model model))))
            (cl-incf count)
            (pcase state
              ('done (cl-incf done))
              ('error (cl-incf failed))
              ('empty (cl-incf empty))
              (_ (cl-incf active)))
            (push (list :model model
                        :status state
                        :review review
                        :selected selectedp)
                  models)
            (when selectedp
              (setq selected
                    (ogent-zen--response-review-badge
                     model (or review 'accepted))))
            (when (and (not selected)
                       (memq review '(accepted useful needs-review
                                               rejected failed)))
              (setq selected (ogent-zen--response-review-badge
                              model review)))))
        (forward-line 1))
      (list :count count :done done :failed failed
            :active active :empty empty :selected selected
            :models (nreverse models)))))

(defun ogent-zen--response-aggregate-label (status stats)
  "Return a compact aggregate response label for STATUS and STATS."
  (let ((count (plist-get stats :count))
        (done (plist-get stats :done))
        (failed (plist-get stats :failed)))
    (cond
     ((<= count 1) nil)
     ((> failed 0)
      (format "%d failed, %d done" failed done))
     ((= done count)
      (format "%d responses" count))
     ((> done 0)
      (format "%d/%d done" done count))
     ((memq status '(wait tool type))
      (format "%d models writing" count)))))

(defun ogent-zen--folded-result-label (end stats)
  "Return the folded result summary for current request before END and STATS."
  (ogent-zen--folded-result-title end stats))

(defun ogent-zen--action-hints (status folded)
  "Return optional action hint labels for STATUS and FOLDED state."
  (when ogent-zen-heading-actions
    (delq nil
          (list (when (memq status '(done error empty))
                  "r rerun")
                "u review"
                (if folded "RET expand" "RET fold")))))

(defun ogent-zen--model-chip-name (model)
  "Return compact display name for MODEL in a headline chip."
  (truncate-string-to-width (or model "model") 12 nil nil "..."))

(defun ogent-zen--response-chip (model-info)
  "Return a compact model chip for MODEL-INFO."
  (let* ((model (plist-get model-info :model))
         (status (plist-get model-info :status))
         (review (plist-get model-info :review))
         (selected (plist-get model-info :selected))
         (icon (nth 1 (ogent-zen--status-icon-parts status)))
         (glyph (cond
                 ((or selected (memq review '(accepted useful))) "✓")
                 ((memq review '(needs-review stale superseded rejected)) "◇")
                 (t icon)))
         (face (cond
                ((or selected (memq review '(accepted useful needs-review)))
                 'ogent-zen-review-face)
                ((eq status 'error)
                 (ogent-zen--compose-face 'ogent-zen-muted-face 'error))
                (t 'ogent-zen-muted-face))))
    (propertize (format "[%s %s]"
                        (ogent-zen--model-chip-name model)
                        glyph)
                'face face)))

(defun ogent-zen--response-chips (stats)
  "Return model chips for multi-response STATS."
  (when (> (or (plist-get stats :count) 0) 1)
    (string-join
     (mapcar #'ogent-zen--response-chip
             (plist-get stats :models))
     " ")))

(defun ogent-zen--sibling-run-position-label (_review)
  "Return a lineage label for the current request."
  (if (eq (ogent-zen--review-lineage) 'superseded)
      "superseded by newer run"
    (save-excursion
      (let ((self (point))
            requests
            has-superseded)
        (org-back-to-heading t)
        (let ((level (org-current-level)))
          (when (org-up-heading-safe)
            (let ((end (ogent-zen--subtree-end)))
              (while (and (outline-next-heading) (< (point) end))
                (when (and (= (org-current-level) level)
                           (ogent-zen--request-heading-p))
                  (push (point) requests)
                  (when (eq (ogent-zen--review-lineage) 'superseded)
                    (setq has-superseded t)))))))
        (setq requests (nreverse requests))
        (when (and has-superseded (> (length requests) 1))
          (if (= self (car (last requests)))
              "latest"
            "previous"))))))

(defun ogent-zen--active-tool-info-p (info)
  "Return non-nil when tool INFO is pending or running."
  (memq (plist-get info :status) '(running pending)))

(defun ogent-zen--request-active-primary-label (status tool-infos tool-label)
  "Return a primary transient label for STATUS, TOOL-INFOS, and TOOL-LABEL."
  (let ((active (cl-find-if #'ogent-zen--active-tool-info-p tool-infos))
        (count (length tool-infos)))
    (cond
     ((and active (memq status '(wait tool type)))
      (ogent-zen--tool-active-label active))
     ((eq status 'type)
      (if (> count 0)
          (format "writing answer · %d %s used"
                  count (if (= count 1) "tool" "tools"))
        "writing answer"))
     ((and (eq status 'tool) tool-label
           (not (string-prefix-p "tool error:" tool-label)))
      "using tools"))))

(defun ogent-zen--quote-title (title)
  "Return TITLE as a short quoted label."
  (format "“%s”"
          (truncate-string-to-width
           (substring-no-properties (or title "request"))
           36 nil nil "...")))

(defun ogent-zen--request-primary-title (fallback status folded end stats
                                                  active-label)
  "Return the request headline title for FALLBACK and display state.
STATUS, FOLDED, END, STATS, and ACTIVE-LABEL decide whether the title is
prompt-first, result-first, or transient-work-first."
  (let ((prompt-title (ogent-zen--request-display-title fallback)))
    (truncate-string-to-width
     (cond
      (active-label
       (format "%s · %s" active-label prompt-title))
      ((and folded (eq status 'done))
       (if-let ((result-title (ogent-zen--folded-result-title end stats)))
           (format "%s · from %s"
                   result-title
                   (ogent-zen--quote-title prompt-title))
         prompt-title))
      (t prompt-title))
     96 nil nil "...")))

(defun ogent-zen--request-preview-after-string (status folded end)
  "Return a virtual preview line for STATUS, FOLDED, and END."
  (when (and ogent-zen-folded-result-preview
             folded
             (eq status 'done))
    (when-let ((summary (ogent-zen--response-summary end)))
      (concat "\n"
              (propertize (format "  %s" summary)
                          'face 'ogent-zen-muted-face)))))

(defun ogent-zen--valid-density ()
  "Return the active Zen headline density."
  (if (memq ogent-zen-result-headline-density
            '(minimal balanced rich debug))
      ogent-zen-result-headline-density
    'rich))

(defun ogent-zen--right-alignable-p ()
  "Return non-nil when right-aligned overlay metadata should be used."
  (and ogent-zen-right-align-metadata
       (display-graphic-p)
       (>= (window-body-width nil t) 100)))

(defun ogent-zen--suffix-lanes (left-parts right-parts)
  "Return a suffix with LEFT-PARTS and lower-priority RIGHT-PARTS."
  (let ((left (ogent-zen--suffix left-parts))
        (right (ogent-zen--suffix right-parts)))
    (cond
     ((and left right (ogent-zen--right-alignable-p))
      (concat left
              (propertize
               " "
               'display
               `(space :align-to
                       (- right ,(1+ (string-width
                                      (substring-no-properties right))))))
              right))
     ((and left right)
      (concat left
              (propertize " · " 'face 'ogent-zen-muted-face)
              right))
     (left left)
     (right right))))

(defun ogent-zen--request-display-parts (status meta)
  "Return semantic display parts for request STATUS and META."
  (let* ((end (ogent-zen--subtree-end))
         (path (org-entry-get (point) "OGENT_PATH"))
         (review (ogent-zen--review-state))
         (review-badges (ogent-zen--review-badges))
         (folded (ogent-zen--subtree-folded-p))
         (tool-infos (ogent-zen--request-tool-infos end))
         (tool-label (ogent-zen--request-tool-label status tool-infos end))
         (tool-error (and tool-label
                          (string-prefix-p "tool error:" tool-label)))
         (active-label
          (ogent-zen--request-active-primary-label
           status tool-infos tool-label))
         (workspace (unless tool-error
                      (ogent-zen--workspace-label tool-infos)))
         (stats (ogent-zen--response-stats end))
         (aggregate (ogent-zen--response-aggregate-label status stats))
         (chips (ogent-zen--response-chips stats))
         (selected (and (> (or (plist-get stats :count) 0) 1)
                        (plist-get stats :selected)))
         (lineage (ogent-zen--sibling-run-position-label review))
         (status-labels
          (unless (or tool-error active-label)
            (ogent-zen--request-status-labels status meta end)))
         (debug-status
          (when (eq (ogent-zen--valid-density) 'debug)
            (format "raw %s" (or (plist-get meta :status) status)))))
    (list :end end
          :path path
          :review review
          :review-badges review-badges
          :folded folded
          :tool-infos tool-infos
          :tool-label tool-label
          :tool-error tool-error
          :active-label active-label
          :workspace workspace
          :stats stats
          :aggregate aggregate
          :chips chips
          :selected selected
          :lineage lineage
          :status-labels status-labels
          :debug-status debug-status)))

(defun ogent-zen--request-help (status meta parts)
  "Return help text for a Zen request overlay.
STATUS is the display status, META is parsed src-block metadata, and
PARTS is the semantic display plist."
  (let* ((path (plist-get parts :path))
         (workspace (plist-get parts :workspace))
         (stats (plist-get parts :stats))
         (tool-label (plist-get parts :tool-label)))
    (string-join
     (delq nil
           (list (when path (format "Bullet: %s" path))
                 (when workspace (format "Workspace: %s" workspace))
                 (when (plist-get meta :model)
                   (format "Model: %s" (plist-get meta :model)))
                 (when (plist-get meta :latency)
                   (format "Latency: %s" (plist-get meta :latency)))
                 (when tool-label (format "Tools: %s" tool-label))
                 (when (> (or (plist-get stats :count) 0) 0)
                   (format "Responses: %d done, %d active, %d failed"
                           (or (plist-get stats :done) 0)
                           (or (plist-get stats :active) 0)
                           (or (plist-get stats :failed) 0)))
                 (format "Status: %s"
                         (or (ogent-zen--status-label status) "done"))
                 (format "Density: %s" (ogent-zen--valid-density))
                 (when ogent-zen-heading-actions
                   "RET/mouse-1: fold or expand; r: rerun; u: review; e: error")))
     "\n")))

(defun ogent-zen--request-suffix (status meta &optional parts)
  "Return the muted suffix for a Zen request STATUS and META.
PARTS, when non-nil, is the value from `ogent-zen--request-display-parts'."
  (let* ((parts (or parts (ogent-zen--request-display-parts status meta)))
         (density (ogent-zen--valid-density))
         (folded (plist-get parts :folded))
         (lineage (plist-get parts :lineage))
         (tool-label (plist-get parts :tool-label))
         (tool-error (plist-get parts :tool-error))
         (active-label (plist-get parts :active-label))
         (workspace (plist-get parts :workspace))
         (stats (plist-get parts :stats))
         (aggregate (plist-get parts :aggregate))
         (chips (plist-get parts :chips))
         (selected (plist-get parts :selected))
         (left (delq nil
                     (append
                      (plist-get parts :review-badges)
                      (list lineage
                            (when tool-error tool-label))
                      (plist-get parts :status-labels)
                      (list chips
                            (and (not chips) aggregate)
                            (when (memq density '(rich debug)) selected)))))
         (right
          (pcase density
            ('minimal nil)
            ('balanced
             (list (plist-get meta :model)
                   (plist-get meta :latency)))
            ('rich
             (append
              (list (when ogent-zen-show-breadcrumbs
                      (ogent-zen--path-parent-label
                       (plist-get parts :path)))
                    workspace
                    (unless (or tool-error active-label) tool-label)
                    (plist-get meta :model)
                    (plist-get meta :latency)
                    (and (> (or (plist-get stats :count) 0) 1)
                         aggregate)
                    (when folded "folded"))
              (ogent-zen--action-hints status folded)))
            ('debug
             (append
              (list (ogent-zen--path-parent-label
                     (plist-get parts :path))
                    workspace
                    tool-label
                    (plist-get meta :model)
                    (plist-get meta :latency)
                    aggregate
                    selected
                    (plist-get parts :debug-status)
                    (format "%d responses"
                            (or (plist-get stats :count) 0))
                    (when folded "folded"))
              (ogent-zen--action-hints status folded))))))
    (ogent-zen--suffix-lanes left right)))

(defun ogent-zen--response-char-count ()
  "Return the trimmed response body character count at point."
  (length (string-trim (ogent-zen--response-body-text (point)))))

(defun ogent-zen--response-local-summary ()
  "Return a folded summary for the response at point."
  (ogent-zen--response-summary-at (point)))

(defun ogent-zen--response-suffix (status latency)
  "Return the rich muted suffix for a Zen response STATUS and LATENCY."
  (let ((folded (ogent-zen--subtree-folded-p))
        (density (ogent-zen--valid-density)))
    (ogent-zen--suffix
     (append
      (append (ogent-zen--review-badges)
              (list (when (and folded (eq status 'done))
                      (ogent-zen--response-local-summary))
                    (if (eq status 'empty)
                        (ogent-zen--char-count-label
                         (ogent-zen--response-char-count))
                      (ogent-zen--status-label status))
                    (unless (eq density 'minimal) latency)
                    (when (and folded
                               (eq status 'done)
                               (memq density '(rich debug)))
                      (ogent-zen--char-count-label
                       (ogent-zen--response-char-count)))
                    (when (and folded (memq density '(rich debug))) "folded")))
      (unless (eq density 'minimal)
        (ogent-zen--action-hints status folded))))))

;;; Overlay rendering

(defun ogent-zen--heading-text-bounds ()
  "Return bounds of the visible heading text at point."
  (save-excursion
    (beginning-of-line)
    (when (looking-at "^\\*+[ \t]+\\(.*\\)$")
      (cons (match-beginning 1) (match-end 1)))))

(defvar ogent-zen--heading-overlay-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-zen-toggle-transcript)
    (define-key map (kbd "r") #'ogent-zen-rerun)
    (define-key map (kbd "u") #'ogent-zen-review-menu)
    (define-key map (kbd "e") #'ogent-zen-show-error)
    (define-key map [mouse-1] #'ogent-zen--mouse-toggle-transcript)
    map)
  "Keymap active on Zen transcript heading overlays.")

(defun ogent-zen--icon (name fallback &optional face)
  "Return theme icon NAME with FALLBACK and optional FACE."
  (if (fboundp 'ogent-theme-icon)
      (condition-case nil
          (let ((icon (ogent-theme-icon name face)))
            (if (and (stringp icon) (not (string-empty-p icon)))
                icon
              (if face (propertize fallback 'face face) fallback)))
        (error (if face (propertize fallback 'face face) fallback)))
    (if face (propertize fallback 'face face) fallback)))

(defun ogent-zen--compose-face (base status)
  "Return a face list combining BASE with STATUS face when available."
  (let ((status-face (when (fboundp 'ogent-status--get-face)
                       (condition-case nil
                           (ogent-status--get-face status)
                         (error nil)))))
    (if (and status-face (not (eq status-face 'default)))
        (list status-face base)
      base)))

(defun ogent-zen--overlay-label (icon-name fallback text base-face status
                                           &optional suffix)
  "Return a propertized overlay label using ICON-NAME and FALLBACK.
TEXT is rendered with BASE-FACE and STATUS; SUFFIX is appended as metadata."
  (let* ((face (ogent-zen--compose-face base-face status))
         (icon (ogent-zen--icon icon-name fallback face))
         (label (propertize (concat icon " " (string-trim text)) 'face face)))
    (if suffix
        (concat label " "
                (propertize "· " 'face 'ogent-zen-muted-face)
                suffix)
      label)))

(defun ogent-zen--lane-before-string (icon-name fallback status)
  "Return an optional margin lane for ICON-NAME, FALLBACK, and STATUS."
  (when ogent-zen-visual-lanes
    (let* ((face (ogent-zen--compose-face 'ogent-zen-run-face status))
           (icon (ogent-zen--icon icon-name fallback face)))
      (propertize " "
                  'display `((margin left-margin)
                             ,(concat icon " "))
                  'face face))))

(defun ogent-zen--add-heading-overlay (display face &optional help
                                               after-string before-string)
  "Overlay the current heading text with DISPLAY using FACE and HELP.
AFTER-STRING and BEFORE-STRING are optional virtual display strings."
  (when-let* ((bounds (ogent-zen--heading-text-bounds))
              (start (car bounds))
              (end (cdr bounds)))
    (let ((overlay (make-overlay start end nil t nil)))
      (overlay-put overlay 'display display)
      (overlay-put overlay 'face face)
      (overlay-put overlay 'evaporate t)
      (overlay-put overlay 'help-echo help)
      (when after-string
        (overlay-put overlay 'after-string after-string))
      (when before-string
        (overlay-put overlay 'before-string before-string))
      (when ogent-zen-heading-actions
        (overlay-put overlay 'mouse-face 'highlight)
        (overlay-put overlay 'keymap ogent-zen--heading-overlay-map))
      (push overlay ogent-zen--overlays))))

(defun ogent-zen--overlay-request (heading)
  "Add a Zen request overlay for HEADING."
  (let* ((fallback (string-trim
                    (substring heading (length "Request:"))))
         (end (ogent-zen--subtree-end))
         (meta (or (ogent-zen--src-meta end) nil))
         (status (ogent-zen--request-status))
         (icon (ogent-zen--status-icon-parts status))
         (parts (ogent-zen--request-display-parts status meta))
         (stats (plist-get parts :stats))
         (folded (plist-get parts :folded))
         (summary (ogent-zen--request-primary-title
                   fallback status folded end stats
                   (plist-get parts :active-label)))
         (suffix (ogent-zen--request-suffix status meta parts))
         (help (ogent-zen--request-help status meta parts))
         (after-string
          (ogent-zen--request-preview-after-string status folded end))
         (before-string
          (ogent-zen--lane-before-string
           (nth 0 icon) (nth 1 icon) (nth 2 icon)))
         (display (ogent-zen--overlay-label
                   (nth 0 icon) (nth 1 icon) summary 'ogent-zen-run-face
                   (nth 2 icon) suffix)))
    (ogent-zen--add-heading-overlay
     display 'ogent-zen-run-face help after-string before-string)))

(defun ogent-zen--response-overlay-label (model-id status suffix)
  "Return a quiet response overlay label for MODEL-ID, STATUS, and SUFFIX."
  (let* ((face (ogent-zen--compose-face 'ogent-zen-muted-face status))
         (label (propertize (format "↳ %s" model-id) 'face face)))
    (if suffix
        (concat label " "
                (propertize "· " 'face 'ogent-zen-muted-face)
                suffix)
      label)))

(defun ogent-zen--overlay-response (heading)
  "Add a Zen response overlay for HEADING."
  (let* ((model-id (ogent-zen--response-model-id heading))
         (state (ogent-zen--response-state))
         (status (car state))
         (latency (cdr state))
         (suffix (ogent-zen--response-suffix status latency))
         (help (string-join
                (delq nil
                      (list (format "Response: %s" model-id)
                            (format "Status: %s"
                                    (or (ogent-zen--status-label status) "done"))
                            (when ogent-zen-heading-actions
                              "RET/mouse-1: fold or expand; r: rerun; u: review")))
                "\n"))
         (display (ogent-zen--response-overlay-label model-id status suffix)))
    (ogent-zen--add-heading-overlay display 'ogent-zen-response-face help)))

(defun ogent-zen--overlay-entry ()
  "Add a Zen overlay for the heading at point when it is a transcript node.
Runs widened so parent and subtree lookups work when the surrounding
scan is narrowed to a refresh region."
  (condition-case nil
      (save-restriction
        (widen)
        (let ((heading (org-get-heading t t t t)))
          (cond
           ((string-prefix-p "Request:" heading)
            (when (equal (org-entry-get (point) "OGENT_STYLE") "zen")
              (ogent-zen--overlay-request heading)))
           ((string-prefix-p "Response (" heading)
            (when (ogent-zen--parent-zen-request-p)
              (ogent-zen--overlay-response heading))))))
    (error nil)))

(defun ogent-zen--build-overlays (&optional begin end)
  "Build Zen overlays in the buffer, or only between BEGIN and END."
  (save-excursion
    (save-restriction
      (widen)
      (when (and begin end)
        (narrow-to-region begin end))
      (condition-case nil
          (org-map-entries #'ogent-zen--overlay-entry nil nil)
        (error nil)))))

(defun ogent-zen--delete-overlays (&optional begin end)
  "Delete Zen overlays; with BEGIN and END only those starting inside."
  (if (and begin end)
      (setq ogent-zen--overlays
            (cl-delete-if (lambda (overlay)
                            (let ((start (overlay-start overlay)))
                              (when (or (null start)
                                        (and (>= start begin) (< start end)))
                                (delete-overlay overlay)
                                t)))
                          ogent-zen--overlays))
    (mapc #'delete-overlay ogent-zen--overlays)
    (setq ogent-zen--overlays nil)))

(defun ogent-zen-refresh (&optional begin end)
  "Refresh Zen presentation overlays in the current Org buffer.
With BEGIN and END, rebuild only the overlays inside that region;
overlays elsewhere are left untouched."
  (interactive)
  (ogent-zen--delete-overlays begin end)
  (when (and ogent-zen-pretty-headings
             (derived-mode-p 'org-mode))
    (ogent-zen--build-overlays begin end)))

(defun ogent-zen-refresh-at (position)
  "Refresh Zen overlays for the transcript containing POSITION.
Falls back to a full refresh when the transcript cannot be resolved."
  (let ((bounds (condition-case nil
                    (save-excursion
                      (goto-char position)
                      (when-let* ((request
                                   (ogent-zen--transcript-request-heading)))
                        (goto-char request)
                        (cons request (ogent-zen--subtree-end))))
                  (error nil))))
    (if bounds
        (ogent-zen-refresh (car bounds) (cdr bounds))
      (ogent-zen-refresh))))

;;; Active run animation

(defun ogent-zen--active-request-p ()
  "Return non-nil when point is on an active Zen request heading."
  (and (ogent-zen--request-heading-p)
       (memq (ogent-zen--request-status) '(wait tool type))))

(defun ogent-zen--buffer-has-active-request-p ()
  "Return non-nil when the current buffer has a visible active Zen request."
  (and (get-buffer-window-list (current-buffer) nil t)
       (save-excursion
         (save-restriction
           (widen)
           (let (found)
             (goto-char (point-min))
             (while (and (not found)
                         (re-search-forward org-heading-regexp nil t))
               (beginning-of-line)
               (setq found (ogent-zen--active-request-p))
               (forward-line 1))
             found)))))

(defun ogent-zen--animation-buffers ()
  "Return visible Zen buffers with active request headings."
  (cl-remove-if-not
   (lambda (buffer)
     (and (buffer-live-p buffer)
          (buffer-local-value 'ogent-zen-mode buffer)
          (with-current-buffer buffer
            (ogent-zen--buffer-has-active-request-p))))
   (buffer-list)))

(defun ogent-zen--animation-tick ()
  "Advance active Zen overlay animation in visible buffers."
  (let ((buffers (ogent-zen--animation-buffers)))
    (if buffers
        (dolist (buffer buffers)
          (with-current-buffer buffer
            (setq ogent-zen--stream-frame
                  (mod (1+ ogent-zen--stream-frame) 4))
            (ogent-zen-refresh)))
      (when (timerp ogent-zen--animation-timer)
        (cancel-timer ogent-zen--animation-timer))
      (setq ogent-zen--animation-timer nil))))

(defun ogent-zen--ensure-animation-timer ()
  "Start the Zen animation timer when needed."
  (when (and (numberp ogent-zen-active-animation-delay)
             (> ogent-zen-active-animation-delay 0)
             (not (timerp ogent-zen--animation-timer)))
    (setq ogent-zen--animation-timer
          (run-at-time ogent-zen-active-animation-delay
                       ogent-zen-active-animation-delay
                       #'ogent-zen--animation-tick))))

(defun ogent-zen--remove-animation-timer ()
  "Cancel the Zen animation timer when no Zen buffer remains."
  (unless (cl-some (lambda (buffer)
                    (and (buffer-live-p buffer)
                         (buffer-local-value 'ogent-zen-mode buffer)))
                  (buffer-list))
    (when (timerp ogent-zen--animation-timer)
      (cancel-timer ogent-zen--animation-timer))
    (setq ogent-zen--animation-timer nil)))

;;; Folding

(defun ogent-zen--fold-region-safe (from to spec)
  "Fold FROM..TO with SPEC when org-fold is available."
  (when (fboundp 'org-fold-region)
    (ignore-errors (org-fold-region from to t spec))))

(defun ogent-zen--fold-drawer-at (heading-pos)
  "Fold the property drawer of the heading at HEADING-POS."
  (save-excursion
    (goto-char heading-pos)
    (forward-line 1)
    (when (looking-at org-property-drawer-re)
      (ogent-zen--fold-region-safe (line-end-position) (match-end 0)
                                   'drawer))))

(defun ogent-zen--fold-block-at (pos)
  "Fold the src block whose #+begin_src line begins at POS."
  (save-excursion
    (goto-char pos)
    (when (looking-at-p "^#\\+begin_src")
      (let ((from (line-end-position))
            (to (when (re-search-forward "^#\\+end_src" nil t)
                  (line-end-position))))
        (when to
          (ogent-zen--fold-region-safe from to 'block))))))

(defun ogent-zen--fold-tool-drawers (end)
  "Fold all tool drawers before END in the current request subtree.
Unlike normal Org drawer folding, hide the `:TOOL:' line too; Zen run
cards already summarize tool state in the request headline."
  (save-excursion
    (forward-line 1)
    (while (re-search-forward "^[ \t]*:TOOL:[ \t]*$" end t)
      (let ((from (line-beginning-position))
            (to (save-excursion
                  (when (re-search-forward "^[ \t]*:END:[ \t]*$" end t)
                    (line-end-position)))))
        (when to
          (ogent-zen--fold-region-safe from to 'drawer)
          (goto-char to))))))

(defun ogent-zen--fold-transcript-noise (request)
  "Fold the drawers and prompt block of the Zen request at REQUEST."
  (save-excursion
    (goto-char request)
    (let ((end (ogent-zen--subtree-end)))
      (ogent-zen--fold-drawer-at request)
      (goto-char request)
      (when (re-search-forward "^#\\+begin_src text " end t)
        (ogent-zen--fold-block-at (line-beginning-position)))
      (goto-char request)
      (ogent-zen--fold-tool-drawers end))))

(defun ogent-zen--fold-noise-buffer ()
  "Fold drawers, tool drawers, and prompt blocks of every Zen transcript."
  (when (and ogent-zen-fold-noise (fboundp 'org-fold-region))
    (org-with-wide-buffer
     (goto-char (point-min))
     (while (re-search-forward "^\\*+ Request:" nil t)
       (save-excursion
         (beginning-of-line)
         (when (ogent-zen--request-heading-p)
           (ogent-zen--fold-transcript-noise (point))))))))

(defun ogent-zen--collapse-sibling-runs (request)
  "Fold and supersede older Zen sibling transcripts of REQUEST."
  (save-excursion
    (goto-char request)
    (org-back-to-heading t)
    (let ((level (org-current-level)))
      (when (org-up-heading-safe)
        ;; Point is on the parent bullet; walk its child headings.
        (let ((end (ogent-zen--subtree-end)))
          (while (and (outline-next-heading) (< (point) end))
            (when (and (eql (org-current-level) level)
                       (/= (point) request)
                       (ogent-zen--request-heading-p))
              (let ((review (or (org-entry-get (point) "OGENT_LINEAGE")
                                (org-entry-get (point) "OGENT_REVIEW"))))
                (when (or (null review)
                          (member review '("needs-review" "stale"
                                           "superseded")))
                  (org-entry-put (point) "OGENT_LINEAGE" "superseded")
                  (ogent-zen--sync-legacy-review (point))
                  (ogent-zen--sync-review-drawer (point))))
              (when (fboundp 'org-fold-hide-subtree)
                (ignore-errors (org-fold-hide-subtree))))))))))

(defun ogent-zen-after-insert (request-pos)
  "Apply Zen presentation after a transcript was inserted at REQUEST-POS.
Folds the new request's drawer and prompt block, collapses earlier
sibling runs, and refreshes overlays for the enclosing bullet subtree."
  (when (derived-mode-p 'org-mode)
    (let ((request (if (markerp request-pos)
                       (marker-position request-pos)
                     request-pos)))
      (when (integerp request)
        (when ogent-zen-fold-noise
          (ogent-zen--fold-transcript-noise request))
        (when ogent-zen-collapse-previous-runs
          (ogent-zen--collapse-sibling-runs request))
        (let ((bounds (condition-case nil
                          (save-excursion
                            (goto-char request)
                            (org-back-to-heading t)
                            (when (org-up-heading-safe)
                              (cons (point) (ogent-zen--subtree-end))))
                        (error nil))))
          (if bounds
              (ogent-zen-refresh (car bounds) (cdr bounds))
            (ogent-zen-refresh-at request)))))))

;;; Quiet bullets (star composition)

(defconst ogent-zen--star-regexp "^\\(\\*+\\) "
  "Regexp matching the leading stars of an Org heading.")

(defun ogent-zen--bullets-allowed-p ()
  "Return non-nil when star composition should be installed."
  (and ogent-zen-bullet
       (not (string-empty-p ogent-zen-bullet))
       (not (bound-and-true-p org-modern-mode))
       (not (bound-and-true-p org-bullets-mode))
       (not (bound-and-true-p org-superstar-mode))))

(defun ogent-zen--prettify-stars ()
  "Font-lock helper: compose the matched star run into `ogent-zen-bullet'."
  (compose-region (match-beginning 1) (match-end 1) ogent-zen-bullet)
  nil)

(defun ogent-zen--compose-buffer-stars ()
  "Compose every heading's leading stars into `ogent-zen-bullet'."
  (org-with-wide-buffer
   (goto-char (point-min))
   (with-silent-modifications
     (while (re-search-forward ogent-zen--star-regexp nil t)
       (compose-region (match-beginning 1) (match-end 1) ogent-zen-bullet)))))

(defun ogent-zen--decompose-buffer-stars ()
  "Remove star compositions installed by `ogent-zen-mode'."
  (org-with-wide-buffer
   (goto-char (point-min))
   (with-silent-modifications
     (while (re-search-forward ogent-zen--star-regexp nil t)
       (decompose-region (match-beginning 1) (match-end 1))))))

(defun ogent-zen--install-bullets ()
  "Install quiet bullet composition for heading stars."
  (when (ogent-zen--bullets-allowed-p)
    (setq ogent-zen--bullet-keywords
          `((,ogent-zen--star-regexp (0 (ogent-zen--prettify-stars)))))
    (font-lock-add-keywords nil ogent-zen--bullet-keywords)
    (ogent-zen--compose-buffer-stars)
    (when font-lock-mode
      (font-lock-flush))))

(defun ogent-zen--remove-bullets ()
  "Remove quiet bullet composition installed by `ogent-zen-mode'."
  (when ogent-zen--bullet-keywords
    (font-lock-remove-keywords nil ogent-zen--bullet-keywords)
    (setq ogent-zen--bullet-keywords nil)
    (ogent-zen--decompose-buffer-stars)
    (when font-lock-mode
      (font-lock-flush))))

;;; Centered page (window margins)

(defun ogent-zen--sync-margins (&optional _frame)
  "Synchronize centered margins for windows showing Zen buffers."
  (dolist (frame (frame-list))
    (dolist (window (window-list frame 'no-minibuf))
      (let* ((buffer (window-buffer window))
             (column (and (buffer-live-p buffer)
                          (buffer-local-value 'ogent-zen-mode buffer)
                          (buffer-local-value 'ogent-zen-center-column
                                              buffer))))
        (cond
         ((integerp column)
          (let ((margin (max 0 (/ (- (window-total-width window) column) 2))))
            (set-window-parameter window 'ogent-zen-centered t)
            (set-window-margins window margin margin)))
         ((window-parameter window 'ogent-zen-centered)
          (set-window-parameter window 'ogent-zen-centered nil)
          (set-window-margins window nil nil)))))))

(defun ogent-zen--margins-needed-p ()
  "Return non-nil when some live buffer still has `ogent-zen-mode'."
  (cl-some (lambda (buffer)
             (buffer-local-value 'ogent-zen-mode buffer))
           (buffer-list)))

(defun ogent-zen--install-margins ()
  "Install global margin synchronization hooks."
  (add-hook 'window-configuration-change-hook #'ogent-zen--sync-margins)
  (add-hook 'window-size-change-functions #'ogent-zen--sync-margins)
  (ogent-zen--sync-margins))

(defun ogent-zen--remove-margins ()
  "Clear margins for this buffer and drop hooks when no Zen buffer remains."
  (ogent-zen--sync-margins)
  (unless (ogent-zen--margins-needed-p)
    (remove-hook 'window-configuration-change-hook #'ogent-zen--sync-margins)
    (remove-hook 'window-size-change-functions #'ogent-zen--sync-margins)))

;;; Minor mode

;;;###autoload
(define-minor-mode ogent-zen-mode
  "Minor mode for Zen-style ogent interaction in Org buffers.

Write normal Org bullets; \\[ogent-run-subtree] runs the bullet at
point as the prompt with its parent bullets as context.
\\[org-ctrl-c-ctrl-c] on a generated transcript re-runs that bullet
\(`ogent-zen-rerun').

Presentation is non-destructive: generated `Request:' / `Response'
headings get compact status overlays, leading stars are composed into
`ogent-zen-bullet', transcript drawers, tool drawers, and prompt blocks
fold away \(`ogent-zen-fold-noise'), earlier runs collapse when a new
run starts \(`ogent-zen-collapse-previous-runs'), active runs animate
only in visible buffers, and the page can be centered via
`ogent-zen-center-column'.  Disabling the mode restores plain Org."
  :lighter " Zen"
  (if ogent-zen-mode
      (when (derived-mode-p 'org-mode)
        (visual-line-mode 1)
        (setq-local line-spacing 0.15)
        (when (and (fboundp 'org-indent-mode)
                   (not (bound-and-true-p org-indent-mode)))
          (setq-local ogent-zen--enabled-org-indent t)
          (org-indent-mode 1))
        (ogent-zen--install-bullets)
        (add-hook 'org-ctrl-c-ctrl-c-hook #'ogent-zen--ctrl-c-ctrl-c nil t)
        (ogent-zen--install-margins)
        (ogent-zen--fold-noise-buffer)
        (ogent-zen--ensure-animation-timer)
        (ogent-zen-refresh))
    (ogent-zen--delete-overlays)
    (when (derived-mode-p 'org-mode)
      (ogent-zen--remove-bullets)
      (remove-hook 'org-ctrl-c-ctrl-c-hook #'ogent-zen--ctrl-c-ctrl-c t)
      (when (and ogent-zen--enabled-org-indent
                 (fboundp 'org-indent-mode))
        (setq-local ogent-zen--enabled-org-indent nil)
        (org-indent-mode -1)))
    (ogent-zen--remove-margins)
    (ogent-zen--remove-animation-timer)))

(defun ogent-zen--turn-on ()
  "Enable `ogent-zen-mode' for `global-ogent-zen-mode'.
Activate only in Org buffers, skipping internal temporary buffers whose
names begin with a space so prompt-extraction scratch buffers stay
untouched."
  (when (and (derived-mode-p 'org-mode)
             (not (derived-mode-p 'ogent-zen-tool-calls-mode))
             (not ogent-zen-mode)
             (not (string-prefix-p " " (buffer-name))))
    (ogent-zen-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-ogent-zen-mode
  ogent-zen-mode ogent-zen--turn-on
  :group 'ogent-zen
  :predicate '(org-mode))

;;; Prompt extraction

(defun ogent-zen--delete-generated-subtrees ()
  "Delete generated ogent child subtrees from the current temp Org buffer."
  (let (positions)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward org-heading-regexp nil t)
        (beginning-of-line)
        (unless (= (point) (point-min))
          (when (ogent-zen--generated-heading-p)
            (push (copy-marker (point)) positions)))
        (forward-line 1)))
    (dolist (marker positions)
      (when (marker-position marker)
        (goto-char marker)
        (let ((start (point))
              (end (save-excursion
                     (org-end-of-subtree t t)
                     (point))))
          (delete-region start end)))
      (set-marker marker nil))))

(defun ogent-zen--delete-property-drawers ()
  "Delete Org property drawers from the current buffer."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "^[ \t]*:PROPERTIES:[ \t]*$" nil t)
      (let ((start (line-beginning-position)))
        (when (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
          (delete-region start (min (point-max) (1+ (line-end-position)))))))))

(defun ogent-zen--root-level ()
  "Return the level of the first Org heading in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward org-heading-regexp nil t)
      (length (match-string 1)))))

(defun ogent-zen--markdown-lines (root-level)
  "Return markdown-like bullet lines relative to ROOT-LEVEL."
  (let ((current-relative 0)
        lines)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (cond
         ((looking-at org-heading-regexp)
          (let* ((level (length (match-string 1)))
                 (relative (max 0 (- level root-level)))
                 (indent (make-string (* 2 relative) ?\s))
                 (title (org-get-heading t t t t)))
            (setq current-relative relative)
            (push (concat indent "- " title) lines)))
         (t
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position)
                       (line-end-position))))
            (push (if (string-empty-p line)
                      ""
                    (concat (make-string (* 2 (1+ current-relative)) ?\s)
                            line))
                  lines))))
        (forward-line 1)))
    (nreverse lines)))

(defun ogent-zen--subtree-prompt (point)
  "Return POINT's Org subtree as a markdown-like prompt string."
  (let ((text (save-excursion
                (goto-char point)
                (org-back-to-heading t)
                (let* ((element (org-element-at-point))
                       (begin (org-element-property :begin element))
                       (end (org-element-property :end element)))
                  (buffer-substring-no-properties begin end)))))
    (with-temp-buffer
      (org-mode)
      (insert text)
      (goto-char (point-min))
      (ogent-zen--delete-generated-subtrees)
      (ogent-zen--delete-property-drawers)
      (let* ((root-level (or (ogent-zen--root-level) 1))
             (prompt (string-trim
                      (string-join (ogent-zen--markdown-lines root-level)
                                   "\n"))))
        (when (string-empty-p prompt)
          (user-error "Current subtree is empty after removing ogent output"))
        prompt))))

(defun ogent-zen--element-target-bounds ()
  "Return editable Org element bounds at point, or nil."
  (let* ((element (org-element-context))
         (type (org-element-type element)))
    (when (memq type '(paragraph item src-block quote-block verse-block
                                 example-block special-block table-row
                                 table fixed-width plain-list))
      (let ((beg (or (org-element-property :contents-begin element)
                     (org-element-property :begin element)))
            (end (or (org-element-property :contents-end element)
                     (org-element-property :end element))))
        (when (and beg end (< beg end))
          (cons beg end))))))

(defun ogent-zen--thing-target-bounds (thing)
  "Return bounds for THING at point, constrained to the current heading."
  (when-let ((bounds (bounds-of-thing-at-point thing)))
    (save-excursion
      (let ((beg (car bounds))
            (end (cdr bounds))
            (heading (ogent-zen--heading-point)))
        (when heading
          (goto-char heading)
          (let ((subtree-end (ogent-zen--subtree-end))
                (body-beg (save-excursion
                            (goto-char heading)
                            (forward-line 1)
                            (point))))
            (setq beg (max beg body-beg)
                  end (min end subtree-end))
            (when (< beg end)
              (cons beg end))))))))

(defun ogent-zen--scope-target-bounds (kind)
  "Return text target bounds for scope KIND at point."
  (pcase kind
    ('region
     (unless (use-region-p)
       (user-error "Region scope requires an active region"))
     (cons (region-beginning) (region-end)))
    ('element (or (ogent-zen--element-target-bounds)
                  (ogent-zen--thing-target-bounds 'paragraph)))
    ('sentence (ogent-zen--thing-target-bounds 'sentence))
    ('paragraph (or (ogent-zen--element-target-bounds)
                    (ogent-zen--thing-target-bounds 'paragraph)))
    (_ nil)))

(defun ogent-zen--scope-at-point (&optional preferred-kind instruction edit-p)
  "Return an `ogent-zen-scope' for the current Org location.
PREFERRED-KIND chooses `subtree', `region', `element', `sentence', or
`paragraph'.  INSTRUCTION is attached to edit and region prompts.  When
EDIT-P is non-nil, the scope expects a SEARCH/REPLACE edit response."
  (unless (derived-mode-p 'org-mode)
    (user-error "Zen scope requires an Org buffer"))
  (let ((heading-point (ogent-zen--heading-point)))
    (unless heading-point
      (user-error "Zen scope requires point inside a user Org heading"))
    (let* ((kind (or preferred-kind
                     (and (use-region-p) 'region)
                     'element))
           (breadcrumb (ogent-zen--breadcrumb heading-point)))
      (if (eq kind 'subtree)
          (make-ogent-zen-scope
           :kind 'subtree
           :heading-point heading-point
           :prompt-text (ogent-zen--subtree-prompt heading-point)
           :breadcrumb breadcrumb
           :instruction instruction
           :edit-p edit-p)
        (let ((bounds (or (ogent-zen--scope-target-bounds kind)
                          (and (not preferred-kind)
                               (ogent-zen--scope-target-bounds 'sentence))
                          (and (not preferred-kind)
                               (ogent-zen--scope-target-bounds 'paragraph)))))
          (unless bounds
            (user-error "No editable text scope at point"))
          (let* ((beg (car bounds))
                 (end (cdr bounds))
                 (text (ogent-zen--scope-text beg end)))
            (when (string-empty-p (string-trim text))
              (user-error "Selected Zen scope is empty"))
            (make-ogent-zen-scope
             :kind kind
             :heading-point heading-point
             :start-marker (copy-marker beg)
             :end-marker (copy-marker end t)
             :original-text text
             :prompt-text text
             :breadcrumb breadcrumb
             :instruction instruction
             :edit-p edit-p)))))))

(defun ogent-zen--scope-edit-instruction (scope)
  "Return the edit instruction for SCOPE."
  (let ((instruction (ogent-zen-scope-instruction scope)))
    (if (and instruction (not (string-empty-p (string-trim instruction))))
        instruction
      "Improve the selected text while preserving its meaning and Org structure.")))

(defun ogent-zen--scope-prompt (scope)
  "Return the direct model prompt for Zen SCOPE."
  (if (eq (ogent-zen-scope-kind scope) 'subtree)
      (ogent-zen-scope-prompt-text scope)
    (let ((selected (or (ogent-zen-scope-original-text scope)
                        (ogent-zen-scope-prompt-text scope)
                        "")))
      (if (ogent-zen-scope-edit-p scope)
          (format
           "Rewrite the selected text according to this instruction:\n\n%s\n\nSelected text:\n#+begin_quote\n%s\n#+end_quote\n\nReturn exactly one SEARCH/REPLACE block for the selected text:\n\n<<<<<<< SEARCH\n[exact selected text]\n=======\n[replacement text]\n>>>>>>> REPLACE"
           (ogent-zen--scope-edit-instruction scope)
           selected)
        (format
         "Answer the following question about the selected text with the surrounding tree as context:\n\n%s\n\nSelected text:\n#+begin_quote\n%s\n#+end_quote"
         (or (ogent-zen-scope-instruction scope)
             "Explain this selected text.")
         selected)))))


(defun ogent-zen--workspace-base-directory ()
  "Return the directory used to resolve relative Zen workspace paths."
  (or (and buffer-file-name (file-name-directory buffer-file-name))
      default-directory))

(defun ogent-zen--project-root ()
  "Return the project root for the current Zen buffer, or nil."
  (let ((base (ogent-zen--workspace-base-directory)))
    (or (and (fboundp 'project-current)
             (let ((default-directory base))
               (when-let ((project (project-current nil)))
                 (project-root project))))
        (when-let ((root (locate-dominating-file base ".git")))
          (file-name-as-directory root)))))

(defun ogent-zen--workspace-resolution-bases ()
  "Return directories used for resolving relative workspace mentions."
  (cl-remove-duplicates
   (delq nil
         (mapcar (lambda (dir)
                   (and dir
                        (file-name-as-directory (expand-file-name dir))))
                 (list (ogent-zen--workspace-base-directory)
                       (ogent-zen--project-root)
                       default-directory)))
   :test #'string=))

(defun ogent-zen--workspace-node-text (node)
  "Return searchable title and body text for NODE."
  (when node
    (string-join
     (delq nil
           (list (ogent-context-node-title node)
                 (ogent-context-node-content node)))
     "\n")))

(defun ogent-zen--workspace-search-texts (context)
  "Return nearest-first text fragments for workspace inference from CONTEXT."
  (let ((root (plist-get context :root))
        (ancestors (plist-get context :ancestors)))
    (delq nil
          (append
           (when root (list (ogent-zen--workspace-node-text root)))
           (mapcar #'ogent-zen--workspace-node-text
                   (reverse ancestors))))))

(defun ogent-zen--workspace-directive-from-text (content)
  "Return the first explicit workspace path declared in CONTENT, or nil.
Recognizes lines like \"Context: ~/repo\" using
`ogent-zen-workspace-directives'.  Only the first shell-like token after
the colon is treated as the path, so users can append prose safely."
  (catch 'path
    (dolist (line (split-string (or content "") "\n"))
      (dolist (label ogent-zen-workspace-directives)
        (when (string-match
               (format "\\`[ \t]*%s:[ \t]*\\([^ \t\n]+\\)"
                       (regexp-quote label))
               line)
          (throw 'path (match-string 1 line)))))))

(defconst ogent-zen--workspace-path-regexp
  "\\(?:[\"'`“‘]\\(\\(?:~\\|/\\|\\.\\.?/\\)[^\"'`“”‘’\n]+\\)[\"'`”’]\\|\\(\\(?:~\\|/\\|\\.\\.?/\\)[^ \t\n\"'`“”‘’()<>;,]+\\)\\)"
  "Regexp matching quoted or bare path-like prose.")

(defconst ogent-zen--workspace-tool-intent-regexp
  "\\b\\(?:look\\|inspect\\|read\\|search\\|grep\\|scan\\|find\\|explore\\|investigate\\|ground\\|grounded\\|code\\|codebase\\|repo\\|repository\\|implementation\\|source\\|file\\|files\\|tool\\)\\b"
  "Regexp matching prose that should actively inspect a workspace.")

(defun ogent-zen--clean-workspace-token (token)
  "Return cleaned path TOKEN, or nil when TOKEN is not a usable path."
  (when token
    (let* ((without-file-scheme
            (replace-regexp-in-string "\\`file://" "" token))
           (trimmed
            (string-trim without-file-scheme
                         "[ \t\n\r\"'`“”‘’([{<]+"
                         "[ \t\n\r\"'`“”‘’.,;:!?)}>\\]]+")))
      (unless (or (string-empty-p trimmed)
                  (string-prefix-p "//" trimmed))
        trimmed))))

(defun ogent-zen--workspace-paths-from-text (content)
  "Return path-like natural language mentions in CONTENT."
  (let (paths)
    (when (and ogent-zen-infer-workspace-from-prose content)
      (let ((pos 0))
        (while (string-match ogent-zen--workspace-path-regexp content pos)
          (when-let ((path (ogent-zen--clean-workspace-token
                            (or (match-string 1 content)
                                (match-string 2 content)))))
            (push path paths))
          (setq pos (max (1+ pos) (match-end 0))))))
    (cl-remove-duplicates (nreverse paths) :test #'string= :from-end t)))

(defun ogent-zen--resolve-workspace-path (raw-path)
  "Return workspace info for RAW-PATH, or nil when it is unusable.
The returned plist contains :root, :target, and :raw.  Files resolve to
their containing directory as :root while preserving the file as :target."
  (when (and raw-path (not (string-empty-p raw-path)))
    (catch 'resolved
      (let ((bases (if (or (file-name-absolute-p raw-path)
                           (string-prefix-p "~" raw-path))
                       '(nil)
                     (ogent-zen--workspace-resolution-bases))))
        (dolist (base bases)
          (let* ((expanded (expand-file-name raw-path base))
                 (directory (and (file-directory-p expanded)
                                 (file-name-as-directory expanded)))
                 (file (and (file-regular-p expanded) expanded)))
            (cond
             (directory
              (throw 'resolved
                     (list :root (file-truename directory)
                           :target (file-truename directory)
                           :raw raw-path)))
             (file
              (throw 'resolved
                     (list :root (file-truename
                                  (file-name-directory file))
                           :target (file-truename file)
                           :raw raw-path))))))))))

(defun ogent-zen--workspace-tool-intent-p (texts)
  "Return non-nil when TEXTS ask for workspace inspection."
  (cl-some
   (lambda (text)
     (and text
          (string-match-p ogent-zen--workspace-tool-intent-regexp
                          (downcase text))))
   texts))

(defun ogent-zen--workspace-info (context)
  "Return inferred workspace info for CONTEXT, nearest scope first."
  (let* ((texts (ogent-zen--workspace-search-texts context))
         (explicit
          (cl-loop for text in texts
                   for raw = (ogent-zen--workspace-directive-from-text text)
                   for resolved = (ogent-zen--resolve-workspace-path raw)
                   when resolved
                   return (plist-put resolved :source 'directive)))
         (natural
          (and ogent-zen-infer-workspace-from-prose
               (cl-loop for text in texts
                        append (ogent-zen--workspace-paths-from-text text)
                        into paths
                        finally return
                        (cl-loop for raw in paths
                                 for resolved = (ogent-zen--resolve-workspace-path raw)
                                 when resolved
                                 return (plist-put resolved :source 'natural)))))
         (implicit
          (and ogent-zen-infer-workspace-from-prose
               (ogent-zen--workspace-tool-intent-p texts)
               (when-let ((root (ogent-zen--project-root)))
                 (list :root (file-truename (file-name-as-directory root))
                       :target (file-truename (file-name-as-directory root))
                       :raw "current project"
                       :source 'project))))
         (info (or explicit natural implicit)))
    (when info
      (plist-put info :tool-intent
                 (and ogent-zen-force-tools-for-workspace-intent
                      (if (or (memq (plist-get info :source)
                                    '(natural project))
                              (ogent-zen--workspace-tool-intent-p texts))
                          t
                        nil)))
      info)))

(defun ogent-zen--workspace-root (context)
  "Return workspace root inferred from CONTEXT, nearest scope first."
  (plist-get (ogent-zen--workspace-info context) :root))

(defun ogent-zen--workspace-brief-files (workspace-root)
  "Return recent source/doc files under WORKSPACE-ROOT for a compact brief."
  (let (files)
    (dolist (dir ogent-zen-workspace-brief-directories)
      (let ((absolute (expand-file-name dir workspace-root)))
        (when (file-directory-p absolute)
          (dolist (file (directory-files-recursively
                         absolute "\\.\\(el\\|org\\|md\\)\\'"))
            (when (file-regular-p file)
              (push file files))))))
    (setq files
          (sort files
                (lambda (a b)
                  (time-less-p
                   (file-attribute-modification-time (file-attributes b))
                   (file-attribute-modification-time (file-attributes a))))))
    (when (> (length files) ogent-zen-workspace-brief-max-files)
      (setq files (cl-subseq files 0 ogent-zen-workspace-brief-max-files)))
    files))

(defun ogent-zen--workspace-brief (workspace-root)
  "Return a compact workspace brief for WORKSPACE-ROOT."
  (let* ((dirs (cl-remove-if-not
                (lambda (dir)
                  (file-directory-p (expand-file-name dir workspace-root)))
                ogent-zen-workspace-brief-directories))
         (files (ogent-zen--workspace-brief-files workspace-root)))
    (string-join
     (delq nil
           (list
            (when dirs
              (format "Source areas: %s" (string-join dirs ", ")))
            (when files
              (format "Recent files:\n%s"
                      (mapconcat
                       (lambda (file)
                         (format "- %s"
                                 (file-relative-name file workspace-root)))
                       files
                       "\n")))))
     "\n")))

(defun ogent-zen--context-transform (context point)
  "Return CONTEXT adjusted for a Zen run rooted at POINT.
Marks the context as a Zen run, records the bullet breadcrumb, resolves
any workspace directive, empties the root content (the bullet text
already is the prompt), and trims each ancestor to its own body so
parents never duplicate the prompt, each other, or earlier transcripts."
  (let* ((next (copy-sequence context))
         (workspace-info (ogent-zen--workspace-info context))
         (workspace-root (plist-get workspace-info :root)))
    (setq next (plist-put next :zen-run t))
    (setq next (plist-put next :zen-path (ogent-zen--breadcrumb point)))
    (when workspace-root
      (setq next (plist-put next :workspace-root workspace-root))
      (setq next (plist-put next :workspace-source
                            (plist-get workspace-info :source)))
      (setq next (plist-put next :workspace-target
                            (plist-get workspace-info :target)))
      (setq next (plist-put next :workspace-tool-intent
                            (plist-get workspace-info :tool-intent)))
      (setq next (plist-put next :workspace-brief
                            (ogent-zen--workspace-brief workspace-root))))
    (when-let* ((root (plist-get context :root))
                (root-copy (copy-ogent-context-node root)))
      (setf (ogent-context-node-content root-copy) "")
      (setq next (plist-put next :root root-copy)))
    (when-let* ((ancestors (plist-get context :ancestors)))
      (setq next
            (plist-put next :ancestors
                       (mapcar (lambda (node)
                                 (let ((copy (copy-ogent-context-node node)))
                                   (setf (ogent-context-node-content copy)
                                         (ogent-zen--own-body
                                          (or (ogent-context-node-content node)
                                              "")))
                                   copy))
                               ancestors))))
    next))

(defun ogent-zen--selection-plist (scope)
  "Return persisted selection metadata for SCOPE."
  (when-let ((text (ogent-zen-scope-original-text scope)))
    (list :text text
          :begin (ogent-zen--marker-position
                  (ogent-zen-scope-start-marker scope))
          :end (ogent-zen--marker-position
                (ogent-zen-scope-end-marker scope))
          :length (length text)
          :sha256 (secure-hash 'sha256 text))))

(defun ogent-zen--context-transform-for-scope (context scope)
  "Return CONTEXT adjusted for a Zen SCOPE."
  (let* ((heading (ogent-zen-scope-heading-point scope))
         (next (ogent-zen--context-transform context heading))
         (kind (ogent-zen-scope-kind scope))
         (selection (ogent-zen--selection-plist scope)))
    (unless (eq kind 'subtree)
      (when-let* ((root (plist-get context :root))
                  (root-copy (copy-ogent-context-node root)))
        (setf (ogent-context-node-content root-copy)
              (ogent-zen--own-body
               (or (ogent-context-node-content root) "")))
        (setq next (plist-put next :root root-copy))))
    (setq next (plist-put next :zen-scope-kind kind))
    (setq next (plist-put next :zen-scope-instruction
                          (ogent-zen-scope-instruction scope)))
    (setq next (plist-put next :zen-edit
                          (ogent-zen-scope-edit-p scope)))
    (setq next (plist-put next :zen-selection selection))
    (setq next (plist-put next :zen-scope scope))
    next))

(defun ogent-zen-edit--strip-delimiter-newline (text)
  "Return TEXT without the delimiter-introduced trailing newline."
  (if (string-suffix-p "\n" text)
      (substring text 0 -1)
    text))

(defun ogent-zen-edit--parse-search-replace (response)
  "Return the first SEARCH/REPLACE edit parsed from RESPONSE.
The return value is a plist with :old-text and :new-text."
  (with-temp-buffer
    (insert response)
    (goto-char (point-min))
    (unless (re-search-forward "^<<<<<<< SEARCH[ \t]*$" nil t)
      (user-error "No SEARCH/REPLACE block found in response"))
    (forward-line 1)
    (let ((old-start (point)))
      (unless (re-search-forward "^=======[ \t]*$" nil t)
        (user-error "SEARCH/REPLACE block is missing ======= separator"))
      (let ((old-end (match-beginning 0))
            (new-start (progn (forward-line 1) (point))))
        (unless (re-search-forward "^>>>>>>> REPLACE[ \t]*$" nil t)
          (user-error "SEARCH/REPLACE block is missing REPLACE terminator"))
        (list :old-text
              (ogent-zen-edit--strip-delimiter-newline
               (buffer-substring-no-properties old-start old-end))
              :new-text
              (ogent-zen-edit--strip-delimiter-newline
               (buffer-substring-no-properties new-start
                                               (match-beginning 0))))))))

(defun ogent-zen-edit--inside-generated-subtree-p (pos)
  "Return non-nil when POS is inside an ogent-generated subtree."
  (save-excursion
    (goto-char pos)
    (condition-case nil
        (progn
          (org-back-to-heading t)
          (ogent-zen--generated-heading-p))
      (error nil))))

(defun ogent-zen-edit--find-unique-in-heading (heading search-text)
  "Return unique bounds for SEARCH-TEXT under HEADING, excluding transcripts."
  (let (matches)
    (save-excursion
      (goto-char heading)
      (let ((end (ogent-zen--subtree-end)))
        (while (search-forward search-text end t)
          (let ((beg (match-beginning 0))
                (fin (match-end 0)))
            (unless (ogent-zen-edit--inside-generated-subtree-p beg)
              (push (cons beg fin) matches))))))
    (let ((count (length matches)))
      (cond
       ((= count 0)
        (user-error "SEARCH text not found in the owning heading"))
       ((= count 1)
        (car matches))
       (t
        (user-error "SEARCH text matches %d locations in the owning heading"
                    count))))))

(defun ogent-zen-edit--locate-target (scope search-text)
  "Return (BEG . END) for SEARCH-TEXT in SCOPE."
  (let* ((beg-marker (ogent-zen-scope-start-marker scope))
         (end-marker (ogent-zen-scope-end-marker scope))
         (marker-beg (ogent-zen--marker-position beg-marker))
         (marker-end (ogent-zen--marker-position end-marker)))
    (if (and marker-beg marker-end
             (string= search-text
                      (buffer-substring-no-properties marker-beg marker-end)))
        (cons marker-beg marker-end)
      (ogent-zen-edit--find-unique-in-heading
       (ogent-zen-scope-heading-point scope)
       search-text))))

(defun ogent-zen-edit--insert-error-block (request-marker message)
  "Insert an actionable edit error MESSAGE under REQUEST-MARKER."
  (when (and (markerp request-marker)
             (marker-buffer request-marker)
             (marker-position request-marker))
    (with-current-buffer (marker-buffer request-marker)
      (save-excursion
        (goto-char request-marker)
        (org-end-of-subtree t t)
        (unless (bolp) (insert "\n"))
        (insert "#+begin_quote ogent-edit-error\n"
                "Edit preview failed: " message "\n"
                "#+end_quote\n")))))

(defun ogent-zen-edit--set-request-status (request-marker status
                                                          &optional message)
  "Set REQUEST-MARKER edit STATUS and optional MESSAGE."
  (when (and (markerp request-marker)
             (marker-buffer request-marker)
             (marker-position request-marker))
    (with-current-buffer (marker-buffer request-marker)
      (save-excursion
        (goto-char request-marker)
        (org-entry-put (point) "OGENT_EDIT_STATUS" status)
        (if message
            (org-entry-put (point) "OGENT_EDIT_ERROR" message)
          (org-entry-delete (point) "OGENT_EDIT_ERROR"))))))

(defun ogent-zen-edit--set-target-metadata (request-marker beg end text)
  "Persist edit target BEG, END, and TEXT metadata on REQUEST-MARKER."
  (when (and (markerp request-marker)
             (marker-buffer request-marker)
             (marker-position request-marker))
    (with-current-buffer (marker-buffer request-marker)
      (save-excursion
        (goto-char request-marker)
        (org-entry-put (point) "OGENT_TARGET_BEGIN" (number-to-string beg))
        (org-entry-put (point) "OGENT_TARGET_END" (number-to-string end))
        (org-entry-put (point) "OGENT_TARGET_LENGTH"
                       (number-to-string (length text)))
        (org-entry-put (point) "OGENT_TARGET_SHA256"
                       (secure-hash 'sha256 text))))))

(defun ogent-zen-edit--refresh-target-metadata (preview)
  "Persist current target metadata for PREVIEW."
  (let* ((request (ogent-zen-edit-preview-request-marker preview))
         (beg (ogent-zen--marker-position
               (ogent-zen-edit-preview-target-start-marker preview)))
         (end (ogent-zen--marker-position
               (ogent-zen-edit-preview-target-end-marker preview))))
    (when (and beg end)
      (ogent-zen-edit--set-target-metadata
       request beg end (buffer-substring-no-properties beg end)))))

(defun ogent-zen-edit--preview-replacement (scope old-text new-text
                                                  request-marker)
  "Preview replacing OLD-TEXT with NEW-TEXT for SCOPE.
REQUEST-MARKER identifies the transcript that produced this proposal."
  (let* ((target (ogent-zen-edit--locate-target scope old-text))
         (beg (car target))
         (end (cdr target))
         new-end)
    (atomic-change-group
      (delete-region beg end)
      (goto-char beg)
      (insert new-text)
      (setq new-end (point))
      (inline-diff-words-region beg new-end old-text))
    (setq ogent-zen-edit--pending-preview
          (make-ogent-zen-edit-preview
           :request-marker request-marker
           :target-start-marker (copy-marker beg)
           :target-end-marker (copy-marker new-end t)
           :old-text old-text
           :new-text new-text
           :status 'preview
           :scope-kind (ogent-zen-scope-kind scope)))
    (add-hook 'inline-diff-accept-hook
              #'ogent-zen-edit--accept-hook nil t)
    (add-hook 'inline-diff-reject-hook
              #'ogent-zen-edit--reject-hook nil t)
    (ogent-zen-edit--set-request-status request-marker "preview")
    (ogent-zen-edit--refresh-target-metadata
     ogent-zen-edit--pending-preview)
    ogent-zen-edit--pending-preview))

(defun ogent-zen-edit--accept-hook ()
  "Mark the pending Zen edit as accepted."
  (when ogent-zen-edit--pending-preview
    (setf (ogent-zen-edit-preview-status
           ogent-zen-edit--pending-preview)
          'accepted)
    (ogent-zen-edit--set-request-status
     (ogent-zen-edit-preview-request-marker
      ogent-zen-edit--pending-preview)
     "accepted")
    (ogent-zen-edit--refresh-target-metadata
     ogent-zen-edit--pending-preview)))

(defun ogent-zen-edit--reject-hook ()
  "Mark the pending Zen edit as rejected."
  (when ogent-zen-edit--pending-preview
    (setf (ogent-zen-edit-preview-status
           ogent-zen-edit--pending-preview)
          'rejected)
    (ogent-zen-edit--set-request-status
     (ogent-zen-edit-preview-request-marker
      ogent-zen-edit--pending-preview)
     "rejected")
    (ogent-zen-edit--refresh-target-metadata
     ogent-zen-edit--pending-preview)))

(defun ogent-zen-edit--scope-from-transcript (request)
  "Reconstruct a Zen edit scope from REQUEST metadata."
  (save-excursion
    (goto-char request)
    (unless (ogent-zen--request-heading-p)
      (user-error "Point is not on a Zen request"))
    (let* ((heading (save-excursion
                      (or (and (org-up-heading-safe) (point))
                          (user-error "No user heading above edit request"))))
           (kind (intern (or (org-entry-get request "OGENT_SCOPE_KIND")
                             "region")))
           (beg (and-let* ((raw (org-entry-get request "OGENT_TARGET_BEGIN")))
                  (string-to-number raw)))
           (end (and-let* ((raw (org-entry-get request "OGENT_TARGET_END")))
                  (string-to-number raw)))
           (instruction (org-entry-get request "OGENT_INSTRUCTION")))
      (make-ogent-zen-scope
       :kind kind
       :heading-point heading
       :start-marker (and beg (> beg 0) (copy-marker beg))
       :end-marker (and end (> end 0) (copy-marker end t))
       :breadcrumb (ogent-zen--breadcrumb heading)
       :instruction instruction
       :edit-p t))))

(defun ogent-zen-edit--preview-from-response (scope response request-marker)
  "Parse RESPONSE and preview its edit against SCOPE."
  (let* ((edit (ogent-zen-edit--parse-search-replace response))
         (old-text (plist-get edit :old-text))
         (new-text (plist-get edit :new-text)))
    (ogent-zen-edit--preview-replacement
     scope old-text new-text request-marker)))

(defun ogent-zen-preview-edit-from-request (context request-pos)
  "Preview the structured edit for CONTEXT at REQUEST-POS."
  (save-excursion
    (goto-char request-pos)
    (let* ((request-marker (copy-marker request-pos))
           (scope (or (plist-get context :zen-scope)
                      (ogent-zen-edit--scope-from-transcript request-pos)))
           (response (ogent-zen--preferred-response-heading
                      (ogent-zen--subtree-end)))
           (body (and response (ogent-zen--response-body-text response))))
      (unless response
        (user-error "This edit request has no response"))
      (condition-case err
          (ogent-zen-edit--preview-from-response scope body request-marker)
        (error
         (let ((message (error-message-string err)))
           (ogent-zen-edit--set-request-status request-marker "error" message)
           (ogent-zen-edit--insert-error-block request-marker message)
           (user-error "%s" message)))))))

;;;###autoload
(defun ogent-zen-apply-last-edit ()
  "Apply the latest structured Zen edit response at point as an inline diff."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Zen edit application requires an Org buffer"))
  (let ((request (ogent-zen--transcript-request-or-error)))
    (ogent-zen-preview-edit-from-request nil request)))

;;;###autoload
(defun ogent-zen-accept-edit ()
  "Accept the pending Zen inline edit preview."
  (interactive)
  (unless (bound-and-true-p inline-diff-mode)
    (user-error "No pending inline diff to accept"))
  (inline-diff-accept-all))

;;;###autoload
(defun ogent-zen-reject-edit ()
  "Reject the pending Zen inline edit preview and restore original text."
  (interactive)
  (unless (bound-and-true-p inline-diff-mode)
    (user-error "No pending inline diff to reject"))
  (inline-diff-reject-all))

;;;###autoload
(defun ogent-zen-copy-response ()
  "Copy the response body for the Zen transcript at point."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Zen transcript commands require an Org buffer"))
  (let* ((response (ogent-zen--response-heading-or-error))
         (text (ogent-zen--response-body-text response)))
    (kill-new text)
    (message "ogent: Copied response: %s"
             (ogent-zen--char-count-label (length text)))
    text))

(defun ogent-zen--transcript-request-or-error ()
  "Return the Zen request owning point, or signal a user error."
  (or (ogent-zen--transcript-request-heading)
      (user-error "Point is not inside a Zen transcript")))

;;;###autoload
(defun ogent-zen-toggle-transcript ()
  "Toggle folding for the Zen transcript at point."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Zen transcript commands require an Org buffer"))
  (let ((request (ogent-zen--transcript-request-or-error)))
    (save-excursion
      (goto-char request)
      (if (ogent-zen--subtree-folded-p)
          (when (fboundp 'org-fold-show-subtree)
            (org-fold-show-subtree))
        (when (fboundp 'org-fold-hide-subtree)
          (org-fold-hide-subtree))))
    (ogent-zen-refresh-at request)))

(defun ogent-zen--mouse-toggle-transcript (event)
  "Toggle the Zen transcript clicked by mouse EVENT."
  (interactive "e")
  (mouse-set-point event)
  (ogent-zen-toggle-transcript))

;;;###autoload
(defun ogent-zen-show-error ()
  "Jump to the error output in the Zen transcript at point."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Zen transcript commands require an Org buffer"))
  (let ((request (ogent-zen--transcript-request-or-error)))
    (goto-char request)
    (when (fboundp 'org-fold-show-subtree)
      (org-fold-show-subtree))
    (let ((end (ogent-zen--subtree-end)))
      (unless (re-search-forward
               "^[ \t]*#\\+begin_quote[ \t]+ogent-error\\b\\|\\bTool error:"
               end t)
        (user-error "This Zen transcript has no visible error"))
      (beginning-of-line)
      (recenter))))

(defconst ogent-zen--review-properties
  '("OGENT_DECISION"
    "OGENT_REVIEW_STATUS"
    "OGENT_USEFULNESS"
    "OGENT_LINEAGE"
    "OGENT_OUTCOME"
    "OGENT_REVIEWED_AT"
    "OGENT_REVIEWER"
    "OGENT_REVIEW_NOTE")
  "Structured review properties persisted on Zen transcripts.")

(defun ogent-zen--review-timestamp ()
  "Return the current timestamp for review metadata."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun ogent-zen--reviewer-id ()
  "Return the current reviewer identifier."
  (or user-login-name user-real-login-name user-full-name "unknown"))

(defun ogent-zen--set-entry-value (target property value)
  "Set PROPERTY on TARGET to VALUE, or clear it when VALUE is nil."
  (if value
      (org-entry-put target property value)
    (org-entry-delete target property)))

(defun ogent-zen--top-review-drawer-region (target)
  "Return the top-level review drawer region for TARGET, or nil."
  (save-excursion
    (goto-char target)
    (let ((end (ogent-zen--subtree-end))
          region)
      (forward-line 1)
      (when (looking-at "^[ \t]*:PROPERTIES:[ \t]*$")
        (ogent-zen--skip-drawer-at-point end '("PROPERTIES")))
      (skip-chars-forward "\n\t ")
      (when (looking-at "^[ \t]*:REVIEW:[ \t]*$")
        (let ((start (line-beginning-position)))
          (when (re-search-forward "^[ \t]*:END:[ \t]*$" end t)
            (forward-line 1)
            (setq region (cons start (point))))))
      region)))

(defun ogent-zen--review-drawer-point (target)
  "Return the insertion point for a review drawer under TARGET."
  (save-excursion
    (goto-char target)
    (let ((end (ogent-zen--subtree-end)))
      (forward-line 1)
      (when (looking-at "^[ \t]*:PROPERTIES:[ \t]*$")
        (ogent-zen--skip-drawer-at-point end '("PROPERTIES")))
      (point))))

(defun ogent-zen--review-drawer-lines (target)
  "Return visible review drawer lines for TARGET."
  (save-excursion
    (goto-char target)
    (let ((decision (ogent-zen--review-decision))
          (review-status (ogent-zen--review-status-value))
          (usefulness (ogent-zen--review-usefulness))
          (lineage (ogent-zen--review-lineage))
          (outcome (ogent-zen--review-outcome))
          (selected-model (org-entry-get (point) "OGENT_SELECTED_MODEL"))
          (reviewed-at (org-entry-get (point) "OGENT_REVIEWED_AT"))
          (reviewer (org-entry-get (point) "OGENT_REVIEWER"))
          (note (org-entry-get (point) "OGENT_REVIEW_NOTE")))
      (delq nil
            (list (when decision
                    (format "Decision: %s" decision))
                  (when review-status
                    (format "Review status: %s" review-status))
                  (when usefulness
                    (format "Usefulness: %s" usefulness))
                  (when lineage
                    (format "Lineage: %s" lineage))
                  (when outcome
                    (format "Outcome: %s" outcome))
                  (when selected-model
                    (format "Selected model: %s" selected-model))
                  (when reviewed-at
                    (format "Reviewed at: %s" reviewed-at))
                  (when reviewer
                    (format "Reviewer: %s" reviewer))
                  (when note
                    (format "Reason: %s" note)))))))

(defun ogent-zen--sync-legacy-review (target)
  "Mirror structured review metadata into legacy `OGENT_REVIEW' on TARGET."
  (let ((legacy (save-excursion
                  (goto-char target)
                  (or (let ((decision (ogent-zen--review-decision)))
                        (and (memq decision '(accepted rejected)) decision))
                      (let ((usefulness (ogent-zen--review-usefulness)))
                        (and (eq usefulness 'useful) usefulness))
                      (let ((review-status
                             (ogent-zen--review-status-value)))
                        (and (eq review-status 'needs-review) review-status))
                      (let ((lineage (ogent-zen--review-lineage)))
                        (and (memq lineage '(stale superseded)) lineage))
                      (let ((outcome (ogent-zen--review-outcome)))
                        (and (eq outcome 'failed) outcome))))))
    (ogent-zen--set-entry-value
     target "OGENT_REVIEW" (and legacy (symbol-name legacy)))))

(defun ogent-zen--sync-review-drawer (target)
  "Upsert or remove the visible review drawer for TARGET."
  (let ((region (ogent-zen--top-review-drawer-region target))
        (lines (ogent-zen--review-drawer-lines target)))
    (save-excursion
      (when region
        (delete-region (car region) (cdr region)))
      (when lines
        (goto-char (ogent-zen--review-drawer-point target))
        (insert ":REVIEW:\n")
        (dolist (line lines)
          (insert line "\n"))
        (insert ":END:\n")))))

(defun ogent-zen--clear-review-properties (target)
  "Delete structured review properties from TARGET."
  (dolist (property ogent-zen--review-properties)
    (org-entry-delete target property)))

(defun ogent-zen--sync-request-selected-model (request)
  "Synchronize `OGENT_SELECTED_MODEL' on REQUEST from accepted responses."
  (save-excursion
    (goto-char request)
    (let ((request-level (org-current-level))
          (end (ogent-zen--subtree-end))
          accepted useful)
      (forward-line 1)
      (while (re-search-forward org-heading-regexp end t)
        (beginning-of-line)
        (when (and (= (org-current-level) (1+ request-level))
                   (ogent-zen--response-heading-p))
          (let* ((heading (org-get-heading t t t t))
                 (model (ogent-zen--response-model-id heading))
                 (decision (ogent-zen--review-decision))
                 (usefulness-state (ogent-zen--review-usefulness)))
            (when (and (null accepted) (eq decision 'accepted))
              (setq accepted model))
            (when (and (null useful) (eq usefulness-state 'useful))
              (setq useful model))))
        (forward-line 1))
      (ogent-zen--set-entry-value
       request "OGENT_SELECTED_MODEL" (or accepted useful)))))

(defun ogent-zen--clear-sibling-accepted-responses (request keep-response)
  "Clear accepted sibling responses under REQUEST except KEEP-RESPONSE."
  (save-excursion
    (goto-char request)
    (let ((request-level (org-current-level))
          (end (ogent-zen--subtree-end)))
      (forward-line 1)
      (while (re-search-forward org-heading-regexp end t)
        (beginning-of-line)
        (when (and (= (org-current-level) (1+ request-level))
                   (ogent-zen--response-heading-p)
                   (/= (point) keep-response)
                   (eq (ogent-zen--effective-review-state) 'accepted))
          (org-entry-delete (point) "OGENT_DECISION")
          (org-entry-delete (point) "OGENT_REVIEW")
          (ogent-zen--sync-legacy-review (point))
          (ogent-zen--sync-review-drawer (point)))
        (forward-line 1)))))

(defun ogent-zen--stamp-review (target note)
  "Record review timestamp, reviewer, and NOTE on TARGET."
  (ogent-zen--set-entry-value target "OGENT_REVIEWED_AT"
                              (ogent-zen--review-timestamp))
  (ogent-zen--set-entry-value target "OGENT_REVIEWER"
                              (ogent-zen--reviewer-id))
  (ogent-zen--set-entry-value target "OGENT_REVIEW_NOTE" note))

(defun ogent-zen--resolve-review-target (&optional target-kind)
  "Return review target info plist for TARGET-KIND.
TARGET-KIND is one of nil, `run', or `response'."
  (let* ((request (ogent-zen--transcript-request-or-error))
         (response (pcase target-kind
                     ('run nil)
                     ('response
                      (or (ogent-zen--current-response-heading)
                          (ogent-zen--first-response-heading request)
                          (user-error "This Zen transcript has no response")))
                     (_ (ogent-zen--current-response-heading))))
         (target (or response request)))
    (list :request request
          :response response
          :target target
          :kind (if response 'response 'run)
          :model (and response
                      (save-excursion
                        (goto-char response)
                        (ogent-zen--response-model-id
                         (org-get-heading t t t t)))))))

(defun ogent-zen--update-review-target (target &rest properties)
  "Apply review PROPERTIES to TARGET, then sync legacy and visible metadata."
  (while properties
    (let ((property (pop properties))
          (value (pop properties)))
      (ogent-zen--set-entry-value target property value)))
  (ogent-zen--sync-legacy-review target)
  (ogent-zen--sync-review-drawer target))

(defun ogent-zen--set-review-state (state &optional target-kind)
  "Apply review STATE to the current Zen transcript TARGET-KIND."
  (let* ((info (ogent-zen--resolve-review-target target-kind))
         (request (plist-get info :request))
         (response (plist-get info :response))
         (target (plist-get info :target))
         (model (plist-get info :model)))
    (save-excursion
      (pcase state
        ((or `nil "clear")
         (ogent-zen--clear-review-properties target)
         (org-entry-delete target "OGENT_REVIEW")
         (ogent-zen--sync-review-drawer target))
        ("accepted"
         (ogent-zen--stamp-review target nil)
         (ogent-zen--update-review-target
          target
          "OGENT_DECISION" "accepted"
          "OGENT_REVIEW_STATUS" "reviewed"
          "OGENT_LINEAGE" "current"
          "OGENT_OUTCOME" "done")
         (when response
           (ogent-zen--clear-sibling-accepted-responses request response))
         (ogent-zen--stamp-review request nil)
         (ogent-zen--update-review-target
          request
          "OGENT_DECISION" (unless response "accepted")
          "OGENT_REVIEW_STATUS" "reviewed"
          "OGENT_LINEAGE" "current"
          "OGENT_SELECTED_MODEL" model))
        ("useful"
         (ogent-zen--stamp-review target nil)
         (ogent-zen--update-review-target
          target
          "OGENT_USEFULNESS" "useful"
          "OGENT_REVIEW_STATUS" "reviewed")
         (when response
           (ogent-zen--stamp-review request nil)
           (ogent-zen--update-review-target
            request
            "OGENT_REVIEW_STATUS" "reviewed"
            "OGENT_SELECTED_MODEL" model)))
        ("needs-review"
         (ogent-zen--stamp-review target nil)
         (ogent-zen--update-review-target
          target
          "OGENT_DECISION" nil
          "OGENT_USEFULNESS" nil
          "OGENT_REVIEW_STATUS" "needs-review"))
        ("stale"
         (ogent-zen--stamp-review target nil)
         (ogent-zen--update-review-target
          target
          "OGENT_LINEAGE" "stale"))
        ("superseded"
         (ogent-zen--stamp-review target nil)
         (ogent-zen--update-review-target
          target
          "OGENT_LINEAGE" "superseded"))
        ("rejected"
         (ogent-zen--stamp-review target nil)
         (ogent-zen--update-review-target
          target
          "OGENT_DECISION" "rejected"
          "OGENT_REVIEW_STATUS" "reviewed"))
        ("failed"
         (ogent-zen--stamp-review target nil)
         (ogent-zen--update-review-target
          target
          "OGENT_OUTCOME" "failed"
          "OGENT_REVIEW_STATUS" "reviewed"))
        (_
         (user-error "Unknown Zen review state: %s" state)))
      (when response
        (ogent-zen--sync-request-selected-model request)
        (ogent-zen--sync-review-drawer request))
      (ogent-zen-refresh-at request))))

(defun ogent-zen--review-prompt (target-kind)
  "Return a specific review prompt for TARGET-KIND."
  (let* ((info (ogent-zen--resolve-review-target target-kind))
         (kind (plist-get info :kind)))
    (pcase kind
      ('response
       (format "Review response from %s: [a]ccept [u]seful [n]needs-review [s]stale [r]eject [f]failed [c]lear [.]describe"
               (or (plist-get info :model) "model")))
      (_
       (save-excursion
         (goto-char (plist-get info :request))
         (format "Review run “%s”: [a]ccept [u]useful [n]needs-review [s]stale [x]superseded [r]eject [f]failed [c]lear [.]describe"
                 (ogent-zen--request-display-title
                  (substring-no-properties
                   (or (org-entry-get (point) "OGENT_RESULT_TITLE")
                       (org-get-heading t t t t))))))))))

(defun ogent-zen--dispatch-review-key (key target-kind)
  "Handle review KEY for TARGET-KIND."
  (pcase key
    (?a (ogent-zen--set-review-state "accepted" target-kind))
    (?u (ogent-zen--set-review-state "useful" target-kind))
    (?n (ogent-zen--set-review-state "needs-review" target-kind))
    (?s (ogent-zen--set-review-state "stale" target-kind))
    (?x (ogent-zen--set-review-state "superseded" target-kind))
    (?r (ogent-zen--set-review-state "rejected" target-kind))
    (?f (ogent-zen--set-review-state "failed" target-kind))
    (?c (ogent-zen--set-review-state nil target-kind))
    (?. (ogent-review-describe))
    (?q (message "Review unchanged"))
    (_ (user-error "Unknown review key"))))

;;;###autoload
(defun ogent-zen-set-review (state)
  "Set the review STATE for the Zen request or response at point."
  (interactive
   (list (let ((choice (completing-read
                        "Review state: "
                        (append
                         (mapcar (lambda (entry)
                                   (symbol-name (car entry)))
                                 ogent-zen--review-states)
                         '("clear"))
                        nil t)))
           (unless (string= choice "clear")
             choice))))
  (ogent-zen--set-review-state state))

;;;###autoload
(defun ogent-zen-review-run ()
  "Review the current Zen run explicitly."
  (interactive)
  (message "%s" (ogent-zen--review-prompt 'run))
  (ogent-zen--dispatch-review-key (read-key) 'run))

;;;###autoload
(defun ogent-zen-review-response ()
  "Review the current Zen response explicitly."
  (interactive)
  (message "%s" (ogent-zen--review-prompt 'response))
  (ogent-zen--dispatch-review-key (read-key) 'response))

;;;###autoload
(defun ogent-zen-review-menu ()
  "Review the current Zen run or response with an explicit prompt."
  (interactive)
  (let ((target-kind (if (ogent-zen--current-response-heading)
                         'response
                       'run)))
    (message "%s" (ogent-zen--review-prompt target-kind))
    (ogent-zen--dispatch-review-key (read-key) target-kind)))

;;;###autoload
(defun ogent-zen-accept-response ()
  "Accept the current Zen response and select it for the parent request."
  (interactive)
  (ogent-zen--set-review-state "accepted" 'response))

;;;###autoload
(defun ogent-zen-reject-response ()
  "Reject the current Zen response."
  (interactive)
  (ogent-zen--set-review-state "rejected" 'response))

;;;###autoload
(defun ogent-zen-mark-accepted ()
  "Mark the Zen request or response at point as accepted."
  (interactive)
  (ogent-zen--set-review-state "accepted"))

;;;###autoload
(defun ogent-zen-mark-useful ()
  "Mark the Zen request or response at point as useful."
  (interactive)
  (ogent-zen--set-review-state "useful"))

;;;###autoload
(defun ogent-zen-mark-needs-review ()
  "Mark the Zen request or response at point as needing review."
  (interactive)
  (ogent-zen--set-review-state "needs-review"))

;;;###autoload
(defun ogent-zen-mark-stale ()
  "Mark the Zen request or response at point as stale."
  (interactive)
  (ogent-zen--set-review-state "stale"))

;;;###autoload
(defun ogent-zen-mark-superseded ()
  "Mark the Zen request or response at point as superseded."
  (interactive)
  (ogent-zen--set-review-state "superseded"))

;;;###autoload
(defun ogent-zen-mark-rejected ()
  "Mark the Zen request or response at point as rejected."
  (interactive)
  (ogent-zen--set-review-state "rejected"))

;;;###autoload
(defun ogent-zen-mark-failed ()
  "Mark the Zen request or response at point as failed."
  (interactive)
  (ogent-zen--set-review-state "failed"))

;;;###autoload
(defun ogent-zen-clear-review ()
  "Clear the review state for the Zen request or response at point."
  (interactive)
  (ogent-zen--set-review-state nil))

(defvar-local ogent-review-dashboard-source-buffer nil
  "Source Org buffer shown by the current review dashboard.")

(defun ogent-zen--review-item-heading-p ()
  "Return non-nil when point is on a reviewable Zen heading."
  (or (ogent-zen--response-heading-p)
      (ogent-zen--request-heading-p)))

(defun ogent-zen--review-item-state (&optional target)
  "Return the queue state for TARGET or point."
  (or (let ((outcome (ogent-zen--review-outcome target)))
        (and (eq outcome 'failed) 'failed))
      (let ((lineage (ogent-zen--review-lineage target)))
        (and (eq lineage 'stale) 'stale))
      (let ((status (ogent-zen--review-status-value target)))
        (and (eq status 'needs-review) status))
      (let ((decision (ogent-zen--review-decision target)))
        (and (memq decision '(accepted rejected)) decision))
      (let ((usefulness (ogent-zen--review-usefulness target)))
        (and (eq usefulness 'useful) usefulness))
      (and (eq (ogent-zen--review-status-value target) 'reviewed)
           (org-entry-get (or target (point)) "OGENT_SELECTED_MODEL")
           'accepted)
      (let ((lineage (ogent-zen--review-lineage target)))
        (and (eq lineage 'superseded) lineage))
      'unreviewed))

(defun ogent-zen--request-reviewable-p ()
  "Return non-nil when the current request should appear in review queues."
  (or (not (ogent-zen--first-response-heading (point)))
      (ogent-zen--review-decision)
      (ogent-zen--review-status-value)
      (ogent-zen--review-usefulness)
      (ogent-zen--review-lineage)
      (ogent-zen--legacy-review-state)))

(defun ogent-zen--review-item-label ()
  "Return a compact label for the review item at point."
  (cond
   ((ogent-zen--response-heading-p)
    (format "response %s — %s"
            (ogent-zen--response-model-id (org-get-heading t t t t))
            (or (ogent-zen--response-title-from-text
                 (ogent-zen--response-body-text (point)))
                "answer")))
   ((ogent-zen--request-heading-p)
    (or (org-entry-get (point) "OGENT_RESULT_TITLE")
        (ogent-zen--request-display-title
         (substring-no-properties (org-get-heading t t t t)))))
   (t
    (substring-no-properties (org-get-heading t t t t)))))

(defun ogent-zen--collect-review-items ()
  "Return reviewable Zen items in the current buffer."
  (save-excursion
    (let (items)
      (goto-char (point-min))
      (while (re-search-forward org-heading-regexp nil t)
        (beginning-of-line)
        (when (and (ogent-zen--review-item-heading-p)
                   (or (ogent-zen--response-heading-p)
                       (ogent-zen--request-reviewable-p)))
          (push (list :marker (copy-marker (point))
                      :kind (if (ogent-zen--response-heading-p)
                                'response
                              'run)
                      :state (ogent-zen--review-item-state)
                      :path (or (ogent-zen--path-parent-label
                                 (org-entry-get (point) "OGENT_PATH"))
                                (org-entry-get (point) "OGENT_PATH"))
                      :label (ogent-zen--review-item-label))
                items))
        (forward-line 1))
      (nreverse items))))

(defun ogent-zen--review-attention-p (state)
  "Return non-nil when review STATE needs attention."
  (memq state '(unreviewed needs-review stale failed)))

(defun ogent-zen--jump-review-item (item)
  "Jump to review ITEM."
  (let ((marker (plist-get item :marker)))
    (unless (and (markerp marker) (marker-buffer marker))
      (user-error "Review item no longer exists"))
    (pop-to-buffer (marker-buffer marker))
    (goto-char marker)
    (when (fboundp 'org-fold-show-subtree)
      (org-fold-show-subtree))
    (recenter)))

(defun ogent-zen--review-step (direction)
  "Jump to the next pending review item in DIRECTION."
  (let* ((origin (point))
         (items (ogent-zen--collect-review-items))
         (positions
          (mapcar (lambda (item)
                    (cons (marker-position (plist-get item :marker)) item))
                  items))
         (ordered (sort positions (lambda (a b) (< (car a) (car b)))))
         target)
    (setq target
          (if (> direction 0)
              (or (cl-find-if
                   (lambda (entry)
                     (and (> (car entry) origin)
                          (ogent-zen--review-attention-p
                           (plist-get (cdr entry) :state))))
                   ordered)
                  (cl-find-if
                   (lambda (entry)
                     (ogent-zen--review-attention-p
                      (plist-get (cdr entry) :state)))
                   ordered))
            (or (cl-find-if
                 (lambda (entry)
                   (and (< (car entry) origin)
                        (ogent-zen--review-attention-p
                         (plist-get (cdr entry) :state))))
                 (reverse ordered))
                (cl-find-if
                 (lambda (entry)
                   (ogent-zen--review-attention-p
                    (plist-get (cdr entry) :state)))
                 (reverse ordered)))))
    (unless target
      (user-error "No Zen review items need attention"))
    (ogent-zen--jump-review-item (cdr target))))

(defvar ogent-review-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-review-dashboard-visit)
    (define-key map (kbd "g") #'ogent-review-dashboard-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `ogent-review-dashboard-mode'.")

(define-derived-mode ogent-review-dashboard-mode special-mode "Ogent-Review"
  "Major mode for browsing Zen review queues.")

(defun ogent-review-dashboard-visit ()
  "Visit the review item at point."
  (interactive)
  (let ((marker (get-text-property (point) 'ogent-review-marker)))
    (unless marker
      (user-error "No review item on this line"))
    (pop-to-buffer (marker-buffer marker))
    (goto-char marker)
    (when (fboundp 'org-fold-show-subtree)
      (org-fold-show-subtree))
    (recenter)))

(defun ogent-review-dashboard-refresh ()
  "Refresh the current review dashboard."
  (interactive)
  (unless (buffer-live-p ogent-review-dashboard-source-buffer)
    (user-error "Dashboard source buffer is gone"))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (let ((items (with-current-buffer ogent-review-dashboard-source-buffer
                   (ogent-zen--collect-review-items)))
          (states '(unreviewed needs-review stale failed accepted useful
                               rejected superseded))
          (counts (make-hash-table :test 'eq)))
      (dolist (item items)
        (puthash (plist-get item :state)
                 (1+ (gethash (plist-get item :state) counts 0))
                 counts))
      (insert "Ogent Review Dashboard\n\n")
      (insert (format "Source: %s\n\n"
                      (buffer-name ogent-review-dashboard-source-buffer)))
      (insert "Queue\n-----\n")
      (dolist (state states)
        (let ((count (gethash state counts 0)))
          (when (> count 0)
            (insert (format "%-12s %d\n" state count)))))
      (insert "\nNeeds attention\n---------------\n")
      (dolist (item items)
        (when (ogent-zen--review-attention-p (plist-get item :state))
          (let ((start (point)))
            (insert (format "- [%s] %s\n"
                            (plist-get item :state)
                            (plist-get item :label)))
            (add-text-properties
             start (point)
             (list 'ogent-review-marker
                   (plist-get item :marker)
                   'mouse-face 'highlight)))))
      (insert "\nAll review items\n----------------\n")
      (dolist (item items)
        (let ((start (point)))
          (insert (format "- [%s] %s\n"
                          (plist-get item :state)
                          (plist-get item :label)))
          (add-text-properties
           start (point)
           (list 'ogent-review-marker
                 (plist-get item :marker)
                 'mouse-face 'highlight)))))
    (goto-char (point-min))))

;;;###autoload
(defun ogent-review-dashboard ()
  "Show a Zen review dashboard for the current Org buffer."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Review dashboard requires an Org buffer"))
  (let ((source (current-buffer))
        (buffer (get-buffer-create "*Ogent Review*")))
    (with-current-buffer buffer
      (ogent-review-dashboard-mode)
      (setq-local ogent-review-dashboard-source-buffer source)
      (ogent-review-dashboard-refresh))
    (pop-to-buffer buffer)))

;;;###autoload
(defun ogent-review-describe ()
  "Explain the current review target and stored metadata."
  (interactive)
  (if-let ((request (ogent-zen--transcript-request-heading)))
      (let* ((info (ogent-zen--resolve-review-target
                    (if (ogent-zen--current-response-heading)
                        'response
                      'run)))
             (target (plist-get info :target)))
        (with-help-window "*Ogent Review*"
          (save-excursion
            (goto-char target)
            (princ (format "Target: %s\n"
                           (if (plist-get info :response)
                               (format "response %s"
                                       (plist-get info :model))
                             "run")))
            (princ (format "Primary state: %s\n"
                           (or (ogent-zen--effective-review-state) 'unreviewed)))
            (dolist (property (append ogent-zen--review-properties
                                      '("OGENT_REVIEW" "OGENT_SELECTED_MODEL")))
              (when-let ((value (org-entry-get (point) property)))
                (princ (format "%s: %s\n" property value)))))))
    (with-help-window "*Ogent Review*"
      (princ "Completion review item.\n")
      (princ "Use C-c , a/x/n/p to accept, reject, or navigate completions.\n"))))

;;;###autoload
(defun ogent-review-next ()
  "Move to the next review item, using Zen or completion context."
  (interactive)
  (if (ogent-zen--transcript-request-heading)
      (ogent-zen--review-step 1)
    (call-interactively #'ogent-completion-next)))

;;;###autoload
(defun ogent-review-previous ()
  "Move to the previous review item, using Zen or completion context."
  (interactive)
  (if (ogent-zen--transcript-request-heading)
      (ogent-zen--review-step -1)
    (call-interactively #'ogent-completion-prev)))

;;;###autoload
(defun ogent-review-reject ()
  "Reject the current review item, using Zen or completion semantics."
  (interactive)
  (if (ogent-zen--transcript-request-heading)
      (if (ogent-zen--current-response-heading)
          (ogent-zen-reject-response)
        (ogent-zen--set-review-state "rejected" 'run))
    (call-interactively #'ogent-completion-reject)))

;;;###autoload
(defun ogent-review-useful ()
  "Mark the current Zen review item useful."
  (interactive)
  (unless (ogent-zen--transcript-request-heading)
    (user-error "Useful review is only available for Zen transcripts"))
  (ogent-zen--set-review-state "useful"))

;;;###autoload
(defun ogent-review-defer ()
  "Mark the current Zen review item as needing review."
  (interactive)
  (unless (ogent-zen--transcript-request-heading)
    (user-error "Deferred review is only available for Zen transcripts"))
  (ogent-zen--set-review-state "needs-review"))

;;;###autoload
(defun ogent-review-stale ()
  "Mark the current Zen review item stale."
  (interactive)
  (unless (ogent-zen--transcript-request-heading)
    (user-error "Stale review is only available for Zen transcripts"))
  (ogent-zen--set-review-state "stale"))

;;;###autoload
(defun ogent-zen-run-scope (scope &optional models preset templates)
  "Run Zen SCOPE with normal tree context preservation.
MODELS, PRESET, and TEMPLATES are forwarded to request dispatch unchanged."
  (let* ((start-marker (ogent-zen-scope-start-marker scope))
         (end-marker (ogent-zen-scope-end-marker scope))
         (region-start (ogent-zen--marker-position start-marker))
         (region-end (ogent-zen--marker-position end-marker))
         (heading-point (ogent-zen-scope-heading-point scope))
         (prompt (ogent-zen--scope-prompt scope)))
    (ogent-ui--dispatch-request
     (current-buffer) region-start region-end prompt models preset templates
     heading-point
     (lambda (context)
       (ogent-zen--context-transform-for-scope context scope)))))

;;;###autoload
(defun ogent-run-subtree (&optional models preset templates)
  "Run the current Org subtree as an ogent prompt.
The bullet at point (heading plus body and user children) becomes the
prompt; ancestor bullets are sent with full content as parent context.
When point is inside a generated transcript, the owning user bullet is
run instead.  MODELS, PRESET, and TEMPLATES are forwarded to the
request dispatch unchanged."
  (interactive)
  (ogent-zen-run-scope
   (ogent-zen--scope-at-point 'subtree)
   models preset templates))

;;;###autoload
(defun ogent-zen-run-region (question &optional models preset templates)
  "Ask QUESTION about the active region with Zen tree context."
  (interactive
   (list (read-string "Ask about selected text: ")))
  (ogent-zen-run-scope
   (ogent-zen--scope-at-point 'region question nil)
   models preset templates))

;;;###autoload
(defun ogent-zen-edit-region (instruction &optional models preset templates)
  "Rewrite the active region according to INSTRUCTION with Zen context."
  (interactive
   (list (read-string "Rewrite selected text: ")))
  (ogent-zen-run-scope
   (ogent-zen--scope-at-point 'region instruction t)
   models preset templates))

;;;###autoload
(defun ogent-zen-rewrite-paragraph (instruction &optional models preset templates)
  "Rewrite the paragraph at point according to INSTRUCTION with Zen context."
  (interactive
   (list (read-string "Rewrite paragraph: ")))
  (ogent-zen-run-scope
   (ogent-zen--scope-at-point 'paragraph instruction t)
   models preset templates))

;;;###autoload
(defun ogent-zen-rewrite-sentence (instruction &optional models preset templates)
  "Rewrite the sentence at point according to INSTRUCTION with Zen context."
  (interactive
   (list (read-string "Rewrite sentence: ")))
  (ogent-zen-run-scope
   (ogent-zen--scope-at-point 'sentence instruction t)
   models preset templates))

;;;###autoload
(defun ogent-zen-edit-dwim (instruction &optional models preset templates)
  "Rewrite the active region or nearest text element according to INSTRUCTION."
  (interactive
   (list (read-string "Rewrite here: ")))
  (ogent-zen-run-scope
   (ogent-zen--scope-at-point nil instruction t)
   models preset templates))

;;;###autoload
(defun ogent-zen-rerun ()
  "Re-run the Zen transcript at point, or run the current bullet.
On a generated `Request:' / `Response' transcript, delete that
transcript and dispatch the owning bullet again — edit the bullet, then
re-run.  Anywhere else this behaves like `ogent-run-subtree'.  A
still-streaming transcript must be aborted before it can be re-run.
The deletion and the new run form one undoable change group."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Run subtree requires an Org buffer"))
  (let ((request (ogent-zen--transcript-request-heading)))
    (if (null request)
        (ogent-run-subtree)
      (save-excursion
        (goto-char request)
        (let ((info (ogent-zen--src-info (ogent-zen--subtree-end))))
          (when (member (car-safe info) '("waiting" "typing" "tool"))
            (user-error "This run is still streaming; abort it first"))))
      (let* ((edit-p (equal (org-entry-get request "OGENT_KIND") "edit"))
             (scope (and edit-p
                         (ogent-zen-edit--scope-from-transcript request)))
             (parent (save-excursion
                       (goto-char request)
                       (and (org-up-heading-safe) (point)))))
        (unless parent
          (user-error "No user bullet above this run"))
        (atomic-change-group
          (goto-char request)
          (delete-region (point)
                         (save-excursion (org-end-of-subtree t t) (point)))
          (if scope
              (ogent-zen-run-scope scope)
            (goto-char parent)
            (ogent-run-subtree)))))))

(defun ogent-zen--ctrl-c-ctrl-c ()
  "Re-run the Zen transcript at point for `org-ctrl-c-ctrl-c-hook'.
Return non-nil only when point is on a generated Zen transcript."
  (when (and ogent-zen-mode
             (ogent-zen--transcript-request-heading))
    (ogent-zen-rerun)
    t))

(provide 'ogent-zen)
;;; ogent-zen.el ends here
