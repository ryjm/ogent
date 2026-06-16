;;; ogent-ui.el --- UI commands for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Facade for the ogent UI: requires the extracted submodules (core state,
;; org formatting, tool calls, conversation engine, request send, context
;; preview, and the transient dispatcher) and hosts the two load-time side
;; effects that must run once when the feature loads.

;;; Code:

(require 'ogent-ui-core)
(require 'ogent-ui-format)
(require 'ogent-ui-toolcalls)
(require 'ogent-ui-engine)
(require 'ogent-ui-send)
(require 'ogent-ui-preview)
(require 'ogent-ui-dispatch)

;; Autoloaded entry points; targets preserved from the pre-split file.
;;;###autoload (autoload 'ogent-ask-menu "ogent" nil t)
;;;###autoload (autoload 'ogent-prompt-dispatch "ogent" nil t)
;;;###autoload (autoload 'ogent-request "ogent" nil t)
;;;###autoload (autoload 'ogent-navigate "ogent-ui" nil t)
;;;###autoload (autoload 'ogent-ask-here "ogent-ui" nil t)
;;;###autoload (autoload 'ogent-context-preview "ogent-ui" nil t)
;;;###autoload (autoload 'ogent-context-preview-toggle "ogent-ui" nil t)
;;;###autoload (autoload 'ogent-ask-context-preview-toggle "ogent-ui" nil t)
;;;###autoload (autoload 'ogent-show-errors "ogent-ui" nil t)
;;;###autoload (autoload 'ogent-clear-errors "ogent-ui" nil t)
;;;###autoload (autoload 'ogent-abort-request "ogent-ui" nil t)
;;;###autoload (autoload 'ogent-pause-request "ogent-ui" nil t)
;;;###autoload (autoload 'ogent-resume-request "ogent-ui" nil t)
;;;###autoload (autoload 'ogent-retry-request "ogent-ui" nil t)

;; Migrate any legacy `ogent-response-function' value to the streaming preparer.
(when (and (boundp 'ogent-response-function)
           (eq ogent-response-function #'ogent-ui-insert-response-block))
  (setq ogent-response-function #'ogent-ui-prepare-response-block))

;; Register the gptel post-response hook once gptel is available.
(if (featurep 'gptel)
    (ogent-ui--register-gptel-hook)
  (with-eval-after-load 'gptel
    (ogent-ui--register-gptel-hook)))

(provide 'ogent-ui)
;;; ogent-ui.el ends here
