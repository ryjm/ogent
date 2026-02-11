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

;;; --- Normalization Stability/Regression ---

(ert-deftest ogent-convoy-test-normalize-idempotent ()
  "Normalizing an already-normalized convoy produces identical output."
  (let* ((original '(:id "c1" :title "Test" :status "active"
                     :completed 3 :total 5 :tracked ("a")))
         (first (ogent-gastown--normalize-convoy original))
         (second (ogent-gastown--normalize-convoy first)))
    (should (equal (plist-get first :id) (plist-get second :id)))
    (should (equal (plist-get first :title) (plist-get second :title)))
    (should (equal (plist-get first :status) (plist-get second :status)))
    (should (equal (plist-get first :completed) (plist-get second :completed)))
    (should (equal (plist-get first :total) (plist-get second :total)))
    (should (equal (plist-get first :tracked) (plist-get second :tracked)))))

(ert-deftest ogent-convoy-test-normalize-legacy-idempotent ()
  "Normalizing a legacy convoy twice produces same result."
  (let* ((original '(:id "c1" :name "Legacy" :status "active" :progress "2/5"))
         (first (ogent-gastown--normalize-convoy original))
         (second (ogent-gastown--normalize-convoy first)))
    (should (equal (plist-get first :title) (plist-get second :title)))
    (should (equal (plist-get first :completed) (plist-get second :completed)))
    (should (equal (plist-get first :total) (plist-get second :total)))))

(ert-deftest ogent-convoy-test-visit-no-issue-at-point ()
  "Test visit errors when no issue at point."
  (with-temp-buffer
    (ogent-convoy-mode)
    (let ((ogent-convoy--magit-section-available nil))
      (should-error (ogent-convoy-visit) :type 'user-error))))

;;; Entry Point Tests

(ert-deftest ogent-convoy-test-inspect-empty-id ()
  "Test inspect with empty ID errors."
  (should-error (ogent-convoy-inspect "") :type 'user-error))

(ert-deftest ogent-convoy-test-inspect-nil-id ()
  "Test inspect with nil ID errors."
  (should-error (ogent-convoy-inspect nil) :type 'user-error))

(ert-deftest ogent-convoy-test-inspect-creates-buffer ()
  "Test inspect creates buffer with correct name."
  (ogent-convoy-test-with-mock ogent-convoy-test--sample-convoy-raw
    (let ((buf (get-buffer "*Convoy: convoy-001*")))
      (when buf (kill-buffer buf)))
    (cl-letf (((symbol-function 'pop-to-buffer-same-window) #'ignore))
      (ogent-convoy-inspect "convoy-001")
      (let ((buf (get-buffer "*Convoy: convoy-001*")))
        (should buf)
        (with-current-buffer buf
          (should (derived-mode-p 'ogent-convoy-mode))
          (should (equal "convoy-001" ogent-convoy--convoy-id)))
        (kill-buffer buf)))))

;;; Face Tests

(ert-deftest ogent-convoy-test-face-section-heading ()
  "Test ogent-convoy-section-heading face is defined."
  (should (facep 'ogent-convoy-section-heading)))

(ert-deftest ogent-convoy-test-face-active ()
  "Test ogent-convoy-active face is defined."
  (should (facep 'ogent-convoy-active)))

(ert-deftest ogent-convoy-test-face-complete ()
  "Test ogent-convoy-complete face is defined."
  (should (facep 'ogent-convoy-complete)))

(ert-deftest ogent-convoy-test-face-progress ()
  "Test ogent-convoy-progress face is defined."
  (should (facep 'ogent-convoy-progress)))

(ert-deftest ogent-convoy-test-face-dimmed ()
  "Test ogent-convoy-dimmed face is defined."
  (should (facep 'ogent-convoy-dimmed)))

(ert-deftest ogent-convoy-test-face-issue-id ()
  "Test ogent-convoy-issue-id face is defined."
  (should (facep 'ogent-convoy-issue-id)))

(ert-deftest ogent-convoy-test-face-issue-title ()
  "Test ogent-convoy-issue-title face is defined."
  (should (facep 'ogent-convoy-issue-title)))

(ert-deftest ogent-convoy-test-face-header-line ()
  "Test ogent-convoy-header-line face is defined."
  (should (facep 'ogent-convoy-header-line)))

(ert-deftest ogent-convoy-test-face-header-line-key ()
  "Test ogent-convoy-header-line-key face is defined."
  (should (facep 'ogent-convoy-header-line-key)))

;;; Customization Tests

(ert-deftest ogent-convoy-test-customization-buffer-name ()
  "Test default buffer name."
  (should (equal "*Convoy*" ogent-convoy-buffer-name)))

(ert-deftest ogent-convoy-test-customization-timeout ()
  "Test default timeout."
  (should (= 30 ogent-convoy-timeout)))

(ert-deftest ogent-convoy-test-customization-cache-ttl ()
  "Test default cache TTL."
  (should (= 5 ogent-convoy-cache-ttl)))

(ert-deftest ogent-convoy-test-customization-use-unicode ()
  "Test default unicode setting."
  (should ogent-convoy-use-unicode))

;;; --- Normalization Contract Tests (Regression) ---

(ert-deftest ogent-convoy-test-normalize-nil-convoy ()
  "Normalizing nil convoy produces a plist with all nil values."
  (let ((result (ogent-gastown--normalize-convoy nil)))
    (should (listp result))
    (should-not (plist-get result :id))
    (should-not (plist-get result :title))
    (should-not (plist-get result :status))
    (should-not (plist-get result :completed))
    (should-not (plist-get result :total))))

(ert-deftest ogent-convoy-test-normalize-empty-plist ()
  "Normalizing an empty plist produces a canonical plist with nil values."
  (let ((result (ogent-gastown--normalize-convoy '())))
    (should (listp result))
    (should-not (plist-get result :id))
    (should-not (plist-get result :title))))

(ert-deftest ogent-convoy-test-normalize-empty-string-title ()
  "Empty string title is preserved (not coerced to nil)."
  (let ((result (ogent-gastown--normalize-convoy '(:id "c1" :title "" :status "active"))))
    (should (equal (plist-get result :title) ""))))

(ert-deftest ogent-convoy-test-normalize-empty-string-name ()
  "Empty string :name is used as title when :title absent."
  (let ((result (ogent-gastown--normalize-convoy '(:id "c1" :name "" :status "active"))))
    (should (equal (plist-get result :title) ""))))

(ert-deftest ogent-convoy-test-normalize-title-takes-precedence-over-name ()
  "When both :title and :name present, :title wins."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :title "Modern Title" :name "Legacy Name" :status "active"))))
    (should (equal (plist-get result :title) "Modern Title"))))

(ert-deftest ogent-convoy-test-normalize-completed-total-override-progress ()
  "When :completed/:total present alongside :progress, explicit values win."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :title "Test" :status "active"
                   :completed 7 :total 10 :progress "3/5"))))
    (should (equal (plist-get result :completed) 7))
    (should (equal (plist-get result :total) 10))))

(ert-deftest ogent-convoy-test-normalize-legacy-progress-with-leading-zeros ()
  "Legacy :progress with leading zeros parses correctly."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :name "Test" :status "active" :progress "03/07"))))
    (should (equal (plist-get result :completed) 3))
    (should (equal (plist-get result :total) 7))))

(ert-deftest ogent-convoy-test-normalize-legacy-progress-zero-slash-zero ()
  "Legacy :progress 0/0 parses correctly."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :name "Empty" :status "active" :progress "0/0"))))
    (should (equal (plist-get result :completed) 0))
    (should (equal (plist-get result :total) 0))))

(ert-deftest ogent-convoy-test-normalize-legacy-progress-single-number ()
  "Legacy :progress with no slash does not parse."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :name "Bad" :status "active" :progress "42"))))
    (should-not (plist-get result :completed))
    (should-not (plist-get result :total))))

(ert-deftest ogent-convoy-test-normalize-legacy-progress-empty-string ()
  "Legacy :progress as empty string does not parse."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :name "Empty" :status "active" :progress ""))))
    (should-not (plist-get result :completed))
    (should-not (plist-get result :total))))

(ert-deftest ogent-convoy-test-normalize-legacy-progress-negative ()
  "Legacy :progress with negative numbers does not parse."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :name "Negative" :status "active" :progress "-1/5"))))
    (should-not (plist-get result :completed))
    (should-not (plist-get result :total))))

(ert-deftest ogent-convoy-test-normalize-legacy-progress-with-spaces ()
  "Legacy :progress with whitespace around numbers does not parse."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :name "Spaces" :status "active" :progress " 3 / 5 "))))
    (should-not (plist-get result :completed))
    (should-not (plist-get result :total))))

(ert-deftest ogent-convoy-test-normalize-legacy-progress-non-string ()
  "Legacy :progress as non-string value is safely ignored."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :name "NonStr" :status "active" :progress 42))))
    (should-not (plist-get result :completed))
    (should-not (plist-get result :total))))

(ert-deftest ogent-convoy-test-normalize-large-numbers ()
  "Large completed/total values are preserved."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :title "Big" :status "active"
                   :completed 999999 :total 1000000))))
    (should (equal (plist-get result :completed) 999999))
    (should (equal (plist-get result :total) 1000000))))

