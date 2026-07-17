;;; ogent-ui-send.el --- Request build and gptel dispatch -*- lexical-binding: t; -*-

;;; Commentary:
;; Builds the effective prompt and companion context, applies prompt
;; templates and preset cookies, resolves the gptel backend, and
;; dispatches a request into the conversation engine.  Hosts the
;; `ogent-request' command.

;;; Code:

(require 'ogent-ui-core)
(require 'ogent-ui-engine)
(require 'ogent-context)
(require 'ogent-models)
(require 'ogent-gptel)
(require 'ogent-companion)
(require 'ogent-prompts)
(require 'org-id)

;; gptel dynamic variables let-bound while dispatching a request.
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-cache)
(defvar gptel-stream)
(defvar gptel-tools)
(defvar gptel-use-tools)

;; gptel integration (soft dependency).
(declare-function gptel-request "ext:gptel-request")
(declare-function gptel-backend-p "ext:gptel-request" t t)
(declare-function gptel--model-name "ext:gptel-request")
(declare-function gptel-with-preset "ext:gptel" t t)
(declare-function ogent-gptel-ensure-model-on-backend "ogent-gptel" (model backend))
(declare-function ogent-anthropic-oauth-using-bearer-p "ogent-anthropic-oauth")
(declare-function ogent-tools-enabled-list "ogent-models")
(declare-function ogent-presets-available "ogent-models")
(declare-function ogent-prompt-compose-with-params "ogent-prompts")

(defun ogent--get-effective-prompt ()
  "Get the prompt to send: transient input, region, or minibuffer."
  (or ogent--transient-prompt
      (when (use-region-p)
        (buffer-substring-no-properties (region-beginning) (region-end)))
      (read-string "Prompt: ")))

(defun ogent-ui--apply-prompt-templates (prompt &optional templates)
  "Apply TEMPLATES to PROMPT, returning the combined string."
  (let ((templates (or templates ogent-ui--selected-templates)))
    (if (and templates (fboundp 'ogent-prompt-compose-with-params))
        (let ((template-text (ogent-prompt-compose-with-params templates)))
          (if (string-empty-p template-text)
              prompt
            (string-join (list template-text prompt) "\n\n")))
      prompt)))

(defun ogent-ui--model-id-or-default (&optional model-id)
  "Return registered MODEL-ID, or the effective model id at point.
Resolution follows `ogent-models-effective': an inherited
`OGENT_MODEL' Org property, then the buffer's registered gptel
model, then the project model, then `ogent-default-model'.  This
keeps buffer-local gptel state from breaking ogent when a buffer
remembers a model that is not in `ogent-model-registry'."
  (or (and model-id (ogent-models-canonical-id model-id))
      (ogent-models-effective-id)))

(defun ogent-ui--announce-token-budget (final-prompt context model-ids)
  "Echo the estimated prompt token budget before dispatching.
FINAL-PROMPT and CONTEXT render into the payload every member of
MODEL-IDS receives.  With several members (a fan-out) the estimate
carries the member-count multiplication, since each member is sent
an identical payload.  The warn threshold comes from the members'
:context-window registry entries; the smallest declared window
drives the warning and members without one never warn (see
`ogent-ui-token-budget-line').  Unknown ids are skipped rather than
signaled: dispatch itself reports those."
  (let* ((payload (ogent-ui--render-prompt final-prompt context))
         (models (delq nil (mapcar #'ogent-models-get model-ids)))
         (model (or (ogent-ui-token-budget-model models) (car models)))
         (members (length model-ids)))
    (message "Ogent: %s"
             (ogent-ui-token-budget-line payload model
                                         (and (> members 1) members)))))

(defun ogent--send-with-current-model (prompt)
  "Send PROMPT using current gptel-backend and gptel-model.
Captures source buffer context and sends to companion without switching focus.
When `ogent-ui--selected-models' is non-nil, dispatches to all selected models
concurrently (fan-out mode)."
  (let* ((source-buffer (current-buffer))
         (region-start (when (use-region-p) (region-beginning)))
         (region-end (when (use-region-p) (region-end)))
         (companion (ogent-ui--ensure-companion-context))
         (extracted (ogent-ui--extract-preset-cookies prompt))
         (clean-prompt (car extracted))
         (cookie-presets (cdr extracted))
         (effective-preset (or (car cookie-presets) ogent-ui--selected-preset))
         (final-prompt (ogent-ui--apply-prompt-templates clean-prompt)))
    (with-current-buffer companion
      (let ((context (ogent-context-build-with-source
                      source-buffer region-start region-end)))
        (if (ogent-validate-and-prompt context)
            (progn
              (ogent-ui--announce-token-budget
               final-prompt context
               (or ogent-ui--selected-models
                   (list (ogent-ui--model-id-or-default))))
              (if ogent-ui--selected-models
                  ;; Multi-model fan-out: dispatch to all selected models
                  (dolist (model-id ogent-ui--selected-models)
                    (let* ((model (ogent-models-ensure model-id))
                           (request (funcall ogent-response-function final-prompt context model)))
                      (unless (ogent-ui-request-p request)
                        (user-error "Function `ogent-response-function' must return an `ogent-ui-request'"))
                      (setf (ogent-ui-request-preset request) effective-preset)
                      (setf (ogent-ui-request-source-buffer request) source-buffer)
                      (ogent-ui--send-request request)))
                ;; Single model: resolve the effective model at point
                ;; (Org property > session > project > default).
                (let* ((model (ogent-models-ensure (ogent-ui--model-id-or-default)))
                       (request (funcall ogent-response-function final-prompt context model)))
                  (unless (ogent-ui-request-p request)
                    (user-error "Function `ogent-response-function' must return an `ogent-ui-request'"))
                  (setf (ogent-ui-request-preset request) effective-preset)
                  (setf (ogent-ui-request-source-buffer request) source-buffer)
                  (ogent-ui--send-request request))))
          (message "Ogent request canceled"))))))

