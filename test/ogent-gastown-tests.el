;;; ogent-gastown-tests.el --- Tests for ogent-gastown -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Gas Town CLI integration layer.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-gastown)
(require 'ogent-gastown-status)
(require 'ogent-ops-style)

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

(defconst ogent-gastown-test--sample-rigs
  (list '(:name "ogent"
          :polecat_count 2
          :crew_count 3
          :has_witness t
          :has_refinery t
          :agents ((:name "witness"
                    :role "witness"
                    :running t
                    :has_work nil
                    :unread_mail 0)
                   (:name "refinery"
                    :role "refinery"
                    :running nil
                    :has_work nil
                    :unread_mail 0)
                   (:name "ritchie"
                    :role "crew"
                    :running t
                    :has_work t
                    :unread_mail 2)))
        '(:name "beads"
          :polecat_count 0
          :crew_count 1
          :has_witness nil
          :has_refinery nil
          :agents ((:name "knuth"
                    :role "crew"
                    :running nil
                    :has_work nil
                    :unread_mail 0))))
  "Sample rigs list for testing.")

;;; Mocking Utilities

(defvar ogent-gastown-test--mock-output nil
  "Mock output to return from gt commands.")

(defvar ogent-gastown-test--mock-error nil
  "Mock error to return from gt commands.")

(defvar ogent-gastown-test--captured-command nil
  "Captured command from mock gt calls.")

(defvar ogent-gastown-test--captured-args nil
  "Captured arguments from mock gt calls.")

(defclass ogent-gastown-test--section ()
  ((value :initarg :value :initform nil))
  "Minimal section object for status navigation tests.")

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
  "Test town root detection from GT_ROOT environment variable."
  (let ((ogent-gastown--town-root nil)
        (default-directory "/some/random/dir/")
        (root (make-temp-file "ogent-town-root-env-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'getenv)
                   (lambda (var)
                     (when (equal var "GT_ROOT")
                       root))))
          (should (equal (file-name-as-directory (expand-file-name root))
                         (ogent-gastown-town-root))))
      (delete-directory root))))

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

;;; Rigs Section Tests (ogent-gastown-status.el)

(ert-deftest ogent-gastown-test-insert-rigs-section-plain ()
  "Test rigs section insertion (plain mode)."
  (with-temp-buffer
    (let ((ogent-gastown--rigs-data ogent-gastown-test--sample-rigs))
      (ogent-gastown--insert-rigs-section-plain)
      (goto-char (point-min))
      ;; Check section heading
      (should (search-forward "Rigs" nil t))
      ;; Check rig names appear
      (goto-char (point-min))
      (should (search-forward "ogent" nil t))
      (should (search-forward "beads" nil t))
      ;; Check counts appear
      (goto-char (point-min))
      (should (search-forward "P:2 C:3" nil t)))))

(ert-deftest ogent-gastown-test-insert-rigs-section-empty ()
  "Test rigs section with no rigs."
  (with-temp-buffer
    (let ((ogent-gastown--rigs-data nil))
      (ogent-gastown--insert-rigs-section-plain)
      (goto-char (point-min))
      (should (search-forward "Rigs" nil t))
      (should (search-forward "No rigs configured" nil t)))))

(ert-deftest ogent-gastown-test-insert-rig-agent ()
  "Test rig agent line insertion."
  (with-temp-buffer
    (let ((agent '(:name "ritchie"
                   :role "crew"
                   :running t
                   :has_work t
                   :unread_mail 2))
          (ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent agent)
      (goto-char (point-min))
      ;; Check agent name appears
      (should (search-forward "ritchie" nil t))
      ;; Check role icon (C for crew)
      (goto-char (point-min))
      (should (search-forward "C" nil t)))))

(ert-deftest ogent-gastown-test-insert-rig-agent-with-hook ()
  "Test rig agent with hooked work shows hook indicator."
  (with-temp-buffer
    (let ((agent '(:name "worker"
                   :role "polecat"
                   :running t
                   :has_work t
                   :unread_mail 0))
          (ogent-gastown-use-unicode t))
      (ogent-gastown--insert-rig-agent agent)
      (goto-char (point-min))
      ;; Check hook indicator appears (via ops-style helper)
      (should (search-forward (ogent-ops-badge-symbol 'hook) nil t)))))

(ert-deftest ogent-gastown-test-insert-rig-agent-with-mail ()
  "Test rig agent with unread mail shows mail indicator."
  (with-temp-buffer
    (let ((agent '(:name "worker"
                   :role "crew"
                   :running nil
                   :has_work nil
                   :unread_mail 5))
          (ogent-gastown-use-unicode t))
      (ogent-gastown--insert-rig-agent agent)
      (goto-char (point-min))
      ;; Check mail indicator appears (via ops-style badge)
      (should (search-forward
               (format "%s5" (ogent-ops-badge-symbol 'mail))
               nil t)))))

(ert-deftest ogent-gastown-test-insert-rig-agent-no-mail ()
  "Test rig agent with no unread mail does not show mail indicator."
  (with-temp-buffer
    (let ((agent '(:name "worker"
                   :role "crew"
                   :running nil
                   :has_work nil
                   :unread_mail 0))
          (ogent-gastown-use-unicode t))
      (ogent-gastown--insert-rig-agent agent)
      (let ((content (buffer-string)))
        ;; Should NOT have mail indicator
        (should-not (string-match-p
                     (regexp-quote (ogent-ops-badge-symbol 'mail))
                     content))))))

(ert-deftest ogent-gastown-test-rig-agent-role-icons ()
  "Test that different roles get different icons."
  ;; Test witness
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent '(:name "w" :role "witness" :running nil :has_work nil :unread_mail 0))
      (goto-char (point-min))
      (should (search-forward "W" nil t))))
  ;; Test refinery
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent '(:name "r" :role "refinery" :running nil :has_work nil :unread_mail 0))
      (goto-char (point-min))
      (should (search-forward "R" nil t))))
  ;; Test polecat
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent '(:name "p" :role "polecat" :running nil :has_work nil :unread_mail 0))
      (goto-char (point-min))
      (should (search-forward "P" nil t))))
  ;; Test crew
  (with-temp-buffer
    (let ((ogent-gastown-use-unicode nil))
      (ogent-gastown--insert-rig-agent '(:name "c" :role "crew" :running nil :has_work nil :unread_mail 0))
      (goto-char (point-min))
      (should (search-forward "C" nil t)))))

(ert-deftest ogent-gastown-test-rigs-data-nil-values ()
  "Test rigs rendering handles nil values gracefully."
  (with-temp-buffer
    (let ((ogent-gastown--rigs-data
           (list '(:name "test-rig"
                   :polecat_count nil
                   :crew_count nil
                   :has_witness nil
                   :has_refinery nil
                   :agents nil))))
      (ogent-gastown--insert-rigs-section-plain)
      ;; Should not error, should show rig name
      (goto-char (point-min))
      (should (search-forward "test-rig" nil t))
      ;; Nil counts should show as 0
      (goto-char (point-min))
      (should (search-forward "P:0 C:0" nil t)))))

;;; Mail Recipient Completion Tests

(defconst ogent-gastown-test--sample-crew
  (list '(:name "stallman"
          :rig "ogent"
          :session_running t
          :hooked_work "ogent-123"
          :session_started "2026-01-22T10:00:00Z")
        '(:name "wolf"
          :rig "ogent"
          :session_running nil
          :hooked_work nil
          :session_started nil)
        '(:name "alpha"
          :rig "beads"
          :session_running t
          :hooked_work nil
          :session_started "2026-01-22T09:30:00Z"))
  "Sample crew list for testing.")

(defconst ogent-gastown-test--sample-polecats
  (list '(:name "alpha"
          :rig "ogent"
          :state "running"
          :session_running t
          :hooked_work "task-001"
          :session_started "2026-01-22T08:00:00Z")
        '(:name "beta"
          :rig "ogent"
          :state "idle"
          :session_running nil
          :hooked_work nil
          :session_started nil)
        '(:name "gamma"
          :rig "beads"
          :state "running"
          :session_running t
          :hooked_work "beads-789"
          :session_started "2026-01-22T11:00:00Z"))
  "Sample polecat list for testing.")

