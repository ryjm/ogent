;;; ogent-armory-palette.el --- Armory ranked search and palette -*- lexical-binding: t; -*-

;;; Commentary:
;; Rebuildable search index and command palette across Armory records,
;; commands, apps, and git actions.

;;; Code:

(require 'cl-lib)
(require 'browse-url)
(require 'seq)
(require 'subr-x)
(require 'ogent-armory)
(require 'ogent-armory-conversations)
(require 'ogent-armory-data)
(require 'ogent-armory-schedule)
(require 'ogent-armory-git)
(require 'ogent-armory-settings)

(defgroup ogent-armory-palette nil
  "Ranked search and command palette for Armories."
  :group 'ogent-armory)

(defun ogent-armory-search-index-file (directory)
  "Return the search index cache file under DIRECTORY."
  (expand-file-name ".armory-state/search.el"
                    (ogent-armory-data--root directory)))

(defun ogent-armory-palette--command-records (root)
  "Return command records for ROOT."
  `((:kind command :title "Armory Home" :command ogent-armory-home
     :path ,root :text "home overview")
    (:kind command :title "Armory Data" :command ogent-armory-data
     :path ,root :text "data browser pages files")
    (:kind command :title "Armory Agents" :command ogent-armory-agents
     :path ,root :text "agents personas")
    (:kind command :title "Create Armory Task"
     :command ogent-armory-create-task :path ,root
     :text "capture task todo inbox manual")
    (:kind command :title "Armory Tasks" :command ogent-armory-tasks
     :path ,root :text "tasks board")
    (:kind command :title "Armory Conversations"
     :command ogent-armory-conversations :path ,root :text "runs transcripts")
    (:kind command :title "Armory Schedule"
     :command ogent-armory-schedule :path ,root :text "calendar jobs heartbeats")
    (:kind command :title "Armory Apps" :command ogent-armory-apps
     :path ,root :text "generated apps html")
    (:kind command :title "Armory Git Status"
     :command ogent-armory-git-status :path ,root :text "git dirty status")
    (:kind command :title "Armory Settings"
     :command ogent-armory-settings :path ,root :text "settings providers storage")
    (:kind command :title "Armory Help"
     :command ogent-armory-help :path ,root :text "help shortcuts demo")
    (:kind command :title "Armory Onboard"
     :command ogent-armory-onboard :path ,root :text "setup storage provider team")
    (:kind command :title "Armory Registry Import"
     :command ogent-armory-registry-import-into :path ,root :text "template manifest import")
    (:kind command :title "Armory Backup"
     :command ogent-armory-backup :path ,root :text "backup durable org data")
    (:kind command :title "Armory Agenda"
     :command ogent-armory-agenda :path ,root :text "org agenda")))

(defun ogent-armory-palette--file-text (record)
  "Return searchable text for data RECORD."
  (let ((path (plist-get record :path))
        (relative (plist-get record :relative)))
    (string-join
     (delq nil
           (list relative
                 (when (and (eq (plist-get record :kind) 'page)
                            (file-readable-p path))
                   (with-temp-buffer
                     (insert-file-contents path)
                     (buffer-string)))))
     "\n")))

(defun ogent-armory-palette--file-records (root)
  "Return indexed data file records for ROOT."
  (mapcar
   (lambda (record)
     (list :kind (plist-get record :kind)
           :title (plist-get record :title)
           :path (plist-get record :path)
           :relative (plist-get record :relative)
           :text (ogent-armory-palette--file-text record)))
   (ogent-armory-data-records root)))

(defun ogent-armory-palette--agent-records (root)
  "Return indexed agent records for ROOT."
  (mapcar
   (lambda (agent)
     (list :kind 'agent
           :title (or (plist-get agent :display-name)
                      (plist-get agent :name)
                      (plist-get agent :slug))
           :path (plist-get agent :path)
           :agent (plist-get agent :slug)
           :text (string-join
                  (delq nil
                        (list (plist-get agent :role)
                              (plist-get agent :department)
                              (plist-get agent :type)))
                  " ")))
   (ogent-armory-agent-records root :include-visible t)))

(defun ogent-armory-palette--job-records (root)
  "Return indexed job records for ROOT."
  (let (records)
    (dolist (agent (ogent-armory-agent-records root :include-visible t))
      (when (memq (plist-get agent :scope) '(armory visible))
        (let ((source-root (or (plist-get agent :source-root) root)))
          (dolist (job (ogent-armory-list-jobs
                        source-root
                        (plist-get agent :slug)))
            (push (list :kind 'job
                        :title (or (plist-get job :name)
                                   (plist-get job :id))
                        :path (ogent-armory-job-file
                               source-root
                               (plist-get agent :slug)
                               (plist-get job :id))
                        :agent (plist-get agent :slug)
                        :job-id (plist-get job :id)
                        :text (string-join
                               (delq nil
                                     (list (plist-get job :cron)
                                           (plist-get job :run-after)
                                           (plist-get job :body)))
                               " "))
                  records)))))
    (nreverse records)))

(defun ogent-armory-palette--conversation-records (root)
  "Return indexed conversation records for ROOT."
  (mapcar
   (lambda (conversation)
     (list :kind 'conversation
           :title (or (plist-get conversation :title)
                      (plist-get conversation :id))
           :path (plist-get conversation :path)
           :agent (plist-get conversation :agent)
           :conversation-id (plist-get conversation :id)
           :text (string-join
                  (delq nil
                        (list (plist-get conversation :status)
                              (plist-get conversation :summary)
                              (plist-get conversation :job-id)))
                  " ")))
   (ogent-armory-conversation-list root)))

(defun ogent-armory-palette--app-records (root)
  "Return indexed app records for ROOT."
  (mapcar
   (lambda (app)
     (list :kind 'app
           :title (plist-get app :label)
           :path (plist-get app :path)
           :agent (plist-get app :agent)
           :conversation-id (plist-get app :conversation-id)
           :text (string-join
                  (delq nil
                        (list (plist-get app :directory)
                              (plist-get app :job-id)))
                  " ")))
   (ogent-armory-list-apps root)))

;;;###autoload
(defun ogent-armory-search-index-build (directory)
  "Build and persist the Armory search index for DIRECTORY."
  (let* ((root (ogent-armory-data--root directory))
         (records (append (ogent-armory-palette--command-records root)
                          (ogent-armory-palette--file-records root)
                          (ogent-armory-palette--agent-records root)
                          (ogent-armory-palette--job-records root)
                          (ogent-armory-palette--conversation-records root)
                          (ogent-armory-palette--app-records root)))
         (file (ogent-armory-search-index-file root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (prin1 records (current-buffer)))
    records))

(defun ogent-armory-search-index-read (directory)
  "Read the Armory search index for DIRECTORY, rebuilding when missing."
  (let ((file (ogent-armory-search-index-file directory)))
    (if (file-readable-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (read (current-buffer)))
      (ogent-armory-search-index-build directory))))

(defun ogent-armory-palette--score (record query)
  "Return a rank score for RECORD against QUERY."
  (let* ((needle (downcase (string-trim (or query ""))))
         (title (downcase (or (plist-get record :title) "")))
         (path (downcase (or (plist-get record :relative)
                             (plist-get record :path)
                             "")))
         (text (downcase (or (plist-get record :text) ""))))
    (cond
     ((string-empty-p needle) 1)
     ((equal title needle) 1000)
     ((string-prefix-p needle title) 750)
     ((string-match-p (regexp-quote needle) title) 500)
     ((string-match-p (regexp-quote needle) path) 300)
     ((string-match-p (regexp-quote needle) text) 150)
     (t 0))))

;;;###autoload
(cl-defun ogent-armory-ranked-search (directory query &key limit rebuild)
  "Return ranked Armory records under DIRECTORY for QUERY.
When REBUILD is non-nil, refresh the persisted index first."
  (let* ((records (if rebuild
                      (ogent-armory-search-index-build directory)
                    (ogent-armory-search-index-read directory)))
         (scored (delq
                  nil
                  (mapcar
                   (lambda (record)
                     (let ((score (ogent-armory-palette--score record query)))
                       (when (> score 0)
                         (append record (list :score score)))))
                   records))))
    (setq scored (seq-sort-by
                  (lambda (record)
                    (- (plist-get record :score)))
                  #'<
                  scored))
    (if limit
        (seq-take scored limit)
      scored)))

(defun ogent-armory-palette--display (record)
  "Return a completion display string for RECORD."
  (format "%s  %s  %s"
          (upcase (symbol-name (plist-get record :kind)))
          (or (plist-get record :title) "")
          (or (plist-get record :relative)
              (plist-get record :path)
              "")))

(defun ogent-armory-palette-open-record (record)
  "Open RECORD using its command or file path."
  (pcase (plist-get record :kind)
    ('command
     (funcall (plist-get record :command) (plist-get record :path)))
    ('app
     (browse-url-of-file (plist-get record :path)))
    (_
     (ogent-armory-open-file (plist-get record :path)))))

;;;###autoload
(defun ogent-armory-command-palette (&optional directory query)
  "Open a ranked Armory command/search palette for DIRECTORY."
  (interactive
   (let ((root (or (ogent-armory-find-root)
                   (read-directory-name "Armory root: "))))
     (list root (read-string "Armory palette: "))))
  (let* ((root (ogent-armory-data--root (or directory default-directory)))
         (records (ogent-armory-ranked-search
                   root
                   (or query "")
                   :rebuild t))
         (choices (mapcar (lambda (record)
                            (cons (ogent-armory-palette--display record)
                                  record))
                          records))
         (choice (completing-read "Armory: " choices nil t)))
    (ogent-armory-palette-open-record (cdr (assoc choice choices)))))

(provide 'ogent-armory-palette)

;;; ogent-armory-palette.el ends here
