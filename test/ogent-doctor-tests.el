;;; ogent-doctor-tests.el --- Tests for ogent doctor -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-doctor)

;; Dynamic variables from ogent-mcp, which tests require at run time.
(defvar ogent-mcp-servers)
(defvar ogent-mcp--connections)
(declare-function make-ogent-mcp-connection "ogent-mcp")
(defvar transient-version)
(defvar ogent-model-registry)

;;; Framework fixtures

(defun ogent-doctor-tests--fixture-results ()
  "Return the fixture result plists pinned by the golden artifact."
  (list (list :id 'emacs-version
              :label "Emacs version"
              :category 'environment
              :status 'ok
              :detail "Emacs 30.2 (required >= 29.1)"
              :remediation "Upgrade Emacs to at least the version in `ogent-doctor-required-emacs-version`")
        (list :id 'backend
              :label "gptel backend"
              :category 'models
              :status 'warn
              :detail "Backend \"OpenAI\" has not resolved to an object"
              :remediation "Define the gptel backend the default model refers to")
        (list :id 'codex-auth
              :label "Codex OAuth cache"
              :category 'auth
              :status 'info
              :detail "No Codex auth file at ~/.codex/auth.json"
              :remediation "Run codex login to refresh the Codex auth cache")
        (list :id 'adapter-clis
              :label "Adapter CLIs"
              :category 'cli
              :status 'error
              :detail "Codex CLI: codex found\nPi CLI: unsupported - flags unverified"
              :remediation "Install the missing adapter CLIs")))

