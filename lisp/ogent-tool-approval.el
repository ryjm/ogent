;;; ogent-tool-approval.el --- User approval workflow for tools -*- lexical-binding: t; -*-

;;; Commentary:
;; Implements user consent workflow before executing tools with side effects.
;; Checks :confirm flag in tool specs and displays transient menu for approval.
;; Tracks session approvals to avoid re-prompting for the same tool.

;;; Code:

(require 'cl-lib)
(require 'transient)

(defgroup ogent-tool-approval nil
  "Tool approval settings for ogent."
  :group 'ogent)

(defvar ogent-tool-approval--session-approved (make-hash-table :test 'equal)
  "Hash table tracking tools approved for this session.
Keys are tool names (symbols), values are t.")

(defun ogent-tool-approval-required-p (tool-spec)
  "Return non-nil if TOOL-SPEC requires user approval.
Checks for :confirm flag in the spec plist."
  (and tool-spec
       (plist-get tool-spec :confirm)))

(defun ogent-tool-approval--format-args (args)
  "Format ARGS plist for display in approval prompt.
Returns a formatted string with indented key-value pairs."
  (if (not args)
      "  (no arguments)"
    (let ((result ""))
      (while args
        (let ((key (car args))
              (val (cadr args)))
          (setq result
                (concat result
                        (format "  %s: %s\n"
                                (substring (symbol-name key) 1) ; Remove leading :
                                (if (stringp val)
                                    (if (> (length val) 200)
                                        (concat (substring val 0 200) "...")
                                      val)
                                  val))))
          (setq args (cddr args))))
      (substring result 0 -1)))) ; Remove trailing newline

(defvar ogent-tool-approval--current-tool-name nil
  "Tool name for the current approval transient.")

(defvar ogent-tool-approval--current-tool-args nil
  "Tool args for the current approval transient.")

(defvar ogent-tool-approval--current-callback nil
  "Callback function for the current approval transient.
Called with t for approval, nil for rejection.")

(defun ogent-tool-approval--approve ()
  "Approve the current tool execution (one-time)."
  (interactive)
  (when ogent-tool-approval--current-callback
    (funcall ogent-tool-approval--current-callback t))
  (setq ogent-tool-approval--current-tool-name nil
        ogent-tool-approval--current-tool-args nil
        ogent-tool-approval--current-callback nil))

(defun ogent-tool-approval--reject ()
  "Reject the current tool execution."
  (interactive)
  (when ogent-tool-approval--current-callback
    (funcall ogent-tool-approval--current-callback nil))
  (setq ogent-tool-approval--current-tool-name nil
        ogent-tool-approval--current-tool-args nil
        ogent-tool-approval--current-callback nil))

(defun ogent-tool-approval--approve-all-session ()
  "Approve current tool and remember for this session."
  (interactive)
  (when ogent-tool-approval--current-tool-name
    (puthash ogent-tool-approval--current-tool-name t
             ogent-tool-approval--session-approved))
  (ogent-tool-approval--approve))

(defun ogent-tool-approval--reject-all-session ()
  "Reject current tool and remember for this session."
  (interactive)
  (when ogent-tool-approval--current-tool-name
    (puthash ogent-tool-approval--current-tool-name 'rejected
             ogent-tool-approval--session-approved))
  (ogent-tool-approval--reject))

(transient-define-prefix ogent-tool-approval-menu ()
  "Transient menu for tool execution approval."
  [:description
   (lambda ()
     (format "Tool Approval: %s\n\nArguments:\n%s"
             (propertize (or (and ogent-tool-approval--current-tool-name
                                  (symbol-name ogent-tool-approval--current-tool-name))
                             "unknown")
                         'face 'warning)
             (ogent-tool-approval--format-args
              ogent-tool-approval--current-tool-args)))
   ["Actions"
    ("a" "Approve (once)" ogent-tool-approval--approve)
    ("r" "Reject (once)" ogent-tool-approval--reject)]
   ["Session Rules"
    ("A" "Approve all this session" ogent-tool-approval--approve-all-session)
    ("R" "Reject all this session" ogent-tool-approval--reject-all-session)]])

(defun ogent-tool-approval-request (tool-spec args callback)
  "Request approval for TOOL-SPEC with ARGS, calling CALLBACK with result.
CALLBACK is called with t for approval, nil for rejection.

If tool doesn't require approval (:confirm flag is nil or absent),
calls CALLBACK immediately with t.

If tool was approved/rejected for this session, uses cached decision.
Otherwise, displays transient approval menu."
  (let ((tool-name (plist-get tool-spec :name)))
    (cond
     ;; No approval required - execute immediately
     ((not (ogent-tool-approval-required-p tool-spec))
      (funcall callback t))
     
     ;; Check session cache
     ((gethash tool-name ogent-tool-approval--session-approved)
      (let ((cached (gethash tool-name ogent-tool-approval--session-approved)))
        (funcall callback (eq cached t))))
     
     ;; Prompt for approval
     (t
      (setq ogent-tool-approval--current-tool-name tool-name
            ogent-tool-approval--current-tool-args args
            ogent-tool-approval--current-callback callback)
      (ogent-tool-approval-menu)))))

(defun ogent-tool-approval-reset ()
  "Clear all session approval decisions.
Forces re-prompting for all tools that require approval."
  (interactive)
  (clrhash ogent-tool-approval--session-approved)
  (message "Tool approval cache cleared"))

(provide 'ogent-tool-approval)

;;; ogent-tool-approval.el ends here
