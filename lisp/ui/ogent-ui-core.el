;;; ogent-ui-core.el --- Shared state and contract for ogent UI -*- lexical-binding: t; -*-

;;; Commentary:
;; The request struct, central request table/history, dispatcher
;; selections, the `ogent-response-function' indirection, cross-cutting
;; customs and constants, and the small scope/render helpers shared by
;; every ogent UI module.

;;; Code:

(require 'cl-lib)
(require 'ogent-core)

;; Function-quoted by the response-function setter/default and rendered at
;; call time; cannot be required here (would cycle).
(declare-function ogent-ui-insert-response-block "ogent-ui-format")
(declare-function ogent-ui-prepare-response-block "ogent-ui-engine")
(declare-function ogent-context-render-prompt "ogent-context")
(declare-function ogent-analytics-estimate-tokens "ogent-analytics")

(defcustom ogent-org-format-responses t
  "When non-nil, instruct LLM to format responses as Org-mode.
This adds a system directive to requests when the target buffer
is in Org-mode, ensuring code blocks use #+begin_src syntax,
headings use * rather than #, etc."
  :type 'boolean
  :group 'ogent-mode)

(defcustom ogent-multi-turn-history t
  "When non-nil, replay prior exchanges as conversation history.
Each completed Request/Response pair found in the
transcript buffer before the current request is sent as a prior
user/assistant turn.  The model sees the running conversation, not
only a single-shot prompt.  History is bounded by
`ogent-multi-turn-token-budget'.  When `ogent-gptel-cache' includes
message caching on a cache-capable Anthropic model, the replayed
prefix becomes the cached prompt prefix across turns."
  :type 'boolean
  :group 'ogent-mode)

(defcustom ogent-multi-turn-token-budget 16000
  "Estimated-token budget for replayed conversation history.
When the collected history exceeds this budget, the oldest exchange
pairs are dropped first (see `ogent-ui--compact-history')."
  :type 'integer
  :group 'ogent-mode)

(defcustom ogent-auto-scroll t
  "When non-nil, auto-scroll window to follow streaming responses.
During a streaming response, the window will scroll to show new content
as it arrives.  Auto-scroll stops if the user manually scrolls away from
the bottom, and resumes when they scroll back to the bottom or when a
new request starts."
  :type 'boolean
  :group 'ogent-mode)

(defcustom ogent-stream-tool-output t
  "When non-nil, stream shell command output incrementally.
This shows command output as it arrives rather than waiting for
the command to complete.  Only applies to async-capable tools like bash."
  :type 'boolean
  :group 'ogent-mode)

(defconst ogent-org-format-directive
  "Format your response using Org-mode syntax:
- Use * for headings (not # markdown headings)
- Use #+begin_src LANG / #+end_src for code blocks (not ``` fences)
- Use - or + for unordered lists
- Use 1. for ordered lists
- Use [[url][description]] for links
- Use *bold*, /italic/, =code=, ~verbatim~ for inline formatting
- Use | for tables with |---| separator rows

Do NOT use markdown syntax. Use Org-mode syntax exclusively."
  "System directive instructing the LLM to format output as Org-mode.")

(defvar-local ogent--set-buffer-locally nil
  "When non-nil, set model parameters buffer-locally.")

(defun ogent--set-with-scope (sym value &optional scope)
  "Set SYM to VALUE, buffer-locally if SCOPE is non-nil."
  (if scope
      (set (make-local-variable sym) value)
    (kill-local-variable sym)
    (set sym value)))

(defvar ogent--transient-prompt nil
  "Prompt text set via the transient infix.")

(defvar ogent-ui--selected-preset nil
  "The currently selected preset name (string), or nil for no preset.")

(defvar ogent-ui--selected-templates nil
  "List of selected prompt template IDs for the dispatcher.")