(ert-deftest ogent-convoy-test-normalize-tracked-list ()
  "Tracked list is preserved as-is."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :title "Track" :status "active"
                   :completed 1 :total 3 :tracked ("issue-1" "issue-2" "issue-3")))))
    (should (equal (plist-get result :tracked) '("issue-1" "issue-2" "issue-3")))))

(ert-deftest ogent-convoy-test-normalize-tracked-nil ()
  "Nil tracked is preserved."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :title "NoTrack" :status "active"
                   :completed 1 :total 3 :tracked nil))))
    (should-not (plist-get result :tracked))))

(ert-deftest ogent-convoy-test-normalize-unexpected-status ()
  "Unexpected status strings are preserved, not rejected."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :title "Test" :status "pending-review"))))
    (should (equal (plist-get result :status) "pending-review"))))

(ert-deftest ogent-convoy-test-normalize-nil-status ()
  "Nil status is preserved."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :title "Test" :status nil))))
    (should-not (plist-get result :status))))

(ert-deftest ogent-convoy-test-normalize-list-single-element ()
  "Normalizing a single-element list works."
  (let ((result (ogent-gastown--normalize-convoy-list
                 (list '(:id "c1" :title "Only" :status "active")))))
    (should (= (length result) 1))
    (should (equal (plist-get (car result) :title) "Only"))))

(ert-deftest ogent-convoy-test-normalize-list-preserves-order ()
  "Normalizing a list preserves element order."
  (let* ((convoys (list '(:id "c1" :title "First" :status "active")
                        '(:id "c2" :title "Second" :status "active")
                        '(:id "c3" :title "Third" :status "complete")))
         (result (ogent-gastown--normalize-convoy-list convoys)))
    (should (= (length result) 3))
    (should (equal (plist-get (nth 0 result) :title) "First"))
    (should (equal (plist-get (nth 1 result) :title) "Second"))
    (should (equal (plist-get (nth 2 result) :title) "Third"))))

;;; --- Progress String Tests ---

(ert-deftest ogent-convoy-test-progress-string-zero-values ()
  "Progress string formats zero values."
  (should (equal (ogent-gastown--convoy-progress-string
                  '(:completed 0 :total 0))
                 "0/0")))

(ert-deftest ogent-convoy-test-progress-string-large-values ()
  "Progress string formats large values."
  (should (equal (ogent-gastown--convoy-progress-string
                  '(:completed 999 :total 1000))
                 "999/1000")))

(ert-deftest ogent-convoy-test-progress-string-completed-only ()
  "Progress string returns nil when only :completed present."
  (should-not (ogent-gastown--convoy-progress-string
               '(:completed 5 :total nil))))

(ert-deftest ogent-convoy-test-progress-string-total-only ()
  "Progress string returns nil when only :total present."
  (should-not (ogent-gastown--convoy-progress-string
               '(:completed nil :total 10))))

;;; --- Plain Rendering Edge Cases ---

(ert-deftest ogent-convoy-test-plain-convoy-no-id ()
  "Convoy with nil ID renders without error."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id nil :title "No ID Convoy" :status "active"
                   :completed 1 :total 2 :tracked nil))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "No ID Convoy" content))))))

(ert-deftest ogent-convoy-test-plain-convoy-no-title-shows-unnamed ()
  "Convoy with nil title shows (unnamed) in plain mode."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :title nil :status "active"
                   :completed 1 :total 3 :tracked nil))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "(unnamed)" content))))))

