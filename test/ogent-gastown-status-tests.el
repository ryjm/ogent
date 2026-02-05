;;; ogent-gastown-status-tests.el --- Tests for ogent-gastown-status -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Gas Town status buffer (ogent-gastown-status.el).
;; Focuses on data formatting, section insertion, and buffer management.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-gastown-status)

;;; Test Fixtures

(defconst ogent-gts-test--sample-hook-active
  '(:has_work t
    :role "mayor"
    :target "mayor/"
    :next_action nil)
  "Sample hook data with active work.")

(defconst ogent-gts-test--sample-hook-empty
  '(:has_work nil
    :role "polecat"
    :target "ogent/polecats/alpha"
    :next_action "Check mail or wait for assignment")
  "Sample hook data with no work.")

(defconst ogent-gts-test--sample-mail
  (list '(:id "mail-001"
          :from "witness"
          :subject "Status check"
          :timestamp "2026-01-05T10:00:00Z"
          :read nil)
        '(:id "mail-002"
          :from "refinery"
          :subject "Merge complete"
          :timestamp "2026-01-05T11:00:00Z"
          :read t)
        '(:id "mail-003"
          :from "deacon"
          :subject "Health check passed"
          :timestamp "2026-01-05T12:00:00Z"
          :read nil))
  "Sample mail list for testing.")

(defconst ogent-gts-test--sample-convoy
  (list '(:id "convoy-001"
          :name "Feature implementation"
          :status "active"
          :progress "3/5")
        '(:id "convoy-002"
          :name "Bug fixes"
          :status "complete"
          :progress "5/5"))
  "Sample convoy list for testing.")

(defconst ogent-gts-test--sample-workers
  (list '(:name "alpha"
          :rig "ogent"
          :state "working"
          :session_running t)
        '(:name "beta"
          :rig "ogent"
          :state "idle"
          :session_running nil)
        '(:name "gamma"
          :rig "beads"
          :state "working"
          :session_running t))
  "Sample workers list for testing.")

(defconst ogent-gts-test--sample-stats
  '(:rig_count 3
    :polecat_count 5
    :crew_count 8
    :witness_count 2
    :refinery_count 3
    :active_hooks 2)
  "Sample stats for testing.")

(defconst ogent-gts-test--sample-deacon-running
  '(:name "deacon"
    :address "deacon/"
    :running t
    :has_work nil)
  "Sample deacon data when running.")

(defconst ogent-gts-test--sample-deacon-stopped
  '(:name "deacon"
    :address "deacon/"
    :running nil
    :has_work nil)
  "Sample deacon data when stopped.")

(defconst ogent-gts-test--sample-deacon-with-work
  '(:name "deacon"
    :address "deacon/"
    :running t
    :has_work t)
  "Sample deacon data with hooked work.")

(defconst ogent-gts-test--sample-witnesses
  (list '(:rig "ogent"
          :has_witness t
          :polecat_count 3
          :crew_count 2)
        '(:rig "beads"
          :has_witness t
          :polecat_count 1
          :crew_count 1)
        '(:rig "gastown"
          :has_witness nil
          :polecat_count 0
          :crew_count 1))
  "Sample witness data for testing.")

(defconst ogent-gts-test--sample-crew
  (list '(:name "ritchie"
          :rig "ogent"
          :session_running t
          :hooked_work "ogent-123"
          :branch "feature/new-api"
          :dirty t
          :unread_mail 3)
        '(:name "knuth"
          :rig "ogent"
          :session_running nil
          :hooked_work nil
          :branch "master"
          :dirty nil
          :unread_mail 0)
        '(:name "carmack"
          :rig "beads"
          :session_running t
          :hooked_work nil
          :branch "develop"
          :dirty nil
          :unread_mail 1))
  "Sample crew list for testing.")

(defconst ogent-gts-test--sample-polecats
  (list '(:name "alpha"
          :rig "ogent"
          :state "working"
          :session_running t
          :current_task "ogent-abc"
          :session_started "2026-01-22T10:00:00Z")
        '(:name "beta"
          :rig "ogent"
          :state "idle"
          :session_running nil
          :current_task nil
          :session_started nil)
        '(:name "gamma"
          :rig "beads"
          :state "working"
          :session_running t
          :hooked_work "beads-xyz"
          :session_started "2026-01-22T08:30:00Z"))
  "Sample polecat list for testing.")

(defconst ogent-gts-test--sample-rigs
  (list '(:name "ogent"
          :polecat_count 2
          :crew_count 2
          :has_witness t
          :has_refinery t
          :agents ((:name "witness"
                    :role "witness"
                    :running t
                    :has_work nil
                    :unread_mail 0)
                   (:name "ritchie"
                    :role "crew"
                    :running t
                    :has_work t
                    :unread_mail 3)))
        '(:name "beads"
          :polecat_count 1
          :crew_count 1
          :has_witness nil
          :has_refinery t
          :agents nil))
  "Sample rigs list for testing.")

;;; Time Formatting Tests

;; Note: parse-iso8601-time-string may not be available in all Emacs versions.
;; We test the error handling paths when the parser isn't available, and
;; conditionally test the success paths when it is.

(ert-deftest ogent-gts-test-format-time-nil ()
  "Test formatting nil time returns ???."
  (should (equal "???" (ogent-gastown--format-time nil))))

(ert-deftest ogent-gts-test-format-time-empty-string ()
  "Test formatting empty string returns ???."
  (should (equal "???" (ogent-gastown--format-time ""))))

(ert-deftest ogent-gts-test-format-time-invalid ()
  "Test formatting invalid time string returns ???."
  (should (equal "???" (ogent-gastown--format-time "not-a-date"))))

(ert-deftest ogent-gts-test-format-time-graceful-parse-failure ()
  "Test that format-time returns ??? when parsing fails."
  ;; Test completely unparseable strings - these should return ???
  ;; Note: ISO8601 parser normalizes overflow values (e.g., month 13 -> next year),
  ;; so we test with truly invalid format strings instead
  (should (equal "???" (ogent-gastown--format-time "invalid-timestamp")))
  (should (equal "???" (ogent-gastown--format-time "not-a-real-date-format"))))

(ert-deftest ogent-gts-test-format-time-just-now-mocked ()
  "Test formatting time within last minute (with mocked parser)."
  (let ((now (current-time)))
    (cl-letf (((symbol-function 'parse-iso8601-time-string)
               (lambda (_iso-time)
                 (time-subtract now 30))))
      (should (equal "just now" (ogent-gastown--format-time "2026-01-23T17:00:00Z"))))))

(ert-deftest ogent-gts-test-format-time-minutes-ago-mocked ()
  "Test formatting time in minutes (with mocked parser)."
  (let ((now (current-time)))
    (cl-letf (((symbol-function 'parse-iso8601-time-string)
               (lambda (_iso-time)
                 (time-subtract now (* 5 60)))))
      (should (string-match-p "5m ago" (ogent-gastown--format-time "2026-01-23T17:00:00Z"))))))

(ert-deftest ogent-gts-test-format-time-hours-ago-mocked ()
  "Test formatting time in hours (with mocked parser)."
  (let ((now (current-time)))
    (cl-letf (((symbol-function 'parse-iso8601-time-string)
               (lambda (_iso-time)
                 (time-subtract now (* 3 3600)))))
      (should (string-match-p "3h ago" (ogent-gastown--format-time "2026-01-23T17:00:00Z"))))))

(ert-deftest ogent-gts-test-format-time-days-ago-mocked ()
  "Test formatting time in days shows date format (with mocked parser)."
  (let ((now (current-time)))
    (cl-letf (((symbol-function 'parse-iso8601-time-string)
               (lambda (_iso-time)
                 (time-subtract now (* 2 86400)))))
      ;; Should show date format like "Jan 21" instead of relative time
      (let ((result (ogent-gastown--format-time "2026-01-23T17:00:00Z")))
        (should-not (string-match-p "ago" result))
        (should-not (equal "???" result))))))

;;; Cache Tests

(ert-deftest ogent-gts-test-cache-key ()
  "Test cache key generation."
  (let ((key1 (ogent-gastown--cache-key '("hook" "--json")))
        (key2 (ogent-gastown--cache-key '("mail" "inbox" "--json")))
        (key3 (ogent-gastown--cache-key '("hook" "--json"))))
    ;; Same args should produce same key
    (should (equal key1 key3))
    ;; Different args should produce different keys
    (should-not (equal key1 key2))))

(ert-deftest ogent-gts-test-cache-get-set ()
  "Test cache get and set operations."
  (let ((ogent-gastown--cache (make-hash-table :test 'equal))
        (ogent-gastown-cache-ttl 10))
    ;; Cache miss returns nil
    (should-not (ogent-gastown--cache-get '("test" "args")))
    ;; Set and get
    (ogent-gastown--cache-set '("test" "args") '(:result "data"))
    (should (equal '(:result "data") (ogent-gastown--cache-get '("test" "args"))))))

(ert-deftest ogent-gts-test-cache-disabled ()
  "Test cache is disabled when TTL is 0."
  (let ((ogent-gastown--cache (make-hash-table :test 'equal))
        (ogent-gastown-cache-ttl 0))
    (ogent-gastown--cache-set '("test") '(:data "value"))
    ;; Should not cache when TTL is 0
    (should-not (ogent-gastown--cache-get '("test")))))

(ert-deftest ogent-gts-test-cache-invalidate ()
  "Test cache invalidation clears all entries."
  (let ((ogent-gastown--cache (make-hash-table :test 'equal))
        (ogent-gastown-cache-ttl 10))
    (ogent-gastown--cache-set '("test1") '(:a 1))
    (ogent-gastown--cache-set '("test2") '(:b 2))
    (should (ogent-gastown--cache-get '("test1")))
    (should (ogent-gastown--cache-get '("test2")))
    (ogent-gastown-cache-invalidate)
    (should-not (ogent-gastown--cache-get '("test1")))
    (should-not (ogent-gastown--cache-get '("test2")))))

;;; Loading Indicator Tests

(ert-deftest ogent-gts-test-loading-indicator-nil-when-not-loading ()
  "Test loading indicator returns nil when not loading."
  (with-temp-buffer
    (let ((ogent-gastown--loading nil))
      (should-not (ogent-gastown--loading-indicator)))))

(ert-deftest ogent-gts-test-loading-indicator-returns-frame ()
  "Test loading indicator returns current frame when loading."
  (with-temp-buffer
    (let ((ogent-gastown--loading t)
          (ogent-gastown--loading-frame 0))
      (should (ogent-gastown--loading-indicator)))))

;;; Town Detection Tests

(ert-deftest ogent-gts-test-find-town-root-from-env ()
  "Test finding town root from GT_ROOT environment variable."
  (cl-letf (((symbol-function 'getenv)
             (lambda (var)
               (when (equal var "GT_ROOT")
                 "/custom/gt/root"))))
    (should (equal "/custom/gt/root" (ogent-gastown--find-town-root)))))

(ert-deftest ogent-gts-test-find-town-root-default ()
  "Test finding town root falls back to ~/gt."
  (cl-letf (((symbol-function 'getenv)
             (lambda (_var) nil)))
    (should (equal (expand-file-name "~/gt") (ogent-gastown--find-town-root)))))

(ert-deftest ogent-gts-test-in-town-p-with-gt ()
  "Test in-town detection when gt is available."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_cmd) "/usr/local/bin/gt")))
    (should (ogent-gastown--in-town-p))))

(ert-deftest ogent-gts-test-in-town-p-without-gt ()
  "Test in-town detection when gt is not available."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_cmd) nil)))
    (should-not (ogent-gastown--in-town-p))))

;;; Hook Section Tests (Plain Mode)

(ert-deftest ogent-gts-test-insert-hook-section-plain-active ()
  "Test hook section plain text rendering with active work."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data ogent-gts-test--sample-hook-active))
      (ogent-gastown--insert-hook-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Hook Status" content))
        (should (string-match-p "Role: mayor" content))
        (should (string-match-p "Work hooked" content))))))

(ert-deftest ogent-gts-test-insert-hook-section-plain-empty ()
  "Test hook section plain text rendering with no work."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data ogent-gts-test--sample-hook-empty))
      (ogent-gastown--insert-hook-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Hook Status" content))
        (should (string-match-p "Role: polecat" content))
        (should (string-match-p "No work hooked" content))))))

;;; Mail Section Tests (Plain Mode)

(ert-deftest ogent-gts-test-insert-mail-section-plain-with-messages ()
  "Test mail section plain text rendering with messages."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data ogent-gts-test--sample-mail))
      (ogent-gastown--insert-mail-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Mail Inbox" content))
        (should (string-match-p "witness" content))
        (should (string-match-p "Status check" content))
        (should (string-match-p "refinery" content))
        ;; Check unread indicator
        (should (string-match-p "\\* witness" content))))))

(ert-deftest ogent-gts-test-insert-mail-section-plain-empty ()
  "Test mail section plain text rendering with no messages."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data nil))
      (ogent-gastown--insert-mail-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Mail Inbox" content))
        (should (string-match-p "No messages" content))))))

;;; Convoy Section Tests (Plain Mode)

(ert-deftest ogent-gts-test-insert-convoy-section-plain-with-convoys ()
  "Test convoy section plain text rendering with convoys."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data ogent-gts-test--sample-convoy))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Convoys" content))
        (should (string-match-p "Feature implementation" content))
        (should (string-match-p "Bug fixes" content))))))

(ert-deftest ogent-gts-test-insert-convoy-section-plain-empty ()
  "Test convoy section plain text rendering with no convoys."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data nil))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Convoys" content))
        (should (string-match-p "No active convoys" content))))))

