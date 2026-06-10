;;; ogent-ledger.el --- Append-only proof ledger for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Records request and tool events as inspectable Org data.

;;; Code:

(require 'cl-lib)
(require 'project nil t)
(require 'subr-x)

(defgroup ogent-ledger nil
  "Append-only event ledger for ogent."
  :group 'ogent)

(defcustom ogent-ledger-enabled nil
  "When non-nil, append request and tool events to `ogent-ledger-file'."
  :type 'boolean
  :group 'ogent-ledger)

(defcustom ogent-ledger-file ".ogent/ledger.org"
  "Path to the Org ledger file.
Relative paths are resolved from the current project root."
  :type 'file
  :group 'ogent-ledger)

;; Request struct accessors (fileonly: cl-defstruct-generated)
(declare-function ogent-ui-request-id "ui/ogent-ui" t t)
(declare-function ogent-ui-request-model "ui/ogent-ui" t t)
(declare-function ogent-ui-request-context "ui/ogent-ui" t t)
(declare-function ogent-ui-request-prompt "ui/ogent-ui" t t)
(declare-function ogent-ui-request-buffer "ui/ogent-ui" t t)
(declare-function ogent-ui-request-status "ui/ogent-ui" t t)
(declare-function ogent-ui-request-start-time "ui/ogent-ui" t t)
(declare-function ogent-ui-request-end-time "ui/ogent-ui" t t)

(defun ogent-ledger--project-root ()
  "Return the project root used for relative ledger paths."
  (or (and (fboundp 'project-current)
           (when-let ((project (project-current nil)))
             (project-root project)))
      default-directory))

(defun ogent-ledger--file ()
  "Return the absolute ledger file path."
  (if (file-name-absolute-p ogent-ledger-file)
      ogent-ledger-file
    (expand-file-name ogent-ledger-file (ogent-ledger--project-root))))

(defun ogent-ledger--time-string (&optional time)
  "Return TIME formatted for the ledger."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z" (or time (current-time))))

(defun ogent-ledger--date-string (&optional time)
  "Return TIME formatted as a calendar date."
  (format-time-string "%Y-%m-%d" (or time (current-time))))

(defun ogent-ledger-sanitize (value)
  "Return VALUE in a printable, low-surprise shape."
  (cond
   ((bufferp value) (list :buffer (buffer-name value)))
   ((markerp value)
    (list :marker (marker-position value)
          :buffer (when-let ((buffer (marker-buffer value)))
                    (buffer-name buffer))))
   ((hash-table-p value)
    (let (pairs)
      (maphash (lambda (key val)
                 (push (cons (ogent-ledger-sanitize key)
                             (ogent-ledger-sanitize val))
                       pairs))
               value)
      (nreverse pairs)))
   ((vectorp value) (vconcat (mapcar #'ogent-ledger-sanitize value)))
   ((consp value)
    (mapcar #'ogent-ledger-sanitize value))
   ((or (stringp value)
        (symbolp value)
        (numberp value)
        (null value))
    value)
   (t (format "%S" value))))

(defun ogent-ledger-hash (value)
  "Return a stable hash for sanitized VALUE."
  (secure-hash 'sha256 (prin1-to-string (ogent-ledger-sanitize value))))

(defun ogent-ledger--append-event (file event)
  "Append EVENT to FILE."
  (make-directory (file-name-directory file) t)
  (let* ((type (plist-get event :type))
         (time (plist-get event :time))
         (hash (plist-get event :hash))
         (date (ogent-ledger--date-string time))
         (coding-system-for-write 'utf-8-unix))
    (with-temp-buffer
      (unless (file-exists-p file)
        (insert "#+title: ogent ledger\n\n"))
      (insert (format "* %s\n" date))
      (insert (format "** %s %s\n" (format-time-string "%H:%M:%S" time) type))
      (insert ":PROPERTIES:\n")
      (insert (format ":OGENT_LEDGER_TYPE: %s\n" type))
      (insert (format ":OGENT_LEDGER_HASH: %s\n" hash))
      (insert ":END:\n")
      (insert "#+begin_src emacs-lisp\n")
      (prin1 event (current-buffer))
      (insert "\n#+end_src\n\n")
      (append-to-file (point-min) (point-max) file))))

(defun ogent-ledger-record (type data)
  "Append a ledger event of TYPE with DATA.
Return the event plist, or nil when the ledger is disabled."
  (when ogent-ledger-enabled
    (let* ((time (current-time))
           (sanitized-data (ogent-ledger-sanitize data))
           (event (list :type type
                        :time time
                        :hash (ogent-ledger-hash
                               (list :type type
                                     :time (ogent-ledger--time-string time)
                                     :data sanitized-data))
                        :data sanitized-data)))
      (ogent-ledger--append-event (ogent-ledger--file) event)
      event)))

(defun ogent-ledger--model-id (model)
  "Return MODEL's identifier."
  (cond
   ((and (listp model) (plist-get model :id))
    (plist-get model :id))
   ((symbolp model) (symbol-name model))
   ((stringp model) model)
   (t (format "%S" model))))

(defun ogent-ledger-record-request-start (request)
  "Record REQUEST start in the ledger."
  (when ogent-ledger-enabled
    (ogent-ledger-record
     'request-start
     (list :id (ogent-ui-request-id request)
           :model (ogent-ledger--model-id (ogent-ui-request-model request))
           :prompt-hash (ogent-ledger-hash (ogent-ui-request-prompt request))
           :context-hash (ogent-ledger-hash (ogent-ui-request-context request))
           :buffer (buffer-name (ogent-ui-request-buffer request))
           :status (ogent-ui-request-status request)))))

(defun ogent-ledger-record-request-finish (request &optional error-message)
  "Record REQUEST finish in the ledger."
  (when ogent-ledger-enabled
    (let ((start (ogent-ui-request-start-time request))
          (end (or (ogent-ui-request-end-time request)
                   (current-time))))
      (ogent-ledger-record
       'request-finish
       (list :id (ogent-ui-request-id request)
             :model (ogent-ledger--model-id (ogent-ui-request-model request))
             :status (ogent-ui-request-status request)
             :duration (when start
                         (float-time (time-subtract end start)))
             :error error-message)))))

(defun ogent-ledger-record-tool-start (tool-call &optional effects)
  "Record TOOL-CALL start in the ledger."
  (ogent-ledger-record
   'tool-start
   (append (copy-sequence tool-call)
           (when effects
             (list :effects effects)))))

(defun ogent-ledger-record-tool-finish (tool-call result error-message duration
                                                  &optional effects)
  "Record TOOL-CALL completion in the ledger."
  (ogent-ledger-record
   'tool-finish
   (append (copy-sequence tool-call)
           (list :result-hash (and result (ogent-ledger-hash result))
                 :error error-message
                 :duration duration)
           (when effects
             (list :effects effects)))))

(provide 'ogent-ledger)

;;; ogent-ledger.el ends here
