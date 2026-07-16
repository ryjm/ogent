;;; ogent-issues-bd-tests.el --- Tests for ogent-issues-bd -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the beads CLI integration layer.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-issues-bd)

;; Dynamically bound in the agenda-projection tests; declared special
;; here so the let bindings reach `ogent-issues-agenda'.
(defvar org-agenda-buffer)
(defvar org-agenda-files)

;; Loaded on demand by the projection round-trip test.
(declare-function ogent-armory-record-metadata "ogent-armory-store" (file))

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
         (ogent-issues-bd-executable "br"))
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
         (ogent-issues-bd-executable "br"))
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

(ert-deftest ogent-issues-bd-test-get-normalizes-singleton-list ()
  "Test get coerces singleton list payloads to one plist."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock (list ogent-issues-bd-test--sample-issue)
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
    (progn
      (ogent-issues-bd-create "New issue"
                              #'ignore
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
  "Test claiming an issue."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock "Started"
    (let ((called nil))
      (ogent-issues-bd-start "test-abc"
                             (lambda ()
                               (setq called t)))
      (should called)
      (let ((args (car ogent-issues-bd-test--captured-args)))
        (should (equal '("update" "test-abc" "--claim")
                       args))))))

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
        (should (member "comments" args))
        (should (member "add" args))
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
      ;; Don't prompt "Buffer has a running process" on buffer kill
      (set-process-query-on-exit-flag fake-proc nil)
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
          (kill-process fake-proc)
          (sleep-for 0.1))))))

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

;;; Version Async Tests

(ert-deftest ogent-issues-bd-test-version-async-calls-callback ()
  "Test async version calls callback with trimmed version string."
  (let ((ogent-issues-bd--version-cache nil)
        (result nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_) t))
              ((symbol-function 'locate-dominating-file)
               (lambda (_d _n) "/project/"))
              ((symbol-function 'ogent-issues-bd--run-async)
               (lambda (args callback &optional _error-cb raw)
                 ;; Verify raw flag is set
                 (should raw)
                 ;; Verify args
                 (should (equal args '("--version")))
                 ;; Call callback with version output
                 (funcall callback "  bd 1.2.3\n  "))))
      (ogent-issues-bd-version
       (lambda (v) (setq result v)))
      (should (equal result "bd 1.2.3"))
      ;; Should also update the cache
      (should (equal ogent-issues-bd--version-cache "bd 1.2.3")))))

(ert-deftest ogent-issues-bd-test-version-sync-uses-cache ()
  "Test synchronous version returns cached value without shell call."
  (let ((ogent-issues-bd--version-cache "bd 0.99.0")
        (shell-called nil))
    (cl-letf (((symbol-function 'shell-command-to-string)
               (lambda (_) (setq shell-called t) "bd 0.99.1")))
      (should (equal (ogent-issues-bd-version) "bd 0.99.0"))
      (should-not shell-called))))

;;; Cached Path Tests

(ert-deftest ogent-issues-bd-test-list-returns-cached ()
  "Test list returns cached result without calling run-async."
  (ogent-issues-bd-cache-invalidate)
  (let ((async-called nil)
        (result nil)
        (ogent-issues-bd-cache-ttl 60))
    (ogent-issues-bd-test-with-mock ogent-issues-bd-test--sample-list
      ;; First call populates cache
      (ogent-issues-bd-list (lambda (issues) (setq result issues)))
      (should (equal 2 (length result)))
      ;; Now override run-async to track if it's called again
      (setq async-called nil)
      (cl-letf (((symbol-function 'ogent-issues-bd--run-async)
                 (lambda (&rest _) (setq async-called t))))
        ;; Second call should use cache
        (setq result nil)
        (ogent-issues-bd-list (lambda (issues) (setq result issues)))
        (should (equal 2 (length result)))
        ;; run-async should NOT have been called
        (should-not async-called)))))

(ert-deftest ogent-issues-bd-issue-list-accepts-both-shapes ()
  "br's pagination wrapper and bd's bare array both normalize."
  (let ((issues (list ogent-issues-bd-test--sample-issue)))
    ;; br shape: (:issues (...) :total N ...)
    (should (equal (ogent-issues-bd--issue-list
                    (list :issues issues :total 1 :limit 50
                          :offset 0 :has_more nil))
                   issues))
    ;; classic bd shape: bare array
    (should (equal (ogent-issues-bd--issue-list issues) issues))
    ;; empty results
    (should (null (ogent-issues-bd--issue-list nil)))
    (should (null (ogent-issues-bd--issue-list (list :issues nil :total 0))))))

(ert-deftest ogent-issues-bd-test-list-unwraps-br-pagination ()
  "Callback receives the bare issue list from br's wrapped response."
  (ogent-issues-bd-cache-invalidate)
  (let ((result 'unset)
        (ogent-issues-bd-cache-ttl 60))
    (ogent-issues-bd-test-with-mock (list :issues ogent-issues-bd-test--sample-list
                                          :total 2 :limit 50 :offset 0
                                          :has_more nil)
      (ogent-issues-bd-list (lambda (issues) (setq result issues)))
      (should (equal result ogent-issues-bd-test--sample-list))
      ;; The cached second call unwraps too.
      (setq result 'unset)
      (ogent-issues-bd-list (lambda (issues) (setq result issues)))
      (should (equal result ogent-issues-bd-test--sample-list)))))

(ert-deftest ogent-issues-bd-test-get-returns-cached ()
  "Test get returns cached result on second call."
  (ogent-issues-bd-cache-invalidate)
  (let ((result nil)
        (ogent-issues-bd-cache-ttl 60))
    (ogent-issues-bd-test-with-mock ogent-issues-bd-test--sample-issue
      ;; First call
      (ogent-issues-bd-get "test-abc" (lambda (issue) (setq result issue)))
      (should (equal "test-abc" (plist-get result :id)))
      ;; Second call should use cache (run-async is overridden by mock, but cache hits first)
      (setq result nil)
      (ogent-issues-bd-get "test-abc" (lambda (issue) (setq result issue)))
      (should (equal "test-abc" (plist-get result :id))))))

(ert-deftest ogent-issues-bd-test-ready-returns-cached ()
  "Test ready returns cached result on second call."
  (ogent-issues-bd-cache-invalidate)
  (let ((result nil)
        (ogent-issues-bd-cache-ttl 60))
    (ogent-issues-bd-test-with-mock ogent-issues-bd-test--sample-list
      ;; First call
      (ogent-issues-bd-ready (lambda (issues) (setq result issues)))
      (should (equal 2 (length result)))
      ;; Second call should hit cache
      (setq result nil)
      (ogent-issues-bd-ready (lambda (issues) (setq result issues)))
      (should (equal 2 (length result))))))

;;; Create with Parent Tests

(ert-deftest ogent-issues-bd-test-create-with-parent ()
  "Test create with --parent argument."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-mock ogent-issues-bd-test--sample-issue
    (ogent-issues-bd-create "Subtask"
                            (lambda (_) nil)
                            :parent "parent-abc"
                            :type "task")
    (let ((args (car ogent-issues-bd-test--captured-args)))
      (should (member "create" args))
      (should (member "--parent" args))
      (should (member "parent-abc" args))
      (should (member "--type" args))
      (should (member "task" args)))))

;;; Error Callbacks for Mutation Functions

(ert-deftest ogent-issues-bd-test-close-error-callback ()
  "Test close error handling with error callback."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-error "close failed: not found"
    (let ((error-msg nil))
      (ogent-issues-bd-close "nonexist" "Done"
                             (lambda () nil)
                             (lambda (err) (setq error-msg err)))
      (should (equal "close failed: not found" error-msg)))))

(ert-deftest ogent-issues-bd-test-start-error-callback ()
  "Test start error handling with error callback."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-error "start failed"
    (let ((error-msg nil))
      (ogent-issues-bd-start "bad-id"
                             (lambda () nil)
                             (lambda (err) (setq error-msg err)))
      (should (equal "start failed" error-msg)))))

(ert-deftest ogent-issues-bd-test-sync-error-callback ()
  "Test sync error handling with error callback."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-error "sync failed: merge conflict"
    (let ((error-msg nil))
      (ogent-issues-bd-sync (lambda () nil)
                            (lambda (err) (setq error-msg err)))
      (should (equal "sync failed: merge conflict" error-msg)))))

;;; User-Error Paths (no error-callback)

(ert-deftest ogent-issues-bd-test-list-no-bd-user-error ()
  "Test list signals user-error when bd unavailable and no error-callback."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-error
     (ogent-issues-bd-list (lambda (_) nil))
     :type 'user-error)))

(ert-deftest ogent-issues-bd-test-get-no-bd-user-error ()
  "Test get signals user-error when bd unavailable and no error-callback."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-error
     (ogent-issues-bd-get "test-abc" (lambda (_) nil))
     :type 'user-error)))

(ert-deftest ogent-issues-bd-test-ready-no-bd-user-error ()
  "Test ready signals user-error when bd unavailable and no error-callback."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-error
     (ogent-issues-bd-ready (lambda (_) nil))
     :type 'user-error)))

(ert-deftest ogent-issues-bd-test-create-no-bd-user-error ()
  "Test create signals user-error when bd unavailable and no error-callback."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-error
     (ogent-issues-bd-create "Title" (lambda (_) nil))
     :type 'user-error)))

(ert-deftest ogent-issues-bd-test-close-no-bd-user-error ()
  "Test close signals user-error when bd unavailable and no error-callback."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-error
     (ogent-issues-bd-close "id" "reason" (lambda () nil))
     :type 'user-error)))

(ert-deftest ogent-issues-bd-test-start-no-bd-user-error ()
  "Test start signals user-error when bd unavailable and no error-callback."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-error
     (ogent-issues-bd-start "id" (lambda () nil))
     :type 'user-error)))

(ert-deftest ogent-issues-bd-test-sync-no-bd-user-error ()
  "Test sync signals user-error when bd unavailable and no error-callback."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-error
     (ogent-issues-bd-sync (lambda () nil))
     :type 'user-error)))

(ert-deftest ogent-issues-bd-test-update-no-bd-user-error ()
  "Test update signals user-error when bd unavailable and no error-callback."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil)))
    (should-error
     (ogent-issues-bd-update "id" (lambda () nil) :status "closed")
     :type 'user-error)))

;;; Get Error Callback

(ert-deftest ogent-issues-bd-test-get-error-callback ()
  "Test get error handling with error callback."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-error "show failed"
    (let ((error-msg nil))
      (ogent-issues-bd-get "bad-id"
                           (lambda (_) nil)
                           (lambda (err) (setq error-msg err)))
      (should (equal "show failed" error-msg)))))

;;; Ready Error Callback

(ert-deftest ogent-issues-bd-test-ready-error-callback ()
  "Test ready error handling with error callback."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-error "ready failed"
    (let ((error-msg nil))
      (ogent-issues-bd-ready (lambda (_) nil)
                             (lambda (err) (setq error-msg err)))
      (should (equal "ready failed" error-msg)))))

;;; Create Error Callback

(ert-deftest ogent-issues-bd-test-create-error-callback ()
  "Test create error handling with :error-callback."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd-test-with-error "create failed"
    (let ((error-msg nil))
      (ogent-issues-bd-create "Title"
                              (lambda (_) nil)
                              :error-callback (lambda (err) (setq error-msg err)))
      (should (equal "create failed" error-msg)))))

;;; Cache Key With Nil Project

(ert-deftest ogent-issues-bd-test-cache-key-nil-project ()
  "Test cache key format when project root is nil."
  (cl-letf (((symbol-function 'ogent-issues-bd-project-root)
             (lambda () nil)))
    (let ((key (ogent-issues-bd--cache-key '("list" "--json"))))
      (should (stringp key))
      (should (string-match-p "nil" key)))))

;;; Start/Reopen/Close Invalidation

(ert-deftest ogent-issues-bd-test-start-invalidates-cache ()
  "Test that start invalidates the cache."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd--cache-set '("list" "--json") ogent-issues-bd-test--sample-list)
  (should (ogent-issues-bd--cache-get '("list" "--json")))
  (ogent-issues-bd-test-with-mock "Started"
    (ogent-issues-bd-start "test-abc" (lambda () nil)))
  (should-not (ogent-issues-bd--cache-get '("list" "--json"))))

(ert-deftest ogent-issues-bd-test-sync-invalidates-cache ()
  "Test that sync invalidates the cache."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd--cache-set '("list" "--json") ogent-issues-bd-test--sample-list)
  (should (ogent-issues-bd--cache-get '("list" "--json")))
  (ogent-issues-bd-test-with-mock "Synced"
    (ogent-issues-bd-sync (lambda () nil)))
  (should-not (ogent-issues-bd--cache-get '("list" "--json"))))

(ert-deftest ogent-issues-bd-test-comment-invalidates-cache-2 ()
  "Test that comment invalidates the cache (second test with different data)."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd--cache-set '("show" "test-abc" "--json") ogent-issues-bd-test--sample-issue)
  (should (ogent-issues-bd--cache-get '("show" "test-abc" "--json")))
  (ogent-issues-bd-test-with-mock "Commented"
    (ogent-issues-bd-comment "test-abc" "new note" (lambda () nil)))
  (should-not (ogent-issues-bd--cache-get '("show" "test-abc" "--json"))))

;;; Dep-add Tests

(ert-deftest ogent-issues-bd-test-dep-add ()
  "Test dep-add calls async with correct args."
  (let ((called nil))
    (ogent-issues-bd-test-with-mock "Added"
      (ogent-issues-bd-dep-add "blocked-1" "blocker-1"
                               (lambda () (setq called t)))
      (should called)
      (should (equal (car ogent-issues-bd-test--captured-args)
                     '("dep" "add" "blocked-1" "blocker-1"))))))

(ert-deftest ogent-issues-bd-test-dep-add-invalidates-cache ()
  "Test dep-add invalidates cache."
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-bd--cache-set '("list" "--json") ogent-issues-bd-test--sample-list)
  (should (ogent-issues-bd--cache-get '("list" "--json")))
  (ogent-issues-bd-test-with-mock "Added"
    (ogent-issues-bd-dep-add "blocked-1" "blocker-1" (lambda () nil)))
  (should-not (ogent-issues-bd--cache-get '("list" "--json"))))

(ert-deftest ogent-issues-bd-test-dep-add-no-bd-user-error ()
  "Test dep-add errors when bd not available."
  (let ((ogent-issues-bd-executable nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
      (should-error
       (ogent-issues-bd-dep-add "blocked-1" "blocker-1" (lambda () nil))
       :type 'user-error))))

;;; Git Worktree Redirect Tests

(defmacro ogent-issues-bd-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-issues-bd-wt-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-issues-bd-test--worktree-layout (base &optional gitdir-line
                                                   no-main-beads)
  "Create a fake main checkout and linked worktree under BASE.
Return a plist with :main, :worktree, and :main-beads paths.
GITDIR-LINE overrides the worktree `.git' pointer file contents.
NO-MAIN-BEADS skips creating the main `.beads' directory."
  (let* ((main (expand-file-name "main" base))
         (worktree (expand-file-name "wt" base))
         (main-beads (expand-file-name ".beads" main)))
    (make-directory (expand-file-name ".git/worktrees/wt" main) t)
    (unless no-main-beads
      (make-directory main-beads t)
      (write-region "" nil (expand-file-name "config.yaml" main-beads)
                    nil 'silent))
    (make-directory worktree t)
    (write-region (or gitdir-line
                      (format "gitdir: %s\n"
                              (expand-file-name ".git/worktrees/wt" main)))
                  nil (expand-file-name ".git" worktree) nil 'silent)
    (list :main main :worktree worktree :main-beads main-beads)))

(ert-deftest ogent-issues-bd-worktree-redirect-created ()
  "A redirect pointing at the main beads dir is written in the worktree."
  (ogent-issues-bd-test-with-temp-dir base
    (let* ((layout (ogent-issues-bd-test--worktree-layout base))
           (worktree (plist-get layout :worktree))
           (subdir (expand-file-name "src/deep" worktree)))
      (make-directory subdir t)
      (let ((result (ogent-issues-bd-ensure-worktree-redirect subdir))
            (redirect (expand-file-name ".beads/redirect" worktree)))
        (should (equal result redirect))
        (should (file-exists-p redirect))
        (should (equal (with-temp-buffer
                         (insert-file-contents redirect)
                         (string-trim (buffer-string)))
                       (plist-get layout :main-beads)))))))

(ert-deftest ogent-issues-bd-worktree-redirect-idempotent ()
  "An existing redirect is returned untouched."
  (ogent-issues-bd-test-with-temp-dir base
    (let* ((layout (ogent-issues-bd-test--worktree-layout base))
           (worktree (plist-get layout :worktree))
           (redirect (expand-file-name ".beads/redirect" worktree)))
      (make-directory (expand-file-name ".beads" worktree) t)
      (write-region "/custom/beads\n" nil redirect nil 'silent)
      (should (equal (ogent-issues-bd-ensure-worktree-redirect worktree)
                     redirect))
      (should (equal (with-temp-buffer
                       (insert-file-contents redirect)
                       (buffer-string))
                     "/custom/beads\n")))))

(ert-deftest ogent-issues-bd-worktree-redirect-primary-checkout-nil ()
  "A primary checkout (.git directory) needs no redirect."
  (ogent-issues-bd-test-with-temp-dir base
    (let ((repo (expand-file-name "repo" base)))
      (make-directory (expand-file-name ".git" repo) t)
      (should-not (ogent-issues-bd-ensure-worktree-redirect repo))
      (should-not (file-exists-p
                   (expand-file-name ".beads/redirect" repo))))))

(ert-deftest ogent-issues-bd-worktree-redirect-submodule-nil ()
  "Submodule gitdir pointers must not be treated as worktrees."
  (ogent-issues-bd-test-with-temp-dir base
    (let* ((layout (ogent-issues-bd-test--worktree-layout
                    base
                    (format "gitdir: %s\n"
                            (expand-file-name
                             "main/.git/modules/sub" base))))
           (worktree (plist-get layout :worktree)))
      (should-not (ogent-issues-bd-ensure-worktree-redirect worktree))
      (should-not (file-exists-p
                   (expand-file-name ".beads/redirect" worktree))))))

(ert-deftest ogent-issues-bd-worktree-redirect-no-main-beads-nil ()
  "No redirect is written when the main checkout has no beads dir."
  (ogent-issues-bd-test-with-temp-dir base
    (let* ((layout (ogent-issues-bd-test--worktree-layout base nil t))
           (worktree (plist-get layout :worktree)))
      (should-not (ogent-issues-bd-ensure-worktree-redirect worktree))
      (should-not (file-exists-p
                   (expand-file-name ".beads/redirect" worktree))))))

(ert-deftest ogent-issues-bd-worktree-redirect-relative-gitdir ()
  "Relative gitdir pointers resolve against the worktree root."
  (ogent-issues-bd-test-with-temp-dir base
    (let* ((layout (ogent-issues-bd-test--worktree-layout
                    base "gitdir: ../main/.git/worktrees/wt\n"))
           (worktree (plist-get layout :worktree))
           (redirect (ogent-issues-bd-ensure-worktree-redirect worktree)))
      (should redirect)
      (should (equal (with-temp-buffer
                       (insert-file-contents redirect)
                       (string-trim (buffer-string)))
                     (plist-get layout :main-beads))))))

;;; Org Agenda Projection Tests

(defconst ogent-issues-bd-test--projection-issues
  '((:id "pj-3" :title "Blocked work" :status "blocked" :priority 2
         :issue_type "task" :blocked_by ("pj-1"))
    (:id "pj-1" :title "Open work" :status "open" :priority 0
         :issue_type "bug" :description "Fix the thing.\n* not a headline")
    (:id "pj-2" :title "Active work" :status "in_progress" :priority 3
         :issue_type "feature")
    (:id "pj-4" :title "Done work" :status "closed" :priority 1
         :issue_type "task"))
  "Issues covering each projection status, deliberately unsorted.")

(ert-deftest ogent-issues-bd-agenda-file-honors-customization ()
  "A customized `ogent-issues-agenda-file' is returned verbatim."
  (let ((ogent-issues-agenda-file "/tmp/ogent-custom-beads.org"))
    (should (equal (ogent-issues-bd--agenda-file)
                   "/tmp/ogent-custom-beads.org"))))

