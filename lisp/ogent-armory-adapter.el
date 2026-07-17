;;; ogent-armory-adapter.el --- Armory provider adapter registry -*- lexical-binding: t; -*-

;;; Commentary:
;; Provider metadata, invocation planning, verification, and error taxonomy for
;; Org Armory runners.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'ogent-armory-evil)

(defgroup ogent-armory-adapter nil
  "Provider adapters for Org Armory runtimes."
  :group 'ogent-armory
  :prefix "ogent-armory-adapter-")

(defvar ogent-armory-codex-executable)
(defvar ogent-armory-claude-executable)
(defvar ogent-armory-gemini-executable)
(defvar ogent-armory-cursor-executable)
(defvar ogent-armory-opencode-executable)
(defvar ogent-armory-pi-executable)
(defvar ogent-armory-grok-executable)
(defvar ogent-armory-copilot-executable)
(defvar ogent-armory-runner-codex-approval)
(defvar ogent-armory-runner-codex-sandbox)
(defvar ogent-armory-runner-codex-skip-git-repo-check)

(defcustom ogent-armory-adapter-model-list-timeout 5
  "Seconds to wait for a provider CLI model list."
  :type 'number
  :group 'ogent-armory-adapter)

(defconst ogent-armory-adapter-error-kinds
  '(cli-not-found auth-expired rate-limited session-expired context-exceeded
                  transport timeout model-unavailable unknown)
  "Canonical Armory adapter error kinds.")

