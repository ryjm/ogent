;;; ogent-armory-ql-tests.el --- Tests for the Armory org-ql adapter -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the pure Armory QL query builder, the saved view defaults,
;; and the org-ql availability guard on the interactive commands.  None
;; of these tests require org-ql to be installed.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory)
(require 'ogent-armory-ql)

(defmacro ogent-armory-ql-test-with-temp-dir (var &rest body)
  "Bind VAR to a retained temporary Armory directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (file-truename
                (directory-file-name
                 (ogent-test--provision-store-directory 'armory-ql)))))
     ,@body))

;;; Pure query builder

(ert-deftest ogent-armory-ql-query-kind-maps-marker-properties ()
  "Each classified record kind maps to its OGENT_* marker property."
  (dolist (pair '((armory . "OGENT_ARMORY")
                  (conversation . "OGENT_CONVERSATION")
                  (session . "OGENT_SESSION")
                  (job . "OGENT_JOB")
                  (agent . "OGENT_AGENT")
                  (import . "OGENT_IMPORT")
                  (issue-link . "OGENT_ISSUE_ID")
                  (action . "OGENT_ACTION")))
    (should (equal (ogent-armory-ql-query :kind (car pair))
                   (list 'property (cdr pair))))))

(ert-deftest ogent-armory-ql-query-kind-accepts-strings ()
  "A string kind is normalized to its symbol before mapping."
  (should (equal (ogent-armory-ql-query :kind "session")
                 '(property "OGENT_SESSION"))))

(ert-deftest ogent-armory-ql-query-status-matches-todo-or-property ()
  "Status matches the todo keyword or OGENT_STATUS, like record metadata."
  (should (equal (ogent-armory-ql-query :status "failed")
                 '(or (todo "FAILED")
                      (property "OGENT_STATUS" "failed")))))

(ert-deftest ogent-armory-ql-query-agent-falls-back-to-slug ()
  "Agent intent matches OGENT_AGENT with the OGENT_SLUG fallback."
  (should (equal (ogent-armory-ql-query :agent "builder")
                 '(or (property "OGENT_AGENT" "builder")
                      (property "OGENT_SLUG" "builder")))))

(ert-deftest ogent-armory-ql-query-action-status-maps-property ()
  "Action status maps to the OGENT_ACTION_STATUS property."
  (should (equal (ogent-armory-ql-query :action-status "pending")
                 '(property "OGENT_ACTION_STATUS" "pending"))))

(ert-deftest ogent-armory-ql-query-tag-matches-tags-or-property ()
  "Tag intent matches Org tags or the OGENT_TAGS property."
  (should (equal (ogent-armory-ql-query :tag "urgent")
                 '(or (tags "urgent")
                      (property "OGENT_TAGS" "urgent")))))

(ert-deftest ogent-armory-ql-query-archived-covers-truthy-strings ()
  "Archived t matches every truthy OGENT_ARCHIVED spelling; nil negates."
  (let ((truthy '(or (property "OGENT_ARCHIVED" "t")
                     (property "OGENT_ARCHIVED" "true")
                     (property "OGENT_ARCHIVED" "yes")
                     (property "OGENT_ARCHIVED" "1"))))
    (should (equal (ogent-armory-ql-query :archived t) truthy))
    (should (equal (ogent-armory-ql-query :archived nil)
                   (list 'not truthy)))))

(ert-deftest ogent-armory-ql-query-text-is-regexp-quoted ()
  "Free text intent becomes a literal, regexp-quoted match."
  (should (equal (ogent-armory-ql-query :query "a.b*c")
                 (list 'regexp (regexp-quote "a.b*c")))))

(ert-deftest ogent-armory-ql-query-composes-with-and ()
  "Multiple intent keys compose into a single `and' query."
  (should (equal (ogent-armory-ql-query
                  :kind 'conversation :status "failed" :agent "x")
                 '(and (property "OGENT_CONVERSATION")
                       (or (todo "FAILED")
                           (property "OGENT_STATUS" "failed"))
                       (or (property "OGENT_AGENT" "x")
                           (property "OGENT_SLUG" "x"))))))

(ert-deftest ogent-armory-ql-query-order-is-canonical ()
  "Clause order does not depend on intent plist key order."
  (should (equal (ogent-armory-ql-query
                  :agent "x" :status "failed" :kind 'conversation)
                 (ogent-armory-ql-query
                  :kind 'conversation :status "failed" :agent "x"))))

(ert-deftest ogent-armory-ql-query-rejects-bad-intents ()
  "Unknown keys, unknown kinds, and empty intents signal `user-error'."
  (should-error (ogent-armory-ql-query :flavor "sweet") :type 'user-error)
  (should-error (ogent-armory-ql-query :kind 'banana) :type 'user-error)
  (should-error (ogent-armory-ql-query) :type 'user-error)
  ;; :sort is dispatch-only and produces no clause.
  (should-error (ogent-armory-ql-query :sort 'recent) :type 'user-error)
  ;; Dangling key without a value.
  (should-error (ogent-armory-ql-query :kind) :type 'user-error))

;;; Saved views

(ert-deftest ogent-armory-ql-saved-views-defaults-expand ()
  "Every default saved view expands to the expected valid query."
  (let ((expected
         '(("failed runs"
            . (and (property "OGENT_CONVERSATION")
                   (or (todo "FAILED")
                       (property "OGENT_STATUS" "failed"))))
           ("running now"
            . (and (property "OGENT_CONVERSATION")
                   (or (todo "RUNNING")
                       (property "OGENT_STATUS" "running"))))
           ("recent conversations"
            . (property "OGENT_CONVERSATION"))
           ("pending approvals"
            . (and (property "OGENT_ACTION")
                   (property "OGENT_ACTION_STATUS" "pending"))))))
    (should (equal (mapcar #'car ogent-armory-ql-saved-views)
                   (mapcar #'car expected)))
    (dolist (view ogent-armory-ql-saved-views)
      (should (equal (apply #'ogent-armory-ql-query (cdr view))
                     (cdr (assoc (car view) expected)))))))

;;; Result ordering

(ert-deftest ogent-armory-ql-recent-first-orders-by-activity ()
  "The recent comparator puts fresher OGENT_* activity first."
  (let ((new '(headline (:OGENT_LAST_ACTIVITY_AT "2026-07-13T10:00:00Z")))
        (old '(headline (:OGENT_LAST_ACTIVITY_AT "2026-07-01T10:00:00Z")))
        (started '(headline (:OGENT_STARTED_AT "2026-07-10T10:00:00Z")))
        (bare '(headline nil)))
    (should (ogent-armory-ql--recent-first new old))
    (should-not (ogent-armory-ql--recent-first old new))
    ;; OGENT_STARTED_AT is used when no last-activity stamp exists.
    (should (ogent-armory-ql--recent-first new started))
    (should (ogent-armory-ql--recent-first started old))
    ;; Entries without timestamps sort last and never crash.
    (should (ogent-armory-ql--recent-first new bare))
    (should-not (ogent-armory-ql--recent-first bare new))
    (should-not (ogent-armory-ql--recent-first bare bare))))

(ert-deftest ogent-armory-ql-sort-argument-translates-recent ()
  "Only the `recent' sort hint is rewritten; others pass through."
  (should (eq (ogent-armory-ql--sort-argument 'recent)
              #'ogent-armory-ql--recent-first))
  (should (eq (ogent-armory-ql--sort-argument 'date) 'date))
  (should-not (ogent-armory-ql--sort-argument nil)))

;;; Availability guard on interactive commands

(ert-deftest ogent-armory-ql-search-signals-install-hint-without-org-ql ()
  "`ogent-armory-ql-search' signals a user-error naming org-ql."
  (cl-letf (((symbol-function 'ogent-armory-ql-available-p)
             (lambda () nil)))
    (let ((err (should-error (ogent-armory-ql-search '(:kind conversation))
                             :type 'user-error)))
      (should (string-match-p "org-ql" (cadr err)))
      (should (string-match-p "package-install" (cadr err))))))

(ert-deftest ogent-armory-ql-view-signals-install-hint-without-org-ql ()
  "`ogent-armory-ql-view' signals a user-error naming org-ql."
  (cl-letf (((symbol-function 'ogent-armory-ql-available-p)
             (lambda () nil)))
    (let ((err (should-error (ogent-armory-ql-view "failed runs")
                             :type 'user-error)))
      (should (string-match-p "org-ql" (cadr err)))
      (should (string-match-p "package-install" (cadr err))))))

(ert-deftest ogent-armory-ql-view-rejects-unknown-names ()
  "An unknown saved view name signals a user-error, not a crash."
  (cl-letf (((symbol-function 'ogent-armory-ql--ensure) (lambda () t)))
    (should-error (ogent-armory-ql-view "no such view") :type 'user-error)))

;;; Dispatch wiring (org-ql stubbed)

(ert-deftest ogent-armory-ql-view-dispatches-org-ql-search ()
  "A saved view dispatches org-ql-search with the right files and query."
  (ogent-armory-ql-test-with-temp-dir root
    (with-temp-file (expand-file-name "note.org" root)
      (insert "* Note\n"))
    (let ((actions-dir (expand-file-name ".agents/.conversations/c1" root)))
      (make-directory actions-dir t)
      (with-temp-file (expand-file-name "actions.org" actions-dir)
        (insert "* PENDING Deploy\n"))
      (with-temp-file (expand-file-name "index.org" actions-dir)
        (insert "* Conversation\n")))
    (let (captured)
      (cl-letf (((symbol-function 'ogent-armory-ql-available-p)
                 (lambda () t))
                ((symbol-function 'org-ql-search)
                 (lambda (files query &rest options)
                   (setq captured (list files query options)))))
        (ogent-armory-ql-view "running now" root))
      (should captured)
      (let ((files (nth 0 captured)))
        (should (member (expand-file-name "note.org" root) files))
        ;; Hidden conversation indexes and action files are searched too.
        (should (member (expand-file-name
                         ".agents/.conversations/c1/index.org" root)
                        files))
        (should (member (expand-file-name
                         ".agents/.conversations/c1/actions.org" root)
                        files)))
      (should (equal (nth 1 captured)
                     '(and (property "OGENT_CONVERSATION")
                           (or (todo "RUNNING")
                               (property "OGENT_STATUS" "running")))))
      (should (equal (plist-get (nth 2 captured) :title)
                     "Armory: running now")))))

(ert-deftest ogent-armory-ql-search-dispatches-intent ()
  "`ogent-armory-ql-search' forwards its intent plist to org-ql-search."
  (ogent-armory-ql-test-with-temp-dir root
    (with-temp-file (expand-file-name "note.org" root)
      (insert "* Note\n"))
    (let (captured)
      (cl-letf (((symbol-function 'ogent-armory-ql-available-p)
                 (lambda () t))
                ((symbol-function 'org-ql-search)
                 (lambda (_files query &rest options)
                   (setq captured (list query options)))))
        (ogent-armory-ql-search '(:kind session :agent "builder") root))
      (should (equal (nth 0 captured)
                     '(and (property "OGENT_SESSION")
                           (or (property "OGENT_AGENT" "builder")
                               (property "OGENT_SLUG" "builder")))))
      (should (equal (plist-get (nth 1 captured) :title) "Armory search")))))

(ert-deftest ogent-armory-ql-recent-view-passes-sort-comparator ()
  "The recent-conversations view hands org-ql-search the comparator."
  (ogent-armory-ql-test-with-temp-dir root
    (with-temp-file (expand-file-name "note.org" root)
      (insert "* Note\n"))
    (let (captured)
      (cl-letf (((symbol-function 'ogent-armory-ql-available-p)
                 (lambda () t))
                ((symbol-function 'org-ql-search)
                 (lambda (_files _query &rest options)
                   (setq captured options))))
        (ogent-armory-ql-view "recent conversations" root))
      (should (eq (plist-get captured :sort)
                  #'ogent-armory-ql--recent-first)))))

(provide 'ogent-armory-ql-tests)
;;; ogent-armory-ql-tests.el ends here
