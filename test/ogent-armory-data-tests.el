;;; ogent-armory-data-tests.el --- Tests for Armory data pages -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for page file operations, metadata preservation, export, and viewer
;; dispatch.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory)
(require 'ogent-armory-data)
(require 'org)
(require 'seq)

(defmacro ogent-armory-data-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary Armory directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (ogent-test--provision-store-directory 'armory-data)))
     ,@body))

(defun ogent-armory-data-test--slurp (file)
  "Return FILE contents as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(ert-deftest ogent-armory-data-page-operations-preserve-metadata-and-links ()
  "Create, rename, move, delete, and export keep Org metadata usable."
  (ogent-armory-data-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (let* ((alpha (ogent-armory-page-create
                   root
                   "Alpha Page"
                   :path "notes/alpha.org"
                   :tags '("research")
                   :body "Alpha body."))
           (linker (ogent-armory-page-create
                    root
                    "Linker"
                    :path "linker.org"
                    :body "See [[file:notes/alpha.org][Alpha]]."))
           (renamed (ogent-armory-page-rename root alpha "Beta Page")))
      (should (string-suffix-p "beta-page.org" renamed))
      (should-not (file-exists-p alpha))
      (let ((page (ogent-armory-page-read renamed)))
        (should (equal (plist-get page :title) "Beta Page"))
        (should (member "research" (plist-get page :tags))))
      (should (string-match-p "notes/beta-page.org"
                              (ogent-armory-data-test--slurp linker)))
      (let* ((moved (ogent-armory-page-move root renamed "archive"))
             (page (ogent-armory-page-read moved))
             (exported (ogent-armory-page-export moved 'html))
             (trashed (ogent-armory-page-delete root moved)))
        (should (string-match-p "archive" (plist-get page :dir)))
        (should (file-exists-p exported))
        (should (string-match-p ".armory-state/trash" trashed))
        (should (file-exists-p trashed))
        (should-not (file-exists-p moved))))))

(ert-deftest ogent-armory-data-records-classify-files ()
  "Data records classify pages and common viewer file types."
  (ogent-armory-data-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-page-create root "Notes" :path "notes.org")
    (with-temp-file (expand-file-name "table.csv" root)
      (insert "a,b\n1,2\n"))
    (with-temp-file (expand-file-name "site.html" root)
      (insert "<!doctype html><title>Site</title>"))
    (let ((records (ogent-armory-data-records root)))
      (should (seq-find (lambda (record)
                          (and (equal (plist-get record :relative) "notes.org")
                               (eq (plist-get record :kind) 'page)))
                        records))
      (should (seq-find (lambda (record)
                          (and (equal (plist-get record :relative) "table.csv")
                               (eq (plist-get record :kind) 'csv)))
                        records))
      (should (seq-find (lambda (record)
                          (and (equal (plist-get record :relative) "site.html")
                               (eq (plist-get record :kind) 'html)))
                        records)))))

(ert-deftest ogent-armory-data-open-file-dispatches-by-kind ()
  "Viewer dispatch uses browser, Dired, or file buffers by file kind."
  (ogent-armory-data-test-with-temp-dir root
    (let ((html (expand-file-name "index.html" root))
          (csv (expand-file-name "table.csv" root))
          (opened nil))
      (with-temp-file html
        (insert "<!doctype html>"))
      (with-temp-file csv
        (insert "a,b\n"))
      (cl-letf (((symbol-function 'browse-url-of-file)
                 (lambda (path)
                   (setq opened (list :browser path))))
                ((symbol-function 'find-file)
                 (lambda (path)
                   (setq opened (list :file path))))
                ((symbol-function 'dired)
                 (lambda (path)
                   (setq opened (list :directory path)))))
        (should (eq (ogent-armory-open-file html) 'html))
        (should (equal opened (list :browser html)))
        (should (eq (ogent-armory-open-file csv) 'file))
        (should (equal opened (list :file csv)))
        (should (eq (ogent-armory-open-file root) 'directory))
        (should (equal opened (list :directory root)))))))

(provide 'ogent-armory-data-tests)

;;; ogent-armory-data-tests.el ends here
