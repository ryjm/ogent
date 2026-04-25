;;; ogent-completions-tests.el --- Tests for completion review workflow -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-completions)
(require 'ogent-ui)
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

;;; Response End Marker Tests

(ert-deftest ogent-completions-response-end-marker-returns-marker ()
  "ogent-completions--response-end-marker returns marker at end of subtree."
  (with-temp-buffer
    (org-mode)
    (insert "* Response\nContent line 1\nContent line 2\n* Next heading\n")
    (goto-char (point-min))
    (let ((marker (ogent-completions--response-end-marker (point-marker))))
      (should marker)
      (should (markerp marker))
      ;; Should be at or before the next heading
      (should (> (marker-position marker) (point-min)))
      (should (<= (marker-position marker) (point-max))))))

(ert-deftest ogent-completions-response-end-marker-nil-for-nil-input ()
  "ogent-completions--response-end-marker returns nil for nil marker."
  (should-not (ogent-completions--response-end-marker nil)))

(ert-deftest ogent-completions-response-end-marker-nil-for-dead-buffer ()
  "ogent-completions--response-end-marker returns nil when buffer is dead."
  (let ((marker (with-temp-buffer
                  (org-mode)
                  (insert "* Response\nContent\n")
                  (goto-char (point-min))
                  (point-marker))))
    ;; Buffer is now killed (temp buffer is gone)
    (should-not (ogent-completions--response-end-marker marker))))

;;; Get Response Model Tests

(ert-deftest ogent-completions-get-response-model-from-property ()
  "ogent-completions--get-response-model extracts MODEL property."
  (with-temp-buffer
    (org-mode)
    (insert "* Response\n:PROPERTIES:\n:MODEL: gpt-4o\n:END:\nContent\n")
    (goto-char (point-min))
    (let ((model (ogent-completions--get-response-model (point-marker))))
      (should (equal model "gpt-4o")))))

(ert-deftest ogent-completions-get-response-model-unknown-fallback ()
  "ogent-completions--get-response-model returns unknown when no model info."
  (with-temp-buffer
    (org-mode)
    (insert "* Response\nContent without model info\n")
    (goto-char (point-min))
    (let ((model (ogent-completions--get-response-model (point-marker))))
      (should (equal model "unknown")))))

(ert-deftest ogent-completions-get-response-model-nil-marker ()
  "ogent-completions--get-response-model returns nil for nil marker."
  (should-not (ogent-completions--get-response-model nil)))

;;; Get Response Index Tests

(ert-deftest ogent-completions-get-response-index-from-property ()
  "ogent-completions--get-response-index extracts RESPONSE-INDEX property."
  (with-temp-buffer
    (org-mode)
    (insert "* Response\n:PROPERTIES:\n:RESPONSE-INDEX: 3\n:END:\nContent\n")
    (goto-char (point-min))
    (let ((idx (ogent-completions--get-response-index (point-marker))))
      (should (= idx 3)))))

(ert-deftest ogent-completions-get-response-index-default-1 ()
  "ogent-completions--get-response-index defaults to 1 when no property."
  (with-temp-buffer
    (org-mode)
    (insert "* Response\nContent\n")
    (goto-char (point-min))
    (let ((idx (ogent-completions--get-response-index (point-marker))))
      (should (= idx 1)))))

;;; For-Subtree Tests

(ert-deftest ogent-completions-for-subtree-returns-completions ()
  "ogent-completions--for-subtree returns completions when in Question context."
  (with-temp-buffer
    (org-mode)
    (insert "** Question\nPrompt\n** Response 1\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nFirst\n** Response 2\n:PROPERTIES:\n:RESPONSE-INDEX: 2\n:END:\nSecond\n")
    (goto-char (point-min))
    ;; Reset local registry
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (let ((completions (ogent-completions--for-subtree)))
      (should completions)
      (should (= (length completions) 2)))))

(ert-deftest ogent-completions-for-subtree-nil-outside-context ()
  "ogent-completions--for-subtree returns nil outside Question/Response context."
  (with-temp-buffer
    (org-mode)
    (insert "* Random heading\nSome content\n")
    (goto-char (point-min))
    (should-not (ogent-completions--for-subtree))))

;;; Set Current Index Tests

(ert-deftest ogent-completions-set-current-index-stores-value ()
  "ogent-completions--set-current-index stores index in hash table."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "* Question\n")
    (goto-char (point-min))
    (let ((marker (point-marker)))
      (ogent-completions--set-current-index marker 5)
      (should (= (gethash (marker-position marker) ogent-completions--current-index) 5)))))

