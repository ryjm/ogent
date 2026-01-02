;;; ogent-ui-graph.el --- Dependency graph for ogent handles -*- lexical-binding: t; -*-

;;; Commentary:
;; Visualize handle dependencies as an Org-mode tree.
;; Shows which handles reference which handles in the current buffer.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'ogent-context)

(defcustom ogent-graph-buffer-name "*ogent-graph*"
  "Buffer name for displaying dependency graphs."
  :type 'string
  :group 'ogent)

(defcustom ogent-graph-max-depth 10
  "Maximum depth for dependency traversal to prevent infinite loops."
  :type 'integer
  :group 'ogent)

(defvar-local ogent-graph--source-buffer nil
  "The source buffer this graph was generated from.")

(defun ogent-graph--collect-all-handles (buffer)
  "Collect all handles defined in BUFFER.
Returns a list of plists with :handle and :node keys.
Uses ogent-context caching for performance."
  ;; Delegate to ogent-context which has caching
  (ogent-context--collect-handles-from-buffer buffer))

(defun ogent-graph--find-references-in-node (node _buffer)
  "Find all @handle references in NODE from BUFFER.
Returns a list of handle strings (without @).
BUFFER argument is unused but kept for API consistency."
  (when node
    (let ((content (ogent-context-node-content node)))
      (ogent-context--collect-handles content))))

(defun ogent-graph--build-adjacency-list (buffer)
  "Build adjacency list of handle dependencies in BUFFER.
Returns an alist where each entry is (HANDLE . (REFERENCED-HANDLES...))."
  (let ((all-handles (ogent-graph--collect-all-handles buffer))
        (adjacency-list nil))
    (dolist (entry all-handles)
      (let* ((handle (plist-get entry :handle))
             (node (plist-get entry :node))
             (references (ogent-graph--find-references-in-node node buffer)))
        (push (cons handle references) adjacency-list)))
    (nreverse adjacency-list)))

(defun ogent-graph--detect-cycles (adjacency-list)
  "Detect cycles using DFS with color marking (white/gray/black).
ADJACENCY-LIST is the dependency map.
Returns an alist of (HANDLE . REFERENCES-FORMING-CYCLE).
Uses O(V+E) algorithm instead of O(V*E*V)."
  (let ((cycles nil)
        ;; Colors: nil=white (unvisited), 'gray (in progress), 'black (done)
        (color (make-hash-table :test 'equal)))
    
    (cl-labels ((dfs (handle parent)
                  (let ((current-color (gethash handle color)))
                    (cond
                     ;; Gray node = back edge = cycle
                     ((eq current-color 'gray)
                      (when parent
                        (push (cons parent handle) cycles))
                      t)
                     ;; Black node = already fully explored
                     ((eq current-color 'black)
                      nil)
                     ;; White node = explore
                     (t
                      (puthash handle 'gray color)
                      (dolist (child (cdr (assoc handle adjacency-list)))
                        (dfs child handle))
                      (puthash handle 'black color)
                      nil)))))
      
      ;; Run DFS from each node
      (dolist (entry adjacency-list)
        (let ((handle (car entry)))
          (unless (gethash handle color)
            (dfs handle nil)))))
    
    (nreverse cycles)))

(defun ogent-graph--find-roots (adjacency-list)
  "Find root handles (not referenced by any other handle).
ADJACENCY-LIST is the dependency map.
Returns a list of handle strings."
  (let ((all-handles (mapcar #'car adjacency-list))
        (referenced (make-hash-table :test 'equal)))
    ;; Mark all referenced handles
    (dolist (entry adjacency-list)
      (dolist (ref (cdr entry))
        (puthash ref t referenced)))
    ;; Roots are handles that are never referenced
    (cl-remove-if (lambda (h) (gethash h referenced)) all-handles)))

(defun ogent-graph--insert-tree-node (handle adjacency-list cycles depth max-depth visited-this-path source-buffer)
  "Insert tree node for HANDLE at DEPTH.
ADJACENCY-LIST is the dependency map.
CYCLES is the list of cycle pairs.
MAX-DEPTH prevents infinite recursion.
VISITED-THIS-PATH tracks handles in current path to detect cycles.
SOURCE-BUFFER is the buffer to link back to."
  (when (> depth max-depth)
    (insert (make-string (* 2 depth) ?\s) "...\n")
    (cl-return-from ogent-graph--insert-tree-node))
  
  (let* ((indent (make-string (* 2 depth) ?\s))
         (prefix (make-string (1+ depth) ?*))
         (references (cdr (assoc handle adjacency-list)))
         (is-cycle (member handle visited-this-path))
         (cycle-marker (if is-cycle " [cycle]" ""))
         (start (point)))
    
    ;; Insert heading
    (insert (format "%s @%s%s\n" prefix handle cycle-marker))
    
    ;; Make handle clickable
    (make-text-button (+ start (length prefix) 1)
                      (+ start (length prefix) 1 (length handle))
                      'action (lambda (_button)
                                (ogent-graph--goto-handle handle source-buffer))
                      'follow-link t
                      'help-echo (format "Jump to @%s definition" handle))
    
    ;; Don't recurse if we've hit a cycle
    (unless is-cycle
      (dolist (ref references)
        (ogent-graph--insert-tree-node ref adjacency-list cycles
                                       (1+ depth) max-depth
                                       (cons handle visited-this-path)
                                       source-buffer)))))

(defun ogent-graph--goto-handle (handle source-buffer)
  "Jump to HANDLE definition in SOURCE-BUFFER.
Handles the case where buffer is killed or node no longer exists."
  (if (not (buffer-live-p source-buffer))
      (message "Source buffer no longer exists")
    (pop-to-buffer source-buffer)
    (if-let ((node (ogent-resolve-handle handle (list source-buffer))))
        (let ((pos (ogent-context-node-begin node)))
          (if (and pos (>= pos (point-min)) (<= pos (point-max)))
              (progn
                (goto-char pos)
                (org-fold-show-context)
                (recenter))
            (message "Handle @%s position is invalid" handle)))
      (message "Handle @%s not found" handle))))

(defun ogent-graph--format-tree (adjacency-list cycles source-buffer)
  "Format ADJACENCY-LIST as an Org-mode tree.
CYCLES is the list of cycle pairs.
SOURCE-BUFFER is the buffer to link back to.
Returns the formatted string."
  (with-temp-buffer
    (org-mode)
    (insert "* Handle Dependency Graph\n\n")
    
    ;; Show cycle warning if any
    (when cycles
      (insert "#+begin_quote\n")
      (insert "Warning: Circular dependencies detected:\n")
      (dolist (cycle cycles)
        (insert (format "  @%s -> @%s\n" (car cycle) (cdr cycle))))
      (insert "#+end_quote\n\n"))
    
    ;; Find roots (handles not referenced by others)
    (let ((roots (ogent-graph--find-roots adjacency-list)))
      (if roots
          (progn
            (insert "** Roots (not referenced by others)\n")
            (dolist (root roots)
              (ogent-graph--insert-tree-node root adjacency-list cycles
                                             2 ogent-graph-max-depth
                                             nil source-buffer))
            (insert "\n"))
        (insert "** No root nodes (all handles are referenced)\n\n")))
    
    ;; Show all handles with their direct dependencies
    (insert "** All Dependencies\n")
    (dolist (entry adjacency-list)
      (let ((handle (car entry))
            (references (cdr entry)))
        (insert (format "*** @%s\n" handle))
        (if references
            (dolist (ref references)
              (let ((cycle-marker (if (cl-find (cons handle ref) cycles :test #'equal)
                                      " [cycle]"
                                    "")))
                (insert (format "**** @%s%s\n" ref cycle-marker))))
          (insert "**** (no dependencies)\n"))))
    
    (buffer-string)))

;;;###autoload
(defun ogent-show-dependency-graph ()
  "Display dependency graph for handles in current buffer.
Shows which handles reference which in an Org-mode tree format.
Each handle is clickable to jump to its definition."
  (interactive)
  (ogent-context--ensure-org)
  (let* ((source-buffer (current-buffer))
         (adjacency-list (ogent-graph--build-adjacency-list source-buffer))
         (cycles (ogent-graph--detect-cycles adjacency-list))
         (graph-buffer (get-buffer-create ogent-graph-buffer-name)))
    
    (unless adjacency-list
      (user-error "No handles found in current buffer"))
    
    (with-current-buffer graph-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (ogent-graph--format-tree adjacency-list cycles source-buffer))
        (goto-char (point-min))
        (org-mode)
        (setq ogent-graph--source-buffer source-buffer)
        (read-only-mode 1)))
    
    (display-buffer graph-buffer)))

(provide 'ogent-ui-graph)

;;; ogent-ui-graph.el ends here