(defvar ogent-ui--selected-models nil
  "List of selected model IDs for multi-model fan-out.
When non-nil, requests are dispatched to all listed models concurrently.")

(defvar ogent-response-function)

(cl-defstruct ogent-ui-request
  id model context prompt buffer marker closed preset
  status start-time end-time gptel-handle source-buffer
  block-start response-pos
  request-heading-pos  ; Marker at the request's headline
  response-heading-level  ; Org level of the response headline
  paused-response  ; Stores partial response when paused for resume
  handled-tool-use  ; Identity of the :tool-use payload already dispatched
  watchdog)  ; Inactivity timer that force-closes a hung request

(defun ogent-ui--set-response-function (symbol value)
  "Setter for `ogent-response-function' that migrates legacy values.
Store VALUE in SYMBOL, mapping the obsolete function to its replacement."
  (set-default symbol
               (if (eq value #'ogent-ui-insert-response-block)
                   #'ogent-ui-prepare-response-block
                 value)))

(defcustom ogent-response-function #'ogent-ui-prepare-response-block
  "Function that prepares an `ogent-ui-request' for streaming responses.
The function receives PROMPT text, a CONTEXT plist from
`ogent-context-build', and the MODEL plist drawn from
`ogent-model-registry'.  It must return an `ogent-ui-request'
object that points at the buffer location where streamed output
should be inserted."
  :type 'function
  :set #'ogent-ui--set-response-function
  :group 'ogent-mode)

(defvar ogent-ui--request-table (make-hash-table :test #'equal)
  "Active gptel requests keyed by their `ogent-ui-request-id'.")

(defvar ogent-ui--request-history nil
  "List of recently closed requests, most recent first.
Used for retry functionality.")

(defvar ogent-ui--request-seq 0
  "Incrementing counter for request identifiers.")

(defcustom ogent-gptel-required-features '(gptel-openai gptel-anthropic)
  "Features that must be loaded so gptel backends can service requests.
Every symbol should name the feature provided by the corresponding
`gptel-*' backend file (for example `gptel-openai').  Extend this list
whenever `ogent-model-registry' gains a new provider so backend structs
exist before `ogent-request' dispatches."
  :type '(repeat symbol)
  :group 'ogent-mode)

(defcustom ogent-shift-response-headings t
  "When non-nil, shift org headings in LLM responses to nest under Response.
LLM responses appear under a Response heading.
When this is enabled, any org headings in the response are shifted
by the active Response heading level.

For example, `* Heading' becomes `**** Heading' (level 4)."
  :type 'boolean
  :group 'ogent-mode)

(defcustom ogent-ui-request-history-max 20
  "Maximum number of closed requests to keep in history."
  :type 'integer
  :group 'ogent-mode)

(defun ogent-ui--render-prompt (prompt context)
  "Render PROMPT and CONTEXT into the final text sent to gptel."
  (ogent-context-render-prompt prompt context))

(defun ogent-ui-token-budget-line (payload model &optional members)
  "Return a token-budget summary for PAYLOAD dispatched to MODEL.
PAYLOAD is the fully rendered prompt text.  MODEL is a model plist
from `ogent-model-registry', or nil when no model is resolvable.
MEMBERS, when an integer greater than 1, is the fan-out member
count and the summary reads \"MEMBERS x ~N tokens\": every member
receives an identical payload, so total prompt cost multiplies by
MEMBERS while each member's request fills its own window with the
single per-member estimate.

The estimate comes from `ogent-analytics-estimate-tokens', a
character heuristic accurate to roughly +/-20%, hence the \"~\"
label.  When MODEL declares a :context-window and the per-member
estimate meets or exceeds it, a truncation warning is appended.  A
model without a :context-window never warns: absence means unknown,
and no limit is ever fabricated."
  (require 'ogent-analytics)
  (let* ((tokens (ogent-analytics-estimate-tokens payload))
         (estimate (if (and (integerp members) (> members 1))
                       (format "%d x ~%d tokens" members tokens)
                     (format "~%d tokens" tokens)))
         (window (plist-get model :context-window)))
    (if (and window (>= tokens window))
        (format "%s (may exceed %s's %d-token context window)"
                estimate (plist-get model :id) window)
      estimate)))

(defun ogent-ui-token-budget-model (models)
  "Return the member of MODELS with the smallest :context-window.
MODELS is a list of model plists.  Members without a :context-window
never win: when no member declares one, return nil so callers fall
through to a warning-free `ogent-ui-token-budget-line'.  The
tightest window drives the fan-out warning because the group shares
one payload and its most constrained member truncates first."
  (let (best best-window)
    (dolist (model models best)
      (let ((window (plist-get model :context-window)))
        (when (and window (or (null best-window) (< window best-window)))
          (setq best model
                best-window window))))))

(defun ogent-ui-active-requests ()
  "Return a list of all active (non-closed) requests."
  (let (requests)
    (maphash (lambda (_id request)
               (unless (ogent-ui-request-closed request)
                 (push request requests)))
             ogent-ui--request-table)
    (nreverse requests)))

(provide 'ogent-ui-core)
;;; ogent-ui-core.el ends here