(ert-deftest ogent-completions-set-current-index-overwrites ()
  "ogent-completions--set-current-index overwrites previous value."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "* Question\n")
    (goto-char (point-min))
    (let ((marker (point-marker)))
      (ogent-completions--set-current-index marker 2)
      (ogent-completions--set-current-index marker 7)
      (should (= (gethash (marker-position marker) ogent-completions--current-index) 7)))))

;;; Make Overlay Tests

(ert-deftest ogent-completions-make-overlay-creates-overlay ()
  "ogent-completions--make-overlay creates an overlay spanning the completion."
  (with-temp-buffer
    (org-mode)
    (insert "* Response\nContent here\n")
    (goto-char (point-min))
    (let* ((start-marker (point-marker))
           (end-marker (progn (goto-char (point-max)) (point-marker)))
           (completion (make-ogent-completion
                        :id 1
                        :model "test"
                        :marker start-marker
                        :end-marker end-marker
                        :status 'pending
                        :overlay nil)))
      (let ((ov (ogent-completions--make-overlay completion)))
        (should ov)
        (should (overlayp ov))
        (should (= (overlay-start ov) (marker-position start-marker)))
        (should (= (overlay-end ov) (marker-position end-marker)))
        (should (eq (ogent-completion-overlay completion) ov))
        ;; Cleanup
        (delete-overlay ov)))))

(ert-deftest ogent-completions-make-overlay-replaces-existing ()
  "ogent-completions--make-overlay removes previous overlay before creating new."
  (with-temp-buffer
    (org-mode)
    (insert "* Response\nContent here\n")
    (goto-char (point-min))
    (let* ((start-marker (point-marker))
           (end-marker (progn (goto-char (point-max)) (point-marker)))
           (old-ov (make-overlay (point-min) (point-max)))
           (completion (make-ogent-completion
                        :id 1
                        :model "test"
                        :marker start-marker
                        :end-marker end-marker
                        :status 'pending
                        :overlay old-ov)))
      (let ((new-ov (ogent-completions--make-overlay completion)))
        ;; Old overlay should be deleted
        (should-not (overlay-buffer old-ov))
        ;; New overlay should be set
        (should (eq (ogent-completion-overlay completion) new-ov))
        (delete-overlay new-ov)))))

;;; Highlight / Dim Tests

