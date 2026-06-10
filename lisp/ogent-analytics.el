;;; ogent-analytics.el --- Analytics and benchmarking for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Tracks prompt effectiveness and provides analytics for ogent sessions.
;;
;; Metrics tracked:
;; - Response quality ratings (accept/reject + optional thumbs up/down)
;; - Token usage (estimated via ~4 chars/token)
;; - Model comparison stats
;; - Time-to-first-token and completion latency
;; - Accept/reject ratio
;;
;; Storage:
;; - Per-project SQLite database (.ogent-analytics.db)
;;
;; Usage:
;;   C-c . + - Rate current completion thumbs up
;;   C-c . - - Rate current completion thumbs down
;;   M-x ogent-analytics-dashboard - View analytics

;;; Code:

(require 'cl-lib)
(require 'sqlite)
(require 'json)

;; Forward declarations
;; Struct accessors (fileonly: cl-defstruct-generated)
(declare-function ogent-completion-marker "ogent-completions" t t)
(declare-function ogent-completion-model "ogent-completions" t t)
(declare-function ogent-completions--current "ogent-completions")
(declare-function ogent-completions--find-question-marker "ogent-completions")

(defgroup ogent-analytics nil
  "Analytics and benchmarking for ogent."
  :group 'ogent)

(defcustom ogent-analytics-enabled t
  "When non-nil, track analytics data."
  :type 'boolean
  :group 'ogent-analytics)

(defcustom ogent-analytics-db-name ".ogent-analytics.db"
  "Name of the analytics database file.
This is created in the project root."
  :type 'string
  :group 'ogent-analytics)

(defcustom ogent-analytics-chars-per-token 4.0
  "Approximate characters per token for estimation.
Used to estimate token counts from text length."
  :type 'number
  :group 'ogent-analytics)

;;; Database

(defvar ogent-analytics--db-cache (make-hash-table :test 'equal)
  "Cache of open database connections by project path.")

(defun ogent-analytics--project-root ()
  "Get the project root directory, or default-directory."
  (or (when (fboundp 'project-root)
        (when-let ((proj (project-current)))
          (project-root proj)))
      (locate-dominating-file default-directory ".git")
      default-directory))

(defun ogent-analytics--db-path ()
  "Get the path to the analytics database for current project."
  (expand-file-name ogent-analytics-db-name (ogent-analytics--project-root)))

(defun ogent-analytics--db-valid-p (db)
  "Check if DB is a valid sqlite connection."
  (and db
       (or (and (fboundp 'sqlitep) (sqlitep db))
           (and (fboundp 'sqlite-p) (sqlite-p db))
           ;; Fallback: check if it's a user-ptr (sqlite objects are user-ptrs)
           (user-ptrp db))))

(defun ogent-analytics--get-db ()
  "Get or create SQLite database connection for current project.
Returns nil if sqlite is not available."
  (when (and ogent-analytics-enabled
             (fboundp 'sqlite-available-p)
             (sqlite-available-p))
    (let* ((db-path (ogent-analytics--db-path))
           (cached (gethash db-path ogent-analytics--db-cache)))
      (if (ogent-analytics--db-valid-p cached)
          cached
        ;; Create new connection
        (let ((db (sqlite-open db-path)))
          (when db
            (ogent-analytics--init-schema db)
            (puthash db-path db ogent-analytics--db-cache))
          db)))))

(defun ogent-analytics--init-schema (db)
  "Initialize database schema in DB."
  ;; Completions table - tracks each completion event
  (sqlite-execute db "
    CREATE TABLE IF NOT EXISTS completions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp TEXT NOT NULL DEFAULT (datetime('now')),
      session_id TEXT,
      model TEXT NOT NULL,
      prompt_template TEXT,
      prompt_tokens INTEGER,
      response_tokens INTEGER,
      total_tokens INTEGER,
      time_to_first_token_ms INTEGER,
      completion_latency_ms INTEGER,
      outcome TEXT CHECK(outcome IN ('accepted', 'rejected', 'pending')),
      rating INTEGER CHECK(rating IN (-1, 0, 1)),
      question_preview TEXT,
      response_preview TEXT
    )")
  ;; Model stats view
  (sqlite-execute db "
    CREATE VIEW IF NOT EXISTS model_stats AS
    SELECT
      model,
      COUNT(*) as total_completions,
      SUM(CASE WHEN outcome = 'accepted' THEN 1 ELSE 0 END) as accepted,
      SUM(CASE WHEN outcome = 'rejected' THEN 1 ELSE 0 END) as rejected,
      ROUND(100.0 * SUM(CASE WHEN outcome = 'accepted' THEN 1 ELSE 0 END) / COUNT(*), 1) as accept_rate,
      AVG(total_tokens) as avg_tokens,
      AVG(completion_latency_ms) as avg_latency_ms,
      SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END) as thumbs_up,
      SUM(CASE WHEN rating = -1 THEN 1 ELSE 0 END) as thumbs_down
    FROM completions
    GROUP BY model")
  ;; Daily stats view
  (sqlite-execute db "
    CREATE VIEW IF NOT EXISTS daily_stats AS
    SELECT
      date(timestamp) as date,
      COUNT(*) as completions,
      SUM(CASE WHEN outcome = 'accepted' THEN 1 ELSE 0 END) as accepted,
      SUM(CASE WHEN outcome = 'rejected' THEN 1 ELSE 0 END) as rejected,
      SUM(total_tokens) as total_tokens,
      AVG(completion_latency_ms) as avg_latency_ms
    FROM completions
    GROUP BY date(timestamp)
    ORDER BY date DESC"))

;;; Token Estimation

(defun ogent-analytics-estimate-tokens (text)
  "Estimate token count for TEXT using character-based heuristic."
  (if (stringp text)
      (round (/ (float (length text)) ogent-analytics-chars-per-token))
    0))

;;; Completion Tracking

(defvar ogent-analytics--pending-completion nil
  "Currently pending completion being tracked.")

(defvar ogent-analytics--request-start-time nil
  "Start time of current request.")

(defvar ogent-analytics--first-token-time nil
  "Time when first token was received.")

(cl-defstruct ogent-analytics-completion
  "Structure tracking a completion for analytics."
  id                    ; Database row ID (nil until saved)
  session-id            ; Session identifier
  model                 ; Model name
  prompt-template       ; Template used (if any)
  prompt-tokens         ; Estimated prompt tokens
  response-tokens       ; Estimated response tokens
  ttft-ms               ; Time to first token in ms
  latency-ms            ; Total completion latency in ms
  outcome               ; 'pending, 'accepted, 'rejected
  rating                ; -1 (thumbs down), 0 (no rating), 1 (thumbs up)
  question-preview      ; First 200 chars of question
  response-preview)     ; First 200 chars of response

(defun ogent-analytics--truncate (text max-len)
  "Truncate TEXT to MAX-LEN characters."
  (if (and text (> (length text) max-len))
      (substring text 0 max-len)
    text))

(defun ogent-analytics-start-request ()
  "Mark the start of a new request."
  (setq ogent-analytics--request-start-time (current-time))
  (setq ogent-analytics--first-token-time nil))

(defun ogent-analytics-first-token ()
  "Mark when first token is received."
  (unless ogent-analytics--first-token-time
    (setq ogent-analytics--first-token-time (current-time))))

(defun ogent-analytics-record-completion (model prompt response &optional template)
  "Record a completion with MODEL, PROMPT, RESPONSE, and optional TEMPLATE."
  (when ogent-analytics-enabled
    (let* ((now (current-time))
           (start ogent-analytics--request-start-time)
           (first-token ogent-analytics--first-token-time)
           (ttft-ms (when (and start first-token)
                      (round (* 1000 (float-time (time-subtract first-token start))))))
           (latency-ms (when start
                         (round (* 1000 (float-time (time-subtract now start))))))
           (prompt-tokens (ogent-analytics-estimate-tokens prompt))
           (response-tokens (ogent-analytics-estimate-tokens response))
           (completion (make-ogent-analytics-completion
                        :session-id (when (boundp 'ogent-session-id) ogent-session-id)
                        :model model
                        :prompt-template template
                        :prompt-tokens prompt-tokens
                        :response-tokens response-tokens
                        :ttft-ms ttft-ms
                        :latency-ms latency-ms
                        :outcome 'pending
                        :rating 0
                        :question-preview (ogent-analytics--truncate prompt 200)
                        :response-preview (ogent-analytics--truncate response 200))))
      ;; Save to database
      (ogent-analytics--save-completion completion)
      ;; Store as pending for rating
      (setq ogent-analytics--pending-completion completion)
      ;; Reset timing
      (setq ogent-analytics--request-start-time nil)
      (setq ogent-analytics--first-token-time nil)
      completion)))

(defun ogent-analytics--save-completion (completion)
  "Save COMPLETION to database, updating its ID."
  (when-let ((db (ogent-analytics--get-db)))
    (sqlite-execute db "
      INSERT INTO completions (
        session_id, model, prompt_template,
        prompt_tokens, response_tokens, total_tokens,
        time_to_first_token_ms, completion_latency_ms,
        outcome, rating, question_preview, response_preview
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
      (list
       (ogent-analytics-completion-session-id completion)
       (ogent-analytics-completion-model completion)
       (ogent-analytics-completion-prompt-template completion)
       (ogent-analytics-completion-prompt-tokens completion)
       (ogent-analytics-completion-response-tokens completion)
       (+ (or (ogent-analytics-completion-prompt-tokens completion) 0)
          (or (ogent-analytics-completion-response-tokens completion) 0))
       (ogent-analytics-completion-ttft-ms completion)
       (ogent-analytics-completion-latency-ms completion)
       (symbol-name (ogent-analytics-completion-outcome completion))
       (ogent-analytics-completion-rating completion)
       (ogent-analytics-completion-question-preview completion)
       (ogent-analytics-completion-response-preview completion)))
    ;; Get the inserted row ID
    (let ((result (sqlite-select db "SELECT last_insert_rowid()")))
      (when result
        (setf (ogent-analytics-completion-id completion) (caar result))))))

(defun ogent-analytics--update-completion (completion)
  "Update existing COMPLETION in database."
  (when-let ((db (ogent-analytics--get-db))
             (id (ogent-analytics-completion-id completion)))
    (sqlite-execute db "
      UPDATE completions SET
        outcome = ?,
        rating = ?
      WHERE id = ?"
      (list
       (symbol-name (ogent-analytics-completion-outcome completion))
       (ogent-analytics-completion-rating completion)
       id))))

;;; Accept/Reject Integration

(defun ogent-analytics-mark-accepted ()
  "Mark the pending completion as accepted."
  (when ogent-analytics--pending-completion
    (setf (ogent-analytics-completion-outcome ogent-analytics--pending-completion) 'accepted)
    (ogent-analytics--update-completion ogent-analytics--pending-completion)))

(defun ogent-analytics-mark-rejected ()
  "Mark the pending completion as rejected."
  (when ogent-analytics--pending-completion
    (setf (ogent-analytics-completion-outcome ogent-analytics--pending-completion) 'rejected)
    (ogent-analytics--update-completion ogent-analytics--pending-completion)))

;;; Rating Commands

;;;###autoload
(defun ogent-analytics-rate-up ()
  "Rate the current/last completion as thumbs up."
  (interactive)
  (if ogent-analytics--pending-completion
      (progn
        (setf (ogent-analytics-completion-rating ogent-analytics--pending-completion) 1)
        (ogent-analytics--update-completion ogent-analytics--pending-completion)
        (message "Rated completion as thumbs up"))
    (message "No pending completion to rate")))

;;;###autoload
(defun ogent-analytics-rate-down ()
  "Rate the current/last completion as thumbs down."
  (interactive)
  (if ogent-analytics--pending-completion
      (progn
        (setf (ogent-analytics-completion-rating ogent-analytics--pending-completion) -1)
        (ogent-analytics--update-completion ogent-analytics--pending-completion)
        (message "Rated completion as thumbs down"))
    (message "No pending completion to rate")))

;;; Dashboard

(defvar ogent-analytics-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'ogent-analytics-dashboard-refresh)
    (define-key map (kbd "e") #'ogent-analytics-export-csv)
    (define-key map (kbd "o") #'ogent-analytics-export-org)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `ogent-analytics-dashboard-mode'.")

(define-derived-mode ogent-analytics-dashboard-mode special-mode "OgAnalytics"
  "Major mode for viewing ogent analytics dashboard.

\\{ogent-analytics-dashboard-mode-map}"
  :group 'ogent-analytics
  (setq truncate-lines t))

(defun ogent-analytics--format-number (n)
  "Format number N for display."
  (cond
   ((null n) "-")
   ((floatp n) (format "%.1f" n))
   (t (format "%d" n))))

(defun ogent-analytics--format-latency (ms)
  "Format latency MS for display."
  (cond
   ((null ms) "-")
   ((< ms 1000) (format "%dms" ms))
   (t (format "%.1fs" (/ ms 1000.0)))))

;;;###autoload
(defun ogent-analytics-dashboard ()
  "Open the ogent analytics dashboard."
  (interactive)
  (let ((buf (get-buffer-create "*ogent-analytics*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (ogent-analytics--insert-dashboard))
      (goto-char (point-min))
      (ogent-analytics-dashboard-mode))
    (pop-to-buffer buf)))

(defun ogent-analytics-dashboard-refresh ()
  "Refresh the analytics dashboard."
  (interactive)
  (ogent-analytics-dashboard))

(defun ogent-analytics--insert-dashboard ()
  "Insert dashboard content into current buffer."
  (let ((db (ogent-analytics--get-db)))
    (insert "# Ogent Analytics Dashboard\n")
    (insert (format "# Project: %s\n" (ogent-analytics--project-root)))
    (insert "# Keys: g=refresh  e=export CSV  o=export org  q=quit\n\n")
    (if (null db)
        (insert "SQLite not available or database not initialized.\n")
      ;; Overall stats
      (insert "## Overall Statistics\n\n")
      (let ((totals (car (sqlite-select db "
        SELECT
          COUNT(*) as total,
          SUM(CASE WHEN outcome = 'accepted' THEN 1 ELSE 0 END) as accepted,
          SUM(CASE WHEN outcome = 'rejected' THEN 1 ELSE 0 END) as rejected,
          ROUND(100.0 * SUM(CASE WHEN outcome = 'accepted' THEN 1 ELSE 0 END) /
                NULLIF(SUM(CASE WHEN outcome IN ('accepted', 'rejected') THEN 1 ELSE 0 END), 0), 1) as accept_rate,
          SUM(total_tokens) as total_tokens,
          AVG(completion_latency_ms) as avg_latency,
          SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END) as thumbs_up,
          SUM(CASE WHEN rating = -1 THEN 1 ELSE 0 END) as thumbs_down
        FROM completions"))))
        (if (or (null totals) (null (nth 0 totals)) (= (nth 0 totals) 0))
            (insert "No completions recorded yet.\n\n")
          (insert (format "| Metric           | Value     |\n"))
          (insert (format "|------------------|----------|\n"))
          (insert (format "| Total Completions | %s |\n" (ogent-analytics--format-number (nth 0 totals))))
          (insert (format "| Accepted         | %s |\n" (ogent-analytics--format-number (nth 1 totals))))
          (insert (format "| Rejected         | %s |\n" (ogent-analytics--format-number (nth 2 totals))))
          (insert (format "| Accept Rate      | %s%% |\n" (ogent-analytics--format-number (nth 3 totals))))
          (insert (format "| Total Tokens     | %s |\n" (ogent-analytics--format-number (nth 4 totals))))
          (insert (format "| Avg Latency      | %s |\n" (ogent-analytics--format-latency (nth 5 totals))))
          (insert (format "| Thumbs Up        | %s |\n" (ogent-analytics--format-number (nth 6 totals))))
          (insert (format "| Thumbs Down      | %s |\n" (ogent-analytics--format-number (nth 7 totals))))
          (insert "\n")))
      ;; Model comparison
      (insert "## Model Comparison\n\n")
      (let ((models (sqlite-select db "SELECT * FROM model_stats ORDER BY total_completions DESC")))
        (if (null models)
            (insert "No model data available.\n\n")
          (insert "| Model | Completions | Accepted | Rejected | Accept% | Avg Tokens | Avg Latency | +1 | -1 |\n")
          (insert "|-------|-------------|----------|----------|---------|------------|-------------|----|----|")
          (insert "\n")
          (dolist (row models)
            (insert (format "| %s | %s | %s | %s | %s%% | %s | %s | %s | %s |\n"
                            (or (nth 0 row) "unknown")
                            (ogent-analytics--format-number (nth 1 row))
                            (ogent-analytics--format-number (nth 2 row))
                            (ogent-analytics--format-number (nth 3 row))
                            (ogent-analytics--format-number (nth 4 row))
                            (ogent-analytics--format-number (nth 5 row))
                            (ogent-analytics--format-latency (nth 6 row))
                            (ogent-analytics--format-number (nth 7 row))
                            (ogent-analytics--format-number (nth 8 row)))))
          (insert "\n")))
      ;; Recent activity
      (insert "## Recent Activity (Last 7 Days)\n\n")
      (let ((daily (sqlite-select db "SELECT * FROM daily_stats LIMIT 7")))
        (if (null daily)
            (insert "No recent activity.\n\n")
          (insert "| Date | Completions | Accepted | Rejected | Tokens | Avg Latency |\n")
          (insert "|------|-------------|----------|----------|--------|-------------|\n")
          (dolist (row daily)
            (insert (format "| %s | %s | %s | %s | %s | %s |\n"
                            (or (nth 0 row) "-")
                            (ogent-analytics--format-number (nth 1 row))
                            (ogent-analytics--format-number (nth 2 row))
                            (ogent-analytics--format-number (nth 3 row))
                            (ogent-analytics--format-number (nth 4 row))
                            (ogent-analytics--format-latency (nth 5 row)))))
          (insert "\n")))
      ;; Recent completions
      (insert "## Recent Completions\n\n")
      (let ((recent (sqlite-select db "
        SELECT timestamp, model, outcome, rating, total_tokens,
               completion_latency_ms, response_preview
        FROM completions
        ORDER BY timestamp DESC
        LIMIT 10")))
        (if (null recent)
            (insert "No completions recorded.\n")
          (dolist (row recent)
            (let ((timestamp (nth 0 row))
                  (model (nth 1 row))
                  (outcome (nth 2 row))
                  (rating (nth 3 row))
                  (tokens (nth 4 row))
                  (latency (nth 5 row))
                  (preview (nth 6 row)))
              (insert (format "### %s - %s [%s]\n"
                              timestamp model
                              (cond
                               ((string= outcome "accepted") "ACCEPTED")
                               ((string= outcome "rejected") "REJECTED")
                               (t "pending"))))
              (insert (format "Tokens: %s | Latency: %s | Rating: %s\n"
                              (ogent-analytics--format-number tokens)
                              (ogent-analytics--format-latency latency)
                              (cond
                               ((= rating 1) "")
                               ((= rating -1) "")
                               (t "-"))))
              (when preview
                (insert (format "> %s\n" (replace-regexp-in-string "\n" " " preview))))
              (insert "\n"))))))))

;;; Export

;;;###autoload
(defun ogent-analytics-export-csv (file)
  "Export analytics data to CSV FILE."
  (interactive
   (list (read-file-name "Export CSV to: "
                         nil nil nil
                         (format "ogent-analytics-%s.csv"
                                 (format-time-string "%Y%m%d")))))
  (let ((db (ogent-analytics--get-db)))
    (unless db
      (user-error "SQLite not available"))
    (let ((rows (sqlite-select db "
      SELECT timestamp, model, outcome, rating, prompt_tokens,
             response_tokens, total_tokens, time_to_first_token_ms,
             completion_latency_ms, prompt_template
      FROM completions
      ORDER BY timestamp")))
      (with-temp-file file
        (insert "timestamp,model,outcome,rating,prompt_tokens,response_tokens,")
        (insert "total_tokens,ttft_ms,latency_ms,template\n")
        (dolist (row rows)
          (insert (mapconcat
                   (lambda (val)
                     (if val
                         (if (stringp val)
                             (format "\"%s\"" (replace-regexp-in-string "\"" "\"\"" val))
                           (format "%s" val))
                       ""))
                   row ","))
          (insert "\n")))
      (message "Exported %d rows to %s" (length rows) file))))

;;;###autoload
(defun ogent-analytics-export-org (file)
  "Export analytics data to org-table FILE."
  (interactive
   (list (read-file-name "Export Org to: "
                         nil nil nil
                         (format "ogent-analytics-%s.org"
                                 (format-time-string "%Y%m%d")))))
  (let ((db (ogent-analytics--get-db)))
    (unless db
      (user-error "SQLite not available"))
    (with-temp-file file
      (insert "#+TITLE: Ogent Analytics Export\n")
      (insert (format "#+DATE: %s\n\n" (format-time-string "%Y-%m-%d")))
      ;; Model stats table
      (insert "* Model Statistics\n\n")
      (insert "| Model | Total | Accepted | Rejected | Accept% | Avg Tokens | Thumbs Up | Thumbs Down |\n")
      (insert "|-------|-------|----------|----------|---------|------------|-----------|-------------|\n")
      (let ((models (sqlite-select db "SELECT * FROM model_stats ORDER BY total_completions DESC")))
        (dolist (row models)
          (insert (format "| %s | %s | %s | %s | %s | %s | %s | %s |\n"
                          (or (nth 0 row) "unknown")
                          (ogent-analytics--format-number (nth 1 row))
                          (ogent-analytics--format-number (nth 2 row))
                          (ogent-analytics--format-number (nth 3 row))
                          (ogent-analytics--format-number (nth 4 row))
                          (ogent-analytics--format-number (nth 5 row))
                          (ogent-analytics--format-number (nth 7 row))
                          (ogent-analytics--format-number (nth 8 row))))))
      (insert "\n")
      ;; Daily stats table
      (insert "* Daily Statistics\n\n")
      (insert "| Date | Completions | Accepted | Rejected | Tokens | Avg Latency |\n")
      (insert "|------|-------------|----------|----------|--------|-------------|\n")
      (let ((daily (sqlite-select db "SELECT * FROM daily_stats LIMIT 30")))
        (dolist (row daily)
          (insert (format "| %s | %s | %s | %s | %s | %s |\n"
                          (or (nth 0 row) "-")
                          (ogent-analytics--format-number (nth 1 row))
                          (ogent-analytics--format-number (nth 2 row))
                          (ogent-analytics--format-number (nth 3 row))
                          (ogent-analytics--format-number (nth 4 row))
                          (ogent-analytics--format-latency (nth 5 row)))))))
    (message "Exported analytics to %s" file)))

;;; Hooks Integration

(defun ogent-analytics--pre-request-hook ()
  "Hook to call before sending a request."
  (when ogent-analytics-enabled
    (ogent-analytics-start-request)))

(defun ogent-analytics--completion-accept-advice (orig-fun &rest args)
  "Advice around `ogent-completion-accept' to track acceptance.
ORIG-FUN and ARGS are the original function and arguments."
  (prog1 (apply orig-fun args)
    (ogent-analytics-mark-accepted)))

(defun ogent-analytics--completion-reject-advice (orig-fun &rest args)
  "Advice around `ogent-completion-reject' to track rejection.
ORIG-FUN and ARGS are the original function and arguments."
  (prog1 (apply orig-fun args)
    (ogent-analytics-mark-rejected)))

;;;###autoload
(defun ogent-analytics-setup ()
  "Set up analytics hooks and advice."
  (when (featurep 'gptel)
    (add-hook 'gptel-pre-request-hook #'ogent-analytics--pre-request-hook))
  ;; Advice for completion accept/reject
  (when (fboundp 'ogent-completion-accept)
    (advice-add 'ogent-completion-accept :around #'ogent-analytics--completion-accept-advice))
  (when (fboundp 'ogent-completion-reject)
    (advice-add 'ogent-completion-reject :around #'ogent-analytics--completion-reject-advice)))

;;;###autoload
(defun ogent-analytics-teardown ()
  "Remove analytics hooks and advice."
  (when (featurep 'gptel)
    (remove-hook 'gptel-pre-request-hook #'ogent-analytics--pre-request-hook))
  (when (fboundp 'ogent-completion-accept)
    (advice-remove 'ogent-completion-accept #'ogent-analytics--completion-accept-advice))
  (when (fboundp 'ogent-completion-reject)
    (advice-remove 'ogent-completion-reject #'ogent-analytics--completion-reject-advice)))

;; Auto-setup when loaded with ogent-core
(with-eval-after-load 'ogent-core
  (ogent-analytics-setup))

;; Canonical Evil integration so the dashboard's single-key affordances
;; (g refresh, e/o export, q quit) fire under Doom/Evil.
(with-eval-after-load 'evil
  (when (fboundp 'ogent-evil-display-mode-setup)
    (ogent-evil-display-mode-setup
     'ogent-analytics-dashboard-mode ogent-analytics-dashboard-mode-map
     'ogent-analytics-dashboard-mode-hook #'ogent-analytics-dashboard-refresh)))

(provide 'ogent-analytics)

;;; ogent-analytics.el ends here
