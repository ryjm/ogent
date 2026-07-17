;;; ogent-ui-models.el --- Model picker and role assignment UI -*- lexical-binding: t; -*-

;;; Commentary:
;; An oh-my-pi style model picker for ogent: switch the active model in
;; one keystroke, assign different models to different task roles
;; (edit, codemap, deep, fast), pin models onto Org subtrees via the
;; inherited `OGENT_MODEL' property, and browse the registry as an Org
;; table.  The transient header always shows the effective model at
;; point and which layer decided it (Org property, session, project,
;; role, or default).  When the per-project analytics DB has recorded
;; completions, the picker surfaces evidence per model - completion
;; count, median latency, mean star rating, and mean cost - in the
;; header, the completion annotations, and the browser table.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'org)
(require 'org-table)
(require 'ogent-models)
(require 'ogent-gptel)
(require 'ogent-analytics)
(require 'ogent-ui-theme)

;; gptel session state manipulated by the switch commands.
(defvar gptel-backend)
(defvar gptel-model)
(declare-function gptel-backend-p "ext:gptel-request" t t)

(defvar ogent-ui-models--history nil
  "Minibuffer history for model designator reads.")

;;; Formatting helpers

(defconst ogent-ui-models--provider-names
  '((gptel-openai . "OpenAI")
    (gptel-anthropic . "Anthropic"))
  "Alist mapping registry :backend symbols to display names.")

(defun ogent-ui-models--provider-name (model)
  "Return a human-readable provider name for MODEL's :backend."
  (let ((backend (plist-get model :backend)))
    (or (cdr (assq backend ogent-ui-models--provider-names))
        (let ((name (format "%s" backend)))
          (if (string-prefix-p "gptel-" name)
              (capitalize (substring name (length "gptel-")))
            name)))))

(defun ogent-ui-models--roles-resolving-to (model-id)
  "Return the role symbols whose resolution lands on MODEL-ID."
  (seq-filter (lambda (role)
                (equal (ogent-models-resolve-role role) model-id))
              (ogent-models-known-roles)))

(defun ogent-ui-models--source-label (source)
  "Return a short display label for resolution layer SOURCE."
  (pcase source
    ('org-property "org property")
    ('session "session")
    ('project "project")
    ('role "role")
    (_ "default")))

(defun ogent-ui-models--format-role (role)
  "Return a propertized ROLE assignment summary like \"edit gpt-5.6-terra\"."
  (let* ((designator (ogent-models-role-designator role))
         (resolved (ogent-models-resolve-role role))
         (alias-p (and designator (symbolp designator))))
    (concat
     (propertize (symbol-name role) 'face 'ogent-theme-secondary)
     " "
     (if alias-p
         (concat (propertize (format "@%s" designator) 'face 'ogent-theme-highlight)
                 (propertize (format "=%s" resolved) 'face 'ogent-theme-muted))
       (propertize resolved
                   'face (if designator 'ogent-theme-info 'ogent-theme-muted))))))

;;; Evidence from analytics

(defun ogent-ui-models--evidence-group-stats (db raw-ids)
  "Aggregate completion evidence in DB over the model strings RAW-IDS.
RAW-IDS lists every completions.model value that canonicalizes to
one registry model, so rows recorded under an alias and under the
canonical id aggregate together.  Returns a plist with :count,
:median-latency-ms, :mean-rating (over 1-5 star rated rows only;
thumb ratings use a different scale), and :mean-cost-usd (over
priced rows only).  Every component except :count may be nil when
the underlying rows carry no such data."
  (let* ((holes (mapconcat (lambda (_) "?") raw-ids ", "))
         (row (car (sqlite-select
                    db
                    (format "
SELECT COUNT(*),
       (SELECT AVG(ms)
        FROM (SELECT completion_latency_ms AS ms,
                     ROW_NUMBER() OVER (ORDER BY completion_latency_ms) AS rn,
                     COUNT(*) OVER () AS cnt
              FROM completions
              WHERE model IN (%s)
                AND completion_latency_ms IS NOT NULL)
        WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2)),
       AVG(CASE WHEN outcome = 'rated' THEN rating END),
       AVG(cost_usd)
FROM completions
WHERE model IN (%s)" holes holes)
                    (append raw-ids raw-ids)))))
    (list :count (nth 0 row)
          :median-latency-ms (nth 1 row)
          :mean-rating (nth 2 row)
          :mean-cost-usd (nth 3 row))))

(defun ogent-ui-models--evidence-stats ()
  "Return per-model completion evidence from the project analytics DB.
The result is an alist mapping canonical registry model ids (in
registry order) to the stat plists of
`ogent-ui-models--evidence-group-stats'.  Rows recorded under a
registry alias fold into their canonical id; rows naming no
registered model are ignored.  Returns nil when analytics is
unavailable or no registered model has recorded completions, so
callers drop the evidence entirely rather than rendering zeros."
  (when-let* ((db (ogent-analytics--get-db)))
    (let ((groups nil))
      (dolist (row (sqlite-select db "SELECT DISTINCT model FROM completions"))
        (when-let* ((canonical (ogent-models-canonical-id (car row))))
          (let ((cell (assoc canonical groups)))
            (if cell
                (setcdr cell (cons (car row) (cdr cell)))
              (push (list canonical (car row)) groups)))))
      (let ((stats nil))
        (dolist (id (ogent-models-ids))
          (when-let* ((raw-ids (cdr (assoc id groups))))
            (push (cons id (ogent-ui-models--evidence-group-stats db raw-ids))
                  stats)))
        (nreverse stats)))))

