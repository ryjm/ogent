;;; ogent-core-tests.el --- Tests for ogent-mode -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-core)
(require 'org)

(ert-deftest ogent-mode-keymap-binds-dispatch ()
  "Ensure the primary keybindings are available."
  (should (eq (lookup-key ogent-mode-map (kbd "C-c o p"))
              #'ogent-prompt-dispatch))
  (should (eq (lookup-key ogent-mode-map (kbd "C-c o r"))
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
          (should (eq (lookup-key ogent-mode-map (kbd "C-c o p"))
                     #'ogent-prompt-dispatch)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-mode-keybindings-available-globally ()
  "C-c o keybindings work when ogent-mode is enabled in any buffer."
  (let ((js-buffer (get-buffer-create "*test.js*")))
    (unwind-protect
        (with-current-buffer js-buffer
          (fundamental-mode)
          (ogent-mode 1)
          ;; Verify all main keybindings are available
          (should (eq (lookup-key ogent-mode-map (kbd "C-c o p"))
                     #'ogent-prompt-dispatch))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c o r"))
                     #'ogent-request))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c o c"))
                     #'ogent-context-preview))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c o m"))
                     #'ogent-codemap-buffer))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c o a"))
                     #'ogent-abort-request))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c o R"))
                     #'ogent-retry-request)))
      (kill-buffer js-buffer))))

(provide 'ogent-core-tests)
;;; ogent-core-tests.el ends here
