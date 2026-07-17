;;; ogent-armory-cache-tests.el --- Tests for Armory stamp cache -*- lexical-binding: t; -*-

;;; Commentary:
;; Focused behavioral tests for `ogent-armory-cache'.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-armory-cache)

(defmacro ogent-armory-cache-test-with-temp-root (var &rest body)
  "Bind VAR to a temporary Armory root while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (ogent-test--provision-store-directory 'armory-cache))
         (ogent-armory-cache--table (make-hash-table :test 'equal)))
     ,@body))

(defun ogent-armory-cache-test--time (seconds)
  "Return a deterministic file timestamp SECONDS after the Unix epoch."
  (seconds-to-time seconds))

(defun ogent-armory-cache-test--write-file (root relative contents &optional mtime)
  "Write CONTENTS under ROOT at RELATIVE, optionally setting MTIME."
  (let ((file (expand-file-name relative root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert contents))
    (when mtime
      (set-file-times file mtime))
    file))

(ert-deftest ogent-armory-cache-hit-reuses-builder-value-while-stamp-unchanged ()
  "An unchanged stamp returns the previously built value without rerunning BUILDER."
  (ogent-armory-cache-test-with-temp-root root
    (ogent-armory-cache-test--write-file
     root "index.org" "#+title: Cache Test\n"
     (ogent-armory-cache-test--time 1700000000))
    (let ((calls 0))
      (let* ((builder (lambda ()
                        (setq calls (1+ calls))
                        (list :build calls)))
             (first (ogent-armory-cache-get root 'graph builder))
             (second (ogent-armory-cache-get root 'graph builder)))
        (should (= calls 1))
        (should (equal first '(:build 1)))
        (should (eq second first))))))

(ert-deftest ogent-armory-cache-force-rebuilds-despite-unchanged-stamp ()
  "FORCE bypasses a fresh entry and stores the rebuilt value."
  (ogent-armory-cache-test-with-temp-root root
    (ogent-armory-cache-test--write-file
     root "agents/editor/persona.org" "#+title: Editor\n"
     (ogent-armory-cache-test--time 1700000000))
    (let ((calls 0))
      (let* ((builder (lambda ()
                        (setq calls (1+ calls))
                        (list :build calls)))
             (first (ogent-armory-cache-get root 'sessions builder))
             (forced (ogent-armory-cache-get root 'sessions builder t))
             (after-force (ogent-armory-cache-get root 'sessions builder)))
        (should (= calls 2))
        (should (equal first '(:build 1)))
        (should (equal forced '(:build 2)))
        (should (eq after-force forced))))))

(ert-deftest ogent-armory-cache-rebuilds-when-relevant-files-change ()
  "Changing a relevant mtime or adding a relevant app index invalidates the entry."
  (ogent-armory-cache-test-with-temp-root root
    (let ((session-file
           (ogent-armory-cache-test--write-file
            root ".agents/editor/sessions/one.org" "#+title: One\n"
            (ogent-armory-cache-test--time 1700000000)))
          (calls 0))
      (let ((builder (lambda ()
                       (setq calls (1+ calls))
                       (list :build calls))))
        (let ((first (ogent-armory-cache-get root 'sessions builder)))
          (set-file-times session-file
                          (ogent-armory-cache-test--time 1700000100))
          (let ((after-touch (ogent-armory-cache-get root 'sessions builder)))
            (should (= calls 2))
            (should-not (eq after-touch first))
            (should (equal after-touch '(:build 2)))
            (should (eq (ogent-armory-cache-get root 'sessions builder)
                        after-touch))
            (ogent-armory-cache-test--write-file
             root "apps/demo/index.html" "<main>Demo</main>\n"
             (ogent-armory-cache-test--time 1700000200))
            (let ((after-add (ogent-armory-cache-get root 'sessions builder)))
              (should (= calls 3))
              (should (equal after-add '(:build 3))))))))))

(ert-deftest ogent-armory-cache-invalidate-clears-only-the-requested-root ()
  "Invalidating one root leaves other roots' entries fresh."
  (let ((root-a (ogent-test--provision-store-directory 'armory-cache))
        (root-b (ogent-test--provision-store-directory 'armory-cache))
        (ogent-armory-cache--table (make-hash-table :test 'equal)))
    (ogent-armory-cache-test--write-file
     root-a "index.org" "#+title: A\n"
     (ogent-armory-cache-test--time 1700000000))
    (ogent-armory-cache-test--write-file
     root-b "index.org" "#+title: B\n"
     (ogent-armory-cache-test--time 1700000000))
    (let ((calls-a 0)
          (calls-b 0))
      (let* ((builder-a (lambda ()
                          (setq calls-a (1+ calls-a))
                          (list :root 'a :build calls-a)))
             (builder-b (lambda ()
                          (setq calls-b (1+ calls-b))
                          (list :root 'b :build calls-b)))
             (a1 (ogent-armory-cache-get root-a 'graph builder-a))
             (b1 (ogent-armory-cache-get root-b 'graph builder-b)))
        (ogent-armory-cache-invalidate root-a)
        (let ((a2 (ogent-armory-cache-get root-a 'graph builder-a))
              (b2 (ogent-armory-cache-get root-b 'graph builder-b)))
          (should (= calls-a 2))
          (should (= calls-b 1))
          (should (equal a1 '(:root a :build 1)))
          (should (equal a2 '(:root a :build 2)))
          (should (eq b2 b1)))))))

(ert-deftest ogent-armory-cache-missing-root-bypasses-cache ()
  "A missing ROOT has no stamp, so every lookup calls BUILDER."
  (ogent-armory-cache-test-with-temp-root parent
    (let ((missing-root (expand-file-name "missing" parent))
          (calls 0))
      (let* ((builder (lambda ()
                        (setq calls (1+ calls))
                        (list :build calls)))
             (first (ogent-armory-cache-get missing-root 'graph builder))
             (second (ogent-armory-cache-get missing-root 'graph builder)))
        (should (= calls 2))
        (should (equal first '(:build 1)))
        (should (equal second '(:build 2)))))))

(provide 'ogent-armory-cache-tests)
;;; ogent-armory-cache-tests.el ends here