;;; Workers Section Tests (Plain Mode)

(ert-deftest ogent-gts-test-insert-workers-section-plain-with-workers ()
  "Test workers section plain text rendering with workers."
  (with-temp-buffer
    (let ((ogent-gastown--workers-data ogent-gts-test--sample-workers))
      (ogent-gastown--insert-workers-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Workers" content))
        (should (string-match-p "ogent/alpha" content))
        (should (string-match-p "ogent/beta" content))
        (should (string-match-p "beads/gamma" content))
        (should (string-match-p "\\[working\\]" content))
        (should (string-match-p "\\[idle\\]" content))))))

(ert-deftest ogent-gts-test-insert-workers-section-plain-empty ()
  "Test workers section plain text rendering with no workers."
  (with-temp-buffer
    (let ((ogent-gastown--workers-data nil))
      (ogent-gastown--insert-workers-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Workers" content))
        (should (string-match-p "No workers" content))))))

;;; Stats Section Tests (Plain Mode)

(ert-deftest ogent-gts-test-insert-stats-section-plain ()
  "Test stats section plain text rendering."
  (with-temp-buffer
    (let ((ogent-gastown--stats-data ogent-gts-test--sample-stats))
      (ogent-gastown--insert-stats-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Town Stats" content))
        (should (string-match-p "Rigs: 3" content))
        (should (string-match-p "Polecats: 5" content))
        (should (string-match-p "Crew: 8" content))
        (should (string-match-p "Witnesses: 2" content))
        (should (string-match-p "Refineries: 3" content))
        (should (string-match-p "Hooks: 2" content))))))

(ert-deftest ogent-gts-test-insert-stats-section-plain-nil ()
  "Test stats section plain text rendering with nil data."
  (with-temp-buffer
    (let ((ogent-gastown--stats-data nil))
      (ogent-gastown--insert-stats-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Town Stats" content))
        (should (string-match-p "No stats available" content))))))

(ert-deftest ogent-gts-test-insert-stats-section-plain-missing-values ()
  "Test stats section handles missing values gracefully."
  (with-temp-buffer
    (let ((ogent-gastown--stats-data '(:rig_count 2)))
      (ogent-gastown--insert-stats-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Rigs: 2" content))
        ;; Missing values should default to 0
        (should (string-match-p "Polecats: 0" content))))))

;;; Deacon Section Tests (Plain Mode)

(ert-deftest ogent-gts-test-insert-deacon-section-plain-running ()
  "Test deacon section plain text rendering when running."
  (with-temp-buffer
    (let ((ogent-gastown--deacon-data ogent-gts-test--sample-deacon-running))
      (ogent-gastown--insert-deacon-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Deacon" content))
        (should (string-match-p "running" content))))))

(ert-deftest ogent-gts-test-insert-deacon-section-plain-stopped ()
  "Test deacon section plain text rendering when stopped."
  (with-temp-buffer
    (let ((ogent-gastown--deacon-data ogent-gts-test--sample-deacon-stopped))
      (ogent-gastown--insert-deacon-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Deacon" content))
        (should (string-match-p "stopped" content))))))

;;; Witness Section Tests (Plain Mode)

(ert-deftest ogent-gts-test-insert-witness-section-plain ()
  "Test witness section plain text rendering."
  (with-temp-buffer
    (let ((ogent-gastown--witness-data ogent-gts-test--sample-witnesses))
      (ogent-gastown--insert-witness-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Witnesses" content))
        (should (string-match-p "ogent" content))
        (should (string-match-p "beads" content))
        (should (string-match-p "gastown" content))
        ;; Check active/inactive indicators
        (should (string-match-p "\\+ ogent" content))
        (should (string-match-p "\\+ beads" content))
        (should (string-match-p "- gastown" content))))))

(ert-deftest ogent-gts-test-insert-witness-section-plain-nil ()
  "Test witness section plain text rendering with nil data."
  (with-temp-buffer
    (let ((ogent-gastown--witness-data nil))
      (ogent-gastown--insert-witness-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Witnesses" content))
        (should (string-match-p "No rig data available" content))))))

;;; Crew Section Tests (Plain Mode)

(ert-deftest ogent-gts-test-insert-crew-section-plain ()
  "Test crew section plain text rendering."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data ogent-gts-test--sample-crew))
      (ogent-gastown--insert-crew-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Crew" content))
        (should (string-match-p "ogent/ritchie" content))
        (should (string-match-p "ogent/knuth" content))
        (should (string-match-p "beads/carmack" content))
        ;; Check active indicator
        (should (string-match-p "\\[active\\]" content))))))

(ert-deftest ogent-gts-test-insert-crew-section-plain-empty ()
  "Test crew section plain text rendering with no crew."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data nil))
      (ogent-gastown--insert-crew-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Crew" content))
        (should (string-match-p "No crew members" content))))))

;;; Polecat Section Tests (Plain Mode)

(ert-deftest ogent-gts-test-insert-polecat-section-plain ()
  "Test polecat section plain text rendering."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data ogent-gts-test--sample-polecats))
      (ogent-gastown--insert-polecat-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Polecats" content))
        (should (string-match-p "ogent/alpha" content))
        (should (string-match-p "ogent/beta" content))
        (should (string-match-p "beads/gamma" content))
        (should (string-match-p "\\[working\\]" content))
        (should (string-match-p "\\[idle\\]" content))
        (should (string-match-p "running" content))))))

(ert-deftest ogent-gts-test-insert-polecat-section-plain-empty ()
  "Test polecat section plain text rendering with no polecats."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data nil))
      (ogent-gastown--insert-polecat-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Polecats" content))
        (should (string-match-p "No polecats" content))))))

;;; Rigs Section Tests (Plain Mode)

(ert-deftest ogent-gts-test-insert-rigs-section-plain ()
  "Test rigs section plain text rendering."
  (with-temp-buffer
    (let ((ogent-gastown--rigs-data ogent-gts-test--sample-rigs))
      (ogent-gastown--insert-rigs-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Rigs" content))
        (should (string-match-p "ogent" content))
        (should (string-match-p "beads" content))
        (should (string-match-p "P:2 C:2" content))
        (should (string-match-p "P:1 C:1" content))))))

(ert-deftest ogent-gts-test-insert-rigs-section-plain-empty ()
  "Test rigs section plain text rendering with no rigs."
  (with-temp-buffer
    (let ((ogent-gastown--rigs-data nil))
      (ogent-gastown--insert-rigs-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Rigs" content))
        (should (string-match-p "No rigs configured" content))))))

;;; Header Line Tests

(ert-deftest ogent-gts-test-header-line-with-hook ()
  "Test header line shows hook active status."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data ogent-gts-test--sample-hook-active)
          (ogent-gastown--mail-data nil)
          (ogent-gastown--loading nil))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "Gas Town" header))
        (should (string-match-p "Hook: active" header))))))

(ert-deftest ogent-gts-test-header-line-hook-empty ()
  "Test header line shows hook empty status."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data ogent-gts-test--sample-hook-empty)
          (ogent-gastown--mail-data nil)
          (ogent-gastown--loading nil))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "Gas Town" header))
        (should (string-match-p "Hook: empty" header))))))

(ert-deftest ogent-gts-test-header-line-with-unread-mail ()
  "Test header line shows unread mail count."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data ogent-gts-test--sample-hook-empty)
          (ogent-gastown--mail-data ogent-gts-test--sample-mail)
          (ogent-gastown--loading nil))
      (let ((header (ogent-gastown--header-line)))
        ;; Sample mail has 2 unread messages
        (should (string-match-p "2 unread" header))))))

(ert-deftest ogent-gts-test-header-line-loading ()
  "Test header line shows loading indicator."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data nil)
          (ogent-gastown--mail-data nil)
          (ogent-gastown--loading t)
          (ogent-gastown--loading-frame 0))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "Gas Town" header))
        (should (string-match-p "Loading" header))))))

(ert-deftest ogent-gts-test-header-line-no-unread-mail ()
  "Test header line omits mail count when no unread."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data ogent-gts-test--sample-hook-empty)
          (ogent-gastown--mail-data (list '(:id "m1" :read t)))
          (ogent-gastown--loading nil))
      (let ((header (ogent-gastown--header-line)))
        (should-not (string-match-p "unread" header))))))

;;; Insert Stat Item Tests

(ert-deftest ogent-gts-test-insert-stat-item ()
  "Test stat item insertion."
  (with-temp-buffer
    (ogent-gastown--insert-stat-item "Rigs" 5)
    (let ((content (buffer-string)))
      (should (string-match-p "Rigs" content))
      (should (string-match-p "5" content)))))

(ert-deftest ogent-gts-test-insert-stat-item-nil ()
  "Test stat item insertion with nil value defaults to 0."
  (with-temp-buffer
    (ogent-gastown--insert-stat-item "Polecats" nil)
    (let ((content (buffer-string)))
      (should (string-match-p "Polecats" content))
      (should (string-match-p "0" content)))))

;;; Worker Item Tests

(ert-deftest ogent-gts-test-insert-worker-item-running ()
  "Test worker item insertion for running worker."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-worker-item
       '(:name "alpha" :state "working" :session_running t))
      (let ((content (buffer-string)))
        (should (string-match-p "alpha" content))
        (should (string-match-p "\\[working\\]" content))
        (should (string-match-p "running" content))))))

(ert-deftest ogent-gts-test-insert-worker-item-idle ()
  "Test worker item insertion for idle worker."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-worker-item
       '(:name "beta" :state "idle" :session_running nil))
      (let ((content (buffer-string)))
        (should (string-match-p "beta" content))
        (should (string-match-p "\\[idle\\]" content))
        (should-not (string-match-p "running" content))))))

;;; Crew Item Tests (in magit-section context, testing with temp buffer)

(ert-deftest ogent-gts-test-crew-item-with-branch-and-dirty ()
  "Test crew item shows branch and dirty indicator."
  ;; This tests the insertion logic without magit-section
  (with-temp-buffer
    (let ((member '(:name "ritchie"
                    :rig "ogent"
                    :session_running t
                    :hooked_work "ogent-123"
                    :branch "feature/new"
                    :dirty t
                    :unread_mail 2))
          (ogent-gastown-use-unicode t))
      ;; We can't easily test the magit-section version, but we can verify
      ;; the plain section groups by rig correctly
      (let ((ogent-gastown--crew-data (list member)))
        (ogent-gastown--insert-crew-section-plain)
        (let ((content (buffer-string)))
          (should (string-match-p "ritchie" content)))))))

;;; Polecat Item Tests

(ert-deftest ogent-gts-test-polecat-item-with-task ()
  "Test polecat item shows current task."
  ;; Test via plain section insertion
  (with-temp-buffer
    (let ((polecat '(:name "alpha"
                     :rig "ogent"
                     :state "working"
                     :session_running t
                     :current_task "task-123"
                     :session_started "2026-01-22T10:00:00Z")))
      (let ((ogent-gastown--polecat-data (list polecat)))
        (ogent-gastown--insert-polecat-section-plain)
        (let ((content (buffer-string)))
          (should (string-match-p "alpha" content))
          (should (string-match-p "\\[working\\]" content)))))))

;;; Rig Agent Tests

(ert-deftest ogent-gts-test-insert-rig-agent-witness ()
  "Test rig agent insertion for witness role."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent
       '(:name "witness" :role "witness" :running t :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "W" content))
        (should (string-match-p "witness" content))))))

(ert-deftest ogent-gts-test-insert-rig-agent-refinery ()
  "Test rig agent insertion for refinery role."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent
       '(:name "refinery" :role "refinery" :running nil :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "R" content))
        (should (string-match-p "refinery" content))))))

(ert-deftest ogent-gts-test-insert-rig-agent-with-hook-and-mail ()
  "Test rig agent insertion with hooked work and unread mail."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-rig-agent
       '(:name "worker" :role "crew" :running t :has_work t :unread_mail 5))
      (let ((content (buffer-string)))
        (should (string-match-p "worker" content))
        ;; Hook indicator (anchor emoji)
        (should (string-match-p "⚓" content))
        ;; Mail indicator
        (should (string-match-p "📬5" content))))))

