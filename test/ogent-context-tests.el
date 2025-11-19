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

(provide 'ogent-context-tests)
;;; ogent-context-tests.el ends here
