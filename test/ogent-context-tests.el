;;; ogent-context-tests.el --- Tests for ogent-context -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-context)
(require 'org)

(ert-deftest ogent-context-resolve-by-ogent-id ()
  "Handles using explicit OGENT_ID are resolved."
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (let ((node (ogent-resolve-handle "details-block")))
			       (should (ogent-context-node-p node))
			       (should (string= (ogent-context-node-title node)
						"Details Block"))))))

(ert-deftest ogent-context-resolve-by-slug ()
  "Handles derived from title slugs resolve when OGENT_ID is absent."
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (let ((node (ogent-resolve-handle "deep-note")))
			       (should (ogent-context-node-p node))
			       (should (string= (ogent-context-node-title node)
						"Deep Note"))))))

(ert-deftest ogent-context-build-collects-dependencies ()
  "Context builder tracks handles, ancestors, and missing nodes."
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (goto-char (point-min))
			     (search-forward "Root Overview")
			     (org-back-to-heading t)
			     (let* ((ctx (ogent-context-build))
				    (handles (plist-get ctx :handles))
				    (deps (plist-get ctx :dependencies)))
			       (should (equal handles
					      '("details-block" "deep-note" "appendix-note"
						"missing-note")))
			       (should (= (length deps) 4))
			       (should-not (plist-get (nth 0 deps) :missing-p))
			       (should (ogent-context-node-p
					(plist-get (nth 1 deps) :node)))
			       (should-not (plist-get (nth 2 deps) :missing-p))
			       (should (plist-get (nth 3 deps) :missing-p))))))

(ert-deftest ogent-context-build-provides-ancestors ()
  "Ancestors are ordered from top-level down to the immediate parent."
  ;; Skip on Emacs 28.x due to org-element :parent behavior differences
  (skip-unless (>= emacs-major-version 29))
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (goto-char (point-min))
			     (search-forward "Details Block")
			     (org-back-to-heading t)
			     (let* ((ctx (ogent-context-build))
				    (ancestors (plist-get ctx :ancestors)))
			       (should (= (length ancestors) 1))
			       (should (string= (ogent-context-node-title (car ancestors))
						"Root Overview"))))))

;;; Source buffer context tests

