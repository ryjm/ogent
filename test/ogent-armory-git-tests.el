;;; ogent-armory-git-tests.el --- Tests for Armory git wrappers -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for Armory git status, log, diff, restore, commit, and pull wrappers.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory)
(require 'ogent-armory-data)
(require 'ogent-armory-git)

(defmacro ogent-armory-git-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (ogent-test--provision-store-directory 'armory-git)))
     ,@body))

(defun ogent-armory-git-test--git (root &rest args)
  "Run git in ROOT with ARGS."
  (let ((buffer (generate-new-buffer " *ogent-armory-git-test*")))
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

(defun ogent-armory-git-test--seed (root)
  "Create a git-backed Armory under ROOT."
  (ogent-armory-git-test--git root "init")
  (ogent-armory-git-test--git root "config" "user.email" "test@example.com")
  (ogent-armory-git-test--git root "config" "user.name" "Armory Test")
  (ogent-armory-git-test--git root "config" "commit.gpgsign" "false")
  (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
  (let ((page (ogent-armory-page-create
               root
               "Plan"
               :path "plan.org"
               :body "Initial plan.")))
    (ogent-armory-git-test--git root "add" ".")
    (ogent-armory-git-test--git root "commit" "-m" "initial armory")
    page))

(ert-deftest ogent-armory-git-status-diff-log-and-restore-page ()
  "Git wrappers expose dirty status, diff, log, and restore for a page."
  (ogent-armory-git-test-with-temp-dir root
    (let ((page (ogent-armory-git-test--seed root)))
      (with-temp-buffer
        (insert-file-contents page)
        (goto-char (point-max))
        (insert "\nChanged plan.\n")
        (write-region (point-min) (point-max) page nil 'silent))
      (let ((status (ogent-armory-git-status-data root)))
        (should (= 1 (length status)))
        (should (equal (plist-get (car status) :relative) "plan.org"))
        (should (= (ogent-armory-git-dirty-count root) 1)))
      (let ((diff-buffer (ogent-armory-git-diff-page page)))
        (with-current-buffer diff-buffer
          (should (string-match-p "Changed plan" (buffer-string))))
        (kill-buffer diff-buffer))
      (let ((log-buffer (ogent-armory-git-log-page page)))
        (with-current-buffer log-buffer
          (should (string-match-p "initial armory" (buffer-string))))
        (kill-buffer log-buffer))
      (ogent-armory-git-restore-page page t)
      (should-not (string-match-p
                   "Changed plan"
                   (with-temp-buffer
                     (insert-file-contents page)
                     (buffer-string)))))))

(ert-deftest ogent-armory-git-commit-stages-selected-files ()
  "Armory git commit stages selected files and records the commit."
  (ogent-armory-git-test-with-temp-dir root
    (let ((page (ogent-armory-git-test--seed root)))
      (with-temp-buffer
        (insert-file-contents page)
        (goto-char (point-max))
        (insert "\nSecond plan.\n")
        (write-region (point-min) (point-max) page nil 'silent))
      (ogent-armory-git-commit root "update plan" '("plan.org"))
      (should (= 0 (ogent-armory-git-dirty-count root)))
      (should (string-match-p
               "update plan"
               (ogent-armory-git-test--git root "log" "--oneline"))))))

(ert-deftest ogent-armory-git-pull-calls-fast-forward-only ()
  "Armory git pull uses a fast-forward-only pull."
  (let (captured)
    (cl-letf (((symbol-function 'ogent-armory-git--require-root)
               (lambda (_directory) "/tmp/armory"))
              ((symbol-function 'ogent-armory-git--call)
               (lambda (root &rest args)
                 (setq captured (cons root args))
                 "ok")))
      (should (equal (ogent-armory-git-pull "/tmp/armory") "ok"))
      (should (equal captured '("/tmp/armory" "pull" "--ff-only"))))))

(ert-deftest ogent-armory-git-status-keymap-binds-pull ()
  "The git status keymap reaches the pull wrapper on `F' and `C-c f'."
  (should (eq (lookup-key ogent-armory-git-mode-map "F")
              #'ogent-armory-git-pull-from-status))
  (should (eq (lookup-key ogent-armory-git-mode-map (kbd "C-c f"))
              #'ogent-armory-git-pull-from-status)))

(ert-deftest ogent-armory-git-pull-from-status-pulls-root-and-refreshes ()
  "The status-buffer pull wrapper pulls the buffer's root, then refreshes."
  (let (pulled refreshed)
    (cl-letf (((symbol-function 'ogent-armory-git-pull)
               (lambda (directory) (setq pulled directory)))
              ((symbol-function 'ogent-armory-git-refresh)
               (lambda (&rest _) (setq refreshed t))))
      (with-temp-buffer
        (setq-local ogent-armory-git--root "/tmp/armory")
        (ogent-armory-git-pull-from-status)))
    (should (equal pulled "/tmp/armory"))
    (should refreshed)))

(provide 'ogent-armory-git-tests)

;;; ogent-armory-git-tests.el ends here
