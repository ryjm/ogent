;;; ogent-test-helper-tests.el --- Meta-tests for the store guard -*- lexical-binding: t; -*-

;;; Commentary:
;; Verifies the store guard installed by test/ogent-test-helper.el:
;; persistence flags are forced off, store paths are redirected under
;; `ogent-test-store-root', a late module load cannot resurrect
;; persistence, and the `ogent-test-with-real-store' fixture
;; round-trips (enabled inside, disabled after).

;;; Code:

(require 'ert)
(require 'ogent-test-helper)

;; Modules are required inside test bodies (the late-load test depends
;; on that); declare their symbols for the byte compiler.
(defvar ogent-analytics-enabled)
(defvar ogent-analytics--pending-completion)
(defvar ogent-analytics--request-start-time)
(defvar ogent-analytics--first-token-time)
(defvar ogent-ledger-enabled)
(declare-function ogent-analytics--get-db "ogent-analytics")
(declare-function ogent-analytics-record-completion "ogent-analytics")
(declare-function ogent-ledger--file "ogent-ledger")
(declare-function ogent-ledger-record "ogent-ledger")

(defconst ogent-test-helper-tests--root-existed-at-load
  (file-exists-p ogent-test-store-root)
  "Whether the store root already existed when this suite loaded.")

(ert-deftest ogent-test-helper-store-root-not-auto-created ()
  "The helper never creates the store root; only fixtures provision it."
  (should-not ogent-test-helper-tests--root-existed-at-load)
  (should (or ogent-test--store-provision-log
              (not (file-exists-p ogent-test-store-root)))))

(ert-deftest ogent-test-helper-store-guard-defaults ()
  "Persistence flags are off and store paths live under the store root."
  (dolist (flag ogent-test-store-guard-flags)
    (should-not (default-value flag)))
  (let ((spec ogent-test-store-guard-paths))
    (while spec
      (let ((symbol (pop spec)))
        (pop spec)
        (should (stringp (default-value symbol)))
        (should (string-prefix-p ogent-test-store-root
                                 (default-value symbol)))))))

(ert-deftest ogent-test-helper-late-module-load-keeps-guard ()
  "A late module load does not resurrect persistence defaults."
  (require 'ogent-analytics)
  (should-not (default-value 'ogent-analytics-enabled))
  (should (string-prefix-p ogent-test-store-root
                           (default-value 'ogent-analytics-db-name)))
  (require 'ogent-ledger)
  (should-not (default-value 'ogent-ledger-enabled))
  (should (string-prefix-p ogent-test-store-root
                           (default-value 'ogent-ledger-file)))
  (require 'ogent-companion)
  (should-not (default-value 'ogent-companion-persist-links))
  (should (string-prefix-p ogent-test-store-root
                           (default-value 'ogent-companion-link-registry-file))))

(ert-deftest ogent-test-helper-guard-reassert-restores-defaults ()
  "The guard re-assertion restores forcibly corrupted defaults."
  (should (advice-member-p #'ogent-test--store-guard-reassert 'ert-run-test))
  (unwind-protect
      (progn
        (set-default 'ogent-ledger-enabled t)
        (set-default 'ogent-ledger-file "/nonexistent/real-store/ledger.org")
        (ogent-test-store-guard-assert)
        (should-not (default-value 'ogent-ledger-enabled))
        (should (string-prefix-p ogent-test-store-root
                                 (default-value 'ogent-ledger-file))))
    (ogent-test-store-guard-assert)))

(ert-deftest ogent-test-helper-real-store-analytics-round-trip ()
  "The analytics fixture enables an in-memory store inside its body only."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (require 'ogent-analytics)
  (should-not (default-value 'ogent-analytics-enabled))
  (let ((ogent-analytics--pending-completion nil)
        (ogent-analytics--request-start-time nil)
        (ogent-analytics--first-token-time nil))
    (ogent-test-with-real-store 'analytics
      (should ogent-analytics-enabled)
      (should (equal (getenv "OGENT_TEST_STORE_ROOT") ogent-test-store-root))
      (let ((db (ogent-analytics--get-db)))
        (should db)
        (should (ogent-analytics-record-completion "meta-model" "prompt" "response"))
        (should (equal (caar (sqlite-select
                              db "SELECT COUNT(*) FROM completions"))
                       1))))
    (should-not ogent-analytics-enabled)
    (should-not (getenv "OGENT_TEST_STORE_ROOT"))
    (should-not (ogent-analytics--get-db))))

(ert-deftest ogent-test-helper-real-store-nesting ()
  "Nested fixtures provision independent stores and unwind in order."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (require 'ogent-analytics)
  (ogent-test-with-real-store 'analytics
    (let ((outer-db (ogent-analytics--get-db)))
      (should outer-db)
      (ogent-test-with-real-store 'analytics
        (let ((inner-db (ogent-analytics--get-db)))
          (should inner-db)
          (should-not (eq inner-db outer-db))))
      (should (eq (ogent-analytics--get-db) outer-db))))
  (should-not (default-value 'ogent-analytics-enabled)))

(ert-deftest ogent-test-helper-real-store-ledger-round-trip ()
  "The ledger fixture provisions a retained file store under the root."
  (require 'ogent-ledger)
  (let (ledger-file)
    (ogent-test-with-real-store 'ledger
      (should ogent-ledger-enabled)
      (setq ledger-file (ogent-ledger--file))
      (should (string-prefix-p ogent-test-store-root ledger-file))
      (should (ogent-ledger-record 'meta-test '(:x 1)))
      (should (file-exists-p ledger-file)))
    (should-not (default-value 'ogent-ledger-enabled))
    (should-not ogent-ledger-enabled)
    ;; Retained per the fixture file policy: never deleted.
    (should (file-exists-p ledger-file))
    (should (member (directory-file-name (file-name-directory ledger-file))
                    ogent-test--store-provision-log))))

(ert-deftest ogent-test-helper-real-store-unknown-kind-errors ()
  "An unknown store kind signals an error."
  (should-error (ogent-test-with-real-store 'bogus (ignore))))

;;; Tripwire probes (ogent-aq8.2)
;;
;; Three kinds of coverage per chokepoint:
;; - VIOLATING PROBES (`:expected-result :failed'): perform the raw
;;   violation with the underlying write primitives stubbed (or against
;;   an uncreatable path), so a disarmed tripwire yields an UNEXPECTED
;;   PASS instead of a silent real-store write.
;; - MESSAGE TESTS: assert the violation error text pinpoints the test,
;;   path, and chokepoint, so CI logs identify a leak instantly.
;; - SILENCE TESTS: prove compliant fixtures and sanctioned temp paths
;;   never trip.
;; No probe ever creates a file outside `temporary-file-directory'.

(require 'cl-lib)

(declare-function ogent-companion--write-link-registry "ogent-companion")
(declare-function org-capture-expand-file "org-capture")
(defvar org-directory)
(defvar ogent-analytics-db-name)
(defvar ogent-ledger-file)
(defvar ogent-companion-link-registry-file)
(defvar ogent-capture-notes-file)

(defun ogent-test-helper-tests--real-path (name)
  "Return NAME under an absent real-store subdirectory.
The `user-emacs-directory' prefix classifies the path as a real store;
the never-created intermediate directories guarantee that a disarmed
chokepoint cannot materialize a file there."
  (expand-file-name (concat "ogent-tripwire-probe/absent/" name)
                    user-emacs-directory))

;;;; Violating probes: each MUST fail via the tripwire.

(ert-deftest ogent-test-tripwire-probe-sqlite-open ()
  "Opening a file-backed DB on a real store path trips the wire."
  :expected-result :failed
  (skip-unless (and noninteractive (fboundp 'sqlite-open)))
  (sqlite-open (ogent-test-helper-tests--real-path "probe.sqlite")))

(ert-deftest ogent-test-tripwire-probe-analytics-get-db ()
  "A real analytics DB path trips at `ogent-analytics--get-db'."
  :expected-result :failed
  (skip-unless (and noninteractive
                    (fboundp 'sqlite-available-p)
                    (sqlite-available-p)))
  (require 'ogent-analytics)
  (let ((ogent-analytics-enabled t)
        (ogent-analytics-db-name
         (ogent-test-helper-tests--real-path "analytics.sqlite")))
    (ogent-analytics--get-db)))

(ert-deftest ogent-test-tripwire-probe-ledger-writer ()
  "A real ledger file trips at `ogent-ledger--append-event'."
  :expected-result :failed
  (skip-unless noninteractive)
  (require 'ogent-ledger)
  (cl-letf (((symbol-function 'make-directory) #'ignore)
            ((symbol-function 'append-to-file) #'ignore))
    (let ((ogent-ledger-enabled t)
          (ogent-ledger-file
           (ogent-test-helper-tests--real-path "ledger.org")))
      (ogent-ledger-record 'tripwire-probe '(:x 1)))))

(ert-deftest ogent-test-tripwire-probe-companion-writer ()
  "A real registry file trips at `ogent-companion--write-link-registry'."
  :expected-result :failed
  (skip-unless noninteractive)
  (require 'ogent-companion)
  (cl-letf (((symbol-function 'make-directory) #'ignore)
            ((symbol-function 'write-region) #'ignore))
    (let ((ogent-companion-link-registry-file
           (ogent-test-helper-tests--real-path "companion-links.el")))
      (ogent-companion--write-link-registry '(("src" . "companion"))))))

(ert-deftest ogent-test-tripwire-probe-capture-target ()
  "A real capture target trips at `org-capture-expand-file'."
  :expected-result :failed
  (skip-unless noninteractive)
  (require 'org-capture)
  (org-capture-expand-file
   (expand-file-name "ogent-tripwire-probe.org" org-directory)))

(ert-deftest ogent-test-tripwire-probe-make-process-arg ()
  "A real store path in a :command argument trips `make-process'."
  :expected-result :failed
  (skip-unless noninteractive)
  (make-process :name "ogent-tripwire-probe" :noquery t
                :command (list "true"
                               (ogent-test-helper-tests--real-path "x"))))

(ert-deftest ogent-test-tripwire-probe-start-process-arg ()
  "A real store path in a program argument trips `start-process'."
  :expected-result :failed
  (skip-unless noninteractive)
  (start-process "ogent-tripwire-probe" nil "true"
                 (ogent-test-helper-tests--real-path "x")))

(ert-deftest ogent-test-tripwire-probe-process-directory ()
  "Spawning from a real store `default-directory' trips the wire."
  :expected-result :failed
  (skip-unless noninteractive)
  (let ((default-directory (expand-file-name user-emacs-directory)))
    (make-process :name "ogent-tripwire-probe" :noquery t
                  :command (list "true"))))

;;;; Message tests: the failure text pinpoints test, path, and chokepoint.

(defun ogent-test-helper-tests--violation-message (thunk fn)
  "Call THUNK, return its tripwire violation message naming FN.
Fail the current test when THUNK signals no such violation."
  (let ((msg (error-message-string (should-error (funcall thunk)))))
    (should (string-match-p "attempted real-store access: " msg))
    (should (string-match-p (regexp-quote (format "via %s" fn)) msg))
    msg))

(ert-deftest ogent-test-tripwire-message-names-test-and-path ()
  "The violation message names the running test and the leaked path."
  (skip-unless (and noninteractive (fboundp 'sqlite-open)))
  (let* ((path (ogent-test-helper-tests--real-path "named.sqlite"))
         (msg (ogent-test-helper-tests--violation-message
               (lambda () (sqlite-open path)) 'sqlite-open)))
    (should (string-match-p
             "^TEST ogent-test-tripwire-message-names-test-and-path " msg))
    (should (string-match-p (regexp-quote path) msg))))

(ert-deftest ogent-test-tripwire-message-per-chokepoint ()
  "Every chokepoint's violation message names its own function."
  (skip-unless noninteractive)
  (require 'ogent-ledger)
  (require 'ogent-companion)
  (require 'org-capture)
  (cl-letf (((symbol-function 'make-directory) #'ignore)
            ((symbol-function 'append-to-file) #'ignore)
            ((symbol-function 'write-region) #'ignore))
    (let ((ogent-ledger-enabled t)
          (ogent-ledger-file (ogent-test-helper-tests--real-path "l.org"))
          (ogent-companion-link-registry-file
           (ogent-test-helper-tests--real-path "c.el")))
      (ogent-test-helper-tests--violation-message
       (lambda () (ogent-ledger-record 'probe nil))
       'ogent-ledger--append-event)
      (ogent-test-helper-tests--violation-message
       (lambda () (ogent-companion--write-link-registry nil))
       'ogent-companion--write-link-registry)))
  (ogent-test-helper-tests--violation-message
   (lambda () (org-capture-expand-file
               (expand-file-name "p.org" org-directory)))
   'org-capture-expand-file)
  (ogent-test-helper-tests--violation-message
   (lambda () (make-process :name "p" :noquery t
                            :command
                            (list "true"
                                  (ogent-test-helper-tests--real-path "x"))))
   'make-process)
  (ogent-test-helper-tests--violation-message
   (lambda () (start-process "p" nil "true"
                             (ogent-test-helper-tests--real-path "x")))
   'start-process))

(ert-deftest ogent-test-tripwire-message-analytics-chokepoint ()
  "The analytics chokepoint fires even when `sqlite-open' is stubbed."
  (skip-unless (and noninteractive
                    (fboundp 'sqlite-available-p)
                    (sqlite-available-p)))
  (require 'ogent-analytics)
  (cl-letf (((symbol-function 'sqlite-open) (lambda (&optional _) t)))
    (let ((ogent-analytics-enabled t)
          (ogent-analytics-db-name
           (ogent-test-helper-tests--real-path "a.sqlite")))
      (ogent-test-helper-tests--violation-message
       (lambda () (ogent-analytics--get-db))
       'ogent-analytics--get-db))))

;;;; Silence tests: compliant fixtures and sanctioned paths never trip.

(ert-deftest ogent-test-tripwire-silent-sqlite-sanctioned ()
  "In-memory and temp-rooted DBs pass the sqlite chokepoint."
  (skip-unless (and noninteractive
                    (fboundp 'sqlite-available-p)
                    (sqlite-available-p)))
  (sqlite-close (sqlite-open nil))
  ;; Retained temp directory: the OS owns its lifecycle.
  (let ((dir (make-temp-file "ogent-tripwire-ok-" t)))
    (sqlite-close (sqlite-open (expand-file-name "ok.sqlite" dir)))))

(ert-deftest ogent-test-tripwire-silent-store-fixtures ()
  "The opt-in fixtures write their stores without tripping."
  (skip-unless noninteractive)
  (require 'ogent-ledger)
  (require 'ogent-companion)
  (ogent-test-with-real-store 'ledger
    (should (ogent-ledger-record 'tripwire-silence '(:ok t))))
  (ogent-test-with-real-store 'companion
    (ogent-companion--write-link-registry '(("src" . "companion")))))

(ert-deftest ogent-test-tripwire-silent-capture-guarded-default ()
  "The guard-redirected capture target resolves without tripping."
  (skip-unless noninteractive)
  (require 'org-capture)
  (should (equal (org-capture-expand-file ogent-capture-notes-file)
                 ogent-capture-notes-file))
  (should (org-capture-expand-file
           (expand-file-name "ok.org" temporary-file-directory))))

(ert-deftest ogent-test-tripwire-silent-process-sanctioned ()
  "Temp-rooted spawn directories and arguments pass the process check."
  (skip-unless noninteractive)
  (let ((default-directory temporary-file-directory))
    (should (processp
             (make-process :name "ogent-tripwire-ok" :noquery t
                           :command
                           (list "true"
                                 (expand-file-name
                                  "ok" temporary-file-directory)))))))

(ert-deftest ogent-test-tripwire-allowlist-sanctions-registered-root ()
  "A registered allowlist root is sanctioned; unregistered kin are not."
  (skip-unless noninteractive)
  (let ((probe (ogent-test-helper-tests--real-path "allow/x")))
    (should-not (ogent-test--tripwire-sanctioned-p probe))
    ;; Justified transient registration: this test exercises the
    ;; allowlist mechanism itself; the let-binding restores the empty
    ;; allowlist on exit and the path is never created.
    (let ((ogent-test-tripwire-allowed-roots ogent-test-tripwire-allowed-roots))
      (ogent-test-tripwire-allow-root (file-name-directory probe))
      (should (ogent-test--tripwire-sanctioned-p probe)))
    (should-not (ogent-test--tripwire-sanctioned-p probe))))

(provide 'ogent-test-helper-tests)

;;; ogent-test-helper-tests.el ends here
