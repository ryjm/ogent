;;; ogent-ui-context.el --- Interactive context preview for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Replaces static context formatting with interactive Org structure.
;; Provides clickable links, folding sections, and token/char counts.
;; Context management buffer allows viewing/editing context elements.

;;; Code:

(require 'org)
(require 'button)
(require 'ogent-context)
(require 'ogent-ui-theme)
(require 'ogent-ui-layout)
(require 'ogent-ui-section)
(require 'ogent-keys)

;;; Context Budget Configuration

(defcustom ogent-ui-context-budget-default 100000
  "Set the character budget for the formatted review snapshot.
This estimate is separate from the dispatcher's model-specific token budget."
  :type 'integer
  :group 'ogent-mode)

(defcustom ogent-ui-context-budget-warning-threshold 70
  "Percentage of budget at which to show warning color."
  :type 'integer
  :group 'ogent-mode)

(defcustom ogent-ui-context-budget-danger-threshold 90
  "Percentage of budget at which to show danger color."
  :type 'integer
  :group 'ogent-mode)

;;; Context Management Buffer

(defconst ogent-ui-context-buffer-name "*ogent-context-manager*"
  "Name of the context management buffer.")

(defvar-local ogent-ui-context--context nil
  "Context plist for the management buffer.")

(defvar-local ogent-ui-context--source-buffer nil
  "Source buffer from which context was built.")

(defvar-local ogent-ui-context--summary nil
  "Element and missing-handle summary for this snapshot.")

(defvar ogent-ui-context-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'ogent-ui-context-next-element)
    (define-key map (kbd "p") #'ogent-ui-context-previous-element)
    (define-key map (kbd "d") #'ogent-ui-context-delete-element)
    (define-key map (kbd "a") #'ogent-ui-context-add-element)
    (define-key map (kbd "RET") #'ogent-ui-context-preview-element)
    (define-key map (kbd "o") #'ogent-ui-context-visit-element)
    (define-key map (kbd "g") #'ogent-ui-context-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `ogent-ui-context-mode'.")

(define-derived-mode ogent-ui-context-mode special-mode "Ogent-Context"
  "Major mode for managing ogent context elements.

Key bindings:
\\{ogent-ui-context-mode-map}"
  (ogent-ui-layout-configure)
  (setq-local header-line-format
              '(:eval (ogent-section-header-line
                       "Context" ogent-ui-context--summary
                       '("RET" . "details") '("q" . "return")
                       '("o" . "source") '("g" . "redraw")))))

(defvar-local ogent-ui-context--detail-element nil
  "Captured element displayed by the detail reader.")

(defvar ogent-ui-context-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "o") #'ogent-ui-context-visit-element)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for the full context element reader.")

(define-derived-mode ogent-ui-context-detail-mode special-mode "ContextItem"
  "Read the complete captured text of one context element."
  (ogent-ui-layout-configure)
  (setq-local header-line-format
              '(:eval (ogent-section-header-line
                       "Context item" nil '("q" . "return")))))

(defun ogent-ui-context--estimate-tokens (text)
  "Estimate the number of tokens in TEXT.
Uses ~4 characters per token approximation for English text."
  (if (or (null text) (string-empty-p text))
      0
    (ceiling (/ (float (length text)) 4.0))))

(defun ogent-ui-context--char-count (text)
  "Return character count of TEXT, handling nil."
  (if (or (null text) (string-empty-p text))
      0
    (length text)))

(defun ogent-ui-context--format-node-link (node)
  "Format NODE as an Org link with file:line reference.
Returns a string like: [[file:path.org::LINE][TITLE]] (id: ID)"
  (if (null node)
      "(no node)"
    (let* ((title (or (ogent-context-node-title node) "<untitled>"))
           (id (ogent-context-node-id node))
           (buffer (ogent-context-node-buffer node))
           (begin (ogent-context-node-begin node))
           (file (when (buffer-live-p buffer) (buffer-file-name buffer)))
           (line (when (and (buffer-live-p buffer) begin)
                   (with-current-buffer buffer
                     (line-number-at-pos begin)))))
      (if (and file line)
          (format "[[file:%s::%d][%s]] (id: %s)" file line title id)
        (format "%s (id: %s)" title id)))))

(defun ogent-ui-context--format-source-section (source-ctx)
  "Format SOURCE-CTX as an Org section with char count.
Returns a plist with :heading and :content."
  (let* ((file (or (ogent-source-context-file source-ctx) "(unsaved)"))
         (mode (ogent-source-context-mode source-ctx))
         (content (ogent-source-context-content source-ctx))
         (region-start (ogent-source-context-region-start source-ctx))
         (region-end (ogent-source-context-region-end source-ctx))
         (char-count (ogent-ui-context--char-count content))
         (buffer (ogent-source-context-buffer source-ctx))
         (region-info (if (and region-start region-end)
                          (if (buffer-live-p buffer)
                              (with-current-buffer buffer
                                (save-restriction
                                  (widen)
                                  (format "Selected region (lines %d-%d)"
                                          (line-number-at-pos (min region-start (point-max)))
                                          (line-number-at-pos (min region-end (point-max))))))
                            "Selected region (source unavailable)")
                        "Full buffer"))
         (heading (format "* Source Context [%d chars]" char-count))
         (body (format "File: %s\nMode: %s\n%s\n#+begin_src %s\n%s\n#+end_src"
                       (file-name-nondirectory file)
                       mode
                       region-info
                       (replace-regexp-in-string "-mode$" "" mode)
                       content)))
    (list :heading heading :content body :chars char-count)))

(defun ogent-ui-context--format-root-section (root)
  "Format ROOT node as an Org section with char count.
Returns a plist with :heading and :content."
  (if (null root)
      (list :heading "* Root" :content "(no root node)" :chars 0)
    (let* ((content-text (or (ogent-context-node-content root) ""))
           (char-count (+ (ogent-ui-context--char-count content-text)
                          (ogent-ui-context--char-count
                           (ogent-context-node-title root))))
           (heading (format "* Root [%d chars]" char-count))
           (body (format "%s\n\n%s"
                         (ogent-ui-context--format-node-link root)
                         content-text)))
      (list :heading heading :content body :chars char-count))))

(defun ogent-ui-context--format-ancestors-section (ancestors)
  "Format ANCESTORS as an Org section with char count.
Returns a plist with :heading and :content."
  (if (null ancestors)
      (list :heading "* Ancestors" :content "(none)" :chars 0)
    (let* ((lines (mapcar (lambda (node)
                            (concat "- " (ogent-ui-context--format-node-link node)))
                          ancestors))
           (body (string-join lines "\n"))
           (char-count (apply #'+ (mapcar (lambda (node)
                                            (+ (ogent-ui-context--char-count
                                                (ogent-context-node-title node))
                                               (ogent-ui-context--char-count
                                                (ogent-context-node-content node))))
                                          ancestors)))
           (heading (format "* Ancestors [%d chars]" char-count)))
      (list :heading heading :content body :chars char-count))))

(defun ogent-ui-context--format-dependencies-section (dependencies)
  "Format DEPENDENCIES as an Org section with char count.
Returns a plist with :heading and :content."
  (if (null dependencies)
      (list :heading "* Dependencies" :content "(none)" :chars 0)
    (let* ((total-chars 0)
           (dep-strings
            (mapcar (lambda (dep)
                      (let* ((handle (plist-get dep :handle))
                             (missing-p (plist-get dep :missing-p))
                             (node (plist-get dep :node))
                             (dep-str (if missing-p
                                          (format "** @%s (missing)" handle)
                                        (let ((content (or (ogent-context-node-content node) "")))
                                          (setq total-chars (+ total-chars
                                                               (ogent-ui-context--char-count content)
                                                               (ogent-ui-context--char-count
                                                                (ogent-context-node-title node))))
                                          (format "** @%s\n%s\n\n%s"
                                                  handle
                                                  (ogent-ui-context--format-node-link node)
                                                  content)))))
                        dep-str))
                    dependencies))
           (body (string-join dep-strings "\n"))
           (heading (format "* Dependencies [%d chars]" total-chars)))
      (list :heading heading :content body :chars total-chars))))

;;; Budget Visualization

(defun ogent-ui-context--format-budget-bar (used budget)
  "Format a visual budget bar showing USED of BUDGET chars.
Returns a string with progress bar and percentage."
  (let* ((percent (if (> budget 0)
                      (* 100.0 (/ (float used) budget))
                    0))
         (face (ogent-theme-progress-face percent))
         (bar (ogent-theme-progress-bar percent 20 face))
         (tokens-used (ceiling (/ (float used) 4.0))))
    (concat
     bar
     " "
     (propertize (format "%.0f%%" percent) 'face face)
     "\n"
     (propertize (format "%d" used) 'face face)
     (propertize "/" 'face 'ogent-theme-muted)
     (propertize (format "%d chars" budget) 'face 'ogent-theme-muted)
     "  "
     (propertize (format "(~%d tokens, estimate)" tokens-used) 'face 'ogent-theme-muted))))

(defun ogent-ui-context--format-section-bar (chars total-budget section-name)
  "Format a mini progress bar for a section with CHARS.
TOTAL-BUDGET is the overall context budget.
SECTION-NAME is displayed before the bar."
  (let* ((percent (if (> total-budget 0)
                      (min 100 (* 100.0 (/ (float chars) total-budget)))
                    0))
         (face (if (> percent 30) 'ogent-theme-warning 'ogent-theme-muted))
         (bar (ogent-theme-progress-bar percent 8 face)))
    (concat
     (propertize section-name 'face 'ogent-theme-muted)
     " "
     bar
     " "
     (propertize (format "%d" chars) 'face face))))

;;;###autoload
(defun ogent-ui-context-format (context)
  "Format CONTEXT plist as interactive Org structure.
Returns an Org-formatted string with:
- Visual budget indicator with progress bar
- Clickable file:line links to source locations
- Collapsible sections (Root, Ancestors, Dependencies)
- Character and token counts per section and total

CONTEXT is a plist with keys:
  :source-context - ogent-source-context struct (optional)
  :root           - ogent-context-node struct
  :ancestors      - list of ogent-context-node structs
  :dependencies   - list of plists with :handle, :missing-p, :node"
  (let* ((source-ctx (plist-get context :source-context))
         (root (plist-get context :root))
         (ancestors (plist-get context :ancestors))
         (dependencies (plist-get context :dependencies))
         
         ;; Build sections
         (source-section (when source-ctx
                           (ogent-ui-context--format-source-section source-ctx)))
         (root-section (ogent-ui-context--format-root-section root))
         (ancestors-section (ogent-ui-context--format-ancestors-section ancestors))
         (deps-section (ogent-ui-context--format-dependencies-section dependencies))
         
         ;; Calculate totals
         (source-chars (if source-section (plist-get source-section :chars) 0))
         (root-chars (plist-get root-section :chars))
         (ancestors-chars (plist-get ancestors-section :chars))
         (deps-chars (plist-get deps-section :chars))
         (total-chars (+ source-chars root-chars ancestors-chars deps-chars))
         (budget ogent-ui-context-budget-default)
         
         ;; Build header with budget visualization
         (header (concat
                  (propertize "Context Budget" 'face 'ogent-theme-section-heading)
                  "\n"
                  (ogent-ui-context--format-budget-bar total-chars budget)
                  "\n\n"
                  (propertize "Breakdown:" 'face 'ogent-theme-muted)
                  "\n"
                  (when source-section
                    (concat "  " (ogent-ui-context--format-section-bar source-chars budget "Source") "\n"))
                  "  " (ogent-ui-context--format-section-bar root-chars budget "Root") "\n"
                  "  " (ogent-ui-context--format-section-bar ancestors-chars budget "Ancestors") "\n"
                  "  " (ogent-ui-context--format-section-bar deps-chars budget "Dependencies") "\n"
                  "\n"
                  (ogent-theme-separator)
                  "\n\n"))
         
         ;; Build output parts
         (parts (list header)))
    
    ;; Add sections with icons
    (when source-section
      (push (format "%s %s\n%s\n"
                    (plist-get source-section :heading)
                    (ogent-theme-icon 'file)
                    (plist-get source-section :content))
            parts))
    
    (push (format "%s %s\n%s\n"
                  (plist-get root-section :heading)
                  (ogent-theme-icon 'context)
                  (plist-get root-section :content))
          parts)
    
    (push (format "%s %s\n%s\n"
                  (plist-get ancestors-section :heading)
                  (ogent-theme-icon 'link)
                  (plist-get ancestors-section :content))
          parts)
    
    (push (format "%s %s\n%s\n"
                  (plist-get deps-section :heading)
                  (ogent-theme-icon 'search)
                  (plist-get deps-section :content))
          parts)
    
    ;; Return concatenated result
    (string-join (nreverse parts) "")))

(defun ogent-ui-context--node-element (type node)
  "Return a captured element for NODE of TYPE."
  (let ((buffer (ogent-context-node-buffer node))
        (title (or (ogent-context-node-title node) "(no title)"))
        (content (or (ogent-context-node-content node) "")))
    (list :type type :data node :name title :content content
          :key (list type (or (ogent-context-node-id node)
                              (list buffer (ogent-context-node-begin node) title)))
          :chars (+ (length title) (length content)) :node-id (ogent-context-node-id node)
          :buffer buffer :begin (ogent-context-node-begin node)
          :file (when (buffer-live-p buffer) (buffer-file-name buffer)))))

(defun ogent-ui-context--elements ()
  "Return the ordered captured elements of this review snapshot."
  (let* ((context ogent-ui-context--context)
         (source (plist-get context :source-context))
         (root (plist-get context :root)))
    (append
     (when source
       (let ((file (ogent-source-context-file source))
             (content (or (ogent-source-context-content source) "")))
         (list (list :type 'source :data source
                     :name (if file (file-name-nondirectory file) "(unsaved source)")
                     :key (list 'source (ogent-source-context-buffer source) file)
                     :content content :chars (length content) :file file
                     :buffer (ogent-source-context-buffer source)
                     :begin (ogent-source-context-region-start source)))))
     (when root (list (ogent-ui-context--node-element 'root root)))
     (mapcar (lambda (node) (ogent-ui-context--node-element 'ancestor node))
             (plist-get context :ancestors))
     (mapcar (lambda (dependency)
               (let* ((node (plist-get dependency :node))
                      (handle (plist-get dependency :handle))
                      (element (if node (ogent-ui-context--node-element 'dependency node)
                                 (list :type 'dependency :content "" :chars 0))))
                 (setq element (plist-put element :data dependency))
                 (setq element (plist-put element :key (list 'dependency handle)))
                 (setq element (plist-put element :name (concat "@" handle)))
                 (setq element (plist-put element :missing-p (or (plist-get dependency :missing-p) (null node))))
                 element))
             (plist-get context :dependencies)))))

(defun ogent-ui-context--element-at-point ()
  "Return the captured element at point, including continuation lines."
  (or (get-text-property (point) 'ogent-context-element)
      (save-excursion
        (beginning-of-line)
        (when (looking-at "^\\s-*\\([0-9]+\\)\\. \\[\\(.*?\\)\\]")
          (let ((index (1- (string-to-number (match-string 1))))
                (type (intern (string-trim (match-string 2)))))
            (or (nth index (ogent-ui-context--elements))
                (list :type type :index index)))))))

(defun ogent-ui-context--snippet (content)
  "Return the first readable line of CONTENT, omitting property drawers."
  (let (drawer)
    (or (catch 'line
          (dolist (line (split-string content "\n"))
            (cond ((string-match-p "\\`[ \t]*:PROPERTIES:[ \t]*\\'" line) (setq drawer t))
                  ((and drawer (string-match-p "\\`[ \t]*:END:[ \t]*\\'" line)) (setq drawer nil))
                  ((or drawer (string-empty-p (string-trim line))) nil)
                  (t (throw 'line (string-trim line))))))
        "(empty text)")))

(defun ogent-ui-context--format-element (index type name size preview)
  "Format element INDEX with TYPE, full NAME, SIZE and a short PREVIEW."
  (concat (propertize (format "%3d. [%s] " index type) 'face 'ogent-theme-muted)
          (propertize name 'face 'ogent-theme-primary) "\n"
          (propertize (format "     %d chars  " size) 'face 'ogent-theme-muted)
          (truncate-string-to-width (or preview "") 96 nil nil
                                    (if ogent-theme-use-unicode "…" "~"))
          "\n\n"))

(defun ogent-ui-context--button-preview (button)
  "Read the captured element associated with BUTTON."
  (goto-char (button-start button))
  (ogent-ui-context-preview-element))

(defun ogent-ui-context--render-buffer ()
  "Redraw the review snapshot, preserving item identity and visible position."
  (let* ((inhibit-read-only t)
         (elements (ogent-ui-context--elements))
         (missing (cl-count-if (lambda (element) (plist-get element :missing-p)) elements))
         (first-render (= (buffer-size) 0))
         (index 0))
    (setq ogent-ui-context--summary (format "%d elements, %d missing" (length elements) missing))
    (ogent-ui-layout-preserve-location 'ogent-context-identity
      (erase-buffer)
      (insert (propertize "Context review\n" 'face 'ogent-theme-section-heading)
              "From: " (if (buffer-live-p ogent-ui-context--source-buffer)
                           (or (buffer-file-name ogent-ui-context--source-buffer)
                               (buffer-name ogent-ui-context--source-buffer))
                         "source unavailable") "\n"
              (propertize ogent-ui-context--summary
                          'face (if (> missing 0) 'ogent-theme-warning 'ogent-theme-muted))
              "\n"
              "Snapshot only: removing source or ancestors here does not change a request.\n"
              "Excluded handles apply to later requests in this session.\n"
              "n/p elements   RET full text   o source   a inspect handle   d remove\n\n")
      (unless elements
        (insert "No context elements captured. Return with q and choose an Org heading or a source buffer.\n"))
      (dolist (element elements)
        (let ((start (point)))
          (setq element (plist-put element :index index))
          (insert (ogent-ui-context--format-element
                   (1+ index) (plist-get element :type) (plist-get element :name)
                   (plist-get element :chars)
                   (if (plist-get element :missing-p) "Missing: no captured text; resolve or remove this handle."
                     (ogent-ui-context--snippet (plist-get element :content)))))
          (let ((name-start (+ start (length (format "%3d. [%s] " (1+ index) (plist-get element :type))))))
            (make-text-button name-start (+ name-start (length (plist-get element :name)))
                              'follow-link t 'action #'ogent-ui-context--button-preview
                              'help-echo "Read full captured text"))
          (when (plist-get element :missing-p)
            (add-face-text-property start (point) 'ogent-theme-warning t))
          (add-text-properties start (point)
                               (list 'ogent-context-element element
                                     'ogent-context-identity (plist-get element :key)))
          (cl-incf index))))
    (when first-render
      (goto-char (point-min))
      (when (re-search-forward "^\\s-*1\\." nil t) (beginning-of-line)))
    (set-buffer-modified-p nil)))

;;;###autoload
(defun ogent-ui-context-refresh ()
  "Redraw the captured snapshot without rebuilding or dispatching a request."
  (interactive)
  (ogent-ui-context--render-buffer))

(defun ogent-ui-context--step (direction)
  "Move to an adjacent element in DIRECTION, keeping point at boundaries."
  (let ((origin (point))
        (element (get-text-property (point) 'ogent-context-element)))
    (when element
      (goto-char (text-property-any (point-min) (point-max) 'ogent-context-element element)))
    (beginning-of-line)
    (let ((found (if (> direction 0)
                     (progn
                       (when (looking-at "^\\s-*[0-9]+\\.") (forward-line 1))
                       (re-search-forward "^\\s-*[0-9]+\\." nil t))
                   (re-search-backward "^\\s-*[0-9]+\\." nil t))))
      (if found (beginning-of-line)
        (goto-char origin)
        (message "%s of context elements" (if (> direction 0) "End" "Beginning"))))))

(defun ogent-ui-context-next-element ()
  "Move to the next captured context element."
  (interactive)
  (ogent-ui-context--step 1))

(defun ogent-ui-context-previous-element ()
  "Move to the previous captured context element."
  (interactive)
  (ogent-ui-context--step -1))

(defun ogent-ui-context-delete-element ()
  "Remove an element from the snapshot, or exclude a handle for this session."
  (interactive)
  (let* ((element (or (ogent-ui-context--element-at-point) (user-error "Choose a context element")))
         (type (plist-get element :type))
         (data (plist-get element :data)))
    (pcase type
      ('root (user-error "The root defines this scope; choose another heading at the source"))
      ('source
       (when (yes-or-no-p "Remove source from this review snapshot only? ")
         (setq ogent-ui-context--context (plist-put ogent-ui-context--context :source-context nil))
         (ogent-ui-context--render-buffer)))
      ('ancestor
       (when (yes-or-no-p "Remove ancestor from this review snapshot only? ")
         (setq ogent-ui-context--context
               (plist-put ogent-ui-context--context :ancestors
                          (delq data (copy-sequence (plist-get ogent-ui-context--context :ancestors)))))
         (ogent-ui-context--render-buffer)))
      ('dependency
       (let ((handle (plist-get data :handle)))
         (when (yes-or-no-p (format "Exclude @%s from later requests in this session? " handle))
           (ogent-context-exclude-handle handle)
           (setq ogent-ui-context--context
                 (plist-put ogent-ui-context--context :dependencies
                            (cl-remove-if (lambda (dependency) (equal handle (plist-get dependency :handle)))
                                          (plist-get ogent-ui-context--context :dependencies))))
           (ogent-ui-context--render-buffer)))))))

(defun ogent-ui-context-add-element ()
  "Inspect a handle in this snapshot, resolving it at its originating buffer."
  (interactive)
  (let* ((root (plist-get ogent-ui-context--context :root))
         (source (or (and root (ogent-context-node-buffer root)) ogent-ui-context--source-buffer))
         (handle (string-remove-prefix "@" (string-trim (read-string "Inspect handle: ")))))
    (unless (string-empty-p handle)
      (unless (buffer-live-p source) (user-error "Source unavailable; reopen context from its source"))
      (let* ((deps (plist-get ogent-ui-context--context :dependencies))
             (existing (cl-find handle deps :key (lambda (dependency) (plist-get dependency :handle)) :test #'equal))
             (node (unless existing (with-current-buffer source (ogent-resolve-handle handle)))))
        (when (or existing node (yes-or-no-p (format "@%s is missing.  Inspect it anyway? " handle)))
          (unless existing
            (setq ogent-ui-context--context
                  (plist-put ogent-ui-context--context :dependencies
                             (append deps (list (list :handle handle :missing-p (null node) :node node)))))
            (ogent-context-include-handle handle))
          (ogent-ui-context--render-buffer)
          (goto-char (ogent-ui-layout--position
                      'ogent-context-identity (list (list 'dependency handle) 0 (point-min))))
          (message "Inspecting @%s; add the handle to your source to send it" handle))))))

;;;###autoload
(defun ogent-ui-context-visit-element ()
  "Visit the source of the selected context element when it is available."
  (interactive)
  (let* ((element (if (derived-mode-p 'ogent-ui-context-detail-mode)
                      ogent-ui-context--detail-element
                    (ogent-ui-context--element-at-point)))
         (buffer (plist-get element :buffer))
         (position (plist-get element :begin)))
    (unless (buffer-live-p buffer)
      (user-error "Source unavailable; RET in the context review shows captured text"))
    (pop-to-buffer buffer)
    (when position (goto-char (min position (point-max))))
    (when (derived-mode-p 'org-mode) (org-fold-show-context))))

(defun ogent-ui-context-preview-element ()
  "Read full captured text for the context element at point."
  (interactive)
  (let* ((element (or (ogent-ui-context--element-at-point) (user-error "Choose a context element")))
         (source (plist-get element :buffer))
         (buffer (get-buffer-create "*ogent context item*")))
    (with-current-buffer buffer
      (ogent-ui-context-detail-mode)
      (setq ogent-ui-context--detail-element element)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (plist-get element :name) 'face 'ogent-theme-section-heading) "\n"
                (format "Type: %s   %d captured chars\n" (plist-get element :type) (plist-get element :chars)))
        (when-let ((file (plist-get element :file))) (insert "Source: " file "\n"))
        (when-let ((id (plist-get element :node-id))) (insert "Node ID: " id "\n"))
        (cond ((plist-get element :missing-p)
               (insert (propertize "Missing handle: no text was captured.\n" 'face 'ogent-theme-warning)
                       "Return with q to remove it, or resolve it in your source before sending.\n"))
              ((buffer-live-p source) (insert "o visits the live source; q returns to the review.\n"))
              (t (insert "Source unavailable. The captured text remains readable.\n")))
        (insert "\n" (propertize "Captured text\n" 'face 'ogent-theme-muted)
                (plist-get element :content) "\n")
        (goto-char (point-min)) (set-buffer-modified-p nil)))
    (pop-to-buffer buffer)))


;;;###autoload
(defun ogent-context-manage (&optional context source-buffer)
  "Open the context management buffer.
CONTEXT is a context plist (defaults to building from current buffer).
SOURCE-BUFFER is the originating buffer."
  (interactive)
  (let* ((ctx (or context
                  (if (derived-mode-p 'org-mode)
                      (condition-case nil
                          (ogent-context-build)
                        (error (list :root nil :ancestors nil :dependencies nil)))
                    (ogent-context-build-for-buffer))))
         (src-buf (or source-buffer (current-buffer)))
         (buf (get-buffer-create ogent-ui-context-buffer-name)))
    (with-current-buffer buf
      (ogent-ui-context-mode)
      (setq ogent-ui-context--context (copy-tree ctx))
      (setq ogent-ui-context--source-buffer src-buf)
      (ogent-ui-context--render-buffer))
    (pop-to-buffer buf)))

;; Canonical Evil integration so the context buffer's single-key
;; affordances (n/p, a add, d delete, RET preview, q quit) fire under
;; Doom/Evil.
(with-eval-after-load 'evil
  (when (fboundp 'ogent-evil-display-mode-setup)
    (ogent-evil-display-mode-setup
     'ogent-ui-context-mode ogent-ui-context-mode-map
     'ogent-ui-context-mode-hook #'ogent-ui-context-refresh)
    (ogent-evil-display-mode-setup
     'ogent-ui-context-detail-mode ogent-ui-context-detail-mode-map
     'ogent-ui-context-detail-mode-hook)))

(provide 'ogent-ui-context)
;;; ogent-ui-context.el ends here