(ert-deftest ogent-completions-highlight-clears-dim-face ()
  "ogent-completions--highlight removes dimming from the overlay."
  (with-temp-buffer
    (org-mode)
    (insert "* Response\nContent\n")
    (goto-char (point-min))
    (let* ((start-marker (point-marker))
           (end-marker (progn (goto-char (point-max)) (point-marker)))
           (completion (make-ogent-completion
                        :id 1
                        :model "test"
                        :marker start-marker
                        :end-marker end-marker
                        :status 'current
                        :overlay nil)))
      (ogent-completions--highlight completion)
      (let ((ov (ogent-completion-overlay completion)))
        (should ov)
        (should-not (overlay-get ov 'face))
        (should-not (overlay-get ov 'ogent-dim))
        (delete-overlay ov)))))

(ert-deftest ogent-completions-dim-sets-shadow-face ()
  "ogent-completions--dim applies dim face to overlay."
  (with-temp-buffer
    (org-mode)
    (insert "* Response\nContent\n")
    (goto-char (point-min))
    (let* ((start-marker (point-marker))
           (end-marker (progn (goto-char (point-max)) (point-marker)))
           (completion (make-ogent-completion
                        :id 1
                        :model "test"
                        :marker start-marker
                        :end-marker end-marker
                        :status 'pending
                        :overlay nil)))
      (ogent-completions--dim completion)
      (let ((ov (ogent-completion-overlay completion)))
        (should ov)
        (should (eq (overlay-get ov 'face) ogent-completions-dim-face))
        (should (overlay-get ov 'ogent-dim))
        (delete-overlay ov)))))

;;; Update Visual State Tests

(ert-deftest ogent-completions-update-visual-state-highlights-current ()
  "ogent-completions--update-visual-state highlights only current index."
  (with-temp-buffer
    (org-mode)
    (insert "** Response A\nFirst\n** Response B\nSecond\n")
    (goto-char (point-min))
    (let* ((m1 (point-marker))
           (_ (search-forward "** Response B"))
           (m2 (progn (beginning-of-line) (point-marker)))
           (completions
            (list (make-ogent-completion
                   :id 1 :model "a"
                   :marker m1
                   :end-marker (copy-marker (+ (marker-position m1) 20))
                   :status 'pending :overlay nil)
                  (make-ogent-completion
                   :id 2 :model "b"
                   :marker m2
                   :end-marker (point-max-marker)
                   :status 'pending :overlay nil))))
      (ogent-completions--update-visual-state completions 0)
      ;; First should be highlighted (no dim)
      (should-not (overlay-get (ogent-completion-overlay (nth 0 completions)) 'ogent-dim))
      ;; Second should be dimmed
      (should (overlay-get (ogent-completion-overlay (nth 1 completions)) 'ogent-dim))
      ;; Cleanup
      (dolist (c completions)
        (when (ogent-completion-overlay c)
          (delete-overlay (ogent-completion-overlay c)))))))

;;; Clear Overlays Tests

(ert-deftest ogent-completions-clear-overlays-removes-all ()
  "ogent-completions--clear-overlays removes all overlays."
  (with-temp-buffer
    (insert "Some text")
    (let* ((ov1 (make-overlay 1 5))
           (ov2 (make-overlay 5 9))
           (completions
            (list (make-ogent-completion
                   :id 1 :model "a" :marker nil :end-marker nil
                   :status 'pending :overlay ov1)
                  (make-ogent-completion
                   :id 2 :model "b" :marker nil :end-marker nil
                   :status 'pending :overlay ov2))))
      (ogent-completions--clear-overlays completions)
      ;; Overlays should be deleted
      (should-not (overlay-buffer ov1))
      (should-not (overlay-buffer ov2))
      ;; Struct fields should be nil
      (should-not (ogent-completion-overlay (nth 0 completions)))
      (should-not (ogent-completion-overlay (nth 1 completions))))))

(ert-deftest ogent-completions-clear-overlays-handles-nil-overlays ()
  "ogent-completions--clear-overlays handles completions with nil overlays."
  (let ((completions
         (list (make-ogent-completion
                :id 1 :model "a" :marker nil :end-marker nil
                :status 'pending :overlay nil))))
    ;; Should not error
    (ogent-completions--clear-overlays completions)))

;;; Delete Completion Tests

(ert-deftest ogent-completions-delete-completion-removes-subtree ()
  "ogent-completions--delete-completion deletes the response region."
  (with-temp-buffer
    (org-mode)
    (insert "** Question\nPrompt\n** Response\nContent\n** Other\n")
    (goto-char (point-min))
    (search-forward "** Response")
    (beginning-of-line)
    (let* ((start-marker (point-marker))
           (end-marker (progn
                         (search-forward "** Other")
                         (beginning-of-line)
                         (point-marker)))
           (completion (make-ogent-completion
                        :id 1 :model "test"
                        :marker start-marker
                        :end-marker end-marker
                        :status 'pending
                        :overlay nil)))
      (ogent-completions--delete-completion completion)
      ;; Response content should be gone
      (should-not (string-match-p "Response" (buffer-string)))
      ;; Other heading should remain
      (should (string-match-p "Other" (buffer-string))))))

(ert-deftest ogent-completions-delete-completion-cleans-overlay ()
  "ogent-completions--delete-completion cleans up overlay before deleting."
  (with-temp-buffer
    (insert "Start\nResponse content\nEnd")
    (let* ((ov (make-overlay 7 24))
           (start-marker (copy-marker 7))
           (end-marker (copy-marker 24))
           (completion (make-ogent-completion
                        :id 1 :model "test"
                        :marker start-marker
                        :end-marker end-marker
                        :status 'pending
                        :overlay ov)))
      (ogent-completions--delete-completion completion)
      ;; Overlay should be deleted
      (should-not (overlay-buffer ov))
      ;; Markers should be nil'd
      (should-not (marker-buffer start-marker))
      (should-not (marker-buffer end-marker)))))

;;; Invalidate Registry Tests

(ert-deftest ogent-completions-invalidate-registry-removes-entries ()
  "ogent-completions--invalidate-registry removes registry entries."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "* Question\n")
    (goto-char (point-min))
    (let ((marker (point-marker))
          (key nil))
      (setq key (marker-position marker))
      ;; Populate registry
      (puthash key '(completion1 completion2) ogent-completions--registry)
      (puthash key 0 ogent-completions--current-index)
      ;; Invalidate
      (ogent-completions--invalidate-registry marker)
      ;; Both tables should have entry removed
      (should-not (gethash key ogent-completions--registry))
      (should-not (gethash key ogent-completions--current-index)))))

(ert-deftest ogent-completions-invalidate-registry-idempotent ()
  "ogent-completions--invalidate-registry is safe to call multiple times."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "* Question\n")
    (goto-char (point-min))
    (let ((marker (point-marker)))
      ;; Call twice -- should not error
      (ogent-completions--invalidate-registry marker)
      (ogent-completions--invalidate-registry marker)
      (should-not (gethash (marker-position marker) ogent-completions--registry)))))

;;; On Response Complete Hook Tests

(ert-deftest ogent-completions-on-response-complete-invalidates ()
  "ogent-completions--on-response-complete invalidates the registry."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    ;; Set buffer-local session flag so boundp returns t
    (setq-local ogent-session-buffer-p t)
    (insert "** Question\nPrompt\n** Response\nContent\n")
    ;; Find the actual Question marker position that find-question-marker
    ;; will return by calling it from the Response heading
    (goto-char (point-min))
    (search-forward "** Response")
    (beginning-of-line)
    (let* ((response-marker (point-marker))
           ;; Determine the question key the same way the code does
           (question-marker (ogent-completions--find-question-marker))
           (question-pos (and question-marker (marker-position question-marker))))
      ;; Pre-populate registry with the correct key
      (puthash question-pos '(dummy) ogent-completions--registry)
      (let ((request (make-ogent-ui-request :marker response-marker)))
        (ogent-completions--on-response-complete request)
        ;; The registry for this question should now be invalidated
        (should-not (gethash question-pos ogent-completions--registry))))))

(ert-deftest ogent-completions-on-response-complete-nil-request ()
  "ogent-completions--on-response-complete handles nil request gracefully."
  (with-temp-buffer
    (org-mode)
    (let ((ogent-session-buffer-p t))
      ;; Should not error with nil request
      (ogent-completions--on-response-complete nil))))

(ert-deftest ogent-completions-on-response-complete-non-session-buffer ()
  "ogent-completions--on-response-complete is a no-op outside session buffers."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (puthash 1 '(dummy) ogent-completions--registry)
    ;; ogent-session-buffer-p is unbound or nil
    (ogent-completions--on-response-complete nil)
    ;; Registry should be unchanged
    (should (gethash 1 ogent-completions--registry))))

;;; Find Question Marker Tests (Additional)

(ert-deftest ogent-completions-find-question-marker-at-question ()
  "ogent-completions--find-question-marker returns marker when at Question."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nPrompt here\n")
    (goto-char (point-min))
    (let ((marker (ogent-completions--find-question-marker)))
      (should marker)
      (should (= (marker-position marker) 1)))))

(ert-deftest ogent-completions-find-question-marker-at-response ()
  "ogent-completions--find-question-marker navigates back from Response."
  (with-temp-buffer
    (org-mode)
    (insert "** Question\nPrompt\n** Response\nContent\n")
    (goto-char (point-min))
    (search-forward "** Response")
    (beginning-of-line)
    (let ((marker (ogent-completions--find-question-marker)))
      (should marker)
      (save-excursion
        (goto-char (marker-position marker))
        (should (string-match-p "\\`Question" (org-get-heading t t t t)))))))

(ert-deftest ogent-completions-find-question-marker-at-random-heading ()
  "ogent-completions--find-question-marker returns nil for non-Q/R heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Random\nSome content\n")
    (goto-char (point-min))
    (should-not (ogent-completions--find-question-marker))))

(ert-deftest ogent-completions-find-question-marker-outside-org ()
  "ogent-completions--find-question-marker returns nil outside org-mode."
  (with-temp-buffer
    (should-not (ogent-completions--find-question-marker))))

;;; Find Responses Tests

(ert-deftest ogent-completions-find-responses-multiple ()
  "ogent-completions--find-responses finds all Response siblings."
  (with-temp-buffer
    (org-mode)
    (insert "** Question\nPrompt\n** Response 1\nFirst\n** Response 2\nSecond\n** Response 3\nThird\n")
    (goto-char (point-min))
    (let* ((marker (point-marker))
           (responses (ogent-completions--find-responses marker)))
      (should (= (length responses) 3)))))

(ert-deftest ogent-completions-find-responses-none ()
  "ogent-completions--find-responses returns nil when no responses exist."
  (with-temp-buffer
    (org-mode)
    (insert "** Question\nPrompt\n** Other heading\nNot a response\n")
    (goto-char (point-min))
    (let* ((marker (point-marker))
           (responses (ogent-completions--find-responses marker)))
      (should-not responses))))

(ert-deftest ogent-completions-find-responses-nil-marker ()
  "ogent-completions--find-responses returns nil for nil marker."
  (should-not (ogent-completions--find-responses nil)))

(ert-deftest ogent-completions-find-responses-dead-buffer ()
  "ogent-completions--find-responses returns nil when marker buffer is dead."
  (let ((marker (with-temp-buffer
                  (org-mode)
                  (insert "** Question\n")
                  (goto-char (point-min))
                  (point-marker))))
    ;; temp-buffer is now killed
    (should-not (ogent-completions--find-responses marker))))

;;; Ensure Registry Tests

(ert-deftest ogent-completions-ensure-registry-builds-on-first-call ()
  "ogent-completions--ensure-registry builds registry on first access."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Response\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nContent\n")
    (goto-char (point-min))
    (let* ((marker (point-marker))
           (completions (ogent-completions--ensure-registry marker)))
      (should completions)
      (should (= (length completions) 1))
      ;; Current index should be set to 0
      (should (= (gethash (marker-position marker) ogent-completions--current-index) 0)))))

(ert-deftest ogent-completions-ensure-registry-caches ()
  "ogent-completions--ensure-registry returns cached registry on second call."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Response\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nContent\n")
    (goto-char (point-min))
    (let ((marker (point-marker)))
      (let ((first (ogent-completions--ensure-registry marker))
            (second (ogent-completions--ensure-registry marker)))
        ;; Should return same list object (cached)
        (should (eq first second))))))

;;; Current Completion Tests

(ert-deftest ogent-completions-current-returns-indexed-completion ()
  "ogent-completions--current returns the completion at current index."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Response 1\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nFirst\n** Response 2\n:PROPERTIES:\n:RESPONSE-INDEX: 2\n:END:\nSecond\n")
    (goto-char (point-min))
    ;; Build registry
    (ogent-completions--for-subtree)
    ;; Should return first completion (index 0)
    (let ((current (ogent-completions--current)))
      (should current)
      (should (= (ogent-completion-id current) 1)))))

(ert-deftest ogent-completions-current-returns-nil-outside-context ()
  "ogent-completions--current returns nil outside Question/Response context."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "* Random\nContent\n")
    (goto-char (point-min))
    (should-not (ogent-completions--current))))

;;; Completion Struct Tests

(ert-deftest ogent-completions-struct-accessors ()
  "ogent-completion struct accessors work correctly."
  (let ((c (make-ogent-completion
            :id 42
            :model "test-model"
            :marker nil
            :end-marker nil
            :status 'pending
            :overlay nil)))
    (should (= (ogent-completion-id c) 42))
    (should (equal (ogent-completion-model c) "test-model"))
    (should (eq (ogent-completion-status c) 'pending))
    (should-not (ogent-completion-marker c))
    (should-not (ogent-completion-overlay c))))

(ert-deftest ogent-completions-struct-setf ()
  "ogent-completion struct fields can be modified with setf."
  (let ((c (make-ogent-completion
            :id 1 :model "a" :marker nil :end-marker nil
            :status 'pending :overlay nil)))
    (setf (ogent-completion-status c) 'accepted)
    (should (eq (ogent-completion-status c) 'accepted))
    (setf (ogent-completion-model c) "b")
    (should (equal (ogent-completion-model c) "b"))))

;;; In Response P Tests (Additional)

(ert-deftest ogent-completions-in-response-p-case-insensitive ()
  "ogent-completions--in-response-p matches 'response' case-insensitively."
  (with-temp-buffer
    (org-mode)
    (insert "* response (model)\nContent\n")
    (goto-char (point-min))
    (should (ogent-completions--in-response-p))))

(ert-deftest ogent-completions-in-response-p-response-with-suffix ()
  "ogent-completions--in-response-p matches Response with suffix text."
  (with-temp-buffer
    (org-mode)
    (insert "* Response (claude-3)\nContent\n")
    (goto-char (point-min))
    (should (ogent-completions--in-response-p))))

(ert-deftest ogent-completions-in-response-p-at-body ()
  "ogent-completions--in-response-p returns t even when at body text under Response."
  (with-temp-buffer
    (org-mode)
    (insert "* Response\nBody text here\n")
    (goto-char (point-min))
    (forward-line 1)
    ;; org-back-to-heading jumps to the Response heading above,
    ;; so this correctly returns non-nil
    (should (ogent-completions--in-response-p))))

;;; Get Response Model From Request Block

(ert-deftest ogent-completions-get-response-model-from-sibling ()
  "ogent-completions--get-response-model finds model in sibling Request block."
  (with-temp-buffer
    (org-mode)
    (insert "* Request\n:model claude-3-opus\n* Response\nContent\n")
    (goto-char (point-min))
    (search-forward "* Response")
    (beginning-of-line)
    (let ((model (ogent-completions--get-response-model (point-marker))))
      (should (equal model "claude-3-opus")))))

;;; Get Response Index (Additional)

(ert-deftest ogent-completions-get-response-index-nil-marker ()
  "ogent-completions--get-response-index returns nil for nil marker."
  (should-not (ogent-completions--get-response-index nil)))

;;; Build Registry Edge Cases

(ert-deftest ogent-completions-build-registry-single-response ()
  "ogent-completions--build-registry handles single response."
  (with-temp-buffer
    (org-mode)
    (insert "** Question\nPrompt\n** Response\nContent\n")
    (goto-char (point-min))
    (let ((completions (ogent-completions--build-registry (point-marker))))
      (should (= (length completions) 1))
      (should (eq (ogent-completion-status (car completions)) 'pending)))))

(ert-deftest ogent-completions-build-registry-sets-markers ()
  "ogent-completions--build-registry sets both marker and end-marker."
  (with-temp-buffer
    (org-mode)
    (insert "** Question\nPrompt\n** Response\nContent\n")
    (goto-char (point-min))
    (let* ((completions (ogent-completions--build-registry (point-marker)))
           (c (car completions)))
      (should (markerp (ogent-completion-marker c)))
      (should (markerp (ogent-completion-end-marker c)))
      (should (< (marker-position (ogent-completion-marker c))
                 (marker-position (ogent-completion-end-marker c)))))))

;;; Completions Setup Tests

(ert-deftest ogent-completions-setup-adds-hook ()
  "ogent-completions-setup adds the after-completion hook."
  (defvar ogent-after-completion-hook nil)
  (let ((ogent-after-completion-hook nil))
    (ogent-completions-setup)
    (should (memq 'ogent-completions--on-response-complete
                  ogent-after-completion-hook))))

;;; Cycling with Single Completion

(ert-deftest ogent-completions-next-single-completion-no-error ()
  "ogent-completion-next returns early when only one completion."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Response\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nContent\n")
    (goto-char (point-min))
    ;; cl-return-from uses throw; catch it here
    (catch '--cl-block-ogent-completion-next--
      (ogent-completion-next))))

(ert-deftest ogent-completions-prev-single-completion-no-error ()
  "ogent-completion-prev returns early when only one completion."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Response\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nContent\n")
    (goto-char (point-min))
    ;; cl-return-from uses throw; catch it here
    (catch '--cl-block-ogent-completion-prev--
      (ogent-completion-prev))))

;;; Error When Not in Context

(ert-deftest ogent-completions-next-no-question-errors ()
  "ogent-completion-next errors when not in Question/Response context."
  (with-temp-buffer
    (org-mode)
    (insert "* Random heading\nContent\n")
    (goto-char (point-min))
    (should-error (ogent-completion-next) :type 'user-error)))

(ert-deftest ogent-completions-prev-no-question-errors ()
  "ogent-completion-prev errors when not in Question/Response context."
  (with-temp-buffer
    (org-mode)
    (insert "* Random heading\nContent\n")
    (goto-char (point-min))
    (should-error (ogent-completion-prev) :type 'user-error)))

(ert-deftest ogent-completions-accept-no-question-errors ()
  "ogent-completion-accept errors when not in Question/Response context."
  (with-temp-buffer
    (org-mode)
    (insert "* Random heading\nContent\n")
    (goto-char (point-min))
    (should-error (ogent-completion-accept) :type 'user-error)))

(ert-deftest ogent-completions-reject-no-question-errors ()
  "ogent-completion-reject errors when not in Question/Response context."
  (with-temp-buffer
    (org-mode)
    (insert "* Random heading\nContent\n")
    (goto-char (point-min))
    (should-error (ogent-completion-reject) :type 'user-error)))

;;; Review Accept No Question

(ert-deftest ogent-completions-review-accept-no-question-errors ()
  "ogent-review-accept errors when not in Question/Response context."
  (with-temp-buffer
    (org-mode)
    (insert "* Random heading\nContent\n")
    (goto-char (point-min))
    (should-error (ogent-review-accept) :type 'user-error)))

;;; Delete Completion with Dead Markers

(ert-deftest ogent-completions-delete-completion-dead-markers ()
  "ogent-completions--delete-completion handles dead marker buffers."
  (let ((marker (with-temp-buffer
                  (insert "content")
                  (point-marker))))
    ;; Buffer is now dead
    (let ((completion (make-ogent-completion
                       :id 1 :model "test"
                       :marker marker
                       :end-marker marker
                       :status 'pending
                       :overlay nil)))
      ;; Should not error
      (ogent-completions--delete-completion completion))))

;;; Remove Transient Metadata Nil Marker

(ert-deftest ogent-completions-remove-transient-metadata-nil-marker ()
  "ogent-completions--remove-transient-metadata handles nil marker."
  (let ((completion (make-ogent-completion
                     :id 1 :model "test"
                     :marker nil
                     :end-marker nil
                     :status 'pending
                     :overlay nil)))
    ;; Should not error
    (ogent-completions--remove-transient-metadata completion)))

;;; Customization Variables

(ert-deftest ogent-completions-dim-face-default ()
  "ogent-completions-dim-face defaults to shadow."
  (should (eq ogent-completions-dim-face 'shadow)))

(ert-deftest ogent-completions-fold-others-default ()
  "ogent-completions-fold-others defaults to t."
  (should (eq ogent-completions-fold-others t)))

;;; Cycling Multiple Completions Tests

(ert-deftest ogent-completions-next-cycles-through-multiple ()
  "ogent-completion-next cycles forward through multiple completions."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Response 1\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nFirst\n** Response 2\n:PROPERTIES:\n:RESPONSE-INDEX: 2\n:END:\nSecond\n")
    (goto-char (point-min))
    (let ((ogent-completions-fold-others nil))
      (ogent-completion-next)
      ;; Index should now be 1 (second completion)
      (let* ((question-marker (ogent-completions--find-question-marker))
             (key (marker-position question-marker))
             (idx (gethash key ogent-completions--current-index)))
        (should (= idx 1))))))

(ert-deftest ogent-completions-prev-cycles-backward ()
  "ogent-completion-prev cycles backward wrapping around."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Response 1\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nFirst\n** Response 2\n:PROPERTIES:\n:RESPONSE-INDEX: 2\n:END:\nSecond\n")
    (goto-char (point-min))
    (let ((ogent-completions-fold-others nil))
      (ogent-completion-prev)
      ;; Index should wrap to last (1)
      (let* ((question-marker (ogent-completions--find-question-marker))
             (key (marker-position question-marker))
             (idx (gethash key ogent-completions--current-index)))
        (should (= idx 1))))))

;;; Accept/Reject with y-or-n-p Tests

(ert-deftest ogent-completions-accept-single-no-confirm ()
  "ogent-completion-accept with single completion does not confirm."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Response\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nContent\n")
    (goto-char (point-min))
    (let ((ogent-completions-fold-others nil)
          (confirm-called nil))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (_prompt) (setq confirm-called t) t)))
        (ogent-completion-accept))
      ;; With single completion, y-or-n-p should NOT be called
      (should-not confirm-called))))

(ert-deftest ogent-completions-accept-cancelled ()
  "ogent-completion-accept cancelled by user raises user-error."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Response 1\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nFirst\n** Response 2\n:PROPERTIES:\n:RESPONSE-INDEX: 2\n:END:\nSecond\n")
    (goto-char (point-min))
    (let ((ogent-completions-fold-others nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
        (should-error (ogent-completion-accept) :type 'user-error)))))

(ert-deftest ogent-completions-reject-cancelled ()
  "ogent-completion-reject cancelled by user raises user-error."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Response\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nContent\n")
    (goto-char (point-min))
    (let ((ogent-completions-fold-others nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
        (should-error (ogent-completion-reject) :type 'user-error)))))

(ert-deftest ogent-completions-review-accept-cancelled ()
  "ogent-review-accept cancelled by user raises user-error."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Response 1\n:PROPERTIES:\n:RESPONSE-INDEX: 1\n:END:\nFirst\n** Response 2\n:PROPERTIES:\n:RESPONSE-INDEX: 2\n:END:\nSecond\n")
    (goto-char (point-min))
    (let ((ogent-completions-fold-others nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
        (should-error (ogent-review-accept) :type 'user-error)))))

;;; No Completions Error Tests

(ert-deftest ogent-completions-accept-no-completions-errors ()
  "ogent-completion-accept errors when no completions found."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Other heading\nNot a response\n")
    (goto-char (point-min))
    (should-error (ogent-completion-accept) :type 'user-error)))

(ert-deftest ogent-completions-reject-no-completions-errors ()
  "ogent-completion-reject errors when no completions found."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Other heading\nNot a response\n")
    (goto-char (point-min))
    (should-error (ogent-completion-reject) :type 'user-error)))

(ert-deftest ogent-completions-review-accept-no-completions-errors ()
  "ogent-review-accept errors when no completions found."
  (with-temp-buffer
    (org-mode)
    (setq ogent-completions--registry (make-hash-table :test 'equal))
    (setq ogent-completions--current-index (make-hash-table :test 'equal))
    (insert "** Question\nPrompt\n** Other heading\nNot a response\n")
    (goto-char (point-min))
    (should-error (ogent-review-accept) :type 'user-error)))

;;; Make Overlay Edge Cases

(ert-deftest ogent-completions-make-overlay-nil-start-marker ()
  "ogent-completions--make-overlay returns nil with nil start marker."
  (let ((completion (make-ogent-completion
                      :id 1 :model "test"
                      :marker nil
                      :end-marker nil
                      :status 'pending :overlay nil)))
    (should-not (ogent-completions--make-overlay completion))))

(ert-deftest ogent-completions-make-overlay-different-buffers ()
  "ogent-completions--make-overlay returns nil when markers are in different buffers."
  (let* ((buf1 (generate-new-buffer " *test1*"))
         (buf2 (generate-new-buffer " *test2*"))
         (m1 (with-current-buffer buf1
               (insert "content1")
               (point-marker)))
         (m2 (with-current-buffer buf2
               (insert "content2")
               (point-marker)))
         (completion (make-ogent-completion
                       :id 1 :model "test"
                       :marker m1 :end-marker m2
                       :status 'pending :overlay nil)))
    (unwind-protect
        (should-not (ogent-completions--make-overlay completion))
      (kill-buffer buf1)
      (kill-buffer buf2))))

;;; Get Response Model Dead Buffer

(ert-deftest ogent-completions-get-response-model-dead-buffer ()
  "ogent-completions--get-response-model returns nil for dead buffer marker."
  (let ((marker (with-temp-buffer
                  (org-mode)
                  (insert "* Response\nContent\n")
                  (goto-char (point-min))
                  (point-marker))))
    ;; Buffer is now dead
    (should-not (ogent-completions--get-response-model marker))))

(provide 'ogent-completions-tests)
;;; ogent-completions-tests.el ends here
