;;; ogent-context.el --- Org context utilities for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Resolve Org handles and assemble prompt-ready payloads for ogent.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'subr-x)
(require 'thunk)

(defgroup ogent nil
  "Org-first AI prompting inside Emacs."
  :group 'applications)

;; Forward declaration for companion linking
(declare-function ogent-companion-source-buffer "ogent-companion")

;; Forward declarations for codemap handle resolution
(declare-function ogent-codemap-handle-p "ogent-codemap")
(declare-function ogent-codemap-resolve-handle "ogent-codemap")
(declare-function ogent-codemap-task-handle-p "ogent-codemap-task")
(declare-function ogent-codemap-resolve-task-handle "ogent-codemap-task")

;; Forward declarations for org-roam integration (optional dependency)
(declare-function org-roam-node-title "ext:org-roam-node")
(declare-function org-roam-node-aliases "ext:org-roam-node")
(declare-function org-roam-node-file "ext:org-roam-node")
(declare-function org-roam-node-point "ext:org-roam-node")
(declare-function org-roam-node-list "ext:org-roam")
;; Defined later in this file inside `with-eval-after-load', so the
;; byte-compiler cannot see it as a top-level definition.
(declare-function ogent-context--roam-node-matches "ogent-context" t t)

(defcustom ogent-context-handle-regexp
  (rx "@" (group
           (+ (any alnum "_-"))
           ;; Optional colon-suffix for task handles like @codemap-task:desc
           (optional ":" (+ (not (any "\n" "@"))))))
  "Regexp that captures handle references inside Org text.
Matches @handle-name with alphanumeric, underscore, and hyphen.
Also supports colon-suffix syntax like @codemap-task:question."
  :type 'string
  :group 'ogent)

(defcustom ogent-context-extra-buffers nil
  "List of buffers searched when resolving handles.
Each entry can be a live buffer or the name of one."
  :type '(repeat (choice buffer string))
  :group 'ogent)

(defcustom ogent-context-max-item-chars 120000
  "Maximum characters captured from any single source context item."
  :type 'integer
  :group 'ogent)

(defcustom ogent-context-binary-sample-bytes 4096
  "Number of bytes sampled when checking pinned files for binary content."
  :type 'integer
  :group 'ogent)

(defvar ogent-context-excluded-handles nil
  "List of handle strings to exclude from context building.
Handles in this list will be filtered out from the :dependencies
list when building context payloads.")

(cl-defstruct ogent-context-node
  title id level begin end content properties buffer)

;;; Pinned Context
;;
;; Pinned items persist across requests, allowing users to build up
;; context incrementally. Items can be files, buffers, or regions.

(cl-defstruct ogent-pinned-item
  "A pinned context item."
  type           ; 'file, 'buffer, or 'region
  path           ; file path (for 'file type)
  buffer         ; buffer object (for 'buffer and 'region types)
  start-marker   ; start marker (for 'region type)
  end-marker     ; end marker (for 'region type)
  label          ; display label
  pinned-at)     ; timestamp when pinned

(defvar ogent-pinned-context nil
  "List of `ogent-pinned-item' structs representing pinned context.")

(defun ogent-pin--make-label (type &optional path buffer start end)
  "Generate a label for a pinned item of TYPE."
  (pcase type
    ('file (file-name-nondirectory path))
    ('buffer (buffer-name buffer))
    ('region (format "%s:%d-%d"
                     (buffer-name buffer)
                     (line-number-at-pos start)
                     (line-number-at-pos end)))))

;;;###autoload
(defun ogent-pin-file (path)
  "Pin file at PATH to context."
  (interactive "fPin file: ")
  (let* ((abs-path (expand-file-name path))
         (existing (cl-find-if (lambda (item)
                                 (and (eq (ogent-pinned-item-type item) 'file)
                                      (string= (ogent-pinned-item-path item) abs-path)))
                               ogent-pinned-context)))
    (if existing
        (message "File already pinned: %s" (ogent-pinned-item-label existing))
      (push (make-ogent-pinned-item
             :type 'file
             :path abs-path
             :label (ogent-pin--make-label 'file abs-path)
             :pinned-at (current-time))
            ogent-pinned-context)
      (message "Pinned: %s" (file-name-nondirectory abs-path)))))

;;;###autoload
(defun ogent-pin-buffer (&optional buffer)
  "Pin BUFFER (or current buffer) to context."
  (interactive)
  (let* ((buf (or buffer (current-buffer)))
         (existing (cl-find-if (lambda (item)
                                 (and (eq (ogent-pinned-item-type item) 'buffer)
                                      (eq (ogent-pinned-item-buffer item) buf)))
                               ogent-pinned-context)))
    (if existing
        (message "Buffer already pinned: %s" (ogent-pinned-item-label existing))
      (push (make-ogent-pinned-item
             :type 'buffer
             :buffer buf
             :label (ogent-pin--make-label 'buffer nil buf)
             :pinned-at (current-time))
            ogent-pinned-context)
      (message "Pinned: %s" (buffer-name buf)))))

;;;###autoload
(defun ogent-pin-region (start end &optional buffer)
  "Pin region from START to END in BUFFER to context."
  (interactive "r")
  (let* ((buf (or buffer (current-buffer)))
         (start-marker (with-current-buffer buf
                         (copy-marker start)))
         (end-marker (with-current-buffer buf
                       (copy-marker end t))))  ; t = insert after
    (push (make-ogent-pinned-item
           :type 'region
           :buffer buf
           :start-marker start-marker
           :end-marker end-marker
           :label (ogent-pin--make-label 'region nil buf start end)
           :pinned-at (current-time))
          ogent-pinned-context)
    (message "Pinned region: %s" (ogent-pin--make-label 'region nil buf start end))))

(defun ogent-unpin (item-or-index)
  "Remove ITEM-OR-INDEX from pinned context.
ITEM-OR-INDEX can be an `ogent-pinned-item' or an index (0-based)."
  (let ((item (if (integerp item-or-index)
                  (nth item-or-index ogent-pinned-context)
                item-or-index)))
    (when item
      ;; Clean up markers for region items
      (when (eq (ogent-pinned-item-type item) 'region)
        (let ((start (ogent-pinned-item-start-marker item))
              (end (ogent-pinned-item-end-marker item)))
          (when (markerp start) (set-marker start nil))
          (when (markerp end) (set-marker end nil))))
      (setq ogent-pinned-context (delq item ogent-pinned-context))
      (message "Unpinned: %s" (ogent-pinned-item-label item)))))

;;;###autoload
(defun ogent-unpin-all ()
  "Clear all pinned context items."
  (interactive)
  (let ((count (length ogent-pinned-context)))
    ;; Clean up all markers
    (dolist (item ogent-pinned-context)
      (when (eq (ogent-pinned-item-type item) 'region)
        (let ((start (ogent-pinned-item-start-marker item))
              (end (ogent-pinned-item-end-marker item)))
          (when (markerp start) (set-marker start nil))
          (when (markerp end) (set-marker end nil)))))
    (setq ogent-pinned-context nil)
    (message "Unpinned %d item(s)" count)))

;;;###autoload
(defun ogent-unpin-interactive ()
  "Interactively select and unpin a context item."
  (interactive)
  (if (null ogent-pinned-context)
      (message "No pinned context items")
    (let* ((candidates (mapcar (lambda (item)
                                 (cons (format "[%s] %s"
                                               (ogent-pinned-item-type item)
                                               (ogent-pinned-item-label item))
                                       item))
                               ogent-pinned-context))
           (choice (completing-read "Unpin: " candidates nil t))
           (item (cdr (assoc choice candidates))))
      (when item
        (ogent-unpin item)))))

;;;###autoload
(defun ogent-list-pinned ()
  "Display all pinned context items."
  (interactive)
  (if (null ogent-pinned-context)
      (message "No pinned context items")
    (with-help-window "*Ogent Pinned Context*"
      (princ "Pinned Context Items\n")
      (princ "====================\n\n")
      (let ((idx 0))
        (dolist (item (reverse ogent-pinned-context))
          (let ((valid (pcase (ogent-pinned-item-type item)
                         ('file (file-readable-p (ogent-pinned-item-path item)))
                         ('buffer (buffer-live-p (ogent-pinned-item-buffer item)))
                         ('region (and (buffer-live-p (ogent-pinned-item-buffer item))
                                       (marker-position (ogent-pinned-item-start-marker item)))))))
            (princ (format "%d. [%s] %s %s\n"
                           idx
                           (ogent-pinned-item-type item)
                           (ogent-pinned-item-label item)
                           (if valid "" "(invalid)"))))
          (cl-incf idx)))
      (princ (format "\nTotal: %d item(s)\n" (length ogent-pinned-context))))))

;;;###autoload
(defun ogent-pin-dwim ()
  "Pin context based on current state (Do What I Mean).
If region is active, pin the region.
If current buffer has a file, pin the file.
Otherwise, pin the buffer."
  (interactive)
  (cond
   ((use-region-p)
    (ogent-pin-region (region-beginning) (region-end)))
   ((buffer-file-name)
    (ogent-pin-file (buffer-file-name)))
   (t
    (ogent-pin-buffer))))

(defun ogent-pinned-count ()
  "Return the number of valid pinned items."
  (length (ogent-pinned-items-valid)))

(defun ogent-context--truncate-content (content label &optional total-length)
  "Return CONTENT capped to `ogent-context-max-item-chars' for LABEL."
  (let ((limit ogent-context-max-item-chars)
        (size (or total-length (length content))))
    (if (and (integerp limit)
             (> limit 0)
             (> (length content) limit))
        (concat
         (substring content 0 limit)
         (format "\n\n[ogent: truncated %s; original %d chars, showing first %d]"
                 label size limit))
      content)))

(defun ogent-context--binary-file-p (path)
  "Return non-nil when PATH appears to contain binary content."
  (with-temp-buffer
    (insert-file-contents-literally path nil 0 ogent-context-binary-sample-bytes)
    (goto-char (point-min))
    (search-forward "\0" nil t)))

(defun ogent-context--file-content (path)
  "Return prompt-safe text content for file PATH."
  (cond
   ((ogent-context--binary-file-p path)
    (format "[ogent: binary file omitted: %s]" path))
   (t
    (let* ((attrs (file-attributes path))
           (size (file-attribute-size attrs))
           (limit (and (integerp ogent-context-max-item-chars)
                       (> ogent-context-max-item-chars 0)
                       (1+ ogent-context-max-item-chars))))
      (with-temp-buffer
        (insert-file-contents path nil 0 limit)
        (ogent-context--truncate-content
         (buffer-string)
         (format "file %s" path)
         size))))))

(defun ogent-pinned-item-content (item)
  "Get the content string for pinned ITEM."
  (pcase (ogent-pinned-item-type item)
    ('file
     (let ((path (ogent-pinned-item-path item)))
       (when (file-readable-p path)
         (ogent-context--file-content path))))
    ('buffer
     (let ((buf (ogent-pinned-item-buffer item)))
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (ogent-context--truncate-content
            (buffer-substring-no-properties (point-min) (point-max))
            (format "buffer %s" (buffer-name buf)))))))
    ('region
     (let ((buf (ogent-pinned-item-buffer item))
           (start (ogent-pinned-item-start-marker item))
           (end (ogent-pinned-item-end-marker item)))
       (when (and (buffer-live-p buf)
                  (markerp start) (markerp end)
                  (marker-position start) (marker-position end))
         (with-current-buffer buf
           (ogent-context--truncate-content
            (buffer-substring-no-properties start end)
            (format "region %s" (buffer-name buf)))))))))

(defun ogent-pinned-items-valid ()
  "Return list of valid pinned items (buffers still live, files exist)."
  (cl-remove-if-not
   (lambda (item)
     (pcase (ogent-pinned-item-type item)
       ('file (file-readable-p (ogent-pinned-item-path item)))
       ('buffer (buffer-live-p (ogent-pinned-item-buffer item)))
       ('region (and (buffer-live-p (ogent-pinned-item-buffer item))
                     (marker-position (ogent-pinned-item-start-marker item))
                     (marker-position (ogent-pinned-item-end-marker item))))))
   ogent-pinned-context))

(defun ogent-pinned-context-string ()
  "Format all pinned items as a string for inclusion in prompts."
  (let ((valid-items (ogent-pinned-items-valid)))
    (when valid-items
      (mapconcat
       (lambda (item)
         (let ((content (ogent-pinned-item-content item))
               (label (ogent-pinned-item-label item))
               (type (ogent-pinned-item-type item)))
           (format "--- Pinned %s: %s ---\n%s"
                   type label
                   (or content "(content unavailable)"))))
       valid-items
       "\n\n"))))

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
                    (ogent-context--truncate-content
                     (if (and region-start region-end)
                         (buffer-substring-no-properties region-start region-end)
                       (buffer-substring-no-properties (point-min) (point-max)))
                     (format "source buffer %s" (buffer-name buffer))))))
    (make-ogent-source-context
     :buffer buffer
     :file file
     :mode mode
     :content content
     :region-start region-start
     :region-end region-end)))

(defun ogent-context--source-line-number (source-ctx position)
  "Return the line number for POSITION in SOURCE-CTX's buffer."
  (let ((buffer (ogent-source-context-buffer source-ctx)))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer
          (line-number-at-pos position t))
      0)))

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
                        (ogent-context--source-line-number source-ctx region-start)
                        (ogent-context--source-line-number source-ctx region-end))
              "Full buffer:")
            content)))

