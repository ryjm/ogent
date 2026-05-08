;;; ogent-cabinet-palette-tests.el --- Tests for Cabinet palette search -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for ranked Cabinet search, persisted index data, command records, and
;; app ownership discovery.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-cabinet)
(require 'ogent-cabinet-conversations)
(require 'ogent-cabinet-data)
(require 'ogent-cabinet-palette)
(require 'seq)

(defmacro ogent-cabinet-palette-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary Cabinet directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-cabinet-palette-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(ert-deftest ogent-cabinet-palette-ranks-exact-titles-and-paths ()
  "Ranked search prefers exact titles, then paths and text matches."
  (ogent-cabinet-palette-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-page-create
     root
     "Alpha Plan"
     :path "docs/alpha.org"
     :body "Roadmap details.")
    (ogent-cabinet-page-create
     root
     "Roadmap"
     :path "docs/roadmap.org"
     :body "Alpha Plan is referenced here.")
    (let ((records (ogent-cabinet-search-index-build root)))
      (should (file-exists-p (ogent-cabinet-search-index-file root)))
      (should (seq-find (lambda (record)
                          (equal (plist-get record :title) "Cabinet Git Status"))
                        records))
      (should (seq-find (lambda (record)
                          (equal (plist-get record :title) "Create Cabinet Task"))
                        records)))
    (let ((results (ogent-cabinet-ranked-search root "Alpha Plan")))
      (should (equal (plist-get (car results) :title) "Alpha Plan"))
      (should (> (plist-get (car results) :score)
                 (plist-get (cadr results) :score))))
    (let ((path-result (car (ogent-cabinet-ranked-search
                             root
                             "docs/alpha"))))
      (should (equal (plist-get path-result :title) "Alpha Plan")))))

(ert-deftest ogent-cabinet-palette-open-record-dispatches-commands-and-files ()
  "Palette records open through commands, app browsers, and file viewers."
  (ogent-cabinet-palette-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (let ((called nil)
          (opened nil)
          (page (ogent-cabinet-page-create root "Plan" :path "plan.org")))
      (cl-letf (((symbol-function 'ogent-cabinet-home)
                 (lambda (directory)
                   (setq called directory)))
                ((symbol-function 'ogent-cabinet-open-file)
                 (lambda (file)
                   (setq opened file)
                   'file)))
        (ogent-cabinet-palette-open-record
         (list :kind 'command
               :title "Cabinet Home"
               :command #'ogent-cabinet-home
               :path root))
        (should (equal called root))
        (ogent-cabinet-palette-open-record
         (list :kind 'page :title "Plan" :path page))
        (should (equal opened page))))))

(ert-deftest ogent-cabinet-command-palette-completes-live-index ()
  "The command palette opens completion over commands and Cabinet records."
  (ogent-cabinet-palette-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-page-create root "Plan" :path "plan.org")
    (let (prompt candidates opened read-string-called)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _)
                   (setq read-string-called t)
                   ""))
                ((symbol-function 'completing-read)
                 (lambda (read-prompt collection &rest _)
                   (setq prompt read-prompt)
                   (setq candidates (mapcar #'car collection))
                   (seq-find (lambda (candidate)
                               (string-match-p "Plan" candidate))
                             candidates)))
                ((symbol-function 'ogent-cabinet-open-file)
                 (lambda (path)
                   (setq opened path))))
        (ogent-cabinet-command-palette root))
      (should-not read-string-called)
      (should (equal prompt "Cabinet command or record: "))
      (should (seq-some (lambda (candidate)
                          (string-match-p "Cabinet Home" candidate))
                        candidates))
      (should (equal (file-truename opened)
                     (file-truename (expand-file-name "plan.org" root)))))))

(ert-deftest ogent-cabinet-apps-identify-canonical-conversation-owner ()
  "App detection links hidden conversation artifacts back to their owner."
  (ogent-cabinet-palette-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (let* ((relative ".agents/.conversations/run-1/artifacts/app")
           (app-dir (expand-file-name relative root)))
      (ogent-cabinet-conversation-create
       root
       (list :id "run-1"
             :agent "cto"
             :title "Build app"
             :status "done"
             :artifact-paths (list relative)))
      (make-directory app-dir t)
      (with-temp-file (expand-file-name "index.html" app-dir)
        (insert "<!doctype html><title>App</title>"))
      (let ((app (seq-find (lambda (candidate)
                             (equal (plist-get candidate :label) relative))
                           (ogent-cabinet-list-apps root))))
        (should app)
        (should (equal (plist-get app :conversation-id) "run-1"))
        (should (equal (plist-get app :agent) "cto"))))))

(provide 'ogent-cabinet-palette-tests)

;;; ogent-cabinet-palette-tests.el ends here
