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

(provide 'ogent-ui-context-tests)
;;; ogent-ui-context-tests.el ends here
