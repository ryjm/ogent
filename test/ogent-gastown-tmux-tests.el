;;; ogent-gastown-tmux-tests.el --- Tests for ogent-gastown-tmux -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for tmux session integration.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-gastown-tmux)

;;; Test Fixtures

(defconst ogent-gastown-tmux-test--sample-sessions
  (list '(:name "gt-ogent-slit" :windows 2 :attached t :gastown t)
        '(:name "gt-ogent-witness" :windows 1 :attached nil :gastown t)
        '(:name "other-session" :windows 3 :attached nil :gastown nil))
  "Sample tmux sessions for testing.")

(defconst ogent-gastown-tmux-test--list-sessions-output
  "gt-ogent-slit: 2 windows (created Sat Jan  4 10:00:00 2026) (attached)
gt-ogent-witness: 1 windows (created Sat Jan  4 11:00:00 2026)
other-session: 3 windows (created Sat Jan  4 12:00:00 2026)"
  "Sample tmux list-sessions output.")

;;; Mocking Utilities

(defvar ogent-gastown-tmux-test--mock-output nil
  "Mock output for tmux commands.")

(defvar ogent-gastown-tmux-test--captured-args nil
  "Captured arguments from mock tmux calls.")

(defmacro ogent-gastown-tmux-test-with-mock (output &rest body)
  "Execute BODY with tmux mocked to return OUTPUT."
  (declare (indent 1) (debug t))
  `(let ((ogent-gastown-tmux-test--mock-output ,output)
         (ogent-gastown-tmux-test--captured-args nil)
         (ogent-gastown-tmux--sessions-cache nil)
         (ogent-gastown-tmux--cache-time nil)
         (ogent-gastown-tmux-executable "tmux"))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (cmd)
                  (when (string= cmd "tmux") "/usr/bin/tmux")))
               ((symbol-function 'ogent-gastown-tmux--run-command)
                (lambda (args)
                  (setq ogent-gastown-tmux-test--captured-args args)
                  ogent-gastown-tmux-test--mock-output)))
       ,@body)))

;;; Availability Tests

(ert-deftest ogent-gastown-tmux-test-available-p ()
  "Test tmux availability check."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (cmd)
               (when (string= cmd "tmux") "/usr/bin/tmux"))))
    (should (ogent-gastown-tmux-available-p)))

  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-not (ogent-gastown-tmux-available-p))))

;;; Session Parsing Tests

(ert-deftest ogent-gastown-tmux-test-parse-session-line ()
  "Test parsing tmux list-sessions output lines."
  ;; Attached session
  (let ((result (ogent-gastown-tmux--parse-session-line
                 "gt-ogent-slit: 2 windows (created Sat Jan  4 10:00:00 2026) (attached)")))
    (should (equal "gt-ogent-slit" (plist-get result :name)))
    (should (equal 2 (plist-get result :windows)))
    (should (plist-get result :attached))
    (should (plist-get result :gastown)))

  ;; Detached session
  (let ((result (ogent-gastown-tmux--parse-session-line
                 "other-session: 3 windows (created Sat Jan  4 12:00:00 2026)")))
    (should (equal "other-session" (plist-get result :name)))
    (should (equal 3 (plist-get result :windows)))
    (should-not (plist-get result :attached))
    (should-not (plist-get result :gastown)))

  ;; Invalid line
  (should-not (ogent-gastown-tmux--parse-session-line "invalid line")))

;;; Session Listing Tests

(ert-deftest ogent-gastown-tmux-test-list-sessions ()
  "Test listing tmux sessions."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--list-sessions-output
    (let ((sessions (ogent-gastown-tmux--list-sessions)))
      (should (equal 3 (length sessions)))
      ;; First session
      (let ((first (nth 0 sessions)))
        (should (equal "gt-ogent-slit" (plist-get first :name)))
        (should (plist-get first :gastown))
        (should (plist-get first :attached)))
      ;; Check captured args
      (should (member "list-sessions" ogent-gastown-tmux-test--captured-args)))))

(ert-deftest ogent-gastown-tmux-test-sessions-cache ()
  "Test that sessions are cached."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--list-sessions-output
    (let ((ogent-gastown-tmux--sessions-cache nil)
          (ogent-gastown-tmux--cache-time nil))
      ;; First call populates cache
      (ogent-gastown-tmux--list-sessions)
      (should ogent-gastown-tmux--sessions-cache)
      (should ogent-gastown-tmux--cache-time))))

(ert-deftest ogent-gastown-tmux-test-refresh-sessions ()
  "Test that refresh clears cache."
  (let ((ogent-gastown-tmux--sessions-cache ogent-gastown-tmux-test--sample-sessions)
        (ogent-gastown-tmux--cache-time (current-time)))
    (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--list-sessions-output
      (ogent-gastown-tmux-refresh-sessions)
      ;; Cache should be repopulated
      (should ogent-gastown-tmux--sessions-cache))))

;;; Session Formatting Tests

(ert-deftest ogent-gastown-tmux-test-format-session ()
  "Test session formatting for display."
  (let ((gt-attached '(:name "gt-slit" :windows 2 :attached t :gastown t))
        (other-detached '(:name "other" :windows 1 :attached nil :gastown nil)))
    (let ((formatted (ogent-gastown-tmux--format-session gt-attached)))
      (should (string-match-p "\\[GT\\]" formatted))
      (should (string-match-p "gt-slit" formatted))
      (should (string-match-p "2 windows" formatted))
      (should (string-match-p "\\[attached\\]" formatted)))
    (let ((formatted (ogent-gastown-tmux--format-session other-detached)))
      (should-not (string-match-p "\\[GT\\]" formatted))
      (should (string-match-p "other" formatted))
      (should-not (string-match-p "\\[attached\\]" formatted)))))

;;; Send Keys Tests

(ert-deftest ogent-gastown-tmux-test-send-keys ()
  "Test sending keys to a session."
  (ogent-gastown-tmux-test-with-mock "success"
    (ogent-gastown-tmux--send-keys "gt-slit" "ls -la")
    (should (member "send-keys" ogent-gastown-tmux-test--captured-args))
    (should (member "-t" ogent-gastown-tmux-test--captured-args))
    (should (member "gt-slit" ogent-gastown-tmux-test--captured-args))
    (should (member "ls -la" ogent-gastown-tmux-test--captured-args))
    (should (member "Enter" ogent-gastown-tmux-test--captured-args))))

;;; Capture Pane Tests

(ert-deftest ogent-gastown-tmux-test-capture-pane ()
  "Test capturing pane content."
  (let ((sample-output "$ gt hook\nHook: ogent-xyz\n$ "))
    (ogent-gastown-tmux-test-with-mock sample-output
      (let ((result (ogent-gastown-tmux--capture-pane "gt-slit" 50)))
        (should (equal sample-output result))
        (should (member "capture-pane" ogent-gastown-tmux-test--captured-args))
        (should (member "-t" ogent-gastown-tmux-test--captured-args))
        (should (member "gt-slit" ogent-gastown-tmux-test--captured-args))
        (should (member "-p" ogent-gastown-tmux-test--captured-args))
        (should (member "-S" ogent-gastown-tmux-test--captured-args))
        (should (member "-50" ogent-gastown-tmux-test--captured-args))))))

;;; Quick Commands Tests

(ert-deftest ogent-gastown-tmux-test-quick-commands-available ()
  "Test that quick commands are defined."
  (should (listp ogent-gastown-tmux-quick-commands))
  (should (> (length ogent-gastown-tmux-quick-commands) 0))
  (dolist (cmd ogent-gastown-tmux-quick-commands)
    (should (stringp (car cmd)))
    (should (stringp (cdr cmd)))))

;;; Configuration Tests

(ert-deftest ogent-gastown-tmux-test-attach-method-options ()
  "Test attach method configuration."
  (should (memq ogent-gastown-tmux-attach-method '(vterm term external))))

(ert-deftest ogent-gastown-tmux-test-session-prefix ()
  "Test session prefix detection."
  (let ((ogent-gastown-tmux-session-prefix "gt-"))
    (let ((gt-session (ogent-gastown-tmux--parse-session-line
                       "gt-slit: 1 windows")))
      (should (plist-get gt-session :gastown)))
    (let ((other-session (ogent-gastown-tmux--parse-session-line
                          "other: 1 windows")))
      (should-not (plist-get other-session :gastown)))))

;;; List Mode Tests

(ert-deftest ogent-gastown-tmux-test-list-session-at-point ()
  "Test extracting session name from list buffer."
  (with-temp-buffer
    (insert "[GT] gt-ogent-slit (2 windows) [attached]\n")
    (insert "other-session (3 windows)\n")
    (goto-char (point-min))
    (should (equal "gt-ogent-slit" (ogent-gastown-tmux-list--session-at-point)))
    (forward-line)
    (should (equal "other-session" (ogent-gastown-tmux-list--session-at-point)))))

;;; Integration Helper Tests

(ert-deftest ogent-gastown-tmux-test-get-sessions-for-status ()
  "Test helper function for status buffer integration."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--list-sessions-output
    (let ((sessions (ogent-gastown-tmux-get-sessions-for-status)))
      (should (listp sessions))
      (should (= 3 (length sessions)))
      (dolist (session sessions)
        (should (plist-get session :name))
        (should (numberp (plist-get session :windows)))))))

(provide 'ogent-gastown-tmux-tests)

;;; ogent-gastown-tmux-tests.el ends here
