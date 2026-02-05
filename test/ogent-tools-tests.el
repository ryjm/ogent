;;; ogent-tools-tests.el --- Tests for ogent tools -*- lexical-binding: t; -*-

;;; Commentary:
;; Unit tests for ogent tool implementations.

;;; Code:

(require 'ert)
(require 'ogent-models)
(require 'ogent-tools)

(ert-deftest ogent-tools-format-bytes ()
  "Human-readable byte formatting matches expected units."
  (should (equal (ogent-tools--format-bytes 512) "512 B"))
  (should (equal (ogent-tools--format-bytes 1024) "1.0 KB"))
  (should (equal (ogent-tools--format-bytes (* 1024 1024)) "1.0 MB")))

(ert-deftest ogent-tools-project-root-prefers-custom ()
  "Project root uses ogent-tools-project-root when set."
  (let ((root (make-temp-file "ogent-root-" t)))
    (unwind-protect
        (let ((ogent-tools-project-root root))
          (should (equal (file-name-as-directory root)
                         (file-name-as-directory (ogent-tools--project-root)))))
      (delete-directory root t))))

(ert-deftest ogent-tools-resolve-path-relative ()
  "Relative paths resolve against default-directory."
  (let ((root (make-temp-file "ogent-root-" t)))
    (unwind-protect
        (let ((default-directory (file-name-as-directory root)))
          (should (equal (expand-file-name "file.txt" root)
                         (ogent-tools--resolve-path "file.txt"))))
      (delete-directory root t))))

(ert-deftest ogent-tools-truncate-output ()
  "Output truncation appends a notice when exceeding max."
  (let* ((output (make-string 20 ?a))
         (truncated (ogent-tools--truncate-output output 10)))
    (should (string-prefix-p (make-string 10 ?a) truncated))
    (should (string-match-p "Output truncated" truncated)))
  (should (equal (ogent-tools--truncate-output "short" 10) "short")))

(ert-deftest ogent-tools-read-file-basic ()
  "Read file returns content with line numbers."
  (let ((test-file (make-temp-file "ogent-test-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "line one\nline two\nline three\n"))
          (let ((result (ogent-tool--read-file test-file)))
            (should (string-match-p "1\t.*line one" result))
            (should (string-match-p "2\t.*line two" result))
            (should (string-match-p "3\t.*line three" result))))
      (delete-file test-file))))

(ert-deftest ogent-tools-read-file-offset-limit ()
  "Read file respects offset and limit."
  (let ((test-file (make-temp-file "ogent-test-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "a\nb\nc\nd\ne\n"))
          (let ((result (ogent-tool--read-file test-file 2 2)))
            (should (string-match-p "2\t.*b" result))
            (should (string-match-p "3\t.*c" result))
            (should-not (string-match-p "1\t.*a" result))
            (should-not (string-match-p "4\t.*d" result))))
      (delete-file test-file))))

(ert-deftest ogent-tools-read-file-not-found ()
  "Read file errors on missing file."
  (should-error (ogent-tool--read-file "/nonexistent/path/file.txt")))

(ert-deftest ogent-tools-read-file-binary-detected ()
  "Binary files are rejected by read-file."
  (let ((test-file (make-temp-file "ogent-binary-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "hello\0world"))
          (let ((err (should-error (ogent-tool--read-file test-file))))
            (should (string-match-p "Binary file detected" (cadr err)))))
      (delete-file test-file))))

(ert-deftest ogent-tools-glob-basic ()
  "Glob finds matching files."
  (let ((temp-dir (make-temp-file "ogent-glob-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "test1.el" temp-dir) (insert ""))
          (with-temp-file (expand-file-name "test2.el" temp-dir) (insert ""))
          (with-temp-file (expand-file-name "test.txt" temp-dir) (insert ""))
          (let ((result (ogent-tool--glob "*.el" temp-dir)))
            (should (string-match-p "test1\\.el" result))
            (should (string-match-p "test2\\.el" result))
            (should-not (string-match-p "test\\.txt" result))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-tools-bash-basic ()
  "Bash executes simple commands."
  (let ((result (ogent-tool--bash "echo hello")))
    (should (string-match-p "hello" result))
    (should (string-match-p "Exit code: 0" result))))

(ert-deftest ogent-tools-bash-exit-code ()
  "Bash captures non-zero exit codes."
  (let ((result (ogent-tool--bash "exit 42")))
    (should (string-match-p "Exit code: 42" result))))

(ert-deftest ogent-tools-write-file-basic ()
  "Write file creates and writes content."
  (let ((test-file (make-temp-file "ogent-write-")))
    (unwind-protect
        (progn
          (ogent-tool--write-file test-file "test content")
          (should (equal "test content"
                         (with-temp-buffer
                           (insert-file-contents test-file)
                           (buffer-string)))))
      (delete-file test-file))))

(ert-deftest ogent-tools-edit-file-basic ()
  "Edit file replaces string."
  (let ((test-file (make-temp-file "ogent-edit-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "hello world"))
          (ogent-tool--edit-file test-file "world" "emacs")
          (should (equal "hello emacs"
                         (with-temp-buffer
                           (insert-file-contents test-file)
                           (buffer-string)))))
      (delete-file test-file))))

(ert-deftest ogent-tools-edit-file-not-found ()
  "Edit file errors when string not found."
  (let ((test-file (make-temp-file "ogent-edit-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "hello world"))
          (should-error (ogent-tool--edit-file test-file "foo" "bar")))
      (delete-file test-file))))

(ert-deftest ogent-tools-registry-install ()
  "Default tools can be installed to registry."
  (let ((ogent-tool-registry nil))
    (ogent-tools-install-defaults)
    (should (> (length ogent-tool-registry) 0))
    (should (seq-find (lambda (spec) (eq (plist-get spec :name) 'read-file))
                      ogent-tool-registry))))

;;; Additional format-bytes tests

(ert-deftest ogent-tools-format-bytes-zero ()
  "Zero bytes formats correctly."
  (should (equal "0 B" (ogent-tools--format-bytes 0))))

(ert-deftest ogent-tools-format-bytes-small ()
  "Small byte counts use B suffix."
  (should (equal "1 B" (ogent-tools--format-bytes 1)))
  (should (equal "100 B" (ogent-tools--format-bytes 100)))
  (should (equal "1023 B" (ogent-tools--format-bytes 1023))))

(ert-deftest ogent-tools-format-bytes-kilobytes ()
  "Kilobyte-range values use KB suffix."
  (should (equal "1.0 KB" (ogent-tools--format-bytes 1024)))
  (should (equal "1.5 KB" (ogent-tools--format-bytes 1536)))
  (should (equal "512.0 KB" (ogent-tools--format-bytes (* 512 1024)))))

(ert-deftest ogent-tools-format-bytes-megabytes ()
  "Megabyte-range values use MB suffix."
  (should (equal "1.0 MB" (ogent-tools--format-bytes (* 1024 1024))))
  (should (equal "2.5 MB" (ogent-tools--format-bytes (* 2.5 1024 1024)))))

;;; Additional project-root tests

(ert-deftest ogent-tools-project-root-fallback-default-directory ()
  "Project root falls back to default-directory when nothing else available."
  (let ((ogent-tools-project-root nil)
        (default-directory "/tmp/"))
    (cl-letf (((symbol-function 'projectile-project-root) nil)
              ((symbol-function 'project-current) (lambda () nil)))
      (should (equal "/tmp/" (ogent-tools--project-root))))))

(ert-deftest ogent-tools-project-root-uses-project-el ()
  "Project root uses project.el when projectile is unavailable."
  (let ((ogent-tools-project-root nil)
        (default-directory "/tmp/"))
    (cl-letf (((symbol-function 'projectile-project-root)
               (lambda () nil))
              ((symbol-function 'project-current)
               (lambda () '(vc Git "/home/user/project/")))
              ((symbol-function 'project-root)
               (lambda (_proj) "/home/user/project/")))
      (should (equal "/home/user/project/" (ogent-tools--project-root))))))

;;; Additional resolve-path tests

(ert-deftest ogent-tools-resolve-path-absolute ()
  "Absolute paths are returned as-is (expanded)."
  (should (equal "/usr/bin/foo" (ogent-tools--resolve-path "/usr/bin/foo"))))

(ert-deftest ogent-tools-resolve-path-tilde ()
  "Tilde paths are expanded to home directory."
  (let ((result (ogent-tools--resolve-path "~/test.txt")))
    (should (file-name-absolute-p result))
    (should (string-match-p "test\\.txt" result))
    (should-not (string-prefix-p "~" result))))

(ert-deftest ogent-tools-resolve-path-relative-with-default-dir ()
  "Relative paths resolve against default-directory via expand-file-name."
  (let ((default-directory "/home/user/project/"))
    (should (equal "/home/user/project/src/file.el"
                   (ogent-tools--resolve-path "src/file.el")))))

;;; Additional truncate-output tests

(ert-deftest ogent-tools-truncate-output-no-truncation ()
  "Output shorter than max is returned unchanged."
  (should (equal "hello" (ogent-tools--truncate-output "hello" 100))))

(ert-deftest ogent-tools-truncate-output-exact ()
  "Output exactly at max is not truncated."
  (let ((s (make-string 10 ?x)))
    (should (equal s (ogent-tools--truncate-output s 10)))))

(ert-deftest ogent-tools-truncate-output-includes-length ()
  "Truncation notice includes total length."
  (let* ((output (make-string 100 ?a))
         (truncated (ogent-tools--truncate-output output 50)))
    (should (string-match-p "100 chars" truncated))))

(ert-deftest ogent-tools-truncate-output-empty ()
  "Empty string is not truncated."
  (should (equal "" (ogent-tools--truncate-output "" 10))))

;;; Additional read-file tests

(ert-deftest ogent-tools-read-file-empty-file ()
  "Read file handles empty file without error."
  (let ((test-file (make-temp-file "ogent-test-empty-")))
    (unwind-protect
        (let ((result (ogent-tool--read-file test-file)))
          ;; Empty file should return something (possibly just line 1 with empty content)
          (should (stringp result)))
      (delete-file test-file))))

(ert-deftest ogent-tools-read-file-long-lines-truncated ()
  "Read file truncates lines longer than 2000 chars."
  (let ((test-file (make-temp-file "ogent-test-long-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert (make-string 3000 ?x)))
          (let ((result (ogent-tool--read-file test-file)))
            ;; Should contain truncation indicator
            (should (string-match-p "\\.\\.\\." result))
            ;; Should not contain the full 3000-char line
            (should (< (length result) 3100))))
      (delete-file test-file))))

(ert-deftest ogent-tools-read-file-offset-past-end ()
  "Read file with offset past file end returns empty."
  (let ((test-file (make-temp-file "ogent-test-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "line 1\nline 2\n"))
          (let ((result (ogent-tool--read-file test-file 100 10)))
            (should (equal "" result))))
      (delete-file test-file))))

;;; Additional glob tests

(ert-deftest ogent-tools-glob-no-matches ()
  "Glob returns informative message for no matches."
  (let ((temp-dir (make-temp-file "ogent-glob-" t)))
    (unwind-protect
        (let ((result (ogent-tool--glob "*.nonexistent" temp-dir)))
          (should (string-match-p "No files found" result)))
      (delete-directory temp-dir t))))

(ert-deftest ogent-tools-glob-sorted-by-mtime ()
  "Glob results are sorted by modification time, newest first."
  (let ((temp-dir (make-temp-file "ogent-glob-sort-" t)))
    (unwind-protect
        (progn
          ;; Create files with different mtimes
          (with-temp-file (expand-file-name "old.el" temp-dir)
            (insert "old"))
          (sleep-for 0.1)
          (with-temp-file (expand-file-name "new.el" temp-dir)
            (insert "new"))
          (let ((result (ogent-tool--glob "*.el" temp-dir)))
            ;; new.el should come before old.el
            (let ((new-pos (string-match "new\\.el" result))
                  (old-pos (string-match "old\\.el" result)))
              (should new-pos)
              (should old-pos)
              (should (< new-pos old-pos)))))
      (delete-directory temp-dir t))))

;;; Streaming lifecycle tests

(ert-deftest ogent-tools-stream-start-initializes-state ()
  "Stream start initializes progress state."
  (let ((ogent-tools--progress-state nil)
        (ogent-tools--spinner-index 5)
        (ogent-tools-show-progress nil)
        (ogent-tools-stream-callback nil))
    (ogent-tools--stream-start 'test-tool)
    (should ogent-tools--progress-state)
    (should (equal 'test-tool (plist-get ogent-tools--progress-state :tool)))
    (should (equal 0 (plist-get ogent-tools--progress-state :bytes)))
    (should (equal 0 (plist-get ogent-tools--progress-state :lines)))
    (should (equal 0 ogent-tools--spinner-index))))

(ert-deftest ogent-tools-stream-start-notifies-callback ()
  "Stream start calls stream callback with start event."
  (let ((ogent-tools--progress-state nil)
        (ogent-tools-show-progress nil)
        (ogent-tools--progress-timer nil)
        (captured nil))
    (let ((ogent-tools-stream-callback
           (lambda (tool type data)
             (setq captured (list :tool tool :type type :data data)))))
      (ogent-tools--stream-start 'grep (list :pattern "test"))
      (should (equal 'grep (plist-get captured :tool)))
      (should (equal 'start (plist-get captured :type))))))

(ert-deftest ogent-tools-stream-output-updates-counters ()
  "Stream output accumulates byte and line counts."
  (let ((ogent-tools--progress-state
         (list :tool 'test :bytes 0 :lines 0 :start-time (current-time)))
        (ogent-tools-stream-callback nil))
    (ogent-tools--stream-output 'test 'stdout "hello\nworld\n")
    (should (equal 12 (plist-get ogent-tools--progress-state :bytes)))
    (should (equal 2 (plist-get ogent-tools--progress-state :lines)))
    ;; Add more output
    (ogent-tools--stream-output 'test 'stdout "more\n")
    (should (equal 17 (plist-get ogent-tools--progress-state :bytes)))
    (should (equal 3 (plist-get ogent-tools--progress-state :lines)))))

(ert-deftest ogent-tools-stream-output-notifies-callback ()
  "Stream output calls stream callback with data."
  (let ((ogent-tools--progress-state
         (list :tool 'test :bytes 0 :lines 0 :start-time (current-time)))
        (captured nil))
    (let ((ogent-tools-stream-callback
           (lambda (tool type data)
             (setq captured (list :tool tool :type type :data data)))))
      (ogent-tools--stream-output 'bash 'stderr "error msg")
      (should (equal 'bash (plist-get captured :tool)))
      (should (equal 'stderr (plist-get captured :type)))
      (should (equal "error msg" (plist-get captured :data))))))

(ert-deftest ogent-tools-stream-done-clears-state ()
  "Stream done clears progress state and timer."
  (let ((ogent-tools--progress-state
         (list :tool 'test :bytes 100 :lines 5 :start-time (current-time)))
        (ogent-tools--progress-timer nil)
        (ogent-tools-show-progress nil)
        (ogent-tools-stream-callback nil))
    (ogent-tools--stream-done 'test 0)
    (should-not ogent-tools--progress-state)
    (should-not ogent-tools--progress-timer)))

(ert-deftest ogent-tools-stream-done-notifies-callback ()
  "Stream done calls callback with exit code and duration."
  (let ((ogent-tools--progress-state
         (list :tool 'bash :bytes 50 :lines 2 :start-time (current-time)))
        (ogent-tools--progress-timer nil)
        (ogent-tools-show-progress nil)
        (captured nil))
    (let ((ogent-tools-stream-callback
           (lambda (tool type data)
             (setq captured (list :tool tool :type type :data data)))))
      (ogent-tools--stream-done 'bash 42)
      (should (equal 'bash (plist-get captured :tool)))
      (should (equal 'done (plist-get captured :type)))
      (should (equal 42 (plist-get (plist-get captured :data) :exit-code))))))

(ert-deftest ogent-tools-stream-error-clears-state ()
  "Stream error clears progress state."
  (let ((ogent-tools--progress-state
         (list :tool 'test :bytes 0 :lines 0 :start-time (current-time)))
        (ogent-tools--progress-timer nil)
        (ogent-tools-stream-callback nil))
    (ogent-tools--stream-error 'test "Something went wrong")
    (should-not ogent-tools--progress-state)))

(ert-deftest ogent-tools-stream-error-notifies-callback ()
  "Stream error calls callback with error message."
  (let ((ogent-tools--progress-state nil)
        (ogent-tools--progress-timer nil)
        (captured nil))
    (let ((ogent-tools-stream-callback
           (lambda (tool type data)
             (setq captured (list :tool tool :type type :data data)))))
      (ogent-tools--stream-error 'grep "command not found")
      (should (equal 'grep (plist-get captured :tool)))
      (should (equal 'error (plist-get captured :type)))
      (should (equal "command not found" (plist-get captured :data))))))

;;; Progress update tests

(ert-deftest ogent-tools-progress-update-with-state ()
  "Progress update formats message correctly."
  (let ((ogent-tools-show-progress t)
        (ogent-tools--spinner-index 0)
        (ogent-tools--progress-state
         (list :tool 'bash :bytes 2048 :lines 10 :start-time (current-time)))
        (last-message nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq last-message (apply #'format fmt args)))))
      (ogent-tools--progress-update)
      (should last-message)
      (should (string-match-p "bash" last-message))
      (should (string-match-p "2\\.0 KB" last-message))
      (should (string-match-p "10 lines" last-message)))))

(ert-deftest ogent-tools-progress-update-no-state ()
  "Progress update does nothing when no state."
  (let ((ogent-tools-show-progress t)
        (ogent-tools--progress-state nil)
        (message-called nil))
    (cl-letf (((symbol-function 'message)
               (lambda (&rest _args)
                 (setq message-called t))))
      (ogent-tools--progress-update)
      (should-not message-called))))

(ert-deftest ogent-tools-progress-update-disabled ()
  "Progress update does nothing when show-progress is nil."
  (let ((ogent-tools-show-progress nil)
        (ogent-tools--progress-state
         (list :tool 'bash :bytes 100 :lines 1 :start-time (current-time)))
        (message-called nil))
    (cl-letf (((symbol-function 'message)
               (lambda (&rest _args)
                 (setq message-called t))))
      (ogent-tools--progress-update)
      (should-not message-called))))

;;; Active count tests

(ert-deftest ogent-tools-active-count-empty ()
  "Active count returns 0 when no processes."
  (let ((ogent-tools--active-processes nil))
    (should (equal 0 (ogent-tools-active-count)))))

(ert-deftest ogent-tools-active-count-with-dead-processes ()
  "Active count does not count dead processes."
  (let* ((buf (generate-new-buffer " *test-proc*"))
         (ogent-tools--active-processes
          (list (cons (start-process "test-dead" buf "true") nil))))
    ;; Wait for process to finish
    (sleep-for 0.2)
    (unwind-protect
        (should (equal 0 (ogent-tools-active-count)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; Cancel all tests

(ert-deftest ogent-tools-cancel-all-empty ()
  "Cancel all with no active processes does not error."
  (let ((ogent-tools--active-processes nil)
        (ogent-tools--progress-timer nil)
        (ogent-tools--progress-state nil))
    (ogent-tools-cancel-all)
    (should-not ogent-tools--active-processes)
    (should-not ogent-tools--progress-timer)
    (should-not ogent-tools--progress-state)))

(ert-deftest ogent-tools-cancel-all-clears-progress ()
  "Cancel all clears progress state and timer."
  (let ((ogent-tools--active-processes nil)
        (ogent-tools--progress-state
         (list :tool 'bash :bytes 0 :lines 0 :start-time (current-time)))
        (ogent-tools--progress-timer nil))
    (ogent-tools-cancel-all)
    (should-not ogent-tools--progress-state)
    (should-not ogent-tools--progress-timer)))

;;; Spinner frames test

(ert-deftest ogent-tools-spinner-frames-valid ()
  "Spinner frames list is non-empty and cyclic index works."
  (should (> (length ogent-tools--spinner-frames) 0))
  (let ((ogent-tools--spinner-index 0))
    (dotimes (_ 20)
      (setq ogent-tools--spinner-index
            (mod (1+ ogent-tools--spinner-index)
                 (length ogent-tools--spinner-frames))))
    ;; After 20 increments, index should still be valid
    (should (< ogent-tools--spinner-index (length ogent-tools--spinner-frames)))))

;;; Write file tests

(ert-deftest ogent-tools-write-file-creates-parent-dirs ()
  "Write file creates parent directories if needed."
  (let* ((temp-dir (make-temp-file "ogent-write-dir-" t))
         (nested-file (expand-file-name "sub/dir/file.txt" temp-dir)))
    (unwind-protect
        (progn
          (ogent-tool--write-file nested-file "nested content")
          (should (file-exists-p nested-file))
          (should (equal "nested content"
                         (with-temp-buffer
                           (insert-file-contents nested-file)
                           (buffer-string)))))
      (delete-directory temp-dir t))))

;;; Edit file tests

(ert-deftest ogent-tools-edit-file-replace-all ()
  "Edit file with replace-all replaces all occurrences."
  (let ((test-file (make-temp-file "ogent-edit-all-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "foo bar foo baz foo"))
          (let ((result (ogent-tool--edit-file test-file "foo" "qux" t)))
            (should (string-match-p "3 occurrence" result))
            (should (equal "qux bar qux baz qux"
                           (with-temp-buffer
                             (insert-file-contents test-file)
                             (buffer-string))))))
      (delete-file test-file))))

;;; Default registry tests

(ert-deftest ogent-tools-registry-has-all-tools ()
  "Default registry includes all expected tools."
  (let ((names (mapcar (lambda (t) (plist-get t :name))
                       ogent-tools-default-registry)))
    (should (memq 'read-file names))
    (should (memq 'glob names))
    (should (memq 'grep names))
    (should (memq 'bash names))
    (should (memq 'write-file names))
    (should (memq 'edit-file names))))

(ert-deftest ogent-tools-registry-no-duplicates-on-reinstall ()
  "Installing defaults twice does not create duplicates."
  (let ((ogent-tool-registry nil))
    (ogent-tools-install-defaults)
    (let ((count-first (length ogent-tool-registry)))
      (ogent-tools-install-defaults)
      (should (equal count-first (length ogent-tool-registry))))))

;;; ================================================================
;;; New coverage tests (streaming, grep, bash, edit, registry, etc.)
;;; ================================================================

;;; Stream-start with timer tests

(ert-deftest ogent-tools-stream-start-creates-timer-when-progress ()
  "Stream start creates a progress timer when show-progress is non-nil."
  (let ((ogent-tools--progress-state nil)
        (ogent-tools--progress-timer nil)
        (ogent-tools-show-progress t)
        (ogent-tools-stream-callback nil))
    (unwind-protect
        (progn
          (ogent-tools--stream-start 'test-tool)
          (should ogent-tools--progress-timer)
          (should (timerp ogent-tools--progress-timer)))
      ;; Cleanup
      (when ogent-tools--progress-timer
        (cancel-timer ogent-tools--progress-timer)
        (setq ogent-tools--progress-timer nil))
      (setq ogent-tools--progress-state nil))))

(ert-deftest ogent-tools-stream-start-cancels-existing-timer ()
  "Stream start cancels any existing progress timer before creating new one."
  (let ((ogent-tools--progress-state nil)
        (ogent-tools--progress-timer nil)
        (ogent-tools-show-progress t)
        (ogent-tools-stream-callback nil))
    (unwind-protect
        (progn
          ;; Create initial timer
          (ogent-tools--stream-start 'first-tool)
          (let ((first-timer ogent-tools--progress-timer))
            (should first-timer)
            ;; Start another
            (ogent-tools--stream-start 'second-tool)
            ;; Old timer should have been cancelled; new timer should exist
            (should ogent-tools--progress-timer)
            (should (eq 'second-tool
                        (plist-get ogent-tools--progress-state :tool)))))
      ;; Cleanup
      (when ogent-tools--progress-timer
        (cancel-timer ogent-tools--progress-timer)
        (setq ogent-tools--progress-timer nil))
      (setq ogent-tools--progress-state nil))))

(ert-deftest ogent-tools-stream-start-no-timer-when-disabled ()
  "Stream start does not create timer when show-progress is nil."
  (let ((ogent-tools--progress-state nil)
        (ogent-tools--progress-timer nil)
        (ogent-tools-show-progress nil)
        (ogent-tools-stream-callback nil))
    (ogent-tools--stream-start 'test-tool)
    (should-not ogent-tools--progress-timer)
    (setq ogent-tools--progress-state nil)))

;;; Stream-done with show-progress message tests

(ert-deftest ogent-tools-stream-done-shows-message-when-progress ()
  "Stream done displays a completion message when show-progress is t."
  (let ((ogent-tools--progress-state
         (list :tool 'bash :bytes 100 :lines 5 :start-time (current-time)))
        (ogent-tools--progress-timer nil)
        (ogent-tools-show-progress t)
        (ogent-tools-stream-callback nil)
        (last-message nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq last-message (apply #'format fmt args)))))
      (ogent-tools--stream-done 'bash 0)
      (should last-message)
      (should (string-match-p "completed" last-message))
      (should (string-match-p "exit 0" last-message)))))

(ert-deftest ogent-tools-stream-done-cancels-timer ()
  "Stream done cancels any running progress timer."
  (let ((ogent-tools--progress-state
         (list :tool 'bash :bytes 0 :lines 0 :start-time (current-time)))
        (ogent-tools-show-progress nil)
        (ogent-tools-stream-callback nil)
        (timer (run-at-time 99 nil #'ignore)))
    (let ((ogent-tools--progress-timer timer))
      (ogent-tools--stream-done 'bash 0)
      (should-not ogent-tools--progress-timer))))

(ert-deftest ogent-tools-stream-done-includes-duration-in-callback ()
  "Stream done callback data includes a non-nil :duration."
  (let ((ogent-tools--progress-state
         (list :tool 'test :bytes 0 :lines 0 :start-time (current-time)))
        (ogent-tools--progress-timer nil)
        (ogent-tools-show-progress nil)
        (captured nil))
    (let ((ogent-tools-stream-callback
           (lambda (_tool _type data)
             (setq captured data))))
      (ogent-tools--stream-done 'test 0)
      (should captured)
      (should (numberp (plist-get captured :duration)))
      (should (>= (plist-get captured :duration) 0)))))

;;; Stream-error with timer tests

(ert-deftest ogent-tools-stream-error-cancels-timer ()
  "Stream error cancels any running progress timer."
  (let ((timer (run-at-time 99 nil #'ignore))
        (ogent-tools--progress-state
         (list :tool 'test :bytes 0 :lines 0 :start-time (current-time)))
        (ogent-tools-stream-callback nil))
    (let ((ogent-tools--progress-timer timer))
      (ogent-tools--stream-error 'test "boom")
      (should-not ogent-tools--progress-timer)
      (should-not ogent-tools--progress-state))))

;;; Grep (sync) tests - using mocked shell processes

(ert-deftest ogent-tools-grep-returns-match-count ()
  "Grep sync returns match count in output."
  (let ((temp-dir (make-temp-file "ogent-grep-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "hello.txt" temp-dir)
            (insert "hello world\ngoodbye world\nhello again\n"))
          (let ((ogent-tools-show-progress nil)
                (ogent-tools-stream-callback nil)
                (ogent-tools--progress-timer nil)
                (ogent-tools--progress-state nil)
                (result (ogent-tool--grep "hello" temp-dir)))
            (should (string-match-p "hello" result))
            (should (string-match-p "matches" result))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-tools-grep-no-match ()
  "Grep sync returns no-matches message for unmatched pattern."
  (let ((temp-dir (make-temp-file "ogent-grep-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "data.txt" temp-dir)
            (insert "some content\n"))
          (let ((ogent-tools-show-progress nil)
                (ogent-tools-stream-callback nil)
                (ogent-tools--progress-timer nil)
                (ogent-tools--progress-state nil)
                (result (ogent-tool--grep "zzznomatch" temp-dir)))
            (should (string-match-p "No matches found" result))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-tools-grep-with-glob-filter ()
  "Grep sync filters by glob when provided."
  (let ((temp-dir (make-temp-file "ogent-grep-glob-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "file.el" temp-dir)
            (insert "target-pattern\n"))
          (with-temp-file (expand-file-name "file.txt" temp-dir)
            (insert "target-pattern\n"))
          (let ((ogent-tools-show-progress nil)
                (ogent-tools-stream-callback nil)
                (ogent-tools--progress-timer nil)
                (ogent-tools--progress-state nil)
                (result (ogent-tool--grep "target-pattern" temp-dir "*.el")))
            ;; Should find at least from .el file
            (should (string-match-p "target-pattern" result))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-tools-grep-streams-start-and-done ()
  "Grep sync calls stream start and done with proper events."
  (let ((temp-dir (make-temp-file "ogent-grep-stream-" t))
        (events nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "test.txt" temp-dir)
            (insert "foo bar\n"))
          (let* ((ogent-tools-show-progress nil)
                 (ogent-tools--progress-timer nil)
                 (ogent-tools--progress-state nil)
                 (ogent-tools-stream-callback
                  (lambda (tool type _data)
                    (push (list tool type) events))))
            (ogent-tool--grep "foo" temp-dir)
            ;; Should have start and done events
            (should (cl-find '(grep start) events :test #'equal))
            (should (cl-find '(grep done) events :test #'equal))))
      (delete-directory temp-dir t))))

;;; Bash stderr and edge case tests

(ert-deftest ogent-tools-bash-captures-stderr ()
  "Bash captures stderr output."
  (let ((ogent-tools-show-progress nil)
        (ogent-tools-stream-callback nil)
        (ogent-tools--progress-timer nil)
        (ogent-tools--progress-state nil)
        (result (ogent-tool--bash "echo errormsg >&2")))
    (should (string-match-p "errormsg" result))
    (should (string-match-p "stderr" result))))

(ert-deftest ogent-tools-bash-empty-command ()
  "Bash with empty-output command returns no stdout marker."
  (let ((ogent-tools-show-progress nil)
        (ogent-tools-stream-callback nil)
        (ogent-tools--progress-timer nil)
        (ogent-tools--progress-state nil)
        (result (ogent-tool--bash "true")))
    (should (string-match-p "no stdout" result))
    (should (string-match-p "Exit code: 0" result))))

(ert-deftest ogent-tools-bash-streams-start-done ()
  "Bash calls stream start and done with proper events."
  (let* ((events nil)
         (ogent-tools-show-progress nil)
         (ogent-tools--progress-timer nil)
         (ogent-tools--progress-state nil)
         (ogent-tools-stream-callback
          (lambda (tool type _data)
            (push (list tool type) events))))
    (ogent-tool--bash "echo test")
    (should (cl-find '(bash start) events :test #'equal))
    (should (cl-find '(bash done) events :test #'equal))))

(ert-deftest ogent-tools-bash-working-directory ()
  "Bash respects working directory."
  (let ((temp-dir (make-temp-file "ogent-bash-wd-" t))
        (ogent-tools-show-progress nil)
        (ogent-tools-stream-callback nil)
        (ogent-tools--progress-timer nil)
        (ogent-tools--progress-state nil))
    (unwind-protect
        (let ((result (ogent-tool--bash "pwd" temp-dir)))
          ;; On macOS /var -> /private/var, so compare basename
          (let ((dir-base (file-name-nondirectory
                           (directory-file-name temp-dir))))
            (should (string-match-p (regexp-quote dir-base) result))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-tools-bash-multiline-output ()
  "Bash captures multi-line output correctly."
  (let ((ogent-tools-show-progress nil)
        (ogent-tools-stream-callback nil)
        (ogent-tools--progress-timer nil)
        (ogent-tools--progress-state nil)
        (result (ogent-tool--bash "printf 'line1\\nline2\\nline3\\n'")))
    (should (string-match-p "line1" result))
    (should (string-match-p "line2" result))
    (should (string-match-p "line3" result))))

;;; Edit file edge case tests

(ert-deftest ogent-tools-edit-file-single-replacement-returns-count ()
  "Edit file single replacement reports exactly 1 occurrence."
  (let ((test-file (make-temp-file "ogent-edit-count-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "alpha beta alpha"))
          ;; Single replacement (default)
          (let ((result (ogent-tool--edit-file test-file "alpha" "gamma")))
            (should (string-match-p "1 occurrence" result))
            ;; Only first occurrence should be replaced
            (should (equal "gamma beta alpha"
                           (with-temp-buffer
                             (insert-file-contents test-file)
                             (buffer-string))))))
      (delete-file test-file))))

(ert-deftest ogent-tools-edit-file-replace-all-counts-correctly ()
  "Edit file replace-all correctly counts multiple occurrences."
  (let ((test-file (make-temp-file "ogent-edit-count-all-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "xx yy xx zz xx"))
          (let ((result (ogent-tool--edit-file test-file "xx" "aa" t)))
            (should (string-match-p "3 occurrence" result))
            (should (equal "aa yy aa zz aa"
                           (with-temp-buffer
                             (insert-file-contents test-file)
                             (buffer-string))))))
      (delete-file test-file))))

(ert-deftest ogent-tools-edit-file-multiline-string ()
  "Edit file handles multiline old and new strings."
  (let ((test-file (make-temp-file "ogent-edit-multi-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "first\nsecond\nthird\n"))
          (ogent-tool--edit-file test-file "second\nthird" "2nd\n3rd")
          (should (equal "first\n2nd\n3rd\n"
                         (with-temp-buffer
                           (insert-file-contents test-file)
                           (buffer-string)))))
      (delete-file test-file))))

(ert-deftest ogent-tools-edit-file-error-message-contains-path ()
  "Edit file error includes the file path."
  (let ((test-file (make-temp-file "ogent-edit-err-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "known content"))
          (let ((err (should-error
                      (ogent-tool--edit-file test-file "nonexistent" "replacement"))))
            (should (string-match-p "not found" (cadr err)))))
      (delete-file test-file))))

;;; Write file tests

(ert-deftest ogent-tools-write-file-return-value ()
  "Write file returns a message with char count and path."
  (let ((test-file (make-temp-file "ogent-write-rv-")))
    (unwind-protect
        (let ((result (ogent-tool--write-file test-file "hello world")))
          (should (string-match-p "11 characters" result))
          (should (string-match-p (regexp-quote test-file) result)))
      (delete-file test-file))))

(ert-deftest ogent-tools-write-file-overwrites-existing ()
  "Write file overwrites existing file content."
  (let ((test-file (make-temp-file "ogent-write-over-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "original content"))
          (ogent-tool--write-file test-file "new content")
          (should (equal "new content"
                         (with-temp-buffer
                           (insert-file-contents test-file)
                           (buffer-string)))))
      (delete-file test-file))))

(ert-deftest ogent-tools-write-file-empty-content ()
  "Write file handles empty string content."
  (let ((test-file (make-temp-file "ogent-write-empty-")))
    (unwind-protect
        (progn
          (ogent-tool--write-file test-file "")
          (should (equal ""
                         (with-temp-buffer
                           (insert-file-contents test-file)
                           (buffer-string)))))
      (delete-file test-file))))

;;; Read file additional edge cases

(ert-deftest ogent-tools-read-file-not-readable ()
  "Read file errors on unreadable file."
  ;; Mock file-readable-p to return nil
  (let ((test-file (make-temp-file "ogent-read-perm-")))
    (unwind-protect
        (cl-letf (((symbol-function 'file-readable-p)
                   (lambda (_path) nil)))
          (let ((err (should-error (ogent-tool--read-file test-file))))
            (should (string-match-p "not readable" (cadr err)))))
      (delete-file test-file))))

(ert-deftest ogent-tools-read-file-line-numbering ()
  "Read file produces correct 6-digit padded line numbers."
  (let ((test-file (make-temp-file "ogent-read-ln-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "alpha\nbeta\ngamma\n"))
          (let ((result (ogent-tool--read-file test-file)))
            ;; Should have "     1\t" format (6 chars + tab)
            (should (string-match-p "^     1\t" result))
            (should (string-match-p "     2\t" result))
            (should (string-match-p "     3\t" result))))
      (delete-file test-file))))

(ert-deftest ogent-tools-read-file-limit-zero ()
  "Read file with limit 0 returns empty string."
  (let ((test-file (make-temp-file "ogent-read-lim0-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "line1\nline2\n"))
          (let ((result (ogent-tool--read-file test-file 1 0)))
            (should (equal "" result))))
      (delete-file test-file))))

;;; Registry structure tests

(ert-deftest ogent-tools-registry-tools-have-required-fields ()
  "Every default tool has :name, :function, :description, :args."
  (dolist (tool ogent-tools-default-registry)
    (should (plist-get tool :name))
    (should (plist-get tool :function))
    (should (plist-get tool :description))
    (should (plist-get tool :args))))

(ert-deftest ogent-tools-registry-tools-have-categories ()
  "Every default tool has a :category field."
  (dolist (tool ogent-tools-default-registry)
    (should (plist-get tool :category))))

(ert-deftest ogent-tools-registry-confirm-on-dangerous-tools ()
  "Bash, write-file, and edit-file require confirmation."
  (let ((confirm-tools '(bash write-file edit-file)))
    (dolist (name confirm-tools)
      (let ((tool (seq-find (lambda (t) (eq (plist-get t :name) name))
                            ogent-tools-default-registry)))
        (should tool)
        (should (plist-get tool :confirm))))))

(ert-deftest ogent-tools-registry-safe-tools-no-confirm ()
  "Read-file, glob, and grep do not require confirmation."
  (let ((safe-tools '(read-file glob grep)))
    (dolist (name safe-tools)
      (let ((tool (seq-find (lambda (t) (eq (plist-get t :name) name))
                            ogent-tools-default-registry)))
        (should tool)
        (should-not (plist-get tool :confirm))))))

(ert-deftest ogent-tools-registry-args-have-names-and-types ()
  "Every arg in every tool has :name and :type fields."
  (dolist (tool ogent-tools-default-registry)
    (dolist (arg (plist-get tool :args))
      (should (plist-get arg :name))
      (should (plist-get arg :type)))))

(ert-deftest ogent-tools-registry-async-tools-have-async-functions ()
  "Grep and bash have :async-function and :async-callback-style."
  (dolist (name '(grep bash))
    (let ((tool (seq-find (lambda (t) (eq (plist-get t :name) name))
                          ogent-tools-default-registry)))
      (should tool)
      (should (plist-get tool :async-function))
      (should (plist-get tool :async-callback-style)))))

;;; Cancel-all with live processes

(ert-deftest ogent-tools-cancel-all-kills-live-processes ()
  "Cancel-all kills live processes and clears the list."
  (let* ((buf (generate-new-buffer " *test-cancel*"))
         (proc (start-process "test-sleep" buf "sleep" "10"))
         (ogent-tools--active-processes (list (cons proc nil)))
         (ogent-tools--progress-state nil)
         (ogent-tools--progress-timer nil))
    (unwind-protect
        (progn
          (should (process-live-p proc))
          (ogent-tools-cancel-all)
          (sleep-for 0.1)
          (should-not (process-live-p proc))
          (should-not ogent-tools--active-processes))
      (when (process-live-p proc)
        (kill-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-tools-cancel-all-cancels-associated-timers ()
  "Cancel-all cancels timers stored in process info."
  (let* ((timer (run-at-time 99 nil #'ignore))
         (ogent-tools--active-processes
          (list (cons (start-process "test-cancel-timer" nil "true")
                      (list :timer timer))))
         (ogent-tools--progress-state nil)
         (ogent-tools--progress-timer nil))
    (sleep-for 0.1)  ;; let 'true' finish
    (ogent-tools-cancel-all)
    (should-not ogent-tools--active-processes)))

;;; Active-count with live processes

(ert-deftest ogent-tools-active-count-counts-live ()
  "Active count only counts live processes."
  (let* ((buf (generate-new-buffer " *test-count*"))
         (live-proc (start-process "test-live" buf "sleep" "10"))
         (ogent-tools--active-processes (list (cons live-proc nil))))
    (unwind-protect
        (progn
          (should (equal 1 (ogent-tools-active-count)))
          (kill-process live-proc)
          (sleep-for 0.1)
          (should (equal 0 (ogent-tools-active-count))))
      (when (process-live-p live-proc)
        (kill-process live-proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; Customization defaults tests

(ert-deftest ogent-tools-default-max-file-lines ()
  "Default max file lines is 2000."
  (should (equal 2000 (default-value 'ogent-tools-max-file-lines))))

(ert-deftest ogent-tools-default-max-output-chars ()
  "Default max output chars is 30000."
  (should (equal 30000 (default-value 'ogent-tools-max-output-chars))))

(ert-deftest ogent-tools-default-shell-timeout ()
  "Default shell timeout is 120 seconds."
  (should (equal 120 (default-value 'ogent-tools-shell-timeout))))

(provide 'ogent-tools-tests)

;;; ogent-tools-tests.el ends here
