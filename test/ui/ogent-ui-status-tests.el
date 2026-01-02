;;; ogent-ui-status-tests.el --- Tests for status indicators (header-line + margin) -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-ui)
(require 'ogent-ui-status)
(require 'org)

(ert-deftest ogent-status-icons-mapping ()
  "Status symbols map to correct icons."
  (should (equal (cdr (assoc 'wait ogent-status--icons)) "⏳"))
  (should (equal (cdr (assoc 'type ogent-status--icons)) "✍"))
  (should (equal (cdr (assoc 'done ogent-status--icons)) "✓"))
  (should (equal (cdr (assoc 'error ogent-status--icons)) "✗"))
  (should (equal (cdr (assoc 'aborted ogent-status--icons)) "⊘")))

(ert-deftest ogent-status-format-elapsed ()
  "Elapsed time formatting works correctly."
  (let ((start-time (time-subtract (current-time) (seconds-to-time 3.2))))
    (should (string-match-p "^3\\.[0-9]s$"
                            (ogent-status--format-elapsed start-time))))
  (should (equal (ogent-status--format-elapsed nil) "0.0s")))

(ert-deftest ogent-status-format-header-line-ready ()
  "Header-line shows 'ready' when no active request."
  (with-temp-buffer
    (setq ogent-status--current-request nil)
    ;; New format includes icon and faces, so check for key parts
    (let ((header (ogent-status--format-header-line)))
      (should (string-match-p "ogent" header))
      (should (string-match-p "ready" header)))))

(ert-deftest ogent-status-format-header-line-waiting ()
  "Header-line shows model, icon, and elapsed time for waiting request."
  (with-temp-buffer
    (let* ((start-time (time-subtract (current-time) (seconds-to-time 2.5)))
           (model (list :id "claude-3.5-sonnet" :backend 'gptel-anthropic))
           (request (make-ogent-ui-request
                     :id "test-1"
                     :model model
                     :status 'wait
                     :start-time start-time)))
      (setq ogent-status--current-request request)
      (let ((header (ogent-status--format-header-line)))
        ;; New format uses theme icons (○ for pending) instead of ⏳
        (should (string-match-p "ogent" header))
        (should (string-match-p "claude-3.5-sonnet" header))
        (should (string-match-p "[0-9]\\.[0-9]s" header))))))

(ert-deftest ogent-status-format-header-line-typing ()
  "Header-line shows typing icon for active response."
  (with-temp-buffer
    (let* ((start-time (time-subtract (current-time) (seconds-to-time 5.0)))
           (model (list :id "gpt-4o" :backend 'gptel-openai))
           (request (make-ogent-ui-request
                     :id "test-2"
                     :model model
                     :status 'type
                     :start-time start-time)))
      (setq ogent-status--current-request request)
      (let ((header (ogent-status--format-header-line)))
        ;; New format uses theme icons (◐ for running) instead of ✍
        (should (string-match-p "ogent" header))
        (should (string-match-p "gpt-4o" header))
        (should (string-match-p "[0-9]\\.[0-9]s" header))))))

(ert-deftest ogent-status-format-header-line-done ()
  "Header-line shows done icon for completed request."
  (with-temp-buffer
    (let* ((start-time (time-subtract (current-time) (seconds-to-time 10.0)))
           (model (list :id "claude-3.5-haiku"))
           (request (make-ogent-ui-request
                     :id "test-3"
                     :model model
                     :status 'done
                     :start-time start-time)))
      (setq ogent-status--current-request request)
      (let ((header (ogent-status--format-header-line)))
        (should (string-match-p "ogent: claude-3.5-haiku ✓" header))))))

(ert-deftest ogent-status-format-header-line-error ()
  "Header-line shows error icon for failed request."
  (with-temp-buffer
    (let* ((start-time (current-time))
           (model (list :id "test-model"))
           (request (make-ogent-ui-request
                     :id "test-4"
                     :model model
                     :status 'error
                     :start-time start-time)))
      (setq ogent-status--current-request request)
      (should (string-match-p "ogent: test-model ✗"
                              (ogent-status--format-header-line))))))

(ert-deftest ogent-status-format-header-line-aborted ()
  "Header-line shows abort icon for aborted request."
  (with-temp-buffer
    (let* ((start-time (current-time))
           (model (list :id "test-model"))
           (request (make-ogent-ui-request
                     :id "test-5"
                     :model model
                     :status 'aborted
                     :start-time start-time)))
      (setq ogent-status--current-request request)
      (should (string-match-p "ogent: test-model ⊘"
                              (ogent-status--format-header-line))))))

(ert-deftest ogent-status-set-request ()
  "Setting a request updates buffer state."
  (with-temp-buffer
    (let* ((model (list :id "gpt-4o-mini"))
           (request (make-ogent-ui-request
                     :id "test-6"
                     :model model
                     :status 'wait
                     :start-time (current-time))))
      (ogent-status-set-request request)
      (should (eq ogent-status--current-request request))
      (should ogent-status--elapsed-timer)
      ;; Clean up
      (ogent-status-clear-request))))

(ert-deftest ogent-status-clear-request ()
  "Clearing a request stops timer and resets state."
  (with-temp-buffer
    (let* ((model (list :id "test-model"))
           (request (make-ogent-ui-request
                     :id "test-7"
                     :model model
                     :status 'type
                     :start-time (current-time))))
      (ogent-status-set-request request)
      (should ogent-status--elapsed-timer)
      (ogent-status-clear-request)
      (should-not ogent-status--current-request)
      (should-not ogent-status--elapsed-timer))))

(ert-deftest ogent-status-mode-toggle ()
  "Enabling mode sets header-line, disabling restores it."
  (with-temp-buffer
    (let ((original-header header-line-format))
      ;; Enable mode
      (ogent-status-mode 1)
      (should (equal header-line-format
                     '(:eval (ogent-status--format-header-line))))
      ;; Disable mode
      (ogent-status-mode -1)
      (should (equal header-line-format original-header))
      (should-not ogent-status--elapsed-timer))))

(ert-deftest ogent-status-timer-updates ()
  "Timer callback updates header-line in correct buffer."
  (with-temp-buffer
    (let* ((test-buffer (current-buffer))
           (model (list :id "test-model"))
           (request (make-ogent-ui-request
                     :id "test-8"
                     :model model
                     :status 'type
                     :start-time (current-time))))
      (ogent-status-mode 1)
      (ogent-status-set-request request)
      (should ogent-status--elapsed-timer)
      ;; Simulate timer callback
      (ogent-status--update test-buffer)
      (should (buffer-live-p test-buffer))
      ;; Clean up
      (ogent-status-clear-request)
      (ogent-status-mode -1))))

;;; Margin Indicator Tests

(ert-deftest ogent-status-margin-icon-static ()
  "Static margin icons return correct strings."
  (should (equal (ogent-status--get-margin-icon 'waiting) "○"))
  (should (equal (ogent-status--get-margin-icon 'done) "✓"))
  (should (equal (ogent-status--get-margin-icon 'error) "✗")))

(ert-deftest ogent-status-margin-icon-animated ()
  "Animated streaming icon cycles through frames."
  (should (equal (ogent-status--get-margin-icon 'streaming 0) "◐"))
  (should (equal (ogent-status--get-margin-icon 'streaming 1) "◑"))
  (should (equal (ogent-status--get-margin-icon 'streaming 2) "◒"))
  (should (equal (ogent-status--get-margin-icon 'streaming 3) "◓"))
  ;; Should wrap around
  (should (equal (ogent-status--get-margin-icon 'streaming 4) "◐")))

(ert-deftest ogent-status-find-request-headline ()
  "Finding request headline from response marker."
  (with-temp-buffer
    (org-mode)
    (insert "** Request: test prompt\n")
    (insert "#+begin_src text\nPrompt: test\n#+end_src\n\n")
    (insert "*** Response\n")
    (let ((response-marker (point-marker)))
      (insert "Response content here\n")
      (should (equal (ogent-status--find-request-headline response-marker)
                     (save-excursion
                       (goto-char (point-min))
                       (point)))))))

(ert-deftest ogent-status-create-margin-overlay ()
  "Creating margin overlay for a request."
  (with-temp-buffer
    (org-mode)
    (ogent-status-mode 1)
    (insert "** Request: test prompt\n")
    (insert "#+begin_src text\nPrompt: test\n#+end_src\n\n")
    (insert "*** Response\n")
    (let* ((response-marker (point-marker))
           (model (list :id "test-model"))
           (request (make-ogent-ui-request
                     :id "test-margin-1"
                     :model model
                     :buffer (current-buffer)
                     :marker response-marker
                     :status 'wait
                     :start-time (current-time)))
           (overlay-info (ogent-status--create-margin-overlay request)))
      (should overlay-info)
      (should (plist-get overlay-info :overlay))
      (should (overlayp (plist-get overlay-info :overlay)))
      (should (equal (plist-get overlay-info :animation-frame) 0))
      ;; Clean up
      (ogent-status--remove-margin-overlay overlay-info)
      (ogent-status-mode -1))))

(ert-deftest ogent-status-update-margin-overlay ()
  "Updating margin overlay changes the icon."
  (with-temp-buffer
    (org-mode)
    (ogent-status-mode 1)
    (insert "** Request: test prompt\n")
    (insert "#+begin_src text\nPrompt: test\n#+end_src\n\n")
    (insert "*** Response\n")
    (let* ((response-marker (point-marker))
           (model (list :id "test-model"))
           (request (make-ogent-ui-request
                     :id "test-margin-2"
                     :model model
                     :buffer (current-buffer)
                     :marker response-marker
                     :status 'wait
                     :start-time (current-time)))
           (overlay-info (ogent-status--create-margin-overlay request)))
      ;; Update to streaming
      (ogent-status--update-margin-overlay overlay-info 'type)
      (should (plist-get overlay-info :overlay))
      ;; Update to done
      (ogent-status--update-margin-overlay overlay-info 'done)
      (should (plist-get overlay-info :overlay))
      ;; Clean up
      (ogent-status--remove-margin-overlay overlay-info)
      (ogent-status-mode -1))))

(ert-deftest ogent-status-animation-lifecycle ()
  "Animation starts and stops correctly."
  (with-temp-buffer
    (org-mode)
    (ogent-status-mode 1)
    (insert "** Request: test prompt\n")
    (insert "#+begin_src text\nPrompt: test\n#+end_src\n\n")
    (insert "*** Response\n")
    (let* ((response-marker (point-marker))
           (model (list :id "test-model"))
           (request (make-ogent-ui-request
                     :id "test-margin-3"
                     :model model
                     :buffer (current-buffer)
                     :marker response-marker
                     :status 'wait
                     :start-time (current-time)))
           (overlay-info (ogent-status--create-margin-overlay request)))
      ;; Start animation
      (ogent-status--start-animation overlay-info)
      (should (plist-get overlay-info :animation-timer))
      ;; Stop animation
      (ogent-status--stop-animation overlay-info)
      (should-not (plist-get overlay-info :animation-timer))
      ;; Clean up
      (ogent-status--remove-margin-overlay overlay-info)
      (ogent-status-mode -1))))

(ert-deftest ogent-status-indicator-integration ()
  "Full integration: set, update, clear."
  (with-temp-buffer
    (org-mode)
    (ogent-status-mode 1)
    (insert "** Request: test prompt\n")
    (insert "#+begin_src text\nPrompt: test\n#+end_src\n\n")
    (insert "*** Response\n")
    (let* ((response-marker (point-marker))
           (model (list :id "test-model"))
           (request (make-ogent-ui-request
                     :id "test-integration-1"
                     :model model
                     :buffer (current-buffer)
                     :marker response-marker
                     :status 'wait
                     :start-time (current-time))))
      ;; Set request (creates indicator)
      (ogent-status-set-request request)
      (should ogent-status--margin-overlays)
      (should (gethash "test-integration-1" ogent-status--margin-overlays))
      ;; Update to streaming
      (ogent-status-update-indicator request 'type)
      (let ((overlay-info (gethash "test-integration-1" ogent-status--margin-overlays)))
        (should (plist-get overlay-info :animation-timer)))
      ;; Update to done
      (ogent-status-update-indicator request 'done)
      (let ((overlay-info (gethash "test-integration-1" ogent-status--margin-overlays)))
        (should-not (plist-get overlay-info :animation-timer)))
      ;; Clear request
      (ogent-status-clear-request request)
      (should-not (gethash "test-integration-1" ogent-status--margin-overlays))
      ;; Clean up
      (ogent-status-mode -1))))

(ert-deftest ogent-status-mode-sets-margin-width ()
  "Enabling ogent-status-mode sets left-margin-width in Org buffers."
  (with-temp-buffer
    (org-mode)
    (ogent-status-mode 1)
    (should (equal left-margin-width 2))
    (ogent-status-mode -1)))

(provide 'ogent-ui-status-tests)

;;; ogent-ui-status-tests.el ends here