(ert-deftest ogent-context-source-context-builds ()
  "Source context is built for non-Org buffers."
  (let ((source-buffer (get-buffer-create "*test-source.el*")))
    (unwind-protect
        (with-current-buffer source-buffer
          (emacs-lisp-mode)
          (insert "(defun foo () \"test\")")
          (let ((ctx (ogent-context-build-for-buffer)))
            (should (plist-get ctx :source-context))
            (should (ogent-source-context-p
                     (plist-get ctx :source-context)))
            (should (string= (ogent-source-context-mode
                              (plist-get ctx :source-context))
                             "emacs-lisp-mode"))
            (should (string-match-p "defun foo"
                                    (ogent-source-context-content
                                     (plist-get ctx :source-context))))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-context-source-context-with-region ()
  "Source context respects region selection."
  (let ((source-buffer (get-buffer-create "*test-region.el*")))
    (unwind-protect
        (with-current-buffer source-buffer
          (emacs-lisp-mode)
          (insert "line1\nline2\nline3\nline4\n")
          (goto-char (point-min))
          (forward-line 1)
          (let* ((start (point))
                 (end (progn (forward-line 2) (point)))
                 (ctx (ogent-context-build-for-buffer
                       source-buffer start end))
                 (source-ctx (plist-get ctx :source-context)))
            (should source-ctx)
            (should (equal (ogent-source-context-region-start source-ctx)
                           start))
            (should (equal (ogent-source-context-region-end source-ctx)
                           end))
            (should (string= (ogent-source-context-content source-ctx)
                             "line2\nline3\n"))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-context-build-with-source-combines-contexts ()
  "Combined context includes both source and Org context."
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (let ((source-buffer (get-buffer-create "*test-combined.py*")))
			       (unwind-protect
				   (progn
				     (with-current-buffer source-buffer
				       (python-mode)
				       (insert "def hello(): pass"))
				     ;; In the Org buffer, build combined context
				     (goto-char (point-min))
				     (search-forward "Root Overview")
				     (org-back-to-heading t)
				     (let ((ctx (ogent-context-build-with-source source-buffer)))
				       ;; Should have source context
				       (should (plist-get ctx :source-context))
				       (should (string-match-p
						"def hello"
						(ogent-source-context-content
						 (plist-get ctx :source-context))))
				       ;; Should also have Org context
				       (should (plist-get ctx :root))
				       (should (string= (ogent-context-node-title
							 (plist-get ctx :root))
							"Root Overview"))))
				 (kill-buffer source-buffer))))))

;;; Lazy context building tests

(ert-deftest ogent-context-build-lazy-defers-evaluation ()
  "Lazy context building defers evaluation until forced."
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (goto-char (point-min))
			     (search-forward "Root Overview")
			     (org-back-to-heading t)
			     (let* ((thunk (progn
					     ;; Create thunk - should not call ogent-context-build yet
					     (ogent-context-build-lazy))))
			       ;; Thunk should be a closure, not evaluated yet
			       (should (functionp thunk))
			       ;; Force the thunk - now it evaluates
			       (let ((ctx (thunk-force thunk)))
				 (should (plist-get ctx :root))
				 (should (string= (ogent-context-node-title (plist-get ctx :root))
						  "Root Overview")))))))

(ert-deftest ogent-context-build-lazy-caches-result ()
  "Lazy context building caches result after first force."
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (goto-char (point-min))
			     (search-forward "Root Overview")
			     (org-back-to-heading t)
			     (let ((thunk (ogent-context-build-lazy)))
			       ;; Force multiple times - should return same result
			       (let ((ctx1 (thunk-force thunk))
				     (ctx2 (thunk-force thunk)))
				 ;; Results should be identical (same object due to caching)
				 (should (eq ctx1 ctx2)))))))

(ert-deftest ogent-context-build-source-lazy-works ()
  "Lazy source context building works correctly."
  (let ((source-buffer (get-buffer-create "*test-lazy-source.el*")))
    (unwind-protect
        (with-current-buffer source-buffer
          (emacs-lisp-mode)
          (insert "(defun lazy-test () t)")
          (let ((thunk (ogent-context-build-source-lazy source-buffer)))
            (should (functionp thunk))
            (let ((ctx (thunk-force thunk)))
              (should (ogent-source-context-p ctx))
              (should (string-match-p "lazy-test"
                                      (ogent-source-context-content ctx))))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-context-with-lazy-binds-thunks ()
  "ogent-context-with-lazy creates thunk bindings."
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (goto-char (point-min))
			     (search-forward "Root Overview")
			     (org-back-to-heading t)
			     (let ((forced-count 0))
			       (ogent-context-with-lazy
				((ctx (progn
					(cl-incf forced-count)
					(ogent-context-build))))
				;; Not forced yet
				(should (= forced-count 0))
				;; Force once
				(let ((result (thunk-force ctx)))
				  (should (= forced-count 1))
				  (should (plist-get result :root)))
				;; Force again - count shouldn't increase (cached)
				(thunk-force ctx)
				(should (= forced-count 1)))))))

;;; Completion-at-point tests

(ert-deftest ogent-context-completion-triggers-after-at ()
  "Completion triggers when point is after @ character."
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (goto-char (point-max))
			     (insert "\n* Test\nHere is @")
			     ;; Should return nil when no text after @
			     (should-not (ogent-context-completion-at-point))
			     ;; Type partial text
			     (insert "det")
			     (let ((result (ogent-context-completion-at-point)))
			       (should result)
			       (should (= (nth 0 result)
					  (- (point) 3)))  ; start of "det"
			       (should (= (nth 1 result)
					  (point)))))))      ; end of "det"

(ert-deftest ogent-context-completion-includes-buffer-handles ()
  "Completion includes handles from current buffer."
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (goto-char (point-max))
			     (insert "\n* Test\nHere is @d")
			     (let* ((result (ogent-context-completion-at-point))
				    (collection (nth 2 result)))
			       (should (member "details-block" collection))
			       (should (member "deep-note" collection))
			       (should (member "appendix-note" collection))))))

(ert-deftest ogent-context-completion-annotation-works ()
  "Completion annotation shows content preview."
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (goto-char (point-max))
			     (insert "\n* Test\nHere is @d")
			     (let* ((result (ogent-context-completion-at-point))
				    (annot-fn (plist-get (nthcdr 3 result) :annotation-function)))
			       (should (functionp annot-fn))
			       (let ((annotation (funcall annot-fn "details-block")))
				 (should (stringp annotation))
				 (should (string-match-p "This paragraph" annotation)))))))

(ert-deftest ogent-context-completion-not-in-non-org-buffer ()
  "Completion does not activate in non-Org buffers."
  (let ((buf (get-buffer-create "*test-non-org*")))
    (unwind-protect
	(with-current-buffer buf
	  (emacs-lisp-mode)
	  (insert "@handle")
	  (should-not (ogent-context-completion-at-point)))
      (kill-buffer buf))))

(ert-deftest ogent-context-collect-all-handles-from-current ()
  "ogent-context--collect-all-handles gathers from current buffer."
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (let ((handles (ogent-context--collect-all-handles)))
			       (should (> (length handles) 0))
			       (let ((handle-names (mapcar (lambda (entry)
							     (plist-get entry :handle))
							   handles)))
				 (should (member "details-block" handle-names))
				 (should (member "overview-root" handle-names))
				 (should (member "appendix-note" handle-names)))))))

