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
			     (let* ((call-count 0)
				    (thunk (progn
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

(provide 'ogent-context-tests)
;;; ogent-context-tests.el ends here
