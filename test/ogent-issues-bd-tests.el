;;; ogent-issues-bd-tests.el --- Tests for ogent-issues-bd -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the beads CLI integration layer.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-issues-bd)

;;; Test Fixtures

(defconst ogent-issues-bd-test--sample-issue
  '(:id "test-abc"
    :title "Test issue"
    :description "A test issue"
    :status "open"
    :priority 1
    :issue_type "task"
    :created_at "2025-12-16T10:00:00-05:00"
    :updated_at "2025-12-16T10:00:00-05:00"
    :dependency_count 0
    :dependent_count 0)
  "Sample issue plist for testing.")

(defconst ogent-issues-bd-test--sample-list
  (list ogent-issues-bd-test--sample-issue
        '(:id "test-def"
          :title "Another issue"
          :description ""
          :status "in_progress"
          :priority 2
          :issue_type "bug"
          :created_at "2025-12-16T11:00:00-05:00"
          :updated_at "2025-12-16T11:00:00-05:00"
          :dependency_count 1
          :dependent_count 0))
  "Sample issue list for testing.")

;;; Mocking Utilities

(defvar ogent-issues-bd-test--mock-output nil
  "Mock output to return from bd commands.")

(defvar ogent-issues-bd-test--mock-error nil
  "Mock error to return from bd commands.")

(defvar ogent-issues-bd-test--captured-args nil
  "Captured arguments from mock bd calls.")

(defmacro ogent-issues-bd-test-with-mock (output &rest body)
  "Execute BODY with bd mocked to return OUTPUT.
OUTPUT should be a plist or list that will be JSON-encoded."
  (declare (indent 1) (debug t))
  `(let ((ogent-issues-bd-test--mock-output ,output)
         (ogent-issues-bd-test--mock-error nil)
         (ogent-issues-bd-test--captured-args nil)
         ;; Ensure bd appears available
         (ogent-issues-bd-executable "bd"))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (_) t))
               ((symbol-function 'file-directory-p)
                (lambda (path)
                  (string-suffix-p ".beads" path)))
               ;; Mock locate-dominating-file to find .beads
               ((symbol-function 'locate-dominating-file)
                (lambda (file name)
                  (when (equal name ".beads")
                    (file-name-directory (or file default-directory)))))
               ((symbol-function 'ogent-issues-bd--run-async)
                (lambda (args callback &optional error-callback _raw)
                  (push args ogent-issues-bd-test--captured-args)
                  (if ogent-issues-bd-test--mock-error
                      (when error-callback
                        (funcall error-callback ogent-issues-bd-test--mock-error))
                    (funcall callback ogent-issues-bd-test--mock-output))
                  nil)))
       ,@body)))

(defmacro ogent-issues-bd-test-with-error (error-msg &rest body)
  "Execute BODY with bd mocked to return ERROR-MSG."
  (declare (indent 1) (debug t))
  `(let ((ogent-issues-bd-test--mock-output nil)
         (ogent-issues-bd-test--mock-error ,error-msg)
         (ogent-issues-bd-test--captured-args nil)
         (ogent-issues-bd-executable "bd"))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (_) t))
               ((symbol-function 'file-directory-p)
                (lambda (path)
                  (string-suffix-p ".beads" path)))
               ;; Mock locate-dominating-file to find .beads
               ((symbol-function 'locate-dominating-file)
                (lambda (file name)
                  (when (equal name ".beads")
                    (file-name-directory (or file default-directory)))))
               ((symbol-function 'ogent-issues-bd--run-async)
                (lambda (args callback &optional error-callback _raw)
                  (push args ogent-issues-bd-test--captured-args)
                  (if ogent-issues-bd-test--mock-error
                      (when error-callback
                        (funcall error-callback ogent-issues-bd-test--mock-error))
                    (funcall callback ogent-issues-bd-test--mock-output))
                  nil)))
       ,@body)))

;;; Availability Tests

(ert-deftest ogent-issues-bd-test-available-p ()
  "Test bd availability check."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) "/usr/local/bin/bd")))
    (should (ogent-issues-bd-available-p)))
  
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-not (ogent-issues-bd-available-p))))

(ert-deftest ogent-issues-bd-test-initialized-p ()
  "Test beads initialization check walks up directory tree."
  ;; When locate-dominating-file finds .beads, initialized-p returns t
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (_dir _name) "/some/project/")))
    (should (ogent-issues-bd-initialized-p "/some/project/deep/subdir")))
  
  ;; When locate-dominating-file returns nil, initialized-p returns nil
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (_dir _name) nil)))
    (should-not (ogent-issues-bd-initialized-p "/some/other/path"))))

