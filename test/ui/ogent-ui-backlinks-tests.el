;;; ogent-ui-backlinks-tests.el --- Tests for backlink tracking -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-ui-backlinks)
(require 'ogent-context)

(ert-deftest ogent-backlinks-find-in-buffer ()
  "Test finding handle references in a buffer."
  (with-temp-buffer
    (org-mode)
    (insert "* Heading One\n")
    (insert "This references @test-handle in the text.\n")
    (insert "* Heading Two\n")
    (insert "Another @test-handle reference here.\n")
    (insert "And @test-handle appears twice here @test-handle.\n")
    (let ((refs (ogent-backlinks--find-in-buffer "test-handle" (current-buffer))))
      (should (= 4 (length refs)))
      ;; Check first reference
      (let ((first (car refs)))
        (should (= 2 (plist-get first :line)))
        (should (stringp (plist-get first :context)))
        (should (string-match-p "@test-handle" (plist-get first :context)))))))

(ert-deftest ogent-backlinks-no-matches ()
  "Test that no matches returns empty list."
  (with-temp-buffer
    (org-mode)
    (insert "* Heading\nNo handles here.\n")
    (let ((refs (ogent-backlinks--find-in-buffer "nonexistent" (current-buffer))))
      (should (null refs)))))

(ert-deftest ogent-backlinks-extract-context ()
  "Test context extraction around a position."
  (with-temp-buffer
    (insert "This is a long line with @handle in the middle and more text after it")
    (goto-char (point-min))
    (search-forward "@handle")
    (let ((context (ogent-backlinks--extract-context (match-beginning 0)
                                                     (current-buffer))))
      (should (stringp context))
      (should (string-match-p "@handle" context)))))

(ert-deftest ogent-backlinks-for-handle ()
  "Test scanning multiple buffers for a handle."
  (let ((buf1 (generate-new-buffer "*test-1*"))
        (buf2 (generate-new-buffer "*test-2*")))
    (unwind-protect
        (progn
          (with-current-buffer buf1
            (org-mode)
            (insert "* Test\n@myhandle is here.\n"))
          (with-current-buffer buf2
            (org-mode)
            (insert "* Other\n@myhandle is also here.\n"))
          (let ((results (ogent-backlinks-for-handle "myhandle")))
            ;; Should find references in both buffers
            (should (>= (length results) 2))
            ;; Each entry should be (buffer . refs)
            (should (cl-every #'consp results))
            (should (cl-every (lambda (x) (bufferp (car x))) results))
            (should (cl-every (lambda (x) (listp (cdr x))) results))))
      (kill-buffer buf1)
      (kill-buffer buf2))))

(ert-deftest ogent-backlinks-handle-at-point-from-title ()
  "Test extracting handle from heading title."
  (with-temp-buffer
    (org-mode)
    (insert "* Test Handle\n")
    (insert "Content here.\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (let ((handle (ogent-backlinks--handle-at-point)))
      (should (equal handle "test-handle")))))

(ert-deftest ogent-backlinks-handle-at-point-from-property ()
  "Test extracting handle from OGENT_ID property."
  (with-temp-buffer
    (org-mode)
    (insert "* Custom Title\n")
    (insert ":PROPERTIES:\n")
    (insert ":OGENT_ID: my-custom-handle\n")
    (insert ":END:\n")
    (insert "Content.\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (let ((handle (ogent-backlinks--handle-at-point)))
      (should (equal handle "my-custom-handle")))))

(ert-deftest ogent-backlinks-at-point ()
  "Test getting backlinks for current heading."
  (let ((buf1 (generate-new-buffer "*test-main*"))
        (buf2 (generate-new-buffer "*test-ref*")))
    (unwind-protect
        (progn
          (with-current-buffer buf1
            (org-mode)
            (insert "* Target Heading\n")
            (insert "This is the target.\n"))
          (with-current-buffer buf2
            (org-mode)
            (insert "* Reference\n")
            (insert "This references @target-heading.\n"))
          (with-current-buffer buf1
            (goto-char (point-min))
            (org-next-visible-heading 1)
            (let ((backlinks (ogent-backlinks-at-point)))
              (should (consp backlinks))
              ;; Should find at least the reference in buf2
              (should (cl-some (lambda (x) (eq (car x) buf2)) backlinks)))))
      (kill-buffer buf1)
      (kill-buffer buf2))))

(ert-deftest ogent-backlinks-format-buffer ()
  "Test formatting backlinks in a buffer."
  (let ((source-buf (generate-new-buffer "*source*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buf
            (org-mode)
            (insert "* Test\n@target appears here.\n"))
          (let ((refs (ogent-backlinks--find-in-buffer "target" source-buf))
                (backlinks (list (cons source-buf
                                      (ogent-backlinks--find-in-buffer "target" source-buf)))))
            (with-temp-buffer
              (ogent-backlinks--format-buffer "target" backlinks)
              (goto-char (point-min))
              (should (search-forward "#+title: Backlinks for @target" nil t))
              (should (search-forward "* Backlinks" nil t))
              (should (search-forward (format "** %s" (buffer-name source-buf)) nil t))
              (should (search-forward "Line 2:" nil t)))))
      (kill-buffer source-buf))))

(ert-deftest ogent-backlinks-format-empty ()
  "Test formatting when no backlinks are found."
  (with-temp-buffer
    (ogent-backlinks--format-buffer "nonexistent" nil)
    (goto-char (point-min))
    (should (search-forward "#+title: Backlinks for @nonexistent" nil t))
    (should (search-forward "No backlinks found." nil t))))

(ert-deftest ogent-backlinks-clickable-links ()
  "Test that backlink references are clickable."
  (let ((source-buf (generate-new-buffer "*source*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buf
            (org-mode)
            (insert "* Test\n@target reference.\n"))
          (let ((refs (ogent-backlinks--find-in-buffer "target" source-buf)))
            (with-temp-buffer
              (org-mode)
              (ogent-backlinks--insert-reference source-buf (car refs))
              (goto-char (point-min))
              ;; Check that button properties exist
              (let ((button (button-at (point))))
                (should button)
                (should (button-get button 'action))
                (should (button-get button 'follow-link))))))
      (kill-buffer source-buf))))

(ert-deftest ogent-backlinks-show-buffer ()
  "Test the interactive show-backlinks command."
  (let ((buf1 (generate-new-buffer "*main*"))
        (buf2 (generate-new-buffer "*ref*")))
    (unwind-protect
        (progn
          (with-current-buffer buf1
            (org-mode)
            (insert "* Target\nContent.\n"))
          (with-current-buffer buf2
            (org-mode)
            (insert "* Ref\n@target is here.\n"))
          (with-current-buffer buf1
            (goto-char (point-min))
            (org-next-visible-heading 1)
            (ogent-show-backlinks)
            ;; Check backlinks buffer was created
            (let ((backlinks-buf (get-buffer ogent-backlinks-buffer-name)))
              (should backlinks-buf)
              (with-current-buffer backlinks-buf
                (goto-char (point-min))
                (should (search-forward "Backlinks for @target" nil t))))))
      (kill-buffer buf1)
      (kill-buffer buf2)
      (when-let ((bb (get-buffer ogent-backlinks-buffer-name)))
        (kill-buffer bb)))))

(ert-deftest ogent-backlinks-word-boundaries ()
  "Test that handle matching respects word boundaries."
  (with-temp-buffer
    (org-mode)
    (insert "* Test\n")
    (insert "@test is a handle.\n")
    (insert "@testing is different.\n")
    (insert "email@test.com is not a handle.\n")
    (let ((refs (ogent-backlinks--find-in-buffer "test" (current-buffer))))
      ;; Should only match @test, not @testing or email@test.com
      (should (= 1 (length refs)))
      (should (= 2 (plist-get (car refs) :line))))))

(provide 'ogent-ui-backlinks-tests)
;;; ogent-ui-backlinks-tests.el ends here
