;;; ogent-ui-graph-tests.el --- Tests for dependency graph -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-ui-graph)
(require 'ogent-context)

(ert-deftest ogent-graph-collect-all-handles ()
  "Test collecting all handles from a buffer."
  (with-temp-buffer
    (org-mode)
    (insert "* First Handle\n")
    (insert "Content.\n")
    (insert "* Second Handle\n")
    (insert ":PROPERTIES:\n")
    (insert ":OGENT_ID: custom-handle\n")
    (insert ":END:\n")
    (insert "More content.\n")
    (let ((handles (ogent-graph--collect-all-handles (current-buffer))))
      (should (= 2 (length handles)))
      (should (cl-some (lambda (h) (string= (plist-get h :handle) "first-handle"))
                       handles))
      (should (cl-some (lambda (h) (string= (plist-get h :handle) "custom-handle"))
                       handles)))))

(ert-deftest ogent-graph-find-references ()
  "Test finding references in a node."
  (with-temp-buffer
    (org-mode)
    (insert "* Main Node\n")
    (insert "This references @handle-one and @handle-two.\n")
    (insert "Also mentions @handle-one again.\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (let* ((element (org-element-at-point))
           (node (ogent-context--node-from-element element (current-buffer)))
           (refs (ogent-graph--find-references-in-node node (current-buffer))))
      (should (= 2 (length refs)))
      (should (member "handle-one" refs))
      (should (member "handle-two" refs)))))

(ert-deftest ogent-graph-build-adjacency-list ()
  "Test building adjacency list from buffer."
  (with-temp-buffer
    (org-mode)
    (insert "* Root Node\n")
    (insert "References @child-one and @child-two.\n")
    (insert "* Child One\n")
    (insert "No references.\n")
    (insert "* Child Two\n")
    (insert "References @child-one.\n")
    (let ((adj-list (ogent-graph--build-adjacency-list (current-buffer))))
      (should (= 3 (length adj-list)))
      ;; Root node should have 2 children
      (let ((root-entry (assoc "root-node" adj-list)))
        (should root-entry)
        (should (= 2 (length (cdr root-entry))))
        (should (member "child-one" (cdr root-entry)))
        (should (member "child-two" (cdr root-entry))))
      ;; Child one has no deps
      (let ((child1-entry (assoc "child-one" adj-list)))
        (should child1-entry)
        (should (null (cdr child1-entry))))
      ;; Child two references child one
      (let ((child2-entry (assoc "child-two" adj-list)))
        (should child2-entry)
        (should (= 1 (length (cdr child2-entry))))
        (should (member "child-one" (cdr child2-entry)))))))

(ert-deftest ogent-graph-find-roots ()
  "Test finding root handles."
  (let ((adj-list '(("root-a" . ("child"))
                    ("root-b" . ())
                    ("child" . ()))))
    (let ((roots (ogent-graph--find-roots adj-list)))
      (should (= 2 (length roots)))
      (should (member "root-a" roots))
      (should (member "root-b" roots))
      (should-not (member "child" roots)))))

(ert-deftest ogent-graph-detect-cycles-none ()
  "Test cycle detection when no cycles exist."
  (let ((adj-list '(("a" . ("b"))
                    ("b" . ("c"))
                    ("c" . ()))))
    (let ((cycles (ogent-graph--detect-cycles adj-list)))
      (should (null cycles)))))

(ert-deftest ogent-graph-detect-cycles-simple ()
  "Test detecting a simple cycle."
  (let ((adj-list '(("a" . ("b"))
                    ("b" . ("a")))))
    (let ((cycles (ogent-graph--detect-cycles adj-list)))
      (should cycles)
      (should (>= (length cycles) 1)))))

(ert-deftest ogent-graph-detect-cycles-self-reference ()
  "Test detecting a self-reference cycle."
  (let ((adj-list '(("a" . ("a"))
                    ("b" . ()))))
    (let ((cycles (ogent-graph--detect-cycles adj-list)))
      (should cycles)
      (should (cl-some (lambda (c) (and (string= (car c) "a")
                                       (string= (cdr c) "a")))
                       cycles)))))

(ert-deftest ogent-graph-detect-cycles-transitive ()
  "Test detecting a transitive cycle."
  (let ((adj-list '(("a" . ("b"))
                    ("b" . ("c"))
                    ("c" . ("a")))))
    (let ((cycles (ogent-graph--detect-cycles adj-list)))
      (should cycles)
      (should (>= (length cycles) 1)))))

(ert-deftest ogent-graph-format-tree-simple ()
  "Test formatting a simple tree."
  (with-temp-buffer
    (org-mode)
    (insert "* Root\n")
    (insert "References @child.\n")
    (insert "* Child\n")
    (insert "No deps.\n")
    (let* ((adj-list (ogent-graph--build-adjacency-list (current-buffer)))
           (cycles (ogent-graph--detect-cycles adj-list))
           (formatted (ogent-graph--format-tree adj-list cycles (current-buffer))))
      (should (stringp formatted))
      (should (string-match-p "\\* Handle Dependency Graph" formatted))
      (should (string-match-p "@root" formatted))
      (should (string-match-p "@child" formatted)))))

