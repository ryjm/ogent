;;; ogent-cabinet-actions-tests.el --- Tests for Cabinet action proposals -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for parsing, validating, approving, and dispatching agent proposals.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-cabinet)
(require 'ogent-cabinet-actions)
(require 'ogent-cabinet-conversations)

(defmacro ogent-cabinet-actions-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary Cabinet directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (file-truename
                (make-temp-file "ogent-cabinet-actions-" t))))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-cabinet-actions-test--seed (root)
  "Create agents and a parent conversation under ROOT."
  (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
  (ogent-cabinet-write-agent
   root
   '(:slug "lead"
     :name "Lead"
     :type "lead"
     :can-dispatch t
     :provider "codex-cli"
     :model "gpt-5.4"
     :effort "high"
     :runtime-mode "terminal")
   "Lead the work.")
  (ogent-cabinet-write-agent
   root
   '(:slug "builder"
     :name "Builder"
     :provider "claude")
   "Build the work.")
  (ogent-cabinet-conversation-create
   root
   '(:id "parent"
     :agent "lead"
     :title "Parent"
     :status "done")))

(ert-deftest ogent-cabinet-actions-parse-and-dedupe-proposals ()
  "Action parser handles line proposals, JSON blocks, and duplicates."
  (let* ((text (concat
                "LAUNCH_TASK: builder | Build thing | Make the thing.\n"
                "LAUNCH_TASK: builder | Build thing | Make the thing.\n"
                "SCHEDULE_JOB: builder | Weekly Review | 0 9 * * 1 | Review.\n"
                "#+begin_cabinet-actions\n"
                "[{\"type\":\"schedule_task\",\"agent\":\"builder\","
                "\"datetime\":\"2026-05-07T09:00:00-0700\","
                "\"title\":\"Check deploy\",\"prompt\":\"Check it.\"}]\n"
                "#+end_cabinet-actions\n"))
         (actions (ogent-cabinet-actions-parse text)))
    (should (= 3 (length actions)))
    (should (seq-find (lambda (action)
                        (eq (plist-get action :type) 'launch-task))
                      actions))
    (should (seq-find (lambda (action)
                        (eq (plist-get action :type) 'schedule-job))
                      actions))
    (should (seq-find (lambda (action)
                        (eq (plist-get action :type) 'schedule-task))
                      actions))))

(ert-deftest ogent-cabinet-actions-validate-targets-and-self-launch ()
  "Validation reports invalid targets and flags self-launch proposals."
  (ogent-cabinet-actions-test-with-temp-dir root
    (ogent-cabinet-actions-test--seed root)
    (let* ((invalid (car (ogent-cabinet-actions-validate
                          root
                          (list (list :type 'launch-task
                                      :target-agent "missing"
                                      :title "Nope"
                                      :prompt "Nope."))
                          :triggering-agent "lead")))
           (self (car (ogent-cabinet-actions-validate
                       root
                       (list (list :type 'launch-task
                                   :target-agent "lead"
                                   :title "Loop"
                                   :prompt "Do it."))
                       :triggering-agent "lead"))))
      (should-not (plist-get invalid :valid))
      (should (string-match-p "Target agent not found"
                              (car (plist-get invalid :errors))))
      (should (plist-get self :valid))
      (should (member "Self-launch proposal" (plist-get self :warnings))))))

(ert-deftest ogent-cabinet-actions-store-and-read-pending-actions ()
  "Pending actions are stored under the canonical conversation record."
  (ogent-cabinet-actions-test-with-temp-dir root
    (ogent-cabinet-actions-test--seed root)
    (let* ((actions (ogent-cabinet-actions-validate
                     root
                     (ogent-cabinet-actions-parse
                      "LAUNCH_TASK: builder | Build | Build it.")
                     :triggering-agent "lead"))
           (_ (ogent-cabinet-actions-store root "parent" actions))
           (stored (ogent-cabinet-actions-read root "parent")))
      (should (= 1 (length stored)))
      (should (equal (plist-get (car stored) :status) "pending"))
      (should (equal (plist-get (car stored) :target-agent) "builder")))))

(ert-deftest ogent-cabinet-actions-approval-dispatches-runs-and-jobs ()
  "Approved actions create runner plans and jobs with inherited runtime fields."
  (ogent-cabinet-actions-test-with-temp-dir root
    (ogent-cabinet-actions-test--seed root)
    (let* ((actions (ogent-cabinet-actions-approve-all
                     (ogent-cabinet-actions-validate
                      root
                      (ogent-cabinet-actions-parse
                       (concat
                        "LAUNCH_TASK: builder | Build | Build it.\n"
                        "SCHEDULE_JOB: builder | Weekly Review | 0 9 * * 1 | Review."))
                      :triggering-agent "lead")))
           captured)
      (cl-letf (((symbol-function 'ogent-cabinet-runner-start)
                 (lambda (plan)
                   (push plan captured)
                   :started)))
        (ogent-cabinet-actions-dispatch
         root "parent" actions :triggering-agent "lead"))
      (let ((job (ogent-cabinet-read-job root "builder" "weekly-review"))
            (plan (car captured)))
        (should (equal (plist-get job :provider) "codex-cli"))
        (should (equal (plist-get job :model) "gpt-5.4"))
        (should (equal (plist-get plan :adapter-id) "codex-cli"))
        (should (equal (plist-get plan :model) "gpt-5.4"))
        (should (equal (plist-get plan :effort) "high"))
        (should (equal (plist-get plan :parent-task) "parent"))))))

(provide 'ogent-cabinet-actions-tests)

;;; ogent-cabinet-actions-tests.el ends here
