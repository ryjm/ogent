;;; ogent-ui.el --- UI commands for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides prompt dispatch, request handling, and context previews.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'subr-x)
(require 'transient)
(require 'ogent-context)
(require 'ogent-core)
(require 'ogent-codemap)
(require 'ogent-models)
(require 'ogent-gptel)
(require 'ogent-prompts)
(require 'ogent-companion)
(require 'ogent-tool-effects)
(require 'ogent-tool-approval)
(require 'ogent-ledger)
(require 'ogent-provider-fallback)
(require 'ogent-ui-status)
(require 'ogent-ui-theme)

;; Extracted ogent UI submodules (dependency order).
(require 'ogent-ui-core)
(require 'ogent-ui-format)
(require 'ogent-ui-toolcalls)
(require 'ogent-ui-engine)
(require 'ogent-ui-send)
(require 'ogent-ui-preview)
(require 'ogent-ui-dispatch)

;; Forward declarations for source context
(declare-function ogent-context-build-with-source "ogent-context")
(declare-function ogent-context--format-source-context "ogent-context")
(declare-function ogent-context-render-prompt "ogent-context")

;; Forward declarations for Zen presentation
(declare-function ogent-run-subtree "ogent-zen" (&optional models preset templates))
(declare-function ogent-zen-rerun "ogent-zen" ())
(declare-function ogent-zen-run-region
                  "ogent-zen" (question &optional models preset templates))
(declare-function ogent-zen-edit-dwim
                  "ogent-zen" (instruction &optional models preset templates))
(declare-function ogent-zen-apply-last-edit "ogent-zen" ())
(declare-function ogent-zen-refresh "ogent-zen" (&optional begin end))
(declare-function ogent-zen-refresh-at "ogent-zen" (position))
(declare-function ogent-zen-after-insert "ogent-zen" (request-pos))
(declare-function ogent-zen-store-result-title "ogent-zen" (request))
(declare-function ogent-zen-preview-edit-from-request
                  "ogent-zen" (context request-pos))
(declare-function ogent-zen--heading-point "ogent-zen" () t)
(declare-function ogent-zen--context-transform "ogent-zen" (context point) t)
(declare-function ogent-zen--tool-record-active-p "ogent-zen" ())
(declare-function ogent-zen-record-tool-call
                  "ogent-zen" (name args result &optional status context))
(declare-function ogent-zen-tool-record-append "ogent-zen" (record chunk))
(declare-function ogent-zen-tool-record-finish
                  "ogent-zen" (record status &optional detail))
(defvar ogent-zen-tool-calls-inline)
(declare-function org-fold-region "org-fold" (from to flag &optional spec))
(defvar ogent-zen-mode)
(defvar ogent-tools-project-root)
;; cl-defstruct accessors (fileonly: generated, not findable by check-declare)
(declare-function ogent-pinned-item-type "ogent-context" t t)
(declare-function ogent-pinned-item-label "ogent-context" t t)
(declare-function ogent-pinned-item-content "ogent-context")
(declare-function ogent-pinned-context-string "ogent-context")
(declare-function ogent-pin-dwim "ogent-context")
(declare-function ogent-list-pinned "ogent-context")
(declare-function ogent-pinned-count "ogent-context")
(declare-function ogent-edit-display-all "ogent-edit-display")
(declare-function ogent-edit-inline-diff-available-p "ogent-edit-display")
(declare-function ogent-edit--generate-id "ogent-edit-format")
(declare-function make-ogent-edit "ogent-edit-format" t t)
(autoload 'ogent-edit-menu "ogent-edit" nil t)
(autoload 'ogent-ai-speed-edit "ogent-edit" nil t)
(autoload 'ogent-fix-buffer-diagnostics "ogent-edit" nil t)
(autoload 'ogent-fix-diagnostic "ogent-edit" nil t)
(autoload 'ogent-quick-edit "ogent-edit" nil t)
(autoload 'ogent-issues "ogent-issues" nil t)
(autoload 'ogent-session-save "ogent-session" nil t)
(autoload 'ogent-session-load "ogent-session" nil t)
(autoload 'ogent-session-list "ogent-session" nil t)
(autoload 'ogent-debug-mode "ogent-debug" nil t)
(autoload 'ogent-onboard-login-different-provider "ogent-onboard" nil t)

(declare-function ogent-describe-bindings "ogent-keys")

(defvar ogent-edit-display-method)

;; Silence byte-compiler for functions that may not be loaded at compile time
(declare-function ogent-presets-available "ogent-models")
(declare-function ogent-preset-get "ogent-models")
(declare-function ogent-gptel-ensure-model-on-backend "ogent-gptel" (model backend))
;; gptel integration
(declare-function gptel-backend-name "ext:gptel")
(declare-function gptel-backend-models "ext:gptel")
(declare-function gptel--model-name "ext:gptel")
(declare-function gptel-backend-p "ext:gptel")
(declare-function gptel-tool-name "ext:gptel-request" (tool))
(defvar gptel--known-backends)
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-cache)
(defvar gptel-stream)
(defvar gptel-tools)
(defvar gptel-use-tools)

;; OAuth integration - for detecting when system message is locked
(declare-function ogent-anthropic-oauth-using-bearer-p "ogent-anthropic-oauth")

;; ogent-tools integration
(declare-function ogent-tools-enabled-list "ogent-models")
(declare-function ogent-tool-spec-get "ogent-models")
(declare-function ogent-tool--bash-async "ogent-tools")
(declare-function ogent-tools--resolve-path "ogent-tools")
(declare-function ogent-tools--project-root "ogent-tools")

;;; Org-mode Output Formatting








;;; gptel-style Variable Scope Management





;;; Provider/Model Selection Infix








;;; Inline Prompt Infix





;; Forward declaration for ogent-response-function (defined as defcustom later)

;; Request struct must be defined early for setf accessors


;;; Tools Toggle Infix




;;; Preset Selector Infix




;;; Prompt Template Infix




;;; Multi-Model Selection Infix




;;; Direct Send Suffix





;; Note: ogent--suffix-send replaced by ogent--suffix-send-action
;; which includes visual feedback via ogent-theme-flash





























;;;###autoload (autoload 'ogent-context-preview "ogent-ui" nil t)



;;;###autoload (autoload 'ogent-context-preview-toggle "ogent-ui" nil t)

;;;###autoload (autoload 'ogent-ask-context-preview-toggle "ogent-ui" nil t)





;;; Prompt dispatcher descriptions






;;;###autoload (autoload 'ogent-ask-here "ogent-ui" nil t)

;;;###autoload (autoload 'ogent-ask-menu "ogent" nil t)















;;;###autoload (autoload 'ogent-prompt-dispatch "ogent" nil t)




;;; Transcript Navigation





;;;###autoload (autoload 'ogent-navigate "ogent-ui" nil t)

(declare-function gptel-request "ext:gptel-request" (prompt &rest args))







;;; Conversation History














(when (and (boundp 'ogent-response-function)
           (eq ogent-response-function #'ogent-ui-insert-response-block))
  (setq ogent-response-function #'ogent-ui-prepare-response-block))











(declare-function ogent-analytics-start-request "ogent-analytics")
(declare-function ogent-analytics-estimate-tokens "ogent-analytics" (text))
(declare-function ogent-analytics-first-token "ogent-analytics")
(declare-function ogent-analytics-record-completion "ogent-analytics"
                  (model prompt response &optional template))




















;; Register the post-response handler with gptel (both now and after load)

(if (featurep 'gptel)
    (ogent-ui--register-gptel-hook)
  (with-eval-after-load 'gptel
    (ogent-ui--register-gptel-hook)))






(declare-function ogent-debug-log-tool-call "ogent-debug" (tool-call result duration))









;;;###autoload (autoload 'ogent-request "ogent" nil t)

;;; Tool and Reasoning Block Support




;;; Tool Drawer Display









;;; Streaming Tool Drawer Support












;;; Inline Diff Display for Edit Proposals




























;;; Error Collection and Display





;;;###autoload (autoload 'ogent-show-errors "ogent-ui" nil t)

;;;###autoload (autoload 'ogent-clear-errors "ogent-ui" nil t)

;;; Cancellation and Retry


(declare-function gptel-abort "ext:gptel" (buffer))





;;;###autoload (autoload 'ogent-abort-request "ogent-ui" nil t)

;;;###autoload (autoload 'ogent-pause-request "ogent-ui" nil t)


;;;###autoload (autoload 'ogent-resume-request "ogent-ui" nil t)

;;;###autoload (autoload 'ogent-retry-request "ogent-ui" nil t)

(provide 'ogent-ui)

;;; ogent-ui.el ends here