(defun ogent-context--node-location (node)
  "Return a human-readable source location for NODE."
  (let ((buffer (ogent-context-node-buffer node)))
    (cond
     ((and (buffer-live-p buffer) (buffer-file-name buffer))
      (buffer-file-name buffer))
     ((buffer-live-p buffer)
      (buffer-name buffer))
     (t "generated"))))

(defun ogent-context--format-node-reference (node)
  "Return a compact one-line reference for NODE."
  (format "%s (id: %s, source: %s)"
          (or (ogent-context-node-title node) "<untitled>")
          (or (ogent-context-node-id node) "<none>")
          (ogent-context--node-location node)))

(defun ogent-context--format-node-payload (label node)
  "Return full prompt payload for NODE labeled as LABEL."
  (when node
    (let* ((title (or (ogent-context-node-title node) "<untitled>"))
           (raw-content (or (ogent-context-node-content node) ""))
           (content (string-trim
                     (ogent-context--truncate-content
                      raw-content
                      (format "node %s" title)))))
      (string-join
       (delq nil
             (list (format "## %s: %s"
                           label
                           title)
                   (format "ID: %s" (or (ogent-context-node-id node) "<none>"))
                   (format "Source: %s" (ogent-context--node-location node))
                   (unless (string-empty-p content)
                     (format "Content:\n%s" content))))
       "\n"))))

