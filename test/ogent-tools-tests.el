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

(provide 'ogent-tools-tests)

;;; ogent-tools-tests.el ends here
