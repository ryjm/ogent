;;; ogent-profile.el --- ELP profiling utilities for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Wrapper around Emacs's built-in ELP profiler for profiling ogent functions.
;; Based on patterns from elisp-handbook.org.
;;
;; Usage:
;;   M-x ogent-profile-start    ; Instrument functions
;;   ... use ogent normally ...
;;   M-x ogent-profile-results  ; View timing data
;;   M-x ogent-profile-stop     ; Remove instrumentation
;;
;; Or use the macro:
;;   (ogent-with-profile
;;     (ogent-context-build)
;;     (ogent-resolve-handle "test"))

;;; Code:

(require 'elp)
(require 'cl-lib)

;;; Configuration

(defvar ogent-profile-functions
  '(;; Context building
    ogent-context-build
    ogent-context-build-for-buffer
    ogent-context-build-with-source
    ogent-context--node-from-element
    ogent-context--element-properties
    ogent-context--ancestor-elements
    ogent-context--collect-handles
    ogent-context--build-source-context
    ;; Handle resolution
    ogent-resolve-handle
    ogent-context--find-in-buffer
    ogent-context--match-handle
    ogent-context--slug
    ogent-context--buffers-to-search
    ;; Companion buffer
    ogent-companion-get-or-create
    ogent-companion--reuse-or-create
    ogent-companion--create-companion
    ogent-companion--get-linked-buffer
    ;; Codemap
    ogent-codemap--project-root
    ogent-codemap--source-files
    ogent-codemap--definitions
    ogent-codemap--render)
  "Functions to instrument for profiling.
Add or remove functions from this list to customize profiling scope.")

(defvar ogent-profile--active nil
  "Non-nil when profiling is currently active.")

;;; Commands

;;;###autoload
(defun ogent-profile-start ()
  "Start profiling ogent functions.
Instruments all functions in `ogent-profile-functions'."
  (interactive)
  (when ogent-profile--active
    (user-error "Profiling already active. Run `ogent-profile-stop' first"))
  ;; Filter to only existing functions
  (let ((existing (cl-remove-if-not #'fboundp ogent-profile-functions)))
    (elp-instrument-list existing)
    (setq ogent-profile--active t)
    (message "Profiling %d ogent functions (of %d configured)"
             (length existing)
             (length ogent-profile-functions))))

;;;###autoload
(defun ogent-profile-results ()
  "Display profiling results without stopping.
Use this to check intermediate results while profiling is active."
  (interactive)
  (unless ogent-profile--active
    (user-error "No profiling session active. Run `ogent-profile-start' first"))
  (elp-results))

;;;###autoload
(defun ogent-profile-reset ()
  "Reset profiling counters without stopping.
Clears accumulated timing data for a fresh measurement."
  (interactive)
  (unless ogent-profile--active
    (user-error "No profiling session active. Run `ogent-profile-start' first"))
  (elp-reset-all)
  (message "Profiling counters reset"))

;;;###autoload
(defun ogent-profile-stop ()
  "Stop profiling and show final results.
Removes instrumentation from all functions."
  (interactive)
  (unless ogent-profile--active
    (user-error "No profiling session active"))
  (elp-results)
  (elp-restore-all)
  (setq ogent-profile--active nil)
  (message "Profiling stopped. Instrumentation removed."))

;;; Macro for scoped profiling

(defmacro ogent-with-profile (&rest body)
  "Execute BODY with profiling enabled, then show results.
Automatically starts profiling, runs BODY, and displays results.
Instrumentation is removed even if BODY signals an error.

Example:
  (ogent-with-profile
    (dotimes (_ 100)
      (ogent-context-build)))"
  (declare (indent 0) (debug t))
  `(progn
     (ogent-profile-start)
     (unwind-protect
         (progn ,@body)
       (ogent-profile-stop))))

;;; Utilities

(defun ogent-profile-add-function (func)
  "Add FUNC to the list of profiled functions.
If profiling is active, instruments the function immediately."
  (interactive "aFunction to profile: ")
  (unless (memq func ogent-profile-functions)
    (push func ogent-profile-functions)
    (when ogent-profile--active
      (elp-instrument-function func))
    (message "Added %s to profiling" func)))

(defun ogent-profile-remove-function (func)
  "Remove FUNC from the list of profiled functions.
If profiling is active, removes instrumentation from the function."
  (interactive
   (list (intern (completing-read "Remove function: "
                                  (mapcar #'symbol-name ogent-profile-functions)
                                  nil t))))
  (when (memq func ogent-profile-functions)
    (setq ogent-profile-functions (delq func ogent-profile-functions))
    (when ogent-profile--active
      (elp-restore-function func))
    (message "Removed %s from profiling" func)))

(defun ogent-profile-list ()
  "Display the list of functions configured for profiling."
  (interactive)
  (with-help-window "*ogent-profile-functions*"
    (princ "Functions configured for ogent profiling:\n\n")
    (dolist (func ogent-profile-functions)
      (princ (format "  %s%s\n"
                     func
                     (if (fboundp func) "" " (not defined)"))))))

(provide 'ogent-profile)

;;; ogent-profile.el ends here
