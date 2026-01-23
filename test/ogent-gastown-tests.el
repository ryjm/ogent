;;; ogent-gastown-tests.el --- Tests for ogent-gastown -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Gas Town CLI integration layer.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-gastown)
(require 'ogent-gastown-status)

;;; Test Fixtures

(defconst ogent-gastown-test--sample-hook
  '(:id "ogent-xyz"
    :title "Test hooked work"
    :status "hooked"
    :type "task")
  "Sample hook plist for testing.")

(defconst ogent-gastown-test--sample-mail
  (list '(:id "mail-001"
          :from "witness"
          :subject "Status check"
          :date "2026-01-05T10:00:00Z"
          :read nil)
        '(:id "mail-002"
          :from "refinery"
          :subject "Merge complete"
          :date "2026-01-05T11:00:00Z"
          :read t))
  "Sample mail list for testing.")

(defconst ogent-gastown-test--sample-convoy
  (list '(:id "convoy-001"
          :name "Feature implementation"
          :status "active"
          :progress 75))
  "Sample convoy list for testing.")

;;; Mocking Utilities

(defvar ogent-gastown-test--mock-output nil
  "Mock output to return from gt commands.")

(defvar ogent-gastown-test--mock-error nil
  "Mock error to return from gt commands.")

(defvar ogent-gastown-test--captured-command nil
  "Captured command from mock gt calls.")

(defvar ogent-gastown-test--captured-args nil
  "Captured arguments from mock gt calls.")

(defmacro ogent-gastown-test-with-mock (output &rest body)
  "Execute BODY with gt mocked to return OUTPUT.
OUTPUT should be a plist or list that will be returned."
  (declare (indent 1) (debug t))
  `(let ((ogent-gastown-test--mock-output ,output)
         (ogent-gastown-test--mock-error nil)
         (ogent-gastown-test--captured-command nil)
         (ogent-gastown-test--captured-args nil)
         (ogent-gastown-gt-executable "gt")
         ;; Clear cache
         (ogent-gastown--hook-cache nil)
         (ogent-gastown--mail-cache nil)
         (ogent-gastown--convoy-cache nil)
         (ogent-gastown--town-root "/mock/gt/"))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (_) "/usr/local/bin/gt"))
               ((symbol-function 'ogent-gastown--run-async)
                (lambda (command args callback &optional error-callback _raw)
                  (setq ogent-gastown-test--captured-command command)
                  (setq ogent-gastown-test--captured-args args)
                  (if ogent-gastown-test--mock-error
                      (when error-callback
                        (funcall error-callback ogent-gastown-test--mock-error))
                    (funcall callback ogent-gastown-test--mock-output))
                  nil)))
       ,@body)))

(defmacro ogent-gastown-test-with-error (error-msg &rest body)
  "Execute BODY with gt mocked to return ERROR-MSG."
  (declare (indent 1) (debug t))
  `(let ((ogent-gastown-test--mock-output nil)
         (ogent-gastown-test--mock-error ,error-msg)
         (ogent-gastown-test--captured-command nil)
         (ogent-gastown-test--captured-args nil)
         (ogent-gastown-gt-executable "gt")
         (ogent-gastown--hook-cache nil)
         (ogent-gastown--mail-cache nil)
         (ogent-gastown--convoy-cache nil)
         (ogent-gastown--town-root "/mock/gt/"))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (_) "/usr/local/bin/gt"))
               ((symbol-function 'ogent-gastown--run-async)
                (lambda (command args callback &optional error-callback _raw)
                  (setq ogent-gastown-test--captured-command command)
                  (setq ogent-gastown-test--captured-args args)
                  (if ogent-gastown-test--mock-error
                      (when error-callback
                        (funcall error-callback ogent-gastown-test--mock-error))
                    (funcall callback ogent-gastown-test--mock-output))
                  nil)))
       ,@body)))

;;; Availability Tests

(ert-deftest ogent-gastown-test-available-p ()
  "Test gt availability check."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) "/usr/local/bin/gt")))
    (should (ogent-gastown-available-p)))

  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-not (ogent-gastown-available-p))))