(defvar ogent-armory-adapter--registry (make-hash-table :test 'equal)
  "Hash table of adapter ids and aliases to adapter plists.")

(defvar ogent-armory-adapter--ids nil
  "Canonical adapter ids in registration order.")

(defvar ogent-armory-providers-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'ogent-armory-providers-refresh)
    (define-key map (kbd "C-c g") #'ogent-armory-providers-refresh)
    (define-key map "v" #'ogent-armory-provider-verify)
    (define-key map (kbd "C-c v") #'ogent-armory-provider-verify)
    (define-key map (kbd "RET") #'ogent-armory-provider-verify)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-providers-mode'.")

(define-derived-mode ogent-armory-providers-mode tabulated-list-mode
  "Armory-Providers"
  "Major mode for Armory provider adapter status."
  :group 'ogent-armory-adapter
  (setq-local tabulated-list-format
              [("Adapter" 18 t)
               ("Name" 18 t)
               ("Executable" 14 t)
               ("Status" 12 t)
               ("Modes" 18 t)
               ("Resume" 8 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-armory-providers-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-adapter--id (value)
  "Return VALUE as a normalized adapter id string."
  (downcase (string-trim (format "%s" value))))

(defun ogent-armory-adapter--symbol-id (value)
  "Return VALUE as a provider symbol."
  (intern (replace-regexp-in-string
           "[^[:alnum:]-]" "-"
           (ogent-armory-adapter--id value))))

(defun ogent-armory-adapter--symbol-value (symbol fallback)
  "Return SYMBOL value when bound, otherwise FALLBACK."
  (if (and symbol (boundp symbol))
      (symbol-value symbol)
    fallback))

(defun ogent-armory-adapter-executable (adapter)
  "Return executable configured for ADAPTER."
  (ogent-armory-adapter--symbol-value
   (plist-get adapter :executable-symbol)
   (plist-get adapter :default-executable)))

(defun ogent-armory-adapter-register (adapter)
  "Register ADAPTER and return it."
  (let ((id (ogent-armory-adapter--id (plist-get adapter :id))))
    (when (string-empty-p id)
      (user-error "Armory adapter requires an id"))
    (setq adapter (plist-put (copy-sequence adapter) :id id))
    (puthash id adapter ogent-armory-adapter--registry)
    (unless (member id ogent-armory-adapter--ids)
      (setq ogent-armory-adapter--ids
            (append ogent-armory-adapter--ids (list id))))
    (dolist (alias (plist-get adapter :aliases))
      (puthash (ogent-armory-adapter--id alias)
               adapter
               ogent-armory-adapter--registry))
    adapter))

(defun ogent-armory-adapter-list ()
  "Return registered Armory adapters."
  (delq
   nil
   (mapcar (lambda (id)
             (gethash id ogent-armory-adapter--registry))
           ogent-armory-adapter--ids)))

(defun ogent-armory-adapter-get (id)
  "Return adapter ID or nil."
  (gethash (ogent-armory-adapter--id id)
           ogent-armory-adapter--registry))

(defun ogent-armory-adapter-require (id)
  "Return adapter ID or signal a user error."
  (or (ogent-armory-adapter-get id)
      (user-error "Unsupported Armory provider adapter: %s" id)))

(defun ogent-armory-adapter-normalize-provider (provider)
  "Return provider symbol for PROVIDER."
  (let ((adapter (ogent-armory-adapter-get
                  (if (or (null provider)
                          (string-empty-p (string-trim (format "%s" provider))))
                      "codex"
                    provider))))
    (if adapter
        (plist-get adapter :provider-symbol)
      (ogent-armory-adapter--symbol-id provider))))

(defun ogent-armory-adapter-resolve-provider (provider)
  "Return registered adapter for PROVIDER."
  (ogent-armory-adapter-require
   (if (or (null provider)
           (string-empty-p (string-trim (format "%s" provider))))
       "codex"
     provider)))

(defun ogent-armory-adapter--append-option (args option value)
  "Append OPTION and VALUE to ARGS when VALUE is nonblank."
  (if (and value (not (string-blank-p (format "%s" value))))
      (append args (list option (format "%s" value)))
    args))

(defun ogent-armory-adapter--codex-invocation (adapter context)
  "Return Codex CLI invocation for ADAPTER and CONTEXT.
When CONTEXT carries a :resume-session-id, plan `codex exec resume'
instead of a fresh `codex exec' run.  The resume subcommand accepts
neither `--cd' nor `--sandbox', so those flags are omitted there."
  (let* ((resume-id (plist-get context :resume-session-id))
         (args (list "--ask-for-approval"
                     (ogent-armory-adapter--symbol-value
                      'ogent-armory-runner-codex-approval "on-request")
                     "exec")))
    (if resume-id
        (setq args (append args (list "resume")))
      (setq args (append args
                         (list "--cd" (plist-get context :workspace)
                               "--sandbox"
                               (ogent-armory-adapter--symbol-value
                                'ogent-armory-runner-codex-sandbox
                                "workspace-write")))))
    (when (ogent-armory-adapter--symbol-value
           'ogent-armory-runner-codex-skip-git-repo-check t)
      (setq args (append args (list "--skip-git-repo-check"))))
    (setq args (ogent-armory-adapter--append-option
                args "--model" (plist-get context :model)))
    (when resume-id
      (setq args (append args (list resume-id))))
    (list :program (ogent-armory-adapter-executable adapter)
          :args (append args (list "-"))
          :stdin (plist-get context :prompt))))

(defun ogent-armory-adapter--claude-invocation (adapter context)
  "Return Claude Code invocation for ADAPTER and CONTEXT."
  (let ((args (list "-p"
                    "--permission-mode"
                    (or (plist-get context :permission-mode) "default")
                    "--add-dir"
                    (plist-get context :root))))
    (setq args (ogent-armory-adapter--append-option
                args "--model" (plist-get context :model)))
    (setq args (ogent-armory-adapter--append-option
                args "--effort" (plist-get context :effort)))
    (setq args (ogent-armory-adapter--append-option
                args "--resume" (plist-get context :resume-session-id)))
    (list :program (ogent-armory-adapter-executable adapter)
          :args (append args (list (plist-get context :prompt)))
          :stdin nil)))

(defun ogent-armory-adapter--gemini-invocation (adapter context)
  "Return Gemini CLI invocation for ADAPTER and CONTEXT."
  (let ((args (list "-p" (plist-get context :prompt))))
    (setq args (ogent-armory-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-armory-adapter-executable adapter)
          :args args
          :stdin nil)))

(defun ogent-armory-adapter--cursor-invocation (adapter context)
  "Return Cursor Agent invocation for ADAPTER and CONTEXT."
  (let ((args (list "-p" (plist-get context :prompt)
                    "--output-format" "text")))
    (setq args (ogent-armory-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-armory-adapter-executable adapter)
          :args args
          :stdin nil)))

(defun ogent-armory-adapter--opencode-invocation (adapter context)
  "Return OpenCode invocation for ADAPTER and CONTEXT."
  (let ((args (list "run" (plist-get context :prompt))))
    (setq args (ogent-armory-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-armory-adapter-executable adapter)
          :args args
          :stdin nil)))

(defun ogent-armory-adapter--copilot-invocation (adapter context)
  "Return GitHub Copilot CLI invocation for ADAPTER and CONTEXT."
  (let ((args (list "-p" (plist-get context :prompt) "--allow-all")))
    (setq args (ogent-armory-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-armory-adapter-executable adapter)
          :args args
          :stdin nil)))

(defun ogent-armory-adapter--gptel-native-invocation (_adapter _context)
  "Return the in-process invocation stub for the gptel-native adapter.
The native runner drives `gptel-request' directly (see
ogent-armory-native.el), so there is no external program to spawn."
  (list :program nil :args nil :stdin nil))

(defun ogent-armory-adapter-build-invocation (adapter context)
  "Return process invocation for ADAPTER with CONTEXT."
  (let ((builder (plist-get adapter :build-invocation)))
    (unless builder
      (let ((reason (plist-get adapter :unsupported-reason)))
        (if reason
            (user-error "Armory adapter %s cannot run: %s"
                        (plist-get adapter :id) reason)
          (user-error "Armory adapter has no runnable invocation: %s"
                      (plist-get adapter :id)))))
    (append
     (list :adapter-id (plist-get adapter :id)
           :provider (plist-get adapter :provider-symbol)
           :runtime-mode (or (plist-get context :runtime-mode) 'native))
     (funcall builder adapter context))))

(defun ogent-armory-adapter-skill-mounts (adapter skills)
  "Return adapter-native skill mounts for ADAPTER and SKILLS."
  (when-let ((mount (plist-get adapter :skill-mount-function)))
    (funcall mount adapter skills)))

(defun ogent-armory-adapter--normalize-models (models)
  "Return normalized model ids from MODELS."
  (seq-filter
   (lambda (model)
     (not (string-blank-p model)))
   (delete-dups
    (mapcar
     (lambda (model)
       (string-trim
        (format "%s"
                (cond
                 ((stringp model) model)
                 ((and (listp model) (plist-get model :id))
                  (plist-get model :id))
                 ((and (listp model) (alist-get 'id model))
                  (alist-get 'id model))
                 (t model)))))
     models))))

(defun ogent-armory-adapter-models (adapter)
  "Return model ids for ADAPTER.
Provider-specific model list functions are preferred, with static adapter
metadata as the fallback completion list."
  (let* ((static (ogent-armory-adapter--normalize-models
                  (plist-get adapter :models)))
         (dynamic nil)
         (list-function (plist-get adapter :model-list-function)))
    (when list-function
      (setq dynamic
            (condition-case err
                (ogent-armory-adapter--normalize-models
                 (funcall list-function adapter))
              (error
               (message "Armory model listing failed for %s: %s"
                        (plist-get adapter :id)
                        (error-message-string err))
               nil))))
    (or dynamic static)))

(defun ogent-armory-adapter--call-lines (program args)
  "Return output lines from PROGRAM ARGS, or nil when unavailable."
  (when-let ((path (and program (executable-find program))))
    (with-timeout (ogent-armory-adapter-model-list-timeout nil)
      (with-temp-buffer
        (let ((status (apply #'call-process path nil t nil args)))
          (when (zerop status)
            (split-string (buffer-string) "\n" t "[[:space:]\r]+")))))))

(defun ogent-armory-adapter--opencode-models (adapter)
  "Return current OpenCode model ids for ADAPTER."
  (ogent-armory-adapter--call-lines
   (ogent-armory-adapter-executable adapter)
   '("models")))

(defun ogent-armory-adapter-classify-error (_adapter text &optional exit-status)
  "Classify adapter error TEXT and EXIT-STATUS."
  (let* ((raw (or text ""))
         (lower (downcase raw))
         (kind
          (cond
           ((or (not (null (and exit-status (= exit-status 127))))
                (string-match-p "command not found\\|no such file\\|executable"
                                lower))
            'cli-not-found)
           ((string-match-p "auth\\|login\\|credential\\|api key\\|unauthorized"
                            lower)
            'auth-expired)
           ((string-match-p "rate limit\\|too many requests\\|quota" lower)
            'rate-limited)
           ((string-match-p "session .*expired\\|session .*not found\\|resume"
                            lower)
            'session-expired)
           ((string-match-p "context\\|token limit\\|maximum.*tokens" lower)
            'context-exceeded)
           ((string-match-p "timed out\\|timeout" lower)
            'timeout)
           ((string-match-p "model .*unavailable\\|unknown model\\|model not found"
                            lower)
            'model-unavailable)
           ((string-match-p "network\\|transport\\|econn\\|connection" lower)
            'transport)
           (t 'unknown))))
    (list :kind kind
          :message (string-trim raw)
          :exit-status exit-status)))

(defun ogent-armory-adapter-test-environment (adapter)
  "Return environment status for ADAPTER."
  (let* ((program (ogent-armory-adapter-executable adapter))
         (path (and program (executable-find program))))
    (list :adapter-id (plist-get adapter :id)
          :program program
          :path path
          :available (not (null path))
          :status (if path "available" "missing"))))

(defun ogent-armory-adapter-runtime-candidates ()
  "Return completion candidates for adapter runtime choices."
  (apply
   #'append
   (mapcar
    (lambda (adapter)
      (mapcar
       (lambda (mode)
         (let ((label (format "%s / %s"
                              (plist-get adapter :name)
                              mode)))
           (cons label (list :adapter-id (plist-get adapter :id)
                             :runtime-mode mode))))
       (plist-get adapter :runtime-modes)))
    (ogent-armory-adapter-list))))

(defun ogent-armory-runtime-picker (&optional prompt)
  "Read and return a Armory runtime candidate using PROMPT."
  (interactive)
  (let* ((candidates (ogent-armory-adapter-runtime-candidates))
         (choice (completing-read (or prompt "Runtime: ")
                                  (mapcar #'car candidates)
                                  nil t)))
    (cdr (assoc choice candidates))))

(defun ogent-armory-providers--entry (adapter)
  "Return a tabulated entry for ADAPTER."
  (let* ((status (ogent-armory-adapter-test-environment adapter))
         (program (plist-get status :program)))
    (list
     adapter
     (vector
      (plist-get adapter :id)
      (plist-get adapter :name)
      (or program "")
      (plist-get status :status)
      (string-join (mapcar #'symbol-name
                           (plist-get adapter :runtime-modes))
                   ",")
      (if (plist-get adapter :supports-session-resume) "yes" "no")))))

(defun ogent-armory-providers--entries ()
  "Return provider status entries."
  (mapcar #'ogent-armory-providers--entry
          (ogent-armory-adapter-list)))

;;;###autoload
(defun ogent-armory-providers ()
  "Open Armory provider adapter status."
  (interactive)
  (let ((buffer (get-buffer-create "*ogent-armory-providers*")))
    (with-current-buffer buffer
      (ogent-armory-providers-mode)
      (setq tabulated-list-entries #'ogent-armory-providers--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-providers-refresh (&rest _)
  "Refresh Armory provider status."
  (interactive)
  (tabulated-list-print t))

;;;###autoload
(defun ogent-armory-provider-verify (&optional adapter-id)
  "Verify ADAPTER-ID or the provider at point."
  (interactive)
  (let* ((adapter (or (and adapter-id
                           (ogent-armory-adapter-require adapter-id))
                      (tabulated-list-get-id)
                      (ogent-armory-adapter-require
                       (completing-read
                        "Provider: "
                        (mapcar (lambda (adapter)
                                  (plist-get adapter :id))
                                (ogent-armory-adapter-list))
                        nil t))))
         (status (ogent-armory-adapter-test-environment adapter)))
    (message "%s: %s%s"
             (plist-get adapter :name)
             (plist-get status :status)
             (if-let ((path (plist-get status :path)))
                 (format " (%s)" path)
               ""))
    status))

;; Capability grounding (ogent-h3y).  Invocation builders may only emit
;; CLI flags that appear verbatim in a checked-in help snapshot under
;; `ogent-armory-adapter-ground-directory' (ogent-8e0.7's honesty
;; rule).  `ogent-armory-adapter-ground' diffs a live --help against
;; the newest snapshot and reports drift; the adapter test suite
;; asserts that every builder-emitted flag appears in the snapshot.

(defconst ogent-armory-adapter-ground--default-directory
  (expand-file-name
   "../test/data/cli-help/"
   (file-name-directory
    (or load-file-name buffer-file-name default-directory)))
  "Snapshot directory resolved relative to this library at load time.")

(defcustom ogent-armory-adapter-ground-directory nil
  "Directory of checked-in CLI help snapshots, or nil for the default.
Snapshots are named <adapter-id>-<version>.txt and collected verbatim
from the provider CLIs (see `ogent-armory-adapter-ground').  When nil,
resolve test/data/cli-help/ relative to this library."
  :type '(choice (const :tag "Relative to library" nil) directory)
  :group 'ogent-armory-adapter)

(defun ogent-armory-adapter-ground--directory ()
  "Return the snapshot directory for CLI help grounding."
  (or ogent-armory-adapter-ground-directory
      ogent-armory-adapter-ground--default-directory))

(defun ogent-armory-adapter-ground--call-string (program args)
  "Return combined output of PROGRAM run with ARGS, or nil if not found."
  (when-let ((path (and program (executable-find program))))
    (with-temp-buffer
      (apply #'call-process path nil t nil args)
      (buffer-string))))

(defun ogent-armory-adapter-ground--parse-version (text)
  "Return the first dotted version number in TEXT, or nil."
  (when (and text (string-match "\\([0-9]+\\(?:\\.[0-9]+\\)+\\)" text))
    (match-string 1 text)))

(defun ogent-armory-adapter-ground--live-version (adapter)
  "Return ADAPTER's live CLI version string, or nil."
  (ogent-armory-adapter-ground--parse-version
   (ogent-armory-adapter-ground--call-string
    (ogent-armory-adapter-executable adapter) '("--version"))))

(defun ogent-armory-adapter-ground--help-commands (adapter)
  "Return the argument vectors whose help output grounds ADAPTER."
  (or (plist-get adapter :ground-help-commands) '(("--help"))))

(defun ogent-armory-adapter-ground--live-help (adapter)
  "Collect ADAPTER's live CLI help in snapshot format, or nil.
Each grounding surface (the adapter's :ground-help-commands) is
emitted verbatim below a \"$ <command>\" provenance header."
  (let ((program (ogent-armory-adapter-executable adapter))
        (name (plist-get adapter :default-executable)))
    (when (and program (executable-find program))
      (mapconcat
       (lambda (args)
         (concat "$ " (string-join (cons (or name program) args) " ") "\n"
                 (or (ogent-armory-adapter-ground--call-string program args)
                     "")))
       (ogent-armory-adapter-ground--help-commands adapter)
       "\n"))))

(defun ogent-armory-adapter-ground--match-snapshots (adapter-id file-names)
  "Return (VERSION . NAME) pairs for ADAPTER-ID snapshots in FILE-NAMES.
Pairs are sorted newest version first; NAME is kept as given."
  (let ((regexp (concat "\\`" (regexp-quote adapter-id)
                        "-\\([0-9][^/]*\\)\\.txt\\'")))
    (sort (delq nil
                (mapcar (lambda (name)
                          (when (string-match regexp name)
                            (cons (match-string 1 name) name)))
                        file-names))
          (lambda (a b)
            (condition-case nil
                (version< (car b) (car a))
              (error (string< (car b) (car a))))))))

(defun ogent-armory-adapter-ground--pick (pairs version)
  "Return the PAIRS entry matching VERSION exactly, else the newest."
  (or (and version (assoc version pairs))
      (car pairs)))

(defun ogent-armory-adapter-ground-snapshot (adapter-id &optional version)
  "Return the checked-in help snapshot plist for ADAPTER-ID, or nil.
Prefer the snapshot matching VERSION exactly, falling back to the
newest one.  The plist carries :file, :version, and :text.  When no
snapshot exists, emit a named warning and return nil: missing
grounding data downgrades to a skip, never a failure (ogent-8e0.7)."
  (let* ((dir (ogent-armory-adapter-ground--directory))
         (pair (ogent-armory-adapter-ground--pick
                (and (file-directory-p dir)
                     (ogent-armory-adapter-ground--match-snapshots
                      adapter-id (directory-files dir)))
                version)))
    (if (not pair)
        (prog1 nil
          (display-warning
           'ogent-armory-adapter-ground
           (format "No CLI help snapshot for %s under %s; grounding skipped"
                   adapter-id dir)))
      (let ((file (expand-file-name (cdr pair) dir)))
        (list :file file
              :version (car pair)
              :text (with-temp-buffer
                      (insert-file-contents file)
                      (buffer-string)))))))

(defun ogent-armory-adapter-ground--lines (text)
  "Return the trimmed, deduplicated, nonblank lines of TEXT."
  (seq-uniq (split-string (or text "") "\n" t "[[:space:]\r]+") #'string=))

(defun ogent-armory-adapter-ground--diff-lines (snapshot live)
  "Diff SNAPSHOT against LIVE help text line-wise.
Lines are compared whitespace-trimmed as sets; the returned plist's
:added lists lines only in LIVE, :removed lines only in SNAPSHOT."
  (let ((old (ogent-armory-adapter-ground--lines snapshot))
        (new (ogent-armory-adapter-ground--lines live)))
    (list :added (seq-remove (lambda (line) (member line old)) new)
          :removed (seq-remove (lambda (line) (member line new)) old))))

(defun ogent-armory-adapter-ground--save-snapshot (adapter version text)
  "Write TEXT as ADAPTER's VERSION help snapshot; return the file path."
  (let* ((dir (ogent-armory-adapter-ground--directory))
         (file (expand-file-name (format "%s-%s.txt"
                                         (plist-get adapter :id)
                                         (or version "unversioned"))
                                 dir)))
    (make-directory dir t)
    (write-region text nil file)
    file))

(defun ogent-armory-adapter-ground--show-report (report)
  "Render drift REPORT in the *ogent-armory-ground* buffer."
  (let ((buffer (get-buffer-create "*ogent-armory-ground*"))
        (added (plist-get report :added))
        (removed (plist-get report :removed)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Adapter:  %s\n" (plist-get report :adapter-id))
                (format "Live:     %s\n" (or (plist-get report :live-version)
                                             "unknown version"))
                (format "Snapshot: %s (%s)\n\n"
                        (plist-get report :snapshot-file)
                        (plist-get report :snapshot-version)))
        (if (not (or added removed))
            (insert "No drift: live help matches the snapshot.\n")
          (insert (format "Drift: %d line(s) added, %d removed\n\n"
                          (length added) (length removed)))
          (dolist (line added)
            (insert "+ " line "\n"))
          (dolist (line removed)
            (insert "- " line "\n"))))
      (goto-char (point-min))
      (special-mode))
    (pop-to-buffer buffer)))

;;;###autoload
(defun ogent-armory-adapter-ground (adapter-id &optional save)
  "Diff ADAPTER-ID's live CLI help against its checked-in snapshot.
Run the adapter's grounding help commands, compare the output
line-wise with the newest snapshot in
`ogent-armory-adapter-ground-directory' (preferring one matching the
live version), and return a report plist whose :added lines appear
only in the live help and whose :removed lines appear only in the
snapshot.  Interactively, show the report in a buffer.  With prefix
argument SAVE, first write the live help as a fresh
<adapter>-<version>.txt snapshot.  A missing snapshot produces a named
warning and a nil return, never an error."
  (interactive
   (list (completing-read
          "Ground adapter CLI help: "
          (mapcar (lambda (adapter) (plist-get adapter :id))
                  (seq-filter (lambda (adapter)
                                (plist-get adapter :default-executable))
                              (ogent-armory-adapter-list)))
          nil t)
         current-prefix-arg))
  (let* ((adapter (ogent-armory-adapter-require adapter-id))
         (live-help (ogent-armory-adapter-ground--live-help adapter))
         (live-version (and live-help
                            (ogent-armory-adapter-ground--live-version
                             adapter))))
    (unless live-help
      (user-error "Armory adapter %s: executable %s not found on PATH"
                  (plist-get adapter :id)
                  (or (ogent-armory-adapter-executable adapter) "nil")))
    (when save
      (message "ogent: saved CLI help snapshot %s"
               (ogent-armory-adapter-ground--save-snapshot
                adapter live-version live-help)))
    (when-let ((snapshot (ogent-armory-adapter-ground-snapshot
                          (plist-get adapter :id) live-version)))
      (let ((report (append (list :adapter-id (plist-get adapter :id)
                                  :live-version live-version
                                  :snapshot-file (plist-get snapshot :file)
                                  :snapshot-version
                                  (plist-get snapshot :version))
                            (ogent-armory-adapter-ground--diff-lines
                             (plist-get snapshot :text) live-help))))
        (when (called-interactively-p 'any)
          (ogent-armory-adapter-ground--show-report report))
        report))))

(defun ogent-armory-adapter--builtin ()
  "Register built-in Armory adapters."
  (setq ogent-armory-adapter--registry (make-hash-table :test 'equal))
  (setq ogent-armory-adapter--ids nil)
  (dolist
      (adapter
       `((:id "codex-cli"
              :provider-symbol codex
              :adapter-type "codex_local"
              :name "Codex CLI"
              :aliases ("codex" "codex-cli" "openai-codex" "codex_local")
              :default-executable "codex"
              :executable-symbol ogent-armory-codex-executable
              :models ("gpt-5.5" "gpt-5.4" "gpt-5.3-codex")
              :effort-levels ("low" "medium" "high" "xhigh")
              :runtime-modes (native terminal)
              :supports-session-resume t
              :supports-detached-runs t
              ;; Grounding surfaces for the builder's emitted flags:
              ;; --ask-for-approval is top-level, the rest live on the
              ;; exec / exec resume subcommands.
              :ground-help-commands (("--help") ("exec" "--help")
                                     ("exec" "resume" "--help"))
              :build-invocation ogent-armory-adapter--codex-invocation)
         (:id "claude-code"
              :provider-symbol claude
              :adapter-type "claude_local"
              :name "Claude Code"
              :aliases ("claude" "claude-code" "anthropic" "anthropic-claude"
                        "claude_local")
              :default-executable "claude"
              :executable-symbol ogent-armory-claude-executable
              :models ("fable" "opus" "sonnet")
              :effort-levels ("low" "medium" "high" "xhigh" "max")
              :runtime-modes (native terminal)
              :supports-session-resume t
              :supports-detached-runs t
              :ground-help-commands (("--help"))
              :build-invocation ogent-armory-adapter--claude-invocation)
         (:id "gemini-cli"
              :provider-symbol gemini
              :adapter-type "gemini_local"
              :name "Gemini CLI"
              :aliases ("gemini" "gemini-cli" "google-gemini" "gemini_local")
              :default-executable "gemini"
              :executable-symbol ogent-armory-gemini-executable
              :models ("auto" "gemini-3-pro" "gemini-2.5-pro")
              :effort-levels nil
              :runtime-modes (native terminal)
              ;; Resume flags not yet grounded against a real CLI
              ;; (no local gemini --help); builder emits none, so the
              ;; capability must not be advertised (ogent-8e0.6).
              :supports-session-resume nil
              :supports-detached-runs t
              :build-invocation ogent-armory-adapter--gemini-invocation)
         (:id "cursor-cli"
              :provider-symbol cursor
              :adapter-type "cursor_local"
              :name "Cursor Agent"
              :aliases ("cursor" "cursor-cli" "cursor-agent" "cursor_local")
              :default-executable "cursor-agent"
              :executable-symbol ogent-armory-cursor-executable
              :models ("auto" "gpt-5" "claude-4.5-sonnet")
              :effort-levels nil
              :runtime-modes (native terminal)
              ;; See gemini-cli: resume flags ungrounded (ogent-8e0.6).
              :supports-session-resume nil
              :supports-detached-runs t
              :build-invocation ogent-armory-adapter--cursor-invocation)
         (:id "opencode"
              :provider-symbol opencode
              :adapter-type "opencode_local"
              :name "OpenCode"
              :aliases ("opencode" "opencode-cli" "opencode_local")
              :default-executable "opencode"
              :executable-symbol ogent-armory-opencode-executable
              :models nil
              :model-list-function ogent-armory-adapter--opencode-models
              :effort-levels nil
              :runtime-modes (native terminal)
              ;; See gemini-cli: resume flags ungrounded (ogent-8e0.6).
              :supports-session-resume nil
              :supports-detached-runs t
              :build-invocation ogent-armory-adapter--opencode-invocation)
         (:id "pi-cli"
              :provider-symbol pi
              :adapter-type "pi_local"
              :name "Pi CLI"
              :aliases ("pi" "pi-cli" "pi_local")
              :default-executable "pi"
              :executable-symbol ogent-armory-pi-executable
              :models nil
              :effort-levels ("brief" "normal" "deep")
              :runtime-modes (native terminal)
              ;; Adapter cannot run at all yet; see :unsupported-reason.
              :supports-session-resume nil
              :supports-detached-runs nil
              :unsupported-reason
              "pi CLI invocation flags are unverified (no local pi --help to ground them)")
         (:id "grok-cli"
              :provider-symbol grok
              :adapter-type "grok_local"
              :name "Grok CLI"
              :aliases ("grok" "grok-cli" "xai" "grok_local")
              :default-executable "grok"
              :executable-symbol ogent-armory-grok-executable
              :models ("grok-4")
              :effort-levels nil
              :runtime-modes (native terminal)
              :supports-session-resume nil
              :supports-detached-runs nil
              :unsupported-reason
              "grok CLI invocation flags are unverified (no local grok --help to ground them)")
         (:id "copilot-cli"
              :provider-symbol copilot
              :adapter-type "copilot_local"
              :name "GitHub Copilot"
              :aliases ("copilot" "github-copilot" "copilot-cli" "copilot_local")
              :default-executable "copilot"
              :executable-symbol ogent-armory-copilot-executable
              :models ("gpt-5.2-codex" "gpt-5")
              :effort-levels nil
              :runtime-modes (native terminal)
              :supports-session-resume nil
              :supports-detached-runs t
              :build-invocation ogent-armory-adapter--copilot-invocation)
         (:id "gptel-native"
              :provider-symbol gptel
              :adapter-type "gptel_native"
              :name "gptel (in-process)"
              :aliases ("gptel" "gptel-native" "gptel_native")
              :models nil
              :effort-levels nil
              :runtime-modes (native)
              ;; Native resume reloads the stored conversation turns
              ;; into the gptel message list (ogent-armory-native.el,
              ;; `ogent-armory-native--resume-messages'); flipped in
              ;; the same change as that implementation (ogent-8e0.6
              ;; capability-honesty rule).
              :supports-session-resume t
              :supports-detached-runs nil
              :build-invocation ogent-armory-adapter--gptel-native-invocation)))
    (ogent-armory-adapter-register adapter)))

(ogent-armory-adapter--builtin)

(defun ogent-armory-providers--evil-local-keys ()
  "Install local Evil keys for Armory providers."
  (ogent-armory-evil-install-local-bindings ogent-armory-providers-mode-map))

(defun ogent-armory-providers--setup-evil ()
  "Set up Evil integration for Armory providers."
  (ogent-armory-evil-setup-mode
   'ogent-armory-providers-mode
   ogent-armory-providers-mode-map
   'ogent-armory-providers-mode-hook
   #'ogent-armory-providers--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-providers--setup-evil))

(provide 'ogent-armory-adapter)

;;; ogent-armory-adapter.el ends here
