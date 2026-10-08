;;; ogent-tool-execution.el --- Bridge gptel tools to ogent policy -*- lexical-binding: t; -*-

;;; Commentary:
;; Give gptel automatic and confirmed calls the same execution owner.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'ogent-tool-approval)
(require 'ogent-ledger)
(require 'ogent-tool-contract)
(declare-function ogent-tool-spec-get "ogent-models")
(declare-function ogent-ui--execute-tool "ogent-ui-toolcalls")
(declare-function ogent-ui--is-edit-tool-p "ogent-ui-toolcalls")
(declare-function ogent-ui--show-diff-for-tool "ogent-ui-toolcalls")
(declare-function ogent-tools--resolve-path "ogent-tools")
(defvar ogent-tools-result-format 'text)
(defvar ogent-tool-registry)

(defun ogent-tool-execution-result (name status &optional data code message)
  "Return a versioned result for NAME with STATUS and DATA.
Include a typed error with CODE and MESSAGE when supplied."
  (list :contract_version "1" :tool (format "%s" name) :status status
        :data (or data :json-null)
        :error (if code (list :code code :message message
                              :recovery
                              (pcase code
				("unknown_tool" "Call ogent-agent-capabilities to inspect available names and aliases")
				("invalid_arguments" (format "Call (ogent-agent-describe %S) for the declared arguments" (format "%s" name)))
				((or "denied" "approval_required") "Use the normal user approval/review flow; do not retry with relaxed policy")
				("snapshot_changed" "Restart the original read/search call from its first page")
				((or "command_failed" "timeout" "cancelled") "Inspect retained stdout/stderr and exit_code before deciding whether to retry")
				(_ "Inspect the error message and tool contract before retrying")))
                 :json-null)
        :next []))

(defun ogent-tool-execution-json (data)
  "Serialize result DATA, returning a typed error for unsupported values.
Preserve callback delivery even when an extension returns non-JSON objects
or raw filename bytes that cannot be represented as Unicode."
  (condition-case nil
      (concat (json-serialize data :null-object :json-null :false-object :json-false) "\n")
    (error
     (concat (json-serialize
              (ogent-tool-execution-result
               "serialization" "error" nil "unsupported_output"
               "Result cannot be represented as JSON; use Unicode filenames and JSON-compatible tool values")
              :null-object :json-null :false-object :json-false) "\n"))))

(defun ogent-tool-execution-process-error (data)
  "Return the stable failure code for process DATA, or nil on success."
  (cond ((eq (plist-get data :timed_out) t) "timeout")
        ((eq (plist-get data :cancelled) t) "cancelled")
        ((and (integerp (plist-get data :exit_code))
              (/= (plist-get data :exit_code) 0)) "command_failed")))

(defun ogent-tool-execution--success (spec args data)
  "Return a structured terminal result for SPEC, ARGS and DATA."
  (let* ((name (plist-get spec :name))
         (structured (plist-get spec :result-function))
         (code (and structured (ogent-tool-execution-process-error data)))
         (result (ogent-tool-execution-result
                  name (if code "error" "ok")
                  (if structured data (list :value data)) code
                  (when code "Inspect stdout, stderr and exit_code; correct the command or increase its timeout before retrying"))))
    (when (and structured (eq (plist-get data :has_more) t))
      (let ((next-args (copy-sequence args)))
        (setq next-args (plist-put next-args :offset (plist-get data :next_offset)))
        (when (memq name '(read-file glob grep))
          (setq next-args
                (plist-put next-args (if (eq name 'read-file) :file_path :path)
                           (or (plist-get data :path)
                               (ogent-tools--resolve-path (or (plist-get args :path) "."))))))
        (when (eq name 'read-file)
          (setq next-args (plist-put next-args :column (plist-get data :next_column))))
        (let ((print-length nil) (print-level nil))
          (setq result
                (plist-put result :next
                           (vector (list :tool (symbol-name name) :args next-args
                                         :snapshot (plist-get data :snapshot)
                                         :call (prin1-to-string
                                                (list 'ogent-agent-call (symbol-name name)
                                                      (list 'quote next-args))))))))))
    result))

(defun ogent-tool-execution--schema (spec)
  "Return SPEC's named structured argument schema."
  (plist-put (copy-sequence spec) :args
             (append (plist-get spec :args) (plist-get spec :result-args))))

(defun ogent-tool-execution-snapshot (spec)
  "Copy registry SPEC metadata while preserving callable closure identity."
  (let ((snapshot (copy-tree spec t)))
    (dolist (key '(:function :async-function :result-function :result-async-function))
      (when (plist-member spec key)
        (setq snapshot (plist-put snapshot key (plist-get spec key)))))
    snapshot))

(defun ogent-tool-execution--failure (name code err)
  "Return a typed failure for NAME from ERR, defaulting to CODE."
  (ogent-tool-execution-result
   name "error" nil
   (pcase (car-safe err)
     ('ogent-tool-process-search-timeout "timeout")
     ('ogent-tool-process-search-cancelled "cancelled")
     ('ogent-tool-process-start-failed "process_start_failed")
     ('ogent-tool-process-unavailable "dependency_missing")
     ('ogent-tool-process-output-error "unsupported_output")
     ('ogent-tool-results-output-error "unsupported_output")
     ('ogent-tool-process-search-failed "search_failed")
     (_ code))
   (if (consp err) (error-message-string err) (format "%s" err))))

(defun ogent-tool-execution--start (spec args values callback)
  "Start asynchronous SPEC with ARGS, VALUES and terminal CALLBACK.
Record exactly one ledger terminal even if the tool completes twice or fails
after completion.  Adapt native callback-last tools to the result contract."
  (let* ((name (plist-get spec :name))
         (call (list :name (symbol-name name) :args args))
         (effects (plist-get spec :effects))
         (function (or (plist-get spec :result-async-function) (plist-get spec :function)))
         (started (float-time)) finished
         (complete (lambda (data &optional failure)
                     (unless finished
                       (setq finished t)
                       (let ((result (if failure
                                         (ogent-tool-execution--failure name "execution_failed" failure)
                                       (ogent-tool-execution--success spec args data))))
                         (ogent-ledger-record-tool-finish
                          call data (unless (eq (plist-get result :error) :json-null)
                                      (plist-get (plist-get result :error) :message))
                          (- (float-time) started) effects)
                         (funcall callback result))))))
    (ogent-ledger-record-tool-start call effects)
    (condition-case err
        (apply function (append values (list complete)))
      (error (funcall complete nil err) nil))))

(defun ogent-tool-execution-call (name args &optional callback prompt)
  "Execute registered NAME with named ARGS and return a typed result.
Validate before approval.  Never prompt for approval: return approval_required
when policy needs a decision.  Preserve the existing edit review and ledger
owners.  Prefer registered structured result functions when available.
When CALLBACK is non-nil, call it once with the terminal result and return
the process for asynchronous tools.  Other tools can complete immediately.
PROMPT is reserved for the normal interactive gptel execution path."
  (when (and callback (not (functionp callback)))
    (user-error "Provide a function callback accepting one terminal result"))
  (let ((phase "unknown_tool") spec canonical schema deferred delivered)
    (cl-labels ((deliver (result)
                  (unless delivered
                    (setq delivered t)
                    (funcall callback result))))
      (let ((result
             (condition-case err
		 (progn
		   (setq spec (ogent-tool-execution-snapshot (ogent-tool-spec-get name)))
		   (unless spec
		     (user-error "%s" (ogent-tool-contract-name-hint
				       name (mapcar (lambda (item) (plist-get item :name))
						    ogent-tool-registry))))
		   (setq name (plist-get spec :name)
			 phase "invalid_arguments"
			 schema (ogent-tool-execution--schema spec))
		   (let ((values (ogent-tool-contract-values schema args)))
		     (setq canonical
			   (cl-loop for argument in (plist-get schema :args)
				    for value in values
				    unless (and (plist-get argument :optional) (null value))
				    append (list (intern (concat ":" (plist-get argument :name))) value))))
		   (when (and (plist-get spec :async) (not callback))
		     (setq phase "async_required")
		     (user-error "This tool requires ogent-agent-call-async with a terminal callback"))
		   (pcase (ogent-tool-approval-check name canonical (not prompt))
		     ('required
		      (ogent-tool-execution-result
		       name "approval_required" nil "approval_required"
		       "This call needs user approval under the current effects policy; use the normal tool review flow or an existing explicit allow rule"))
		     ('denied
		      (ogent-tool-execution-result
		       name "denied" nil "denied" "Current approval policy denies this tool; ask the user to review the decision"))
		     (_
		      (setq phase "unavailable")
		      (unless (equal spec (ogent-tool-spec-get name))
			(user-error "Registry entry changed before execution; rediscover the tool and retry"))
		      (require 'ogent-ui-toolcalls)
		      (setq phase "execution_failed")
		      (cond
		       ((ogent-ui--is-edit-tool-p (symbol-name name))
			(progn
			  (ogent-ui--show-diff-for-tool (symbol-name name) canonical)
			  (ogent-tool-execution-result name "proposed" (list :review_required t))))
		       ((and callback (or (plist-get spec :result-async-function)
					  (plist-get spec :async)))
			(setq deferred t)
			(ogent-tool-execution--start
			 spec canonical (ogent-tool-contract-values schema canonical) #'deliver))
		       (t
			(let ((data (ogent-ui--execute-tool name canonical t)))
			  (ogent-tool-execution--success spec canonical data)))))))
               (error
                (setq deferred nil)
                (ogent-tool-execution--failure name phase err)))))
        (if (and callback (not deferred)) (progn (deliver result) nil) result)))))

(defun ogent-tool-execution--json-call (spec values)
  "Execute snapshot SPEC with gptel VALUES and return versioned JSON."
  (let* ((name (plist-get spec :name))
         (async (plist-get spec :async))
         (callback (and async (pop values))) delivered)
    (when (and async (not (functionp callback)))
      (user-error "Async tool %s requires a callback first" name))
    (cl-labels ((serialize (result) (ogent-tool-execution-json result))
                (deliver (result)
                  (unless delivered
                    (setq delivered t)
                    (funcall callback (serialize result)))))
      (condition-case err
          (let* ((schema (ogent-tool-execution--schema spec))
                 (values (ogent-tool-contract-validate-values schema values))
                 (args (cl-loop for arg in (plist-get schema :args)
                                for value in values
                                unless (and (plist-get arg :optional) (null value))
                                append (list (intern (concat ":" (plist-get arg :name))) value))))
            (if (not (equal spec (ogent-tool-spec-get name)))
                (let ((result (ogent-tool-execution-result
                               name "error" nil "unavailable" "Tool registry entry changed; rediscover before retrying")))
                  (if async (deliver result) (serialize result)))
              (if async
                  (ogent-tool-execution-call name args #'deliver t)
                (serialize (ogent-tool-execution-call name args nil t)))))
        (error
         (let ((result (ogent-tool-execution--failure name "invalid_arguments" err)))
           (if async (deliver result) (serialize result))))))))

(defun ogent-tool-execution-wrapper (spec &optional result-format)
  "Return a gptel function enforcing policy and ledger recording for SPEC.
Adapt gptel's callback-first convention to ogent's callback-last async specs.
Reject stale tool objects after registry removal or schema replacement.
Capture RESULT-FORMAT, defaulting to `ogent-tools-result-format'."
  ;; Preserve the function's closure environment when copying metadata.
  (let ((name (plist-get spec :name))
        (format (or result-format ogent-tools-result-format))
        (snapshot (ogent-tool-execution-snapshot spec)))
    (lambda (&rest values)
      (if (eq format 'json)
          (ogent-tool-execution--json-call snapshot values)
	(let* ((async (plist-get snapshot :async))
               (callback (and async (pop values)))
               args
               (result
		(condition-case err
                    (progn
                      (when (and async (not (functionp callback)))
			(user-error "Async tool %s requires a callback first; pass the result callback before arguments" name))
                      (setq values (ogent-tool-contract-validate-values snapshot values)
                            args (cl-loop for arg in (plist-get snapshot :args)
                                          for value in values
                                          unless (and (plist-get arg :optional) (null value))
                                          append (list (intern (concat ":" (plist-get arg :name)))
                                                       value)))
                      (cond
		       ((not (equal snapshot (ogent-tool-spec-get name)))
			"Tool unavailable: its registry entry changed or was removed")
		       ((not (eq (ogent-tool-approval-check name args) 'approved))
			"Tool execution denied by user")
		       ((not (equal snapshot (ogent-tool-spec-get name)))
			"Tool unavailable: its registry entry changed during approval")
		       (t
			(require 'ogent-ui-toolcalls)
			(cond
			 ((ogent-ui--is-edit-tool-p (symbol-name name))
			  (ogent-ui--show-diff-for-tool (symbol-name name) args)
			  "Edit proposed for user review")
			 (async
			  (ogent-tool-execution--async snapshot args values callback)
			  :async)
			 (t (ogent-ui--execute-tool name args))))))
                  (error (concat "Tool error: " (error-message-string err))))))
          (when (and async (not (functionp callback)))
            (user-error "Async tool %s requires a callback first; pass the result callback before arguments" name))
          (if async
              (unless (eq result :async) (funcall callback result))
            result))))))

(defun ogent-tool-execution--async (spec args values callback)
  "Execute async SPEC with ARGS, positional VALUES and gptel CALLBACK."
  (let* ((call (list :name (symbol-name (plist-get spec :name)) :args args))
         (effects (plist-get spec :effects))
         (started (float-time))
         (finished nil)
         (complete (lambda (result &optional failure)
                     (unless finished
                       (setq finished t)
                       (ogent-ledger-record-tool-finish
                        call result failure (- (float-time) started) effects)
                       (funcall callback (or result (concat "Tool error: " failure)))))))
    (ogent-ledger-record-tool-start call effects)
    (condition-case err
        (apply (plist-get spec :function) (append values (list complete)))
      (error (funcall complete nil (error-message-string err))))))

(provide 'ogent-tool-execution)
;;; ogent-tool-execution.el ends here
