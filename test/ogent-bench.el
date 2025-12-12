;;; ogent-bench.el --- Benchmarking utilities for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Performance benchmarking macros and tests for ogent.
;; Based on patterns from elisp-handbook.org.
;;
;; Usage:
;;   M-x ogent-run-benchmarks
;;   or: make bench

;;; Code:

(require 'cl-lib)
(require 'benchmark)
(require 'ogent-test-helper)
(require 'ogent-context)
(require 'ogent-codemap)

;;; Benchmarking Macros

(cl-defmacro ogent-bench (&optional (times 100000) &rest body)
  "Benchmark BODY for TIMES iterations.
Returns a list: (total-time gc-count gc-time).
Runs garbage collection before timing for consistent results."
  (declare (indent defun))
  `(progn
     (garbage-collect)
     (benchmark-run-compiled ,times
       (progn ,@body))))

(cl-defmacro ogent-bench-multi (&key (times 1) forms ensure-equal)
  "Compare multiple FORMS for TIMES iterations.
Returns an alist of (form-name . results).
When ENSURE-EQUAL is non-nil, verify all forms produce equal results."
  (declare (indent 0))
  (let ((results-sym (gensym "results"))
        (form-results (mapcar (lambda (form)
                                (let ((name (if (listp form) (car form) form)))
                                  `(cons ',name
                                         (ogent-bench ,times ,form))))
                              forms)))
    `(let ((,results-sym (list ,@form-results)))
       ,@(when ensure-equal
           `((let ((first-result (funcall (cdar ,results-sym))))
               (dolist (entry (cdr ,results-sym))
                 (unless (equal first-result (funcall (cdr entry)))
                   (error "Results not equal: %s vs %s"
                          (caar ,results-sym) (car entry)))))))
       ,results-sym)))

(defun ogent-bench-format-results (results)
  "Format benchmark RESULTS as an Org table string."
  (let ((lines '("| Form | Time (s) | GC count | GC time |"
                 "|---+---+---+---|")))
    (dolist (entry results)
      (let* ((name (car entry))
             (data (cdr entry))
             (time (nth 0 data))
             (gc-count (nth 1 data))
             (gc-time (nth 2 data)))
        (push (format "| %s | %.6f | %d | %.6f |"
                      name time gc-count gc-time)
              lines)))
    (string-join (nreverse lines) "\n")))

;;; Benchmark Tests

(defvar ogent-bench-fixture-file
  (expand-file-name "data/fixture.org" ogent-test-root)
  "Path to fixture file for benchmarks.")

(defun ogent-bench--with-fixture (fn)
  "Run FN with the benchmark fixture loaded."
  (with-temp-buffer
    (insert-file-contents ogent-bench-fixture-file)
    (org-mode)
    (goto-char (point-min))
    (search-forward "Root Overview")
    (org-back-to-heading t)
    (funcall fn)))

(defun ogent-bench-context-build ()
  "Benchmark ogent-context-build."
  (ogent-bench--with-fixture
   (lambda ()
     (ogent-bench 1000
		  (ogent-context-build)))))

(defun ogent-bench-resolve-handle ()
  "Benchmark ogent-resolve-handle."
  (ogent-bench--with-fixture
   (lambda ()
     (ogent-bench 1000
		  (ogent-resolve-handle "details-block")))))

(defun ogent-bench-slug ()
  "Benchmark ogent-context--slug."
  (ogent-bench 10000
	       (ogent-context--slug "My Test Heading With Spaces")))

(defun ogent-bench-codemap-project-root ()
  "Benchmark ogent-codemap--project-root."
  (let ((default-directory ogent-project-root))
    (ogent-bench 1000
		 (ogent-codemap--project-root))))

;;; Runner

(defun ogent-run-benchmarks ()
  "Run all ogent benchmarks and display results."
  (interactive)
  (message "Running ogent benchmarks...")
  (let ((results
         `(("context-build" . ,(ogent-bench-context-build))
           ("resolve-handle" . ,(ogent-bench-resolve-handle))
           ("slug" . ,(ogent-bench-slug))
           ("project-root" . ,(ogent-bench-codemap-project-root)))))
    (with-current-buffer (get-buffer-create "*ogent-benchmarks*")
      (erase-buffer)
      (insert "#+title: Ogent Benchmark Results\n\n")
      (insert (format "Run at: %s\n\n" (current-time-string)))
      (insert (ogent-bench-format-results results))
      (insert "\n\n")
      (insert "Note: Times are in seconds. Lower is better.\n")
      (org-mode)
      (goto-char (point-min))
      (display-buffer (current-buffer)))
    (message "Benchmarks complete. See *ogent-benchmarks* buffer.")))

(provide 'ogent-bench)

;;; ogent-bench.el ends here