(ert-deftest ogent-gastown-status-test-get-mail-recipients ()
  "Test mail recipient list generation."
  (let ((orig-crew (default-value 'ogent-gastown--crew-data))
        (orig-polecat (default-value 'ogent-gastown--polecat-data))
        (orig-witness (default-value 'ogent-gastown--witness-data)))
    (unwind-protect
        (progn
          (setq-default ogent-gastown--crew-data ogent-gastown-test--sample-crew)
          (setq-default ogent-gastown--polecat-data ogent-gastown-test--sample-polecats)
          (setq-default ogent-gastown--witness-data ogent-gastown-test--sample-witnesses)
          (let ((recipients (ogent-gastown--get-mail-recipients)))
            ;; Should include fixed addresses
            (should (member "mayor/" recipients))
            (should (member "deacon/" recipients))
            ;; Should include crew members
            (should (member "ogent/crew/stallman" recipients))
            (should (member "ogent/crew/wolf" recipients))
            (should (member "beads/crew/alpha" recipients))
            ;; Should include polecats
            (should (member "ogent/polecats/alpha" recipients))
            (should (member "ogent/polecats/beta" recipients))
            (should (member "beads/polecats/gamma" recipients))
            ;; Should include witnesses (only for rigs that have them)
            ;; Note: sample witnesses has beads=t, gastown=nil
            (should (member "beads/witness/" recipients))
            (should-not (member "gastown/witness/" recipients))
            ;; Should include refineries
            (should (member "beads/refinery/" recipients))
            (should (member "gastown/refinery/" recipients))))
      (setq-default ogent-gastown--crew-data orig-crew)
      (setq-default ogent-gastown--polecat-data orig-polecat)
      (setq-default ogent-gastown--witness-data orig-witness))))

(ert-deftest ogent-gastown-status-test-get-mail-recipients-empty ()
  "Test mail recipient list with no data."
  (let ((orig-crew (default-value 'ogent-gastown--crew-data))
        (orig-polecat (default-value 'ogent-gastown--polecat-data))
        (orig-witness (default-value 'ogent-gastown--witness-data)))
    (unwind-protect
        (progn
          (setq-default ogent-gastown--crew-data nil)
          (setq-default ogent-gastown--polecat-data nil)
          (setq-default ogent-gastown--witness-data nil)
          (let ((recipients (ogent-gastown--get-mail-recipients)))
            ;; Should still have fixed addresses
            (should (member "mayor/" recipients))
            (should (member "deacon/" recipients))
            ;; Should only have the 2 fixed addresses
            (should (equal 2 (length recipients)))))
      (setq-default ogent-gastown--crew-data orig-crew)
      (setq-default ogent-gastown--polecat-data orig-polecat)
      (setq-default ogent-gastown--witness-data orig-witness))))

(ert-deftest ogent-gastown-status-test-get-mail-recipients-no-duplicates ()
  "Test that recipient list has no duplicates."
  (let ((orig-crew (default-value 'ogent-gastown--crew-data))
        (orig-polecat (default-value 'ogent-gastown--polecat-data))
        (orig-witness (default-value 'ogent-gastown--witness-data)))
    (unwind-protect
        (progn
          (setq-default ogent-gastown--crew-data ogent-gastown-test--sample-crew)
          (setq-default ogent-gastown--polecat-data ogent-gastown-test--sample-polecats)
          (setq-default ogent-gastown--witness-data ogent-gastown-test--sample-witnesses)
          (let ((recipients (ogent-gastown--get-mail-recipients)))
            ;; Length should equal length of unique list
            (should (equal (length recipients)
                           (length (delete-dups (copy-sequence recipients)))))))
      (setq-default ogent-gastown--crew-data orig-crew)
      (setq-default ogent-gastown--polecat-data orig-polecat)
      (setq-default ogent-gastown--witness-data orig-witness))))

(ert-deftest ogent-gastown-status-test-get-mail-recipients-sorted ()
  "Test that recipient list is sorted."
  (let ((orig-crew (default-value 'ogent-gastown--crew-data))
        (orig-polecat (default-value 'ogent-gastown--polecat-data))
        (orig-witness (default-value 'ogent-gastown--witness-data)))
    (unwind-protect
        (progn
          (setq-default ogent-gastown--crew-data ogent-gastown-test--sample-crew)
          (setq-default ogent-gastown--polecat-data ogent-gastown-test--sample-polecats)
          (setq-default ogent-gastown--witness-data ogent-gastown-test--sample-witnesses)
          (let ((recipients (ogent-gastown--get-mail-recipients)))
            ;; Should be sorted alphabetically
            (should (equal recipients (sort (copy-sequence recipients) #'string<)))))
      (setq-default ogent-gastown--crew-data orig-crew)
      (setq-default ogent-gastown--polecat-data orig-polecat)
      (setq-default ogent-gastown--witness-data orig-witness))))

;;; Interactive Command Tests - ogent-gastown-done

(ert-deftest ogent-gastown-test-done-in-town ()
  "Test gt done runs when in town and user confirms."
  (let ((all-commands nil))
    (let ((ogent-gastown-gt-executable "gt")
          (ogent-gastown--hook-cache nil)
          (ogent-gastown--mail-cache nil)
          (ogent-gastown--convoy-cache nil)
          (ogent-gastown--town-root "/mock/gt/"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (_) "/usr/local/bin/gt"))
                ((symbol-function 'ogent-gastown--run-async)
                 (lambda (command _args callback &optional _error-cb _raw)
                   (push command all-commands)
                   (funcall callback nil)
                   nil))
                ((symbol-function 'ogent-gastown-in-town-p)
                 (lambda () t))
                ((symbol-function 'yes-or-no-p)
                 (lambda (_prompt) t)))
        (ogent-gastown-done)
        (should (member "done" all-commands))))))

(ert-deftest ogent-gastown-test-done-user-declines ()
  "Test gt done does nothing when user says no."
  (ogent-gastown-test-with-mock nil
    (cl-letf (((symbol-function 'ogent-gastown-in-town-p)
               (lambda () t))
              ((symbol-function 'yes-or-no-p)
               (lambda (_prompt) nil)))
      (ogent-gastown-done)
      (should-not ogent-gastown-test--captured-command))))

(ert-deftest ogent-gastown-test-done-not-in-town ()
  "Test gt done messages when not in town."
  (let ((ogent-gastown--town-root nil))
    (cl-letf (((symbol-function 'ogent-gastown-in-town-p)
               (lambda () nil)))
      (ogent-gastown-done)
      (should-not ogent-gastown-test--captured-command))))

;;; Interactive Command Tests - ogent-gastown-mail-read

(ert-deftest ogent-gastown-test-mail-read-with-callback ()
  "Test mail read calls run-async with correct args."
  (ogent-gastown-test-with-mock '(:from "witness" :to "me" :subject "Test" :date "2026-01-01" :body "Hello")
    (let ((result nil))
      (ogent-gastown-mail-read "mail-001"
                                (lambda (msg)
                                  (setq result msg)))
      (should (equal "mail" ogent-gastown-test--captured-command))
      (should (member "read" ogent-gastown-test--captured-args))
      (should (member "mail-001" ogent-gastown-test--captured-args))
      (should (equal "witness" (plist-get result :from))))))

(ert-deftest ogent-gastown-test-mail-read-default-creates-buffer ()
  "Test mail read without callback creates a display buffer."
  (ogent-gastown-test-with-mock '(:from "witness" :to "crew" :subject "Status" :date "2026-01-05" :body "All good")
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (ogent-gastown-mail-read "mail-042")
      (should (equal "mail" ogent-gastown-test--captured-command))
      (let ((buf (get-buffer "*Mail: mail-042*")))
        (unwind-protect
            (progn
              (should buf)
              (with-current-buffer buf
                (should (string-match-p "From: witness" (buffer-string)))
                (should (string-match-p "Subject: Status" (buffer-string)))
                (should (string-match-p "All good" (buffer-string)))))
          (when buf (kill-buffer buf)))))))

;;; Interactive Command Tests - ogent-gastown-show-hook

(ert-deftest ogent-gastown-test-show-hook-displays-buffer ()
  "Test show-hook creates a buffer with hook details."
  (let ((ogent-gastown--hook-cache ogent-gastown-test--sample-hook))
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (ogent-gastown-show-hook)
      (let ((buf (get-buffer "*Gas Town Hook*")))
        (unwind-protect
            (progn
              (should buf)
              (with-current-buffer buf
                (should (string-match-p "ogent-xyz" (buffer-string)))
                (should (string-match-p "Test hooked work" (buffer-string)))
                (should (string-match-p "hooked" (buffer-string)))
                (should (string-match-p "task" (buffer-string)))))
          (when buf (kill-buffer buf)))))))

(ert-deftest ogent-gastown-test-show-hook-no-hook ()
  "Test show-hook messages when no hook is set."
  (let ((ogent-gastown--hook-cache nil))
    ;; Should not error, just message
    (ogent-gastown-show-hook)))

;;; Interactive Command Tests - ogent-gastown-show-mail

(ert-deftest ogent-gastown-test-show-mail-creates-buffer ()
  "Test show-mail creates mail inbox buffer."
  (ogent-gastown-test-with-mock ogent-gastown-test--sample-mail
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (ogent-gastown-show-mail)
      (let ((buf (get-buffer "*Gas Town Mail*")))
        (unwind-protect
            (progn
              (should buf)
              (with-current-buffer buf
                (should (string-match-p "Mail Inbox" (buffer-string)))
                (should (string-match-p "mail-001" (buffer-string)))
                (should (string-match-p "witness" (buffer-string)))
                (should (string-match-p "Status check" (buffer-string)))))
          (when buf (kill-buffer buf)))))))

(ert-deftest ogent-gastown-test-show-mail-empty ()
  "Test show-mail displays empty message for no mail."
  (ogent-gastown-test-with-mock nil
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (ogent-gastown-show-mail)
      (let ((buf (get-buffer "*Gas Town Mail*")))
        (unwind-protect
            (progn
              (should buf)
              (with-current-buffer buf
                (should (string-match-p "No messages" (buffer-string)))))
          (when buf (kill-buffer buf)))))))

;;; Interactive Command Tests - ogent-gastown-show-ready

(ert-deftest ogent-gastown-test-show-ready-creates-buffer ()
  "Test show-ready creates buffer with ready issues."
  (ogent-gastown-test-bd-with-mock ogent-gastown-test--sample-ready-issues
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (ogent-gastown-show-ready)
      (let ((buf (get-buffer "*Beads Ready*")))
        (unwind-protect
            (progn
              (should buf)
              (with-current-buffer buf
                (should (string-match-p "Ready Work" (buffer-string)))
                (should (string-match-p "test-abc" (buffer-string)))
                (should (string-match-p "test-def" (buffer-string)))
                (should (string-match-p "\\[P1\\]" (buffer-string)))
                (should (string-match-p "\\[P2\\]" (buffer-string)))))
          (when buf (kill-buffer buf)))))))

(ert-deftest ogent-gastown-test-show-ready-empty ()
  "Test show-ready shows empty message when no issues."
  (ogent-gastown-test-bd-with-mock nil
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (ogent-gastown-show-ready)
      (let ((buf (get-buffer "*Beads Ready*")))
        (unwind-protect
            (progn
              (should buf)
              (with-current-buffer buf
                (should (string-match-p "No ready issues" (buffer-string)))))
          (when buf (kill-buffer buf)))))))

;;; Interactive Command Tests - ogent-gastown-bd-issue-start

(ert-deftest ogent-gastown-test-bd-issue-start ()
  "Test bd issue start calls claim on current issue."
  (let ((all-args nil))
    (let ((ogent-gastown--bd-ready-cache nil)
          (ogent-gastown-bd-executable "bd"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd) (when (string= cmd "bd") "/usr/local/bin/bd")))
                ((symbol-function 'ogent-gastown-bd--run-async)
                 (lambda (args callback &optional _error-cb _raw)
                   (push args all-args)
                   (funcall callback nil)
                   nil)))
        (with-temp-buffer
          (setq-local ogent-gastown-bd--current-issue-id "test-abc")
          (ogent-gastown-bd-issue-start)
          (let ((update-args (car (last all-args))))
            (should (member "update" update-args))
            (should (member "test-abc" update-args))
            (should (member "--status=in_progress" update-args))))))))

(ert-deftest ogent-gastown-test-bd-issue-start-nil-id ()
  "Test bd issue start does nothing when no current issue."
  (let ((ogent-gastown-test--bd-captured-args nil))
    (with-temp-buffer
      (setq-local ogent-gastown-bd--current-issue-id nil)
      (ogent-gastown-bd-issue-start)
      ;; Should not have made any calls
      (should-not ogent-gastown-test--bd-captured-args))))

;;; Interactive Command Tests - ogent-gastown-bd-issue-close

(ert-deftest ogent-gastown-test-bd-issue-close ()
  "Test bd issue close calls close with reason."
  (let ((all-args nil))
    (let ((ogent-gastown--bd-ready-cache nil)
          (ogent-gastown-bd-executable "bd"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd) (when (string= cmd "bd") "/usr/local/bin/bd")))
                ((symbol-function 'ogent-gastown-bd--run-async)
                 (lambda (args callback &optional _error-cb _raw)
                   (push args all-args)
                   (funcall callback nil)
                   nil))
                ((symbol-function 'read-string)
                 (lambda (_prompt &rest _) "Completed feature")))
        (with-temp-buffer
          (setq-local ogent-gastown-bd--current-issue-id "test-xyz")
          (ogent-gastown-bd-issue-close)
          (let ((close-args (car (last all-args))))
            (should (member "close" close-args))
            (should (member "test-xyz" close-args))
            (should (member "--reason=Completed feature" close-args))))))))

;;; Interactive Command Tests - ogent-gastown-bd-issue-refresh

(ert-deftest ogent-gastown-test-bd-issue-refresh ()
  "Test bd issue refresh calls show-issue on current issue."
  (ogent-gastown-test-bd-with-mock ogent-gastown-test--sample-issue
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (with-temp-buffer
        (setq-local ogent-gastown-bd--current-issue-id "test-abc")
        (ogent-gastown-bd-issue-refresh)
        ;; Should have called show with the issue ID
        (should (member "show" ogent-gastown-test--bd-captured-args))
        (should (member "test-abc" ogent-gastown-test--bd-captured-args))))))

(ert-deftest ogent-gastown-test-bd-issue-refresh-nil ()
  "Test bd issue refresh does nothing when no current issue."
  (with-temp-buffer
    (setq-local ogent-gastown-bd--current-issue-id nil)
    (ogent-gastown-bd-issue-refresh)
    ;; Nothing should happen, no error
    ))

;;; Interactive Command Tests - ogent-gastown-bd-ready-show-at-point

(ert-deftest ogent-gastown-test-bd-ready-show-at-point ()
  "Test show at point extracts ID and calls show-issue."
  (ogent-gastown-test-bd-with-mock ogent-gastown-test--sample-issue
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (with-temp-buffer
        (insert "[P1] test-abc [task] Ready issue 1\n")
        (insert "[P2] test-def [bug] Ready issue 2\n")
        (goto-char (point-min))
        (ogent-gastown-bd-ready-show-at-point)
        (should (member "show" ogent-gastown-test--bd-captured-args))
        (should (member "test-abc" ogent-gastown-test--bd-captured-args))))))

(ert-deftest ogent-gastown-test-bd-ready-show-at-point-no-match ()
  "Test show at point does nothing on non-issue line."
  (with-temp-buffer
    (insert "Some random text\n")
    (goto-char (point-min))
    (ogent-gastown-bd-ready-show-at-point)
    ;; No error, just nothing happens
    ))

;;; Interactive Command Tests - ogent-gastown-bd-ready-start-at-point

(ert-deftest ogent-gastown-test-bd-ready-start-at-point ()
  "Test start at point extracts ID and claims issue."
  (let ((all-args nil))
    (let ((ogent-gastown--bd-ready-cache nil)
          (ogent-gastown-bd-executable "bd"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd) (when (string= cmd "bd") "/usr/local/bin/bd")))
                ((symbol-function 'ogent-gastown-bd--run-async)
                 (lambda (args callback &optional _error-cb _raw)
                   (push args all-args)
                   (funcall callback nil)
                   nil)))
        (with-temp-buffer
          (insert "[P1] test-abc [task] Ready issue 1\n")
          (goto-char (point-min))
          (ogent-gastown-bd-ready-start-at-point)
          (let ((update-args (car (last all-args))))
            (should (member "update" update-args))
            (should (member "test-abc" update-args))
            (should (member "--status=in_progress" update-args))))))))

;;; Interactive Command Tests - ogent-gastown-send-mail

(ert-deftest ogent-gastown-test-send-mail ()
  "Test send-mail reads input and sends."
  (let ((all-commands nil)
        (all-args nil)
        (inputs '("witness" "Hello" "Test body")))
    (let ((ogent-gastown-gt-executable "gt")
          (ogent-gastown--hook-cache nil)
          (ogent-gastown--mail-cache nil)
          (ogent-gastown--convoy-cache nil)
          (ogent-gastown--town-root "/mock/gt/"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (_) "/usr/local/bin/gt"))
                ((symbol-function 'ogent-gastown--run-async)
                 (lambda (command args callback &optional _error-cb _raw)
                   (push command all-commands)
                   (push args all-args)
                   (funcall callback nil)
                   nil))
                ((symbol-function 'read-string)
                 (lambda (_prompt &rest _)
                   (pop inputs))))
        (ogent-gastown-send-mail)
        ;; The first call should be "mail" with "send" args
        (should (member "mail" all-commands))
        (let ((send-args (car (last all-args))))
          (should (member "send" send-args))
          (should (member "witness" send-args)))))))

(ert-deftest ogent-gastown-test-send-mail-empty-recipient ()
  "Test send-mail does nothing with empty recipient."
  (ogent-gastown-test-with-mock nil
    (let ((inputs '("" "Hello" "Test body")))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (_prompt &rest _)
                   (pop inputs))))
        (ogent-gastown-send-mail)
        ;; Should not have called run-async
        (should-not ogent-gastown-test--captured-command)))))

;;; Interactive Command Tests - ogent-gastown-show-convoy

(ert-deftest ogent-gastown-test-show-convoy-delegates-to-inspector ()
  "Test show-convoy delegates to convoy-status when available."
  (let ((called nil))
    (cl-letf (((symbol-function 'ogent-gastown-convoy-status)
               (lambda () (interactive) (setq called t))))
      (ogent-gastown-show-convoy)
      (should called))))

(ert-deftest ogent-gastown-test-show-convoy-plain-fallback ()
  "Test show-convoy falls back to plain buffer when inspector unavailable."
  (ogent-gastown-test-with-mock ogent-gastown-test--sample-convoy
    (cl-letf (((symbol-function 'display-buffer) #'ignore)
              ((symbol-function 'ogent-gastown-convoy-status) nil))
      (fmakunbound 'ogent-gastown-convoy-status)
      (unwind-protect
          (progn
            (ogent-gastown-show-convoy)
            (let ((buf (get-buffer "*Gas Town Convoys*")))
              (unwind-protect
                  (progn
                    (should buf)
                    (with-current-buffer buf
                      (should (string-match-p "Active Convoys" (buffer-string)))
                      (should (string-match-p "convoy-001" (buffer-string)))
                      (should (string-match-p "Feature implementation" (buffer-string)))
                      (should (string-match-p "75%" (buffer-string)))))
                (when buf (kill-buffer buf)))))
        ;; Restore the function
        (autoload 'ogent-gastown-convoy-status "ogent-gastown-status" nil t)))))

(ert-deftest ogent-gastown-test-show-convoy-empty ()
  "Test show-convoy plain fallback with no convoys."
  (ogent-gastown-test-with-mock nil
    (cl-letf (((symbol-function 'display-buffer) #'ignore)
              ((symbol-function 'ogent-gastown-convoy-status) nil))
      (fmakunbound 'ogent-gastown-convoy-status)
      (unwind-protect
          (progn
            (ogent-gastown-show-convoy)
            (let ((buf (get-buffer "*Gas Town Convoys*")))
              (unwind-protect
                  (progn
                    (should buf)
                    (with-current-buffer buf
                      (should (string-match-p "No active convoys" (buffer-string)))))
                (when buf (kill-buffer buf)))))
        (autoload 'ogent-gastown-convoy-status "ogent-gastown-status" nil t)))))

;;; Interactive Command Tests - ogent-gastown-claim-issue

(ert-deftest ogent-gastown-test-claim-issue ()
  "Test claim-issue sets status to in_progress."
  (let ((all-args nil))
    (let ((ogent-gastown--bd-ready-cache nil)
          (ogent-gastown-bd-executable "bd"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd) (when (string= cmd "bd") "/usr/local/bin/bd")))
                ((symbol-function 'ogent-gastown-bd--run-async)
                 (lambda (args callback &optional _error-cb _raw)
                   (push args all-args)
                   (funcall callback nil)
                   nil)))
        (ogent-gastown-claim-issue "issue-123")
        (let ((update-args (car (last all-args))))
          (should (member "update" update-args))
          (should (member "issue-123" update-args))
          (should (member "--status=in_progress" update-args)))))))

;;; Interactive Command Tests - ogent-gastown-close-issue

(ert-deftest ogent-gastown-test-close-issue ()
  "Test close-issue sends close command with reason."
  (let ((all-args nil))
    (let ((ogent-gastown--bd-ready-cache nil)
          (ogent-gastown-bd-executable "bd"))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd) (when (string= cmd "bd") "/usr/local/bin/bd")))
                ((symbol-function 'ogent-gastown-bd--run-async)
                 (lambda (args callback &optional _error-cb _raw)
                   (push args all-args)
                   (funcall callback nil)
                   nil)))
        (ogent-gastown-close-issue "issue-123" "Fixed the bug")
        (let ((close-args (car (last all-args))))
          (should (member "close" close-args))
          (should (member "issue-123" close-args))
          (should (member "--reason=Fixed the bug" close-args)))))))

;;; Mail Read At Point Tests

(ert-deftest ogent-gastown-test-mail-read-at-point-unread ()
  "Test mail read at point extracts ID from unread line."
  (ogent-gastown-test-with-mock '(:from "witness" :to "me" :subject "Test" :date "2026-01-01" :body "Hello")
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (with-temp-buffer
        (insert "● mail-001 witness: Status check\n")
        (insert "  mail-002 refinery: Merge complete\n")
        (goto-char (point-min))
        (ogent-gastown-mail-read-at-point)
        (should (equal "mail" ogent-gastown-test--captured-command))
        (should (member "read" ogent-gastown-test--captured-args))
        (should (member "mail-001" ogent-gastown-test--captured-args))))))

(ert-deftest ogent-gastown-test-mail-read-at-point-read ()
  "Test mail read at point extracts ID from already-read line."
  (ogent-gastown-test-with-mock '(:from "refinery" :to "me" :subject "Merge" :date "2026-01-01" :body "Done")
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (with-temp-buffer
        (insert "● mail-001 witness: Status check\n")
        (insert "  mail-002 refinery: Merge complete\n")
        (goto-char (point-min))
        (forward-line)
        (ogent-gastown-mail-read-at-point)
        (should (equal "mail" ogent-gastown-test--captured-command))
        (should (member "mail-002" ogent-gastown-test--captured-args))))))

;;; Mode Keymap Tests

(ert-deftest ogent-gastown-test-bd-ready-mode-keymap ()
  "Test BD-Ready mode keymap bindings."
  (should (eq (lookup-key ogent-gastown-bd-ready-mode-map (kbd "RET"))
              'ogent-gastown-bd-ready-show-at-point))
  (should (eq (lookup-key ogent-gastown-bd-ready-mode-map (kbd "s"))
              'ogent-gastown-bd-ready-start-at-point))
  (should (eq (lookup-key ogent-gastown-bd-ready-mode-map (kbd "g"))
              'ogent-gastown-show-ready))
  (should (eq (lookup-key ogent-gastown-bd-ready-mode-map (kbd "q"))
              'quit-window)))

(ert-deftest ogent-gastown-test-bd-issue-mode-keymap ()
  "Test BD-Issue mode keymap bindings."
  (should (eq (lookup-key ogent-gastown-bd-issue-mode-map (kbd "s"))
              'ogent-gastown-bd-issue-start))
  (should (eq (lookup-key ogent-gastown-bd-issue-mode-map (kbd "c"))
              'ogent-gastown-bd-issue-close))
  (should (eq (lookup-key ogent-gastown-bd-issue-mode-map (kbd "g"))
              'ogent-gastown-bd-issue-refresh))
  (should (eq (lookup-key ogent-gastown-bd-issue-mode-map (kbd "q"))
              'quit-window)))

(ert-deftest ogent-gastown-test-mail-mode-keymap ()
  "Test mail mode keymap bindings."
  (should (eq (lookup-key ogent-gastown-mail-mode-map (kbd "RET"))
              'ogent-gastown-mail-read-at-point))
  (should (eq (lookup-key ogent-gastown-mail-mode-map (kbd "r"))
              'ogent-gastown-mail-reply-at-point))
  (should (eq (lookup-key ogent-gastown-mail-mode-map (kbd "c"))
              'ogent-gastown-send-mail))
  (should (eq (lookup-key ogent-gastown-mail-mode-map (kbd "g"))
              'ogent-gastown-show-mail))
  (should (eq (lookup-key ogent-gastown-mail-mode-map (kbd "q"))
              'quit-window)))

;;; ====================================================================
;;; NEW COVERAGE TESTS (ogent-gastown.el + ogent-gastown-status.el)
;;; ====================================================================

;;; --- Town Root Detection Tests ---

(ert-deftest ogent-gastown-test-town-root-cached ()
  "Test that town root returns cached value when set."
  (let ((ogent-gastown--town-root "/cached/gt/"))
    (should (equal "/cached/gt/" (ogent-gastown-town-root)))))

(ert-deftest ogent-gastown-test-town-root-delegates-to-shared-finder ()
  "Test town-root delegates workspace discovery to shared status helper."
  (let ((ogent-gastown--town-root nil))
    (cl-letf (((symbol-function 'ogent-gastown--find-town-root)
               (lambda () "/shared/root/")))
      (should (equal "/shared/root/" (ogent-gastown-town-root))))))

(ert-deftest ogent-gastown-test-town-root-from-gt-prefix ()
  "Test town root detection when under ~/gt/ directory."
  (let ((ogent-gastown--town-root nil)
        (default-directory (expand-file-name "~/gt/some/project/")))
    (cl-letf (((symbol-function 'locate-dominating-file)
               (lambda (_dir _file) nil))
              ((symbol-function 'getenv)
               (lambda (_var) nil)))
      ;; Should detect ~/gt/ prefix
      (let ((result (ogent-gastown-town-root)))
        (should (equal (expand-file-name "~/gt/") result))))))

(ert-deftest ogent-gastown-test-town-root-from-gastown-marker ()
  "Test town root detection from .gastown marker file."
  (let ((ogent-gastown--town-root nil)
        (default-directory "/some/other/dir/")
        (marker-root (make-temp-file "ogent-town-root-marker-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'locate-dominating-file)
                   (lambda (_dir file)
                     (when (equal file ".gastown")
                       marker-root)))
                  ((symbol-function 'getenv)
                   (lambda (_var) nil)))
          (should (equal (file-name-as-directory (expand-file-name marker-root))
                         (ogent-gastown-town-root))))
      (delete-directory marker-root))))

(ert-deftest ogent-gastown-test-town-root-falls-back-to-default-root ()
  "Test town root falls back to configured default root when no marker is found."
  (let ((root (make-temp-file "ogent-town-root-default-fallback-" t)))
    (unwind-protect
        (let ((ogent-gastown--town-root nil)
              (default-directory "/tmp/random/")
              (ogent-gastown-default-town-root root))
          (cl-letf (((symbol-function 'locate-dominating-file)
                     (lambda (_dir _file) nil))
                    ((symbol-function 'getenv)
                     (lambda (_var) nil)))
            (should (equal (file-name-as-directory (expand-file-name root))
                           (ogent-gastown-town-root)))))
      (delete-directory root t))))

;;; --- Mode Line Update Tests ---

(ert-deftest ogent-gastown-test-update-mode-line-with-hook ()
  "Test mode line string is set when hook is active."
  (let ((ogent-gastown--hook-cache '(:id "abc-123" :title "Test work")))
    (ogent-gastown--update-mode-line)
    (should (stringp ogent-gastown--mode-line-string))
    (should (string-match-p "abc-123" ogent-gastown--mode-line-string))))

(ert-deftest ogent-gastown-test-update-mode-line-no-hook ()
  "Test mode line string is empty when no hook is active."
  (let ((ogent-gastown--hook-cache nil))
    (ogent-gastown--update-mode-line)
    (should (equal "" ogent-gastown--mode-line-string))))

(ert-deftest ogent-gastown-test-update-mode-line-no-id ()
  "Test mode line uses fallback when hook has no id."
  (let ((ogent-gastown--hook-cache '(:title "Some work")))
    (ogent-gastown--update-mode-line)
    (should (stringp ogent-gastown--mode-line-string))
    (should (string-match-p "hooked" ogent-gastown--mode-line-string))))

;;; --- Header Line Formatting Tests ---

(ert-deftest ogent-gastown-test-header-line-with-mail ()
  "Test header line shows mail count when there are unread messages."
  (let ((ogent-gastown--hook-cache '(:id "test-id" :title "Work"))
        (ogent-gastown--mail-cache
         (list '(:id "m1" :read nil)
               '(:id "m2" :read nil)
               '(:id "m3" :read t))))
    (let ((header (ogent-gastown--format-header-line)))
      (should (string-match-p "Gas Town" header))
      (should (string-match-p "test-id" header))
      ;; Should show 2 unread
      (should (string-match-p "2" header)))))

(ert-deftest ogent-gastown-test-header-line-with-title-truncation ()
  "Test header line truncates long titles."
  (let ((ogent-gastown--hook-cache
         '(:id "x" :title "This is a very long title that exceeds thirty characters"))
        (ogent-gastown--mail-cache nil))
    (let ((header (ogent-gastown--format-header-line)))
      ;; The title should be truncated
      (should (stringp header))
      (should (string-match-p "x" header)))))

;;; --- Polling Tests ---

(ert-deftest ogent-gastown-test-start-stop-polling ()
  "Test that polling timer starts and stops correctly."
  (let ((ogent-gastown--poll-timer nil)
        (ogent-gastown-poll-interval 60))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat _fn)
                 'mock-timer))
              ((symbol-function 'cancel-timer)
               (lambda (_timer) nil)))
      (ogent-gastown--start-polling)
      (should (eq 'mock-timer ogent-gastown--poll-timer))
      (ogent-gastown--stop-polling)
      (should-not ogent-gastown--poll-timer))))

(ert-deftest ogent-gastown-test-start-polling-disabled ()
  "Test that polling does not start when interval is 0."
  (let ((ogent-gastown--poll-timer nil)
        (ogent-gastown-poll-interval 0))
    (ogent-gastown--start-polling)
    (should-not ogent-gastown--poll-timer)))

(ert-deftest ogent-gastown-test-poll-calls-refresh ()
  "Test that poll calls hook and mail refresh when in town."
  (let ((refreshed nil))
    (cl-letf (((symbol-function 'ogent-gastown-in-town-p)
               (lambda () t))
              ((symbol-function 'ogent-gastown-hook-refresh)
               (lambda (&optional _cb) (push 'hook refreshed)))
              ((symbol-function 'ogent-gastown-mail-refresh)
               (lambda (&optional _cb) (push 'mail refreshed))))
      (ogent-gastown--poll)
      (should (member 'hook refreshed))
      (should (member 'mail refreshed)))))

(ert-deftest ogent-gastown-test-poll-noop-outside-town ()
  "Test that poll does nothing when not in town."
  (let ((refreshed nil))
    (cl-letf (((symbol-function 'ogent-gastown-in-town-p)
               (lambda () nil))
              ((symbol-function 'ogent-gastown-hook-refresh)
               (lambda (&optional _cb) (push 'hook refreshed)))
              ((symbol-function 'ogent-gastown-mail-refresh)
               (lambda (&optional _cb) (push 'mail refreshed))))
      (ogent-gastown--poll)
      (should-not refreshed))))

;;; --- Mode Enable/Disable Tests ---

(ert-deftest ogent-gastown-test-mode-restores-header-line ()
  "Test that disabling mode restores the original header-line."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/mock/gt/")
          (original-header "original-format"))
      (setq-local header-line-format original-header)
      (cl-letf (((symbol-function 'ogent-gastown-in-town-p)
                 (lambda () nil))
                ((symbol-function 'ogent-gastown--start-polling)
                 (lambda () nil))
                ((symbol-function 'ogent-gastown--stop-polling)
                 (lambda () nil)))
        (ogent-gastown-mode 1)
        ;; Header line should be changed
        (should (equal '(:eval (ogent-gastown--format-header-line))
                       header-line-format))
        (ogent-gastown-mode -1)
        ;; Should be restored
        (should (equal original-header header-line-format))))))

;;; --- Show Hook with Description Tests ---

(ert-deftest ogent-gastown-test-show-hook-with-description ()
  "Test show-hook displays description when present."
  (let ((ogent-gastown--hook-cache
         '(:id "task-1" :title "Big task" :status "active"
           :type "feature" :description "A detailed description")))
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (ogent-gastown-show-hook)
      (let ((buf (get-buffer "*Gas Town Hook*")))
        (unwind-protect
            (progn
              (should buf)
              (with-current-buffer buf
                (should (string-match-p "task-1" (buffer-string)))
                (should (string-match-p "Big task" (buffer-string)))
                (should (string-match-p "A detailed description" (buffer-string)))))
          (when buf (kill-buffer buf)))))))

;;; --- Show Issue Buffer Tests ---

(ert-deftest ogent-gastown-test-show-issue-creates-buffer ()
  "Test show-issue creates a buffer with issue details."
  (ogent-gastown-test-bd-with-mock ogent-gastown-test--sample-issue
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (ogent-gastown-show-issue "test-abc")
      (let ((buf (get-buffer "*Beads: test-abc*")))
        (unwind-protect
            (progn
              (should buf)
              (with-current-buffer buf
                (should (string-match-p "Test issue" (buffer-string)))
                (should (string-match-p "test-abc" (buffer-string)))
                (should (string-match-p "P1" (buffer-string)))
                (should (string-match-p "task" (buffer-string)))
                (should (string-match-p "A test issue" (buffer-string)))
                (should (string-match-p "2026-01-05" (buffer-string)))))
          (when buf (kill-buffer buf)))))))

;;; --- Mail Unread Count Edge Cases ---

(ert-deftest ogent-gastown-test-mail-unread-count-empty ()
  "Test unread count returns 0 for empty mail cache."
  (let ((ogent-gastown--mail-cache nil))
    (should (equal 0 (ogent-gastown-mail-unread-count)))))

(ert-deftest ogent-gastown-test-mail-unread-count-all-read ()
  "Test unread count returns 0 when all messages are read."
  (let ((ogent-gastown--mail-cache
         (list '(:id "m1" :read t)
               '(:id "m2" :read t))))
    (should (equal 0 (ogent-gastown-mail-unread-count)))))

(ert-deftest ogent-gastown-test-mail-unread-count-all-unread ()
  "Test unread count returns total when all messages are unread."
  (let ((ogent-gastown--mail-cache
         (list '(:id "m1" :read nil)
               '(:id "m2" :read nil)
               '(:id "m3" :read nil))))
    (should (equal 3 (ogent-gastown-mail-unread-count)))))

;;; --- Convoy Error Handling ---

(ert-deftest ogent-gastown-test-convoy-refresh-error ()
  "Test error handling in convoy refresh."
  (ogent-gastown-test-with-error "convoy failed"
    (ogent-gastown-convoy-refresh nil)
    (should-not ogent-gastown--convoy-cache)))

;;; --- BD Ready Refresh Error ---

(ert-deftest ogent-gastown-test-bd-ready-refresh-error ()
  "Test error handling in bd ready refresh."
  (let ((ogent-gastown--bd-ready-cache '((:id "old")))
        (ogent-gastown-bd-executable "bd"))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (cmd) (when (string= cmd "bd") "/usr/local/bin/bd")))
              ((symbol-function 'ogent-gastown-bd--run-async)
               (lambda (_args _callback &optional error-callback _raw)
                 (when error-callback
                   (funcall error-callback "bd ready failed"))
                 nil)))
      (ogent-gastown-bd-ready-refresh nil)
      ;; Cache should be cleared on error
      (should-not ogent-gastown--bd-ready-cache))))

;;; --- ogent-gastown-status.el Tests ---

;;; --- Cache Tests ---

(ert-deftest ogent-gastown-test-cache-key ()
  "Test cache key generation."
  (let ((key1 (ogent-gastown--cache-key '("hook" "--json")))
        (key2 (ogent-gastown--cache-key '("mail" "inbox" "--json"))))
    (should (stringp key1))
    (should (stringp key2))
    (should-not (equal key1 key2))))

(ert-deftest ogent-gastown-test-cache-set-and-get ()
  "Test caching set and get within TTL."
  (let ((ogent-gastown--cache (make-hash-table :test 'equal))
        (ogent-gastown-cache-ttl 60))
    (ogent-gastown--cache-set '("test") '(:result "data"))
    (let ((cached (ogent-gastown--cache-get '("test"))))
      (should cached)
      (should (equal '(:result "data") cached)))))

(ert-deftest ogent-gastown-test-cache-miss ()
  "Test cache miss for uncached args."
  (let ((ogent-gastown--cache (make-hash-table :test 'equal))
        (ogent-gastown-cache-ttl 60))
    (should-not (ogent-gastown--cache-get '("nonexistent")))))

(ert-deftest ogent-gastown-test-cache-disabled ()
  "Test that cache returns nil when TTL is 0."
  (let ((ogent-gastown--cache (make-hash-table :test 'equal))
        (ogent-gastown-cache-ttl 0))
    (ogent-gastown--cache-set '("test") '(:result "data"))
    (should-not (ogent-gastown--cache-get '("test")))))

(ert-deftest ogent-gastown-test-cache-invalidate ()
  "Test cache invalidation clears all entries."
  (let ((ogent-gastown--cache (make-hash-table :test 'equal))
        (ogent-gastown-cache-ttl 60))
    (ogent-gastown--cache-set '("a") '(:data 1))
    (ogent-gastown--cache-set '("b") '(:data 2))
    (ogent-gastown-cache-invalidate)
    (should-not (ogent-gastown--cache-get '("a")))
    (should-not (ogent-gastown--cache-get '("b")))))

;;; --- Format Time Tests ---

(ert-deftest ogent-gastown-test-format-time-nil ()
  "Test format-time handles nil input."
  (should (equal "???" (ogent-gastown--format-time nil))))

(ert-deftest ogent-gastown-test-format-time-empty ()
  "Test format-time handles empty string."
  (should (equal "???" (ogent-gastown--format-time ""))))

(ert-deftest ogent-gastown-test-format-time-invalid ()
  "Test format-time handles invalid time string."
  (should (equal "???" (ogent-gastown--format-time "not-a-date"))))

(ert-deftest ogent-gastown-test-format-time-recent ()
  "Test format-time for a recent timestamp returns relative time."
  (require 'parse-time)
  ;; A timestamp from 30 minutes ago
  (let* ((past (time-subtract (current-time) (seconds-to-time 1800)))
         (iso (format-time-string "%FT%T%z" past)))
    (let ((result (ogent-gastown--format-time iso)))
      (should (stringp result))
      (should (string-match-p "m ago" result)))))

(ert-deftest ogent-gastown-test-format-time-hours-ago ()
  "Test format-time for a timestamp hours ago."
  (require 'parse-time)
  (let* ((past (time-subtract (current-time) (seconds-to-time 7200)))
         (iso (format-time-string "%FT%T%z" past)))
    (let ((result (ogent-gastown--format-time iso)))
      (should (stringp result))
      (should (string-match-p "h ago" result)))))

;;; --- Status Plain Section Tests ---

(ert-deftest ogent-gastown-test-insert-hook-section-plain-with-work ()
  "Test hook section plain rendering with hooked work."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data '(:has_work t :role "crew")))
      (ogent-gastown--insert-hook-section-plain)
      (should (string-match-p "Hook Status" (buffer-string)))
      (should (string-match-p "crew" (buffer-string)))
      (should (string-match-p "Work hooked" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-hook-section-plain-no-work ()
  "Test hook section plain rendering without hooked work."
  (with-temp-buffer
    (let ((ogent-gastown--hook-data '(:has_work nil :role "witness")))
      (ogent-gastown--insert-hook-section-plain)
      (should (string-match-p "Hook Status" (buffer-string)))
      (should (string-match-p "witness" (buffer-string)))
      (should (string-match-p "No work hooked" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-mail-section-plain-with-msgs ()
  "Test mail section plain rendering with messages."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data
           (list '(:from "alice" :subject "Hello" :read nil)
                 '(:from "bob" :subject "Update" :read t))))
      (ogent-gastown--insert-mail-section-plain)
      (should (string-match-p "Mail Inbox" (buffer-string)))
      (should (string-match-p "alice" (buffer-string)))
      (should (string-match-p "bob" (buffer-string)))
      ;; Unread marker
      (should (string-match-p "\\* alice" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-mail-section-plain-empty ()
  "Test mail section plain rendering with no messages."
  (with-temp-buffer
    (let ((ogent-gastown--mail-data nil))
      (ogent-gastown--insert-mail-section-plain)
      (should (string-match-p "No messages" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-convoy-section-plain-with-data ()
  "Test convoy section plain rendering with normalized convoys."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data
           (list '(:id "convoy-001" :title "Deploy v2" :status "active"))))
      (ogent-gastown--insert-convoy-section-plain)
      (should (string-match-p "Convoys" (buffer-string)))
      (should (string-match-p "Deploy v2" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-convoy-section-plain-empty ()
  "Test convoy section plain rendering with no convoys."
  (with-temp-buffer
    (let ((ogent-gastown--convoy-data nil))
      (ogent-gastown--insert-convoy-section-plain)
      (should (string-match-p "No active convoys" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-workers-section-plain-with-data ()
  "Test workers section plain rendering with workers."
  (with-temp-buffer
    (let ((ogent-gastown--workers-data
           (list '(:rig "ogent" :name "alpha" :state "running")
                 '(:rig "ogent" :name "beta" :state "idle"))))
      (ogent-gastown--insert-workers-section-plain)
      (should (string-match-p "Workers" (buffer-string)))
      (should (string-match-p "ogent/alpha" (buffer-string)))
      (should (string-match-p "ogent/beta" (buffer-string)))
      (should (string-match-p "\\[running\\]" (buffer-string)))
      (should (string-match-p "\\[idle\\]" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-workers-section-plain-empty ()
  "Test workers section plain rendering with no workers."
  (with-temp-buffer
    (let ((ogent-gastown--workers-data nil))
      (ogent-gastown--insert-workers-section-plain)
      (should (string-match-p "No workers" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-crew-section-plain-with-data ()
  "Test crew section plain rendering with crew members."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data
           (list '(:rig "ogent" :name "stallman" :session_running t)
                 '(:rig "beads" :name "knuth" :session_running nil))))
      (ogent-gastown--insert-crew-section-plain)
      (should (string-match-p "Crew" (buffer-string)))
      (should (string-match-p "ogent/stallman" (buffer-string)))
      (should (string-match-p "beads/knuth" (buffer-string)))
      (should (string-match-p "\\[active\\]" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-crew-section-plain-empty ()
  "Test crew section plain rendering with no crew."
  (with-temp-buffer
    (let ((ogent-gastown--crew-data nil))
      (ogent-gastown--insert-crew-section-plain)
      (should (string-match-p "No crew members" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-polecat-section-plain-with-data ()
  "Test polecat section plain rendering with polecats."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data
           (list '(:rig "ogent" :name "alpha" :state "running" :session_running t)
                 '(:rig "ogent" :name "beta" :state "idle" :session_running nil))))
      (ogent-gastown--insert-polecat-section-plain)
      (should (string-match-p "Polecats" (buffer-string)))
      (should (string-match-p "ogent/alpha" (buffer-string)))
      (should (string-match-p "\\[running\\]" (buffer-string)))
      (should (string-match-p "running" (buffer-string))))))

(ert-deftest ogent-gastown-test-insert-polecat-section-plain-empty ()
  "Test polecat section plain rendering with no polecats."
  (with-temp-buffer
    (let ((ogent-gastown--polecat-data nil))
      (ogent-gastown--insert-polecat-section-plain)
      (should (string-match-p "No polecats" (buffer-string))))))

;;; --- Navigation Tests (Non-Magit) ---

(ert-deftest ogent-gastown-test-next-item-plain ()
  "Test next-item falls back to forward-line without magit."
  (with-temp-buffer
    (insert "line1\nline2\nline3\n")
    (goto-char (point-min))
    (let ((ogent-gastown--magit-section-available nil))
      (ogent-gastown-next-item)
      (should (= 2 (line-number-at-pos))))))

(ert-deftest ogent-gastown-test-prev-item-plain ()
  "Test prev-item falls back to forward-line -1 without magit."
  (with-temp-buffer
    (insert "line1\nline2\nline3\n")
    (goto-char (point-min))
    (forward-line 2)
    (let ((ogent-gastown--magit-section-available nil))
      (ogent-gastown-prev-item)
      (should (= 2 (line-number-at-pos))))))

(ert-deftest ogent-gastown-test-visit-rig-magit-status-opens-target-rig ()
  "Rig-scoped sections should open `magit-status' for the represented rig."
  (let ((root (make-temp-file "ogent-gastown-visit-rig-" t)))
    (unwind-protect
        (dolist (entry '((ogent-gastown-witness-item-section (:rig "witness") "witness")
                         (ogent-gastown-crew-item-section (:rig "crew-rig") "crew-rig")
                         (ogent-gastown-rig-item-section (:name "mayor-rig") "mayor-rig")))
          (pcase-let ((`(,section-class ,value ,expected-rig) entry))
            (let* ((section (ogent-gastown-test--section :value value))
                   (rig-path (expand-file-name expected-rig root))
                   (opened-path nil))
              (make-directory rig-path t)
              (cl-letf (((symbol-function 'ogent-gastown--magit-usable-p)
                         (lambda () t))
                        ((symbol-function 'magit-current-section)
                         (lambda () section))
                        ((symbol-function 'eieio-object-class-name)
                         (lambda (_section) section-class))
                        ((symbol-function 'magit-status)
                         (lambda (directory &rest _)
                           (setq opened-path directory))))
                (let ((ogent-gastown--town-root root))
                  (should (ogent-gastown--visit-rig-magit-status))
                  (should (equal rig-path opened-path)))))))
      (delete-directory root t))))

(ert-deftest ogent-gastown-test-visit-opens-rig-status-before-toggle ()
  "Visit should open rig status for rig-scoped items instead of toggling."
  (let ((opened nil)
        (toggled nil))
    (cl-letf (((symbol-function 'ogent-gastown--magit-usable-p)
               (lambda () t))
              ((symbol-function 'magit-current-section)
               (lambda () 'section))
              ((symbol-function 'eieio-object-class-name)
               (lambda (_section) 'ogent-gastown-crew-item-section))
              ((symbol-function 'ogent-gastown--visit-rig-magit-status)
               (lambda ()
                 (setq opened t)
                 t))
              ((symbol-function 'magit-section-toggle)
               (lambda (_section)
                 (setq toggled t))))
      (ogent-gastown-visit)
      (should opened)
      (should-not toggled))))

(ert-deftest ogent-gastown-test-visit-toggles-when-rig-status-not-applicable ()
  "Visit should keep default toggle behavior for non-rig sections."
  (let ((toggled nil))
    (cl-letf (((symbol-function 'ogent-gastown--magit-usable-p)
               (lambda () t))
              ((symbol-function 'magit-current-section)
               (lambda () 'section))
              ((symbol-function 'eieio-object-class-name)
               (lambda (_section) 'ogent-gastown-workers-section))
              ((symbol-function 'ogent-gastown--visit-rig-magit-status)
               (lambda () nil))
              ((symbol-function 'magit-section-toggle)
               (lambda (_section)
                 (setq toggled t))))
      (ogent-gastown-visit)
      (should toggled))))

;;; --- Header Line (status buffer) Tests ---

(ert-deftest ogent-gastown-test-status-header-line-loading ()
  "Test status header line shows loading indicator."
  (with-temp-buffer
    (let ((ogent-gastown--loading t)
          (ogent-gastown--loading-frame 0)
          (ogent-gastown--mail-data nil)
          (ogent-gastown--hook-data nil))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "Gas Town" header))
        (should (string-match-p "Loading" header))))))

(ert-deftest ogent-gastown-test-status-header-line-hook-active ()
  "Test status header line shows hook active."
  (with-temp-buffer
    (let ((ogent-gastown--loading nil)
          (ogent-gastown--mail-data nil)
          (ogent-gastown--hook-data '(:has_work t)))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "Hook: active" header))))))

(ert-deftest ogent-gastown-test-status-header-line-hook-empty ()
  "Test status header line shows hook empty."
  (with-temp-buffer
    (let ((ogent-gastown--loading nil)
          (ogent-gastown--mail-data nil)
          (ogent-gastown--hook-data nil))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "Hook: empty" header))))))

(ert-deftest ogent-gastown-test-status-header-line-with-unread ()
  "Test status header line shows unread mail count."
  (with-temp-buffer
    (let ((ogent-gastown--loading nil)
          (ogent-gastown--mail-data
           (list '(:id "m1" :read nil)
                 '(:id "m2" :read nil)))
          (ogent-gastown--hook-data nil))
      (let ((header (ogent-gastown--header-line)))
        (should (string-match-p "2 unread" header))))))

;;; --- Loading Animation Tests ---

(ert-deftest ogent-gastown-test-loading-indicator-nil ()
  "Test loading indicator returns nil when not loading."
  (with-temp-buffer
    (let ((ogent-gastown--loading nil))
      (should-not (ogent-gastown--loading-indicator)))))

(ert-deftest ogent-gastown-test-loading-indicator-returns-frame ()
  "Test loading indicator returns current frame when loading."
  (with-temp-buffer
    (let ((ogent-gastown--loading t)
          (ogent-gastown--loading-frame 0))
      (should (ogent-gastown--loading-indicator)))))

(ert-deftest ogent-gastown-test-animate-loading ()
  "Test animate-loading advances the frame."
  (with-temp-buffer
    (cl-letf (((symbol-function 'ogent-gastown--loading-frames)
               (lambda () '("a" "b" "c"))))
      (let ((ogent-gastown--loading-frame 0))
        (ogent-gastown--animate-loading (current-buffer))
        (should (= 1 ogent-gastown--loading-frame))
        (ogent-gastown--animate-loading (current-buffer))
        (should (= 2 ogent-gastown--loading-frame))
        ;; Wraps at current frame count.
        (ogent-gastown--animate-loading (current-buffer))
        (should (= 0 ogent-gastown--loading-frame))))))

(ert-deftest ogent-gastown-test-animate-loading-dead-buffer ()
  "Test animate-loading does nothing for killed buffer."
  (let ((buf (generate-new-buffer " *test-dead*")))
    (with-current-buffer buf
      (setq-local ogent-gastown--loading-frame 0))
    (kill-buffer buf)
    ;; Should not error
    (ogent-gastown--animate-loading buf)))

;;; --- Find Town Root (status) Tests ---

(ert-deftest ogent-gastown-test-find-town-root-from-env ()
  "Test status find-town-root uses GT_ROOT env var."
  (let ((root (make-temp-file "ogent-gt-root-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'getenv)
                   (lambda (var)
                     (when (equal var "GT_ROOT")
                       root))))
          (should (equal (file-name-as-directory (expand-file-name root))
                         (ogent-gastown--find-town-root))))
      (delete-directory root))))

(ert-deftest ogent-gastown-test-find-town-root-from-gt-town-env ()
  "Test status find-town-root uses GT_TOWN when GT_ROOT is unset."
  (let ((root (make-temp-file "ogent-gt-town-" t)))
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

(ert-deftest ogent-gastown-test-find-town-root-falls-back-to-default-root ()
  "Test status find-town-root falls back to configured default root."
  (let ((root (make-temp-file "ogent-gt-default-root-fallback-" t)))
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

(ert-deftest ogent-gastown-test-find-town-root-nil-when-default-root-missing ()
  "Test status find-town-root returns nil when default root does not exist."
  (let ((default-directory "/tmp/not-a-town/")
        (ogent-gastown-default-town-root
         (make-temp-name
          (expand-file-name "ogent-gt-missing-default-root-"
                            temporary-file-directory))))
    (cl-letf (((symbol-function 'getenv)
               (lambda (_var) nil))
              ((symbol-function 'locate-dominating-file)
               (lambda (_dir _marker) nil)))
      (should-not (ogent-gastown--find-town-root)))))

;;; --- In Town Check (status) Tests ---

(ert-deftest ogent-gastown-test-status-in-town-p ()
  "Test status in-town-p requires executable and workspace."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) "/usr/local/bin/gt"))
            ((symbol-function 'ogent-gastown--find-town-root)
             (lambda () "/workspace/")))
    (should (ogent-gastown--in-town-p)))

  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil))
            ((symbol-function 'ogent-gastown--find-town-root)
             (lambda () "/workspace/")))
    (should-not (ogent-gastown--in-town-p)))

  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) "/usr/local/bin/gt"))
            ((symbol-function 'ogent-gastown--find-town-root)
             (lambda () nil)))
    (should-not (ogent-gastown--in-town-p))))

;;; --- Stat Item Rendering ---

(ert-deftest ogent-gastown-test-insert-stat-item ()
  "Test stat item renders label and value."
  (with-temp-buffer
    (ogent-gastown--insert-stat-item "Rigs" 5)
    (should (string-match-p "Rigs" (buffer-string)))
    (should (string-match-p "5" (buffer-string)))))

(ert-deftest ogent-gastown-test-insert-stat-item-nil ()
  "Test stat item renders nil value as 0."
  (with-temp-buffer
    (ogent-gastown--insert-stat-item "Hooks" nil)
    (should (string-match-p "Hooks" (buffer-string)))
    (should (string-match-p "0" (buffer-string)))))

;;; --- Plain Buffer Rendering Tests ---

(ert-deftest ogent-gastown-test-insert-plain-all-sections ()
  "Test that insert-plain renders all sections without error."
  (with-temp-buffer
    (let ((ogent-gastown--stats-data '(:rig_count 2 :polecat_count 1
                                       :crew_count 3 :witness_count 1
                                       :refinery_count 1 :active_hooks 1))
          (ogent-gastown--deacon-data '(:name "deacon" :running t))
          (ogent-gastown--witness-data
           (list '(:rig "ogent" :has_witness t :polecat_count 1 :crew_count 2)))
          (ogent-gastown--hook-data '(:has_work t :role "crew"))
          (ogent-gastown--mail-data nil)
          (ogent-gastown--convoy-data nil)
          (ogent-gastown--rigs-data nil)
          (ogent-gastown--crew-data nil)
          (ogent-gastown--polecat-data nil)
          (ogent-gastown--workers-data nil))
      ;; Should not error
      (ogent-gastown--insert-plain)
      (should (> (buffer-size) 0))
      (should (string-match-p "Town Stats" (buffer-string)))
      (should (string-match-p "Deacon" (buffer-string)))
      (should (string-match-p "Witnesses" (buffer-string)))
      (should (string-match-p "Hook Status" (buffer-string)))
      (should (string-match-p "Mail Inbox" (buffer-string)))
      (should (string-match-p "Convoys" (buffer-string))))))

;;; --- Crew Rig Path Tests ---

(ert-deftest ogent-gastown-test-crew-rig-path ()
  "Test crew rig path computation."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/home/user/gt/"))
      (let ((path (ogent-gastown--crew-rig-path '(:rig "ogent" :name "stallman"))))
        (should (equal "/home/user/gt/ogent" path))))))

(ert-deftest ogent-gastown-test-crew-rig-path-nil-rig ()
  "Test crew rig path returns nil for missing rig."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/home/user/gt/"))
      (should-not (ogent-gastown--crew-rig-path '(:name "stallman"))))))

;;; --- Status Help Tests ---

(ert-deftest ogent-gastown-test-status-help ()
  "Test status help command does not error."
  ;; Just verify it does not error
  (ogent-gastown-status-help))

;;; --- BD Ready ID At Point Edge Cases ---

(ert-deftest ogent-gastown-test-bd-ready-id-at-point-no-match ()
  "Test bd ready id at point returns nil for non-matching line."
  (with-temp-buffer
    (insert "Some random text without proper format\n")
    (goto-char (point-min))
    (should-not (ogent-gastown-bd-ready--id-at-point))))

(ert-deftest ogent-gastown-test-bd-ready-id-at-point-question-priority ()
  "Test bd ready id at point handles ? priority."
  (with-temp-buffer
    (insert "[P?] unknown-id (no title)\n")
    (goto-char (point-min))
    (should (equal "unknown-id" (ogent-gastown-bd-ready--id-at-point)))))

;;; --- Show Convoy with Progress ---

(ert-deftest ogent-gastown-test-show-convoy-no-progress ()
  "Test show-convoy plain fallback handles convoy without progress."
  (ogent-gastown-test-with-mock
      (list '(:id "c1" :name "Small job" :status "active" :progress nil))
    (cl-letf (((symbol-function 'display-buffer) #'ignore)
              ((symbol-function 'ogent-gastown-convoy-status) nil))
      (fmakunbound 'ogent-gastown-convoy-status)
      (unwind-protect
          (progn
            (ogent-gastown-show-convoy)
            (let ((buf (get-buffer "*Gas Town Convoys*")))
              (unwind-protect
                  (progn
                    (should buf)
                    (with-current-buffer buf
                      (should (string-match-p "Small job" (buffer-string)))
                      ;; No percent sign since no progress
                      (should-not (string-match-p "%" (buffer-string)))))
                (when buf (kill-buffer buf)))))
        (autoload 'ogent-gastown-convoy-status "ogent-gastown-status" nil t)))))

;;; ====================================================================
;;; NEW COVERAGE TESTS - Phase 2 (targeting 80%+ coverage)
;;; ====================================================================

;;; --- Polling Timer Tests ---

(ert-deftest ogent-gastown-test-start-polling-stops-existing ()
  "Test that start-polling stops any existing timer first."
  (let ((ogent-gastown--poll-timer 'old-timer)
        (ogent-gastown-poll-interval 60)
        (cancelled nil))
    (cl-letf (((symbol-function 'cancel-timer)
               (lambda (timer)
                 (when (eq timer 'old-timer)
                   (setq cancelled t))))
              ((symbol-function 'run-at-time)
               (lambda (_time _repeat _fn)
                 'new-timer)))
      (ogent-gastown--start-polling)
      (should cancelled)
      (should (eq 'new-timer ogent-gastown--poll-timer)))))

(ert-deftest ogent-gastown-test-stop-polling-nil-timer ()
  "Test that stop-polling handles nil timer gracefully."
  (let ((ogent-gastown--poll-timer nil))
    ;; Should not error
    (ogent-gastown--stop-polling)
    (should-not ogent-gastown--poll-timer)))

;;; --- Mode-line String Tests ---

(ert-deftest ogent-gastown-test-update-mode-line-has-help-echo ()
  "Test mode line includes help-echo property."
  (let ((ogent-gastown--hook-cache '(:id "xyz" :title "Help text here")))
    (ogent-gastown--update-mode-line)
    (should (stringp ogent-gastown--mode-line-string))
    (should (get-text-property 0 'help-echo ogent-gastown--mode-line-string))
    (should (equal "Help text here"
                   (get-text-property 0 'help-echo ogent-gastown--mode-line-string)))))

(ert-deftest ogent-gastown-test-update-mode-line-has-face ()
  "Test mode line string has ogent-gastown-hook-active face."
  (let ((ogent-gastown--hook-cache '(:id "test-id" :title "Work")))
    (ogent-gastown--update-mode-line)
    (should (eq 'ogent-gastown-hook-active
                (get-text-property 0 'face ogent-gastown--mode-line-string)))))

;;; --- Header Line Edge Cases ---

(ert-deftest ogent-gastown-test-header-line-no-title ()
  "Test header line handles hook with nil title."
  (let ((ogent-gastown--hook-cache '(:id "no-title-hook"))
        (ogent-gastown--mail-cache nil))
    (let ((header (ogent-gastown--format-header-line)))
      (should (string-match-p "no-title-hook" header))
      (should (string-match-p "Gas Town" header)))))

(ert-deftest ogent-gastown-test-header-line-zero-unread ()
  "Test header line does not show mail count when zero unread."
  (let ((ogent-gastown--hook-cache '(:id "x" :title "Work"))
        (ogent-gastown--mail-cache (list '(:id "m1" :read t))))
    (let ((header (ogent-gastown--format-header-line)))
      ;; Should not contain mail indicator
      (should-not (string-match-p
                   (regexp-quote (ogent-ops-section-prefix "📬" "M:"))
                   header)))))

;;; --- Cleanup Process Handling ---

(ert-deftest ogent-gastown-test-cleanup-kills-gt-processes ()
  "Test cleanup kills live gt processes."
  (let* ((buf (generate-new-buffer " *test-gt-proc*"))
         (proc (start-process "test-gt" buf "sleep" "10"))
         (ogent-gastown--processes (list proc))
         (ogent-gastown--bd-processes nil)
         (ogent-gastown--hook-cache '(:id "x"))
         (ogent-gastown--mail-cache nil)
         (ogent-gastown--convoy-cache nil)
         (ogent-gastown--bd-ready-cache nil)
         (ogent-gastown--town-root "/test/")
         (ogent-gastown--poll-timer nil))
    (unwind-protect
        (progn
          (should (process-live-p proc))
          (ogent-gastown-cleanup)
          (sleep-for 0.1)
          (should-not (process-live-p proc))
          (should-not ogent-gastown--processes))
      (when (process-live-p proc)
        (kill-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-gastown-test-cleanup-kills-bd-processes ()
  "Test cleanup kills live bd processes."
  (let* ((buf (generate-new-buffer " *test-bd-proc*"))
         (proc (start-process "test-bd" buf "sleep" "10"))
         (ogent-gastown--processes nil)
         (ogent-gastown--bd-processes (list proc))
         (ogent-gastown--hook-cache nil)
         (ogent-gastown--mail-cache nil)
         (ogent-gastown--convoy-cache nil)
         (ogent-gastown--bd-ready-cache nil)
         (ogent-gastown--town-root "/test/")
         (ogent-gastown--poll-timer nil))
    (unwind-protect
        (progn
          (should (process-live-p proc))
          (ogent-gastown-cleanup)
          (sleep-for 0.1)
          (should-not (process-live-p proc))
          (should-not ogent-gastown--bd-processes))
      (when (process-live-p proc)
        (kill-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; --- Mode Enable with Mode-line Tests ---

(ert-deftest ogent-gastown-test-mode-adds-to-mode-line-info ()
  "Test that enabling mode adds hook status to mode-line-misc-info."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/mock/gt/")
          (ogent-gastown-show-hook-in-modeline t)
          (ogent-gastown--hook-cache '(:id "test" :title "Work"))
          (mode-line-misc-info nil))
      (cl-letf (((symbol-function 'ogent-gastown-in-town-p)
                 (lambda () nil))
                ((symbol-function 'ogent-gastown--start-polling)
                 (lambda () nil))
                ((symbol-function 'ogent-gastown--stop-polling)
                 (lambda () nil)))
        (ogent-gastown-mode 1)
        ;; mode-line-misc-info should contain the eval form
        (should (member '(:eval ogent-gastown--mode-line-string)
                        mode-line-misc-info))
        (ogent-gastown-mode -1)
        ;; Should be removed
        (should-not (member '(:eval ogent-gastown--mode-line-string)
                            mode-line-misc-info))))))

(ert-deftest ogent-gastown-test-mode-no-mode-line-when-disabled ()
  "Test that mode does not add to mode-line when show-hook-in-modeline is nil."
  (with-temp-buffer
    (let ((ogent-gastown--town-root "/mock/gt/")
          (ogent-gastown-show-hook-in-modeline nil)
          (mode-line-misc-info nil))
      (cl-letf (((symbol-function 'ogent-gastown-in-town-p)
                 (lambda () nil))
                ((symbol-function 'ogent-gastown--start-polling)
                 (lambda () nil))
                ((symbol-function 'ogent-gastown--stop-polling)
                 (lambda () nil)))
        (ogent-gastown-mode 1)
        (should-not (member '(:eval ogent-gastown--mode-line-string)
                            mode-line-misc-info))
        (ogent-gastown-mode -1)))))

;;; --- Mail Mode Tests ---

(ert-deftest ogent-gastown-test-mail-mode-derived-from-special ()
  "Test that GT-Mail mode is derived from special-mode."
  (with-temp-buffer
    (ogent-gastown-mail-mode)
    (should (derived-mode-p 'special-mode))
    (should (eq major-mode 'ogent-gastown-mail-mode))))

(ert-deftest ogent-gastown-test-mail-mode-has-revert-function ()
  "Test that GT-Mail mode sets revert-buffer-function."
  (with-temp-buffer
    (ogent-gastown-mail-mode)
    (should revert-buffer-function)))

;;; --- BD Ready Mode Tests ---

(ert-deftest ogent-gastown-test-bd-ready-mode-derived-from-special ()
  "Test that BD-Ready mode is derived from special-mode."
  (with-temp-buffer
    (ogent-gastown-bd-ready-mode)
    (should (derived-mode-p 'special-mode))
    (should (eq major-mode 'ogent-gastown-bd-ready-mode))))

(ert-deftest ogent-gastown-test-bd-issue-mode-derived-from-special ()
  "Test that BD-Issue mode is derived from special-mode."
  (with-temp-buffer
    (ogent-gastown-bd-issue-mode)
    (should (derived-mode-p 'special-mode))
    (should (eq major-mode 'ogent-gastown-bd-issue-mode))))

;;; --- Run Async Not Available Tests ---

(ert-deftest ogent-gastown-test-gt-not-available-returns-nil ()
  "Test that available-p returns nil when gt is not in PATH."
  (let ((ogent-gastown-gt-executable "gt-nonexistent-test"))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_) nil)))
      (should-not (ogent-gastown-available-p)))))

(ert-deftest ogent-gastown-test-bd-not-available-returns-nil ()
  "Test that bd-available-p returns nil when bd is not in PATH."
  (let ((ogent-gastown-bd-executable "bd-nonexistent-test"))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_) nil)))
      (should-not (ogent-gastown-bd-available-p)))))

;;; --- Navigation Functions ---

(ert-deftest ogent-gastown-test-toggle-section-plain ()
  "Test toggle-section does not error without magit."
  (with-temp-buffer
    (insert "Section Header\nContent\n")
    (goto-char (point-min))
    (let ((ogent-gastown--magit-section-available nil))
      ;; Should not error
      (ogent-gastown-toggle-section))))

(ert-deftest ogent-gastown-test-next-section-plain ()
  "Test next-section falls back to search without magit."
  (with-temp-buffer
    (insert "--- Section 1 ---\n")
    (insert "content\n")
    (insert "--- Section 2 ---\n")
    (goto-char (point-min))
    (let ((ogent-gastown--magit-section-available nil))
      ;; Should not error, just move
      (ogent-gastown-next-section))))

(ert-deftest ogent-gastown-test-prev-section-plain ()
  "Test prev-section falls back without magit."
  (with-temp-buffer
    (insert "--- Section 1 ---\n")
    (insert "content\n")
    (insert "--- Section 2 ---\n")
    (goto-char (point-max))
    (let ((ogent-gastown--magit-section-available nil))
      (ogent-gastown-prev-section))))

;;; --- Show Issue with Created At ---

(ert-deftest ogent-gastown-test-show-issue-without-created-at ()
  "Test show-issue handles missing created_at field."
  (let ((issue-no-date '(:id "no-date" :title "Timeless" :status "open"
                          :priority 2 :issue_type "task")))
    (ogent-gastown-test-bd-with-mock issue-no-date
      (cl-letf (((symbol-function 'display-buffer) #'ignore))
        (ogent-gastown-show-issue "no-date")
        (let ((buf (get-buffer "*Beads: no-date*")))
          (unwind-protect
              (progn
                (should buf)
                (with-current-buffer buf
                  (should (string-match-p "Timeless" (buffer-string)))
                  (should-not (string-match-p "Created:" (buffer-string)))))
            (when buf (kill-buffer buf))))))))

(ert-deftest ogent-gastown-test-show-issue-without-description ()
  "Test show-issue handles missing description field."
  (let ((issue-no-desc '(:id "no-desc" :title "Simple" :status "open"
                          :priority 1 :issue_type "bug")))
    (ogent-gastown-test-bd-with-mock issue-no-desc
      (cl-letf (((symbol-function 'display-buffer) #'ignore))
        (ogent-gastown-show-issue "no-desc")
        (let ((buf (get-buffer "*Beads: no-desc*")))
          (unwind-protect
              (progn
                (should buf)
                (with-current-buffer buf
                  (should-not (string-match-p "Description:" (buffer-string)))))
            (when buf (kill-buffer buf))))))))

;;; --- Convoy Active Tests ---

(ert-deftest ogent-gastown-test-convoy-active-empty ()
  "Test convoy-active returns nil when no cache."
  (let ((ogent-gastown--convoy-cache nil))
    (should-not (ogent-gastown-convoy-active))))

(ert-deftest ogent-gastown-test-convoy-active-returns-cache ()
  "Test convoy-active returns the cached convoy list."
  (let ((ogent-gastown--convoy-cache '((:id "c1") (:id "c2"))))
    (should (equal 2 (length (ogent-gastown-convoy-active))))))

;;; --- Hook Status with No Cache ---

(ert-deftest ogent-gastown-test-hook-status-nil ()
  "Test hook-status returns nil when no cache."
  (let ((ogent-gastown--hook-cache nil))
    (should-not (ogent-gastown-hook-status))))

(ert-deftest ogent-gastown-test-hook-id-nil ()
  "Test hook-id returns nil when no cache."
  (let ((ogent-gastown--hook-cache nil))
    (should-not (ogent-gastown-hook-id))))

(ert-deftest ogent-gastown-test-hook-title-nil ()
  "Test hook-title returns nil when no cache."
  (let ((ogent-gastown--hook-cache nil))
    (should-not (ogent-gastown-hook-title))))

;;; Integration Active Predicate Tests

(ert-deftest ogent-gastown-test-integration-active-when-all-conditions-met ()
  "Test integration-active-p returns t when flag is t and in town."
  (let ((ogent-gastown-integration t)
        (ogent-gastown--integration-cache nil))
    (cl-letf (((symbol-function 'ogent-gastown-available-p) (lambda () t))
              ((symbol-function 'ogent-gastown-in-town-p) (lambda () t)))
      (should (ogent-gastown-integration-active-p)))))

(ert-deftest ogent-gastown-test-integration-active-nil-when-flag-disabled ()
  "Test integration-active-p returns nil when flag is nil."
  (let ((ogent-gastown-integration nil)
        (ogent-gastown--integration-cache nil))
    (cl-letf (((symbol-function 'ogent-gastown-available-p) (lambda () t))
              ((symbol-function 'ogent-gastown-in-town-p) (lambda () t)))
      (should-not (ogent-gastown-integration-active-p)))))

(ert-deftest ogent-gastown-test-integration-active-nil-when-gt-not-in-path ()
  "Test integration-active-p returns nil when gt not available."
  (let ((ogent-gastown-integration t)
        (ogent-gastown--integration-cache nil))
    (cl-letf (((symbol-function 'ogent-gastown-available-p) (lambda () nil))
              ((symbol-function 'ogent-gastown-in-town-p) (lambda () t)))
      (should-not (ogent-gastown-integration-active-p)))))

(ert-deftest ogent-gastown-test-integration-active-nil-when-not-in-town ()
  "Test integration-active-p returns nil when not in a town workspace."
  (let ((ogent-gastown-integration t)
        (ogent-gastown--integration-cache nil))
    (cl-letf (((symbol-function 'ogent-gastown-available-p) (lambda () t))
              ((symbol-function 'ogent-gastown-in-town-p) (lambda () nil)))
      (should-not (ogent-gastown-integration-active-p)))))

(ert-deftest ogent-gastown-test-integration-active-uses-cache ()
  "Test integration-active-p returns cached result within TTL."
  (let ((ogent-gastown--integration-cache (cons (float-time) t)))
    (cl-letf (((symbol-function 'ogent-gastown-available-p) (lambda () nil))
              ((symbol-function 'ogent-gastown-in-town-p) (lambda () nil)))
      ;; Should return cached t even though conditions are now nil
      (should (ogent-gastown-integration-active-p)))))

(ert-deftest ogent-gastown-test-integration-invalidate-clears-cache ()
  "Test integration-invalidate clears the cached result."
  (let ((ogent-gastown--integration-cache (cons (float-time) t)))
    (ogent-gastown-integration-invalidate)
    (should-not ogent-gastown--integration-cache)))

;;; Agent Assignment Tests

(ert-deftest ogent-gastown-test-agent-assignments-nil-by-default ()
  "Test agent assignments cache is nil by default."
  (let ((ogent-gastown--agent-assignments-cache nil))
    (should-not (ogent-gastown-agent-assignments))))

(ert-deftest ogent-gastown-test-agent-assignments-stale-when-nil ()
  "Test agent assignments are stale when cache is nil."
  (let ((ogent-gastown--agent-assignments-cache nil)
        (ogent-gastown--agent-assignments-timestamp nil))
    (should (ogent-gastown-agent-assignments-stale-p))))

(ert-deftest ogent-gastown-test-agent-assignments-stale-when-old ()
  "Test agent assignments are stale when timestamp is old."
  (let ((ogent-gastown--agent-assignments-cache (make-hash-table :test #'equal))
        (ogent-gastown--agent-assignments-timestamp (- (float-time) 10.0)))
    (should (ogent-gastown-agent-assignments-stale-p))))

(ert-deftest ogent-gastown-test-agent-assignments-fresh ()
  "Test agent assignments are not stale when recently cached."
  (let ((ogent-gastown--agent-assignments-cache (make-hash-table :test #'equal))
        (ogent-gastown--agent-assignments-timestamp (float-time)))
    (should-not (ogent-gastown-agent-assignments-stale-p))))

(ert-deftest ogent-gastown-test-lookup-agent-assignment ()
  "Test looking up agent assignments by bead ID."
  (let ((ogent-gastown--agent-assignments-cache (make-hash-table :test #'equal)))
    (puthash "og-abc" '(("ritchie" . "crew")) ogent-gastown--agent-assignments-cache)
    (should (equal '(("ritchie" . "crew"))
                   (ogent-gastown-lookup-agent-assignment "og-abc")))
    (should-not (ogent-gastown-lookup-agent-assignment "og-xyz"))))

(ert-deftest ogent-gastown-test-lookup-nil-cache ()
  "Test lookup returns nil when cache is nil."
  (let ((ogent-gastown--agent-assignments-cache nil))
    (should-not (ogent-gastown-lookup-agent-assignment "og-abc"))))

(ert-deftest ogent-gastown-test-format-agent-assignment-single ()
  "Test formatting agent assignment for single agent."
  (let ((ogent-gastown--agent-assignments-cache (make-hash-table :test #'equal)))
    (puthash "og-abc" '(("ritchie" . "crew")) ogent-gastown--agent-assignments-cache)
    (should (string= " → ritchie"
                     (ogent-gastown-format-agent-assignment "og-abc")))))

(ert-deftest ogent-gastown-test-format-agent-assignment-multiple ()
  "Test formatting agent assignment for multiple agents."
  (let ((ogent-gastown--agent-assignments-cache (make-hash-table :test #'equal)))
    (puthash "og-abc" '(("toast" . "polecat") ("ritchie" . "crew"))
             ogent-gastown--agent-assignments-cache)
    (should (string= " → toast +1"
                     (ogent-gastown-format-agent-assignment "og-abc")))))

(ert-deftest ogent-gastown-test-format-agent-assignment-none ()
  "Test formatting returns nil when no agent assigned."
  (let ((ogent-gastown--agent-assignments-cache (make-hash-table :test #'equal)))
    (should-not (ogent-gastown-format-agent-assignment "og-xyz"))))

(provide 'ogent-gastown-tests)

;;; ogent-gastown-tests.el ends here
