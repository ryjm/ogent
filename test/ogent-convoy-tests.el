;;; ogent-convoy-tests.el --- Tests for ogent-convoy -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Convoy inspector mode.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-convoy)

;;; Test Fixtures

(defconst ogent-convoy-test--sample-convoy-raw
  '(:id "convoy-001"
    :title "Feature implementation"
    :status "active"
    :completed 3
    :total 5
    :tracked ((:id "og-001" :title "Add auth" :status "in_progress"
               :type "task" :assignee "polecat-alpha")
              (:id "og-002" :title "Fix login" :status "open"
               :type "bug" :assignee nil)
              (:id "og-003" :title "Update docs" :status "closed"
               :type "chore")))
  "Sample raw convoy data for testing.")

(defconst ogent-convoy-test--sample-convoy-complete
  '(:id "convoy-002"
    :title "Bug fixes"
    :status "complete"
    :completed 5
    :total 5
    :tracked nil)
  "Sample completed convoy with no tracked items.")

(defconst ogent-convoy-test--sample-convoy-legacy
  '(:id "convoy-003"
    :name "Legacy convoy"
    :status "active"
    :progress "2/4"
    :tracked nil)
  "Sample convoy with legacy payload shape.")

(defconst ogent-convoy-test--sample-convoy-no-title
  '(:id "convoy-004"
    :status "active"
    :completed 0
    :total 3
    :tracked nil)
  "Sample convoy with missing title.")

;;; Mocking Utilities

(defvar ogent-convoy-test--mock-output nil
  "Mock output to return from gt commands.")

(defvar ogent-convoy-test--mock-error nil
  "Mock error to return from gt commands.")

(defvar ogent-convoy-test--captured-args nil
  "Captured arguments from mock gt calls.")