(defun ogent-ui-models--evidence-latency (ms)
  "Format the median latency MS compactly, like \"840ms\" or \"1.2s\"."
  (if (< ms 1000)
      (format "%dms" (round ms))
    (format "%.1fs" (/ ms 1000.0))))

(defun ogent-ui-models--evidence-segments (stats)
  "Return display segments for the evidence plist STATS.
Segments cover completion count, median latency, mean star rating,
and mean cost; components missing from the recorded rows produce no
segment (never a zero)."
  (delq nil
        (list (format "%d×" (plist-get stats :count))
              (when-let* ((ms (plist-get stats :median-latency-ms)))
                (concat "~" (ogent-ui-models--evidence-latency ms)))
              (when-let* ((rating (plist-get stats :mean-rating)))
                (format "★%.1f" rating))
              (when-let* ((cost (plist-get stats :mean-cost-usd)))
                (format "$%.4f" cost)))))

(defun ogent-ui-models--evidence-string (stats)
  "Format the evidence plist STATS as one compact display string."
  (mapconcat #'identity (ogent-ui-models--evidence-segments stats) " "))

(defun ogent-ui-models--evidence-cells (stats)
  "Return the browser table's four evidence cells for plist STATS.
STATS nil (a model with no recorded completions) yields empty cells,
as do components missing from the recorded rows."
  (list (if stats (format "%d" (plist-get stats :count)) "")
        (if-let* ((ms (and stats (plist-get stats :median-latency-ms))))
            (ogent-ui-models--evidence-latency ms)
          "")
        (if-let* ((rating (and stats (plist-get stats :mean-rating))))
            (format "%.1f" rating)
          "")
        (if-let* ((cost (and stats (plist-get stats :mean-cost-usd))))
            (format "$%.4f" cost)
          "")))

;;; Designator completion (annotated + grouped)

(defun ogent-ui-models--annotate (candidate pad &optional stats)
  "Return the completion annotation for CANDIDATE, padded to width PAD.
STATS, when non-nil, is the evidence alist of
`ogent-ui-models--evidence-stats'; a model candidate with recorded
completions gets its evidence appended after the description."
  (let ((padding (make-string (max 1 (- pad (length candidate))) ?\s)))
    (if (string-prefix-p "@" candidate)
        (concat padding
                (propertize (format "role → %s"
                                    (ogent-models-resolve-role
                                     (intern (substring candidate 1))))
                            'face 'ogent-theme-muted))
      (let* ((model (ogent-models-get candidate))
             (desc (or (plist-get model :description) ""))
             (roles (ogent-ui-models--roles-resolving-to candidate))
             (evidence
              (when-let* ((entry (cdr (assoc candidate stats))))
                (propertize
                 (concat "  " (ogent-ui-models--evidence-string entry))
                 'face 'ogent-theme-info)))
             (markers
              (concat
               (when (equal candidate ogent-default-model)
                 (propertize "  ←default" 'face 'ogent-theme-success))
               (when roles
                 (propertize (format "  [%s]"
                                     (mapconcat #'symbol-name roles ","))
                             'face 'ogent-theme-highlight)))))
        (concat padding (propertize desc 'face 'ogent-theme-muted)
                evidence markers)))))

(defun ogent-ui-models--group (candidate transform)
  "Return the completion group title for CANDIDATE.
When TRANSFORM is non-nil return CANDIDATE itself, per the
`group-function' completion metadata contract."
  (if transform
      candidate
    (if (string-prefix-p "@" candidate)
        "Roles"
      (let ((model (ogent-models-get candidate)))
        (if model (ogent-ui-models--provider-name model) "Other")))))

(defun ogent-ui-models-read (prompt &optional include-roles)
  "Read a model designator with PROMPT and rich completion UI.
Candidates are registry model ids grouped by provider, each
annotated with its description, role back-references, a default
marker, and - when the project analytics DB has recorded
completions - its per-model evidence.  When INCLUDE-ROLES is
non-nil, \"@role\" designators are offered too.  Returns the
selected string."
  (let* ((ids (ogent-models-ids))
         (candidates (if include-roles
                         (append ids
                                 (mapcar (lambda (role)
                                           (format "@%s" role))
                                         (ogent-models-known-roles)))
                       ids))
         (pad (+ 2 (apply #'max (mapcar #'length candidates))))
         (stats (ogent-ui-models--evidence-stats))
         (table
          (lambda (string pred action)
            (if (eq action 'metadata)
                `(metadata
                  (category . ogent-model)
                  (annotation-function
                   . ,(lambda (cand) (ogent-ui-models--annotate cand pad stats)))
                  (group-function . ,#'ogent-ui-models--group)
                  (display-sort-function . ,#'identity))
              (complete-with-action action candidates string pred)))))
    (completing-read prompt table nil t nil 'ogent-ui-models--history)))

(defun ogent-ui-models--read-id (prompt)
  "Read a registered model id with PROMPT (roles excluded)."
  (ogent-ui-models-read prompt nil))

;;; Switching

(defun ogent-ui-models--apply (model-id &optional buffer-local)
  "Point gptel at MODEL-ID and return the model plist.
MODEL-ID may be an alias; all gptel state uses the canonical id.
Resolves the backend, registers the model on it, and copies
request params and capabilities onto the model symbol.  With
BUFFER-LOCAL non-nil only the current buffer's gptel state
changes; otherwise the global default is updated."
  (let* ((model (ogent-models-ensure model-id))
         (canonical (plist-get model :id))
         (backend (ogent-gptel-resolve-backend model))
         (backend (and (fboundp 'gptel-backend-p)
                       (gptel-backend-p backend)
                       backend))
         (symbol (if backend
                     (ogent-gptel-ensure-model-on-backend model backend)
                   (intern canonical))))
    (ogent-models-apply-gptel-props model)
    (if buffer-local
        (progn
          (when backend (setq-local gptel-backend backend))
          (setq-local gptel-model symbol))
      (when backend (setq-default gptel-backend backend))
      (setq-default gptel-model symbol))
    model))

;;;###autoload
(defun ogent-model-switch (model-id)
  "Switch the session model to MODEL-ID (a model id or alias).
Updates the global gptel backend and model so every ogent request
without a more specific override (Org property, role, project)
uses MODEL-ID."
  (interactive (list (ogent-ui-models--read-id "Switch model (session): ")))
  (let ((model (ogent-ui-models--apply model-id)))
    (ogent-theme-flash 'success
                       (format "Model: %s" (plist-get model :id)))))

;;;###autoload
(defun ogent-model-switch-buffer (model-id)
  "Switch this buffer's model to MODEL-ID (a model id or alias).
Sets buffer-local gptel state; other buffers keep the session model."
  (interactive (list (ogent-ui-models--read-id "Switch model (buffer): ")))
  (let ((model (ogent-ui-models--apply model-id 'buffer-local)))
    (ogent-theme-flash 'success
                       (format "Buffer model: %s" (plist-get model :id)))))

;;;###autoload
(defun ogent-model-set-default (model-id)
  "Set MODEL-ID as `ogent-default-model' and the session model.
MODEL-ID may be an alias; the canonical id is stored."
  (interactive (list (ogent-ui-models--read-id "Default model: ")))
  (let ((model (ogent-ui-models--apply model-id)))
    (setq ogent-default-model (plist-get model :id))
    (ogent-theme-flash 'success
                       (format "Default model: %s" ogent-default-model))))

;;; Org pinning

(defconst ogent-ui-models--file-keyword-regexp
  (format "^#\\+\\(?:PROPERTY\\|property\\):[ \t]+%s\\(?:[ \t].*\\)?$"
          (regexp-quote ogent-models-org-property))
  "Regexp matching the file-level OGENT_MODEL property keyword.")

(defun ogent-ui-models--file-keyword-position ()
  "Return the position of the file-level OGENT_MODEL keyword, or nil."
  (org-with-wide-buffer
   (goto-char (point-min))
   (when (re-search-forward ogent-ui-models--file-keyword-regexp nil t)
     (match-beginning 0))))

(defun ogent-ui-models--pin-file-keyword (designator)
  "Insert or update a file-level OGENT_MODEL property with DESIGNATOR."
  (org-with-wide-buffer
   (goto-char (point-min))
   (if (re-search-forward ogent-ui-models--file-keyword-regexp nil t)
       (replace-match (format "#+PROPERTY: %s %s"
                              ogent-models-org-property designator)
                      t t)
     (goto-char (point-min))
     (while (looking-at "^#\\+")
       (forward-line 1))
     (insert (format "#+PROPERTY: %s %s\n"
                     ogent-models-org-property designator))))
  ;; Refresh Org's cached file keywords so the pin applies immediately.
  (org-set-regexps-and-options))

(defun ogent-ui-models--remove-file-keyword ()
  "Remove the file-level OGENT_MODEL keyword and refresh Org's cache.
Returns non-nil when a keyword was found and removed.  The
trailing newline is deleted explicitly: appending \"\\n?\" to the
anchored regexp would demote its `$' to a literal dollar sign."
  (prog1
      (org-with-wide-buffer
       (goto-char (point-min))
       (when (re-search-forward ogent-ui-models--file-keyword-regexp nil t)
         (delete-region (match-beginning 0)
                        (min (point-max) (1+ (match-end 0))))
         t))
    (org-set-regexps-and-options)))

(defun ogent-ui-models--pin-source ()
  "Return the source of the model pin in effect at point.
The result is a cons (heading . POS) when a heading in the
ancestry carries a direct `OGENT_MODEL' property, (file . POS)
when only the file-level keyword applies, or nil when nothing
pins a model at point."
  (or (org-with-wide-buffer
       (unless (org-before-first-heading-p)
         (org-back-to-heading t)
         (let ((found nil)
               (continue t))
           (while (and continue (not found))
             (if (org-entry-get (point) ogent-models-org-property nil)
                 (setq found (cons 'heading (point)))
               (setq continue (org-up-heading-safe))))
           found)))
      (when-let* ((pos (ogent-ui-models--file-keyword-position)))
        (cons 'file pos))))

;;;###autoload
(defun ogent-model-pin-heading (designator)
  "Pin DESIGNATOR as the model for the Org subtree at point.
Sets the inherited `OGENT_MODEL' property, so every request made
from this subtree uses DESIGNATOR (a model id or \"@role\").
Before the first heading the pin lands file-wide instead."
  (interactive (list (ogent-ui-models-read "Pin model on heading: " t)))
  (unless (derived-mode-p 'org-mode)
    (user-error "Model pinning requires an Org buffer"))
  (if (org-before-first-heading-p)
      (progn
        (ogent-ui-models--pin-file-keyword designator)
        (ogent-theme-flash 'success (format "File model: %s" designator)))
    (org-entry-put (point) ogent-models-org-property designator)
    (ogent-theme-flash 'success (format "Subtree model: %s" designator))))

;;;###autoload
(defun ogent-model-pin-file (designator)
  "Pin DESIGNATOR as the file-wide model for the current Org file.
Inserts or updates a `#+PROPERTY: OGENT_MODEL' keyword, which every
heading inherits unless a deeper pin overrides it."
  (interactive (list (ogent-ui-models-read "Pin model file-wide: " t)))
  (unless (derived-mode-p 'org-mode)
    (user-error "Model pinning requires an Org buffer"))
  (ogent-ui-models--pin-file-keyword designator)
  (ogent-theme-flash 'success (format "File model: %s" designator)))

;;;###autoload
(defun ogent-model-unpin ()
  "Remove the model pin in effect at point.
Deletes a pin set directly on the current heading without asking.
When the effective pin is inherited - from an ancestor heading or
from the file-level keyword - asks before removing it at its
source, and leaves it in place on refusal."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Model pinning requires an Org buffer"))
  (pcase (ogent-ui-models--pin-source)
    (`(heading . ,pos)
     (let ((direct (and (not (org-before-first-heading-p))
                        (= pos (save-excursion
                                 (org-back-to-heading t)
                                 (point))))))
       (if direct
           (progn
             (org-entry-delete pos ogent-models-org-property)
             (ogent-theme-flash 'info "Removed subtree model pin"))
         ;; The ancestor may sit outside a subtree narrowing, where
         ;; `goto-char' silently clamps; widen for every access.
         (let ((title (org-with-wide-buffer
                       (goto-char pos)
                       (org-get-heading t t t t))))
           (if (y-or-n-p (format "Model pin is inherited from \"%s\"; remove it there? "
                                 title))
               (progn
                 (org-with-wide-buffer
                  (goto-char pos)
                  (org-entry-delete (point) ogent-models-org-property))
                 (ogent-theme-flash
                  'info (format "Removed model pin from \"%s\"" title)))
             (message "ogent: kept model pin on \"%s\"" title))))))
    (`(file . ,_pos)
     (if (or (org-before-first-heading-p)
             (y-or-n-p "Model pin is file-wide; remove the #+PROPERTY keyword? "))
         (progn
           (ogent-ui-models--remove-file-keyword)
           (ogent-theme-flash 'info "Removed file model pin"))
       (message "ogent: kept file-wide model pin")))
    (_ (message "ogent: no model pin at point"))))

;;; Roles

;;;###autoload
(defun ogent-model-assign-role (role designator)
  "Assign DESIGNATOR to model ROLE.
ROLE is one of `ogent-models-known-roles'.  DESIGNATOR is a model
id or an \"@role\" alias.  Assigning the `default' role updates
`ogent-default-model' instead of the role alist."
  (interactive
   (let* ((role (intern (completing-read
                         "Role: "
                         (mapcar #'symbol-name (ogent-models-known-roles))
                         nil t)))
          (designator (ogent-ui-models-read
                       (format "Model for role %s: " role) t)))
     (list role designator)))
  (let ((value (if (string-prefix-p "@" designator)
                   (intern (substring designator 1))
                 designator)))
    (when (eq value role)
      (user-error "Role %s cannot alias itself" role))
    (if (eq role 'default)
        (setq ogent-default-model (ogent-models-resolve-designator designator))
      (ogent-models-set-role role value))
    (ogent-theme-flash 'success (format "Role %s → %s" role designator))))

;;;###autoload
(defun ogent-model-clear-role (role)
  "Clear ROLE's assignment so it falls back to the default model."
  (interactive
   (let ((assigned (mapcar (lambda (entry) (symbol-name (car entry)))
                           ogent-model-roles)))
     (unless assigned
       (user-error "No roles are assigned"))
     (list (intern (completing-read "Clear role: " assigned nil t)))))
  (ogent-models-set-role role nil)
  (ogent-theme-flash 'info (format "Role %s → default" role)))

;;;###autoload
(defun ogent-model-save-config ()
  "Persist the default model and role assignments across sessions.
Saves `ogent-default-model' and `ogent-model-roles' with Custom."
  (interactive)
  (customize-save-variable 'ogent-default-model ogent-default-model)
  (customize-save-variable 'ogent-model-roles ogent-model-roles)
  (ogent-theme-flash 'success "Saved model configuration"))

;;; Picker transient

(defvar transient--original-buffer)

(defmacro ogent-ui-models--in-invocation-buffer (&rest body)
  "Evaluate BODY in the buffer the transient was invoked from."
  (declare (indent 0) (debug t))
  `(with-current-buffer
       (if (and (bound-and-true-p transient--original-buffer)
                (buffer-live-p transient--original-buffer))
           transient--original-buffer
         (current-buffer))
     ,@body))

(defun ogent-ui-models--wrap-chunks (label chunks width)
  "Return LABEL followed by CHUNKS as lines at most WIDTH wide.
Chunks never break mid-token: when the next chunk would overflow
WIDTH display columns, it starts a continuation line aligned under
the first chunk (indented by LABEL's display width)."
  (let* ((indent (make-string (string-width label) ?\s))
         (lines nil)
         (current label)
         (first t))
    (dolist (chunk chunks)
      (cond
       (first
        (setq current (concat current chunk)
              first nil))
       ((> (+ (string-width current) 3 (string-width chunk)) width)
        (push current lines)
        (setq current (concat indent chunk)))
       (t
        (setq current (concat current "   " chunk)))))
    (nreverse (cons current lines))))

(defun ogent-ui-models--roles-lines (width)
  "Return the header's role summary as lines at most WIDTH wide.
Roles never break mid-token; see `ogent-ui-models--wrap-chunks'."
  (ogent-ui-models--wrap-chunks
   (propertize "roles  " 'face 'transient-heading)
   (mapcar #'ogent-ui-models--format-role (ogent-models-known-roles))
   width))

(defun ogent-ui-models--evidence-lines (stats width)
  "Return the header's evidence for STATS as lines at most WIDTH wide.
STATS is the alist of `ogent-ui-models--evidence-stats'.  Each
chunk names a model and its evidence string; chunks wrap at token
boundaries like the roles summary."
  (ogent-ui-models--wrap-chunks
   (propertize "stats  " 'face 'transient-heading)
   (mapcar (lambda (entry)
             (concat
              (propertize (car entry) 'face 'ogent-theme-secondary)
              " "
              (propertize (ogent-ui-models--evidence-string (cdr entry))
                          'face 'ogent-theme-muted)))
           stats)
   width))

(defvar transient--window)

(defun ogent-ui-models--display-width ()
  "Return the usable width of the window hosting the picker.
Prefers the live transient window (which may be a half-frame
split under custom `transient-display-buffer-action' values) and
falls back to the frame width."
  (if (and (boundp 'transient--window)
           (window-live-p transient--window))
      (window-body-width transient--window)
    (frame-width)))

(defun ogent-ui-models--status-description ()
  "Format the picker header: effective model, source, roles, and evidence.
Evidence lines appear only when the project analytics DB has
recorded completions for registered models."
  (ogent-ui-models--in-invocation-buffer
    (let* ((effective (ogent-models-effective))
           (id (car effective))
           (model (ogent-models-get id))
           (desc (or (plist-get model :description) ""))
           (source (ogent-ui-models--source-label (cdr effective)))
           (width (max 40 (- (ogent-ui-models--display-width) 4)))
           (stats (ogent-ui-models--evidence-stats)))
      (concat
       (propertize id 'face 'ogent-theme-primary)
       "  "
       (propertize (ogent-ui-models--provider-name model)
                   'face 'ogent-theme-badge)
       (propertize (format "  via %s" source) 'face 'ogent-theme-muted)
       "\n "
       (propertize desc 'face 'ogent-theme-muted)
       "\n "
       (mapconcat #'identity (ogent-ui-models--roles-lines width) "\n ")
       "\n"
       (when stats
         (concat " "
                 (mapconcat #'identity
                            (ogent-ui-models--evidence-lines stats width)
                            "\n ")
                 "\n"))))))

(defun ogent-ui-models--org-buffer-p ()
  "Return non-nil when the picker was invoked from an Org buffer."
  (ogent-ui-models--in-invocation-buffer
    (derived-mode-p 'org-mode)))

;;;###autoload (autoload 'ogent-model-picker "ogent-ui-models" nil t)
(transient-define-prefix ogent-model-picker ()
  "Switch models, assign task roles, and pin models onto Org subtrees."
  [:description ogent-ui-models--status-description
                ["Switch"
                 ("m" "Model (session)" ogent-model-switch :transient t)
                 ("b" "Model (buffer)" ogent-model-switch-buffer :transient t)
                 ("d" "Set as default" ogent-model-set-default :transient t)]
                ["Org pin"
                 :if ogent-ui-models--org-buffer-p
                 ("h" "Pin on heading" ogent-model-pin-heading :transient t)
                 ("f" "Pin file-wide" ogent-model-pin-file :transient t)
                 ("u" "Unpin" ogent-model-unpin :transient t)]
                ["Roles"
                 ("r" "Assign role..." ogent-model-assign-role :transient t)
                 ("R" "Clear role..." ogent-model-clear-role :transient t)]]
  [["Registry"
    ("l" "Browse registry" ogent-models-browse)
    ("s" "Save configuration" ogent-model-save-config :transient t)]
   [""
    ("q" "Quit" transient-quit-one)]])

;;; Registry browser (Org table)

(defvar ogent-ui-models--browser-buffer-name "*ogent models*"
  "Buffer name for the model registry browser.")

(defvar-local ogent-ui-models--browser-origin nil
  "Marker into the buffer this browser was opened from, or nil.
Refreshes and row actions resolve the effective model at this
marker so the browser keeps describing the originating buffer -
including its `OGENT_MODEL' pins - rather than itself.")

(defvar-keymap ogent-models-browser-mode-map
  :doc "Keymap for `ogent-models-browser-mode'."
  "RET" #'ogent-models-browser-select
  "d" #'ogent-models-browser-set-default
  "g" #'ogent-models-browse
  "q" #'quit-window)

(define-derived-mode ogent-models-browser-mode org-mode "ogent-models"
  "Major mode for browsing the ogent model registry as Org tables.
\\<ogent-models-browser-mode-map>
Type \\[ogent-models-browser-select] on a model row to switch the
session model, \\[ogent-models-browser-set-default] to make it the
default, \\[ogent-models-browse] to refresh, and \\[quit-window] to
quit."
  (setq-local buffer-read-only t)
  (setq header-line-format
        (concat " "
                (propertize "RET" 'face 'ogent-theme-key) " switch  "
                (propertize "d" 'face 'ogent-theme-key) " default  "
                (propertize "g" 'face 'ogent-theme-key) " refresh  "
                (propertize "q" 'face 'ogent-theme-key) " quit")))

(defun ogent-ui-models--browser-model-at-point ()
  "Return the model id named on the browser table row at point."
  (when (org-at-table-p)
    (let ((field (string-trim (org-table-get-field 2))))
      (and (ogent-models-get field) field))))

(defun ogent-models-browser-select ()
  "Switch the session model to the one on the current row."
  (interactive)
  (let ((model-id (ogent-ui-models--browser-model-at-point)))
    (unless model-id
      (user-error "No model on this row"))
    (ogent-model-switch model-id)
    (ogent-models-browse)))

(defun ogent-models-browser-set-default ()
  "Make the model on the current row the default model."
  (interactive)
  (let ((model-id (ogent-ui-models--browser-model-at-point)))
    (unless model-id
      (user-error "No model on this row"))
    (ogent-model-set-default model-id)
    (ogent-models-browse)))

(defun ogent-ui-models--browser-insert (effective)
  "Insert the registry browser contents into the current buffer.
EFFECTIVE is the (MODEL-ID . SOURCE) cons resolved in the buffer
the browser was opened from.  When the project analytics DB has
recorded completions for registered models, the Models table
carries N, Median, Rating, and Cost evidence columns; without any
such rows the columns are absent entirely."
  (let ((effective-id (car effective)))
    (insert "#+title: ogent models\n\n")
    (insert (format "Effective model: =%s= (via %s)\n\n"
                    effective-id
                    (ogent-ui-models--source-label (cdr effective))))
    (insert "* Models\n\n")
    (let ((table-start (point))
          (stats (ogent-ui-models--evidence-stats)))
      (insert "|  | Model | Provider | Stream | Roles |"
              (if stats " N | Median | Rating | Cost |" "")
              " Description |\n")
      (insert "|-\n")
      (dolist (model (ogent-models-all))
        (let* ((id (plist-get model :id))
               (roles (ogent-ui-models--roles-resolving-to id))
               (cells
                (append
                 (list (if (equal id effective-id) ">" "")
                       id
                       (ogent-ui-models--provider-name model)
                       (if (plist-get model :stream?) "yes" "no")
                       (if roles
                           (mapconcat #'symbol-name roles ", ")
                         ""))
                 (when stats
                   (ogent-ui-models--evidence-cells (cdr (assoc id stats))))
                 (list (or (plist-get model :description) "")))))
          (insert "| " (mapconcat #'identity cells " | ") " |\n")))
      (goto-char table-start)
      (org-table-align)
      (goto-char (point-max)))
    (insert "\n* Roles\n\n")
    (let ((table-start (point)))
      (insert "| Role | Assigned | Resolves to |\n")
      (insert "|-\n")
      (dolist (role (ogent-models-known-roles))
        (let ((designator (ogent-models-role-designator role)))
          (insert (format "| %s | %s | %s |\n"
                          role
                          (cond
                           ((null designator) "(default)")
                           ((symbolp designator) (format "@%s" designator))
                           (t designator))
                          (ogent-models-resolve-role role)))))
      (goto-char table-start)
      (org-table-align)
      (goto-char (point-max)))
    (insert "\n* Pinning\n\n")
    (insert "- Subtree :: set the =OGENT_MODEL= property on a heading"
            " (inherited by children).\n")
    (insert "- File :: add =#+PROPERTY: OGENT_MODEL <model-or-@role>=.\n")
    (insert "- Project :: set =ogent-project-model= or"
            " =ogent-project-model-roles= in =.ogent.el=.\n")
    (insert "- Babel :: =#+begin_src ogent :model @deep= runs a block on"
            " a role.\n")))

;;;###autoload
(defun ogent-models-browse ()
  "Browse the model registry and role assignments as Org tables.
The effective model shown is resolved at the position the browser
was opened from; refreshing from inside the browser keeps that
origin."
  (interactive)
  (let* ((browser (get-buffer ogent-ui-models--browser-buffer-name))
         (origin
          (if (eq (current-buffer) browser)
              ;; Refresh from inside the browser: keep a live origin.
              (let ((prior ogent-ui-models--browser-origin))
                (and (markerp prior)
                     (buffer-live-p (marker-buffer prior))
                     prior))
            (point-marker)))
         (effective (if origin
                        (org-with-point-at origin (ogent-models-effective))
                      (ogent-models-effective)))
         (buffer (get-buffer-create ogent-ui-models--browser-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (unless (derived-mode-p 'ogent-models-browser-mode)
          (ogent-models-browser-mode))
        (setq ogent-ui-models--browser-origin origin)
        (ogent-ui-models--browser-insert effective)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(provide 'ogent-ui-models)
;;; ogent-ui-models.el ends here