(defun ogent-ui--ensure-companion-context ()
  "Ensure we're in an Org buffer, creating a companion if needed.
When invoked from a non-Org buffer, get or create the companion Org
buffer and display it as a popup/side window.  Returns the companion
\(or current) Org buffer.
The original window remains selected - companion is shown but not focused."
  (if (derived-mode-p 'org-mode)
      (current-buffer)
    (let ((original-window (selected-window))
          (companion (ogent-companion-get-or-create)))
      ;; Display the companion buffer as a popup or side window
      (unless (get-buffer-window companion)
        (ogent-companion-display-buffer companion))
      ;; Ensure we stay in the original window
      (when (window-live-p original-window)
        (select-window original-window))
      companion)))

(defun ogent-ui--read-prompt ()
  "Derive the prompt from the region or minibuffer."
  (if (use-region-p)
      (string-trim (buffer-substring-no-properties (region-beginning)
                                                   (region-end)))
    (read-string "Prompt: ")))

(defun ogent-ui--ensure-gptel ()
  "Signal a user error if gptel is unavailable."
  (unless (require 'gptel nil 'noerror)
    (user-error "Gptel is required for ogent requests.  Install gptel first"))
  (dolist (feature ogent-gptel-required-features)
    (unless (require feature nil 'noerror)
      (display-warning
       'ogent
       (format
        (concat "Could not load `%s'. Add the backend feature to your load path "
                "or update `ogent-gptel-required-features'.")
        feature)
       :warning)))
  t)

(defun ogent-ui--backend-matches-provider-p (backend-object provider)
  "Return non-nil when BACKEND-OBJECT has PROVIDER type."
  (ogent-gptel-backend-matches-provider-p backend-object provider))

(defun ogent-ui--resolve-backend (model)
  "Return the backend object for MODEL plist."
  (ogent-gptel-resolve-backend model))

(defun ogent-ui--extract-preset-cookies (prompt)
  "Extract @preset tokens from PROMPT.
Returns a cons (CLEANED-PROMPT . PRESETS) where PRESETS is a list of
preset name strings found in the prompt."
  (let ((presets nil)
        (available (ogent-presets-available))
        (cleaned prompt))
    (when available
      (dolist (name available)
        (let ((pattern (concat "\\s-*@" (regexp-quote name) "\\b\\s-*")))
          (when (string-match (concat "@" (regexp-quote name) "\\b") cleaned)
            (push name presets)
            (setq cleaned (replace-regexp-in-string pattern " " cleaned))))))
    (cons (string-trim cleaned) (nreverse presets))))

(defun ogent-ui--send-request (request)
  "Send REQUEST to the LLM via gptel.
When target buffer is Org-mode, includes org-format directive.
When model has :tools, enables gptel tool calling.
When `ogent-multi-turn-history' is non-nil, prior completed exchanges
found in the transcript buffer are replayed as leading conversation
turns, compacted to `ogent-multi-turn-token-budget'."
  (ogent-ui--ensure-gptel)
  (let* ((model (ogent-ui-request-model request))
         (prompt-text (ogent-ui--render-prompt (ogent-ui-request-prompt request)
                                               (ogent-ui-request-context request)))
         (callback (ogent-ui--make-callback (ogent-ui-request-id request)))
         (backend (ogent-ui--resolve-backend model))
         (model-id (plist-get model :id))
         (preset (or (ogent-ui-request-preset request)
                     (plist-get model :preset)))
         (target-buffer (ogent-ui-request-buffer request))
         (use-org-format (with-current-buffer target-buffer
                           (derived-mode-p 'org-mode)))
         ;; Check if OAuth is active (system message is locked)
         (oauth-active (and (fboundp 'ogent-anthropic-oauth-using-bearer-p)
                            (ogent-anthropic-oauth-using-bearer-p)))
         ;; Get enabled tools based on ogent-tools-enabled
         (tools (when (fboundp 'ogent-tools-enabled-list)
                  (ogent-tools-enabled-list)))
         ;; Prior exchanges replayed as conversation turns (oldest first)
         (history (when ogent-multi-turn-history
                    (ogent-ui--compact-history
                     (ogent-ui--conversation-history
                      target-buffer
                      (or (ogent-ui-request-request-heading-pos request)
                          (ogent-ui-request-block-start request)
                          (ogent-ui-request-marker request))
                      model-id)
                     ogent-multi-turn-token-budget)))
         (args (list :buffer target-buffer
                     :stream (plist-get model :stream?)
                     :callback callback)))
    ;; Add org-format directive when target is org-mode and enabled
    (when (and ogent-org-format-responses use-org-format)
      (if oauth-active
          ;; OAuth locks the system message, so prepend directive to user prompt
          (setq prompt-text (concat ogent-org-format-directive "\n\n" prompt-text))
        ;; Normal mode: use system message
        (setq args (plist-put args :system ogent-org-format-directive))))
    (condition-case err
        (progn
          (when (and (fboundp 'gptel-backend-p)
                     (not (gptel-backend-p backend)))
            (user-error
             "Backend %S for model %s is not loaded.  Require the backend module or update `ogent-model-registry'"
             (plist-get model :backend) model-id))
          ;; Surface the ogent registry to gptel before `gptel--sanitize-model'
          ;; can silently rewrite a newer model id to the backend fallback.
          (ogent-gptel-ensure-model-on-backend model backend)
          (ogent-models-apply-gptel-props model)
          (let* ((sender (lambda ()
                           (apply #'gptel-request
                                  (if history
                                      (append history (list prompt-text))
                                    prompt-text)
                                  args)))
                 (gptel-backend backend)
                 (gptel-model model-id)
                 (gptel-cache ogent-gptel-cache)
                 ;; Bind all registered tools
                 (gptel-tools (or tools gptel-tools))
                 (gptel-use-tools (when tools t))
                 (handle (if preset
                             (if (fboundp 'gptel-with-preset)
                                 (gptel-with-preset
                                  (if (stringp preset) (intern preset) preset)
                                  (funcall sender))
                               (funcall sender))
                           (funcall sender))))
            (setf (ogent-ui-request-gptel-handle request) handle)))
      (error
       (ogent-ui--close-response request (error-message-string err))))))

(defun ogent-ui--dispatch-request
    (source-buffer region-start region-end raw-prompt models preset templates
                   &optional org-point context-transform)
  "Dispatch RAW-PROMPT using MODELS from SOURCE-BUFFER.
REGION-START and REGION-END bound the active region in SOURCE-BUFFER.
PRESET and TEMPLATES shape the request, ORG-POINT anchors the transcript
heading, and CONTEXT-TRANSFORM, when non-nil, post-processes the context."
  (let* ((companion (ogent-ui--ensure-companion-context))
         (extracted (ogent-ui--extract-preset-cookies raw-prompt))
         (clean-prompt (car extracted))
         (cookie-presets (cdr extracted))
         (effective-preset (or preset
                               (car cookie-presets)
                               ogent-ui--selected-preset))
         (final-prompt (ogent-ui--apply-prompt-templates
                        clean-prompt
                        (or templates ogent-ui--selected-templates))))
    (with-current-buffer companion
      ;; Anchor the transcript at the requested heading: Zen runs may be
      ;; invoked with point deep inside a generated transcript, and the
      ;; response skeleton must attach to the user bullet, not to point.
      (when (and org-point (eq companion source-buffer))
        (goto-char org-point))
      (let* ((context (ogent-context-build-with-source
                       source-buffer region-start region-end org-point))
             (context (if context-transform
                          (funcall context-transform context)
                        context))
             ;; Use provided models or fall back to a registered/default ogent model.
             (model-ids (or models
                            (list (ogent-ui--model-id-or-default))))
             fanout-block
             last-request)
        (if (ogent-validate-and-prompt context)
            (progn
              (ogent-ui--announce-token-budget final-prompt context model-ids)
              (dolist (model-id model-ids)
                (let* ((model (ogent-models-ensure model-id))
                       ;; Fan-out members after the first reuse the
                       ;; group's Request block, adding only their own
                       ;; Response sibling headline.
                       (request (if fanout-block
                                    (ogent-ui-prepare-response-block
                                     final-prompt context model fanout-block)
                                  (funcall ogent-response-function
                                           final-prompt context model))))
                  (unless (ogent-ui-request-p request)
                    (user-error "Function `ogent-response-function' must return an `ogent-ui-request'"))
                  (when (and (plist-get context :fanout-group)
                             (null fanout-block))
                    (setq fanout-block (ogent-ui--request-block request)))
                  (setf (ogent-ui-request-preset request) effective-preset)
                  (setf (ogent-ui-request-source-buffer request) source-buffer)
                  (ogent-ui--send-request request)
                  (setq last-request request)))
              ;; Position cursor at response heading in companion window.
              (when-let* ((response-pos (and last-request
                                             (ogent-ui-request-response-pos
                                              last-request)))
                          (win (get-buffer-window companion)))
                (with-selected-window win
                  (goto-char response-pos))))
          (message "Ogent request canceled"))))))

(defun ogent-request (&optional prompt models preset templates)
  "Dispatch PROMPT for the current subtree using MODELS via gptel.
When PROMPT or MODELS are nil, prompt the user and fall back to the
selected models from the dispatcher.
PRESET overrides any dispatcher or model preset.  If PROMPT contains
@preset cookies, they are extracted and applied (first cookie wins).
TEMPLATES is an optional list of prompt template IDs to apply.

When invoked from a non-Org buffer, automatically creates and displays
a companion Org buffer to hold the request/response transcript.
The source buffer content is captured for context."
  (interactive)
  (let ((source-buffer (current-buffer))
        (region-start (when (use-region-p) (region-beginning)))
        (region-end (when (use-region-p) (region-end)))
        (raw-prompt (or prompt (ogent-ui--read-prompt))))
    (ogent-ui--dispatch-request source-buffer region-start region-end
                                raw-prompt models preset templates)))

(defcustom ogent-fanout-default-models nil
  "Model ids `ogent-fanout' dispatches to when no set is given.
A list of `ogent-model-registry' id strings (aliases are resolved).
nil falls back to the dispatcher's live fan-out selection and finally
to the distinct models the role picker resolves (see
`ogent-fanout--model-set')."
  :type '(repeat (string :tag "Model id"))
  :group 'ogent-mode)

(defun ogent-fanout--role-model-set ()
  "Return the distinct model ids the role picker resolves.
One id per known role, duplicates removed.  Returns nil instead of
signaling when `ogent-model-registry' is empty, so callers can report
the empty set with fan-out specific guidance."
  (when ogent-model-registry
    (delete-dups
     (delq nil
           (mapcar #'ogent-models-resolve-role
                   (ogent-models-known-roles))))))

(defun ogent-fanout--model-set (&optional models)
  "Return the fan-out member model ids as a list.
MODELS, when non-nil, wins.  Otherwise fall back through the
dispatcher's live selection (`ogent-ui--selected-models'), then
`ogent-fanout-default-models', and finally the distinct models that
the role picker resolves via `ogent-models-resolve-role'."
  (or models
      ogent-ui--selected-models
      ogent-fanout-default-models
      (ogent-fanout--role-model-set)))

(defun ogent-fanout--canonicalize-models (models)
  "Return MODELS as canonical `ogent-model-registry' ids.
Every member is resolved through `ogent-models-resolve-designator',
so aliases and @role designators canonicalize to registry ids.
Signal a `user-error' for members naming no registered model, and for
duplicate members (two designators resolving to the same model)."
  (let (canonical)
    (dolist (model models)
      (let ((id (ogent-models-resolve-designator model)))
        (unless id
          (user-error "Unknown fan-out model: %s" model))
        (when (member id canonical)
          (user-error
           "Duplicate fan-out model: %s (each member must be a distinct model)"
           id))
        (push id canonical)))
    (nreverse canonical)))

(defun ogent-fanout--resolve-model-set (&optional models)
  "Return the canonical fan-out member set, validating it.
Resolve the raw set via `ogent-fanout--model-set' (MODELS wins over
the dispatcher selection, `ogent-fanout-default-models', and the role
fallback), then canonicalize it via
`ogent-fanout--canonicalize-models'.  Signal a `user-error' naming
the three selection sources when the set comes up empty."
  (let ((raw (ogent-fanout--model-set models)))
    (unless raw
      (user-error
       (concat "No fan-out models: invoke `ogent-fanout' with C-u to pick a"
               " set, customize `ogent-fanout-default-models', or assign"
               " models to roles in `ogent-model-roles'")))
    (ogent-fanout--canonicalize-models raw)))

(defun ogent-fanout--read-models ()
  "Read a fan-out model set with completion over registry ids.
Uses `completing-read-multiple' over `ogent-model-registry' ids;
aliases and @role designators typed freely are accepted and later
canonicalized by `ogent-fanout--canonicalize-models'.  Returns nil
for empty input so the caller falls back to the configured sources."
  (completing-read-multiple "Fan-out models: " (ogent-models-ids)))

(defun ogent-fanout--group-id ()
  "Return a fresh fan-out group id."
  (org-id-uuid))

;;;###autoload
(defun ogent-fanout (&optional prompt models preset templates)
  "Send PROMPT to several MODELS at once, side by side.
Build the prompt and companion context exactly once, then issue one
request per member of MODELS through the normal send path.  Every
member's context plist carries the same :fanout-group id, the
transcript gets a single Request block, and each member streams under
its own Response sibling headline beneath that block.  Member
failures never retry or fail over to another provider (that could
duplicate a model already in the group); the failed member simply
closes with its error.

When PROMPT is nil, read it from the region or minibuffer.
Interactively, a prefix argument (\\[universal-argument]) prompts for
the member set with completion over the registry; otherwise, and when
MODELS is nil, the set falls back through
`ogent-fanout-default-models' and the role picker's distinct models
(see `ogent-fanout--resolve-model-set').  Aliases canonicalize;
duplicate and empty sets are refused.  PRESET and TEMPLATES are
forwarded to the send path as in `ogent-request'.

Whatever the dispatch outcome -- validation canceled, the user quit,
or a member signaled mid-loop -- the group is settled via
`ogent-ui-fanout-settle-group', so undispatched members close as
failed and a group that never dispatched leaves no state behind and
never runs `ogent-fanout-group-done-hook'.  Return the fan-out
group id."
  (interactive
   (list nil (when current-prefix-arg (ogent-fanout--read-models))))
  (let ((source-buffer (current-buffer))
        (region-start (when (use-region-p) (region-beginning)))
        (region-end (when (use-region-p) (region-end)))
        (raw-prompt (or prompt (ogent-ui--read-prompt)))
        (member-ids (ogent-fanout--resolve-model-set models))
        (group (ogent-fanout--group-id)))
    (ogent-ui-fanout-begin-group group member-ids)
    (unwind-protect
        (ogent-ui--dispatch-request
         source-buffer region-start region-end raw-prompt member-ids
         preset templates nil
         (lambda (context)
           (plist-put (copy-sequence context) :fanout-group group)))
      ;; Any non-dispatch outcome (validation nil, quit, mid-loop
      ;; signal) must not leak group state: settle the stragglers.
      (ogent-ui-fanout-settle-group group))
    group))

(defun ogent-fanout--group-at-point ()
  "Return the fan-out group id at point, or nil.
Prefer the inherited OGENT_FANOUT_GROUP property of the Org entry at
point.  When point is not inside a fan-out subtree, fall back to the
only live fan-out group in the current buffer, when exactly one
exists."
  (or (and (derived-mode-p 'org-mode)
           (ignore-errors (org-entry-get nil "OGENT_FANOUT_GROUP" t)))
      (let (groups)
        (dolist (request (ogent-ui-active-requests))
          (when-let ((group (and (eq (ogent-ui-request-buffer request)
                                     (current-buffer))
                                 (plist-get (ogent-ui-request-context request)
                                            :fanout-group))))
            (unless (member group groups)
              (push group groups))))
        (and groups (null (cdr groups)) (car groups)))))

;;;###autoload
(defun ogent-fanout-abort (&optional group)
  "Abort every in-flight member of the fan-out GROUP at point.
GROUP defaults to the group at point (see
`ogent-fanout--group-at-point').  Members that already finished keep
their responses -- partial completion is a feature -- while each
in-flight member goes through the normal abort path, so its watchdog
is cancelled and its Response section is marked aborted.  Return the
number of members aborted."
  (interactive)
  (let ((group (or group (ogent-fanout--group-at-point))))
    (unless group
      (user-error "No fan-out group at point"))
    (let ((members (seq-filter
                    (lambda (request)
                      (equal (plist-get (ogent-ui-request-context request)
                                        :fanout-group)
                             group))
                    (ogent-ui-active-requests))))
      (dolist (request members)
        (ogent-ui--abort-request request))
      (message "Aborted %d fan-out member%s"
               (length members)
               (if (= 1 (length members)) "" "s"))
      (length members))))

;;; Compare mode: pairwise diff and keep-this-one (bead ogent-pje.4)

;; Analytics rating pipeline (soft dependency, fboundp-guarded).
(declare-function ogent-analytics-rate-completion "ogent-analytics")

(defun ogent-fanout--group-heading-marker (group)
  "Return a marker on GROUP's Request heading, or nil.
The heading is the Org entry whose property drawer records GROUP as
its OGENT_FANOUT_GROUP."
  (org-with-wide-buffer
   (goto-char (point-min))
   (when (search-forward (format ":OGENT_FANOUT_GROUP: %s" group) nil t)
     (org-back-to-heading t)
     (copy-marker (point)))))

(defun ogent-fanout--members (group)
  "Return GROUP's member responses as (MODEL-ID MARKER . BODY) entries.
Scans GROUP's Request subtree for the per-member \"Response (MODEL)\"
headlines, in dispatch order.  MARKER sits on the member's headline
and survives sibling edits; BODY is the member's rendered plain-text
response: the trimmed text between the headline's meta data and the
next heading.  Return nil when GROUP has no subtree in the current
buffer."
  (when-let ((start (ogent-fanout--group-heading-marker group)))
    (org-with-wide-buffer
     (goto-char start)
     (let ((bound (save-excursion (org-end-of-subtree t t) (point)))
           (members nil))
       (while (re-search-forward "^\\*+ Response (\\([^)]+\\))" bound t)
         (let* ((model (match-string-no-properties 1))
                (headline (copy-marker (line-beginning-position)))
                (body-start (save-excursion
                              (org-end-of-meta-data t)
                              (point)))
                (body-end (save-excursion
                            (if (re-search-forward org-outline-regexp-bol
                                                   bound t)
                                (match-beginning 0)
                              bound))))
           (push (cons model
                       (cons headline
                             (string-trim (buffer-substring-no-properties
                                           body-start body-end))))
                 members)))
       (nreverse members)))))

(defun ogent-fanout--compare-buffer (model members)
  "Return a fresh plain-text buffer holding MODEL's body from MEMBERS.
MEMBERS is the `ogent-fanout--members' list.  Signal a `user-error'
when MODEL has no response in MEMBERS."
  (let ((entry (assoc model members)))
    (unless entry
      (user-error "No fan-out response for model %s" model))
    (let ((buffer (generate-new-buffer
                   (format "*ogent fanout diff: %s*" model))))
      (with-current-buffer buffer
        (insert (cddr entry))
        (text-mode))
      buffer)))

;;;###autoload
(defun ogent-fanout-compare (&optional group model-a model-b)
  "Pairwise ediff two member responses of the fan-out GROUP at point.
GROUP defaults to the group at point (see
`ogent-fanout--group-at-point').  A two-member group implies the
pair; a larger group reads MODEL-A and MODEL-B with completion over
the member model ids.  Refuse a group that still has members in
flight: a partial body would diff as a regression that is not one.
Each rendered body is copied verbatim into a fresh plain-text buffer
and the pair goes to `ediff-buffers'; the transcript itself is never
touched, so comparing stays read-only.  The variant buffers are
ephemeral: quitting the ediff session reaps exactly them (via a
buffer-local `ediff-after-quit-hook-internal' on the control buffer),
and a failing ediff setup reaps them immediately, so repeated
comparisons never accumulate buffers."
  (interactive)
  (let ((group (or group (ogent-fanout--group-at-point))))
    (unless group
      (user-error "No fan-out group at point"))
    (when (seq-some (lambda (request)
                      (equal (plist-get (ogent-ui-request-context request)
                                        :fanout-group)
                             group))
                    (ogent-ui-active-requests))
      (user-error "Fan-out group still has members in flight"))
    (let ((members (ogent-fanout--members group)))
      (when (< (length members) 2)
        (user-error "Fan-out group needs two responses to compare"))
      (let* ((ids (mapcar #'car members))
             (a (or model-a
                    (if (null (cddr members))
                        (car ids)
                      (completing-read "Compare model: " ids nil t))))
             (b (or model-b
                    (if (null (cddr members))
                        (cadr ids)
                      (completing-read (format "Compare %s with: " a)
                                       (remove a ids) nil t)))))
        (ogent-fanout--compare-ediff
         (ogent-fanout--compare-buffer a members)
         (ogent-fanout--compare-buffer b members))))))

(defun ogent-fanout--compare-cleanup (buffers)
  "Return a closure that kills whichever of BUFFERS are still live."
  (lambda ()
    (dolist (buffer buffers)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ogent-fanout--compare-ediff (buffer-a buffer-b)
  "Hand variant BUFFER-A and BUFFER-B to `ediff-buffers' with cleanup.
A startup hook runs in the ediff control buffer and registers a
buffer-local `ediff-after-quit-hook-internal' there that kills
exactly the two generated variants when the session quits.  When
ediff setup signals instead, kill them here and re-signal, so a
failed session cannot leak either buffer."
  (let ((cleanup (ogent-fanout--compare-cleanup
                  (list buffer-a buffer-b))))
    (condition-case err
        (ediff-buffers
         buffer-a buffer-b
         (list (lambda ()
                 (add-hook 'ediff-after-quit-hook-internal cleanup
                           nil t))))
      (error
       (funcall cleanup)
       (signal (car err) (cdr err))))))

(defun ogent-fanout--member-at-point ()
  "Return the model id of the fan-out member Response headline at point.
Point may sit anywhere inside the member's subtree.  Return nil when
no enclosing headline is a member Response headline."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (when (ignore-errors (org-back-to-heading t) t)
        (catch 'model
          (while t
            (let ((heading (buffer-substring-no-properties
                            (line-beginning-position)
                            (line-end-position))))
              (if (string-match "^\\*+ Response (\\([^)]+\\))" heading)
                  (throw 'model (match-string 1 heading))
                (unless (org-up-heading-safe)
                  (throw 'model nil))))))))))

(defun ogent-fanout--archived-p (pom)
  "Return non-nil when the heading at POM carries the ARCHIVE tag."
  (org-with-point-at pom
    (member org-archive-tag (org-get-tags nil t))))

(defun ogent-fanout--set-archived (pom archived)
  "Give the heading at POM the org ARCHIVE tag iff ARCHIVED is non-nil.
Toggles via `org-toggle-archive-tag' only when the current state
differs, so the operation is idempotent and fully reversible."
  (org-with-point-at pom
    (when (xor archived (ogent-fanout--archived-p (point)))
      (org-toggle-archive-tag))))

;;;###autoload
(defun ogent-fanout-keep (&optional model)
  "Keep the fan-out member response at point; archive-tag its siblings.
MODEL overrides the member Response headline at point.  Every losing
sibling headline gets the org ARCHIVE tag via
`org-toggle-archive-tag' -- org-native and reversible: the subtree
folds by default and no text moves anywhere -- while the winner's tag
is removed, so re-running the command on another member swaps the
marking.  The winner itself gets no marking.  When the analytics
rating pipeline is loaded (`ogent-analytics-rate-completion') and the
winner's headline carries an OGENT_COMPLETION_ID property, the
winner's completion row is rated 5; losers stay unrated -- an
unpicked response is not evidence of badness.  Return the winner's
model id."
  (interactive)
  (let ((model (or model (ogent-fanout--member-at-point)))
        (group (ogent-fanout--group-at-point)))
    (unless (and model group)
      (user-error "Point is not on a fan-out member response"))
    (let ((members (ogent-fanout--members group)))
      (unless (assoc model members)
        (user-error "No fan-out response for model %s" model))
      (let ((losers 0)
            (winner nil))
        (dolist (entry members)
          (if (equal (car entry) model)
              (progn
                (setq winner (cadr entry))
                (ogent-fanout--set-archived (cadr entry) nil))
            (ogent-fanout--set-archived (cadr entry) t)
            (setq losers (1+ losers))))
        (when (fboundp 'ogent-analytics-rate-completion)
          (when-let* ((prop (org-entry-get winner "OGENT_COMPLETION_ID"))
                      (id (string-to-number prop)))
            (when (> id 0)
              (ogent-analytics-rate-completion id 5))))
        (message "Kept %s; archived %d sibling%s"
                 model losers (if (= losers 1) "" "s"))
        model))))

(provide 'ogent-ui-send)
;;; ogent-ui-send.el ends here
