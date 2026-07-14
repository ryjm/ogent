;;; ogent-armory-ql.el --- org-ql adapter for Armory records -*- lexical-binding: t; -*-

;;; Commentary:
;; Optional org-ql adapter over Armory Org records.  This module maps
;; ogent search intents (plists such as (:kind conversation :status
;; "failed")) to org-ql sexp queries over the OGENT_* property drawer
;; schema, mirroring the metadata classification used by
;; `ogent-armory-record-metadata' and `ogent-armory-search-records'.
;; It complements the built-in line-oriented search; it does not
;; replace it.
;;
;; org-ql is an optional dependency: the pure query builder works
;; without it, and the interactive commands signal a `user-error' with
;; an install hint when the package is unavailable.

;;; Code:

(require 'subr-x)
(require 'org-element)
(require 'ogent-armory)

(require 'org-ql nil t)
(require 'org-ql-search nil t)
(declare-function org-ql-search "ext:org-ql-search" (buffers-files query &rest rest))

(defgroup ogent-armory-ql nil
  "Saved org-ql views over Armory Org records."
  :group 'ogent-armory
  :prefix "ogent-armory-ql-")

(defconst ogent-armory-ql-kind-properties
  '((armory . "OGENT_ARMORY")
    (conversation . "OGENT_CONVERSATION")
    (session . "OGENT_SESSION")
    (job . "OGENT_JOB")
    (agent . "OGENT_AGENT")
    (import . "OGENT_IMPORT")
    (issue-link . "OGENT_ISSUE_ID")
    (action . "OGENT_ACTION"))
  "Marker Org properties identifying each Armory record kind.
Mirrors the kind classification in `ogent-armory-record-metadata',
plus `action' for the per-heading proposals written by
ogent-armory-actions.")

(defconst ogent-armory-ql--intent-keys
  '(:kind :status :action-status :agent :tag :archived :query :sort)
  "Keywords accepted in an Armory QL search intent plist.")

(defconst ogent-armory-ql--truthy-strings '("t" "true" "yes" "1")
  "Property strings `ogent-armory--truth-value' treats as true.")

(defcustom ogent-armory-ql-saved-views
  '(("failed runs" . (:kind conversation :status "failed"))
    ("running now" . (:kind conversation :status "running"))
    ("recent conversations" . (:kind conversation :sort recent))
    ("pending approvals" . (:kind action :action-status "pending")))
  "Saved Armory org-ql views as an alist of name to search intent.
Each value is an intent plist accepted by `ogent-armory-ql-query'.
The optional `:sort' key only orders results (`recent' puts the
freshest OGENT_* activity first) and adds no query clause."
  :type '(alist :key-type (string :tag "View name")
                :value-type (plist :tag "Search intent"))
  :group 'ogent-armory-ql)

;;; Availability

