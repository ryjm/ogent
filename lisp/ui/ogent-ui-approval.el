;;; ogent-ui-approval.el --- Full tool approval preview -*- lexical-binding: t; -*-

;;; Commentary:
;; Keep proposed effects and full arguments in a copyable reader while the
;; minibuffer holds only the decision.  Approval policy stays in its owner.

;;; Code:

(require 'org)
(require 'ogent-ui-layout)

(defun ogent-ui-approval-read (tool-name preview allow-pattern)
  "Read an approval choice for TOOL-NAME with PREVIEW and ALLOW-PATTERN.
Return a choice character.  Restore the original windows on decision or quit."
  (let ((buffer (generate-new-buffer "*ogent-tool-review*")))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer buffer
            (org-mode)
            (ogent-ui-layout-configure)
            (insert (format "#+title: Review %s\n\n" tool-name)
                    "* Decision\n"
                    "y  Allow this call     n  Deny this call\n"
                    "a  Always allow       e  Deny this tool for this session\n"
                    "v  Next page          b  Previous page     C-g  Cancel\n\n"
                    (format "Always saves this allow-list pattern: %s\n\n" allow-pattern)
                    "* Proposed effects and arguments\n" preview "\n")
            (goto-char (point-min))
            (setq-local buffer-read-only t)
            (setq-local header-line-format
                        '(:eval (ogent-ui-layout-header
                                 "Tool review" nil '(("y/n" . "allow/deny")
                                                     ("v/b" . "scroll"))))))
          (switch-to-buffer buffer)
          (let (choice)
            (while (not (memq choice '(?y ?n ?a ?e)))
              (setq choice (read-char-choice
                            "Allow tool? y yes, n no, a always, e never; v/b scroll: "
                            '(?y ?n ?a ?e ?v ?b)))
              (pcase choice
                (?v (ignore-errors (scroll-up-command)))
                (?b (ignore-errors (scroll-down-command)))))
            choice))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'ogent-ui-approval)
;;; ogent-ui-approval.el ends here
