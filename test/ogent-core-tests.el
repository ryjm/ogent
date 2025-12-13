;;; ogent-core-tests.el --- Tests for ogent-mode -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-core)
(require 'org)

(ert-deftest ogent-mode-keymap-binds-dispatch ()
  "Ensure the primary keybindings are available."
  (should (eq (lookup-key ogent-mode-map (kbd "C-c . p"))
              #'ogent-prompt-dispatch))
  (should (eq (lookup-key ogent-mode-map (kbd "C-c . r"))
              #'ogent-request)))

(ert-deftest ogent-global-mode-enables-in-all-buffers ()
  "Global mode should enable in all buffers, not just Org."
  (let ((org-buffer (get-buffer-create "*ogent-org*"))
        (text-buffer (get-buffer-create "*ogent-txt*")))
    (unwind-protect
        (progn
          (with-current-buffer org-buffer
            (org-mode)
            (ogent-mode -1))
          (with-current-buffer text-buffer
            (fundamental-mode)
            (ogent-mode -1))
          (ogent-global-mode 1)
          (with-current-buffer org-buffer
            (should ogent-mode))
          (with-current-buffer text-buffer
            (should ogent-mode)))
      (ogent-global-mode -1)
      (when (buffer-live-p org-buffer)
        (kill-buffer org-buffer))
      (when (buffer-live-p text-buffer)
        (kill-buffer text-buffer)))))

(ert-deftest ogent-mode-works-in-non-org-buffers ()
  "ogent-mode can be enabled manually in non-Org buffers."
  (let ((text-buffer (get-buffer-create "*test-python*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (python-mode)
          (ogent-mode 1)
          (should ogent-mode)
          (should (keymapp ogent-mode-map))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . p"))
                      #'ogent-prompt-dispatch)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-mode-keybindings-available-globally ()
  "C-c . keybindings work when ogent-mode is enabled in any buffer."
  (let ((js-buffer (get-buffer-create "*test.js*")))
    (unwind-protect
        (with-current-buffer js-buffer
          (fundamental-mode)
          (ogent-mode 1)
          ;; Verify all main keybindings are available
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . p"))
                      #'ogent-prompt-dispatch))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . r"))
                      #'ogent-request))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . c"))
                      #'ogent-context-preview))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . m"))
                      #'ogent-codemap-buffer))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . a"))
                      #'ogent-abort-request))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . R"))
                      #'ogent-retry-request)))
      (kill-buffer js-buffer))))

(ert-deftest ogent-global-mode-does-not-switch-buffer ()
  "Enabling ogent-global-mode should not change current buffer or window."
  (let ((test-buffer (get-buffer-create "*ogent-test-nosw*"))
        (original-buffer nil))
    (unwind-protect
        (progn
          (set-buffer test-buffer)
          (setq original-buffer (current-buffer))
          (ogent-global-mode 1)
          ;; Buffer should not change
          (should (eq (current-buffer) original-buffer)))
      (ogent-global-mode -1)
      (when (buffer-live-p test-buffer)
        (kill-buffer test-buffer)))))

;;; Validation Tests

(ert-deftest ogent-context-validate-detects-missing-handles ()
  "ogent-context-validate should identify missing handles from dependencies."
  (let ((context (list :dependencies
                       (list (list :handle "found-handle"
                                   :missing-p nil
                                   :node '(mock-node))
                             (list :handle "missing-handle"
                                   :missing-p t
                                   :node nil)
                             (list :handle "another-missing"
                                   :missing-p t
                                   :node nil)))))
    (let ((missing (ogent-context-validate context)))
      (should (equal missing '("missing-handle" "another-missing"))))))

(ert-deftest ogent-context-validate-returns-empty-when-all-resolved ()
  "ogent-context-validate should return empty list when all handles resolved."
  (let ((context (list :dependencies
                       (list (list :handle "handle1"
                                   :missing-p nil
                                   :node '(mock-node))
                             (list :handle "handle2"
                                   :missing-p nil
                                   :node '(another-mock))))))
    (should (null (ogent-context-validate context)))))

(ert-deftest ogent-context-validate-handles-empty-dependencies ()
  "ogent-context-validate should handle context with no dependencies."
  (let ((context (list :dependencies nil)))
    (should (null (ogent-context-validate context)))))

(ert-deftest ogent-context-add-validation-warnings-adds-warnings ()
  "ogent-context-add-validation-warnings should add :validation-warnings key."
  (let* ((context (list :dependencies
                        (list (list :handle "missing"
                                    :missing-p t
                                    :node nil))))
         (updated (ogent-context-add-validation-warnings context))
         (warnings (plist-get updated :validation-warnings)))
    (should warnings)
    (should (= (length warnings) 1))
    (should (string-match-p "missing" (car warnings)))))

(ert-deftest ogent-context-add-validation-warnings-handles-no-missing ()
  "ogent-context-add-validation-warnings with no missing handles."
  (let* ((context (list :dependencies
                        (list (list :handle "found"
                                    :missing-p nil
                                    :node '(node)))))
         (updated (ogent-context-add-validation-warnings context))
         (warnings (plist-get updated :validation-warnings)))
    (should (null warnings))))

(ert-deftest ogent-validate-and-prompt-with-nil-setting ()
  "ogent-validate-and-prompt should proceed when validation is nil."
  (let ((ogent-validate-before-send nil)
        (context (list :dependencies
                       (list (list :handle "missing"
                                   :missing-p t
                                   :node nil)))))
    (should (ogent-validate-and-prompt context))))

(ert-deftest ogent-validate-and-prompt-with-warn-setting ()
  "ogent-validate-and-prompt should warn and proceed."
  (let ((ogent-validate-before-send 'warn)
        (context (list :dependencies
                       (list (list :handle "missing"
                                   :missing-p t
                                   :node nil))))
        (message-log nil))
    ;; Capture message output
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-log (apply #'format fmt args)))))
      (should (ogent-validate-and-prompt context))
      (should (string-match-p "missing" message-log)))))

(ert-deftest ogent-validate-and-prompt-with-confirm-approve ()
  "ogent-validate-and-prompt should prompt and respect user approval."
  (let ((ogent-validate-before-send 'confirm)
        (context (list :dependencies
                       (list (list :handle "missing"
                                   :missing-p t
                                   :node nil)))))
    ;; Mock y-or-n-p to return t (user approves)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_prompt) t)))
      (should (ogent-validate-and-prompt context)))))

(ert-deftest ogent-validate-and-prompt-with-confirm-deny ()
  "ogent-validate-and-prompt should abort when user denies."
  (let ((ogent-validate-before-send 'confirm)
        (context (list :dependencies
                       (list (list :handle "missing"
                                   :missing-p t
                                   :node nil)))))
    ;; Mock y-or-n-p to return nil (user denies)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_prompt) nil)))
      (should-not (ogent-validate-and-prompt context)))))

(ert-deftest ogent-validate-and-prompt-proceeds-when-no-missing ()
  "ogent-validate-and-prompt should proceed when no handles missing."
  (let ((ogent-validate-before-send 'confirm)
        (context (list :dependencies
                       (list (list :handle "found"
                                   :missing-p nil
                                   :node '(node))))))
    (should (ogent-validate-and-prompt context))))

(provide 'ogent-core-tests)
;;; ogent-core-tests.el ends here
