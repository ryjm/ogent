;;; ogent-convoy-tests.el --- Regression tests for convoy normalization and fallback paths -*- lexical-binding: t; -*-

;;; Commentary:
;; Contract tests for convoy normalization across modern/legacy payload shapes,
;; no-magit fallback inspector rendering, malformed payloads, and edge cases.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-gastown-status)

;;; --- Normalization Contract Tests ---

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

(provide 'ogent-convoy-tests)

;;; ogent-convoy-tests.el ends here
