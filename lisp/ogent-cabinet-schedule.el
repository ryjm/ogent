;;; ogent-cabinet-schedule.el --- Cabinet schedule and agenda views -*- lexical-binding: t; -*-

;;; Commentary:
;; Expands Cabinet job cron metadata, agent heartbeats, one-shot scheduled
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
(require 'ogent-cabinet)
(require 'ogent-cabinet-evil)
(require 'ogent-cabinet-conversations)
(require 'ogent-cabinet-runner)

(defgroup ogent-cabinet-schedule nil
  "Cabinet schedule views and agenda integration."
  :group 'ogent-cabinet)

(defcustom ogent-cabinet-schedule-buffer-name-format "*ogent-cabinet-schedule:%s*"
  "Format string used for Cabinet schedule buffer names."
  :type 'string
  :group 'ogent-cabinet-schedule)

(defvar-local ogent-cabinet-schedule--root nil
  "Cabinet root shown by the current schedule buffer.")

(defvar-local ogent-cabinet-schedule--view 'week
  "Current schedule view, one of `day', `week', or `month'.")

(defvar-local ogent-cabinet-schedule--date nil
  "Anchor date for the current schedule buffer.")

(defvar-local ogent-cabinet-schedule--now nil
  "Current time reference for the current schedule buffer.")

(defvar-local ogent-cabinet-schedule--range nil
  "Current schedule time range as a plist.")

(defvar-local ogent-cabinet-schedule--events nil
  "Events displayed by the current schedule buffer.")

(defun ogent-cabinet-schedule-parse-time (value)
  "Return VALUE as an Emacs time value."
  (cond
   ((null value) nil)
   ((or (integerp value) (floatp value) (consp value)) value)
   ((stringp value)
    (date-to-time value))
   (t (user-error "Unsupported Cabinet schedule time: %S" value))))

(defun ogent-cabinet-schedule--minute-time (time)
  "Return TIME with seconds cleared."
  (let ((decoded (decode-time time)))
    (encode-time 0
                 (nth 1 decoded)
                 (nth 2 decoded)
                 (nth 3 decoded)
                 (nth 4 decoded)
                 (nth 5 decoded)
                 (nth 8 decoded))))

(defun ogent-cabinet-schedule--minute-iso (time)
  "Return TIME formatted as a stable local minute string."
  (format-time-string "%Y-%m-%dT%H:%M"
                      (ogent-cabinet-schedule--minute-time time)))

(defun ogent-cabinet-schedule-key (agent source-type source-id time)
  "Return the stable schedule key for AGENT SOURCE-TYPE SOURCE-ID and TIME."
  (format "%s::%s::%s::%s"
          agent
          (if (symbolp source-type)
              (symbol-name source-type)
            source-type)
          (or source-id "--")
          (ogent-cabinet-schedule--minute-iso time)))

(defun ogent-cabinet-schedule--time< (left right)
  "Return non-nil when LEFT is before RIGHT."
  (time-less-p (ogent-cabinet-schedule-parse-time left)
               (ogent-cabinet-schedule-parse-time right)))

(defun ogent-cabinet-schedule--time<= (left right)
  "Return non-nil when LEFT is before or equal to RIGHT."
  (not (ogent-cabinet-schedule--time< right left)))

(defun ogent-cabinet-schedule--range-contains-p (time start end)
  "Return non-nil when TIME is inside the half-open START END range."
  (and (ogent-cabinet-schedule--time<= start time)
       (ogent-cabinet-schedule--time< time end)))

(defun ogent-cabinet-schedule--day-start (time)
  "Return local midnight for TIME."
  (let ((decoded (decode-time time)))
    (encode-time 0 0 0
                 (nth 3 decoded)
                 (nth 4 decoded)
                 (nth 5 decoded)
                 (nth 8 decoded))))

(defun ogent-cabinet-schedule--add-days (time days)
  "Return TIME moved by DAYS days."
  (time-add time (days-to-time days)))

(defun ogent-cabinet-schedule--week-start (time)
  "Return the Monday local midnight for the week containing TIME."
  (let* ((start (ogent-cabinet-schedule--day-start time))
         (weekday (nth 6 (decode-time start)))
         (offset (mod (1- weekday) 7)))
    (ogent-cabinet-schedule--add-days start (- offset))))

(defun ogent-cabinet-schedule--month-start (time)
  "Return local midnight on the first day of TIME's month."
  (let ((decoded (decode-time time)))
    (encode-time 0 0 0 1 (nth 4 decoded) (nth 5 decoded) (nth 8 decoded))))

(defun ogent-cabinet-schedule--month-end (time)
  "Return local midnight on the first day after TIME's month."
  (let* ((decoded (decode-time time))
         (month (nth 4 decoded))
         (year (nth 5 decoded)))
    (if (= month 12)
        (encode-time 0 0 0 1 1 (1+ year) (nth 8 decoded))
      (encode-time 0 0 0 1 (1+ month) year (nth 8 decoded)))))

(defun ogent-cabinet-schedule--range (date view)
  "Return the schedule range for DATE and VIEW."
  (let* ((time (or (ogent-cabinet-schedule-parse-time date)
                   (current-time)))
         (view (or view 'week)))
    (pcase view
      ('day
       (let ((start (ogent-cabinet-schedule--day-start time)))
         (list :start start
               :end (ogent-cabinet-schedule--add-days start 1))))
      ('week
       (let ((start (ogent-cabinet-schedule--week-start time)))
         (list :start start
               :end (ogent-cabinet-schedule--add-days start 7))))
      ('month
       (let ((start (ogent-cabinet-schedule--month-start time)))
         (list :start start
               :end (ogent-cabinet-schedule--month-end start))))
      (_
       (user-error "Unknown Cabinet schedule view: %s" view)))))

(defun ogent-cabinet-schedule--cron-match-p (fields time)
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

(defun ogent-cabinet-schedule--cron-times (cron start end)
  "Return run times for CRON inside START and END."
  (let ((fields (ogent-cabinet--cron-expression-fields cron))
        (cursor (ogent-cabinet-schedule--minute-time start))
        times)
    (when fields
      (while (ogent-cabinet-schedule--time< cursor end)
        (when (and (ogent-cabinet-schedule--time<= start cursor)
                   (ogent-cabinet-schedule--cron-match-p fields cursor))
          (push cursor times))
        (setq cursor (time-add cursor (seconds-to-time 60)))))
    (nreverse times)))

(cl-defun ogent-cabinet-schedule--event
    (&key root agent source-type source-id title time path job owner-task)
  "Return one Cabinet schedule event."
  (let* ((minute (ogent-cabinet-schedule--minute-iso time))
         (key (ogent-cabinet-schedule-key agent source-type source-id time)))
    (list :root root
          :agent agent
          :source-type source-type
          :source-id source-id
          :title title
          :time (ogent-cabinet-schedule--minute-time time)
          :minute-iso minute
          :schedule-key key
          :path path
          :job job
          :owner-task owner-task)))

(defun ogent-cabinet-schedule--job-enabled-p (job)
  "Return non-nil when JOB is enabled for schedule expansion."
  (and (plist-get job :enabled)
       (not (plist-get job :archived))))

(defun ogent-cabinet-schedule--job-events (root agent job start end)
  "Return schedule events for JOB owned by AGENT under ROOT."
  (let ((agent-slug (plist-get agent :slug))
        (job-id (plist-get job :id))
        (title (or (plist-get job :name) (plist-get job :id)))
        (path (ogent-cabinet-job-file
               root
               (plist-get agent :slug)
               (plist-get job :id)))
        events)
    (when (ogent-cabinet-schedule--job-enabled-p job)
      (when-let ((cron (ogent-cabinet--blank-to-nil (plist-get job :cron))))
        (dolist (time (ogent-cabinet-schedule--cron-times cron start end))
          (push (ogent-cabinet-schedule--event
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
      (when-let ((run-after (ogent-cabinet--blank-to-nil
                             (plist-get job :run-after))))
        (let ((time (ogent-cabinet-schedule-parse-time run-after)))
          (when (ogent-cabinet-schedule--range-contains-p time start end)
            (push (ogent-cabinet-schedule--event
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

(defun ogent-cabinet-schedule--heartbeat-events (root agent start end)
  "Return heartbeat schedule events for AGENT under ROOT."
  (let ((agent-slug (plist-get agent :slug))
        (heartbeat (ogent-cabinet--blank-to-nil
                    (plist-get agent :heartbeat)))
        events)
    (when (and heartbeat
               (plist-get agent :active)
               (not (plist-get agent :archived))
               (ogent-cabinet--cron-expression-p heartbeat))
      (dolist (time (ogent-cabinet-schedule--cron-times heartbeat start end))
        (push (ogent-cabinet-schedule--event
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

(defun ogent-cabinet-schedule--conversation-map (roots)
  "Return a hash table mapping schedule keys to conversations under ROOTS."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (root (if (listp roots) roots (list roots)))
      (dolist (conversation (ogent-cabinet-conversation-list root))
        (when-let ((key (plist-get conversation :scheduled-key)))
          (puthash key conversation table))))
    table))

(defun ogent-cabinet-schedule--state (event conversation now)
  "Return EVENT state using CONVERSATION and NOW."
  (cond
   (conversation
    (intern (or (plist-get conversation :status) "done")))
   ((ogent-cabinet-schedule--time< (plist-get event :time) now)
    'missed)
   (t 'upcoming)))

(defun ogent-cabinet-schedule--link-event (event conversation-table now)
  "Return EVENT annotated with conversation linkage and state."
  (let* ((conversation (gethash (plist-get event :schedule-key)
                                conversation-table))
         (state (ogent-cabinet-schedule--state event conversation now)))
    (append
     event
     (list :state state
           :conversation-id (plist-get conversation :id)
           :conversation-path (plist-get conversation :path)
           :conversation conversation))))

(defun ogent-cabinet-schedule--key-source (key fallback-id)
  "Return source metadata parsed from schedule KEY.
FALLBACK-ID is used when KEY does not have the stable Cabinet shape."
  (let ((parts (and key (split-string key "::"))))
    (if (= (length parts) 4)
        (list :source-type (intern (nth 1 parts))
              :source-id (nth 2 parts))
      (list :source-type 'manual
            :source-id fallback-id))))

(defun ogent-cabinet-schedule--manual-events (roots start end generated now)
  "Return scheduled manual conversation events not already in GENERATED."
  (let ((seen (make-hash-table :test 'equal))
        events)
    (dolist (event generated)
      (puthash (plist-get event :schedule-key) t seen))
    (dolist (root (if (listp roots) roots (list roots)))
      (dolist (conversation (ogent-cabinet-conversation-list root))
        (when-let ((scheduled-at (plist-get conversation :scheduled-at)))
          (let* ((time (ogent-cabinet-schedule-parse-time scheduled-at))
                 (key (or (plist-get conversation :scheduled-key)
                          (ogent-cabinet-schedule-key
                           (or (plist-get conversation :agent) "manual")
                           'manual
                           (plist-get conversation :id)
                           time)))
                 (source (ogent-cabinet-schedule--key-source
                          key
                          (plist-get conversation :id))))
            (when (and (not (gethash key seen))
                       (ogent-cabinet-schedule--range-contains-p time start end))
              (puthash key t seen)
              (push (append
                     (list :root root
                           :agent (plist-get conversation :agent)
                           :source-type (plist-get source :source-type)
                           :source-id (plist-get source :source-id)
                           :title (or (plist-get conversation :title)
                                      (plist-get conversation :id))
                           :time (ogent-cabinet-schedule--minute-time time)
                           :minute-iso
                           (ogent-cabinet-schedule--minute-iso time)
                           :schedule-key key
                           :state (ogent-cabinet-schedule--state
                                   (list :time time)
                                   conversation
                                   now)
                           :conversation-id (plist-get conversation :id)
                           :conversation-path (plist-get conversation :path)
                           :conversation conversation
                           :path (plist-get conversation :path)))
                    events))))))
    (nreverse events)))

(defun ogent-cabinet-schedule--local-agent-p (agent)
  "Return non-nil when AGENT jobs are stored in a Cabinet agents directory."
  (memq (plist-get agent :scope) '(cabinet visible)))

;;;###autoload
(cl-defun ogent-cabinet-schedule-events
    (directory start end &key now (include-visible t))
  "Return schedule events under DIRECTORY from START until END.
NOW controls missed-run detection and defaults to the current time."
  (let* ((candidate (ogent-cabinet--directory directory))
         (root (directory-file-name
                (file-truename
                 (ogent-cabinet--directory
                  (or (ogent-cabinet-find-root candidate)
                      candidate)))))
         (start (ogent-cabinet-schedule-parse-time start))
         (end (ogent-cabinet-schedule-parse-time end))
         (now (or (ogent-cabinet-schedule-parse-time now)
                  (current-time)))
         (conversation-roots (if include-visible
                                 (ogent-cabinet-visible-cabinets root)
                               (list root)))
         events)
    (dolist (agent (ogent-cabinet-agent-records
                    root
                    :include-visible include-visible))
      (let ((source-root (or (plist-get agent :source-root) root)))
        (setq events
              (append events
                      (ogent-cabinet-schedule--heartbeat-events
                       source-root agent start end)))
        (when (ogent-cabinet-schedule--local-agent-p agent)
          (dolist (job (ogent-cabinet-list-jobs
                        source-root
                        (plist-get agent :slug)))
            (setq events
                  (append events
                          (ogent-cabinet-schedule--job-events
                           source-root agent job start end)))))))
    (let* ((conversation-table
            (ogent-cabinet-schedule--conversation-map conversation-roots))
           (linked (mapcar (lambda (event)
                             (ogent-cabinet-schedule--link-event
                              event
                              conversation-table
                              now))
                           events)))
      (seq-sort-by
       (lambda (event)
         (plist-get event :minute-iso))
       #'string<
       (append linked
               (ogent-cabinet-schedule--manual-events
                conversation-roots start end linked now))))))

(cl-defun ogent-cabinet-agenda-files (directory &key (include-visible t))
  "Return Org agenda files for DIRECTORY and visible child Cabinets."
  (let* ((candidate (ogent-cabinet--directory directory))
         (root (directory-file-name
                (file-truename
                 (ogent-cabinet--directory
                  (or (ogent-cabinet-find-root candidate)
                      candidate)))))
         (roots (if include-visible
                    (ogent-cabinet-visible-cabinets root)
                  (list root)))
         files)
    (dolist (cabinet-root roots)
      (setq files (append files (ogent-cabinet-org-files cabinet-root))))
    (seq-sort #'string<
              (delete-dups
               (seq-filter #'file-readable-p
                           (mapcar #'expand-file-name files))))))

(defmacro ogent-cabinet-with-agenda-files (directory &rest body)
  "Run BODY with `org-agenda-files' bound to Cabinet files under DIRECTORY."
  (declare (indent 1) (debug t))
  `(let ((org-agenda-files (ogent-cabinet-agenda-files ,directory)))
     ,@body))

;;;###autoload
(defun ogent-cabinet-agenda (&optional directory)
  "Open Org agenda over Cabinet files under DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (ogent-cabinet-with-agenda-files (or directory default-directory)
    (call-interactively #'org-agenda)))

(defun ogent-cabinet-schedule--state-label (state)
  "Return a display label for schedule STATE."
  (pcase state
    ('missed "missed")
    ('upcoming "upcoming")
    ('done "done")
    ('failed "failed")
    ('running "running")
    ('awaiting-input "awaiting")
    (_ (format "%s" state))))

(defun ogent-cabinet-schedule--entry (event)
  "Return a tabulated-list entry for EVENT."
  (list
   event
   (vector
    (format-time-string "%Y-%m-%d %H:%M" (plist-get event :time))
    (ogent-cabinet-schedule--state-label (plist-get event :state))
    (symbol-name (plist-get event :source-type))
    (or (plist-get event :agent) "")
    (or (plist-get event :title) "")
    (or (plist-get event :schedule-key) ""))))

(defun ogent-cabinet-schedule--entries ()
  "Return schedule entries for the current buffer."
  (mapcar #'ogent-cabinet-schedule--entry ogent-cabinet-schedule--events))

(defun ogent-cabinet-schedule--range-label ()
  "Return a concise label for the current schedule range."
  (let ((start (plist-get ogent-cabinet-schedule--range :start))
        (end (plist-get ogent-cabinet-schedule--range :end)))
    (format "%s %s to %s"
            (capitalize (symbol-name ogent-cabinet-schedule--view))
            (format-time-string "%Y-%m-%d" start)
            (format-time-string "%Y-%m-%d" end))))

(defun ogent-cabinet-schedule--render ()
  "Render the current Cabinet schedule buffer."
  (let* ((range (ogent-cabinet-schedule--range
                 ogent-cabinet-schedule--date
                 ogent-cabinet-schedule--view))
         (start (plist-get range :start))
         (end (plist-get range :end)))
    (setq ogent-cabinet-schedule--range range)
    (setq ogent-cabinet-schedule--events
          (ogent-cabinet-schedule-events
           ogent-cabinet-schedule--root
           start
           end
           :now (or ogent-cabinet-schedule--now (current-time))))
    (setq tabulated-list-entries #'ogent-cabinet-schedule--entries)
    (setq header-line-format
          (concat " Cabinet schedule: "
                  (ogent-cabinet-schedule--range-label)
                  "   d day   w week   m month   R run missed   RET open"))
    (tabulated-list-print t)))

(defvar ogent-cabinet-schedule-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-cabinet-schedule-open)
    (define-key map (kbd "<return>") #'ogent-cabinet-schedule-open)
    (define-key map (kbd "<kp-enter>") #'ogent-cabinet-schedule-open)
    (define-key map "R" #'ogent-cabinet-schedule-run-missed)
    (define-key map "d" #'ogent-cabinet-schedule-day-view)
    (define-key map "w" #'ogent-cabinet-schedule-week-view)
    (define-key map "m" #'ogent-cabinet-schedule-month-view)
    (define-key map "g" #'ogent-cabinet-schedule-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-schedule-mode'.")

(define-derived-mode ogent-cabinet-schedule-mode tabulated-list-mode
  "Cabinet-Schedule"
  "Major mode for Cabinet schedule events."
  :group 'ogent-cabinet-schedule
  (setq-local tabulated-list-format
              [("When" 17 t)
               ("State" 10 t)
               ("Source" 10 t)
               ("Agent" 14 t)
               ("Title" 30 t)
               ("Key" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-cabinet-schedule-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-schedule--item ()
  "Return the schedule event at point."
  (or (tabulated-list-get-id)
      (user-error "No Cabinet schedule event at point")))

(defun ogent-cabinet-schedule-open ()
  "Open the conversation or source record for the schedule event at point."
  (interactive)
  (let* ((item (ogent-cabinet-schedule--item))
         (path (or (plist-get item :conversation-path)
                   (plist-get item :path))))
    (unless (and path (file-exists-p path))
      (user-error "No Cabinet schedule source at point"))
    (find-file path)))

(defun ogent-cabinet-schedule--run-event (event)
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
         (plan (ogent-cabinet-runner-plan
                root
                agent
                :job-id job-id
                :instruction instruction
                :trigger (symbol-name source-type)
                :conversation-title (plist-get event :title)
                :scheduled-at (plist-get event :minute-iso)
                :scheduled-key (plist-get event :schedule-key))))
    (when (ogent-cabinet-runner--confirm plan)
      (ogent-cabinet-runner-start plan))))

(defun ogent-cabinet-schedule-run-missed ()
  "Run the missed Cabinet schedule event at point."
  (interactive)
  (let ((event (ogent-cabinet-schedule--item)))
    (unless (eq (plist-get event :state) 'missed)
      (user-error "The selected schedule event is not missed"))
    (ogent-cabinet-schedule--run-event event)))

(defun ogent-cabinet-schedule-refresh (&rest _)
  "Refresh the current Cabinet schedule buffer."
  (interactive)
  (ogent-cabinet-schedule--render))

(defun ogent-cabinet-schedule-day-view ()
  "Switch the current schedule buffer to day view."
  (interactive)
  (setq ogent-cabinet-schedule--view 'day)
  (ogent-cabinet-schedule--render))

(defun ogent-cabinet-schedule-week-view ()
  "Switch the current schedule buffer to week view."
  (interactive)
  (setq ogent-cabinet-schedule--view 'week)
  (ogent-cabinet-schedule--render))

(defun ogent-cabinet-schedule-month-view ()
  "Switch the current schedule buffer to month view."
  (interactive)
  (setq ogent-cabinet-schedule--view 'month)
  (ogent-cabinet-schedule--render))

;;;###autoload
(cl-defun ogent-cabinet-schedule (&optional directory &key view date now)
  "Open the Cabinet schedule for DIRECTORY.
VIEW may be `day', `week', or `month'.  DATE anchors the range.  NOW is used
for deterministic missed-run detection."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (directory-file-name
                (file-truename
                 (ogent-cabinet--directory
                  (or (ogent-cabinet-find-root
                       (ogent-cabinet--directory
                        (or directory default-directory)))
                      directory
                      default-directory)))))
         (buffer (get-buffer-create
                  (format ogent-cabinet-schedule-buffer-name-format
                          (file-name-nondirectory root)))))
    (with-current-buffer buffer
      (ogent-cabinet-schedule-mode)
      (setq ogent-cabinet-schedule--root root)
      (setq ogent-cabinet-schedule--view (or view 'week))
      (setq ogent-cabinet-schedule--date (or date (current-time)))
      (setq ogent-cabinet-schedule--now now)
      (setq default-directory (file-name-as-directory root))
      (ogent-cabinet-schedule--render))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(defun ogent-cabinet-schedule--evil-local-keys ()
  "Install local Evil keys for Cabinet schedule."
  (ogent-cabinet-evil-install-local-bindings ogent-cabinet-schedule-mode-map))

(defun ogent-cabinet-schedule--setup-evil ()
  "Set up Evil integration for Cabinet schedule."
  (ogent-cabinet-evil-setup-mode
   'ogent-cabinet-schedule-mode
   ogent-cabinet-schedule-mode-map
   'ogent-cabinet-schedule-mode-hook
   #'ogent-cabinet-schedule--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-cabinet-schedule--setup-evil))

(provide 'ogent-cabinet-schedule)

;;; ogent-cabinet-schedule.el ends here