(defun ogent-doctor-tests--check-ok ()
  "Fixture check that passes."
  (cons 'ok "fixture passed"))

(defun ogent-doctor-tests--check-crash ()
  "Fixture check that signals."
  (error "Fixture check blew up"))

(defun ogent-doctor-tests--check-malformed ()
  "Fixture check returning a value outside the (STATUS . DETAIL) contract."
  '(splendid . "not a real status"))

;;; Version and summary helpers

(ert-deftest ogent-doctor-version-status-compares-minimum ()
  "Version status passes only when current version meets the minimum."
  (should (eq (ogent-doctor--version-status "29.1" "29.1") 'ok))
  (should (eq (ogent-doctor--version-status "30.2" "29.1") 'ok))
  (should (eq (ogent-doctor--version-status "29.0" "29.1") 'error)))

(ert-deftest ogent-doctor-summary-status-prioritizes-errors ()
  "Summary status reports the worst result severity."
  (should (eq (ogent-doctor-summary-status
               '((:status info) (:status ok)))
              'ok))
  (should (eq (ogent-doctor-summary-status
               '((:status info) (:status warn) (:status ok)))
              'warn))
  (should (eq (ogent-doctor-summary-status
               '((:status warn) (:status error) (:status ok)))
              'error)))

;;; Runner contract

(ert-deftest ogent-doctor-run-checks-contains-crashes ()
  "A crashing check reports as a failing result and never aborts the run."
  (let* ((checks '((:id first :label "First" :category environment
                        :fn ogent-doctor-tests--check-ok)
                   (:id boom :label "Boom" :category environment
                        :fn ogent-doctor-tests--check-crash
                        :remediation "defuse the fixture")
                   (:id last :label "Last" :category models
                        :fn ogent-doctor-tests--check-ok)))
         (results (ogent-doctor--run-checks checks)))
    (should (equal (mapcar (lambda (result) (plist-get result :id)) results)
                   '(first boom last)))
    (let ((boom (nth 1 results)))
      (should (eq (plist-get boom :status) 'error))
      (should (string-match-p "check crashed: Fixture check blew up"
                              (plist-get boom :detail)))
      (should (equal (plist-get boom :remediation) "defuse the fixture")))
    (should (eq (plist-get (nth 0 results) :status) 'ok))
    (should (eq (plist-get (nth 2 results) :status) 'ok))))

(ert-deftest ogent-doctor-run-checks-rejects-malformed-outcomes ()
  "A check returning a non-contract value reports as a failing result."
  (let* ((checks '((:id odd :label "Odd" :category environment
                        :fn ogent-doctor-tests--check-malformed)))
         (result (car (ogent-doctor--run-checks checks))))
    (should (eq (plist-get result :status) 'error))
    (should (string-match-p "invalid result" (plist-get result :detail)))))

(ert-deftest ogent-doctor-run-checks-carries-registry-metadata ()
  "Results carry the registry id, label, category, and remediation."
  (let* ((checks '((:id meta :label "Meta" :category stores
                        :fn ogent-doctor-tests--check-ok
                        :remediation "no fix needed")))
         (result (car (ogent-doctor--run-checks checks))))
    (should (eq (plist-get result :id) 'meta))
    (should (equal (plist-get result :label) "Meta"))
    (should (eq (plist-get result :category) 'stores))
    (should (eq (plist-get result :status) 'ok))
    (should (equal (plist-get result :detail) "fixture passed"))
    (should (equal (plist-get result :remediation) "no fix needed"))))

(ert-deftest ogent-doctor-run-includes-core-checks ()
  "Doctor run returns stable plist entries for core checks."
  (let* ((results (ogent-doctor-run))
         (ids (mapcar (lambda (result) (plist-get result :id)) results)))
    (dolist (id '(emacs-version org-version gptel transient model-registry default-model))
      (should (memq id ids)))
    (dolist (result results)
      (should (plist-get result :label))
      (should (plist-get result :category))
      (should (memq (plist-get result :status) '(ok warn error info))))))

(ert-deftest ogent-doctor-run-skips-opt-in-checks-by-default ()
  "Opt-in registry entries only run when the caller asks for them."
  (let ((ogent-doctor-checks
         '((:id normal :label "Normal" :category environment
                :fn ogent-doctor-tests--check-ok)
           (:id gated :label "Gated" :category mcp :opt-in t
                :fn ogent-doctor-tests--check-ok))))
    (should (equal (mapcar (lambda (result) (plist-get result :id))
                           (ogent-doctor-run))
                   '(normal)))
    (should (equal (mapcar (lambda (result) (plist-get result :id))
                           (ogent-doctor-run t))
                   '(normal gated)))))

;;; Report rendering

(ert-deftest ogent-doctor-format-matches-golden ()
  "Doctor report formatting is pinned by a golden Org artifact."
  (let* ((golden-file (expand-file-name "data/ogent-doctor-golden.org"
                                        ogent-test-root))
         (expected (with-temp-buffer
                     (insert-file-contents golden-file)
                     (buffer-string))))
    (should (equal (ogent-doctor-format (ogent-doctor-tests--fixture-results))
                   expected))))

(ert-deftest ogent-doctor-format-groups-by-category ()
  "Report groups checks under category headings in display order."
  (let* ((results (list (list :id 'b :label "B check" :category 'auth
                              :status 'ok :detail "b")
                        (list :id 'a :label "A check" :category 'environment
                              :status 'ok :detail "a")
                        (list :id 'c :label "C check" :category 'environment
                              :status 'ok :detail "c")
                        (list :id 'd :label "D check" :category 'mystery
                              :status 'ok :detail "d")))
         (report (ogent-doctor-format results))
         (env (string-match "^\\*\\* Environment$" report))
         (auth (string-match "^\\*\\* Auth$" report))
         (mystery (string-match "^\\*\\* Mystery$" report)))
    ;; Known categories render in `ogent-doctor-categories' order,
    ;; unknown categories sort last under a derived heading.
    (should (and env auth mystery))
    (should (< env auth mystery))
    ;; Registry order is preserved within a category.
    (should (< (string-match "A check" report)
               (string-match "C check" report)))
    ;; Each category heading appears exactly once.
    (should (= 1 (with-temp-buffer
                   (insert report)
                   (count-matches "^\\*\\* Environment$" (point-min) (point-max)))))))

(ert-deftest ogent-doctor-format-omits-remediation-for-passing-checks ()
  "Remediation hints render only for warn and error results."
  (let ((report (ogent-doctor-format
                 (list (list :id 'fine :label "Fine" :category 'environment
                             :status 'ok :detail "all good"
                             :remediation "never shown")
                       (list :id 'meh :label "Meh" :category 'environment
                             :status 'warn :detail "off"
                             :remediation "do the thing")))))
    (should-not (string-match-p "never shown" report))
    (should (string-match-p "fix: do the thing" report))))

;;; Commands

(ert-deftest ogent-doctor-command-renders-buffer ()
  "Interactive doctor command renders a report buffer and returns results."
  (let ((ogent-doctor-buffer-name "*ogent-doctor-test*"))
    (unwind-protect
        (let ((results (ogent-doctor)))
          (should results)
          (should (get-buffer ogent-doctor-buffer-name))
          (with-current-buffer ogent-doctor-buffer-name
            (should (derived-mode-p 'org-mode))
            (should (string-match-p "Ogent Doctor" (buffer-string)))))
      (when-let ((buffer (get-buffer ogent-doctor-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest ogent-doctor-batch-exit-contract ()
  "Batch runner prints the report and maps worst status to an exit code."
  (cl-letf (((symbol-function 'ogent-doctor-run)
             (lambda (&optional _include-opt-in)
               '((:id a :label "A" :category environment
                      :status ok :detail "fine")))))
    (with-output-to-string
      (should (= (ogent-doctor-batch) 0))))
  (cl-letf (((symbol-function 'ogent-doctor-run)
             (lambda (&optional _include-opt-in)
               '((:id a :label "A" :category environment
                      :status ok :detail "fine")
                 (:id b :label "B" :category auth
                      :status warn :detail "meh")))))
    (with-output-to-string
      (should (= (ogent-doctor-batch) 1))))
  (cl-letf (((symbol-function 'ogent-doctor-run)
             (lambda (&optional _include-opt-in)
               '((:id b :label "B" :category auth
                      :status warn :detail "meh")
                 (:id c :label "C" :category cli
                      :status error :detail "broken")))))
    (let ((output (with-output-to-string
                    (should (= (ogent-doctor-batch) 2)))))
      (should (string-match-p "\\* Ogent Doctor" output))
      (should (string-match-p "Status: ERROR" output)))))

;;; e73.2 environment checks

(ert-deftest ogent-doctor-registry-contains-e73-2-checks ()
  "Registry carries the nine environment checks with MCP gated opt-in."
  (let ((by-id (mapcar (lambda (check) (cons (plist-get check :id) check))
                       ogent-doctor-checks)))
    (dolist (id '(default-model-key anthropic-auth codex-auth curl
                                    org-ql vterm markdown-mode adapter-clis analytics-db
                                    stale-elc mcp-servers))
      (should (assq id by-id)))
    (should (plist-get (cdr (assq 'mcp-servers by-id)) :opt-in))
    (dolist (entry by-id)
      (unless (eq (car entry) 'mcp-servers)
        (should-not (plist-get (cdr entry) :opt-in))))))

(ert-deftest ogent-doctor-check-default-model-key ()
  "Default-model key check reports key presence without exposing it."
  (let ((backend (vector 'fake-backend)))
    (cl-letf (((symbol-function 'ogent-models-default)
               (lambda () '(:id "test-model" :backend "test")))
              ((symbol-function 'ogent-gptel-resolve-backend)
               (lambda (_model) backend))
              ((symbol-function 'gptel-backend-key)
               (lambda (_backend) "sk-fixture-secret")))
      (let ((result (ogent-doctor--check-default-model-key)))
        (should (eq (car result) 'ok))
        (should (string-match-p "test-model" (cdr result)))
        (should-not (string-match-p "sk-fixture-secret" (cdr result)))))
    ;; Key resolving through a function works the same way.
    (cl-letf (((symbol-function 'ogent-models-default)
               (lambda () '(:id "test-model" :backend "test")))
              ((symbol-function 'ogent-gptel-resolve-backend)
               (lambda (_model) backend))
              ((symbol-function 'gptel-backend-key)
               (lambda (_backend) (lambda () "bearer-token"))))
      (should (eq (car (ogent-doctor--check-default-model-key)) 'ok)))
    ;; Missing key warns.
    (cl-letf (((symbol-function 'ogent-models-default)
               (lambda () '(:id "test-model" :backend "test")))
              ((symbol-function 'ogent-gptel-resolve-backend)
               (lambda (_model) backend))
              ((symbol-function 'gptel-backend-key)
               (lambda (_backend) nil)))
      (let ((result (ogent-doctor--check-default-model-key)))
        (should (eq (car result) 'warn))
        (should (string-match-p "No API key/bearer" (cdr result)))))
    ;; Unresolved backend defers the key check.
    (cl-letf (((symbol-function 'ogent-models-default)
               (lambda () '(:id "test-model" :backend "test")))
              ((symbol-function 'ogent-gptel-resolve-backend)
               (lambda (_model) "test")))
      (should (eq (car (ogent-doctor--check-default-model-key)) 'warn)))
    ;; No default model is a hard failure.
    (cl-letf (((symbol-function 'ogent-models-default)
               (lambda () (error "empty registry"))))
      (should (eq (car (ogent-doctor--check-default-model-key)) 'error)))))

(defun ogent-doctor-tests--token-file (plist)
  "Write PLIST to a retained temp token fixture and return its path."
  (let ((file (make-temp-file "ogent-doctor-tokens-" nil ".el")))
    (with-temp-file file
      (insert ";; Generated by ogent-doctor-tests.el\n\n")
      (prin1 plist (current-buffer)))
    file))

(defun ogent-doctor-tests--anthropic-check-with (file)
  "Run the anthropic auth check against token FILE and return its result."
  (cl-letf (((symbol-function 'ogent-anthropic-oauth--find-existing-token-file)
             (lambda () file)))
    (ogent-doctor--check-anthropic-auth)))

(ert-deftest ogent-doctor-check-anthropic-token-expiry ()
  "Anthropic token check warns below seven days and fails when expired."
  (require 'ogent-anthropic-oauth)
  (let ((now (floor (float-time))))
    ;; Fresh token passes.
    (let ((result (ogent-doctor-tests--anthropic-check-with
                   (ogent-doctor-tests--token-file
                    (list :type 'auth/oauth :access-token "x"
                          :expires-at (+ now (* 30 86400)))))))
      (should (eq (car result) 'ok))
      (should (string-match-p "valid for" (cdr result))))
    ;; Inside the warn window.
    (let ((result (ogent-doctor-tests--anthropic-check-with
                   (ogent-doctor-tests--token-file
                    (list :type 'auth/oauth :access-token "x"
                          :expires-at (+ now (* 3 86400)))))))
      (should (eq (car result) 'warn))
      (should (string-match-p "expires in" (cdr result))))
    ;; Expired fails.
    (let ((result (ogent-doctor-tests--anthropic-check-with
                   (ogent-doctor-tests--token-file
                    (list :type 'auth/oauth :access-token "x"
                          :expires-at (- now 86400))))))
      (should (eq (car result) 'error))
      (should (string-match-p "expired" (cdr result))))
    ;; No expiry field means API key mode.
    (should (eq (car (ogent-doctor-tests--anthropic-check-with
                      (ogent-doctor-tests--token-file
                       (list :type 'api-key :access-token "x"))))
                'ok))
    ;; Missing file is informational, unreadable file warns.
    (should (eq (car (ogent-doctor-tests--anthropic-check-with nil)) 'info))
    (let ((garbage (make-temp-file "ogent-doctor-garbage-" nil ".el")))
      (with-temp-file garbage (insert "%%% not lisp"))
      (should (eq (car (ogent-doctor-tests--anthropic-check-with garbage))
                  'warn)))))

(ert-deftest ogent-doctor-check-codex-auth-modes ()
  "Codex auth check distinguishes usable, keyless, and absent caches."
  (require 'ogent-codex-oauth)
  (cl-letf (((symbol-function 'ogent-codex-oauth--auth-file)
             (lambda () "/tmp/ogent-doctor-fake/auth.json"))
            ((symbol-function 'ogent-codex-oauth-get-api-key)
             (lambda () "sk-fixture"))
            ((symbol-function 'ogent-codex-oauth-mode)
             (lambda () "chatgpt")))
    (let ((result (ogent-doctor--check-codex-auth)))
      (should (eq (car result) 'ok))
      (should (string-match-p "chatgpt" (cdr result)))))
  (cl-letf (((symbol-function 'ogent-codex-oauth--auth-file)
             (lambda () "/tmp/ogent-doctor-fake/auth.json"))
            ((symbol-function 'ogent-codex-oauth-get-api-key)
             (lambda () nil))
            ((symbol-function 'ogent-codex-oauth-mode)
             (lambda () nil))
            ((symbol-function 'file-readable-p) (lambda (_file) t)))
    (let ((result (ogent-doctor--check-codex-auth)))
      (should (eq (car result) 'warn))
      (should (string-match-p "no OPENAI_API_KEY" (cdr result)))))
  (cl-letf (((symbol-function 'ogent-codex-oauth--auth-file)
             (lambda () "/tmp/ogent-doctor-fake/auth.json"))
            ((symbol-function 'ogent-codex-oauth-get-api-key)
             (lambda () nil))
            ((symbol-function 'ogent-codex-oauth-mode)
             (lambda () nil)))
    (should (eq (car (ogent-doctor--check-codex-auth)) 'info))))

(ert-deftest ogent-doctor-check-curl-fallback-warning ()
  "Missing curl warns about the non-streaming MCP HTTP fallback."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (program &optional _remote)
               (when (equal program "curl") "/usr/bin/curl"))))
    (let ((result (ogent-doctor--check-curl)))
      (should (eq (car result) 'ok))
      (should (string-match-p "/usr/bin/curl" (cdr result)))))
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_program &optional _remote) nil)))
    (let ((result (ogent-doctor--check-curl)))
      (should (eq (car result) 'warn))
      (should (string-match-p "falls back to non-streaming" (cdr result))))))

(ert-deftest ogent-doctor-optional-package-names-what-it-unlocks ()
  "Optional package probes stay info-level and name the unlocked feature."
  (let ((present (ogent-doctor--optional-package 'seq "sequence helpers")))
    (should (eq (car present) 'ok)))
  (let ((absent (ogent-doctor--optional-package
                 'ogent-doctor-tests-no-such-package "imaginary powers")))
    (should (eq (car absent) 'info))
    (should (string-match-p "imaginary powers" (cdr absent))))
  ;; Each registered optional check names its unlocked functionality.
  (dolist (fn '(ogent-doctor--check-org-ql
                ogent-doctor--check-vterm
                ogent-doctor--check-markdown-mode))
    (let ((result (funcall fn)))
      (should (memq (car result) '(ok info)))
      (when (eq (car result) 'info)
        (should (string-match-p "unlocks" (cdr result)))))))

(ert-deftest ogent-doctor-check-adapter-clis-surfaces-unsupported-reason ()
  "Adapter CLI check reports PATH status and honest unsupported reasons."
  (require 'ogent-armory-adapter)
  (cl-letf (((symbol-function 'ogent-armory-adapter-list)
             (lambda ()
               '((:id "codex-cli" :name "Codex CLI"
                      :default-executable "codex-fixture")
                 (:id "pi-cli" :name "Pi CLI"
                      :default-executable "pi"
                      :unsupported-reason "pi CLI invocation flags are unverified")
                 (:id "gptel-native" :name "gptel (in-process)")
                 (:id "ghost-cli" :name "Ghost CLI"
                      :default-executable "ghost-fixture-missing"))))
            ((symbol-function 'ogent-armory-adapter-executable)
             (lambda (adapter) (plist-get adapter :default-executable)))
            ((symbol-function 'executable-find)
             (lambda (program &optional _remote)
               (when (equal program "codex-fixture") "/usr/bin/codex-fixture"))))
    (let* ((result (ogent-doctor--check-adapter-clis))
           (detail (cdr result)))
      (should (eq (car result) 'info))
      (should (string-match-p "Codex CLI: codex-fixture found" detail))
      (should (string-match-p
               "Pi CLI: unsupported - pi CLI invocation flags are unverified"
               detail))
      (should (string-match-p "gptel (in-process): in-process" detail))
      (should (string-match-p "ghost-fixture-missing not in PATH" detail))))
  ;; All runnable adapters present reports ok.
  (cl-letf (((symbol-function 'ogent-armory-adapter-list)
             (lambda () '((:id "gptel-native" :name "gptel (in-process)")))))
    (should (eq (car (ogent-doctor--check-adapter-clis)) 'ok))))

(ert-deftest ogent-doctor-check-analytics-db-integrity ()
  "Analytics DB check probes integrity only when the DB file exists."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (require 'ogent-analytics)
  ;; In-memory database reports a passing integrity check.
  (let ((db (sqlite-open nil)))
    (should (equal (ogent-doctor--sqlite-integrity db)
                   '(ok . "integrity_check: ok")))
    (sqlite-close db))
  ;; A failing pragma row propagates as an error result.
  (cl-letf (((symbol-function 'sqlite-select)
             (lambda (_db _query &rest _)
               '(("*** in database main *** rowid missing")))))
    (let ((result (ogent-doctor--sqlite-integrity 'fake-db)))
      (should (eq (car result) 'error))
      (should (string-match-p "rowid missing" (cdr result)))))
  ;; Missing per-project DB is informational and never created.
  (cl-letf (((symbol-function 'ogent-analytics--db-path)
             (lambda () "/tmp/ogent-doctor-no-such-dir/analytics.db")))
    (let ((result (ogent-doctor--check-analytics-db)))
      (should (eq (car result) 'info))
      (should-not (file-exists-p "/tmp/ogent-doctor-no-such-dir/analytics.db"))))
  ;; An existing healthy DB file passes end to end.
  (let ((path (make-temp-file "ogent-doctor-analytics-" nil ".db")))
    (let ((db (sqlite-open path)))
      (sqlite-execute db "CREATE TABLE fixture (x INTEGER)")
      (sqlite-close db))
    (cl-letf (((symbol-function 'ogent-analytics--db-path)
               (lambda () path)))
      (let ((result (ogent-doctor--check-analytics-db)))
        (should (eq (car result) 'ok))
        (should (string-match-p "integrity_check: ok" (cdr result)))))))

(defconst ogent-doctor-tests--elc-header-newer
  ";ELC\x17\n;;; Compiled\n;;; in Emacs version 99.1\n;;; with all optimizations.\n"
  "Synthesized .elc header claiming a future Emacs.")

(ert-deftest ogent-doctor-check-stale-elc-header-parsing ()
  "The .elc header parser extracts the compiling Emacs major version."
  (should (= (ogent-doctor--elc-header-major
              ogent-doctor-tests--elc-header-newer)
             99))
  (should (= (ogent-doctor--elc-header-major
              ";ELC\n;;; Compiled\n;;; in Emacs version 30.2\n")
             30))
  (should-not (ogent-doctor--elc-header-major "not a bytecode header")))

(ert-deftest ogent-doctor-check-stale-elc-flags-newer-compiler ()
  "Stale-elc scan flags only ogent bytecode from a newer Emacs."
  (let ((dir (make-temp-file "ogent-doctor-elc-" t)))
    ;; Mark the directory as holding ogent code.
    (with-temp-file (expand-file-name "ogent-fixture.el" dir)
      (insert ";;; fixture\n"))
    (with-temp-file (expand-file-name "ogent-fixture.elc" dir)
      (insert ogent-doctor-tests--elc-header-newer))
    (with-temp-file (expand-file-name "ogent-current.elc" dir)
      (insert (format ";ELC\n;;; Compiled\n;;; in Emacs version %d.1\n"
                      emacs-major-version)))
    (let ((stale (ogent-doctor--stale-elc-files (list dir))))
      (should (equal stale
                     (list (cons (expand-file-name "ogent-fixture.elc" dir)
                                 99)))))
    ;; A directory without ogent sources is not scanned at all.
    (let ((other (make-temp-file "ogent-doctor-nonogent-" t)))
      (with-temp-file (expand-file-name "unrelated.elc" other)
        (insert ogent-doctor-tests--elc-header-newer))
      (should-not (ogent-doctor--stale-elc-files (list other))))
    ;; The registered check renders the remediation-worthy warning.
    (cl-letf (((symbol-function 'ogent-doctor--stale-elc-files)
               (lambda (&optional _dirs)
                 (list (cons "/fake/ogent-old.elc" 99)))))
      (let ((result (ogent-doctor--check-stale-elc)))
        (should (eq (car result) 'warn))
        (should (string-match-p "compiled by Emacs 99" (cdr result)))))))

(ert-deftest ogent-doctor-check-mcp-servers-handshake ()
  "MCP check is opt-in, stubs handshakes, and never needs a network."
  (require 'ogent-mcp)
  ;; Not configured is informational.
  (let ((ogent-mcp-servers nil))
    (should (eq (car (ogent-doctor--check-mcp-servers)) 'info)))
  ;; A successful handshake reports ok and disconnects the probe.
  (let ((ogent-mcp-servers '(("fixture" . (:command "fixture-server"))))
        (ogent-mcp--connections (make-hash-table :test 'equal))
        (ogent-doctor-mcp-timeout 0.2)
        (disconnected nil))
    (cl-letf (((symbol-function 'ogent-mcp-connect)
               (lambda (name)
                 (puthash name
                          (make-ogent-mcp-connection :name name :status 'ready)
                          ogent-mcp--connections)))
              ((symbol-function 'ogent-mcp-disconnect)
               (lambda (name) (push name disconnected))))
      (let ((result (ogent-doctor--check-mcp-servers)))
        (should (eq (car result) 'ok))
        (should (string-match-p "initialize handshake succeeded" (cdr result)))
        (should (equal disconnected '("fixture"))))))
  ;; A server that never becomes ready fails within the timeout.
  (let ((ogent-mcp-servers '(("dead" . (:command "dead-server"))))
        (ogent-mcp--connections (make-hash-table :test 'equal))
        (ogent-doctor-mcp-timeout 0.1))
    (cl-letf (((symbol-function 'ogent-mcp-connect) (lambda (_name) nil))
              ((symbol-function 'ogent-mcp-disconnect) (lambda (_name) nil)))
      (let ((result (ogent-doctor--check-mcp-servers)))
        (should (eq (car result) 'error))
        (should (string-match-p "no initialize handshake within" (cdr result))))))
  ;; An already-connected server is reported without being disconnected.
  (let ((ogent-mcp-servers '(("live" . (:command "live-server"))))
        (ogent-mcp--connections (make-hash-table :test 'equal))
        (disconnected nil))
    (puthash "live" (make-ogent-mcp-connection :name "live" :status 'ready)
             ogent-mcp--connections)
    (cl-letf (((symbol-function 'ogent-mcp-connect)
               (lambda (_name) (error "must not reconnect")))
              ((symbol-function 'ogent-mcp-disconnect)
               (lambda (name) (push name disconnected))))
      (let ((result (ogent-doctor--check-mcp-servers)))
        (should (eq (car result) 'ok))
        (should (string-match-p "already connected" (cdr result)))
        (should-not disconnected)))))

;;; e73.3 full-run golden

(defun ogent-doctor-tests--scrub (report substitutions)
  "Return REPORT with machine-specific paths replaced.
SUBSTITUTIONS is an alist of (PATH . PLACEHOLDER) string pairs; every
literal occurrence of PATH in REPORT becomes PLACEHOLDER."
  (dolist (substitution substitutions report)
    (setq report (string-replace (car substitution) (cdr substitution)
                                 report))))

(defun ogent-doctor-tests--unified-diff (expected actual)
  "Return a unified diff between the EXPECTED and ACTUAL strings.
Both are compared line-wise via a longest-common-subsequence walk and
rendered as a single whole-file hunk, entirely in Lisp so batch test
runs never shell out."
  (let* ((a (vconcat (split-string expected "\n")))
         (b (vconcat (split-string actual "\n")))
         (n (length a))
         (m (length b))
         (stride (1+ m))
         (lcs (make-vector (* (1+ n) stride) 0)))
    (dotimes (i n)
      (dotimes (j m)
        (aset lcs (+ (* (1+ i) stride) (1+ j))
              (if (equal (aref a i) (aref b j))
                  (1+ (aref lcs (+ (* i stride) j)))
                (max (aref lcs (+ (* i stride) (1+ j)))
                     (aref lcs (+ (* (1+ i) stride) j)))))))
    (let ((i n) (j m) (lines nil))
      (while (or (> i 0) (> j 0))
        (cond
         ((and (> i 0) (> j 0) (equal (aref a (1- i)) (aref b (1- j))))
          (push (concat " " (aref a (1- i))) lines)
          (setq i (1- i) j (1- j)))
         ((and (> j 0)
               (or (zerop i)
                   (>= (aref lcs (+ (* i stride) (1- j)))
                       (aref lcs (+ (* (1- i) stride) j)))))
          (push (concat "+" (aref b (1- j))) lines)
          (setq j (1- j)))
         (t
          (push (concat "-" (aref a (1- i))) lines)
          (setq i (1- i)))))
      (concat (format "--- expected\n+++ actual\n@@ -1,%d +1,%d @@\n" n m)
              (string-join lines "\n")))))

(defun ogent-doctor-tests--full-run-elc-dir ()
  "Provision a retained temp dir holding current and stale ogent bytecode.
The directory carries an ogent source marker so the stale-elc scan
treats it as ogent's own, one .elc from the pinned Emacs 30 (fresh),
and one from Emacs 99 (stale)."
  (let ((dir (make-temp-file "ogent-doctor-full-run-elc-" t)))
    (with-temp-file (expand-file-name "ogent-fixture.el" dir)
      (insert ";;; fixture\n"))
    (with-temp-file (expand-file-name "ogent-current.elc" dir)
      (insert ";ELC\n;;; Compiled\n;;; in Emacs version 30.1\n"))
    (with-temp-file (expand-file-name "ogent-stale.elc" dir)
      (insert ogent-doctor-tests--elc-header-newer))
    dir))

(defun ogent-doctor-tests--full-run ()
  "Run every registered doctor check in a fully-stubbed environment.
Every environment boundary the checks probe - version variables,
PATH lookups, OAuth caches, the model registry, adapter registry,
store paths, `load-path', and the MCP handshake - is pinned to fixture
values; the registered check functions themselves execute for real.
Return (RESULTS . REPORT) where REPORT is the rendered Org report with
machine-specific temp paths scrubbed to stable placeholders."
  (require 'transient)
  (require 'ogent-codex-oauth)
  (require 'ogent-anthropic-oauth)
  (require 'ogent-armory-adapter)
  (require 'ogent-analytics)
  (require 'ogent-mcp)
  (let* ((token-file (ogent-doctor-tests--token-file
                      (list :type 'auth/oauth :access-token "x"
                            :expires-at (+ (floor (float-time))
                                           (* 30 86400)))))
         (elc-dir (ogent-doctor-tests--full-run-elc-dir))
         (real-require (symbol-function 'require))
         ;; Pin the environment the checks read dynamically.
         (emacs-version "30.2")
         (emacs-major-version 30)
         (transient-version "0.13.5")
         (gptel-use-tools t)
         (ogent-doctor-required-emacs-version "29.1")
         (ogent-doctor-required-org-version "9.8.7")
         (ogent-doctor-required-transient-version "0.13.5")
         (ogent-model-registry '((:id "claude-fixture" :backend "Claude")
                                 (:id "gpt-fixture" :backend "OpenAI")))
         (ogent-default-model "claude-fixture")
         (ogent-mcp-servers '(("fixture" . (:command "fixture-server"))))
         (ogent-mcp--connections (make-hash-table :test 'equal))
         (ogent-doctor-mcp-timeout 0.2)
         (load-path (list elc-dir)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 ;; Optional packages read as absent regardless of the
                 ;; machine; everything else resolves for real (all
                 ;; ogent modules are preloaded above, so the narrowed
                 ;; `load-path' is never searched).
                 (unless (memq feature '(org-ql vterm markdown-mode))
                   (funcall real-require feature filename noerror))))
              ((symbol-function 'org-version)
               (lambda (&rest _) "9.8.10"))
              ((symbol-function 'executable-find)
               (lambda (program &optional _remote)
                 (cdr (assoc program
                             '(("br" . "/stub/bin/br")
                               ("curl" . "/stub/bin/curl")
                               ("codex-fixture" . "/stub/bin/codex-fixture"))))))
              ((symbol-function 'ogent-gptel-resolve-backend)
               (lambda (_model) (record 'gptel-anthropic "Claude")))
              ((symbol-function 'gptel-backend-key)
               (lambda (_backend) "sk-fixture-secret"))
              ((symbol-function 'ogent-codex-oauth--auth-file)
               (lambda () "/stub/.codex/auth.json"))
              ((symbol-function 'ogent-codex-oauth-mode)
               (lambda () "chatgpt"))
              ((symbol-function 'ogent-codex-oauth-get-api-key)
               (lambda () "sk-codex-stub"))
              ((symbol-function 'ogent-anthropic-oauth--find-existing-token-file)
               (lambda () token-file))
              ((symbol-function 'ogent-armory-adapter-list)
               (lambda ()
                 '((:id "codex-cli" :name "Codex CLI"
                        :default-executable "codex-fixture")
                   (:id "pi-cli" :name "Pi CLI"
                        :default-executable "pi"
                        :unsupported-reason "pi CLI invocation flags are unverified")
                   (:id "gptel-native" :name "gptel (in-process)"))))
              ((symbol-function 'ogent-armory-adapter-executable)
               (lambda (adapter) (plist-get adapter :default-executable)))
              ((symbol-function 'sqlite-available-p) (lambda () t))
              ((symbol-function 'ogent-analytics--db-path)
               (lambda () "/stub/project/.ogent/analytics.db"))
              ((symbol-function 'ogent-mcp-connect)
               (lambda (name)
                 (puthash name
                          (make-ogent-mcp-connection :name name :status 'ready)
                          ogent-mcp--connections)))
              ((symbol-function 'ogent-mcp-disconnect) (lambda (_name) nil)))
      (let ((results (ogent-doctor-run t)))
        (cons results
              (ogent-doctor-tests--scrub
               (ogent-doctor-format results)
               (list (cons token-file "<claude-token-file>")
                     (cons elc-dir "<ogent-elc-dir>"))))))))

(ert-deftest ogent-doctor-full-run-matches-golden ()
  "Full doctor run over every registered check is pinned by a golden report.
Executes each registered check function against a fully-stubbed
environment and compares the whole rendered report - grouping, glyphs,
alignment, detail text, and registry remediation hints - against the
golden artifact, printing a unified diff on drift."
  (pcase-let* ((`(,results . ,report) (ogent-doctor-tests--full-run))
               (golden-file (expand-file-name
                             "data/ogent-doctor-full-run-golden.org"
                             ogent-test-root))
               (expected (with-temp-buffer
                           (insert-file-contents golden-file)
                           (buffer-string))))
    ;; Every registered check ran, in registry order; adding a check
    ;; without regenerating the golden fails here by name first.
    (should (equal (mapcar (lambda (result) (plist-get result :id)) results)
                   (mapcar (lambda (check) (plist-get check :id))
                           ogent-doctor-checks)))
    ;; No stub crashed: crashes would surface as error results and are
    ;; indistinguishable from real regressions in the golden alone.
    (dolist (result results)
      (should-not (string-match-p "\\`check crashed"
                                  (plist-get result :detail))))
    (unless (equal report expected)
      (ert-fail (concat "Doctor full-run report drifted from the golden "
                        "artifact (test/data/ogent-doctor-full-run-golden.org):\n"
                        (ogent-doctor-tests--unified-diff expected report))))))

;;; ogent-doctor-tests.el ends here
