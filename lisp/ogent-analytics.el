;;; ogent-analytics.el --- Analytics and benchmarking for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Tracks prompt effectiveness and provides analytics for ogent sessions.
;;
;; Metrics tracked:
;; - Response quality ratings (accept/reject + 1-5 star rating)
;; - Token usage (estimated via ~4 chars/token)
;; - Completion cost in USD (from `ogent-analytics-model-pricing')
;; - Model comparison stats
;; - Time-to-first-token and completion latency
;; - Accept/reject ratio
;;
;; Storage:
;; - Per-project SQLite database (.ogent-analytics.db)
;;
;; Usage:
;;   C-c . * - Rate the response at point 1-5
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
;; Org property lookup for the rating command; org is loaded whenever
;; the command's `derived-mode-p' guard passes.
(declare-function org-entry-get "org"
                  (epom property &optional inherit literal-nil))

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

(defcustom ogent-analytics-model-pricing
  ;; Starter table for the shipped `ogent-model-registry' entries.
  ;; Prices are USD per million tokens as published 2026-07; revisit
  ;; when providers reprice.  The bare "claude-haiku-4-5" entry shows
  ;; the prefix rule covering dated variants like
  ;; claude-haiku-4-5-20251001 without listing each one.
  '(("gpt-5.6-sol"       . (:input-per-mtok 1.25 :output-per-mtok 10.00))
    ("gpt-5.6-terra"     . (:input-per-mtok 0.25 :output-per-mtok 2.00))
    ("gpt-5.6-luna"      . (:input-per-mtok 0.05 :output-per-mtok 0.40))
    ("gpt-5.5-pro"       . (:input-per-mtok 15.00 :output-per-mtok 120.00))
    ("gpt-5.5"           . (:input-per-mtok 1.25 :output-per-mtok 10.00))
    ("gpt-5.4-mini"      . (:input-per-mtok 0.25 :output-per-mtok 2.00))
    ("gpt-5.4-nano"      . (:input-per-mtok 0.05 :output-per-mtok 0.40))
    ("gpt-5.4"           . (:input-per-mtok 1.25 :output-per-mtok 10.00))
    ("gpt-5.3-codex"     . (:input-per-mtok 1.25 :output-per-mtok 10.00))
    ("gpt-4.1"           . (:input-per-mtok 2.00 :output-per-mtok 8.00))
    ("gpt-4o-mini"       . (:input-per-mtok 0.15 :output-per-mtok 0.60))
    ("claude-fable-5"    . (:input-per-mtok 5.00 :output-per-mtok 25.00))
    ("claude-opus-4-8"   . (:input-per-mtok 15.00 :output-per-mtok 75.00))
    ("claude-sonnet-5"   . (:input-per-mtok 3.00 :output-per-mtok 15.00))
    ("claude-sonnet-4-6" . (:input-per-mtok 3.00 :output-per-mtok 15.00))
    ("claude-haiku-4-5"  . (:input-per-mtok 1.00 :output-per-mtok 5.00)))
  "Alist mapping model-id prefixes to USD pricing plists.
Each entry is (PATTERN . (:input-per-mtok IN :output-per-mtok OUT))
where PATTERN is a model-id prefix and IN/OUT are USD per million
tokens.  Registry ids grow suffixed variants, so lookup uses a
longest-prefix rule: the entry with the longest PATTERN prefixing the
model id wins.  A model with no matching entry records a NULL cost,
never 0 (0 lies; NULL renders as \"-\")."
  :type '(alist :key-type string :value-type plist)
  :group 'ogent-analytics)

;;; Database

(defvar ogent-analytics--db-cache (make-hash-table :test 'equal)
  "Cache of open database connections by project path.")

(defun ogent-analytics--project-root ()
  "Get the project root directory, or `default-directory'."
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
Returns nil if sqlite is not available.  A fresh connection gets its
schema initialized and migrated to the current version; see
`ogent-analytics--migrate-schema' for the idempotent version-pragma
migration pattern."
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
  "Initialize database schema in DB and migrate it to the current version.
Creates the base (version 0) completions table when missing, runs
`ogent-analytics--migrate-schema' (which may rebuild the table and
drop stale views), then (re)creates the views, so every connection --
fresh or pre-existing -- ends up at `ogent-analytics--schema-version'."
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
  ;; Migrate before creating views: a migration that rebuilds the
  ;; completions table drops the views referencing it (SQLite >= 3.25
  ;; refuses to RENAME a table a live view mentions).
  (ogent-analytics--migrate-schema db)
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

(defconst ogent-analytics--schema-version 1
  "Schema version the running code expects.
Recorded in each database's user_version pragma by
`ogent-analytics--migrate-schema'.")

(defun ogent-analytics--migrate-schema (db)
  "Bring DB's schema up to `ogent-analytics--schema-version'.
Idempotent version-pragma migration pattern: the sqlite user_version
pragma records the version already applied (0 on a fresh database),
each block below upgrades exactly one version step inside a
transaction that bumps the pragma, and re-running on an up-to-date
connection is a no-op.  New migrations append a (when (< version N))
block and bump `ogent-analytics--schema-version'."
  (let ((version (caar (sqlite-select db "PRAGMA user_version"))))
    (when (< version 1)
      ;; v1 (2026-07, beads ogent-z0k.1/ogent-z0k.3): per-completion
      ;; cost and fan-out tagging, plus the 1-5 star rating scale.
      ;; The two new columns arrive via ALTER TABLE; widening the
      ;; rating/outcome CHECK constraints then needs SQLite's
      ;; documented table rebuild (constraints cannot be altered in
      ;; place).  Legacy thumb ratings (-1/0/1) stay valid under the
      ;; widened CHECK, so no data rewrite.
      (sqlite-execute db "BEGIN IMMEDIATE")
      (condition-case err
          (progn
            (sqlite-execute
             db "ALTER TABLE completions ADD COLUMN cost_usd REAL")
            (sqlite-execute
             db "ALTER TABLE completions ADD COLUMN fanout_group TEXT")
            ;; SQLite >= 3.25 refuses to rename a table referenced by a
            ;; live view; drop the views here, `ogent-analytics--init-schema'
            ;; recreates them right after this migration returns.
            (sqlite-execute db "DROP VIEW IF EXISTS model_stats")
            (sqlite-execute db "DROP VIEW IF EXISTS daily_stats")
            (sqlite-execute db "
              CREATE TABLE completions_migrate (
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
                outcome TEXT CHECK(outcome IN ('accepted', 'rejected', 'pending', 'rated')),
                rating INTEGER CHECK(rating BETWEEN -1 AND 5),
                question_preview TEXT,
                response_preview TEXT,
                cost_usd REAL,
                fanout_group TEXT
              )")
            (sqlite-execute db "
              INSERT INTO completions_migrate
              SELECT id, timestamp, session_id, model, prompt_template,
                     prompt_tokens, response_tokens, total_tokens,
                     time_to_first_token_ms, completion_latency_ms,
                     outcome, rating, question_preview, response_preview,
                     cost_usd, fanout_group
              FROM completions")
            (sqlite-execute db "DROP TABLE completions")
            (sqlite-execute
             db "ALTER TABLE completions_migrate RENAME TO completions")
            (sqlite-execute db "PRAGMA user_version = 1")
            (sqlite-execute db "COMMIT"))
        (error
         (sqlite-execute db "ROLLBACK")
         (signal (car err) (cdr err)))))))

