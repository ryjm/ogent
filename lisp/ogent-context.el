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

;; Forward declaration for companion linking
(declare-function ogent-companion-source-buffer "ogent-companion")

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

;;; Source Buffer Context (non-Org modes)

(cl-defstruct ogent-source-context
  "Context from a source code buffer."
  buffer file mode content region-start region-end)

(defun ogent-context--build-source-context (buffer &optional region-start region-end)
  "Build a source context plist from BUFFER.
If REGION-START and REGION-END are provided, include the selected region."
  (with-current-buffer buffer
    (let* ((file (buffer-file-name))
           (mode (symbol-name major-mode))
           (content (if (and region-start region-end)
                        (buffer-substring-no-properties region-start region-end)
                      (buffer-substring-no-properties (point-min) (point-max)))))
      (make-ogent-source-context
       :buffer buffer
       :file file
       :mode mode
       :content content
       :region-start region-start
       :region-end region-end))))

(defun ogent-context--format-source-context (source-ctx)
  "Format SOURCE-CTX as a string for the prompt."
  (let ((file (or (ogent-source-context-file source-ctx) "(unsaved)"))
        (mode (ogent-source-context-mode source-ctx))
        (content (ogent-source-context-content source-ctx))
        (region-start (ogent-source-context-region-start source-ctx))
        (region-end (ogent-source-context-region-end source-ctx)))
    (format "Source File: %s\nMode: %s\n%s\n```\n%s\n```"
            (file-name-nondirectory file)
            mode
            (if (and region-start region-end)
                (format "Selected region (lines %d-%d):"
                        (line-number-at-pos region-start)
                        (line-number-at-pos region-end))
              "Full buffer:")
            content)))

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

;;;###autoload
(defun ogent-context-build-for-buffer (&optional buffer region-start region-end)
  "Build context from BUFFER, handling both Org and non-Org modes.
For Org buffers, builds standard Org context.
For non-Org buffers, builds source context with optional region.
Returns a plist with :source-context for non-Org or standard Org context keys."
  (let ((buf (or buffer (current-buffer))))
    (with-current-buffer buf
      (if (derived-mode-p 'org-mode)
          ;; Org buffer: use standard context building
          (condition-case nil
              (ogent-context-build)
            ;; If no heading found, return minimal context
            (error (list :root nil :ancestors nil :handles nil :dependencies nil)))
        ;; Non-Org buffer: build source context
        (let ((source-ctx (ogent-context--build-source-context
                           buf region-start region-end)))
          (list :source-context source-ctx
                :root nil
                :ancestors nil
                :handles nil
                :dependencies nil))))))

;;;###autoload
(defun ogent-context-build-with-source (source-buffer &optional region-start region-end)
  "Build combined context from SOURCE-BUFFER and current Org buffer.
The current buffer should be an Org companion buffer.
SOURCE-BUFFER is the code buffer the user is editing.
Returns context with both Org structure (if any) and source code."
  (let ((source-ctx (when (and source-buffer
                               (buffer-live-p source-buffer)
                               (not (with-current-buffer source-buffer
                                      (derived-mode-p 'org-mode))))
                      (ogent-context--build-source-context
                       source-buffer region-start region-end)))
        (org-ctx (when (derived-mode-p 'org-mode)
                   (condition-case nil
                       (ogent-context-build)
                     (error nil)))))
    (list :source-context source-ctx
          :root (plist-get org-ctx :root)
          :ancestors (plist-get org-ctx :ancestors)
          :handles (plist-get org-ctx :handles)
          :dependencies (plist-get org-ctx :dependencies))))

(provide 'ogent-context)

;;; ogent-context.el ends here
