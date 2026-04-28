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
(require 'ogent-edit-diff)

(eval-when-compile
  (require 'flymake))

;; gptel integration
(declare-function gptel-request "ext:gptel" (prompt &rest args))
(declare-function gptel-backend-name "ext:gptel")
(declare-function gptel--model-name "ext:gptel")
(defvar gptel-backend)
(defvar gptel-model)

;; Diagnostic integrations
(declare-function flycheck-overlay-errors-at "ext:flycheck" (pos))
(declare-function flycheck-error-filename "ext:flycheck" (err))
(declare-function flycheck-error-line "ext:flycheck" (err))
(declare-function flycheck-error-column "ext:flycheck" (err))
(declare-function flycheck-error-level "ext:flycheck" (err))
(declare-function flycheck-error-message "ext:flycheck" (err))
(declare-function flycheck-error-id "ext:flycheck" (err))
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

(defvar ogent-edit--pending-request nil
  "Plist storing context for the current edit request.")

(defvar ogent-edit--streaming-response ""
  "Accumulated response text during streaming.")

;;; Request Flow

(defun ogent-edit--ensure-gptel ()
  "Signal a user error if gptel is unavailable."
  (unless (require 'gptel nil 'noerror)
    (user-error "gptel is required for ogent edit requests. Install gptel first")))

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
      (message "Edit request failed: %s" (plist-get info :error))
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
         (full-prompt (ogent-edit-wrap-prompt user-prompt filename mode content)))
    ;; Store context for callback
    (setq ogent-edit--pending-request
          (list :source-buffer source-buffer
                :region-start region-start
                :region-end region-end
                :prompt user-prompt))
    ;; Reset streaming accumulator
    (setq ogent-edit--streaming-response "")
    ;; Send the request via gptel
    (message "Sending edit request to %s..."
             (if (and (boundp 'gptel-model) gptel-model)
                 (if (fboundp 'gptel--model-name)
                     (gptel--model-name gptel-model)
                   gptel-model)
               "LLM"))
    (gptel-request full-prompt
                   :system ogent-edit-system-prompt
                   :stream t
                   :callback (ogent-edit--make-callback))))

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

(defun ogent-edit--process-response (response)
  "Process LLM RESPONSE and apply edits to source buffer.
If `ogent-edit-auto-apply' is non-nil, edits are applied directly.
Otherwise, edits are displayed for user review."
  (let* ((request ogent-edit--pending-request)
         (source-buffer (plist-get request :source-buffer))
         (edits (ogent-edit-parse-response response source-buffer)))
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
