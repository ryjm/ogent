;;; ogent-tool-execution.el --- Bridge gptel tools to ogent policy -*- lexical-binding: t; -*-

;;; Commentary:
;; Give gptel automatic and confirmed calls the same execution owner.

;;; Code:

(require 'cl-lib)
(require 'ogent-tool-approval)
(require 'ogent-ledger)
(require 'ogent-tool-contract)
(declare-function ogent-tool-spec-get "ogent-models")
(declare-function ogent-ui--execute-tool "ogent-ui-toolcalls")
(declare-function ogent-ui--is-edit-tool-p "ogent-ui-toolcalls")
(declare-function ogent-ui--show-diff-for-tool "ogent-ui-toolcalls")
(declare-function ogent-tools--resolve-path "ogent-tools")

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

(defun ogent-tool-execution--success (spec args data)
  "Return a structured terminal result for SPEC, ARGS and DATA."
  (let* ((name (plist-get spec :name))
         (structured (plist-get spec :result-function))
         (code (and structured
                    (cond ((eq (plist-get data :timed_out) t) "timeout")
                          ((eq (plist-get data :cancelled) t) "cancelled")
                          ((and (integerp (plist-get data :exit_code))
                                (/= (plist-get data :exit_code) 0)) "command_failed"))))
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

(defun ogent-tool-execution-call (name args)
  "Execute registered NAME with named ARGS and return a typed result.
Validate before approval.  Never prompt for approval: return approval_required
when policy needs a decision.  Preserve the existing edit review and ledger
owners.  Prefer registered structured result functions when available."
  (let ((phase "unknown_tool") spec canonical schema)
    (condition-case err
        (progn
          (setq spec (ogent-tool-spec-get name))
          (unless spec
            (user-error "%s" (ogent-tool-contract-name-hint
                              name (mapcar (lambda (item) (plist-get item :name))
                                           ogent-tool-registry))))
          (setq name (plist-get spec :name)
                phase "invalid_arguments"
                schema (plist-put (copy-sequence spec) :args
                                  (append (plist-get spec :args)
                                          (plist-get spec :result-args))))
          (let ((values (ogent-tool-contract-values schema args)))
            (setq canonical
                  (cl-loop for argument in (plist-get schema :args)
                           for value in values
                           unless (and (plist-get argument :optional) (null value))
                           append (list (intern (concat ":" (plist-get argument :name))) value))))
          (pcase (ogent-tool-approval-check name canonical t)
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
             (if (ogent-ui--is-edit-tool-p (symbol-name name))
                 (progn
                   (ogent-ui--show-diff-for-tool (symbol-name name) canonical)
                   (ogent-tool-execution-result name "proposed" (list :review_required t)))
               (let ((data (ogent-ui--execute-tool name canonical t)))
                 (ogent-tool-execution--success spec canonical data))))))
      (error (ogent-tool-execution-result name "error" nil
                                          (pcase (car err)
                                            ('ogent-tool-process-search-timeout "timeout")
                                            ('ogent-tool-process-search-cancelled "cancelled")
                                            ('ogent-tool-process-start-failed "process_start_failed")
                                            ('ogent-tool-process-unavailable "dependency_missing")
                                            ('ogent-tool-process-output-error "unsupported_output")
                                            ('ogent-tool-process-search-failed "search_failed")
                                            (_ phase))
                                          (error-message-string err))))))

(defun ogent-tool-execution-wrapper (spec)
  "Return a gptel function enforcing policy and ledger recording for SPEC.
Adapt gptel's callback-first convention to ogent's callback-last async specs.
Reject stale tool objects after registry removal or schema replacement."
  ;; Preserve the function's closure environment when copying metadata.
  (let ((name (plist-get spec :name))
        (snapshot (plist-put (copy-tree spec) :function (plist-get spec :function))))
    (lambda (&rest values)
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
          result)))))

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