(defmacro ogent-convoy-test-with-mock (output &rest body)
  "Execute BODY with gt mocked to return OUTPUT."
  (declare (indent 1) (debug t))
  `(let ((ogent-convoy-test--mock-output ,output)
         (ogent-convoy-test--mock-error nil)
         (ogent-convoy-test--captured-args nil)
         (ogent-convoy-gt-executable "gt")
         (ogent-convoy--cache (make-hash-table :test 'equal)))
     (cl-letf (((symbol-function 'ogent-convoy--run-async)
                (lambda (args callback &optional error-callback)
                  (setq ogent-convoy-test--captured-args args)
                  (if ogent-convoy-test--mock-error
                      (when error-callback
                        (funcall error-callback ogent-convoy-test--mock-error))
                    (funcall callback ogent-convoy-test--mock-output))
                  nil)))
       ,@body)))

(defmacro ogent-convoy-test-with-error (error-msg &rest body)
  "Execute BODY with gt mocked to return ERROR-MSG."
  (declare (indent 1) (debug t))
  `(let ((ogent-convoy-test--mock-output nil)
         (ogent-convoy-test--mock-error ,error-msg)
         (ogent-convoy-test--captured-args nil)
         (ogent-convoy-gt-executable "gt")
         (ogent-convoy--cache (make-hash-table :test 'equal)))
     (cl-letf (((symbol-function 'ogent-convoy--run-async)
                (lambda (args callback &optional error-callback)
                  (setq ogent-convoy-test--captured-args args)
                  (if ogent-convoy-test--mock-error
                      (when error-callback
                        (funcall error-callback ogent-convoy-test--mock-error))
                    (funcall callback ogent-convoy-test--mock-output))
                  nil)))
       ,@body)))

;;; Mode Tests

(ert-deftest ogent-convoy-test-mode-defined ()
  "Test that ogent-convoy-mode is defined."
  (should (fboundp 'ogent-convoy-mode)))

(ert-deftest ogent-convoy-test-mode-keymap-exists ()
  "Test that the mode keymap exists."
  (should (keymapp ogent-convoy-mode-map)))

(ert-deftest ogent-convoy-test-mode-keymap-g ()
  "Test that g is bound to refresh."
  (should (eq (lookup-key ogent-convoy-mode-map "g")
              'ogent-convoy-refresh)))

(ert-deftest ogent-convoy-test-mode-keymap-G ()
  "Test that G is bound to force refresh."
  (should (eq (lookup-key ogent-convoy-mode-map "G")
              'ogent-convoy-refresh-force)))

(ert-deftest ogent-convoy-test-mode-keymap-q ()
  "Test that q is bound to quit-window."
  (should (eq (lookup-key ogent-convoy-mode-map "q")
              'quit-window)))

(ert-deftest ogent-convoy-test-mode-keymap-n ()
  "Test that n is bound to next-item."
  (should (eq (lookup-key ogent-convoy-mode-map "n")
              'ogent-convoy-next-item)))

(ert-deftest ogent-convoy-test-mode-keymap-p ()
  "Test that p is bound to prev-item."
  (should (eq (lookup-key ogent-convoy-mode-map "p")
              'ogent-convoy-prev-item)))

(ert-deftest ogent-convoy-test-mode-keymap-tab ()
  "Test that TAB is bound to toggle-section."
  (should (eq (lookup-key ogent-convoy-mode-map (kbd "TAB"))
              'ogent-convoy-toggle-section)))

(ert-deftest ogent-convoy-test-mode-keymap-ret ()
  "Test that RET is bound to visit."
  (should (eq (lookup-key ogent-convoy-mode-map (kbd "RET"))
              'ogent-convoy-visit)))

(ert-deftest ogent-convoy-test-mode-sets-read-only ()
  "Test that mode sets buffer to read-only."
  (with-temp-buffer
    (ogent-convoy-mode)
    (should buffer-read-only)))

(ert-deftest ogent-convoy-test-mode-sets-truncate-lines ()
  "Test that mode sets truncate-lines."
  (with-temp-buffer
    (ogent-convoy-mode)
    (should truncate-lines)))

;;; Cache Tests

(ert-deftest ogent-convoy-test-cache-key ()
  "Test cache key generation."
  (should (equal "c1:(\"convoy\" \"status\")"
                 (ogent-convoy--cache-key "c1" '("convoy" "status")))))

(ert-deftest ogent-convoy-test-cache-key-different-convoys ()
  "Test that different convoy IDs produce different cache keys."
  (let ((key1 (ogent-convoy--cache-key "c1" '("convoy" "status")))
        (key2 (ogent-convoy--cache-key "c2" '("convoy" "status"))))
    (should-not (equal key1 key2))))

(ert-deftest ogent-convoy-test-cache-set-and-get ()
  "Test setting and getting cache values."
  (let ((ogent-convoy--cache (make-hash-table :test 'equal))
        (ogent-convoy-cache-ttl 60))
    (ogent-convoy--cache-set "c1" '("cmd") '(:result "value"))
    (let ((result (ogent-convoy--cache-get "c1" '("cmd"))))
      (should result)
      (should (equal '(:result "value") result)))))

(ert-deftest ogent-convoy-test-cache-get-returns-nil-when-empty ()
  "Test that cache get returns nil for uncached values."
  (let ((ogent-convoy--cache (make-hash-table :test 'equal))
        (ogent-convoy-cache-ttl 60))
    (should-not (ogent-convoy--cache-get "c1" '("cmd")))))

(ert-deftest ogent-convoy-test-cache-disabled-when-ttl-zero ()
  "Test that cache is disabled when TTL is 0."
  (let ((ogent-convoy--cache (make-hash-table :test 'equal))
        (ogent-convoy-cache-ttl 0))
    (ogent-convoy--cache-set "c1" '("cmd") '(:result "value"))
    (should-not (ogent-convoy--cache-get "c1" '("cmd")))))

(ert-deftest ogent-convoy-test-cache-invalidate ()
  "Test cache invalidation clears all entries."
  (let ((ogent-convoy--cache (make-hash-table :test 'equal))
        (ogent-convoy-cache-ttl 60))
    (ogent-convoy--cache-set "c1" '("cmd1") '(:result "1"))
    (ogent-convoy--cache-set "c2" '("cmd2") '(:result "2"))
    (should (ogent-convoy--cache-get "c1" '("cmd1")))
    (should (ogent-convoy--cache-get "c2" '("cmd2")))
    (ogent-convoy-cache-invalidate)
    (should-not (ogent-convoy--cache-get "c1" '("cmd1")))
    (should-not (ogent-convoy--cache-get "c2" '("cmd2")))))

;;; Loading Animation Tests

(ert-deftest ogent-convoy-test-loading-frames-defined ()
  "Test that loading frames are defined."
  (should (listp ogent-convoy--loading-frames))
  (should (= 4 (length ogent-convoy--loading-frames))))

(ert-deftest ogent-convoy-test-start-loading ()
  "Test start-loading sets state."
  (with-temp-buffer
    (ogent-convoy-mode)
    (ogent-convoy--start-loading)
    (should ogent-convoy--loading)
    (should ogent-convoy--loading-timer)
    (should (= 0 ogent-convoy--loading-frame))
    (ogent-convoy--stop-loading)))

(ert-deftest ogent-convoy-test-stop-loading ()
  "Test stop-loading clears state."
  (with-temp-buffer
    (ogent-convoy-mode)
    (ogent-convoy--start-loading)
    (ogent-convoy--stop-loading)
    (should-not ogent-convoy--loading)
    (should-not ogent-convoy--loading-timer)))

(ert-deftest ogent-convoy-test-stop-loading-timer-noop ()
  "Test stop-loading-timer is safe when nil."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--loading-timer nil)
    (ogent-convoy--stop-loading-timer)
    (should-not ogent-convoy--loading-timer)))

(ert-deftest ogent-convoy-test-loading-indicator-nil-when-not-loading ()
  "Test loading indicator returns nil when not loading."
  (with-temp-buffer
    (ogent-convoy-mode)
    (should-not (ogent-convoy--loading-indicator))))

(ert-deftest ogent-convoy-test-loading-indicator-returns-frame ()
  "Test loading indicator returns current frame when loading."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--loading t
          ogent-convoy--loading-frame 0)
    (should (ogent-convoy--loading-indicator))
    (setq ogent-convoy--loading nil)))

(ert-deftest ogent-convoy-test-animate-loading ()
  "Test animate-loading advances frame."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--loading t
          ogent-convoy--loading-frame 0)
    (ogent-convoy--animate-loading (current-buffer))
    (should (= 1 ogent-convoy--loading-frame))
    (ogent-convoy--animate-loading (current-buffer))
    (should (= 2 ogent-convoy--loading-frame))
    (setq ogent-convoy--loading nil)))

(ert-deftest ogent-convoy-test-animate-loading-wraps ()
  "Test animate-loading wraps around at frame 4."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--loading t
          ogent-convoy--loading-frame 3)
    (ogent-convoy--animate-loading (current-buffer))
    (should (= 0 ogent-convoy--loading-frame))
    (setq ogent-convoy--loading nil)))

(ert-deftest ogent-convoy-test-animate-loading-dead-buffer ()
  "Test animate-loading is safe for dead buffers."
  (let ((buf (generate-new-buffer " *test*")))
    (kill-buffer buf)
    ;; Should not error
    (ogent-convoy--animate-loading buf)))

;;; Header Line Tests

(ert-deftest ogent-convoy-test-header-line-no-data ()
  "Test header line with no convoy data."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--data nil
          ogent-convoy--convoy-id "c1")
    (let ((result (ogent-convoy--header-line)))
      (should (stringp result))
      (should (string-match-p "Convoy:" result)))))

(ert-deftest ogent-convoy-test-header-line-with-data ()
  "Test header line displays convoy title."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--data
          (ogent-gastown--normalize-convoy ogent-convoy-test--sample-convoy-raw)
          ogent-convoy--convoy-id "convoy-001")
    (let ((result (ogent-convoy--header-line)))
      (should (string-match-p "Feature implementation" result)))))

(ert-deftest ogent-convoy-test-header-line-loading ()
  "Test header line shows loading indicator."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--loading t
          ogent-convoy--loading-frame 0
          ogent-convoy--convoy-id "c1")
    (let ((result (ogent-convoy--header-line)))
      (should (string-match-p "Loading" result)))
    (setq ogent-convoy--loading nil)))

;;; Header Section Rendering Tests

(ert-deftest ogent-convoy-test-header-section-plain-with-data ()
  "Test header section plain rendering with convoy data."
  (with-temp-buffer
    (let ((ogent-convoy--data
           (ogent-gastown--normalize-convoy ogent-convoy-test--sample-convoy-raw)))
      (ogent-convoy--insert-header-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Convoy" content))
        (should (string-match-p "Feature implementation" content))
        (should (string-match-p "active" content))
        (should (string-match-p "3/5" content))))))

(ert-deftest ogent-convoy-test-header-section-plain-no-data ()
  "Test header section plain rendering with no data."
  (with-temp-buffer
    (let ((ogent-convoy--data nil))
      (ogent-convoy--insert-header-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "No convoy data" content))))))

(ert-deftest ogent-convoy-test-header-section-plain-complete ()
  "Test header section plain rendering for completed convoy."
  (with-temp-buffer
    (let ((ogent-convoy--data
           (ogent-gastown--normalize-convoy ogent-convoy-test--sample-convoy-complete)))
      (ogent-convoy--insert-header-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Bug fixes" content))
        (should (string-match-p "complete" content))))))

(ert-deftest ogent-convoy-test-header-section-plain-legacy ()
  "Test header section plain rendering for legacy convoy."
  (with-temp-buffer
    (let ((ogent-convoy--data
           (ogent-gastown--normalize-convoy ogent-convoy-test--sample-convoy-legacy)))
      (ogent-convoy--insert-header-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Legacy convoy" content))
        (should (string-match-p "2/4" content))))))

(ert-deftest ogent-convoy-test-header-section-plain-unnamed ()
  "Test header section plain rendering for unnamed convoy."
  (with-temp-buffer
    (let ((ogent-convoy--data
           (ogent-gastown--normalize-convoy ogent-convoy-test--sample-convoy-no-title)))
      (ogent-convoy--insert-header-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "(unnamed)" content))))))

(ert-deftest ogent-convoy-test-header-fields-id ()
  "Test header fields include ID."
  (with-temp-buffer
    (let ((convoy (ogent-gastown--normalize-convoy ogent-convoy-test--sample-convoy-raw)))
      (ogent-convoy--insert-header-fields convoy)
      (let ((content (buffer-string)))
        (should (string-match-p "convoy-001" content))))))

;;; Tracked Issues Section Tests

(ert-deftest ogent-convoy-test-tracked-section-plain-with-issues ()
  "Test tracked issues section plain rendering with issues."
  (with-temp-buffer
    (let ((ogent-convoy--data
           (ogent-gastown--normalize-convoy ogent-convoy-test--sample-convoy-raw)))
      (ogent-convoy--insert-tracked-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Tracked Issues" content))
        (should (string-match-p "og-001" content))
        (should (string-match-p "Add auth" content))
        (should (string-match-p "og-002" content))
        (should (string-match-p "Fix login" content))
        (should (string-match-p "og-003" content))
        (should (string-match-p "Update docs" content))))))

(ert-deftest ogent-convoy-test-tracked-section-plain-empty ()
  "Test tracked issues section plain rendering with no issues."
  (with-temp-buffer
    (let ((ogent-convoy--data
           (ogent-gastown--normalize-convoy ogent-convoy-test--sample-convoy-complete)))
      (ogent-convoy--insert-tracked-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "No tracked issues" content))))))

(ert-deftest ogent-convoy-test-tracked-section-plain-nil-convoy ()
  "Test tracked issues section plain rendering with nil convoy."
  (with-temp-buffer
    (let ((ogent-convoy--data nil))
      (ogent-convoy--insert-tracked-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "No tracked issues" content))))))

;;; Issue Item Rendering Tests

(ert-deftest ogent-convoy-test-issue-item-plain-with-status ()
  "Test plain issue item rendering with all fields."
  (with-temp-buffer
    (ogent-convoy--insert-issue-item-plain
     '(:id "og-001" :title "Add auth" :status "in_progress"))
    (let ((content (buffer-string)))
      (should (string-match-p "og-001" content))
      (should (string-match-p "Add auth" content))
      (should (string-match-p "in_progress" content)))))

(ert-deftest ogent-convoy-test-issue-item-plain-nil-status ()
  "Test plain issue item rendering with nil status."
  (with-temp-buffer
    (ogent-convoy--insert-issue-item-plain
     '(:id "og-001" :title "Test" :status nil))
    (let ((content (buffer-string)))
      (should (string-match-p "\\?" content)))))

(ert-deftest ogent-convoy-test-issue-item-plain-nil-id ()
  "Test plain issue item rendering with nil id."
  (with-temp-buffer
    (ogent-convoy--insert-issue-item-plain
     '(:id nil :title "Test" :status "open"))
    (let ((content (buffer-string)))
      (should (string-match-p "???" content)))))

(ert-deftest ogent-convoy-test-issue-item-plain-nil-title ()
  "Test plain issue item rendering with nil title."
  (with-temp-buffer
    (ogent-convoy--insert-issue-item-plain
     '(:id "og-001" :title nil :status "open"))
    (let ((content (buffer-string)))
      (should (string-match-p "(untitled)" content)))))

;;; Full Buffer Rendering Tests (Plain)

(ert-deftest ogent-convoy-test-insert-plain-with-data ()
  "Test full plain buffer rendering with convoy data."
  (with-temp-buffer
    (let ((ogent-convoy--data
           (ogent-gastown--normalize-convoy ogent-convoy-test--sample-convoy-raw)))
      (ogent-convoy--insert-plain)
      (let ((content (buffer-string)))
        ;; Header section
        (should (string-match-p "Convoy" content))
        (should (string-match-p "Feature implementation" content))
        ;; Tracked section
        (should (string-match-p "Tracked Issues" content))
        (should (string-match-p "og-001" content))))))

(ert-deftest ogent-convoy-test-insert-plain-no-data ()
  "Test full plain buffer rendering with no data."
  (with-temp-buffer
    (let ((ogent-convoy--data nil))
      (ogent-convoy--insert-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "No convoy data" content))
        (should (string-match-p "No tracked issues" content))))))

;;; Fetch Tests

(ert-deftest ogent-convoy-test-fetch-calls-correct-args ()
  "Test that fetch calls gt with correct arguments."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--convoy-id "convoy-001")
    (ogent-convoy-test-with-mock ogent-convoy-test--sample-convoy-raw
      (ogent-convoy--fetch (lambda ()))
      (should (equal '("convoy" "status" "convoy-001" "--json")
                     ogent-convoy-test--captured-args)))))

(ert-deftest ogent-convoy-test-fetch-normalizes-data ()
  "Test that fetch normalizes the convoy data."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--convoy-id "convoy-001")
    (ogent-convoy-test-with-mock ogent-convoy-test--sample-convoy-raw
      (ogent-convoy--fetch (lambda ()))
      (should ogent-convoy--data)
      (should (equal "Feature implementation" (plist-get ogent-convoy--data :title))))))

(ert-deftest ogent-convoy-test-fetch-error-sets-nil ()
  "Test that fetch error sets data to nil."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--convoy-id "convoy-001")
    (ogent-convoy-test-with-error "connection refused"
      (ogent-convoy--fetch (lambda ()))
      (should-not ogent-convoy--data))))

(ert-deftest ogent-convoy-test-fetch-nil-result ()
  "Test that fetch with nil result sets data to nil."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--convoy-id "convoy-001")
    (ogent-convoy-test-with-mock nil
      (ogent-convoy--fetch (lambda ()))
      (should-not ogent-convoy--data))))

;;; Refresh Tests

(ert-deftest ogent-convoy-test-refresh-populates-buffer ()
  "Test that refresh populates the buffer."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--convoy-id "convoy-001")
    (ogent-convoy-test-with-mock ogent-convoy-test--sample-convoy-raw
      (ogent-convoy-refresh)
      (let ((content (buffer-string)))
        (should (> (length content) 0))))))

(ert-deftest ogent-convoy-test-refresh-force-clears-cache ()
  "Test that force refresh clears cache."
  (with-temp-buffer
    (ogent-convoy-mode)
    (setq ogent-convoy--convoy-id "convoy-001")
    (let ((ogent-convoy--cache (make-hash-table :test 'equal))
          (ogent-convoy-cache-ttl 60))
      (ogent-convoy--cache-set "c1" '("cmd") '(:data "old"))
      (ogent-convoy-test-with-mock ogent-convoy-test--sample-convoy-raw
        (ogent-convoy-refresh-force)
        (should-not (ogent-convoy--cache-get "c1" '("cmd")))))))

;;; Navigation Tests (plain mode, no magit)

(ert-deftest ogent-convoy-test-next-item-no-magit ()
  "Test next-item without magit moves forward line."
  (with-temp-buffer
    (ogent-convoy-mode)
    (let ((ogent-convoy--magit-section-available nil)
          (inhibit-read-only t))
      (insert "line 1\nline 2\nline 3\n")
      (goto-char (point-min))
      (ogent-convoy-next-item)
      (should (= 2 (line-number-at-pos))))))

(ert-deftest ogent-convoy-test-prev-item-no-magit ()
  "Test prev-item without magit moves backward line."
  (with-temp-buffer
    (ogent-convoy-mode)
    (let ((ogent-convoy--magit-section-available nil)
          (inhibit-read-only t))
      (insert "line 1\nline 2\nline 3\n")
      (goto-char (point-min))
      (forward-line 2)
      (ogent-convoy-prev-item)
      (should (= 2 (line-number-at-pos))))))

(ert-deftest ogent-convoy-test-toggle-section-no-magit ()
  "Test toggle-section is safe without magit."
  (with-temp-buffer
    (ogent-convoy-mode)
    (let ((ogent-convoy--magit-section-available nil))
      ;; Should not error
      (ogent-convoy-toggle-section))))

;;; Visit Tests

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

(provide 'ogent-convoy-tests)
;;; ogent-convoy-tests.el ends here
