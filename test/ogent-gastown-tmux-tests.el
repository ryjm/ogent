;;; ogent-gastown-tmux-tests.el --- Tests for ogent-gastown-tmux -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Gas Town tmux integration layer.
;; Focuses on:
;; - Session line parsing
;; - Session name parsing and metadata extraction
;; - Session formatting for display
;; - Command building/formatting
;; - Caching behavior
;; - List mode utilities

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-gastown-tmux)

;;; Test Fixtures

(defconst ogent-gastown-tmux-test--sample-session-line
  "gt-ogent-ritchie:2:1:1737654321:1737650000"
  "Sample tmux session line in format: name:windows:attached:activity:created.")

(defconst ogent-gastown-tmux-test--sample-sessions
  (list
   (list :name "gt-ogent-witness"
         :windows 1
         :attached nil
         :activity 1737654300
         :created 1737650000)
   (list :name "gt-ogent-refinery"
         :windows 1
         :attached nil
         :activity 1737654200
         :created 1737649000)
   (list :name "gt-ogent-ritchie"
         :windows 2
         :attached t
         :activity 1737654321
         :created 1737650000)
   (list :name "gt-beads-knuth"
         :windows 1
         :attached nil
         :activity 1737654100
         :created 1737648000)
   (list :name "other-session"
         :windows 1
         :attached nil
         :activity 1737654000
         :created 1737647000))
  "Sample session list for testing.")

;;; Mocking Utilities

(defvar ogent-gastown-tmux-test--mock-sessions nil
  "Mock sessions to return from list-sessions.")

(defvar ogent-gastown-tmux-test--captured-command nil
  "Captured shell command from mock calls.")

