;;; ogent-agent.el --- Agent contracts and named execution -*- lexical-binding: t; -*-

;;; Commentary:
;; Publish live metadata and local diagnostics without provider requests.
;; Execute named tools through the shared approval, review and ledger owners.
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
    ('json (ogent-tool-execution-json data))
    (_ (user-error "Use nil, (quote plist), or (quote json) for the agent report format"))))

(defun ogent-agent-call (name args &optional format)
  "Execute tool NAME with named ARGS and return its structured result.
Return a plist by default or JSON when FORMAT is `json'.  Validate FORMAT
before execution.  Respect approval policy without granting permission.
For example:
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
              (if (equal (plist-get result :status) "ok")
                  (ogent-tool-execution-result name "done") result)
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

(defun ogent-agent-call-async (name args callback &optional format)
  "Execute NAME with named ARGS and send its terminal result to CALLBACK.
Serialize that result according to FORMAT.  Return a process for asynchronous
tools; immediate results return nil.  CALLBACK accepts one result and runs
exactly once, including validation, denial, timeout and cancellation failures.
Cancel a returned process with `ogent-tool-process-cancel'."
  (ogent-agent--output nil format)
  (unless (functionp callback)
    (user-error "Provide a callback function accepting one terminal result"))
  (ogent-tool-execution-call
   name args (lambda (result) (funcall callback (ogent-agent--output result format)))))

