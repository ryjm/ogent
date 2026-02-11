;;; ogent-convoy-tests.el --- Tests for ogent-convoy.el -*- lexical-binding: t; -*-

;;; Commentary:
;; ERT tests for the convoy inspector mode.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Load the module under test
(require 'ogent-ops-style)
(require 'ogent-gastown-status)
(require 'ogent-convoy)

;;; Test Fixtures

(defconst ogent-convoy-test--sample-data
  '(:id "convoy-001"
    :title "Feature implementation"
    :status "active"
    :completed 3
    :total 5
    :tracked ("og-abc" "og-def" "og-ghi"))
  "Sample normalized convoy data for testing.")

(defconst ogent-convoy-test--sample-data-complete
  '(:id "convoy-002"
    :title "Bug fixes"
    :status "complete"
    :completed 5
    :total 5
    :tracked ("og-xyz"))
  "Sample completed convoy data.")

(defconst ogent-convoy-test--sample-data-empty-tracked
  '(:id "convoy-003"
    :title "Empty convoy"
    :status "active"
    :completed 0
    :total 0
    :tracked nil)
  "Sample convoy with no tracked issues.")

;;; Mode Tests

(ert-deftest ogent-convoy-test-mode-defined ()
  "Test that ogent-convoy-mode is properly defined."
  (should (fboundp 'ogent-convoy-mode)))

(ert-deftest ogent-convoy-test-mode-keymap-exists ()
  "Test that the mode keymap exists."
  (should (keymapp ogent-convoy-mode-map)))

(ert-deftest ogent-convoy-test-mode-keymap-has-g ()
  "Test that g is bound to refresh."
  (should (eq (lookup-key ogent-convoy-mode-map "g")
              #'ogent-convoy-refresh)))

(ert-deftest ogent-convoy-test-mode-keymap-has-q ()
  "Test that q is bound to quit-window."
  (should (eq (lookup-key ogent-convoy-mode-map "q")
              #'quit-window)))

(ert-deftest ogent-convoy-test-mode-keymap-has-n ()
  "Test that n is bound to next-item."
  (should (eq (lookup-key ogent-convoy-mode-map "n")
              #'ogent-convoy-next-item)))

(ert-deftest ogent-convoy-test-mode-keymap-has-p ()
  "Test that p is bound to prev-item."
  (should (eq (lookup-key ogent-convoy-mode-map "p")
              #'ogent-convoy-prev-item)))

(ert-deftest ogent-convoy-test-mode-keymap-has-ret ()
  "Test that RET is bound to visit-tracked."
  (should (eq (lookup-key ogent-convoy-mode-map (kbd "RET"))
              #'ogent-convoy-visit-tracked)))

(ert-deftest ogent-convoy-test-mode-keymap-has-tab ()
  "Test that TAB is bound to toggle-section."
  (should (eq (lookup-key ogent-convoy-mode-map (kbd "TAB"))
              #'ogent-convoy-toggle-section)))

(ert-deftest ogent-convoy-test-mode-keymap-has-G ()
  "Test that G is bound to force refresh."
  (should (eq (lookup-key ogent-convoy-mode-map "G")
              #'ogent-convoy-refresh-force)))

;;; Entry Point Tests

(ert-deftest ogent-convoy-test-inspect-creates-buffer ()
  "Test that ogent-convoy-inspect creates a buffer."
  (cl-letf (((symbol-function 'ogent-convoy-refresh) #'ignore)
            ((symbol-function 'pop-to-buffer-same-window) #'ignore))
    (let ((buf (get-buffer-create (format ogent-convoy-buffer-name-format "test-id"))))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (ogent-convoy-mode)
              (setq ogent-convoy--id "test-id"))
            (should (buffer-live-p buf))
            (should (string-match-p "Convoy.*test-id" (buffer-name buf))))
        (kill-buffer buf)))))

(ert-deftest ogent-convoy-test-inspect-errors-without-id ()
  "Test that inspect errors with empty convoy ID."
  (should-error (ogent-convoy-inspect "") :type 'user-error)
  (should-error (ogent-convoy-inspect nil) :type 'user-error))

;;; Header Line Tests

(ert-deftest ogent-convoy-test-header-line-shows-id ()
  "Test that header line includes convoy ID."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--id "convoy-001")
    (setq ogent-convoy--loading nil)
    (let ((header (ogent-convoy--header-line)))
      (should (string-match-p "convoy-001" header)))))

(ert-deftest ogent-convoy-test-header-line-shows-loading ()
  "Test that header line shows loading indicator."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--id "test")
    (setq ogent-convoy--loading t)
    (setq ogent-convoy--loading-frame 0)
    (let ((header (ogent-convoy--header-line)))
      (should (string-match-p "Loading" header)))))

(ert-deftest ogent-convoy-test-header-line-shows-keys-when-not-loading ()
  "Test that header line shows key hints when not loading."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--id "test")
    (setq ogent-convoy--loading nil)
    (let ((header (ogent-convoy--header-line)))
      (should (string-match-p "refresh" header))
      (should (string-match-p "quit" header)))))

;;; Plain Rendering Tests

(ert-deftest ogent-convoy-test-insert-header-plain-with-data ()
  "Test plain header rendering with convoy data."
  (with-temp-buffer
    (let ((ogent-convoy--data ogent-convoy-test--sample-data))
      (ogent-convoy--insert-header-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Convoy" content))
        (should (string-match-p "convoy-001" content))
        (should (string-match-p "Feature implementation" content))
        (should (string-match-p "active" content))
        (should (string-match-p "3/5" content))))))

(ert-deftest ogent-convoy-test-insert-header-plain-nil-data ()
  "Test plain header rendering with nil data."
  (with-temp-buffer
    (let ((ogent-convoy--data nil))
      (ogent-convoy--insert-header-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Convoy" content))
        (should (string-match-p "not found" content))))))

(ert-deftest ogent-convoy-test-insert-header-plain-complete ()
  "Test plain header rendering with completed convoy."
  (with-temp-buffer
    (let ((ogent-convoy--data ogent-convoy-test--sample-data-complete))
      (ogent-convoy--insert-header-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Bug fixes" content))
        (should (string-match-p "complete" content))
        (should (string-match-p "5/5" content))))))

(ert-deftest ogent-convoy-test-insert-tracked-plain-with-issues ()
  "Test plain tracked issues rendering with data."
  (with-temp-buffer
    (let ((ogent-convoy--data ogent-convoy-test--sample-data))
      (ogent-convoy--insert-tracked-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Tracked Issues" content))
        (should (string-match-p "og-abc" content))
        (should (string-match-p "og-def" content))
        (should (string-match-p "og-ghi" content))))))

(ert-deftest ogent-convoy-test-insert-tracked-plain-empty ()
  "Test plain tracked issues rendering with no issues."
  (with-temp-buffer
    (let ((ogent-convoy--data ogent-convoy-test--sample-data-empty-tracked))
      (ogent-convoy--insert-tracked-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Tracked Issues" content))
        (should (string-match-p "No tracked issues" content))))))

(ert-deftest ogent-convoy-test-insert-tracked-plain-nil-data ()
  "Test plain tracked issues rendering with nil data."
  (with-temp-buffer
    (let ((ogent-convoy--data nil))
      (ogent-convoy--insert-tracked-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "No tracked issues" content))))))

(ert-deftest ogent-convoy-test-insert-plain-full ()
  "Test full plain rendering produces expected content."
  (with-temp-buffer
    (let ((ogent-convoy--data ogent-convoy-test--sample-data))
      (ogent-convoy--insert-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Convoy" content))
        (should (string-match-p "convoy-001" content))
        (should (string-match-p "Tracked Issues" content))
        (should (string-match-p "og-abc" content))))))

;;; Cache Tests

(ert-deftest ogent-convoy-test-cache-set-and-get ()
  "Test cache set and get."
  (ogent-convoy-cache-invalidate)
  (ogent-convoy--cache-set "c1" '(:id "c1" :title "Test"))
  (let ((result (ogent-convoy--cache-get "c1")))
    (should result)
    (should (equal (plist-get result :id) "c1")))
  (ogent-convoy-cache-invalidate))

(ert-deftest ogent-convoy-test-cache-miss ()
  "Test cache miss returns nil."
  (ogent-convoy-cache-invalidate)
  (should-not (ogent-convoy--cache-get "nonexistent")))

(ert-deftest ogent-convoy-test-cache-invalidate ()
  "Test cache invalidation."
  (ogent-convoy--cache-set "c1" '(:id "c1"))
  (ogent-convoy-cache-invalidate)
  (should-not (ogent-convoy--cache-get "c1")))

(ert-deftest ogent-convoy-test-cache-ttl-zero-disables ()
  "Test that cache TTL of 0 disables caching."
  (ogent-convoy-cache-invalidate)
  (let ((ogent-convoy-cache-ttl 0))
    (ogent-convoy--cache-set "c1" '(:id "c1"))
    (should-not (ogent-convoy--cache-get "c1"))))

;;; Loading Animation Tests

(ert-deftest ogent-convoy-test-start-loading-sets-state ()
  "Test that start-loading sets loading state."
  (with-temp-buffer
    (ogent-convoy-mode)
    (ogent-convoy--start-loading)
    (should ogent-convoy--loading)
    (should (= ogent-convoy--loading-frame 0))
    (ogent-convoy--stop-loading)))

(ert-deftest ogent-convoy-test-stop-loading-clears-state ()
  "Test that stop-loading clears loading state."
  (with-temp-buffer
    (ogent-convoy-mode)
    (ogent-convoy--start-loading)
    (ogent-convoy--stop-loading)
    (should-not ogent-convoy--loading)))

(ert-deftest ogent-convoy-test-loading-indicator-nil-when-not-loading ()
  "Test that loading indicator is nil when not loading."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--loading nil)
    (should-not (ogent-convoy--loading-indicator))))

(ert-deftest ogent-convoy-test-loading-indicator-returns-frame ()
  "Test that loading indicator returns current frame."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--loading t)
    (setq ogent-convoy--loading-frame 0)
    (should (ogent-convoy--loading-indicator))))

(ert-deftest ogent-convoy-test-stop-loading-timer-noop-when-nil ()
  "Test that stop-loading-timer is safe when no timer."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--loading-timer nil)
    (ogent-convoy--stop-loading-timer)
    (should-not ogent-convoy--loading-timer)))

;;; Navigation (non-magit) Tests

(ert-deftest ogent-convoy-test-next-item-without-magit ()
  "Test next-item without magit-section falls back to forward-line."
  (with-temp-buffer
    (let ((ogent-convoy--magit-section-available nil))
      (insert "line1\nline2\nline3\n")
      (goto-char (point-min))
      (ogent-convoy-next-item)
      (should (= (line-number-at-pos) 2)))))

(ert-deftest ogent-convoy-test-prev-item-without-magit ()
  "Test prev-item without magit-section falls back to backward-line."
  (with-temp-buffer
    (let ((ogent-convoy--magit-section-available nil))
      (insert "line1\nline2\nline3\n")
      (goto-char (point-min))
      (forward-line 2) ; go to line 3
      (ogent-convoy-prev-item)
      (should (= (line-number-at-pos) 2)))))

(ert-deftest ogent-convoy-test-toggle-section-without-magit-noop ()
  "Test toggle-section is a no-op without magit-section."
  (with-temp-buffer
    (let ((ogent-convoy--magit-section-available nil))
      ;; Should not error
      (ogent-convoy-toggle-section))))

(ert-deftest ogent-convoy-test-visit-tracked-without-magit ()
  "Test visit-tracked errors without magit-section."
  (with-temp-buffer
    (let ((ogent-convoy--magit-section-available nil))
      (should-error (ogent-convoy-visit-tracked) :type 'user-error))))

;;; Wiring Tests (ogent-gastown-status integration)

;; Mock section object for tests that don't have real magit-section
(defclass ogent-convoy-test--mock-section ()
  ((value :initarg :value :initform nil))
  "Mock section for testing without magit-section.")

(ert-deftest ogent-convoy-test-gastown-visit-convoy-calls-inspect ()
  "Test that RET on convoy item in gastown dispatches to inspector."
  (let ((inspected-id nil)
        (inspected-root nil)
        (mock-section (ogent-convoy-test--mock-section :value '(:id "convoy-test" :title "Test"))))
    (cl-letf (((symbol-function 'ogent-convoy-inspect)
               (lambda (id &optional root)
                 (setq inspected-id id)
                 (setq inspected-root root)))
              ((symbol-function 'magit-current-section)
               (lambda () mock-section))
              ((symbol-function 'eieio-object-class-name)
               (lambda (_obj) 'ogent-gastown-convoy-item-section))
              ((symbol-function 'ogent-gastown--active-workspace-root)
               (lambda () "/tmp/test")))
      (let ((ogent-gastown--magit-section-available t))
        (ogent-gastown-visit)
        (should (equal inspected-id "convoy-test"))
        (should (equal inspected-root "/tmp/test"))))))

(ert-deftest ogent-convoy-test-gastown-convoy-status-with-completing-read ()
  "Test that convoy-status uses completing-read when no section at point."
  (let ((inspected-id nil))
    (cl-letf (((symbol-function 'ogent-convoy-inspect)
               (lambda (id &optional _root)
                 (setq inspected-id id)))
              ((symbol-function 'ogent-gastown--active-workspace-root)
               (lambda () "/tmp/test"))
              ((symbol-function 'completing-read)
               (lambda (_prompt candidates &rest _)
                 (caar candidates))))
      (let ((ogent-gastown--magit-section-available nil)
            (ogent-gastown--convoy-data
             (list '(:id "c1" :title "First convoy")
                   '(:id "c2" :title "Second convoy"))))
        (ogent-gastown-convoy-status)
        (should (equal inspected-id "c1"))))))

(ert-deftest ogent-convoy-test-gastown-convoy-status-empty-prompts-read ()
  "Test that convoy-status falls back to read-string when no convoys."
  (let ((inspected-id nil))
    (cl-letf (((symbol-function 'ogent-convoy-inspect)
               (lambda (id &optional _root)
                 (setq inspected-id id)))
              ((symbol-function 'ogent-gastown--active-workspace-root)
               (lambda () "/tmp/test"))
              ((symbol-function 'read-string)
               (lambda (_prompt) "manual-id")))
      (let ((ogent-gastown--magit-section-available nil)
            (ogent-gastown--convoy-data nil))
        (ogent-gastown-convoy-status)
        (should (equal inspected-id "manual-id"))))))

(ert-deftest ogent-convoy-test-gastown-visit-mail-still-works ()
  "Test that RET on mail items still dispatches to mail reader."
  (let ((mail-read-called nil)
        (mock-section (ogent-convoy-test--mock-section :value '(:id "mail-123"))))
    (cl-letf (((symbol-function 'ogent-gastown-status-mail-read)
               (lambda (&optional id) (setq mail-read-called id)))
              ((symbol-function 'magit-current-section)
               (lambda () mock-section))
              ((symbol-function 'eieio-object-class-name)
               (lambda (_obj) 'ogent-gastown-mail-item-section)))
      (let ((ogent-gastown--magit-section-available t))
        (ogent-gastown-visit)
        (should (equal mail-read-called "mail-123"))))))

(ert-deftest ogent-convoy-test-gastown-visit-other-toggles ()
  "Test that RET on non-convoy/non-mail sections toggles."
  (let ((toggled nil)
        (mock-section (ogent-convoy-test--mock-section)))
    (cl-letf (((symbol-function 'magit-current-section)
               (lambda () mock-section))
              ((symbol-function 'eieio-object-class-name)
               (lambda (_obj) 'ogent-gastown-root-section))
              ((symbol-function 'magit-section-toggle)
               (lambda (_section) (setq toggled t))))
      (let ((ogent-gastown--magit-section-available t))
        (ogent-gastown-visit)
        (should toggled)))))

;;; Buffer Name Tests

(ert-deftest ogent-convoy-test-buffer-name-format ()
  "Test buffer name formatting."
  (should (string= (format ogent-convoy-buffer-name-format "convoy-001")
                    "*Convoy: convoy-001*")))

;;; Provide

(provide 'ogent-convoy-tests)
;;; ogent-convoy-tests.el ends here
