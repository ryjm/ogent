;;; ogent-ui-context-tests.el --- Tests for ogent-ui-context -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for interactive context preview module.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-ui-context)
(require 'ogent-context)

(ert-deftest ogent-ui-context--estimate-tokens-basic ()
  "Token estimation uses ~4 chars per token."
  (should (= (ogent-ui-context--estimate-tokens "test") 1))
  (should (= (ogent-ui-context--estimate-tokens "test test test test") 5))
  (should (= (ogent-ui-context--estimate-tokens "") 0))
  (should (= (ogent-ui-context--estimate-tokens nil) 0)))

(ert-deftest ogent-ui-context--char-count-handles-nil ()
  "Character count handles nil and empty strings."
  (should (= (ogent-ui-context--char-count nil) 0))
  (should (= (ogent-ui-context--char-count "") 0))
  (should (= (ogent-ui-context--char-count "hello") 5)))

(ert-deftest ogent-ui-context--format-node-link-with-file ()
  "Format node as Org link with file:line reference."
  (with-temp-buffer
    (set-visited-file-name "/tmp/test-ogent-file.org" t)
    (insert "* Test Heading\n")
    (let* ((test-buffer (current-buffer))
           (node (make-ogent-context-node
                  :title "Test Node"
                  :id "test-node"
                  :buffer test-buffer
                  :begin (point-min))))
      (let ((result (ogent-ui-context--format-node-link node)))
        (should (string-match-p "\\[\\[file:" result))
        (should (string-match-p "Test Node\\]\\]" result))
        (should (string-match-p "(id: test-node)" result))))
    (set-visited-file-name nil)))

(ert-deftest ogent-ui-context--format-node-link-without-file ()
  "Format node without file falls back to plain text."
  (let ((node (make-ogent-context-node
               :title "Untitled Node"
               :id "no-file"
               :buffer nil
               :begin nil)))
    (let ((result (ogent-ui-context--format-node-link node)))
      (should (string= result "Untitled Node (id: no-file)")))))

(ert-deftest ogent-ui-context--format-node-link-handles-nil ()
  "Format nil node returns placeholder."
  (should (string= (ogent-ui-context--format-node-link nil) "(no node)")))

(ert-deftest ogent-ui-context-format-with-full-context ()
  "Format complete context with all sections."
  (ogent-test-with-fixture "data/fixture.org"
    (lambda ()
      (goto-char (point-min))
      (search-forward "Root Overview")
      (org-back-to-heading t)
      (let* ((context (ogent-context-build))
             (formatted (ogent-ui-context-format context)))
        ;; Check for title and total
        (should (string-match-p "^#\\+title: Context Preview" formatted))
        (should (string-match-p "Total: [0-9]+ chars (~[0-9]+ tokens)" formatted))
        
        ;; Check for sections (multiline mode)
        (should (string-match-p "\\* Root \\[[0-9]+ chars\\]" formatted))
        (should (string-match-p "\\* Ancestors" formatted))
        (should (string-match-p "\\* Dependencies \\[[0-9]+ chars\\]" formatted))))))

(ert-deftest ogent-ui-context-format-with-missing-dependencies ()
  "Format context includes missing dependency markers."
  (ogent-test-with-fixture "data/fixture.org"
    (lambda ()
      (goto-char (point-min))
      (search-forward "Root Overview")
      (org-back-to-heading t)
      (let* ((context (ogent-context-build))
             (formatted (ogent-ui-context-format context)))
        ;; Should mark missing dependencies
        (should (string-match-p "@missing-note (missing)" formatted))))))

(ert-deftest ogent-ui-context-format-empty-ancestors ()
  "Format handles empty ancestors list."
  (let* ((root (make-ogent-context-node
                :title "Root"
                :id "root"
                :content "Root content"
                :buffer (current-buffer)
                :begin (point-min)))
         (context (list :root root
                        :ancestors nil
                        :dependencies nil))
         (formatted (ogent-ui-context-format context)))
    (should (string-match-p "^\\* Ancestors" formatted))
    (should (string-match-p "(none)" formatted))))

(ert-deftest ogent-ui-context-format-source-context ()
  "Format source context from non-Org buffer."
  (with-temp-buffer
    (insert "function test() {\n  return 42;\n}")
    (setq major-mode 'javascript-mode)
    (set-visited-file-name "/tmp/test.js" t)
    (let* ((source-ctx (ogent-context--build-source-context (current-buffer)))
           (context (list :source-context source-ctx
                          :root nil
                          :ancestors nil
                          :dependencies nil))
           (formatted (ogent-ui-context-format context)))
      ;; Check for source section
      (should (string-match-p "^\\* Source Context \\[[0-9]+ chars\\]" formatted))
      (should (string-match-p "File: test.js" formatted))
      (should (string-match-p "Mode: javascript-mode" formatted))
      (should (string-match-p "#\\+begin_src javascript" formatted))
      (should (string-match-p "function test()" formatted))
      (should (string-match-p "#\\+end_src" formatted)))
    (set-visited-file-name nil)))

(ert-deftest ogent-ui-context-format-char-counts-accurate ()
  "Character counts are accurate for all sections."
  (let* ((root (make-ogent-context-node
                :title "Test"
                :id "test"
                :content "1234"
                :buffer (current-buffer)
                :begin (point-min)))
         (context (list :root root
                        :ancestors nil
                        :dependencies nil))
         (formatted (ogent-ui-context-format context)))
    ;; Root section should count title + content = "Test" (4) + "1234" (4) = 8
    (should (string-match-p "\\* Root \\[8 chars\\]" formatted))))

(ert-deftest ogent-ui-context-format-dependencies-with-content ()
  "Dependencies section includes resolved node content."
  (with-temp-buffer
    (set-visited-file-name "/tmp/test-dep.org" t)
    (insert "* Dependency Heading\n")
    (let* ((dep-node (make-ogent-context-node
                      :title "Dependency"
                      :id "dep"
                      :content "Dep content here"
                      :buffer (current-buffer)
                      :begin (point-min)))
           (context (list :root nil
                          :ancestors nil
                          :dependencies (list (list :handle "dep-handle"
                                                    :missing-p nil
                                                    :node dep-node))))
           (formatted (ogent-ui-context-format context)))
      (should (string-match-p "\\*\\* @dep-handle" formatted))
      (should (string-match-p "Dep content here" formatted))
      (should (string-match-p "\\[\\[file:.*\\]\\[Dependency\\]\\]" formatted)))
    (set-visited-file-name nil)))

;;; Context Management Buffer Tests

(ert-deftest ogent-ui-context-mode-derived-from-special-mode ()
  "Context mode should be derived from special-mode."
  (with-temp-buffer
    (ogent-ui-context-mode)
    (should (derived-mode-p 'special-mode))
    (should buffer-read-only)))

(ert-deftest ogent-ui-context-mode-keybindings ()
  "Context mode should define navigation and editing keybindings."
  (with-temp-buffer
    (ogent-ui-context-mode)
    (should (eq (lookup-key ogent-ui-context-mode-map (kbd "n"))
                #'ogent-ui-context-next-element))
    (should (eq (lookup-key ogent-ui-context-mode-map (kbd "p"))
                #'ogent-ui-context-previous-element))
    (should (eq (lookup-key ogent-ui-context-mode-map (kbd "d"))
                #'ogent-ui-context-delete-element))
    (should (eq (lookup-key ogent-ui-context-mode-map (kbd "a"))
                #'ogent-ui-context-add-element))
    (should (eq (lookup-key ogent-ui-context-mode-map (kbd "RET"))
                #'ogent-ui-context-preview-element))
    (should (eq (lookup-key ogent-ui-context-mode-map (kbd "q"))
                #'quit-window))))

(ert-deftest ogent-ui-context--format-element-basic ()
  "Element formatting should include index, type, name, size, and preview."
  (let ((result (ogent-ui-context--format-element
                 1 'root "Test Node" 100 "This is a preview")))
    (should (string-match-p "^\\s-*1\\." result))
    (should (string-match-p "root" result))
    (should (string-match-p "Test Node" result))
    (should (string-match-p "100 chars" result))
    (should (string-match-p "This is a preview" result))))

(ert-deftest ogent-ui-context--format-element-truncates-long-names ()
  "Element formatting should truncate long names with ellipsis."
  (let* ((long-name (make-string 50 ?a))
         (result (ogent-ui-context--format-element
                  1 'dependency long-name 100 "preview")))
    (should (string-match-p "…" result))))

(ert-deftest ogent-ui-context--render-buffer-with-source ()
  "Render should display source context element."
  (with-temp-buffer
    (ogent-ui-context-mode)
    (let ((source (make-ogent-source-context
                   :file "/tmp/test.js"
                   :mode "javascript-mode"
                   :content "function test() { return 42; }")))
      (setq ogent-ui-context--context (list :source-context source
                                             :root nil
                                             :ancestors nil
                                             :dependencies nil))
      (ogent-ui-context--render-buffer)
      (goto-char (point-min))
      (should (search-forward "1. [source" nil t))
      (should (search-forward "test.js" nil t)))))

(ert-deftest ogent-ui-context--render-buffer-with-root ()
  "Render should display root node element."
  (with-temp-buffer
    (ogent-ui-context-mode)
    (let ((root (make-ogent-context-node
                 :title "Root Node"
                 :content "Root content here"
                 :id "root")))
      (setq ogent-ui-context--context (list :root root
                                             :ancestors nil
                                             :dependencies nil))
      (ogent-ui-context--render-buffer)
      (goto-char (point-min))
      (should (search-forward "1. [root" nil t))
      (should (search-forward "Root Node" nil t)))))

(ert-deftest ogent-ui-context--render-buffer-with-ancestors ()
  "Render should display ancestor elements."
  (with-temp-buffer
    (ogent-ui-context-mode)
    (let ((root (make-ogent-context-node :title "Root" :content ""))
          (ancestor1 (make-ogent-context-node :title "Ancestor 1" :content "Content 1"))
          (ancestor2 (make-ogent-context-node :title "Ancestor 2" :content "Content 2")))
      (setq ogent-ui-context--context (list :root root
                                             :ancestors (list ancestor1 ancestor2)
                                             :dependencies nil))
      (ogent-ui-context--render-buffer)
      (goto-char (point-min))
      (should (search-forward "1. [root" nil t))
      (should (search-forward "2. [ancestor" nil t))
      (should (search-forward "Ancestor 1" nil t))
      (should (search-forward "3. [ancestor" nil t))
      (should (search-forward "Ancestor 2" nil t)))))

(ert-deftest ogent-ui-context--render-buffer-with-dependencies ()
  "Render should display dependency elements."
  (with-temp-buffer
    (ogent-ui-context-mode)
    (let* ((root (make-ogent-context-node :title "Root" :content ""))
           (dep-node (make-ogent-context-node :title "Dep" :content "Dep content"))
           (deps (list (list :handle "dep1" :missing-p nil :node dep-node)
                       (list :handle "dep2" :missing-p t :node nil))))
      (setq ogent-ui-context--context (list :root root
                                             :ancestors nil
                                             :dependencies deps))
      (ogent-ui-context--render-buffer)
      (goto-char (point-min))
      (should (search-forward "1. [root" nil t))
      (should (search-forward "2. [dependency" nil t))
      (should (search-forward "@dep1" nil t))
      (should (search-forward "3. [dependency" nil t))
      (should (search-forward "@dep2 (missing)" nil t)))))

(ert-deftest ogent-ui-context--element-at-point-recognizes-elements ()
  "Element at point should parse element lines correctly."
  (with-temp-buffer
    (insert "  1. [root] Test Node            100 chars  preview\n")
    (insert "  2. [dependency] @handle              50 chars   dep preview\n")
    (goto-char (point-min))
    (let ((elem (ogent-ui-context--element-at-point)))
      (should elem)
      (should (eq (plist-get elem :type) 'root))
      (should (= (plist-get elem :index) 0)))
    (forward-line 1)
    (let ((elem (ogent-ui-context--element-at-point)))
      (should elem)
      (should (eq (plist-get elem :type) 'dependency))
      (should (= (plist-get elem :index) 1)))))

(ert-deftest ogent-ui-context--element-at-point-returns-nil-on-non-element ()
  "Element at point should return nil when not on an element line."
  (with-temp-buffer
    (insert "This is not an element line\n")
    (goto-char (point-min))
    (should-not (ogent-ui-context--element-at-point))))

(ert-deftest ogent-ui-context-next-element-navigates ()
  "Next element should move to the next element line."
  (with-temp-buffer
    (ogent-ui-context-mode)
    (let ((inhibit-read-only t))
      (insert "Header\n")
      (insert "  1. [root] Test 1\n")
      (insert "Some text\n")
      (insert "  2. [dependency] Test 2\n")
      (goto-char (point-min)))
    (ogent-ui-context-next-element)
    (should (looking-at "^\\s-*1\\."))
    (ogent-ui-context-next-element)
    (should (looking-at "^\\s-*2\\."))))

(ert-deftest ogent-ui-context-previous-element-navigates ()
  "Previous element should move to the previous element line."
  (with-temp-buffer
    (ogent-ui-context-mode)
    (let ((inhibit-read-only t))
      (insert "  1. [root] Test 1\n")
      (insert "  2. [dependency] Test 2\n")
      (goto-char (point-max)))
    (ogent-ui-context-previous-element)
    (should (looking-at "^\\s-*2\\."))
    (ogent-ui-context-previous-element)
    (should (looking-at "^\\s-*1\\."))))

(ert-deftest ogent-ui-context-delete-element-removes-ancestor ()
  "Delete element should remove an ancestor from context."
  (with-temp-buffer
    (ogent-ui-context-mode)
    (let* ((root (make-ogent-context-node :title "Root" :content ""))
           (ancestor1 (make-ogent-context-node :title "Ancestor 1" :content ""))
           (ancestor2 (make-ogent-context-node :title "Ancestor 2" :content "")))
      (setq ogent-ui-context--context (list :root root
                                             :ancestors (list ancestor1 ancestor2)
                                             :dependencies nil))
      (ogent-ui-context--render-buffer)
      (goto-char (point-min))
      (search-forward "2. [ancestor")
      (beginning-of-line)
      ;; Mock yes-or-no-p to auto-confirm
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (ogent-ui-context-delete-element))
      ;; After deletion, we should have only 1 ancestor remaining
      (let ((ancestors (plist-get ogent-ui-context--context :ancestors)))
        (should (= (length ancestors) 1))))))

(ert-deftest ogent-ui-context-delete-element-excludes-dependency ()
  "Delete element should exclude a dependency handle."
  (with-temp-buffer
    (ogent-ui-context-mode)
    (let* ((root (make-ogent-context-node :title "Root" :content ""))
           (dep-node (make-ogent-context-node :title "Dep" :content ""))
           (deps (list (list :handle "test-dep" :missing-p nil :node dep-node))))
      (setq ogent-ui-context--context (list :root root
                                             :ancestors nil
                                             :dependencies deps))
      (ogent-ui-context--render-buffer)
      (goto-char (point-min))
      (search-forward "2. [dependency")
      (beginning-of-line)
      ;; Mock yes-or-no-p to auto-confirm
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (ogent-ui-context-delete-element))
      (should (member "test-dep" (ogent-context-get-exclusions)))
      ;; Clean up
      (ogent-context-clear-exclusions))))

(ert-deftest ogent-ui-context-delete-element-prevents-root-deletion ()
  "Delete element should prevent deletion of root node."
  (with-temp-buffer
    (ogent-ui-context-mode)
    (let ((root (make-ogent-context-node :title "Root" :content "Root content")))
      (setq ogent-ui-context--context (list :root root
                                             :ancestors nil
                                             :dependencies nil))
      (ogent-ui-context--render-buffer)
      (goto-char (point-min))
      (search-forward "1. [root")
      (beginning-of-line)
      (ogent-ui-context-delete-element)
      ;; Root should still be present
      (should (plist-get ogent-ui-context--context :root)))))

(ert-deftest ogent-context-manage-creates-buffer ()
  "Context manage should create and populate management buffer."
  (ogent-test-with-fixture "data/fixture.org"
    (lambda ()
      (goto-char (point-min))
      (search-forward "Root Overview")
      (org-back-to-heading t)
      (let ((ctx (ogent-context-build)))
        (ogent-context-manage ctx (current-buffer))
        (let ((buf (get-buffer ogent-ui-context-buffer-name)))
          (should (buffer-live-p buf))
          (with-current-buffer buf
            (should (eq major-mode 'ogent-ui-context-mode))
            (should ogent-ui-context--context)
            (should ogent-ui-context--source-buffer)
            (goto-char (point-min))
            (should (search-forward "Ogent Context Manager" nil t)))
          (kill-buffer buf))))))

(ert-deftest ogent-context-manage-interactive-without-args ()
  "Context manage should work interactively without args."
  (ogent-test-with-fixture "data/fixture.org"
    (lambda ()
      (goto-char (point-min))
      (search-forward "Root Overview")
      (org-back-to-heading t)
      (ogent-context-manage)
      (let ((buf (get-buffer ogent-ui-context-buffer-name)))
        (should (buffer-live-p buf))
        (with-current-buffer buf
          (should (eq major-mode 'ogent-ui-context-mode)))
        (kill-buffer buf)))))

(ert-deftest ogent-context-manage-handles-non-org-buffer ()
  "Context manage should handle non-Org buffers with source context."
  (with-temp-buffer
    (insert "function test() { return 42; }")
    (setq major-mode 'javascript-mode)
    (set-visited-file-name "/tmp/test.js" t)
    (ogent-context-manage)
    (let ((buf (get-buffer ogent-ui-context-buffer-name)))
      (should (buffer-live-p buf))
      (with-current-buffer buf
        (goto-char (point-min))
        (should (search-forward "[source" nil t))
        (should (search-forward "test.js" nil t)))
      (kill-buffer buf))
    (set-visited-file-name nil)))

(provide 'ogent-ui-context-tests)
;;; ogent-ui-context-tests.el ends here
