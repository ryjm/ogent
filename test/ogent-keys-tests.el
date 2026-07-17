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

(ert-deftest ogent-keys-action-get-run-subtree ()
  "Run subtree action uses RET and is visual."
  (should (string= (ogent-action-get 'run-subtree :key) "RET"))
  (should (eq (ogent-action-get 'run-subtree :command) 'ogent-run-subtree))
  (should (string= (ogent-action-get 'run-subtree :desc) "Run subtree"))
  (should (ogent-action-get 'run-subtree :visual)))

(ert-deftest ogent-keys-action-get-zen-copy-response ()
  "Zen copy response action uses the normal ogent prefix map."
  (should (string= (ogent-action-get 'zen-copy-response :key) "w"))
  (should (eq (ogent-action-get 'zen-copy-response :command)
              'ogent-zen-copy-response))
  (should (string= (ogent-action-get 'zen-copy-response :desc)
                   "Copy Zen response")))

(ert-deftest ogent-keys-action-get-zen-dispatch ()
  "Zen dispatch replaces the old review-menu action on the global prefix map."
  (should-not (ogent-action-get 'zen-review-menu :key))
  (should (string= (ogent-action-get 'zen-dispatch :key) "u"))
  (should (eq (ogent-action-get 'zen-dispatch :command)
              'ogent-zen-dispatch))
  (should (string= (ogent-action-get 'zen-dispatch :desc)
                   "Zen menu")))

(ert-deftest ogent-keys-action-get-malleable-bindings ()
  "Malleable Zen actions have direct prefix bindings."
  (should (string= (ogent-action-get 'ask-region :key) "C-r"))
  (should (eq (ogent-action-get 'ask-region :command)
              'ogent-zen-run-region))
  (should (ogent-action-get 'ask-region :visual))
  (should (string= (ogent-action-get 'zen-edit-dwim :key) "C-e"))
  (should (eq (ogent-action-get 'zen-edit-dwim :command)
              'ogent-zen-edit-dwim))
  (should (ogent-action-get 'zen-edit-dwim :visual))
  (should (string= (ogent-action-get 'zen-apply-edit :key) "C-a"))
  (should (eq (ogent-action-get 'zen-apply-edit :command)
              'ogent-zen-apply-last-edit)))

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
    ;; Check that run-subtree is bound
    (should (eq (lookup-key test-map (kbd "C-c . RET")) 'ogent-run-subtree))
    ;; Check that request is bound
    (should (eq (lookup-key test-map (kbd "C-c . r")) 'ogent-request))
    ;; Check malleable Zen bindings
    (should (eq (lookup-key test-map (kbd "C-c . C-r")) 'ogent-zen-run-region))
    (should (eq (lookup-key test-map (kbd "C-c . C-e")) 'ogent-zen-edit-dwim))
    (should (eq (lookup-key test-map (kbd "C-c . C-a")) 'ogent-zen-apply-last-edit))))

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
  (should (get-buffer "*ogent-bindings*"))
  (with-current-buffer "*ogent-bindings*"
    (should (string-match-p "Ogent Keybindings" (buffer-string)))
    (should (string-match-p "Vanilla prefix" (buffer-string)))
    (should (string-match-p "prompt-dispatch" (buffer-string)))
    (should (string-match-p "Run subtree" (buffer-string))))
  (kill-buffer "*ogent-bindings*"))

(ert-deftest ogent-keys-describe-bindings-shows-all-actions ()
  "ogent-describe-bindings lists all actions."
  (ogent-describe-bindings)
  (with-current-buffer "*ogent-bindings*"
    (let ((content (buffer-string)))
      (dolist (entry ogent-action-registry)
        (let ((name (symbol-name (car entry))))
          (should (string-match-p name content))))))
  (kill-buffer "*ogent-bindings*"))

(ert-deftest ogent-keys-describe-bindings-marks-visual ()
  "ogent-describe-bindings marks visual actions."
  (ogent-describe-bindings)
  (with-current-buffer "*ogent-bindings*"
    (should (string-match-p "\\[visual\\]" (buffer-string))))
  (kill-buffer "*ogent-bindings*"))

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

(ert-deftest ogent-keys-malleable-actions-present ()
  "Malleable Zen actions are present in registry."
  (should (assq 'ask-region ogent-action-registry))
  (should (assq 'zen-edit-dwim ogent-action-registry))
  (should (assq 'zen-apply-edit ogent-action-registry)))

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

(ert-deftest ogent-keys-armory-actions-present ()
  "Armory actions expose the complete Org OS entry surface."
  (dolist (action '(armory-home
                    armory-status
                    armory-agents
                    armory-agent-profile
                    armory-org-chart
                    armory-tasks
                    armory-conversations
                    armory-actions
                    armory-data
                    armory-schedule
                    armory-agenda
                    armory-git
                    armory-palette
                    armory-settings
                    armory-help
                    armory-onboard
                    armory-registry-import
                    armory-backup
                    armory-search
                    armory-apps
                    armory-create-agent
                    armory-create-job))
    (should (assq action ogent-action-registry))))

(ert-deftest ogent-keys-armory-visible-dispatch-keys-are-unique ()
  "Armory action keys in the visible dispatch registry do not collide."
  (let ((keys nil))
    (dolist (entry ogent-action-registry)
      (when (string-prefix-p "armory-" (symbol-name (car entry)))
        (push (plist-get (cdr entry) :key) keys)))
    (should (= (length keys) (length (delete-dups (copy-sequence keys)))))))

;;; Unwired-Command Registry Tests (bead ogent-jk5.1)

(ert-deftest ogent-keys-jk5-unwired-commands-present ()
  "Registry rows exist for the previously unwired interactive commands.
Each row binds the agreed chord and carries a non-empty description."
  (dolist (spec '((armory-ql-search ogent-armory-ql-search "C-s")
                  (armory-ql-view ogent-armory-ql-view "C-v")
                  (armory-agenda-control-plane
                   ogent-armory-agenda-control-plane "C-p")
                  (export-conversation ogent-export-conversation "C-x")
                  (onboard ogent-onboard "C-o")))
    (let* ((entry (assq (nth 0 spec) ogent-action-registry))
           (props (cdr entry)))
      (should entry)
      (should (eq (plist-get props :command) (nth 1 spec)))
      (should (equal (plist-get props :key) (nth 2 spec)))
      (should (stringp (plist-get props :desc)))
      (should (> (length (plist-get props :desc)) 0)))))

(ert-deftest ogent-keys-action-get-fanout-compare ()
  "The last reserved chord C-d is bound to compare mode (ogent-pje.4).
This row consumed the final reservation from the ogent-jk5.1 comment,
so the `ogent-keys-reserved-chords-stay-free' guard retired with it."
  (should (string= (ogent-action-get 'fanout-compare :key) "C-d"))
  (should (eq (ogent-action-get 'fanout-compare :command)
              'ogent-fanout-compare))
  (should (string-match-p "C-d" (ogent-action-get 'fanout-compare :desc))))

(ert-deftest ogent-keys-action-get-analytics-rate ()
  "The reserved * chord is bound to the 1-5 rating command (ogent-z0k.1)."
  (should (string= (ogent-action-get 'analytics-rate :key) "*"))
  (should (eq (ogent-action-get 'analytics-rate :command)
              'ogent-analytics-rate-response))
  (should (stringp (ogent-action-get 'analytics-rate :desc))))

;;; Review Bindings Tests

(ert-deftest ogent-keys-review-bindings-setup ()
  "Test that review bindings are set up correctly."
  (let ((map (make-sparse-keymap)))
    (ogent-setup-review-bindings map)
    ;; Check that review keys are bound under review prefix
    (should (eq (lookup-key map (kbd (concat ogent-review-prefix " n")))
                'ogent-review-next))
    (should (eq (lookup-key map (kbd (concat ogent-review-prefix " p")))
                'ogent-review-previous))
    (should (eq (lookup-key map (kbd (concat ogent-review-prefix " a")))
                'ogent-review-accept))
    (should (eq (lookup-key map (kbd (concat ogent-review-prefix " x")))
                'ogent-review-reject))
    (should (eq (lookup-key map (kbd (concat ogent-review-prefix " d")))
                'ogent-review-dashboard))))

(ert-deftest ogent-keys-review-registry-has-entries ()
  "Test that review action registry has expected entries."
  (should (assq 'review-next ogent-review-action-registry))
  (should (assq 'review-prev ogent-review-action-registry))
  (should (assq 'review-accept ogent-review-action-registry))
  (should (assq 'review-reject ogent-review-action-registry))
  (should (assq 'review-dashboard ogent-review-action-registry))
  (should (assq 'review-describe ogent-review-action-registry)))

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
                'ogent-request-edit))
    (should (eq (lookup-key leader-map (kbd "o C-r"))
                'ogent-zen-run-region))
    (should (eq (lookup-key leader-map (kbd "o C-e"))
                'ogent-zen-edit-dwim))
    (should (eq (lookup-key leader-map (kbd "o C-a"))
                'ogent-zen-apply-last-edit))))

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
                  'ogent-review-next)))))

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
        (let ((buf (get-buffer "*ogent-bindings*")))
          (should buf)
          (with-current-buffer buf
            (should (string-match-p "Ogent Keybindings" (buffer-string)))
            (should (string-match-p "prompt-dispatch" (buffer-string)))
            (should (string-match-p "Review Keybindings" (buffer-string))))))
    (when (get-buffer "*ogent-bindings*")
      (kill-buffer "*ogent-bindings*"))))

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
                'ogent-review-next))
    (should (eq (lookup-key map (kbd "C-c r p"))
                'ogent-review-previous))
    ;; Default prefix should not be bound
    (should-not (eq (lookup-key map (kbd "C-c , n")) 'ogent-review-next))))

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
        (with-current-buffer "*ogent-bindings*"
          (should (string-match-p "Review prefix" (buffer-string)))
          (should (string-match-p "C-c ," (buffer-string)))))
    (when (get-buffer "*ogent-bindings*")
      (kill-buffer "*ogent-bindings*"))))

(ert-deftest ogent-keys-describe-bindings-shows-review-actions ()
  "ogent-describe-bindings lists all review actions."
  (unwind-protect
      (progn
        (ogent-describe-bindings)
        (with-current-buffer "*ogent-bindings*"
          (let ((content (buffer-string)))
            (dolist (entry ogent-review-action-registry)
              (let ((name (symbol-name (car entry))))
                (should (string-match-p name content)))))))
    (when (get-buffer "*ogent-bindings*")
      (kill-buffer "*ogent-bindings*"))))

;;; Action-Get Edge Case Tests

(ert-deftest ogent-keys-action-get-returns-nil-for-missing-prop ()
  "ogent-action-get returns nil for missing property on valid action."
  (should-not (ogent-action-get 'prompt-dispatch :nonexistent-prop)))

(ert-deftest ogent-keys-action-get-visual-flag-on-ask-here ()
  "ogent-action-get returns visual flag for inline ask action."
  (should (ogent-action-get 'ask-here :visual)))

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
        (ogent-review-prefix "C-c ,"))
    (cl-letf (((symbol-function 'ogent-setup-evil-bindings)
               (lambda (_) nil)))
      (ogent-setup-all-bindings map)
      ;; Vanilla bindings
      (should (eq (lookup-key map (kbd "C-c . p")) 'ogent-prompt-dispatch))
      (should (eq (lookup-key map (kbd "C-c . r")) 'ogent-request))
      ;; Review bindings
      (should (eq (lookup-key map (kbd "C-c , n")) 'ogent-review-next))
      (should (eq (lookup-key map (kbd "C-c , p")) 'ogent-review-previous))
      (should (eq (lookup-key map (kbd "C-c , a")) 'ogent-review-accept))
      (should (eq (lookup-key map (kbd "C-c , x")) 'ogent-review-reject)))))

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

;;; Autoload Completeness Regression (bead ogent-jk5.4)
;;
;; The load-bearing guard: every `;;;###autoload'-ed interactive command
;; under lisp/ must be reachable through one of five destinations:
;;   1. `ogent-action-registry'
;;   2. `ogent-review-action-registry'
;;   3. a Transient menu suffix (static walk of `transient-define-prefix'
;;      and `ogent-armory-ui--define-prefix' forms, including the jump
;;      group the Armory macro splices into every expansion)
;;   4. the C-c C-e export dispatcher (:menu-entry in lisp/ox-ogent.el)
;;   5. the documented exemption list below, each entry carrying a reason
;; Anything else is a command we shipped and forgot to wire.

(defconst ogent-keys-tests--completeness-exemptions
  '(;; inline-diff.el
    (inline-diff-clear
     . "Programmatic cleanup used by the edit display pipeline; M-x escape hatch for stray overlays")
    (inline-diff-mode
     . "Minor-mode toggle; enabled programmatically by the Zen inline-edit pipeline")
    ;; ogent-analytics.el
    (ogent-analytics-export-csv
     . "Bound to `e' in the analytics dashboard keymap; dashboard is registry `A'")
    (ogent-analytics-export-org
     . "Bound to `o' in the analytics dashboard keymap; dashboard is registry `A'")
    ;; ogent-anthropic-oauth.el
    (ogent-anthropic-login
     . "Invoked by the onboarding wizard (registry C-o); documented M-x login (docs/gptel-integration.org)")
    (ogent-anthropic-logout
     . "Documented M-x auth maintenance (specs/gptel-integration.org)")
    (ogent-anthropic-status
     . "Documented M-x auth diagnostic (specs/gptel-integration.org)")
    (ogent-claude-code-login
     . "Invoked by the onboarding wizard provider table; documented M-x (docs/gptel-integration.org)")
    (ogent-claude-code-logout
     . "Documented M-x auth maintenance (docs/getting-started.md)")
    (ogent-claude-code-status
     . "Documented M-x auth diagnostic (docs/gptel-integration.org)")
    ;; ogent-armory-adapter.el
    (ogent-armory-providers
     . "Documented M-x provider browser (docs/armory.org, specs/armory-parity.org)")
    (ogent-armory-provider-verify
     . "Bound to `v'/`C-c v'/RET in the providers buffer keymap")
    (ogent-armory-adapter-ground
     . "Documented M-x maintenance refreshing the checked-in CLI-help ground snapshots")
    ;; ogent-armory-compose.el
    (ogent-armory-compose
     . "Backend invoked by agent compose flows (agents dispatch row); documented in docs/armory.org")
    (ogent-armory-compose-buffer
     . "Documented M-x compose entry (docs/armory.org, specs/armory-org-os.org)")
    ;; ogent-armory-data.el
    (ogent-armory-page-create
     . "Backend for the data browser buffer commands; data browser is registry `;'")
    (ogent-armory-page-rename
     . "Backend for the data browser buffer commands; data browser is registry `;'")
    (ogent-armory-page-move
     . "Backend for the data browser buffer commands; data browser is registry `;'")
    (ogent-armory-page-delete
     . "Backend for the data browser buffer commands; data browser is registry `;'")
    (ogent-armory-page-export
     . "Backend for the data browser buffer commands; data browser is registry `;'")
    (ogent-armory-open-file
     . "Backend called by the data browser, palette, and apps open commands")
    ;; ogent-armory-git.el
    (ogent-armory-git-log-page
     . "Backend for the git-status buffer's log-at-point command; git status is registry `:'")
    (ogent-armory-git-diff-page
     . "Backend for the git-status buffer's diff-at-point command; git status is registry `:'")
    (ogent-armory-git-restore-page
     . "Backend for the git-status buffer's restore-at-point command; git status is registry `:'")
    (ogent-armory-git-commit
     . "Backend for the git-status buffer's commit-from-status command; git status is registry `:'")
    (ogent-armory-git-pull
     . "UNWIRED (jk5.4 audit): named in specs/armory-parity.org but no chord, transient row, or buffer key reaches it")
    ;; ogent-armory-runner.el
    (ogent-armory-run-agent
     . "Backend run entry invoked from status/agent/agents/conversations dispatch rows")
    (ogent-armory-run-job
     . "Backend run entry invoked from schedule and status/agent dispatch rows")
    ;; ogent-armory-schedule.el
    (ogent-armory-scheduler-mode
     . "Minor-mode toggle arming the scheduler tick; enabled from config")
    ;; ogent-armory-settings.el
    (ogent-armory-settings-export
     . "Invoked from the settings buffer flow; settings is registry `,'")
    (ogent-armory-settings-import
     . "Invoked from the settings buffer flow; settings is registry `,'")
    (ogent-armory-registry-import-into
     . "Palette action target (:command row in ogent-armory-palette.el); palette is registry `/'")
    (ogent-armory-demo
     . "Bound to `d'/`C-c d' in the settings buffer keymap and advertised in its help text")
    ;; ogent-armory-skills.el
    (ogent-armory-skills
     . "Documented M-x skills browser (docs/how-it-works.org, docs/armory.org)")
    ;; ogent-armory-status.el
    (ogent-armory-status-dispatch
     . "Transient prefix itself; bound to `?' in the Armory status buffer keymap")
    ;; ogent-armory.el
    (ogent-armory-scaffold
     . "Backend called by settings/onboard scaffolding flows")
    ;; ogent-codemap-task.el / ogent-codemap.el
    (ogent-codemap-regenerate
     . "M-x maintenance escape hatch: force task-codemap cache rebuild (registry `M' generates)")
    (ogent-codemap-refresh
     . "Idle-timer callback for codemap refresh-on-save; also M-x refresh")
    (ogent-codemap-refresh-full
     . "M-x maintenance escape hatch: full re-render bypassing incremental refresh")
    (ogent-codemap-changes
     . "M-x maintenance view of changed-file codemap deltas")
    ;; ogent-codex-oauth.el
    (ogent-codex-login
     . "Invoked by the onboarding wizard provider table; documented M-x (README.org)")
    (ogent-codex-login-device
     . "Documented M-x device-code login for headless setups (docs/getting-started.md, README.org)")
    (ogent-codex-status
     . "Documented M-x auth diagnostic (README.org, docs/gptel-integration.org)")
    (ogent-codex-logout
     . "Documented M-x auth maintenance (README.org, docs/how-it-works.org)")
    ;; ogent-companion.el
    (ogent-companion-display
     . "Documented M-x companion viewer (docs/doom-emacs.md)")
    (ogent-companion-enable-persistence
     . "Invoked by the `ogent-mode' activation path; M-x opt-in")
    (ogent-companion-save-link
     . "Companion link maintenance, M-x-only by design (persistence plumbing)")
    (ogent-companion-rebind
     . "Companion link maintenance, M-x-only by design (persistence plumbing)")
    (ogent-companion-unlink
     . "Companion link maintenance, M-x-only by design (persistence plumbing)")
    ;; ogent-context.el
    (ogent-pin-file
     . "Subsumed by `ogent-pin-dwim' (registry `P'), which dispatches to it")
    (ogent-pin-buffer
     . "Subsumed by `ogent-pin-dwim' (registry `P'), which dispatches to it")
    (ogent-pin-region
     . "Subsumed by `ogent-pin-dwim' (registry `P'), which dispatches to it")
    (ogent-unpin-all
     . "Bulk variant of `ogent-unpin-interactive' (registry `U'); M-x-only by design")
    ;; ogent-core.el
    (ogent-mode
     . "Minor-mode toggle: the ogent entry mode itself")
    (ogent-global-mode
     . "Globalized minor-mode toggle")
    (ogent-session-prompt-from-question
     . "Programmatic step in the core question flow (ogent-core.el call site)")
    ;; ogent-debug.el
    (ogent-debug-enable
     . "Programmatic half of `ogent-debug-mode' (registry `D')")
    (ogent-debug-disable
     . "Programmatic half of `ogent-debug-mode' (registry `D')")
    (ogent-debug-toggle
     . "Subsumed by `ogent-debug-mode' (registry `D')")
    (ogent-debug-show
     . "Bound to `C-c d s' in the debug minor-mode keymap")
    (ogent-debug-clear
     . "Bound to `C-c d c' in the debug minor-mode keymap")
    ;; ogent-doctor.el
    (ogent-doctor
     . "Documented M-x diagnostic (README.org)")
    ;; ogent-edit-display.el
    (ogent-edit-toggle-display-method
     . "Bound to `t' in the edit overlay and diff-preview keymaps")
    ;; ogent-issues-bd.el / ogent-issues-transient.el
    (ogent-issues-agenda
     . "Documented M-x org-agenda bridge (docs/how-it-works.org)")
    (ogent-issues-dispatch
     . "Transient prefix itself; bound to `?'/`h' in the issues buffer keymap")
    ;; ogent-keys.el
    (ogent-setup-doom-bindings
     . "Setup fn (ogent-setup-*) run at load/init time, never a chord target")
    ;; ogent-mcp.el
    (ogent-mcp-connect
     . "Invoked by the doctor and MCP auto-connect flows; M-x per-server connect")
    (ogent-mcp-disconnect
     . "Invoked by the doctor and MCP teardown flows; M-x per-server disconnect")
    (ogent-mcp-list-connections
     . "Documented M-x MCP diagnostic (docs/how-it-works.org)")
    (ogent-mcp-connect-all
     . "Run from the MCP auto-connect init timer; M-x bulk connect")
    ;; ogent-notes.el
    (ogent-notes-enable-tracking
     . "Invoked by the `ogent-mode' activation path; M-x opt-in")
    (ogent-notes-disable-tracking
     . "M-x opt-out pair of `ogent-notes-enable-tracking'")
    ;; ogent-onboard.el
    (ogent-onboard-login-different-provider
     . "Invoked by the provider-fallback flow (ogent-provider-fallback.el)")
    (ogent-onboard-add-provider
     . "UNWIRED (jk5.4 audit): post-setup provider add; nothing references it - not the wizard, a chord, or any doc")
    (ogent-recompile
     . "Dev utility, documented M-x (docs/getting-started.md, docs/doom-emacs.md)")
    (ogent-reload
     . "Dev utility, documented M-x (docs/getting-started.md)")
    ;; ogent-presets.el
    (ogent-presets-configure
     . "Documented M-x preset management (docs/how-it-works.org)")
    (ogent-presets-show
     . "Documented M-x preset inspection (docs/how-it-works.org)")
    (ogent-presets-mode
     . "Minor-mode toggle; enabled from config")
    ;; ogent-prompts-yasnippet.el
    (ogent-prompts-yasnippet-mode
     . "Minor-mode toggle; enabled from config")
    ;; ogent-session.el
    (ogent-history
     . "Documented M-x session history browser (docs/how-it-works.org)")
    (ogent-history-search
     . "Bound to `s'/`/' in the history buffer keymap")
    (ogent-session-search
     . "Documented M-x session search (docs/how-it-works.org)")
    (ogent-session-create-roam-note
     . "Org-roam integration, M-x-only (requires org-roam; specs/armory-parity.org)")
    ;; ogent-zen.el / ogent-zen-edit.el
    (ogent-zen-accept-edit
     . "Documented M-x wrapper (docs/getting-started.md, README.org); `C-c C-c' in `inline-diff-mode-map' is the chord path")
    (ogent-zen-reject-edit
     . "Documented M-x wrapper (docs/getting-started.md, README.org); `C-c C-k' in `inline-diff-mode-map' is the chord path")
    (ogent-zen-mode
     . "Minor-mode toggle; enabled by `ogent-mode' when Zen is active")
    (global-ogent-zen-mode
     . "Globalized minor-mode toggle")
    (ogent-zen-set-review
     . "UNWIRED (jk5.4 audit): interactive review-state setter with zero references; the review menu uses internal --review-menu-mark commands instead")
    (ogent-zen-review-menu
     . "Transient prefix itself; bound to `u' on Zen heading overlays (`ogent-zen--heading-overlay-map')")
    (ogent-zen-accept-response
     . "Backend invoked by `ogent-review-accept' / `ogent-completion-accept' (registry `z', review `a')")
    (ogent-zen-reject-response
     . "Backend invoked by the completion/review reject path")
    (ogent-zen-mark-superseded
     . "UNWIRED (jk5.4 audit): review state absent from zen-dispatch, review menu, and dashboard dispatch rows")
    (ogent-zen-mark-failed
     . "UNWIRED (jk5.4 audit): review state absent from zen-dispatch, review menu, and dashboard dispatch rows")
    (ogent-review-dashboard-dispatch
     . "Transient prefix itself; bound to `?' in the review dashboard keymap")
    (ogent-zen-edit-region
     . "Explicit-scope variant of `ogent-zen-edit-dwim' (registry C-e); M-x-only by design")
    (ogent-zen-rewrite-paragraph
     . "Explicit-scope variant of `ogent-zen-edit-dwim' (registry C-e); M-x-only by design")
    (ogent-zen-rewrite-sentence
     . "Explicit-scope variant of `ogent-zen-edit-dwim' (registry C-e); M-x-only by design")
    ;; lisp/ui/ogent-ui-armory*.el
    (ogent-armory-home-dispatch
     . "Transient prefix itself; bound to `?' in the Armory Home buffer keymap")
    (ogent-armory-clone-agent
     . "UNWIRED (jk5.4 audit): spec'd in specs/armory-org-os.org but no dispatch row or chord reaches it")
    (ogent-armory-archive-agent
     . "UNWIRED (jk5.4 audit): spec'd in specs/armory-org-os.org but no dispatch row or chord reaches it")
    (ogent-armory-conversation
     . "Backend detail view opened from the conversations list, home, and status surfaces")
    (ogent-armory-open-app
     . "UNWIRED (jk5.4 audit): zero references; the apps dispatch row uses `ogent-armory-apps-open' instead")
    ;; lisp/ui/ogent-ui-*.el
    (ogent-backlinks-at-point
     . "UNWIRED (jk5.4 audit): zero references; possibly subsumed by `ogent-show-backlinks' (registry `b')")
    (ogent-context-manage
     . "Documented M-x context manager (docs/how-it-works.org)")
    (ogent-fanout-keep
     . "UNWIRED (jk5.4 audit): fan-out winner-keeper; C-f/C-k/C-d are wired but keep has no chord or compare-buffer key")
    (ogent-status-mode
     . "Minor-mode toggle; enabled programmatically by status surfaces")
    (ogent-show-errors
     . "Documented M-x error log viewer (docs/how-it-works.org, specs/gptel-integration.org)")
    (ogent-clear-errors
     . "M-x pair of `ogent-show-errors' (specs/gptel-integration.org)")
    (ogent-pause-request
     . "M-x flow control; the pause message hints the resume command")
    (ogent-resume-request
     . "M-x flow control; advertised by the pause message hint (ogent-ui-engine.el)"))
  "Autoloaded interactive commands exempt from the wiring requirement.
Each entry is (COMMAND . REASON).  Entries whose reason starts with
\"UNWIRED\" are known gaps recorded by the ogent-jk5.4 audit: they keep
the suite green while staying loudly documented until a wiring bead
lands.  Every other reason names the concrete path (mode toggle, buffer
keymap, programmatic caller, or doc) that makes a chord unnecessary.")

(defconst ogent-keys-tests--expected-transient-prefixes
  '(ogent-debug-tools-menu
    ogent-edit-menu
    ogent-issues-dispatch
    ogent-zen-review-menu
    ogent-zen-dispatch
    ogent-review-dashboard-dispatch
    ogent-armory-status-dispatch
    ogent-armory-home-dispatch
    ogent-ask-menu
    ogent-prompt-dispatch
    ogent-navigate
    ogent-model-picker)
  "Transient prefixes the static source walk must discover.
Guards the walker itself: if parsing breaks, these disappear and the
completeness test would silently stop seeing transient-reachable
commands.")

(defun ogent-keys-tests--lisp-files ()
  "Return every .el source under lisp/, sorted for determinism."
  (sort (directory-files-recursively
         (expand-file-name "lisp" ogent-project-root) "\\.el\\'")
        #'string<))

(defun ogent-keys-tests--defun-interactive-p (form)
  "Return non-nil when defun-style FORM has a top-level interactive spec."
  (let ((body (nthcdr 3 form))
        found)
    (while (and body (not found))
      (let ((element (pop body)))
        (when (and (consp element) (eq (car element) 'interactive))
          (setq found t))))
    found))

(defun ogent-keys-tests--autoload-commands ()
  "Return an alist of (COMMAND . FILE) for autoloaded interactive commands.
Scans every lisp/ source for `;;;###autoload' cookies.  A bare cookie
claims the next form: defun-style forms count when they declare
\(interactive ...), mode and Transient definitions are interactive by
construction.  A cookie carrying an explicit (autoload NAME FILE DOC
INTERACTIVE) form counts when INTERACTIVE is non-nil."
  (let (commands)
    (dolist (file (ogent-keys-tests--lisp-files))
      (let ((base (file-name-nondirectory file)))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (re-search-forward "^;;;###autoload\\(.*\\)$" nil t)
            (let ((inline (string-trim (match-string 1))))
              (if (> (length inline) 0)
                  (let ((form (ignore-errors (car (read-from-string inline)))))
                    (when (and (consp form)
                               (eq (car form) 'autoload)
                               (nth 4 form))
                      (let ((name (cadr (nth 1 form))))
                        (unless (assq name commands)
                          (push (cons name base) commands)))))
                (let ((form (ignore-errors (read (current-buffer)))))
                  (when (and (consp form)
                             (symbolp (nth 1 form))
                             (or (memq (car form)
                                       '(define-minor-mode
                                          define-globalized-minor-mode
                                          transient-define-prefix
                                          ogent-armory-ui--define-prefix))
                                 (and (memq (car form) '(defun cl-defun))
                                      (ogent-keys-tests--defun-interactive-p
                                       form))))
                    (let ((name (nth 1 form)))
                      (unless (assq name commands)
                        (push (cons name base) commands)))))))))))
    (nreverse commands)))

(defun ogent-keys-tests--transient-suffix-commands (spec)
  "Return the command symbols named by Transient suffix SPEC.
Skips strings and keyword arguments; a keyword consumes its value,
except `:command' whose symbol value is collected."
  (let (acc)
    (while spec
      (let ((element (pop spec)))
        (cond
         ((keywordp element)
          (let ((value (pop spec)))
            (when (and (eq element :command) value (symbolp value))
              (push value acc))))
         ((and element (symbolp element) (not (eq element t)))
          (push element acc)))))
    acc))

(defun ogent-keys-tests--transient-group-commands (group)
  "Return the command symbols reachable in Transient GROUP vector."
  (let ((elements (append group nil))
        acc)
    (while elements
      (let ((element (pop elements)))
        (cond
         ((keywordp element) (pop elements))
         ((stringp element) nil)
         ((vectorp element)
          (setq acc (nconc (ogent-keys-tests--transient-group-commands
                            element)
                           acc)))
         ((consp element)
          (setq acc (nconc (ogent-keys-tests--transient-suffix-commands
                            element)
                           acc))))))
    acc))

(defun ogent-keys-tests--deep-vector-commands (tree)
  "Collect Transient group commands from every vector inside TREE.
Used on the `ogent-armory-ui--define-prefix' macro definition, whose
template splices a literal jump group into every expansion."
  (cond
   ((vectorp tree) (ogent-keys-tests--transient-group-commands tree))
   ((consp tree)
    (nconc (ogent-keys-tests--deep-vector-commands (car tree))
           (ogent-keys-tests--deep-vector-commands (cdr tree))))
   (t nil)))

(defun ogent-keys-tests--transient-reachable ()
  "Walk lisp/ sources for Transient prefixes; return (COMMANDS . PREFIXES).
COMMANDS is every suffix command reachable from some prefix, PREFIXES
the prefix names discovered.  The prefix body begins after NAME +
ARGLIST + optional DOCSTRING: step `cddr' from the arglist position
when a docstring is present (`cdddr' there would swallow the docstring
and mis-read the body as suffix specs), `cdr' when absent."
  (let (commands prefixes)
    (dolist (file (ogent-keys-tests--lisp-files))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (condition-case nil
            (while t
              (let ((form (read (current-buffer))))
                (cond
                 ((and (consp form)
                       (memq (car form) '(transient-define-prefix
                                          ogent-armory-ui--define-prefix)))
                  (push (nth 1 form) prefixes)
                  (let* ((rest (nthcdr 2 form))
                         (body (if (stringp (cadr rest))
                                   (cddr rest)
                                 (cdr rest))))
                    (while body
                      (let ((element (pop body)))
                        (cond
                         ((keywordp element) (pop body))
                         ((vectorp element)
                          (setq commands
                                (nconc
                                 (ogent-keys-tests--transient-group-commands
                                  element)
                                 commands))))))))
                 ((and (consp form)
                       (eq (car form) 'defmacro)
                       (eq (nth 1 form) 'ogent-armory-ui--define-prefix))
                  (setq commands
                        (nconc (ogent-keys-tests--deep-vector-commands form)
                               commands))))))
          (end-of-file nil))))
    (cons (delete-dups commands) (nreverse prefixes))))

(defun ogent-keys-tests--export-dispatcher-commands ()
  "Return commands reachable from the C-c C-e export dispatcher.
Reads the `:menu-entry' of every `org-export-define-derived-backend'
form in lisp/ox-ogent.el."
  (let (commands)
    (with-temp-buffer
      (insert-file-contents
       (expand-file-name "lisp/ox-ogent.el" ogent-project-root))
      (goto-char (point-min))
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (and (consp form)
                         (eq (car form) 'org-export-define-derived-backend))
                (let ((menu (plist-get (nthcdr 3 form) :menu-entry)))
                  (when (eq (car-safe menu) 'quote)
                    (setq menu (cadr menu)))
                  (dolist (entry (nth 2 menu))
                    (let ((command (nth 2 entry)))
                      (when (and command (symbolp command))
                        (push command commands))))))))
        (end-of-file nil)))
    commands))

(defun ogent-keys-tests--registry-commands (registry)
  "Return the :command symbols of every entry in REGISTRY."
  (mapcar (lambda (entry) (plist-get (cdr entry) :command)) registry))

(ert-deftest ogent-keys-autoload-completeness ()
  "Every autoloaded interactive command is wired or documented exempt.
The failure message names each unwired command and the five accepted
destinations."
  (let ((registry (ogent-keys-tests--registry-commands
                   ogent-action-registry))
        (review (ogent-keys-tests--registry-commands
                 ogent-review-action-registry))
        (transient (car (ogent-keys-tests--transient-reachable)))
        (export (ogent-keys-tests--export-dispatcher-commands))
        unwired)
    (dolist (pair (ogent-keys-tests--autoload-commands))
      (let ((command (car pair)))
        (unless (or (memq command registry)
                    (memq command review)
                    (memq command transient)
                    (memq command export)
                    (assq command
                          ogent-keys-tests--completeness-exemptions))
          (push pair unwired))))
    (when unwired
      (ert-fail
       (format
        (concat
         "%d autoloaded interactive command(s) reachable via none of the "
         "five accepted destinations:\n%s\n"
         "Destinations: (1) `ogent-action-registry', "
         "(2) `ogent-review-action-registry', "
         "(3) a Transient menu suffix (static walk of "
         "`transient-define-prefix' / `ogent-armory-ui--define-prefix' "
         "forms under lisp/), "
         "(4) the C-c C-e export dispatcher (:menu-entry in "
         "lisp/ox-ogent.el), "
         "(5) the documented exemption list "
         "`ogent-keys-tests--completeness-exemptions'.\n"
         "Wire each command into one of the first four or add an "
         "exemption entry with a reason.")
        (length unwired)
        (mapconcat (lambda (pair)
                     (format "  %s (%s)" (car pair) (cdr pair)))
                   (nreverse unwired) "\n"))))))

(ert-deftest ogent-keys-completeness-exemptions-are-justified ()
  "Exemption entries are unique, reasoned, current, and not redundant.
Every exemption must name a command that still exists as an autoloaded
interactive command (no rot), carry a non-empty reason string, and not
duplicate coverage a wired destination already provides."
  (let ((autoloads (mapcar #'car (ogent-keys-tests--autoload-commands)))
        (registry (ogent-keys-tests--registry-commands
                   ogent-action-registry))
        (review (ogent-keys-tests--registry-commands
                 ogent-review-action-registry))
        (transient (car (ogent-keys-tests--transient-reachable)))
        (export (ogent-keys-tests--export-dispatcher-commands))
        (seen (make-hash-table :test #'eq)))
    (dolist (entry ogent-keys-tests--completeness-exemptions)
      (let ((command (car entry))
            (reason (cdr entry)))
        (should (symbolp command))
        (should (stringp reason))
        (should (> (length reason) 0))
        (when (gethash command seen)
          (ert-fail (format "Duplicate exemption entry: %s" command)))
        (puthash command t seen)
        (unless (memq command autoloads)
          (ert-fail
           (format "Stale exemption: %s is no longer an autoloaded interactive command"
                   command)))
        (when (or (memq command registry)
                  (memq command review)
                  (memq command transient)
                  (memq command export))
          (ert-fail
           (format
            "Stale exemption: %s is now reachable via a wired destination (registry/review/transient/export) - delete its exemption entry"
            command)))))))

(ert-deftest ogent-keys-completeness-walker-finds-core-prefixes ()
  "The static Transient walk discovers every expected core prefix.
Guards against silent walker breakage emptying the transient-reachable
destination."
  (let* ((walk (ogent-keys-tests--transient-reachable))
         (commands (car walk))
         (prefixes (cdr walk)))
    (dolist (prefix ogent-keys-tests--expected-transient-prefixes)
      (should (memq prefix prefixes)))
    ;; The Armory macro's spliced jump group must be harvested too:
    ;; `ogent-armory-jobs' is only reachable through it.
    (should (memq 'ogent-armory-jobs commands))
    ;; Suffix commands from a plain prefix body prove the body walk
    ;; starts after the docstring rather than swallowing it.
    (should (memq 'ogent-debug-tool-history-buffer commands))
    (should (memq 'ogent-issues-create-quick commands))))

(provide 'ogent-keys-tests)
;;; ogent-keys-tests.el ends here
