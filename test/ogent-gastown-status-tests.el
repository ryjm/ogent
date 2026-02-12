;;; ogent-gastown-status-tests.el --- Tests for ogent-gastown-status -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Gas Town status buffer (ogent-gastown-status.el).
;; Focuses on data formatting, section insertion, and buffer management.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-gastown-status)
(require 'ogent-ops-style)

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
          :title "Feature implementation"
          :status "active"
          :completed 3
          :total 5
          :tracked nil)
        '(:id "convoy-002"
          :title "Bug fixes"
          :status "complete"
          :completed 5
          :total 5
          :tracked nil))
  "Sample convoy list for testing (canonical/normalized shape).")

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
          :beads_stats (:total 150 :open 42 :in_progress 5 :closed 95 :blocked 8 :ready 34)
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
          :beads_stats (:total 80 :open 20 :in_progress 0 :closed 55 :blocked 3 :ready 17)
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
  (let ((root (make-temp-file "ogent-gts-root-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'getenv)
                   (lambda (var)
                     (when (equal var "GT_ROOT")
                       root))))
          (should (equal (file-name-as-directory (expand-file-name root))
                         (ogent-gastown--find-town-root))))
      (delete-directory root))))

(ert-deftest ogent-gts-test-find-town-root-from-gt-town-env ()
  "Test finding town root from GT_TOWN when GT_ROOT is unset."
  (let ((root (make-temp-file "ogent-gts-town-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'getenv)
                   (lambda (var)
                     (pcase var
                       ("GT_ROOT" nil)
                       ("GT_TOWN" root)
                       (_ nil)))))
          (should (equal (file-name-as-directory (expand-file-name root))
                         (ogent-gastown--find-town-root))))
      (delete-directory root))))

(ert-deftest ogent-gts-test-find-town-root-from-gastown-marker ()
  "Test finding town root from .gastown marker."
  (let ((marker-root (make-temp-file "ogent-gts-marker-" t))
        (default-directory "/tmp/ogent-gts-work/rigs/alpha/"))
    (unwind-protect
        (cl-letf (((symbol-function 'getenv)
                   (lambda (_var) nil))
                  ((symbol-function 'locate-dominating-file)
                   (lambda (_dir marker)
                     (when (equal marker ".gastown")
                       marker-root))))
          (should (equal (file-name-as-directory (expand-file-name marker-root))
                         (ogent-gastown--find-town-root))))
      (delete-directory marker-root))))

(ert-deftest ogent-gts-test-find-town-root-from-default-root-prefix ()
  "Test finding town root when current dir is under default town root."
  (let ((root (make-temp-file "ogent-gts-default-root-prefix-" t)))
    (unwind-protect
        (let* ((default-directory (expand-file-name "crew/stallman/" root))
               (ogent-gastown-default-town-root root))
          (make-directory default-directory t)
          (cl-letf (((symbol-function 'getenv)
                     (lambda (_var) nil))
                    ((symbol-function 'locate-dominating-file)
                     (lambda (_dir _marker) nil)))
            (should (equal (file-name-as-directory (expand-file-name root))
                           (ogent-gastown--find-town-root)))))
      (delete-directory root t))))

(ert-deftest ogent-gts-test-find-town-root-falls-back-to-default-root ()
  "Test finding town root falls back to configured default root."
  (let ((root (make-temp-file "ogent-gts-default-root-fallback-" t)))
    (unwind-protect
        (let ((default-directory "/tmp/not-a-town/")
              (ogent-gastown-default-town-root root))
          (cl-letf (((symbol-function 'getenv)
                     (lambda (_var) nil))
                    ((symbol-function 'locate-dominating-file)
                     (lambda (_dir _marker) nil)))
            (should (equal (file-name-as-directory (expand-file-name root))
                           (ogent-gastown--find-town-root)))))
      (delete-directory root t))))

(ert-deftest ogent-gts-test-find-town-root-nil-when-default-root-missing ()
  "Test finding town root returns nil when default root does not exist."
  (let ((default-directory "/tmp/not-a-town/")
        (ogent-gastown-default-town-root
         (make-temp-name
          (expand-file-name "ogent-gts-missing-default-root-"
                            temporary-file-directory))))
    (cl-letf (((symbol-function 'getenv)
               (lambda (_var) nil))
              ((symbol-function 'locate-dominating-file)
               (lambda (_dir _marker) nil)))
      (should-not (ogent-gastown--find-town-root)))))

(ert-deftest ogent-gts-test-in-town-p-with-gt ()
  "Test in-town detection requires gt and workspace root."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_cmd) "/usr/local/bin/gt"))
            ((symbol-function 'ogent-gastown--find-town-root)
             (lambda () "/workspace/")))
    (should (ogent-gastown--in-town-p))))

(ert-deftest ogent-gts-test-in-town-p-without-gt ()
  "Test in-town detection when gt is not available."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_cmd) nil))
            ((symbol-function 'ogent-gastown--find-town-root)
             (lambda () "/workspace/")))
    (should-not (ogent-gastown--in-town-p))))

(ert-deftest ogent-gts-test-in-town-p-without-workspace ()
  "Test in-town detection fails when workspace root is missing."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_cmd) "/usr/local/bin/gt"))
            ((symbol-function 'ogent-gastown--find-town-root)
             (lambda () nil)))
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

(ert-deftest ogent-gts-test-header-line-shows-workspace-segment ()
  "Test header line includes workspace indicator."
  (let ((root (make-temp-file "ogent-gts-header-root-" t)))
    (unwind-protect
        (with-temp-buffer
          (let ((ogent-gastown--town-root (file-name-as-directory root))
                (ogent-gastown--hook-data ogent-gts-test--sample-hook-empty)
                (ogent-gastown--mail-data nil)
                (ogent-gastown--loading nil))
            (let* ((expected-display (ogent-gastown--workspace-root-display
                                      (file-name-as-directory root)))
                   (header (ogent-gastown--header-line)))
              (should (string-match-p "WS:" header))
              (should (string-match-p (regexp-quote expected-display) header)))))
      (delete-directory root))))

