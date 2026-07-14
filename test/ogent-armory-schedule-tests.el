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
(require 'ogent-armory-actions)
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

(ert-deftest ogent-armory-schedule-control-plane-command-structure ()
  "The control-plane custom command composes running/failed/pending blocks."
  (let ((entry (ogent-armory-agenda-control-plane-command)))
    (should (equal (nth 0 entry) ogent-armory-agenda-control-plane-key))
    (should (stringp (nth 1 entry)))
    (let ((blocks (nth 2 entry)))
      (should (= (length blocks) 3))
      (should (equal (mapcar #'car blocks) '(todo todo tags)))
      (should (equal (nth 1 (nth 0 blocks)) "RUNNING"))
      (should (equal (nth 1 (nth 1 blocks)) "FAILED"))
      (should (equal (nth 1 (nth 2 blocks))
                     "OGENT_ACTION_STATUS=\"pending\""))
      (dolist (block blocks)
        (should (assq 'org-agenda-overriding-header (nth 2 block)))))))

(ert-deftest ogent-armory-schedule-control-plane-scopes-buffer-locally ()
  "The control-plane agenda registers command and scope per invocation."
  (ogent-armory-schedule-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-schedule-test--make-agent root)
    (let ((buffer (generate-new-buffer " *ogent-agenda-test*"))
          (global-commands org-agenda-custom-commands)
          (global-files org-agenda-files)
          (org-agenda-buffer nil)
          captured-files captured-commands captured-keys)
      (unwind-protect
          (cl-letf (((symbol-function 'org-agenda)
                     (lambda (&optional _arg keys &rest _)
                       (interactive)
                       (setq captured-files org-agenda-files)
                       (setq captured-commands org-agenda-custom-commands)
                       (setq captured-keys keys)
                       (setq org-agenda-buffer buffer))))
            (ogent-armory-agenda-control-plane root)
            (should (equal captured-keys
                           ogent-armory-agenda-control-plane-key))
            (should (equal captured-files (ogent-armory-agenda-files root)))
            (should (assoc ogent-armory-agenda-control-plane-key
                           captured-commands))
            (should (equal (default-value 'org-agenda-custom-commands)
                           global-commands))
            (should (equal (default-value 'org-agenda-files) global-files))
            (with-current-buffer buffer
              (should (equal org-agenda-files
                             (ogent-armory-agenda-files root)))
              (should ogent-armory-agenda-actions-mode)
              (should (equal ogent-armory-agenda--root root))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-armory-schedule-agenda-actions-mode-bindings ()
  "The control-plane minor mode binds run, retry, and approve keys."
  (should (eq (lookup-key ogent-armory-agenda-actions-mode-map "R")
              #'ogent-armory-agenda-run))
  (should (eq (lookup-key ogent-armory-agenda-actions-mode-map "r")
              #'ogent-armory-agenda-retry))
  (should (eq (lookup-key ogent-armory-agenda-actions-mode-map "a")
              #'ogent-armory-agenda-approve)))

(defun ogent-armory-schedule-tests--org-fixture (content &optional file)
  "Return an Org buffer containing CONTENT, visiting FILE when non-nil."
  (let ((buffer (if file
                    (progn
                      (with-temp-file file (insert content))
                      (find-file-noselect file))
                  (let ((scratch (generate-new-buffer " *ogent-agenda-src*")))
                    (with-current-buffer scratch (insert content))
                    scratch))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode)
        (org-mode)))
    buffer))

(defun ogent-armory-schedule-tests--fake-agenda (source)
  "Return a fake agenda buffer marking SOURCE's first headline."
  (let ((marker (with-current-buffer source
                  (save-excursion
                    (goto-char (point-min))
                    (re-search-forward org-outline-regexp-bol)
                    (copy-marker (line-beginning-position)))))
        (agenda (generate-new-buffer " *ogent-agenda-view*")))
    (with-current-buffer agenda
      (insert "  armory:     fixture entry\n")
      (put-text-property (point-min) (1+ (point-min)) 'org-marker marker)
      (goto-char (point-min)))
    agenda))

(defconst ogent-armory-schedule-tests--run-fixture
  (concat "#+TODO: TODO RUNNING(r) | DONE(d) FAILED(f)\n"
          "* RUNNING CTO Daily Review\n"
          ":PROPERTIES:\n"
          ":OGENT_CONVERSATION_ID: conv-1\n"
          ":OGENT_AGENT: cto\n"
          ":OGENT_JOB_ID: daily-review\n"
          ":END:\n")
  "Org fixture for a RUNNING conversation headline.")

(ert-deftest ogent-armory-schedule-agenda-run-dispatches-job ()
  "Agenda run resolves agent and job from the drawer and dispatches."
  (let* ((source (ogent-armory-schedule-tests--org-fixture
                  ogent-armory-schedule-tests--run-fixture))
         (agenda (ogent-armory-schedule-tests--fake-agenda source))
         dispatched)
    (unwind-protect
        (cl-letf (((symbol-function 'ogent-armory-run-job)
                   (lambda (directory agent job-id)
                     (setq dispatched (list directory agent job-id)))))
          (with-current-buffer agenda
            (setq-local ogent-armory-agenda--root "/tmp/armory")
            (ogent-armory-agenda-run))
          (should (equal dispatched '("/tmp/armory" "cto" "daily-review"))))
      (kill-buffer agenda)
      (kill-buffer source))))

(ert-deftest ogent-armory-schedule-agenda-retry-requires-failed ()
  "Agenda retry refuses headlines whose TODO state is not FAILED."
  (let* ((source (ogent-armory-schedule-tests--org-fixture
                  ogent-armory-schedule-tests--run-fixture))
         (agenda (ogent-armory-schedule-tests--fake-agenda source))
         dispatched)
    (unwind-protect
        (cl-letf (((symbol-function 'ogent-armory-run-job)
                   (lambda (&rest args) (setq dispatched args))))
          (with-current-buffer agenda
            (setq-local ogent-armory-agenda--root "/tmp/armory")
            (should-error (ogent-armory-agenda-retry) :type 'user-error))
          (should-not dispatched))
      (kill-buffer agenda)
      (kill-buffer source))))

(ert-deftest ogent-armory-schedule-agenda-retry-dispatches-failed-job ()
  "Agenda retry dispatches the job behind a FAILED headline."
  (let* ((source (ogent-armory-schedule-tests--org-fixture
                  (concat "#+TODO: TODO RUNNING(r) | DONE(d) FAILED(f)\n"
                          "* FAILED CTO Daily Review\n"
                          ":PROPERTIES:\n"
                          ":OGENT_CONVERSATION_ID: conv-1\n"
                          ":OGENT_AGENT: cto\n"
                          ":OGENT_JOB_ID: daily-review\n"
                          ":END:\n")))
         (agenda (ogent-armory-schedule-tests--fake-agenda source))
         dispatched)
    (unwind-protect
        (cl-letf (((symbol-function 'ogent-armory-run-job)
                   (lambda (directory agent job-id)
                     (setq dispatched (list directory agent job-id)))))
          (with-current-buffer agenda
            (setq-local ogent-armory-agenda--root "/tmp/armory")
            (ogent-armory-agenda-retry))
          (should (equal dispatched '("/tmp/armory" "cto" "daily-review"))))
      (kill-buffer agenda)
      (kill-buffer source))))

(ert-deftest ogent-armory-schedule-agenda-approve-persists-status ()
  "Agenda approve resolves the action id and stores the approval."
  (ogent-armory-schedule-test-with-temp-dir root
    (let* ((actions-dir (expand-file-name "conversations/conv-1" root))
           (actions-file (expand-file-name "actions.org" actions-dir)))
      (make-directory actions-dir t)
      (let* ((source (ogent-armory-schedule-tests--org-fixture
                      (concat "* PENDING Launch task\n"
                              ":PROPERTIES:\n"
                              ":OGENT_ACTION: t\n"
                              ":OGENT_ACTION_ID: act-1\n"
                              ":OGENT_ACTION_STATUS: pending\n"
                              ":END:\n")
                      actions-file))
             (agenda (ogent-armory-schedule-tests--fake-agenda source))
             (actions (list (list :id "act-1" :status "pending")
                            (list :id "act-2" :status "pending")))
             read-args stored)
        (unwind-protect
            (cl-letf (((symbol-function 'ogent-armory-actions-read)
                       (lambda (directory conversation-id)
                         (setq read-args (list directory conversation-id))
                         actions))
                      ((symbol-function 'ogent-armory-actions-store)
                       (lambda (directory conversation-id actions)
                         (setq stored
                               (list directory conversation-id actions)))))
              (with-current-buffer agenda
                (setq-local ogent-armory-agenda--root root)
                (ogent-armory-agenda-approve))
              (should (equal read-args (list root "conv-1")))
              (should (equal (nth 0 stored) root))
              (should (equal (nth 1 stored) "conv-1"))
              (let ((updated (nth 2 stored)))
                (should (equal (plist-get (nth 0 updated) :status)
                               "approved"))
                (should (equal (plist-get (nth 1 updated) :status)
                               "pending"))))
          (kill-buffer agenda)
          (kill-buffer source))))))

(provide 'ogent-armory-schedule-tests)

;;; ogent-armory-schedule-tests.el ends here