(defun ogent-agent-batch (calls &optional format fail-fast)
  "Execute up to 20 explicitly read-only CALLS and return results in FORMAT.
Accept a list or vector of call plists containing :tool and :args.  Preflight
the entire batch before running any call.  Reject writes, shell commands and tools
without declared read effects.  Continue after errors unless FAIL-FAST is t.
For example, batch a glob, search and file read in one local SDK round trip."
  (ogent-agent--output nil format)
  (let ((phase "invalid_arguments") prepared results stopped)
    (ogent-agent--output
     (condition-case err
         (progn
           (unless (and (or (proper-list-p calls) (vectorp calls))
                        (<= (length calls) 20))
             (user-error "Provide at most 20 calls as a list or vector"))
           (unless (memq fail-fast '(nil t))
             (user-error "Use nil or t for fail-fast"))
           (dolist (call (append calls nil))
             (unless (and (proper-list-p call) (= (length call) 4)
                          (plist-member call :tool) (plist-member call :args)
                          (cl-loop for key in call by #'cddr always (memq key '(:tool :args))))
               (user-error "Each call needs only :tool and :args fields"))
             (let ((spec (ogent-tool-spec-get (plist-get call :tool))))
               (unless spec (user-error "%s" (ogent-tool-contract-name-hint
                                              (plist-get call :tool)
                                              (mapcar (lambda (item) (plist-get item :name)) ogent-tool-registry))))
               (ogent-tool-contract-values (ogent-tool-execution--schema spec) (plist-get call :args))
               (setq phase "unsafe_batch")
               (let ((effects (ogent-tool-effects-normalize (plist-get spec :effects))))
                 (unless (and effects (cl-every (lambda (effect) (eq (plist-get effect :kind) 'read)) effects))
                   (user-error "Batch accepts only declared read-only tools; invoke %s individually through approval"
                               (plist-get spec :name))))
               (setq phase "invalid_arguments")
               (push (cons (ogent-tool-execution-snapshot spec) call) prepared)))
           (dolist (entry (nreverse prepared))
             (unless stopped
               (let* ((spec (car entry)) (call (cdr entry))
                      (result (if (equal spec (ogent-tool-spec-get (plist-get spec :name)))
                                  (ogent-tool-execution-call (plist-get call :tool) (plist-get call :args))
                                (ogent-tool-execution-result
                                 (plist-get spec :name) "error" nil "unavailable"
                                 "Tool registry changed during batch; rediscover before retrying"))))
                 (push result results)
                 (when (and fail-fast (not (equal (plist-get result :status) "ok")))
                   (setq stopped t)))))
           (setq results (nreverse results))
           (ogent-tool-execution-result
            "batch" (if (cl-every (lambda (result) (equal (plist-get result :status) "ok")) results)
                        "ok" "partial")
            (list :results (vconcat results) :requested (length calls) :completed (length results)
                  :stopped (if stopped t :json-false))))
       (error (ogent-tool-execution--failure "batch" phase err)))
     format)))

(defun ogent-agent--boolean (value)
  "Return a JSON-compatible boolean for VALUE."
  (if value t :json-false))

(defun ogent-agent--arguments (arguments)
  "Return public metadata for registry ARGUMENTS as a vector."
  (vconcat
   (mapcar (lambda (arg)
             (append (list :name (plist-get arg :name)
                           :type (format "%s" (plist-get arg :type))
                           :optional (ogent-agent--boolean (plist-get arg :optional))
                           :description (or (plist-get arg :description) ""))
                     (when (plist-member arg :enum)
                       (list :enum (vconcat (plist-get arg :enum))))))
           arguments)))

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
          :async_sdk (ogent-agent--boolean (or (plist-get spec :result-async-function)
                                               (plist-get spec :async)))
          :legacy_streaming (ogent-agent--boolean (plist-get spec :async-function))
          :boolean_representation (if (eq (plist-get spec :boolean-representation) 'json)
                                      "json" "native")
          :confirmation_required (ogent-agent--boolean
                                  (ogent-tool-spec-confirm-p spec))
          :risk (symbol-name (ogent-tool-effects-risk (plist-get spec :effects)))
          :arguments (ogent-agent--arguments (plist-get spec :args))
          :call_arguments (ogent-agent--arguments
                           (append (plist-get spec :args) (plist-get spec :result-args)))
          :execution (if (plist-get spec :async) "ogent-agent-call-async" "ogent-agent-call")
          :result (if (plist-get spec :result-function) "structured data" "value envelope")
          :examples (if-let ((args (plist-get spec :example-args)))
                        (let ((print-length nil) (print-level nil))
                          (vector (prin1-to-string (list 'ogent-agent-call (symbol-name name)
                                                         (list 'quote args))))) [])
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
         (list :tool_results "ogent-agent-call returns versioned status/data/error/next envelopes; legacy functions default to text"
               :schema "(ogent-agent-schema 'json)"
               :continuation "(ogent-agent-next RESULT) follows the next page and guards snapshots"
               :batch "ogent-agent-batch accepts up to 20 declared read-only calls"
               :async_sdk "ogent-agent-call-async returns a process and invokes one terminal callback"
               :async_events ["stdout" "stderr" "done" "error"]
               :doctor_exit_codes (list :ok 0 :warning 1 :error 2))
         :discovery
         (list :guide "(ogent-agent-guide)"
               :describe "(ogent-agent-describe TOOL 'json)"
               :triage "(ogent-agent-triage 'json)"
               :doctor "(ogent-doctor-batch nil 'json)"))
   format))

(defun ogent-agent-describe (name &optional format)
  "Return the exact live tool contract for NAME, optionally in FORMAT.
Include legacy and named-call arguments, aliases, approval metadata, examples
and actual asynchronous support.  Never construct or execute a tool."
  (ogent-agent--output nil format)
  (let ((spec (ogent-tool-spec-get name)))
    (unless spec
      (user-error "%s" (ogent-tool-contract-name-hint
                        name (mapcar (lambda (item) (plist-get item :name)) ogent-tool-registry))))
    (ogent-agent--output (list :contract_version "1" :tool (ogent-agent--tool spec)
                               :result_schema "(ogent-agent-schema 'json)") format)))

(defun ogent-agent-schema (&optional format)
  "Return the JSON Schema for version 1 tool-call results in FORMAT.
Permit additive fields and extension-specific objects under data.  Built-in
file and process data shapes are described in `ogent-agent-guide'."
  (ogent-agent--output
   (list :$schema "https://json-schema.org/draft/2020-12/schema"
         :title "ogent tool result" :type "object"
         :required ["contract_version" "tool" "status" "data" "error" "next"]
         :properties
         (list :contract_version (list :const "1")
               :tool (list :type "string")
               :status (list :enum ["ok" "partial" "error" "denied" "approval_required" "proposed" "done"])
               :data (list :type ["object" "null"])
               :error (list :oneOf
                            (vector (list :type "null")
                                    (list :type "object" :required ["code" "message" "recovery"]
                                          :properties (list :code (list :type "string")
                                                            :message (list :type "string")
                                                            :recovery (list :type "string")))))
               :next (list :type "array"
                           :items (list :type "object" :required ["tool" "args" "snapshot" "call"]
                                        :properties (list :tool (list :type "string")
                                                          :args (list :type "object")
                                                          :snapshot (list :type "string")
                                                          :call (list :type "string")))))
         :additionalProperties t)
   format))

(defun ogent-agent-guide ()
  "Return a paste-ready handbook for agents using ogent's Emacs Lisp SDK."
  (concat
   "ogent agent guide (contract 1)\n"
   "Load ogent normally, then inspect (ogent-agent-capabilities 'json).\n"
   "This reads the live registry; an empty tools array means no tools are installed.\n"
   "(ogent-tools-install-defaults) explicitly installs built-in specs if wanted.\n"
   "Use canonical hyphen names or registered underscore aliases; typos get hints, never execution.\n"
   "Use (ogent-agent-describe \"read\" 'json) for exact call_arguments and examples.\n"
   "Call (ogent-agent-call \"read\" '(:file_path \"README.org\" :limit 40) 'json).\n"
   "Named calls reject unknown/duplicate keys before approval.\n"
   "Native boolean false is nil or :json-false; zero and nested objects are preserved.\n"
   "MCP calls use :json-false for explicit false; optional nil means omit the argument.\n"
   "Named calls return contract_version 1, tool, status, data, error and next.\n"
   "Status ok means success, even for empty files or no matches; error includes code/message/recovery.\n"
   "Legacy ogent-tool-- functions still default to text; optional plist/json selects structured data.\n"
   "Read data: lines[number,column,text,partial], content, ends_with_newline, total_lines, snapshot.\n"
   "Glob data: files[path,size,modified], total_files and snapshot; stable path ordering.\n"
   "Search data: matches[path,line,text,context_before,context_after,truncated], total_matches and snapshot.\n"
   "Search text can be truncated while retaining every returned match's path and line.\n"
   "Read offsets/columns start at 1; search/glob offsets start at 0. Follow (ogent-agent-next RESULT).\n"
   "Continuations freeze absolute targets and refuse changed snapshots. Do not combine different snapshots.\n"
   "A long read line continues at its exact column, retaining all characters over successive pages.\n"
   "Search pages cap at 200 matches and context at 20 lines; GNU fallback uses ERE syntax.\n"
   "(ogent-agent-batch '[(:tool \"files\" :args (:pattern \"**/*.el\")) (:tool \"read\" :args (:file_path \"README.org\"))]) batches reads only.\n"
   "(ogent-agent-call-async \"shell\" '(:command \"pwd\") #'YOUR-CALLBACK) returns a process with one terminal result.\n"
   "Cancel that process with ogent-tool-process-cancel; timeout/cancel retains partial output.\n"
   "(ogent-agent-schema 'json) exports the result envelope JSON Schema.\n"
   "Read: (ogent-tool--read-file \"/path/file\" 1 200); follow the exact next offset in its footer.\n"
   "Search: (ogent-tool--glob \"**/*.el\" \"/path/project\") includes every depth.\n"
   "Grep: (ogent-tool--grep \"-needle\" \"/path/project\"); no matches is success, invalid regex is an error.\n"
   "Edit: old_string must be nonempty and unique; set replace_all to t only for intentional repeated replacement.\n"
   "Read-only tools need no confirmation by default. Writes and shell execution require approval.\n"
   "Programmatic calls never prompt or grant approval: approval_required directs you to the user review flow.\n"
   "Direct ogent-tool-- functions are low-level APIs; use registered execution wrappers for approval enforcement.\n"
   "Shell: use a positive timeout in seconds and an existing working_directory.\n"
   "Shell stdout/stderr may be truncated; the final exit code is preserved.\n"
   "Structured shell data has stdout, stderr, exit_code, signal, timed_out, cancelled and truncated.\n"
   "Nonzero exits have status error; inspect retained data. encoding_loss marks UTF-8 replacements.\n"
   "Local health: (ogent-agent-triage 'json), no provider requests or MCP handshakes.\n"
   "Batch health: (ogent-doctor-batch nil 'json), exit 0=ok/info, 1=warning, 2=error.\n"
   "Check readiness offline: make test; make test-isolation; make offline-test with OGENT_ELPA_DIR.\n"
   "Build/test reports: make test format=json; make lint format=json. Diagnostics stay on stderr.\n"
   "Discover actual build tasks and exits: ./makem.sh --capabilities --json.\n"))

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