(ert-deftest ogent-issues-bd-agenda-file-derives-outside-project ()
  "Derived projection path lives under user-emacs-directory, not the repo."
  (ogent-issues-bd-test-with-temp-dir base
    (let ((ogent-issues-agenda-file nil)
          (user-emacs-directory (file-name-as-directory
                                 (expand-file-name "emacs.d" base)))
          (root (file-name-as-directory (expand-file-name "proj" base))))
      (make-directory root t)
      (cl-letf (((symbol-function 'ogent-issues-bd-project-root)
                 (lambda (&optional _dir) root)))
        (let ((file (ogent-issues-bd--agenda-file)))
          (should (string-prefix-p
                   (expand-file-name "ogent/beads/" user-emacs-directory)
                   file))
          (should (string-match-p "/proj-[0-9a-f]\\{8\\}\\.org\\'" file))
          (should-not (string-prefix-p root file)))))))

(ert-deftest ogent-issues-bd-org-projection-headlines-and-header ()
  "Projection maps statuses to keywords and carries the file header."
  (let ((content (ogent-issues-bd--org-projection
                  ogent-issues-bd-test--projection-issues "/tmp/proj")))
    (should (string-match-p "^#\\+TODO: TODO BLOCKED RUNNING | DONE$" content))
    (should (string-match-p "^#\\+filetags: :ogent_beads:$" content))
    (should (string-match-p "^# Generated by ogent-issues-agenda" content))
    (should (string-match-p "^\\* TODO \\[#A\\] pj-1: Open work$" content))
    (should (string-match-p "^\\* RUNNING \\[#C\\] pj-2: Active work$" content))
    (should (string-match-p "^\\* BLOCKED \\[#B\\] pj-3: Blocked work$" content))))

(ert-deftest ogent-issues-bd-org-projection-omits-closed ()
  "Closed issues never enter the projection."
  (let ((content (ogent-issues-bd--org-projection
                  ogent-issues-bd-test--projection-issues "/tmp/proj")))
    (should-not (string-match-p "pj-4" content))))

(ert-deftest ogent-issues-bd-org-projection-property-drawers ()
  "Each headline carries OGENT_ISSUE_ID/TYPE and BLOCKED_BY when present."
  (let ((content (ogent-issues-bd--org-projection
                  ogent-issues-bd-test--projection-issues "/tmp/proj")))
    (should (string-match-p "^:OGENT_ISSUE_ID: pj-1$" content))
    (should (string-match-p "^:OGENT_ISSUE_TYPE: bug$" content))
    (should (string-match-p "^:OGENT_BLOCKED_BY: pj-1$" content))))

(ert-deftest ogent-issues-bd-org-projection-sort-order ()
  "In-progress issues sort first, then ascending priority."
  (let ((content (ogent-issues-bd--org-projection
                  ogent-issues-bd-test--projection-issues "/tmp/proj")))
    (let ((running (string-match "^\\* RUNNING" content))
          (todo (string-match "^\\* TODO" content))
          (blocked (string-match "^\\* BLOCKED" content)))
      (should (< running todo))
      (should (< todo blocked)))))

(ert-deftest ogent-issues-bd-org-projection-indents-description ()
  "Description bodies are indented two spaces, neutralizing org syntax."
  (let ((content (ogent-issues-bd--org-projection
                  ogent-issues-bd-test--projection-issues "/tmp/proj")))
    (should (string-match-p "^  Fix the thing\\.$" content))
    (should (string-match-p "^  \\* not a headline$" content))
    (should-not (string-match-p "^\\* not a headline$" content))))

;;; Issue Parent Extraction

(defconst ogent-issues-bd-test--parented-issues
  '((:id "pj-child" :title "Child work" :status "open" :priority 1
         :issue_type "task" :parent "pj-parent"
         :dependencies ((:issue_id "pj-child" :depends_on_id "pj-parent"
                                   :type "parent-child"))))
  "Single child issue carrying a parent-child dependency.")

