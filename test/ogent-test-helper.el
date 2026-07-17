;;; ogent-test-helper.el --- Test bootstrap for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides helper utilities to load project code and execute ert suites.

;;; Code:

(require 'ert)
(require 'subr-x)
(require 'org)

;; Batch test runs must never block on Org's interactive prompt
;;   "Non-existent agenda file ... [R]emove from list or [A]bort?"
;; Suites create and tear down temporary Org trees, so a stale entry can
;; outlive its file; Emacs 29's bundled Org raises that prompt (Emacs 30
;; does not), which hangs `emacs --batch' forever on `read-char'.  Skip
;; unreadable agenda files, and make `org-check-agenda-file' non-interactive
;; so the prompt can never fire regardless of the calling path.
(require 'org-agenda nil t)
(setq org-agenda-skip-unavailable-files t)

(defun ogent-test--silence-agenda-check (orig file)
  "Batch-safe `org-check-agenda-file': never prompt for a missing FILE.
Validate an existing FILE through ORIG; for a missing FILE, drop it from
`org-agenda-files' (Org's non-destructive [R]emove choice) and return nil
instead of reading a keystroke."
  (if (file-exists-p file)
      (funcall orig file)
    (when (boundp 'org-agenda-files)
      (setq org-agenda-files (delete file org-agenda-files)))
    nil))

(advice-add 'org-check-agenda-file :around #'ogent-test--silence-agenda-check)

;; Preload jka-compr while .elc is still in `load-suffixes'.  Without
;; this, the exclusion below leaves only compressed built-in sources
;; (e.g. face-remap.el.gz on Nix Emacs) loadable via jka-compr, whose
;; own source is also compressed - requiring it then recurses fatally
;; ("Recursive load ... jka-compr.el.gz").
(require 'jka-compr)

;; Exclude .elc from load-suffixes so stale bytecode (which may embed
;; outdated macro expansions, e.g. magit-insert-section) is never loaded.
;; load-prefer-newer alone is insufficient: it still picks a newer .elc
;; over .el, but the .elc may contain stale inlined forms.
(setq load-suffixes (remove ".elc" load-suffixes))
;;
;; BOUNDARY: the exclusion above cannot protect THIS file's own load -
;; a bare `(require 'ogent-test-helper)' under default `load-prefer-newer'
;; (nil) picks a stale test/ogent-test-helper.elc over an edited .el,
;; resurrecting old helper definitions (observed 2026-07-17: void-function
;; on a newly added helper).  Safe entry points, all of which force the
;; source or fresh bytecode: CI and the store-integrity script load
;; "test/ogent-test-helper.el" by explicit .el path; makem's run_emacs
;; sets `load-prefer-newer' t.  CONVENTION for ad-hoc batch runs: load
;; the helper by explicit .el path first (-l test/ogent-test-helper.el),
;; and regenerate this file's .elc whenever you edit it.

(defconst ogent-test-root
  (file-name-directory (or load-file-name buffer-file-name))
  "Absolute path to the ogent/test directory.")

(defconst ogent-project-root
  (expand-file-name ".." ogent-test-root)
  "Absolute path to the ogent project root from tests.")

(add-to-list 'load-path (expand-file-name "lisp" ogent-project-root))
(add-to-list 'load-path (expand-file-name "lisp/ui" ogent-project-root))
(add-to-list 'load-path ogent-test-root)
(add-to-list 'load-path (expand-file-name "ui" ogent-test-root))

;;; Transient source-row parsing (version independent)
;;
;; Tests asserting menu wiring must not walk transient's PRIVATE
;; layout representation: its shape differs across the transient
;; versions in CI (built-in) and local (bundled) Emacsen.  Instead,
;; pair (a) a shape-agnostic runtime registration check -
;; (transient-get-suffix PREFIX KEY) non-nil - with (b) the source
;; parse below for the KEY -> COMMAND binding and row keywords.

(defun ogent-test--transient-row (row)
  "Parse one suffix ROW list into (KEY COMMAND . KEYWORD-PLIST).
Return nil when ROW carries no key or command.  Strings after the
key are descriptions; keywords consume their value; the first bare
symbol outside a keyword pair is the command."
  (let ((items row) key command plist)
    (when (stringp (car items))
      (setq key (pop items)))
    (while items
      (let ((x (pop items)))
        (cond
         ((keywordp x) (setq plist (plist-put plist x (pop items))))
         ((stringp x))
         ((symbolp x) (unless command (setq command x))))))
    (when (and key command)
      (cons key (cons command plist)))))

(defun ogent-test--transient-vector-rows (vector)
  "Collect parsed suffix rows from group VECTOR, recursing into subgroups."
  (let (rows)
    (dolist (element (append vector nil))
      (cond
       ((vectorp element)
        (setq rows (nconc rows (ogent-test--transient-vector-rows element))))
       ((consp element)
        (let ((row (ogent-test--transient-row element)))
          (when row (push row rows))))))
    (nreverse rows)))

(defun ogent-test-transient-source-rows (prefix file)
  "Return PREFIX's suffix rows (KEY COMMAND . PLIST) parsed from FILE.
FILE is relative to `ogent-project-root'.  The prefix body begins
after NAME + ARGLIST + optional docstring (cddr from the arglist
position when a docstring is present).  Works for
`transient-define-prefix' and `ogent-armory-ui--define-prefix'
forms alike; signals when PREFIX is not found in FILE."
  (with-temp-buffer
    (insert-file-contents (expand-file-name file ogent-project-root))
    (goto-char (point-min))
    (let (rows found)
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (and (consp form)
                         (memq (car form) '(transient-define-prefix
                                             ogent-armory-ui--define-prefix))
                         (eq (nth 1 form) prefix))
                (setq found t)
                (let* ((rest (nthcdr 2 form))
                       (body (if (stringp (cadr rest))
                                 (cddr rest)
                               (cdr rest))))
                  (while body
                    (let ((element (pop body)))
                      (cond
                       ((keywordp element) (pop body))
                       ((vectorp element)
                        (setq rows
                              (nconc rows
                                     (ogent-test--transient-vector-rows
                                      element)))))))))))
        (end-of-file nil))
      (unless found
        (error "Prefix %s not found in %s" prefix file))
      rows)))

