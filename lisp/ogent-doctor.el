;;; ogent-doctor.el --- Environment diagnostics for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a read-only health report for ogent's local Emacs/package/provider
;; setup.  Checks live on a registry (`ogent-doctor-checks'): each entry names
;; a check, its report category, a zero-argument function returning a cons
;; (STATUS . DETAIL), and a static remediation string shown for warn/error
;; results.  `ogent-doctor--run-checks' contains per-check crashes - a check
;; that signals reports as a failing result and never aborts the run.  The
;; core returns data plists so tests and future automation can use it without
;; scraping a buffer; `ogent-doctor-batch' adds a shell-style exit contract
;; for CI and scripting.

;;; Code:

(require 'subr-x)
(require 'seq)
(require 'org)
(require 'ogent-gptel)
(require 'ogent-models)

(declare-function gptel-request "ext:gptel-request")
(declare-function ogent-codex-oauth--auth-file "ogent-codex-oauth")
(declare-function ogent-codex-oauth-mode "ogent-codex-oauth")
(declare-function ogent-codex-oauth-get-api-key "ogent-codex-oauth")
(declare-function ogent-anthropic-oauth--find-existing-token-file "ogent-anthropic-oauth")
(declare-function gptel-backend-key "ext:gptel" (backend))
(declare-function ogent-analytics--db-path "ogent-analytics")
(declare-function ogent-armory-adapter-list "ogent-armory-adapter")
(declare-function ogent-armory-adapter-executable "ogent-armory-adapter" (adapter))
(declare-function ogent-mcp-connect "ogent-mcp" (server-name))
(declare-function ogent-mcp-disconnect "ogent-mcp" (server-name))
(declare-function ogent-mcp-connection-status "ogent-mcp" (connection))

(defvar transient-version)
(defvar gptel-backend)
(defvar gptel-use-tools)
(defvar ogent-mcp-servers)
(defvar ogent-mcp--connections)

(defgroup ogent-doctor nil
  "Diagnostics for ogent setup."
  :group 'ogent)

(defcustom ogent-doctor-required-emacs-version "29.1"
  "Minimum Emacs version supported by ogent."
  :type 'string
  :group 'ogent-doctor)

(defcustom ogent-doctor-required-org-version "9.8.7"
  "Minimum Org version supported by ogent."
  :type 'string
  :group 'ogent-doctor)

(defcustom ogent-doctor-required-transient-version "0.13.5"
  "Minimum Transient version supported by ogent."
  :type 'string
  :group 'ogent-doctor)

(defcustom ogent-doctor-anthropic-expiry-warn-days 7
  "Days of remaining Claude OAuth token validity below which doctor warns."
  :type 'natnum
  :group 'ogent-doctor)

(defcustom ogent-doctor-mcp-timeout 3
  "Seconds the doctor waits for each MCP initialize handshake."
  :type 'number
  :group 'ogent-doctor)

(defvar ogent-doctor-buffer-name "*ogent-doctor*"
  "Buffer name for `ogent-doctor' reports.")

;;; Check registry

(defconst ogent-doctor-categories
  '((environment . "Environment")
    (transport . "Transport")
    (models . "Models")
    (auth . "Auth")
    (cli . "CLI tools")
    (optional . "Optional packages")
    (stores . "Stores")
    (mcp . "MCP"))
  "Doctor report categories in display order, mapped to headings.")

