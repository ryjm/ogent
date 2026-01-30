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
  (should (eq (lookup-key ogent-gastown-mode-map (kbd "h"))
              'ogent-gastown-status-dispatch))
  (should (eq (lookup-key ogent-gastown-mode-map (kbd "?"))
              'ogent-gastown-status-dispatch)))

(ert-deftest ogent-gts-test-keybindings-hook ()
  "Hook actions use magit-style bindings."
  (should (eq (lookup-key ogent-gastown-mode-map (kbd "H"))
              'ogent-gastown-hook-show))
  (should (eq (lookup-key ogent-gastown-mode-map (kbd "a"))
              'ogent-gastown-hook-attach)))

(provide 'ogent-gastown-status-tests)

;;; ogent-gastown-status-tests.el ends here