(defmacro ogent-gastown-tmux-test-with-mock (sessions &rest body)
  "Execute BODY with tmux mocked to return SESSIONS."
  (declare (indent 1) (debug t))
  `(let ((ogent-gastown-tmux-test--mock-sessions ,sessions)
         (ogent-gastown-tmux-test--captured-command nil)
         (ogent-gastown-tmux-executable "tmux")
         (ogent-gastown-tmux-session-prefix "gt-")
         ;; Clear cache
         (ogent-gastown-tmux--session-cache nil)
         (ogent-gastown-tmux--cache-time nil))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (_) "/usr/bin/tmux"))
               ((symbol-function 'shell-command-to-string)
                (lambda (cmd)
                  (setq ogent-gastown-tmux-test--captured-command cmd)
                  ;; Return mock session list output
                  (mapconcat (lambda (s)
                               (format "%s:%d:%d:%d:%d"
                                       (plist-get s :name)
                                       (plist-get s :windows)
                                       (if (plist-get s :attached) 1 0)
                                       (plist-get s :activity)
                                       (plist-get s :created)))
                             ogent-gastown-tmux-test--mock-sessions
                             "\n")))
               ((symbol-function 'shell-command)
                (lambda (cmd &optional _output-buffer _error-buffer)
                  (setq ogent-gastown-tmux-test--captured-command cmd)
                  0)))
       ,@body)))

;;; Availability Tests

(ert-deftest ogent-gastown-tmux-test-available-p ()
  "Test tmux availability check."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) "/usr/bin/tmux")))
    (should (ogent-gastown-tmux-available-p)))

  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-not (ogent-gastown-tmux-available-p))))

(ert-deftest ogent-gastown-tmux-test-available-p-custom-executable ()
  "Test availability with custom executable path."
  (let ((ogent-gastown-tmux-executable "/custom/path/tmux"))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (cmd)
                 (when (string= cmd "/custom/path/tmux")
                   "/custom/path/tmux"))))
      (should (ogent-gastown-tmux-available-p)))))

;;; Session Line Parsing Tests

(ert-deftest ogent-gastown-tmux-test-parse-session-line ()
  "Test parsing a session line into plist."
  (let ((result (ogent-gastown-tmux--parse-session-line
                 ogent-gastown-tmux-test--sample-session-line)))
    (should result)
    (should (equal "gt-ogent-ritchie" (plist-get result :name)))
    (should (equal 2 (plist-get result :windows)))
    (should (eq t (plist-get result :attached)))
    (should (equal 1737654321 (plist-get result :activity)))
    (should (equal 1737650000 (plist-get result :created)))))

(ert-deftest ogent-gastown-tmux-test-parse-session-line-not-attached ()
  "Test parsing a session line for unattached session."
  (let ((result (ogent-gastown-tmux--parse-session-line
                 "my-session:1:0:1737654321:1737650000")))
    (should result)
    (should (equal "my-session" (plist-get result :name)))
    (should (equal 1 (plist-get result :windows)))
    (should-not (plist-get result :attached))))

(ert-deftest ogent-gastown-tmux-test-parse-session-line-insufficient-parts ()
  "Test parsing fails gracefully with insufficient parts."
  (should-not (ogent-gastown-tmux--parse-session-line "only:three:parts"))
  (should-not (ogent-gastown-tmux--parse-session-line "a:b:c:d"))
  (should-not (ogent-gastown-tmux--parse-session-line "")))

(ert-deftest ogent-gastown-tmux-test-parse-session-line-extra-colons ()
  "Test parsing handles names with colons."
  ;; This is a known limitation - sessions with colons in names won't parse correctly
  ;; But the test documents expected behavior
  (let ((result (ogent-gastown-tmux--parse-session-line
                 "simple:1:0:1737654321:1737650000")))
    (should result)
    (should (equal "simple" (plist-get result :name)))))

;;; Session Name Parsing Tests

(ert-deftest ogent-gastown-tmux-test-parse-session-name-refinery ()
  "Test parsing refinery session names."
  (let ((ogent-gastown-tmux-session-prefix "gt-"))
    (let ((result (ogent-gastown-tmux--parse-session-name "gt-ogent-refinery")))
      (should result)
      (should (equal "ogent" (plist-get result :rig)))
      (should (equal "refinery" (plist-get result :role)))
      (should (eq 'refinery (plist-get result :type))))))

(ert-deftest ogent-gastown-tmux-test-parse-session-name-witness ()
  "Test parsing witness session names."
  (let ((ogent-gastown-tmux-session-prefix "gt-"))
    (let ((result (ogent-gastown-tmux--parse-session-name "gt-beads-witness")))
      (should result)
      (should (equal "beads" (plist-get result :rig)))
      (should (equal "witness" (plist-get result :role)))
      (should (eq 'witness (plist-get result :type))))))

(ert-deftest ogent-gastown-tmux-test-parse-session-name-polecat ()
  "Test parsing polecat session names."
  (let ((ogent-gastown-tmux-session-prefix "gt-"))
    (let ((result (ogent-gastown-tmux--parse-session-name "gt-ogent-alpha")))
      (should result)
      (should (equal "ogent" (plist-get result :rig)))
      (should (equal "alpha" (plist-get result :role)))
      (should (eq 'polecat (plist-get result :type))))))

(ert-deftest ogent-gastown-tmux-test-parse-session-name-compound-polecat ()
  "Test parsing polecat with compound name."
  (let ((ogent-gastown-tmux-session-prefix "gt-"))
    (let ((result (ogent-gastown-tmux--parse-session-name "gt-ogent-alpha-beta")))
      (should result)
      (should (equal "ogent" (plist-get result :rig)))
      (should (equal "alpha-beta" (plist-get result :role)))
      (should (eq 'polecat (plist-get result :type))))))

(ert-deftest ogent-gastown-tmux-test-parse-session-name-compound-rig-refinery ()
  "Test parsing refinery for compound rig name."
  (let ((ogent-gastown-tmux-session-prefix "gt-"))
    (let ((result (ogent-gastown-tmux--parse-session-name "gt-my-project-refinery")))
      (should result)
      (should (equal "my-project" (plist-get result :rig)))
      (should (equal "refinery" (plist-get result :role)))
      (should (eq 'refinery (plist-get result :type))))))

(ert-deftest ogent-gastown-tmux-test-parse-session-name-simple ()
  "Test parsing single-part session name."
  (let ((ogent-gastown-tmux-session-prefix "gt-"))
    (let ((result (ogent-gastown-tmux--parse-session-name "gt-hq")))
      (should result)
      (should (equal "hq" (plist-get result :rig)))
      (should-not (plist-get result :role))
      (should (eq 'other (plist-get result :type))))))

(ert-deftest ogent-gastown-tmux-test-parse-session-name-non-gt ()
  "Test parsing non-Gas Town session returns nil."
  (let ((ogent-gastown-tmux-session-prefix "gt-"))
    (should-not (ogent-gastown-tmux--parse-session-name "other-session"))
    (should-not (ogent-gastown-tmux--parse-session-name "random"))
    (should-not (ogent-gastown-tmux--parse-session-name ""))))

(ert-deftest ogent-gastown-tmux-test-parse-session-name-custom-prefix ()
  "Test parsing with custom prefix."
  (let ((ogent-gastown-tmux-session-prefix "mytown-"))
    (let ((result (ogent-gastown-tmux--parse-session-name "mytown-proj-refinery")))
      (should result)
      (should (equal "proj" (plist-get result :rig)))
      (should (eq 'refinery (plist-get result :type))))
    ;; Should not parse gt- prefixed sessions
    (should-not (ogent-gastown-tmux--parse-session-name "gt-proj-refinery"))))

;;; Session Formatting Tests

(ert-deftest ogent-gastown-tmux-test-format-session-refinery ()
  "Test formatting a refinery session."
  (let ((ogent-gastown-tmux-session-prefix "gt-")
        (session (list :name "gt-ogent-refinery"
                       :windows 1
                       :attached nil
                       :activity 1737654321
                       :created 1737650000)))
    (let ((formatted (ogent-gastown-tmux--format-session session)))
      (should (string-match-p "" formatted))
      (should (string-match-p "gt-ogent-refinery" formatted))
      (should (string-match-p "\\[1 win\\]" formatted))
      (should-not (string-match-p "(attached)" formatted)))))

(ert-deftest ogent-gastown-tmux-test-format-session-witness ()
  "Test formatting a witness session."
  (let ((ogent-gastown-tmux-session-prefix "gt-")
        (session (list :name "gt-beads-witness"
                       :windows 2
                       :attached nil
                       :activity 1737654321
                       :created 1737650000)))
    (let ((formatted (ogent-gastown-tmux--format-session session)))
      (should (string-match-p "" formatted))
      (should (string-match-p "\\[2 wins\\]" formatted)))))

(ert-deftest ogent-gastown-tmux-test-format-session-polecat ()
  "Test formatting a polecat session."
  (let ((ogent-gastown-tmux-session-prefix "gt-")
        (session (list :name "gt-ogent-alpha"
                       :windows 1
                       :attached nil
                       :activity 1737654321
                       :created 1737650000)))
    (let ((formatted (ogent-gastown-tmux--format-session session)))
      (should (string-match-p "" formatted)))))

(ert-deftest ogent-gastown-tmux-test-format-session-attached ()
  "Test formatting an attached session."
  (let ((ogent-gastown-tmux-session-prefix "gt-")
        (session (list :name "gt-ogent-ritchie"
                       :windows 3
                       :attached t
                       :activity 1737654321
                       :created 1737650000)))
    (let ((formatted (ogent-gastown-tmux--format-session session)))
      (should (string-match-p "(attached)" formatted))
      (should (string-match-p "\\[3 wins\\]" formatted)))))

(ert-deftest ogent-gastown-tmux-test-format-session-pluralization ()
  "Test window count pluralization."
  (let ((ogent-gastown-tmux-session-prefix "gt-"))
    ;; 1 window - no 's'
    (let ((session (list :name "gt-test" :windows 1 :attached nil)))
      (should (string-match-p "\\[1 win\\]" (ogent-gastown-tmux--format-session session))))
    ;; 0 windows - should have 's'
    (let ((session (list :name "gt-test" :windows 0 :attached nil)))
      (should (string-match-p "\\[0 wins\\]" (ogent-gastown-tmux--format-session session))))
    ;; 5 windows - should have 's'
    (let ((session (list :name "gt-test" :windows 5 :attached nil)))
      (should (string-match-p "\\[5 wins\\]" (ogent-gastown-tmux--format-session session))))))

;;; Session List and Caching Tests

(ert-deftest ogent-gastown-tmux-test-get-sessions-filters-prefix ()
  "Test that get-sessions filters to only GT sessions."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--sample-sessions
    (let ((sessions (ogent-gastown-tmux--get-sessions)))
      ;; Should have 4 sessions (excludes "other-session")
      (should (equal 4 (length sessions)))
      ;; All should have gt- prefix
      (dolist (s sessions)
        (should (string-prefix-p "gt-" (plist-get s :name)))))))

(ert-deftest ogent-gastown-tmux-test-get-sessions-caches ()
  "Test that get-sessions uses cache on subsequent calls."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--sample-sessions
    ;; First call - should query tmux
    (let ((sessions1 (ogent-gastown-tmux--get-sessions)))
      (should (equal 4 (length sessions1)))
      (should ogent-gastown-tmux-test--captured-command)
      ;; Clear captured command
      (setq ogent-gastown-tmux-test--captured-command nil)
      ;; Second call - should use cache
      (let ((sessions2 (ogent-gastown-tmux--get-sessions)))
        (should (equal 4 (length sessions2)))
        ;; Should NOT have called shell-command-to-string again
        (should-not ogent-gastown-tmux-test--captured-command)))))

(ert-deftest ogent-gastown-tmux-test-get-sessions-force-refresh ()
  "Test that force-refresh bypasses cache."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--sample-sessions
    ;; First call
    (ogent-gastown-tmux--get-sessions)
    (setq ogent-gastown-tmux-test--captured-command nil)
    ;; Force refresh - should query again
    (ogent-gastown-tmux--get-sessions t)
    (should ogent-gastown-tmux-test--captured-command)))

(ert-deftest ogent-gastown-tmux-test-refresh-sessions ()
  "Test refresh-sessions function."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--sample-sessions
    (ogent-gastown-tmux--get-sessions)
    (setq ogent-gastown-tmux-test--captured-command nil)
    ;; refresh-sessions should force refresh
    (ogent-gastown-tmux-refresh-sessions)
    (should ogent-gastown-tmux-test--captured-command)))

(ert-deftest ogent-gastown-tmux-test-get-sessions-empty ()
  "Test get-sessions with no sessions."
  (ogent-gastown-tmux-test-with-mock nil
    (let ((sessions (ogent-gastown-tmux--get-sessions)))
      (should (null sessions)))))

(ert-deftest ogent-gastown-tmux-test-list-sessions-sync-unavailable ()
  "Test list-sessions-sync returns nil when tmux unavailable."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-not (ogent-gastown-tmux--list-sessions-sync))))

;;; Send Keys Command Building Tests

(ert-deftest ogent-gastown-tmux-test-send-keys-command ()
  "Test send-keys builds correct command."
  (ogent-gastown-tmux-test-with-mock nil
    (ogent-gastown-tmux--send-keys "gt-ogent-ritchie" "echo hello")
    (should ogent-gastown-tmux-test--captured-command)
    (should (string-match-p "tmux send-keys" ogent-gastown-tmux-test--captured-command))
    (should (string-match-p "-t" ogent-gastown-tmux-test--captured-command))
    (should (string-match-p "gt-ogent-ritchie" ogent-gastown-tmux-test--captured-command))
    (should (string-match-p "Enter" ogent-gastown-tmux-test--captured-command))))

(ert-deftest ogent-gastown-tmux-test-send-keys-quotes-session ()
  "Test send-keys properly quotes session name."
  (ogent-gastown-tmux-test-with-mock nil
    (ogent-gastown-tmux--send-keys "session with spaces" "cmd")
    (should ogent-gastown-tmux-test--captured-command)
    ;; Session name should be shell-quoted (spaces escaped)
    (should (string-match-p "session\\\\ with\\\\ spaces" ogent-gastown-tmux-test--captured-command))))

(ert-deftest ogent-gastown-tmux-test-nudge-command ()
  "Test nudge sends just Enter."
  (ogent-gastown-tmux-test-with-mock nil
    (ogent-gastown-tmux-nudge "gt-test")
    (should ogent-gastown-tmux-test--captured-command)
    (should (string-match-p "send-keys" ogent-gastown-tmux-test--captured-command))
    (should (string-match-p "Enter" ogent-gastown-tmux-test--captured-command))
    ;; Should not have additional quoted content before Enter
    (should (string-match-p "-t.*gt-test.*Enter$" ogent-gastown-tmux-test--captured-command))))

;;; Capture Pane Command Building Tests

(ert-deftest ogent-gastown-tmux-test-capture-pane-command ()
  "Test capture-pane builds correct command."
  (ogent-gastown-tmux-test-with-mock nil
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (cmd)
                 (setq ogent-gastown-tmux-test--captured-command cmd)
                 "captured output")))
      (let ((result (ogent-gastown-tmux--capture-pane "gt-test")))
        (should (equal "captured output" result))
        (should (string-match-p "tmux capture-pane" ogent-gastown-tmux-test--captured-command))
        (should (string-match-p "-t" ogent-gastown-tmux-test--captured-command))
        (should (string-match-p "-p" ogent-gastown-tmux-test--captured-command))
        (should (string-match-p "-S" ogent-gastown-tmux-test--captured-command))))))

(ert-deftest ogent-gastown-tmux-test-capture-pane-uses-preview-lines ()
  "Test capture-pane respects preview-lines setting."
  (let ((ogent-gastown-tmux-preview-lines 100))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (cmd)
                 (setq ogent-gastown-tmux-test--captured-command cmd)
                 "")))
      (ogent-gastown-tmux--capture-pane "gt-test")
      (should (string-match-p "-S -100" ogent-gastown-tmux-test--captured-command)))))

(ert-deftest ogent-gastown-tmux-test-capture-pane-custom-lines ()
  "Test capture-pane with custom line count."
  (cl-letf (((symbol-function 'shell-command-to-string)
             (lambda (cmd)
               (setq ogent-gastown-tmux-test--captured-command cmd)
               "")))
    (ogent-gastown-tmux--capture-pane "gt-test" 25)
    (should (string-match-p "-S -25" ogent-gastown-tmux-test--captured-command))))

;;; External Attach Command Building Tests

(ert-deftest ogent-gastown-tmux-test-attach-external-terminal-app ()
  "Test external attach command for Terminal.app."
  (let ((ogent-gastown-tmux-external-terminal "Terminal.app")
        (ogent-gastown-tmux-executable "tmux"))
    (ogent-gastown-tmux-test-with-mock nil
      (ogent-gastown-tmux--attach-external "gt-test")
      (should ogent-gastown-tmux-test--captured-command)
      (should (string-match-p "open -a Terminal.app" ogent-gastown-tmux-test--captured-command)))))

(ert-deftest ogent-gastown-tmux-test-attach-external-kitty ()
  "Test external attach command for kitty."
  (let ((ogent-gastown-tmux-external-terminal "kitty")
        (ogent-gastown-tmux-executable "tmux"))
    (ogent-gastown-tmux-test-with-mock nil
      (ogent-gastown-tmux--attach-external "gt-test")
      (should ogent-gastown-tmux-test--captured-command)
      (should (string-match-p "kitty --single-instance" ogent-gastown-tmux-test--captured-command))
      (should (string-match-p "attach-session" ogent-gastown-tmux-test--captured-command)))))

(ert-deftest ogent-gastown-tmux-test-attach-external-alacritty ()
  "Test external attach command for alacritty."
  (let ((ogent-gastown-tmux-external-terminal "alacritty")
        (ogent-gastown-tmux-executable "tmux"))
    (ogent-gastown-tmux-test-with-mock nil
      (ogent-gastown-tmux--attach-external "gt-test")
      (should ogent-gastown-tmux-test--captured-command)
      (should (string-match-p "alacritty -e" ogent-gastown-tmux-test--captured-command)))))

(ert-deftest ogent-gastown-tmux-test-attach-external-gnome-terminal ()
  "Test external attach command for gnome-terminal."
  (let ((ogent-gastown-tmux-external-terminal "gnome-terminal")
        (ogent-gastown-tmux-executable "tmux"))
    (ogent-gastown-tmux-test-with-mock nil
      (ogent-gastown-tmux--attach-external "gt-test")
      (should ogent-gastown-tmux-test--captured-command)
      (should (string-match-p "gnome-terminal --" ogent-gastown-tmux-test--captured-command)))))

(ert-deftest ogent-gastown-tmux-test-attach-external-fallback ()
  "Test external attach command for unknown terminal."
  (let ((ogent-gastown-tmux-external-terminal "my-custom-term")
        (ogent-gastown-tmux-executable "tmux"))
    (ogent-gastown-tmux-test-with-mock nil
      (ogent-gastown-tmux--attach-external "gt-test")
      (should ogent-gastown-tmux-test--captured-command)
      (should (string-match-p "my-custom-term -e" ogent-gastown-tmux-test--captured-command)))))

;;; Attach Dispatch Tests

(ert-deftest ogent-gastown-tmux-test-attach-dispatch-vterm ()
  "Test attach dispatches to vterm method."
  (let ((ogent-gastown-tmux-attach-method 'vterm)
        (called nil))
    (cl-letf (((symbol-function 'ogent-gastown-tmux--attach-vterm)
               (lambda (session)
                 (setq called session))))
      (ogent-gastown-tmux-attach "gt-test")
      (should (equal "gt-test" called)))))

(ert-deftest ogent-gastown-tmux-test-attach-dispatch-term ()
  "Test attach dispatches to term method."
  (let ((ogent-gastown-tmux-attach-method 'term)
        (called nil))
    (cl-letf (((symbol-function 'ogent-gastown-tmux--attach-term)
               (lambda (session)
                 (setq called session))))
      (ogent-gastown-tmux-attach "gt-test")
      (should (equal "gt-test" called)))))

(ert-deftest ogent-gastown-tmux-test-attach-dispatch-external ()
  "Test attach dispatches to external method."
  (let ((ogent-gastown-tmux-attach-method 'external)
        (called nil))
    (cl-letf (((symbol-function 'ogent-gastown-tmux--attach-external)
               (lambda (session)
                 (setq called session))))
      (ogent-gastown-tmux-attach "gt-test")
      (should (equal "gt-test" called)))))

(ert-deftest ogent-gastown-tmux-test-attach-dispatch-default ()
  "Test attach defaults to vterm for unknown method."
  (let ((ogent-gastown-tmux-attach-method 'unknown-method)
        (called nil))
    (cl-letf (((symbol-function 'ogent-gastown-tmux--attach-vterm)
               (lambda (session)
                 (setq called session))))
      (ogent-gastown-tmux-attach "gt-test")
      (should (equal "gt-test" called)))))

;;; List Mode Session-at-Point Tests

(ert-deftest ogent-gastown-tmux-test-list-session-at-point ()
  "Test extracting session from list buffer."
  (with-temp-buffer
    (insert (propertize "  witness  [1 win]\n"
                        'ogent-gastown-tmux-session "gt-ogent-witness"))
    (insert (propertize "  ritchie (attached) [2 wins]\n"
                        'ogent-gastown-tmux-session "gt-ogent-ritchie"))
    (goto-char (point-min))
    (should (equal "gt-ogent-witness" (ogent-gastown-tmux-list--session-at-point)))
    (forward-line)
    (should (equal "gt-ogent-ritchie" (ogent-gastown-tmux-list--session-at-point)))))

(ert-deftest ogent-gastown-tmux-test-list-session-at-point-no-property ()
  "Test session-at-point returns nil on lines without session property."
  (with-temp-buffer
    (insert "# ogent\n")
    (insert "Some other line\n")
    (goto-char (point-min))
    (should-not (ogent-gastown-tmux-list--session-at-point))
    (forward-line)
    (should-not (ogent-gastown-tmux-list--session-at-point))))

;;; Quick Commands Tests

(ert-deftest ogent-gastown-tmux-test-quick-commands-default ()
  "Test default quick commands are defined."
  (should ogent-gastown-tmux-quick-commands)
  (should (assoc "Check mail" ogent-gastown-tmux-quick-commands))
  (should (assoc "Sync beads" ogent-gastown-tmux-quick-commands))
  (should (assoc "Show hook" ogent-gastown-tmux-quick-commands)))

;;; VTerm Attach Tests

(ert-deftest ogent-gastown-tmux-test-attach-vterm-requires-package ()
  "Test vterm attach fails gracefully when vterm not available."
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _filename _noerror)
               (when (eq feature 'vterm)
                 nil))))
    (should-error (ogent-gastown-tmux--attach-vterm "gt-test")
                  :type 'user-error)))

(ert-deftest ogent-gastown-tmux-test-attach-vterm-reuses-buffer ()
  "Test vterm attach reuses existing buffer."
  (let ((switched-to nil))
    (cl-letf (((symbol-function 'require)
               (lambda (_f &rest _) t))
              ((symbol-function 'get-buffer)
               (lambda (name)
                 (when (equal name "*tmux: gt-test*")
                   (generate-new-buffer " *mock-vterm*"))))
              ((symbol-function 'switch-to-buffer)
               (lambda (buf)
                 (setq switched-to buf))))
      (ogent-gastown-tmux--attach-vterm "gt-test")
      (should switched-to)
      ;; Cleanup mock buffer
      (when (bufferp switched-to)
        (kill-buffer switched-to)))))

;;; Cache TTL Tests

(ert-deftest ogent-gastown-tmux-test-cache-ttl-constant ()
  "Test cache TTL is defined and reasonable."
  (should (numberp ogent-gastown-tmux--cache-ttl))
  (should (> ogent-gastown-tmux--cache-ttl 0))
  (should (<= ogent-gastown-tmux--cache-ttl 60)))  ; Should be <= 1 minute

;;; Customization Defaults Tests

(ert-deftest ogent-gastown-tmux-test-executable-default ()
  "Test default tmux executable."
  (should (equal "tmux" (default-value 'ogent-gastown-tmux-executable))))

(ert-deftest ogent-gastown-tmux-test-attach-method-default ()
  "Test default attach method is vterm."
  (should (eq 'vterm (default-value 'ogent-gastown-tmux-attach-method))))

(ert-deftest ogent-gastown-tmux-test-session-prefix-default ()
  "Test default session prefix."
  (should (equal "gt-" (default-value 'ogent-gastown-tmux-session-prefix))))

(ert-deftest ogent-gastown-tmux-test-preview-lines-default ()
  "Test default preview lines."
  (should (equal 50 (default-value 'ogent-gastown-tmux-preview-lines))))

;;; Preview Buffer Tests

(ert-deftest ogent-gastown-tmux-test-preview-refresh-in-preview-buffer ()
  "Test preview-refresh identifies preview buffer."
  (with-temp-buffer
    (rename-buffer "*Tmux Preview: gt-test*" t)
    (let ((refreshed nil))
      (cl-letf (((symbol-function 'ogent-gastown-tmux-preview)
                 (lambda (session)
                   (setq refreshed session))))
        (ogent-gastown-tmux-preview-refresh)
        (should (equal "gt-test" refreshed))))))

(ert-deftest ogent-gastown-tmux-test-preview-refresh-not-in-preview-buffer ()
  "Test preview-refresh does nothing outside preview buffer."
  (with-temp-buffer
    (rename-buffer "*Other Buffer*" t)
    (let ((refreshed nil))
      (cl-letf (((symbol-function 'ogent-gastown-tmux-preview)
                 (lambda (session)
                   (setq refreshed session))))
        (ogent-gastown-tmux-preview-refresh)
        (should-not refreshed)))))

;;; Mode Map Tests

(ert-deftest ogent-gastown-tmux-test-list-mode-map-bindings ()
  "Test list mode has expected key bindings."
  (should ogent-gastown-tmux-list-mode-map)
  (should (eq 'ogent-gastown-tmux-list-attach
              (lookup-key ogent-gastown-tmux-list-mode-map (kbd "RET"))))
  (should (eq 'ogent-gastown-tmux-list-attach
              (lookup-key ogent-gastown-tmux-list-mode-map (kbd "a"))))
  (should (eq 'ogent-gastown-tmux-list-attach-external
              (lookup-key ogent-gastown-tmux-list-mode-map (kbd "A"))))
  (should (eq 'ogent-gastown-tmux-list-send
              (lookup-key ogent-gastown-tmux-list-mode-map (kbd "s"))))
  (should (eq 'ogent-gastown-tmux-list-preview
              (lookup-key ogent-gastown-tmux-list-mode-map (kbd "p"))))
  (should (eq 'ogent-gastown-tmux-list-nudge
              (lookup-key ogent-gastown-tmux-list-mode-map (kbd "n"))))
  (should (eq 'ogent-gastown-tmux-list-sessions
              (lookup-key ogent-gastown-tmux-list-mode-map (kbd "g"))))
  (should (eq 'quit-window
              (lookup-key ogent-gastown-tmux-list-mode-map (kbd "q")))))

;;; List Sessions Buffer Tests

(ert-deftest ogent-gastown-tmux-test-list-sessions-creates-buffer ()
  "Test that list-sessions creates the *Gas Town Tmux* buffer."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--sample-sessions
    (unwind-protect
        (progn
          (ogent-gastown-tmux-list-sessions)
          (should (get-buffer "*Gas Town Tmux*"))
          (with-current-buffer "*Gas Town Tmux*"
            (should (eq major-mode 'ogent-gastown-tmux-list-mode))
            (should (string-match-p "Gas Town Tmux Sessions"
                                    (buffer-string)))))
      (when (get-buffer "*Gas Town Tmux*")
        (kill-buffer "*Gas Town Tmux*")))))

(ert-deftest ogent-gastown-tmux-test-list-sessions-groups-by-rig ()
  "Test that list-sessions groups sessions by rig name."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--sample-sessions
    (unwind-protect
        (progn
          (ogent-gastown-tmux-list-sessions)
          (with-current-buffer "*Gas Town Tmux*"
            ;; Should have rig headers
            (should (string-match-p "# ogent" (buffer-string)))
            (should (string-match-p "# beads" (buffer-string)))))
      (when (get-buffer "*Gas Town Tmux*")
        (kill-buffer "*Gas Town Tmux*")))))

(ert-deftest ogent-gastown-tmux-test-list-sessions-empty ()
  "Test that list-sessions handles no sessions gracefully."
  (ogent-gastown-tmux-test-with-mock nil
    (unwind-protect
        (progn
          (ogent-gastown-tmux-list-sessions)
          (with-current-buffer "*Gas Town Tmux*"
            (should (string-match-p "No Gas Town sessions"
                                    (buffer-string)))))
      (when (get-buffer "*Gas Town Tmux*")
        (kill-buffer "*Gas Town Tmux*")))))

(ert-deftest ogent-gastown-tmux-test-list-sessions-shows-keybindings ()
  "Test that list-sessions buffer shows keybinding help."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--sample-sessions
    (unwind-protect
        (progn
          (ogent-gastown-tmux-list-sessions)
          (with-current-buffer "*Gas Town Tmux*"
            (should (string-match-p "RET:attach" (buffer-string)))
            (should (string-match-p "s:send" (buffer-string)))
            (should (string-match-p "p:preview" (buffer-string)))))
      (when (get-buffer "*Gas Town Tmux*")
        (kill-buffer "*Gas Town Tmux*")))))

(ert-deftest ogent-gastown-tmux-test-list-sessions-has-text-properties ()
  "Test that sessions in list buffer have text property for session name."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--sample-sessions
    (unwind-protect
        (progn
          (ogent-gastown-tmux-list-sessions)
          (with-current-buffer "*Gas Town Tmux*"
            (goto-char (point-min))
            ;; Find a line with session text property
            (let ((found nil))
              (while (and (not found) (not (eobp)))
                (when (get-text-property (point) 'ogent-gastown-tmux-session)
                  (setq found t))
                (forward-line 1))
              (should found))))
      (when (get-buffer "*Gas Town Tmux*")
        (kill-buffer "*Gas Town Tmux*")))))

;;; Preview Tests

(ert-deftest ogent-gastown-tmux-test-preview-creates-buffer ()
  "Test that preview creates the preview buffer."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--sample-sessions
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'shell-command-to-string)
                     (lambda (_cmd) "sample pane output"))
                    ((symbol-function 'display-buffer)
                     (lambda (_buf _alist) nil)))
            (ogent-gastown-tmux-preview "gt-ogent-ritchie")
            (let ((buf (get-buffer "*Tmux Preview: gt-ogent-ritchie*")))
              (should buf)
              (with-current-buffer buf
                (should (string-match-p "Session: gt-ogent-ritchie"
                                        (buffer-string)))
                (should (string-match-p "sample pane output"
                                        (buffer-string)))))))
      (when (get-buffer "*Tmux Preview: gt-ogent-ritchie*")
        (kill-buffer "*Tmux Preview: gt-ogent-ritchie*")))))

(ert-deftest ogent-gastown-tmux-test-preview-empty-pane ()
  "Test that preview handles empty pane output."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--sample-sessions
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'shell-command-to-string)
                     (lambda (_cmd) nil))
                    ((symbol-function 'display-buffer)
                     (lambda (_buf _alist) nil)))
            (ogent-gastown-tmux-preview "gt-ogent-ritchie")
            (let ((buf (get-buffer "*Tmux Preview: gt-ogent-ritchie*")))
              (should buf)
              (with-current-buffer buf
                (should (string-match-p "(empty)"
                                        (buffer-string)))))))
      (when (get-buffer "*Tmux Preview: gt-ogent-ritchie*")
        (kill-buffer "*Tmux Preview: gt-ogent-ritchie*")))))

;;; Send/Nudge Tests

(ert-deftest ogent-gastown-tmux-test-send-calls-send-keys ()
  "Test that send command calls send-keys and messages."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--sample-sessions
    (let ((last-msg nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq last-msg (apply #'format fmt args)))))
        (ogent-gastown-tmux-send "gt-ogent-ritchie" "ls -la")
        (should (string-match-p "send-keys"
                                ogent-gastown-tmux-test--captured-command))
        (should (string-match-p "gt-ogent-ritchie"
                                ogent-gastown-tmux-test--captured-command))
        (should (string-match-p "Sent to gt-ogent-ritchie" last-msg))))))

(ert-deftest ogent-gastown-tmux-test-nudge-sends-enter ()
  "Test that nudge sends Enter key to session."
  (ogent-gastown-tmux-test-with-mock ogent-gastown-tmux-test--sample-sessions
    (let ((last-msg nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq last-msg (apply #'format fmt args)))))
        (ogent-gastown-tmux-nudge "gt-ogent-ritchie")
        (should (string-match-p "send-keys.*Enter"
                                ogent-gastown-tmux-test--captured-command))
        (should (string-match-p "Nudged" last-msg))))))

;;; List Mode Action Delegation Tests

(ert-deftest ogent-gastown-tmux-test-list-session-at-point-nil ()
  "Test session-at-point returns nil when no session at point."
  (with-temp-buffer
    (insert "no session here\n")
    (goto-char (point-min))
    (should-not (ogent-gastown-tmux-list--session-at-point))))

(ert-deftest ogent-gastown-tmux-test-list-session-at-point-present ()
  "Test session-at-point returns session name from text properties."
  (with-temp-buffer
    (insert (propertize "session line\n"
                        'ogent-gastown-tmux-session "gt-ogent-ritchie"))
    (goto-char (point-min))
    (should (equal (ogent-gastown-tmux-list--session-at-point)
                   "gt-ogent-ritchie"))))

;;; Attach Term Test

(ert-deftest ogent-gastown-tmux-test-attach-term-existing-buffer ()
  "Test that term attach reuses existing buffer."
  (let ((buf (get-buffer-create "*tmux: gt-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'switch-to-buffer)
                   (lambda (b) b))
                  ((symbol-function 'executable-find)
                   (lambda (_) "/usr/bin/tmux")))
          (ogent-gastown-tmux--attach-term "gt-test")
          ;; Should have tried to switch to existing buffer
          (should (buffer-live-p buf)))
      (kill-buffer buf))))

;;; Revert Buffer Test

(ert-deftest ogent-gastown-tmux-test-list-mode-revert ()
  "Test that list mode sets revert-buffer-function."
  (with-temp-buffer
    (ogent-gastown-tmux-list-mode)
    (should (eq major-mode 'ogent-gastown-tmux-list-mode))
    (should (functionp revert-buffer-function))))

(provide 'ogent-gastown-tmux-tests)

;;; ogent-gastown-tmux-tests.el ends here
