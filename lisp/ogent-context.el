;;; ogent-context.el --- Org context utilities for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Resolve Org handles and assemble prompt-ready payloads for ogent.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'thunk)

(defgroup ogent nil
  "Org-first AI prompting inside Emacs."
  :group 'applications)

;; Forward declaration for companion linking
(declare-function ogent-companion-source-buffer "ogent-companion")

;; Forward declarations for codemap handle resolution
(declare-function ogent-codemap-handle-p "ogent-codemap")
(declare-function ogent-codemap-resolve-handle "ogent-codemap")

;; Forward declarations for org-roam integration (optional dependency)
(declare-function org-roam-node-title "ext:org-roam-node")
(declare-function org-roam-node-aliases "ext:org-roam-node")
(declare-function org-roam-node-file "ext:org-roam-node")
(declare-function org-roam-node-point "ext:org-roam-node")
(declare-function org-roam-node-list "ext:org-roam")

(defcustom ogent-context-handle-regexp
  (rx "@" (group (+ (any alnum "_-"))))
  "Regexp that captures handle references inside Org text.
Matches @handle-name where handle can contain alphanumeric, underscore, and hyphen."
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
  ;; Use buffer-local-value for faster variable access (50x speedup)
  (let* ((file (buffer-file-name buffer))
         (mode (symbol-name (buffer-local-value 'major-mode buffer)))
         ;; Content extraction still needs with-current-buffer for point access
         (content (with-current-buffer buffer
                    (if (and region-start region-end)
                        (buffer-substring-no-properties region-start region-end)
                      (buffer-substring-no-properties (point-min) (point-max))))))
    (make-ogent-source-context
     :buffer buffer
     :file file
     :mode mode
     :content content
     :region-start region-start
     :region-end region-end)))

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
First searches open buffers, then org-roam database if available.
Returns nil when the handle cannot be located."
  (cl-check-type handle string)
  (let ((search-buffers (or buffers (ogent-context--buffers-to-search))))
    (or
     ;; Try open buffers first
     (cl-loop for buffer in search-buffers
              for element = (ogent-context--find-in-buffer handle buffer)
              when element
              return (ogent-context--node-from-element element buffer))
     ;; Fall back to org-roam if available
     (when (fboundp 'ogent-context--resolve-via-roam)
       (ogent-context--resolve-via-roam handle)))))

(defun ogent-context--dependency (handle)
  "Return a plist describing HANDLE, resolved when possible.
Handles special cases like @codemap handles."
  ;; Check for codemap handles first
  (if (and (fboundp 'ogent-codemap-handle-p)
           (ogent-codemap-handle-p handle))
      (let ((content (ogent-codemap-resolve-handle handle)))
        (list :handle handle
              :missing-p (null content)
              :node (when content
                      (make-ogent-context-node
                       :title (format "Codemap: %s" handle)
                       :id handle
                       :content content
                       :buffer nil))))
    ;; Standard handle resolution
    (let ((node (ogent-resolve-handle handle)))
      (list :handle handle
            :missing-p (null node)
            :node node))))

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
                               ;; Use buffer-local-value for faster check
                               (not (eq (buffer-local-value 'major-mode source-buffer)
                                        'org-mode)))
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

;;; Lazy Context Building
;;
;; Use thunks to defer expensive context operations until needed.
;; This is useful when the context might not be used (e.g., cached
;; prompts, conditional evaluation).

(defun ogent-context-build-lazy (&optional point)
  "Return a thunk that builds context when forced.
POINT specifies where to build context from.
Use `thunk-force' to get the actual context plist.
Results are cached after first evaluation."
  (thunk-delay (ogent-context-build point)))

(defun ogent-context-build-source-lazy (buffer &optional region-start region-end)
  "Return a thunk that builds source context when forced.
BUFFER is the source buffer, with optional REGION-START and REGION-END.
Use `thunk-force' to get the actual source-context struct."
  (thunk-delay (ogent-context--build-source-context buffer region-start region-end)))

(defmacro ogent-context-with-lazy (bindings &rest body)
  "Evaluate BODY with lazy context BINDINGS.
Each binding is (VAR FORM) where FORM produces context.
VARs are bound to thunks; use `thunk-force' to evaluate.

Example:
  (ogent-context-with-lazy
      ((org-ctx (ogent-context-build))
       (src-ctx (ogent-context--build-source-context buf)))
    (when need-org
      (process (thunk-force org-ctx)))
    (when need-source
      (process (thunk-force src-ctx))))"
  (declare (indent 1) (debug let))
  `(let ,(mapcar (lambda (binding)
                   `(,(car binding) (thunk-delay ,(cadr binding))))
                 bindings)
     ,@body))

;;; Optional org-roam Integration
;;
;; When org-roam is available, handles can be resolved from its database.
;; This allows @handle references to find nodes even when they're not
;; currently open in a buffer.

(with-eval-after-load 'org-roam
  (defun ogent-context--roam-node-matches (node handle)
    "Return non-nil if org-roam NODE matches HANDLE."
    (let ((title (org-roam-node-title node))
          (aliases (org-roam-node-aliases node)))
      (or (string= (ogent-context--slug title)
                   (ogent-context--slug handle))
          (cl-some (lambda (alias)
                     (string= (ogent-context--slug alias)
                              (ogent-context--slug handle)))
                   aliases))))

  (defun ogent-context--resolve-via-roam (handle)
    "Resolve HANDLE using org-roam database.
Returns an `ogent-context-node' if found, nil otherwise."
    (when-let* ((nodes (org-roam-node-list))
                (match (cl-find-if (lambda (node)
                                     (ogent-context--roam-node-matches node handle))
                                   nodes))
                (file (org-roam-node-file match))
                (point (org-roam-node-point match)))
      ;; Open the file and build the node from the element
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          (save-excursion
            (goto-char point)
            (when-let ((element (org-element-at-point)))
              (ogent-context--node-from-element element buffer))))))))

;;; Completion-at-point for handles

;; Cache for handle collection - keyed by buffer modification tick
(defvar-local ogent-context--handle-cache nil
  "Cache of handles for current buffer.
A plist with :tick and :handles keys.")

(defvar ogent-context--global-handle-cache nil
  "Global cache for all handles across buffers.
A plist with :tick-alist and :handles keys.")

(defun ogent-context--cache-valid-p (buffer cache)
  "Return non-nil if CACHE is valid for BUFFER."
  (and cache
       (buffer-live-p buffer)
       (equal (plist-get cache :tick)
              (buffer-chars-modified-tick buffer))))

(defun ogent-context--extract-annotation (node)
  "Extract annotation string from NODE.
Returns first ~50 chars of content, skipping property drawers."
  (when-let ((content (ogent-context-node-content node)))
    (let ((lines (split-string content "\n")))
      (catch 'found
        (let ((in-drawer nil))
          (dolist (line lines)
            (cond
             ((string-match-p "^[ \t]*:PROPERTIES:" line)
              (setq in-drawer t))
             ((string-match-p "^[ \t]*:END:" line)
              (setq in-drawer nil))
             ((and (not in-drawer)
                   (not (string-match-p "^[ \t]*$" line)))
              (let ((trimmed (string-trim line)))
                (when (> (length trimmed) 0)
                  (throw 'found
                         (concat " — "
                                 (if (> (length trimmed) 50)
                                     (concat (substring trimmed 0 50) "…")
                                   trimmed)))))))))
        nil))))

(defun ogent-context--collect-handles-from-buffer (buffer)
  "Collect all handles from BUFFER with caching.
Returns a list of plists with :handle, :node, and :annotation keys."
  (with-current-buffer buffer
    (when (derived-mode-p 'org-mode)
      ;; Check cache first
      (if (ogent-context--cache-valid-p buffer ogent-context--handle-cache)
          (plist-get ogent-context--handle-cache :handles)
        ;; Rebuild cache
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-min))
            (let (handles)
              (org-element-map (org-element-parse-buffer 'headline) 'headline
                (lambda (el)
                  (let* ((node (ogent-context--node-from-element el buffer))
                         (id (ogent-context-node-id node))
                         (annotation (ogent-context--extract-annotation node)))
                    (when id
                      (push (list :handle id
                                  :node node
                                  :annotation annotation)
                            handles)))))
              (setq handles (nreverse handles))
              ;; Update cache
              (setq ogent-context--handle-cache
                    (list :tick (buffer-chars-modified-tick buffer)
                          :handles handles))
              handles)))))))

(defun ogent-context--collect-all-handles ()
  "Collect all available handles from current buffer, extra buffers, and org-roam.
Returns a list of plists with :handle, :node, and :annotation keys.
Uses caching to avoid re-parsing unchanged buffers."
  (let ((handles nil)
        (seen (make-hash-table :test 'equal)))
    ;; Collect from current buffer and extra buffers
    (dolist (buf (ogent-context--buffers-to-search))
      (when (buffer-live-p buf)
        (dolist (entry (ogent-context--collect-handles-from-buffer buf))
          (let ((handle (plist-get entry :handle)))
            (unless (gethash handle seen)
              (puthash handle t seen)
              (push entry handles))))))
    ;; Collect from org-roam if available (with limit for performance)
    (when (fboundp 'org-roam-node-list)
      (let ((count 0)
            (max-roam-nodes 100))  ; Limit org-roam nodes for performance
        (dolist (node (org-roam-node-list))
          (when (< count max-roam-nodes)
            (let* ((title (org-roam-node-title node))
                   (handle (ogent-context--slug title)))
              (unless (gethash handle seen)
                (puthash handle t seen)
                (cl-incf count)
                ;; For org-roam nodes, annotation is title itself
                (push (list :handle handle
                            :node nil
                            :roam-node node
                            :annotation (concat " — " (truncate-string-to-width title 50)))
                      handles)))))))
    (nreverse handles)))

(defun ogent-context--completion-annotation (handle)
  "Return cached annotation string for HANDLE."
  ;; Look up in the cached handles - this is O(n) but handles list is small
  ;; and we avoid re-parsing buffers
  (catch 'found
    (dolist (buf (ogent-context--buffers-to-search))
      (when (buffer-live-p buf)
        (dolist (entry (ogent-context--collect-handles-from-buffer buf))
          (when (string= (plist-get entry :handle) handle)
            (throw 'found (or (plist-get entry :annotation) ""))))))
    ""))

(defun ogent-context-completion-at-point ()
  "Provide completion for @handle references.
Returns (start end collection . props) when point is after @,
nil otherwise.  Collection includes handles from current buffer,
`ogent-context-extra-buffers', and org-roam nodes if available."
  (when (derived-mode-p 'org-mode)
    (let ((bounds (bounds-of-thing-at-point 'symbol)))
      (when bounds
        (save-excursion
          (goto-char (car bounds))
          (when (and (> (point) (point-min))
                     (eq (char-before) ?@))
            (let* ((start (point))
                   (end (cdr bounds))
                   (all-handles (ogent-context--collect-all-handles))
                   (handles (mapcar (lambda (entry)
                                      (plist-get entry :handle))
                                    all-handles))
                   ;; Pre-build annotation table for O(1) lookup
                   (annotation-table (make-hash-table :test 'equal)))
              ;; Populate annotation table
              (dolist (entry all-handles)
                (puthash (plist-get entry :handle)
                         (or (plist-get entry :annotation) "")
                         annotation-table))
              (list start end handles
                    :annotation-function
                    (lambda (handle)
                      (gethash handle annotation-table ""))
                    :company-docsig
                    (lambda (handle)
                      (gethash handle annotation-table ""))
                    :exit-function
                    (lambda (_string _status)
                      (when (looking-at " ")
                        (delete-char 1)))))))))))

(provide 'ogent-context)

;;; ogent-context.el ends here
