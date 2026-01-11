;;; ogent-completions-tests.el --- Tests for completion review workflow -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-completions)
(require 'ogent-keys)

;;; Review Action Registry Tests

(ert-deftest ogent-completions-review-registry-defined ()
  "Review action registry is defined and non-empty."
  (should (boundp 'ogent-review-action-registry))
  (should (listp ogent-review-action-registry))
  (should (> (length ogent-review-action-registry) 0)))

(ert-deftest ogent-completions-review-registry-entries-valid ()
  "All review registry entries have required properties."
  (dolist (entry ogent-review-action-registry)
    (let ((name (car entry))
          (props (cdr entry)))
      (should (symbolp name))
      (should (plist-get props :key))
      (should (plist-get props :command))
      (should (plist-get props :desc))
      (should (stringp (plist-get props :key)))
      (should (symbolp (plist-get props :command)))
      (should (stringp (plist-get props :desc))))))

(ert-deftest ogent-completions-review-actions-present ()
  "Expected review actions are present in registry."
  (should (assq 'review-next ogent-review-action-registry))
  (should (assq 'review-prev ogent-review-action-registry))
  (should (assq 'review-accept ogent-review-action-registry))
  (should (assq 'review-reject ogent-review-action-registry)))

;;; Review Keybindings Tests

(ert-deftest ogent-completions-review-prefix-customizable ()
  "Review prefix is a customizable variable."
  (should (custom-variable-p 'ogent-review-prefix)))

(ert-deftest ogent-completions-review-bindings-setup ()
  "Review bindings are set up correctly."
  (let ((test-map (make-sparse-keymap))
        (ogent-review-prefix "C-c o"))
    (ogent-setup-review-bindings test-map)
    ;; Check that review commands are bound
    (should (eq (lookup-key test-map (kbd "C-c o n")) 'ogent-completion-next))
    (should (eq (lookup-key test-map (kbd "C-c o p")) 'ogent-completion-prev))
    (should (eq (lookup-key test-map (kbd "C-c o a")) 'ogent-review-accept))
    (should (eq (lookup-key test-map (kbd "C-c o x")) 'ogent-completion-reject))))

(ert-deftest ogent-completions-review-prefix-customizable-binding ()
  "Review prefix can be customized."
  (let ((test-map (make-sparse-keymap))
        (ogent-review-prefix "C-c r"))
    (ogent-setup-review-bindings test-map)
    ;; Should use custom prefix
    (should (eq (lookup-key test-map (kbd "C-c r n")) 'ogent-completion-next))
    ;; Default prefix should not be bound
    (should-not (eq (lookup-key test-map (kbd "C-c o n")) 'ogent-completion-next))))

;;; Question/Response Detection Tests

(ert-deftest ogent-completions-in-response-p-nil-outside-org ()
  "ogent-completions--in-response-p returns nil outside Org mode."
  (with-temp-buffer
    (should-not (ogent-completions--in-response-p))))

(ert-deftest ogent-completions-in-response-p-nil-at-question ()
  "ogent-completions--in-response-p returns nil at Question headline."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nSome content\n")
    (goto-char (point-min))
    (should-not (ogent-completions--in-response-p))))

(ert-deftest ogent-completions-in-response-p-t-at-response ()
  "ogent-completions--in-response-p returns t at Response headline."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\n** Response (model)\nSome content\n")
    (goto-char (point-min))
    (search-forward "Response")
    (should (ogent-completions--in-response-p))))

;;; Metadata Removal Tests

(ert-deftest ogent-completions-remove-transient-metadata ()
  "ogent-completions--remove-transient-metadata removes expected properties."
  (with-temp-buffer
    (org-mode)
    (insert "* Response (model)\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:CREATED: [2025-01-10]\n:MODEL: gpt-4\n:END:\nContent\n")
    (goto-char (point-min))
    (let ((completion (make-ogent-completion
                       :id 1
                       :model "gpt-4"
                       :marker (point-marker)
                       :end-marker (point-max-marker)
                       :status 'pending
                       :overlay nil)))
      (ogent-completions--remove-transient-metadata completion)
      ;; Transient properties should be removed
      (should-not (org-entry-get nil "RESPONSE-INDEX"))
      (should-not (org-entry-get nil "CREATED"))
      ;; Other properties should remain
      (should (string= (org-entry-get nil "MODEL") "gpt-4")))))

(ert-deftest ogent-completions-remove-transient-metadata-empty-drawer ()
  "Metadata removal handles case when properties are only transient ones."
  (with-temp-buffer
    (org-mode)
    (insert "* Response (model)\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nContent\n")
    (goto-char (point-min))
    (let ((completion (make-ogent-completion
                       :id 1
                       :model "gpt-4"
                       :marker (point-marker)
                       :end-marker (point-max-marker)
                       :status 'pending
                       :overlay nil)))
      (ogent-completions--remove-transient-metadata completion)
      ;; Should not error even when drawer becomes empty
      (should-not (org-entry-get nil "RESPONSE-INDEX")))))

;;; Registry Management Tests

(ert-deftest ogent-completions-build-registry ()
  "ogent-completions--build-registry finds Response sibling headlines."
  (with-temp-buffer
    (org-mode)
    ;; Response headlines must be siblings of Question (same level)
    (insert "** Question\nPrompt\n** Response 1\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nFirst\n** Response 2\n:PROPERTIES:\n:RESPONSE-INDEX: 2\n:END:\nSecond\n")
    (goto-char (point-min))
    (let ((marker (point-marker)))
      (let ((completions (ogent-completions--build-registry marker)))
        (should (= (length completions) 2))
        (should (= (ogent-completion-id (car completions)) 1))
        (should (= (ogent-completion-id (cadr completions)) 2))))))

(ert-deftest ogent-completions-find-question-marker ()
  "ogent-completions--find-question-marker finds parent Question."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nPrompt\n** Response\nContent\n")
    (goto-char (point-min))
    (search-forward "Response")
    (let ((marker (ogent-completions--find-question-marker)))
      (should marker)
      (should (= (marker-position marker) 1)))))

;;; Error Handling Tests

(ert-deftest ogent-completions-next-outside-org-errors ()
  "ogent-completion-next signals error outside Org mode."
  (with-temp-buffer
    (should-error (ogent-completion-next) :type 'user-error)))

(ert-deftest ogent-completions-prev-outside-org-errors ()
  "ogent-completion-prev signals error outside Org mode."
  (with-temp-buffer
    (should-error (ogent-completion-prev) :type 'user-error)))

(ert-deftest ogent-completions-accept-outside-org-errors ()
  "ogent-completion-accept signals error outside Org mode."
  (with-temp-buffer
    (should-error (ogent-completion-accept) :type 'user-error)))

(ert-deftest ogent-completions-review-accept-outside-org-errors ()
  "ogent-review-accept signals error outside Org mode."
  (with-temp-buffer
    (should-error (ogent-review-accept) :type 'user-error)))

(ert-deftest ogent-completions-reject-outside-org-errors ()
  "ogent-completion-reject signals error outside Org mode."
  (with-temp-buffer
    (should-error (ogent-completion-reject) :type 'user-error)))

;;; Describe Bindings Tests

(ert-deftest ogent-completions-describe-bindings-shows-review ()
  "ogent-describe-bindings includes review keybindings section."
  (ogent-describe-bindings)
  (with-current-buffer "*Ogent Bindings*"
    (should (string-match-p "Review Keybindings" (buffer-string)))
    (should (string-match-p "C-c o prefix" (buffer-string)))
    (should (string-match-p "review-next" (buffer-string)))
    (should (string-match-p "review-accept" (buffer-string))))
  (kill-buffer "*Ogent Bindings*"))

(provide 'ogent-completions-tests)
;;; ogent-completions-tests.el ends here