(ert-deftest ogent-gastown-test-town-root-from-env ()
  "Test town root detection from GT_TOWN environment variable."
  (let ((ogent-gastown--town-root nil)
        (default-directory "/some/random/dir/"))
    (cl-letf (((symbol-function 'getenv)
               (lambda (var)
                 (when (equal var "GT_TOWN")
                   "/home/user/gt/"))))
      (should (equal "/home/user/gt/" (ogent-gastown-town-root))))))

(ert-deftest ogent-gastown-test-in-town-p ()
  "Test in-town detection."
  (let ((ogent-gastown--town-root nil))
    (cl-letf (((symbol-function 'ogent-gastown-town-root)
               (lambda () "/home/user/gt/")))
      (should (ogent-gastown-in-town-p))))

  (let ((ogent-gastown--town-root nil))
    (cl-letf (((symbol-function 'ogent-gastown-town-root)
               (lambda () nil)))
      (should-not (ogent-gastown-in-town-p)))))

;;; Hook Status Tests

(ert-deftest ogent-gastown-test-hook-refresh ()
  "Test hook status refresh."
  (ogent-gastown-test-with-mock ogent-gastown-test--sample-hook
    (let ((result nil))
      (ogent-gastown-hook-refresh
       (lambda (hook)
         (setq result hook)))
      (should (equal "ogent-xyz" (plist-get result :id)))
      (should (equal "Test hooked work" (plist-get result :title)))
      ;; Check command was correct
      (should (equal "hook" ogent-gastown-test--captured-command))
      (should (member "--json" ogent-gastown-test--captured-args)))))

(ert-deftest ogent-gastown-test-hook-status-cached ()
  "Test hook status returns cached value."
  (ogent-gastown-test-with-mock ogent-gastown-test--sample-hook
    (ogent-gastown-hook-refresh nil)
    (let ((status (ogent-gastown-hook-status)))
      (should (equal "ogent-xyz" (plist-get status :id))))))

(ert-deftest ogent-gastown-test-hook-id ()
  "Test extracting hook ID."
  (ogent-gastown-test-with-mock ogent-gastown-test--sample-hook
    (ogent-gastown-hook-refresh nil)
    (should (equal "ogent-xyz" (ogent-gastown-hook-id)))))

(ert-deftest ogent-gastown-test-hook-title ()
  "Test extracting hook title."
  (ogent-gastown-test-with-mock ogent-gastown-test--sample-hook
    (ogent-gastown-hook-refresh nil)
    (should (equal "Test hooked work" (ogent-gastown-hook-title)))))

;;; Mail Tests

(ert-deftest ogent-gastown-test-mail-refresh ()
  "Test mail inbox refresh."
  (ogent-gastown-test-with-mock ogent-gastown-test--sample-mail
    (let ((result nil))
      (ogent-gastown-mail-refresh
       (lambda (mail)
         (setq result mail)))
      (should (equal 2 (length result)))
      (should (equal "mail-001" (plist-get (car result) :id)))
      ;; Check command
      (should (equal "mail" ogent-gastown-test--captured-command))
      (should (member "inbox" ogent-gastown-test--captured-args)))))

(ert-deftest ogent-gastown-test-mail-unread-count ()
  "Test counting unread messages."
  (ogent-gastown-test-with-mock ogent-gastown-test--sample-mail
    (ogent-gastown-mail-refresh nil)
    ;; One unread message in sample data
    (should (equal 1 (ogent-gastown-mail-unread-count)))))

(ert-deftest ogent-gastown-test-mail-send ()
  "Test sending mail."
  (ogent-gastown-test-with-mock nil
    (let ((sent nil))
      (ogent-gastown-mail-send "witness" "Hello" "Test body"
                                (lambda () (setq sent t)))
      (should sent)
      (should (equal "mail" ogent-gastown-test--captured-command))
      (should (member "send" ogent-gastown-test--captured-args))
      (should (member "witness" ogent-gastown-test--captured-args))
      (should (member "-s" ogent-gastown-test--captured-args))
      (should (member "Hello" ogent-gastown-test--captured-args))
      (should (member "-m" ogent-gastown-test--captured-args))
      (should (member "Test body" ogent-gastown-test--captured-args)))))

;;; Convoy Tests

(ert-deftest ogent-gastown-test-convoy-refresh ()
  "Test convoy status refresh."
  (ogent-gastown-test-with-mock ogent-gastown-test--sample-convoy
    (let ((result nil))
      (ogent-gastown-convoy-refresh
       (lambda (convoys)
         (setq result convoys)))
      (should (equal 1 (length result)))
      (should (equal "convoy-001" (plist-get (car result) :id)))
      (should (equal 75 (plist-get (car result) :progress))))))

(ert-deftest ogent-gastown-test-convoy-active ()
  "Test getting active convoys."
  (ogent-gastown-test-with-mock ogent-gastown-test--sample-convoy
    (ogent-gastown-convoy-refresh nil)
    (let ((convoys (ogent-gastown-convoy-active)))
      (should (equal 1 (length convoys))))))

;;; Header Line Formatting Tests

(ert-deftest ogent-gastown-test-header-line-with-hook ()
  "Test header line formatting with hooked work."
  (ogent-gastown-test-with-mock ogent-gastown-test--sample-hook
    (ogent-gastown-hook-refresh nil)
    (let ((header (ogent-gastown--format-header-line)))
      (should (string-match-p "Gas Town" header))
      (should (string-match-p "ogent-xyz" header)))))

(ert-deftest ogent-gastown-test-header-line-no-hook ()
  "Test header line formatting without hooked work."
  (let ((ogent-gastown--hook-cache nil))
    (let ((header (ogent-gastown--format-header-line)))
      (should (string-match-p "Gas Town" header))
      (should (string-match-p "no hook" header)))))

;;; Error Handling Tests

(ert-deftest ogent-gastown-test-hook-refresh-error ()
  "Test error handling in hook refresh."
  (ogent-gastown-test-with-error "gt hook failed"
    (ogent-gastown-hook-refresh nil)
    ;; Cache should be nil on error
    (should-not ogent-gastown--hook-cache)))

(ert-deftest ogent-gastown-test-mail-refresh-error ()
  "Test error handling in mail refresh."
  (ogent-gastown-test-with-error "gt mail failed"
    (ogent-gastown-mail-refresh nil)
    (should-not ogent-gastown--mail-cache)))

;;; Mode Tests

(ert-deftest ogent-gastown-test-mode-enables ()
  "Test that gastown mode enables properly."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/mock/gt/"))
      (cl-letf (((symbol-function 'ogent-gastown-in-town-p)
                 (lambda () t))
                ((symbol-function 'ogent-gastown-hook-refresh)
                 (lambda (&optional _cb) nil))
                ((symbol-function 'ogent-gastown-mail-refresh)
                 (lambda (&optional _cb) nil))
                ((symbol-function 'ogent-gastown--start-polling)
                 (lambda () nil)))
        (ogent-gastown-mode 1)
        (should ogent-gastown-mode)
        ;; Use equal for list comparison, not eq
        (should (equal header-line-format
                       '(:eval (ogent-gastown--format-header-line))))
        (ogent-gastown-mode -1)
        (should-not ogent-gastown-mode)))))

(ert-deftest ogent-gastown-test-cleanup ()
  "Test cleanup clears all state."
  (let ((ogent-gastown--hook-cache ogent-gastown-test--sample-hook)
        (ogent-gastown--mail-cache ogent-gastown-test--sample-mail)
        (ogent-gastown--convoy-cache ogent-gastown-test--sample-convoy)
        (ogent-gastown--town-root "/mock/gt/"))
    (ogent-gastown-cleanup)
    (should-not ogent-gastown--hook-cache)
    (should-not ogent-gastown--mail-cache)
    (should-not ogent-gastown--convoy-cache)
    (should-not ogent-gastown--town-root)))

;;; Session Integration Tests

(ert-deftest ogent-gastown-test-prime-in-town ()
  "Test gt prime runs when in town."
  ;; Track all commands since prime triggers hook/mail refresh in callback
  (let ((all-commands nil))
    (let ((ogent-gastown-test--mock-output nil)
          (ogent-gastown-test--mock-error nil)
          (ogent-gastown-gt-executable "gt")
          (ogent-gastown--hook-cache nil)
          (ogent-gastown--mail-cache nil)
          (ogent-gastown--convoy-cache nil)
          (ogent-gastown--town-root "/mock/gt/"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (_) "/usr/local/bin/gt"))
                ((symbol-function 'ogent-gastown--run-async)
                 (lambda (command _args callback &optional _error-callback _raw)
                   (push command all-commands)
                   (funcall callback nil)
                   nil))
                ((symbol-function 'ogent-gastown-in-town-p)
                 (lambda () t)))
        (ogent-gastown-prime)
        ;; First command should be "prime"
        (should (member "prime" all-commands))))))

(ert-deftest ogent-gastown-test-prime-not-in-town ()
  "Test gt prime does not run outside town."
  (let ((ogent-gastown-test--captured-command nil))
    (cl-letf (((symbol-function 'ogent-gastown-in-town-p)
               (lambda () nil)))
      (ogent-gastown-prime)
      (should-not ogent-gastown-test--captured-command))))

;;; Beads (bd) Integration Tests

(defconst ogent-gastown-test--sample-ready-issues
  (list '(:id "test-abc"
          :title "Ready issue 1"
          :priority 1
          :issue_type "task"
          :status "open")
        '(:id "test-def"
          :title "Ready issue 2"
          :priority 2
          :issue_type "bug"
          :status "open"))
  "Sample ready issues list for testing.")

(defconst ogent-gastown-test--sample-issue
  '(:id "test-abc"
    :title "Test issue"
    :description "A test issue"
    :status "open"
    :priority 1
    :issue_type "task"
    :created_at "2026-01-05T10:00:00-05:00")
  "Sample issue plist for testing.")

(defvar ogent-gastown-test--bd-captured-args nil
  "Captured arguments from mock bd calls.")

(defmacro ogent-gastown-test-bd-with-mock (output &rest body)
  "Execute BODY with bd mocked to return OUTPUT."
  (declare (indent 1) (debug t))
  `(let ((ogent-gastown-test--bd-captured-args nil)
         (ogent-gastown--bd-ready-cache nil)
         (ogent-gastown-bd-executable "bd"))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (cmd)
                  (when (string= cmd "bd") "/usr/local/bin/bd")))
               ((symbol-function 'ogent-gastown-bd--run-async)
                (lambda (args callback &optional _error-callback _raw)
                  (setq ogent-gastown-test--bd-captured-args args)
                  (funcall callback ,output)
                  nil)))
       ,@body)))

(ert-deftest ogent-gastown-test-bd-available-p ()
  "Test bd availability check."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (cmd)
               (when (string= cmd "bd") "/usr/local/bin/bd"))))
    (should (ogent-gastown-bd-available-p)))

  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-not (ogent-gastown-bd-available-p))))

(ert-deftest ogent-gastown-test-bd-ready-refresh ()
  "Test bd ready refresh."
  (ogent-gastown-test-bd-with-mock ogent-gastown-test--sample-ready-issues
    (let ((result nil))
      (ogent-gastown-bd-ready-refresh
       (lambda (issues)
         (setq result issues)))
      (should (equal 2 (length result)))
      (should (equal "test-abc" (plist-get (car result) :id)))
      ;; Check args
      (should (member "ready" ogent-gastown-test--bd-captured-args))
      (should (member "--json" ogent-gastown-test--bd-captured-args)))))

(ert-deftest ogent-gastown-test-bd-show ()
  "Test bd show issue."
  (ogent-gastown-test-bd-with-mock ogent-gastown-test--sample-issue
    (let ((result nil))
      (ogent-gastown-bd-show "test-abc"
                              (lambda (issue)
                                (setq result issue)))
      (should (equal "test-abc" (plist-get result :id)))
      (should (equal "Test issue" (plist-get result :title)))
      ;; Check args
      (should (member "show" ogent-gastown-test--bd-captured-args))
      (should (member "test-abc" ogent-gastown-test--bd-captured-args)))))

(ert-deftest ogent-gastown-test-bd-update ()
  "Test bd update status."
  ;; Track all args since update triggers ready refresh in callback
  (let ((all-args nil))
    (let ((ogent-gastown--bd-ready-cache nil)
          (ogent-gastown-bd-executable "bd"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd)
                   (when (string= cmd "bd") "/usr/local/bin/bd")))
                ((symbol-function 'ogent-gastown-bd--run-async)
                 (lambda (args callback &optional _error-callback _raw)
                   (push args all-args)
                   (funcall callback nil)
                   nil)))
        (let ((updated nil))
          (ogent-gastown-bd-update "test-abc" "in_progress"
                                    (lambda () (setq updated t)))
          (should updated)
          ;; First call should be update
          (let ((update-args (car (last all-args))))
            (should (member "update" update-args))
            (should (member "test-abc" update-args))
            (should (member "--status=in_progress" update-args))))))))

(ert-deftest ogent-gastown-test-bd-close ()
  "Test bd close issue."
  ;; Track all args since close triggers ready refresh in callback
  (let ((all-args nil))
    (let ((ogent-gastown--bd-ready-cache nil)
          (ogent-gastown-bd-executable "bd"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd)
                   (when (string= cmd "bd") "/usr/local/bin/bd")))
                ((symbol-function 'ogent-gastown-bd--run-async)
                 (lambda (args callback &optional _error-callback _raw)
                   (push args all-args)
                   (funcall callback nil)
                   nil)))
        (let ((closed nil))
          (ogent-gastown-bd-close "test-abc" "Done"
                                   (lambda () (setq closed t)))
          (should closed)
          ;; First call should be close
          (let ((close-args (car (last all-args))))
            (should (member "close" close-args))
            (should (member "test-abc" close-args))
            (should (member "--reason=Done" close-args))))))))

(ert-deftest ogent-gastown-test-bd-ready-id-at-point ()
  "Test extracting issue ID from ready buffer line."
  (with-temp-buffer
    (insert "[P1] test-abc [task] Ready issue 1\n")
    (insert "[P2] test-def [bug] Ready issue 2\n")
    (goto-char (point-min))
    (should (equal "test-abc" (ogent-gastown-bd-ready--id-at-point)))
    (forward-line)
    (should (equal "test-def" (ogent-gastown-bd-ready--id-at-point)))))

(ert-deftest ogent-gastown-test-cleanup-includes-bd ()
  "Test cleanup clears bd state too."
  (let ((ogent-gastown--hook-cache '(:id "test"))
        (ogent-gastown--mail-cache '((:id "mail")))
        (ogent-gastown--convoy-cache '((:id "convoy")))
        (ogent-gastown--bd-ready-cache '((:id "issue")))
        (ogent-gastown--bd-processes nil)
        (ogent-gastown--processes nil)
        (ogent-gastown--town-root "/mock/gt/"))
    (ogent-gastown-cleanup)
    (should-not ogent-gastown--hook-cache)
    (should-not ogent-gastown--mail-cache)
    (should-not ogent-gastown--convoy-cache)
    (should-not ogent-gastown--bd-ready-cache)
    (should-not ogent-gastown--town-root)))

;;; Stats/Deacon/Witness Section Tests

(defconst ogent-gastown-test--sample-town-status
  '(:name "gt"
    :location "/Users/test/gt"
    :agents ((:name "mayor"
              :address "mayor/"
              :session "hq-mayor"
              :role "coordinator"
              :running t
              :has_work nil
              :unread_mail 0)
             (:name "deacon"
              :address "deacon/"
              :session "hq-deacon"
              :role "health-check"
              :running t
              :has_work t
              :unread_mail 2))
    :rigs ((:name "beads"
            :polecat_count 2
            :crew_count 1
            :has_witness t
            :has_refinery t)
           (:name "gastown"
            :polecat_count 0
            :crew_count 3
            :has_witness nil
            :has_refinery t))
    :summary (:rig_count 2
              :polecat_count 2
              :crew_count 4
              :witness_count 1
              :refinery_count 2
              :active_hooks 1))
  "Sample town status response for testing.")

(defconst ogent-gastown-test--sample-stats
  '(:rig_count 5
    :polecat_count 3
    :crew_count 10
    :witness_count 2
    :refinery_count 2
    :active_hooks 3)
  "Sample stats plist for testing.")

(defconst ogent-gastown-test--sample-deacon
  '(:name "deacon"
    :address "deacon/"
    :running t
    :has_work nil)
  "Sample deacon plist for testing.")

(defconst ogent-gastown-test--sample-witnesses
  (list '(:rig "beads"
          :has_witness t
          :polecat_count 2
          :crew_count 1)
        '(:rig "gastown"
          :has_witness nil
          :polecat_count 0
          :crew_count 3))
  "Sample witnesses list for testing.")

;; Extraction function tests

(ert-deftest ogent-gastown-test-extract-deacon ()
  "Test extracting deacon info from town status."
  (let ((deacon (ogent-gastown--extract-deacon
                 ogent-gastown-test--sample-town-status)))
    (should deacon)
    (should (equal "deacon" (plist-get deacon :name)))
    (should (eq t (plist-get deacon :running)))
    (should (eq t (plist-get deacon :has_work)))))

(ert-deftest ogent-gastown-test-extract-deacon-nil ()
  "Test extracting deacon from nil town status."
  (should-not (ogent-gastown--extract-deacon nil)))

(ert-deftest ogent-gastown-test-extract-deacon-no-agents ()
  "Test extracting deacon when no agents present."
  (should-not (ogent-gastown--extract-deacon '(:name "gt" :agents nil))))

(ert-deftest ogent-gastown-test-extract-witnesses ()
  "Test extracting witness info from town status."
  (let ((witnesses (ogent-gastown--extract-witnesses
                    ogent-gastown-test--sample-town-status)))
    (should witnesses)
    (should (equal 2 (length witnesses)))
    ;; First rig (beads)
    (let ((beads (car witnesses)))
      (should (equal "beads" (plist-get beads :rig)))
      (should (eq t (plist-get beads :has_witness)))
      (should (equal 2 (plist-get beads :polecat_count)))
      (should (equal 1 (plist-get beads :crew_count))))
    ;; Second rig (gastown)
    (let ((gastown (cadr witnesses)))
      (should (equal "gastown" (plist-get gastown :rig)))
      (should-not (plist-get gastown :has_witness))
      (should (equal 0 (plist-get gastown :polecat_count)))
      (should (equal 3 (plist-get gastown :crew_count))))))

(ert-deftest ogent-gastown-test-extract-witnesses-nil ()
  "Test extracting witnesses from nil town status."
  (should-not (ogent-gastown--extract-witnesses nil)))

(ert-deftest ogent-gastown-test-extract-witnesses-no-rigs ()
  "Test extracting witnesses when no rigs present."
  (should-not (ogent-gastown--extract-witnesses '(:name "gt" :rigs nil))))

(ert-deftest ogent-gastown-test-extract-witnesses-missing-counts ()
  "Test extracting witnesses with missing polecat/crew counts defaults to 0."
  (let ((witnesses (ogent-gastown--extract-witnesses
                    '(:rigs ((:name "minimal" :has_witness t))))))
    (should witnesses)
    (let ((rig (car witnesses)))
      (should (equal 0 (plist-get rig :polecat_count)))
      (should (equal 0 (plist-get rig :crew_count))))))

;; Insert section tests (plain text mode, no magit-section dependency)

(ert-deftest ogent-gastown-test-insert-stats-section-plain ()
  "Test stats section plain text rendering."
  (with-temp-buffer
    (let ((ogent-gastown--stats-data ogent-gastown-test--sample-stats))
      (ogent-gastown--insert-stats-section-plain)
      (should (string-match-p "Town Stats" (buffer-string)))
      (should (string-match-p "Rigs: 5" (buffer-string)))
      (should (string-match-p "Polecats: 3" (buffer-string)))
      (should (string-match-p "Crew: 10" (buffer-string)))
      (should (string-match-p "Witnesses: 2" (buffer-string)))
      (should (string-match-p "Refineries: 2" (buffer-string)))
      (should (string-match-p "Hooks: 3" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-stats-section-plain-nil ()
  "Test stats section plain text rendering with nil data."
  (with-temp-buffer
    (let ((ogent-gastown--stats-data nil))
      (ogent-gastown--insert-stats-section-plain)
      (should (string-match-p "No stats available" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-deacon-section-plain ()
  "Test deacon section plain text rendering."
  (with-temp-buffer
    (let ((ogent-gastown--deacon-data ogent-gastown-test--sample-deacon))
      (ogent-gastown--insert-deacon-section-plain)
      (should (string-match-p "Deacon" (buffer-string)))
      (should (string-match-p "running" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-deacon-section-plain-stopped ()
  "Test deacon section plain text rendering when stopped."
  (with-temp-buffer
    (let ((ogent-gastown--deacon-data '(:name "deacon" :running nil)))
      (ogent-gastown--insert-deacon-section-plain)
      (should (string-match-p "Deacon" (buffer-string)))
      (should (string-match-p "stopped" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-witness-section-plain ()
  "Test witness section plain text rendering."
  (with-temp-buffer
    (let ((ogent-gastown--witness-data ogent-gastown-test--sample-witnesses))
      (ogent-gastown--insert-witness-section-plain)
      (should (string-match-p "Witnesses" (buffer-string)))
      (should (string-match-p "beads" (buffer-string)))
      (should (string-match-p "gastown" (buffer-string)))
      ;; Check active indicator
      (should (string-match-p "\\+ beads" (buffer-string)))
      (should (string-match-p "- gastown" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-witness-section-plain-nil ()
  "Test witness section plain text rendering with nil data."
  (with-temp-buffer
    (let ((ogent-gastown--witness-data nil))
      (ogent-gastown--insert-witness-section-plain)
      (should (string-match-p "No rig data available" (buffer-string))))))

(provide 'ogent-gastown-tests)

;;; ogent-gastown-tests.el ends here
