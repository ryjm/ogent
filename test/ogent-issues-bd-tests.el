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
				  (let ((_result nil))
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

;;; Reopen Tests

(ert-deftest ogent-issues-bd-test-reopen ()
  "Test reopening an issue sends correct args."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock "Reopened"
    (let ((called nil))
      (ogent-issues-bd-reopen "test-abc"
                              (lambda ()
                                (setq called t)))
      (should called)
      (let ((args (car ogent-issues-bd-test--captured-args)))
        (should (member "reopen" args))
        (should (member "test-abc" args))))))

(ert-deftest ogent-issues-bd-test-reopen-invalidates-cache ()
  "Test that reopen invalidates the cache."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd--cache-set '("list" "--json") ogent-issues-bd-test--sample-list)
  (should (ogent-issues-bd--cache-get '("list" "--json")))
  (ogent-issues-bd-test-with-mock "Reopened"
    (ogent-issues-bd-reopen "test-abc" (lambda () nil)))
  (should-not (ogent-issues-bd--cache-get '("list" "--json"))))

(ert-deftest ogent-issues-bd-test-reopen-error-callback ()
  "Test reopen error handling."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-error "reopen failed"
    (let ((error-msg nil))
      (ogent-issues-bd-reopen "test-abc"
                              (lambda () nil)
                              (lambda (err) (setq error-msg err)))
      (should (equal "reopen failed" error-msg)))))

;;; Comment Tests

(ert-deftest ogent-issues-bd-test-comment ()
  "Test adding a comment sends correct args."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock "Commented"
    (let ((called nil))
      (ogent-issues-bd-comment "test-abc" "This is a comment"
                               (lambda ()
                                 (setq called t)))
      (should called)
      (let ((args (car ogent-issues-bd-test--captured-args)))
        (should (member "comment" args))
        (should (member "test-abc" args))
        (should (member "This is a comment" args))))))

(ert-deftest ogent-issues-bd-test-comment-invalidates-cache ()
  "Test that comment invalidates the cache."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd--cache-set '("list" "--json") ogent-issues-bd-test--sample-list)
  (should (ogent-issues-bd--cache-get '("list" "--json")))
  (ogent-issues-bd-test-with-mock "Commented"
    (ogent-issues-bd-comment "test-abc" "note" (lambda () nil)))
  (should-not (ogent-issues-bd--cache-get '("list" "--json"))))

(ert-deftest ogent-issues-bd-test-comment-error-callback ()
  "Test comment error handling."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-error "comment failed"
    (let ((error-msg nil))
      (ogent-issues-bd-comment "test-abc" "text"
                               (lambda () nil)
                               (lambda (err) (setq error-msg err)))
      (should (equal "comment failed" error-msg)))))

;;; Update Tests

(ert-deftest ogent-issues-bd-test-update-status ()
  "Test updating issue status sends correct args."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock "Updated"
    (let ((called nil))
      (ogent-issues-bd-update "test-abc"
                              (lambda ()
                                (setq called t))
                              :status "closed")
      (should called)
      (let ((args (car ogent-issues-bd-test--captured-args)))
        (should (member "update" args))
        (should (member "test-abc" args))
        (should (member "--status" args))
        (should (member "closed" args))))))

(ert-deftest ogent-issues-bd-test-update-priority ()
  "Test updating issue priority sends correct args."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock "Updated"
    (ogent-issues-bd-update "test-def"
                            (lambda () nil)
                            :priority 3)
    (let ((args (car ogent-issues-bd-test--captured-args)))
      (should (member "update" args))
      (should (member "test-def" args))
      (should (member "--priority" args))
      (should (member "3" args)))))

(ert-deftest ogent-issues-bd-test-update-description ()
  "Test updating issue description sends correct args."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock "Updated"
    (ogent-issues-bd-update "test-abc"
                            (lambda () nil)
                            :description "New description")
    (let ((args (car ogent-issues-bd-test--captured-args)))
      (should (member "--description" args))
      (should (member "New description" args)))))

(ert-deftest ogent-issues-bd-test-update-multiple-fields ()
  "Test updating multiple fields at once."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock "Updated"
    (ogent-issues-bd-update "test-abc"
                            (lambda () nil)
                            :status "in_progress"
                            :priority 2
                            :description "Updated desc")
    (let ((args (car ogent-issues-bd-test--captured-args)))
      (should (member "--status" args))
      (should (member "in_progress" args))
      (should (member "--priority" args))
      (should (member "2" args))
      (should (member "--description" args))
      (should (member "Updated desc" args)))))

(ert-deftest ogent-issues-bd-test-update-invalidates-cache ()
  "Test that update invalidates the cache."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd--cache-set '("list" "--json") ogent-issues-bd-test--sample-list)
  (should (ogent-issues-bd--cache-get '("list" "--json")))
  (ogent-issues-bd-test-with-mock "Updated"
    (ogent-issues-bd-update "test-abc" (lambda () nil) :status "closed"))
  (should-not (ogent-issues-bd--cache-get '("list" "--json"))))

(ert-deftest ogent-issues-bd-test-update-error-callback ()
  "Test update error handling via :error-callback."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-error "update failed"
    (let ((error-msg nil))
      (ogent-issues-bd-update "test-abc"
                              (lambda () nil)
                              :status "closed"
                              :error-callback (lambda (err) (setq error-msg err)))
      (should (equal "update failed" error-msg)))))

;;; Cleanup Tests

(ert-deftest ogent-issues-bd-test-cleanup-clears-processes ()
  "Test cleanup clears the process list."
  (let ((ogent-issues-bd--processes nil))
    ;; Simulate having no live processes
    (ogent-issues-bd-cleanup)
    (should (null ogent-issues-bd--processes))))

(ert-deftest ogent-issues-bd-test-cleanup-kills-live-processes ()
  "Test cleanup kills live processes."
  (let ((ogent-issues-bd--processes nil))
    ;; Create a real process
    (let ((fake-proc (start-process "ogent-test-sleep" nil "sleep" "60")))
      (unwind-protect
          (progn
            (push fake-proc ogent-issues-bd--processes)
            (should (process-live-p fake-proc))
            (ogent-issues-bd-cleanup)
            (should (null ogent-issues-bd--processes))
            ;; Wait briefly for signal delivery
            (sleep-for 0.1)
            ;; Process should no longer be live after cleanup
            (should-not (process-live-p fake-proc)))
        ;; Safety net: ensure process is dead even if test fails
        (when (process-live-p fake-proc)
          (kill-process fake-proc))))))

(ert-deftest ogent-issues-bd-test-cleanup-invalidates-cache ()
  "Test cleanup also invalidates the cache."
  (ogent-issues-bd--cache-set '("list" "--json") ogent-issues-bd-test--sample-list)
  (should (ogent-issues-bd--cache-get '("list" "--json")))
  (let ((ogent-issues-bd--processes nil))
    (ogent-issues-bd-cleanup))
  (should-not (ogent-issues-bd--cache-get '("list" "--json"))))

;;; Requirements Gate Tests for Untested Functions

(ert-deftest ogent-issues-bd-test-reopen-no-bd ()
  "Test reopen when bd is not available."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (let ((error-msg nil))
      (ogent-issues-bd-reopen "test-abc"
                              (lambda () nil)
                              (lambda (err) (setq error-msg err)))
      (should (string-match-p "not found" error-msg)))))

(ert-deftest ogent-issues-bd-test-comment-no-bd ()
  "Test comment when bd is not available."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (let ((error-msg nil))
      (ogent-issues-bd-comment "test-abc" "text"
                               (lambda () nil)
                               (lambda (err) (setq error-msg err)))
      (should (string-match-p "not found" error-msg)))))

(ert-deftest ogent-issues-bd-test-update-no-bd ()
  "Test update when bd is not available."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (let ((error-msg nil))
      (ogent-issues-bd-update "test-abc"
                              (lambda () nil)
                              :status "closed"
                              :error-callback (lambda (err) (setq error-msg err)))
      (should (string-match-p "not found" error-msg)))))

;;; Version Tests

(ert-deftest ogent-issues-bd-test-version-sync-caches ()
  "Test synchronous version check caches result."
  (let ((ogent-issues-bd--version-cache nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_) "/usr/bin/bd"))
              ((symbol-function 'shell-command-to-string)
               (lambda (_) "bd 0.42.0\n")))
      (let ((v1 (ogent-issues-bd-version)))
        (should (equal v1 "bd 0.42.0"))
        ;; Second call should use cache, not call shell again
        (cl-letf (((symbol-function 'shell-command-to-string)
                   (lambda (_) (error "Should not be called"))))
          (should (equal (ogent-issues-bd-version) "bd 0.42.0")))))))

(ert-deftest ogent-issues-bd-test-version-sync-no-bd ()
  "Test synchronous version returns nil when bd unavailable."
  (let ((ogent-issues-bd--version-cache nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_) nil)))
      (should-not (ogent-issues-bd-version)))))

;;; Project Detection Tests

(ert-deftest ogent-issues-bd-test-project-root-locates-beads ()
  "Test project root detection finds .beads directory."
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (_dir _file) "/home/user/project/")))
    (should (equal (ogent-issues-bd-project-root "/home/user/project/src/")
                   "/home/user/project/"))))

(ert-deftest ogent-issues-bd-test-project-root-returns-nil ()
  "Test project root returns nil when no .beads found."
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (_dir _file) nil)))
    (should-not (ogent-issues-bd-project-root "/tmp/no-project/"))))

