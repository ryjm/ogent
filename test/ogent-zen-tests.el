;;; ogent-zen-tests.el --- Tests for Zen Org interaction -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-ui)
(require 'ogent-zen)
(require 'ogent-context)
(require 'cl-lib)

(defun ogent-zen-tests--overlay-labels ()
  "Return display labels from active Zen overlays."
  (mapcar (lambda (overlay)
            (substring-no-properties (overlay-get overlay 'display)))
          ogent-zen--overlays))

(ert-deftest ogent-zen-subtree-prompt-converts-nested-headings ()
  "Subtree prompt conversion emits nested markdown bullets."
  (with-temp-buffer
    (org-mode)
    (insert "* Actionpad\nParent context\n** Child\nBody\n*** Grandchild\nMore\n")
    (goto-char (point-min))
    (should (equal (ogent-zen--subtree-prompt (point))
                   "- Actionpad\n  Parent context\n  - Child\n    Body\n    - Grandchild\n      More"))))

(ert-deftest ogent-zen-subtree-prompt-excludes-generated-children ()
  "Subtree prompt conversion removes generated ogent transcript children."
  (with-temp-buffer
    (org-mode)
    (insert "* Prompt\nKeep this\n** User Child\nChild body\n** Request: Old prompt\n:PROPERTIES:\n:OGENT_STYLE: zen\n:END:\nold prompt\n*** Response (m)\nold answer\n** Prior run\n:PROPERTIES:\n:OGENT_STYLE: zen\n:END:\ngone\n** Generated metadata\n:PROPERTIES:\n:OGENT_KIND: response\n:END:\ngone too\n")
    (goto-char (point-min))
    (let ((prompt (ogent-zen--subtree-prompt (point))))
      (should (string-match-p "- Prompt" prompt))
      (should (string-match-p "Keep this" prompt))
      (should (string-match-p "  - User Child" prompt))
      (should (string-match-p "Child body" prompt))
      (should-not (string-match-p "Old prompt" prompt))
      (should-not (string-match-p "old answer" prompt))
      (should-not (string-match-p "Prior run" prompt))
      (should-not (string-match-p "Generated metadata" prompt))
      (should-not (string-match-p "OGENT_STYLE" prompt)))))

(ert-deftest ogent-zen-context-transform-marks-zen-and-empties-root ()
  "Context transform marks Zen metadata and leaves shared context intact."
  (with-temp-buffer
    (org-mode)
    (insert "* Actionpad\nParent body\n** What is Actionpad?\nChild body\n")
    (goto-char (point-min))
    (search-forward "What is Actionpad?")
    (org-back-to-heading t)
    (let* ((root (make-ogent-context-node :title "What is Actionpad?"
                                          :id "child"
                                          :content "duplicate me"))
           (ancestor (make-ogent-context-node
                      :title "Actionpad"
                      :id "parent"
                      :content "Parent body\n** What is Actionpad?\nChild body\n*** Request: old\nstale transcript\n"))
           (dependencies (list (list :handle "h" :node ancestor)))
           (handles '("h"))
           (excluded '("skip"))
           (pinned '(pinned-item))
           (context (list :root root
                          :ancestors (list ancestor)
                          :handles handles
                          :dependencies dependencies
                          :excluded-handles excluded
                          :pinned pinned))
           (transformed (ogent-zen--context-transform context (point)))
           (new-root (plist-get transformed :root)))
      (should (plist-get transformed :zen-run))
      (should (equal (plist-get transformed :zen-path)
                     "Actionpad › What is Actionpad?"))
      (should-not (eq new-root root))
      (should (equal (ogent-context-node-content new-root) ""))
      (should (equal (ogent-context-node-content root) "duplicate me"))
      (let ((new-ancestor (car (plist-get transformed :ancestors))))
        (should-not (eq new-ancestor ancestor))
        ;; Ancestor content is trimmed to its own body: no child subtrees,
        ;; no generated transcripts, no duplicated prompt text.
        (should (equal (ogent-context-node-content new-ancestor)
                       "Parent body"))
        ;; The original node is untouched.
        (should (string-match-p "Request: old"
                                (ogent-context-node-content ancestor))))
      (should (eq (plist-get transformed :dependencies) dependencies))
      (should (eq (plist-get transformed :handles) handles))
      (should (eq (plist-get transformed :excluded-handles) excluded))
      (should (eq (plist-get transformed :pinned) pinned)))))


(ert-deftest ogent-zen-context-transform-adds-workspace-directive ()
  "A parent `Context:' line becomes an operational workspace root."
  (let ((ogent-zen-workspace-brief-directories '("lisp"))
        (ogent-zen-workspace-brief-max-files 4))
    (with-temp-buffer
      (org-mode)
      (insert "* Project\nContext: .\n** Idea\nGround this in code.\n")
      (goto-char (point-min))
      (search-forward "Idea")
      (org-back-to-heading t)
      (let* ((root (make-ogent-context-node :title "Idea"
                                            :id "idea"
                                            :content "Ground this in code."))
             (ancestor (make-ogent-context-node
                        :title "Project"
                        :id "project"
                        :content "Context: .\n** Idea\nGround this in code."))
             (context (list :root root :ancestors (list ancestor)))
             (transformed (ogent-zen--context-transform context (point)))
             (workspace-root (plist-get transformed :workspace-root))
             (payload (ogent-context-render-prompt "Prompt" transformed)))
        (should (equal workspace-root
                       (file-truename (file-name-as-directory default-directory))))
        (should (string-match-p "# Workspace" payload))
        (should (string-match-p "Tool-use expectation" payload))
        (should (string-match-p "Source areas: lisp" payload))
        (should (string-match-p "lisp/" payload))))))


(ert-deftest ogent-zen-context-transform-infers-workspace-from-prose ()
  "A normal sentence like \"look in ~/repo\" selects and inspects that workspace."
  (let* ((workspace-root
          (file-truename (file-name-as-directory default-directory)))
         (title (format "Look in %s for headline ideas" workspace-root))
         (root (make-ogent-context-node :title title
                                        :id "idea"
                                        :content "Ground this in the code."))
         (context (list :root root :ancestors nil))
         (transformed (with-temp-buffer
                        (org-mode)
                        (insert (format "* %s\nGround this in the code.\n"
                                        title))
                        (goto-char (point-min))
                        (ogent-zen--context-transform context (point))))
         (payload (ogent-context-render-prompt "Prompt" transformed)))
    (should (equal (plist-get transformed :workspace-root) workspace-root))
    (should (eq (plist-get transformed :workspace-source) 'natural))
    (should (plist-get transformed :workspace-tool-intent))
    (should (string-match-p "Source: inferred from natural" payload))
    (should (string-match-p "Tool-use expectation" payload))))

(ert-deftest ogent-zen-tool-calls-bind-workspace-root ()
  "Tool calls from a Zen workspace request resolve relative paths there."
  (let ((workspace-root (file-truename (file-name-as-directory default-directory)))
        captured)
    (with-temp-buffer
      (org-mode)
      (let ((request (make-ogent-ui-request
                      :buffer (current-buffer)
                      :context (list :workspace-root workspace-root)
                      :response-pos (point-marker))))
        (cl-letf (((symbol-function 'ogent-tool--name-string)
                   (lambda (_name) "probe"))
                  ((symbol-function 'ogent-tool-approval-check)
                   (lambda (_tool-name _tool-args) 'approved))
                  ((symbol-function 'ogent-ui--is-edit-tool-p)
                   (lambda (_tool-name) nil))
                  ((symbol-function 'ogent-ui--async-tool-p)
                   (lambda (_tool-name) nil))
                  ((symbol-function 'ogent-ui--execute-tool)
                   (lambda (_tool-name _tool-args)
                     (setq captured
                           (list ogent-tools-project-root default-directory))
                     "ok"))
                  ((symbol-function 'ogent-ui--insert-tool-block)
                   (lambda (&rest _args) nil)))
          (ogent-ui--handle-tool-calls
           request
           (list (list :name "probe" :args nil))
           nil))))
    (should (equal captured (list workspace-root workspace-root)))))
(ert-deftest ogent-zen-run-subtree-dispatches-without-minibuffer ()
  "Run subtree dispatches the current bullet text directly."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Child\nBody\n")
    (goto-char (point-min))
    (search-forward "Body")
    (let (captured)
      (cl-letf (((symbol-function 'ogent-ui--dispatch-request)
                 (lambda (source-buffer region-start region-end raw-prompt
                                        models preset templates
                                        &optional org-point context-transform)
                   (setq captured
                         (list :source-buffer source-buffer
                               :region-start region-start
                               :region-end region-end
                               :raw-prompt raw-prompt
                               :models models
                               :preset preset
                               :templates templates
                               :org-point org-point
                               :context-transform context-transform)))))
        (ogent-run-subtree '("m") "preset" '("template")))
      (should (eq (plist-get captured :source-buffer) (current-buffer)))
      (should-not (plist-get captured :region-start))
      (should-not (plist-get captured :region-end))
      (should (equal (plist-get captured :raw-prompt) "- Child\n  Body"))
      (should (equal (plist-get captured :models) '("m")))
      (should (equal (plist-get captured :preset) "preset"))
      (should (equal (plist-get captured :templates) '("template")))
      (should (= (plist-get captured :org-point)
                 (save-excursion
                   (goto-char (point-min))
                   (search-forward "Child")
                   (line-beginning-position))))
      (should (functionp (plist-get captured :context-transform))))))

(ert-deftest ogent-zen-run-region-dispatches-selected-text ()
  "Region scopes ask about selected text while anchoring at the user heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\nParent context.\n** Child\nBefore selected text after.\n")
    (goto-char (point-min))
    (search-forward "selected text")
    (set-mark (match-beginning 0))
    (goto-char (match-end 0))
    (activate-mark)
    (let (captured)
      (cl-letf (((symbol-function 'ogent-ui--dispatch-request)
                 (lambda (source-buffer region-start region-end raw-prompt
                                        models preset templates
                                        &optional org-point context-transform)
                   (setq captured
                         (list :source-buffer source-buffer
                               :region-start region-start
                               :region-end region-end
                               :raw-prompt raw-prompt
                               :models models
                               :preset preset
                               :templates templates
                               :org-point org-point
                               :context-transform context-transform)))))
        (ogent-zen-run-region "What should this say?" '("m")))
      (should (eq (plist-get captured :source-buffer) (current-buffer)))
      (should (equal (buffer-substring-no-properties
                      (plist-get captured :region-start)
                      (plist-get captured :region-end))
                     "selected text"))
      (should (string-match-p "What should this say\\?"
                              (plist-get captured :raw-prompt)))
      (should (string-match-p "selected text"
                              (plist-get captured :raw-prompt)))
      (should (= (plist-get captured :org-point)
                 (save-excursion
                   (goto-char (point-min))
                   (search-forward "Child")
                   (line-beginning-position)))))))

(ert-deftest ogent-zen-scope-transform-keeps-root-body-for-region ()
  "Region scopes keep the owning heading body in tree context."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\nAncestor body.\n** Child\nKeep this body.\nTarget text.\n")
    (goto-char (point-min))
    (search-forward "Target text")
    (set-mark (match-beginning 0))
    (goto-char (match-end 0))
    (activate-mark)
    (let* ((scope (ogent-zen--scope-at-point 'region "Improve" t))
           (root (make-ogent-context-node
                  :title "Child" :content "Keep this body.\nTarget text."))
           (ancestor (make-ogent-context-node
                      :title "Parent" :content "Ancestor body.\n** Child\nignored"))
           (context (list :root root :ancestors (list ancestor)))
           (transformed (ogent-zen--context-transform-for-scope
                         context scope)))
      (should (eq (plist-get transformed :zen-scope-kind) 'region))
      (should (plist-get transformed :zen-edit))
      (should (equal (ogent-context-node-content
                      (plist-get transformed :root))
                     "Keep this body.\nTarget text."))
      (should (equal (ogent-context-node-content
                      (car (plist-get transformed :ancestors)))
                     "Ancestor body.")))))

(ert-deftest ogent-zen-edit-transcript-persists-scope-metadata ()
  "Zen edit transcripts persist scope metadata for re-run and audit."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n")
    (goto-char (point-min))
    (let* ((selection (list :begin 12 :end 18 :length 6 :sha256 "abc123"))
           (context (list :zen-run t
                          :zen-edit t
                          :zen-scope-kind 'region
                          :zen-scope-instruction "Clarify"
                          :zen-selection selection
                          :zen-path "Parent"))
           (model (list :id "m" :backend 'test)))
      (ogent-ui--create-response-block "prompt" context model)
      (goto-char (point-min))
      (search-forward "Request:")
      (org-back-to-heading t)
      (should (equal (org-entry-get (point) "OGENT_KIND") "edit"))
      (should (equal (org-entry-get (point) "OGENT_SCOPE_KIND") "region"))
      (should (equal (org-entry-get (point) "OGENT_TARGET_SHA256") "abc123"))
      (should (equal (org-entry-get (point) "OGENT_EDIT_STATUS") "waiting")))))

(ert-deftest ogent-zen-run-subtree-renders-parent-bullets-end-to-end ()
  "Mocked Zen run sends parent bullets and inserts a nested response."
  (with-temp-buffer
    (org-mode)
    (insert "* Actionpad\nParent context: this notebook takes action.\n** What is Actionpad?\nShared instruction: answer tersely.\n*** (1) A notepad that takes action\nExplain this as a product principle.\n")
    (goto-char (point-min))
    (search-forward "(1) A notepad")
    (org-back-to-heading t)
    (let ((captured-prompt nil)
          (ogent-ui--request-table (make-hash-table :test #'equal)))
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (prompt &rest args)
                   (setq captured-prompt prompt)
                   (when-let ((callback (plist-get args :callback)))
                     (funcall callback "A notebook action is a note that can execute." nil)
                     (funcall callback nil '(:done t)))
                   'mock-request)))
        (ogent-run-subtree '("gpt-4o-mini")))
      (should (string-match-p "# User Prompt" captured-prompt))
      (should (string-match-p "- (1) A notepad that takes action" captured-prompt))
      (should (string-match-p "# Parent Bullets" captured-prompt))
      (should (string-match-p "## Parent 1: Actionpad" captured-prompt))
      (should (string-match-p "Parent context: this notebook takes action" captured-prompt))
      (should (string-match-p "## Parent 2: What is Actionpad?" captured-prompt))
      (should (string-match-p "Shared instruction: answer tersely" captured-prompt))
      (should-not (string-match-p "# Org Ancestors" captured-prompt))
      (goto-char (point-min))
      (search-forward "**** Request:")
      (let ((request-pos (line-beginning-position)))
        (should (string= (org-entry-get request-pos "OGENT_STYLE") "zen"))
        (should (string= (org-entry-get request-pos "OGENT_KIND") "request"))
        (should (string= (org-entry-get request-pos "OGENT_PATH")
                         "Actionpad › What is Actionpad? › (1) A notepad that takes action")))
      (search-forward "***** Response (gpt-4o-mini)")
      (search-forward "A notebook action is a note that can execute."))))

(ert-deftest ogent-zen-run-persists-workspace-grounding-properties ()
  "Zen runs persist workspace grounding metadata for later overlays."
  (let ((workspace-root (file-truename (file-name-as-directory default-directory)))
        (captured-prompt nil)
        (ogent-ui--request-table (make-hash-table :test #'equal)))
    (with-temp-buffer
      (org-mode)
      (insert "* Project\nContext: .\n** Idea\nGround this in code.\n")
      (goto-char (point-min))
      (search-forward "Idea")
      (org-back-to-heading t)
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (prompt &rest args)
                   (setq captured-prompt prompt)
                   (when-let ((callback (plist-get args :callback)))
                     (funcall callback "Grounded answer." nil)
                     (funcall callback nil '(:done t)))
                   'mock-request)))
        (ogent-run-subtree '("gpt-4o-mini")))
      (should (string-match-p "# Workspace" captured-prompt))
      (goto-char (point-min))
      (search-forward "Request:")
      (let ((request-pos (line-beginning-position)))
        (should (equal (org-entry-get request-pos "OGENT_WORKSPACE_ROOT")
                       workspace-root))
        (should (equal (org-entry-get request-pos "OGENT_WORKSPACE")
                       (file-name-nondirectory
                        (directory-file-name workspace-root))))
        (should (equal (org-entry-get request-pos "OGENT_TOOLS") "true"))))))

(ert-deftest ogent-zen-refresh-overlays-generated-headings ()
  "Overlay refresh compacts generated headings without changing Org text."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Explain\n:PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n#+begin_src text :model m :status waiting\n#+end_src\n\n*** Response (m)\n\n** Request: Done\n:PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:OGENT_PATH: Parent › Leaf title\n:END:\n#+begin_src text :model m :status done\n#+end_src\n\n*** Response (m)\nAnswer\n")
      (ogent-zen-mode 1)
      (let ((labels (ogent-zen-tests--overlay-labels)))
        (should (member "○ Explain · waiting · m" labels))
        (should (member "↳ m · waiting" labels))
        (should (member "✓ Leaf title · m" labels)))
      (goto-char (point-min))
      (should (search-forward "Request: Explain" nil t))
      (should (search-forward "Response (m)" nil t)))))

(ert-deftest ogent-zen-own-body-trims-children-and-drawer ()
  "Own-body extraction drops child subtrees and a leading drawer."
  (should (equal (ogent-zen--own-body
                  ":PROPERTIES:\n:ID: x\n:END:\nOwn text.\nMore.\n** Child\nbody\n*** Request: old\n")
                 "Own text.\nMore."))
  (should (equal (ogent-zen--own-body "Just body\n") "Just body"))
  (should (equal (ogent-zen--own-body "") "")))

(ert-deftest ogent-zen-run-subtree-climbs-out-of-transcript ()
  "Running from inside a generated transcript re-runs the owning bullet."
  (with-temp-buffer
    (org-mode)
    (insert "* Notebook\n** Idea\nIdea body\n*** Request: old\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model m :status done\nx\n#+end_src\n\n"
            "**** Response (m)\nOld answer\n")
    (goto-char (point-min))
    (search-forward "Old answer")
    (let (captured)
      (cl-letf (((symbol-function 'ogent-ui--dispatch-request)
                 (lambda (_source-buffer _rs _re raw-prompt
                                         _models _preset _templates
                                         &optional org-point _transform)
                   (setq captured (cons raw-prompt org-point)))))
        (ogent-run-subtree))
      (should (equal (car captured) "- Idea\n  Idea body"))
      (should (= (cdr captured)
                 (save-excursion
                   (goto-char (point-min))
                   (search-forward "** Idea")
                   (line-beginning-position)))))))

(ert-deftest ogent-zen-dispatch-anchors-transcript-at-bullet ()
  "A run started from inside a transcript inserts a sibling transcript."
  (with-temp-buffer
    (org-mode)
    (insert "* Notebook\nIntro.\n** Idea\nIdea body.\n")
    (goto-char (point-min))
    (search-forward "Idea body.")
    (let ((ogent-ui--request-table (make-hash-table :test #'equal)))
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (_prompt &rest args)
                   (when-let ((callback (plist-get args :callback)))
                     (funcall callback "Answer." nil)
                     (funcall callback nil '(:done t)))
                   'mock-request)))
        (ogent-run-subtree '("gpt-4o-mini"))
        ;; Second run with point inside the first transcript.
        (goto-char (point-min))
        (search-forward "Answer.")
        (ogent-run-subtree '("gpt-4o-mini")))
      (let (levels)
        (goto-char (point-min))
        (while (re-search-forward "^\\(\\*+\\) Request:" nil t)
          (push (length (match-string 1)) levels))
        ;; Both transcripts attach to the bullet at the same level.
        (should (equal (nreverse levels) '(3 3)))))))

(ert-deftest ogent-zen-collapse-previous-runs-on-new-run ()
  "Starting a new run folds previous siblings and prompt plumbing."
  (with-temp-buffer
    (org-mode)
    (insert "* Notebook\n** Idea\nIdea body.\n")
    (ogent-zen-mode 1)
    (goto-char (point-min))
    (search-forward "Idea body.")
    (let ((ogent-ui--request-table (make-hash-table :test #'equal)))
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (_prompt &rest args)
                   (when-let ((callback (plist-get args :callback)))
                     (funcall callback "Answer." nil)
                     (funcall callback nil '(:done t)))
                   'mock-request)))
        (ogent-run-subtree '("gpt-4o-mini"))
        (goto-char (point-min))
        (search-forward "Idea body.")
        (ogent-run-subtree '("gpt-4o-mini")))
      (goto-char (point-min))
      (search-forward "Request:")
      (end-of-line)
      ;; First transcript body is folded away.
      (should (invisible-p (1+ (point))))
      ;; The new transcript's drawer and prompt block are folded but the
      ;; transcript heading stays visible.
      (goto-char (point-max))
      (search-backward ":OGENT_STYLE:")
      (should (invisible-p (point)))
      (search-forward "#+begin_src text")
      (forward-line 1)
      (should (invisible-p (point))))))

(ert-deftest ogent-zen-fold-noise-hides-tool-drawers ()
  "Zen folding hides entire tool drawers, including the drawer header."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Request: Work\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model m :status done\nprompt\n#+end_src\n"
            ":TOOL:\n▶ grep: lisp/ogent-zen.el ✓\n:END:\n\n"
            "*** Response (m)\nanswer\n")
    (ogent-zen-mode 1)
    (goto-char (point-min))
    (search-forward ":TOOL:")
    (should (invisible-p (match-beginning 0)))
    (search-forward "▶ grep")
    (should (invisible-p (match-beginning 0)))))

(ert-deftest ogent-zen-rerun-replaces-transcript ()
  "Re-run deletes the transcript at point and dispatches the bullet again."
  (with-temp-buffer
    (org-mode)
    (insert "* Notebook\n** Idea\nIdea body.\n")
    (goto-char (point-min))
    (search-forward "Idea body.")
    (let ((calls 0)
          (ogent-ui--request-table (make-hash-table :test #'equal)))
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (_prompt &rest args)
                   (setq calls (1+ calls))
                   (when-let ((callback (plist-get args :callback)))
                     (funcall callback "Answer." nil)
                     (funcall callback nil '(:done t)))
                   'mock-request)))
        (ogent-run-subtree '("gpt-4o-mini"))
        (goto-char (point-min))
        (search-forward "Answer.")
        (ogent-zen-rerun))
      (should (= calls 2))
      ;; Still exactly one transcript: the rerun replaced the old one.
      (goto-char (point-min))
      (let ((requests 0))
        (while (re-search-forward "^\\*+ Request:" nil t)
          (setq requests (1+ requests)))
        (should (= requests 1))))))

(ert-deftest ogent-zen-rerun-edit-preserves-scope-metadata ()
  "Re-running an edit transcript dispatches the same editable scope."
  (with-temp-buffer
    (org-mode)
    (insert "* Notebook\n** Idea\nRewrite this target text.\n")
    (let ((beg (progn
                 (goto-char (point-min))
                 (search-forward "target text")
                 (match-beginning 0)))
          (end (match-end 0)))
      (goto-char (point-max))
      (insert (format "*** Request: Rewrite\n:PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: edit\n:OGENT_SCOPE_KIND: region\n:OGENT_TARGET_BEGIN: %d\n:OGENT_TARGET_END: %d\n:OGENT_INSTRUCTION: Tighten it\n:END:\n#+begin_src text :model m :status done\nprompt\n#+end_src\n\n**** Response (m)\n<<<<<<< SEARCH\ntarget text\n=======\nclear text\n>>>>>>> REPLACE\n"
                      beg end)))
    (goto-char (point-min))
    (search-forward "clear text")
    (let (captured)
      (cl-letf (((symbol-function 'ogent-ui--dispatch-request)
                 (lambda (_source-buffer region-start region-end raw-prompt
                                         _models _preset _templates
                                         &optional org-point _context-transform)
                   (setq captured
                         (list :region-start region-start
                               :region-end region-end
                               :raw-prompt raw-prompt
                               :org-point org-point)))))
        (ogent-zen-rerun))
      (should (equal (buffer-substring-no-properties
                      (plist-get captured :region-start)
                      (plist-get captured :region-end))
                     "target text"))
      (should (string-match-p "Tighten it" (plist-get captured :raw-prompt)))
      (should (= (plist-get captured :org-point)
                 (save-excursion
                   (goto-char (point-min))
                   (search-forward "Idea")
                   (line-beginning-position)))))))

(ert-deftest ogent-zen-rerun-refuses-streaming-run ()
  "Re-run refuses to delete a transcript that is still streaming."
  (with-temp-buffer
    (org-mode)
    (insert "* Idea\nBody.\n** Request: running\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model m :status typing\nx\n#+end_src\n\n"
            "*** Response (m)\npartial\n")
    (goto-char (point-min))
    (search-forward "partial")
    (should-error (ogent-zen-rerun) :type 'user-error)))

(ert-deftest ogent-zen-ctrl-c-ctrl-c-reruns-transcript ()
  "C-c C-c handler claims Zen transcripts and ignores everything else."
  (with-temp-buffer
    (org-mode)
    (insert "* Idea\nBody.\n** Request: old\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model m :status done\nx\n#+end_src\n\n"
            "*** Response (m)\nanswer\n")
    (ogent-zen-mode 1)
    (let (rerun-called)
      (cl-letf (((symbol-function 'ogent-zen-rerun)
                 (lambda () (setq rerun-called t))))
        ;; On the user bullet: handler must decline.
        (goto-char (point-min))
        (should-not (ogent-zen--ctrl-c-ctrl-c))
        (should-not rerun-called)
        ;; Inside the transcript: handler claims and reruns.
        (search-forward "answer")
        (should (ogent-zen--ctrl-c-ctrl-c))
        (should rerun-called)))))

(ert-deftest ogent-zen-response-label-includes-latency ()
  "Response labels include elapsed latency when present."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Idea\n** Request: done run\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status done :latency 1.2s\nx\n#+end_src\n\n"
              "*** Response (m)\nanswer\n")
      (ogent-zen-refresh)
      (should (member "↳ m · 1.2s"
                      (ogent-zen-tests--overlay-labels))))))

(ert-deftest ogent-zen-rich-request-label-shows-review-workspace-and-tools ()
  "Request labels summarize review state and workspace grounding by default."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Ideas\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n"
              ":OGENT_PATH: Parent › Ideas\n"
              ":OGENT_WORKSPACE_ROOT: /tmp/ogent/\n"
              ":OGENT_TOOLS: true\n"
              ":OGENT_REVIEW: accepted\n:END:\n"
              "#+begin_src text :model gpt-5.5 :status done :latency 2.4s\n"
              "prompt\n#+end_src\n\n"
              "*** Response (gpt-5.5)\nanswer\n")
      (ogent-zen-refresh)
      (should
       (member
        "✓ Ideas · ◆ accepted · ogent/ · tools · gpt-5.5 · 2.4s"
        (ogent-zen-tests--overlay-labels))))))

(ert-deftest ogent-zen-headlines-distinguish-tool-and-empty-states ()
  "Zen labels distinguish tool use from empty completed responses."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Use tools\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n"
              ":OGENT_TOOLS: true\n:END:\n"
              "#+begin_src text :model m :status tool\nprompt\n#+end_src\n\n"
              "*** Response (m)\n\n"
              "** Request: Empty\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status done\nprompt\n#+end_src\n\n"
              "*** Response (m)\n\n")
      (ogent-zen-refresh)
      (let ((labels (ogent-zen-tests--overlay-labels)))
        (should (member "◐ using tools · Use tools · m"
                        labels))
        (should (member "↳ m · using tools" labels))
        (should (member "⚠ Empty · 0 chars · m"
                        labels))
        (should (member "↳ m · 0 chars"
                        labels))))))

(ert-deftest ogent-zen-review-command-updates-structured-metadata ()
  "Review commands persist structured review metadata and visible drawers."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Candidate\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status done\nprompt\n#+end_src\n\n"
              "*** Response (m)\nanswer\n")
      (goto-char (point-min))
      (search-forward "Request:")
      (ogent-zen-mark-stale)
      (should (equal (org-entry-get (point) "OGENT_LINEAGE") "stale"))
      (should (equal (org-entry-get (point) "OGENT_REVIEW") "stale"))
      (goto-char (point-min))
      (should (search-forward ":REVIEW:" nil t))
      (should (search-forward "Lineage: stale" nil t))
      (should (member "✓ Candidate · ◇ stale · m"
                      (ogent-zen-tests--overlay-labels)))
      (goto-char (point-min))
      (search-forward "Request:")
      (ogent-zen-clear-review)
      (should-not (org-entry-get (point) "OGENT_REVIEW"))
      (should-not (org-entry-get (point) "OGENT_LINEAGE"))
      (goto-char (point-min))
      (should-not (search-forward ":REVIEW:" nil t)))))

(ert-deftest ogent-zen-accept-response-sets-structured-review-state ()
  "Accepting a response records decision metadata and selects its model."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Compare\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model many :status done\nprompt\n#+end_src\n\n"
              "*** Response (m1)\nanswer one\n"
              "*** Response (m2)\nanswer two\n")
      (goto-char (point-min))
      (search-forward "Response (m2)")
      (org-back-to-heading t)
      (ogent-zen-accept-response)
      (should (equal (org-entry-get (point) "OGENT_DECISION") "accepted"))
      (should (equal (org-entry-get (point) "OGENT_REVIEW_STATUS") "reviewed"))
      (should (equal (org-entry-get (point) "OGENT_REVIEW") "accepted"))
      (goto-char (point-min))
      (search-forward "Request: Compare")
      (should (equal (org-entry-get (point) "OGENT_SELECTED_MODEL") "m2"))
      (should (equal (org-entry-get (point) "OGENT_REVIEW_STATUS") "reviewed"))
      (should-not (org-entry-get (point) "OGENT_DECISION"))
      (goto-char (point-min))
      (search-forward "Response (m2)")
      (should (search-forward "Decision: accepted" nil t))
      (goto-char (point-min))
      (search-forward "Request: Compare")
      (should (search-forward "Selected model: m2" nil t)))))

(ert-deftest ogent-review-accept-dispatches-to-zen-response ()
  "Generic review accept uses Zen semantics inside Zen transcripts."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Request: Compare\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model many :status done\nprompt\n#+end_src\n\n"
            "*** Response (m1)\nanswer one\n")
    (goto-char (point-min))
    (search-forward "Response (m1)")
    (org-back-to-heading t)
    (ogent-review-accept)
    (should (equal (org-entry-get (point) "OGENT_DECISION") "accepted"))
    (goto-char (point-min))
    (search-forward "Request: Compare")
    (should (equal (org-entry-get (point) "OGENT_SELECTED_MODEL") "m1"))))

(ert-deftest ogent-zen-accept-response-clears-earlier-accepted-sibling ()
  "Accepting one response clears accepted state from earlier siblings."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Request: Compare\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model many :status done\nprompt\n#+end_src\n\n"
            "*** Response (m1)\n:PROPERTIES:\n:OGENT_DECISION: accepted\n:OGENT_REVIEW: accepted\n:END:\nanswer one\n"
            "*** Response (m2)\nanswer two\n")
    (goto-char (point-min))
    (search-forward "Response (m2)")
    (org-back-to-heading t)
    (ogent-zen-accept-response)
    (goto-char (point-min))
    (search-forward "Response (m1)")
    (org-back-to-heading t)
    (should-not (org-entry-get (point) "OGENT_DECISION"))
    (should-not (org-entry-get (point) "OGENT_REVIEW"))))

(ert-deftest ogent-review-next-jumps-to-zen-item-needing-attention ()
  "Generic review navigation jumps to the next Zen item needing review."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Request: Reviewed\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model many :status done\nprompt\n#+end_src\n\n"
            "*** Response (m1)\n:PROPERTIES:\n:OGENT_DECISION: accepted\n:OGENT_REVIEW: accepted\n:END:\nkept\n"
            "*** Response (m2)\nneeds attention\n")
    (goto-char (point-min))
    (search-forward "Response (m1)")
    (org-back-to-heading t)
    (ogent-review-next)
    (should (looking-at "\\*\\*\\* Response (m2)"))))

(ert-deftest ogent-review-dashboard-lists-review-items ()
  "The review dashboard shows pending and accepted Zen items."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Request: Compare\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model many :status done\nprompt\n#+end_src\n\n"
            "*** Response (m1)\n:PROPERTIES:\n:OGENT_DECISION: accepted\n:OGENT_REVIEW: accepted\n:END:\nkept\n"
            "*** Response (m2)\nneeds attention\n")
    (let ((source (current-buffer)))
      (ogent-review-dashboard)
      (with-current-buffer "*Ogent Review*"
        (should (equal ogent-review-dashboard-source-buffer source))
        (should (string-match-p "Needs attention" (buffer-string)))
        (should (string-match-p "\\[unreviewed\\] response m2" (buffer-string)))
        (should (string-match-p "\\[accepted\\] response m1" (buffer-string))))
      (kill-buffer "*Ogent Review*"))))

(ert-deftest ogent-zen-copy-response-copies-body-from-request ()
  "Copy response copies only the nearest Zen answer body from a request."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Request: Done\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model m :status done\nprompt\n#+end_src\n\n"
            "*** Response (m)\nHere are three suggestions:\n\n"
            "1. Rename the request headline.\n"
            "2. Improve response labels.\n"
            "3. Add copy response command.\n")
    (goto-char (point-min))
    (search-forward "Request: Done")
    (let ((text (ogent-zen-copy-response)))
      (should (equal text
                     "Here are three suggestions:\n\n1. Rename the request headline.\n2. Improve response labels.\n3. Add copy response command."))
      (should (equal (current-kill 0 t) text)))))

(ert-deftest ogent-zen-copy-response-copies-body-from-response ()
  "Copy response works from a response heading or body."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Request: Done\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model m :status done\nprompt\n#+end_src\n\n"
            "*** Response (m)\n\n  indented answer\n")
    (goto-char (point-min))
    (search-forward "indented")
    (let ((text (ogent-zen-copy-response)))
      (should (equal text "  indented answer"))
      (should (equal (current-kill 0 t) text)))))

(ert-deftest ogent-zen-copy-response-skips-tool-drawers ()
  "Copy response omits generated tool drawers from the answer body."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Request: Done\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model m :status done\nprompt\n#+end_src\n\n"
            "*** Response (m)\n"
            ":TOOL:\n▶ grep: lisp/ogent-zen.el ✓\n:END:\n\n"
            "Actual answer.\n")
    (goto-char (point-min))
    (search-forward "Request: Done")
    (let ((text (ogent-zen-copy-response)))
      (should (equal text "Actual answer."))
      (should (equal (current-kill 0 t) text)))))

(ert-deftest ogent-zen-apply-last-edit-previews-region-replacement ()
  "Structured edit responses replace only the target text with inline diff."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Child\nThe old wording stays here.\n")
    (let ((beg (progn
                 (goto-char (point-min))
                 (search-forward "old wording")
                 (match-beginning 0)))
          (end (match-end 0)))
      (goto-char (point-max))
      (insert (format "*** Request: Rewrite\n:PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: edit\n:OGENT_SCOPE_KIND: region\n:OGENT_TARGET_BEGIN: %d\n:OGENT_TARGET_END: %d\n:END:\n#+begin_src text :model m :status done\nprompt\n#+end_src\n\n**** Response (m)\n<<<<<<< SEARCH\nold wording\n=======\nnew wording\n>>>>>>> REPLACE\n"
                      beg end))
      (goto-char (point-min))
      (search-forward "Request: Rewrite")
      (let ((request (line-beginning-position)))
        (ogent-zen-apply-last-edit)
        (should (search-backward "new wording" nil t))
        (should (bound-and-true-p inline-diff-mode))
        (goto-char request)
        (should (equal (org-entry-get (point) "OGENT_EDIT_STATUS")
                       "preview"))))))

(ert-deftest ogent-zen-apply-last-edit-records-validation-error ()
  "Failed edit application records an actionable transcript error."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Child\nOriginal text.\n"
            "*** Request: Rewrite\n:PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: edit\n:OGENT_SCOPE_KIND: region\n:END:\n#+begin_src text :model m :status done\nprompt\n#+end_src\n\n**** Response (m)\nNo structured edit here.\n")
    (goto-char (point-min))
    (search-forward "Request: Rewrite")
    (should-error (ogent-zen-apply-last-edit) :type 'user-error)
    (org-back-to-heading t)
    (should (equal (org-entry-get (point) "OGENT_EDIT_STATUS") "error"))
    (should (search-forward "Edit preview failed:" nil t))))

(ert-deftest ogent-zen-edit-falls-back-to-heading-search ()
  "Edit validation falls back to unique SEARCH text inside the heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Child\nUnique target text.\nOther text.\n")
    (goto-char (point-min))
    (search-forward "Other")
    (let ((scope (make-ogent-zen-scope
                  :kind 'region
                  :heading-point (save-excursion
                                   (goto-char (point-min))
                                   (search-forward "Child")
                                   (line-beginning-position))
                  :start-marker (copy-marker (match-beginning 0))
                  :end-marker (copy-marker (match-end 0) t)
                  :edit-p t)))
      (let ((bounds (ogent-zen-edit--locate-target scope "Unique target text")))
        (should (equal (buffer-substring-no-properties
                        (car bounds) (cdr bounds))
                       "Unique target text"))))))

(ert-deftest ogent-zen-edit-errors-on-duplicate-search-text ()
  "Edit validation rejects duplicate SEARCH text inside the owning heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Child\ndup\ndup\n")
    (let ((scope (make-ogent-zen-scope
                  :kind 'region
                  :heading-point (save-excursion
                                   (goto-char (point-min))
                                   (search-forward "Child")
                                   (line-beginning-position))
                  :edit-p t)))
      (should-error (ogent-zen-edit--locate-target scope "dup")
                    :type 'user-error))))

(ert-deftest ogent-zen-reject-edit-restores-original-text ()
  "Rejecting a Zen edit preview restores the original selected text."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Child\nThe old wording stays here.\n")
    (let* ((heading (save-excursion
                      (goto-char (point-min))
                      (search-forward "Child")
                      (line-beginning-position)))
           (beg (progn
                  (goto-char (point-min))
                  (search-forward "old wording")
                  (match-beginning 0)))
           (end (match-end 0))
           (scope (make-ogent-zen-scope
                   :kind 'region
                   :heading-point heading
                   :start-marker (copy-marker beg)
                   :end-marker (copy-marker end t)
                   :edit-p t))
           (request-marker (copy-marker heading)))
      (ogent-zen-edit--preview-replacement
       scope "old wording" "new wording" request-marker)
      (should (search-backward "new wording" nil t))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _args) t)))
        (ogent-zen-reject-edit))
      (goto-char (point-min))
      (should (search-forward "old wording" nil t))
      (should-not (search-forward "new wording" nil t)))))

(ert-deftest ogent-zen-folded-request-label-shows-response-summary ()
  "Folded completed request labels show a semantic response summary."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Summaries\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status done\nprompt\n#+end_src\n\n"
              "*** Response (m)\n\n"
              ":TOOL:\n▶ read-file: lisp/ogent-zen.el ✓\n:END:\n\n"
              "Prioritize run-card overlays and review states.\n")
      (goto-char (point-min))
      (search-forward "Request: Summaries")
      (beginning-of-line)
      (when (fboundp 'org-fold-hide-subtree)
        (org-fold-hide-subtree))
      (ogent-zen-refresh)
      (should (member
               "✓ Prioritize run-card overlays and review states. · from “Summaries” · 1 tool · m · folded"
               (ogent-zen-tests--overlay-labels))))))

(ert-deftest ogent-zen-folded-request-adds-preview-line ()
  "Folded completed request overlays add a muted virtual result preview."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Preview\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status done\nprompt\n#+end_src\n\n"
              "*** Response (m)\nPreview this answer in a virtual line.\n")
      (goto-char (point-min))
      (search-forward "Request: Preview")
      (beginning-of-line)
      (when (fboundp 'org-fold-hide-subtree)
        (org-fold-hide-subtree))
      (ogent-zen-refresh)
      (let ((overlay
             (cl-find-if
              (lambda (candidate)
                (string-prefix-p
                 "✓ Preview this answer"
                 (substring-no-properties
                  (overlay-get candidate 'display))))
              ogent-zen--overlays)))
        (should overlay)
        (should (equal (substring-no-properties
                        (overlay-get overlay 'after-string))
                       "\n  “Preview this answer in a virtual line.”"))))))

(ert-deftest ogent-zen-stores-derived-result-title ()
  "Zen completion can persist a deterministic local result title."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Request: Title me\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model m :status done\nprompt\n#+end_src\n\n"
            "*** Response (m)\n# Polished result cards\n\nBody.\n")
    (goto-char (point-min))
    (search-forward "Request: Title me")
    (beginning-of-line)
    (let ((title (ogent-zen-store-result-title (point))))
      (should (equal title "Polished result cards"))
      (should (equal (org-entry-get (point) "OGENT_RESULT_TITLE")
                     "Polished result cards")))))

(ert-deftest ogent-zen-request-label-shows-tool-count-and-area ()
  "Request labels show concrete tool counts and compact workspace areas."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Work\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n"
              ":OGENT_WORKSPACE_ROOT: /tmp/ogent/\n:END:\n"
              "#+begin_src text :model m :status done\nprompt\n#+end_src\n"
              ":TOOL:\n▶ read-file: lisp/ogent-zen.el ✓\n:END:\n"
              ":TOOL:\n▶ grep: lisp/ui/ogent-ui.el ✓\n:END:\n\n"
              "*** Response (m)\nanswer\n")
      (ogent-zen-refresh)
      (should (member "✓ Work · ogent:lisp/ · 2 tools · m"
                      (ogent-zen-tests--overlay-labels))))))

(ert-deftest ogent-zen-active-tool-label-shows-current-work ()
  "Active request labels show the concrete tool currently doing work."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Search code\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status tool\nprompt\n#+end_src\n"
              ":TOOL:\n▶ grep: lisp/ogent-zen.el ◐\n:END:\n\n"
              "*** Response (m)\n\n")
      (ogent-zen-refresh)
      (should (member "◐ searching lisp/ogent-zen.el · Search code · m"
                      (ogent-zen-tests--overlay-labels))))))

(ert-deftest ogent-zen-tool-error-label-names-tool ()
  "Tool error labels stay diagnostic instead of failing the request card."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Broken\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status done\nprompt\n#+end_src\n"
              ":TOOL:\n▶ grep: bad pattern ✗\n"
              "#+begin_src text :result\nTool error: bad pattern\n#+end_src\n"
              ":END:\n\n"
              "*** Response (m)\nAnswer after trying another tool.\n")
      (ogent-zen-refresh)
      (let ((labels (ogent-zen-tests--overlay-labels)))
        (should (member "✓ Broken · tool error: grep · bad pattern · m"
                        labels))
        (should-not (member "✗ Broken · tool error: grep · bad pattern · m"
                            labels))
        (should-not (member "✗ Broken · failed · m" labels))))))

(ert-deftest ogent-zen-error-labels-show-diagnostics ()
  "Model and abort errors show actionable diagnostic labels."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Rate limit\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model gpt-5.5 :status error\nprompt\n#+end_src\n"
              "#+begin_quote ogent-error\n429 rate limit\n#+end_quote\n\n"
              "*** Response (gpt-5.5)\n\n"
              "** Request: Abort\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status aborted :latency 0.2s\nprompt\n#+end_src\n"
              "#+begin_quote ogent-error\nRequest aborted by user\n#+end_quote\n\n"
              "*** Response (m)\n\n")
      (ogent-zen-refresh)
      (let ((labels (ogent-zen-tests--overlay-labels)))
        (should (member "✗ Rate limit · ✗ failed · model error · 429 rate limit · gpt-5.5"
                        labels))
        (should (member "✗ Abort · ✗ failed · aborted · user cancelled · m · 0.2s"
                        labels))))))

(ert-deftest ogent-zen-multi-model-label-shows-selected-response ()
  "Multi-model request labels show aggregate counts and selected answers."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Compare\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model many :status done\nprompt\n#+end_src\n\n"
              "*** Response (m1)\nanswer one\n"
              "*** Response (m2)\nanswer two\n")
      (goto-char (point-min))
      (search-forward "answer two")
      (ogent-zen-mark-accepted)
      (goto-char (point-min))
      (search-forward "Request: Compare")
      (should (equal (org-entry-get (point) "OGENT_SELECTED_MODEL") "m2"))
      (goto-char (point-min))
      (search-forward "Response (m2)")
      (org-back-to-heading t)
      (should (equal (org-entry-get (point) "OGENT_REVIEW") "accepted"))
      (let ((labels (ogent-zen-tests--overlay-labels)))
        (should (member "✓ Compare · [m1 ✓] [m2 ✓] · ◆ m2 accepted · many · 2 responses"
                        labels))
        (should (member "↳ m2 · ◆ accepted" labels))))))

(ert-deftest ogent-zen-collapse-marks-older-siblings-superseded ()
  "Collapsing previous runs marks unreviewed older siblings superseded."
  (let ((ogent-zen-collapse-previous-runs t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Old\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status done\nold\n#+end_src\n"
              "*** Response (m)\nold\n"
              "** Request: Accepted\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n"
              ":OGENT_REVIEW: accepted\n:END:\n"
              "#+begin_src text :model m :status done\naccepted\n#+end_src\n"
              "*** Response (m)\naccepted\n"
              "** Request: New\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status done\nnew\n#+end_src\n"
              "*** Response (m)\nnew\n")
      (goto-char (point-min))
      (search-forward "Request: New")
      (beginning-of-line)
      (ogent-zen-after-insert (point))
      (goto-char (point-min))
      (search-forward "Request: Old")
      (should (equal (org-entry-get (point) "OGENT_REVIEW") "superseded"))
      (goto-char (point-min))
      (search-forward "Request: Accepted")
      (should (equal (org-entry-get (point) "OGENT_REVIEW") "accepted")))))

(ert-deftest ogent-zen-headline-density-minimal-hides-metadata ()
  "Minimal density renders only the status icon and primary title."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t)
        (ogent-zen-result-headline-density 'minimal))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Done\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status done :latency 1.0s\nprompt\n#+end_src\n\n"
              "*** Response (m)\nanswer\n")
      (ogent-zen-refresh)
      (let ((labels (ogent-zen-tests--overlay-labels)))
        (should (member "✓ Done" labels))
        (should (member "↳ m" labels))))))

(ert-deftest ogent-zen-suffix-lanes-right-align-wide-graphic-windows ()
  "Right metadata uses a virtual alignment segment in wide graphical windows."
  (let ((ogent-zen-right-align-metadata t))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _display) t))
              ((symbol-function 'window-body-width)
               (lambda (&rest _args) 120)))
      (let ((suffix (ogent-zen--suffix-lanes '("left") '("right"))))
        (should
         (cl-loop for index below (length suffix)
                  thereis (get-text-property index 'display suffix)))))))

(ert-deftest ogent-zen-visual-lanes-add-margin-status ()
  "Optional visual lanes add a margin status before-string."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t)
        (ogent-zen-visual-lanes t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Done\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status done\nprompt\n#+end_src\n\n"
              "*** Response (m)\nanswer\n")
      (ogent-zen-refresh)
      (let ((overlay
             (cl-find-if
              (lambda (candidate)
                (string-prefix-p
                 "✓ Done"
                 (substring-no-properties
                  (overlay-get candidate 'display))))
              ogent-zen--overlays)))
        (should overlay)
        (should (overlay-get overlay 'before-string))))))

(ert-deftest ogent-zen-heading-overlays-omit-direct-actions-by-default ()
  "Zen heading overlays avoid direct bindings unless explicitly enabled."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Done\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status done\nprompt\n#+end_src\n\n"
              "*** Response (m)\nanswer\n")
      (ogent-zen-refresh)
      (let ((overlay (car ogent-zen--overlays)))
        (should (overlay-get overlay 'help-echo))
        (should-not (overlay-get overlay 'mouse-face))
        (should-not (overlay-get overlay 'keymap)))
      (should (member "✓ Done · m" (ogent-zen-tests--overlay-labels))))))

(ert-deftest ogent-zen-heading-overlays-show-optional-breadcrumbs-and-actions ()
  "Zen heading overlays expose breadcrumb and action affordances when enabled."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t)
        (ogent-zen-show-breadcrumbs t)
        (ogent-zen-heading-actions t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Done\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n"
              ":OGENT_PATH: Parent › Done\n:END:\n"
              "#+begin_src text :model m :status done\nprompt\n#+end_src\n\n"
              "*** Response (m)\nanswer\n")
      (ogent-zen-refresh)
      (let ((overlay (car ogent-zen--overlays)))
        (should (overlay-get overlay 'help-echo))
        (should (eq (lookup-key (overlay-get overlay 'keymap) (kbd "r"))
                    #'ogent-zen-rerun))
        (should (eq (lookup-key (overlay-get overlay 'keymap) (kbd "RET"))
                    #'ogent-zen-toggle-transcript))
        (should (eq (lookup-key (overlay-get overlay 'keymap) [mouse-1])
                    #'ogent-zen--mouse-toggle-transcript)))
      (should (member "✓ Done · Parent · m · r rerun · u review · RET fold"
                      (ogent-zen-tests--overlay-labels))))))

(ert-deftest ogent-zen-refresh-at-preserves-outside-overlays ()
  "Region refresh rebuilds one transcript and keeps the other's overlays."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Idea\n** Request: first\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status waiting\nx\n#+end_src\n\n"
              "*** Response (m)\n\n"
              "** Request: second\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
              "#+begin_src text :model m :status done\nx\n#+end_src\n\n"
              "*** Response (m)\nanswer\n")
      (ogent-zen-refresh)
      (should (= (length ogent-zen--overlays) 4))
      (let ((second-overlays
             (cl-remove-if-not
              (lambda (overlay)
                (>= (overlay-start overlay)
                    (save-excursion
                      (goto-char (point-min))
                      (search-forward "Request: second")
                      (line-beginning-position))))
              ogent-zen--overlays)))
        ;; Flip the first run to done in the raw text, then region-refresh it.
        (goto-char (point-min))
        (search-forward ":status waiting")
        (replace-match ":status done")
        (goto-char (point-min))
        (search-forward "*** Response (m)")
        (insert "\nnow finished")
        (goto-char (point-min))
        (search-forward "Request: first")
        (ogent-zen-refresh-at (point))
        (should (= (length ogent-zen--overlays) 4))
        ;; First transcript's labels updated to done.
        (should (member "✓ first · m"
                        (ogent-zen-tests--overlay-labels)))
        ;; Second transcript's overlay objects survived untouched.
        (dolist (overlay second-overlays)
          (should (memq overlay ogent-zen--overlays)))))))

(ert-deftest ogent-zen-bullets-compose-and-restore ()
  "Star composition applies on enable and restores plain text on disable."
  (with-temp-buffer
    (org-mode)
    (insert "* Top\nBody\n** Child\n")
    (ogent-zen-mode 1)
    (should (get-char-property 1 'composition))
    (let ((child-star (save-excursion
                        (goto-char (point-min))
                        (search-forward "** Child")
                        (match-beginning 0))))
      (should (get-char-property child-star 'composition)))
    ;; Buffer text itself is unchanged.
    (should (string-prefix-p "* Top" (buffer-string)))
    (ogent-zen-mode -1)
    (should-not (get-char-property 1 'composition))))

(ert-deftest ogent-zen-bullets-defer-to-other-star-packages ()
  "Star composition is skipped when org-modern style modes are active."
  (with-temp-buffer
    (org-mode)
    (insert "* Top\n")
    (set (make-local-variable 'org-modern-mode) t)
    (ogent-zen-mode 1)
    (should-not ogent-zen--bullet-keywords)
    (should-not (get-char-property 1 'composition))
    (ogent-zen-mode -1)))

(ert-deftest ogent-zen-center-column-sets-window-margins ()
  "Centering syncs symmetric window margins and clears them on disable."
  (let ((buffer (generate-new-buffer "*zen-margins*")))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buffer)
          (with-current-buffer buffer
            (org-mode)
            (insert "* Top\n")
            (let ((ogent-zen-center-column 40))
              (ogent-zen-mode 1)
              (skip-unless (> (window-total-width (selected-window)) 42))
              (should (> (or (car (window-margins (selected-window))) 0) 0))
              (ogent-zen-mode -1)
              (should-not (car (window-margins (selected-window)))))))
      (kill-buffer buffer))))

(ert-deftest ogent-zen-global-mode-enables-in-org-buffers ()
  "`global-ogent-zen-mode' turns `ogent-zen-mode' on in Org buffers only."
  (let ((org-buffer (generate-new-buffer "zen-global-org"))
        (text-buffer (generate-new-buffer "zen-global-text"))
        (later-buffer nil))
    (unwind-protect
        (progn
          (with-current-buffer org-buffer (org-mode) (insert "* Top\n"))
          (with-current-buffer text-buffer (fundamental-mode))
          (global-ogent-zen-mode 1)
          (should (buffer-local-value 'ogent-zen-mode org-buffer))
          (should-not (buffer-local-value 'ogent-zen-mode text-buffer))
          ;; An Org buffer created while the global mode is on also gets it.
          (setq later-buffer (generate-new-buffer "zen-global-later"))
          (with-current-buffer later-buffer (org-mode))
          (should (buffer-local-value 'ogent-zen-mode later-buffer)))
      (global-ogent-zen-mode -1)
      (kill-buffer org-buffer)
      (kill-buffer text-buffer)
      (when (buffer-live-p later-buffer) (kill-buffer later-buffer)))))

(ert-deftest ogent-zen-global-mode-disable-restores-plain-org ()
  "Disabling `global-ogent-zen-mode' turns the local mode back off."
  (let ((org-buffer (generate-new-buffer "zen-global-off")))
    (unwind-protect
        (with-current-buffer org-buffer
          (org-mode)
          (insert "* Top\n")
          (global-ogent-zen-mode 1)
          (should ogent-zen-mode)
          (global-ogent-zen-mode -1)
          (should-not ogent-zen-mode))
      (global-ogent-zen-mode -1)
      (when (buffer-live-p org-buffer) (kill-buffer org-buffer)))))

(ert-deftest ogent-zen-turn-on-skips-internal-temp-buffers ()
  "`ogent-zen--turn-on' ignores space-prefixed Org scratch buffers."
  (let ((temp (generate-new-buffer " zen-global-temp")))
    (unwind-protect
        (with-current-buffer temp
          (org-mode)
          (ogent-zen--turn-on)
          (should-not ogent-zen-mode))
      (kill-buffer temp))))

(ert-deftest ogent-zen-record-tool-call-keeps-buffer-clean ()
  "Recorded tool calls stay out of the buffer but feed the headline summary."
  (let ((ogent-theme-use-icons nil)
        (ogent-theme-use-unicode t))
    (with-temp-buffer
      (org-mode)
      (insert "* Parent\n** Request: Work\n"
              ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n"
              ":OGENT_WORKSPACE_ROOT: /tmp/ogent/\n:END:\n"
              "#+begin_src text :model m :status done\nprompt\n#+end_src\n"
              "*** Response (m)\nanswer\n")
      (let ((before (buffer-substring-no-properties (point-min) (point-max))))
        (goto-char (point-max))
        (ogent-zen-record-tool-call
         "read-file" '(:file "x") "ok" 'done "lisp/ogent-zen.el")
        (goto-char (point-max))
        (ogent-zen-record-tool-call
         "grep" '(:pattern "y") "match" 'done "lisp/ui/ogent-ui.el")
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       before))
        (should-not (string-match-p ":TOOL:" (buffer-string))))
      (ogent-zen-refresh)
      (should (member "✓ Work · ogent:lisp/ · 2 tools · m"
                      (ogent-zen-tests--overlay-labels))))))

(ert-deftest ogent-zen-insert-tool-block-records-in-zen ()
  "In Zen buffers `ogent-ui--insert-tool-block' records instead of inlining."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Request: Work\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model m :status done\nprompt\n#+end_src\n"
            "*** Response (m)\nanswer\n")
    (ogent-zen-mode 1)
    (goto-char (point-max))
    (let ((before (buffer-substring-no-properties (point-min) (point-max))))
      (ogent-ui--insert-tool-block "read-file" '(:file "x") "ok")
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     before))
      (should-not (string-match-p ":TOOL:" (buffer-string))))
    (goto-char (point-min))
    (search-forward "Request: Work")
    (org-back-to-heading t)
    (should (= 1 (length (ogent-zen--request-tool-infos
                          (ogent-zen--subtree-end)))))))

(ert-deftest ogent-zen-tool-calls-inline-restores-drawers ()
  "With `ogent-zen-tool-calls-inline', tool calls inline as drawers again."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Request: Work\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model m :status done\nprompt\n#+end_src\n"
            "*** Response (m)\nanswer\n")
    (ogent-zen-mode 1)
    (let ((ogent-zen-tool-calls-inline t))
      (should-not (ogent-zen--tool-record-active-p))
      (goto-char (point-max))
      (ogent-ui--insert-tool-block "read-file" '(:file "x") "ok"))
    (should (string-match-p ":TOOL:" (buffer-string)))))

(ert-deftest ogent-zen-show-tool-calls-lists-records ()
  "`ogent-zen-show-tool-calls' lists recorded tool calls in a separate buffer."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Request: Work\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model m :status done\nprompt\n#+end_src\n"
            "*** Response (m)\nanswer\n")
    (goto-char (point-max))
    (ogent-zen-record-tool-call "read-file" '(:file "x.el") "file body" 'done "x.el")
    (goto-char (point-max))
    (ogent-zen-record-tool-call "grep" '(:pattern "p") "no match" 'error "p")
    (goto-char (point-min))
    (search-forward "Parent")
    (org-back-to-heading t)
    (let ((buf (ogent-zen-show-tool-calls)))
      (unwind-protect
          (with-current-buffer buf
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (eq major-mode 'ogent-zen-tool-calls-mode))
              (should buffer-read-only)
              (should (string-match-p "Request: Work" text))
              (should (string-match-p "read-file: x.el" text))
              (should (string-match-p "file body" text))
              (should (string-match-p "grep: p" text))
              (should (string-match-p "no match" text))))
        (kill-buffer buf)))))

(ert-deftest ogent-zen-show-tool-calls-parses-inline-drawers ()
  "Inspection falls back to inline :TOOL: drawers for legacy transcripts."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Request: Work\n"
            ":PROPERTIES:\n:OGENT_STYLE: zen\n:OGENT_KIND: request\n:END:\n"
            "#+begin_src text :model m :status done\nprompt\n#+end_src\n"
            ":TOOL:\n▶ read-file: lisp/ogent-zen.el ✓\n"
            "#+begin_src elisp :args\n(:file_path \"lisp/ogent-zen.el\")\n#+end_src\n"
            "#+begin_src text :result\nfile contents here\n#+end_src\n"
            ":END:\n"
            "*** Response (m)\nanswer\n")
    (goto-char (point-min))
    (search-forward "Parent")
    (org-back-to-heading t)
    (let ((buf (ogent-zen-show-tool-calls)))
      (unwind-protect
          (with-current-buffer buf
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "read-file: lisp/ogent-zen.el" text))
              (should (string-match-p "file_path" text))
              (should (string-match-p "file contents here" text))))
        (kill-buffer buf)))))

(ert-deftest ogent-zen-turn-on-skips-tool-calls-buffer ()
  "`ogent-zen--turn-on' leaves the tool-call inspection buffer alone."
  (let ((buf (generate-new-buffer "*ogent tool calls*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-zen-tool-calls-mode)
          (ogent-zen--turn-on)
          (should-not ogent-zen-mode))
      (kill-buffer buf))))

(provide 'ogent-zen-tests)
;;; ogent-zen-tests.el ends here
