;;; ogent-context.el --- Org context utilities for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Resolve Org handles and assemble prompt-ready payloads for ogent.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)

(defgroup ogent nil
  "Org-first AI prompting inside Emacs."
  :group 'applications)

(defcustom ogent-context-handle-regexp
  "@\\([A-Za-z0-9_-]+\\)"
  "Regexp that captures handle references inside Org text."
  :type 'string
  :group 'ogent)

(defcustom ogent-context-extra-buffers nil
  "List of buffers searched when resolving handles.
Each entry can be a live buffer or the name of one."
  :type '(repeat (choice buffer string))
  :group 'ogent)

(cl-defstruct ogent-context-node
  title id level begin end content properties buffer)

(defun ogent-context--ensure-org ()
  "Ensure the current buffer is an Org buffer."
  (unless (derived-mode-p 'org-mode)
    (user-error "ogent commands operate inside Org buffers")))

(defun ogent-context--slug (string)
  "Return a kebab-case slug for STRING."
  (let* ((lower (downcase string))
         (slug (replace-regexp-in-string
                "[^a-z0-9]+" "-" lower)))
    (string-trim slug "-" "-")))

(defun ogent-context--element-properties (element buffer)
  "Return an alist of properties for ELEMENT inside BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (org-element-property :begin element))
      (org-entry-properties nil 'standard))))

(defun ogent-context--node-from-element (element buffer)
  "Build an `ogent-context-node' from ELEMENT within BUFFER."
  (let* ((title (org-element-property :raw-value element))
         (level (org-element-property :level element))
         (begin (org-element-property :begin element))
         (end (org-element-property :end element))
         (contents-start (org-element-property :contents-begin element))
         (contents-end (org-element-property :contents-end element))
         (content (when (and contents-start contents-end)
                    (with-current-buffer buffer
                      (buffer-substring-no-properties
                       contents-start contents-end))))
         (properties (ogent-context--element-properties element buffer))
         (id (or (cdr (assoc "OGENT_ID" properties))
                 (cdr (assoc "ID" properties))
                 (ogent-context--slug (or title "")))))
    (make-ogent-context-node :title title
                             :id id
                             :level level
                             :begin begin
                             :end end
                             :content (or content "")
                             :properties properties
                             :buffer buffer)))

(defun ogent-context--ancestor-elements (element)
  "Return a list of ELEMENT's ancestor headline elements."
  (let ((ancestors nil)
        (parent element))
    (while (setq parent (org-element-property :parent parent))
      (when (eq (org-element-type parent) 'headline)
        (push parent ancestors)))
    (nreverse ancestors)))

(defun ogent-context--collect-handles (text)
  "Return a list of unique handles (without the leading @) in TEXT."
  (let (handles)
    (when text
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (while (re-search-forward ogent-context-handle-regexp nil t)
          (push (match-string-no-properties 1) handles))))
    (cl-remove-duplicates (nreverse handles)
                          :test #'string= :from-end t)))

(defun ogent-context--buffers-to-search ()
  "Return the buffers consulted for handle resolution."
  (let ((primary (current-buffer)))
    (cl-remove-duplicates
     (cons primary
           (cl-loop for entry in ogent-context-extra-buffers
                    when (buffer-live-p entry) collect entry
                    when (and (stringp entry)
                              (buffer-live-p (get-buffer entry)))
                    collect (get-buffer entry)))
     :test #'eq)))

(defun ogent-context--match-handle (element buffer handle)
  "Return non-nil when ELEMENT in BUFFER represents HANDLE."
  (let* ((props (ogent-context--element-properties element buffer))
         (stored (cdr (assoc "OGENT_ID" props)))
         (title (org-element-property :raw-value element)))
    (or (and stored (string= (downcase stored)
                             (downcase handle)))
        (and title (string= (ogent-context--slug title)
                            (ogent-context--slug handle))))))

(defun ogent-context--find-in-buffer (handle buffer)
  "Find HANDLE inside BUFFER, returning an element or nil."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (org-element-map (org-element-parse-buffer 'headline) 'headline
          (lambda (el)
            (when (ogent-context--match-handle el buffer handle)
              el))
          nil t)))))

;;;###autoload
(defun ogent-resolve-handle (handle &optional buffers)
  "Return an `ogent-context-node' for HANDLE.
BUFFERS defaults to the current buffer plus `ogent-context-extra-buffers'.
Returns nil when the handle cannot be located."
  (cl-check-type handle string)
  (let ((search-buffers (or buffers (ogent-context--buffers-to-search))))
    (cl-loop for buffer in search-buffers
             for element = (ogent-context--find-in-buffer handle buffer)
             when element
             return (ogent-context--node-from-element element buffer))))

(defun ogent-context--dependency (handle)
  "Return a plist describing HANDLE, resolved when possible."
  (let ((node (ogent-resolve-handle handle)))
    (list :handle handle
          :missing-p (null node)
          :node node)))

;;;###autoload
(defun ogent-context-build (&optional point)
  "Build a structured context payload for the subtree at POINT.
Returns a plist containing :root, :ancestors, :handles, and :dependencies."
  (ogent-context--ensure-org)
  (let* ((origin (or point (point)))
         (element (save-excursion
                    (goto-char origin)
                    (org-back-to-heading t)
                    (org-element-at-point)))
         (node (ogent-context--node-from-element element (current-buffer)))
         (ancestors (mapcar (lambda (el)
                              (ogent-context--node-from-element el (current-buffer)))
                            (ogent-context--ancestor-elements element)))
         (handles (ogent-context--collect-handles (ogent-context-node-content node)))
         (dependencies (mapcar #'ogent-context--dependency handles)))
    (list :root node
          :ancestors ancestors
          :handles handles
          :dependencies dependencies)))

(provide 'ogent-context)

;;; ogent-context.el ends here