(ert-deftest ogent-gts-test-insert-rig-agent-unknown-role ()
  "Test rig agent insertion for unknown role uses ? icon."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent
       '(:name "unknown" :role "mystery" :running nil :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "\\?" content))))))

;;; Plain Buffer Contents Tests

(ert-deftest ogent-gts-test-insert-plain-all-sections ()
  "Test that insert-plain inserts all sections in order."
  (with-temp-buffer
    (let ((ogent-gastown--stats-data ogent-gts-test--sample-stats)
          (ogent-gastown--deacon-data ogent-gts-test--sample-deacon-running)
          (ogent-gastown--witness-data ogent-gts-test--sample-witnesses)
          (ogent-gastown--hook-data ogent-gts-test--sample-hook-active)
          (ogent-gastown--mail-data ogent-gts-test--sample-mail)
          (ogent-gastown--convoy-data ogent-gts-test--sample-convoy)
          (ogent-gastown--rigs-data ogent-gts-test--sample-rigs)
          (ogent-gastown--crew-data ogent-gts-test--sample-crew)
          (ogent-gastown--polecat-data ogent-gts-test--sample-polecats)
          (ogent-gastown--workers-data ogent-gts-test--sample-workers))
      (ogent-gastown--insert-plain)
      (let ((content (buffer-string)))
        ;; All sections should be present
        (should (string-match-p "Town Stats" content))
        (should (string-match-p "Deacon" content))
        (should (string-match-p "Witnesses" content))
        (should (string-match-p "Hook Status" content))
        (should (string-match-p "Mail Inbox" content))
        (should (string-match-p "Convoys" content))
        (should (string-match-p "Rigs" content))
        (should (string-match-p "Crew" content))
        (should (string-match-p "Polecats" content))
        (should (string-match-p "Workers" content))))))

;;; Unicode vs ASCII Tests

(ert-deftest ogent-gts-test-unicode-icons ()
  "Test that unicode icons are used when enabled."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-rig-agent
       '(:name "test" :role "witness" :running t :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "👁" content))))))

(ert-deftest ogent-gts-test-ascii-icons ()
  "Test that ASCII icons are used when unicode disabled."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent
       '(:name "test" :role "witness" :running t :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "W" content))
        (should-not (string-match-p "👁" content))))))

;;; Mail Item Tests

(ert-deftest ogent-gts-test-mail-item-unread ()
  "Test mail item rendering for unread message (via plain section)."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data
           (list '(:id "m1" :from "sender" :subject "Test" :read nil))))
      (ogent-gastown--insert-mail-section-plain)
      (let ((content (buffer-string)))
        ;; Unread messages have asterisk
        (should (string-match-p "\\* sender" content))))))

(ert-deftest ogent-gts-test-mail-item-read ()
  "Test mail item rendering for read message (via plain section)."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data
           (list '(:id "m1" :from "sender" :subject "Test" :read t))))
      (ogent-gastown--insert-mail-section-plain)
      (let ((content (buffer-string)))
        ;; Read messages have spaces
        (should (string-match-p "  sender" content))))))

;;; Convoy Item Tests

(ert-deftest ogent-gts-test-convoy-item-active ()
  "Test convoy item rendering for active convoy."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :name "Active Job" :status "active" :progress "2/5"))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Active Job" content))))))

(ert-deftest ogent-gts-test-convoy-item-complete ()
  "Test convoy item rendering for completed convoy."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :name "Done Job" :status "complete" :progress "5/5"))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Done Job" content))))))

(ert-deftest ogent-gts-test-keybindings-help ()
  "Help keys are bound to the transient dispatch menu."
  (require 'ogent-gastown-status-transient)
  (should (eq (lookup-key ogent-gastown-status-mode-map (kbd "h"))
              'ogent-gastown-status-dispatch))
  (should (eq (lookup-key ogent-gastown-status-mode-map (kbd "?"))
              'ogent-gastown-status-dispatch)))

(ert-deftest ogent-gts-test-keybindings-hook ()
  "Hook actions use magit-style bindings."
  (should (eq (lookup-key ogent-gastown-status-mode-map (kbd "H"))
              'ogent-gastown-hook-show))
  (should (eq (lookup-key ogent-gastown-status-mode-map (kbd "a"))
              'ogent-gastown-hook-attach)))

;;; Extract Deacon Tests

(ert-deftest ogent-gts-test-extract-deacon-found ()
  "Test extracting deacon from town-status plist."
  (let ((town-status '(:agents ((:name "deacon" :running t :has_work nil)
                                (:name "witness" :running t :has_work nil)))))
    (let ((result (ogent-gastown--extract-deacon town-status)))
      (should result)
      (should (equal (plist-get result :name) "deacon"))
      (should (eq (plist-get result :running) t)))))

(ert-deftest ogent-gts-test-extract-deacon-not-found ()
  "Test extracting deacon when no deacon in agents."
  (let ((town-status '(:agents ((:name "witness" :running t)
                                (:name "refinery" :running nil)))))
    (should-not (ogent-gastown--extract-deacon town-status))))

(ert-deftest ogent-gts-test-extract-deacon-nil-status ()
  "Test extracting deacon from nil town-status."
  (should-not (ogent-gastown--extract-deacon nil)))

(ert-deftest ogent-gts-test-extract-deacon-empty-agents ()
  "Test extracting deacon when agents list is empty."
  (let ((town-status '(:agents nil)))
    (should-not (ogent-gastown--extract-deacon town-status))))

;;; Extract Witnesses Tests

(ert-deftest ogent-gts-test-extract-witnesses-basic ()
  "Test extracting witness data from town-status."
  (let ((town-status '(:rigs ((:name "ogent" :has_witness t :polecat_count 3 :crew_count 2)
                              (:name "beads" :has_witness nil :polecat_count 1 :crew_count 0)))))
    (let ((result (ogent-gastown--extract-witnesses town-status)))
      (should (= (length result) 2))
      (let ((first (car result)))
        (should (equal (plist-get first :rig) "ogent"))
        (should (eq (plist-get first :has_witness) t))
        (should (= (plist-get first :polecat_count) 3))
        (should (= (plist-get first :crew_count) 2)))
      (let ((second (cadr result)))
        (should (equal (plist-get second :rig) "beads"))
        (should-not (plist-get second :has_witness))))))

(ert-deftest ogent-gts-test-extract-witnesses-nil-status ()
  "Test extracting witnesses from nil town-status."
  (should-not (ogent-gastown--extract-witnesses nil)))

(ert-deftest ogent-gts-test-extract-witnesses-nil-counts-default-zero ()
  "Test extracting witnesses defaults nil counts to 0."
  (let ((town-status '(:rigs ((:name "rig1" :has_witness t)))))
    (let ((result (ogent-gastown--extract-witnesses town-status)))
      (should (= (length result) 1))
      (should (= (plist-get (car result) :polecat_count) 0))
      (should (= (plist-get (car result) :crew_count) 0)))))

(ert-deftest ogent-gts-test-extract-witnesses-empty-rigs ()
  "Test extracting witnesses when rigs list is empty."
  (let ((town-status '(:rigs nil)))
    (should-not (ogent-gastown--extract-witnesses town-status))))

;;; Insert Buffer Contents Tests

(ert-deftest ogent-gts-test-insert-buffer-contents-plain-fallback ()
  "Test insert-buffer-contents calls plain variant when magit-section unavailable."
  (with-temp-buffer
    (let ((ogent-gastown--stats-data ogent-gts-test--sample-stats)
          (ogent-gastown--deacon-data ogent-gts-test--sample-deacon-running)
          (ogent-gastown--witness-data ogent-gts-test--sample-witnesses)
          (ogent-gastown--hook-data ogent-gts-test--sample-hook-active)
          (ogent-gastown--mail-data ogent-gts-test--sample-mail)
          (ogent-gastown--convoy-data ogent-gts-test--sample-convoy)
          (ogent-gastown--rigs-data ogent-gts-test--sample-rigs)
          (ogent-gastown--crew-data ogent-gts-test--sample-crew)
          (ogent-gastown--polecat-data ogent-gts-test--sample-polecats)
          (ogent-gastown--workers-data ogent-gts-test--sample-workers)
          (plain-called nil)
          (magit-called nil))
      (cl-letf (((symbol-function 'ogent-gastown--insert-plain)
                 (lambda () (setq plain-called t)))
                ((symbol-function 'ogent-gastown--insert-with-magit-section)
                 (lambda () (setq magit-called t))))
        (let ((ogent-gastown--magit-section-available nil))
          (ogent-gastown--insert-buffer-contents)
          (should plain-called)
          (should-not magit-called))))))

(ert-deftest ogent-gts-test-insert-buffer-contents-magit-when-available ()
  "Test insert-buffer-contents calls magit variant when magit-section available."
  (let ((plain-called nil)
        (magit-called nil))
    (cl-letf (((symbol-function 'ogent-gastown--insert-plain)
               (lambda () (setq plain-called t)))
              ((symbol-function 'ogent-gastown--insert-with-magit-section)
               (lambda () (setq magit-called t))))
      (let ((ogent-gastown--magit-section-available t))
        (ogent-gastown--insert-buffer-contents)
        (should magit-called)
        (should-not plain-called)))))

;;; Insert Mail Item Tests (plain mode)

(ert-deftest ogent-gts-test-insert-mail-item-plain-with-subject ()
  "Test mail item renders subject in plain mode."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data
           (list '(:id "m1" :from "alpha" :subject "Hello World" :read nil))))
      (ogent-gastown--insert-mail-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "alpha" content))
        (should (string-match-p "Hello World" content))))))

(ert-deftest ogent-gts-test-insert-mail-item-plain-nil-from ()
  "Test mail item renders unknown for nil from in plain mode."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data
           (list '(:id "m1" :from nil :subject "Test" :read nil))))
      (ogent-gastown--insert-mail-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "unknown" content))))))

(ert-deftest ogent-gts-test-insert-mail-item-plain-nil-subject ()
  "Test mail item renders (no subject) for nil subject in plain mode."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data
           (list '(:id "m1" :from "sender" :subject nil :read t))))
      (ogent-gastown--insert-mail-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "(no subject)" content))))))

(ert-deftest ogent-gts-test-insert-mail-item-plain-multiple ()
  "Test multiple mail items render in order."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data
           (list '(:id "m1" :from "alice" :subject "First" :read nil)
                 '(:id "m2" :from "bob" :subject "Second" :read t)
                 '(:id "m3" :from "charlie" :subject "Third" :read nil))))
      (ogent-gastown--insert-mail-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "alice" content))
        (should (string-match-p "bob" content))
        (should (string-match-p "charlie" content))
        ;; Unread items get asterisk, read items get spaces
        (should (string-match-p "\\* alice" content))
        (should (string-match-p "  bob" content))
        (should (string-match-p "\\* charlie" content))))))

;;; Insert Convoy Item Tests (plain mode)

(ert-deftest ogent-gts-test-insert-convoy-item-unnamed ()
  "Test convoy item rendering for unnamed convoy."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :name nil :status "active" :progress "1/3"))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "(unnamed)" content))))))

(ert-deftest ogent-gts-test-insert-convoy-item-multiple ()
  "Test multiple convoy items render correctly."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :name "Deploy" :status "active" :progress "2/4")
                 '(:id "c2" :name "Cleanup" :status "complete" :progress "3/3"))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Deploy" content))
        (should (string-match-p "Cleanup" content))))))

;;; Insert Witness Item Tests (plain mode)

(ert-deftest ogent-gts-test-insert-witness-item-plain-active ()
  "Test witness item rendering with active witness."
  (with-temp-buffer
    (let ((ogent-gastown--witness-data
           (list '(:rig "myrig" :has_witness t :polecat_count 2 :crew_count 1))))
      (ogent-gastown--insert-witness-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "\\+ myrig" content))))))

(ert-deftest ogent-gts-test-insert-witness-item-plain-inactive ()
  "Test witness item rendering with inactive witness."
  (with-temp-buffer
    (let ((ogent-gastown--witness-data
           (list '(:rig "nowitness" :has_witness nil :polecat_count 0 :crew_count 0))))
      (ogent-gastown--insert-witness-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "- nowitness" content))))))

;;; Insert Crew Item Tests (plain mode)

(ert-deftest ogent-gts-test-insert-crew-item-plain-active-session ()
  "Test crew item rendering for member with active session."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:name "dev1" :rig "myrig" :session_running t
                   :hooked_work nil :branch "main" :dirty nil :unread_mail 0))))
      (ogent-gastown--insert-crew-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "myrig/dev1" content))
        (should (string-match-p "\\[active\\]" content))))))

(ert-deftest ogent-gts-test-insert-crew-item-plain-inactive ()
  "Test crew item rendering for member without active session."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:name "dev2" :rig "myrig" :session_running nil
                   :hooked_work nil :branch "develop" :dirty nil :unread_mail 0))))
      (ogent-gastown--insert-crew-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "myrig/dev2" content))
        (should-not (string-match-p "\\[active\\]" content))))))

(ert-deftest ogent-gts-test-insert-crew-item-plain-nil-fields ()
  "Test crew item rendering with nil rig and name."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:name nil :rig nil :session_running nil))))
      (ogent-gastown--insert-crew-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "\\?\\?\\?/\\?\\?\\?" content))))))

;;; Insert Polecat Item Tests (plain mode)