(ert-deftest ogent-convoy-test-plain-unexpected-status-renders ()
  "Unexpected status strings don't break plain rendering."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :title "Weird Status" :status "exploding"
                   :completed 0 :total 5 :tracked nil))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Weird Status" content))))))

(ert-deftest ogent-convoy-test-plain-nil-status-renders ()
  "Nil status doesn't break plain rendering."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :title "Nil Status" :status nil
                   :completed 2 :total 4 :tracked nil))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Nil Status" content))))))

(ert-deftest ogent-convoy-test-plain-empty-convoy-list ()
  "Empty convoy list shows 'No active convoys'."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data nil))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "No active convoys" content))))))

(ert-deftest ogent-convoy-test-plain-empty-tracked-list ()
  "Convoy with empty tracked list renders correctly."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :title "Has Tracking" :status "active"
                   :completed 0 :total 3 :tracked nil))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Has Tracking" content))))))

(ert-deftest ogent-convoy-test-plain-partial-tracked-entries ()
  "Convoy with partially populated data still renders a line."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :title "Partial" :status "active"
                   :completed nil :total nil :tracked ("only-one")))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Partial" content))))))

(ert-deftest ogent-convoy-test-plain-normalized-legacy-renders ()
  "Legacy payload normalized then rendered produces correct title."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (ogent-gastown--normalize-convoy-list
            (list '(:id "c1" :name "Legacy Deploy" :status "complete"
                    :progress "10/10")))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Legacy Deploy" content))))))

