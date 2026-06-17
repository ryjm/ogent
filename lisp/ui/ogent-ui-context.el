;;; ogent-ui-context.el --- Interactive context preview for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Replaces static context formatting with interactive Org structure.
;; Provides clickable links, folding sections, and token/char counts.
;; Context management buffer allows viewing/editing context elements.

;;; Code:

(require 'org)
(require 'ogent-context)
(require 'ogent-ui-theme)

;;; Context Budget Configuration

(defcustom ogent-ui-context-budget-default 100000
  "Default context budget in characters.
This is used when no model-specific limit is known.
Most models support ~100k tokens which is roughly 400k chars."
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

(defconst ogent-ui-context-buffer-name "*Ogent Context Manager*"
  "Name of the context management buffer.")

(defvar-local ogent-ui-context--context nil
  "Context plist for the management buffer.")

(defvar-local ogent-ui-context--source-buffer nil
  "Source buffer from which context was built.")

(defvar ogent-ui-context-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'ogent-ui-context-next-element)
    (define-key map (kbd "p") #'ogent-ui-context-previous-element)
    (define-key map (kbd "d") #'ogent-ui-context-delete-element)
    (define-key map (kbd "a") #'ogent-ui-context-add-element)
    (define-key map (kbd "RET") #'ogent-ui-context-preview-element)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `ogent-ui-context-mode'.")

(define-derived-mode ogent-ui-context-mode special-mode "Ogent-Context"
  "Major mode for managing ogent context elements.

Key bindings:
\\{ogent-ui-context-mode-map}"
  (setq truncate-lines t)
  (setq buffer-read-only t))

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
           (file (when buffer (buffer-file-name buffer)))
           (line (when (and buffer begin)
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
         (region-info (if (and region-start region-end)
                          (format "Selected region (lines %d-%d)"
                                  (line-number-at-pos region-start)
                                  (line-number-at-pos region-end))
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
                      (min 100 (* 100.0 (/ (float used) budget)))
                    0))
         (face (ogent-theme-progress-face percent))
         (bar (ogent-theme-progress-bar percent 20 face))
         (tokens-used (ogent-ui-context--estimate-tokens (number-to-string used))))
    (concat
     bar
     " "
     (propertize (format "%.0f%%" percent) 'face face)
     "  "
     (propertize (format "%dk" (/ used 1000)) 'face face)
     (propertize "/" 'face 'ogent-theme-muted)
     (propertize (format "%dk chars" (/ budget 1000)) 'face 'ogent-theme-muted)
     "  "
     (propertize (format "(~%dk tokens)" (/ tokens-used 1000)) 'face 'ogent-theme-muted))))

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
                    (ogent-theme-icon 'file)
                    (plist-get source-section :heading)
                    (plist-get source-section :content))
            parts))
    
    (push (format "%s %s\n%s\n"
                  (ogent-theme-icon 'context)
                  (plist-get root-section :heading)
                  (plist-get root-section :content))
          parts)
    
    (push (format "%s %s\n%s\n"
                  (ogent-theme-icon 'link)
                  (plist-get ancestors-section :heading)
                  (plist-get ancestors-section :content))
          parts)
    
    (push (format "%s %s\n%s\n"
                  (ogent-theme-icon 'search)
                  (plist-get deps-section :heading)
                  (plist-get deps-section :content))
          parts)
    
    ;; Return concatenated result
    (string-join (nreverse parts) "")))

(defun ogent-ui-context--element-at-point ()
  "Return the context element at point.
Returns a plist with :type, :data, and :index keys, or nil if not on an element."
  (save-excursion
    (beginning-of-line)
    (when (looking-at "^\\s-*\\([0-9]+\\)\\. \\[\\(.*?\\)\\]")
      (let ((index (string-to-number (match-string 1)))
            (type-str (string-trim (match-string 2))))
        (list :type (intern type-str)
              :index (1- index))))))  ; Convert to 0-based

(defun ogent-ui-context--format-element (index type name size preview)
  "Format a single context element for display.
INDEX is 1-based, TYPE is symbol, NAME is display name, SIZE is char count,
PREVIEW is a snippet of content."
  (format "%3d. [%-12s] %-30s  %6d chars  %s\n"
          index
          type
          (truncate-string-to-width name 30 nil nil "…")
          size
          (truncate-string-to-width (or preview "") 50 nil nil "…")))

(defun ogent-ui-context--render-buffer ()
  "Render the context management buffer from `ogent-ui-context--context'."
  (let ((inhibit-read-only t)
        (ctx ogent-ui-context--context)
        (index 1))
    (erase-buffer)
    ;; Header with icon
    (insert (ogent-theme-icon 'context 'ogent-theme-primary)
            " "
            (propertize "Context Manager" 'face 'ogent-theme-section-heading)
            "\n"
            (ogent-theme-separator)
            "\n\n")
    
    ;; Source context
    (when-let ((source (plist-get ctx :source-context)))
      (let* ((file (or (ogent-source-context-file source) "(unsaved)"))
             (content (ogent-source-context-content source))
             (size (length content))
             (preview (car (split-string content "\n"))))
        (insert (ogent-ui-context--format-element
                 index 'source (file-name-nondirectory file) size preview))
        (cl-incf index)))
    
    ;; Root node
    (when-let ((root (plist-get ctx :root)))
      (let* ((title (ogent-context-node-title root))
             (content (ogent-context-node-content root))
             (size (+ (length (or title "")) (length (or content ""))))
             (preview (car (split-string (or content "") "\n"))))
        (insert (ogent-ui-context--format-element
                 index 'root (or title "(no title)") size preview))
        (cl-incf index)))
    
    ;; Ancestors
    (dolist (ancestor (plist-get ctx :ancestors))
      (let* ((title (ogent-context-node-title ancestor))
             (content (ogent-context-node-content ancestor))
             (size (+ (length (or title "")) (length (or content ""))))
             (preview (car (split-string (or content "") "\n"))))
        (insert (ogent-ui-context--format-element
                 index 'ancestor (or title "(no title)") size preview))
        (cl-incf index)))
    
    ;; Dependencies
    (dolist (dep (plist-get ctx :dependencies))
      (let* ((handle (plist-get dep :handle))
             (missing-p (plist-get dep :missing-p))
             (node (plist-get dep :node))
             (title (if missing-p
                        (format "@%s (missing)" handle)
                      (format "@%s" handle)))
             (size (if node
                       (length (or (ogent-context-node-content node) ""))
                     0))
             (preview (when node
                        (car (split-string (or (ogent-context-node-content node) "") "\n")))))
        (insert (ogent-ui-context--format-element
                 index 'dependency title size (or preview "(missing)")))
        (cl-incf index)))
    
    (insert "\n")
    ;; Help line with themed keybindings
    (insert (ogent-theme-keys '("n" . "next")
                              '("p" . "prev")
                              '("d" . "delete")
                              '("a" . "add")
                              '("RET" . "preview")
                              '("q" . "quit"))
            "\n")
    (goto-char (point-min))
    ;; Move to first element
    (when (re-search-forward "^\\s-*1\\." nil t)
      (beginning-of-line))))

(defun ogent-ui-context-next-element ()
  "Move to the next context element."
  (interactive)
  (let ((current-line (line-number-at-pos)))
    (forward-line 1)
    (while (and (not (eobp))
                (not (looking-at "^\\s-*[0-9]+\\.")))
      (forward-line 1))
    (when (and (eobp) (not (looking-at "^\\s-*[0-9]+\\.")))
      (goto-char (point-min))
      (goto-char (line-beginning-position current-line))
      (message "End of elements"))))

(defun ogent-ui-context-previous-element ()
  "Move to the previous context element."
  (interactive)
  (let ((found nil))
    (forward-line -1)
    (while (and (not (bobp))
                (not (looking-at "^\\s-*[0-9]+\\.")))
      (forward-line -1))
    (when (looking-at "^\\s-*[0-9]+\\.")
      (setq found t))
    (unless found
      (message "Beginning of elements"))))

(defun ogent-ui-context-delete-element ()
  "Delete the context element at point."
  (interactive)
  (when-let ((element (ogent-ui-context--element-at-point)))
    (let ((type (plist-get element :type))
          (index (plist-get element :index)))
      (cond
       ((eq type 'source)
        (when (yes-or-no-p "Remove source context? ")
          (setq ogent-ui-context--context
                (plist-put ogent-ui-context--context :source-context nil))
          (ogent-ui-context--render-buffer)))
       
       ((eq type 'root)
        (message "Cannot delete root node"))
       
       ((eq type 'ancestor)
        (when (yes-or-no-p "Remove ancestor? ")
          (let* ((ancestors (plist-get ogent-ui-context--context :ancestors))
                 ;; Calculate actual ancestor index by subtracting previous elements
                 (ancestor-index (- index
                                    (if (plist-get ogent-ui-context--context :source-context) 1 0)
                                    (if (plist-get ogent-ui-context--context :root) 1 0)))
                 (new-ancestors (append (cl-subseq ancestors 0 ancestor-index)
                                        (cl-subseq ancestors (1+ ancestor-index)))))
            (setq ogent-ui-context--context
                  (plist-put ogent-ui-context--context :ancestors new-ancestors))
            (ogent-ui-context--render-buffer))))
       
       ((eq type 'dependency)
        (let* ((deps (plist-get ogent-ui-context--context :dependencies))
               (dep-index (- index
                             (if (plist-get ogent-ui-context--context :source-context) 1 0)
                             (if (plist-get ogent-ui-context--context :root) 1 0)
                             (length (plist-get ogent-ui-context--context :ancestors)))))
          (when (and (>= dep-index 0) (< dep-index (length deps)))
            (let* ((dep (nth dep-index deps))
                   (handle (plist-get dep :handle)))
              (when (yes-or-no-p (format "Remove dependency @%s? " handle))
                (ogent-context-exclude-handle handle)
                (let ((new-deps (append (cl-subseq deps 0 dep-index)
                                        (cl-subseq deps (1+ dep-index)))))
                  (setq ogent-ui-context--context
                        (plist-put ogent-ui-context--context :dependencies new-deps))
                  (ogent-ui-context--render-buffer)))))))))))

(defun ogent-ui-context-add-element ()
  "Add a new element to context."
  (interactive)
  (let ((handle (read-string "Enter handle (without @): ")))
    (when (and handle (not (string-empty-p handle)))
      (if-let ((node (ogent-resolve-handle handle)))
          (let* ((deps (plist-get ogent-ui-context--context :dependencies))
                 (new-dep (list :handle handle
                                :missing-p nil
                                :node node)))
            (setq deps (append deps (list new-dep)))
            (setq ogent-ui-context--context
                  (plist-put ogent-ui-context--context :dependencies deps))
            (ogent-context-include-handle handle)
            (ogent-ui-context--render-buffer)
            (message "Added @%s to context" handle))
        (when (yes-or-no-p (format "Handle @%s not found.  Add as missing? " handle))
          (let* ((deps (plist-get ogent-ui-context--context :dependencies))
                 (new-dep (list :handle handle
                                :missing-p t
                                :node nil)))
            (setq deps (append deps (list new-dep)))
            (setq ogent-ui-context--context
                  (plist-put ogent-ui-context--context :dependencies deps))
            (ogent-ui-context--render-buffer)
            (message "Added @%s as missing dependency" handle)))))))

(defun ogent-ui-context-preview-element ()
  "Preview the context element at point in another window."
  (interactive)
  (when-let ((element (ogent-ui-context--element-at-point)))
    (let ((type (plist-get element :type))
          (index (plist-get element :index)))
      (cond
       ((eq type 'source)
        (when-let ((source (plist-get ogent-ui-context--context :source-context)))
          (let ((buf (ogent-source-context-buffer source)))
            (when (buffer-live-p buf)
              (pop-to-buffer buf t)))))
       
       ((eq type 'root)
        (when-let ((root (plist-get ogent-ui-context--context :root)))
          (let ((buf (ogent-context-node-buffer root))
                (pos (ogent-context-node-begin root)))
            (when (and (buffer-live-p buf) pos)
              (pop-to-buffer buf t)
              (goto-char pos)
              (org-fold-show-context)))))
       
       ((eq type 'ancestor)
        (when-let ((ancestor (nth index (plist-get ogent-ui-context--context :ancestors))))
          (let ((buf (ogent-context-node-buffer ancestor))
                (pos (ogent-context-node-begin ancestor)))
            (when (and (buffer-live-p buf) pos)
              (pop-to-buffer buf t)
              (goto-char pos)
              (org-fold-show-context)))))
       
       ((eq type 'dependency)
        (let ((deps (plist-get ogent-ui-context--context :dependencies))
              (dep-index (- index
                            (if (plist-get ogent-ui-context--context :source-context) 1 0)
                            (if (plist-get ogent-ui-context--context :root) 1 0)
                            (length (plist-get ogent-ui-context--context :ancestors)))))
          (when (and (>= dep-index 0) (< dep-index (length deps)))
            (let* ((dep (nth dep-index deps))
                   (node (plist-get dep :node)))
              (if node
                  (let ((buf (ogent-context-node-buffer node))
                        (pos (ogent-context-node-begin node)))
                    (when (and (buffer-live-p buf) pos)
                      (pop-to-buffer buf t)
                      (goto-char pos)
                      (org-fold-show-context)))
                (message "Dependency not resolved"))))))))))

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
      (setq ogent-ui-context--context ctx)
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
     'ogent-ui-context-mode-hook)))

(provide 'ogent-ui-context)
;;; ogent-ui-context.el ends here
