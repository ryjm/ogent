;;; ogent-armory-actions-tests.el --- Tests for Armory action proposals -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for parsing, validating, approving, and dispatching agent proposals.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory)
(require 'ogent-armory-actions)
(require 'ogent-armory-conversations)

(defmacro ogent-armory-actions-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary Armory directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (file-truename
                (make-temp-file "ogent-armory-actions-" t))))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-armory-actions-test--seed (root)
  "Create agents and a parent conversation under ROOT."
  (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
  (ogent-armory-write-agent
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
  (ogent-armory-write-agent
   root
   '(:slug "builder"
     :name "Builder"
     :provider "claude")
   "Build the work.")
  (ogent-armory-conversation-create
   root
   '(:id "parent"
     :agent "lead"
     :title "Parent"
     :status "done")))

(ert-deftest ogent-armory-actions-parse-and-dedupe-proposals ()
  "Action parser handles line proposals, JSON blocks, and duplicates."
  (let* ((text (concat
                "LAUNCH_TASK: builder | Build thing | Make the thing.\n"
                "LAUNCH_TASK: builder | Build thing | Make the thing.\n"
                "SCHEDULE_JOB: builder | Weekly Review | 0 9 * * 1 | Review.\n"
                "#+begin_armory-actions\n"
                "[{\"type\":\"schedule_task\",\"agent\":\"builder\","
                "\"datetime\":\"2026-05-07T09:00:00-0700\","
                "\"title\":\"Check deploy\",\"prompt\":\"Check it.\"}]\n"
                "#+end_armory-actions\n"))
         (actions (ogent-armory-actions-parse text)))
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

(ert-deftest ogent-armory-actions-validate-targets-and-self-launch ()
  "Validation reports invalid targets and flags self-launch proposals."
  (ogent-armory-actions-test-with-temp-dir root
    (ogent-armory-actions-test--seed root)
    (let* ((invalid (car (ogent-armory-actions-validate
                          root
                          (list (list :type 'launch-task
                                      :target-agent "missing"
                                      :title "Nope"
                                      :prompt "Nope."))
                          :triggering-agent "lead")))
           (self (car (ogent-armory-actions-validate
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

(ert-deftest ogent-armory-actions-store-and-read-pending-actions ()
  "Pending actions are stored under the canonical conversation record."
  (ogent-armory-actions-test-with-temp-dir root
    (ogent-armory-actions-test--seed root)
    (let* ((actions (ogent-armory-actions-validate
                     root
                     (ogent-armory-actions-parse
                      "LAUNCH_TASK: builder | Build | Build it.")
                     :triggering-agent "lead"))
           (_ (ogent-armory-actions-store root "parent" actions))
           (stored (ogent-armory-actions-read root "parent")))
      (should (= 1 (length stored)))
      (should (equal (plist-get (car stored) :status) "pending"))
      (should (equal (plist-get (car stored) :target-agent) "builder")))))

(ert-deftest ogent-armory-actions-approval-dispatches-runs-and-jobs ()
  "Approved actions create runner plans and jobs with inherited runtime fields."
  (ogent-armory-actions-test-with-temp-dir root
    (ogent-armory-actions-test--seed root)
    (let* ((actions (ogent-armory-actions-approve-all
                     (ogent-armory-actions-validate
                      root
                      (ogent-armory-actions-parse
                       (concat
                        "LAUNCH_TASK: builder | Build | Build it.\n"
                        "SCHEDULE_JOB: builder | Weekly Review | 0 9 * * 1 | Review."))
                      :triggering-agent "lead")))
           captured)
      (cl-letf (((symbol-function 'ogent-armory-runner-start)
                 (lambda (plan)
                   (push plan captured)
                   :started)))
        (ogent-armory-actions-dispatch
         root "parent" actions :triggering-agent "lead"))
      (let ((job (ogent-armory-read-job root "builder" "weekly-review"))
            (plan (car captured)))
        (should (equal (plist-get job :provider) "codex-cli"))
        (should (equal (plist-get job :model) "gpt-5.4"))
        (should (equal (plist-get plan :adapter-id) "codex-cli"))
        (should (equal (plist-get plan :model) "gpt-5.4"))
        (should (equal (plist-get plan :effort) "high"))
        (should (equal (plist-get plan :parent-task) "parent"))))))

(provide 'ogent-armory-actions-tests)

;;; ogent-armory-actions-tests.el ends here