;;; Token Estimation

(defun ogent-analytics-estimate-tokens (text)
  "Estimate token count for TEXT using a character-based heuristic.
Divides TEXT's character count by `ogent-analytics-chars-per-token'.
Real tokenizers vary by model and content, so expect the result to
be within roughly +/-20% of the true count; UI surfaces must label
values derived from it as approximate (\"~\")."
  (if (stringp text)
      (round (/ (float (length text)) ogent-analytics-chars-per-token))
    0))

;;; Pricing

(defun ogent-analytics--model-pricing (model)
  "Return the pricing plist for MODEL, or nil when none matches.
Applies the longest-prefix rule over `ogent-analytics-model-pricing':
the entry with the longest pattern prefixing MODEL wins, so a bare
family entry covers suffixed variants while a more specific entry
overrides it."
  (when (stringp model)
    (let ((best nil)
          (best-len -1))
      (dolist (entry ogent-analytics-model-pricing)
        (let ((pattern (car entry)))
          (when (and (string-prefix-p pattern model)
                     (> (length pattern) best-len))
            (setq best (cdr entry)
                  best-len (length pattern)))))
      best)))

(defun ogent-analytics--completion-cost (model prompt-tokens response-tokens)
  "Return the estimated USD cost of a completion, or nil when unpriced.
MODEL selects a `ogent-analytics-model-pricing' entry via the
longest-prefix rule; PROMPT-TOKENS and RESPONSE-TOKENS are the token
estimates.  A model without pricing yields nil -- stored as NULL,
never 0, because 0 lies while NULL renders as \"-\"."
  (when-let* ((pricing (ogent-analytics--model-pricing model))
              (input-rate (plist-get pricing :input-per-mtok))
              (output-rate (plist-get pricing :output-per-mtok)))
    (when (and (numberp input-rate) (numberp output-rate))
      (/ (+ (* (or prompt-tokens 0) input-rate)
            (* (or response-tokens 0) output-rate))
         1000000.0))))

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
  outcome               ; 'pending, 'accepted, 'rejected, 'rated
  rating                ; 0 (unrated), 1-5 stars; legacy -1/1 thumbs
  question-preview      ; First 200 chars of question
  response-preview      ; First 200 chars of response
  cost-usd              ; Estimated cost in USD (nil when unpriced)
  fanout-group)         ; Fan-out group id (nil for plain requests)

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