(defun ogent-context--format-dependency-payload (dependency)
  "Return full prompt payload for resolved DEPENDENCY."
  (let ((node (plist-get dependency :node))
        (handle (plist-get dependency :handle)))
    (when node
      (ogent-context--format-node-payload
       (format "@%s" handle)
       node))))

(defun ogent-context--format-pinned-context (items)
  "Return prompt-ready text for pinned ITEMS."
  (when items
    (mapconcat
     (lambda (item)
       (let ((content (ogent-pinned-item-content item))
             (label (ogent-pinned-item-label item))
             (type (ogent-pinned-item-type item)))
         (format "## Pinned %s: %s\n%s"
                 type label
                 (or content "(content unavailable)"))))
     items
     "\n\n")))

(defun ogent-context--content-hash (content)
  "Return sha256 hash for CONTENT."
  (secure-hash 'sha256 (or content "")))

(defun ogent-context--manifest-entry (kind label reason content &optional source)
  "Return a provenance manifest entry."
  (list :kind kind
        :label label
        :reason reason
        :source source
        :chars (length (or content ""))
        :hash (ogent-context--content-hash content)))

(defun ogent-context--node-manifest-entry (kind reason node)
  "Return a manifest entry for NODE."
  (ogent-context--manifest-entry
   kind
   (or (ogent-context-node-title node)
       (ogent-context-node-id node)
       "<untitled>")
   reason
   (ogent-context-node-content node)
   (ogent-context--node-location node)))

(defun ogent-context-manifest (context)
  "Return structured provenance entries for CONTEXT."
  (let ((entries nil)
        (source-ctx (plist-get context :source-context))
        (root (plist-get context :root))
        (ancestors (plist-get context :ancestors))
        (dependencies (plist-get context :dependencies))
        (pinned (plist-get context :pinned))
        (excluded (plist-get context :excluded-handles)))
    (when source-ctx
      (push (ogent-context--manifest-entry
             'source
             (or (ogent-source-context-file source-ctx)
                 (buffer-name (ogent-source-context-buffer source-ctx)))
             (if (and (ogent-source-context-region-start source-ctx)
                      (ogent-source-context-region-end source-ctx))
                 "selected source region"
               "active source buffer")
             (ogent-source-context-content source-ctx)
             (ogent-source-context-file source-ctx))
            entries))
    (when root
      (push (ogent-context--node-manifest-entry
             'root "current Org subtree" root)
            entries))
    (dolist (node ancestors)
      (push (ogent-context--node-manifest-entry
             'ancestor "ancestor Org subtree" node)
            entries))
    (dolist (dep dependencies)
      (let ((handle (plist-get dep :handle))
            (node (plist-get dep :node)))
        (if (and node (not (plist-get dep :missing-p)))
            (push (ogent-context--node-manifest-entry
                   'handle (format "@%s reference" handle) node)
                  entries)
          (push (list :kind 'missing-handle
                      :label (format "@%s" handle)
                      :reason "unresolved handle"
                      :chars 0
                      :hash nil)
                entries))))
    (dolist (item pinned)
      (let ((content (ogent-pinned-item-content item)))
        (push (ogent-context--manifest-entry
               'pinned
               (ogent-pinned-item-label item)
               "pinned context"
               content
               (pcase (ogent-pinned-item-type item)
                 ('file (ogent-pinned-item-path item))
                 ('buffer (buffer-name (ogent-pinned-item-buffer item)))
                 ('region (buffer-name (ogent-pinned-item-buffer item)))
                 (_ nil)))
              entries)))
    (dolist (handle excluded)
      (push (list :kind 'excluded-handle
                  :label (format "@%s" handle)
                  :reason "excluded by user"
                  :chars 0
                  :hash nil)
            entries))
    (nreverse entries)))

(defun ogent-context--format-manifest-entry (entry)
  "Return a compact display line for manifest ENTRY."
  (let ((hash (plist-get entry :hash)))
    (format "  - %s: %s (%d chars%s; reason: %s%s)"
            (plist-get entry :kind)
            (plist-get entry :label)
            (or (plist-get entry :chars) 0)
            (if hash
                (format "; sha256:%s" (substring hash 0 12))
              "")
            (plist-get entry :reason)
            (if-let ((source (plist-get entry :source)))
                (format "; source: %s" source)
              ""))))

(defun ogent-context--format-manifest (context)
  "Return a compact manifest for CONTEXT."
  (let* ((source-ctx (plist-get context :source-context))
         (root (plist-get context :root))
         (ancestors (plist-get context :ancestors))
         (dependencies (plist-get context :dependencies))
         (included (cl-remove-if (lambda (dep)
                                   (plist-get dep :missing-p))
                                 dependencies))
         (missing (cl-remove-if-not (lambda (dep)
                                      (plist-get dep :missing-p))
                                    dependencies))
         (pinned (plist-get context :pinned))
         (excluded (plist-get context :excluded-handles))
         (manifest (ogent-context-manifest context))
         (lines nil))
    (when source-ctx
      (push (format "- Source buffer: %s (%d chars)"
                    (or (ogent-source-context-file source-ctx)
                        (buffer-name (ogent-source-context-buffer source-ctx)))
                    (length (or (ogent-source-context-content source-ctx) "")))
            lines))
    (when root
      (push (format "- Root: %s" (ogent-context--format-node-reference root))
            lines))
    (when ancestors
      (push (format "- Ancestors: %s"
                    (string-join
                     (mapcar #'ogent-context--format-node-reference ancestors)
                     " -> "))
            lines))
    (when included
      (push (format "- Resolved handles: %s"
                    (string-join
                     (mapcar (lambda (dep)
                               (format "@%s" (plist-get dep :handle)))
                             included)
                     ", "))
            lines))
    (when missing
      (push (format "- Missing handles: %s"
                    (string-join
                     (mapcar (lambda (dep)
                               (format "@%s" (plist-get dep :handle)))
                             missing)
                     ", "))
            lines))
    (when excluded
      (push (format "- Excluded handles: %s"
                    (string-join
                     (mapcar (lambda (handle) (format "@%s" handle))
                             excluded)
                     ", "))
            lines))
    (when pinned
      (push (format "- Pinned items: %d" (length pinned)) lines))
    (if (or lines manifest)
        (string-join
         (append (nreverse lines)
                 (when manifest
                   (cons "- Provenance:"
                         (mapcar #'ogent-context--format-manifest-entry
                                 manifest))))
         "\n")
      "- No context")))

(defun ogent-context-render-prompt (prompt context)
  "Render PROMPT and CONTEXT into the exact payload sent to the model."
  (let* ((source-ctx (plist-get context :source-context))
         (root (plist-get context :root))
         (ancestors (plist-get context :ancestors))
         (dependencies (plist-get context :dependencies))
         (resolved-dependencies
          (cl-remove-if (lambda (dep)
                          (or (plist-get dep :missing-p)
                              (null (plist-get dep :node))))
                        dependencies))
         (missing-dependencies
          (cl-remove-if-not (lambda (dep)
                              (plist-get dep :missing-p))
                            dependencies))
         (pinned (plist-get context :pinned))
         (pinned-content (ogent-context--format-pinned-context pinned)))
    (string-join
     (delq nil
           (list "# User Prompt"
                 prompt
                 "# Context Manifest"
                 (ogent-context--format-manifest context)
                 (when source-ctx
                   (format "# Source Buffer\n%s"
                           (ogent-context--format-source-context source-ctx)))
                 (when ancestors
                   (format "# Org Ancestors\n%s"
                           (mapconcat
                            (lambda (node)
                              (format "- %s"
                                      (ogent-context--format-node-reference node)))
                            ancestors
                            "\n")))
                 (when root
                   (format "# Org Root\n%s"
                           (ogent-context--format-node-payload "Root" root)))
                 (when resolved-dependencies
                   (format "# Resolved @handles\n%s"
                           (mapconcat
                            #'ogent-context--format-dependency-payload
                            resolved-dependencies
                            "\n\n")))
                 (when missing-dependencies
                   (format "# Missing @handles\n%s"
                           (mapconcat
                            (lambda (dep)
                              (format "- @%s" (plist-get dep :handle)))
                            missing-dependencies
                            "\n")))
                 (when (and pinned-content
                            (not (string-empty-p pinned-content)))
                   (format "# Pinned Context\n%s" pinned-content))))
     "\n\n")))

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
Handles special cases like @codemap and @codemap-task: handles."
  (cond
   ;; Task-scoped codemap handles (@codemap-task:description)
   ((and (fboundp 'ogent-codemap-task-handle-p)
         (ogent-codemap-task-handle-p handle))
    (let ((content (ogent-codemap-resolve-task-handle handle)))
      (list :handle handle
            :missing-p (null content)
            :node (when content
                    (make-ogent-context-node
                     :title (format "Task Codemap: %s" handle)
                     :id handle
                     :content content
                     :buffer nil)))))
   ;; Static codemap handles (@codemap, @codemap-lisp, etc.)
   ((and (fboundp 'ogent-codemap-handle-p)
         (ogent-codemap-handle-p handle))
    (let ((content (ogent-codemap-resolve-handle handle)))
      (list :handle handle
            :missing-p (null content)
            :node (when content
                    (make-ogent-context-node
                     :title (format "Codemap: %s" handle)
                     :id handle
                     :content content
                     :buffer nil)))))
   ;; Standard handle resolution
   (t
    (let ((node (ogent-resolve-handle handle)))
      (list :handle handle
            :missing-p (null node)
            :node node)))))

;;;###autoload
(defun ogent-context-exclude-handle (handle)
  "Add HANDLE to the exclusion list.
Excluded handles will be filtered from context dependencies."
  (cl-check-type handle string)
  (cl-pushnew handle ogent-context-excluded-handles :test #'string=))

;;;###autoload
(defun ogent-context-include-handle (handle)
  "Remove HANDLE from the exclusion list.
The handle will be included in future context builds."
  (cl-check-type handle string)
  (setq ogent-context-excluded-handles
        (cl-remove handle ogent-context-excluded-handles :test #'string=)))

;;;###autoload
(defun ogent-context-toggle-exclusion (handle)
  "Toggle exclusion status of HANDLE.
If HANDLE is excluded, include it; if included, exclude it."
  (cl-check-type handle string)
  (if (member handle ogent-context-excluded-handles)
      (ogent-context-include-handle handle)
    (ogent-context-exclude-handle handle)))

;;;###autoload
(defun ogent-context-clear-exclusions ()
  "Clear all handle exclusions.
All handles will be included in future context builds."
  (setq ogent-context-excluded-handles nil))

;;;###autoload
(defun ogent-context-get-exclusions ()
  "Return the current list of excluded handles."
  (copy-sequence ogent-context-excluded-handles))

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
(defun ogent-context-build-filtered (&optional point)
  "Build context payload with excluded handles filtered out.
Like `ogent-context-build', but filters dependencies where :handle
is in `ogent-context-excluded-handles'.
Returns a plist with :root, :ancestors, :handles, :dependencies,
:excluded-handles, and :pinned keys."
  (let* ((ctx (ogent-context-build point))
         (all-dependencies (plist-get ctx :dependencies))
         (filtered-dependencies
          (cl-remove-if (lambda (dep)
                          (member (plist-get dep :handle)
                                  ogent-context-excluded-handles))
                        all-dependencies))
         (excluded-handles (copy-sequence ogent-context-excluded-handles))
         (pinned-items (ogent-pinned-items-valid)))
    (list :root (plist-get ctx :root)
          :ancestors (plist-get ctx :ancestors)
          :handles (plist-get ctx :handles)
          :dependencies filtered-dependencies
          :excluded-handles excluded-handles
          :pinned pinned-items)))

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
Returns context with both Org structure (if any), source code, and pinned items."
  (let* ((source-ctx (when (and source-buffer
                                (buffer-live-p source-buffer)
                                ;; Use buffer-local-value for faster check
                                (not (eq (buffer-local-value 'major-mode source-buffer)
                                         'org-mode)))
                       (ogent-context--build-source-context
                        source-buffer region-start region-end)))
         (org-ctx (when (derived-mode-p 'org-mode)
                    (condition-case nil
                        (ogent-context-build-filtered)
                      (error nil))))
         (pinned-items (or (plist-get org-ctx :pinned)
                           (ogent-pinned-items-valid))))
    (list :source-context source-ctx
          :root (plist-get org-ctx :root)
          :ancestors (plist-get org-ctx :ancestors)
          :handles (plist-get org-ctx :handles)
          :dependencies (plist-get org-ctx :dependencies)
          :excluded-handles (plist-get org-ctx :excluded-handles)
          :pinned pinned-items)))

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
