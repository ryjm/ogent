;;; ogent-cabinet-git-tests.el --- Tests for Cabinet git wrappers -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for Cabinet git status, log, diff, restore, commit, and pull wrappers.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-cabinet)
(require 'ogent-cabinet-data)
(require 'ogent-cabinet-git)

(defmacro ogent-cabinet-git-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-cabinet-git-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-cabinet-git-test--git (root &rest args)
  "Run git in ROOT with ARGS."
  (let ((buffer (generate-new-buffer " *ogent-cabinet-git-test*")))
    (unwind-protect
        (let ((exit (apply #'process-file "git" nil buffer nil
                           "-C" root args))
              (output (with-current-buffer buffer
                        (buffer-string))))
          (unless (zerop exit)
            (error "git %s failed: %s" (string-join args " ") output))
          output)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ogent-cabinet-git-test--seed (root)
  "Create a git-backed Cabinet under ROOT."
  (ogent-cabinet-git-test--git root "init")
  (ogent-cabinet-git-test--git root "config" "user.email" "test@example.com")
  (ogent-cabinet-git-test--git root "config" "user.name" "Cabinet Test")
  (ogent-cabinet-git-test--git root "config" "commit.gpgsign" "false")
  (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
  (let ((page (ogent-cabinet-page-create
               root
               "Plan"
               :path "plan.org"
               :body "Initial plan.")))
    (ogent-cabinet-git-test--git root "add" ".")
    (ogent-cabinet-git-test--git root "commit" "-m" "initial cabinet")
    page))

(ert-deftest ogent-cabinet-git-status-diff-log-and-restore-page ()
  "Git wrappers expose dirty status, diff, log, and restore for a page."
  (ogent-cabinet-git-test-with-temp-dir root
    (let ((page (ogent-cabinet-git-test--seed root)))
      (with-temp-buffer
        (insert-file-contents page)
        (goto-char (point-max))
        (insert "\nChanged plan.\n")
        (write-region (point-min) (point-max) page nil 'silent))
      (let ((status (ogent-cabinet-git-status-data root)))
        (should (= 1 (length status)))
        (should (equal (plist-get (car status) :relative) "plan.org"))
        (should (= (ogent-cabinet-git-dirty-count root) 1)))
      (let ((diff-buffer (ogent-cabinet-git-diff-page page)))
        (with-current-buffer diff-buffer
          (should (string-match-p "Changed plan" (buffer-string))))
        (kill-buffer diff-buffer))
      (let ((log-buffer (ogent-cabinet-git-log-page page)))
        (with-current-buffer log-buffer
          (should (string-match-p "initial cabinet" (buffer-string))))
        (kill-buffer log-buffer))
      (ogent-cabinet-git-restore-page page t)
      (should-not (string-match-p
                   "Changed plan"
                   (with-temp-buffer
                     (insert-file-contents page)
                     (buffer-string)))))))

(ert-deftest ogent-cabinet-git-commit-stages-selected-files ()
  "Cabinet git commit stages selected files and records the commit."
  (ogent-cabinet-git-test-with-temp-dir root
    (let ((page (ogent-cabinet-git-test--seed root)))
      (with-temp-buffer
        (insert-file-contents page)
        (goto-char (point-max))
        (insert "\nSecond plan.\n")
        (write-region (point-min) (point-max) page nil 'silent))
      (ogent-cabinet-git-commit root "update plan" '("plan.org"))
      (should (= 0 (ogent-cabinet-git-dirty-count root)))
      (should (string-match-p
               "update plan"
               (ogent-cabinet-git-test--git root "log" "--oneline"))))))

(ert-deftest ogent-cabinet-git-pull-calls-fast-forward-only ()
  "Cabinet git pull uses a fast-forward-only pull."
  (let (captured)
    (cl-letf (((symbol-function 'ogent-cabinet-git--require-root)
               (lambda (_directory) "/tmp/cabinet"))
              ((symbol-function 'ogent-cabinet-git--call)
               (lambda (root &rest args)
                 (setq captured (cons root args))
                 "ok")))
      (should (equal (ogent-cabinet-git-pull "/tmp/cabinet") "ok"))
      (should (equal captured '("/tmp/cabinet" "pull" "--ff-only"))))))

(provide 'ogent-cabinet-git-tests)

;;; ogent-cabinet-git-tests.el ends here