(ert-deftest ogent-convoy-test-plain-normalized-mixed-renders-both ()
  "Mixed modern+legacy payloads both appear after normalization."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (ogent-gastown--normalize-convoy-list
            (list '(:id "c1" :title "Modern Ship" :status "active"
                    :completed 3 :total 8 :tracked nil)
                  '(:id "c2" :name "Legacy Ship" :status "complete"
                    :progress "5/5")))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Modern Ship" content))
        (should (string-match-p "Legacy Ship" content))))))

;;; --- No-Magit Fallback Tests ---

(ert-deftest ogent-convoy-test-no-magit-convoy-status-calls-list ()
  "When magit unavailable, convoy-status runs `gt convoy list`."
  (let ((commands nil))
    (cl-letf (((symbol-function 'async-shell-command)
               (lambda (cmd &optional buf)
                 (push (list cmd buf) commands))))
      (let ((ogent-gastown--magit-section-available nil))
        (ogent-gastown-convoy-status)
        (should (= (length commands) 1))
        (should (string-match-p "convoy list" (caar commands)))))))

(ert-deftest ogent-convoy-test-no-magit-convoy-create-success ()
  "When magit unavailable, convoy-create sends correct args."
  (let ((run-async-args nil)
        (messages nil))
    (cl-letf (((symbol-function 'ogent-gastown-status--run-async)
               (lambda (args &optional _ok _err _json)
                 (setq run-async-args args)))
              ((symbol-function 'read-string)
               (let ((calls 0))
                 (lambda (_prompt &rest _rest)
                   (cl-incf calls)
                   (if (= calls 1) "Test Convoy" "issue-a issue-b"))))
              ((symbol-function 'ogent-gastown-cache-invalidate) #'ignore)
              ((symbol-function 'ogent-gastown-refresh) #'ignore))
      (let ((ogent-gastown--magit-section-available nil))
        (ogent-gastown-convoy-create)
        (should (equal run-async-args '("convoy" "create" "Test Convoy" "issue-a" "issue-b")))))))

(ert-deftest ogent-convoy-test-no-magit-convoy-create-error ()
  "When convoy-create fails, error message is displayed."
  (let ((messages nil))
    (cl-letf (((symbol-function 'ogent-gastown-status--run-async)
               (lambda (_args &optional _ok err _json)
                 (when err (funcall err "creation failed"))))
              ((symbol-function 'read-string)
               (let ((calls 0))
                 (lambda (_prompt &rest _rest)
                   (cl-incf calls)
                   (if (= calls 1) "Bad Convoy" "issue-x"))))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (let ((ogent-gastown--magit-section-available nil))
        (ogent-gastown-convoy-create)
        (should (seq-some (lambda (m) (string-match-p "Failed to create convoy" m)) messages))))))

;;; --- Full Buffer Insertion (No-Magit) ---

(ert-deftest ogent-convoy-test-insert-plain-full-buffer-with-convoys ()
  "Full plain buffer insertion includes convoy section when data present."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :title "Ship It" :status "active"
                   :completed 2 :total 5 :tracked nil)))
          (ogent-gastown--hook-data '(:has_work nil :role "test" :target "test/" :next_action nil))
          (ogent-gastown--mail-data nil)
          (ogent-gastown--workers-data nil)
          (ogent-gastown--stats-data nil)
          (ogent-gastown--deacon-data nil)
          (ogent-gastown--witness-data nil)
          (ogent-gastown--crew-data nil)
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--rigs-data nil)
          (ogent-gastown--magit-section-available nil))
      (ogent-gastown--insert-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Convoys" content))
        (should (string-match-p "Ship It" content))))))

(ert-deftest ogent-convoy-test-insert-plain-full-buffer-no-convoys ()
  "Full plain buffer insertion shows empty convoy message."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data nil)
          (ogent-gastown--hook-data '(:has_work nil :role "test" :target "test/" :next_action nil))
          (ogent-gastown--mail-data nil)
          (ogent-gastown--workers-data nil)
          (ogent-gastown--stats-data nil)
          (ogent-gastown--deacon-data nil)
          (ogent-gastown--witness-data nil)
          (ogent-gastown--crew-data nil)
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--rigs-data nil)
          (ogent-gastown--magit-section-available nil))
      (ogent-gastown--insert-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "No active convoys" content))))))

;;; --- Normalization Stability/Regression ---

(ert-deftest ogent-convoy-test-normalize-idempotent ()
  "Normalizing an already-normalized convoy produces identical output."
  (let* ((original '(:id "c1" :title "Test" :status "active"
                     :completed 3 :total 5 :tracked ("a")))
         (first (ogent-gastown--normalize-convoy original))
         (second (ogent-gastown--normalize-convoy first)))
    (should (equal (plist-get first :id) (plist-get second :id)))
    (should (equal (plist-get first :title) (plist-get second :title)))
    (should (equal (plist-get first :status) (plist-get second :status)))
    (should (equal (plist-get first :completed) (plist-get second :completed)))
    (should (equal (plist-get first :total) (plist-get second :total)))
    (should (equal (plist-get first :tracked) (plist-get second :tracked)))))

(ert-deftest ogent-convoy-test-normalize-legacy-idempotent ()
  "Normalizing a legacy convoy twice produces same result."
  (let* ((original '(:id "c1" :name "Legacy" :status "active" :progress "2/5"))
         (first (ogent-gastown--normalize-convoy original))
         (second (ogent-gastown--normalize-convoy first)))
    (should (equal (plist-get first :title) (plist-get second :title)))
    (should (equal (plist-get first :completed) (plist-get second :completed)))
    (should (equal (plist-get first :total) (plist-get second :total)))))

(ert-deftest ogent-convoy-test-normalize-preserves-extra-keys ()
  "Extra keys beyond the canonical set don't cause errors."
  (let ((result (ogent-gastown--normalize-convoy
                 '(:id "c1" :title "Extra" :status "active"
                   :completed 1 :total 2 :tracked nil
                   :extra-key "extra-value" :another 42))))
    (should (equal (plist-get result :title) "Extra"))
    (should (equal (plist-get result :completed) 1))))

;;; Provide

(ert-deftest ogent-convoy-test-inspect-empty-id ()
  "Test inspect with empty ID errors."
  (should-error (ogent-convoy-inspect "") :type 'user-error))

(ert-deftest ogent-convoy-test-inspect-nil-id ()
  "Test inspect with nil ID errors."
  (should-error (ogent-convoy-inspect nil) :type 'user-error))

(ert-deftest ogent-convoy-test-inspect-creates-buffer ()
  "Test inspect creates buffer with correct name."
  (ogent-convoy-test-with-mock ogent-convoy-test--sample-convoy-raw
    (let ((buf (get-buffer "*Convoy: convoy-001*")))
      (when buf (kill-buffer buf)))
    (cl-letf (((symbol-function 'pop-to-buffer-same-window) #'ignore))
      (ogent-convoy-inspect "convoy-001")
      (let ((buf (get-buffer "*Convoy: convoy-001*")))
        (should buf)
        (with-current-buffer buf
          (should (derived-mode-p 'ogent-convoy-mode))
          (should (equal "convoy-001" ogent-convoy--convoy-id)))
        (kill-buffer buf)))))

;;; Face Tests

(ert-deftest ogent-convoy-test-face-section-heading ()
  "Test ogent-convoy-section-heading face is defined."
  (should (facep 'ogent-convoy-section-heading)))

(ert-deftest ogent-convoy-test-face-active ()
  "Test ogent-convoy-active face is defined."
  (should (facep 'ogent-convoy-active)))

(ert-deftest ogent-convoy-test-face-complete ()
  "Test ogent-convoy-complete face is defined."
  (should (facep 'ogent-convoy-complete)))

(ert-deftest ogent-convoy-test-face-progress ()
  "Test ogent-convoy-progress face is defined."
  (should (facep 'ogent-convoy-progress)))

(ert-deftest ogent-convoy-test-face-dimmed ()
  "Test ogent-convoy-dimmed face is defined."
  (should (facep 'ogent-convoy-dimmed)))

(ert-deftest ogent-convoy-test-face-issue-id ()
  "Test ogent-convoy-issue-id face is defined."
  (should (facep 'ogent-convoy-issue-id)))

(ert-deftest ogent-convoy-test-face-issue-title ()
  "Test ogent-convoy-issue-title face is defined."
  (should (facep 'ogent-convoy-issue-title)))

(ert-deftest ogent-convoy-test-face-header-line ()
  "Test ogent-convoy-header-line face is defined."
  (should (facep 'ogent-convoy-header-line)))

(ert-deftest ogent-convoy-test-face-header-line-key ()
  "Test ogent-convoy-header-line-key face is defined."
  (should (facep 'ogent-convoy-header-line-key)))

;;; Customization Tests

(ert-deftest ogent-convoy-test-customization-buffer-name ()
  "Test default buffer name."
  (should (equal "*Convoy*" ogent-convoy-buffer-name)))

(ert-deftest ogent-convoy-test-customization-timeout ()
  "Test default timeout."
  (should (= 30 ogent-convoy-timeout)))

(ert-deftest ogent-convoy-test-customization-cache-ttl ()
  "Test default cache TTL."
  (should (= 5 ogent-convoy-cache-ttl)))

(ert-deftest ogent-convoy-test-customization-use-unicode ()
  "Test default unicode setting."
  (should ogent-convoy-use-unicode))

;;; Provide

(provide 'ogent-convoy-tests)
;;; ogent-convoy-tests.el ends here