(defconst ogent-doctor-checks
  '((:id emacs-version
         :label "Emacs version"
         :category environment
         :fn ogent-doctor--check-emacs-version
         :remediation "Upgrade Emacs to at least the version in `ogent-doctor-required-emacs-version'")
    (:id org-version
         :label "Org version"
         :category environment
         :fn ogent-doctor--check-org-version
         :remediation "Upgrade Org to at least the version in `ogent-doctor-required-org-version'")
    (:id transient
         :label "Transient menus"
         :category environment
         :fn ogent-doctor--check-transient
         :remediation "Upgrade Transient to at least the version in `ogent-doctor-required-transient-version'")
    (:id gptel
         :label "gptel transport"
         :category transport
         :fn ogent-doctor--check-gptel
         :remediation "Install gptel (M-x package-install RET gptel RET)")
    (:id gptel-tools
         :label "gptel tools flag"
         :category transport
         :fn ogent-doctor--check-gptel-tools
         :remediation "Set `gptel-use-tools' non-nil so ogent tools can run")
    (:id model-registry
         :label "Model registry"
         :category models
         :fn ogent-doctor--check-model-registry
         :remediation "Give every `ogent-model-registry' entry an :id and a :backend")
    (:id default-model
         :label "Default model"
         :category models
         :fn ogent-doctor--check-default-model
         :remediation "Set `ogent-default-model' to a registered model id")
    (:id backend
         :label "gptel backend"
         :category models
         :fn ogent-doctor--check-backend
         :remediation "Define the gptel backend the default model's :backend refers to")
    (:id codex-auth
         :label "Codex OAuth cache"
         :category auth
         :fn ogent-doctor--check-codex-auth
         :remediation "Run `codex login' to refresh the Codex auth cache")
    (:id default-model-key
         :label "Default model key"
         :category auth
         :fn ogent-doctor--check-default-model-key
         :remediation "Configure an API key or bearer on the default model's gptel backend")
    (:id anthropic-auth
         :label "Claude OAuth cache"
         :category auth
         :fn ogent-doctor--check-anthropic-auth
         :remediation "Run M-x ogent-anthropic-login to refresh the OAuth tokens")
    (:id br
         :label "br issue tracker"
         :category cli
         :fn ogent-doctor--check-br
         :remediation "Install br (beads_rust) and put it on PATH for issue integration")
    (:id adapter-clis
         :label "Adapter CLIs"
         :category cli
         :fn ogent-doctor--check-adapter-clis
         :remediation "Install the adapter CLIs you plan to run through the Armory")
    (:id curl
         :label "curl transport"
         :category transport
         :fn ogent-doctor--check-curl
         :remediation "Install curl to enable streaming MCP HTTP transport")
    (:id org-ql
         :label "org-ql package"
         :category optional
         :fn ogent-doctor--check-org-ql)
    (:id vterm
         :label "vterm package"
         :category optional
         :fn ogent-doctor--check-vterm)
    (:id markdown-mode
         :label "markdown-mode package"
         :category optional
         :fn ogent-doctor--check-markdown-mode)
    (:id analytics-db
         :label "Analytics DB"
         :category stores
         :fn ogent-doctor--check-analytics-db
         :remediation "Move the corrupt analytics DB aside; ogent recreates it on next use")
    (:id stale-elc
         :label "Stale .elc files"
         :category environment
         :fn ogent-doctor--check-stale-elc
         :remediation "Recompile ogent with the running Emacs, or move the newer-Emacs .elc aside")
    (:id mcp-servers
         :label "MCP servers"
         :category mcp
         :opt-in t
         :fn ogent-doctor--check-mcp-servers
         :remediation "Fix the server command or URL in `ogent-mcp-servers' and reconnect"))
  "Registry of doctor checks.
Each entry is a plist with :id (symbol), :label (string), :category
\(a key of `ogent-doctor-categories'), :fn (a function of no arguments
returning a cons of STATUS and DETAIL, where STATUS is one of the
symbols `ok', `warn', `error' or `info' and DETAIL is a string), and
:remediation (a static hint string rendered for warn/error results).
Entries flagged :opt-in are skipped by default runs; see
`ogent-doctor-run'.")

;;; Version helpers

(defun ogent-doctor--version-status (current required)
  "Return `ok' when CURRENT is at least REQUIRED, otherwise `error'."
  (if (and current (not (version< current required))) 'ok 'error))

(defun ogent-doctor--version-detail (name current required)
  "Return human-readable version detail for NAME, CURRENT, and REQUIRED."
  (if current
      (format "%s %s (required >= %s)" name current required)
    (format "%s version unknown (required >= %s)" name required)))

;;; Checks

(defun ogent-doctor--check-emacs-version ()
  "Check the running Emacs version.  Return (STATUS . DETAIL)."
  (cons (ogent-doctor--version-status
         emacs-version ogent-doctor-required-emacs-version)
        (ogent-doctor--version-detail
         "Emacs" emacs-version ogent-doctor-required-emacs-version)))

