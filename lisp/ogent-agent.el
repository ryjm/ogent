;;; ogent-agent.el --- Read-only agent interface discovery -*- lexical-binding: t; -*-

;;; Commentary:
;; Publish live tool metadata and local diagnostics without constructing gptel
;; tools, requesting approval, contacting providers, or changing configuration.
;; Plists are the native SDK format; JSON is an explicit serialization option.

;;; Code:

(require 'json)
(require 'ogent-models)
(require 'ogent-doctor)
(require 'ogent-tool-execution)

(defun ogent-agent--output (data format)
  "Return DATA as a plist or serialize it according to FORMAT."
  (pcase format
    ((or 'nil 'plist) data)
    ('json (concat (json-serialize data :null-object :json-null
                                   :false-object :json-false) "\n"))
    (_ (user-error "Use nil, (quote plist), or (quote json) for the agent report format"))))

(defun ogent-agent-call (name args &optional format)
  "Execute tool NAME with named ARGS and return its structured result.
Return a plist by default or JSON when FORMAT is `json'.  Validate FORMAT
before execution.  Calls respect approval policy and never grant themselves
permission.  For example:
  (ogent-agent-call \"read_file\" \='(:file_path \"README.org\" :limit 20))"
  (ogent-agent--output nil format)
  (ogent-agent--output (ogent-tool-execution-call name args) format))

(defun ogent-agent-next (result &optional format)
  "Follow RESULT's first continuation and return the next page in FORMAT.
Accept a native result plist or JSON string.  Refuse changed snapshots so
pagination cannot silently combine different versions of file/search data.
Return a terminal result with status done when no continuation remains."
  (ogent-agent--output nil format)
  (when (stringp result)
    (setq result (json-parse-string result :object-type 'plist
                                   :null-object :json-null :false-object :json-false)))
  (unless (and (proper-list-p result) (equal (plist-get result :contract_version) "1")
               (vectorp (plist-get result :next)))
    (user-error "Provide a contract_version 1 result from ogent-agent-call"))
  (let* ((next (and (> (length (plist-get result :next)) 0)
                    (aref (plist-get result :next) 0)))
         (name (plist-get result :tool))
         (page
          (if (null next)
              (ogent-tool-execution-result name "done")
            (let ((expected (plist-get next :snapshot)))
              (unless (and (equal name (plist-get next :tool))
                           (stringp expected)
                           (equal expected (plist-get (plist-get result :data) :snapshot)))
                (user-error "Invalid continuation; restart with ogent-agent-call"))
              (let ((actual (ogent-tool-execution-call name (plist-get next :args))))
                (if (and (equal (plist-get actual :status) "ok")
                         (not (equal expected (plist-get (plist-get actual :data) :snapshot))))
                    (ogent-tool-execution-result
                     name "error" nil "snapshot_changed"
                     "Files changed between pages; restart the original call rather than combining these results")
                  actual))))))
    (ogent-agent--output page format)))

(defun ogent-agent--boolean (value)
  "Return a JSON-compatible boolean for VALUE."
  (if value t :json-false))

(defun ogent-agent--tool (spec)
  "Return public discovery metadata for tool SPEC."
  (let* ((name (plist-get spec :name))
         (enabled (or (eq ogent-tools-enabled t)
                      (and (listp ogent-tools-enabled)
                           (memq name (mapcar #'ogent-tool--name-symbol
                                              ogent-tools-enabled))))))
    (list :name (symbol-name name)
          :aliases (vconcat
                    (delete-dups
                     (seq-filter
                      (lambda (alias) (and (not (equal alias (symbol-name name)))
                                           (eq name (ogent-tool--name-symbol alias))))
                      (cons (replace-regexp-in-string "-" "_" (symbol-name name))
                            (append (plist-get spec :aliases) nil)))))
          :description (or (plist-get spec :description) "")
          :category (or (plist-get spec :category) "")
          :enabled (ogent-agent--boolean enabled)
          :async (ogent-agent--boolean (plist-get spec :async))
          :boolean_representation (if (eq (plist-get spec :boolean-representation) 'json)
                                      "json" "native")
          :confirmation_required (ogent-agent--boolean
                                  (ogent-tool-spec-confirm-p spec))
          :risk (symbol-name (ogent-tool-effects-risk (plist-get spec :effects)))
          :arguments
          (vconcat
           (mapcar (lambda (arg)
                     (append (list :name (plist-get arg :name)
				   :type (format "%s" (plist-get arg :type))
				   :optional (ogent-agent--boolean (plist-get arg :optional))
				   :description (or (plist-get arg :description) ""))
                             (when (plist-member arg :enum)
                               (list :enum (vconcat (plist-get arg :enum))))))
                   (plist-get spec :args)))
          :effects
          (vconcat
           (mapcar (lambda (effect)
                     (list :kind (format "%s" (plist-get effect :kind))
                           :target (format "%s" (plist-get effect :target))
                           :scope (format "%s" (plist-get effect :scope))
                           :risk (format "%s" (plist-get effect :risk))))
                   (ogent-tool-effects-normalize (plist-get spec :effects)))))))

(defun ogent-agent-capabilities (&optional format)
  "Return live tool contracts as a plist, or JSON when FORMAT is `json'.
Report registry metadata without constructing or executing tools.  Empty
registries produce an empty tools array.  Names are sorted; argument order
matches positional SDK calls.  Confirmation describes declared policy;
per-call allow/deny rules still apply at execution time."
  (ogent-agent--output
   (list :contract_version "1"
         :interface "Emacs Lisp SDK"
         :tools
         (vconcat (mapcar #'ogent-agent--tool
                          (sort (copy-sequence ogent-tool-registry)
				(lambda (a b)
                                  (string< (symbol-name (plist-get a :name))
                                           (symbol-name (plist-get b :name)))))))
         :result_contract
         (list :tool_results "text; errors are signaled or returned as Tool error: text by the execution wrapper"
               :async_events ["stdout" "stderr" "done" "error"]
               :doctor_exit_codes (list :ok 0 :warning 1 :error 2))
         :discovery
         (list :guide "(ogent-agent-guide)"
               :triage "(ogent-agent-triage 'json)"
               :doctor "(ogent-doctor-batch nil 'json)"))
   format))

(defun ogent-agent-guide ()
  "Return a paste-ready handbook for agents using ogent's Emacs Lisp SDK."
  (concat
   "ogent agent guide (contract 1)\n"
   "Load ogent normally, then inspect (ogent-agent-capabilities 'json).\n"
   "This reads the live registry; an empty tools array means no tools are installed.\n"
   "(ogent-tools-install-defaults) explicitly installs built-in specs if wanted.\n"
   "Use canonical hyphen names or registered underscore aliases; typos get hints, never execution.\n"
   "Arguments follow registry order; named calls reject unknown/duplicate keys before approval.\n"
   "Native boolean false is nil or :json-false; zero and nested objects are preserved.\n"
   "MCP calls use :json-false for explicit false; optional nil means omit the argument.\n"
   "Tool results remain text. JSON discovery and doctor reports use contract_version 1.\n"
   "Read: (ogent-tool--read-file \"/path/file\" 1 200); follow the exact next offset in its footer.\n"
   "Search: (ogent-tool--glob \"**/*.el\" \"/path/project\") includes every depth.\n"
   "Grep: (ogent-tool--grep \"-needle\" \"/path/project\"); no matches is success, invalid regex is an error.\n"
   "Edit: old_string must be nonempty and unique; set replace_all to t only for intentional repeated replacement.\n"
   "Read-only tools need no confirmation by default. Writes and shell execution require approval.\n"
   "Direct ogent-tool-- functions are low-level APIs; use registered execution wrappers for approval enforcement.\n"
   "Shell: use a positive timeout in seconds and an existing working_directory.\n"
   "Shell stdout/stderr may be truncated; the final exit code is preserved.\n"
   "Local health: (ogent-agent-triage 'json), no provider requests or MCP handshakes.\n"
   "Batch health: (ogent-doctor-batch nil 'json), exit 0=ok/info, 1=warning, 2=error.\n"
   "Check readiness offline: make test; make test-isolation; make offline-test with OGENT_ELPA_DIR.\n"))

(defun ogent-agent-triage (&optional format)
  "Return discovery, next actions, and local health, optionally in FORMAT.
Run default read-only doctor checks; never run opt-in network checks."
  ;; Validate the format before invoking diagnostics.
  (ogent-agent--output nil format)
  (let* ((results (ogent-doctor-run nil))
         (health (ogent-doctor-data results)))
    (ogent-agent--output
     (list :contract_version "1"
           :quick_ref (ogent-agent-capabilities)
           :recommendations
           (vconcat (delq nil
                          (mapcar (lambda (check)
                                    (when (memq (plist-get check :status) '(warn error))
                                      (list :id (symbol-name (plist-get check :id))
                                            :action (or (plist-get check :remediation)
                                                        (plist-get check :detail)))))
                                  results)))
           :commands (vector "(ogent-agent-guide)"
                             "(ogent-doctor-batch nil 'json)"
                             "make test" "make test-isolation" "make offline-test")
           :project_health health)
     format)))

(provide 'ogent-agent)

;;; ogent-agent.el ends here
