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
