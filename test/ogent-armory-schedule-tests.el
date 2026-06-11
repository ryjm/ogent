;;; ogent-armory-schedule-tests.el --- Tests for Armory schedules -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for cron expansion, missed-run detection, one-shot scheduled tasks,
;; and Org agenda bridging.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory)
(require 'ogent-armory-conversations)
(require 'ogent-armory-schedule)
(require 'org)
(require 'seq)

(defmacro ogent-armory-schedule-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-armory-schedule-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-armory-schedule-test--time (year month day hour minute)
  "Return local time for YEAR, MONTH, DAY, HOUR, and MINUTE."
  (encode-time 0 minute hour day month year))

(defun ogent-armory-schedule-test--make-agent (root)
  "Create the schedule test agent under ROOT."
  (ogent-armory-write-agent
   root
   '(:slug "cto"
     :name "CTO"
     :role "Architecture"
     :provider "codex"
     :workspace "/"
     :heartbeat "0 10 * * 1-5"
     :active t)
   "Keep the architecture honest."))

(defun ogent-armory-schedule-test--events-by-source (events source-type)
  "Return EVENTS whose source type is SOURCE-TYPE."
  (seq-filter
   (lambda (event)
     (eq (plist-get event :source-type) source-type))
   events))

(ert-deftest ogent-armory-schedule-expands-cron-and-heartbeats ()
  "Schedule data expands jobs and agent heartbeats over fixed ranges."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-schedule-test--make-agent root)
    (ogent-armory-write-job
     root "cto"
     '(:id "daily-review"
       :name "Daily Review"
       :cron "0 9 * * *"
       :enabled t)
     "Review current work.")
    (let* ((start (ogent-armory-schedule-test--time 2026 5 4 0 0))
           (end (ogent-armory-schedule-test--time 2026 5 7 0 0))
           (events (ogent-armory-schedule-events
                    root start end :now start))
           (jobs (ogent-armory-schedule-test--events-by-source events 'job))
           (heartbeats (ogent-armory-schedule-test--events-by-source
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

(ert-deftest ogent-armory-schedule-expands-sunday-cron-ranges ()
  "Day-of-week cron ranges can include Sunday as 7."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "ops"
       :name "Ops"
       :role "Operations"
       :provider "codex"
       :workspace "/"
       :active t)
     "Watch operations.")
    (ogent-armory-write-job
     root "ops"
     '(:id "weekend-watch"
       :name "Weekend Watch"
       :cron "0 9 * * 5-7"
       :enabled t)
     "Check weekend work.")
    (let* ((start (ogent-armory-schedule-test--time 2026 5 8 0 0))
           (end (ogent-armory-schedule-test--time 2026 5 11 0 0))
           (events (ogent-armory-schedule-events root start end :now start))
           (jobs (ogent-armory-schedule-test--events-by-source
                  events
                  'job)))
      (should (equal (mapcar (lambda (event)
                               (plist-get event :minute-iso))
                             jobs)
                     '("2026-05-08T09:00"
                       "2026-05-09T09:00"
                       "2026-05-10T09:00"))))))

(ert-deftest ogent-armory-schedule-marks-missed-and-linked-runs ()
  "Past schedule slots are missed until a conversation owns the stable key."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-schedule-test--make-agent root)
    (ogent-armory-write-job
     root "cto"
     '(:id "daily-review"
       :name "Daily Review"
       :cron "0 9 * * *"
       :enabled t)
     "Review current work.")
    (let* ((slot (ogent-armory-schedule-test--time 2026 5 4 9 0))
           (start (ogent-armory-schedule-test--time 2026 5 4 0 0))
           (end (ogent-armory-schedule-test--time 2026 5 5 0 0))
           (now (ogent-armory-schedule-test--time 2026 5 4 12 0))
           (key (ogent-armory-schedule-key "cto" 'job "daily-review" slot))
           (missing (car (ogent-armory-schedule-events
                          root start end :now now))))
      (should (eq (plist-get missing :state) 'missed))
      (should-not (plist-get missing :conversation-id))
      (ogent-armory-conversation-create
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
      (let ((linked (car (ogent-armory-schedule-events
                          root start end :now now))))
        (should (eq (plist-get linked :state) 'done))
        (should (equal (plist-get linked :conversation-id) "daily-run"))
        (should (string-match-p ".agents/.conversations/daily-run/index.org"
                                (plist-get linked :conversation-path)))))))

(ert-deftest ogent-armory-schedule-expands-one-shot-run-after-tasks ()
  "One-shot jobs with OGENT_RUN_AFTER create task schedule events."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-schedule-test--make-agent root)
    (ogent-armory-write-job
     root "cto"
     '(:id "launch-plan"
       :name "Launch Plan"
       :run-after "2026-05-04T11:30"
       :owner-task "task-42"
       :enabled t)
     "Prepare the launch plan.")
    (let* ((start (ogent-armory-schedule-test--time 2026 5 4 0 0))
           (end (ogent-armory-schedule-test--time 2026 5 5 0 0))
           (events (ogent-armory-schedule-events root start end :now start))
           (event (car (ogent-armory-schedule-test--events-by-source
                        events
                        'task))))
      (should (eq (plist-get event :source-type) 'task))
      (should (equal (plist-get event :source-id) "launch-plan"))
      (should (equal (plist-get event :owner-task) "task-42"))
      (should (equal (plist-get event :minute-iso) "2026-05-04T11:30"))
      (should (equal (plist-get event :schedule-key)
                     "cto::task::launch-plan::2026-05-04T11:30"))
      (let ((job (ogent-armory-read-job root "cto" "launch-plan")))
        (should (equal (plist-get job :run-after) "2026-05-04T11:30"))
        (should (equal (plist-get job :owner-task) "task-42"))))))

(ert-deftest ogent-armory-schedule-agenda-files-cover-visible-org-records ()
  "Agenda files include root, agent, schedule, inbox, and job Org files."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-schedule-test--make-agent root)
    (ogent-armory-write-job
     root "cto"
     '(:id "daily-review"
       :name "Daily Review"
       :cron "0 9 * * *"
       :enabled t)
     "Review current work.")
    (let ((files (mapcar #'file-truename
                         (ogent-armory-agenda-files root))))
      (should (member (file-truename (ogent-armory-index-file root)) files))
      (should (member (file-truename (ogent-armory-agent-file root "cto"))
                      files))
      (should (member (file-truename (ogent-armory-agent-inbox-file
                                      root
                                      "cto"))
                      files))
      (should (member (file-truename (ogent-armory-agent-schedule-file
                                      root
                                      "cto"))
                      files))
      (should (member (file-truename (ogent-armory-job-file
                                      root
                                      "cto"
                                      "daily-review"))
                      files))
      (ogent-armory-with-agenda-files root
        (should (equal (mapcar #'file-truename org-agenda-files) files))))))

(ert-deftest ogent-armory-schedule-buffer-switches-day-week-month ()
  "The schedule buffer can render day, week, and month ranges."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-schedule-test--make-agent root)
    (ogent-armory-write-job
     root "cto"
     '(:id "daily-review"
       :name "Daily Review"
       :cron "0 9 * * *"
       :enabled t)
     "Review current work.")
    (let* ((date (ogent-armory-schedule-test--time 2026 5 4 12 0))
           (buffer (ogent-armory-schedule
                    root :view 'day :date date :now date)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq ogent-armory-schedule--view 'day))
            (should (string-match-p
                     "Daily Review"
                     (buffer-substring-no-properties
                      (point-min)
                      (point-max))))
            (ogent-armory-schedule-week-view)
            (should (eq ogent-armory-schedule--view 'week))
            (ogent-armory-schedule-month-view)
            (should (eq ogent-armory-schedule--view 'month)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(defmacro ogent-armory-schedule-tests--with-scheduler (root calls &rest body)
  "Run BODY with scheduler state reset, watching ROOT, runner stubbed.
CALLS is bound to a list collecting `ogent-armory-runner-plan'
keyword arguments, newest first."
  (declare (indent 2) (debug t))
  `(let ((ogent-armory-scheduler-roots (list ,root))
         (ogent-armory-scheduler--last-tick nil)
         (ogent-armory-scheduler--fired (make-hash-table :test 'equal))
         (ogent-armory-scheduler-auto-run t)
         (ogent-armory-scheduler-catchup-window 300)
         (,calls nil))
     (cl-letf (((symbol-function 'ogent-armory-runner-plan)
                (lambda (directory agent &rest kwargs)
                  (push (append (list :directory directory :agent agent)
                                kwargs)
                        ,calls)
                  (list :provider "stub" :agent agent)))
               ((symbol-function 'ogent-armory-runner-start)
                (lambda (_plan) nil)))
       ,@body)))

(defun ogent-armory-schedule-tests--scheduler-job (root)
  "Scaffold ROOT with the test agent and a 9am cron job."
  (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
  (ogent-armory-schedule-test--make-agent root)
  (ogent-armory-write-job
   root "cto"
   '(:id "daily-review"
     :name "Daily Review"
     :cron "0 9 * * *"
     :enabled t)
   "Review current work."))

(ert-deftest ogent-armory-schedule-scheduler-fires-due-cron-job ()
  "The scheduler arms on the first tick and fires due cron slots after."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-schedule-tests--scheduler-job root)
    (ogent-armory-schedule-tests--with-scheduler root calls
      (let ((arm (ogent-armory-schedule-test--time 2026 5 4 8 59))
            (tick (ogent-armory-schedule-test--time 2026 5 4 9 1)))
        (should-not (ogent-armory-scheduler-tick arm))
        (should-not calls)
        (let ((fired (ogent-armory-scheduler-tick tick)))
          (should (= (length fired) 1))
          (should (= (length calls) 1))
          (let ((call (car calls)))
            (should (equal (plist-get call :job-id) "daily-review"))
            (should (equal (plist-get call :scheduled-key)
                           "cto::job::daily-review::2026-05-04T09:00"))
            (should (equal (plist-get call :scheduled-key)
                           (plist-get (car fired) :schedule-key)))))))))

(ert-deftest ogent-armory-schedule-scheduler-dedups-fired-slots ()
  "A slot already fired in this session never fires twice."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-schedule-tests--scheduler-job root)
    (ogent-armory-schedule-tests--with-scheduler root calls
      (let ((arm (ogent-armory-schedule-test--time 2026 5 4 8 59))
            (tick (ogent-armory-schedule-test--time 2026 5 4 9 1)))
        (ogent-armory-scheduler-tick arm)
        (should (= (length (ogent-armory-scheduler-tick tick)) 1))
        (setq ogent-armory-scheduler--last-tick arm)
        (should-not (ogent-armory-scheduler-tick tick))
        (should (= (length calls) 1))))))

(ert-deftest ogent-armory-schedule-scheduler-skips-claimed-slots ()
  "Slots already claimed by a conversation are done, never fired."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-schedule-tests--scheduler-job root)
    (let* ((slot (ogent-armory-schedule-test--time 2026 5 4 9 0))
           (key (ogent-armory-schedule-key "cto" 'job "daily-review" slot)))
      (ogent-armory-conversation-create
       root
       (list :id "daily-run"
             :agent "cto"
             :title "Daily Review"
             :trigger "job"
             :status "done"
             :job-id "daily-review"
             :scheduled-at "2026-05-04T09:00"
             :scheduled-key key
             :started "2026-05-04T09:00"
             :completed "2026-05-04T09:12"
             :last-activity "2026-05-04T09:12"))
      (ogent-armory-schedule-tests--with-scheduler root calls
        (ogent-armory-scheduler-tick
         (ogent-armory-schedule-test--time 2026 5 4 8 59))
        (should-not (ogent-armory-scheduler-tick
                     (ogent-armory-schedule-test--time 2026 5 4 9 1)))
        (should-not calls)))))

(ert-deftest ogent-armory-schedule-scheduler-respects-auto-run-gate ()
  "With auto-run disabled due events are announced, never run."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-schedule-tests--scheduler-job root)
    (ogent-armory-schedule-tests--with-scheduler root calls
      (let ((ogent-armory-scheduler-auto-run nil))
        (ogent-armory-scheduler-tick
         (ogent-armory-schedule-test--time 2026 5 4 8 59))
        (let ((fired (ogent-armory-scheduler-tick
                      (ogent-armory-schedule-test--time 2026 5 4 9 1))))
          (should (= (length fired) 1))
          (should (equal (plist-get (car fired) :schedule-key)
                         "cto::job::daily-review::2026-05-04T09:00"))
          (should-not calls))))))

(ert-deftest ogent-armory-schedule-scheduler-floors-window-at-catchup ()
  "Events older than the catch-up window stay manual."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-schedule-test--make-agent root)
    (ogent-armory-write-job
     root "cto"
     '(:id "every-minute"
       :name "Every Minute"
       :cron "* * * * *"
       :enabled t)
     "Tick often.")
    (ogent-armory-schedule-tests--with-scheduler root calls
      (setq ogent-armory-scheduler--last-tick
            (ogent-armory-schedule-test--time 2026 5 4 10 0))
      (let ((fired (ogent-armory-scheduler-tick
                    (ogent-armory-schedule-test--time 2026 5 4 12 0))))
        (should (equal (mapcar (lambda (event)
                                 (plist-get event :minute-iso))
                               fired)
                       '("2026-05-04T11:55"
                         "2026-05-04T11:56"
                         "2026-05-04T11:57"
                         "2026-05-04T11:58"
                         "2026-05-04T11:59")))
        (should (= (length calls) 5))))))

(ert-deftest ogent-armory-schedule-scheduler-fires-heartbeat-instruction ()
  "Heartbeat events plan with an instruction and heartbeat trigger."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "pulse"
       :name "Pulse"
       :role "Operations"
       :provider "codex"
       :workspace "/"
       :heartbeat "* * * * *"
       :active t)
     "Stay responsive.")
    (ogent-armory-schedule-tests--with-scheduler root calls
      (ogent-armory-scheduler-tick
       (ogent-armory-schedule-test--time 2026 5 4 9 0))
      (should (= (length (ogent-armory-scheduler-tick
                          (ogent-armory-schedule-test--time 2026 5 4 9 1)))
                 1))
      (let ((call (car calls)))
        (should-not (plist-get call :job-id))
        (should (stringp (plist-get call :instruction)))
        (should (equal (plist-get call :trigger) "heartbeat"))))))

(ert-deftest ogent-armory-schedule-scheduler-mode-manages-timer ()
  "Enabling the scheduler mode arms a timer; disabling cancels it."
  (unwind-protect
      (progn
        (ogent-armory-scheduler-mode 1)
        (should (timerp ogent-armory-scheduler--timer))
        (should (memq ogent-armory-scheduler--timer timer-list))
        (let ((timer ogent-armory-scheduler--timer))
          (ogent-armory-scheduler-mode -1)
          (should-not ogent-armory-scheduler--timer)
          (should-not (memq timer timer-list))))
    (when ogent-armory-scheduler-mode
      (ogent-armory-scheduler-mode -1))))

(ert-deftest ogent-armory-schedule-agenda-keeps-scope-buffer-locally ()
  "Armory agenda installs its file set buffer-locally for redo."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-schedule-test--make-agent root)
    (let ((buffer (generate-new-buffer " *ogent-agenda-test*"))
          (global-files org-agenda-files)
          (org-agenda-buffer nil)
          captured)
      (unwind-protect
          (cl-letf (((symbol-function 'org-agenda)
                     (lambda (&rest _)
                       (interactive)
                       (setq captured org-agenda-files)
                       (setq org-agenda-buffer buffer))))
            (ogent-armory-agenda root)
            (should (equal captured (ogent-armory-agenda-files root)))
            (should (equal (buffer-local-value 'org-agenda-files buffer)
                           (ogent-armory-agenda-files root)))
            (should (equal (default-value 'org-agenda-files) global-files)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(provide 'ogent-armory-schedule-tests)

;;; ogent-armory-schedule-tests.el ends here