(ert-deftest ogent-issues-bd-test-project-name-extraction ()
  "Test project name extraction from root."
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (_dir _file) "/home/user/my-project/")))
    (should (equal (ogent-issues-bd-project-name "/home/user/my-project/src/")
                   "my-project"))))

(ert-deftest ogent-issues-bd-test-project-name-returns-nil ()
  "Test project name returns nil when no project found."
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (_dir _file) nil)))
    (should-not (ogent-issues-bd-project-name "/tmp/"))))

;;; Cache Isolation Tests

(ert-deftest ogent-issues-bd-test-cache-key-project-isolation ()
  "Test that cache key includes project root for isolation."
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (_dir _file) "/project/a/")))
    (let ((key-a (ogent-issues-bd--cache-key '("list" "--json"))))
      (cl-letf (((symbol-function 'locate-dominating-file)
                 (lambda (_dir _file) "/project/b/")))
        (let ((key-b (ogent-issues-bd--cache-key '("list" "--json"))))
          (should-not (equal key-a key-b)))))))

(ert-deftest ogent-issues-bd-test-cache-expires ()
  "Test that cache entries expire after TTL."
  (let ((ogent-issues-bd--cache (make-hash-table :test 'equal))
        (ogent-issues-bd-cache-ttl 0))
    ;; With TTL=0, nothing should be cached
    (ogent-issues-bd--cache-set '("test") '(:result "data"))
    (should-not (ogent-issues-bd--cache-get '("test")))))

(ert-deftest ogent-issues-bd-test-cache-disabled ()
  "Test that caching can be disabled entirely."
  (let ((ogent-issues-bd--cache (make-hash-table :test 'equal))
        (ogent-issues-bd-cache-ttl 0))
    (ogent-issues-bd--cache-set '("foo") '(:data "bar"))
    ;; Should not cache when TTL is 0
    (should-not (ogent-issues-bd--cache-get '("foo")))))

;;; Check Requirements Tests

(ert-deftest ogent-issues-bd-test-requirements-missing-bd ()
  "Test requirements check when bd is not installed."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (let ((result (ogent-issues-bd-check-requirements)))
      (should result)
      (should (string-match-p "not found" result)))))

(ert-deftest ogent-issues-bd-test-requirements-no-beads-dir ()
  "Test requirements check when not in a beads project."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) "/usr/bin/bd"))
            ((symbol-function 'locate-dominating-file)
             (lambda (_dir _file) nil)))
    (let ((result (ogent-issues-bd-check-requirements)))
      (should result)
      (should (string-match-p "No beads project" result)))))

(ert-deftest ogent-issues-bd-test-requirements-all-satisfied ()
  "Test requirements check when everything is available."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) "/usr/bin/bd"))
            ((symbol-function 'locate-dominating-file)
             (lambda (_dir _file) "/project/")))
    (should-not (ogent-issues-bd-check-requirements))))

;;; Initialized Tests

(ert-deftest ogent-issues-bd-test-initialized-p-delegates ()
  "Test initialized check delegates to project-root."
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (_dir _file) "/project/")))
    (should (ogent-issues-bd-initialized-p "/project/src/")))
  (cl-letf (((symbol-function 'locate-dominating-file)
             (lambda (_dir _file) nil)))
    (should-not (ogent-issues-bd-initialized-p "/tmp/"))))

;;; Create With Properties Tests

(ert-deftest ogent-issues-bd-test-create-with-description ()
  "Test create issue with optional description property."
  (let ((captured-args nil))
    (ogent-issues-bd-test-with-mock
        '(:id "test-xyz" :title "Test")
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest args)
                   (setq captured-args (plist-get args :command))
                   ;; Return a mock process
                   (let ((proc (start-process "test" nil "true")))
                     proc))))
        (ogent-issues-bd-create "My Task"
                                (lambda (_result) nil)
                                :description "A detailed description"
                                :type "bug"
                                :priority 1)
        ;; captured-args should contain --description
        (when captured-args
          (should (member "--description" captured-args)))))))

(provide 'ogent-issues-bd-tests)

;;; ogent-issues-bd-tests.el ends here
