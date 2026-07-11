;;; ogent-ui-models.el --- Model picker and role assignment UI -*- lexical-binding: t; -*-

;;; Commentary:
;; An oh-my-pi style model picker for ogent: switch the active model in
;; one keystroke, assign different models to different task roles
;; (edit, codemap, deep, fast), pin models onto Org subtrees via the
;; inherited `OGENT_MODEL' property, and browse the registry as an Org
;; table.  The transient header always shows the effective model at
;; point and which layer decided it (Org property, session, project,
;; role, or default).

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'org)
(require 'org-table)
(require 'ogent-models)
(require 'ogent-gptel)
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

;;; Designator completion (annotated + grouped)

(defun ogent-ui-models--annotate (candidate pad)
  "Return the completion annotation for CANDIDATE, padded to width PAD."
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
             (markers
              (concat
               (when (equal candidate ogent-default-model)
                 (propertize "  ←default" 'face 'ogent-theme-success))
               (when roles
                 (propertize (format "  [%s]"
                                     (mapconcat #'symbol-name roles ","))
                             'face 'ogent-theme-highlight)))))
        (concat padding (propertize desc 'face 'ogent-theme-muted) markers)))))

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
annotated with its description, role back-references, and a
default marker.  When INCLUDE-ROLES is non-nil, \"@role\"
designators are offered too.  Returns the selected string."
  (let* ((ids (ogent-models-ids))
         (candidates (if include-roles
                         (append ids
                                 (mapcar (lambda (role)
                                           (format "@%s" role))
                                         (ogent-models-known-roles)))
                       ids))
         (pad (+ 2 (apply #'max (mapcar #'length candidates))))
         (table
          (lambda (string pred action)
            (if (eq action 'metadata)
                `(metadata
                  (category . ogent-model)
                  (annotation-function
                   . ,(lambda (cand) (ogent-ui-models--annotate cand pad)))
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
Resolves the backend, registers the model on it, and copies
request params and capabilities onto the model symbol.  With
BUFFER-LOCAL non-nil only the current buffer's gptel state
changes; otherwise the global default is updated."
  (let* ((model (ogent-models-ensure model-id))
         (backend (ogent-gptel-resolve-backend model))
         (backend (and (fboundp 'gptel-backend-p)
                       (gptel-backend-p backend)
                       backend))
         (symbol (if backend
                     (ogent-gptel-ensure-model-on-backend model backend)
                   (intern model-id))))
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
  "Switch the session model to MODEL-ID.
Updates the global gptel backend and model so every ogent request
without a more specific override (Org property, role, project)
uses MODEL-ID."
  (interactive (list (ogent-ui-models--read-id "Switch model (session): ")))
  (ogent-ui-models--apply model-id)
  (ogent-theme-flash 'success (format "Model: %s" model-id)))

;;;###autoload
(defun ogent-model-switch-buffer (model-id)
  "Switch this buffer's model to MODEL-ID.
Sets buffer-local gptel state; other buffers keep the session model."
  (interactive (list (ogent-ui-models--read-id "Switch model (buffer): ")))
  (ogent-ui-models--apply model-id 'buffer-local)
  (ogent-theme-flash 'success (format "Buffer model: %s" model-id)))

;;;###autoload
(defun ogent-model-set-default (model-id)
  "Set MODEL-ID as `ogent-default-model' and the session model."
  (interactive (list (ogent-ui-models--read-id "Default model: ")))
  (setq ogent-default-model model-id)
  (ogent-ui-models--apply model-id)
  (ogent-theme-flash 'success (format "Default model: %s" model-id)))

;;; Org pinning

(defun ogent-ui-models--pin-file-keyword (designator)
  "Insert or update a file-level OGENT_MODEL property with DESIGNATOR."
  (org-with-wide-buffer
   (goto-char (point-min))
   (if (re-search-forward
        (format "^#\\+\\(?:PROPERTY\\|property\\):[ \t]+%s\\(?:[ \t].*\\)?$"
                (regexp-quote ogent-models-org-property))
        nil t)
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
Deletes the `OGENT_MODEL' property from the current heading, or
removes the file-level keyword when point is before the first
heading."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Model pinning requires an Org buffer"))
  (cond
   ((and (not (org-before-first-heading-p))
         (org-entry-get (point) ogent-models-org-property nil))
    (org-entry-delete (point) ogent-models-org-property)
    (ogent-theme-flash 'info "Removed subtree model pin"))
   (t
    (org-with-wide-buffer
     (goto-char (point-min))
     (if (re-search-forward
          (format "^#\\+\\(?:PROPERTY\\|property\\):[ \t]+%s\\(?:[ \t].*\\)?\n?"
                  (regexp-quote ogent-models-org-property))
          nil t)
         (progn
           (replace-match "" t t)
           (org-set-regexps-and-options)
           (ogent-theme-flash 'info "Removed file model pin"))
       (message "ogent: no model pin at point"))))))

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

(defun ogent-ui-models--status-description ()
  "Format the picker header: effective model, source, and roles."
  (ogent-ui-models--in-invocation-buffer
    (let* ((effective (ogent-models-effective))
           (id (car effective))
           (model (ogent-models-get id))
           (desc (or (plist-get model :description) ""))
           (source (ogent-ui-models--source-label (cdr effective))))
      (concat
       (propertize id 'face 'ogent-theme-primary)
       "  "
       (propertize (ogent-ui-models--provider-name model)
                   'face 'ogent-theme-badge)
       (propertize (format "  via %s" source) 'face 'ogent-theme-muted)
       "\n "
       (propertize desc 'face 'ogent-theme-muted)
       "\n "
       (propertize "roles  " 'face 'transient-heading)
       (mapconcat #'ogent-ui-models--format-role
                  (ogent-models-known-roles)
                  "   ")
       "\n"))))

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
the browser was opened from."
  (let ((effective-id (car effective)))
    (insert "#+title: ogent models\n\n")
    (insert (format "Effective model: =%s= (via %s)\n\n"
                    effective-id
                    (ogent-ui-models--source-label (cdr effective))))
    (insert "* Models\n\n")
    (let ((table-start (point)))
      (insert "|  | Model | Provider | Stream | Roles | Description |\n")
      (insert "|-\n")
      (dolist (model (ogent-models-all))
        (let* ((id (plist-get model :id))
               (roles (ogent-ui-models--roles-resolving-to id)))
          (insert (format "| %s | %s | %s | %s | %s | %s |\n"
                          (if (equal id effective-id) ">" "")
                          id
                          (ogent-ui-models--provider-name model)
                          (if (plist-get model :stream?) "yes" "no")
                          (if roles
                              (mapconcat #'symbol-name roles ", ")
                            "")
                          (or (plist-get model :description) "")))))
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
  "Browse the model registry and role assignments as Org tables."
  (interactive)
  ;; Resolve the effective model in the buffer the user came from.
  (let ((effective (ogent-models-effective))
        (buffer (get-buffer-create ogent-ui-models--browser-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (unless (derived-mode-p 'ogent-models-browser-mode)
          (ogent-models-browser-mode))
        (ogent-ui-models--browser-insert effective)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(provide 'ogent-ui-models)
;;; ogent-ui-models.el ends here
