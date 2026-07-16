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

(provide 'ogent-test-helper-tests)

;;; ogent-test-helper-tests.el ends here