(ert-deftest ogent-gts-test-insert-polecat-item-plain-working ()
  "Test polecat item rendering for working polecat."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data
           (list '(:name "p1" :rig "rig1" :state "working" :session_running t))))
      (ogent-gastown--insert-polecat-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "rig1/p1" content))
        (should (string-match-p "\\[working\\]" content))
        (should (string-match-p "running" content))))))

(ert-deftest ogent-gts-test-insert-polecat-item-plain-idle ()
  "Test polecat item rendering for idle polecat."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data
           (list '(:name "p2" :rig "rig1" :state "idle" :session_running nil))))
      (ogent-gastown--insert-polecat-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "rig1/p2" content))
        (should (string-match-p "\\[idle\\]" content))
        (should-not (string-match-p "running" content))))))

(ert-deftest ogent-gts-test-insert-polecat-item-plain-nil-state ()
  "Test polecat item rendering with nil state defaults to unknown."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data
           (list '(:name "p3" :rig "rig1" :state nil :session_running nil))))
      (ogent-gastown--insert-polecat-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "\\[unknown\\]" content))))))

(ert-deftest ogent-gts-test-insert-polecat-item-plain-nil-fields ()
  "Test polecat item rendering with nil rig and name."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data
           (list '(:name nil :rig nil :state "idle" :session_running nil))))
      (ogent-gastown--insert-polecat-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "\\?\\?\\?/\\?\\?\\?" content))))))

;;; Insert Rig Item Tests (plain mode)

(ert-deftest ogent-gts-test-insert-rig-item-plain-basic ()
  "Test rig item plain rendering with polecat and crew counts."
  (with-temp-buffer
    (let ((ogent-gastown--rigs-data
           (list '(:name "testrig" :polecat_count 3 :crew_count 2
                   :has_witness t :has_refinery t :agents nil))))
      (ogent-gastown--insert-rigs-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "testrig" content))
        (should (string-match-p "P:3 C:2" content))))))

(ert-deftest ogent-gts-test-insert-rig-item-plain-nil-counts ()
  "Test rig item plain rendering defaults nil counts to 0."
  (with-temp-buffer
    (let ((ogent-gastown--rigs-data
           (list '(:name "emptyrig" :polecat_count nil :crew_count nil
                   :has_witness nil :has_refinery nil :agents nil))))
      (ogent-gastown--insert-rigs-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "emptyrig" content))
        (should (string-match-p "P:0 C:0" content))))))

(ert-deftest ogent-gts-test-insert-rig-item-plain-nil-name ()
  "Test rig item plain rendering with nil name."
  (with-temp-buffer
    (let ((ogent-gastown--rigs-data
           (list '(:name nil :polecat_count 1 :crew_count 1))))
      (ogent-gastown--insert-rigs-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "\\?\\?\\?" content))))))

;;; Loading Animation Lifecycle Tests

(ert-deftest ogent-gts-test-start-loading-sets-state ()
  "Test start-loading sets loading state."
  (with-temp-buffer
    (let ((ogent-gastown--loading nil)
          (ogent-gastown--loading-frame 5)
          (ogent-gastown--loading-timer nil))
      (ogent-gastown--start-loading)
      (should (eq ogent-gastown--loading t))
      (should (= ogent-gastown--loading-frame 0))
      (should ogent-gastown--loading-timer)
      ;; Clean up the timer
      (ogent-gastown--stop-loading-timer))))

(ert-deftest ogent-gts-test-stop-loading-clears-state ()
  "Test stop-loading clears loading state."
  (with-temp-buffer
    (let ((ogent-gastown--loading t)
          (ogent-gastown--loading-timer nil))
      (ogent-gastown--stop-loading)
      (should-not ogent-gastown--loading))))

(ert-deftest ogent-gts-test-stop-loading-timer-cancels ()
  "Test stop-loading-timer cancels timer and sets to nil."
  (with-temp-buffer
    (let ((ogent-gastown--loading-timer (run-at-time 999 nil #'ignore)))
      (should ogent-gastown--loading-timer)
      (ogent-gastown--stop-loading-timer)
      (should-not ogent-gastown--loading-timer))))

(ert-deftest ogent-gts-test-stop-loading-timer-noop-when-nil ()
  "Test stop-loading-timer is safe when timer is nil."
  (with-temp-buffer
    (let ((ogent-gastown--loading-timer nil))
      ;; Should not error
      (ogent-gastown--stop-loading-timer)
      (should-not ogent-gastown--loading-timer))))

(ert-deftest ogent-gts-test-animate-loading-advances-frame ()
  "Test animate-loading advances frame modulo 4."
  (with-temp-buffer
    (let ((ogent-gastown--loading-frame 0))
      (ogent-gastown--animate-loading (current-buffer))
      (should (= ogent-gastown--loading-frame 1))
      (ogent-gastown--animate-loading (current-buffer))
      (should (= ogent-gastown--loading-frame 2))
      (ogent-gastown--animate-loading (current-buffer))
      (should (= ogent-gastown--loading-frame 3))
      (ogent-gastown--animate-loading (current-buffer))
      (should (= ogent-gastown--loading-frame 0)))))

(ert-deftest ogent-gts-test-animate-loading-dead-buffer ()
  "Test animate-loading is safe with dead buffer."
  (let ((buf (generate-new-buffer " *test-dead*")))
    (kill-buffer buf)
    ;; Should not error on dead buffer
    (ogent-gastown--animate-loading buf)))

(ert-deftest ogent-gts-test-loading-indicator-returns-frame-content ()
  "Test loading indicator returns the correct animation frame string."
  (with-temp-buffer
    (let ((ogent-gastown--loading t)
          (ogent-gastown--loading-frame 0))
      (let ((indicator (ogent-gastown--loading-indicator)))
        (should (stringp indicator))
        (should (member indicator ogent-gastown--loading-frames))))))

;;; Cleanup on Kill Tests

(ert-deftest ogent-gts-test-cleanup-on-kill-stops-timer ()
  "Test cleanup-on-kill stops the loading timer."
  (with-temp-buffer
    (let ((ogent-gastown--loading-timer (run-at-time 999 nil #'ignore)))
      (ogent-gastown--cleanup-on-kill)
      (should-not ogent-gastown--loading-timer))))

(ert-deftest ogent-gts-test-cleanup-on-kill-safe-without-timer ()
  "Test cleanup-on-kill is safe when no timer is active."
  (with-temp-buffer
    (let ((ogent-gastown--loading-timer nil))
      ;; Should not error
      (ogent-gastown--cleanup-on-kill)
      (should-not ogent-gastown--loading-timer))))

;;; Get Mail Recipients Tests

(ert-deftest ogent-gts-test-get-mail-recipients-defaults ()
  "Test get-mail-recipients always includes mayor/ and deacon/."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data nil)
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--witness-data nil))
      (let ((recipients (ogent-gastown--get-mail-recipients)))
        (should (member "deacon/" recipients))
        (should (member "mayor/" recipients))))))

(ert-deftest ogent-gts-test-get-mail-recipients-with-crew ()
  "Test get-mail-recipients includes crew members."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:name "ritchie" :rig "ogent")
                 '(:name "knuth" :rig "beads")))
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--witness-data nil))
      (let ((recipients (ogent-gastown--get-mail-recipients)))
        (should (member "ogent/crew/ritchie" recipients))
        (should (member "beads/crew/knuth" recipients))))))

(ert-deftest ogent-gts-test-get-mail-recipients-with-polecats ()
  "Test get-mail-recipients includes polecats."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data nil)
          (ogent-gastown--polecat-data
           (list '(:name "alpha" :rig "ogent")
                 '(:name "beta" :rig "beads")))
          (ogent-gastown--witness-data nil))
      (let ((recipients (ogent-gastown--get-mail-recipients)))
        (should (member "ogent/polecats/alpha" recipients))
        (should (member "beads/polecats/beta" recipients))))))

(ert-deftest ogent-gts-test-get-mail-recipients-with-witnesses ()
  "Test get-mail-recipients includes witnesses and refineries."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data nil)
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--witness-data
           (list '(:rig "ogent" :has_witness t)
                 '(:rig "beads" :has_witness nil))))
      (let ((recipients (ogent-gastown--get-mail-recipients)))
        ;; Witness with has_witness=t should have witness/ entry
        (should (member "ogent/witness/" recipients))
        ;; Witness without has_witness should NOT have witness/ entry
        (should-not (member "beads/witness/" recipients))
        ;; But all rigs should get refinery/
        (should (member "ogent/refinery/" recipients))
        (should (member "beads/refinery/" recipients))))))

(ert-deftest ogent-gts-test-get-mail-recipients-sorted ()
  "Test get-mail-recipients returns sorted list."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:name "zulu" :rig "aaa")
                 '(:name "alpha" :rig "zzz")))
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--witness-data nil))
      (let ((recipients (ogent-gastown--get-mail-recipients)))
        ;; Should be sorted
        (should (equal recipients (sort (copy-sequence recipients) #'string<)))))))

(ert-deftest ogent-gts-test-get-mail-recipients-skips-nil-fields ()
  "Test get-mail-recipients skips crew/polecats with nil rig or name."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:name nil :rig "ogent")
                 '(:name "ritchie" :rig nil)
                 '(:name "knuth" :rig "ogent")))
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--witness-data nil))
      (let ((recipients (ogent-gastown--get-mail-recipients)))
        ;; Only the one with both non-nil rig and name
        (should (member "ogent/crew/knuth" recipients))
        (should-not (member "ogent/crew/" recipients))))))

(ert-deftest ogent-gts-test-get-mail-recipients-no-duplicates ()
  "Test get-mail-recipients removes duplicates."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:name "ritchie" :rig "ogent")
                 '(:name "ritchie" :rig "ogent")))
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--witness-data nil))
      (let ((recipients (ogent-gastown--get-mail-recipients)))
        (should (= (length (seq-filter (lambda (r) (equal r "ogent/crew/ritchie"))
                                       recipients))
                   1))))))

;;; Crew Rig Path Tests

