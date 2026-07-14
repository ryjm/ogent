;;; ogent-ui-engine.el --- Conversation engine, errors, and request control -*- lexical-binding: t; -*-

;;; Commentary:
;; The streaming conversation engine for ogent UI: transcript skeleton,
;; request lifecycle and streaming callbacks, status/close handling, and
;; the gptel post-response hook.  Also the error console and the
;; cancel/pause/resume/retry commands that operate over live requests.

;;; Code:

(require 'cl-lib)
(require 'ogent-ui-core)
(require 'ogent-ui-format)
(require 'ogent-ui-toolcalls)
(require 'ogent-context)
(require 'ogent-models)
(require 'ogent-gptel)
(require 'ogent-companion)
(require 'ogent-ledger)
(require 'ogent-provider-fallback)
(require 'ogent-ui-status)

(defvar ogent-zen-mode)

;; Request build & send lives downstream; resume/retry dispatch back into it.
(declare-function ogent-request "ogent-ui-send"
                  (&optional prompt models preset templates))

;; Zen presentation hooks (decoupled: declare + fboundp, never required).
(declare-function ogent-zen-refresh "ogent-zen" (&optional begin end))
(declare-function ogent-zen-refresh-at "ogent-zen" (position))
(declare-function ogent-zen-after-insert "ogent-zen" (request-pos))
(declare-function ogent-zen-store-result-title "ogent-zen-core" (request))
(declare-function ogent-zen-preview-edit-from-request
                  "ogent-zen-edit" (context request-pos))

;; gptel integration (soft dependency).
(declare-function gptel-request "ext:gptel-request")
(declare-function gptel-abort "ext:gptel-request")
(declare-function gptel-tool-name "ext:gptel-request" t t)
(declare-function gptel-backend-name "ext:gptel-request" t t)

;; Analytics (optional; loaded lazily).
(declare-function ogent-analytics-start-request "ogent-analytics")
(declare-function ogent-analytics-estimate-tokens "ogent-analytics")
(declare-function ogent-analytics-first-token "ogent-analytics")
(declare-function ogent-analytics-record-completion "ogent-analytics")

;; Provider login offer (autoloaded command).
(autoload 'ogent-onboard-login-different-provider "ogent-onboard" nil t)

(defcustom ogent-errors-buffer-name "*ogent-errors*"
  "Buffer used to display ogent request errors."
  :type 'string
  :group 'ogent-mode)

(defvar ogent-ui--error-history nil
  "List of error records, most recent first.
Each record is a plist with :timestamp, :model, :error, :request-id, :context.")

(defvar ogent-ui--error-window nil
  "Window displaying the error buffer, if any.")

(defun ogent-ui--format-node (node)
  "Return a human-readable summary line for NODE."
  (when node
    (format "%s (id: %s)"
            (or (ogent-context-node-title node) "<untitled>")
            (ogent-context-node-id node))))

(defun ogent-ui--format-context (context)
  "Format CONTEXT plist as a readable summary string."
  (let* ((source-ctx (plist-get context :source-context))
         (root (plist-get context :root))
         (ancestors (plist-get context :ancestors))
         (dependencies (plist-get context :dependencies))
         (handles (plist-get context :handles))
         (pinned (plist-get context :pinned))
         (lines nil))
    ;; Pinned context (always include first)
    (when pinned
      (push (format "Pinned (%d item%s):"
                    (length pinned)
                    (if (= (length pinned) 1) "" "s"))
            lines)
      (dolist (item pinned)
        (push (format "  - [%s] %s"
                      (ogent-pinned-item-type item)
                      (ogent-pinned-item-label item))
              lines))
      (push "" lines))
    ;; Source context (for non-Org buffers)
    (when source-ctx
      (push (ogent-context--format-source-context source-ctx) lines)
      (push "" lines))  ; blank line separator
    ;; Org context
    (when root
      (push (format "Root: %s" (ogent-ui--format-node root)) lines))
    (when ancestors
      (push (format "Ancestors: %s"
                    (string-join
                     (mapcar #'ogent-ui--format-node ancestors)
                     " -> ")) lines))
    (when handles
      (push (format "Handles: %s" (string-join handles ", ")) lines))
    (when dependencies
      (push "Dependencies:" lines)
      (dolist (dep dependencies)
        (push (format "  - %s%s"
                      (plist-get dep :handle)
                      (if (plist-get dep :missing-p)
                          " (missing)"
                        (format " -> %s"
                                (ogent-ui--format-node
                                 (plist-get dep :node)))))
              lines)))
    (if lines
        (mapconcat #'identity (nreverse lines) "\n")
      "(no context)")))

(defun ogent-ui--backend-label (backend)
  "Return a string label describing BACKEND."
  (cond
   ((symbolp backend) (symbol-name backend))
   ((and (consp backend) (symbolp (car backend))) (symbol-name (car backend)))
   (t "backend")))

(defun ogent-ui--next-request-id ()
  "Return a fresh request identifier."
  (setq ogent-ui--request-seq (1+ ogent-ui--request-seq))
  (format "ogent-request-%d" ogent-ui--request-seq))

(defun ogent-ui--encode-prompt-property (prompt)
  "Encode PROMPT for storage in a single-line Org property.
Backslashes are doubled, then newlines become literal backslash-n, so
`ogent-ui--decode-prompt-property' can reverse the encoding exactly."
  (replace-regexp-in-string
   "\n" "\\\\n"
   (replace-regexp-in-string "\\\\" "\\\\\\\\" prompt)))

(defun ogent-ui--decode-prompt-property (value)
  "Decode VALUE produced by `ogent-ui--encode-prompt-property'."
  (replace-regexp-in-string
   "\\\\[n\\\\]"
   (lambda (match)
     (if (string= match "\\n") "\n" "\\"))
   value t t))

(defun ogent-ui--next-heading-at-or-above (level bound)
  "Return the next heading position at or above LEVEL before BOUND."
  (save-excursion
    (when (re-search-forward (format "^\\*\\{1,%d\\} " level) bound t)
      (match-beginning 0))))

(defun ogent-ui--response-body-in-region (start end model-id)
  "Return the preferred Response body between START and END.
Prefer the \"Response (MODEL-ID)\" child when several models fanned
out under one request; otherwise return the first response
body.  Return nil when the region contains no Response heading."
  (save-excursion
    (goto-char start)
    (let (preferred first)
      (while (and (not preferred)
                  (re-search-forward "^\\(\\*+\\) Response (\\([^)]*\\))" end t))
        (let* ((response-level (length (match-string 1)))
               (this-model (match-string-no-properties 2))
               (body-start (min end (1+ (line-end-position))))
               (body-end (or (save-excursion
                               (goto-char body-start)
                               (ogent-ui--next-heading-at-or-above
                                response-level end))
                             end))
               (body (string-trim (buffer-substring-no-properties
                                   body-start (max body-start body-end)))))
          (unless first (setq first body))
          (when (and model-id (string= this-model model-id))
            (setq preferred body))))
      (or preferred first))))

(defun ogent-ui--conversation-history (buffer bound-pos model-id)
  "Collect completed exchanges in BUFFER strictly before BOUND-POS.
Return a flat list (user-1 response-1 user-2 response-2 ...) suitable
as the leading turns of a `gptel-request' conversation PROMPT.  The
user turn comes from the request headline's OGENT_PROMPT property when
present, falling back to the headline summary for transcripts written
before the property existed.  When a request has several Response
children (multi-model fan-out), prefer the one matching MODEL-ID.
Exchanges whose response body is empty (in-flight, aborted, or
errored) are skipped so the user/assistant alternation stays intact."
  (with-current-buffer buffer
    (save-excursion
      (save-match-data
        (save-restriction
          (widen)
          (let ((bound (ogent-ui--position-value bound-pos))
                (history nil))
            (goto-char (point-min))
            (while (re-search-forward "^\\(\\*+\\) Request: \\(.*\\)$" bound t)
              (let* ((request-level (length (match-string 1)))
                     (summary (string-trim (match-string-no-properties 2)))
                     (request-pos (match-beginning 0))
                     (request-end (or (save-excursion
                                        (ogent-ui--next-heading-at-or-above
                                         request-level bound))
                                      (or bound (point-max))))
                     (stored (org-entry-get request-pos "OGENT_PROMPT"))
                     (user-turn (if (and stored (not (string-empty-p stored)))
                                    (ogent-ui--decode-prompt-property stored)
                                  summary))
                     (response (ogent-ui--response-body-in-region
                                request-pos request-end model-id)))
                (when (and response (not (string-empty-p response))
                           (not (string-empty-p user-turn)))
                  (push user-turn history)
                  (push response history))
                (goto-char request-end)))
            (nreverse history)))))))

(defun ogent-ui--compact-history (history budget)
  "Drop oldest exchange pairs from HISTORY until it fits BUDGET tokens.
HISTORY is a flat (user response ...) list; pairs are evicted together
so the user/assistant alternation is preserved.  Token counts use
`ogent-analytics-estimate-tokens'.  Return the possibly empty
compacted list."
  (require 'ogent-analytics)
  (let ((total (apply #'+ (mapcar #'ogent-analytics-estimate-tokens history))))
    (while (and history (> total budget))
      (setq total (- total
                     (ogent-analytics-estimate-tokens (car history))
                     (ogent-analytics-estimate-tokens (cadr history))))
      (setq history (cddr history)))
    history))

(defun ogent-ui--stars (level)
  "Return an Org headline prefix for LEVEL."
  (make-string (max 1 level) ?*))

(defun ogent-ui--request-heading-level ()
  "Return the Org level to use for a new Request headline."
  (if ogent-session-buffer-p
      2
    (save-excursion
      (condition-case nil
          (progn
            (org-back-to-heading t)
            (1+ (or (org-current-level) 0)))
        (error 1)))))

(defun ogent-ui--prepare-request-insertion ()
  "Move point to the insertion position for a new Request headline."
  (if ogent-session-buffer-p
      (progn
        (goto-char (point-max))
        (unless (bolp) (insert "\n")))
    (condition-case nil
        (progn
          (org-back-to-heading t)
          (org-end-of-subtree t t)
          (unless (bolp) (insert "\n")))
      (error
       (goto-char (point-max))
       (unless (bolp) (insert "\n"))))))

(defun ogent-ui--maybe-refresh-zen (&optional request)
  "Refresh Zen overlays when `ogent-zen-mode' is active.
With REQUEST, refresh only that request's transcript region instead of
rescanning the whole buffer."
  (when (and (bound-and-true-p ogent-zen-mode)
             (fboundp 'ogent-zen-refresh))
    (let ((pos (and request
                    (fboundp 'ogent-zen-refresh-at)
                    (let ((marker (ogent-ui-request-request-heading-pos
                                   request)))
                      (and (markerp marker)
                           (eq (marker-buffer marker) (current-buffer))
                           (marker-position marker))))))
      (if pos
          (ogent-zen-refresh-at pos)
        (ogent-zen-refresh)))))

(defun ogent-ui--create-response-block (prompt context model)
  "Insert a nested headline structure for a request with MODEL.
Creates a Request child under the current Org heading containing the
PROMPT/CONTEXT src block and a nested Response sub-headline where
streamed content goes.  This mimics Claude Code's conversation structure
using `org-mode' idioms.
The raw PROMPT is persisted in an OGENT_PROMPT property at the request
headline so later requests can replay the exchange as history (see
`ogent-ui--conversation-history').
Returns a plist containing a streaming marker and block-start marker."
  (let* ((request-level (ogent-ui--request-heading-level))
         (response-level (1+ request-level))
         (request-stars (ogent-ui--stars request-level))
         (response-stars (ogent-ui--stars response-level))
         (model-id (plist-get model :id))
         (backend (plist-get model :backend))
         (payload (ogent-ui--render-prompt prompt context))
         (prompt-summary (ogent-ui--prompt-headline-summary prompt))
         request-heading-pos
         block-start
         response-heading-pos)
    (ogent-ui--prepare-request-insertion)
    (setq request-heading-pos (point-marker))
    (insert (format "%s Request: %s\n" request-stars prompt-summary))
    ;; Persist the raw prompt for later history replay.  Inserted as
    ;; literal drawer text (not `org-entry-put') so the positions and
    ;; markers captured below stay exact.
    (insert ":PROPERTIES:\n"
            (format ":OGENT_PROMPT: %s\n"
                    (ogent-ui--encode-prompt-property
                     (substring-no-properties prompt))))
    (when (plist-get context :zen-run)
      (let ((selection (plist-get context :zen-selection))
            (scope-kind (plist-get context :zen-scope-kind))
            (instruction (plist-get context :zen-scope-instruction))
            (edit-p (plist-get context :zen-edit)))
        (insert ":OGENT_STYLE: zen\n"
                (format ":OGENT_KIND: %s\n" (if edit-p "edit" "request"))
                (format ":OGENT_PATH: %s\n"
                        (or (plist-get context :zen-path) "")))
        (when scope-kind
          (insert (format ":OGENT_SCOPE_KIND: %s\n" scope-kind)))
        (when instruction
          (insert (format ":OGENT_INSTRUCTION: %s\n"
                          (ogent-ui--encode-prompt-property
                           (substring-no-properties instruction)))))
        (when edit-p
          (insert ":OGENT_EDIT_STATUS: waiting\n"))
        (when selection
          (when-let ((begin (plist-get selection :begin)))
            (insert (format ":OGENT_TARGET_BEGIN: %s\n" begin)))
          (when-let ((end (plist-get selection :end)))
            (insert (format ":OGENT_TARGET_END: %s\n" end)))
          (when-let ((length (plist-get selection :length)))
            (insert (format ":OGENT_TARGET_LENGTH: %s\n" length)))
          (when-let ((sha256 (plist-get selection :sha256)))
            (insert (format ":OGENT_TARGET_SHA256: %s\n" sha256))))
        (when-let ((workspace-root (plist-get context :workspace-root)))
          (insert (format ":OGENT_WORKSPACE: %s\n"
                          (file-name-nondirectory
                           (directory-file-name workspace-root)))
                  (format ":OGENT_WORKSPACE_ROOT: %s\n" workspace-root))
          (when-let ((workspace-target (plist-get context :workspace-target)))
            (insert (format ":OGENT_WORKSPACE_TARGET: %s\n"
                            workspace-target)))
          (when-let ((workspace-source (plist-get context :workspace-source)))
            (insert (format ":OGENT_WORKSPACE_SOURCE: %s\n"
                            workspace-source)))
          (when (plist-get context :workspace-tool-intent)
            (insert ":OGENT_TOOLS: true\n")))))
    (insert ":END:\n")
    ;; Insert the prompt/context src block under the request headline
    (setq block-start (point-marker))
    (insert (format "#+begin_src text :model %s%s :status waiting\n"
                    model-id
                    (if backend
                        (format " :backend %s" (ogent-ui--backend-label backend))
                      "")))
    (insert (ogent-ui--escape-org-block-content payload))
    (insert "\n")
    (insert "#+end_src\n\n")
    ;; Fold the context src block immediately.
    (ogent-ui--hide-src-block-at block-start)
    ;; Include model name for multi-model fan-out disambiguation.
    (setq response-heading-pos (point))
    (insert (format "%s Response (%s)\n" response-stars model-id))
    (let ((marker (copy-marker (point))))
      ;; Keep the next sibling headline on its own line even when the final
      ;; streamed chunk has no trailing newline.
      (insert "\n")
      (if (and (plist-get context :zen-run)
               (bound-and-true-p ogent-zen-mode)
               (fboundp 'ogent-zen-after-insert))
          (ogent-zen-after-insert request-heading-pos)
        (ogent-ui--maybe-refresh-zen))
      (list :marker marker
            :block-start block-start
            :response-pos response-heading-pos
            :request-heading-pos request-heading-pos
            :response-heading-level response-level))))

(defcustom ogent-ui-request-timeout 180
  "Seconds of inactivity before an in-flight request is force-closed.
The watchdog is re-armed on every streamed chunk, tool event, and status
change, so only a genuine stall trips it.  When it fires the request is
aborted and its transcript is marked as timed out, so a dropped or hung
backend never leaves a subtree stuck in a running state.  Set to nil (or
a non-positive number) to disable the watchdog entirely."
  :type '(choice (const :tag "Disabled" nil) (number :tag "Seconds"))
  :group 'ogent-mode)

(defun ogent-ui--cancel-watchdog (request)
  "Cancel REQUEST's inactivity watchdog timer, if any."
  (when-let ((timer (ogent-ui-request-watchdog request)))
    (cancel-timer timer)
    (setf (ogent-ui-request-watchdog request) nil)))

(defun ogent-ui--watchdog-timeout (request-id)
  "Force-close the request identified by REQUEST-ID after a stall.
REQUEST-ID is looked up fresh in `ogent-ui--request-table' so a request
that already finished (or was removed) is left untouched.  A still-active
request has its gptel call aborted and is closed with a timeout error so
its transcript leaves the running state."
  (when-let ((request (gethash request-id ogent-ui--request-table)))
    (setf (ogent-ui-request-watchdog request) nil)
    (unless (or (ogent-ui-request-closed request)
                (memq (ogent-ui-request-status request)
                      '(done error aborted paused)))
      (let ((buffer (ogent-ui-request-buffer request)))
        ;; Best-effort abort of the underlying gptel request.
        (when (and (buffer-live-p buffer) (fboundp 'gptel-abort))
          (ignore-errors (gptel-abort buffer)))
        (if (buffer-live-p buffer)
            (ogent-ui--close-response
             request
             (format "Request timed out after %ss of inactivity"
                     ogent-ui-request-timeout)
             'error)
          ;; The buffer is gone; just drop the orphaned request.
          (remhash request-id ogent-ui--request-table))))))

(defun ogent-ui--start-watchdog (request)
  "Arm (or re-arm) REQUEST's inactivity watchdog.
Cancels any pending timer first, then schedules a fresh one unless
`ogent-ui-request-timeout' is disabled or REQUEST is already closed."
  (ogent-ui--cancel-watchdog request)
  (when (and (numberp ogent-ui-request-timeout)
             (> ogent-ui-request-timeout 0)
             (not (ogent-ui-request-closed request)))
    (setf (ogent-ui-request-watchdog request)
          (run-with-timer ogent-ui-request-timeout nil
                          #'ogent-ui--watchdog-timeout
                          (ogent-ui-request-id request)))))

(defvar ogent-ui--fallback-state nil
  "Provider fallback state to record on the next registered request.
Bound around a fallback re-dispatch so the re-issued request stores
the accumulated :attempt and :tried counters under the
:provider-fallback key of its context plist, letting a subsequent
failure re-enter `ogent-provider-handle-error' with that state.")

(defun ogent-ui-register-request (request)
  "Register REQUEST in the active request table."
  (setf (ogent-ui-request-start-time request) (current-time))
  (setf (ogent-ui-request-status request) 'wait)
  ;; A provider-fallback re-dispatch threads its accumulated retry
  ;; state into the fresh request so the next failure re-enters
  ;; `ogent-provider-handle-error' with :attempt/:tried intact.
  (when ogent-ui--fallback-state
    (setf (ogent-ui-request-context request)
          (plist-put (copy-sequence (ogent-ui-request-context request))
                     :provider-fallback ogent-ui--fallback-state)))
  (puthash (ogent-ui-request-id request) request ogent-ui--request-table)
  (ogent-ledger-record-request-start request)
  (when (fboundp 'ogent-analytics-start-request)
    (ogent-analytics-start-request))
  ;; Create margin indicator
  (when (fboundp 'ogent-status-set-request)
    (ogent-status-set-request request))
  ;; Enable auto-scroll for new requests if configured
  (with-current-buffer (ogent-ui-request-buffer request)
    (setq ogent--auto-scroll-enabled ogent-auto-scroll)
    ;; Add post-command hook to detect when user scrolls to bottom
    (add-hook 'post-command-hook #'ogent-ui--auto-scroll-post-command nil t))
  ;; Arm the inactivity watchdog so a hung backend cannot leave this
  ;; request stuck in a running state forever.
  (ogent-ui--start-watchdog request)
  request)

(defun ogent-ui-prepare-response-block (prompt context model)
  "Default `ogent-response-function' implementation.
Creates an `ogent-ui-request' struct and registers it for streaming.
PROMPT, CONTEXT, and MODEL are forwarded to `ogent-ui--create-response-block'."
  (let* ((block (ogent-ui--create-response-block prompt context model))
         (request (make-ogent-ui-request
                   :id (ogent-ui--next-request-id)
                   :model model
                   :context context
                   :prompt prompt
                   :buffer (current-buffer)
                   :marker (plist-get block :marker)
                   :block-start (plist-get block :block-start)
                   :response-pos (plist-get block :response-pos)
                   :request-heading-pos (plist-get block :request-heading-pos)
                   :response-heading-level
                   (plist-get block :response-heading-level))))
    (ogent-ui-register-request request)))

(defun ogent-ui--response-body-text (request)
  "Return the streamed response body for REQUEST as a string, or nil.
Reads the buffer text between REQUEST's Response heading and its end
marker, excluding the heading line itself."
  (when-let* ((buffer (ogent-ui-request-buffer request))
              (start (ogent-ui-request-response-pos request))
              (end (ogent-ui-request-marker request)))
    (when (and (buffer-live-p buffer) (markerp end) (marker-position end))
      (with-current-buffer buffer
        (save-excursion
          (goto-char start)
          (forward-line 1)            ; skip the Response heading
          (let ((body-start (point))
                (body-end (marker-position end)))
            (when (< body-start body-end)
              (string-trim
               (buffer-substring-no-properties body-start body-end)))))))))

(defun ogent-ui--append-response (request chunk)
  "Append CHUNK to REQUEST's response block.
If `ogent-auto-scroll' is enabled and the user hasn't scrolled away,
automatically scroll the window to show new content.

Org headings in the response are shifted to nest under the Response
heading (see `ogent-shift-response-headings')."
  (when (and (stringp chunk) (> (length chunk) 0))
    ;; First streamed chunk marks time-to-first-token for analytics
    ;; (self-guards; no-op after the first call or when analytics is off).
    (when (fboundp 'ogent-analytics-first-token)
      (ogent-analytics-first-token))
    (let ((marker (ogent-ui-request-marker request))
          (processed-chunk
           (ogent-ui--shift-org-headings
            chunk
            (ogent-ui-request-response-heading-level request))))
      (when (and marker (marker-buffer marker))
        (with-current-buffer (ogent-ui-request-buffer request)
          (let ((following-windows
                 (when (and ogent-auto-scroll
                            ogent--auto-scroll-enabled)
                   (ogent-ui--windows-following-position
                    (current-buffer)
                    marker))))
            (save-excursion
              (goto-char marker)
              (insert processed-chunk)
              (set-marker marker (point)))
            (cond
             (following-windows
              (dolist (window following-windows)
                (ogent-ui--scroll-window-to-position window marker)))
             ((and ogent-auto-scroll
                   ogent--auto-scroll-enabled
                   (get-buffer-window-list (current-buffer) nil t))
              (setq ogent--auto-scroll-enabled nil)))))))))

(defun ogent-ui--insert-error-block (request message)
  "Insert an error block for REQUEST containing MESSAGE."
  (let ((marker (ogent-ui-request-marker request)))
    (when (and marker (marker-buffer marker))
      (with-current-buffer (ogent-ui-request-buffer request)
        (save-excursion
          (goto-char marker)
          (insert (format "\n#+begin_quote ogent-error\n%s\n#+end_quote\n" message))
          (set-marker marker (point))))))
  ;; Surface error prominently
  (ogent-ui--surface-error request message))

(defun ogent-ui--update-status (request new-status)
  "Update REQUEST status to NEW-STATUS and refresh block metadata."
  (setf (ogent-ui-request-status request) new-status)
  (when (memq new-status '(done error aborted))
    (setf (ogent-ui-request-end-time request) (current-time)))
  (when (memq new-status '(done error aborted paused))
    (ogent-ui--cancel-watchdog request))
  (ogent-ui--update-block-header request)
  ;; Update margin indicator
  (when (fboundp 'ogent-status-update-indicator)
    (ogent-status-update-indicator request new-status))
  (when-let* ((buffer (ogent-ui-request-buffer request)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ogent-ui--maybe-refresh-zen request)))))

(defun ogent-ui--format-latency (request)
  "Return a formatted latency string for REQUEST, or nil if incomplete."
  (when-let* ((start (ogent-ui-request-start-time request))
              (end (ogent-ui-request-end-time request)))
    (format "%.1fs" (float-time (time-subtract end start)))))

(defun ogent-ui--update-block-header (request)
  "Update the src block header with current status and timing for REQUEST."
  (let ((block-start (ogent-ui-request-block-start request))
        (model (ogent-ui-request-model request))
        (status (ogent-ui-request-status request)))
    (when (and block-start (marker-buffer block-start))
      (with-current-buffer (ogent-ui-request-buffer request)
        (save-excursion
          (goto-char block-start)
          (when (looking-at "^#\\+begin_src text :model \\([^ \n]+\\).*$")
            (let* ((model-id (plist-get model :id))
                   (backend (plist-get model :backend))
                   (latency (ogent-ui--format-latency request))
                   (status-str (pcase status
                                 ('wait "waiting")
                                 ('tool "tool")
                                 ('type "typing")
                                 ('done "done")
                                 ('error "error")
                                 ('paused "paused")
                                 ('aborted "aborted")
                                 (_ nil)))
                   (new-header (concat "#+begin_src text :model " model-id
                                       (when backend
                                         (format " :backend %s"
                                                 (ogent-ui--backend-label backend)))
                                       (when status-str
                                         (format " :status %s" status-str))
                                       (when latency
                                         (format " :latency %s" latency)))))
              (replace-match new-header t t))))))))

(defun ogent-ui--fold-prompt-block (request)
  "Fold the prompt/context src block for REQUEST after response completes."
  (let ((block-start (ogent-ui-request-block-start request)))
    (when (and block-start (marker-buffer block-start))
      (with-current-buffer (ogent-ui-request-buffer request)
        (ogent-ui--hide-src-block-at block-start)))))

(defun ogent-ui--error-message-string (error-message)
  "Return ERROR-MESSAGE as a display string."
  (ogent-provider-error-message-string error-message))

(defun ogent-ui--provider-access-error-p (error-message)
  "Return non-nil when ERROR-MESSAGE resembles a provider access failure."
  (ogent-provider-access-error-p error-message))

(defun ogent-ui--fallback-dispatch (request)
  "Return a provider fallback dispatch closure for REQUEST.
The closure receives (MODEL-ID CONTEXT) from
`ogent-provider-handle-error' and re-issues REQUEST's original
prompt and preset as a fresh request against MODEL-ID, threading
CONTEXT's :attempt and :tried counters into the new request via
`ogent-ui--fallback-state'."
  (lambda (model-id context)
    (let* ((source (ogent-ui-request-source-buffer request))
           (buffer (if (buffer-live-p source)
                       source
                     (ogent-ui-request-buffer request)))
           (prompt (ogent-ui-request-prompt request)))
      (if (not (and prompt (buffer-live-p buffer)))
          (message
           "ogent: dropped fallback dispatch for %s; original request is gone"
           (ogent-ui-request-id request))
        (with-current-buffer buffer
          (let ((ogent-ui--fallback-state
                 (list :attempt (or (plist-get context :attempt) 0)
                       :tried (plist-get context :tried))))
            (ogent-request prompt (list model-id)
                           (ogent-ui-request-preset request))))))))

(defun ogent-ui--handle-provider-error (request error-message)
  "Run headless provider fallback for failed REQUEST with ERROR-MESSAGE.
Build an `ogent-provider-handle-error' context from REQUEST's model
plist whose :dispatch closure re-issues the original request against
the substitute model.  Accumulated :attempt/:tried state stored by a
prior fallback dispatch is threaded back in, so repeated failures
escalate from retry to failover to the interactive login offer."
  (let* ((model (ogent-ui-request-model request))
         (state (plist-get (ogent-ui-request-context request)
                           :provider-fallback)))
    (ogent-provider-handle-error
     (list :model (plist-get model :id)
           :backend (plist-get model :backend)
           :error error-message
           :dispatch (ogent-ui--fallback-dispatch request)
           :attempt (or (plist-get state :attempt) 0)
           :tried (plist-get state :tried)))))

(defun ogent-ui--maybe-store-zen-result-title (request)
  "Persist a derived Zen result title for REQUEST when Zen support is loaded."
  (when (and (plist-get (ogent-ui-request-context request) :zen-run)
             (fboundp 'ogent-zen-store-result-title))
    (when-let* ((buffer (ogent-ui-request-buffer request))
                (marker (ogent-ui-request-request-heading-pos request)))
      (when (and (buffer-live-p buffer)
                 (markerp marker)
                 (marker-position marker))
        (with-current-buffer buffer
          (ignore-errors
            (ogent-zen-store-result-title (marker-position marker))))))))

(defun ogent-ui--maybe-preview-zen-edit (request)
  "Preview a completed Zen edit REQUEST when it carries edit scope metadata."
  (when (and (plist-get (ogent-ui-request-context request) :zen-edit)
             (fboundp 'ogent-zen-preview-edit-from-request))
    (when-let* ((buffer (ogent-ui-request-buffer request))
                (marker (ogent-ui-request-request-heading-pos request)))
      (when (and (buffer-live-p buffer)
                 (markerp marker)
                 (marker-position marker))
        (with-current-buffer buffer
          (ignore-errors
            (ogent-zen-preview-edit-from-request
             (ogent-ui-request-context request)
             (marker-position marker))))))))

(defun ogent-ui--close-response (request &optional error-message final-status)
  "Finalize REQUEST, optionally including ERROR-MESSAGE.
FINAL-STATUS overrides the default terminal status.
The src block is already closed; this just updates status and folds.
Provides visual feedback via mode-line flash."
  ;; A finishing request is no longer stalled: stop its watchdog.
  (ogent-ui--cancel-watchdog request)
  (if (ogent-ui-request-closed request)
      (remhash (ogent-ui-request-id request) ogent-ui--request-table)
    (when-let ((message (and error-message
                             (ogent-ui--error-message-string error-message))))
      (ogent-ui--insert-error-block request message)
      (ogent-ui--update-status request (or final-status 'error))
      ;; Flash error
      (ogent-theme-flash 'error
                         (format "Request failed: %s"
                                 (truncate-string-to-width
                                  message 50 nil nil "...")))
      ;; Aborts are deliberate; only genuine failures enter the
      ;; headless retry/failover pipeline.
      (unless (eq (or final-status 'error) 'aborted)
        (ogent-ui--handle-provider-error request message)))
    (unless error-message
      (ogent-ui--update-status request (or final-status 'done))
      (ogent-ui--maybe-store-zen-result-title request)
      (ogent-ui--maybe-preview-zen-edit request)
      ;; Flash success with latency info
      (let ((latency (ogent-ui--format-latency request)))
        (ogent-theme-flash 'success
                           (format "Response complete%s"
                                   (if latency (format " (%s)" latency) ""))))
      ;; Record the completion for the analytics eval loop (self-guards
      ;; on `ogent-analytics-enabled'; only successful responses count).
      ;; Analytics is a side channel: never let it break request close.
      (when (fboundp 'ogent-analytics-record-completion)
        (condition-case err
            (let ((model (ogent-ui-request-model request)))
              (ogent-analytics-record-completion
               (or (plist-get model :id) "unknown")
               (or (ogent-ui-request-prompt request) "")
               (or (ogent-ui--response-body-text request) "")
               (let ((preset (ogent-ui-request-preset request)))
                 (and preset (format "%s" preset)))))
          (error
           (message "ogent-analytics: failed to record completion: %s"
                    (error-message-string err))))))
    (ogent-ledger-record-request-finish request error-message)
    ;; Fold the prompt/context src block
    (ogent-ui--fold-prompt-block request)
    (setf (ogent-ui-request-closed request) t)
    ;; Save to history for retry
    (push request ogent-ui--request-history)
    (when (> (length ogent-ui--request-history) ogent-ui-request-history-max)
      (setq ogent-ui--request-history
            (seq-take ogent-ui--request-history ogent-ui-request-history-max)))
    (remhash (ogent-ui-request-id request) ogent-ui--request-table)
    ;; Fontify the response region for syntax highlighting (src blocks, etc.)
    ;; and align any Org tables that were streamed in
    (with-current-buffer (ogent-ui-request-buffer request)
      (let ((start (ogent-ui-request-response-pos request))
            (end (ogent-ui-request-marker request)))
        (when (and start end (markerp end) (marker-position end))
          (let ((end-pos (marker-position end)))
            (font-lock-flush start end-pos)
            ;; Align Org tables in the response region
            (when (derived-mode-p 'org-mode)
              (save-excursion
                (goto-char start)
                (while (re-search-forward "^[ \t]*|" end-pos t)
                  (org-table-align)
                  ;; Move past this table to avoid re-aligning
                  (goto-char (org-table-end)))))))))
    ;; Clean up auto-scroll hook if no more active requests in buffer
    (with-current-buffer (ogent-ui-request-buffer request)
      (unless (cl-some (lambda (r)
                         (eq (ogent-ui-request-buffer r)
                             (current-buffer)))
                       (ogent-ui-active-requests))
        (remove-hook 'post-command-hook #'ogent-ui--auto-scroll-post-command t)))
    ;; Clean up margin indicator after a short visible grace period.
    (when (fboundp 'ogent-status-clear-request)
      (run-with-timer 2.0 nil #'ogent-status-clear-request request))
    (run-hook-with-args 'ogent-after-request-hook
                        (ogent-ui-request-context request))))

(defun ogent-ui--gptel-tool-result-entry (entry)
  "Normalize one gptel tool-result ENTRY to (:name NAME :args ARGS :result RESULT)."
  (if (plist-member entry :result)
      (list :name (plist-get entry :name)
            :args (plist-get entry :args)
            :result (plist-get entry :result))
    (let* ((tool (nth 0 entry))
           (args (nth 1 entry))
           (result (nth 2 entry))
           (name (cond
                  ((and tool (fboundp 'gptel-tool-name))
                   (condition-case nil
                       (gptel-tool-name tool)
                     (error (format "%s" tool))))
                  ((and (consp tool) (plist-get tool :name))
                   (plist-get tool :name))
                  (tool (format "%s" tool))
                  (t "unknown"))))
      (list :name name :args args :result result))))

(defun ogent-ui--make-callback (request-id)
  "Return a gptel callback that streams into REQUEST-ID.
Handles both regular text responses and tool call responses."
  (lambda (text info)
    (when (bound-and-true-p ogent-ui-debug-stream-completion)
      (message "[ogent-debug] callback: request-id=%s text=%S text-type=%s null-text=%s info-keys=%s"
               request-id
               (if (stringp text) (truncate-string-to-width text 20 nil nil "...") text)
               (type-of text)
               (null text)
               (when (listp info)
                 (cl-loop for (k _v) on info by #'cddr collect k))))
    (let ((request (gethash request-id ogent-ui--request-table)))
      (when (bound-and-true-p ogent-ui-debug-stream-completion)
        (message "[ogent-debug] LOOKUP: request-id=%s found=%s table-size=%s info-status=%s"
                 request-id (if request t nil) (hash-table-count ogent-ui--request-table)
                 (plist-get info :status)))
      (when request
        ;; Any callback from gptel is activity: re-arm the inactivity
        ;; watchdog so only a genuine stall trips it.
        (ogent-ui--start-watchdog request)
        ;; Handle gptel tool-call/tool-result responses
        ;; gptel sends (tool-call . pending-calls) when waiting for confirmation
        ;; or (tool-result . results) after execution
        (when (and (consp text) (memq (car text) '(tool-call tool-result)))
          (when (bound-and-true-p ogent-ui-debug-stream-completion)
            (message "[ogent-debug] tool response: type=%s data=%S" (car text) (cdr text)))
          (pcase (car text)
            ('tool-result
             ;; Tools were executed by gptel and fed back into the FSM.
             ;; Display the result, but do not close the request here: gptel
             ;; will make the follow-up model call and stream the final text.
             (dolist (entry (cdr text))
               (let* ((normalized (ogent-ui--gptel-tool-result-entry entry))
                      (tool-name (plist-get normalized :name))
                      (tool-args (plist-get normalized :args))
                      (tool-result (plist-get normalized :result)))
                 (ogent-ledger-record-tool-finish
                  (ogent-ui--tool-ledger-call tool-name tool-args)
                  tool-result nil nil
                  (ogent-ui--tool-ledger-effects tool-name))
                 (when-let ((marker (ogent-ui-request-marker request)))
                   (with-current-buffer (ogent-ui-request-buffer request)
                     (save-excursion
                       (goto-char marker)
                       (ogent-ui--insert-tool-block
                        tool-name tool-args (or tool-result "[No result]"))
                       (set-marker marker (point))))))))
            ('tool-call
             ;; Tools pending confirmation - gptel owns resuming the request
             ;; through the callback it supplies in the pending call entry.
             (ogent-ui--update-status request 'tool))))
        ;; Native gptel reports :tool-use on the first response before it
        ;; enters the TOOL state.  Do not execute these ourselves: doing so
        ;; closes ogent before gptel can inject the tool results and ask the
        ;; model for the final answer.
        (when (and (listp info) (plist-get info :tool-use)
                   (not (and (consp text)
                             (memq (car text) '(tool-call tool-result)))))
          (setf (ogent-ui-request-handled-tool-use request)
                (plist-get info :tool-use))
          (ogent-ui--update-status request 'tool))
        ;; Update status based on what we're receiving
        ;; Note: gptel may pass t rather than a string in some cases
        (when (and (stringp text) (> (length text) 0))
          (unless (eq (ogent-ui-request-status request) 'type)
            (ogent-ui--update-status request 'type))
          (ogent-ui--append-response request text))
        (cond
         ((and (listp info) (plist-get info :error))
          (when (bound-and-true-p ogent-ui-debug-stream-completion)
            (message "[ogent-debug] closing due to error: %s" (plist-get info :error)))
          (ogent-ui--close-response request (plist-get info :error)))
         ;; Done when text is not a string (gptel sends t or nil to signal
         ;; completion).  But a (tool-call ...) / (tool-result ...) cons is
         ;; an intermediate payload, not a completion signal; closing on it
         ;; would drop the model's continuation after the tool round.
         ((and (not (stringp text))
               (not (and (consp text)
                         (memq (car text) '(tool-call tool-result)))))
          (let ((tool-active (and (listp info)
                                  (or (plist-get info :tool-pending)
                                      (plist-get info :tool-use)))))
            (when (bound-and-true-p ogent-ui-debug-stream-completion)
              (message "[ogent-debug] stream complete (text=%s), tool-active=%s, closing=%s"
                       text tool-active (not tool-active)))
            (unless tool-active
              (ogent-ui--close-response request)))))))))

(defvar ogent-ui-debug-stream-completion nil
  "When non-nil, log debug info about stream completion detection.")

(defun ogent-ui--gptel-post-response-handler (start _end)
  "Handle gptel stream completion for ogent requests.
START is the response start position.  This function is added to
`gptel-post-response-functions' as a fallback to detect when streaming
completes, in case the callback-based detection doesn't trigger."
  (when (bound-and-true-p ogent-ui-debug-stream-completion)
    (message "[ogent-debug] post-response-handler called: start=%s buffer=%s"
             start (current-buffer)))
  ;; Find any unclosed request in the current buffer whose marker matches START
  (let ((found-match nil))
    (maphash (lambda (id request)
               (let* ((closed (ogent-ui-request-closed request))
                      (req-buffer (ogent-ui-request-buffer request))
                      (handle (ogent-ui-request-gptel-handle request))
                      (handle-pos (when (markerp handle) (marker-position handle))))
                 (when (bound-and-true-p ogent-ui-debug-stream-completion)
                   (message "[ogent-debug] checking request %s: closed=%s buffer-match=%s handle=%s handle-pos=%s start=%s"
                            id closed (eq req-buffer (current-buffer)) handle handle-pos start))
                 (when (and (not closed)
                            (eq req-buffer (current-buffer))
                            handle-pos
                            (= handle-pos start))
                   (setq found-match t)
                   (when (bound-and-true-p ogent-ui-debug-stream-completion)
                     (message "[ogent-debug] MATCH! closing request %s" id))
                   (ogent-ui--close-response request))))
             ogent-ui--request-table)
    (when (and (bound-and-true-p ogent-ui-debug-stream-completion) (not found-match))
      (message "[ogent-debug] NO MATCH found for start=%s in buffer %s"
               start (current-buffer)))))

(defun ogent-ui--register-gptel-hook ()
  "Register ogent handler with gptel-post-response-functions."
  (add-hook 'gptel-post-response-functions #'ogent-ui--gptel-post-response-handler))

(defun ogent-ui--record-error (request error-message)
  "Record an error for REQUEST with ERROR-MESSAGE."
  (let* ((model (ogent-ui-request-model request))
         (model-id (plist-get model :id))
         (context (ogent-ui-request-context request))
         (context-summary (ogent-ui--format-context context))
         (record (list :timestamp (current-time)
                       :model model-id
                       :error error-message
                       :request-id (ogent-ui-request-id request)
                       :prompt (ogent-ui-request-prompt request)
                       :context context-summary)))
    (push record ogent-ui--error-history)
    ;; Limit history size
    (when (> (length ogent-ui--error-history) 50)
      (setq ogent-ui--error-history (seq-take ogent-ui--error-history 50)))
    record))

(defun ogent-ui--format-error-for-display (error-record)
  "Format ERROR-RECORD as an Org-mode heading with buttons."
  (let* ((timestamp (plist-get error-record :timestamp))
         (model (plist-get error-record :model))
         (error-msg (plist-get error-record :error))
         (request-id (plist-get error-record :request-id))
         (prompt (plist-get error-record :prompt)))
    (format "** [%s] %s\nError: %s\nRequest ID: %s\nPrompt: %s\n\n"
            (format-time-string "%Y-%m-%d %H:%M:%S" timestamp)
            (or model "unknown")
            (or error-msg "unknown error")
            (or request-id "unknown")
            (if prompt
                (truncate-string-to-width prompt 100 nil nil "...")
              "(no prompt)"))))

(defun ogent-ui--surface-error (request error-message)
  "Display error prominently for REQUEST with ERROR-MESSAGE.
Records the error and displays it in the *ogent-errors* buffer."
  (ogent-ui--record-error request error-message)
  (ogent-ui--update-error-buffer))

(defun ogent-ui--update-error-buffer ()
  "Update the *ogent-errors* buffer with current error history."
  (let ((buffer (get-buffer-create ogent-errors-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert "#+title: ogent Errors\n\n")
        (insert "* Error History\n\n")
        (if ogent-ui--error-history
            (dolist (error-record ogent-ui--error-history)
              (insert (ogent-ui--format-error-for-display error-record)))
          (insert "No errors recorded.\n"))
        (goto-char (point-min))
        (view-mode 1)))
    ;; Display buffer if not visible
    (unless (and ogent-ui--error-window
                 (window-live-p ogent-ui--error-window)
                 (eq (window-buffer ogent-ui--error-window) buffer))
      (setq ogent-ui--error-window
            (display-buffer buffer
                            '((display-buffer-in-side-window)
                              (side . bottom)
                              (window-height . 8)
                              (preserve-size . (nil . t))))))))

(defun ogent-show-errors ()
  "Display the ogent errors buffer."
  (interactive)
  (ogent-ui--update-error-buffer)
  (select-window ogent-ui--error-window))

(defun ogent-clear-errors ()
  "Clear the ogent error history."
  (interactive)
  (when (yes-or-no-p "Clear all error history? ")
    (setq ogent-ui--error-history nil)
    (let ((buffer (get-buffer ogent-errors-buffer-name)))
      (when buffer
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (org-mode)
            (insert "#+title: ogent Errors\n\n")
            (insert "* Error History\n\nNo errors recorded.\n")
            (goto-char (point-min))))))
    (when (and ogent-ui--error-window
               (window-live-p ogent-ui--error-window))
      (delete-window ogent-ui--error-window)
      (setq ogent-ui--error-window nil))
    (message "Error history cleared")))

(defun ogent-ui--abort-request (request)
  "Abort REQUEST if it's still active."
  (unless (ogent-ui-request-closed request)
    (let ((handle (ogent-ui-request-gptel-handle request)))
      ;; gptel uses buffer-based abort; try if available
      (when (and handle (fboundp 'gptel-abort))
        (ignore-errors
          (gptel-abort (ogent-ui-request-buffer request)))))
    (ogent-ui--close-response request "Request aborted by user" 'aborted)))

(defun ogent-ui--get-partial-response (request)
  "Extract the partial response text accumulated so far for REQUEST."
  (let ((start (ogent-ui-request-response-pos request))
        (end (ogent-ui-request-marker request))
        (buffer (ogent-ui-request-buffer request)))
    (when (and start end buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        (buffer-substring-no-properties
         (if (markerp start) (marker-position start) start)
         (if (markerp end) (marker-position end) end))))))

(defun ogent-ui--pause-request (request)
  "Pause REQUEST, storing its partial response for later resume.
Stops the HTTP stream but keeps the request in a resumable state."
  (unless (or (ogent-ui-request-closed request)
              (eq (ogent-ui-request-status request) 'paused))
    ;; Store partial response before aborting
    (let ((partial (ogent-ui--get-partial-response request)))
      (setf (ogent-ui-request-paused-response request) partial))
    ;; Abort the gptel connection
    (let ((handle (ogent-ui-request-gptel-handle request)))
      (when (and handle (fboundp 'gptel-abort))
        (ignore-errors
          (gptel-abort (ogent-ui-request-buffer request)))))
    ;; Mark as paused (not closed - can be resumed)
    (ogent-ui--update-status request 'paused)
    ;; Insert pause indicator in buffer
    (let ((marker (ogent-ui-request-marker request)))
      (when (and marker (marker-buffer marker))
        (with-current-buffer (ogent-ui-request-buffer request)
          (save-excursion
            (goto-char marker)
            (insert "\n⏸ [Paused - use ogent-resume-request to continue]\n")
            (set-marker marker (point))))))))

(defun ogent-ui--resume-request (request)
  "Resume a paused REQUEST by continuing from where it left off.
Creates a new request with the partial response as context."
  (when (eq (ogent-ui-request-status request) 'paused)
    (let* ((partial (ogent-ui-request-paused-response request))
           (model (ogent-ui-request-model request))
           (preset (ogent-ui-request-preset request))
           (buffer (ogent-ui-request-buffer request))
           ;; Create continuation prompt
           (continuation-prompt
            (format "Continue from where you left off. Your previous partial response was:\n\n%s\n\n---\nPlease continue naturally from this point, completing your response to the original request."
                    (or partial "[No partial response captured]"))))
      ;; Mark old request as resumed (close it)
      (ogent-ui--update-status request 'done)
      (setf (ogent-ui-request-closed request) t)
      (remhash (ogent-ui-request-id request) ogent-ui--request-table)
      ;; Remove the pause indicator
      (let ((marker (ogent-ui-request-marker request)))
        (when (and marker (marker-buffer marker))
          (with-current-buffer buffer
            (save-excursion
              (goto-char marker)
              (when (re-search-backward "⏸ \\[Paused" nil t)
                (delete-region (line-beginning-position)
                               (min (1+ (line-end-position)) (point-max))))))))
      ;; Create new request to continue
      (with-current-buffer buffer
        (goto-char (point-max))
        (ogent-request continuation-prompt
                       (list (plist-get model :id))
                       preset)))))

(defun ogent-abort-request (&optional request-id)
  "Abort the request with REQUEST-ID, or prompt for one if interactive.
When called interactively with a prefix arg, abort all active requests."
  (interactive)
  (if current-prefix-arg
      ;; Abort all
      (let ((requests (ogent-ui-active-requests)))
        (if requests
            (progn
              (dolist (request requests)
                (ogent-ui--abort-request request))
              (message "Aborted %d request(s)" (length requests)))
          (message "No active requests")))
    ;; Abort single request
    (let* ((requests (ogent-ui-active-requests))
           (id (or request-id
                   (when requests
                     (completing-read
                      "Abort request: "
                      (mapcar #'ogent-ui-request-id requests)
                      nil t))))
           (request (and id (gethash id ogent-ui--request-table))))
      (if request
          (progn
            (ogent-ui--abort-request request)
            (message "Aborted request %s" id))
        (message "No request to abort")))))

(defun ogent-pause-request (&optional request-id)
  "Pause the request with REQUEST-ID, or prompt for one if interactive.
Paused requests can be resumed with `ogent-resume-request'.
The partial response is stored for continuation."
  (interactive)
  (let* ((requests (ogent-ui-active-requests))
         (id (or request-id
                 (when requests
                   (completing-read
                    "Pause request: "
                    (mapcar #'ogent-ui-request-id requests)
                    nil t))))
         (request (and id (gethash id ogent-ui--request-table))))
    (if request
        (progn
          (ogent-ui--pause-request request)
          (message "Paused request %s - use ogent-resume-request to continue" id))
      (message "No active request to pause"))))

(defun ogent-ui-paused-requests ()
  "Return a list of all paused requests."
  (let (requests)
    (maphash (lambda (_id request)
               (when (eq (ogent-ui-request-status request) 'paused)
                 (push request requests)))
             ogent-ui--request-table)
    (nreverse requests)))

(defun ogent-resume-request (&optional request-id)
  "Resume a paused request with REQUEST-ID.
Continues from where the request left off by sending a new request
with the partial response as context."
  (interactive)
  (let* ((paused (ogent-ui-paused-requests))
         (id (or request-id
                 (when paused
                   (completing-read
                    "Resume request: "
                    (mapcar #'ogent-ui-request-id paused)
                    nil t))))
         (request (and id (gethash id ogent-ui--request-table))))
    (if (and request (eq (ogent-ui-request-status request) 'paused))
        (progn
          (ogent-ui--resume-request request)
          (message "Resuming request %s" id))
      (message "No paused request to resume"))))

(defun ogent-retry-request (&optional request-id)
  "Retry a failed or completed request with REQUEST-ID.
Re-sends the original prompt with the same model and context."
  (interactive)
  (if ogent-ui--request-history
      (let* ((id (or request-id
                     (completing-read
                      "Retry request: "
                      (mapcar #'ogent-ui-request-id ogent-ui--request-history)
                      nil t)))
             (request (seq-find (lambda (r) (string= (ogent-ui-request-id r) id))
                                ogent-ui--request-history)))
        (when request
          ;; Create a fresh request with the same params
          (ogent-request (ogent-ui-request-prompt request)
                         (list (plist-get (ogent-ui-request-model request) :id))
                         (ogent-ui-request-preset request))
          (message "Retrying request %s" id)))
    (message "No requests in history to retry")))

(provide 'ogent-ui-engine)
;;; ogent-ui-engine.el ends here