(ert-deftest ogent-graph-format-tree-with-cycle ()
  "Test formatting when cycles are present."
  (with-temp-buffer
    (org-mode)
    (insert "* Node A\n")
    (insert "References @node-b.\n")
    (insert "* Node B\n")
    (insert "References @node-a.\n")
    (let* ((adj-list (ogent-graph--build-adjacency-list (current-buffer)))
           (cycles (ogent-graph--detect-cycles adj-list))
           (formatted (ogent-graph--format-tree adj-list cycles (current-buffer))))
      (should (string-match-p "\\[cycle\\]" formatted))
      (should (string-match-p "Warning: Circular dependencies" formatted)))))

(ert-deftest ogent-graph-show-dependency-graph ()
  "Test the interactive command."
  (with-temp-buffer
    (org-mode)
    (insert "* Main\n")
    (insert "References @dep.\n")
    (insert "* Dep\n")
    (insert "No deps.\n")
    (ogent-show-dependency-graph)
    (let ((graph-buf (get-buffer ogent-graph-buffer-name)))
      (should graph-buf)
      (with-current-buffer graph-buf
        (goto-char (point-min))
        (should (search-forward "Handle Dependency Graph" nil t))
        (should (search-forward "@main" nil t))
        (should (search-forward "@dep" nil t)))
      (kill-buffer graph-buf))))

(ert-deftest ogent-graph-empty-buffer ()
  "Test graph generation on buffer with no headings."
  (with-temp-buffer
    (org-mode)
    (insert "Just text, no headings.\n")
    (should-error (ogent-show-dependency-graph) :type 'user-error)))

(ert-deftest ogent-graph-no-references ()
  "Test graph generation on buffer with headings but no references."
  (with-temp-buffer
    (org-mode)
    (insert "* Heading\n")
    (insert "Just plain text, no references.\n")
    (ogent-show-dependency-graph)
    (let ((graph-buf (get-buffer ogent-graph-buffer-name)))
      (should graph-buf)
      (with-current-buffer graph-buf
        (let ((content (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-match-p "Handle Dependency Graph" content))
          (should (string-match-p "@heading" content))
          (should (string-match-p "(no dependencies)" content))))
      (kill-buffer graph-buf))))

(ert-deftest ogent-graph-clickable-handles ()
  "Test that handles in graph are clickable."
  (with-temp-buffer
    (org-mode)
    (insert "* Test Node\n")
    (insert "Content.\n")
    (ogent-show-dependency-graph)
    (let ((graph-buf (get-buffer ogent-graph-buffer-name)))
      (should graph-buf)
      (with-current-buffer graph-buf
        (goto-char (point-min))
        (when (search-forward "@test-node" nil t)
          (goto-char (match-beginning 0))
          ;; Check for button properties
          (let ((button (button-at (1+ (point)))))
            (should button)
            (should (button-get button 'action)))))
      (kill-buffer graph-buf))))

(ert-deftest ogent-graph-max-depth ()
  "Test that max depth prevents infinite recursion."
  (with-temp-buffer
    (org-mode)
    (insert "* Node A\n")
    (insert "References @node-b.\n")
    (insert "* Node B\n")
    (insert "References @node-a.\n")
    (let ((ogent-graph-max-depth 2)
          (adj-list (ogent-graph--build-adjacency-list (current-buffer)))
          (cycles (ogent-graph--detect-cycles (ogent-graph--build-adjacency-list (current-buffer)))))
      (with-temp-buffer
        ;; Should not hang or error
        (insert (ogent-graph--format-tree adj-list cycles (current-buffer)))
        (should (> (buffer-size) 0))))))

(ert-deftest ogent-graph-no-roots ()
  "Test formatting when all handles are referenced."
  (with-temp-buffer
    (org-mode)
    (insert "* Node A\n")
    (insert "References @node-b.\n")
    (insert "* Node B\n")
    (insert "References @node-a.\n")
    (let* ((adj-list (ogent-graph--build-adjacency-list (current-buffer)))
           (cycles (ogent-graph--detect-cycles adj-list))
           (formatted (ogent-graph--format-tree adj-list cycles (current-buffer))))
      (should (string-match-p "No root nodes" formatted)))))

(ert-deftest ogent-graph-multiple-roots ()
  "Test formatting with multiple root nodes."
  (with-temp-buffer
    (org-mode)
    (insert "* Root One\n")
    (insert "References @child.\n")
    (insert "* Root Two\n")
    (insert "References @child.\n")
    (insert "* Child\n")
    (insert "No deps.\n")
    (let* ((adj-list (ogent-graph--build-adjacency-list (current-buffer)))
           (cycles (ogent-graph--detect-cycles adj-list))
           (formatted (ogent-graph--format-tree adj-list cycles (current-buffer))))
      (should (string-match-p "\\*\\* Roots" formatted))
      (should (string-match-p "@root-one" formatted))
      (should (string-match-p "@root-two" formatted)))))

(ert-deftest ogent-graph-isolated-nodes ()
  "Test nodes with no dependencies or dependents."
  (with-temp-buffer
    (org-mode)
    (insert "* Isolated One\n")
    (insert "No refs.\n")
    (insert "* Isolated Two\n")
    (insert "No refs either.\n")
    (let ((adj-list (ogent-graph--build-adjacency-list (current-buffer))))
      (should (= 2 (length adj-list)))
      (should (null (cdr (assoc "isolated-one" adj-list))))
      (should (null (cdr (assoc "isolated-two" adj-list)))))))

(provide 'ogent-ui-graph-tests)
;;; ogent-ui-graph-tests.el ends here
