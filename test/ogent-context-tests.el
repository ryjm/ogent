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

(provide 'ogent-context-tests)
;;; ogent-context-tests.el ends here