(defun ogent-armory-ql-available-p ()
  "Return non-nil when the optional org-ql package is loadable."
  (and (require 'org-ql nil t)
       (require 'org-ql-search nil t)
       (fboundp 'org-ql-search)))

(defun ogent-armory-ql--ensure ()
  "Signal a `user-error' with an install hint unless org-ql is available.
Return non-nil otherwise."
  (or (ogent-armory-ql-available-p)
      (user-error
       "Armory QL views need the optional org-ql package; install it \
with M-x package-install RET org-ql RET")))

;;; Pure query construction

(defun ogent-armory-ql--string (value)
  "Return VALUE as a string, converting symbols by name."
  (if (symbolp value) (symbol-name value) value))

(defun ogent-armory-ql--validate-intent (intent)
  "Signal a `user-error' when the INTENT plist is malformed."
  (let ((tail intent))
    (while tail
      (unless (memq (car tail) ogent-armory-ql--intent-keys)
        (user-error "Unknown Armory QL intent key: %s" (car tail)))
      (unless (cdr tail)
        (user-error "Armory QL intent key %s has no value" (car tail)))
      (setq tail (cddr tail)))))

(defun ogent-armory-ql--kind-clause (kind)
  "Return the org-ql clause selecting Armory records of KIND.
KIND is a symbol (or string) from `ogent-armory-ql-kind-properties'."
  (let* ((symbol (if (stringp kind) (intern kind) kind))
         (property (cdr (assq symbol ogent-armory-ql-kind-properties))))
    (unless property
      (user-error "Unknown Armory record kind %s (expected one of: %s)"
                  kind
                  (mapconcat (lambda (entry) (symbol-name (car entry)))
                             ogent-armory-ql-kind-properties ", ")))
    (list 'property property)))

(defun ogent-armory-ql--status-clause (status)
  "Return the org-ql clause matching record STATUS.
Match either the todo keyword or the OGENT_STATUS property, mirroring
the status fallback in `ogent-armory-record-metadata'."
  (let ((value (ogent-armory-ql--string status)))
    (list 'or
          (list 'todo (upcase value))
          (list 'property "OGENT_STATUS" value))))

(defun ogent-armory-ql--agent-clause (agent)
  "Return the org-ql clause matching records owned by AGENT.
Match OGENT_AGENT or the OGENT_SLUG fallback, mirroring the agent
resolution in `ogent-armory-record-metadata'."
  (let ((value (ogent-armory-ql--string agent)))
    (list 'or
          (list 'property "OGENT_AGENT" value)
          (list 'property "OGENT_SLUG" value))))

(defun ogent-armory-ql--tag-clause (tag)
  "Return the org-ql clause matching records tagged TAG.
Match Org heading tags or an exact OGENT_TAGS property value."
  (let ((value (ogent-armory-ql--string tag)))
    (list 'or
          (list 'tags value)
          (list 'property "OGENT_TAGS" value))))

(defun ogent-armory-ql--archived-clause (archived)
  "Return the org-ql clause for the ARCHIVED intent value.
Non-nil ARCHIVED selects archived records; nil selects records whose
OGENT_ARCHIVED property is absent or not a truthy string."
  (let ((truthy (cons 'or
                      (mapcar (lambda (value)
                                (list 'property "OGENT_ARCHIVED" value))
                              ogent-armory-ql--truthy-strings))))
    (if archived truthy (list 'not truthy))))

(defun ogent-armory-ql-query (&rest intent)
  "Return an org-ql sexp query for the Armory search INTENT plist.
INTENT accepts the following keys, all optional but at least one of
the query-producing keys is required:

  :kind SYMBOL           record kind from `ogent-armory-ql-kind-properties'
  :status STRING         todo keyword or OGENT_STATUS value
  :action-status STRING  OGENT_ACTION_STATUS value on action proposals
  :agent STRING          OGENT_AGENT (or OGENT_SLUG fallback) value
  :tag STRING            Org tag or exact OGENT_TAGS value
  :archived BOOLEAN      archived state via OGENT_ARCHIVED
  :query STRING          literal text matched against entry contents
  :sort SYMBOL           result ordering hint; adds no query clause

Multiple keys compose with `and'; a single key returns its bare
clause.  Signal a `user-error' on unknown keys or an empty intent."
  (ogent-armory-ql--validate-intent intent)
  (let* ((archived-cell (plist-member intent :archived))
         (clauses
          (delq nil
                (list
                 (when-let* ((kind (plist-get intent :kind)))
                   (ogent-armory-ql--kind-clause kind))
                 (when-let* ((status (plist-get intent :status)))
                   (ogent-armory-ql--status-clause status))
                 (when-let* ((status (plist-get intent :action-status)))
                   (list 'property "OGENT_ACTION_STATUS"
                         (ogent-armory-ql--string status)))
                 (when-let* ((agent (plist-get intent :agent)))
                   (ogent-armory-ql--agent-clause agent))
                 (when-let* ((tag (plist-get intent :tag)))
                   (ogent-armory-ql--tag-clause tag))
                 (when archived-cell
                   (ogent-armory-ql--archived-clause (cadr archived-cell)))
                 (when-let* ((text (plist-get intent :query)))
                   (list 'regexp (regexp-quote text)))))))
    (pcase clauses
      ('nil (user-error "Armory QL intent needs at least one search key"))
      (`(,clause) clause)
      (_ (cons 'and clauses)))))

;;; Result ordering

(defun ogent-armory-ql--element-time (element)
  "Return the freshest OGENT_* activity timestamp string on ELEMENT.
Return the empty string when ELEMENT carries no known timestamp."
  (or (org-element-property :OGENT_LAST_ACTIVITY_AT element)
      (org-element-property :OGENT_COMPLETED_AT element)
      (org-element-property :OGENT_FINISHED element)
      (org-element-property :OGENT_STARTED_AT element)
      (org-element-property :OGENT_UPDATED_AT element)
      (org-element-property :OGENT_CREATED_AT element)
      ""))

(defun ogent-armory-ql--recent-first (a b)
  "Return non-nil when element A has fresher Armory activity than B.
Timestamps are ISO-8601 strings, so lexicographic comparison orders
them chronologically."
  (string> (ogent-armory-ql--element-time a)
           (ogent-armory-ql--element-time b)))

(defun ogent-armory-ql--sort-argument (sort)
  "Return the `org-ql-search' :sort argument for the intent SORT value.
Translate `recent' to the OGENT_* activity comparator and pass any
other value through unchanged."
  (if (eq sort 'recent) #'ogent-armory-ql--recent-first sort))

;;; Dispatch

(defun ogent-armory-ql--action-org-files (root)
  "Return conversation action proposal files under ROOT.
These live below .agents/.conversations/, which
`ogent-armory-org-files' deliberately hides."
  (let ((store (expand-file-name ".agents/.conversations" root)))
    (when (file-directory-p store)
      (directory-files-recursively store "\\`actions\\.org\\'"))))

(defun ogent-armory-ql--files (root)
  "Return the Armory Org files searched by QL views under ROOT.
Include visible records plus the hidden conversation indexes and
action proposal files, mirroring `ogent-armory-search-records'."
  (append (ogent-armory-org-files root)
          (ogent-armory--conversation-org-files root)
          (ogent-armory-ql--action-org-files root)))

(defun ogent-armory-ql--dispatch (intent directory title)
  "Run `org-ql-search' for the INTENT plist over an Armory.
DIRECTORY names the Armory root; when nil, use the root at point or
prompt for one.  TITLE labels the results buffer.  Signal a
`user-error' with an install hint when org-ql is unavailable."
  (ogent-armory-ql--ensure)
  (let* ((root (ogent-armory--directory
                (or directory
                    (ogent-armory-find-root)
                    (read-directory-name "Armory root: "))))
         (files (ogent-armory-ql--files root))
         (query (apply #'ogent-armory-ql-query intent)))
    (unless files
      (user-error "No Armory Org files found under %s" root))
    (org-ql-search files query
                   :title (or title "Armory search")
                   :sort (ogent-armory-ql--sort-argument
                          (plist-get intent :sort)))))

(defun ogent-armory-ql--read-intent ()
  "Prompt for an Armory QL search intent plist.
Signal a `user-error' when every prompt is left empty."
  (let* ((kinds (mapcar (lambda (entry) (symbol-name (car entry)))
                        ogent-armory-ql-kind-properties))
         (kind (completing-read "Record kind (empty for any): "
                                kinds nil t))
         (status (read-string "Status (empty for any): "))
         (text (read-string "Matching text (empty for none): "))
         (intent nil))
    (unless (string-empty-p text)
      (setq intent (list :query text)))
    (unless (string-empty-p status)
      (setq intent (append (list :status status) intent)))
    (unless (string-empty-p kind)
      (setq intent (append (list :kind (intern kind)) intent)))
    (unless intent
      (user-error "Armory QL search needs a kind, status, or text"))
    intent))

;;;###autoload
(defun ogent-armory-ql-search (intent &optional directory)
  "Search Armory records with `org-ql-search' for the INTENT plist.
INTENT is a plist accepted by `ogent-armory-ql-query'.  DIRECTORY
overrides the Armory root; when nil, use the root at point or prompt
for one.  Signal a `user-error' with an install hint when the
optional org-ql package is unavailable."
  (interactive
   (progn
     (ogent-armory-ql--ensure)
     (list (ogent-armory-ql--read-intent) nil)))
  (ogent-armory-ql--dispatch intent directory "Armory search"))

;;;###autoload
(defun ogent-armory-ql-view (name &optional directory)
  "Display the saved Armory QL view NAME with `org-ql-search'.
NAME keys into `ogent-armory-ql-saved-views'.  DIRECTORY overrides
the Armory root; when nil, use the root at point or prompt for one.
Signal a `user-error' with an install hint when the optional org-ql
package is unavailable."
  (interactive
   (progn
     (ogent-armory-ql--ensure)
     (list (completing-read "Armory view: "
                            (mapcar #'car ogent-armory-ql-saved-views)
                            nil t)
           nil)))
  (ogent-armory-ql--ensure)
  (let ((intent (cdr (assoc name ogent-armory-ql-saved-views))))
    (unless intent
      (user-error "No saved Armory view named %S (see `ogent-armory-ql-saved-views')"
                  name))
    (ogent-armory-ql--dispatch intent directory
                               (format "Armory: %s" name))))

(provide 'ogent-armory-ql)
;;; ogent-armory-ql.el ends here
