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

(ert-deftest ogent-global-mode-only-enables-in-org ()
  "Global mode should only toggle in Org buffers."
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
            (should-not ogent-mode)))
      (ogent-global-mode -1)
      (when (buffer-live-p org-buffer)
        (kill-buffer org-buffer))
      (when (buffer-live-p text-buffer)
        (kill-buffer text-buffer)))))

(provide 'ogent-core-tests)
;;; ogent-core-tests.el ends here