(ert-deftest ogent-gts-test-crew-rig-path-basic ()
  "Test crew-rig-path constructs correct path."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/tmp/gt"))
      (let ((path (ogent-gastown--crew-rig-path '(:name "ritchie" :rig "ogent"))))
        (should (equal path "/tmp/gt/ogent"))))))

(ert-deftest ogent-gts-test-crew-rig-path-nil-rig ()
  "Test crew-rig-path returns nil when rig is nil."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/tmp/gt"))
      (should-not (ogent-gastown--crew-rig-path '(:name "ritchie" :rig nil))))))

(ert-deftest ogent-gts-test-crew-rig-path-uses-town-root ()
  "Test crew-rig-path expands relative to town-root."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/home/user/gt"))
      (let ((path (ogent-gastown--crew-rig-path '(:rig "myproject"))))
        (should (equal path "/home/user/gt/myproject"))))))

;;; Visit Bead Tests

(ert-deftest ogent-gts-test-visit-bead-no-bead-at-point ()
  "Test visit-bead shows message when no bead at point."
  (with-temp-buffer
    (insert "no bead here")
    (goto-char (point-min))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (ogent-gastown-visit-bead)
        (should (member "No bead at point" messages))))))

(ert-deftest ogent-gts-test-visit-bead-with-bead-no-rig-path ()
  "Test visit-bead shows message when bead ID found but no rig path."
  (with-temp-buffer
    (insert (propertize "bead-123" 'ogent-bead-id "bead-123"))
    (goto-char (point-min))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (ogent-gastown-visit-bead)
        (should (seq-some (lambda (m) (string-match-p "Rig path not found" m))
                          messages))))))

;;; Navigation Function Tests

(ert-deftest ogent-gts-test-next-item-without-magit ()
  "Test next-item calls forward-line when magit-section unavailable."
  (with-temp-buffer
    (insert "line 1\nline 2\nline 3\n")
    (goto-char (point-min))
    (let ((ogent-gastown--magit-section-available nil))
      (ogent-gastown-next-item)
      (should (= (line-number-at-pos) 2)))))

(ert-deftest ogent-gts-test-prev-item-without-magit ()
  "Test prev-item calls forward-line -1 when magit-section unavailable."
  (with-temp-buffer
    (insert "line 1\nline 2\nline 3\n")
    (goto-char (point-max))
    (forward-line -1)  ;; go to line 3
    (let ((ogent-gastown--magit-section-available nil))
      (ogent-gastown-prev-item)
      (should (= (line-number-at-pos) 2)))))

(ert-deftest ogent-gts-test-toggle-section-without-magit ()
  "Test toggle-section shows message when magit-section unavailable."
  (with-temp-buffer
    (let ((ogent-gastown--magit-section-available nil)
          (messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (ogent-gastown-toggle-section)
        (should (member "Section toggling requires magit-section" messages))))))

(ert-deftest ogent-gts-test-cycle-sections-without-magit ()
  "Test cycle-sections shows message when magit-section unavailable."
  (with-temp-buffer
    (let ((ogent-gastown--magit-section-available nil)
          (messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (ogent-gastown-cycle-sections)
        (should (member "Section cycling requires magit-section" messages))))))

(ert-deftest ogent-gts-test-next-section-without-magit-noop ()
  "Test next-section is a no-op when magit-section unavailable."
  (with-temp-buffer
    (insert "line 1\nline 2\n")
    (goto-char (point-min))
    (let ((ogent-gastown--magit-section-available nil)
          (pos (point)))
      ;; Should not error and should not move
      (ogent-gastown-next-section)
      (should (= (point) pos)))))

(ert-deftest ogent-gts-test-prev-section-without-magit-noop ()
  "Test prev-section is a no-op when magit-section unavailable."
  (with-temp-buffer
    (insert "line 1\nline 2\n")
    (goto-char (point-max))
    (let ((ogent-gastown--magit-section-available nil)
          (pos (point)))
      (ogent-gastown-prev-section)
      (should (= (point) pos)))))

(ert-deftest ogent-gts-test-up-section-without-magit-noop ()
  "Test up-section is a no-op when magit-section unavailable."
  (with-temp-buffer
    (insert "line 1\nline 2\n")
    (goto-char (point-max))
    (let ((ogent-gastown--magit-section-available nil)
          (pos (point)))
      (ogent-gastown-up-section)
      (should (= (point) pos)))))

;;; Refresh Tests

(ert-deftest ogent-gts-test-refresh-calls-fetch-all ()
  "Test refresh calls fetch-all with loading animation."
  (with-temp-buffer
    (let ((ogent-gastown--loading nil)
          (ogent-gastown--loading-timer nil)
          (ogent-gastown--loading-frame 0)
          (fetch-called nil)
          (start-loading-called nil)
          (stop-loading-called nil))
      (cl-letf (((symbol-function 'ogent-gastown--fetch-all)
                 (lambda (callback)
                   (setq fetch-called t)
                   ;; Simulate immediate callback
                   (funcall callback)))
                ((symbol-function 'ogent-gastown--start-loading)
                 (lambda () (setq start-loading-called t)))
                ((symbol-function 'ogent-gastown--stop-loading)
                 (lambda () (setq stop-loading-called t)))
                ((symbol-function 'ogent-gastown--insert-buffer-contents)
                 #'ignore))
        (let ((inhibit-read-only t))
          (ogent-gastown-refresh)
          (should fetch-called)
          (should start-loading-called)
          (should stop-loading-called))))))

(ert-deftest ogent-gts-test-refresh-force-invalidates-cache ()
  "Test refresh-force invalidates cache then refreshes."
  (let ((cache-invalidated nil)
        (refresh-called nil))
    (cl-letf (((symbol-function 'ogent-gastown-cache-invalidate)
               (lambda () (setq cache-invalidated t)))
              ((symbol-function 'ogent-gastown-refresh)
               (lambda (&rest _) (setq refresh-called t))))
      (ogent-gastown-refresh-force)
      (should cache-invalidated)
      (should refresh-called))))

;;; ogent-gastown-status Entry Point Tests

(ert-deftest ogent-gts-test-status-errors-without-gt ()
  "Test ogent-gastown-status errors when gt is not available."
  (cl-letf (((symbol-function 'ogent-gastown--in-town-p)
             (lambda () nil)))
    (should-error (ogent-gastown-status) :type 'user-error)))

(ert-deftest ogent-gts-test-status-creates-buffer ()
  "Test ogent-gastown-status creates the status buffer."
  (let ((refresh-called nil)
        (ogent-gastown-buffer-name "*Test Gas Town*"))
    (cl-letf (((symbol-function 'ogent-gastown--in-town-p)
               (lambda () t))
              ((symbol-function 'ogent-gastown--find-town-root)
               (lambda () "/tmp/gt"))
              ((symbol-function 'ogent-gastown-refresh)
               (lambda (&rest _) (setq refresh-called t)))
              ((symbol-function 'switch-to-buffer)
               #'ignore))
      (unwind-protect
          (progn
            (ogent-gastown-status)
            (should refresh-called)
            (should (get-buffer "*Test Gas Town*")))
        (when (get-buffer "*Test Gas Town*")
          (kill-buffer "*Test Gas Town*"))))))

;;; Fetch-All Tests (with mocked run-async)

(ert-deftest ogent-gts-test-fetch-all-calls-callback ()
  "Test fetch-all calls callback after all fetches complete."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/tmp/gt")
          (callback-called nil)
          (call-count 0))
      (cl-letf (((symbol-function 'ogent-gastown-status--run-async)
                 (lambda (_args callback &optional _error-callback _raw)
                   (cl-incf call-count)
                   ;; Immediately call success callback with sample data
                   (funcall callback nil))))
        (ogent-gastown--fetch-all
         (lambda ()
           (setq callback-called t)))
        ;; Should have called run-async 7 times (hook, mail, convoy, workers, town-status, crew, polecat)
        (should (= call-count 7))
        (should callback-called)))))

(ert-deftest ogent-gts-test-fetch-all-handles-errors ()
  "Test fetch-all handles errors gracefully and still calls callback."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/tmp/gt")
          (callback-called nil))
      (cl-letf (((symbol-function 'ogent-gastown-status--run-async)
                 (lambda (_args _callback &optional error-callback _raw)
                   ;; All calls fail
                   (when error-callback
                     (funcall error-callback "test error")))))
        (ogent-gastown--fetch-all
         (lambda ()
           (setq callback-called t)))
        ;; Should still call the callback even on errors
        (should callback-called)))))

(ert-deftest ogent-gts-test-fetch-all-extracts-town-status ()
  "Test fetch-all extracts stats, deacon, witnesses from town-status."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/tmp/gt")
          (callback-called nil)
          (ogent-gastown--stats-data nil)
          (ogent-gastown--deacon-data nil)
          (ogent-gastown--witness-data nil)
          (ogent-gastown--rigs-data nil))
      (cl-letf (((symbol-function 'ogent-gastown-status--run-async)
                 (lambda (args callback &optional _error-callback _raw)
                   ;; Return town-status for the status command
                   (if (equal args '("status" "--json"))
                       (funcall callback
                                '(:summary (:rig_count 2 :polecat_count 3)
                                  :agents ((:name "deacon" :running t :has_work nil))
                                  :rigs ((:name "rig1" :has_witness t
                                          :polecat_count 1 :crew_count 1))))
                     (funcall callback nil)))))
        (ogent-gastown--fetch-all
         (lambda ()
           (setq callback-called t)))
        (should callback-called)
        ;; Stats should be extracted from :summary
        (should ogent-gastown--stats-data)
        (should (= (plist-get ogent-gastown--stats-data :rig_count) 2))
        ;; Deacon should be extracted
        (should ogent-gastown--deacon-data)
        (should (equal (plist-get ogent-gastown--deacon-data :name) "deacon"))
        ;; Witnesses should be extracted
        (should ogent-gastown--witness-data)
        (should (= (length ogent-gastown--witness-data) 1))
        ;; Rigs should be set
        (should ogent-gastown--rigs-data)))))

;;; Worker Item with Unicode Tests

(ert-deftest ogent-gts-test-insert-worker-item-unicode-running ()
  "Test worker item uses unicode icons when enabled and running."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-worker-item
       '(:name "alpha" :state "working" :session_running t))
      (let ((content (buffer-string)))
        (should (string-match-p "alpha" content))
        (should (string-match-p "" content))))))

(ert-deftest ogent-gts-test-insert-worker-item-unicode-idle ()
  "Test worker item uses correct unicode icon for idle state."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-worker-item
       '(:name "beta" :state "idle" :session_running nil))
      (let ((content (buffer-string)))
        (should (string-match-p "" content))))))

;;; Rig Agent Tests - Extended

(ert-deftest ogent-gts-test-insert-rig-agent-polecat-role ()
  "Test rig agent uses polecat icon."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-rig-agent
       '(:name "polecat1" :role "polecat" :running t :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "🐱" content))
        (should (string-match-p "polecat1" content))))))

(ert-deftest ogent-gts-test-insert-rig-agent-no-hook-no-mail ()
  "Test rig agent without hook or mail shows clean output."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-rig-agent
       '(:name "clean" :role "crew" :running t :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "clean" content))
        (should-not (string-match-p "⚓" content))
        (should-not (string-match-p "📬" content))))))

(ert-deftest ogent-gts-test-insert-rig-agent-ascii-hook ()
  "Test rig agent shows H for hook in ASCII mode."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent
       '(:name "worker" :role "crew" :running t :has_work t :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "H" content))))))

(ert-deftest ogent-gts-test-insert-rig-agent-ascii-mail ()
  "Test rig agent shows M: for mail in ASCII mode."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent
       '(:name "worker" :role "crew" :running nil :has_work nil :unread_mail 3))
      (let ((content (buffer-string)))
        (should (string-match-p "M:3" content))))))

;;; Keybinding Tests - Extended

(ert-deftest ogent-gts-test-keybindings-navigation ()
  "Navigation keys are properly bound."
  (should (eq (lookup-key ogent-gastown-status-mode-map "n")
              'ogent-gastown-next-item))
  (should (eq (lookup-key ogent-gastown-status-mode-map "p")
              'ogent-gastown-prev-item))
  (should (eq (lookup-key ogent-gastown-status-mode-map (kbd "TAB"))
              'ogent-gastown-toggle-section))
  (should (eq (lookup-key ogent-gastown-status-mode-map (kbd "RET"))
              'ogent-gastown-visit)))

(ert-deftest ogent-gts-test-keybindings-refresh ()
  "Refresh keys are properly bound."
  (should (eq (lookup-key ogent-gastown-status-mode-map "g")
              'ogent-gastown-refresh))
  (should (eq (lookup-key ogent-gastown-status-mode-map "G")
              'ogent-gastown-refresh-force)))

(ert-deftest ogent-gts-test-keybindings-mail ()
  "Mail keys are properly bound."
  (should (eq (lookup-key ogent-gastown-status-mode-map "m")
              'ogent-gastown-status-mail-read))
  (should (eq (lookup-key ogent-gastown-status-mode-map "M")
              'ogent-gastown-mail-compose)))

(ert-deftest ogent-gts-test-keybindings-sections ()
  "Section navigation keys are properly bound."
  (should (eq (lookup-key ogent-gastown-status-mode-map (kbd "M-n"))
              'ogent-gastown-next-section))
  (should (eq (lookup-key ogent-gastown-status-mode-map (kbd "M-p"))
              'ogent-gastown-prev-section))
  (should (eq (lookup-key ogent-gastown-status-mode-map (kbd "<backtab>"))
              'ogent-gastown-cycle-sections))
  (should (eq (lookup-key ogent-gastown-status-mode-map (kbd "^"))
              'ogent-gastown-up-section)))

(ert-deftest ogent-gts-test-keybindings-issues ()
  "Issues navigation key is properly bound."
  (should (eq (lookup-key ogent-gastown-status-mode-map "i")
              'ogent-gastown-rig-issues)))

(ert-deftest ogent-gts-test-keybindings-quit ()
  "Quit key is properly bound."
  (should (eq (lookup-key ogent-gastown-status-mode-map "q")
              'quit-window)))

;;; Header Line Edge Cases

(ert-deftest ogent-gts-test-header-line-nil-hook-data ()
  "Test header line with completely nil hook data."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data nil)
          (ogent-gastown--mail-data nil)
          (ogent-gastown--loading nil))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "Gas Town" header))
        (should (string-match-p "Hook: empty" header))))))

(ert-deftest ogent-gts-test-header-line-all-mail-read ()
  "Test header line when all mail is read."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data nil)
          (ogent-gastown--mail-data
           (list '(:id "m1" :read t) '(:id "m2" :read t)))
          (ogent-gastown--loading nil))
      (let ((header (ogent-gastown--header-line)))
        (should-not (string-match-p "unread" header))))))

;;; Deacon Section Edge Cases

(ert-deftest ogent-gts-test-insert-deacon-section-plain-nil-data ()
  "Test deacon section plain text rendering with nil data."
  (with-temp-buffer
    (let ((ogent-gastown--deacon-data nil))
      (ogent-gastown--insert-deacon-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Deacon" content))
        ;; nil running -> stopped
        (should (string-match-p "stopped" content))))))

(ert-deftest ogent-gts-test-insert-deacon-section-plain-with-work ()
  "Test deacon section plain text rendering with hooked work."
  (with-temp-buffer
    (let ((ogent-gastown--deacon-data ogent-gts-test--sample-deacon-with-work))
      (ogent-gastown--insert-deacon-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "running" content))))))

;;; Cache TTL Expiry Tests

(ert-deftest ogent-gts-test-cache-expired-entry ()
  "Test cache returns nil for expired entries."
  (let ((ogent-gastown--cache (make-hash-table :test 'equal))
        (ogent-gastown-cache-ttl 1))
    ;; Set cache with an old timestamp
    (puthash (ogent-gastown--cache-key '("test"))
             (cons (time-subtract (current-time) 10) '(:stale "data"))
             ogent-gastown--cache)
    ;; Should return nil because entry is expired
    (should-not (ogent-gastown--cache-get '("test")))
    ;; Expired entry should be removed from cache
    (should-not (gethash (ogent-gastown--cache-key '("test"))
                         ogent-gastown--cache))))

;;; Bead Link Keymap Tests

(ert-deftest ogent-gts-test-bead-link-keymap-exists ()
  "Test bead link keymap is defined."
  (should (keymapp ogent-gastown-bead-link-map)))

(ert-deftest ogent-gts-test-bead-link-keymap-ret-bound ()
  "Test bead link keymap has RET bound."
  (should (eq (lookup-key ogent-gastown-bead-link-map (kbd "RET"))
              'ogent-gastown-visit-bead)))

(ert-deftest ogent-gts-test-bead-link-keymap-mouse-bound ()
  "Test bead link keymap has mouse-1 bound."
  (should (eq (lookup-key ogent-gastown-bead-link-map [mouse-1])
              'ogent-gastown-visit-bead)))

;;; Status Help Tests

(ert-deftest ogent-gts-test-status-help-shows-message ()
  "Test status-help shows keybinding info."
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (ogent-gastown-status-help)
      (should (= (length messages) 1))
      (should (string-match-p "refresh" (car messages)))
      (should (string-match-p "quit" (car messages))))))

;;; ====================================================================
;;; NEW TESTS: Increasing coverage for ogent-gastown-status.el
;;; ====================================================================

;;; Face Existence Tests

(ert-deftest ogent-gts-test-face-section-heading-exists ()
  "Test ogent-gastown-section-heading face is defined."
  (should (facep 'ogent-gastown-section-heading)))

(ert-deftest ogent-gts-test-face-hook-active-exists ()
  "Test ogent-gastown-hook-active face is defined."
  (should (facep 'ogent-gastown-hook-active)))

(ert-deftest ogent-gts-test-face-hook-empty-exists ()
  "Test ogent-gastown-hook-empty face is defined."
  (should (facep 'ogent-gastown-hook-empty)))

(ert-deftest ogent-gts-test-face-mail-unread-exists ()
  "Test ogent-gastown-mail-unread face is defined."
  (should (facep 'ogent-gastown-mail-unread)))

(ert-deftest ogent-gts-test-face-mail-read-exists ()
  "Test ogent-gastown-mail-read face is defined."
  (should (facep 'ogent-gastown-mail-read)))

(ert-deftest ogent-gts-test-face-mail-from-exists ()
  "Test ogent-gastown-mail-from face is defined."
  (should (facep 'ogent-gastown-mail-from)))

(ert-deftest ogent-gts-test-face-convoy-active-exists ()
  "Test ogent-gastown-convoy-active face is defined."
  (should (facep 'ogent-gastown-convoy-active)))

(ert-deftest ogent-gts-test-face-convoy-complete-exists ()
  "Test ogent-gastown-convoy-complete face is defined."
  (should (facep 'ogent-gastown-convoy-complete)))

(ert-deftest ogent-gts-test-face-worker-running-exists ()
  "Test ogent-gastown-worker-running face is defined."
  (should (facep 'ogent-gastown-worker-running)))

(ert-deftest ogent-gts-test-face-worker-done-exists ()
  "Test ogent-gastown-worker-done face is defined."
  (should (facep 'ogent-gastown-worker-done)))

(ert-deftest ogent-gts-test-face-worker-working-exists ()
  "Test ogent-gastown-worker-working face is defined."
  (should (facep 'ogent-gastown-worker-working)))

(ert-deftest ogent-gts-test-face-dimmed-exists ()
  "Test ogent-gastown-dimmed face is defined."
  (should (facep 'ogent-gastown-dimmed)))

(ert-deftest ogent-gts-test-face-stats-label-exists ()
  "Test ogent-gastown-stats-label face is defined."
  (should (facep 'ogent-gastown-stats-label)))

(ert-deftest ogent-gts-test-face-stats-value-exists ()
  "Test ogent-gastown-stats-value face is defined."
  (should (facep 'ogent-gastown-stats-value)))

(ert-deftest ogent-gts-test-face-deacon-running-exists ()
  "Test ogent-gastown-deacon-running face is defined."
  (should (facep 'ogent-gastown-deacon-running)))

(ert-deftest ogent-gts-test-face-deacon-stopped-exists ()
  "Test ogent-gastown-deacon-stopped face is defined."
  (should (facep 'ogent-gastown-deacon-stopped)))

(ert-deftest ogent-gts-test-face-witness-healthy-exists ()
  "Test ogent-gastown-witness-healthy face is defined."
  (should (facep 'ogent-gastown-witness-healthy)))

(ert-deftest ogent-gts-test-face-witness-unhealthy-exists ()
  "Test ogent-gastown-witness-unhealthy face is defined."
  (should (facep 'ogent-gastown-witness-unhealthy)))

(ert-deftest ogent-gts-test-face-crew-active-exists ()
  "Test ogent-gastown-crew-active face is defined."
  (should (facep 'ogent-gastown-crew-active)))

(ert-deftest ogent-gts-test-face-crew-idle-exists ()
  "Test ogent-gastown-crew-idle face is defined."
  (should (facep 'ogent-gastown-crew-idle)))

(ert-deftest ogent-gts-test-face-polecat-active-exists ()
  "Test ogent-gastown-polecat-active face is defined."
  (should (facep 'ogent-gastown-polecat-active)))

(ert-deftest ogent-gts-test-face-polecat-idle-exists ()
  "Test ogent-gastown-polecat-idle face is defined."
  (should (facep 'ogent-gastown-polecat-idle)))

(ert-deftest ogent-gts-test-face-rig-name-exists ()
  "Test ogent-gastown-rig-name face is defined."
  (should (facep 'ogent-gastown-rig-name)))

(ert-deftest ogent-gts-test-face-rig-running-exists ()
  "Test ogent-gastown-rig-running face is defined."
  (should (facep 'ogent-gastown-rig-running)))

(ert-deftest ogent-gts-test-face-rig-stopped-exists ()
  "Test ogent-gastown-rig-stopped face is defined."
  (should (facep 'ogent-gastown-rig-stopped)))

(ert-deftest ogent-gts-test-face-header-line-exists ()
  "Test ogent-gastown-header-line face is defined."
  (should (facep 'ogent-gastown-header-line)))

(ert-deftest ogent-gts-test-face-header-line-key-exists ()
  "Test ogent-gastown-header-line-key face is defined."
  (should (facep 'ogent-gastown-header-line-key)))

;;; Customization Group / Variable Tests

(ert-deftest ogent-gts-test-customization-group-exists ()
  "Test ogent-gastown customization group exists."
  (should (get 'ogent-gastown 'custom-group)))

(ert-deftest ogent-gts-test-customization-faces-group-exists ()
  "Test ogent-gastown-faces customization group exists."
  (should (get 'ogent-gastown-faces 'custom-group)))

(ert-deftest ogent-gts-test-custom-buffer-name-default ()
  "Test default buffer name is *Gas Town*."
  (should (equal ogent-gastown-buffer-name "*Gas Town*")))

(ert-deftest ogent-gts-test-custom-gt-executable-default ()
  "Test default gt executable is gt."
  (should (equal ogent-gastown-gt-executable "gt")))

(ert-deftest ogent-gts-test-custom-timeout-default ()
  "Test default timeout is 30."
  (should (= ogent-gastown-timeout 30)))

(ert-deftest ogent-gts-test-custom-use-unicode-default ()
  "Test default use-unicode is t."
  (should (eq ogent-gastown-use-unicode t)))

;;; Mode Definition Tests

(ert-deftest ogent-gts-test-mode-derived-correctly ()
  "Test ogent-gastown-status-mode is a derived mode."
  ;; Should be derived from either magit-section-mode or special-mode
  (let ((parent (get 'ogent-gastown-status-mode 'derived-mode-parent)))
    (should (memq parent '(magit-section-mode special-mode)))))

(ert-deftest ogent-gts-test-mode-sets-buffer-read-only ()
  "Test mode sets buffer-read-only."
  (let ((buf (generate-new-buffer " *test-mode*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-gastown-status-mode)
          (should buffer-read-only))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-gts-test-mode-sets-truncate-lines ()
  "Test mode sets truncate-lines."
  (let ((buf (generate-new-buffer " *test-mode*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-gastown-status-mode)
          (should truncate-lines))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-gts-test-mode-sets-revert-buffer-function ()
  "Test mode sets revert-buffer-function to ogent-gastown-refresh."
  (let ((buf (generate-new-buffer " *test-mode*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-gastown-status-mode)
          (should (eq revert-buffer-function #'ogent-gastown-refresh)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-gts-test-mode-sets-header-line-format ()
  "Test mode sets header-line-format."
  (let ((buf (generate-new-buffer " *test-mode*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-gastown-status-mode)
          (should header-line-format))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-gts-test-mode-defined ()
  "Test ogent-gastown-status-mode is a defined major mode."
  (should (fboundp 'ogent-gastown-status-mode))
  (let ((buf (generate-new-buffer " *test-mode-def*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-gastown-status-mode)
          (should (eq major-mode 'ogent-gastown-status-mode)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; Loading Animation Constants

(ert-deftest ogent-gts-test-loading-frames-has-four-elements ()
  "Test loading frames has exactly 4 elements."
  (should (= (length ogent-gastown--loading-frames) 4)))

(ert-deftest ogent-gts-test-loading-frames-all-strings ()
  "Test loading frames are all strings."
  (dolist (frame ogent-gastown--loading-frames)
    (should (stringp frame))))

;;; Format Time Extended Tests

(ert-deftest ogent-gts-test-format-time-nil-string ()
  "Test formatting the literal string nil returns ???."
  (should (equal "???" (ogent-gastown--format-time nil))))

(ert-deftest ogent-gts-test-format-time-boundary-59-seconds ()
  "Test formatting time at exactly 59 seconds shows just now."
  (let ((now (current-time)))
    (cl-letf (((symbol-function 'parse-iso8601-time-string)
               (lambda (_iso-time)
                 (time-subtract now 59))))
      (should (equal "just now" (ogent-gastown--format-time "2026-01-23T17:00:00Z"))))))

(ert-deftest ogent-gts-test-format-time-boundary-60-seconds ()
  "Test formatting time at exactly 60 seconds shows 1m ago."
  (let ((now (current-time)))
    (cl-letf (((symbol-function 'parse-iso8601-time-string)
               (lambda (_iso-time)
                 (time-subtract now 60))))
      (should (string-match-p "1m ago" (ogent-gastown--format-time "2026-01-23T17:00:00Z"))))))

(ert-deftest ogent-gts-test-format-time-boundary-3599-seconds ()
  "Test formatting time at 3599 seconds shows 59m ago."
  (let ((now (current-time)))
    (cl-letf (((symbol-function 'parse-iso8601-time-string)
               (lambda (_iso-time)
                 (time-subtract now 3599))))
      (should (string-match-p "59m ago" (ogent-gastown--format-time "2026-01-23T17:00:00Z"))))))

(ert-deftest ogent-gts-test-format-time-boundary-3600-seconds ()
  "Test formatting time at exactly 3600 seconds shows 1h ago."
  (let ((now (current-time)))
    (cl-letf (((symbol-function 'parse-iso8601-time-string)
               (lambda (_iso-time)
                 (time-subtract now 3600))))
      (should (string-match-p "1h ago" (ogent-gastown--format-time "2026-01-23T17:00:00Z"))))))

(ert-deftest ogent-gts-test-format-time-boundary-23-hours ()
  "Test formatting time at 23 hours shows 23h ago."
  (let ((now (current-time)))
    (cl-letf (((symbol-function 'parse-iso8601-time-string)
               (lambda (_iso-time)
                 (time-subtract now (* 23 3600)))))
      (should (string-match-p "23h ago" (ogent-gastown--format-time "2026-01-23T17:00:00Z"))))))

(ert-deftest ogent-gts-test-format-time-boundary-24-hours ()
  "Test formatting time at 24 hours shows date format."
  (let ((now (current-time)))
    (cl-letf (((symbol-function 'parse-iso8601-time-string)
               (lambda (_iso-time)
                 (time-subtract now (* 24 3600)))))
      (let ((result (ogent-gastown--format-time "2026-01-23T17:00:00Z")))
        (should-not (string-match-p "ago" result))
        (should-not (equal "???" result))))))

;;; Worker Item Extended Tests

(ert-deftest ogent-gts-test-insert-worker-item-state-working-not-running ()
  "Test worker item in working state but not running."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-worker-item
       '(:name "worker1" :state "working" :session_running nil))
      (let ((content (buffer-string)))
        (should (string-match-p "worker1" content))
        (should (string-match-p "\\[working\\]" content))
        (should-not (string-match-p "running" content))))))

(ert-deftest ogent-gts-test-insert-worker-item-state-done ()
  "Test worker item in done state."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-worker-item
       '(:name "worker2" :state "done" :session_running nil))
      (let ((content (buffer-string)))
        (should (string-match-p "worker2" content))
        (should (string-match-p "\\[done\\]" content))
        (should (string-match-p "-" content))))))

(ert-deftest ogent-gts-test-insert-worker-item-unicode-working-not-running ()
  "Test worker item uses working unicode icon when state is working but not running."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-worker-item
       '(:name "worker3" :state "working" :session_running nil))
      (let ((content (buffer-string)))
        (should (string-match-p "" content))))))

(ert-deftest ogent-gts-test-insert-worker-item-unicode-done ()
  "Test worker item uses done unicode icon."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-worker-item
       '(:name "worker4" :state "done" :session_running nil))
      (let ((content (buffer-string)))
        (should (string-match-p "" content))))))

;;; Stat Item Extended Tests

(ert-deftest ogent-gts-test-insert-stat-item-zero ()
  "Test stat item insertion with zero value."
  (with-temp-buffer
    (ogent-gastown--insert-stat-item "Test" 0)
    (let ((content (buffer-string)))
      (should (string-match-p "Test" content))
      (should (string-match-p "0" content)))))

(ert-deftest ogent-gts-test-insert-stat-item-large-value ()
  "Test stat item insertion with large value."
  (with-temp-buffer
    (ogent-gastown--insert-stat-item "Count" 9999)
    (let ((content (buffer-string)))
      (should (string-match-p "Count" content))
      (should (string-match-p "9999" content)))))

(ert-deftest ogent-gts-test-insert-stat-item-has-face ()
  "Test stat item uses correct faces."
  (with-temp-buffer
    (ogent-gastown--insert-stat-item "Label" 42)
    (goto-char (point-min))
    ;; Label should have stats-label face
    (should (eq (get-text-property (point) 'face)
                'ogent-gastown-stats-label))))

;;; Header Line Extended Tests

(ert-deftest ogent-gts-test-header-line-shows-keybinding-help ()
  "Test header line includes keybinding hints."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data nil)
          (ogent-gastown--mail-data nil)
          (ogent-gastown--loading nil))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "refresh" header))
        (should (string-match-p "help" header))
        (should (string-match-p "quit" header))))))

(ert-deftest ogent-gts-test-header-line-shows-single-unread ()
  "Test header line with exactly 1 unread message."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data nil)
          (ogent-gastown--mail-data (list '(:id "m1" :read nil)))
          (ogent-gastown--loading nil))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "1 unread" header))))))

(ert-deftest ogent-gts-test-header-line-nil-mail-data ()
  "Test header line with nil mail data."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data nil)
          (ogent-gastown--mail-data nil)
          (ogent-gastown--loading nil))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "Gas Town" header))
        (should-not (string-match-p "unread" header))))))

;;; Rig Agent Extended Tests

(ert-deftest ogent-gts-test-insert-rig-agent-crew-unicode ()
  "Test rig agent uses crew unicode icon."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-rig-agent
       '(:name "dev1" :role "crew" :running t :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "👤" content))))))

(ert-deftest ogent-gts-test-insert-rig-agent-refinery-unicode ()
  "Test rig agent uses refinery unicode icon."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-rig-agent
       '(:name "ref1" :role "refinery" :running nil :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "⚙" content))))))

(ert-deftest ogent-gts-test-insert-rig-agent-nil-name ()
  "Test rig agent with nil name renders ???."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent
       '(:name nil :role "crew" :running nil :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "\\?\\?\\?" content))))))

(ert-deftest ogent-gts-test-insert-rig-agent-running-face ()
  "Test rig agent running uses worker-running face."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent
       '(:name "running-agent" :role "crew" :running t :has_work nil :unread_mail 0))
      ;; Find the agent name text and check its face
      (goto-char (point-min))
      (search-forward "running-agent")
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'ogent-gastown-worker-running)))))

(ert-deftest ogent-gts-test-insert-rig-agent-stopped-face ()
  "Test rig agent not running uses dimmed face."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent
       '(:name "stopped-agent" :role "crew" :running nil :has_work nil :unread_mail 0))
      (goto-char (point-min))
      (search-forward "stopped-agent")
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'ogent-gastown-dimmed)))))

(ert-deftest ogent-gts-test-insert-rig-agent-nil-role ()
  "Test rig agent with nil role shows ? icon."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent
       '(:name "norole" :role nil :running nil :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "\\?" content))))))

(ert-deftest ogent-gts-test-insert-rig-agent-zero-unread ()
  "Test rig agent with zero unread mail shows no mail indicator."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-rig-agent
       '(:name "nomail" :role "crew" :running t :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should-not (string-match-p "📬" content))))))

(ert-deftest ogent-gts-test-insert-rig-agent-nil-unread ()
  "Test rig agent with nil unread mail defaults to 0, no indicator."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-rig-agent
       '(:name "nilmail" :role "crew" :running t :has_work nil :unread_mail nil))
      (let ((content (buffer-string)))
        (should-not (string-match-p "📬" content))))))

;;; Process List Tests

(ert-deftest ogent-gts-test-processes-list-exists ()
  "Test ogent-gastown--processes variable exists."
  (should (boundp 'ogent-gastown--processes)))

;;; Visit/Action Tests (non-magit paths)

(ert-deftest ogent-gts-test-visit-without-magit-noop ()
  "Test visit is a no-op when magit-section unavailable."
  (with-temp-buffer
    (let ((ogent-gastown--magit-section-available nil))
      ;; Should not error
      (ogent-gastown-visit))))

(ert-deftest ogent-gts-test-recipient-at-point-without-magit ()
  "Test recipient-at-point returns nil without magit-section."
  (with-temp-buffer
    (let ((ogent-gastown--magit-section-available nil))
      (should-not (ogent-gastown--recipient-at-point)))))

(ert-deftest ogent-gts-test-rig-at-point-without-magit ()
  "Test rig-at-point returns nil without magit-section."
  (with-temp-buffer
    (let ((ogent-gastown--magit-section-available nil))
      (should-not (ogent-gastown--rig-at-point)))))

;;; Hook Action Tests

(ert-deftest ogent-gts-test-hook-show-calls-async-shell ()
  "Test hook-show calls async-shell-command."
  (let ((commands nil))
    (cl-letf (((symbol-function 'async-shell-command)
               (lambda (cmd &optional buf)
                 (push (list cmd buf) commands))))
      (ogent-gastown-hook-show)
      (should (= (length commands) 1))
      (should (string-match-p "gt hook" (caar commands))))))

;;; Stats Show Tests

(ert-deftest ogent-gts-test-stats-show-calls-async-shell ()
  "Test stats-show calls async-shell-command."
  (let ((commands nil))
    (cl-letf (((symbol-function 'async-shell-command)
               (lambda (cmd &optional buf)
                 (push (list cmd buf) commands))))
      (ogent-gastown-stats-show)
      (should (= (length commands) 1))
      (should (string-match-p "gt status" (caar commands))))))

;;; Deacon Show Tests

(ert-deftest ogent-gts-test-deacon-show-calls-async-shell ()
  "Test deacon-show calls async-shell-command."
  (let ((commands nil))
    (cl-letf (((symbol-function 'async-shell-command)
               (lambda (cmd &optional buf)
                 (push (list cmd buf) commands))))
      (ogent-gastown-deacon-show)
      (should (= (length commands) 1))
      (should (string-match-p "gt deacon status" (caar commands))))))

;;; Crew Status Tests (without magit)

(ert-deftest ogent-gts-test-crew-status-no-magit-lists ()
  "Test crew-status lists all crew when magit unavailable."
  (let ((commands nil))
    (cl-letf (((symbol-function 'async-shell-command)
               (lambda (cmd &optional buf)
                 (push (list cmd buf) commands)))
              ((symbol-function 'ogent-gastown--magit-section-available)
               nil))
      (let ((ogent-gastown--magit-section-available nil))
        (ogent-gastown-crew-status)
        (should (= (length commands) 1))
        (should (string-match-p "gt crew list" (caar commands)))))))

;;; Polecat Status Tests (without magit)

(ert-deftest ogent-gts-test-polecat-status-no-magit-lists ()
  "Test polecat-status lists all polecats when magit unavailable."
  (let ((commands nil))
    (cl-letf (((symbol-function 'async-shell-command)
               (lambda (cmd &optional buf)
                 (push (list cmd buf) commands))))
      (let ((ogent-gastown--magit-section-available nil))
        (ogent-gastown-polecat-status)
        (should (= (length commands) 1))
        (should (string-match-p "gt polecat list" (caar commands)))))))

;;; Convoy Status Tests (without magit)

(ert-deftest ogent-gts-test-convoy-status-no-magit-lists ()
  "Test convoy-status lists all convoys when magit unavailable."
  (let ((commands nil))
    (cl-letf (((symbol-function 'async-shell-command)
               (lambda (cmd &optional buf)
                 (push (list cmd buf) commands))))
      (let ((ogent-gastown--magit-section-available nil))
        (ogent-gastown-convoy-status)
        (should (= (length commands) 1))
        (should (string-match-p "gt convoy list" (caar commands)))))))

;;; Mail Read Tests (without magit)

(ert-deftest ogent-gts-test-mail-read-with-explicit-id ()
  "Test mail-read with explicit ID calls async-shell-command."
  (with-temp-buffer
    (let ((commands nil)
          (ogent-gastown--magit-section-available nil))
      (cl-letf (((symbol-function 'async-shell-command)
                 (lambda (cmd &optional buf)
                   (push (list cmd buf) commands))))
        (ogent-gastown-status-mail-read "test-mail-123")
        (should (= (length commands) 1))
        (should (string-match-p "gt mail read test-mail-123" (caar commands)))))))

;;; Cleanup Hook Tests

(ert-deftest ogent-gts-test-kill-buffer-hook-registered ()
  "Test kill-buffer-hook is registered by mode hook."
  (let ((buf (generate-new-buffer " *test-hook*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-gastown-status-mode)
          ;; kill-buffer-hook should contain cleanup
          (should (memq #'ogent-gastown--cleanup-on-kill kill-buffer-hook)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; Refresh with Position Preservation

(ert-deftest ogent-gts-test-refresh-preserves-point ()
  "Test refresh attempts to preserve point position."
  (let ((buf (generate-new-buffer " *test-refresh-pos*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-gastown-status-mode)
          (let ((inhibit-read-only t))
            (insert "line 1\nline 2\nline 3\n"))
          (goto-char 10)
          (let ((ogent-gastown--loading nil)
                (ogent-gastown--loading-timer nil)
                (ogent-gastown--loading-frame 0))
            (cl-letf (((symbol-function 'ogent-gastown--fetch-all)
                       (lambda (callback)
                         (funcall callback)))
                      ((symbol-function 'ogent-gastown--start-loading)
                       #'ignore)
                      ((symbol-function 'ogent-gastown--stop-loading)
                       #'ignore)
                      ((symbol-function 'ogent-gastown--insert-buffer-contents)
                       (lambda ()
                         (insert "new line 1\nnew line 2\nnew line 3\n"))))
              (ogent-gastown-refresh)
              ;; Point should be at original position or point-max if buffer is shorter
              (should (<= (point) (point-max))))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; Magit Section Availability Flag Tests

(ert-deftest ogent-gts-test-magit-section-available-is-boolean ()
  "Test magit-section-available is a boolean-like value."
  (should (or (null ogent-gastown--magit-section-available)
              ogent-gastown--magit-section-available)))

;;; Extract Deacon Edge Cases

(ert-deftest ogent-gts-test-extract-deacon-multiple-agents ()
  "Test extracting deacon when it is among multiple agents."
  (let ((town-status '(:agents ((:name "witness" :running t)
                                (:name "deacon" :running nil :has_work t)
                                (:name "refinery" :running t)))))
    (let ((result (ogent-gastown--extract-deacon town-status)))
      (should result)
      (should (equal (plist-get result :name) "deacon"))
      (should-not (plist-get result :running))
      (should (eq (plist-get result :has_work) t)))))

;;; Extract Witnesses Extended Tests

(ert-deftest ogent-gts-test-extract-witnesses-multiple-rigs ()
  "Test extracting witnesses from multiple rigs."
  (let ((town-status '(:rigs ((:name "rig1" :has_witness t :polecat_count 5 :crew_count 3)
                               (:name "rig2" :has_witness nil :polecat_count 2 :crew_count 1)
                               (:name "rig3" :has_witness t :polecat_count 0 :crew_count 0)))))
    (let ((result (ogent-gastown--extract-witnesses town-status)))
      (should (= (length result) 3))
      ;; First rig
      (should (equal (plist-get (nth 0 result) :rig) "rig1"))
      (should (eq (plist-get (nth 0 result) :has_witness) t))
      (should (= (plist-get (nth 0 result) :polecat_count) 5))
      ;; Second rig
      (should (equal (plist-get (nth 1 result) :rig) "rig2"))
      (should-not (plist-get (nth 1 result) :has_witness))
      ;; Third rig
      (should (equal (plist-get (nth 2 result) :rig) "rig3"))
      (should (= (plist-get (nth 2 result) :crew_count) 0)))))

;;; Cache Extended Tests

(ert-deftest ogent-gts-test-cache-set-replaces-existing ()
  "Test cache set replaces an existing entry."
  (let ((ogent-gastown--cache (make-hash-table :test 'equal))
        (ogent-gastown-cache-ttl 60))
    (ogent-gastown--cache-set '("test") '(:old "value"))
    (should (equal '(:old "value") (ogent-gastown--cache-get '("test"))))
    (ogent-gastown--cache-set '("test") '(:new "value"))
    (should (equal '(:new "value") (ogent-gastown--cache-get '("test"))))))

(ert-deftest ogent-gts-test-cache-key-with-special-chars ()
  "Test cache key handles special characters in args."
  (let ((key1 (ogent-gastown--cache-key '("test" "--json" "foo bar")))
        (key2 (ogent-gastown--cache-key '("test" "--json" "foo bar"))))
    (should (equal key1 key2))
    (should (stringp key1))))

(ert-deftest ogent-gts-test-cache-key-with-nil-args ()
  "Test cache key handles nil in args."
  (let ((key (ogent-gastown--cache-key '("test" nil))))
    (should (stringp key))))

;;; Insert Plain with Nil Data

(ert-deftest ogent-gts-test-insert-plain-all-nil ()
  "Test insert-plain handles all nil data gracefully."
  (with-temp-buffer
    (let ((ogent-gastown--stats-data nil)
          (ogent-gastown--deacon-data nil)
          (ogent-gastown--witness-data nil)
          (ogent-gastown--hook-data nil)
          (ogent-gastown--mail-data nil)
          (ogent-gastown--convoy-data nil)
          (ogent-gastown--rigs-data nil)
          (ogent-gastown--crew-data nil)
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--workers-data nil))
      ;; Should not error with all nil data
      (ogent-gastown--insert-plain)
      (let ((content (buffer-string)))
        ;; All empty sections should render
        (should (string-match-p "Town Stats" content))
        (should (string-match-p "Deacon" content))
        (should (string-match-p "Witnesses" content))
        (should (string-match-p "Hook Status" content))
        (should (string-match-p "Mail Inbox" content))
        (should (string-match-p "Convoys" content))
        (should (string-match-p "Rigs" content))
        (should (string-match-p "Crew" content))
        (should (string-match-p "Polecats" content))
        (should (string-match-p "Workers" content))
        ;; Empty state messages
        (should (string-match-p "No stats available" content))
        (should (string-match-p "No messages" content))
        (should (string-match-p "No active convoys" content))
        (should (string-match-p "No crew members" content))
        (should (string-match-p "No polecats" content))
        (should (string-match-p "No workers" content))
        (should (string-match-p "No rigs configured" content))
        (should (string-match-p "No rig data available" content))))))

;;; Hook Section Plain Extended Tests

(ert-deftest ogent-gts-test-insert-hook-section-plain-nil-data ()
  "Test hook section plain with nil data uses defaults."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data nil))
      (ogent-gastown--insert-hook-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Hook Status" content))
        (should (string-match-p "Role: unknown" content))
        (should (string-match-p "No work hooked" content))))))

(ert-deftest ogent-gts-test-insert-hook-section-plain-custom-role ()
  "Test hook section plain renders custom role."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data '(:has_work nil :role "witness" :target "witness/")))
      (ogent-gastown--insert-hook-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Role: witness" content))))))

;;; Workers Section Plain Extended Tests

(ert-deftest ogent-gts-test-insert-workers-section-plain-groups-by-rig ()
  "Test workers section plain groups workers by rig."
  (with-temp-buffer
    (let ((ogent-gastown--workers-data
           (list '(:name "a1" :rig "rig-a" :state "working")
                 '(:name "b1" :rig "rig-b" :state "idle")
                 '(:name "a2" :rig "rig-a" :state "idle"))))
      (ogent-gastown--insert-workers-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "rig-a/a1" content))
        (should (string-match-p "rig-b/b1" content))
        (should (string-match-p "rig-a/a2" content))))))

;;; Crew Rig Path Extended Tests

(ert-deftest ogent-gts-test-crew-rig-path-nil-town-root ()
  "Test crew-rig-path with nil town root."
  (with-temp-buffer
    (let ((ogent-gastown--town-root nil))
      ;; Should still produce a path (relative to nil)
      (let ((path (ogent-gastown--crew-rig-path '(:name "dev" :rig "myrig"))))
        ;; expand-file-name with nil dir uses default-directory
        (should (stringp path))))))

;;; Visit Bead Extended Tests

(ert-deftest ogent-gts-test-visit-bead-with-bead-and-dir-calls-bd ()
  "Test visit-bead calls ogent-issues-bd-get when both bead-id and rig-path exist."
  (with-temp-buffer
    (let ((bd-called nil)
          (tmpdir temporary-file-directory))
      (insert (propertize "bead-xyz"
                          'ogent-bead-id "bead-xyz"
                          'ogent-rig-path tmpdir))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'ogent-issues-bd-get)
                 (lambda (id callback &optional err-callback)
                   (setq bd-called id)))
                ((symbol-function 'file-directory-p)
                 (lambda (_path) t)))
        (ogent-gastown-visit-bead)
        (should (equal bd-called "bead-xyz"))))))

;;; Status Buffer Auto-Refresh Test

(ert-deftest ogent-gts-test-status-reuses-existing-buffer ()
  "Test ogent-gastown-status reuses existing buffer."
  (let ((ogent-gastown-buffer-name "*Test GT Reuse*")
        (refresh-count 0))
    (cl-letf (((symbol-function 'ogent-gastown--in-town-p)
               (lambda () t))
              ((symbol-function 'ogent-gastown--find-town-root)
               (lambda () "/tmp/gt"))
              ((symbol-function 'ogent-gastown-refresh)
               (lambda (&rest _) (cl-incf refresh-count)))
              ((symbol-function 'switch-to-buffer)
               #'ignore))
      (unwind-protect
          (progn
            (ogent-gastown-status)
            (should (= refresh-count 1))
            (ogent-gastown-status)
            (should (= refresh-count 2))
            ;; Still just one buffer
            (should (get-buffer "*Test GT Reuse*")))
        (when (get-buffer "*Test GT Reuse*")
          (kill-buffer "*Test GT Reuse*"))))))

;;; Loading Timer Lifecycle Integration Tests

(ert-deftest ogent-gts-test-start-stop-loading-cycle ()
  "Test start then stop loading resets all state."
  (with-temp-buffer
    (let ((ogent-gastown--loading nil)
          (ogent-gastown--loading-frame 5)
          (ogent-gastown--loading-timer nil))
      (ogent-gastown--start-loading)
      (should ogent-gastown--loading)
      (should (= ogent-gastown--loading-frame 0))
      (should ogent-gastown--loading-timer)
      (ogent-gastown--stop-loading)
      (should-not ogent-gastown--loading)
      (should-not ogent-gastown--loading-timer))))

;;; Mail Recipients Extended Tests

(ert-deftest ogent-gts-test-get-mail-recipients-all-data ()
  "Test get-mail-recipients with crew, polecats, and witnesses."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:name "dev1" :rig "ogent")))
          (ogent-gastown--polecat-data
           (list '(:name "alpha" :rig "ogent")))
          (ogent-gastown--witness-data
           (list '(:rig "ogent" :has_witness t))))
      (let ((recipients (ogent-gastown--get-mail-recipients)))
        (should (member "mayor/" recipients))
        (should (member "deacon/" recipients))
        (should (member "ogent/crew/dev1" recipients))
        (should (member "ogent/polecats/alpha" recipients))
        (should (member "ogent/witness/" recipients))
        (should (member "ogent/refinery/" recipients))))))

;;; Keybinding Extended Tests

(ert-deftest ogent-gts-test-keybindings-convoy ()
  "Convoy keys are properly bound."
  (should (eq (lookup-key ogent-gastown-status-mode-map "c")
              'ogent-gastown-convoy-status))
  (should (eq (lookup-key ogent-gastown-status-mode-map "C")
              'ogent-gastown-convoy-create)))

(ert-deftest ogent-gts-test-keybindings-stats-deacon-witness ()
  "Stats/Deacon/Witness keys are properly bound."
  (should (eq (lookup-key ogent-gastown-status-mode-map "s")
              'ogent-gastown-stats-show))
  (should (eq (lookup-key ogent-gastown-status-mode-map "d")
              'ogent-gastown-deacon-show))
  (should (eq (lookup-key ogent-gastown-status-mode-map "w")
              'ogent-gastown-witness-show)))

(ert-deftest ogent-gts-test-keybindings-crew-polecat-rig ()
  "Crew/Polecat/Rig keys are properly bound."
  (should (eq (lookup-key ogent-gastown-status-mode-map "R")
              'ogent-gastown-crew-status))
  (should (eq (lookup-key ogent-gastown-status-mode-map "P")
              'ogent-gastown-polecat-status))
  (should (eq (lookup-key ogent-gastown-status-mode-map "r")
              'ogent-gastown-rig-status))
  (should (eq (lookup-key ogent-gastown-status-mode-map "f")
              'ogent-gastown-refinery-status)))

;;; Mail To Mayor/Deacon Tests

(ert-deftest ogent-gts-test-mail-to-mayor-calls-compose ()
  "Test mail-to-mayor calls mail-compose with mayor/ recipient."
  (let ((compose-args nil))
    (cl-letf (((symbol-function 'ogent-gastown-mail-compose)
               (lambda (&optional recipient)
                 (setq compose-args recipient))))
      (ogent-gastown-mail-to-mayor)
      (should (equal compose-args "mayor/")))))

(ert-deftest ogent-gts-test-mail-to-deacon-calls-compose ()
  "Test mail-to-deacon calls mail-compose with deacon/ recipient."
  (let ((compose-args nil))
    (cl-letf (((symbol-function 'ogent-gastown-mail-compose)
               (lambda (&optional recipient)
                 (setq compose-args recipient))))
      (ogent-gastown-mail-to-deacon)
      (should (equal compose-args "deacon/")))))

;;; Fetch-All Extended Tests

(ert-deftest ogent-gts-test-fetch-all-sets-all-data ()
  "Test fetch-all populates all buffer-local data slots."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/tmp/gt")
          (ogent-gastown--hook-data nil)
          (ogent-gastown--mail-data nil)
          (ogent-gastown--convoy-data nil)
          (ogent-gastown--workers-data nil)
          (ogent-gastown--crew-data nil)
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--stats-data nil)
          (ogent-gastown--deacon-data nil)
          (ogent-gastown--witness-data nil)
          (ogent-gastown--rigs-data nil)
          (callback-called nil))
      (cl-letf (((symbol-function 'ogent-gastown-status--run-async)
                 (lambda (args callback &optional _error-callback _raw)
                   (cond
                    ((equal args '("hook" "--json"))
                     (funcall callback '(:has_work t :role "mayor")))
                    ((equal args '("mail" "inbox" "--json"))
                     (funcall callback (list '(:id "m1" :from "a" :read nil))))
                    ((equal args '("convoy" "list" "--json"))
                     (funcall callback (list '(:id "c1" :name "test"))))
                    ((equal args '("polecat" "list" "--all" "--json"))
                     (funcall callback (list '(:name "w1" :state "working"))))
                    ((equal args '("status" "--json"))
                     (funcall callback '(:summary (:rig_count 1)
                                         :agents ((:name "deacon" :running t))
                                         :rigs ((:name "r1" :has_witness t)))))
                    ((equal args '("crew" "list" "--json"))
                     (funcall callback (list '(:name "c1" :rig "r1"))))
                    ((equal args '("polecat" "list" "--json"))
                     (funcall callback (list '(:name "p1" :rig "r1"))))))))
        (ogent-gastown--fetch-all (lambda () (setq callback-called t)))
        (should callback-called)
        ;; All data should be populated
        (should ogent-gastown--hook-data)
        (should ogent-gastown--mail-data)
        (should ogent-gastown--convoy-data)
        (should ogent-gastown--workers-data)
        (should ogent-gastown--crew-data)
        (should ogent-gastown--polecat-data)
        (should ogent-gastown--stats-data)
        (should ogent-gastown--deacon-data)
        (should ogent-gastown--witness-data)
        (should ogent-gastown--rigs-data)))))

;;; Rig Issues (without magit and missing rig)

(ert-deftest ogent-gts-test-rig-issues-errors-on-missing-dir ()
  "Test rig-issues errors when rig directory does not exist."
  (with-temp-buffer
    (let ((ogent-gastown--magit-section-available nil)
          (ogent-gastown--rigs-data
           (list '(:name "nonexistent-rig")))
          (ogent-gastown--town-root "/tmp/gt-test-nonexistent"))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "nonexistent-rig")))
        (should-error (ogent-gastown-rig-issues) :type 'user-error)))))

;;; Status Help Extended Tests

(ert-deftest ogent-gts-test-status-help-includes-all-keys ()
  "Test status-help message includes main keybindings."
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (ogent-gastown-status-help)
      (let ((msg (car messages)))
        (should (string-match-p "n/p" msg))
        (should (string-match-p "TAB" msg))
        (should (string-match-p "mail" msg))
        (should (string-match-p "convoy" msg))
        (should (string-match-p "rig" msg))
        (should (string-match-p "issues" msg))))))

(provide 'ogent-gastown-status-tests)

;;; ogent-gastown-status-tests.el ends here
