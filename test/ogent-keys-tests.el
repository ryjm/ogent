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

(ert-deftest ogent-keys-registry-commands-are-loaded ()
  "All registry commands should be available after loading ogent."
  (require 'ogent)
  (dolist (entry ogent-action-registry)
    (let ((command (plist-get (cdr entry) :command)))
      (should (commandp command)))))

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

(ert-deftest ogent-keys-evil-prefix-defaults-to-doom-style ()
  "Default evil prefix follows Doom's SPC o convention."
  (should (equal ogent-evil-prefix "SPC o")))

(ert-deftest ogent-keys-enable-evil-customizable-var ()
  "ogent-enable-evil-bindings is a customizable variable."
  (should (custom-variable-p 'ogent-enable-evil-bindings)))

(ert-deftest ogent-keys-doom-customization-vars ()
  "Doom keybinding customization variables are available."
  (should (custom-variable-p 'ogent-enable-doom-bindings))
  (should (custom-variable-p 'ogent-doom-prefix)))

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
  (should (assq 'ai-speed-edit ogent-action-registry))
  (should (assq 'fix-diagnostic ogent-action-registry))
  (should (assq 'fix-buffer-diagnostics ogent-action-registry))
  (should (assq 'quick-edit ogent-action-registry))
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

(ert-deftest ogent-keys-cabinet-actions-present ()
  "Cabinet actions expose the complete Org OS entry surface."
  (dolist (action '(cabinet-home
	                    cabinet-status
	                    cabinet-agents
	                    cabinet-agent-profile
	                    cabinet-org-chart
	                    cabinet-tasks
	                    cabinet-conversations
	                    cabinet-actions
	                    cabinet-data
	                    cabinet-schedule
	                    cabinet-agenda
	                    cabinet-git
	                    cabinet-palette
	                    cabinet-settings
	                    cabinet-help
	                    cabinet-onboard
	                    cabinet-registry-import
	                    cabinet-backup
	                    cabinet-search
	                    cabinet-apps
                    cabinet-create-agent
                    cabinet-create-job))
    (should (assq action ogent-action-registry))))

(ert-deftest ogent-keys-cabinet-visible-dispatch-keys-are-unique ()
  "Cabinet action keys in the visible dispatch registry do not collide."
  (let ((keys nil))
    (dolist (entry ogent-action-registry)
      (when (string-prefix-p "cabinet-" (symbol-name (car entry)))
        (push (plist-get (cdr entry) :key) keys)))
    (should (= (length keys) (length (delete-dups (copy-sequence keys)))))))

;;; Review Bindings Tests

(ert-deftest ogent-keys-review-bindings-setup ()
  "Test that review bindings are set up correctly."
  (let ((map (make-sparse-keymap)))
    (ogent-setup-review-bindings map)
    ;; Check that review keys are bound under review prefix
    (should (eq (lookup-key map (kbd (concat ogent-review-prefix " n")))
                'ogent-completion-next))
    (should (eq (lookup-key map (kbd (concat ogent-review-prefix " p")))
                'ogent-completion-prev))
    (should (eq (lookup-key map (kbd (concat ogent-review-prefix " a")))
                'ogent-review-accept))
    (should (eq (lookup-key map (kbd (concat ogent-review-prefix " x")))
                'ogent-completion-reject))))

(ert-deftest ogent-keys-review-registry-has-entries ()
  "Test that review action registry has expected entries."
  (should (assq 'review-next ogent-review-action-registry))
  (should (assq 'review-prev ogent-review-action-registry))
  (should (assq 'review-accept ogent-review-action-registry))
  (should (assq 'review-reject ogent-review-action-registry)))

(ert-deftest ogent-keys-doom-bindings-install-under-prefix ()
  "Doom leader bindings install the action registry under ogent-doom-prefix."
  (let ((leader-map (make-sparse-keymap))
        (ogent-enable-doom-bindings t)
        (ogent-doom-prefix "o"))
    (ogent-setup-doom-bindings leader-map)
    (should (eq (lookup-key leader-map (kbd "o p"))
                'ogent-prompt-dispatch))
    (should (eq (lookup-key leader-map (kbd "o r"))
                'ogent-request))
    (should (eq (lookup-key leader-map (kbd "o v"))
                'ogent-ai-speed-edit))
    (should (eq (lookup-key leader-map (kbd "o f"))
                'ogent-fix-diagnostic))
    (should (eq (lookup-key leader-map (kbd "o F"))
                'ogent-fix-buffer-diagnostics))
    (should (eq (lookup-key leader-map (kbd "o k"))
                'ogent-quick-edit))
    (should (eq (lookup-key leader-map (kbd "o E"))
                'ogent-request-edit))))

(ert-deftest ogent-keys-doom-bindings-noerror-without-doom ()
  "Doom setup returns nil when NOERROR is non-nil and Doom is absent."
  (let ((ogent-enable-doom-bindings t))
    (should-not (ogent-setup-doom-bindings nil t))))

;;; Setup All Bindings

(ert-deftest ogent-keys-setup-all-bindings-comprehensive ()
  "Test that setup-all-bindings configures vanilla and review bindings."
  (let ((map (make-sparse-keymap)))
    (cl-letf (((symbol-function 'ogent-setup-evil-bindings)
               (lambda (_) nil)))
      (ogent-setup-all-bindings map)
      ;; Vanilla bindings should be set
      (should (commandp (lookup-key map (kbd (concat ogent-vanilla-prefix " p")))))
      ;; Review bindings should be set
      (should (eq (lookup-key map (kbd (concat ogent-review-prefix " n")))
                  'ogent-completion-next)))))

;;; Action Registry Properties

(ert-deftest ogent-keys-action-get-works ()
  "Test ogent-action-get retrieves properties."
  (should (equal (ogent-action-get 'prompt-dispatch :key) "p"))
  (should (equal (ogent-action-get 'prompt-dispatch :command) 'ogent-prompt-dispatch))
  (should (equal (ogent-action-get 'request :visual) t)))

(ert-deftest ogent-keys-action-get-nil-for-missing ()
  "Test ogent-action-get returns nil for nonexistent action."
  (should-not (ogent-action-get 'nonexistent :key)))

;;; Which-Key Integration

(ert-deftest ogent-keys-setup-which-key-no-error ()
  "Test setup-which-key doesn't error when which-key not loaded."
  ;; which-key is typically not loaded in test batch mode
  (ogent-setup-which-key))

;;; Describe Bindings

(ert-deftest ogent-keys-describe-bindings-produces-output ()
  "Test describe-bindings generates help buffer output."
  (unwind-protect
      (progn
        (ogent-describe-bindings)
        (let ((buf (get-buffer "*Ogent Bindings*")))
          (should buf)
          (with-current-buffer buf
            (should (string-match-p "Ogent Keybindings" (buffer-string)))
            (should (string-match-p "prompt-dispatch" (buffer-string)))
            (should (string-match-p "Review Keybindings" (buffer-string))))))
    (when (get-buffer "*Ogent Bindings*")
      (kill-buffer "*Ogent Bindings*"))))

;;; Review Prefix Customization Tests

(ert-deftest ogent-keys-review-prefix-customizable-var ()
  "ogent-review-prefix is a customizable variable."
  (should (custom-variable-p 'ogent-review-prefix)))

(ert-deftest ogent-keys-review-bindings-custom-prefix ()
  "Review bindings respect custom prefix."
  (let ((map (make-sparse-keymap))
        (ogent-review-prefix "C-c r"))
    (ogent-setup-review-bindings map)
    ;; Should use custom prefix
    (should (eq (lookup-key map (kbd "C-c r n"))
                'ogent-completion-next))
    (should (eq (lookup-key map (kbd "C-c r p"))
                'ogent-completion-prev))
    ;; Default prefix should not be bound
    (should-not (eq (lookup-key map (kbd "C-c o n")) 'ogent-completion-next))))

;;; Review Action Registry Validation Tests

(ert-deftest ogent-keys-review-registry-entries-valid ()
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

(ert-deftest ogent-keys-review-registry-unique-keys ()
  "All keys in review registry are unique."
  (let ((keys (mapcar (lambda (entry)
                        (plist-get (cdr entry) :key))
                      ogent-review-action-registry)))
    (should (= (length keys) (length (delete-dups (copy-sequence keys)))))))

(ert-deftest ogent-keys-review-registry-unique-names ()
  "All action names in review registry are unique."
  (let ((names (mapcar #'car ogent-review-action-registry)))
    (should (= (length names) (length (delete-dups (copy-sequence names)))))))

;;; Which-Key No-Op Tests

(ert-deftest ogent-keys-setup-which-key-noop-without-which-key ()
  "setup-which-key does nothing when which-key not loaded."
  ;; which-key is typically not loaded in batch mode
  ;; Should not error
  (ogent-setup-which-key))

;;; Describe Bindings Review Section Tests

(ert-deftest ogent-keys-describe-bindings-shows-review-prefix ()
  "ogent-describe-bindings shows review prefix info."
  (unwind-protect
      (progn
        (ogent-describe-bindings)
        (with-current-buffer "*Ogent Bindings*"
          (should (string-match-p "Review prefix" (buffer-string)))
          (should (string-match-p "C-c o" (buffer-string)))))
    (when (get-buffer "*Ogent Bindings*")
      (kill-buffer "*Ogent Bindings*"))))

(ert-deftest ogent-keys-describe-bindings-shows-review-actions ()
  "ogent-describe-bindings lists all review actions."
  (unwind-protect
      (progn
        (ogent-describe-bindings)
        (with-current-buffer "*Ogent Bindings*"
          (let ((content (buffer-string)))
            (dolist (entry ogent-review-action-registry)
              (let ((name (symbol-name (car entry))))
                (should (string-match-p name content)))))))
    (when (get-buffer "*Ogent Bindings*")
      (kill-buffer "*Ogent Bindings*"))))

;;; Action-Get Edge Case Tests

(ert-deftest ogent-keys-action-get-returns-nil-for-missing-prop ()
  "ogent-action-get returns nil for missing property on valid action."
  (should-not (ogent-action-get 'prompt-dispatch :nonexistent-prop)))

(ert-deftest ogent-keys-action-get-visual-flag-on-ask ()
  "ogent-action-get returns visual flag for ask action."
  (should (ogent-action-get 'ask :visual)))

(ert-deftest ogent-keys-action-get-desc-content ()
  "ogent-action-get retrieves non-empty desc for all actions."
  (dolist (entry ogent-action-registry)
    (let ((name (car entry)))
      (should (> (length (ogent-action-get name :desc)) 0)))))

;;; Comprehensive Setup-All Bindings Tests

(ert-deftest ogent-keys-setup-all-bindings-includes-review ()
  "setup-all-bindings sets up both vanilla and review bindings."
  (let ((map (make-sparse-keymap))
        (ogent-vanilla-prefix "C-c .")
        (ogent-review-prefix "C-c o"))
    (cl-letf (((symbol-function 'ogent-setup-evil-bindings)
               (lambda (_) nil)))
      (ogent-setup-all-bindings map)
      ;; Vanilla bindings
      (should (eq (lookup-key map (kbd "C-c . p")) 'ogent-prompt-dispatch))
      (should (eq (lookup-key map (kbd "C-c . r")) 'ogent-request))
      ;; Review bindings
      (should (eq (lookup-key map (kbd "C-c o n")) 'ogent-completion-next))
      (should (eq (lookup-key map (kbd "C-c o p")) 'ogent-completion-prev))
      (should (eq (lookup-key map (kbd "C-c o a")) 'ogent-review-accept))
      (should (eq (lookup-key map (kbd "C-c o x")) 'ogent-completion-reject)))))

(ert-deftest ogent-keys-setup-all-bindings-all-registry-actions ()
  "setup-all-bindings binds every action from registry."
  (let ((map (make-sparse-keymap))
        (ogent-vanilla-prefix "C-c ."))
    (cl-letf (((symbol-function 'ogent-setup-evil-bindings)
               (lambda (_) nil)))
      (ogent-setup-all-bindings map)
      ;; Every action should be bound
      (dolist (entry ogent-action-registry)
        (let* ((key (plist-get (cdr entry) :key))
               (cmd (plist-get (cdr entry) :command))
               (full-key (kbd (concat "C-c . " key))))
          (should (eq (lookup-key map full-key) cmd)))))))

(provide 'ogent-keys-tests)
;;; ogent-keys-tests.el ends here