(defun ogent-analytics-record-completion (model prompt response
                                                &optional template
                                                &rest kwargs)
  "Record a completion with MODEL, PROMPT, RESPONSE, and optional TEMPLATE.
KWARGS is a trailing keyword plist; the only recognized key is
`:fanout-group', a string tagging the row as one member of a fan-out
run (every member records the same group id, plain requests record
none; the group travels as a keyword tail rather than a fifth
positional, so the recorder's `func-arity' maximum stays `many' for
callers that sniff it).  Cost is computed here, at record time, from the token
estimates and `ogent-analytics-model-pricing'.  Return the saved
completion struct, or nil when `ogent-analytics-enabled' is nil."
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
           (fanout-group (plist-get kwargs :fanout-group))
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
                        :response-preview (ogent-analytics--truncate response 200)
                        :cost-usd (ogent-analytics--completion-cost
                                   model prompt-tokens response-tokens)
                        :fanout-group fanout-group)))
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
        outcome, rating, question_preview, response_preview,
        cost_usd, fanout_group
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
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
                     (ogent-analytics-completion-response-preview completion)
                     (ogent-analytics-completion-cost-usd completion)
                     (ogent-analytics-completion-fanout-group completion)))
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

(defun ogent-analytics--completion-id-at-point ()
  "Return the analytics completion row id for the Org entry at point.
Reads the OGENT_COMPLETION_ID property with inheritance, so the id
stamped into the request block drawer at record time (or onto a
fan-out member's own Response headline) is visible from the
\"*** Response\" headline and anywhere inside the request subtree.
Return nil outside Org buffers or when no id is recorded."
  (when (derived-mode-p 'org-mode)
    (when-let ((prop (org-entry-get (point) "OGENT_COMPLETION_ID" t)))
      (let ((id (string-to-number prop)))
        (and (> id 0) id)))))

(defun ogent-analytics-rate-completion (id rating)
  "Set completion row ID's RATING and mark its outcome \\='rated.
Programmatic core of `ogent-analytics-rate-response', callable without
prompting (the fan-out keep command auto-rates the kept winner this
way).  RATING is an integer star rating, normally 1-5.  Updates the
database row and keeps the in-memory pending struct coherent when it
covers ID.  Re-rating updates the same row, never duplicates it.
Signal `user-error' when the analytics database is unavailable."
  (let ((db (ogent-analytics--get-db)))
    (unless db
      (user-error "Analytics database unavailable"))
    (sqlite-execute
     db "UPDATE completions SET rating = ?, outcome = 'rated' WHERE id = ?"
     (list rating id))
    ;; Keep the in-memory pending struct coherent when it covers the
    ;; row just rated.
    (when (and ogent-analytics--pending-completion
               (eql (ogent-analytics-completion-id
                     ogent-analytics--pending-completion)
                    id))
      (setf (ogent-analytics-completion-rating
             ogent-analytics--pending-completion)
            rating)
      (setf (ogent-analytics-completion-outcome
             ogent-analytics--pending-completion)
            'rated))))

;;;###autoload
(defun ogent-analytics-rate-response ()
  "Rate the response at point 1-5 against its recorded completion row.
Reads the completion row id via
`ogent-analytics--completion-id-at-point', prompts for a single digit
with `read-char-choice' (two keystrokes total after the registry
chord), then delegates to `ogent-analytics-rate-completion'."
  (interactive)
  (let ((id (ogent-analytics--completion-id-at-point)))
    (unless id
      (user-error
       "No completion id on this response (likely cause: analytics was disabled when it was requested)"))
    (let ((rating (- (read-char-choice "Rate response (1-5): "
                                       '(?1 ?2 ?3 ?4 ?5))
                     ?0)))
      (ogent-analytics-rate-completion id rating)
      (message "Rated completion %d: %d/5" id rating))))

;;; Auto-Outcome from Edit Resolution (bead ogent-z0k.2)

;; Struct accessors (fileonly: cl-defstruct-generated)
(declare-function ogent-edit-completion-id "ogent-edit-format" t t)
(declare-function ogent-edit-status "ogent-edit-format" t t)

(defun ogent-analytics--edit-resolved (edit)
  "Set the linked completion's outcome from EDIT's resolution.
Runs from `ogent-edit-resolved-hook' with the resolved `ogent-edit'
struct.  The completions row id rides the struct itself, stamped by
`ogent-edit--process-response' at record time: quick edits and
diagnostic repairs run from ordinary code buffers, so there is no org
drawer to read an OGENT_COMPLETION_ID property from.  Edits without a
completion id (analytics disabled at request time, or structs built
outside the request flow) are silently skipped -- no error spam.

Precedence rule: an explicit user rating ALWAYS wins.  A row whose
outcome is already \\='rated keeps it (the SQL WHERE guard below), and
this function never touches the rating column -- auto-outcomes only
fill in the accepted/rejected disposition of otherwise-unrated rows.
A smerge resolution reported as plain \\='resolved is ambiguous --
either side may have been kept -- and records nothing."
  (when-let* ((id (ogent-edit-completion-id edit))
              (outcome (pcase (ogent-edit-status edit)
                         ((or 'accepted 'applied) "accepted")
                         ('rejected "rejected")))
              (db (ogent-analytics--get-db)))
    (sqlite-execute
     db
     "UPDATE completions SET outcome = ? WHERE id = ? AND outcome IS NOT 'rated'"
     (list outcome id))))

;; Load-time registration, mirroring `ogent-edit--log-resolved': the
;; hook variable lives in ogent-edit-display, but `add-hook' seeds a
;; not-yet-loaded defvar and the later `defvar' keeps the value.
(add-hook 'ogent-edit-resolved-hook #'ogent-analytics--edit-resolved)

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

(defun ogent-analytics--format-cost (usd)
  "Format USD cost for display; a non-number (unpriced NULL) renders as -."
  (if (numberp usd) (format "$%.4f" usd) "-"))

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
      ;; Cost views (bead ogent-z0k.4)
      (insert "## Cost by Model\n\n")
      (let ((rows (sqlite-select db "
        SELECT model, COUNT(*) as completions,
               SUM(cost_usd) as total_cost,
               AVG(cost_usd) as avg_cost
        FROM completions
        GROUP BY model
        ORDER BY total_cost DESC")))
        (if (null rows)
            (insert "No cost data available.\n\n")
          (insert "| Model | Completions | Total Cost | Avg Cost |\n")
          (insert "|-------|-------------|------------|----------|\n")
          (dolist (row rows)
            (insert (format "| %s | %s | %s | %s |\n"
                            (or (nth 0 row) "unknown")
                            (ogent-analytics--format-number (nth 1 row))
                            (ogent-analytics--format-cost (nth 2 row))
                            (ogent-analytics--format-cost (nth 3 row)))))
          (insert "\n")))
      (insert "## Cost by Day\n\n")
      (let ((rows (sqlite-select db "
        SELECT date(timestamp) as date, COUNT(*) as completions,
               SUM(cost_usd) as total_cost,
               AVG(cost_usd) as avg_cost
        FROM completions
        GROUP BY date(timestamp)
        ORDER BY date DESC
        LIMIT 30")))
        (if (null rows)
            (insert "No cost data available.\n\n")
          (insert "| Date | Completions | Total Cost | Avg Cost |\n")
          (insert "|------|-------------|------------|----------|\n")
          (dolist (row rows)
            (insert (format "| %s | %s | %s | %s |\n"
                            (or (nth 0 row) "-")
                            (ogent-analytics--format-number (nth 1 row))
                            (ogent-analytics--format-cost (nth 2 row))
                            (ogent-analytics--format-cost (nth 3 row)))))
          (insert "\n")))
      ;; Rating distribution + unrated nudge (bead ogent-z0k.4).
      ;; Legacy thumb ratings (-1/0/1) predate the 1-5 scale; a legacy
      ;; thumbs-up counts in the 1 bucket, a thumbs-down in none.
      (insert "## Ratings by Model\n\n")
      (let ((rows (sqlite-select db "
        SELECT model,
               SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END) as r1,
               SUM(CASE WHEN rating = 2 THEN 1 ELSE 0 END) as r2,
               SUM(CASE WHEN rating = 3 THEN 1 ELSE 0 END) as r3,
               SUM(CASE WHEN rating = 4 THEN 1 ELSE 0 END) as r4,
               SUM(CASE WHEN rating = 5 THEN 1 ELSE 0 END) as r5,
               ROUND(AVG(CASE WHEN rating BETWEEN 1 AND 5 THEN rating END), 2) as avg_rating
        FROM completions
        GROUP BY model
        ORDER BY model")))
        (if (null rows)
            (insert "No rating data available.\n\n")
          (insert "| Model | 1 | 2 | 3 | 4 | 5 | Avg Rating |\n")
          (insert "|-------|---|---|---|---|---|------------|\n")
          (dolist (row rows)
            (insert (format "| %s | %s | %s | %s | %s | %s | %s |\n"
                            (or (nth 0 row) "unknown")
                            (ogent-analytics--format-number (nth 1 row))
                            (ogent-analytics--format-number (nth 2 row))
                            (ogent-analytics--format-number (nth 3 row))
                            (ogent-analytics--format-number (nth 4 row))
                            (ogent-analytics--format-number (nth 5 row))
                            (ogent-analytics--format-number (nth 6 row)))))
          (insert "\n")))
      (let ((unrated (caar (sqlite-select db "
        SELECT COUNT(*) FROM completions
        WHERE rating IS NULL OR rating = 0"))))
        (insert (format "Unrated completions: %s (press * on a response headline to rate)\n\n"
                        (or unrated 0))))
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
             completion_latency_ms, prompt_template, cost_usd,
             fanout_group
      FROM completions
      ORDER BY timestamp")))
      (with-temp-file file
        (insert "timestamp,model,outcome,rating,prompt_tokens,response_tokens,")
        (insert "total_tokens,ttft_ms,latency_ms,template,cost_usd,fanout_group\n")
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
      ;; Model stats table (+ cost/rating columns, bead ogent-z0k.4)
      (insert "* Model Statistics\n\n")
      (insert "| Model | Total | Accepted | Rejected | Accept% | Avg Tokens | Thumbs Up | Thumbs Down | Total Cost | Avg Rating |\n")
      (insert "|-------|-------|----------|----------|---------|------------|-----------|-------------|------------|------------|\n")
      (let ((cost-rating (sqlite-select db "
        SELECT model, SUM(cost_usd),
               ROUND(AVG(CASE WHEN rating BETWEEN 1 AND 5 THEN rating END), 2)
        FROM completions GROUP BY model"))
            (models (sqlite-select db "SELECT * FROM model_stats ORDER BY total_completions DESC")))
        (dolist (row models)
          (let ((extra (assoc (nth 0 row) cost-rating)))
            (insert (format "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n"
                            (or (nth 0 row) "unknown")
                            (ogent-analytics--format-number (nth 1 row))
                            (ogent-analytics--format-number (nth 2 row))
                            (ogent-analytics--format-number (nth 3 row))
                            (ogent-analytics--format-number (nth 4 row))
                            (ogent-analytics--format-number (nth 5 row))
                            (ogent-analytics--format-number (nth 7 row))
                            (ogent-analytics--format-number (nth 8 row))
                            (ogent-analytics--format-cost (nth 1 extra))
                            (ogent-analytics--format-number (nth 2 extra)))))))
      (insert "\n")
      ;; Daily stats table (+ cost column, bead ogent-z0k.4)
      (insert "* Daily Statistics\n\n")
      (insert "| Date | Completions | Accepted | Rejected | Tokens | Avg Latency | Cost |\n")
      (insert "|------|-------------|----------|----------|--------|-------------|------|\n")
      (let ((cost-by-day (sqlite-select db "
        SELECT date(timestamp), SUM(cost_usd)
        FROM completions GROUP BY date(timestamp)"))
            (daily (sqlite-select db "SELECT * FROM daily_stats LIMIT 30")))
        (dolist (row daily)
          (insert (format "| %s | %s | %s | %s | %s | %s | %s |\n"
                          (or (nth 0 row) "-")
                          (ogent-analytics--format-number (nth 1 row))
                          (ogent-analytics--format-number (nth 2 row))
                          (ogent-analytics--format-number (nth 3 row))
                          (ogent-analytics--format-number (nth 4 row))
                          (ogent-analytics--format-latency (nth 5 row))
                          (ogent-analytics--format-cost
                           (nth 1 (assoc (nth 0 row) cost-by-day))))))))
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