(ert-deftest ogent-issues-bd-test-check-requirements-no-bd ()
  "Test requirements check when bd is not installed."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should (string-match-p "not found" (ogent-issues-bd-check-requirements)))))

(ert-deftest ogent-issues-bd-test-check-requirements-not-initialized ()
  "Test requirements check when beads is not initialized."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) t))
            ((symbol-function 'locate-dominating-file)
             (lambda (_dir _name) nil)))
    (should (string-match-p "No beads project found" (ogent-issues-bd-check-requirements)))))

(ert-deftest ogent-issues-bd-test-check-requirements-ok ()
  "Test requirements check when everything is OK."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) t))
            ((symbol-function 'locate-dominating-file)
             (lambda (_dir _name) "/some/project/")))
    (should-not (ogent-issues-bd-check-requirements))))

;;; Caching Tests

(ert-deftest ogent-issues-bd-test-cache-set-get ()
  "Test cache set and get."
  (ogent-issues-bd-cache-invalidate)
  (let ((args '("list" "--json"))
        (result '((:id "test"))))
    (ogent-issues-bd--cache-set args result)
    (should (equal result (ogent-issues-bd--cache-get args)))))

(ert-deftest ogent-issues-bd-test-cache-invalidate ()
  "Test cache invalidation."
  (let ((args '("list" "--json"))
        (result '((:id "test"))))
    (ogent-issues-bd--cache-set args result)
    (ogent-issues-bd-cache-invalidate)
    (should-not (ogent-issues-bd--cache-get args))))

(ert-deftest ogent-issues-bd-test-cache-expiry ()
  "Test cache expiry."
  (let ((ogent-issues-bd-cache-ttl 0))  ; Disable caching
    (ogent-issues-bd-cache-invalidate)
    (let ((args '("list" "--json"))
          (result '((:id "test"))))
      (ogent-issues-bd--cache-set args result)
      ;; With TTL=0, cache should not store
      (should-not (ogent-issues-bd--cache-get args)))))

;;; High-Level API Tests

(ert-deftest ogent-issues-bd-test-list ()
  "Test listing issues."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock ogent-issues-bd-test--sample-list
    (let ((result nil))
      (ogent-issues-bd-list
       (lambda (issues)
         (setq result issues)))
      (should (equal 2 (length result)))
      (should (equal "test-abc" (plist-get (car result) :id))))))

(ert-deftest ogent-issues-bd-test-list-with-filters ()
  "Test listing issues with filters."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock ogent-issues-bd-test--sample-list
    (ogent-issues-bd-list
     (lambda (_) nil)
     '(:status "open" :type "bug" :priority 1))
    ;; Check captured args include filters
    (let ((args (car ogent-issues-bd-test--captured-args)))
      (should (member "--status=open" args))
      (should (member "--type=bug" args))
      (should (member "--priority=1" args)))))

(ert-deftest ogent-issues-bd-test-get ()
  "Test getting a single issue."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock ogent-issues-bd-test--sample-issue
    (let ((result nil))
      (ogent-issues-bd-get "test-abc"
                           (lambda (issue)
                             (setq result issue)))
      (should (equal "test-abc" (plist-get result :id)))
      (should (equal "Test issue" (plist-get result :title))))))

(ert-deftest ogent-issues-bd-test-ready ()
  "Test getting ready issues."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock ogent-issues-bd-test--sample-list
    (let ((result nil))
      (ogent-issues-bd-ready
       (lambda (issues)
         (setq result issues)))
      (should (equal 2 (length result))))))

(ert-deftest ogent-issues-bd-test-create ()
  "Test creating an issue."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock ogent-issues-bd-test--sample-issue
    (let ((result nil))
      (ogent-issues-bd-create "New issue"
                              (lambda (issue)
                                (setq result issue))
                              :type "task"
                              :priority 1)
      ;; Check args
      (let ((args (car ogent-issues-bd-test--captured-args)))
        (should (member "create" args))
        (should (member "--title" args))
        (should (member "New issue" args))
        (should (member "--type" args))
        (should (member "task" args))))))

(ert-deftest ogent-issues-bd-test-close ()
  "Test closing an issue."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock "Closed"
    (let ((called nil))
      (ogent-issues-bd-close "test-abc" "Done"
                             (lambda ()
                               (setq called t)))
      (should called)
      ;; Check args
      (let ((args (car ogent-issues-bd-test--captured-args)))
        (should (member "close" args))
        (should (member "test-abc" args))
        (should (member "--reason" args))
        (should (member "Done" args))))))

(ert-deftest ogent-issues-bd-test-start ()
  "Test starting an issue."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock "Started"
    (let ((called nil))
      (ogent-issues-bd-start "test-abc"
                             (lambda ()
                               (setq called t)))
      (should called)
      (let ((args (car ogent-issues-bd-test--captured-args)))
        (should (member "start" args))
        (should (member "test-abc" args))))))

(ert-deftest ogent-issues-bd-test-sync ()
  "Test syncing beads."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock "Synced"
    (let ((called nil))
      (ogent-issues-bd-sync
       (lambda ()
         (setq called t)))
      (should called)
      (let ((args (car ogent-issues-bd-test--captured-args)))
        (should (member "sync" args))))))

;;; Error Handling Tests

(ert-deftest ogent-issues-bd-test-list-error ()
  "Test error handling in list."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-error "bd command failed"
    (let ((error-msg nil))
      (ogent-issues-bd-list
       (lambda (_) nil)
       nil
       (lambda (err)
         (setq error-msg err)))
      (should (equal "bd command failed" error-msg)))))

;;; Cache Invalidation on Mutation Tests

(ert-deftest ogent-issues-bd-test-create-invalidates-cache ()
  "Test that create invalidates the cache."
  (ogent-issues-bd-cache-invalidate)
  ;; First, populate cache
  (ogent-issues-bd--cache-set '("list" "--json") ogent-issues-bd-test--sample-list)
  (should (ogent-issues-bd--cache-get '("list" "--json")))
  
  ;; Create should invalidate
  (ogent-issues-bd-test-with-mock ogent-issues-bd-test--sample-issue
    (ogent-issues-bd-create "New" (lambda (_) nil)))
  
  ;; Cache should be empty now
  (should-not (ogent-issues-bd--cache-get '("list" "--json"))))

(ert-deftest ogent-issues-bd-test-close-invalidates-cache ()
  "Test that close invalidates the cache."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd--cache-set '("list" "--json") ogent-issues-bd-test--sample-list)
  
  (ogent-issues-bd-test-with-mock "Closed"
    (ogent-issues-bd-close "test-abc" "Done" (lambda () nil)))
  
  (should-not (ogent-issues-bd--cache-get '("list" "--json"))))

;;; Project Detection Tests

(ert-deftest ogent-issues-bd-test-project-root ()
  "Test project root detection."
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (_dir _name)
               "/home/user/project")))
    (should (equal "/home/user/project"
                   (ogent-issues-bd-project-root "/home/user/project/src")))))

(ert-deftest ogent-issues-bd-test-project-name ()
  "Test project name extraction."
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (_dir _name)
               "/home/user/my-project")))
    (should (equal "my-project"
                   (ogent-issues-bd-project-name "/home/user/my-project/src")))))

;;; Integration Tests for Project Detection (Real Filesystem)

(defmacro ogent-issues-bd-test-with-temp-project (&rest body)
  "Execute BODY with a temporary beads project structure.
Binds `project-root` to the temp project path and `sub-dir` to a nested path."
  (declare (indent 0))
  `(let* ((project-root (make-temp-file "ogent-test-" t))
          (beads-dir (expand-file-name ".beads" project-root))
          (sub-dir (expand-file-name "src/deep/nested" project-root)))
     (unwind-protect
         (progn
           (make-directory beads-dir)
           (make-directory sub-dir t)
           ,@body)
       ;; Cleanup
       (delete-directory project-root t))))

(ert-deftest ogent-issues-bd-test-integration-initialized-p-from-root ()
  "Integration test: initialized-p returns t when in project root."
  (ogent-issues-bd-test-with-temp-project
    (let ((default-directory project-root))
      (should (ogent-issues-bd-initialized-p)))))

(ert-deftest ogent-issues-bd-test-integration-initialized-p-from-subdir ()
  "Integration test: initialized-p returns t when in subdirectory."
  (ogent-issues-bd-test-with-temp-project
    (let ((default-directory sub-dir))
      (should (ogent-issues-bd-initialized-p)))))

(ert-deftest ogent-issues-bd-test-integration-initialized-p-outside-project ()
  "Integration test: initialized-p returns nil outside any project."
  (let ((default-directory temporary-file-directory))
    ;; Ensure we're not accidentally in a beads project
    (unless (locate-dominating-file default-directory ".beads")
      (should-not (ogent-issues-bd-initialized-p)))))

(ert-deftest ogent-issues-bd-test-integration-project-root-from-subdir ()
  "Integration test: project-root returns correct path from subdirectory."
  (ogent-issues-bd-test-with-temp-project
    (let ((default-directory sub-dir))
      ;; Use expand-file-name on both sides to normalize tilde expansion
      (should (equal (expand-file-name (file-name-as-directory project-root))
                     (expand-file-name (ogent-issues-bd-project-root)))))))

(ert-deftest ogent-issues-bd-test-integration-project-root-outside-project ()
  "Integration test: project-root returns nil outside any project."
  (let ((default-directory temporary-file-directory))
    ;; Ensure we're not accidentally in a beads project
    (unless (locate-dominating-file default-directory ".beads")
      (should-not (ogent-issues-bd-project-root)))))

(ert-deftest ogent-issues-bd-test-integration-project-name-from-subdir ()
  "Integration test: project-name returns correct name from subdirectory."
  (ogent-issues-bd-test-with-temp-project
    (let ((default-directory sub-dir)
          (expected-name (file-name-nondirectory (directory-file-name project-root))))
      (should (equal expected-name (ogent-issues-bd-project-name))))))

;;; Multi-Project Cache Tests
;; These tests verify that cache entries are isolated by project root,
;; preventing the bug where switching projects shows stale issues.

(ert-deftest ogent-issues-bd-test-cache-key-includes-project ()
  "Test that cache key includes project root."
  (cl-letf (((symbol-function 'ogent-issues-bd-project-root)
             (lambda () "/project-a/")))
    (let ((key1 (ogent-issues-bd--cache-key '("list" "--json"))))
      (cl-letf (((symbol-function 'ogent-issues-bd-project-root)
                 (lambda () "/project-b/")))
        (let ((key2 (ogent-issues-bd--cache-key '("list" "--json"))))
          (should-not (equal key1 key2)))))))

(ert-deftest ogent-issues-bd-test-cache-isolated-by-project ()
  "Test that cache entries are isolated by project root."
  (ogent-issues-bd-cache-invalidate)
  (let ((project-a-issues '((:id "a-001" :title "Project A issue")))
        (project-b-issues '((:id "b-001" :title "Project B issue"))))
    ;; Cache result for project A
    (cl-letf (((symbol-function 'ogent-issues-bd-project-root)
               (lambda () "/path/to/project-a")))
      (ogent-issues-bd--cache-set '("list" "--json") project-a-issues))
    ;; Cache result for project B
    (cl-letf (((symbol-function 'ogent-issues-bd-project-root)
               (lambda () "/path/to/project-b")))
      (ogent-issues-bd--cache-set '("list" "--json") project-b-issues))
    ;; Verify project A returns its own issues
    (cl-letf (((symbol-function 'ogent-issues-bd-project-root)
               (lambda () "/path/to/project-a")))
      (should (equal project-a-issues
                     (ogent-issues-bd--cache-get '("list" "--json")))))
    ;; Verify project B returns its own issues
    (cl-letf (((symbol-function 'ogent-issues-bd-project-root)
               (lambda () "/path/to/project-b")))
      (should (equal project-b-issues
                     (ogent-issues-bd--cache-get '("list" "--json")))))))

(ert-deftest ogent-issues-bd-test-cache-nil-project-isolated ()
  "Test that nil project root has its own cache namespace."
  (ogent-issues-bd-cache-invalidate)
  (cl-letf (((symbol-function 'ogent-issues-bd-project-root)
             (lambda () nil)))
    (ogent-issues-bd--cache-set '("list" "--json") '((:id "orphan")))
    (should (ogent-issues-bd--cache-get '("list" "--json"))))
  ;; Different project should not see nil project's cache
  (cl-letf (((symbol-function 'ogent-issues-bd-project-root)
             (lambda () "/some/project")))
    (should-not (ogent-issues-bd--cache-get '("list" "--json")))))

(provide 'ogent-issues-bd-tests)

;;; ogent-issues-bd-tests.el ends here
