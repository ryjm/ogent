;;; ogent-edit.el --- Inline code editing for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Main module for inline code editing.  Coordinates parsing, display,
;; and logging of LLM-proposed code changes.
;; See specs/inline-edits.org for full specification.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'ogent-edit-format)
(require 'ogent-edit-parse)
(require 'ogent-edit-display)
(require 'ogent-edit-log)
(require 'ogent-companion)
(require 'ogent-edit-diff)
(require 'ogent-gptel)
(require 'ogent-models)
(require 'ogent-provider-fallback)

(eval-when-compile
  (require 'flymake))

;; gptel integration
(declare-function gptel-request "ext:gptel-request")
(declare-function gptel-backend-name "ext:gptel-request" t t)
(declare-function gptel--model-name "ext:gptel-request")
(declare-function gptel--parse-schema "ext:gptel-request")
(defvar gptel-backend)
(defvar gptel-model)

;; Diagnostic integrations.  The flycheck-error-* accessors are
;; cl-defstruct-generated, which check-declare cannot resolve, hence
;; the FILEONLY flags.  The flymake declarations silence Emacs 30.2's
;; stricter "might not be defined at runtime" check; flymake itself is
;; only loaded on demand (see `ogent-edit--flymake-diagnostics-at-point').
(declare-function flymake-diagnostic-beg "flymake" (diag) t)
(declare-function flymake-diagnostic-end "flymake" (diag) t)
(declare-function flymake-diagnostic-text "flymake" (diag) t)
(declare-function flymake-diagnostic-type "flymake" (diag) t)
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flycheck-overlay-errors-at "ext:flycheck" (pos))
(declare-function flycheck-error-filename "ext:flycheck" (err) t)
(declare-function flycheck-error-line "ext:flycheck" (err) t)
(declare-function flycheck-error-column "ext:flycheck" (err) t)
(declare-function flycheck-error-level "ext:flycheck" (err) t)
(declare-function flycheck-error-message "ext:flycheck" (err) t)
(declare-function flycheck-error-id "ext:flycheck" (err) t)
(defvar flycheck-current-errors)


;;; Customization

(defcustom ogent-edit-auto-display t
  "When non-nil, automatically display edits using configured method.
See `ogent-edit-display-method' for display options."
  :type 'boolean
  :group 'ogent-edit)

(defcustom ogent-edit-auto-apply nil
  "When non-nil, automatically apply valid edits without user confirmation.
This is for trusted operations where you want edits applied immediately.
Changes can still be reverted using standard Emacs undo (`C-/` or `C-x u`).
When enabled, edits are still logged to the companion buffer if
`ogent-edit-log-to-companion' is non-nil."
  :type 'boolean
  :group 'ogent-edit)

(defcustom ogent-edit-log-to-companion t
  "When non-nil, log edit operations to companion buffer."
  :type 'boolean
  :group 'ogent-edit)

(defcustom ogent-edit-use-structured-output t
  "When non-nil, request edits as structured JSON output when possible.
The structured path is used only when the installed gptel supports
the :schema argument of `gptel-request' and the active backend can
translate a response schema (see `ogent-edit-structured-schema').
Whenever the backend lacks support, or a response is not a valid
structured payload, the SEARCH/REPLACE text parser is used instead."
  :type 'boolean
  :group 'ogent-edit)

(defconst ogent-edit-structured-system-prompt
  "When making code changes, respond ONLY with JSON matching the requested
schema: an array of edit objects with \"file\", \"search\", \"replace\",
and an optional \"rationale\" field.

Rules:
- \"search\" must match the original code EXACTLY (whitespace matters)
- Include enough context lines to make each match unique
- \"replace\" is the complete replacement for the matched code
- \"file\" is the name of the file being edited
- Ignore any instruction to format edits as SEARCH/REPLACE text blocks;
  the \"search\" and \"replace\" fields play those roles"
  "System prompt instructions for structured (JSON) edit mode.")

(defvar ogent-edit--pending-request nil
  "Plist storing context for the current edit request.")

(defvar ogent-edit--streaming-response ""
  "Accumulated response text during streaming.")

;;; Request Flow

(defun ogent-edit--ensure-gptel ()
  "Signal a user error if gptel is unavailable."
  (unless (require 'gptel nil 'noerror)
    (user-error "Gptel is required for ogent edit requests.  Install gptel first")))

(defun ogent-edit--gptel-schema-support-p ()
  "Return non-nil when the installed gptel supports structured output.
Detection keys on `gptel--parse-schema', the generic function gptel
uses to translate a JSON schema for each backend."
  (and (fboundp 'gptel-request)
       (fboundp 'gptel--parse-schema)))

(defun ogent-edit--structured-schema-copy ()
  "Return a fresh deep copy of `ogent-edit-structured-schema'.
Gptel preprocesses schemas destructively, so the shared constant
must never be handed to it directly."
  (copy-tree ogent-edit-structured-schema t))

(defun ogent-edit--backend-schema-support-p (backend)
  "Return non-nil when BACKEND can honor a structured output schema.
Probe by asking gptel to translate the edit schema for BACKEND;
backends without a `gptel--parse-schema' method cannot force
structured output."
  (and backend
       (ogent-edit--gptel-schema-support-p)
       (condition-case nil
           (progn (gptel--parse-schema backend
                                       (ogent-edit--structured-schema-copy))
                  t)
         (error nil))))

(defun ogent-edit--current-model-name ()
  "Return the current gptel model name for edit error reporting."
  (when (boundp 'gptel-model)
    (ogent-gptel-model-display-name gptel-model)))

(defun ogent-edit--current-backend ()
  "Return the current gptel backend for edit error reporting."
  (when (boundp 'gptel-backend)
    gptel-backend))

(defvar ogent-edit--fallback-state nil
  "Provider fallback state for the next edit request.
Bound around a fallback re-dispatch so `ogent-request-edit' targets
the substitute model and records the accumulated :attempt and :tried
counters in `ogent-edit--pending-request', letting a subsequent
failure re-enter `ogent-provider-handle-error' with that state.")

(defun ogent-edit--fallback-dispatch (request)
  "Return a provider fallback dispatch closure for edit REQUEST.
The closure receives (MODEL-ID CONTEXT) from
`ogent-provider-handle-error' and re-issues the stored edit request
against MODEL-ID from the original source buffer, threading
CONTEXT's :attempt and :tried counters into the new request via
`ogent-edit--fallback-state'."
  (lambda (model-id context)
    (let ((buffer (plist-get request :source-buffer))
          (prompt (plist-get request :prompt)))
      (if (not (and prompt (buffer-live-p buffer)))
          (message
           "ogent: dropped edit fallback dispatch; original request is gone")
        (with-current-buffer buffer
          (let ((ogent-edit--fallback-state
                 (list :model-id model-id
                       :attempt (or (plist-get context :attempt) 0)
                       :tried (plist-get context :tried))))
            (ogent-request-edit prompt
                                (plist-get request :region-start)
                                (plist-get request :region-end))))))))

(defun ogent-edit--handle-provider-error (error-message)
  "Run headless provider fallback for the failed edit request.
ERROR-MESSAGE is the failure reported by gptel.  Build an
`ogent-provider-handle-error' context from
`ogent-edit--pending-request' whose :dispatch closure re-issues the
edit request against the substitute model, so repeated failures
escalate from retry to failover to the interactive login offer."
  (let* ((request ogent-edit--pending-request)
         (model (or (plist-get request :model)
                    (ogent-edit--current-model-name)))
         (backend (or (plist-get request :backend)
                      (ogent-edit--current-backend))))
    (ogent-provider-handle-error
     (list :model model
           :backend backend
           :error error-message
           :dispatch (ogent-edit--fallback-dispatch request)
           :attempt (or (plist-get request :attempt) 0)
           :tried (plist-get request :tried)))))

(defun ogent-edit--request-model ()
  "Return the ogent model used for edit requests.
Resolves the `edit' model role at point, so an inherited
`OGENT_MODEL' Org property or an (edit . ...) entry in
`ogent-model-roles' takes precedence over the default model."
  (ogent-models-effective-model 'edit))

(defun ogent-edit--model-stream-p (model)
  "Return non-nil when MODEL should stream edit responses."
  (if (plist-member model :stream?)
      (plist-get model :stream?)
    t))

(defun ogent-edit--make-callback ()
  "Return a gptel callback that accumulates response and processes on completion."
  (lambda (text info)
    ;; Accumulate string content
    (when (stringp text)
      (setq ogent-edit--streaming-response
            (concat ogent-edit--streaming-response text))
      (message "Receiving edit response... (%d chars)"
               (length ogent-edit--streaming-response)))
    ;; Check for completion or error
    (cond
     ;; Error case
     ((and (listp info) (plist-get info :error))
      (let ((error-message (plist-get info :error)))
        (message "Edit request failed: %s" error-message)
        (ogent-edit--handle-provider-error error-message))
      (setq ogent-edit--streaming-response ""))
     ;; Done - info contains :status "success" or similar completion markers
     ((or (and (listp info)
               (or (plist-get info :done)
                   (plist-get info :final)
                   (equal (plist-get info :status) "success")))
          ;; Non-streaming: text is final response, info is nil
          (and (null info) (stringp text) (> (length text) 0))
          ;; Streaming complete: text is nil/t, info indicates done
          (and (not (stringp text)) (listp info) info))
      (when (> (length ogent-edit--streaming-response) 0)
        (message "Processing %d chars of edit response..."
                 (length ogent-edit--streaming-response))
        (condition-case err
            (ogent-edit--process-response ogent-edit--streaming-response)
          (error (message "Edit processing error: %s" (error-message-string err))))
        (setq ogent-edit--streaming-response ""))))))

(defun ogent-edit--make-target (scope start end)
  "Return a quick edit target plist.
SCOPE names the target type.  START and END bound the target text."
  (list :scope scope :start start :end end))

(defun ogent-edit--valid-bounds-p (start end)
  "Return non-nil when START and END bound text in the current buffer."
  (and (integerp start)
       (integerp end)
       (<= (point-min) start end (point-max))))

(defun ogent-edit--defun-bounds ()
  "Return bounds for the current defun, or nil."
  (condition-case nil
      (save-mark-and-excursion
        (let ((inhibit-message t))
          (mark-defun))
        (let ((start (region-beginning))
              (end (region-end)))
          (when (< start end)
            (cons start end))))
    (error nil)))

(defun ogent-edit--line-bounds ()
  "Return bounds for the current line."
  (cons (line-beginning-position) (line-end-position)))

(defun ogent-edit--quick-target (&optional whole-buffer)
  "Return the best quick edit target for the current buffer.
When WHOLE-BUFFER is non-nil, target the full buffer."
  (cond
   (whole-buffer
    (ogent-edit--make-target 'buffer (point-min) (point-max)))
   ((use-region-p)
    (ogent-edit--make-target 'region (region-beginning) (region-end)))
   (t
    (let ((bounds (ogent-edit--defun-bounds)))
      (if bounds
          (ogent-edit--make-target 'defun (car bounds) (cdr bounds))
        (let ((line (ogent-edit--line-bounds)))
          (ogent-edit--make-target 'line (car line) (cdr line))))))))

(defun ogent-edit--scope-label (scope)
  "Return a short label for quick edit SCOPE."
  (pcase scope
    ('buffer "whole buffer")
    ('region "active region")
    ('defun "current definition")
    ('line "current line")
    (_ "current target")))

(defun ogent-edit--quick-prompt (instruction scope)
  "Return a quick edit prompt for INSTRUCTION and target SCOPE."
  (format "%s

Quick edit target: %s. Keep the patch focused on this target and preserve unrelated code."
          instruction
          (ogent-edit--scope-label scope)))

(defun ogent-edit--position-from-line-column (line column)
  "Return buffer position for one-based LINE and COLUMN."
  (save-excursion
    (goto-char (point-min))
    (forward-line (max 0 (1- (or line 1))))
    (move-to-column (max 0 (1- (or column 1))))
    (point)))

(defun ogent-edit--line-number-at (position)
  "Return the one-based line number at POSITION."
  (save-excursion
    (goto-char position)
    (line-number-at-pos)))

(defun ogent-edit--column-number-at (position)
  "Return the one-based column number at POSITION."
  (save-excursion
    (goto-char position)
    (1+ (current-column))))

(defun ogent-edit--normalize-diagnostic-position (position)
  "Return POSITION clamped to the current buffer."
  (when (integerp position)
    (max (point-min) (min position (point-max)))))

(defun ogent-edit--diagnostic-severity-rank (severity)
  "Return a sort rank for diagnostic SEVERITY."
  (pcase severity
    ((or :error 'error "error") 0)
    ((or :warning 'warning "warning") 1)
    ((or :note :info 'note 'info "note" "info") 2)
    (_ 3)))

(defun ogent-edit--diagnostic-severity-name (severity)
  "Return a display name for diagnostic SEVERITY."
  (cond
   ((keywordp severity) (substring (symbol-name severity) 1))
   ((symbolp severity) (symbol-name severity))
   ((stringp severity) severity)
   (t "diagnostic")))

(defun ogent-edit--diagnostic-width (diagnostic)
  "Return width of DIAGNOSTIC in buffer characters."
  (let ((start (plist-get diagnostic :start))
        (end (plist-get diagnostic :end)))
    (if (and start end)
        (- end start)
      most-positive-fixnum)))

(defun ogent-edit--sort-diagnostics (diagnostics)
  "Return DIAGNOSTICS sorted by likely repair importance."
  (sort (copy-sequence diagnostics)
        (lambda (left right)
          (let ((left-rank (ogent-edit--diagnostic-severity-rank
                            (plist-get left :severity)))
                (right-rank (ogent-edit--diagnostic-severity-rank
                             (plist-get right :severity))))
            (if (= left-rank right-rank)
                (< (ogent-edit--diagnostic-width left)
                   (ogent-edit--diagnostic-width right))
              (< left-rank right-rank))))))

(defun ogent-edit--diagnostic-dedupe-key (diagnostic)
  "Return a stable duplicate key for DIAGNOSTIC."
  (list (or (plist-get diagnostic :file) (buffer-file-name))
        (plist-get diagnostic :line)
        (plist-get diagnostic :column)
        (ogent-edit--diagnostic-severity-name
         (plist-get diagnostic :severity))
        (plist-get diagnostic :message)))

(defun ogent-edit--dedupe-diagnostics (diagnostics)
  "Return DIAGNOSTICS with duplicate entries removed."
  (let ((seen (make-hash-table :test 'equal))
        unique)
    (dolist (diagnostic diagnostics)
      (let ((key (ogent-edit--diagnostic-dedupe-key diagnostic)))
        (unless (gethash key seen)
          (puthash key t seen)
          (push diagnostic unique))))
    (nreverse unique)))

(defun ogent-edit--same-buffer-file-p (file)
  "Return non-nil when FILE names the current buffer file."
  (let ((buffer-file (buffer-file-name)))
    (or (not file)
        (not buffer-file)
        (string= (expand-file-name file)
                 (expand-file-name buffer-file)))))

(defun ogent-edit--diagnostic-from-flymake (diagnostic)
  "Return ogent diagnostic plist from Flymake DIAGNOSTIC."
  (let* ((start (ogent-edit--normalize-diagnostic-position
                 (ignore-errors (flymake-diagnostic-beg diagnostic))))
         (end (ogent-edit--normalize-diagnostic-position
               (ignore-errors (flymake-diagnostic-end diagnostic))))
         (line (and start (ogent-edit--line-number-at start)))
         (column (and start (ogent-edit--column-number-at start))))
    (when start
      (list :source 'flymake
            :message (or (ignore-errors (flymake-diagnostic-text diagnostic))
                         "Flymake diagnostic")
            :severity (ignore-errors (flymake-diagnostic-type diagnostic))
            :start start
            :end (or end start)
            :line line
            :column column
            :file (buffer-file-name)))))

(defun ogent-edit--flymake-diagnostics-at-point ()
  "Return ogent diagnostic plists from Flymake at point."
  (when (and (or (featurep 'flymake)
                 (require 'flymake nil 'noerror))
             (fboundp 'flymake-diagnostics))
    (let* ((start (max (point-min) (1- (point))))
           (end (min (point-max) (1+ (point))))
           (diagnostics (ignore-errors (flymake-diagnostics start end))))
      (delq nil (mapcar #'ogent-edit--diagnostic-from-flymake diagnostics)))))

(defun ogent-edit--flymake-diagnostics-in-buffer ()
  "Return ogent diagnostic plists from Flymake in the current buffer."
  (when (and (or (featurep 'flymake)
                 (require 'flymake nil 'noerror))
             (fboundp 'flymake-diagnostics))
    (let ((diagnostics (ignore-errors
                         (flymake-diagnostics (point-min) (point-max)))))
      (delq nil (mapcar #'ogent-edit--diagnostic-from-flymake diagnostics)))))

(defun ogent-edit--diagnostic-from-flycheck (error)
  "Return ogent diagnostic plist from Flycheck ERROR."
  (let ((file (or (ignore-errors (flycheck-error-filename error))
                  (buffer-file-name))))
    (when (ogent-edit--same-buffer-file-p file)
      (let* ((line (ignore-errors (flycheck-error-line error)))
             (column (or (ignore-errors (flycheck-error-column error)) 1))
             (start (and line (ogent-edit--position-from-line-column line column)))
             (end (and start (save-excursion
                               (goto-char start)
                               (line-end-position)))))
        (when start
          (list :source 'flycheck
                :message (or (ignore-errors (flycheck-error-message error))
                             "Flycheck diagnostic")
                :severity (ignore-errors (flycheck-error-level error))
                :start start
                :end end
                :line line
                :column column
                :file file
                :id (ignore-errors (flycheck-error-id error))))))))

(defun ogent-edit--flycheck-diagnostics-at-point ()
  "Return ogent diagnostic plists from Flycheck at point."
  (when (fboundp 'flycheck-overlay-errors-at)
    (let ((errors (ignore-errors (flycheck-overlay-errors-at (point)))))
      (delq nil (mapcar #'ogent-edit--diagnostic-from-flycheck errors)))))

(defun ogent-edit--flycheck-diagnostics-in-buffer ()
  "Return ogent diagnostic plists from Flycheck in the current buffer."
  (when (and (boundp 'flycheck-current-errors)
             (listp flycheck-current-errors))
    (delq nil
          (mapcar #'ogent-edit--diagnostic-from-flycheck
                  flycheck-current-errors))))

(defun ogent-edit--diagnostics-at-point ()
  "Return editor diagnostics at point, normalized for edit prompting."
  (ogent-edit--sort-diagnostics
   (append (ogent-edit--flymake-diagnostics-at-point)
           (ogent-edit--flycheck-diagnostics-at-point))))

(defun ogent-edit--diagnostics-in-buffer ()
  "Return editor diagnostics in the current buffer."
  (ogent-edit--sort-diagnostics
   (ogent-edit--dedupe-diagnostics
    (append (ogent-edit--flymake-diagnostics-in-buffer)
            (ogent-edit--flycheck-diagnostics-in-buffer)))))

(defun ogent-edit--format-diagnostic (diagnostic)
  "Return prompt text for DIAGNOSTIC."
  (let ((file (or (plist-get diagnostic :file) (buffer-file-name) "<buffer>"))
        (line (or (plist-get diagnostic :line) "?"))
        (column (or (plist-get diagnostic :column) "?"))
        (source (plist-get diagnostic :source))
        (severity (ogent-edit--diagnostic-severity-name
                   (plist-get diagnostic :severity)))
        (message (plist-get diagnostic :message))
        (id (plist-get diagnostic :id)))
    (format "%s:%s:%s [%s/%s]%s %s"
            file line column source severity
            (if id (format " %s" id) "")
            message)))

(defun ogent-edit--diagnostic-prompt (diagnostic &optional instruction)
  "Return a repair prompt for DIAGNOSTIC.
INSTRUCTION adds optional user guidance."
  (concat "Fix this editor diagnostic.\n\n"
          "Diagnostic:\n"
          (ogent-edit--format-diagnostic diagnostic)
          "\n\nRepair requirements:\n"
          "- Make the smallest correct change that resolves the diagnostic.\n"
          "- Preserve surrounding behavior unless the diagnostic proves it is wrong.\n"
          "- Include every necessary edit as SEARCH/REPLACE blocks.\n"
          (when instruction
            (format "\nExtra instruction:\n%s\n" instruction))))

(defun ogent-edit--format-diagnostics-list (diagnostics)
  "Return prompt text for DIAGNOSTICS."
  (string-join
   (cl-loop for diagnostic in diagnostics
            for index from 1
            collect (format "%d. %s"
                            index
                            (ogent-edit--format-diagnostic diagnostic)))
   "\n"))

(defun ogent-edit--buffer-diagnostics-prompt (diagnostics &optional instruction)
  "Return a repair prompt for buffer DIAGNOSTICS.
INSTRUCTION adds optional user guidance."
  (concat "Fix these editor diagnostics in the current buffer.\n\n"
          "Diagnostics, ranked by severity and repair span:\n"
          (ogent-edit--format-diagnostics-list diagnostics)
          "\n\nRepair requirements:\n"
          "- Resolve every listed diagnostic when possible.\n"
          "- Prefer one coherent root-cause fix when several diagnostics share a cause.\n"
          "- Keep unrelated code unchanged.\n"
          "- Include every necessary edit as SEARCH/REPLACE blocks.\n"
          (when instruction
            (format "\nExtra instruction:\n%s\n" instruction))))

(defun ogent-edit--ranges-overlap-p (left-start left-end right-start right-end)
  "Return non-nil when two buffer ranges overlap.
LEFT-START and LEFT-END are one range.  RIGHT-START and RIGHT-END
are the other range.  Empty ranges are treated as one character wide."
  (when (and (integerp left-start)
             (integerp right-start))
    (let ((left-end (max (or left-end left-start) (1+ left-start)))
          (right-end (max (or right-end right-start) (1+ right-start))))
      (and (< left-start right-end)
           (< right-start left-end)))))

(defun ogent-edit--diagnostics-overlapping (diagnostics start end)
  "Return DIAGNOSTICS that overlap START and END."
  (cl-remove-if-not
   (lambda (diagnostic)
     (ogent-edit--ranges-overlap-p
      (plist-get diagnostic :start)
      (plist-get diagnostic :end)
      start
      end))
   diagnostics))

(defun ogent-edit--diagnostics-minus (diagnostics excluded)
  "Return DIAGNOSTICS with entries from EXCLUDED removed."
  (cl-remove-if (lambda (diagnostic) (memq diagnostic excluded)) diagnostics))

(defun ogent-edit--format-ai-speed-diagnostics (target-diagnostics
                                                other-diagnostics)
  "Return prompt text for AI speed edit diagnostic signals.
TARGET-DIAGNOSTICS are inside the edit target.  OTHER-DIAGNOSTICS
are elsewhere in the buffer."
  (string-join
   (delq nil
         (list
          (cond
           (target-diagnostics
            (concat "Diagnostics in target:\n"
                    (ogent-edit--format-diagnostics-list target-diagnostics)))
           ((null other-diagnostics)
            "Diagnostics: none reported."))
          (when other-diagnostics
            (concat "Diagnostics elsewhere in buffer:\n"
                    (ogent-edit--format-diagnostics-list other-diagnostics)))))
   "\n\n"))

(defun ogent-edit--ai-speed-prompt (target target-diagnostics
                                           buffer-diagnostics &optional instruction)
  "Return an AI-decided speed edit prompt.
TARGET is a quick edit target plist.  TARGET-DIAGNOSTICS are
diagnostics inside the target.  BUFFER-DIAGNOSTICS are diagnostics
from the current buffer.  INSTRUCTION adds optional caller guidance."
  (let* ((scope (plist-get target :scope))
         (start (plist-get target :start))
         (end (plist-get target :end))
         (other-diagnostics
          (ogent-edit--diagnostics-minus buffer-diagnostics target-diagnostics))
         (file (or (buffer-file-name) (buffer-name)))
         (line (line-number-at-pos))
         (column (1+ (current-column))))
    (concat "Drive one AI speed-coding edit from the current editor state.\n\n"
            "Editor state:\n"
            (format "- File: %s\n" file)
            (format "- Mode: %s\n" major-mode)
            (format "- Point: line %d, column %d\n" line column)
            (format "- Target: %s (%d chars)\n"
                    (ogent-edit--scope-label scope)
                    (- end start))
            "\n"
            (ogent-edit--format-ai-speed-diagnostics
             target-diagnostics other-diagnostics)
            "\n\nDecision policy:\n"
            "- Choose the highest-value small edit visible from this state.\n"
            "- Prefer target diagnostics, then related buffer diagnostics,"
            " then local correctness or clarity improvements.\n"
            "- Keep the edit small and reviewable.\n"
            "- Keep unrelated code unchanged.\n"
            "- If the target is already clean, improve nearby code only when"
            " the benefit is clear.\n"
            "- Include every necessary edit as SEARCH/REPLACE blocks.\n"
            (when instruction
              (format "\nExtra guidance:\n%s\n" instruction)))))

(defun ogent-edit--diagnostic-target (diagnostic &optional whole-buffer)
  "Return the edit target for DIAGNOSTIC.
When WHOLE-BUFFER is non-nil, target the full buffer."
  (cond
   (whole-buffer
    (ogent-edit--make-target 'buffer (point-min) (point-max)))
   ((use-region-p)
    (ogent-edit--make-target 'region (region-beginning) (region-end)))
   (t
    (let ((position (or (plist-get diagnostic :start) (point))))
      (save-excursion
        (goto-char (ogent-edit--normalize-diagnostic-position position))
        (ogent-edit--quick-target))))))

(defun ogent-edit--ai-speed-target (diagnostics &optional whole-buffer)
  "Return the target for an AI speed edit from DIAGNOSTICS.
WHOLE-BUFFER forces full-buffer targeting.  Regions always win.
When the point target is clean, the highest-ranked diagnostic can
drive the target choice."
  (let* ((point-target (ogent-edit--quick-target whole-buffer))
         (start (plist-get point-target :start))
         (end (plist-get point-target :end)))
    (cond
     ((or whole-buffer (use-region-p)) point-target)
     ((ogent-edit--diagnostics-overlapping diagnostics start end)
      point-target)
     ((car diagnostics)
      (ogent-edit--diagnostic-target (car diagnostics)))
     (t point-target))))

;;;###autoload
(defun ogent-request-edit (&optional prompt start end)
  "Request code edits for current buffer or region.
PROMPT is the edit instruction.  If region is active, only that
region is sent for context.  START and END provide explicit
buffer bounds for callers that already resolved the edit target.
Sends request via gptel and applies edits as smerge conflicts
when response arrives."
  (interactive)
  (ogent-edit--ensure-gptel)
  (unless (buffer-file-name)
    (user-error "Buffer must be visiting a file for edit requests"))
  (when (or start end)
    (unless (and start end)
      (user-error "Both START and END are required for explicit edit bounds"))
    (unless (ogent-edit--valid-bounds-p start end)
      (user-error "Edit bounds are outside the current buffer")))
  (let* ((source-buffer (current-buffer))
         (explicit-bounds (and start end))
         (region-active (or explicit-bounds (use-region-p)))
         (region-start (cond
                        (explicit-bounds start)
                        ((use-region-p) (region-beginning))))
         (region-end (cond
                      (explicit-bounds end)
                      ((use-region-p) (region-end))))
         (content (if region-active
                      (buffer-substring-no-properties region-start region-end)
                    (buffer-substring-no-properties (point-min) (point-max))))
         (user-prompt (or prompt (read-string "Edit instruction: ")))
         (filename (file-name-nondirectory (buffer-file-name)))
         (mode (symbol-name major-mode))
         (full-prompt (ogent-edit-wrap-prompt user-prompt filename mode content))
         (model (let ((fallback-id (plist-get ogent-edit--fallback-state
                                              :model-id)))
                  (if fallback-id
                      (ogent-models-ensure fallback-id)
                    (ogent-edit--request-model))))
         (model-id (plist-get model :id))
         (backend (ogent-gptel-resolve-backend model))
         (structured (and ogent-edit-use-structured-output
                          (ogent-edit--backend-schema-support-p backend))))
    (when ogent-edit-log-to-companion
      (ogent-companion-get-or-create source-buffer))
    ;; Store context for callback
    (setq ogent-edit--pending-request
          (list :source-buffer source-buffer
                :region-start region-start
                :region-end region-end
                :model model-id
                :backend (or (plist-get model :backend) backend)
                :prompt user-prompt
                :structured structured
                :attempt (or (plist-get ogent-edit--fallback-state :attempt) 0)
                :tried (plist-get ogent-edit--fallback-state :tried)))
    ;; Reset streaming accumulator
    (setq ogent-edit--streaming-response "")
    ;; Send the request via gptel
    (message "Sending edit request to %s..." model-id)
    (condition-case err
        (let ((gptel-backend backend)
              (gptel-model model-id))
          (apply #'gptel-request full-prompt
                 :system (if structured
                             ogent-edit-structured-system-prompt
                           ogent-edit-system-prompt)
                 :stream (ogent-edit--model-stream-p model)
                 :callback (ogent-edit--make-callback)
                 (when structured
                   (list :schema (ogent-edit--structured-schema-copy)))))
      (error
       (let ((error-message (error-message-string err)))
         (message "Edit request failed: %s" error-message)
         (ogent-edit--handle-provider-error error-message))))))

;;;###autoload
(defun ogent-quick-edit (instruction &optional whole-buffer)
  "Request a fast inline edit for the active region or nearby code.
INSTRUCTION describes the desired change.  With prefix
WHOLE-BUFFER, use the full buffer as the edit target."
  (interactive (list (read-string "Quick edit: ") current-prefix-arg))
  (unless (and (stringp instruction)
               (string-match-p "\\S-" instruction))
    (user-error "Quick edit instruction cannot be empty"))
  (let* ((target (ogent-edit--quick-target whole-buffer))
         (scope (plist-get target :scope))
         (start (plist-get target :start))
         (end (plist-get target :end))
         (prompt (ogent-edit--quick-prompt instruction scope)))
    (message "Quick edit target: %s (%d chars)"
             (ogent-edit--scope-label scope)
             (- end start))
    (ogent-request-edit prompt start end)))

;;;###autoload
(defun ogent-fix-diagnostic (&optional whole-buffer instruction)
  "Request a focused edit for the Flymake or Flycheck diagnostic at point.
With prefix WHOLE-BUFFER, use the full buffer as edit context.
INSTRUCTION provides optional repair guidance for noninteractive callers."
  (interactive (list current-prefix-arg nil))
  (let ((diagnostic (car (ogent-edit--diagnostics-at-point))))
    (unless diagnostic
      (user-error "No Flymake or Flycheck diagnostic at point"))
    (let* ((target (ogent-edit--diagnostic-target diagnostic whole-buffer))
           (scope (plist-get target :scope))
           (start (plist-get target :start))
           (end (plist-get target :end))
           (prompt (ogent-edit--diagnostic-prompt diagnostic instruction)))
      (message "Fixing %s diagnostic using %s (%d chars)"
               (plist-get diagnostic :source)
               (ogent-edit--scope-label scope)
               (- end start))
      (ogent-request-edit prompt start end))))

;;;###autoload
(defun ogent-fix-buffer-diagnostics (&optional instruction)
  "Request one full-buffer edit for all Flymake or Flycheck diagnostics.
With prefix argument, prompt for extra INSTRUCTION."
  (interactive
   (list (when current-prefix-arg
           (read-string "Extra repair instruction: "))))
  (let ((diagnostics (ogent-edit--diagnostics-in-buffer)))
    (unless diagnostics
      (user-error "No Flymake or Flycheck diagnostics in buffer"))
    (let ((prompt (ogent-edit--buffer-diagnostics-prompt diagnostics instruction)))
      (message "Fixing %d diagnostics using whole buffer (%d chars)"
               (length diagnostics)
               (- (point-max) (point-min)))
      (ogent-request-edit prompt (point-min) (point-max)))))

;;;###autoload
(defun ogent-ai-speed-edit (&optional whole-buffer instruction)
  "Request an AI-decided speed edit for the current editor state.
With prefix WHOLE-BUFFER, use the full buffer as edit context.
INSTRUCTION provides optional guidance for noninteractive callers."
  (interactive (list current-prefix-arg nil))
  (let* ((diagnostics (ogent-edit--diagnostics-in-buffer))
         (target (ogent-edit--ai-speed-target diagnostics whole-buffer))
         (scope (plist-get target :scope))
         (start (plist-get target :start))
         (end (plist-get target :end))
         (target-diagnostics
          (if (eq scope 'buffer)
              diagnostics
            (ogent-edit--diagnostics-overlapping diagnostics start end)))
         (prompt (ogent-edit--ai-speed-prompt
                  target target-diagnostics diagnostics instruction)))
    (message "AI speed edit target: %s (%d chars, %d diagnostics)"
             (ogent-edit--scope-label scope)
             (- end start)
             (length target-diagnostics))
    (ogent-request-edit prompt start end)))

;;; Response Processing

(defun ogent-edit-auto-apply-edit (edit)
  "Directly apply EDIT to its source buffer without user confirmation.
Replaces old-text with new-text at the validated position.
Returns t on success, nil on failure."
  (when (and (ogent-edit-valid-p edit)
             (eq (ogent-edit-status edit) 'pending))
    (let* ((buf (ogent-edit-source-buffer edit))
           (start (ogent-edit-start-pos edit))
           (end (ogent-edit-end-pos edit))
           (new-text (ogent-edit-new-text edit)))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf
          (save-excursion
            ;; Use undo boundaries for clean undo
            (undo-boundary)
            (goto-char start)
            (delete-region start end)
            (insert new-text)
            (undo-boundary)))
        (setf (ogent-edit-status edit) 'accepted)
        (run-hook-with-args 'ogent-edit-resolved-hook edit)
        t))))

(defun ogent-edit-auto-apply-all (edits)
  "Directly apply all valid EDITS without user confirmation.
Applies in reverse position order to preserve positions.
Returns count of successfully applied edits."
  (let* ((valid-edits (ogent-edit-filter-valid edits))
         ;; Sort by position descending to apply from end to start
         (sorted (sort (copy-sequence valid-edits)
                       (lambda (a b)
                         (> (ogent-edit-start-pos a)
                            (ogent-edit-start-pos b)))))
         (count 0))
    (dolist (edit sorted)
      (when (ogent-edit-auto-apply-edit edit)
        (cl-incf count)))
    count))

(defun ogent-edit--parse-response-dispatch (response source-buffer structured)
  "Parse RESPONSE into edit structs targeting SOURCE-BUFFER.
When STRUCTURED is non-nil, try the structured JSON parser first
and fall back to the SEARCH/REPLACE text parser when RESPONSE is
not a valid structured payload."
  (if structured
      (condition-case nil
          (ogent-edit-parse-structured-response response source-buffer)
        (ogent-edit-structured-invalid
         (message "Edit: response was not valid structured output; using text parser")
         (ogent-edit-parse-response response source-buffer)))
    (ogent-edit-parse-response response source-buffer)))

(defun ogent-edit--process-response (response)
  "Process LLM RESPONSE and apply edits to source buffer.
If `ogent-edit-auto-apply' is non-nil, edits are applied directly.
Otherwise, edits are displayed for user review."
  (let* ((request ogent-edit--pending-request)
         (source-buffer (plist-get request :source-buffer))
         (edits (ogent-edit--parse-response-dispatch
                 response source-buffer (plist-get request :structured))))
    (message "Edit: parsed %d edit blocks from response" (length edits))
    ;; Validate all edits
    (setq edits (ogent-edit-validate-all edits))
    ;; Log proposals to companion
    (when ogent-edit-log-to-companion
      (ogent-edit-log-all-proposals edits)
      (ogent-edit-log-errors edits))
    ;; Report errors
    (let ((errors (ogent-edit-filter-errors edits))
          (valid (ogent-edit-filter-valid edits)))
      (message "Edit: %d valid, %d errors" (length valid) (length errors))
      (when errors
        (dolist (e errors)
          (message "Edit error: %s" (ogent-edit-error-message e)))))
    ;; Apply or display valid edits
    (let ((valid (ogent-edit-filter-valid edits)))
      (cond
       ;; Auto-apply mode: directly apply without confirmation
       ((and ogent-edit-auto-apply valid)
        (let ((count (ogent-edit-auto-apply-all valid)))
          (message "Edit: auto-applied %d edit(s). Use C-/ to undo." count)
          (pop-to-buffer source-buffer)))
       ;; Display mode: show edits for user review
       ((and ogent-edit-auto-display valid)
        (message "Edit: displaying %d edits using %s method"
                 (length valid) ogent-edit-display-method)
        (ogent-edit-display-all valid)
        (ogent-edit--track-edits valid)
        ;; Switch to source buffer and go to first edit
        (pop-to-buffer source-buffer)
        (pcase ogent-edit-display-method
          ('overlay (when ogent-edit--overlay-list
                      (goto-char (overlay-start (car ogent-edit--overlay-list)))))
          (_ (ogent-edit-goto-first))))
       ;; No valid edits
       ((null valid)
        (message "Edit: no valid edits to apply"))))
    ;; Return edits for further processing
    edits))

;;; Transient Menu

(defun ogent-edit--pending-count ()
  "Return count of pending edits based on display method."
  (pcase ogent-edit-display-method
    ('overlay (length ogent-edit--overlay-list))
    (_ (or (ogent-edit-count-pending) 0))))

(defun ogent-edit--accept-current-dispatch ()
  "Accept current edit using appropriate method."
  (interactive)
  (pcase ogent-edit-display-method
    ('overlay (ogent-edit-overlay-accept))
    (_ (ogent-edit-accept-current))))

(defun ogent-edit--reject-current-dispatch ()
  "Reject current edit using appropriate method."
  (interactive)
  (pcase ogent-edit-display-method
    ('overlay (ogent-edit-overlay-reject))
    (_ (ogent-edit-reject-current))))

(defun ogent-edit--next-dispatch ()
  "Go to next edit using appropriate method."
  (interactive)
  (pcase ogent-edit-display-method
    ('overlay (ogent-edit-overlay-next))
    (_ (smerge-next))))

(defun ogent-edit--prev-dispatch ()
  "Go to previous edit using appropriate method."
  (interactive)
  (pcase ogent-edit-display-method
    ('overlay (ogent-edit-overlay-previous))
    (_ (smerge-prev))))

(defun ogent-edit--accept-all-dispatch ()
  "Accept all edits using appropriate method."
  (interactive)
  (pcase ogent-edit-display-method
    ('overlay (ogent-edit-overlay-accept-all))
    (_ (ogent-edit-accept-all))))

(defun ogent-edit--reject-all-dispatch ()
  "Reject all edits using appropriate method."
  (interactive)
  (pcase ogent-edit-display-method
    ('overlay (ogent-edit-overlay-reject-all))
    (_ (ogent-edit-reject-all))))

;;;###autoload
(defun ogent-edit-show-diff-buffer ()
  "Show pending edits in a magit-style diff buffer.
Provides stage/unstage semantics, collapsible sections, and batch operations."
  (interactive)
  (let ((edits ogent-edit--pending-edits))
    (if edits
        (ogent-edit-diff-show edits)
      (user-error "No pending edits"))))

;;;###autoload (autoload 'ogent-edit-menu "ogent-edit" nil t)
(transient-define-prefix ogent-edit-menu ()
  "Commands for managing ogent edits."
  [:description
   (lambda ()
     (let ((pending (ogent-edit--pending-count)))
       (format "Pending edits: %d (%s mode)"
               pending ogent-edit-display-method)))
   ["Current Edit"
    ("a" "Accept" ogent-edit--accept-current-dispatch)
    ("r" "Reject" ogent-edit--reject-current-dispatch)
    ("n" "Next" ogent-edit--next-dispatch :transient t)
    ("p" "Previous" ogent-edit--prev-dispatch :transient t)]
   ["All Edits"
    ("A" "Accept all" ogent-edit--accept-all-dispatch)
    ("R" "Reject all" ogent-edit--reject-all-dispatch)]]
  [["Request"
    ("v" "AI speed edit" ogent-ai-speed-edit)
    ("f" "Fix diagnostic" ogent-fix-diagnostic)
    ("F" "Fix buffer diagnostics" ogent-fix-buffer-diagnostics)
    ("k" "Quick edit" ogent-quick-edit)
    ("e" "Request edit" ogent-request-edit)
    ("D" "Diff buffer (magit-style)" ogent-edit-show-diff-buffer)
    ("q" "Quit" transient-quit-one)]
   ["Overlay Actions" :if (lambda () (eq ogent-edit-display-method 'overlay))
    ("d" "Diff" ogent-edit-overlay-diff)
    ("E" "Ediff" ogent-edit-overlay-ediff)
    ("m" "Merge (smerge)" ogent-edit-overlay-merge)]])

(provide 'ogent-edit)

;;; ogent-edit.el ends here