;;; Handle exclusion tests

(ert-deftest ogent-context-exclude-handle-adds-to-list ()
  "ogent-context-exclude-handle adds handle to exclusion list."
  (let ((ogent-context-excluded-handles nil))
    (ogent-context-exclude-handle "test-handle")
    (should (member "test-handle" ogent-context-excluded-handles))
    ;; Adding same handle twice should not duplicate
    (ogent-context-exclude-handle "test-handle")
    (should (= 1 (cl-count "test-handle" ogent-context-excluded-handles
                           :test #'string=)))))

(ert-deftest ogent-context-include-handle-removes-from-list ()
  "ogent-context-include-handle removes handle from exclusion list."
  (let ((ogent-context-excluded-handles '("handle1" "handle2" "handle3")))
    (ogent-context-include-handle "handle2")
    (should-not (member "handle2" ogent-context-excluded-handles))
    (should (member "handle1" ogent-context-excluded-handles))
    (should (member "handle3" ogent-context-excluded-handles))))

(ert-deftest ogent-context-toggle-exclusion-works ()
  "ogent-context-toggle-exclusion adds and removes handles."
  (let ((ogent-context-excluded-handles nil))
    ;; Toggle to exclude
    (ogent-context-toggle-exclusion "toggle-handle")
    (should (member "toggle-handle" ogent-context-excluded-handles))
    ;; Toggle to include
    (ogent-context-toggle-exclusion "toggle-handle")
    (should-not (member "toggle-handle" ogent-context-excluded-handles))))

(ert-deftest ogent-context-clear-exclusions-empties-list ()
  "ogent-context-clear-exclusions clears all exclusions."
  (let ((ogent-context-excluded-handles '("a" "b" "c")))
    (ogent-context-clear-exclusions)
    (should (null ogent-context-excluded-handles))))

(ert-deftest ogent-context-get-exclusions-returns-copy ()
  "ogent-context-get-exclusions returns a copy of exclusion list."
  (let ((ogent-context-excluded-handles '("handle1" "handle2")))
    (let ((exclusions (ogent-context-get-exclusions)))
      (should (equal exclusions '("handle1" "handle2")))
      ;; Modifying returned list should not affect original
      (setcar exclusions "modified")
      (should (equal ogent-context-excluded-handles '("handle1" "handle2"))))))

(ert-deftest ogent-context-build-filtered-excludes-handles ()
  "ogent-context-build-filtered filters out excluded handles."
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (goto-char (point-min))
			     (search-forward "Root Overview")
			     (org-back-to-heading t)
			     (let ((ogent-context-excluded-handles '("details-block" "missing-note")))
			       (let* ((ctx (ogent-context-build-filtered))
				      (deps (plist-get ctx :dependencies))
				      (excluded (plist-get ctx :excluded-handles))
				      (dep-handles (mapcar (lambda (dep)
							     (plist-get dep :handle))
							   deps)))
				 ;; Excluded handles should not be in dependencies
				 (should-not (member "details-block" dep-handles))
				 (should-not (member "missing-note" dep-handles))
				 ;; Non-excluded handles should be present
				 (should (member "deep-note" dep-handles))
				 (should (member "appendix-note" dep-handles))
				 ;; :excluded-handles should contain the exclusion list
				 (should (equal excluded '("details-block" "missing-note"))))))))

(ert-deftest ogent-context-build-filtered-with-no-exclusions ()
  "ogent-context-build-filtered works with empty exclusion list."
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (goto-char (point-min))
			     (search-forward "Root Overview")
			     (org-back-to-heading t)
			     (let ((ogent-context-excluded-handles nil))
			       (let* ((ctx (ogent-context-build-filtered))
				      (deps (plist-get ctx :dependencies))
				      (excluded (plist-get ctx :excluded-handles)))
				 ;; All dependencies should be present
				 (should (= (length deps) 4))
				 ;; Excluded list should be empty
				 (should (null excluded)))))))

(ert-deftest ogent-context-build-filtered-preserves-other-fields ()
  "ogent-context-build-filtered preserves :root and :ancestors."
  ;; Skip on Emacs 28.x due to org-element :parent behavior differences
  (skip-unless (>= emacs-major-version 29))
  (ogent-test-with-fixture "data/fixture.org"
			   (lambda ()
			     (goto-char (point-min))
			     (search-forward "Details Block")
			     (org-back-to-heading t)
			     (let ((ogent-context-excluded-handles '("details-block")))
			       (let* ((ctx (ogent-context-build-filtered))
				      (root (plist-get ctx :root))
				      (ancestors (plist-get ctx :ancestors)))
				 ;; Root should be present
				 (should (ogent-context-node-p root))
				 (should (string= (ogent-context-node-title root)
						  "Details Block"))
				 ;; Ancestors should be present
				 (should (= (length ancestors) 1))
				 (should (string= (ogent-context-node-title (car ancestors))
						  "Root Overview")))))))

;;; Slug generation tests

(ert-deftest ogent-context-slug-basic ()
  "Slug downcases and replaces non-alnum with hyphens."
  (should (string= (ogent-context--slug "Hello World")
                   "hello-world")))

(ert-deftest ogent-context-slug-strips-leading-trailing-hyphens ()
  "Slug strips leading and trailing hyphens."
  (should (string= (ogent-context--slug "  Hello  ")
                   "hello")))

(ert-deftest ogent-context-slug-consecutive-special-chars ()
  "Consecutive special chars collapse to a single hyphen."
  (should (string= (ogent-context--slug "foo!!!bar")
                   "foo-bar")))

(ert-deftest ogent-context-slug-already-slug ()
  "A string that is already a slug passes through unchanged."
  (should (string= (ogent-context--slug "my-slug-123")
                   "my-slug-123")))

(ert-deftest ogent-context-slug-empty ()
  "Empty string yields empty slug."
  (should (string= (ogent-context--slug "") "")))

(ert-deftest ogent-context-slug-underscores ()
  "Underscores are replaced with hyphens in slug."
  (should (string= (ogent-context--slug "foo_bar_baz")
                   "foo-bar-baz")))

;;; Collect handles tests

(ert-deftest ogent-context-collect-handles-basic ()
  "Handles are collected from text containing @ references."
  (let ((handles (ogent-context--collect-handles "See @foo and @bar-baz.")))
    (should (member "foo" handles))
    (should (member "bar-baz" handles))))

(ert-deftest ogent-context-collect-handles-no-duplicates ()
  "Duplicate handles are removed."
  (let ((handles (ogent-context--collect-handles "@alpha @beta @alpha")))
    (should (= (cl-count "alpha" handles :test #'string=) 1))
    (should (= (length handles) 2))))

(ert-deftest ogent-context-collect-handles-nil-input ()
  "Nil input returns empty list."
  (should (null (ogent-context--collect-handles nil))))

(ert-deftest ogent-context-collect-handles-no-handles ()
  "Text without handles returns empty list."
  (should (null (ogent-context--collect-handles "No handles here."))))

(ert-deftest ogent-context-collect-handles-colon-suffix ()
  "Handles with colon suffix are collected."
  (let ((handles (ogent-context--collect-handles "See @codemap-task:my question")))
    (should (= (length handles) 1))
    (should (string-match-p "codemap-task:" (car handles)))))

;;; Match handle tests

(ert-deftest ogent-context-match-handle-by-slug ()
  "Handle matches by slug derived from title."
  (with-temp-buffer
    (org-mode)
    (insert "* My Test Heading\nContent here.\n")
    (goto-char (point-min))
    (let ((element (org-element-at-point)))
      (should (ogent-context--match-handle element (current-buffer) "my-test-heading")))))

(ert-deftest ogent-context-match-handle-case-insensitive ()
  "Handle matching is case-insensitive."
  (with-temp-buffer
    (org-mode)
    (insert "* Alpha Beta\nContent.\n")
    (goto-char (point-min))
    (let ((element (org-element-at-point)))
      (should (ogent-context--match-handle element (current-buffer) "Alpha-Beta"))
      (should (ogent-context--match-handle element (current-buffer) "alpha-beta")))))

(ert-deftest ogent-context-match-handle-no-match ()
  "Non-matching handle returns nil."
  (with-temp-buffer
    (org-mode)
    (insert "* Foo Bar\nContent.\n")
    (goto-char (point-min))
    (let ((element (org-element-at-point)))
      (should-not (ogent-context--match-handle element (current-buffer) "baz-quux")))))

;;; Format source context tests

(ert-deftest ogent-context-format-source-basic ()
  "Format source context produces expected output."
  (let* ((buf (generate-new-buffer "*test-format*")))
    (unwind-protect
        (with-current-buffer buf
          (emacs-lisp-mode)
          (insert "(message \"hello\")")
          (let* ((ctx (ogent-context--build-source-context buf))
                 (formatted (ogent-context--format-source-context ctx)))
            (should (string-match-p "Mode: emacs-lisp-mode" formatted))
            (should (string-match-p "Full buffer:" formatted))
            (should (string-match-p "(message \"hello\")" formatted))))
      (kill-buffer buf))))

(ert-deftest ogent-context-format-source-with-region ()
  "Format source context shows region info when region is provided."
  (let ((buf (generate-new-buffer "*test-fmt-region*")))
    (unwind-protect
        (with-current-buffer buf
          (emacs-lisp-mode)
          (insert "line1\nline2\nline3\n")
          (let* ((ctx (ogent-context--build-source-context buf 7 12))
                 (formatted (ogent-context--format-source-context ctx)))
            (should (string-match-p "Selected region" formatted))))
      (kill-buffer buf))))

(ert-deftest ogent-context-format-source-unsaved-buffer ()
  "Format source context shows (unsaved) for buffers without files."
  (let ((buf (generate-new-buffer "*test-unsaved*")))
    (unwind-protect
        (with-current-buffer buf
          (emacs-lisp-mode)
          (insert "test")
          (let* ((ctx (ogent-context--build-source-context buf))
                 (formatted (ogent-context--format-source-context ctx)))
            (should (string-match-p "(unsaved)" formatted))))
      (kill-buffer buf))))

;;; Build source context tests

(ert-deftest ogent-context-build-source-captures-mode ()
  "Source context captures the major mode name."
  (let ((buf (generate-new-buffer "*test-mode*")))
    (unwind-protect
        (with-current-buffer buf
          (emacs-lisp-mode)
          (insert "hello")
          (let ((ctx (ogent-context--build-source-context buf)))
            (should (string= (ogent-source-context-mode ctx) "emacs-lisp-mode"))))
      (kill-buffer buf))))

(ert-deftest ogent-context-build-source-full-content ()
  "Source context captures full buffer content without region."
  (let ((buf (generate-new-buffer "*test-full*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "abc\ndef\n")
          (let ((ctx (ogent-context--build-source-context buf)))
            (should (string= (ogent-source-context-content ctx) "abc\ndef\n"))
            (should-not (ogent-source-context-region-start ctx))
            (should-not (ogent-source-context-region-end ctx))))
      (kill-buffer buf))))

(ert-deftest ogent-context-build-source-region-content ()
  "Source context extracts only region content when given."
  (let ((buf (generate-new-buffer "*test-region-ctx*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "aaa\nbbb\nccc\n")
          (let ((ctx (ogent-context--build-source-context buf 5 8)))
            (should (string= (ogent-source-context-content ctx) "bbb"))
            (should (= (ogent-source-context-region-start ctx) 5))
            (should (= (ogent-source-context-region-end ctx) 8))))
      (kill-buffer buf))))

;;; Pin label tests

(ert-deftest ogent-pin-make-label-file ()
  "File pin label is the base filename."
  (should (string= (ogent-pin--make-label 'file "/home/user/foo.el")
                   "foo.el")))

(ert-deftest ogent-pin-make-label-buffer ()
  "Buffer pin label is the buffer name."
  (let ((buf (generate-new-buffer "*pin-label-test*")))
    (unwind-protect
        (should (string= (ogent-pin--make-label 'buffer nil buf)
                         (buffer-name buf)))
      (kill-buffer buf))))

(ert-deftest ogent-pin-make-label-region ()
  "Region pin label includes buffer name and line numbers."
  (let ((buf (generate-new-buffer "*pin-region-label*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "line1\nline2\nline3\nline4\n")
          (let ((label (ogent-pin--make-label 'region nil buf 7 18)))
            (should (string-match-p (regexp-quote (buffer-name buf)) label))
            (should (string-match-p "2-3" label))))
      (kill-buffer buf))))

;;; Pinned count tests

(ert-deftest ogent-pinned-count-empty ()
  "Count is 0 when nothing is pinned."
  (let ((ogent-pinned-context nil))
    (should (= (ogent-pinned-count) 0))))

(ert-deftest ogent-pinned-count-with-valid-items ()
  "Count reflects only valid pinned items."
  (let* ((buf (generate-new-buffer "*pinned-count*"))
         (ogent-pinned-context
          (list (make-ogent-pinned-item :type 'buffer :buffer buf
                                        :label "test" :pinned-at (current-time)))))
    (unwind-protect
        (should (= (ogent-pinned-count) 1))
      (kill-buffer buf))))

(ert-deftest ogent-pinned-count-excludes-dead-buffers ()
  "Dead buffers are not counted."
  (let* ((buf (generate-new-buffer "*pinned-dead*"))
         (ogent-pinned-context
          (list (make-ogent-pinned-item :type 'buffer :buffer buf
                                        :label "test" :pinned-at (current-time)))))
    (kill-buffer buf)
    (should (= (ogent-pinned-count) 0))))

;;; Pinned item content tests

(ert-deftest ogent-pinned-item-content-file ()
  "File pinned items return file contents."
  (let ((tmp (make-temp-file "ogent-pin-test")))
    (unwind-protect
        (progn
          (write-region "file content" nil tmp)
          (let ((item (make-ogent-pinned-item :type 'file :path tmp
                                              :label "test" :pinned-at (current-time))))
            (should (string= (ogent-pinned-item-content item) "file content"))))
      (delete-file tmp))))

(ert-deftest ogent-pinned-item-content-buffer ()
  "Buffer pinned items return buffer contents."
  (let ((buf (generate-new-buffer "*pin-content*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (insert "buffer content"))
          (let ((item (make-ogent-pinned-item :type 'buffer :buffer buf
                                              :label "test" :pinned-at (current-time))))
            (should (string= (ogent-pinned-item-content item) "buffer content"))))
      (kill-buffer buf))))

(ert-deftest ogent-pinned-item-content-region ()
  "Region pinned items return region contents."
  (let ((buf (generate-new-buffer "*pin-region-content*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "aaabbbccc")
          (let* ((start (copy-marker 4))
                 (end (copy-marker 7 t))
                 (item (make-ogent-pinned-item :type 'region :buffer buf
                                               :start-marker start :end-marker end
                                               :label "test" :pinned-at (current-time))))
            (should (string= (ogent-pinned-item-content item) "bbb"))))
      (kill-buffer buf))))

(ert-deftest ogent-pinned-item-content-dead-buffer ()
  "Dead buffer pinned items return nil."
  (let* ((buf (generate-new-buffer "*pin-dead*"))
         (item (make-ogent-pinned-item :type 'buffer :buffer buf
                                       :label "test" :pinned-at (current-time))))
    (kill-buffer buf)
    (should-not (ogent-pinned-item-content item))))

;;; Pinned items valid tests

(ert-deftest ogent-pinned-items-valid-filters-dead ()
  "Valid items list excludes dead buffer items."
  (let* ((live-buf (generate-new-buffer "*pin-valid-live*"))
         (dead-buf (generate-new-buffer "*pin-valid-dead*"))
         (ogent-pinned-context
          (list (make-ogent-pinned-item :type 'buffer :buffer live-buf
                                        :label "live" :pinned-at (current-time))
                (make-ogent-pinned-item :type 'buffer :buffer dead-buf
                                        :label "dead" :pinned-at (current-time)))))
    (kill-buffer dead-buf)
    (unwind-protect
        (let ((valid (ogent-pinned-items-valid)))
          (should (= (length valid) 1))
          (should (string= (ogent-pinned-item-label (car valid)) "live")))
      (kill-buffer live-buf))))

(ert-deftest ogent-pinned-items-valid-file-exists ()
  "Valid items include files that exist."
  (let* ((tmp (make-temp-file "ogent-valid-test"))
         (ogent-pinned-context
          (list (make-ogent-pinned-item :type 'file :path tmp
                                        :label "exists" :pinned-at (current-time))
                (make-ogent-pinned-item :type 'file :path "/no/such/file.txt"
                                        :label "missing" :pinned-at (current-time)))))
    (unwind-protect
        (let ((valid (ogent-pinned-items-valid)))
          (should (= (length valid) 1))
          (should (string= (ogent-pinned-item-label (car valid)) "exists")))
      (delete-file tmp))))

;;; Pin file / buffer / region tests

(ert-deftest ogent-pin-file-adds-to-context ()
  "Pinning a file adds it to the pinned context list."
  (let ((ogent-pinned-context nil)
        (tmp (make-temp-file "ogent-pin-file-test")))
    (unwind-protect
        (progn
          (ogent-pin-file tmp)
          (should (= (length ogent-pinned-context) 1))
          (should (eq (ogent-pinned-item-type (car ogent-pinned-context)) 'file)))
      (delete-file tmp))))

(ert-deftest ogent-pin-file-no-duplicate ()
  "Pinning the same file twice does not duplicate."
  (let ((ogent-pinned-context nil)
        (tmp (make-temp-file "ogent-pin-dup-test")))
    (unwind-protect
        (progn
          (ogent-pin-file tmp)
          (ogent-pin-file tmp)
          (should (= (length ogent-pinned-context) 1)))
      (delete-file tmp))))

(ert-deftest ogent-pin-buffer-adds-to-context ()
  "Pinning a buffer adds it to the pinned context list."
  (let ((ogent-pinned-context nil)
        (buf (generate-new-buffer "*pin-buf-test*")))
    (unwind-protect
        (progn
          (ogent-pin-buffer buf)
          (should (= (length ogent-pinned-context) 1))
          (should (eq (ogent-pinned-item-type (car ogent-pinned-context)) 'buffer)))
      (kill-buffer buf))))

(ert-deftest ogent-pin-buffer-no-duplicate ()
  "Pinning the same buffer twice does not duplicate."
  (let ((ogent-pinned-context nil)
        (buf (generate-new-buffer "*pin-buf-dup*")))
    (unwind-protect
        (progn
          (ogent-pin-buffer buf)
          (ogent-pin-buffer buf)
          (should (= (length ogent-pinned-context) 1)))
      (kill-buffer buf))))

(ert-deftest ogent-pin-region-adds-to-context ()
  "Pinning a region adds it to the pinned context list."
  (let ((ogent-pinned-context nil)
        (buf (generate-new-buffer "*pin-region-test*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "hello world")
          (ogent-pin-region 1 6 buf)
          (should (= (length ogent-pinned-context) 1))
          (should (eq (ogent-pinned-item-type (car ogent-pinned-context)) 'region)))
      (kill-buffer buf))))

;;; Unpin / unpin-all tests

(ert-deftest ogent-unpin-by-index ()
  "Unpinning by index removes the correct item."
  (let* ((buf1 (generate-new-buffer "*unpin1*"))
         (buf2 (generate-new-buffer "*unpin2*"))
         (ogent-pinned-context
          (list (make-ogent-pinned-item :type 'buffer :buffer buf1
                                        :label "first" :pinned-at (current-time))
                (make-ogent-pinned-item :type 'buffer :buffer buf2
                                        :label "second" :pinned-at (current-time)))))
    (unwind-protect
        (progn
          (ogent-unpin 0)
          (should (= (length ogent-pinned-context) 1))
          (should (string= (ogent-pinned-item-label (car ogent-pinned-context)) "second")))
      (kill-buffer buf1)
      (kill-buffer buf2))))

(ert-deftest ogent-unpin-by-item ()
  "Unpinning by item object removes it."
  (let* ((buf (generate-new-buffer "*unpin-item*"))
         (item (make-ogent-pinned-item :type 'buffer :buffer buf
                                       :label "target" :pinned-at (current-time)))
         (ogent-pinned-context (list item)))
    (unwind-protect
        (progn
          (ogent-unpin item)
          (should (null ogent-pinned-context)))
      (kill-buffer buf))))

(ert-deftest ogent-unpin-region-cleans-markers ()
  "Unpinning a region cleans up markers."
  (let ((buf (generate-new-buffer "*unpin-markers*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "test content")
          (let* ((start (copy-marker 1))
                 (end (copy-marker 5 t))
                 (item (make-ogent-pinned-item :type 'region :buffer buf
                                               :start-marker start :end-marker end
                                               :label "region" :pinned-at (current-time)))
                 (ogent-pinned-context (list item)))
            (ogent-unpin item)
            (should-not (marker-position start))
            (should-not (marker-position end))))
      (kill-buffer buf))))

(ert-deftest ogent-unpin-all-clears-list ()
  "Unpin-all empties the pinned context."
  (let* ((buf (generate-new-buffer "*unpin-all*"))
         (ogent-pinned-context
          (list (make-ogent-pinned-item :type 'buffer :buffer buf
                                        :label "a" :pinned-at (current-time))
                (make-ogent-pinned-item :type 'buffer :buffer buf
                                        :label "b" :pinned-at (current-time)))))
    (unwind-protect
        (progn
          (ogent-unpin-all)
          (should (null ogent-pinned-context)))
      (kill-buffer buf))))

;;; List pinned tests

(ert-deftest ogent-list-pinned-empty ()
  "Listing pinned items when empty shows message."
  (let ((ogent-pinned-context nil))
    ;; Should not error
    (ogent-list-pinned)))

(ert-deftest ogent-list-pinned-with-items ()
  "Listing pinned items creates a help buffer."
  (let* ((buf (generate-new-buffer "*list-pinned*"))
         (ogent-pinned-context
          (list (make-ogent-pinned-item :type 'buffer :buffer buf
                                        :label "test-buf" :pinned-at (current-time)))))
    (unwind-protect
        (progn
          (ogent-list-pinned)
          (let ((help-buf (get-buffer "*Ogent Pinned Context*")))
            (when help-buf
              (with-current-buffer help-buf
                (should (string-match-p "test-buf" (buffer-string))))
              (kill-buffer help-buf))))
      (kill-buffer buf))))

;;; Pin DWIM tests

(ert-deftest ogent-pin-dwim-pins-file ()
  "DWIM pins file when buffer visits a file."
  (let ((ogent-pinned-context nil)
        (tmp (make-temp-file "ogent-dwim-test")))
    (unwind-protect
        (let ((buf (find-file-noselect tmp)))
          (unwind-protect
              (with-current-buffer buf
                (ogent-pin-dwim)
                (should (= (length ogent-pinned-context) 1))
                (should (eq (ogent-pinned-item-type (car ogent-pinned-context)) 'file)))
            (kill-buffer buf)))
      (delete-file tmp))))

(ert-deftest ogent-pin-dwim-pins-buffer ()
  "DWIM pins buffer when no file is associated."
  (let ((ogent-pinned-context nil)
        (buf (generate-new-buffer "*dwim-buffer*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-pin-dwim)
          (should (= (length ogent-pinned-context) 1))
          (should (eq (ogent-pinned-item-type (car ogent-pinned-context)) 'buffer)))
      (kill-buffer buf))))

;;; Element properties tests

(ert-deftest ogent-context-element-properties-returns-alist ()
  "Element properties returns an alist for a heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Test Heading\n:PROPERTIES:\n:OGENT_ID: test-id\n:END:\nContent.\n")
    (goto-char (point-min))
    (let* ((element (org-element-at-point))
           (props (ogent-context--element-properties element (current-buffer))))
      (should (listp props))
      (should (assoc "OGENT_ID" props))
      (should (string= (cdr (assoc "OGENT_ID" props)) "test-id")))))

;;; Ancestor elements tests

(ert-deftest ogent-context-ancestor-elements-nested ()
  "Ancestor elements returns parent headlines."
  (skip-unless (>= emacs-major-version 29))
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Child\n*** Grandchild\nContent.\n")
    (goto-char (point-min))
    (let* ((tree (org-element-parse-buffer 'headline))
           (grandchild (org-element-map tree 'headline
                         (lambda (el)
                           (when (string= (org-element-property :raw-value el)
                                          "Grandchild")
                             el))
                         nil t)))
      (when grandchild
        (let ((ancestors (ogent-context--ancestor-elements grandchild)))
          (should (>= (length ancestors) 1)))))))

(ert-deftest ogent-context-ancestor-elements-top-level ()
  "Top-level heading has no ancestors."
  (with-temp-buffer
    (org-mode)
    (insert "* Top Level\nContent.\n")
    (goto-char (point-min))
    (let* ((element (org-element-at-point))
           (ancestors (ogent-context--ancestor-elements element)))
      (should (null ancestors)))))

;;; Buffers to search tests

(ert-deftest ogent-context-buffers-to-search-includes-current ()
  "Buffers to search includes the current buffer."
  (with-temp-buffer
    (org-mode)
    (let ((ogent-context-extra-buffers nil))
      (should (memq (current-buffer) (ogent-context--buffers-to-search))))))

(ert-deftest ogent-context-buffers-to-search-includes-extras ()
  "Buffers to search includes extra buffers."
  (let ((extra (generate-new-buffer "*extra-search*")))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (let ((ogent-context-extra-buffers (list extra)))
            (should (memq extra (ogent-context--buffers-to-search)))))
      (kill-buffer extra))))

(ert-deftest ogent-context-buffers-to-search-skips-dead ()
  "Dead extra buffers are excluded from search."
  (let ((dead (generate-new-buffer "*dead-extra*")))
    (kill-buffer dead)
    (with-temp-buffer
      (org-mode)
      (let ((ogent-context-extra-buffers (list dead)))
        (should-not (memq dead (ogent-context--buffers-to-search)))))))

;;; Find in buffer tests

(ert-deftest ogent-context-find-in-buffer-by-slug ()
  "Find in buffer locates heading by slug match."
  (with-temp-buffer
    (org-mode)
    (insert "* My Heading\nContent.\n* Another\nMore.\n")
    (let ((result (ogent-context--find-in-buffer "my-heading" (current-buffer))))
      (should result)
      (should (string= (org-element-property :raw-value result) "My Heading")))))

(ert-deftest ogent-context-find-in-buffer-not-found ()
  "Find in buffer returns nil when handle is not present."
  (with-temp-buffer
    (org-mode)
    (insert "* Something Else\nContent.\n")
    (should-not (ogent-context--find-in-buffer "nonexistent" (current-buffer)))))

;;; Completion annotation tests

(ert-deftest ogent-context-completion-annotation-returns-string ()
  "Completion annotation returns a string for a known handle."
  (with-temp-buffer
    (org-mode)
    (insert "* Test Node\nSome annotation content here.\n")
    (let ((annotation (ogent-context--completion-annotation "test-node")))
      (should (stringp annotation)))))

(ert-deftest ogent-context-completion-annotation-unknown ()
  "Completion annotation returns empty string for unknown handle."
  (with-temp-buffer
    (org-mode)
    (insert "* Known\nContent.\n")
    (let ((annotation (ogent-context--completion-annotation "totally-unknown-xyz")))
      (should (stringp annotation))
      (should (string= annotation "")))))

(provide 'ogent-context-tests)
;;; ogent-context-tests.el ends here
