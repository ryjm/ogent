;;; ogent-armory-native.el --- In-process gptel runner for Armory agents -*- lexical-binding: t; -*-

;;; Commentary:
;; Runs Armory agents inside Emacs by driving a gptel tool-use loop
;; instead of spawning an external coding CLI.  The loop sends the
;; composed plan prompt through `gptel-request' with ogent's enabled
;; tools, executes model tool calls through the ogent tool registry
;; while honoring `ogent-tool-approval-check', feeds results back as
;; fabricated conversation turns, and iterates until the model stops
;; calling tools or `ogent-armory-native-max-iterations' is reached.
;; Completion funnels through the same conversation lifecycle the
;; process sentinel uses, so turns, status, session recording, and the
;; conversation index behave identically to CLI-backed runs.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ogent-gptel)
(require 'ogent-models)
(require 'ogent-tool-approval)
(require 'ogent-armory-runner)
(require 'ogent-armory-conversations)
(require 'ogent-ui-toolcalls)

(declare-function gptel-request "ext:gptel-request")
(declare-function gptel-backend-p "ext:gptel-request" t t)
(declare-function gptel-tool-name "ext:gptel-request" t t)

;; Analytics (optional; loaded lazily), mirroring the ogent-ui engine.
(declare-function ogent-analytics-record-completion "ogent-analytics")

(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-cache)
(defvar gptel-tools)
(defvar gptel-use-tools)
(defvar ogent-tools-project-root)

(defgroup ogent-armory-native nil
  "In-process gptel runner for Org Armory agents."
  :group 'ogent-armory-runner
  :prefix "ogent-armory-native-")

(defcustom ogent-armory-native-max-iterations 10
  "Maximum gptel request rounds for one native Armory run.
Each round may return tool calls whose results are fed back as a
new round.  When the cap is reached before the model produces a
final answer, the run finalizes as failed."
  :type 'natnum
  :group 'ogent-armory-native)

;;; Model selection

(defun ogent-armory-native--model (plan)
  "Return the ogent model plist PLAN should run on.
Resolve the plan's :model designator through
`ogent-models-resolve-designator'; fall back to the session default
model when the designator is absent or unknown."
  (let* ((designator (plist-get plan :model))
         (id (and designator
                  (ogent-models-resolve-designator designator))))
    (cond
     (id (ogent-models-ensure id))
     (t
      (when designator
        (message "ogent: unknown native run model %S; using session default"
                 designator))
      (ogent-models-effective-model)))))

;;; Tool-call plumbing

