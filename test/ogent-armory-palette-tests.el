;;; ogent-armory-palette-tests.el --- Tests for Armory palette search -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for ranked Armory search, persisted index data, command records, and
;; app ownership discovery.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory)
(require 'ogent-armory-conversations)
(require 'ogent-armory-data)
(require 'ogent-armory-palette)
(require 'seq)

(defmacro ogent-armory-palette-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary Armory directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-armory-palette-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(ert-deftest ogent-armory-palette-ranks-exact-titles-and-paths ()
  "Ranked search prefers exact titles, then paths and text matches."
  (ogent-armory-palette-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-page-create
     root
     "Alpha Plan"
     :path "docs/alpha.org"
     :body "Roadmap details.")
    (ogent-armory-page-create
     root
     "Roadmap"
     :path "docs/roadmap.org"
     :body "Alpha Plan is referenced here.")
    (let ((records (ogent-armory-search-index-build root)))
      (should (file-exists-p (ogent-armory-search-index-file root)))
      (should (seq-find (lambda (record)
                          (equal (plist-get record :title) "Armory Git Status"))
                        records)))
    (let ((results (ogent-armory-ranked-search root "Alpha Plan")))
      (should (equal (plist-get (car results) :title) "Alpha Plan"))
      (should (> (plist-get (car results) :score)
                 (plist-get (cadr results) :score))))
    (let ((path-result (car (ogent-armory-ranked-search
                             root
                             "docs/alpha"))))
      (should (equal (plist-get path-result :title) "Alpha Plan")))))

(ert-deftest ogent-armory-palette-open-record-dispatches-commands-and-files ()
  "Palette records open through commands, app browsers, and file viewers."
  (ogent-armory-palette-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (let ((called nil)
          (opened nil)
          (page (ogent-armory-page-create root "Plan" :path "plan.org")))
      (cl-letf (((symbol-function 'ogent-armory-home)
                 (lambda (directory)
                   (setq called directory)))
                ((symbol-function 'ogent-armory-open-file)
                 (lambda (file)
                   (setq opened file)
                   'file)))
        (ogent-armory-palette-open-record
         (list :kind 'command
               :title "Armory Home"
               :command #'ogent-armory-home
               :path root))
        (should (equal called root))
        (ogent-armory-palette-open-record
         (list :kind 'page :title "Plan" :path page))
        (should (equal opened page))))))

(ert-deftest ogent-armory-command-palette-completes-live-index ()
  "The command palette opens completion over commands and Armory records."
  (ogent-armory-palette-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-page-create root "Plan" :path "plan.org")
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
                ((symbol-function 'ogent-armory-open-file)
                 (lambda (path)
                   (setq opened path))))
        (ogent-armory-command-palette root))
      (should-not read-string-called)
      (should (equal prompt "Armory command or record: "))
      (should (seq-some (lambda (candidate)
                          (string-match-p "Armory Home" candidate))
                        candidates))
      (should (equal (file-truename opened)
                     (file-truename (expand-file-name "plan.org" root)))))))

(ert-deftest ogent-armory-apps-identify-canonical-conversation-owner ()
  "App detection links hidden conversation artifacts back to their owner."
  (ogent-armory-palette-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (let* ((relative ".agents/.conversations/run-1/artifacts/app")
           (app-dir (expand-file-name relative root)))
      (ogent-armory-conversation-create
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
                           (ogent-armory-list-apps root))))
        (should app)
        (should (equal (plist-get app :conversation-id) "run-1"))
        (should (equal (plist-get app :agent) "cto"))))))

(provide 'ogent-armory-palette-tests)

;;; ogent-armory-palette-tests.el ends here