(defun ogent-test-transient-row (prefix file key)
  "Return PREFIX's parsed row for KEY from FILE, or nil.
See `ogent-test-transient-source-rows'."
  (assoc key (ogent-test-transient-source-rows prefix file)))

;;; Store guard: persistence off by default under ert
;;
;; Suites must never write real user stores.  Modules may load at any
;; point during a suite and `defcustom' defaults evaluate at module load
;; time, so the helper cannot rely on load order: it forcibly
;; `setq-default's every persistence flag and store path below
;; (`defcustom' preserves an existing default binding), and re-asserts
;; them before every test via `ert-run-test' advice (ert has no public
;; per-test setup hook) so a module loaded mid-suite cannot restore its
;; default.  Tests may still dynamically let-bind any of these.
;;
;; AUDIT 2026-07-16 (ogent-aq8.1) - every defcustom/defvar under lisp/
;; whose default resolves under `user-emacs-directory', `org-directory',
;; HOME, or the project root:
;;
;; Guarded flags (forced off; persistence is opt-in via the fixture):
;; - [x] ogent-analytics-enabled        (ogent-analytics.el, default t)
;; - [x] ogent-ledger-enabled           (ogent-ledger.el, default nil)
;; - [x] ogent-companion-persist-links  (ogent-companion.el, default t)
;; Guarded paths (redirected under `ogent-test-store-root'):
;; - [x] ogent-analytics-db-name        (ogent-analytics.el; relative name
;;       resolved against the project root at use time - an absolute
;;       value short-circuits that resolution)
;; - [x] ogent-ledger-file              (ogent-ledger.el; ditto)
;; - [x] ogent-companion-link-registry-file (ogent-companion.el;
;;       user-emacs-directory)
;; - [x] ogent-capture-notes-file       (ogent-notes.el; org-directory)
;; - [x] ogent-capture-companion-file   (ogent-notes.el; org-directory)
;; - [x] ogent-session-directory        (ogent-session.el;
;;       user-emacs-directory)
;; - [x] ogent-anthropic-oauth-tokens-dir (ogent-anthropic-oauth.el;
;;       user-emacs-directory)
;; - [x] ogent-anthropic-oauth--token-file (ogent-anthropic-oauth.el;
;;       defvar cache - pinned so the module never probes and then
;;       writes Jake's real token files found via
;;       `ogent-anthropic-oauth--known-token-paths')
;; - [x] ogent-codex-oauth-auth-file    (ogent-codex-oauth.el; nil falls
;;       back to ~/.codex/auth.json at use time - pinned so tests never
;;       read real credentials)
;; - [x] ogent-codemap-cache-directory  (ogent-codemap-task.el;
;;       user-emacs-directory)
;; - [x] ogent-prompts-snippet-dir      (ogent-prompts-yasnippet.el;
;;       user-emacs-directory)
;; - [x] ogent-issues-agenda-file       (ogent-issues-bd.el; nil derives
;;       a write target under user-emacs-directory at use time)
;; Audited, deliberately NOT guarded:
;; - [x] ogent-anthropic-oauth--known-token-paths (read-only probe list
;;       of HOME paths; harmless once --token-file is pinned)
;; - [x] ogent-presets-file-name        (read-only project config .ogent.el)
;; - [x] ogent-project-prompts-file     (nil; read-only when user-set)
;; - [x] ogent-source-directory         (nil; dev-reload helper, read-only)
;; - [x] ogent-tools-project-root       (nil; path-resolution base only)
;; - [x] ogent-armory-runner-ensure-beads-redirect (writes only into a
;;       run's explicitly provisioned workspace, which suites always
;;       point at temp dirs; ogent-armory-runner-tests relies on the
;;       default)
;; - [x] ogent-armory-global-agents-root / ogent-armory-backup-directory-name
;;       / ogent-armory-scheduler-roots (resolve under a caller-supplied
;;       Armory directory, never under the four bases)
;; - [x] ogent-armory-skill-include-user-roots (read-only skill
;;       discovery; suites bind it explicitly both ways)
;; - [x] ogent-codemap-source-directories / ogent-zen-workspace-brief-directories
;;       (read-only relative scan lists)
;; - [x] ogent-armory-adapter-ground-directory (nil; resolves checked-in
;;       CLI-help snapshots under the project tree at use time - tests
;;       only read; the sole writer is the interactive C-u save path,
;;       never invoked by tests)
;; - [x] transient-history-file (third-party; scratch file below)
;;
;; Subprocess note: sqlite mutations bypass `write-region' entirely (the
;; native sqlite API), and spawned processes inherit the environment.
;; The tripwire section below (ogent-aq8.2) guards those chokepoints;
;; `ogent-test-with-real-store' exports OGENT_TEST_STORE_ROOT into
;; `process-environment' so future subprocess-based store code can
;; honor it.

(defvar ogent-analytics-enabled)
(defvar ogent-ledger-enabled)
(defvar ogent-companion-persist-links)
(defvar ogent-analytics-db-name)
(defvar ogent-ledger-file)
(defvar ogent-companion-link-registry-file)
(defvar ogent-capture-notes-file)
(defvar ogent-capture-companion-file)
(defvar ogent-session-directory)
(defvar ogent-anthropic-oauth-tokens-dir)
(defvar ogent-anthropic-oauth--token-file)
(defvar ogent-codex-oauth-auth-file)
(defvar ogent-codemap-cache-directory)
(defvar ogent-prompts-snippet-dir)
(defvar ogent-issues-agenda-file)

(defconst ogent-test-store-root
  (make-temp-name (expand-file-name "ogent-test-store-" temporary-file-directory))
  "Per-session root for redirected test stores.
The helper never creates this directory; only the opt-in
`ogent-test-with-real-store' fixture provisions under it, so its mere
existence indicates a test wrote to a store without the fixture.")

(defvar ogent-test--store-provision-log nil
  "Directories provisioned by `ogent-test-with-real-store', newest first.
Provisioned stores are retained (never deleted); this log records where
to look.")

(defconst ogent-test-store-guard-flags
  '(ogent-analytics-enabled
    ogent-ledger-enabled
    ogent-companion-persist-links)
  "Persistence flags forced off by `ogent-test-store-guard-assert'.")

(defconst ogent-test-store-guard-paths
  (list 'ogent-analytics-db-name "analytics.sqlite"
        'ogent-ledger-file "ledger.org"
        'ogent-companion-link-registry-file "companion-links.el"
        'ogent-capture-notes-file "capture-notes.org"
        'ogent-capture-companion-file "capture-companion.org"
        'ogent-session-directory "sessions/"
        'ogent-anthropic-oauth-tokens-dir "anthropic-oauth/"
        'ogent-anthropic-oauth--token-file "anthropic-oauth/tokens.el"
        'ogent-codex-oauth-auth-file "codex-auth.json"
        'ogent-codemap-cache-directory "codemap-cache"
        'ogent-prompts-snippet-dir "prompt-snippets"
        'ogent-issues-agenda-file "beads-agenda.org")
  "Plist of store path variables and their targets under the store root.")

(defun ogent-test-store-guard-assert ()
  "Force every guarded persistence flag off and path under the store root.
See `ogent-test-store-guard-flags' and `ogent-test-store-guard-paths'."
  (dolist (flag ogent-test-store-guard-flags)
    (set-default flag nil))
  (let ((spec ogent-test-store-guard-paths))
    (while spec
      (set-default (pop spec)
                   (expand-file-name (pop spec) ogent-test-store-root)))))

(ogent-test-store-guard-assert)

(defun ogent-test--store-guard-reassert (&rest _)
  "Re-assert the store guard; installed as before-advice on `ert-run-test'."
  (ogent-test-store-guard-assert))

(advice-add 'ert-run-test :before #'ogent-test--store-guard-reassert)

;; Opt-in fixture.  FIXTURE FILE POLICY: fixtures never delete files,
;; not even ones they create.  KIND `analytics' uses in-memory sqlite
;; (zero filesystem footprint); file-backed kinds provision retained
;; directories under `ogent-test-store-root' with the path logged.
;; Cleanup on exit resets Lisp state only (connections closed, variables
;; and functions restored), never the filesystem.

(declare-function ogent-analytics--init-schema "ogent-analytics")
(declare-function ogent-analytics--get-db "ogent-analytics")

(defun ogent-test--provision-store-directory (kind)
  "Create and return a fresh KIND-named directory under the store root.
The directory is retained per the fixture file policy; its path is
logged and recorded in `ogent-test--store-provision-log'."
  (let ((dir (make-temp-name
              (expand-file-name (format "%s-" kind) ogent-test-store-root))))
    (make-directory dir t)
    (push dir ogent-test--store-provision-log)
    (message "ogent-test: provisioned %s store at %s (retained)" kind dir)
    (file-name-as-directory dir)))

(defun ogent-test--call-with-real-store (kind thunk)
  "Call THUNK with an ephemeral KIND store enabled.
Runtime worker for `ogent-test-with-real-store', which see."
  (let ((process-environment
         (cons (concat "OGENT_TEST_STORE_ROOT=" ogent-test-store-root)
               process-environment)))
    (pcase kind
      ('analytics
       (require 'ogent-analytics)
       (let ((db (sqlite-open nil)))
         (ogent-analytics--init-schema db)
         (unwind-protect
             (let ((ogent-analytics-enabled t)
                   (real-get-db (symbol-function 'ogent-analytics--get-db)))
               (unwind-protect
                   (progn
                     (fset 'ogent-analytics--get-db
                           (lambda () (and ogent-analytics-enabled db)))
                     (funcall thunk))
                 (fset 'ogent-analytics--get-db real-get-db)))
           (sqlite-close db))))
      ('ledger
       (require 'ogent-ledger)
       (let* ((dir (ogent-test--provision-store-directory kind))
              (ogent-ledger-enabled t)
              (ogent-ledger-file (expand-file-name "ledger.org" dir)))
         (funcall thunk)))
      ('companion
       (require 'ogent-companion)
       (let* ((dir (ogent-test--provision-store-directory kind))
              (ogent-companion-persist-links t)
              (ogent-companion-link-registry-file
               (expand-file-name "companion-links.el" dir)))
         (funcall thunk)))
      ('capture
       (require 'ogent-notes)
       (let* ((dir (ogent-test--provision-store-directory kind))
              (ogent-capture-notes-file
               (expand-file-name "capture-notes.org" dir))
              (ogent-capture-companion-file
               (expand-file-name "capture-companion.org" dir)))
         (funcall thunk)))
      (_ (error "ogent-test-with-real-store: unknown store kind %S" kind)))))

(defmacro ogent-test-with-real-store (kind &rest body)
  "Run BODY with an ephemeral KIND store provisioned and enabled.
KIND evaluates to one of the symbols `analytics', `ledger', `companion',
or `capture'.  KIND `analytics' backs `ogent-analytics--get-db' with an
in-memory sqlite connection; file-backed kinds provision a retained
directory under `ogent-test-store-root'.  OGENT_TEST_STORE_ROOT is
exported into `process-environment' around BODY.  Nesting is allowed;
on exit only Lisp state is reset, files are never deleted."
  (declare (indent 1) (debug (form body)))
  `(ogent-test--call-with-real-store ,kind (lambda () ,@body)))

;;; Tripwire: fail any test that touches a real store path (ogent-aq8.2)
;;
;; The store guard above redirects defaults, but a test can still
;; let-bind a store variable back to a real path, and two write channels
;; bypass `write-region' entirely: the native sqlite API mutates DB
;; files directly, and subprocesses can write anywhere.  The tripwire
;; advises the actual store chokepoints and converts an isolation
;; violation into a loud named failure whose message pinpoints the
;; leaking test, path, and chokepoint.  It is installed only under
;; noninteractive ert (batch runs); interactive helper loads for
;; development are left untouched.  The hash-audit bead (ogent-aq8.4)
;; remains the backstop for write channels these chokepoints miss.

(declare-function ogent-analytics--db-path "ogent-analytics")

(defvar ogent-test--current-test nil
  "Name of the ert test currently executing, for tripwire messages.")

(defvar ogent-test-tripwire-allowed-roots nil
  "Extra directory roots the tripwire treats as sanctioned.
Register one with `ogent-test-tripwire-allow-root'.  Every registration
site MUST carry a comment justifying why `temporary-file-directory'
\(which already sanctions every `make-temp-file' fixture root) or the
`ogent-test-with-real-store' fixture cannot serve; unjustified entries
fail the ogent-aq8.3 sweep audit.")

(defun ogent-test-tripwire-allow-root (root)
  "Register ROOT as a sanctioned tripwire directory and return it.
See `ogent-test-tripwire-allowed-roots' for the justification policy."
  (let ((expanded (file-name-as-directory (expand-file-name root))))
    (push expanded ogent-test-tripwire-allowed-roots)
    expanded))

(defconst ogent-test--tripwire-real-store-prefixes
  (list (file-name-as-directory (expand-file-name user-emacs-directory))
        (file-name-as-directory (expand-file-name org-directory))
        (file-name-as-directory (expand-file-name "~/.codex")))
  "Absolute prefixes of real user store locations, captured at load.
The subprocess chokepoint trips only on these prefixes (a blanket
subprocess ban would break legitimate fixture spawns); the in-Lisp
chokepoints use the stricter `ogent-test--tripwire-sanctioned-p'
inside-out check instead.")

(defconst ogent-test--tripwire-store-basenames
  (let ((names (list ".ogent-analytics.db" "ledger.org"))
        (spec ogent-test-store-guard-paths))
    ;; Module defaults above (the real on-disk names a subprocess like
    ;; the sqlite3 CLI would touch at a project root), plus every
    ;; file-backed guard target.  Directory targets (no dot in the
    ;; basename) are skipped: names like "sessions" are too generic to
    ;; ban in arbitrary subprocess arguments.
    (while spec
      (pop spec)
      (let ((base (file-name-nondirectory
                   (directory-file-name (pop spec)))))
        (when (string-match-p "\\." base)
          (push base names))))
    (delete-dups names))
  "Basenames of guarded store files, banned in subprocess arguments.
A path-like :command argument whose basename matches trips the wire
wherever it points, unless the expanded path is sanctioned; this
catches relative store paths (e.g. \".ogent-analytics.db\" spawned at
a project root) that the absolute prefix check misses.")

(defun ogent-test--tripwire-sanctioned-p (path)
  "Return non-nil when PATH is under a sanctioned test root.
Sanctioned roots are `temporary-file-directory' (which contains
`ogent-test-store-root' and every `make-temp-file' fixture) and each
registered `ogent-test-tripwire-allowed-roots' entry."
  (let ((expanded (expand-file-name path))
        (roots (cons (file-name-as-directory
                      (expand-file-name temporary-file-directory))
                     ogent-test-tripwire-allowed-roots))
        (hit nil))
    (dolist (root roots hit)
      (when (string-prefix-p root expanded)
        (setq hit t)))))

(defun ogent-test--tripwire-violation (fn path)
  "Signal a tripwire failure: FN attempted real-store access to PATH."
  (error "TEST %s attempted real-store access: %s via %s"
         (or ogent-test--current-test 'no-test) path fn))

(defun ogent-test--tripwire-note-test (orig test)
  "Record TEST's name around ORIG for tripwire violation messages."
  (let ((ogent-test--current-test (ert-test-name test)))
    (funcall orig test)))

(defun ogent-test--tripwire-check-sqlite-open (&optional file &rest _)
  "Fail when `sqlite-open' targets FILE outside the sanctioned roots.
A nil FILE (in-memory database) is always sanctioned."
  (when (and file (not (ogent-test--tripwire-sanctioned-p file)))
    (ogent-test--tripwire-violation 'sqlite-open file)))

(defun ogent-test--tripwire-check-analytics-db (&rest _)
  "Fail when `ogent-analytics--get-db' would open a real DB path.
Checked before the body runs, so the violation fires even when the
`sqlite-open' chokepoint is stubbed out."
  (when (and (bound-and-true-p ogent-analytics-enabled)
             (fboundp 'sqlite-available-p)
             (sqlite-available-p))
    (let ((path (ogent-analytics--db-path)))
      (unless (ogent-test--tripwire-sanctioned-p path)
        (ogent-test--tripwire-violation 'ogent-analytics--get-db path)))))

(defun ogent-test--tripwire-check-ledger-append (file _event)
  "Fail when the ledger writer targets FILE outside the sanctioned roots."
  (unless (ogent-test--tripwire-sanctioned-p file)
    (ogent-test--tripwire-violation 'ogent-ledger--append-event file)))

(defun ogent-test--tripwire-check-companion-registry (&rest _)
  "Fail when the companion registry writer targets a real path."
  (unless (ogent-test--tripwire-sanctioned-p
           ogent-companion-link-registry-file)
    (ogent-test--tripwire-violation 'ogent-companion--write-link-registry
                                    ogent-companion-link-registry-file)))

(defun ogent-test--tripwire-check-capture-target (file)
  "Fail when org-capture resolves FILE outside the sanctioned roots.
Installed as :filter-return advice on `org-capture-expand-file', the
single point every capture target file passes through."
  (when (and (stringp file) (not (ogent-test--tripwire-sanctioned-p file)))
    (ogent-test--tripwire-violation 'org-capture-expand-file file))
  file)

(defun ogent-test--tripwire-check-process-arg (fn arg)
  "Fail when subprocess argument ARG for FN references a store path.
Three tiers: an embedded absolute real-store prefix trips anywhere in
ARG; a path-like ARG (containing a slash, or naming a guarded store
basename) is expanded against `default-directory' and trips when the
result lands under a real-store prefix; and an unsanctioned expansion
whose basename is in `ogent-test--tripwire-store-basenames' trips
regardless of directory, catching relative store paths spawned at a
project root.  Everything else stays sanctioned, so unrelated
subprocess arguments are never banned."
  (when (stringp arg)
    (dolist (prefix ogent-test--tripwire-real-store-prefixes)
      (when (string-search prefix arg)
        (ogent-test--tripwire-violation fn arg)))
    (let ((base (file-name-nondirectory arg)))
      (when (or (string-search "/" arg)
                (member base ogent-test--tripwire-store-basenames))
        (let ((expanded (expand-file-name arg)))
          (unless (ogent-test--tripwire-sanctioned-p expanded)
            (dolist (prefix ogent-test--tripwire-real-store-prefixes)
              (when (string-prefix-p prefix expanded)
                (ogent-test--tripwire-violation fn arg)))
            (when (member (file-name-nondirectory expanded)
                          ogent-test--tripwire-store-basenames)
              (ogent-test--tripwire-violation fn arg))))))))

(defun ogent-test--tripwire-check-process (fn command)
  "Fail when FN would spawn COMMAND referencing a real store path.
COMMAND is the program-and-arguments list; `default-directory' is
checked as the spawn directory and each argument goes through
`ogent-test--tripwire-check-process-arg'.  The check is deliberately
narrow -- real-store prefixes and guarded store basenames only -- so
ordinary subprocess fixtures under temp roots stay unaffected."
  (dolist (prefix ogent-test--tripwire-real-store-prefixes)
    (when (and default-directory
               (string-prefix-p prefix (expand-file-name default-directory)))
      (ogent-test--tripwire-violation fn default-directory)))
  (dolist (arg command)
    (ogent-test--tripwire-check-process-arg fn arg)))

(defun ogent-test--tripwire-check-make-process (&rest args)
  "Check `make-process' ARGS against the real store prefixes."
  (ogent-test--tripwire-check-process 'make-process
                                      (plist-get args :command)))

(defun ogent-test--tripwire-check-start-process (_name _buffer program
                                                       &rest program-args)
  "Check `start-process' PROGRAM and PROGRAM-ARGS against store prefixes."
  (ogent-test--tripwire-check-process 'start-process
                                      (cons program program-args)))

(defun ogent-test--tripwire-install ()
  "Install the tripwire advice on every store chokepoint.
Advice on the ogent module functions attaches now and takes effect
when the defining module loads (nadvice re-applies pending advice on
definition)."
  (advice-add 'ert-run-test :around #'ogent-test--tripwire-note-test)
  (when (fboundp 'sqlite-open)
    (advice-add 'sqlite-open :before #'ogent-test--tripwire-check-sqlite-open))
  (advice-add 'ogent-analytics--get-db :before
              #'ogent-test--tripwire-check-analytics-db)
  (advice-add 'ogent-ledger--append-event :before
              #'ogent-test--tripwire-check-ledger-append)
  (advice-add 'ogent-companion--write-link-registry :before
              #'ogent-test--tripwire-check-companion-registry)
  (advice-add 'org-capture-expand-file :filter-return
              #'ogent-test--tripwire-check-capture-target)
  (advice-add 'make-process :before #'ogent-test--tripwire-check-make-process)
  (advice-add 'start-process :before
              #'ogent-test--tripwire-check-start-process))

(when noninteractive
  (ogent-test--tripwire-install))

(defvar transient-history-file)
(defvar transient-save-history)

(defconst ogent-test-transient-history-file
  (make-temp-file "ogent-transient-history")
  "Scratch Transient history file used by batch tests.")

(with-temp-file ogent-test-transient-history-file
  (insert "nil\n"))

(setq transient-history-file ogent-test-transient-history-file)
(setq transient-save-history nil)

;; Auto-detect magit-section from Doom Emacs straight builds.
;; Prefer the sandbox/local Compat package when it already provides compat-31.
;; Pick the highest-versioned build dir available (exact version may not match).
(unless (featurep 'magit-section)
  (let* ((straight-dir (expand-file-name
                        ".local/share/doom/straight/"
                        (getenv "HOME")))
         (build-dir
          (when (file-directory-p straight-dir)
            (car (last (sort
                        (seq-filter
                         (lambda (d)
                           (and (string-match-p "^build-[0-9]" d)
                                (not (string-match-p "\\.el$" d))
                                (file-directory-p
                                 (expand-file-name d straight-dir))))
                         (directory-files straight-dir))
                        #'string<)))))
         (doom-build (when build-dir
                       (expand-file-name build-dir straight-dir)))
         (deps (append (unless (locate-library "compat-31")
                         '("compat"))
                       '("dash" "seq" "magit-section"))))
    (when doom-build
      (let ((repos-dir (expand-file-name "repos" straight-dir)))
        (dolist (dep deps)
          (let ((dep-dir (expand-file-name dep doom-build)))
            (when (file-directory-p dep-dir)
              (add-to-list 'load-path dep-dir)))
          ;; Prefer repo source over stale bytecode for magit-section.
          ;; The build dir .elc may be compiled from an older source,
          ;; and load-prefer-newer cannot distinguish when timestamps match.
          (when (equal dep "magit-section")
            (let ((src-dir (expand-file-name "magit/lisp" repos-dir)))
              (when (file-directory-p src-dir)
                (add-to-list 'load-path src-dir)))))))))

(unless (featurep 'gptel)
  (provide 'gptel))

(dolist (feature '(gptel-openai gptel-anthropic))
  (unless (featurep feature)
    (provide feature)))

(unless (fboundp 'gptel-with-preset)
  (defmacro gptel-with-preset (_preset &rest body)
    "Fallback macro for tests when gptel isn't installed."
    `(progn ,@body)))

(unless (fboundp 'gptel-request)
  (defun gptel-request (_prompt &rest _args)
    (error "gptel-request stub not overridden in tests")))

;; Define gptel variables that ogent-ui references
(defvar gptel-tools nil
  "Test stub for gptel-tools.")
(defvar gptel-use-tools nil
  "Test stub for gptel-use-tools.")

;;; Mocking utilities
;;
;; These macros/functions make it easy to mock gptel and other external
;; dependencies using cl-letf. See elisp-handbook.org for best practices.

(defvar ogent-test--captured-requests nil
  "Captures requests made during tests.")

(defmacro ogent-test-with-mock-gptel (&rest body)
  "Execute BODY with gptel-request mocked to capture and simulate responses.
Access captured data via `ogent-test--captured-requests'.
Automatically calls the callback with success if provided."
  (declare (indent 0) (debug t))
  `(let ((ogent-test--captured-requests nil))
     (cl-letf (((symbol-function 'gptel-request)
                (lambda (prompt &rest args)
                  (push (list :prompt prompt :args args) ogent-test--captured-requests)
                  (when-let ((callback (plist-get args :callback)))
                    (funcall callback "Mock response" nil)
                    (funcall callback nil '(:done t)))
                  'mock-request)))
       ,@body)))

(defmacro ogent-test-with-streaming-mock (chunks &rest body)
  "Execute BODY with gptel-request mocked to stream CHUNKS.
CHUNKS is a list of strings to send via the callback."
  (declare (indent 1) (debug t))
  `(let ((ogent-test--captured-requests nil))
     (cl-letf (((symbol-function 'gptel-request)
                (lambda (prompt &rest args)
                  (push (list :prompt prompt :args args) ogent-test--captured-requests)
                  (when-let ((callback (plist-get args :callback)))
                    (dolist (chunk ,chunks)
                      (funcall callback chunk nil))
                    (funcall callback nil '(:done t)))
                  'mock-request)))
       ,@body)))

(defmacro ogent-test-with-error-mock (error-message &rest body)
  "Execute BODY with gptel-request mocked to simulate an error.
ERROR-MESSAGE is the error string returned via callback."
  (declare (indent 1) (debug t))
  `(let ((ogent-test--captured-requests nil))
     (cl-letf (((symbol-function 'gptel-request)
                (lambda (prompt &rest args)
                  (push (list :prompt prompt :args args) ogent-test--captured-requests)
                  (when-let ((callback (plist-get args :callback)))
                    (funcall callback nil (list :error ,error-message)))
                  'mock-request)))
       ,@body)))

(defmacro ogent-test-with-timeout-mock (&rest body)
  "Execute BODY with gptel-request mocked to simulate a timeout (no callback)."
  (declare (indent 0) (debug t))
  `(let ((ogent-test--captured-requests nil))
     (cl-letf (((symbol-function 'gptel-request)
                (lambda (prompt &rest args)
                  (push (list :prompt prompt :args args) ogent-test--captured-requests)
                  ;; Don't call callback - simulates hung request
                  'mock-request)))
       ,@body)))

(defun ogent-test-last-request ()
  "Return the most recent captured request, or nil."
  (car ogent-test--captured-requests))

(defun ogent-test-request-count ()
  "Return the number of captured requests."
  (length ogent-test--captured-requests))

;;; Simulated input for interactive function testing
;;
;; Uses `with-simulated-input` package when available.
;; See: https://github.com/DarwinAwardWinner/with-simulated-input

(defvar ogent-test--simulated-input-available nil
  "Non-nil when `with-simulated-input' is available.")

(condition-case nil
    (progn
      (require 'with-simulated-input)
      (setq ogent-test--simulated-input-available t))
  (error nil))

(defmacro ogent-test-with-input (keys &rest body)
  "Execute BODY with simulated keyboard input KEYS.
If `with-simulated-input' is not available, skip the test.
KEYS is a string like \"hello RET\" or a list of inputs."
  (declare (indent 1) (debug t))
  (if ogent-test--simulated-input-available
      `(with-simulated-input ,keys ,@body)
    `(ert-skip "with-simulated-input package not available")))

(defun ogent-test-with-org-file (file fn)
  "Open FILE contents in a temporary Org buffer and run FN."
  (let ((buffer (generate-new-buffer " *ogent-test*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert-file-contents file)
          (org-mode)
          (funcall fn))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ogent-test-with-fixture (relative-path fn)
  "Execute FN inside the Org fixture at RELATIVE-PATH."
  (ogent-test-with-org-file
   (expand-file-name relative-path ogent-test-root)
   fn))

(defun ogent-test--files ()
  "Return every ert test file under `test/'."
  (directory-files-recursively ogent-test-root "-tests\\.el$"))

(defun ogent-test-load (file)
  "Load FILE relative to the project root."
  (load file nil 'nomessage))

;;;###autoload
(defun ogent-run-tests ()
  "Load every ogent test file then run ert suites."
  (interactive)
  (mapc #'ogent-test-load (ogent-test--files))
  (ert-run-tests-batch-and-exit t))

(provide 'ogent-test-helper)

;;; ogent-test-helper.el ends here
