;;; ogent-cabinet-schedule-tests.el --- Tests for Cabinet schedules -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for cron expansion, missed-run detection, one-shot scheduled tasks,
;; and Org agenda bridging.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-cabinet)
(require 'ogent-cabinet-conversations)
(require 'ogent-cabinet-schedule)
(require 'org)
(require 'seq)

(defmacro ogent-cabinet-schedule-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-cabinet-schedule-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-cabinet-schedule-test--time (year month day hour minute)
  "Return local time for YEAR, MONTH, DAY, HOUR, and MINUTE."
  (encode-time 0 minute hour day month year))

(defun ogent-cabinet-schedule-test--make-agent (root)
  "Create the schedule test agent under ROOT."
  (ogent-cabinet-write-agent
   root
   '(:slug "cto"
     :name "CTO"
     :role "Architecture"
     :provider "codex"
     :workspace "/"
     :heartbeat "0 10 * * 1-5"
     :active t)
   "Keep the architecture honest."))

(defun ogent-cabinet-schedule-test--events-by-source (events source-type)
  "Return EVENTS whose source type is SOURCE-TYPE."
  (seq-filter
   (lambda (event)
     (eq (plist-get event :source-type) source-type))
   events))

(ert-deftest ogent-cabinet-schedule-expands-cron-and-heartbeats ()
  "Schedule data expands jobs and agent heartbeats over fixed ranges."
  (ogent-cabinet-schedule-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-schedule-test--make-agent root)
    (ogent-cabinet-write-job
     root "cto"
     '(:id "daily-review"
       :name "Daily Review"
       :cron "0 9 * * *"
       :enabled t)
     "Review current work.")
    (let* ((start (ogent-cabinet-schedule-test--time 2026 5 4 0 0))
           (end (ogent-cabinet-schedule-test--time 2026 5 7 0 0))
           (events (ogent-cabinet-schedule-events
                    root start end :now start))
           (jobs (ogent-cabinet-schedule-test--events-by-source events 'job))
           (heartbeats (ogent-cabinet-schedule-test--events-by-source
                        events 'heartbeat)))
      (should (equal (mapcar (lambda (event)
                               (plist-get event :minute-iso))
                             jobs)
                     '("2026-05-04T09:00"
                       "2026-05-05T09:00"
                       "2026-05-06T09:00")))
      (should (equal (mapcar (lambda (event)
                               (plist-get event :minute-iso))
                             heartbeats)
                     '("2026-05-04T10:00"
                       "2026-05-05T10:00"
                       "2026-05-06T10:00")))
      (should (equal (plist-get (car jobs) :schedule-key)
                     "cto::job::daily-review::2026-05-04T09:00")))))

(ert-deftest ogent-cabinet-schedule-expands-sunday-cron-ranges ()
  "Day-of-week cron ranges can include Sunday as 7."
  (ogent-cabinet-schedule-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     root
     '(:slug "ops"
       :name "Ops"
       :role "Operations"
       :provider "codex"
       :workspace "/"
       :active t)
     "Watch operations.")
    (ogent-cabinet-write-job
     root "ops"
     '(:id "weekend-watch"
       :name "Weekend Watch"
       :cron "0 9 * * 5-7"
       :enabled t)
     "Check weekend work.")
    (let* ((start (ogent-cabinet-schedule-test--time 2026 5 8 0 0))
           (end (ogent-cabinet-schedule-test--time 2026 5 11 0 0))
           (events (ogent-cabinet-schedule-events root start end :now start))
           (jobs (ogent-cabinet-schedule-test--events-by-source
                  events
                  'job)))
      (should (equal (mapcar (lambda (event)
                               (plist-get event :minute-iso))
                             jobs)
                     '("2026-05-08T09:00"
                       "2026-05-09T09:00"
                       "2026-05-10T09:00"))))))

(ert-deftest ogent-cabinet-schedule-marks-missed-and-linked-runs ()
  "Past schedule slots are missed until a conversation owns the stable key."
  (ogent-cabinet-schedule-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-schedule-test--make-agent root)
    (ogent-cabinet-write-job
     root "cto"
     '(:id "daily-review"
       :name "Daily Review"
       :cron "0 9 * * *"
       :enabled t)
     "Review current work.")
    (let* ((slot (ogent-cabinet-schedule-test--time 2026 5 4 9 0))
           (start (ogent-cabinet-schedule-test--time 2026 5 4 0 0))
           (end (ogent-cabinet-schedule-test--time 2026 5 5 0 0))
           (now (ogent-cabinet-schedule-test--time 2026 5 4 12 0))
           (key (ogent-cabinet-schedule-key "cto" 'job "daily-review" slot))
           (missing (car (ogent-cabinet-schedule-events
                          root start end :now now))))
      (should (eq (plist-get missing :state) 'missed))
      (should-not (plist-get missing :conversation-id))
      (ogent-cabinet-conversation-create
       root
       (list :id "daily-run"
             :agent "cto"
             :title "Daily Review"
             :trigger "job"
             :status "done"
             :job-id "daily-review"
             :job-name "Daily Review"
             :scheduled-at "2026-05-04T09:00"
             :scheduled-key key
             :started "2026-05-04T09:00"
             :completed "2026-05-04T09:12"
             :last-activity "2026-05-04T09:12"))
      (let ((linked (car (ogent-cabinet-schedule-events
                          root start end :now now))))
        (should (eq (plist-get linked :state) 'done))
        (should (equal (plist-get linked :conversation-id) "daily-run"))
        (should (string-match-p ".agents/.conversations/daily-run/index.org"
                                (plist-get linked :conversation-path)))))))

(ert-deftest ogent-cabinet-schedule-expands-one-shot-run-after-tasks ()
  "One-shot jobs with OGENT_RUN_AFTER create task schedule events."
  (ogent-cabinet-schedule-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-schedule-test--make-agent root)
    (ogent-cabinet-write-job
     root "cto"
     '(:id "launch-plan"
       :name "Launch Plan"
       :run-after "2026-05-04T11:30"
       :owner-task "task-42"
       :enabled t)
     "Prepare the launch plan.")
    (let* ((start (ogent-cabinet-schedule-test--time 2026 5 4 0 0))
           (end (ogent-cabinet-schedule-test--time 2026 5 5 0 0))
           (events (ogent-cabinet-schedule-events root start end :now start))
           (event (car (ogent-cabinet-schedule-test--events-by-source
                        events
                        'task))))
      (should (eq (plist-get event :source-type) 'task))
      (should (equal (plist-get event :source-id) "launch-plan"))
      (should (equal (plist-get event :owner-task) "task-42"))
      (should (equal (plist-get event :minute-iso) "2026-05-04T11:30"))
      (should (equal (plist-get event :schedule-key)
                     "cto::task::launch-plan::2026-05-04T11:30"))
      (let ((job (ogent-cabinet-read-job root "cto" "launch-plan")))
        (should (equal (plist-get job :run-after) "2026-05-04T11:30"))
        (should (equal (plist-get job :owner-task) "task-42"))))))

(ert-deftest ogent-cabinet-schedule-agenda-files-cover-visible-org-records ()
  "Agenda files include root, agent, schedule, inbox, and job Org files."
  (ogent-cabinet-schedule-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-schedule-test--make-agent root)
    (ogent-cabinet-write-job
     root "cto"
     '(:id "daily-review"
       :name "Daily Review"
       :cron "0 9 * * *"
       :enabled t)
     "Review current work.")
    (let ((files (mapcar #'file-truename
                         (ogent-cabinet-agenda-files root))))
      (should (member (file-truename (ogent-cabinet-index-file root)) files))
      (should (member (file-truename (ogent-cabinet-agent-file root "cto"))
                      files))
      (should (member (file-truename (ogent-cabinet-agent-inbox-file
                                      root
                                      "cto"))
                      files))
      (should (member (file-truename (ogent-cabinet-agent-schedule-file
                                      root
                                      "cto"))
                      files))
      (should (member (file-truename (ogent-cabinet-job-file
                                      root
                                      "cto"
                                      "daily-review"))
                      files))
      (ogent-cabinet-with-agenda-files root
        (should (equal (mapcar #'file-truename org-agenda-files) files))))))

(ert-deftest ogent-cabinet-schedule-buffer-switches-day-week-month ()
  "The schedule buffer can render day, week, and month ranges."
  (ogent-cabinet-schedule-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-schedule-test--make-agent root)
    (ogent-cabinet-write-job
     root "cto"
     '(:id "daily-review"
       :name "Daily Review"
       :cron "0 9 * * *"
       :enabled t)
     "Review current work.")
    (let* ((date (ogent-cabinet-schedule-test--time 2026 5 4 12 0))
           (buffer (ogent-cabinet-schedule
                    root :view 'day :date date :now date)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq ogent-cabinet-schedule--view 'day))
            (should (string-match-p
                     "Daily Review"
                     (buffer-substring-no-properties
                      (point-min)
                      (point-max))))
            (ogent-cabinet-schedule-week-view)
            (should (eq ogent-cabinet-schedule--view 'week))
            (ogent-cabinet-schedule-month-view)
            (should (eq ogent-cabinet-schedule--view 'month)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(provide 'ogent-cabinet-schedule-tests)

;;; ogent-cabinet-schedule-tests.el ends here
