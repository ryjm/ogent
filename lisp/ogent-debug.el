;;; ogent-debug.el --- Development debugging utilities -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides debugging macros that compile away to nothing in production.
;; Based on patterns from elisp-handbook.org.
;;
;; Usage:
;;   ;; Enable debugging (in init.el or interactively)
;;   (setq ogent-debug-enabled t)
;;
;;   ;; In code:
;;   (defun my-function (arg)
;;     (ogent-debug "Processing arg=%s buffer=%s" arg (current-buffer))
;;     ...)
;;
;;   ;; Output in *Messages*:
;;   ;; [ogent] my-function: Processing arg=foo buffer=#<buffer test.org>
;;
;; When ogent-debug-enabled is nil, the macro expands to nil (zero overhead).

;;; Code:

(require 'cl-lib)

;;; Configuration

(defvar ogent-debug-enabled nil
  "When non-nil, `ogent-debug' macros produce output.
Set to t during development, nil for production.
Changes take effect at compile time for byte-compiled code.")

(defvar ogent-debug-buffer "*ogent-debug*"
  "Buffer name for debug output.
Set to nil to use *Messages* instead.")

;;; Debug Macro

(defmacro ogent-debug (format-string &rest args)
  "Log debug message when `ogent-debug-enabled' is non-nil.
FORMAT-STRING and ARGS are passed to `format'.
The message is prefixed with [ogent] and the calling function name.

This macro compiles to nil when `ogent-debug-enabled' is nil,
so it can be left in production code with zero overhead.

Example:
  (defun ogent-context-build ()
    (ogent-debug \"Building context at point=%s\" (point))
    ...)"
  (declare (indent 1) (debug t))
  (when ogent-debug-enabled
    (let ((fn-name (or (and (boundp 'byte-compile-current-form)
                            byte-compile-current-form)
                       'unknown)))
      `(ogent-debug--log ',fn-name ,format-string ,@args))))

(defun ogent-debug--log (fn-name format-string &rest args)
  "Log a debug message from FN-NAME using FORMAT-STRING and ARGS."
  (let ((msg (format "[ogent] %s: %s"
                     fn-name
                     (apply #'format format-string args))))
    (if ogent-debug-buffer
        (with-current-buffer (get-buffer-create ogent-debug-buffer)
          (goto-char (point-max))
          (insert (format-time-string "%H:%M:%S ") msg "\n"))
      (message "%s" msg))))

;;; Debug with Variable Display

(defmacro ogent-debug-vars (&rest vars)
  "Log the names and values of VARS when debugging is enabled.
Each VAR can be a symbol or an expression.

Example:
  (let ((x 1) (y 2))
    (ogent-debug-vars x y (+ x y)))
  ;; Output: [ogent] fn: x=1 y=2 (+ x y)=3"
  (declare (debug t))
  (when ogent-debug-enabled
    (let ((fn-name (or (and (boundp 'byte-compile-current-form)
                            byte-compile-current-form)
                       'unknown))
          (var-formats (mapcar (lambda (var)
                                 (if (symbolp var)
                                     (format "%s=%%S" var)
                                   (format "%S=%%S" var)))
                               vars)))
      `(ogent-debug--log ',fn-name
                         ,(string-join var-formats " ")
                         ,@vars))))

;;; Conditional Execution

(defmacro ogent-when-debug (&rest body)
  "Execute BODY only when debugging is enabled.
Use for debug-only side effects like assertions or state dumps."
  (declare (indent 0) (debug t))
  (when ogent-debug-enabled
    `(progn ,@body)))

;;; Interactive Commands

;;;###autoload
(defun ogent-debug-enable ()
  "Enable ogent debug output.
Note: This only affects interpreted code. Byte-compiled code
must be recompiled to pick up the change."
  (interactive)
  (setq ogent-debug-enabled t)
  (message "ogent debugging enabled (interpreted code only)"))

;;;###autoload
(defun ogent-debug-disable ()
  "Disable ogent debug output."
  (interactive)
  (setq ogent-debug-enabled nil)
  (message "ogent debugging disabled"))

;;;###autoload
(defun ogent-debug-toggle ()
  "Toggle ogent debug output."
  (interactive)
  (if ogent-debug-enabled
      (ogent-debug-disable)
    (ogent-debug-enable)))

;;;###autoload
(defun ogent-debug-show ()
  "Show the ogent debug buffer."
  (interactive)
  (if ogent-debug-buffer
      (display-buffer (get-buffer-create ogent-debug-buffer))
    (display-buffer "*Messages*")))

;;;###autoload
(defun ogent-debug-clear ()
  "Clear the ogent debug buffer."
  (interactive)
  (when ogent-debug-buffer
    (with-current-buffer (get-buffer-create ogent-debug-buffer)
      (erase-buffer)))
  (message "Debug buffer cleared"))

(provide 'ogent-debug)

;;; ogent-debug.el ends here
