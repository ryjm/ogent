;;; ogent-issues-graph.el --- Dependency graph visualization -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides dependency graph visualization for beads issues.
;; Renders dependencies as navigable ASCII trees.
;; Detects cycles and computes critical paths.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;; Forward declarations
(declare-function ogent-issues-bd-list "ogent-issues-bd")
(declare-function ogent-issues-bd-get "ogent-issues-bd")
(declare-function ogent-issues-bd-project-name "ogent-issues-bd")
(declare-function ogent-issues--current-issue-id "ogent-issues")
(declare-function ogent-issues--show-detail "ogent-issues" (issue))

;; Buffer-local render state, declared before first use in the tree renderer.
(defvar-local ogent-issues-graph--collapsed-nodes nil
  "Hash-table of collapsed node IDs.
When a node ID is present in this table, its children are not rendered.")

;;; Customization

(defgroup ogent-issues-graph nil
  "Dependency graph visualization for ogent-issues."
  :group 'ogent-issues
  :prefix "ogent-issues-graph-")

(defcustom ogent-issues-graph-max-depth 10
  "Maximum depth to render in dependency trees.
Prevents infinite loops and excessive output for deep graphs."
  :type 'integer
  :group 'ogent-issues-graph)

(defcustom ogent-issues-graph-use-unicode t
  "Whether to use Unicode box-drawing characters.
Set to nil for ASCII-only terminals."
  :type 'boolean
  :group 'ogent-issues-graph)

(defcustom ogent-issues-graph-show-status t
  "Whether to show issue status in graph nodes."
  :type 'boolean
  :group 'ogent-issues-graph)

;;; Faces

(defface ogent-issues-graph-node
  '((((class color) (background light)) :foreground "#37474f")
    (((class color) (background dark)) :foreground "#b0bec5")
    (t :inherit default))
  "Face for graph node IDs."
  :group 'ogent-issues-graph)

(defface ogent-issues-graph-connector
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#546e7a")
    (t :inherit shadow))
  "Face for tree connectors (lines, branches)."
  :group 'ogent-issues-graph)

(defface ogent-issues-graph-cycle
  '((((class color) (background light)) :foreground "#c62828" :weight bold)
    (((class color) (background dark)) :foreground "#ef5350" :weight bold)
    (t :weight bold :inverse-video t))
  "Face for cycle indicators."
  :group 'ogent-issues-graph)

(defface ogent-issues-graph-critical
  '((((class color) (background light)) :foreground "#d84315" :weight bold)
    (((class color) (background dark)) :foreground "#ff7043" :weight bold)
    (t :weight bold :underline t))
  "Face for critical path nodes."
  :group 'ogent-issues-graph)

(defface ogent-issues-graph-root
  '((((class color) (background light)) :foreground "#1565c0" :weight bold)
    (((class color) (background dark)) :foreground "#64b5f6" :weight bold)
    (t :weight bold :inherit font-lock-function-name-face))
  "Face for root nodes (no incoming edges)."
  :group 'ogent-issues-graph)

;;; Data Structure

(cl-defstruct ogent-dep-graph
  "Dependency graph for issues."
  (nodes nil :documentation "Hash-table: id -> issue plist")
  (edges nil :documentation "List of (from-id to-id type) tuples")
  (reverse-edges nil :documentation "Hash-table: id -> list of (from-id type)")
  (roots nil :documentation "List of IDs with no incoming blocking edges")
  (leaves nil :documentation "List of IDs with no outgoing blocking edges")
  (cycles nil :documentation "List of cycle paths (each is a list of IDs)"))

;;; Graph Construction

(defun ogent-issues-graph-build (issues)
  "Build dependency graph from ISSUES.
ISSUES is a list of issue plists with :id, :blocks, :blocked_by,
:parent_id, :children, :related fields."
  (let ((graph (make-ogent-dep-graph
                :nodes (make-hash-table :test 'equal)
                :edges nil
                :reverse-edges (make-hash-table :test 'equal)
                :roots nil
                :leaves nil
                :cycles nil)))
    ;; Populate nodes
    (dolist (issue issues)
      (let ((id (plist-get issue :id)))
        (when id
          (puthash id issue (ogent-dep-graph-nodes graph)))))

    ;; Build edges from all dependency types
    (dolist (issue issues)
      (let ((id (plist-get issue :id)))
        (when id
          ;; blocks relationships (id blocks other -> edge from id to other)
          (dolist (blocked-id (plist-get issue :blocks))
            (when blocked-id
              (push (list id blocked-id 'blocks)
                    (ogent-dep-graph-edges graph))
              (push (list id 'blocks)
                    (gethash blocked-id (ogent-dep-graph-reverse-edges graph)))))

          ;; parent-child relationships (id is parent of child)
          (dolist (child-id (plist-get issue :children))
            (when child-id
              (push (list id child-id 'parent)
                    (ogent-dep-graph-edges graph))
              (push (list id 'parent)
                    (gethash child-id (ogent-dep-graph-reverse-edges graph)))))

          ;; related relationships (bidirectional but we track from lower ID)
          (dolist (related-id (plist-get issue :related))
            (when (and related-id (string< id related-id))
              (push (list id related-id 'related)
                    (ogent-dep-graph-edges graph)))))))

    ;; Compute roots and leaves
    (ogent-issues-graph--compute-roots-leaves graph)

    ;; Detect cycles
    (setf (ogent-dep-graph-cycles graph)
          (ogent-issues-graph--detect-cycles graph))

    graph))

(defun ogent-issues-graph--compute-roots-leaves (graph)
  "Compute root and leaf nodes in GRAPH.
Roots have no incoming blocking edges.
Leaves have no outgoing blocking edges."
  (let ((has-incoming (make-hash-table :test 'equal))
        (has-outgoing (make-hash-table :test 'equal))
        (roots nil)
        (leaves nil))
    ;; Mark nodes with edges
    (dolist (edge (ogent-dep-graph-edges graph))
      (let ((from (car edge))
            (to (cadr edge))
            (type (caddr edge)))
        (when (eq type 'blocks)
          (puthash to t has-incoming)
          (puthash from t has-outgoing))))
    ;; Find roots and leaves
    (maphash
     (lambda (id _)
       (unless (gethash id has-incoming)
         (push id roots))
       (unless (gethash id has-outgoing)
         (push id leaves)))
     (ogent-dep-graph-nodes graph))

    (setf (ogent-dep-graph-roots graph) (nreverse roots))
    (setf (ogent-dep-graph-leaves graph) (nreverse leaves))))

;;; Cycle Detection

(defun ogent-issues-graph--detect-cycles (graph)
  "Detect cycles in GRAPH using DFS.
Returns a list of cycle paths (each is a list of IDs forming the cycle)."
  (let ((visited (make-hash-table :test 'equal))
        (rec-stack (make-hash-table :test 'equal))
        (parent (make-hash-table :test 'equal))
        (cycles nil))

    (maphash
     (lambda (id _)
       (unless (gethash id visited)
         (let ((cycle (ogent-issues-graph--dfs-cycle graph id visited rec-stack parent)))
           (when cycle
             (push cycle cycles)))))
     (ogent-dep-graph-nodes graph))

    ;; Remove duplicate cycles
    (delete-dups cycles)))

(defun ogent-issues-graph--dfs-cycle (graph id visited rec-stack parent)
  "DFS from ID to detect cycles in GRAPH.
VISITED, REC-STACK, and PARENT are hash tables for tracking state.
Returns cycle path if found, nil otherwise."
  (puthash id t visited)
  (puthash id t rec-stack)

  (let ((cycle nil))
    (dolist (edge (ogent-dep-graph-edges graph))
      (when (and (string= (car edge) id)
                 (eq (caddr edge) 'blocks)
                 (not cycle))
        (let ((neighbor (cadr edge)))
          (cond
           ;; Back edge found - cycle detected
           ((gethash neighbor rec-stack)
            (setq cycle (ogent-issues-graph--extract-cycle id neighbor parent)))
           ;; Continue DFS
           ((not (gethash neighbor visited))
            (puthash neighbor id parent)
            (let ((sub-cycle (ogent-issues-graph--dfs-cycle
                              graph neighbor visited rec-stack parent)))
              (when sub-cycle
                (setq cycle sub-cycle))))))))

    (remhash id rec-stack)
    cycle))

(defun ogent-issues-graph--extract-cycle (from to parent)
  "Extract cycle path from FROM back to TO using PARENT pointers."
  (let ((path (list to))
        (current from))
    (while (and current (not (string= current to)))
      (push current path)
      (setq current (gethash current parent)))
    (when (string= current to)
      (push to path))
    path))

;;; Critical Path

(defun ogent-issues-graph-critical-path (graph)
  "Find the longest blocking chain in GRAPH.
Returns a list of issue IDs representing the critical path."
  (let ((memo (make-hash-table :test 'equal))
        (max-path nil)
        (max-length 0))

    (maphash
     (lambda (id _)
       (let ((path (ogent-issues-graph--longest-path graph id memo)))
         (when (> (length path) max-length)
           (setq max-path path
                 max-length (length path)))))
     (ogent-dep-graph-nodes graph))

    max-path))

(defun ogent-issues-graph--longest-path (graph id memo)
  "Find longest path starting from ID in GRAPH.
MEMO caches results to avoid recomputation."
  (if-let ((cached (gethash id memo)))
      cached
    (let ((max-path (list id)))
      (dolist (edge (ogent-dep-graph-edges graph))
        (when (and (string= (car edge) id)
                   (eq (caddr edge) 'blocks))
          (let* ((neighbor (cadr edge))
                 (sub-path (ogent-issues-graph--longest-path graph neighbor memo))
                 (full-path (cons id sub-path)))
            (when (> (length full-path) (length max-path))
              (setq max-path full-path)))))
      (puthash id max-path memo)
      max-path)))

;;; Tree Rendering

(defconst ogent-issues-graph--box-chars-unicode
  '((branch . "├── ")
    (last . "└── ")
    (pipe . "│   ")
    (space . "    ")
    (arrow-right . " → ")
    (arrow-left . " ← ")
    (cycle . "⟲ ")
    (root . "◉ ")
    (node . "○ ")
    (collapsed . "▸ ")
    (expanded . "▾ "))
  "Unicode box-drawing characters for tree rendering.")

(defconst ogent-issues-graph--box-chars-ascii
  '((branch . "+-- ")
    (last . "`-- ")
    (pipe . "|   ")
    (space . "    ")
    (arrow-right . " -> ")
    (arrow-left . " <- ")
    (cycle . "(C) ")
    (root . "[R] ")
    (node . "[ ] ")
    (collapsed . "[+] ")
    (expanded . "[-] "))
  "ASCII characters for tree rendering.")

(defun ogent-issues-graph--char (key)
  "Get box-drawing character for KEY."
  (let ((chars (if ogent-issues-graph-use-unicode
                   ogent-issues-graph--box-chars-unicode
                 ogent-issues-graph--box-chars-ascii)))
    (cdr (assq key chars))))

(defun ogent-issues-graph--insert-tree (graph id depth prefix visited is-last critical-path cycles)
  "Insert tree node for ID at DEPTH with PREFIX in GRAPH.
VISITED tracks already-rendered nodes to handle DAGs.
IS-LAST is non-nil if this is the last child.
CRITICAL-PATH is list of IDs on the critical path.
CYCLES is list of cycle ID sets."
  (when (>= depth ogent-issues-graph-max-depth)
    (insert prefix)
    (insert (propertize "... (max depth)" 'face 'ogent-issues-graph-connector))
    (insert "\n")
    (cl-return-from ogent-issues-graph--insert-tree))

  (let* ((issue (gethash id (ogent-dep-graph-nodes graph)))
         (status (plist-get issue :status))
         (title (plist-get issue :title))
         (is-root (member id (ogent-dep-graph-roots graph)))
         (is-critical (member id critical-path))
         (in-cycle (cl-some (lambda (c) (member id c)) cycles))
         (already-visited (gethash id visited))
         ;; Get outgoing blocking edges
         (blocks (cl-remove-if-not
                  (lambda (e)
                    (and (string= (car e) id)
                         (eq (caddr e) 'blocks)))
                  (ogent-dep-graph-edges graph)))
         (has-children (> (length blocks) 0))
         (is-collapsed (and ogent-issues-graph--collapsed-nodes
                            (gethash id ogent-issues-graph--collapsed-nodes)))
         (connector (if is-last
                        (ogent-issues-graph--char 'last)
                      (ogent-issues-graph--char 'branch))))

    ;; Insert prefix and connector
    (insert prefix)
    (when (> depth 0)
      (insert (propertize connector 'face 'ogent-issues-graph-connector)))

    ;; Insert toggle indicator for nodes with children
    (cond
     ;; Node has children - show toggle indicator
     ((and has-children (not already-visited))
      (insert (propertize (if is-collapsed
                              (ogent-issues-graph--char 'collapsed)
                            (ogent-issues-graph--char 'expanded))
                          'face (cond
                                 (in-cycle 'ogent-issues-graph-cycle)
                                 (is-root 'ogent-issues-graph-root)
                                 (t 'ogent-issues-graph-connector)))))
     ;; Cycle indicator
     (in-cycle
      (insert (propertize (ogent-issues-graph--char 'cycle)
                          'face 'ogent-issues-graph-cycle)))
     ;; Root indicator
     (is-root
      (insert (propertize (ogent-issues-graph--char 'root)
                          'face 'ogent-issues-graph-root)))
     ;; Leaf node
     (t
      (insert (ogent-issues-graph--char 'node))))

    ;; Insert issue ID with face and text properties for navigation
    (let ((id-face (cond
                    (in-cycle 'ogent-issues-graph-cycle)
                    (is-critical 'ogent-issues-graph-critical)
                    (is-root 'ogent-issues-graph-root)
                    (t 'ogent-issues-graph-node))))
      (insert (propertize id
                          'face id-face
                          'ogent-issue-id id
                          'ogent-issue issue
                          'ogent-has-children has-children
                          'mouse-face 'highlight
                          'help-echo (format "%s%s"
                                             (if has-children "TAB:toggle " "")
                                             (format "RET:visit %s" id)))))

    ;; Insert status if enabled
    (when ogent-issues-graph-show-status
      (insert " ")
      (insert (propertize (format "[%s]" (or status "?"))
                          'face (ogent-issues-graph--status-face status))))

    ;; Insert truncated title
    (when title
      (insert " ")
      (insert (truncate-string-to-width title 40 nil nil "…")))

    ;; Show child count for collapsed nodes
    (when (and has-children is-collapsed (not already-visited))
      (insert (propertize (format " (%d hidden)" (length blocks))
                          'face 'ogent-issues-graph-connector)))

    ;; Handle cycles and already-visited nodes
    (when already-visited
      (insert (propertize " (see above)" 'face 'ogent-issues-graph-connector)))

    (insert "\n")

    ;; Don't recurse if already visited or collapsed
    (unless (or already-visited is-collapsed)
      (puthash id t visited)

      ;; Recurse to children (issues this one blocks)
      (let ((children (mapcar #'cadr blocks))
            (new-prefix (concat prefix
                                (if is-last
                                    (ogent-issues-graph--char 'space)
                                  (ogent-issues-graph--char 'pipe)))))
        (dotimes (i (length children))
          (let ((child-id (nth i children))
                (is-last-child (= i (1- (length children)))))
            (ogent-issues-graph--insert-tree
             graph child-id (1+ depth) new-prefix visited is-last-child
             critical-path cycles)))))))

(defun ogent-issues-graph--status-face (status)
  "Return face for STATUS."
  (pcase status
    ("open" 'success)
    ("in_progress" 'warning)
    ("blocked" 'error)
    ("closed" 'shadow)
    (_ 'default)))

;;; Buffer and Mode

(defvar ogent-issues-graph-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-issues-graph-visit)
    (define-key map (kbd "TAB") #'ogent-issues-graph-toggle-node)
    (define-key map "n" #'ogent-issues-graph-next-node)
    (define-key map "p" #'ogent-issues-graph-prev-node)
    (define-key map "^" #'ogent-issues-graph-up-to-blocker)
    (define-key map "c" #'ogent-issues-graph-show-cycles)
    (define-key map "C" #'ogent-issues-graph-show-critical-path)
    (define-key map "g" #'ogent-issues-graph-refresh)
    (define-key map "q" #'quit-window)
    (define-key map "?" #'ogent-issues-graph-help)
    map)
  "Keymap for `ogent-issues-graph-mode'.")

(define-derived-mode ogent-issues-graph-mode special-mode "Deps"
  "Major mode for viewing issue dependency graphs.

\\{ogent-issues-graph-mode-map}"
  :group 'ogent-issues-graph
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  ;; Disable font-lock to prevent it from overriding our face text properties
  (font-lock-mode -1))

(defvar-local ogent-issues-graph--graph nil
  "The current graph being displayed.")

(defvar-local ogent-issues-graph--root-id nil
  "The root issue ID for focused view, or nil for full graph.")

(defvar-local ogent-issues-graph--critical-path nil
  "Cached critical path for current graph.")

;;; Commands

(defun ogent-issues-graph-view (&optional issue-id)
  "Show dependency graph, optionally centered on ISSUE-ID.
When called interactively without prefix, shows full graph.
With prefix argument, prompts for issue ID to center on."
  (interactive
   (list (when current-prefix-arg
           (read-string "Center on issue ID: "))))
  (require 'ogent-issues-bd)
  (let ((buf (get-buffer-create "*ogent-deps*")))
    (ogent-issues-bd-list
     (lambda (issues)
       (with-current-buffer buf
         (let ((inhibit-read-only t))
           (erase-buffer)
           (ogent-issues-graph-mode)
           (setq ogent-issues-graph--root-id issue-id)
           (setq ogent-issues-graph--graph (ogent-issues-graph-build issues))
           (setq ogent-issues-graph--critical-path
                 (ogent-issues-graph-critical-path ogent-issues-graph--graph))
           ;; Initialize collapsed-nodes hash-table if not already set
           ;; (preserves state across refresh)
           (unless ogent-issues-graph--collapsed-nodes
             (setq ogent-issues-graph--collapsed-nodes
                   (make-hash-table :test 'equal)))
           (ogent-issues-graph--render-buffer)
           (goto-char (point-min))))
       (pop-to-buffer buf)))))

(defun ogent-issues-graph--render-buffer ()
  "Render the current graph into the buffer."
  (let* ((graph ogent-issues-graph--graph)
         (root-id ogent-issues-graph--root-id)
         (critical-path ogent-issues-graph--critical-path)
         (cycles (ogent-dep-graph-cycles graph))
         (visited (make-hash-table :test 'equal)))

    ;; Header
    (insert (propertize "Dependency Graph" 'face 'bold))
    (when root-id
      (insert (format " (centered on %s)" root-id)))
    (insert "\n")

    ;; Stats line
    (let ((node-count (hash-table-count (ogent-dep-graph-nodes graph)))
          (edge-count (length (ogent-dep-graph-edges graph)))
          (cycle-count (length cycles))
          (critical-len (length critical-path)))
      (insert (propertize
               (format "%d issues, %d edges, %d cycles, critical path: %d"
                       node-count edge-count cycle-count critical-len)
               'face 'shadow))
      (insert "\n"))

    ;; Help hint
    (insert (propertize "RET:visit  TAB:toggle  n/p:nav  c:cycles  C:critical  ?:help"
                        'face 'shadow))
    (insert "\n\n")

    ;; Render graph
    (if root-id
        ;; Focused view: just render from the specified root
        (if (gethash root-id (ogent-dep-graph-nodes graph))
            (ogent-issues-graph--insert-tree
             graph root-id 0 "" visited t critical-path cycles)
          (insert (propertize (format "Issue %s not found\n" root-id)
                              'face 'error)))
      ;; Full view: render from all roots
      (let ((roots (ogent-dep-graph-roots graph)))
        (if roots
            (let ((i 0))
              (dolist (root roots)
                (ogent-issues-graph--insert-tree
                 graph root 0 "" visited (= i (1- (length roots)))
                 critical-path cycles)
                (cl-incf i)))
          ;; No roots - might all be in cycles, show all nodes
          (insert (propertize "No root nodes found (all in cycles?)\n"
                              'face 'warning))
          (maphash
           (lambda (id _)
             (unless (gethash id visited)
               (ogent-issues-graph--insert-tree
                graph id 0 "" visited t critical-path cycles)))
           (ogent-dep-graph-nodes graph)))))

    ;; Cycle warnings
    (when cycles
      (insert "\n")
      (insert (propertize "Cycles Detected:\n" 'face 'ogent-issues-graph-cycle))
      (dolist (cycle cycles)
        (insert "  ")
        (insert (propertize (string-join cycle " → ") 'face 'ogent-issues-graph-cycle))
        (insert "\n")))))

(defun ogent-issues-graph-visit ()
  "Visit the issue at point."
  (interactive)
  (if-let ((id (get-text-property (point) 'ogent-issue-id)))
      (progn
        (require 'ogent-issues)
        (ogent-issues-bd-get id
                              (lambda (issue)
                                (ogent-issues--show-detail issue))
                              (lambda (err)
                                (message "Error fetching issue: %s" err))))
    (user-error "No issue at point")))

(defun ogent-issues-graph-next-node ()
  "Move to next issue node."
  (interactive)
  (let ((pos (next-single-property-change (point) 'ogent-issue-id)))
    (if pos
        (goto-char pos)
      (message "No more nodes"))))

(defun ogent-issues-graph-prev-node ()
  "Move to previous issue node."
  (interactive)
  (let ((pos (previous-single-property-change (point) 'ogent-issue-id)))
    (if pos
        (goto-char pos)
      (message "No previous nodes"))))

(defun ogent-issues-graph-up-to-blocker ()
  "Jump to the issue that blocks this one."
  (interactive)
  (when-let* ((issue (get-text-property (point) 'ogent-issue))
              (blocked-by (plist-get issue :blocked_by))
              (blocker-id (car blocked-by)))
    (goto-char (point-min))
    (if-let ((match (text-property-search-forward 'ogent-issue-id blocker-id #'equal)))
        (goto-char (prop-match-beginning match))
      (message "Blocker %s not found in view" blocker-id))))

(defun ogent-issues-graph-toggle-node ()
  "Toggle expansion of current node's dependency subtree.
When collapsed, child nodes are hidden and a count is shown.
When expanded, the full subtree is visible."
  (interactive)
  (let ((id (get-text-property (point) 'ogent-issue-id))
        (has-children (get-text-property (point) 'ogent-has-children)))
    (cond
     ((not id)
      (user-error "No issue at point"))
     ((not has-children)
      (message "%s has no children to collapse" id))
     (t
      ;; Toggle the collapsed state
      (if (gethash id ogent-issues-graph--collapsed-nodes)
          (progn
            (remhash id ogent-issues-graph--collapsed-nodes)
            (message "Expanded: %s" id))
        (puthash id t ogent-issues-graph--collapsed-nodes)
        (message "Collapsed: %s" id))
      ;; Re-render the buffer, preserving position
      (let ((current-id id)
            (inhibit-read-only t))
        (erase-buffer)
        (ogent-issues-graph--render-buffer)
        ;; Restore position to the toggled node
        (goto-char (point-min))
        (text-property-search-forward 'ogent-issue-id current-id #'equal))))))

(defun ogent-issues-graph-show-cycles ()
  "Highlight all cycles in the graph."
  (interactive)
  (let ((cycles (ogent-dep-graph-cycles ogent-issues-graph--graph)))
    (if cycles
        (message "Cycles: %s"
                 (mapconcat (lambda (c) (string-join c "→"))
                            cycles ", "))
      (message "No cycles detected"))))

(defun ogent-issues-graph-show-critical-path ()
  "Highlight and describe the critical path."
  (interactive)
  (let ((path ogent-issues-graph--critical-path))
    (if path
        (message "Critical path (%d): %s"
                 (length path)
                 (string-join path " → "))
      (message "No critical path (no blocking relationships)"))))

(defun ogent-issues-graph-refresh ()
  "Refresh the graph view."
  (interactive)
  (ogent-issues-graph-view ogent-issues-graph--root-id))

(defun ogent-issues-graph-help ()
  "Show help for graph view."
  (interactive)
  (message "RET:visit TAB:toggle n/p:navigate ^:up c:cycles C:critical g:refresh q:quit"))

;;; Integration with ogent-issues

(defun ogent-issues-graph-view-current ()
  "View dependency graph centered on current issue."
  (interactive)
  (require 'ogent-issues)
  (if-let ((id (ogent-issues--current-issue-id)))
      (ogent-issues-graph-view id)
    (user-error "No issue at point")))

;; Canonical Evil integration so the graph buffer's single-key
;; affordances (RET visit, TAB toggle, n/p nav, c cycles, C critical,
;; g refresh, ? help, q quit) fire under Doom/Evil.
(with-eval-after-load 'evil
  (when (fboundp 'ogent-evil-display-mode-setup)
    (ogent-evil-display-mode-setup
     'ogent-issues-graph-mode ogent-issues-graph-mode-map
     'ogent-issues-graph-mode-hook #'ogent-issues-graph-refresh)))

(provide 'ogent-issues-graph)

;;; ogent-issues-graph.el ends here