(defun ogent-doctor--check-org-version ()
  "Check Org can load and meets the configured minimum.
Return (STATUS . DETAIL)."
  (if (require 'org nil t)
      (let ((version (org-version)))
        (cons (ogent-doctor--version-status
               version ogent-doctor-required-org-version)
              (ogent-doctor--version-detail
               "Org" version ogent-doctor-required-org-version)))
    (cons 'error "Org is not loadable")))

(defun ogent-doctor--check-gptel ()
  "Check gptel can load and exposes its request entrypoint.
Return (STATUS . DETAIL)."
  (if (and (require 'gptel nil t) (fboundp 'gptel-request))
      (cons 'ok "gptel loaded and `gptel-request' is available")
    (cons 'error "gptel is not loadable or lacks `gptel-request'")))

(defun ogent-doctor--check-transient ()
  "Check Transient can load and meets the minimum when versioned.
Return (STATUS . DETAIL)."
  (if (and (require 'transient nil t) (fboundp 'transient-define-prefix))
      (let ((version (and (boundp 'transient-version) transient-version)))
        (if version
            (cons (ogent-doctor--version-status
                   version ogent-doctor-required-transient-version)
                  (ogent-doctor--version-detail
                   "Transient" version ogent-doctor-required-transient-version))
          (cons 'ok "Transient loaded; version variable is unavailable")))
    (cons 'error "Transient is not loadable")))

(defun ogent-doctor--check-model-registry ()
  "Check the ogent model registry shape.  Return (STATUS . DETAIL)."
  (let* ((models (ogent-models-all))
         (bad (seq-filter (lambda (model)
                            (or (not (plist-get model :id))
                                (not (plist-get model :backend))))
                          models)))
    (if bad
        (cons 'error (format "%d model entries lack :id or :backend" (length bad)))
      (cons 'ok (format "%d model entries registered" (length models))))))

(defun ogent-doctor--check-default-model ()
  "Check `ogent-default-model' resolves to a registered model.
Return (STATUS . DETAIL)."
  (if (and (boundp 'ogent-default-model)
           ogent-default-model
           (ogent-models-get ogent-default-model))
      (cons 'ok (format "Default model: %s" ogent-default-model))
    (cons 'error (format "Default model is not registered: %S"
                         (and (boundp 'ogent-default-model)
                              ogent-default-model)))))

(defun ogent-doctor--check-backend ()
  "Check the default model resolves to a gptel backend candidate.
Return (STATUS . DETAIL)."
  (condition-case err
      (let* ((model (ogent-models-default))
             (backend (and model (ogent-gptel-resolve-backend model))))
        (cond
         ((not backend)
          (cons 'warn "Default model has no backend"))
         ((stringp backend)
          (cons 'warn (format "Backend %S has not resolved to an object" backend)))
         ((symbolp backend)
          (cons 'warn (format "Backend %S is unresolved" backend)))
         (t
          (cons 'ok (format "Backend object: %s" (type-of backend))))))
    (error (cons 'warn (error-message-string err)))))

(defun ogent-doctor--check-gptel-tools ()
  "Report whether gptel tool execution is enabled.  Return (STATUS . DETAIL)."
  (if (and (boundp 'gptel-use-tools) gptel-use-tools)
      (cons 'ok "`gptel-use-tools' is enabled")
    (cons 'info "`gptel-use-tools' is not enabled")))

(defun ogent-doctor--check-br ()
  "Check whether br is available for issue integration.
Return (STATUS . DETAIL)."
  (if-let ((path (executable-find "br")))
      (cons 'ok (format "br found at %s" path))
    (cons 'warn "br executable not found in PATH")))

(defun ogent-doctor--check-codex-auth ()
  "Check local Codex OAuth cache presence without network access.
Return (STATUS . DETAIL)."
  (if (require 'ogent-codex-oauth nil t)
      (let ((file (ogent-codex-oauth--auth-file))
            (mode (ignore-errors (ogent-codex-oauth-mode)))
            (has-key (ignore-errors (ogent-codex-oauth-get-api-key))))
        (cond
         (has-key
          (cons 'ok (format "Codex auth cache is usable%s"
                            (if mode (format " (%s)" mode) ""))))
         ((file-readable-p file)
          (cons 'warn (format "Codex auth file exists but has no OPENAI_API_KEY: %s" file)))
         (t
          (cons 'info (format "No Codex auth file at %s" file)))))
    (cons 'info "Codex OAuth module is not loadable")))

(defun ogent-doctor--anthropic-token-plist (file)
  "Read the OAuth token plist stored in FILE, or nil when unreadable."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((value (read (current-buffer))))
        (and (consp value) value)))))

(defun ogent-doctor--check-anthropic-auth ()
  "Check the Claude OAuth token cache expiry without network access.
Read the token file only; warn when the token expires within
`ogent-doctor-anthropic-expiry-warn-days' days, fail when it has
already expired.  Return (STATUS . DETAIL)."
  (if (require 'ogent-anthropic-oauth nil t)
      (let ((file (ignore-errors
                    (ogent-anthropic-oauth--find-existing-token-file))))
        (if (not file)
            (cons 'info "No Claude OAuth token file found")
          (let* ((tokens (ogent-doctor--anthropic-token-plist file))
                 (expires-at (plist-get tokens :expires-at)))
            (cond
             ((null tokens)
              (cons 'warn (format "Claude OAuth token file is unreadable: %s" file)))
             ((null expires-at)
              (cons 'ok (format "Claude OAuth cache has no expiry (API key mode): %s" file)))
             (t
              (let ((days (/ (- expires-at (float-time)) 86400)))
                (cond
                 ((<= days 0)
                  (cons 'error (format "Claude OAuth token expired %.1f days ago (%s)"
                                       (- days) file)))
                 ((< days ogent-doctor-anthropic-expiry-warn-days)
                  (cons 'warn (format "Claude OAuth token expires in %.1f days (%s)"
                                      days file)))
                 (t
                  (cons 'ok (format "Claude OAuth token valid for %.0f more days (%s)"
                                    days file))))))))))
    (cons 'info "Claude OAuth module is not loadable")))

(defun ogent-doctor--backend-key-present-p (backend)
  "Return non-nil when BACKEND's key resolves to a non-empty secret."
  (when-let ((key (ignore-errors (gptel-backend-key backend))))
    (let ((resolved (cond
                     ((functionp key) (ignore-errors (funcall key)))
                     ((and (symbolp key) (boundp key)) (symbol-value key))
                     (t key))))
      (and (stringp resolved) (not (string-empty-p resolved))))))

(defun ogent-doctor--check-default-model-key ()
  "Check an API key or bearer resolves for the session default model.
Never sends the secret anywhere; only its presence is reported.
Return (STATUS . DETAIL)."
  (let* ((model (ignore-errors (ogent-models-default)))
         (backend (and model (ignore-errors (ogent-gptel-resolve-backend model)))))
    (cond
     ((null model)
      (cons 'error "No default model is registered"))
     ((or (null backend) (stringp backend) (symbolp backend))
      (cons 'warn (format "Backend for %s has not resolved; key check deferred"
                          (plist-get model :id))))
     ((not (fboundp 'gptel-backend-key))
      (cons 'info "gptel is not fully loaded; cannot inspect the backend key"))
     ((ogent-doctor--backend-key-present-p backend)
      (cons 'ok (format "API key/bearer resolves for %s" (plist-get model :id))))
     (t
      (cons 'warn (format "No API key/bearer resolves for %s"
                          (plist-get model :id)))))))

(defun ogent-doctor--check-curl ()
  "Check curl is on PATH for the streaming MCP HTTP transport.
Return (STATUS . DETAIL)."
  (if-let ((path (executable-find "curl")))
      (cons 'ok (format "curl found at %s" path))
    (cons 'warn "curl not found in PATH; MCP HTTP falls back to non-streaming (buffered url.el POSTs)")))

(defun ogent-doctor--optional-package (feature unlocks)
  "Probe the optional package FEATURE.  Return (STATUS . DETAIL).
UNLOCKS names the functionality installing FEATURE enables."
  (if (require feature nil t)
      (cons 'ok (format "%s is available" feature))
    (cons 'info (format "%s is not installed; installing it unlocks %s"
                        feature unlocks))))

(defun ogent-doctor--check-org-ql ()
  "Probe the optional org-ql package.  Return (STATUS . DETAIL)."
  (ogent-doctor--optional-package
   'org-ql "saved-query search over Armory conversations (ogent-armory-ql)"))

(defun ogent-doctor--check-vterm ()
  "Probe the optional vterm package.  Return (STATUS . DETAIL)."
  (ogent-doctor--optional-package
   'vterm "full terminal emulation for interactive CLI agent sessions (the Armory terminal runtime otherwise uses term.el)"))

(defun ogent-doctor--check-markdown-mode ()
  "Probe the optional markdown-mode package.  Return (STATUS . DETAIL)."
  (ogent-doctor--optional-package
   'markdown-mode "Markdown highlighting for exported conversations (ox-ogent)"))

(defun ogent-doctor--adapter-cli-line (adapter)
  "Return a (STATUS . LINE) cons describing ADAPTER's CLI availability."
  (let ((name (plist-get adapter :name))
        (reason (plist-get adapter :unsupported-reason))
        (program (ogent-armory-adapter-executable adapter)))
    (cond
     (reason
      (cons 'info (format "%s: unsupported - %s" name reason)))
     ((null program)
      (cons 'ok (format "%s: in-process, no CLI needed" name)))
     ((executable-find program)
      (cons 'ok (format "%s: %s found" name program)))
     (t
      (cons 'info (format "%s: %s not in PATH" name program))))))

(defun ogent-doctor--check-adapter-clis ()
  "Check CLI availability for every registered Armory adapter.
Adapters that cannot run at all surface their :unsupported-reason so
the user sees why.  Return (STATUS . DETAIL)."
  (if (require 'ogent-armory-adapter nil t)
      (let ((entries (mapcar #'ogent-doctor--adapter-cli-line
                             (ogent-armory-adapter-list))))
        (if entries
            (cons (if (seq-some (lambda (entry) (eq (car entry) 'info)) entries)
                      'info
                    'ok)
                  (mapconcat #'cdr entries "\n"))
          (cons 'warn "No Armory adapters are registered")))
    (cons 'info "Armory adapter registry is not loadable")))

(defun ogent-doctor--sqlite-integrity (db)
  "Run the integrity_check pragma on sqlite DB.  Return (STATUS . DETAIL)."
  (let ((rows (sqlite-select db "PRAGMA integrity_check")))
    (if (equal rows '(("ok")))
        (cons 'ok "integrity_check: ok")
      (cons 'error (format "integrity_check: %s" (or (caar rows) "no result"))))))

(defun ogent-doctor--check-analytics-db ()
  "Check the current project's analytics database integrity.
Only probe when the per-project DB file already exists; never create
it.  Return (STATUS . DETAIL)."
  (cond
   ((not (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
    (cons 'info "Native sqlite is unavailable; analytics stays disabled"))
   ((not (require 'ogent-analytics nil t))
    (cons 'info "ogent-analytics is not loadable"))
   (t
    (let ((path (ogent-analytics--db-path)))
      (if (not (file-exists-p path))
          (cons 'info (format "No analytics DB for this project (%s)" path))
        (let (db)
          (unwind-protect
              (progn
                (setq db (sqlite-open path))
                (pcase-let ((`(,status . ,detail)
                             (ogent-doctor--sqlite-integrity db)))
                  (cons status (format "%s (%s)" detail path))))
            (when db (sqlite-close db)))))))))

(defun ogent-doctor--elc-header-major (header)
  "Return the Emacs major version recorded in .elc HEADER text, or nil.
HEADER is the leading bytes of a byte-compiled file, whose comment
block names the compiling Emacs."
  (when (string-match "in Emacs version \\([0-9]+\\)" header)
    (string-to-number (match-string 1 header))))

(defun ogent-doctor--elc-file-major (file)
  "Return the Emacs major version that byte-compiled FILE, or nil."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents-literally file nil 0 512)
      (ogent-doctor--elc-header-major (buffer-string)))))

(defun ogent-doctor--stale-elc-files (&optional dirs)
  "Return (FILE . MAJOR) conses for stale ogent bytecode in DIRS.
DIRS defaults to `load-path'.  A directory participates when it holds
ogent files; a .elc file is stale when the Emacs major version in its
header exceeds the running `emacs-major-version'."
  (let (stale)
    (dolist (dir (or dirs load-path))
      (when (and (stringp dir)
                 (file-directory-p dir)
                 (directory-files dir nil "\\`ogent" t))
        (dolist (name (directory-files dir nil "\\.elc\\'" t))
          (let* ((file (expand-file-name name dir))
                 (major (ogent-doctor--elc-file-major file)))
            (when (and major (> major emacs-major-version))
              (push (cons file major) stale))))))
    (nreverse stale)))

(defun ogent-doctor--check-stale-elc ()
  "Check for ogent .elc files compiled by a newer Emacs than this one.
Loading such bytecode is the classic stale-.elc trap: it can embed
incompatible expansions.  Return (STATUS . DETAIL)."
  (let ((stale (ogent-doctor--stale-elc-files)))
    (if (null stale)
        (cons 'ok (format "No ogent .elc compiled by an Emacs newer than %s"
                          emacs-major-version))
      (cons 'warn
            (mapconcat (lambda (entry)
                         (format "%s (compiled by Emacs %d)"
                                 (car entry) (cdr entry)))
                       stale "\n")))))

(defun ogent-doctor--mcp-server-ready-p (name)
  "Return non-nil when the MCP connection named NAME is ready."
  (when-let ((conn (gethash name ogent-mcp--connections)))
    (eq (ogent-mcp-connection-status conn) 'ready)))

(defun ogent-doctor--mcp-probe-server (name)
  "Probe the MCP server NAME with an initialize handshake.
Touch the network: wait up to `ogent-doctor-mcp-timeout' seconds for
the handshake, and disconnect again afterwards unless the server was
already connected.  Return (STATUS . DETAIL)."
  (if (ogent-doctor--mcp-server-ready-p name)
      (cons 'ok (format "%s: already connected" name))
    (let ((deadline (+ (float-time) ogent-doctor-mcp-timeout)))
      (condition-case err
          (progn
            (ogent-mcp-connect name)
            (while (and (not (ogent-doctor--mcp-server-ready-p name))
                        (< (float-time) deadline))
              (accept-process-output nil 0.05))
            (prog1
                (if (ogent-doctor--mcp-server-ready-p name)
                    (cons 'ok (format "%s: initialize handshake succeeded" name))
                  (cons 'error (format "%s: no initialize handshake within %ss"
                                       name ogent-doctor-mcp-timeout)))
              (ignore-errors (ogent-mcp-disconnect name))))
        (error (cons 'error (format "%s: %s" name (error-message-string err))))))))

(defun ogent-doctor--check-mcp-servers ()
  "Check every configured MCP server with an initialize handshake.
Opt-in only: it may spawn server processes and touch the network.
Return (STATUS . DETAIL)."
  (cond
   ((not (require 'ogent-mcp nil t))
    (cons 'info "ogent-mcp is not loadable"))
   ((null ogent-mcp-servers)
    (cons 'info "No MCP servers configured in `ogent-mcp-servers'"))
   (t
    (let ((entries (mapcar (lambda (entry)
                             (ogent-doctor--mcp-probe-server (car entry)))
                           ogent-mcp-servers)))
      (cons (if (seq-some (lambda (entry) (eq (car entry) 'error)) entries)
                'error
              'ok)
            (mapconcat #'cdr entries "\n"))))))

;;; Runner

(defun ogent-doctor--run-checks (checks)
  "Run every probe in CHECKS and return a list of result plists.
Each check's :fn is called with no arguments and must return a cons
\(STATUS . DETAIL).  Crashes are contained: a check that signals
reports as a failing result carrying the error text, and a check
returning a malformed value reports as a failing result naming it;
neither aborts the remaining checks.  Each result plist carries :id,
:label, :category, :status, :detail, and :remediation."
  (mapcar
   (lambda (check)
     (pcase-let ((`(,status . ,detail)
                  (condition-case err
                      (let ((outcome (funcall (plist-get check :fn))))
                        (if (and (consp outcome)
                                 (memq (car outcome) '(ok warn error info))
                                 (stringp (cdr outcome)))
                            outcome
                          (cons 'error
                                (format "check returned invalid result %S" outcome))))
                    (error (cons 'error
                                 (format "check crashed: %s"
                                         (error-message-string err)))))))
       (list :id (plist-get check :id)
             :label (plist-get check :label)
             :category (plist-get check :category)
             :status status
             :detail detail
             :remediation (plist-get check :remediation))))
   checks))

(defun ogent-doctor-run (&optional include-opt-in)
  "Run every registered doctor probe and return result plists.
Entries flagged :opt-in in `ogent-doctor-checks' are skipped unless
INCLUDE-OPT-IN is non-nil."
  (ogent-doctor--run-checks
   (seq-remove (lambda (check)
                 (and (plist-get check :opt-in) (not include-opt-in)))
               ogent-doctor-checks)))

(defun ogent-doctor-summary-status (results)
  "Return worst doctor status in RESULTS."
  (cond
   ((seq-some (lambda (result) (eq (plist-get result :status) 'error)) results)
    'error)
   ((seq-some (lambda (result) (eq (plist-get result :status) 'warn)) results)
    'warn)
   (t 'ok)))

;;; Report rendering

(defun ogent-doctor--status-label (status)
  "Return display label for STATUS."
  (pcase status
    ('ok "OK")
    ('warn "WARN")
    ('error "ERROR")
    ('info "INFO")
    (_ (upcase (format "%s" status)))))

(defun ogent-doctor--status-glyph (status)
  "Return the aligned single-character report glyph for STATUS."
  (pcase status
    ('ok "✓")
    ('warn "!")
    ('error "✗")
    ('info "·")
    (_ "?")))

(defun ogent-doctor--category-label (category)
  "Return the report heading for CATEGORY."
  (or (cdr (assq category ogent-doctor-categories))
      (capitalize (format "%s" (or category 'other)))))

(defun ogent-doctor--group-results (results)
  "Group RESULTS into (CATEGORY . RESULTS) cells in display order.
Categories follow `ogent-doctor-categories'; unknown categories sort
last in first-seen order.  Results keep registry order within each
category."
  (let ((order (mapcar #'car ogent-doctor-categories))
        (groups nil))
    (dolist (result results)
      (let* ((category (or (plist-get result :category) 'other))
             (cell (assq category groups)))
        (if cell
            (setcdr cell (cons result (cdr cell)))
          (push (cons category (list result)) groups))))
    (setq groups (mapcar (lambda (group)
                           (cons (car group) (nreverse (cdr group))))
                         (nreverse groups)))
    (sort groups
          (lambda (a b)
            (< (or (seq-position order (car a)) most-positive-fixnum)
               (or (seq-position order (car b)) most-positive-fixnum))))))

(defun ogent-doctor--format-entry (result width)
  "Return the report lines for one doctor RESULT.
WIDTH is the label column width shared across the report so the
status glyphs and details align.  Multi-line details indent under the
detail column; warn/error results append their remediation hint."
  (let* ((indent (make-string (+ width 5) ?\s))
         (status (plist-get result :status))
         (detail-lines (split-string (or (plist-get result :detail) "") "\n"))
         (remediation (plist-get result :remediation)))
    (string-join
     (append
      (list (format " %s %s  %s"
                    (ogent-doctor--status-glyph status)
                    (string-pad (or (plist-get result :label) "") width)
                    (car detail-lines)))
      (mapcar (lambda (line) (concat indent line)) (cdr detail-lines))
      (when (and remediation (memq status '(warn error)))
        (list (concat indent "fix: " remediation))))
     "\n")))

(defun ogent-doctor-format (results)
  "Return an Org report string for doctor RESULTS, grouped by category."
  (let ((width (apply #'max 1 (mapcar (lambda (result)
                                        (length (or (plist-get result :label) "")))
                                      results))))
    (concat
     "* Ogent Doctor\n"
     (format "Status: %s\n" (ogent-doctor--status-label
                             (ogent-doctor-summary-status results)))
     (mapconcat
      (lambda (group)
        (concat
         (format "\n** %s\n" (ogent-doctor--category-label (car group)))
         (mapconcat (lambda (result)
                      (ogent-doctor--format-entry result width))
                    (cdr group)
                    "\n")
         "\n"))
      (ogent-doctor--group-results results)
      ""))))

;;; Commands

;;;###autoload
(defun ogent-doctor (&optional include-opt-in)
  "Display a read-only health report for the current ogent setup.
With a prefix argument INCLUDE-OPT-IN, also run opt-in checks that
may touch the network (for example MCP server handshakes)."
  (interactive "P")
  (let* ((results (ogent-doctor-run include-opt-in))
         (status (ogent-doctor-summary-status results))
         (buffer (get-buffer-create ogent-doctor-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (ogent-doctor-format results))
        (org-mode)
        (view-mode 1)
        (goto-char (point-min))))
    (display-buffer buffer)
    (message "ogent doctor: %s" (ogent-doctor--status-label status))
    results))

;;;###autoload
(defun ogent-doctor-batch (&optional include-opt-in)
  "Run the doctor probes, print the report, and return an exit code.
Print the full report with `princ' and return a shell-style code for
CI and scripting: 0 when every probe is ok or info, 1 when the worst
result is a warning, 2 when any probe fails.  Wire it to the batch
exit status by wrapping the call in `kill-emacs'.
With INCLUDE-OPT-IN non-nil, also run opt-in probes that may touch
the network."
  (let ((results (ogent-doctor-run include-opt-in)))
    (princ (ogent-doctor-format results))
    (pcase (ogent-doctor-summary-status results)
      ('error 2)
      ('warn 1)
      (_ 0))))

(provide 'ogent-doctor)

;;; ogent-doctor.el ends here