(ert-deftest ogent-issues-bd-issue-parent-prefers-parent-field ()
  "A top-level :parent string wins over dependency entries."
  (should (equal (ogent-issues-bd--issue-parent
                  '(:id "c" :parent "p"
                        :dependencies ((:id "other"
                                            :dependency_type "parent-child"))))
                 "p")))

(ert-deftest ogent-issues-bd-issue-parent-show-shape ()
  "A `br show --json' dependency entry yields the parent via :id."
  (should (equal (ogent-issues-bd--issue-parent
                  '(:id "c" :dependencies
                        ((:id "blocker" :dependency_type "blocks")
                         (:id "p" :dependency_type "parent-child"))))
                 "p")))

(ert-deftest ogent-issues-bd-issue-parent-jsonl-shape ()
  "A JSONL export dependency entry yields the parent via :depends_on_id."
  (should (equal (ogent-issues-bd--issue-parent
                  '(:id "c" :dependencies
                        ((:issue_id "c" :depends_on_id "p"
                                    :type "parent-child"))))
                 "p")))

(ert-deftest ogent-issues-bd-issue-parent-nil-cases ()
  "Parentless issues and non-parent-child dependencies yield nil."
  (should-not (ogent-issues-bd--issue-parent '(:id "c")))
  (should-not (ogent-issues-bd--issue-parent '(:id "c" :parent "")))
  (should-not (ogent-issues-bd--issue-parent
               '(:id "c" :dependencies
                     ((:issue_id "c" :depends_on_id "b" :type "blocks"))))))

(ert-deftest ogent-issues-bd-org-projection-emits-issue-parent ()
  "A child issue's headline carries OGENT_ISSUE_PARENT."
  (let ((content (ogent-issues-bd--org-projection
                  ogent-issues-bd-test--parented-issues "/tmp/proj")))
    (should (string-match-p "^:OGENT_ISSUE_PARENT: pj-parent$" content))))

(ert-deftest ogent-issues-bd-org-projection-omits-issue-parent-when-absent ()
  "Parentless issues emit no OGENT_ISSUE_PARENT property."
  (let ((content (ogent-issues-bd--org-projection
                  ogent-issues-bd-test--projection-issues "/tmp/proj")))
    (should-not (string-match-p "OGENT_ISSUE_PARENT" content))))

(ert-deftest ogent-issues-bd-org-projection-record-metadata-issue-parent ()
  "Projection output round-trips through the armory record reader.
Feeding the generated Org text to `ogent-armory-record-metadata'
yields an issue-link record whose :issue-parent matches the bead's
parent id, closing the OGENT_ISSUE_PARENT writer gap left by the
armory graph work."
  (require 'ogent-armory-store)
  (let ((content (ogent-issues-bd--org-projection
                  ogent-issues-bd-test--parented-issues "/tmp/proj"))
        (real-insert (symbol-function 'insert-file-contents)))
    ;; Serve the projection text for the sentinel path only; org-mode
    ;; setup may lazy-load libraries through the real function.
    (cl-letf (((symbol-function 'insert-file-contents)
               (lambda (file &rest args)
                 (if (equal file "in-memory.org")
                     (progn (insert content) nil)
                   (apply real-insert file args)))))
      (let ((meta (ogent-armory-record-metadata "in-memory.org")))
        (should (eq (plist-get meta :kind) 'issue-link))
        (should (equal (plist-get meta :issue-id) "pj-child"))
        (should (equal (plist-get meta :issue-parent) "pj-parent"))))))

(ert-deftest ogent-issues-agenda-writes-file-and-scopes-agenda ()
  "Command writes the projection file and scopes org-agenda to it."
  (require 'org-agenda)
  (ogent-issues-bd-test-with-temp-dir base
    (let* ((file (expand-file-name "projection/beads.org" base))
           (ogent-issues-agenda-file file)
           (recorded-files 'unset)
           (recorded-keys nil)
           (org-agenda-buffer nil))
      (cl-letf (((symbol-function 'ogent-issues-bd-list)
                 (lambda (callback &optional _filters _error-callback)
                   (funcall callback
                            ogent-issues-bd-test--projection-issues)))
                ((symbol-function 'ogent-issues-bd-project-root)
                 (lambda (&optional _dir) base))
                ((symbol-function 'org-agenda)
                 (lambda (&optional _arg keys _restriction)
                   (setq recorded-keys keys
                         recorded-files org-agenda-files))))
        (ogent-issues-agenda))
      (should (file-exists-p file))
      (should (equal recorded-files (list file)))
      (should (equal recorded-keys "t"))
      (let ((content (with-temp-buffer
                       (insert-file-contents file)
                       (buffer-string))))
        (should (string-match-p
                 "^#\\+TODO: TODO BLOCKED RUNNING | DONE$" content))
        (should (string-match-p "pj-1: Open work" content))))))

(ert-deftest ogent-issues-agenda-sets-buffer-local-agenda-files ()
  "Agenda buffer gets a buffer-local file scope; the global is untouched."
  (require 'org-agenda)
  (ogent-issues-bd-test-with-temp-dir base
    (let* ((file (expand-file-name "beads.org" base))
           (ogent-issues-agenda-file file)
           (buf (generate-new-buffer "*ogent-issues-agenda-test*"))
           (org-agenda-buffer nil))
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'ogent-issues-bd-list)
                       (lambda (callback &optional _filters _error-callback)
                         (funcall callback
                                  ogent-issues-bd-test--projection-issues)))
                      ((symbol-function 'ogent-issues-bd-project-root)
                       (lambda (&optional _dir) base))
                      ((symbol-function 'org-agenda)
                       (lambda (&optional _arg _keys _restriction)
                         (setq org-agenda-buffer buf))))
              (ogent-issues-agenda))
            (should (equal (buffer-local-value 'org-agenda-files buf)
                           (list file)))
            (should-not (equal (default-value 'org-agenda-files)
                               (list file))))
        (kill-buffer buf)))))

(ert-deftest ogent-issues-agenda-messages-br-error ()
  "br failures are reported via `message', not signaled."
  (let ((messages nil))
    (cl-letf (((symbol-function 'ogent-issues-bd-list)
               (lambda (_callback &optional _filters error-callback)
                 (funcall error-callback "br exploded")))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages)
                 nil)))
      (ogent-issues-agenda))
    (should (seq-some (lambda (m) (string-match-p "br exploded" m))
                      messages))))

(provide 'ogent-issues-bd-tests)

;;; ogent-issues-bd-tests.el ends here