(defun ogent-armory-native--tool-name (call)
  "Return the tool name string for CALL, or nil.
CALL is either a plist with :name (gptel's parsed tool-use shape) or
a gptel pending-call list whose head is a tool object or name."
  (if (keywordp (car-safe call))
      (ogent-tool--name-string (plist-get call :name))
    (let ((tool (car-safe call)))
      (cond
       ((or (stringp tool) (symbolp tool))
        (ogent-tool--name-string tool))
       ((and tool (fboundp 'gptel-tool-name))
        (ignore-errors (gptel-tool-name tool)))))))

(defun ogent-armory-native--tool-args (call)
  "Return the argument plist for CALL."
  (if (keywordp (car-safe call))
      (or (plist-get call :args)
          (plist-get call :input)
          (plist-get call :arguments))
    (cadr call)))

(defun ogent-armory-native--approval (name args)
  "Return `approved' or `denied' for tool NAME with ARGS.
Defer to `ogent-tool-approval-check'; a quit or error raised by an
interactive approval prompt counts as denial, so unattended runs
never execute a tool the policy would not auto-approve."
  (condition-case nil
      (ogent-tool-approval-check name args)
    ((quit error) 'denied)))

(defun ogent-armory-native--execute-tool (plan name args)
  "Execute tool NAME with ARGS for PLAN and return the result.
Delegate to the canonical executor `ogent-ui--execute-tool', which
records tool start/finish to the proof ledger and the debug tool-call
history, inside the plan workspace.  Approval is decided by
`ogent-tool-approval-check' before execution; the executor does not
re-check it."
  (let* ((tool-symbol (ogent-tool--name-symbol name))
         (spec (and tool-symbol (ogent-tool-spec-get tool-symbol))))
    (cond
     ((not (functionp (plist-get spec :function)))
      (format "Unknown tool: %s" name))
     ((eq (ogent-armory-native--approval name args) 'denied)
      (format "Tool %s denied by approval policy" name))
     (t
      (let* ((workspace (plist-get plan :workspace))
             (default-directory (or workspace default-directory))
             (ogent-tools-project-root workspace))
        (ogent-ui--execute-tool name args))))))

;;; Transcript and fabricated output

(defun ogent-armory-native--record (state entry)
  "Prepend transcript ENTRY to STATE."
  (plist-put state :transcript (cons entry (plist-get state :transcript))))

(defun ogent-armory-native--record-pending-text (state)
  "Move STATE's pending model text into the transcript."
  (let ((text (plist-get state :pending-text)))
    (plist-put state :pending-text nil)
    (when (and text (not (string-blank-p text)))
      (ogent-armory-native--record state (list :type 'text :text text)))))

(defun ogent-armory-native--format-entry (entry)
  "Return the fabricated output block for transcript ENTRY."
  (pcase (plist-get entry :type)
    ('tool-call
     (format "[tool %d] %s %s\n=> %s"
             (or (plist-get entry :iteration) 0)
             (plist-get entry :name)
             (or (plist-get entry :args) "()")
             (or (plist-get entry :result) "")))
    (_ (or (plist-get entry :text) ""))))

(defun ogent-armory-native--output (state)
  "Return the fabricated process-output equivalent for STATE.
Tool transcript blocks come first, mirroring CLI stdout, with the
model's final text last so end-anchored contract footers parse."
  (mapconcat #'ogent-armory-native--format-entry
             (reverse (plist-get state :transcript))
             "\n\n"))

;;; Live round streaming

(defun ogent-armory-native--stream-buffer (state)
  "Return a live buffer already visiting STATE's conversation file.
Return nil when no buffer visits it; native runs never open one."
  (let* ((plan (plist-get state :plan))
         (file (plist-get plan :conversation-file))
         (buffer (and file (get-file-buffer file))))
    (and buffer (buffer-live-p buffer) buffer)))

(defun ogent-armory-native--stream-marker (state buffer)
  "Return STATE's streaming insertion marker inside BUFFER.
Create the marker at BUFFER's current end (the running turn's
position) on first use; the insertion type keeps it after each
inserted chunk so rounds append in order."
  (let ((marker (plist-get state :stream-marker)))
    (unless (and (markerp marker)
                 (eq (marker-buffer marker) buffer))
      (setq marker (make-marker))
      (set-marker-insertion-type marker t)
      (set-marker marker (with-current-buffer buffer (point-max)) buffer)
      (plist-put state :stream-marker marker))
    marker))

(defun ogent-armory-native--stream-text (state text)
  "Echo round TEXT live into a buffer visiting STATE's conversation file.
Insert at STATE's stream marker only when such a buffer already
exists; the conversation file itself is never written here, so the
canonical finalize write stays the only file mutation.  Insertion is
read-only-safe, takes no file lock, and leaves the buffer's modified
flag and undo list untouched, keeping a later revert against the
finalized file clean."
  (when (and text (not (string-empty-p text)))
    (when-let ((buffer (ogent-armory-native--stream-buffer state)))
      (let ((marker (ogent-armory-native--stream-marker state buffer)))
        (with-current-buffer buffer
          (save-excursion
            (goto-char marker)
            (let ((inhibit-read-only t)
                  (create-lockfiles nil)
                  (buffer-undo-list t)
                  (modified (buffer-modified-p)))
              (insert text)
              (restore-buffer-modified-p modified))))))))

(defun ogent-armory-native--stream-release (state)
  "Detach STATE's streaming marker, if any."
  (let ((marker (plist-get state :stream-marker)))
    (when (markerp marker)
      (set-marker marker nil))
    (plist-put state :stream-marker nil)))

;;; Fabricated conversation turns

(defun ogent-armory-native--assistant-turn (text results)
  "Return the fabricated assistant turn for round TEXT and tool RESULTS.
RESULTS is a list of (NAME . RESULT) conses."
  (string-join
   (delq nil
         (cons (when (and text (not (string-blank-p text))) text)
               (mapcar (lambda (result)
                         (format "[tool-call] %s" (car result)))
                       results)))
   "\n"))

(defun ogent-armory-native--results-turn (results)
  "Return the user turn feeding tool RESULTS back to the model."
  (concat
   "Tool results:\n\n"
   (mapconcat (lambda (result)
                (format "[%s]\n%s" (car result) (cdr result)))
              results
              "\n\n")
   "\n\nContinue the task with these results.  When no more tools are"
   " needed, reply with your final answer."))

;;; Native session resume

(defun ogent-armory-native--resume-messages (plan)
  "Return the stored conversation of PLAN as a gptel message list.
Native resume reloads the turns already persisted in the canonical
conversation Org store: turn bodies come back oldest first, matching
the user/assistant alternation `gptel-request' expects, and the new
prompt is appended by the caller.  Return nil for a fresh
conversation.  A resumed conversation is a new run over old context:
the iteration budget starts fresh, while stored turn numbering
continues through the usual append-turn path."
  (let ((root (plist-get plan :root))
        (conversation-id (plist-get plan :conversation-id)))
    (when (and root conversation-id
               (file-exists-p (ogent-armory-conversation-file
                               root conversation-id)))
      (mapcar (lambda (turn) (or (plist-get turn :content) ""))
              (ogent-armory-conversation-read-turns root conversation-id)))))

;;; Lifecycle

(defun ogent-armory-native--finalize-write (plan output error-text exit-status)
  "Run the runner finalize for PLAN, tolerating a visiting buffer.
The canonical finalize path rewrites the conversation file several
times; when live streaming echoed rounds into a buffer visiting it,
that buffer's stale modtime would raise Emacs's supersession prompt
mid-write.  The run owns the file, so the prompt is suppressed for
the conversation file alone.  OUTPUT, ERROR-TEXT, and EXIT-STATUS
pass through unchanged; return the finalized conversation file."
  ;; `ask-user-about-supersession-threat' lives in userlock.el, which
  ;; has no feature and autoloads on first use; force the load now so
  ;; the shadowing below is not clobbered by a mid-write autoload.
  (unless (fboundp 'userlock--check-content-unchanged)
    (load "userlock" nil t))
  (let ((conversation-file
         (when-let ((file (plist-get plan :conversation-file)))
           (expand-file-name file)))
        (ask (symbol-function 'ask-user-about-supersession-threat)))
    (cl-letf (((symbol-function 'ask-user-about-supersession-threat)
               (lambda (filename)
                 (unless (and conversation-file
                              (equal (expand-file-name filename)
                                     conversation-file))
                   (funcall ask filename)))))
      (ogent-armory-runner--finalize-conversation
       plan output error-text exit-status))))

(defun ogent-armory-native--finalize-refresh (file)
  "Revert an unmodified buffer visiting FILE onto the finalized content.
Streaming never marks the visiting buffer modified, so after the
canonical write the buffer swaps its transient round echoes for the
authoritative conversation record.  A buffer the user edited is left
alone."
  (when-let ((buffer (and file (get-file-buffer file))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless (buffer-modified-p)
          (revert-buffer :ignore-auto :noconfirm :preserve-modes))))))

(defun ogent-armory-native--finalize (state exit-status error-text)
  "Finalize STATE's conversation with EXIT-STATUS and ERROR-TEXT.
Reuse the runner's sentinel finalize path so turns, status, and the
conversation index behave exactly like a CLI-backed run.  Return the
conversation file, or nil when STATE already finished."
  (unless (plist-get state :finished)
    (plist-put state :finished t)
    (ogent-armory-native--stream-release state)
    (let* ((plan (plist-get state :plan))
           (output (ogent-armory-native--output state)))
      (plist-put plan :duration
                 (format "%.2fs"
                         (- (float-time) (plist-get state :started-at))))
      (let ((file (ogent-armory-native--finalize-write
                   plan output error-text exit-status)))
        (ogent-armory-runner--capture-actions plan output exit-status)
        (ogent-armory-native--finalize-refresh file)
        (plist-put state :conversation-file file)
        (message "Armory agent finished: %s (native gptel)" file)
        file))))

(defun ogent-armory-native--record-completion (state response)
  "Record RESPONSE for STATE in the analytics eval loop.
Mirror the ogent-ui engine's request close: only successful
completions count, `ogent-analytics-record-completion' self-guards on
`ogent-analytics-enabled', and analytics is a side channel that must
never break finalization.  Analytics is soft-required here so direct
users of this module (without the ogent umbrella) still share the
eval loop."
  (require 'ogent-analytics nil t)
  (when (fboundp 'ogent-analytics-record-completion)
    (condition-case err
        (ogent-analytics-record-completion
         (or (plist-get (plist-get state :model) :id) "unknown")
         (or (plist-get (plist-get state :plan) :prompt) "")
         (or response ""))
      (error
       (message "ogent-analytics: failed to record completion: %s"
                (error-message-string err))))))

(defun ogent-armory-native--complete (state)
  "Finalize STATE successfully with its pending model text."
  (let ((text (or (plist-get state :pending-text) "")))
    (ogent-armory-native--record-pending-text state)
    (ogent-armory-native--record-completion state text)
    (ogent-armory-native--finalize state 0 nil)))

(defun ogent-armory-native--fail (state error-text)
  "Finalize STATE as failed with ERROR-TEXT."
  (ogent-armory-native--record-pending-text state)
  (ogent-armory-native--finalize state 1 error-text))

(defun ogent-armory-native--iteration-cap-text ()
  "Return the error text for a run stopped at the iteration cap."
  (format "native run stopped: %d iterations reached without a final answer (ogent-armory-native-max-iterations)"
          ogent-armory-native-max-iterations))

;;; Request loop

(defun ogent-armory-native--send (state)
  "Issue the next gptel round for STATE.
Bind the resolved backend, model, and ogent's enabled tools around
`gptel-request'; the callback drives the tool-use loop."
  (let* ((model (plist-get state :model))
         (model-id (plist-get model :id))
         (backend (ogent-gptel-resolve-backend model))
         (messages (plist-get state :messages)))
    (when (and backend
               (fboundp 'gptel-backend-p)
               (not (gptel-backend-p backend)))
      (user-error
       "Backend %S for model %s is not loaded; require the backend module"
       (plist-get model :backend) model-id))
    (ogent-gptel-ensure-model-on-backend model backend)
    (ogent-models-apply-gptel-props model)
    (let* ((tools (ogent-tools-enabled-list))
           (gptel-backend backend)
           (gptel-model model-id)
           (gptel-cache ogent-gptel-cache)
           (gptel-tools (or tools (and (boundp 'gptel-tools) gptel-tools)))
           (gptel-use-tools (and tools t)))
      (plist-put state :handle
                 (gptel-request
                  (if (cdr messages) messages (car messages))
                  :stream nil
                  :callback (ogent-armory-native--callback state))))))

(defun ogent-armory-native--send-guarded (state)
  "Send the next round for STATE, finalizing as failed on errors."
  (condition-case err
      (ogent-armory-native--send state)
    (error
     (ogent-armory-native--fail state (error-message-string err)))))

(defun ogent-armory-native--continue (state results)
  "Feed tool RESULTS back to the model for STATE and iterate.
Finalize as failed instead when the next round would exceed
`ogent-armory-native-max-iterations'."
  (let ((iteration (1+ (plist-get state :iteration)))
        (text (plist-get state :round-text)))
    (plist-put state :round-text nil)
    (if (> iteration ogent-armory-native-max-iterations)
        (ogent-armory-native--fail
         state (ogent-armory-native--iteration-cap-text))
      (plist-put state :iteration iteration)
      (plist-put state :messages
                 (append (plist-get state :messages)
                         (list (ogent-armory-native--assistant-turn
                                text results)
                               (ogent-armory-native--results-turn results))))
      (ogent-armory-native--send-guarded state))))

(defun ogent-armory-native--handle-tool-calls (state tool-calls)
  "Run each of TOOL-CALLS for STATE through ogent's tool machinery, then iterate."
  (let ((plan (plist-get state :plan))
        (iteration (plist-get state :iteration))
        (results nil))
    (plist-put state :round-text (plist-get state :pending-text))
    (ogent-armory-native--record-pending-text state)
    (dolist (call tool-calls)
      (let* ((name (ogent-armory-native--tool-name call))
             (args (ogent-armory-native--tool-args call))
             (result (if name
                         (ogent-armory-native--execute-tool plan name args)
                       "Malformed tool call: missing name")))
        (ogent-armory-native--record
         state (list :type 'tool-call
                     :iteration iteration
                     :name (or name "unknown")
                     :args args
                     :result result))
        (push (cons (or name "unknown") result) results)))
    (ogent-armory-native--continue state (nreverse results))))

(defun ogent-armory-native--handle-tool-results (state results)
  "Record RESULTS that gptel executed itself for STATE.
This path only runs under a real gptel whose tool FSM auto-ran
tools it registered without :confirm (the same set ogent
auto-approves).  gptel continues the request on its own, so only
count the round; past the cap, mark the run failed so any late
callbacks are ignored."
  (let ((iteration (plist-get state :iteration)))
    (dolist (entry results)
      (let ((result (if (keywordp (car-safe entry))
                        (plist-get entry :result)
                      (caddr entry))))
        (ogent-armory-native--record
         state (list :type 'tool-call
                     :iteration iteration
                     :name (or (ogent-armory-native--tool-name entry)
                               "unknown")
                     :args (ogent-armory-native--tool-args entry)
                     :result (if (stringp result)
                                 result
                               (format "%S" result))))))
    (if (>= iteration ogent-armory-native-max-iterations)
        (ogent-armory-native--fail
         state (ogent-armory-native--iteration-cap-text))
      (plist-put state :iteration (1+ iteration)))))

(defun ogent-armory-native--callback (state)
  "Return a gptel callback driving the native loop for STATE."
  (lambda (response info)
    (unless (plist-get state :finished)
      (cond
       ;; Model text.  Final unless this round still has tool use in
       ;; flight (mirrors the ogent-ui engine's :tool-use check).
       ((stringp response)
        (ogent-armory-native--stream-text state response)
        (plist-put state :pending-text
                   (concat (or (plist-get state :pending-text) "")
                           response))
        (unless (or (plist-get info :tool-use)
                    (plist-get info :tool-pending))
          (ogent-armory-native--complete state)))
       ;; Model requested tools: run them and feed results back.
       ((eq (car-safe response) 'tool-call)
        (ogent-armory-native--handle-tool-calls state (cdr response)))
       ;; Real gptel executed auto-approved tools itself.
       ((eq (car-safe response) 'tool-result)
        (ogent-armory-native--handle-tool-results state (cdr response)))
       ;; Abort or request error.
       ((null response)
        (ogent-armory-native--fail
         state
         (let ((status (plist-get info :status))
               (err (plist-get info :error)))
           (if (or err status)
               (format "gptel request failed: %s" (or err status))
             "gptel request failed"))))))))

(defun ogent-armory-native-start (plan)
  "Run PLAN in-process through a gptel tool-use loop.
Create the canonical conversation, issue the first request round
asynchronously, and return the run state plist.  The gptel callback
finalizes the conversation through the runner's sentinel path, so
callers never block on the model."
  (let ((state (list :plan plan
                     :model (ogent-armory-native--model plan)
                     :messages (append
                                (ogent-armory-native--resume-messages plan)
                                (list (plist-get plan :prompt)))
                     :iteration 1
                     :transcript nil
                     :pending-text nil
                     :round-text nil
                     :stream-marker nil
                     :handle nil
                     :finished nil
                     :conversation-file nil
                     :started-at (float-time))))
    (when ogent-armory-runner-ensure-beads-redirect
      (ogent-issues-bd-ensure-worktree-redirect (plist-get plan :workspace)))
    (plist-put plan :conversation-file
               (ogent-armory-runner--create-conversation
                plan (ogent-armory-runner--iso-now)))
    (ogent-armory-native--send-guarded state)
    state))

(provide 'ogent-armory-native)

;;; ogent-armory-native.el ends here
