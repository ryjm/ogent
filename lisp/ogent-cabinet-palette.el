;;; ogent-cabinet-palette.el --- Cabinet ranked search and palette -*- lexical-binding: t; -*-

;;; Commentary:
;; Rebuildable search index and command palette across Cabinet records,
;; commands, apps, and git actions.

;;; Code:

(require 'cl-lib)
(require 'browse-url)
(require 'seq)
(require 'subr-x)
(require 'ogent-cabinet)
(require 'ogent-cabinet-conversations)
(require 'ogent-cabinet-data)
(require 'ogent-cabinet-schedule)
(require 'ogent-cabinet-git)

(defgroup ogent-cabinet-palette nil
  "Ranked search and command palette for Cabinets."
  :group 'ogent-cabinet)

(defun ogent-cabinet-search-index-file (directory)
  "Return the search index cache file under DIRECTORY."
  (expand-file-name ".cabinet-state/search.el"
                    (ogent-cabinet-data--root directory)))

(defun ogent-cabinet-palette--command-records (root)
  "Return command records for ROOT."
  `((:kind command :title "Cabinet Home" :command ogent-cabinet-home
     :path ,root :text "home overview")
    (:kind command :title "Cabinet Data" :command ogent-cabinet-data
     :path ,root :text "data browser pages files")
    (:kind command :title "Cabinet Agents" :command ogent-cabinet-agents
     :path ,root :text "agents personas")
    (:kind command :title "Cabinet Tasks" :command ogent-cabinet-tasks
     :path ,root :text "tasks board")
    (:kind command :title "Cabinet Conversations"
     :command ogent-cabinet-conversations :path ,root :text "runs transcripts")
    (:kind command :title "Cabinet Schedule"
     :command ogent-cabinet-schedule :path ,root :text "calendar jobs heartbeats")
    (:kind command :title "Cabinet Apps" :command ogent-cabinet-apps
     :path ,root :text "generated apps html")
    (:kind command :title "Cabinet Git Status"
     :command ogent-cabinet-git-status :path ,root :text "git dirty status")
    (:kind command :title "Cabinet Agenda"
     :command ogent-cabinet-agenda :path ,root :text "org agenda")))

(defun ogent-cabinet-palette--file-text (record)
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

(defun ogent-cabinet-palette--file-records (root)
  "Return indexed data file records for ROOT."
  (mapcar
   (lambda (record)
     (list :kind (plist-get record :kind)
           :title (plist-get record :title)
           :path (plist-get record :path)
           :relative (plist-get record :relative)
           :text (ogent-cabinet-palette--file-text record)))
   (ogent-cabinet-data-records root)))

(defun ogent-cabinet-palette--agent-records (root)
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
   (ogent-cabinet-agent-records root :include-visible t)))

(defun ogent-cabinet-palette--job-records (root)
  "Return indexed job records for ROOT."
  (let (records)
    (dolist (agent (ogent-cabinet-agent-records root :include-visible t))
      (when (memq (plist-get agent :scope) '(cabinet visible))
        (let ((source-root (or (plist-get agent :source-root) root)))
          (dolist (job (ogent-cabinet-list-jobs
                        source-root
                        (plist-get agent :slug)))
            (push (list :kind 'job
                        :title (or (plist-get job :name)
                                   (plist-get job :id))
                        :path (ogent-cabinet-job-file
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

(defun ogent-cabinet-palette--conversation-records (root)
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
   (ogent-cabinet-conversation-list root)))

(defun ogent-cabinet-palette--app-records (root)
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
   (ogent-cabinet-list-apps root)))

;;;###autoload
(defun ogent-cabinet-search-index-build (directory)
  "Build and persist the Cabinet search index for DIRECTORY."
  (let* ((root (ogent-cabinet-data--root directory))
         (records (append (ogent-cabinet-palette--command-records root)
                          (ogent-cabinet-palette--file-records root)
                          (ogent-cabinet-palette--agent-records root)
                          (ogent-cabinet-palette--job-records root)
                          (ogent-cabinet-palette--conversation-records root)
                          (ogent-cabinet-palette--app-records root)))
         (file (ogent-cabinet-search-index-file root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (prin1 records (current-buffer)))
    records))

(defun ogent-cabinet-search-index-read (directory)
  "Read the Cabinet search index for DIRECTORY, rebuilding when missing."
  (let ((file (ogent-cabinet-search-index-file directory)))
    (if (file-readable-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (read (current-buffer)))
      (ogent-cabinet-search-index-build directory))))

(defun ogent-cabinet-palette--score (record query)
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
(cl-defun ogent-cabinet-ranked-search (directory query &key limit rebuild)
  "Return ranked Cabinet records under DIRECTORY for QUERY.
When REBUILD is non-nil, refresh the persisted index first."
  (let* ((records (if rebuild
                      (ogent-cabinet-search-index-build directory)
                    (ogent-cabinet-search-index-read directory)))
         (scored (delq
                  nil
                  (mapcar
                   (lambda (record)
                     (let ((score (ogent-cabinet-palette--score record query)))
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

(defun ogent-cabinet-palette--display (record)
  "Return a completion display string for RECORD."
  (format "%s  %s  %s"
          (upcase (symbol-name (plist-get record :kind)))
          (or (plist-get record :title) "")
          (or (plist-get record :relative)
              (plist-get record :path)
              "")))

(defun ogent-cabinet-palette-open-record (record)
  "Open RECORD using its command or file path."
  (pcase (plist-get record :kind)
    ('command
     (funcall (plist-get record :command) (plist-get record :path)))
    ('app
     (browse-url-of-file (plist-get record :path)))
    (_
     (ogent-cabinet-open-file (plist-get record :path)))))

;;;###autoload
(defun ogent-cabinet-command-palette (&optional directory query)
  "Open a ranked Cabinet command/search palette for DIRECTORY."
  (interactive
   (let ((root (or (ogent-cabinet-find-root)
                   (read-directory-name "Cabinet root: "))))
     (list root (read-string "Cabinet palette: "))))
  (let* ((root (ogent-cabinet-data--root (or directory default-directory)))
         (records (ogent-cabinet-ranked-search
                   root
                   (or query "")
                   :rebuild t))
         (choices (mapcar (lambda (record)
                            (cons (ogent-cabinet-palette--display record)
                                  record))
                          records))
         (choice (completing-read "Cabinet: " choices nil t)))
    (ogent-cabinet-palette-open-record (cdr (assoc choice choices)))))

(provide 'ogent-cabinet-palette)

;;; ogent-cabinet-palette.el ends here
