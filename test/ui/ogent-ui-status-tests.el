;;; ogent-ui-status-tests.el --- Tests for header-line status indicator -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-ui)
(require 'ogent-ui-status)

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
    (should (equal (ogent-status--format-header-line) "ogent: ready"))))

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
        (should (string-match-p "ogent: claude-3.5-sonnet ⏳" header))
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
        (should (string-match-p "ogent: gpt-4o ✍" header))
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

(provide 'ogent-ui-status-tests)

;;; ogent-ui-status-tests.el ends here
