;;; ogent-armory-schedule.el --- Armory schedule and agenda views -*- lexical-binding: t; -*-

;;; Commentary:
;; Expands Armory job cron metadata, agent heartbeats, one-shot scheduled
;; tasks, and scheduled conversations into deterministic events.  The same
;; event data backs the schedule UI and Org agenda bridge.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-agenda)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'time-date)
(require 'ogent-armory)
(require 'ogent-armory-evil)
(require 'ogent-armory-conversations)
(require 'ogent-armory-runner)

(defgroup ogent-armory-schedule nil
  "Armory schedule views and agenda integration."
  :group 'ogent-armory)

(defcustom ogent-armory-schedule-buffer-name-format "*ogent-armory-schedule:%s*"
  "Format string used for Armory schedule buffer names."
  :type 'string
  :group 'ogent-armory-schedule)

(defvar-local ogent-armory-schedule--root nil
  "Armory root shown by the current schedule buffer.")

(defvar-local ogent-armory-schedule--view 'week
  "Current schedule view, one of `day', `week', or `month'.")

(defvar-local ogent-armory-schedule--date nil
  "Anchor date for the current schedule buffer.")

(defvar-local ogent-armory-schedule--now nil
  "Current time reference for the current schedule buffer.")

(defvar-local ogent-armory-schedule--range nil
  "Current schedule time range as a plist.")

(defvar-local ogent-armory-schedule--events nil
  "Events displayed by the current schedule buffer.")

(defun ogent-armory-schedule-parse-time (value)
  "Return VALUE as an Emacs time value."
  (cond
   ((null value) nil)
   ((or (integerp value) (floatp value) (consp value)) value)
   ((stringp value)
    (date-to-time value))
   (t (user-error "Unsupported Armory schedule time: %S" value))))

(defun ogent-armory-schedule--minute-time (time)
  "Return TIME with seconds cleared."
  (let ((decoded (decode-time time)))
    (encode-time 0
                 (nth 1 decoded)
                 (nth 2 decoded)
                 (nth 3 decoded)
                 (nth 4 decoded)
                 (nth 5 decoded)
                 (nth 8 decoded))))

(defun ogent-armory-schedule--minute-iso (time)
  "Return TIME formatted as a stable local minute string."
  (format-time-string "%Y-%m-%dT%H:%M"
                      (ogent-armory-schedule--minute-time time)))

(defun ogent-armory-schedule-key (agent source-type source-id time)
  "Return the stable schedule key for AGENT SOURCE-TYPE SOURCE-ID and TIME."
  (format "%s::%s::%s::%s"
          agent
          (if (symbolp source-type)
              (symbol-name source-type)
            source-type)
          (or source-id "--")
          (ogent-armory-schedule--minute-iso time)))

(defun ogent-armory-schedule--time< (left right)
  "Return non-nil when LEFT is before RIGHT."
  (time-less-p (ogent-armory-schedule-parse-time left)
               (ogent-armory-schedule-parse-time right)))

(defun ogent-armory-schedule--time<= (left right)
  "Return non-nil when LEFT is before or equal to RIGHT."
  (not (ogent-armory-schedule--time< right left)))

(defun ogent-armory-schedule--range-contains-p (time start end)
  "Return non-nil when TIME is inside the half-open START END range."
  (and (ogent-armory-schedule--time<= start time)
       (ogent-armory-schedule--time< time end)))

(defun ogent-armory-schedule--day-start (time)
  "Return local midnight for TIME."
  (let ((decoded (decode-time time)))
    (encode-time 0 0 0
                 (nth 3 decoded)
                 (nth 4 decoded)
                 (nth 5 decoded)
                 (nth 8 decoded))))

(defun ogent-armory-schedule--add-days (time days)
  "Return TIME moved by DAYS days."
  (time-add time (days-to-time days)))

(defun ogent-armory-schedule--week-start (time)
  "Return the Monday local midnight for the week containing TIME."
  (let* ((start (ogent-armory-schedule--day-start time))
         (weekday (nth 6 (decode-time start)))
         (offset (mod (1- weekday) 7)))
    (ogent-armory-schedule--add-days start (- offset))))

(defun ogent-armory-schedule--month-start (time)
  "Return local midnight on the first day of TIME's month."
  (let ((decoded (decode-time time)))
    (encode-time 0 0 0 1 (nth 4 decoded) (nth 5 decoded) (nth 8 decoded))))

(defun ogent-armory-schedule--month-end (time)
  "Return local midnight on the first day after TIME's month."
  (let* ((decoded (decode-time time))
         (month (nth 4 decoded))
         (year (nth 5 decoded)))
    (if (= month 12)
        (encode-time 0 0 0 1 1 (1+ year) (nth 8 decoded))
      (encode-time 0 0 0 1 (1+ month) year (nth 8 decoded)))))

(defun ogent-armory-schedule--range (date view)
  "Return the schedule range for DATE and VIEW."
  (let* ((time (or (ogent-armory-schedule-parse-time date)
                   (current-time)))
         (view (or view 'week)))
    (pcase view
      ('day
       (let ((start (ogent-armory-schedule--day-start time)))
         (list :start start
               :end (ogent-armory-schedule--add-days start 1))))
      ('week
       (let ((start (ogent-armory-schedule--week-start time)))
         (list :start start
               :end (ogent-armory-schedule--add-days start 7))))
      ('month
       (let ((start (ogent-armory-schedule--month-start time)))
         (list :start start
               :end (ogent-armory-schedule--month-end start))))
      (_
       (user-error "Unknown Armory schedule view: %s" view)))))

(defun ogent-armory-schedule--cron-match-p (fields time)
  "Return non-nil when parsed cron FIELDS match TIME."
  (let* ((decoded (decode-time time))
         (minute (nth 1 decoded))
         (hour (nth 2 decoded))
         (day (nth 3 decoded))
         (month (nth 4 decoded))
         (weekday (nth 6 decoded)))
    (and (member minute (nth 0 fields))
         (member hour (nth 1 fields))
         (member day (nth 2 fields))
         (member month (nth 3 fields))
         (member weekday (nth 4 fields)))))

(defun ogent-armory-schedule--cron-times (cron start end)
  "Return run times for CRON inside START and END."
  (let ((fields (ogent-armory--cron-expression-fields cron))
        (cursor (ogent-armory-schedule--minute-time start))
        times)
    (when fields
      (while (ogent-armory-schedule--time< cursor end)
        (when (and (ogent-armory-schedule--time<= start cursor)
                   (ogent-armory-schedule--cron-match-p fields cursor))
          (push cursor times))
        (setq cursor (time-add cursor (seconds-to-time 60)))))
    (nreverse times)))

(cl-defun ogent-armory-schedule--event
    (&key root agent source-type source-id title time path job owner-task)
  "Return one Armory schedule event for ROOT and AGENT.
Use SOURCE-TYPE, SOURCE-ID, TITLE, TIME, PATH, JOB, and OWNER-TASK
as event metadata."
  (let* ((minute (ogent-armory-schedule--minute-iso time))
         (key (ogent-armory-schedule-key agent source-type source-id time)))
    (list :root root
          :agent agent
          :source-type source-type
          :source-id source-id
          :title title
          :time (ogent-armory-schedule--minute-time time)
          :minute-iso minute
          :schedule-key key
          :path path
          :job job
          :owner-task owner-task)))

(defun ogent-armory-schedule--job-enabled-p (job)
  "Return non-nil when JOB is enabled for schedule expansion."
  (and (plist-get job :enabled)
       (not (plist-get job :archived))))

(defun ogent-armory-schedule--job-events (root agent job start end)
  "Return schedule events for JOB owned by AGENT under ROOT."
  (let ((agent-slug (plist-get agent :slug))
        (job-id (plist-get job :id))
        (title (or (plist-get job :name) (plist-get job :id)))
        (path (ogent-armory-job-file
               root
               (plist-get agent :slug)
               (plist-get job :id)))
        events)
    (when (ogent-armory-schedule--job-enabled-p job)
      (when-let ((cron (ogent-armory--blank-to-nil (plist-get job :cron))))
        (dolist (time (ogent-armory-schedule--cron-times cron start end))
          (push (ogent-armory-schedule--event
                 :root root
                 :agent agent-slug
                 :source-type 'job
                 :source-id job-id
                 :title title
                 :time time
                 :path path
                 :job job
                 :owner-task (plist-get job :owner-task))
                events)))
      (when-let ((run-after (ogent-armory--blank-to-nil
                             (plist-get job :run-after))))
        (let ((time (ogent-armory-schedule-parse-time run-after)))
          (when (ogent-armory-schedule--range-contains-p time start end)
            (push (ogent-armory-schedule--event
                   :root root
                   :agent agent-slug
                   :source-type 'task
                   :source-id job-id
                   :title title
                   :time time
                   :path path
                   :job job
                   :owner-task (plist-get job :owner-task))
                  events)))))
    (nreverse events)))

(defun ogent-armory-schedule--heartbeat-events (root agent start end)
  "Return heartbeat schedule events for AGENT under ROOT."
  (let ((agent-slug (plist-get agent :slug))
        (heartbeat (ogent-armory--blank-to-nil
                    (plist-get agent :heartbeat)))
        events)
    (when (and heartbeat
               (plist-get agent :active)
               (not (plist-get agent :archived))
               (ogent-armory--cron-expression-p heartbeat))
      (dolist (time (ogent-armory-schedule--cron-times heartbeat start end))
        (push (ogent-armory-schedule--event
               :root root
               :agent agent-slug
               :source-type 'heartbeat
               :source-id nil
               :title (format "%s heartbeat"
                              (or (plist-get agent :name) agent-slug))
               :time time
               :path (plist-get agent :path))
              events)))
    (nreverse events)))

(defun ogent-armory-schedule--conversation-map (roots)
  "Return a hash table mapping schedule keys to conversations under ROOTS."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (root (if (listp roots) roots (list roots)))
      (dolist (conversation (ogent-armory-conversation-list root))
        (when-let ((key (plist-get conversation :scheduled-key)))
          (puthash key conversation table))))
    table))

(defun ogent-armory-schedule--state (event conversation now)
  "Return EVENT state using CONVERSATION and NOW."
  (cond
   (conversation
    (intern (or (plist-get conversation :status) "done")))
   ((ogent-armory-schedule--time< (plist-get event :time) now)
    'missed)
   (t 'upcoming)))

(defun ogent-armory-schedule--link-event (event conversation-table now)
  "Return EVENT annotated with CONVERSATION-TABLE linkage and state.
Use NOW to classify missed events."
  (let* ((conversation (gethash (plist-get event :schedule-key)
                                conversation-table))
         (state (ogent-armory-schedule--state event conversation now)))
    (append
     event
     (list :state state
           :conversation-id (plist-get conversation :id)
           :conversation-path (plist-get conversation :path)
           :conversation conversation))))

(defun ogent-armory-schedule--key-source (key fallback-id)
  "Return source metadata parsed from schedule KEY.
FALLBACK-ID is used when KEY does not have the stable Armory shape."
  (let ((parts (and key (split-string key "::"))))
    (if (= (length parts) 4)
        (list :source-type (intern (nth 1 parts))
              :source-id (nth 2 parts))
      (list :source-type 'manual
            :source-id fallback-id))))

(defun ogent-armory-schedule--manual-events (roots start end generated now)
  "Return scheduled manual events from ROOTS between START and END.
Use GENERATED and NOW to suppress duplicates and classify events."
  (let ((seen (make-hash-table :test 'equal))
        events)
    (dolist (event generated)
      (puthash (plist-get event :schedule-key) t seen))
    (dolist (root (if (listp roots) roots (list roots)))
      (dolist (conversation (ogent-armory-conversation-list root))
        (when-let ((scheduled-at (plist-get conversation :scheduled-at)))
          (let* ((time (ogent-armory-schedule-parse-time scheduled-at))
                 (key (or (plist-get conversation :scheduled-key)
                          (ogent-armory-schedule-key
                           (or (plist-get conversation :agent) "manual")
                           'manual
                           (plist-get conversation :id)
                           time)))
                 (source (ogent-armory-schedule--key-source
                          key
                          (plist-get conversation :id))))
            (when (and (not (gethash key seen))
                       (ogent-armory-schedule--range-contains-p time start end))
              (puthash key t seen)
              (push (append
                     (list :root root
                           :agent (plist-get conversation :agent)
                           :source-type (plist-get source :source-type)
                           :source-id (plist-get source :source-id)
                           :title (or (plist-get conversation :title)
                                      (plist-get conversation :id))
                           :time (ogent-armory-schedule--minute-time time)
                           :minute-iso
                           (ogent-armory-schedule--minute-iso time)
                           :schedule-key key
                           :state (ogent-armory-schedule--state
                                   (list :time time)
                                   conversation
                                   now)
                           :conversation-id (plist-get conversation :id)
                           :conversation-path (plist-get conversation :path)
                           :conversation conversation
                           :path (plist-get conversation :path)))
                    events))))))
    (nreverse events)))

(defun ogent-armory-schedule--local-agent-p (agent)
  "Return non-nil when AGENT jobs are stored in a Armory agents directory."
  (memq (plist-get agent :scope) '(armory visible)))

;;;###autoload
(cl-defun ogent-armory-schedule-events
    (directory start end &key now (include-visible t))
  "Return schedule events under DIRECTORY from START until END.
Use NOW for missed-run detection and INCLUDE-VISIBLE for visible child Armories."
  (let* ((candidate (ogent-armory--directory directory))
         (root (directory-file-name
                (file-truename
                 (ogent-armory--directory
                  (or (ogent-armory-find-root candidate)
                      candidate)))))
         (start (ogent-armory-schedule-parse-time start))
         (end (ogent-armory-schedule-parse-time end))
         (now (or (ogent-armory-schedule-parse-time now)
                  (current-time)))
         (conversation-roots (if include-visible
                                 (ogent-armory-visible-armories root)
                               (list root)))
         events)
    (dolist (agent (ogent-armory-agent-records
                    root
                    :include-visible include-visible))
      (let ((source-root (or (plist-get agent :source-root) root)))
        (setq events
              (append events
                      (ogent-armory-schedule--heartbeat-events
                       source-root agent start end)))
        (when (ogent-armory-schedule--local-agent-p agent)
          (dolist (job (ogent-armory-list-jobs
                        source-root
                        (plist-get agent :slug)))
            (setq events
                  (append events
                          (ogent-armory-schedule--job-events
                           source-root agent job start end)))))))
    (let* ((conversation-table
            (ogent-armory-schedule--conversation-map conversation-roots))
           (linked (mapcar (lambda (event)
                             (ogent-armory-schedule--link-event
                              event
                              conversation-table
                              now))
                           events)))
      (seq-sort-by
       (lambda (event)
         (plist-get event :minute-iso))
       #'string<
       (append linked
               (ogent-armory-schedule--manual-events
                conversation-roots start end linked now))))))

(cl-defun ogent-armory-agenda-files (directory &key (include-visible t))
  "Return Org agenda files for DIRECTORY according to INCLUDE-VISIBLE."
  (let* ((candidate (ogent-armory--directory directory))
         (root (directory-file-name
                (file-truename
                 (ogent-armory--directory
                  (or (ogent-armory-find-root candidate)
                      candidate)))))
         (roots (if include-visible
                    (ogent-armory-visible-armories root)
                  (list root)))
         files)
    (dolist (armory-root roots)
      (setq files (append files (ogent-armory-org-files armory-root))))
    (seq-sort #'string<
              (delete-dups
               (seq-filter #'file-readable-p
                           (mapcar #'expand-file-name files))))))

(defmacro ogent-armory-with-agenda-files (directory &rest body)
  "Run BODY with `org-agenda-files' bound to Armory files under DIRECTORY."
  (declare (indent 1) (debug t))
  `(let ((org-agenda-files (ogent-armory-agenda-files ,directory)))
     ,@body))

;;;###autoload
(defun ogent-armory-agenda (&optional directory)
  "Open Org agenda over Armory files under DIRECTORY.
The Armory file set is also installed buffer-locally in the agenda
buffer so refresh commands such as `org-agenda-redo' keep the
Armory scope instead of falling back to the global
`org-agenda-files'."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (or directory default-directory))
         (files (ogent-armory-agenda-files root)))
    (let ((org-agenda-files files))
      (call-interactively #'org-agenda))
    (when-let ((buf (if (boundp 'org-agenda-buffer) org-agenda-buffer
                      (get-buffer org-agenda-buffer-name))))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (setq-local org-agenda-files files))))))

(defun ogent-armory-schedule--state-label (state)
  "Return a display label for schedule STATE."
  (pcase state
    ('missed "missed")
    ('upcoming "upcoming")
    ('done "done")
    ('failed "failed")
    ('running "running")
    ('awaiting-input "awaiting")
    (_ (format "%s" state))))

(defun ogent-armory-schedule--entry (event)
  "Return a tabulated-list entry for EVENT."
  (list
   event
   (vector
    (format-time-string "%Y-%m-%d %H:%M" (plist-get event :time))
    (ogent-armory-schedule--state-label (plist-get event :state))
    (symbol-name (plist-get event :source-type))
    (or (plist-get event :agent) "")
    (or (plist-get event :title) "")
    (or (plist-get event :schedule-key) ""))))

(defun ogent-armory-schedule--entries ()
  "Return schedule entries for the current buffer."
  (mapcar #'ogent-armory-schedule--entry ogent-armory-schedule--events))

(defun ogent-armory-schedule--range-label ()
  "Return a concise label for the current schedule range."
  (let ((start (plist-get ogent-armory-schedule--range :start))
        (end (plist-get ogent-armory-schedule--range :end)))
    (format "%s %s to %s"
            (capitalize (symbol-name ogent-armory-schedule--view))
            (format-time-string "%Y-%m-%d" start)
            (format-time-string "%Y-%m-%d" end))))

(defun ogent-armory-schedule--render ()
  "Render the current Armory schedule buffer."
  (let* ((range (ogent-armory-schedule--range
                 ogent-armory-schedule--date
                 ogent-armory-schedule--view))
         (start (plist-get range :start))
         (end (plist-get range :end)))
    (setq ogent-armory-schedule--range range)
    (setq ogent-armory-schedule--events
          (ogent-armory-schedule-events
           ogent-armory-schedule--root
           start
           end
           :now (or ogent-armory-schedule--now (current-time))))
    (setq tabulated-list-entries #'ogent-armory-schedule--entries)
    (setq header-line-format
          (concat " Armory schedule: "
                  (ogent-armory-schedule--range-label)
                  "   C-c d day   C-c w week   C-c m month   C-c r run missed   RET open"))
    (tabulated-list-print t)))

(defvar ogent-armory-schedule-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-armory-schedule-open)
    (define-key map (kbd "<return>") #'ogent-armory-schedule-open)
    (define-key map (kbd "<kp-enter>") #'ogent-armory-schedule-open)
    (define-key map "R" #'ogent-armory-schedule-run-missed)
    (define-key map (kbd "C-c r") #'ogent-armory-schedule-run-missed)
    (define-key map "d" #'ogent-armory-schedule-day-view)
    (define-key map (kbd "C-c d") #'ogent-armory-schedule-day-view)
    (define-key map "w" #'ogent-armory-schedule-week-view)
    (define-key map (kbd "C-c w") #'ogent-armory-schedule-week-view)
    (define-key map "m" #'ogent-armory-schedule-month-view)
    (define-key map (kbd "C-c m") #'ogent-armory-schedule-month-view)
    (define-key map "g" #'ogent-armory-schedule-refresh)
    (define-key map (kbd "C-c g") #'ogent-armory-schedule-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-schedule-mode'.")

(define-derived-mode ogent-armory-schedule-mode tabulated-list-mode
  "Armory-Schedule"
  "Major mode for Armory schedule events."
  :group 'ogent-armory-schedule
  (setq-local tabulated-list-format
              [("When" 17 t)
               ("State" 10 t)
               ("Source" 10 t)
               ("Agent" 14 t)
               ("Title" 30 t)
               ("Key" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-armory-schedule-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-schedule--item ()
  "Return the schedule event at point."
  (or (tabulated-list-get-id)
      (user-error "No Armory schedule event at point")))

(defun ogent-armory-schedule-open ()
  "Open the conversation or source record for the schedule event at point."
  (interactive)
  (let* ((item (ogent-armory-schedule--item))
         (path (or (plist-get item :conversation-path)
                   (plist-get item :path))))
    (unless (and path (file-exists-p path))
      (user-error "No Armory schedule source at point"))
    (find-file path)))

(defun ogent-armory-schedule--run-event (event)
  "Run EVENT now with its scheduled key attached to the conversation."
  (let* ((root (plist-get event :root))
         (agent (plist-get event :agent))
         (source-type (plist-get event :source-type))
         (job-id (when (memq source-type '(job task))
                   (plist-get event :source-id)))
         (instruction (unless job-id
                        (format "Run the scheduled %s slot for %s at %s."
                                source-type
                                agent
                                (plist-get event :minute-iso))))
         (plan (ogent-armory-runner-plan
                root
                agent
                :job-id job-id
                :instruction instruction
                :trigger (symbol-name source-type)
                :conversation-title (plist-get event :title)
                :scheduled-at (plist-get event :minute-iso)
                :scheduled-key (plist-get event :schedule-key))))
    (when (ogent-armory-runner--confirm plan)
      (ogent-armory-runner-start plan))))

;;; Scheduler

(defcustom ogent-armory-scheduler-roots nil
  "Armory root directories watched by `ogent-armory-scheduler-mode'."
  :type '(repeat directory)
  :group 'ogent-armory-schedule)

(defcustom ogent-armory-scheduler-interval 60
  "Seconds between Armory scheduler ticks."
  :type 'integer
  :group 'ogent-armory-schedule)

(defcustom ogent-armory-scheduler-auto-run t
  "When non-nil, run due Armory schedule events automatically.
When nil, each scheduler tick only announces due events via
`message' and leaves them for the manual run-missed flow in the
schedule buffer."
  :type 'boolean
  :group 'ogent-armory-schedule)

(defcustom ogent-armory-scheduler-catchup-window 300
  "Seconds of backlog the scheduler fires automatically per tick.
Events due earlier than this many seconds before the tick are left
for the manual run-missed flow, so waking from a long suspend does
not launch the whole missed backlog at once."
  :type 'integer
  :group 'ogent-armory-schedule)

(defvar ogent-armory-scheduler--timer nil
  "Repeating timer driving `ogent-armory-scheduler-tick'.")

(defvar ogent-armory-scheduler--last-tick nil
  "Time of the previous scheduler tick, or nil before the arming tick.")

(defvar ogent-armory-scheduler--fired (make-hash-table :test 'equal)
  "Schedule keys already fired by the scheduler in this session.")

(defun ogent-armory-scheduler--due-events (root window-start now)
  "Return unfired missed ROOT events between WINDOW-START and NOW."
  (seq-filter
   (lambda (event)
     (and (eq (plist-get event :state) 'missed)
          (not (gethash (plist-get event :schedule-key)
                        ogent-armory-scheduler--fired))))
   (ogent-armory-schedule-events root window-start now :now now)))

(defun ogent-armory-scheduler--fire (event)
  "Fire one due schedule EVENT, honoring the auto-run gate."
  (let ((key (plist-get event :schedule-key)))
    (puthash key t ogent-armory-scheduler--fired)
    (if ogent-armory-scheduler-auto-run
        (let ((ogent-armory-runner-confirm-before-run nil))
          (ogent-armory-schedule--run-event event))
      (message "ogent scheduler: %s due (auto-run disabled)" key))))

(defun ogent-armory-scheduler-tick (&optional now)
  "Fire Armory schedule events that came due since the previous tick.
NOW defaults to the current time.  The first tick after enabling
`ogent-armory-scheduler-mode' only arms the tick window and fires
nothing.  Events older than `ogent-armory-scheduler-catchup-window'
seconds at NOW are skipped.  Return the list of events processed."
  (let ((now (or now (current-time))))
    (if (null ogent-armory-scheduler--last-tick)
        (progn
          (setq ogent-armory-scheduler--last-tick now)
          nil)
      (let* ((floor-time (time-subtract
                          now ogent-armory-scheduler-catchup-window))
             (window-start (if (time-less-p
                                ogent-armory-scheduler--last-tick
                                floor-time)
                               floor-time
                             ogent-armory-scheduler--last-tick))
             fired)
        (dolist (root ogent-armory-scheduler-roots)
          (when (file-directory-p root)
            (condition-case root-err
                (dolist (event (ogent-armory-scheduler--due-events
                                root window-start now))
                  (condition-case event-err
                      (progn
                        (ogent-armory-scheduler--fire event)
                        (push event fired))
                    (error
                     (message "ogent scheduler: %s failed: %s"
                              (plist-get event :schedule-key)
                              (error-message-string event-err)))))
              (error
               (message "ogent scheduler: armory %s failed: %s"
                        root (error-message-string root-err))))))
        (setq ogent-armory-scheduler--last-tick now)
        (nreverse fired)))))

;;;###autoload
(define-minor-mode ogent-armory-scheduler-mode
  "Fire due Armory schedule events from an Emacs timer loop.
Watch the Armory roots in `ogent-armory-scheduler-roots' every
`ogent-armory-scheduler-interval' seconds and run due cron jobs,
agent heartbeats, and one-shot tasks through the Armory runner.
Events older than `ogent-armory-scheduler-catchup-window' seconds
stay manual via the schedule buffer's run-missed command."
  :global t
  :group 'ogent-armory-schedule
  (when ogent-armory-scheduler--timer
    (cancel-timer ogent-armory-scheduler--timer)
    (setq ogent-armory-scheduler--timer nil))
  (when ogent-armory-scheduler-mode
    (setq ogent-armory-scheduler--last-tick nil)
    (setq ogent-armory-scheduler--timer
          (run-with-timer ogent-armory-scheduler-interval
                          ogent-armory-scheduler-interval
                          #'ogent-armory-scheduler-tick))))

(defun ogent-armory-schedule-run-missed ()
  "Run the missed Armory schedule event at point."
  (interactive)
  (let ((event (ogent-armory-schedule--item)))
    (unless (eq (plist-get event :state) 'missed)
      (user-error "The selected schedule event is not missed"))
    (ogent-armory-schedule--run-event event)))

(defun ogent-armory-schedule-refresh (&rest _)
  "Refresh the current Armory schedule buffer."
  (interactive)
  (ogent-armory-schedule--render))

(defun ogent-armory-schedule-day-view ()
  "Switch the current schedule buffer to day view."
  (interactive)
  (setq ogent-armory-schedule--view 'day)
  (ogent-armory-schedule--render))

(defun ogent-armory-schedule-week-view ()
  "Switch the current schedule buffer to week view."
  (interactive)
  (setq ogent-armory-schedule--view 'week)
  (ogent-armory-schedule--render))

(defun ogent-armory-schedule-month-view ()
  "Switch the current schedule buffer to month view."
  (interactive)
  (setq ogent-armory-schedule--view 'month)
  (ogent-armory-schedule--render))

;;;###autoload
(cl-defun ogent-armory-schedule (&optional directory &key view date now)
  "Open the Armory schedule for DIRECTORY.
VIEW may be `day', `week', or `month'.  DATE anchors the range.  NOW is used
for deterministic missed-run detection."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (directory-file-name
                (file-truename
                 (ogent-armory--directory
                  (or (ogent-armory-find-root
                       (ogent-armory--directory
                        (or directory default-directory)))
                      directory
                      default-directory)))))
         (buffer (get-buffer-create
                  (format ogent-armory-schedule-buffer-name-format
                          (file-name-nondirectory root)))))
    (with-current-buffer buffer
      (ogent-armory-schedule-mode)
      (setq ogent-armory-schedule--root root)
      (setq ogent-armory-schedule--view (or view 'week))
      (setq ogent-armory-schedule--date (or date (current-time)))
      (setq ogent-armory-schedule--now now)
      (setq default-directory (file-name-as-directory root))
      (ogent-armory-schedule--render))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(defun ogent-armory-schedule--evil-local-keys ()
  "Install local Evil keys for Armory schedule."
  (ogent-armory-evil-install-local-bindings ogent-armory-schedule-mode-map))

(defun ogent-armory-schedule--setup-evil ()
  "Set up Evil integration for Armory schedule."
  (ogent-armory-evil-setup-mode
   'ogent-armory-schedule-mode
   ogent-armory-schedule-mode-map
   'ogent-armory-schedule-mode-hook
   #'ogent-armory-schedule--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-schedule--setup-evil))

(provide 'ogent-armory-schedule)

;;; ogent-armory-schedule.el ends here
