;;; ogent-gastown-tests.el --- Tests for ogent-gastown -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Gas Town CLI integration layer.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-gastown)

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

(provide 'ogent-gastown-tests)

;;; ogent-gastown-tests.el ends here
