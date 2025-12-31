;;; ogent-keys-tests.el --- Tests for keybinding system -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-keys)

;;; Action Registry Tests

(ert-deftest ogent-keys-registry-defined ()
  "Action registry is defined and non-empty."
  (should (boundp 'ogent-action-registry))
  (should (listp ogent-action-registry))
  (should (> (length ogent-action-registry) 0)))

(ert-deftest ogent-keys-registry-entries-valid ()
  "All registry entries have required properties."
  (dolist (entry ogent-action-registry)
    (let ((name (car entry))
          (props (cdr entry)))
      (should (symbolp name))
      (should (plist-get props :key))
      (should (plist-get props :command))
      (should (plist-get props :desc))
      (should (stringp (plist-get props :key)))
      (should (symbolp (plist-get props :command)))
      (should (stringp (plist-get props :desc))))))

(ert-deftest ogent-keys-registry-unique-keys ()
  "All keys in registry are unique."
  (let ((keys (mapcar (lambda (entry)
                        (plist-get (cdr entry) :key))
                      ogent-action-registry)))
    (should (= (length keys) (length (delete-dups (copy-sequence keys)))))))

(ert-deftest ogent-keys-registry-unique-names ()
  "All action names in registry are unique."
  (let ((names (mapcar #'car ogent-action-registry)))
    (should (= (length names) (length (delete-dups (copy-sequence names)))))))

;;; Action Getter Tests

(ert-deftest ogent-keys-action-get-key ()
  "ogent-action-get retrieves key property."
  (should (stringp (ogent-action-get 'prompt-dispatch :key)))
  (should (string= (ogent-action-get 'prompt-dispatch :key) "p")))

(ert-deftest ogent-keys-action-get-command ()
  "ogent-action-get retrieves command property."
  (should (symbolp (ogent-action-get 'prompt-dispatch :command)))
  (should (eq (ogent-action-get 'prompt-dispatch :command) 'ogent-prompt-dispatch)))

(ert-deftest ogent-keys-action-get-desc ()
  "ogent-action-get retrieves description property."
  (should (stringp (ogent-action-get 'prompt-dispatch :desc))))

(ert-deftest ogent-keys-action-get-visual ()
  "ogent-action-get retrieves visual flag."
  ;; request has :visual t
  (should (ogent-action-get 'request :visual))
  ;; prompt-dispatch does not
  (should-not (ogent-action-get 'prompt-dispatch :visual)))

(ert-deftest ogent-keys-action-get-unknown ()
  "ogent-action-get returns nil for unknown action."
  (should-not (ogent-action-get 'nonexistent-action :key)))

;;; Vanilla Binding Tests

(ert-deftest ogent-keys-setup-vanilla-bindings ()
  "Vanilla bindings are set up correctly."
  (let ((test-map (make-sparse-keymap))
        (ogent-vanilla-prefix "C-c ."))
    (ogent-setup-vanilla-bindings test-map)
    ;; Check that prompt-dispatch is bound
    (should (eq (lookup-key test-map (kbd "C-c . p")) 'ogent-prompt-dispatch))
    ;; Check that request is bound
    (should (eq (lookup-key test-map (kbd "C-c . r")) 'ogent-request))))

(ert-deftest ogent-keys-vanilla-prefix-customizable ()
  "Vanilla prefix can be customized."
  (let ((test-map (make-sparse-keymap))
        (ogent-vanilla-prefix "C-c o"))
    (ogent-setup-vanilla-bindings test-map)
    ;; Should use custom prefix
    (should (eq (lookup-key test-map (kbd "C-c o p")) 'ogent-prompt-dispatch))
    ;; Old prefix should not be bound
    (should-not (eq (lookup-key test-map (kbd "C-c . p")) 'ogent-prompt-dispatch))))

(ert-deftest ogent-keys-all-actions-bound ()
  "All actions from registry are bound in vanilla keymap."
  (let ((test-map (make-sparse-keymap))
        (ogent-vanilla-prefix "C-c ."))
    (ogent-setup-vanilla-bindings test-map)
    (dolist (entry ogent-action-registry)
      (let* ((key (plist-get (cdr entry) :key))
             (cmd (plist-get (cdr entry) :command))
             (full-key (kbd (concat "C-c . " key))))
        (should (eq (lookup-key test-map full-key) cmd))))))

;;; Evil Binding Tests (when evil not loaded)

(ert-deftest ogent-keys-evil-bindings-skip-without-evil ()
  "Evil bindings are skipped when evil is not loaded."
  (let ((test-map (make-sparse-keymap))
        (ogent-enable-evil-bindings t))
    ;; This should not error even without evil
    (ogent-setup-evil-bindings test-map)
    ;; Map should still be empty (no evil bindings added)
    (should (equal test-map (make-sparse-keymap)))))

(ert-deftest ogent-keys-evil-bindings-disabled ()
  "Evil bindings are skipped when disabled."
  (let ((test-map (make-sparse-keymap))
        (ogent-enable-evil-bindings nil))
    (ogent-setup-evil-bindings test-map)
    ;; Map should be empty
    (should (equal test-map (make-sparse-keymap)))))

;;; Describe Bindings Tests

(ert-deftest ogent-keys-describe-bindings-creates-buffer ()
  "ogent-describe-bindings creates help buffer."
  (ogent-describe-bindings)
  (should (get-buffer "*Ogent Bindings*"))
  (with-current-buffer "*Ogent Bindings*"
    (should (string-match-p "Ogent Keybindings" (buffer-string)))
    (should (string-match-p "Vanilla prefix" (buffer-string)))
    (should (string-match-p "prompt-dispatch" (buffer-string))))
  (kill-buffer "*Ogent Bindings*"))

(ert-deftest ogent-keys-describe-bindings-shows-all-actions ()
  "ogent-describe-bindings lists all actions."
  (ogent-describe-bindings)
  (with-current-buffer "*Ogent Bindings*"
    (let ((content (buffer-string)))
      (dolist (entry ogent-action-registry)
        (let ((name (symbol-name (car entry))))
          (should (string-match-p name content))))))
  (kill-buffer "*Ogent Bindings*"))

(ert-deftest ogent-keys-describe-bindings-marks-visual ()
  "ogent-describe-bindings marks visual actions."
  (ogent-describe-bindings)
  (with-current-buffer "*Ogent Bindings*"
    (should (string-match-p "\\[visual\\]" (buffer-string))))
  (kill-buffer "*Ogent Bindings*"))

;;; Setup All Bindings Tests

(ert-deftest ogent-keys-setup-all-bindings ()
  "ogent-setup-all-bindings sets up vanilla bindings."
  (let ((test-map (make-sparse-keymap))
        (ogent-vanilla-prefix "C-c ."))
    (ogent-setup-all-bindings test-map)
    ;; Vanilla bindings should be set
    (should (eq (lookup-key test-map (kbd "C-c . p")) 'ogent-prompt-dispatch))))

;;; Customization Tests

(ert-deftest ogent-keys-customization-group-exists ()
  "ogent-keys customization group exists."
  (should (get 'ogent-keys 'custom-group)))

(ert-deftest ogent-keys-vanilla-prefix-customizable-var ()
  "ogent-vanilla-prefix is a customizable variable."
  (should (custom-variable-p 'ogent-vanilla-prefix)))

(ert-deftest ogent-keys-evil-prefix-customizable-var ()
  "ogent-evil-prefix is a customizable variable."
  (should (custom-variable-p 'ogent-evil-prefix)))

(ert-deftest ogent-keys-enable-evil-customizable-var ()
  "ogent-enable-evil-bindings is a customizable variable."
  (should (custom-variable-p 'ogent-enable-evil-bindings)))

;;; Expected Actions Tests

(ert-deftest ogent-keys-core-actions-present ()
  "Core actions are present in registry."
  (should (assq 'prompt-dispatch ogent-action-registry))
  (should (assq 'request ogent-action-registry))
  (should (assq 'abort ogent-action-registry))
  (should (assq 'retry ogent-action-registry)))

(ert-deftest ogent-keys-context-actions-present ()
  "Context actions are present in registry."
  (should (assq 'context-preview ogent-action-registry))
  (should (assq 'codemap ogent-action-registry)))

(ert-deftest ogent-keys-edit-actions-present ()
  "Edit actions are present in registry."
  (should (assq 'edit-menu ogent-action-registry))
  (should (assq 'request-edit ogent-action-registry))
  (should (assq 'goto-source ogent-action-registry))
  (should (assq 'goto-companion ogent-action-registry)))

(ert-deftest ogent-keys-navigation-actions-present ()
  "Navigation actions are present in registry."
  (should (assq 'backlinks ogent-action-registry))
  (should (assq 'graph ogent-action-registry))
  (should (assq 'open-block ogent-action-registry)))

(ert-deftest ogent-keys-session-actions-present ()
  "Session actions are present in registry."
  (should (assq 'issues ogent-action-registry))
  (should (assq 'session-save ogent-action-registry))
  (should (assq 'session-load ogent-action-registry))
  (should (assq 'session-list ogent-action-registry)))

(provide 'ogent-keys-tests)
;;; ogent-keys-tests.el ends here