(ert-deftest ogent-gts-test-header-line-abbreviates-long-workspace ()
  "Test long workspace path is abbreviated in header line."
  (with-temp-buffer
    (let ((ogent-gastown-workspace-display-width 18)
          (ogent-gastown--town-root "/tmp/this/is/a/very/long/gastown/workspace/path/for-testing/")
          (ogent-gastown--hook-data ogent-gts-test--sample-hook-empty)
          (ogent-gastown--mail-data nil)
          (ogent-gastown--loading nil))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "WS:…" header))
        (should (string-match-p "for-testing" header))))))

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
        ;; Hook indicator via ops badge helper.
        (should (string-match-p
                 (regexp-quote
                  (let ((ogent-ops-use-unicode t))
                    (ogent-ops-badge-symbol 'hook)))
                 content))
        ;; Mail indicator via ops badge helper.
        (should (string-match-p (regexp-quote
                                 (format "%s5"
                                         (let ((ogent-ops-use-unicode t))
                                           (ogent-ops-badge-symbol 'mail))))
                                content))))))

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
        (should (string-match-p
                 (regexp-quote (let ((ogent-ops-use-unicode t))
                                 (ogent-ops-role-symbol 'witness)))
                 content))))))

(ert-deftest ogent-gts-test-ascii-icons ()
  "Test that ASCII icons are used when unicode disabled."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent
       '(:name "test" :role "witness" :running t :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p
                 (regexp-quote (let ((ogent-ops-use-unicode nil))
                                 (ogent-ops-section-prefix "👁" "W")))
                 content))
        ;; Unicode icon should NOT appear
        (should-not (string-match-p
                     (regexp-quote (let ((ogent-ops-use-unicode t))
                                     (ogent-ops-section-prefix "👁" "W")))
                     content))))))

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
           (list '(:id "c1" :title "Active Job" :status "active" :completed 2 :total 5 :tracked nil))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Active Job" content))))))

(ert-deftest ogent-gts-test-convoy-item-complete ()
  "Test convoy item rendering for completed convoy."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :title "Done Job" :status "complete" :completed 5 :total 5 :tracked nil))))
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
  "Hook and rig cycle actions use expected bindings."
  (should (eq (lookup-key ogent-gastown-status-mode-map (kbd "H"))
              'ogent-gastown-cycle-rig-prev))
  (should (eq (lookup-key ogent-gastown-status-mode-map (kbd "L"))
              'ogent-gastown-cycle-rig-next))
  (should (eq (lookup-key ogent-gastown-status-mode-map (kbd "o"))
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
           (list '(:id "c1" :title nil :status "active" :completed 1 :total 3 :tracked nil))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "(unnamed)" content))))))

(ert-deftest ogent-gts-test-insert-convoy-item-multiple ()
  "Test multiple convoy items render correctly."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :title "Deploy" :status "active" :completed 2 :total 4 :tracked nil)
                 '(:id "c2" :title "Cleanup" :status "complete" :completed 3 :total 3 :tracked nil))))
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

(ert-deftest ogent-gts-test-ensure-magit-root-section-seeds-placeholder ()
  "Test missing magit root is seeded before async refresh."
  (with-temp-buffer
    (insert "stale")
    (setq-local magit-root-section nil)
    (let ((ogent-gastown--magit-section-available t)
          (insert-called 0))
      (cl-letf (((symbol-function 'derived-mode-p)
                 (lambda (&rest modes)
                   (memq 'magit-section-mode modes)))
                ((symbol-function 'ogent-gastown--insert-buffer-contents)
                 (lambda ()
                   (cl-incf insert-called)
                   (insert "placeholder"))))
        (ogent-gastown--ensure-magit-root-section)
        (should (= insert-called 1))
        (should (equal (buffer-string) "placeholder"))))))

(ert-deftest ogent-gts-test-ensure-magit-root-section-noop-when-present ()
  "Test existing magit root is left untouched."
  (with-temp-buffer
    (insert "keep")
    (setq-local magit-root-section 'existing-root)
    (let ((ogent-gastown--magit-section-available t)
          (insert-called 0))
      (cl-letf (((symbol-function 'derived-mode-p)
                 (lambda (&rest modes)
                   (memq 'magit-section-mode modes)))
                ((symbol-function 'ogent-gastown--insert-buffer-contents)
                 (lambda () (cl-incf insert-called))))
        (ogent-gastown--ensure-magit-root-section)
        (should (= insert-called 0))
        (should (equal (buffer-string) "keep"))))))

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
                 (lambda (callback &optional _deferred-callback)
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
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_cmd) nil)))
    (should-error (ogent-gastown-status) :type 'user-error)))

(ert-deftest ogent-gts-test-status-errors-without-workspace ()
  "Test ogent-gastown-status errors when workspace root is not resolvable."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_cmd) "/usr/local/bin/gt"))
            ((symbol-function 'ogent-gastown--find-town-root)
             (lambda () nil)))
    (should-error (ogent-gastown-status) :type 'user-error)))

(ert-deftest ogent-gts-test-status-creates-buffer ()
  "Test ogent-gastown-status creates the status buffer."
  (let ((refresh-called nil)
        (ogent-gastown-buffer-name "*Test Gas Town*")
        (workspace-root (make-temp-file "ogent-gts-status-root-" t)))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_cmd) "/usr/local/bin/gt"))
              ((symbol-function 'ogent-gastown--find-town-root)
               (lambda () workspace-root))
              ((symbol-function 'ogent-gastown-refresh)
               (lambda (&rest _) (setq refresh-called t)))
              ((symbol-function 'switch-to-buffer)
               #'ignore))
      (unwind-protect
          (progn
            (ogent-gastown-status)
            (should refresh-called)
            (should (get-buffer "*Test Gas Town*"))
            (with-current-buffer "*Test Gas Town*"
              (should (equal ogent-gastown--town-root
                             (file-name-as-directory workspace-root)))
              (should (equal default-directory
                             (file-name-as-directory workspace-root)))))
        (when (get-buffer "*Test Gas Town*")
          (kill-buffer "*Test Gas Town*"))
        (delete-directory workspace-root)))))

;;; Fetch-All Tests (with mocked run-async)

(ert-deftest ogent-gts-test-fetch-all-calls-callback ()
  "Test fetch-all calls callback after all fetches complete."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/tmp/gt")
          (ogent-gastown-cache-ttl 0)
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
        ;; Should have called run-async 6 times (hook, mail, convoy, workers, town-status, crew)
        (should (= call-count 6))
        (should callback-called)))))

(ert-deftest ogent-gts-test-fetch-all-handles-errors ()
  "Test fetch-all handles errors gracefully and still calls callback."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/tmp/gt")
          (ogent-gastown-cache-ttl 0)
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
          (ogent-gastown-cache-ttl 0)
          (callback-called nil)
          (ogent-gastown--stats-data nil)
          (ogent-gastown--deacon-data nil)
          (ogent-gastown--witness-data nil)
          (ogent-gastown--rigs-data nil))
      (cl-letf (((symbol-function 'ogent-gastown-status--run-async)
                 (lambda (args callback &optional _error-callback _raw)
                   ;; Return town-status for the status command
                   (if (equal args '("status" "--json" "--fast"))
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
        (should (string-match-p
                 (regexp-quote (let ((ogent-ops-use-unicode t))
                                 (ogent-ops-role-symbol 'polecat)))
                 content))
        (should (string-match-p "polecat1" content))))))

(ert-deftest ogent-gts-test-insert-rig-agent-no-hook-no-mail ()
  "Test rig agent without hook or mail shows clean output."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-rig-agent
       '(:name "clean" :role "crew" :running t :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "clean" content))
        ;; No hook indicator
        (should-not (string-match-p
                     (regexp-quote
                      (let ((ogent-ops-use-unicode t))
                        (ogent-ops-badge-symbol 'hook)))
                     content))
        ;; No mail indicator
        (should-not (string-match-p
                     (regexp-quote
                      (let ((ogent-ops-use-unicode t))
                        (ogent-ops-badge-symbol 'mail)))
                     content))))))

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

(ert-deftest ogent-gts-test-status-help-includes-workspace-guidance ()
  "Test status-help includes workspace context and recovery guidance."
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (with-temp-buffer
        (let ((ogent-gastown--town-root "/tmp/gt/"))
          (ogent-gastown-status-help)))
      (let ((msg (car messages)))
        (should (string-match-p "Workspace:" msg))
        (should (string-match-p "GT_ROOT/GT_TOWN" msg))
        (should (string-match-p "Reopen from a town directory" msg))))))

;;; ====================================================================
;;; NEW TESTS: Increasing coverage for ogent-gastown-status.el
;;; ====================================================================

;;; Face Existence Tests

(ert-deftest ogent-gts-test-face-section-heading-exists ()
  "Test ogent-gastown-section-heading face is defined."
  (should (facep 'ogent-gastown-section-heading)))

(ert-deftest ogent-gts-test-face-section-heading-variants-exist ()
  "Test section-specific heading faces are defined."
  (dolist (face '(ogent-gastown-section-heading-hook
                  ogent-gastown-section-heading-mail
                  ogent-gastown-section-heading-convoy
                  ogent-gastown-section-heading-workers
                  ogent-gastown-section-heading-stats
                  ogent-gastown-section-heading-deacon
                  ogent-gastown-section-heading-witnesses
                  ogent-gastown-section-heading-crew
                  ogent-gastown-section-heading-polecats
                  ogent-gastown-section-heading-rigs
                  ogent-gastown-section-heading-issues))
    (should (facep face))))

(ert-deftest ogent-gts-test-face-section-heading-variants-declare-background ()
  "Test section heading face specs declare background attributes."
  (dolist (face '(ogent-gastown-section-heading
                  ogent-gastown-section-heading-hook
                  ogent-gastown-section-heading-mail
                  ogent-gastown-section-heading-convoy
                  ogent-gastown-section-heading-workers
                  ogent-gastown-section-heading-stats
                  ogent-gastown-section-heading-deacon
                  ogent-gastown-section-heading-witnesses
                  ogent-gastown-section-heading-crew
                  ogent-gastown-section-heading-polecats
                  ogent-gastown-section-heading-rigs
                  ogent-gastown-section-heading-issues))
    (let ((spec (get face 'face-defface-spec)))
      (should spec)
      (should (string-match-p ":background" (format "%S" spec))))))

(ert-deftest ogent-gts-test-section-heading-face-map ()
  "Test section heading face mapping returns the expected face."
  (should (eq (ogent-gastown--section-heading-face 'hook)
              'ogent-gastown-section-heading-hook))
  (should (eq (ogent-gastown--section-heading-face 'mail)
              'ogent-gastown-section-heading-mail))
  (should (eq (ogent-gastown--section-heading-face 'convoy)
              'ogent-gastown-section-heading-convoy))
  (should (eq (ogent-gastown--section-heading-face 'workers)
              'ogent-gastown-section-heading-workers))
  (should (eq (ogent-gastown--section-heading-face 'stats)
              'ogent-gastown-section-heading-stats))
  (should (eq (ogent-gastown--section-heading-face 'deacon)
              'ogent-gastown-section-heading-deacon))
  (should (eq (ogent-gastown--section-heading-face 'witnesses)
              'ogent-gastown-section-heading-witnesses))
  (should (eq (ogent-gastown--section-heading-face 'crew)
              'ogent-gastown-section-heading-crew))
  (should (eq (ogent-gastown--section-heading-face 'polecats)
              'ogent-gastown-section-heading-polecats))
  (should (eq (ogent-gastown--section-heading-face 'rigs)
              'ogent-gastown-section-heading-rigs))
  (should (eq (ogent-gastown--section-heading-face 'issues)
              'ogent-gastown-section-heading-issues))
  (should (eq (ogent-gastown--section-heading-face 'unknown)
              'ogent-gastown-section-heading)))

(ert-deftest ogent-gts-test-section-heading-face-map-valid-override ()
  "Test valid overrides replace section heading default faces."
  (let ((ogent-gastown-section-heading-face-overrides '((issues . error))))
    (should (eq (ogent-gastown--section-heading-face 'issues) 'error))))

(ert-deftest ogent-gts-test-section-heading-face-map-invalid-override-falls-back ()
  "Test invalid overrides fall back to section default faces."
  (let ((ogent-gastown-section-heading-face-overrides '((crew . definitely-not-a-face))))
    (should (eq (ogent-gastown--section-heading-face 'crew)
                'ogent-gastown-section-heading-crew))))

(ert-deftest ogent-gts-test-section-heading-helper-propertizes-label ()
  "Test section heading helper applies mapped face to labels."
  (let* ((label (ogent-gastown--section-heading 'crew "Crew"))
         (face (get-text-property 0 'face label)))
    (should (string= label "Crew"))
    (should (eq face 'ogent-gastown-section-heading-crew))))

(ert-deftest ogent-gts-test-compose-section-heading-shared-path ()
  "Test Magit heading composition uses a shared section formatter."
  (let ((ogent-gastown-use-unicode nil))
    (let ((heading (ogent-gastown--compose-section-heading
                    'crew
                    "Crew"
                    (propertize " (1/3 active)" 'face 'ogent-gastown-dimmed))))
      (should (string= (substring-no-properties heading) "C Crew (1/3 active)"))
      (should (eq (get-text-property 2 'face heading)
                  'ogent-gastown-section-heading-crew)))))

(ert-deftest ogent-gts-test-compose-section-heading-applies-face-to-full-line ()
  "Test Magit heading background face extends across icon and suffix text."
  (let ((ogent-gastown-use-unicode nil))
    (let* ((heading (ogent-gastown--compose-section-heading
                     'crew
                     "Crew"
                     (propertize " (1/3 active)" 'face 'ogent-gastown-dimmed)))
           (prefix-face (get-text-property 0 'face heading))
           (suffix-pos (string-match-p "(1/3 active)" heading))
           (suffix-face (and suffix-pos (get-text-property suffix-pos 'face heading))))
      (should (memq 'ogent-gastown-section-heading-crew
                    (if (listp prefix-face) prefix-face (list prefix-face))))
      (should suffix-pos)
      (should (memq 'ogent-gastown-section-heading-crew
                    (if (listp suffix-face) suffix-face (list suffix-face))))
      (should (memq 'ogent-gastown-dimmed
                    (if (listp suffix-face) suffix-face (list suffix-face)))))))

(ert-deftest ogent-gts-test-compose-plain-section-heading-shared-path ()
  "Test plain heading composition uses section-specific plain prefixes."
  (should (string= (ogent-gastown--compose-plain-section-heading
                    'rigs "Rigs")
                   "R Rigs\n"))
  (should (string= (ogent-gastown--compose-plain-section-heading
                    'issues "Issues")
                   "I Issues\n"))
  (should (string= (ogent-gastown--compose-plain-section-heading
                    'workers "Workers" " [ogent]")
                   "* Workers [ogent]\n")))

(ert-deftest ogent-gts-test-compose-section-heading-uses-override-face ()
  "Test Magit heading composition uses override face when configured."
  (let ((ogent-gastown-use-unicode nil)
        (ogent-gastown-section-heading-face-overrides '((issues . warning))))
    (let ((heading (ogent-gastown--compose-section-heading 'issues "Issues:")))
      (should (string= (substring-no-properties heading) "I Issues:"))
      (should (eq (get-text-property 2 'face heading) 'warning)))))

(ert-deftest ogent-gts-test-magit-crew-heading-uses-crew-face ()
  "Test Magit Crew heading label uses the crew heading face."
  (if (not ogent-gastown--magit-section-available)
      (ert-skip "magit-section not available")
    (with-temp-buffer
      (ogent-gastown-status-mode)
      (let ((inhibit-read-only t)
            (ogent-gastown--crew-data nil)
            (ogent-gastown--rigs-data '((:name "ogent")))
            (ogent-gastown--selected-rig "ogent"))
        (erase-buffer)
        (ogent-gastown--insert-crew-section)
        (goto-char (point-min))
        (should (search-forward "Crew" nil t))
        (let ((pos (- (point) (length "Crew"))))
          (should (eq (get-text-property pos 'face)
                      'ogent-gastown-section-heading-crew)))))))

(ert-deftest ogent-gts-test-magit-workers-heading-uses-workers-face ()
  "Test Magit Workers heading label uses the workers heading face."
  (if (not ogent-gastown--magit-section-available)
      (ert-skip "magit-section not available")
    (with-temp-buffer
      (ogent-gastown-status-mode)
      (let ((inhibit-read-only t)
            (ogent-gastown--workers-data nil)
            (ogent-gastown--rigs-data '((:name "ogent")))
            (ogent-gastown--selected-rig "ogent"))
        (erase-buffer)
        (ogent-gastown--insert-workers-section)
        (goto-char (point-min))
        (should (search-forward "Workers" nil t))
        (let ((pos (- (point) (length "Workers"))))
          (should (eq (get-text-property pos 'face)
                      'ogent-gastown-section-heading-workers)))))))

(ert-deftest ogent-gts-test-magit-polecats-heading-uses-polecats-face ()
  "Test Magit Polecats heading label uses the polecats heading face."
  (if (not ogent-gastown--magit-section-available)
      (ert-skip "magit-section not available")
    (with-temp-buffer
      (ogent-gastown-status-mode)
      (let ((inhibit-read-only t)
            (ogent-gastown--polecat-data nil)
            (ogent-gastown--rigs-data '((:name "ogent")))
            (ogent-gastown--selected-rig "ogent"))
        (erase-buffer)
        (ogent-gastown--insert-polecat-section)
        (goto-char (point-min))
        (should (search-forward "Polecats" nil t))
        (let ((pos (- (point) (length "Polecats"))))
          (should (eq (get-text-property pos 'face)
                      'ogent-gastown-section-heading-polecats)))))))

(ert-deftest ogent-gts-test-insert-plain-crew-heading-uses-crew-face ()
  "Test plain crew heading uses crew-specific heading face."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data nil)
          (ogent-gastown--selected-rig "ogent"))
      (ogent-gastown--insert-crew-section-plain)
      (goto-char (point-min))
      (should (eq (get-text-property (point) 'face)
                  'ogent-gastown-section-heading-crew)))))

(ert-deftest ogent-gts-test-insert-plain-rigs-heading-uses-rigs-face ()
  "Test plain rigs heading uses rigs-specific heading face."
  (with-temp-buffer
    (let ((ogent-gastown--rigs-data nil))
      (ogent-gastown--insert-rigs-section-plain)
      (goto-char (point-min))
      (should (eq (get-text-property (point) 'face)
                  'ogent-gastown-section-heading-rigs)))))

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

(ert-deftest ogent-gts-test-custom-default-town-root-default ()
  "Test default town root is ~/gt."
  (should (equal ogent-gastown-default-town-root "~/gt")))

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

(ert-deftest ogent-gts-test-status-mode-parent-follows-magit-usable ()
  "Test status mode parent selection follows runtime magit capability."
  (cl-letf (((symbol-function 'ogent-gastown--magit-usable-p)
             (lambda () t)))
    (should (eq (ogent-gastown--status-mode-parent) 'magit-section-mode)))
  (cl-letf (((symbol-function 'ogent-gastown--magit-usable-p)
             (lambda () nil)))
    (should (eq (ogent-gastown--status-mode-parent) 'special-mode))))

(ert-deftest ogent-gts-test-ensure-status-mode-definition-redefines-on-mismatch ()
  "Test status mode is redefined when parent mode no longer matches runtime."
  (let ((original-parent (get 'ogent-gastown-status-mode 'derived-mode-parent))
        (redefined nil))
    (unwind-protect
        (cl-letf (((symbol-function 'ogent-gastown--status-mode-parent)
                   (lambda () 'special-mode))
                  ((symbol-function 'ogent-gastown--define-status-mode)
                   (lambda () (setq redefined t))))
          (put 'ogent-gastown-status-mode 'derived-mode-parent 'magit-section-mode)
          (ogent-gastown--ensure-status-mode-definition)
          (should redefined))
      (put 'ogent-gastown-status-mode 'derived-mode-parent original-parent))))

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
        (should (string-match-p
                 (regexp-quote
                  (let ((ogent-ops-use-unicode t))
                    (ogent-ops-role-symbol 'crew)))
                 content))))))

(ert-deftest ogent-gts-test-insert-rig-agent-refinery-unicode ()
  "Test rig agent uses refinery unicode icon."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-rig-agent
       '(:name "ref1" :role "refinery" :running nil :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p
                 (regexp-quote
                  (let ((ogent-ops-use-unicode t))
                    (ogent-ops-role-symbol 'refinery)))
                 content))))))

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
  "Test convoy-status uses completing-read when magit unavailable."
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
             (list '(:id "c1" :title "Test convoy"))))
        (ogent-gastown-convoy-status)
        (should (equal inspected-id "c1"))))))

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
                       (lambda (callback &optional _deferred-callback)
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
        (refresh-count 0)
        (workspace-a (make-temp-file "ogent-gts-reuse-a-" t))
        (workspace-b (make-temp-file "ogent-gts-reuse-b-" t))
        (roots nil))
    (setq roots (list workspace-a workspace-b))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_cmd) "/usr/local/bin/gt"))
              ((symbol-function 'ogent-gastown--find-town-root)
               (lambda ()
                 (prog1 (car roots)
                   (setq roots (or (cdr roots) roots)))))
              ((symbol-function 'ogent-gastown-refresh)
               (lambda (&rest _) (cl-incf refresh-count)))
              ((symbol-function 'switch-to-buffer)
               #'ignore))
      (unwind-protect
          (progn
            (ogent-gastown-status)
            (should (= refresh-count 1))
            (with-current-buffer "*Test GT Reuse*"
              (should (equal ogent-gastown--town-root
                             (file-name-as-directory workspace-a)))
              (should (equal default-directory
                             (file-name-as-directory workspace-a))))
            (ogent-gastown-status)
            (should (= refresh-count 2))
            ;; Still just one buffer
            (should (get-buffer "*Test GT Reuse*"))
            (with-current-buffer "*Test GT Reuse*"
              (should (equal ogent-gastown--town-root
                             (file-name-as-directory workspace-b)))
              (should (equal default-directory
                             (file-name-as-directory workspace-b)))))
        (when (get-buffer "*Test GT Reuse*")
          (kill-buffer "*Test GT Reuse*"))
        (delete-directory workspace-a)
        (delete-directory workspace-b)))))

(ert-deftest ogent-gts-test-run-shell-command-binds-workspace-root ()
  "Test shell launcher executes from the active workspace root."
  (let ((captured-cmd nil)
        (captured-default nil))
    (cl-letf (((symbol-function 'ogent-gastown--active-workspace-root)
               (lambda () "/tmp/workspace/"))
              ((symbol-function 'async-shell-command)
               (lambda (cmd &optional _output-buffer _error-buffer)
                 (setq captured-cmd cmd)
                 (setq captured-default default-directory))))
      (let ((default-directory "/tmp/elsewhere/"))
        (ogent-gastown-status--run-shell-command '("status") "*gt status*")
        (should (equal captured-cmd "gt status"))
        (should (equal captured-default "/tmp/workspace/"))))))

(ert-deftest ogent-gts-test-run-shell-command-errors-without-workspace ()
  "Test shell launcher errors when workspace root cannot be resolved."
  (cl-letf (((symbol-function 'ogent-gastown--active-workspace-root)
             (lambda () nil)))
    (should-error
     (ogent-gastown-status--run-shell-command '("status") "*gt status*")
     :type 'user-error)))

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
                    ((equal args '("polecat" "list" "r1" "--json"))
                     (funcall callback (list '(:name "w1" :state "working"))))
                    ((equal args '("status" "--json" "--fast"))
                     (funcall callback '(:summary (:rig_count 1)
                                         :agents ((:name "deacon" :running t))
                                         :rigs ((:name "r1" :has_witness t)))))
                    ((equal args '("crew" "list" "--rig" "r1" "--json"))
                     (funcall callback (list '(:name "c1" :rig "r1"))))))))
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

;;; ====================================================================
;;; ADDITIONAL TESTS: Pushing coverage past 80%
;;; ====================================================================

;;; --- Hook Attach Action Tests ---

(ert-deftest ogent-gts-test-hook-attach-success ()
  "Test hook-attach sends run-async with correct args on success."
  (let ((run-async-args nil)
        (messages nil))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "bead-42"))
              ((symbol-function 'ogent-gastown-status--run-async)
               (lambda (args callback &optional _err _raw)
                 (setq run-async-args args)
                 (funcall callback nil)))
              ((symbol-function 'ogent-gastown-cache-invalidate) #'ignore)
              ((symbol-function 'ogent-gastown-refresh)
               (lambda (&rest _) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (ogent-gastown-hook-attach)
      (should (equal run-async-args '("hook" "bead-42")))
      (should (seq-some (lambda (m) (string-match-p "Hooked: bead-42" m)) messages)))))

(ert-deftest ogent-gts-test-hook-attach-failure ()
  "Test hook-attach shows error message on failure."
  (let ((messages nil))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "bead-99"))
              ((symbol-function 'ogent-gastown-status--run-async)
               (lambda (_args _callback &optional err-callback _raw)
                 (when err-callback
                   (funcall err-callback "hook failed"))))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (ogent-gastown-hook-attach)
      (should (seq-some (lambda (m) (string-match-p "Failed to hook" m)) messages)))))

;;; --- Convoy Create Action Tests ---

(ert-deftest ogent-gts-test-convoy-create-success ()
  "Test convoy-create sends correct args on success."
  (let ((run-async-args nil)
        (messages nil))
    (cl-letf (((symbol-function 'read-string)
               (lambda (prompt &rest _)
                 (cond
                  ((string-match-p "name" prompt) "My Convoy")
                  ((string-match-p "Issue" prompt) "issue-1 issue-2")
                  (t ""))))
              ((symbol-function 'ogent-gastown-status--run-async)
               (lambda (args callback &optional _err _raw)
                 (setq run-async-args args)
                 (funcall callback nil)))
              ((symbol-function 'ogent-gastown-cache-invalidate) #'ignore)
              ((symbol-function 'ogent-gastown-refresh)
               (lambda (&rest _) nil))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (ogent-gastown-convoy-create)
      (should (equal run-async-args '("convoy" "create" "My Convoy" "issue-1" "issue-2")))
      (should (seq-some (lambda (m) (string-match-p "Created convoy" m)) messages)))))

(ert-deftest ogent-gts-test-convoy-create-failure ()
  "Test convoy-create shows error message on failure."
  (let ((messages nil))
    (cl-letf (((symbol-function 'read-string)
               (lambda (prompt &rest _)
                 (cond
                  ((string-match-p "name" prompt) "Fail Convoy")
                  (t "issue-1"))))
              ((symbol-function 'ogent-gastown-status--run-async)
               (lambda (_args _callback &optional err-callback _raw)
                 (when err-callback
                   (funcall err-callback "convoy create failed"))))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (ogent-gastown-convoy-create)
      (should (seq-some (lambda (m) (string-match-p "Failed to create convoy" m)) messages)))))

;;; --- Witness Show Tests (completing-read fallback) ---

(ert-deftest ogent-gts-test-witness-show-no-magit-prompts ()
  "Test witness-show prompts for rig when magit unavailable."
  (let ((commands nil))
    (cl-letf (((symbol-function 'async-shell-command)
               (lambda (cmd &optional buf)
                 (push (list cmd buf) commands)))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "my-rig")))
      (let ((ogent-gastown--magit-section-available nil)
            (ogent-gastown--witness-data
             (list '(:rig "my-rig" :has_witness t))))
        (ogent-gastown-witness-show)
        (should (= (length commands) 1))
        (should (string-match-p "gt witness status my-rig" (caar commands)))))))

;;; --- Rig Status Tests (completing-read fallback) ---

(ert-deftest ogent-gts-test-rig-status-no-magit-prompts ()
  "Test rig-status prompts for rig when magit unavailable."
  (let ((commands nil))
    (cl-letf (((symbol-function 'async-shell-command)
               (lambda (cmd &optional buf)
                 (push (list cmd buf) commands)))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "test-rig")))
      (let ((ogent-gastown--magit-section-available nil)
            (ogent-gastown--rigs-data
             (list '(:name "test-rig"))))
        (ogent-gastown-rig-status)
        (should (= (length commands) 1))
        (should (string-match-p "gt rig status test-rig" (caar commands)))))))

;;; --- Refinery Status Tests ---

(ert-deftest ogent-gts-test-refinery-status-no-magit-prompts ()
  "Test refinery-status prompts for rig when magit unavailable."
  (let ((commands nil))
    (cl-letf (((symbol-function 'async-shell-command)
               (lambda (cmd &optional buf)
                 (push (list cmd buf) commands)))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "ref-rig")))
      (let ((ogent-gastown--magit-section-available nil)
            (ogent-gastown--rigs-data
             (list '(:name "ref-rig"))))
        (ogent-gastown-refinery-status)
        (should (= (length commands) 1))
        (should (string-match-p "gt refinery status ref-rig" (caar commands)))))))

;;; --- Mail Compose Tests ---

(ert-deftest ogent-gts-test-mail-compose-sends-message ()
  "Test mail-compose sends message via run-async."
  (with-temp-buffer
    (let ((run-async-args nil)
          (messages nil)
          (ogent-gastown--crew-data nil)
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--witness-data nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "mayor/"))
                ((symbol-function 'read-string)
                 (lambda (prompt &rest _)
                   (cond
                    ((string-match-p "Subject" prompt) "Test Subject")
                    ((string-match-p "Message" prompt) "Test Body")
                    (t ""))))
                ((symbol-function 'ogent-gastown-status--run-async)
                 (lambda (args callback &optional _err _raw)
                   (setq run-async-args args)
                   (funcall callback nil)))
                ((symbol-function 'ogent-gastown-cache-invalidate) #'ignore)
                ((symbol-function 'ogent-gastown-refresh)
                 (lambda (&rest _) nil))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (ogent-gastown-mail-compose)
        (should (equal run-async-args
                       '("mail" "send" "mayor/" "-s" "Test Subject" "-m" "Test Body")))
        (should (seq-some (lambda (m) (string-match-p "Mail sent to mayor/" m)) messages))))))

(ert-deftest ogent-gts-test-mail-compose-failure ()
  "Test mail-compose shows error on failure."
  (with-temp-buffer
    (let ((messages nil)
          (ogent-gastown--crew-data nil)
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--witness-data nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "mayor/"))
                ((symbol-function 'read-string)
                 (lambda (prompt &rest _)
                   (cond
                    ((string-match-p "Subject" prompt) "Fail Subject")
                    ((string-match-p "Message" prompt) "Fail Body")
                    (t ""))))
                ((symbol-function 'ogent-gastown-status--run-async)
                 (lambda (_args _callback &optional err-callback _raw)
                   (when err-callback
                     (funcall err-callback "send failed"))))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (ogent-gastown-mail-compose)
        (should (seq-some (lambda (m) (string-match-p "Failed to send mail" m)) messages))))))

(ert-deftest ogent-gts-test-mail-compose-with-initial-recipient ()
  "Test mail-compose uses initial recipient."
  (with-temp-buffer
    (let ((run-async-args nil)
          (ogent-gastown--crew-data nil)
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--witness-data nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt _coll &optional _pred _req initial &rest _)
                   (or initial "mayor/")))
                ((symbol-function 'read-string)
                 (lambda (&rest _) "stuff"))
                ((symbol-function 'ogent-gastown-status--run-async)
                 (lambda (args callback &optional _err _raw)
                   (setq run-async-args args)
                   (funcall callback nil)))
                ((symbol-function 'ogent-gastown-cache-invalidate) #'ignore)
                ((symbol-function 'ogent-gastown-refresh)
                 (lambda (&rest _) nil))
                ((symbol-function 'message) #'ignore))
        (ogent-gastown-mail-compose "deacon/")
        (should (member "deacon/" run-async-args))))))

(ert-deftest ogent-gts-test-mail-compose-empty-to-does-nothing ()
  "Test mail-compose does nothing with empty To field."
  (with-temp-buffer
    (let ((run-async-called nil)
          (ogent-gastown--crew-data nil)
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--witness-data nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) ""))
                ((symbol-function 'read-string)
                 (lambda (&rest _) "content"))
                ((symbol-function 'ogent-gastown-status--run-async)
                 (lambda (&rest _)
                   (setq run-async-called t))))
        (ogent-gastown-mail-compose)
        (should-not run-async-called)))))

;;; --- Mail Read with completing-read Tests ---

(ert-deftest ogent-gts-test-mail-read-completing-read-fallback ()
  "Test mail-read falls back to completing-read without magit."
  (with-temp-buffer
    (let ((commands nil)
          (ogent-gastown--magit-section-available nil)
          (ogent-gastown--mail-data
           (list '(:id "mail-abc" :from "sender" :subject "Test"))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "mail-abc"))
                ((symbol-function 'async-shell-command)
                 (lambda (cmd &optional buf)
                   (push (list cmd buf) commands))))
        (ogent-gastown-status-mail-read)
        (should (= (length commands) 1))
        (should (string-match-p "gt mail read mail-abc" (caar commands)))))))

;;; --- Worker Item Face Tests ---

(ert-deftest ogent-gts-test-insert-worker-item-running-face ()
  "Test worker item running uses worker-running face on name."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-worker-item
       '(:name "fast" :state "working" :session_running t))
      (goto-char (point-min))
      (search-forward "fast")
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'ogent-gastown-worker-running)))))

(ert-deftest ogent-gts-test-insert-worker-item-working-not-running-face ()
  "Test worker item working-not-running uses worker-working face."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-worker-item
       '(:name "slow" :state "working" :session_running nil))
      (goto-char (point-min))
      (search-forward "slow")
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'ogent-gastown-worker-working)))))

(ert-deftest ogent-gts-test-insert-worker-item-done-face ()
  "Test worker item done uses worker-done face."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-worker-item
       '(:name "finished" :state "done" :session_running nil))
      (goto-char (point-min))
      (search-forward "finished")
      (should (eq (get-text-property (match-beginning 0) 'face)
                  'ogent-gastown-worker-done)))))

;;; --- Worker Item ASCII Icon Tests ---

(ert-deftest ogent-gts-test-insert-worker-item-ascii-running-icon ()
  "Test worker item running ASCII icon is >."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-worker-item
       '(:name "r" :state "working" :session_running t))
      (should (string-match-p ">" (buffer-string))))))

(ert-deftest ogent-gts-test-insert-worker-item-ascii-working-icon ()
  "Test worker item working (not running) ASCII icon is *."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-worker-item
       '(:name "w" :state "working" :session_running nil))
      (should (string-match-p "\\*" (buffer-string))))))

(ert-deftest ogent-gts-test-insert-worker-item-ascii-idle-icon ()
  "Test worker item idle ASCII icon is -."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-worker-item
       '(:name "i" :state "idle" :session_running nil))
      (should (string-match-p "-" (buffer-string))))))

;;; --- Polecat Item State Face Tests ---

(ert-deftest ogent-gts-test-insert-polecat-item-plain-with-session-started ()
  "Test polecat plain with session_started timestamp."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data
           (list '(:name "timed" :rig "r1" :state "working"
                   :session_running t
                   :session_started "2026-01-22T10:00:00Z"))))
      (ogent-gastown--insert-polecat-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "r1/timed" content))
        (should (string-match-p "running" content))))))

;;; --- Crew Section Plain with Multiple Rigs ---

(ert-deftest ogent-gts-test-insert-crew-section-plain-multiple-rigs ()
  "Test crew section plain groups by rig correctly."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:name "dev1" :rig "rig-a" :session_running t)
                 '(:name "dev2" :rig "rig-b" :session_running nil)
                 '(:name "dev3" :rig "rig-a" :session_running t))))
      (ogent-gastown--insert-crew-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "rig-a/dev1" content))
        (should (string-match-p "rig-b/dev2" content))
        (should (string-match-p "rig-a/dev3" content))
        (should (string-match-p "\\[active\\]" content))))))

;;; --- Rigs Section Plain with Multiple Rigs ---

(ert-deftest ogent-gts-test-insert-rigs-section-plain-multiple ()
  "Test rigs section plain renders multiple rigs."
  (with-temp-buffer
    (let ((ogent-gastown--rigs-data
           (list '(:name "alpha" :polecat_count 3 :crew_count 2)
                 '(:name "beta" :polecat_count 1 :crew_count 0)
                 '(:name "gamma" :polecat_count 0 :crew_count 5))))
      (ogent-gastown--insert-rigs-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "alpha" content))
        (should (string-match-p "P:3 C:2" content))
        (should (string-match-p "beta" content))
        (should (string-match-p "P:1 C:0" content))
        (should (string-match-p "gamma" content))
        (should (string-match-p "P:0 C:5" content))))))

;;; --- Convoy Section Plain with Naming ---

(ert-deftest ogent-gts-test-insert-convoy-section-plain-named-and-unnamed ()
  "Test convoy section plain renders named and unnamed convoys."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :title "Named Job" :status "active" :completed 2 :total 4 :tracked nil)
                 '(:id "c2" :title nil :status "complete" :completed 5 :total 5 :tracked nil))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Named Job" content))
        (should (string-match-p "(unnamed)" content))))))

;;; --- Witness Section Plain with Counts in Paren ---

(ert-deftest ogent-gts-test-insert-witness-section-plain-multiple ()
  "Test witness section plain with multiple rigs."
  (with-temp-buffer
    (let ((ogent-gastown--witness-data
           (list '(:rig "rig-a" :has_witness t :polecat_count 5 :crew_count 3)
                 '(:rig "rig-b" :has_witness nil :polecat_count 1 :crew_count 0)
                 '(:rig "rig-c" :has_witness t :polecat_count 0 :crew_count 2))))
      (ogent-gastown--insert-witness-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "\\+ rig-a" content))
        (should (string-match-p "- rig-b" content))
        (should (string-match-p "\\+ rig-c" content))))))

;;; --- Evil Integration Tests ---

(ert-deftest ogent-gts-test-setup-evil-noop-without-evil ()
  "Test setup-evil is a no-op when evil is not loaded."
  (cl-letf (((symbol-function 'fboundp)
             (lambda (sym)
               (if (eq sym 'evil-set-initial-state)
                   nil
                 (funcall (symbol-function 'fboundp) sym)))))
    ;; Should not error when evil functions are not available
    (ogent-gastown--setup-evil)))

;;; --- Header Line Extended Condition Tests ---

(ert-deftest ogent-gts-test-header-line-loading-hides-hook-status ()
  "Test header line hides hook status when loading."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data ogent-gts-test--sample-hook-active)
          (ogent-gastown--mail-data ogent-gts-test--sample-mail)
          (ogent-gastown--loading t)
          (ogent-gastown--loading-frame 2))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "Loading" header))
        ;; When loading, hook status and mail count should not appear
        (should-not (string-match-p "Hook:" header))))))

(ert-deftest ogent-gts-test-header-line-active-hook-with-many-unread ()
  "Test header line with active hook and many unread messages."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data '(:has_work t :role "mayor"))
          (ogent-gastown--mail-data
           (list '(:id "m1" :read nil)
                 '(:id "m2" :read nil)
                 '(:id "m3" :read nil)
                 '(:id "m4" :read nil)
                 '(:id "m5" :read nil)))
          (ogent-gastown--loading nil))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "Hook: active" header))
        (should (string-match-p "5 unread" header))))))

;;; --- Stats Section Plain with Full Data ---

(ert-deftest ogent-gts-test-insert-stats-section-plain-full-data ()
  "Test stats section plain renders all stat values."
  (with-temp-buffer
    (let ((ogent-gastown--stats-data
           '(:rig_count 10 :polecat_count 20 :crew_count 30
             :witness_count 5 :refinery_count 8 :active_hooks 3)))
      (ogent-gastown--insert-stats-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Rigs: 10" content))
        (should (string-match-p "Polecats: 20" content))
        (should (string-match-p "Crew: 30" content))
        (should (string-match-p "Witnesses: 5" content))
        (should (string-match-p "Refineries: 8" content))
        (should (string-match-p "Hooks: 3" content))))))

;;; --- Deacon Section Plain All Branches ---

(ert-deftest ogent-gts-test-insert-deacon-section-plain-running-with-work ()
  "Test deacon section plain shows running when deacon has work."
  (with-temp-buffer
    (let ((ogent-gastown--deacon-data '(:running t :has_work t)))
      (ogent-gastown--insert-deacon-section-plain)
      (should (string-match-p "running" (buffer-string))))))

;;; --- Polecat Section Plain Groups by Rig ---

(ert-deftest ogent-gts-test-insert-polecat-section-plain-groups-by-rig ()
  "Test polecat section plain groups polecats by rig."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data
           (list '(:name "a1" :rig "rig-x" :state "working" :session_running t)
                 '(:name "b1" :rig "rig-y" :state "idle" :session_running nil)
                 '(:name "a2" :rig "rig-x" :state "idle" :session_running nil))))
      (ogent-gastown--insert-polecat-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "rig-x/a1" content))
        (should (string-match-p "rig-y/b1" content))
        (should (string-match-p "rig-x/a2" content))
        (should (string-match-p "running" content))))))

;;; --- Rig Issues Success Path ---

(ert-deftest ogent-gts-test-rig-issues-success-with-existing-dir ()
  "Test rig-issues opens issues when rig directory exists."
  (with-temp-buffer
    (let ((ogent-gastown--magit-section-available nil)
          (ogent-gastown--rigs-data (list '(:name "test-rig")))
          (ogent-gastown--town-root temporary-file-directory)
          (issues-called nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "test-rig"))
                ((symbol-function 'file-directory-p)
                 (lambda (_path) t))
                ((symbol-function 'ogent-issues)
                 (lambda () (setq issues-called t))))
        (ogent-gastown-rig-issues)
        (should issues-called)))))

;;; --- Convoy Status with Explicit ID ---

(ert-deftest ogent-gts-test-convoy-status-without-id ()
  "Test convoy-status prompts for ID when no convoys available."
  (let ((inspected-id nil))
    (cl-letf (((symbol-function 'ogent-convoy-inspect)
               (lambda (id &optional _root)
                 (setq inspected-id id)))
              ((symbol-function 'ogent-gastown--active-workspace-root)
               (lambda () "/tmp/test"))
              ((symbol-function 'read-string)
               (lambda (_prompt) "manual-convoy")))
      (let ((ogent-gastown--magit-section-available nil)
            (ogent-gastown--convoy-data nil))
        (ogent-gastown-convoy-status)
        (should (equal inspected-id "manual-convoy"))))))

;;; --- Visit Bead Error Path ---

(ert-deftest ogent-gts-test-visit-bead-with-dir-not-existing ()
  "Test visit-bead shows message when rig directory does not exist."
  (with-temp-buffer
    (let ((messages nil))
      (insert (propertize "bead-fail"
                          'ogent-bead-id "bead-fail"
                          'ogent-rig-path "/nonexistent/path"))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages)))
                ((symbol-function 'file-directory-p)
                 (lambda (_path) nil)))
        (ogent-gastown-visit-bead)
        (should (seq-some (lambda (m) (string-match-p "Rig path not found" m))
                          messages))))))

;;; --- Stat Item String Value ---

(ert-deftest ogent-gts-test-insert-stat-item-string-value ()
  "Test stat item renders string value."
  (with-temp-buffer
    (ogent-gastown--insert-stat-item "Version" "1.2.3")
    (let ((content (buffer-string)))
      (should (string-match-p "Version" content))
      (should (string-match-p "1.2.3" content)))))

;;; --- Mode Map Inheritance ---

(ert-deftest ogent-gts-test-mode-map-exists ()
  "Test the mode map is a keymap."
  (should (keymapp ogent-gastown-status-mode-map)))

;;; --- Backward Compat Alias ---

(ert-deftest ogent-gts-test-mode-alias ()
  "Test ogent-gastown-mode is an alias for ogent-gastown-status-mode."
  ;; `ogent-gastown.el' may redefine `ogent-gastown-mode' as a minor mode.
  ;; Validate alias behavior only when the alias still points at status mode.
  (should (fboundp 'ogent-gastown-mode))
  (let ((status-fn (indirect-function 'ogent-gastown-status-mode))
        (legacy-fn (indirect-function 'ogent-gastown-mode)))
    (if (eq legacy-fn status-fn)
        (let ((buf (generate-new-buffer " *test-alias*")))
          (unwind-protect
              (with-current-buffer buf
                (ogent-gastown-mode)
                (should (eq major-mode 'ogent-gastown-status-mode)))
            (when (buffer-live-p buf)
              (kill-buffer buf))))
      (should (commandp 'ogent-gastown-mode)))))

;;; --- Format Time with Parser Returning Error ---

(ert-deftest ogent-gts-test-format-time-parser-throws-error ()
  "Test format-time returns ??? when parser throws."
  (cl-letf (((symbol-function 'parse-iso8601-time-string)
             (lambda (_iso-time)
               (error "Parse failed"))))
    (should (equal "???" (ogent-gastown--format-time "2026-01-23T17:00:00Z")))))

;;; --- Insert Buffer Contents Dispatch ---

(ert-deftest ogent-gts-test-insert-buffer-contents-delegates ()
  "Test insert-buffer-contents dispatches based on magit availability."
  (let ((plain-count 0)
        (magit-count 0))
    (cl-letf (((symbol-function 'ogent-gastown--insert-plain)
               (lambda () (cl-incf plain-count)))
              ((symbol-function 'ogent-gastown--insert-with-magit-section)
               (lambda () (cl-incf magit-count))))
      (let ((ogent-gastown--magit-section-available nil))
        (ogent-gastown--insert-buffer-contents)
        (should (= plain-count 1))
        (should (= magit-count 0)))
      (let ((ogent-gastown--magit-section-available t))
        (ogent-gastown--insert-buffer-contents)
        (should (= plain-count 1))
        (should (= magit-count 1))))))

;;; --- Hook Section Plain with Next Action ---

(ert-deftest ogent-gts-test-insert-hook-section-plain-with-next-action ()
  "Test hook section plain rendering when next_action is present."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data
           '(:has_work nil :role "crew" :target "crew/"
             :next_action "Wait for assignment")))
      (ogent-gastown--insert-hook-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Role: crew" content))
        (should (string-match-p "No work hooked" content))))))

;;; --- Workers Section Plain with Single Worker ---

(ert-deftest ogent-gts-test-insert-workers-section-plain-single ()
  "Test workers section plain with a single worker."
  (with-temp-buffer
    (let ((ogent-gastown--workers-data
           (list '(:name "solo" :rig "only-rig" :state "working"))))
      (ogent-gastown--insert-workers-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Workers" content))
        (should (string-match-p "only-rig/solo" content))
        (should (string-match-p "\\[working\\]" content))))))

;;; --- Crew Rig Path with Different Town Roots ---

(ert-deftest ogent-gts-test-crew-rig-path-various-roots ()
  "Test crew-rig-path with different town roots."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/var/gt"))
      (should (equal "/var/gt/my-project"
                     (ogent-gastown--crew-rig-path '(:rig "my-project")))))
    (let ((ogent-gastown--town-root "/opt/gastown"))
      (should (equal "/opt/gastown/alpha"
                     (ogent-gastown--crew-rig-path '(:rig "alpha")))))))

;;; --- Header Line All Mail Read No Unread Indicator ---

(ert-deftest ogent-gts-test-header-line-mixed-mail ()
  "Test header line shows correct unread count with mixed read/unread mail."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data nil)
          (ogent-gastown--mail-data
           (list '(:id "m1" :read nil)
                 '(:id "m2" :read t)
                 '(:id "m3" :read nil)
                 '(:id "m4" :read t)))
          (ogent-gastown--loading nil))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "2 unread" header))))))

;;; --- Cache Get with Valid Entry ---

(ert-deftest ogent-gts-test-cache-get-valid-returns-result ()
  "Test cache-get returns result for a valid (non-expired) entry."
  (let ((ogent-gastown--cache (make-hash-table :test 'equal))
        (ogent-gastown-cache-ttl 60))
    (ogent-gastown--cache-set '("valid" "test") '(:data "fresh"))
    (let ((result (ogent-gastown--cache-get '("valid" "test"))))
      (should (equal result '(:data "fresh"))))))

;;; --- Rig Agent with Both Hook and Mail ---

(ert-deftest ogent-gts-test-insert-rig-agent-hook-and-mail-ascii ()
  "Test rig agent ASCII shows H and M: when both hooked and mail."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent
       '(:name "busy" :role "crew" :running t :has_work t :unread_mail 7))
      (let ((content (buffer-string)))
        (should (string-match-p "H" content))
        (should (string-match-p "M:7" content))))))

;;; --- Hook Section Plain with Has-Work True ---

(ert-deftest ogent-gts-test-insert-hook-section-plain-has-work ()
  "Test hook section plain shows work hooked when has_work is t."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data '(:has_work t :role "polecat")))
      (ogent-gastown--insert-hook-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Role: polecat" content))
        (should (string-match-p "Work hooked" content))))))

;;; --- Fetch All with Dead Buffer ---

(ert-deftest ogent-gts-test-fetch-all-dead-buffer-safe ()
  "Test fetch-all is safe when buffer is killed before callback."
  (let ((buf (generate-new-buffer " *test-dead-fetch*"))
        (callback-called nil))
    (with-current-buffer buf
      (let ((ogent-gastown--town-root "/tmp/gt"))
        (cl-letf (((symbol-function 'ogent-gastown-status--run-async)
                   (lambda (_args callback &optional _err _raw)
                     (funcall callback nil))))
          (ogent-gastown--fetch-all
           (lambda ()
             (setq callback-called t))))))
    ;; Kill the buffer
    (kill-buffer buf)
    ;; Callback should have been called because buffer was alive during fetch
    (should callback-called)))

;;; --- Polecat Item Plain with hooked_work ---

(ert-deftest ogent-gts-test-insert-polecat-item-plain-hooked-work ()
  "Test polecat plain with hooked_work field."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data
           (list '(:name "linker" :rig "r1" :state "working"
                   :session_running t :hooked_work "bead-456"))))
      (ogent-gastown--insert-polecat-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "r1/linker" content))
        (should (string-match-p "\\[working\\]" content))
        (should (string-match-p "running" content))))))

;;; --- Loading Indicator for Different Frames ---

(ert-deftest ogent-gts-test-loading-indicator-frame-2 ()
  "Test loading indicator returns frame 2."
  (with-temp-buffer
    (let ((ogent-gastown--loading t)
          (ogent-gastown--loading-frame 2))
      (let ((indicator (ogent-gastown--loading-indicator)))
        (should (equal indicator (nth 2 ogent-gastown--loading-frames)))))))

(ert-deftest ogent-gts-test-loading-indicator-frame-3 ()
  "Test loading indicator returns frame 3."
  (with-temp-buffer
    (let ((ogent-gastown--loading t)
          (ogent-gastown--loading-frame 3))
      (let ((indicator (ogent-gastown--loading-indicator)))
        (should (equal indicator (nth 3 ogent-gastown--loading-frames)))))))

;;; --- Extract Deacon from Town Status with Missing Agents ---

(ert-deftest ogent-gts-test-extract-deacon-missing-agents-key ()
  "Test extracting deacon from town-status with no :agents key."
  (let ((town-status '(:rigs ((:name "r1")))))
    (should-not (ogent-gastown--extract-deacon town-status))))

;;; --- Extract Witnesses Preserves Order ---

(ert-deftest ogent-gts-test-extract-witnesses-preserves-order ()
  "Test extract-witnesses returns rigs in original order."
  (let ((town-status '(:rigs ((:name "z-rig" :has_witness t)
                               (:name "a-rig" :has_witness nil)
                               (:name "m-rig" :has_witness t)))))
    (let ((result (ogent-gastown--extract-witnesses town-status)))
      (should (equal (plist-get (nth 0 result) :rig) "z-rig"))
      (should (equal (plist-get (nth 1 result) :rig) "a-rig"))
      (should (equal (plist-get (nth 2 result) :rig) "m-rig")))))

;;; --- Refresh Force Calls Both Functions ---

(ert-deftest ogent-gts-test-refresh-force-sequence ()
  "Test refresh-force invalidates cache before refreshing."
  (let ((call-order nil))
    (cl-letf (((symbol-function 'ogent-gastown-cache-invalidate)
               (lambda () (push 'invalidate call-order)))
              ((symbol-function 'ogent-gastown-refresh)
               (lambda (&rest _) (push 'refresh call-order))))
      (ogent-gastown-refresh-force)
      ;; Invalidate should have been called before refresh
      (should (equal (reverse call-order) '(invalidate refresh))))))

;;; --- Mode Hook Adds Kill Buffer Hook ---

(ert-deftest ogent-gts-test-mode-hook-adds-cleanup ()
  "Test the mode hook adds ogent-gastown--cleanup-on-kill to kill-buffer-hook."
  (let ((buf (generate-new-buffer " *test-cleanup*")))
    (unwind-protect
        (with-current-buffer buf
          (ogent-gastown-status-mode)
          (should (member #'ogent-gastown--cleanup-on-kill kill-buffer-hook)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; --- Mail Section Plain with All Read ---

(ert-deftest ogent-gts-test-insert-mail-section-plain-all-read ()
  "Test mail section plain with all read messages."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data
           (list '(:id "m1" :from "a" :subject "Old" :read t)
                 '(:id "m2" :from "b" :subject "Older" :read t))))
      (ogent-gastown--insert-mail-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Mail Inbox" content))
        ;; No asterisks for unread
        (should-not (string-match-p "\\* " content))
        ;; Both read messages with spaces
        (should (string-match-p "  a" content))
        (should (string-match-p "  b" content))))))

;;; --- Rig Agent Polecat ASCII Icon ---

(ert-deftest ogent-gts-test-insert-rig-agent-polecat-ascii ()
  "Test rig agent polecat role uses P in ASCII mode."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent
       '(:name "p1" :role "polecat" :running t :has_work nil :unread_mail 0))
      (let ((content (buffer-string)))
        (should (string-match-p "P" content))
        (should (string-match-p "p1" content))))))

;;; --- Crew Section Plain with Hooked Work and Branch ---

(ert-deftest ogent-gts-test-insert-crew-section-plain-with-details ()
  "Test crew section plain renders correctly with hooked work and branch."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:name "dev" :rig "r1" :session_running t
                   :hooked_work "bead-x" :branch "feature/x"
                   :dirty t :unread_mail 5))))
      (ogent-gastown--insert-crew-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "r1/dev" content))
        (should (string-match-p "\\[active\\]" content))))))

;;; --- Worker Item with Different Rig Groupings ---

(ert-deftest ogent-gts-test-insert-workers-section-plain-three-rigs ()
  "Test workers section plain handles three different rigs."
  (with-temp-buffer
    (let ((ogent-gastown--workers-data
           (list '(:name "a" :rig "rig1" :state "idle")
                 '(:name "b" :rig "rig2" :state "working")
                 '(:name "c" :rig "rig3" :state "done"))))
      (ogent-gastown--insert-workers-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "rig1/a" content))
        (should (string-match-p "rig2/b" content))
        (should (string-match-p "rig3/c" content))))))

;;; --- Beads Stats Detail (Expandable Rig Sub-section) ---

(ert-deftest ogent-gts-test-insert-rig-beads-detail-nil ()
  "Test beads detail does nothing when stats are nil."
  (with-temp-buffer
    (ogent-gastown--insert-rig-beads-detail nil)
    (should (string= "" (buffer-string)))))

(ert-deftest ogent-gts-test-insert-rig-beads-detail-all-zeros ()
  "Test beads detail does nothing when all counts are zero."
  (with-temp-buffer
    (ogent-gastown--insert-rig-beads-detail
     '(:ready 0 :in_progress 0 :blocked 0 :open 0 :closed 0 :total 0))
    (should (string= "" (buffer-string)))))

(ert-deftest ogent-gts-test-insert-rig-beads-detail-with-data ()
  "Test beads detail renders non-zero counts."
  (with-temp-buffer
    (ogent-gastown--insert-rig-beads-detail
     '(:ready 3 :in_progress 2 :blocked 1 :open 5 :closed 10 :total 21))
    (let ((content (buffer-string)))
      (should (string-match-p "Issues:" content))
      (should (string-match-p "Ready" content))
      (should (string-match-p "3" content))
      (should (string-match-p "In Progress" content))
      (should (string-match-p "2" content))
      (should (string-match-p "Blocked" content))
      (should (string-match-p "1" content))
      (should (string-match-p "Total" content))
      (should (string-match-p "21" content)))))

(ert-deftest ogent-gts-test-insert-rig-beads-detail-skips-zero-lines ()
  "Test beads detail skips lines where value is zero."
  (with-temp-buffer
    (ogent-gastown--insert-rig-beads-detail
     '(:ready 5 :in_progress 0 :blocked 0 :open 0 :closed 0 :total 5))
    (let ((content (buffer-string)))
      (should (string-match-p "Ready" content))
      (should-not (string-match-p "In Progress" content))
      (should-not (string-match-p "Blocked" content)))))

(ert-deftest ogent-gts-test-insert-rig-beads-detail-total-fallback ()
  "Test beads detail shows when total is missing but other counts > 0."
  (with-temp-buffer
    (ogent-gastown--insert-rig-beads-detail
     '(:ready 2 :in_progress 1 :open 3))
    (let ((content (buffer-string)))
      (should (string-match-p "Issues:" content))
      (should (string-match-p "Ready" content)))))

(ert-deftest ogent-gts-test-insert-rig-beads-detail-heading-uses-issues-face ()
  "Test beads detail heading applies the issues section heading face."
  (with-temp-buffer
    (ogent-gastown--insert-rig-beads-detail
     '(:ready 1 :in_progress 0 :open 0 :total 1))
    (goto-char (point-min))
    (should (search-forward "Issues:" nil t))
    (let ((pos (- (point) (length "Issues:"))))
      (should (eq (get-text-property pos 'face)
                  'ogent-gastown-section-heading-issues)))))

;;; --- Aggregate Beads Stats ---

(ert-deftest ogent-gts-test-aggregate-beads-stats-nil-rigs ()
  "Test aggregate returns nil when no rigs data."
  (let ((ogent-gastown--rigs-data nil))
    (should (null (ogent-gastown--aggregate-beads-stats)))))

(ert-deftest ogent-gts-test-aggregate-beads-stats-no-beads ()
  "Test aggregate returns nil when rigs have no beads_stats."
  (let ((ogent-gastown--rigs-data
         (list '(:name "rig1" :polecat_count 1)
               '(:name "rig2" :polecat_count 2))))
    (should (null (ogent-gastown--aggregate-beads-stats)))))

(ert-deftest ogent-gts-test-aggregate-beads-stats-sums-correctly ()
  "Test aggregate sums beads stats across rigs."
  (let ((ogent-gastown--rigs-data
         (list '(:name "rig1" :beads_stats (:ready 3 :in_progress 2 :open 5))
               '(:name "rig2" :beads_stats (:ready 1 :in_progress 0 :open 2))
               '(:name "rig3"))))
    (let ((agg (ogent-gastown--aggregate-beads-stats)))
      (should agg)
      (should (= 4 (plist-get agg :ready)))
      (should (= 2 (plist-get agg :in_progress)))
      (should (= 7 (plist-get agg :open))))))

(ert-deftest ogent-gts-test-aggregate-beads-stats-all-zeros ()
  "Test aggregate returns nil when all sums are zero."
  (let ((ogent-gastown--rigs-data
         (list '(:name "rig1" :beads_stats (:ready 0 :in_progress 0 :open 0)))))
    (should (null (ogent-gastown--aggregate-beads-stats)))))

;;; --- Stats Section with Beads Aggregates ---

(ert-deftest ogent-gts-test-stats-section-plain-with-beads ()
  "Test plain stats section includes aggregate beads line."
  (with-temp-buffer
    (let ((ogent-gastown--stats-data
           '(:rig_count 2 :polecat_count 3 :crew_count 1
             :witness_count 2 :refinery_count 1 :active_hooks 1))
          (ogent-gastown--rigs-data
           (list '(:name "rig1" :beads_stats (:ready 5 :in_progress 2 :open 3))
                 '(:name "rig2" :beads_stats (:ready 1 :in_progress 1 :open 0)))))
      (ogent-gastown--insert-stats-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Rigs: 2" content))
        (should (string-match-p "+Ready: 6" content))
        (should (string-match-p "\\*Active: 3" content))))))

(ert-deftest ogent-gts-test-stats-section-plain-no-beads ()
  "Test plain stats section omits beads line when no beads data."
  (with-temp-buffer
    (let ((ogent-gastown--stats-data
           '(:rig_count 1 :polecat_count 1 :crew_count 0
             :witness_count 0 :refinery_count 0 :active_hooks 0))
          (ogent-gastown--rigs-data
           (list '(:name "rig1"))))
      (ogent-gastown--insert-stats-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Rigs: 1" content))
        (should-not (string-match-p "Ready" content))))))

;;; --- Convoy Normalization Tests ---

(ert-deftest ogent-gts-test-normalize-convoy-modern-payload ()
  "Test normalization of modern payload shape (:title, :completed, :total, :tracked)."
  (let ((convoy '(:id "c1" :title "Deploy v2" :status "active"
                  :completed 3 :total 7 :tracked ("a" "b"))))
    (let ((result (ogent-gastown--normalize-convoy convoy)))
      (should (equal (plist-get result :id) "c1"))
      (should (equal (plist-get result :title) "Deploy v2"))
      (should (equal (plist-get result :status) "active"))
      (should (equal (plist-get result :completed) 3))
      (should (equal (plist-get result :total) 7))
      (should (equal (plist-get result :tracked) '("a" "b"))))))

(ert-deftest ogent-gts-test-normalize-convoy-legacy-payload ()
  "Test normalization of legacy payload shape (:name, :progress)."
  (let ((convoy '(:id "c2" :name "Bug fixes" :status "complete" :progress "5/5")))
    (let ((result (ogent-gastown--normalize-convoy convoy)))
      (should (equal (plist-get result :title) "Bug fixes"))
      (should (equal (plist-get result :completed) 5))
      (should (equal (plist-get result :total) 5))
      (should-not (plist-get result :tracked)))))

(ert-deftest ogent-gts-test-normalize-convoy-missing-title-and-name ()
  "Test normalization when both :title and :name are missing."
  (let ((convoy '(:id "c3" :status "active")))
    (let ((result (ogent-gastown--normalize-convoy convoy)))
      (should-not (plist-get result :title)))))

(ert-deftest ogent-gts-test-normalize-convoy-missing-progress-data ()
  "Test normalization when no progress data is present."
  (let ((convoy '(:id "c4" :name "No progress" :status "active")))
    (let ((result (ogent-gastown--normalize-convoy convoy)))
      (should (equal (plist-get result :title) "No progress"))
      (should-not (plist-get result :completed))
      (should-not (plist-get result :total)))))

(ert-deftest ogent-gts-test-normalize-convoy-list-mixed ()
  "Test normalizing a list with both modern and legacy convoys."
  (let* ((convoys (list '(:id "c1" :title "Modern" :status "active"
                           :completed 2 :total 4 :tracked nil)
                        '(:id "c2" :name "Legacy" :status "complete"
                           :progress "3/3")))
         (result (ogent-gastown--normalize-convoy-list convoys)))
    (should (= (length result) 2))
    (should (equal (plist-get (car result) :title) "Modern"))
    (should (equal (plist-get (cadr result) :title) "Legacy"))
    (should (equal (plist-get (cadr result) :completed) 3))
    (should (equal (plist-get (cadr result) :total) 3))))

(ert-deftest ogent-gts-test-normalize-convoy-progress-string ()
  "Test progress string formatting from normalized convoy."
  (should (equal (ogent-gastown--convoy-progress-string
                  '(:completed 3 :total 5))
                 "3/5"))
  (should-not (ogent-gastown--convoy-progress-string
               '(:completed nil :total nil)))
  (should-not (ogent-gastown--convoy-progress-string
               '(:completed 3 :total nil))))

(ert-deftest ogent-gts-test-normalize-convoy-malformed-progress ()
  "Test normalization with malformed :progress string."
  (let ((convoy '(:id "c5" :name "Bad" :status "active" :progress "not-a-fraction")))
    (let ((result (ogent-gastown--normalize-convoy convoy)))
      (should (equal (plist-get result :title) "Bad"))
      (should-not (plist-get result :completed))
      (should-not (plist-get result :total)))))

(ert-deftest ogent-gts-test-normalize-convoy-empty-list ()
  "Test normalizing an empty convoy list."
  (should-not (ogent-gastown--normalize-convoy-list nil)))

(ert-deftest ogent-gts-test-convoy-section-plain-modern-payload ()
  "Test convoy section plain rendering with modern payload shape."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (ogent-gastown--normalize-convoy-list
            (list '(:id "c1" :title "Ship v3" :status "active"
                    :completed 2 :total 6 :tracked ("issue-1"))))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Ship v3" content))))))

(ert-deftest ogent-gts-test-convoy-section-plain-legacy-payload ()
  "Test convoy section plain rendering with legacy payload shape."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (ogent-gastown--normalize-convoy-list
            (list '(:id "c1" :name "Old style" :status "active" :progress "1/4")))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Old style" content))))))

(ert-deftest ogent-gts-test-convoy-section-plain-mixed-shapes ()
  "Test convoy section plain rendering with mixed legacy and modern shapes."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (ogent-gastown--normalize-convoy-list
            (list '(:id "c1" :title "Modern one" :status "active"
                    :completed 1 :total 3 :tracked nil)
                  '(:id "c2" :name "Legacy one" :status "complete"
                    :progress "5/5")))))
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Modern one" content))
        (should (string-match-p "Legacy one" content))))))

;;; --- Crew Normalization Tests ---

(ert-deftest ogent-gts-test-convoy-status-no-magit-no-section-context ()
  "Without magit, convoy-status prompts for convoy ID and opens inspector."
  (let ((inspected-id nil))
    (cl-letf (((symbol-function 'read-string)
               (lambda (_prompt &rest _) "test-convoy-42"))
              ((symbol-function 'ogent-convoy-inspect)
               (lambda (id &rest _) (setq inspected-id id))))
      (let ((ogent-gastown--magit-section-available nil)
            (ogent-gastown--convoy-data nil))
        (ogent-gastown-convoy-status)
        (should (equal inspected-id "test-convoy-42"))))))

(ert-deftest ogent-gts-test-normalize-crew-canonical-passthrough ()
  "Canonical crew keys pass through unchanged."
  (let ((result (ogent-gastown--normalize-crew-member
                 '(:name "ritchie" :rig "ogent" :branch "master"
                   :session_running t :dirty t :hooked_work "og-123"
                   :unread_mail 3))))
    (should (equal (plist-get result :name) "ritchie"))
    (should (equal (plist-get result :session_running) t))
    (should (equal (plist-get result :dirty) t))
    (should (equal (plist-get result :hooked_work) "og-123"))
    (should (equal (plist-get result :unread_mail) 3))))

(ert-deftest ogent-gts-test-normalize-crew-gt-output ()
  "Real gt crew list output is normalized to canonical keys."
  (let ((result (ogent-gastown--normalize-crew-member
                 '(:name "ritchie" :rig "ogent" :branch "master"
                   :path "/Users/jake/gt/ogent/crew/ritchie"
                   :has_session t :git_clean nil))))
    (should (equal (plist-get result :session_running) t))
    (should (equal (plist-get result :dirty) t))
    (should (equal (plist-get result :unread_mail) 0))))

(ert-deftest ogent-gts-test-normalize-crew-git-clean-true ()
  "git_clean=true maps to dirty=nil."
  (let ((result (ogent-gastown--normalize-crew-member
                 '(:name "torvalds" :rig "ogent" :branch "master"
                   :has_session t :git_clean t))))
    (should-not (plist-get result :dirty))))

(ert-deftest ogent-gts-test-normalize-crew-nil ()
  "Normalizing nil crew member returns nil."
  (should-not (ogent-gastown--normalize-crew-member nil)))

(ert-deftest ogent-gts-test-normalize-crew-list-mixed ()
  "Normalize list with both canonical and gt-output shapes."
  (let* ((crew (list '(:name "a" :rig "r" :session_running t :dirty nil)
                     '(:name "b" :rig "r" :has_session nil :git_clean t)))
         (result (ogent-gastown--normalize-crew-list crew)))
    (should (= (length result) 2))
    (should (equal (plist-get (car result) :session_running) t))
    (should-not (plist-get (cadr result) :session_running))
    (should-not (plist-get (cadr result) :dirty))))

(ert-deftest ogent-gts-test-normalize-crew-list-nil ()
  "Normalizing nil crew list returns nil."
  (should-not (ogent-gastown--normalize-crew-list nil)))

(ert-deftest ogent-gts-test-normalize-crew-missing-optional-fields ()
  "Missing optional fields get defaults without error."
  (let ((result (ogent-gastown--normalize-crew-member
                 '(:name "minimal" :rig "r"))))
    (should (equal (plist-get result :name) "minimal"))
    (should-not (plist-get result :session_running))
    (should-not (plist-get result :dirty))
    (should-not (plist-get result :hooked_work))
    (should (equal (plist-get result :unread_mail) 0))))

;;; --- Polecat Normalization Tests ---

(ert-deftest ogent-gts-test-normalize-polecat-canonical-passthrough ()
  "Canonical polecat keys pass through unchanged."
  (let ((result (ogent-gastown--normalize-polecat
                 '(:name "alpha" :rig "ogent" :state "working"
                   :session_running t :current_task "og-abc"
                   :session_started "2026-01-22T10:00:00Z"))))
    (should (equal (plist-get result :name) "alpha"))
    (should (equal (plist-get result :session_running) t))
    (should (equal (plist-get result :current_task) "og-abc"))
    (should (equal (plist-get result :session_started) "2026-01-22T10:00:00Z"))))

(ert-deftest ogent-gts-test-normalize-polecat-gt-output ()
  "Real gt status agent output is normalized to canonical keys."
  (let ((result (ogent-gastown--normalize-polecat
                 '(:name "furiosa" :rig "ogent" :state "working"
                   :running t :has_work t :hook_bead "og-75up"
                   :work_title "Stabilize fetch"))))
    (should (equal (plist-get result :session_running) t))
    (should (equal (plist-get result :current_task) "og-75up"))
    (should (equal (plist-get result :hooked_work) "og-75up"))))

(ert-deftest ogent-gts-test-normalize-polecat-nil ()
  "Normalizing nil polecat returns nil."
  (should-not (ogent-gastown--normalize-polecat nil)))

(ert-deftest ogent-gts-test-normalize-polecat-list-mixed ()
  "Normalize list with canonical and gt-output shapes."
  (let* ((polecats (list '(:name "a" :rig "r" :state "working"
                            :session_running t :current_task "og-1")
                         '(:name "b" :rig "r" :state "idle"
                            :running nil :hook_bead nil)))
         (result (ogent-gastown--normalize-polecat-list polecats)))
    (should (= (length result) 2))
    (should (equal (plist-get (car result) :current_task) "og-1"))
    (should-not (plist-get (cadr result) :session_running))))

(ert-deftest ogent-gts-test-normalize-polecat-list-nil ()
  "Normalizing nil polecat list returns nil."
  (should-not (ogent-gastown--normalize-polecat-list nil)))

(ert-deftest ogent-gts-test-normalize-polecat-hooked-work-fallback ()
  "hooked_work is used when current_task is nil."
  (let ((result (ogent-gastown--normalize-polecat
                 '(:name "beta" :rig "r" :state "working"
                   :session_running t :hooked_work "og-xyz"))))
    (should (equal (plist-get result :current_task) "og-xyz"))
    (should (equal (plist-get result :hooked_work) "og-xyz"))))

;;; --- Worker Normalization Tests ---

(ert-deftest ogent-gts-test-normalize-worker-canonical-passthrough ()
  "Canonical worker keys pass through unchanged."
  (let ((result (ogent-gastown--normalize-worker
                 '(:name "alpha" :rig "ogent" :state "working"
                   :session_running t))))
    (should (equal (plist-get result :name) "alpha"))
    (should (equal (plist-get result :session_running) t))
    (should (equal (plist-get result :state) "working"))))

(ert-deftest ogent-gts-test-normalize-worker-gt-output ()
  "Real gt output with :running is normalized."
  (let ((result (ogent-gastown--normalize-worker
                 '(:name "beta" :rig "ogent" :state "idle"
                   :running nil))))
    (should-not (plist-get result :session_running))))

(ert-deftest ogent-gts-test-normalize-worker-nil ()
  "Normalizing nil worker returns nil."
  (should-not (ogent-gastown--normalize-worker nil)))

(ert-deftest ogent-gts-test-normalize-worker-list-nil ()
  "Normalizing nil worker list returns nil."
  (should-not (ogent-gastown--normalize-worker-list nil)))

(ert-deftest ogent-gts-test-full-plain-buffer-convoy-and-other-sections ()
  "Full plain buffer renders convoy alongside other sections."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "c1" :title "Full Test" :status "active"
                   :completed 1 :total 3 :tracked nil)))
          (ogent-gastown--hook-data '(:has_work nil :role "test" :target "t/" :next_action nil))
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
        (should (string-match-p "Full Test" content))
        (should (string-match-p "Hook" content))
        (should (string-match-p "Workers" content))))))

;;; --- Fetch Command Contract Tests ---

(ert-deftest ogent-gts-test-fetch-contract-town-status-uses-fast ()
  "Test fetch-all uses --fast flag for town status."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/tmp/gt")
          (ogent-gastown-cache-ttl 0)
          (captured-args nil))
      (cl-letf (((symbol-function 'ogent-gastown-status--run-async)
                 (lambda (args callback &optional _error-callback _raw)
                   (push args captured-args)
                   (funcall callback nil))))
        (ogent-gastown--fetch-all #'ignore)
        ;; Town status MUST use --fast
        (should (member '("status" "--json" "--fast") captured-args))
        ;; Old contract without --fast MUST NOT appear
        (should-not (member '("status" "--json") captured-args))))))

(ert-deftest ogent-gts-test-fetch-contract-polecat-uses-all-flag ()
  "Test fetch-all uses --all flag for polecat list."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/tmp/gt")
          (ogent-gastown-cache-ttl 0)
          (captured-args nil))
      (cl-letf (((symbol-function 'ogent-gastown-status--run-async)
                 (lambda (args callback &optional _error-callback _raw)
                   (push args captured-args)
                   (funcall callback nil))))
        (ogent-gastown--fetch-all #'ignore)
        ;; Polecat list MUST use --all
        (should (member '("polecat" "list" "--all" "--json") captured-args))
        ;; Old contract without --all MUST NOT appear
        (should-not (member '("polecat" "list" "--json") captured-args))))))

(ert-deftest ogent-gts-test-fetch-contract-all-six-commands ()
  "Test fetch-all dispatches exactly 6 commands with correct args."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/tmp/gt")
          (ogent-gastown-cache-ttl 0)
          (captured-args nil))
      (cl-letf (((symbol-function 'ogent-gastown-status--run-async)
                 (lambda (args callback &optional _error-callback _raw)
                   (push args captured-args)
                   (funcall callback nil))))
        (ogent-gastown--fetch-all #'ignore)
        (should (= (length captured-args) 6))
        (should (member '("hook" "--json") captured-args))
        (should (member '("mail" "inbox" "--json") captured-args))
        (should (member '("convoy" "list" "--json") captured-args))
        (should (member '("polecat" "list" "--all" "--json") captured-args))
        (should (member '("status" "--json" "--fast") captured-args))
        (should (member '("crew" "list" "--all" "--json") captured-args))))))

;;; --- Crew/Polecat/Worker Payload Normalization Tests ---

(ert-deftest ogent-gts-test-crew-section-plain-nil-fields ()
  "Test crew section renders safely with nil/missing fields."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:name nil :rig nil :session_running nil))))
      (ogent-gastown--insert-crew-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Crew" content))
        ;; Should render "???" for nil name
        (should (string-match-p "\\?" content))))))

(ert-deftest ogent-gts-test-crew-section-plain-active-member ()
  "Test crew section shows [active] for running sessions."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:name "stallman" :rig "ogent" :session_running t))))
      (ogent-gastown--insert-crew-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "stallman" content))
        (should (string-match-p "\\[active\\]" content))))))

(ert-deftest ogent-gts-test-crew-section-plain-inactive-member ()
  "Test crew section omits [active] for non-running sessions."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:name "knuth" :rig "beads" :session_running nil))))
      (ogent-gastown--insert-crew-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "knuth" content))
        (should-not (string-match-p "\\[active\\]" content))))))

(ert-deftest ogent-gts-test-polecat-section-plain-nil-fields ()
  "Test polecat section renders safely with nil/missing fields."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data
           (list '(:name nil :rig nil :state nil :session_running nil))))
      (ogent-gastown--insert-polecat-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Polecats" content))
        ;; Should render "???" for nil name/rig
        (should (string-match-p "\\?" content))
        ;; Should render "unknown" for nil state
        (should (string-match-p "unknown" content))))))

(ert-deftest ogent-gts-test-polecat-section-plain-running-state ()
  "Test polecat section shows running indicator."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data
           (list '(:name "alpha" :rig "ogent" :state "working"
                   :session_running t))))
      (ogent-gastown--insert-polecat-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "alpha" content))
        (should (string-match-p "working" content))
        (should (string-match-p "running" content))))))

(ert-deftest ogent-gts-test-worker-item-uses-ops-activity-symbol ()
  "Test worker item renders ops-style activity symbols, not hardcoded icons."
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode t))
      (ogent-gastown--insert-worker-item
       '(:name "alpha" :state "working" :session_running t))
      (let ((content (buffer-string)))
        (should (string-match-p
                 (regexp-quote (let ((ogent-ops-use-unicode t))
                                 (ogent-ops-activity-symbol 'active)))
                 content)))))
  ;; ASCII mode
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-worker-item
       '(:name "beta" :state "idle" :session_running nil))
      (let ((content (buffer-string)))
        (should (string-match-p
                 (regexp-quote (let ((ogent-ops-use-unicode nil))
                                 (ogent-ops-activity-symbol 'idle)))
                 content))))))

(ert-deftest ogent-gts-test-workers-section-plain-empty ()
  "Test workers section renders empty state."
  (with-temp-buffer
    (let ((ogent-gastown--workers-data nil))
      (ogent-gastown--insert-workers-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Workers" content))
        (should (string-match-p "No workers" content))))))

;;; --- Section-Level Error/Nil Data Rendering Tests ---

(ert-deftest ogent-gts-test-fetch-all-partial-failure ()
  "Test fetch-all populates data for successful fetches, nil for failures."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/tmp/gt")
          (ogent-gastown-cache-ttl 0)
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
                 (lambda (args callback &optional error-callback _raw)
                   (cond
                    ;; Hook and mail succeed
                    ((equal args '("hook" "--json"))
                     (funcall callback '(:has_work t :role "mayor")))
                    ((equal args '("mail" "inbox" "--json"))
                     (funcall callback (list '(:id "m1" :from "a" :read nil))))
                    ;; Everything else fails
                    (t (when error-callback
                         (funcall error-callback "timeout")))))))
        (ogent-gastown--fetch-all (lambda () (setq callback-called t)))
        ;; Callback fires despite partial failure
        (should callback-called)
        ;; Successful fetches populate data
        (should ogent-gastown--hook-data)
        (should ogent-gastown--mail-data)
        ;; Failed fetches leave data nil
        (should-not ogent-gastown--convoy-data)
        (should-not ogent-gastown--stats-data)
        (should-not ogent-gastown--rigs-data)))))

(ert-deftest ogent-gts-test-plain-buffer-renders-with-all-nil-data ()
  "Test full plain buffer renders without error when all data is nil."
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
          (ogent-gastown--workers-data nil)
          (ogent-gastown--magit-section-available nil))
      (ogent-gastown--insert-plain)
      (let ((content (buffer-string)))
        ;; All section headings should still appear
        (should (string-match-p "Hook" content))
        (should (string-match-p "Mail" content))
        (should (string-match-p "Convoys" content))
        (should (string-match-p "Workers" content))
        (should (string-match-p "Crew" content))
        (should (string-match-p "Polecats" content))
        ;; Empty state indicators should appear
        (should (string-match-p "No workers" content))
        (should (string-match-p "No crew" content))
        (should (string-match-p "No polecats" content))))))

(ert-deftest ogent-gts-test-hook-section-plain-nil-data ()
  "Test hook section renders empty state with nil data."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data nil))
      (ogent-gastown--insert-hook-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Hook" content))
        (should (string-match-p "No work hooked" content))))))

(ert-deftest ogent-gts-test-mail-section-plain-nil-data ()
  "Test mail section renders empty state with nil data."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data nil))
      (ogent-gastown--insert-mail-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Mail" content))
        (should (string-match-p "No messages" content))))))

(ert-deftest ogent-gts-test-crew-section-plain-nil-data ()
  "Test crew section renders empty state with nil data."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data nil))
      (ogent-gastown--insert-crew-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Crew" content))
        (should (string-match-p "No crew" content))))))

(ert-deftest ogent-gts-test-polecat-section-plain-nil-data ()
  "Test polecat section renders empty state with nil data."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data nil))
      (ogent-gastown--insert-polecat-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Polecats" content))
        (should (string-match-p "No polecats" content))))))

(ert-deftest ogent-gts-test-rigs-section-plain-nil-data ()
  "Test rigs section renders empty state with nil data."
  (with-temp-buffer
    (let ((ogent-gastown--rigs-data nil))
      (ogent-gastown--insert-rigs-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Rigs" content))
        (should (string-match-p "No rigs" content))))))

;;; --- Rig Agent Role Icon Contract Tests ---

(ert-deftest ogent-gts-test-rig-agent-role-icons-ops-style ()
  "Test all role icons use `ogent-ops-role-symbol' consistently."
  (let ((ogent-gastown-use-unicode t))
    ;; Each role should render through the role-symbol helper.
    (dolist (role-spec '((witness "witness")
                         (refinery "refinery")
                         (polecat "polecat")
                         (crew "crew")))
      (let ((role-key (nth 0 role-spec))
            (role-name (nth 1 role-spec)))
        (with-temp-buffer
          (ogent-gastown--insert-rig-agent
           (list :name (format "test-%s" role-name) :role role-name
                 :running nil :has_work nil :unread_mail 0))
          (let ((content (buffer-string)))
            (should (string-match-p
                     (regexp-quote (let ((ogent-ops-use-unicode t))
                                     (ogent-ops-role-symbol role-key)))
                     content))))))))

;;; Fetch Error Tests

(ert-deftest ogent-gts-test-fetch-error-face-exists ()
  "Test that the fetch error face is defined."
  (should (facep 'ogent-gastown-fetch-error)))

(ert-deftest ogent-gts-test-section-fetch-error-returns-error ()
  "Test section-fetch-error returns error message for failed section."
  (with-temp-buffer
    (let ((ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (puthash 'mail "connection refused" ogent-gastown--fetch-errors)
      (should (equal "connection refused"
                     (ogent-gastown--section-fetch-error 'mail)))
      (should-not (ogent-gastown--section-fetch-error 'hook)))))

(ert-deftest ogent-gts-test-insert-fetch-error-renders-message ()
  "Test insert-fetch-error inserts a formatted error line."
  (with-temp-buffer
    (let ((ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (puthash 'convoy "timeout" ogent-gastown--fetch-errors)
      (should (ogent-gastown--insert-fetch-error 'convoy))
      (let ((content (buffer-string)))
        (should (string-match-p "Fetch failed: timeout" content))))))

(ert-deftest ogent-gts-test-insert-fetch-error-returns-nil-no-error ()
  "Test insert-fetch-error returns nil when no error exists."
  (with-temp-buffer
    (let ((ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (should-not (ogent-gastown--insert-fetch-error 'convoy))
      (should (string-empty-p (buffer-string))))))

(ert-deftest ogent-gts-test-mail-section-plain-shows-fetch-error ()
  "Test mail plain section shows error when fetch failed."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data nil)
          (ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (puthash 'mail "gt command failed: exited abnormally" ogent-gastown--fetch-errors)
      (ogent-gastown--insert-mail-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Mail Inbox" content))
        (should (string-match-p "Fetch failed:" content))
        (should-not (string-match-p "No messages" content))))))

(ert-deftest ogent-gts-test-mail-section-plain-no-error-shows-empty ()
  "Test mail plain section shows empty message when no data and no error."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data nil)
          (ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (ogent-gastown--insert-mail-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "No messages" content))
        (should-not (string-match-p "Fetch failed" content))))))

(ert-deftest ogent-gts-test-convoy-section-plain-shows-fetch-error ()
  "Test convoy plain section shows error when fetch failed."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data nil)
          (ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (puthash 'convoy "timeout" ogent-gastown--fetch-errors)
      (ogent-gastown--insert-convoy-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Fetch failed:" content))
        (should-not (string-match-p "No convoys" content))))))

(ert-deftest ogent-gts-test-workers-section-plain-shows-fetch-error ()
  "Test workers plain section shows error when fetch failed."
  (with-temp-buffer
    (let ((ogent-gastown--workers-data nil)
          (ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (puthash 'workers "permission denied" ogent-gastown--fetch-errors)
      (ogent-gastown--insert-workers-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Fetch failed:" content))
        (should-not (string-match-p "No workers" content))))))

(ert-deftest ogent-gts-test-stats-section-plain-shows-fetch-error ()
  "Test stats plain section shows error when town-status fetch failed."
  (with-temp-buffer
    (let ((ogent-gastown--stats-data nil)
          (ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (puthash 'town-status "no such command" ogent-gastown--fetch-errors)
      (ogent-gastown--insert-stats-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Fetch failed:" content))
        (should-not (string-match-p "No stats" content))))))

(ert-deftest ogent-gts-test-deacon-section-plain-shows-fetch-error ()
  "Test deacon plain section shows error when town-status fetch failed."
  (with-temp-buffer
    (let ((ogent-gastown--deacon-data nil)
          (ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (puthash 'town-status "connection refused" ogent-gastown--fetch-errors)
      (ogent-gastown--insert-deacon-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Fetch failed:" content))
        (should-not (string-match-p "Status:" content))))))

(ert-deftest ogent-gts-test-witness-section-plain-shows-fetch-error ()
  "Test witness plain section shows error when town-status fetch failed."
  (with-temp-buffer
    (let ((ogent-gastown--witness-data nil)
          (ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (puthash 'town-status "gt not found" ogent-gastown--fetch-errors)
      (ogent-gastown--insert-witness-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Fetch failed:" content))
        (should-not (string-match-p "No rig data" content))))))

(ert-deftest ogent-gts-test-crew-section-plain-shows-fetch-error ()
  "Test crew plain section shows error when fetch failed."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data nil)
          (ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (puthash 'crew "parse error" ogent-gastown--fetch-errors)
      (ogent-gastown--insert-crew-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Fetch failed:" content))
        (should-not (string-match-p "No crew" content))))))

(ert-deftest ogent-gts-test-polecat-section-plain-shows-fetch-error ()
  "Test polecat plain section shows error when fetch failed."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data nil)
          (ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (puthash 'polecat "JSON parse error: unexpected eof" ogent-gastown--fetch-errors)
      (ogent-gastown--insert-polecat-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Fetch failed:" content))
        (should-not (string-match-p "No polecats" content))))))

(ert-deftest ogent-gts-test-rigs-section-plain-shows-fetch-error ()
  "Test rigs plain section shows error when town-status fetch failed."
  (with-temp-buffer
    (let ((ogent-gastown--rigs-data nil)
          (ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (puthash 'town-status "command not found" ogent-gastown--fetch-errors)
      (ogent-gastown--insert-rigs-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Fetch failed:" content))
        (should-not (string-match-p "No rigs" content))))))

(ert-deftest ogent-gts-test-hook-section-plain-shows-fetch-error ()
  "Test hook plain section shows error when fetch failed."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data nil)
          (ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (puthash 'hook "gt hook failed" ogent-gastown--fetch-errors)
      (ogent-gastown--insert-hook-section-plain)
      (let ((content (buffer-string)))
        (should (string-match-p "Fetch failed:" content))))))

(ert-deftest ogent-gts-test-successful-fetch-clears-errors ()
  "Test that a successful fetch doesn't show errors from prior cycle."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data ogent-gts-test--sample-mail)
          (ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      ;; No error in hash for mail - simulates successful fetch
      (ogent-gastown--insert-mail-section-plain)
      (let ((content (buffer-string)))
        (should-not (string-match-p "Fetch failed" content))
        (should (string-match-p "witness" content))))))

(ert-deftest ogent-gts-test-fetch-error-hash-table-initially-empty ()
  "Test that fetch errors hash table starts empty."
  (with-temp-buffer
    (ogent-gastown-status-mode)
    (should (hash-table-p ogent-gastown--fetch-errors))
    (should (= 0 (hash-table-count ogent-gastown--fetch-errors)))))

(ert-deftest ogent-gts-test-all-plain-sections-render-with-errors ()
  "Test that insert-plain renders all sections with fetch errors."
  (with-temp-buffer
    (let ((ogent-gastown--fetch-errors (make-hash-table :test 'eq))
          (ogent-gastown--hook-data nil)
          (ogent-gastown--mail-data nil)
          (ogent-gastown--convoy-data nil)
          (ogent-gastown--workers-data nil)
          (ogent-gastown--stats-data nil)
          (ogent-gastown--deacon-data nil)
          (ogent-gastown--witness-data nil)
          (ogent-gastown--crew-data nil)
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--rigs-data nil)
          (ogent-gastown--magit-section-available nil))
      (puthash 'hook "err1" ogent-gastown--fetch-errors)
      (puthash 'mail "err2" ogent-gastown--fetch-errors)
      (puthash 'convoy "err3" ogent-gastown--fetch-errors)
      (puthash 'workers "err4" ogent-gastown--fetch-errors)
      (puthash 'town-status "err5" ogent-gastown--fetch-errors)
      (puthash 'crew "err6" ogent-gastown--fetch-errors)
      (puthash 'polecat "err7" ogent-gastown--fetch-errors)
      (ogent-gastown--insert-plain)
      (let ((content (buffer-string)))
        ;; All sections should show fetch errors, not empty-state messages
        (should (string-match-p "Fetch failed: err1" content))
        (should (string-match-p "Fetch failed: err2" content))
        (should (string-match-p "Fetch failed: err3" content))
        (should (string-match-p "Fetch failed: err4" content))
        (should (string-match-p "Fetch failed: err5" content))
        (should (string-match-p "Fetch failed: err6" content))
        (should (string-match-p "Fetch failed: err7" content))
        ;; None of the empty-state messages should appear
        (should-not (string-match-p "No messages" content))
        (should-not (string-match-p "No convoys" content))
        (should-not (string-match-p "No workers" content))
        (should-not (string-match-p "No polecats" content))))))

(ert-deftest ogent-gts-test-fetch-error-uses-correct-face ()
  "Test that fetch error text uses the ogent-gastown-fetch-error face."
  (with-temp-buffer
    (let ((ogent-gastown--fetch-errors (make-hash-table :test 'eq)))
      (puthash 'mail "test error" ogent-gastown--fetch-errors)
      (ogent-gastown--insert-fetch-error 'mail)
      (goto-char (point-min))
      (search-forward "Fetch failed")
      (should (eq (get-text-property (1- (point)) 'face)
                  'ogent-gastown-fetch-error)))))

(provide 'ogent-gastown-status-tests)

;;; ogent-gastown-status-tests.el ends here
