;;; probe_ledger_context.el --- Real relative ledger and settings checks -*- lexical-binding: t; -*-
(require 'ogent-tools)
(require 'ogent-agent)
(require 'ogent-ui-toolcalls)
(require 'json)
(setq coding-system-for-write 'utf-8-unix)
(defun scorerB-ledger-types (file)
  (if (not (file-exists-p file)) []
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let (types)
        (while (search-forward "#+begin_src emacs-lisp\n" nil t)
          (push (symbol-name (plist-get (read (current-buffer)) :type)) types))
        (vconcat (nreverse types))))))
(defun scorerB-context-emit (name function)
  (let ((result (condition-case error
                    (list :status "returned" :value (funcall function))
                  (error (list :status "signalled" :condition (format "%s" (car error))
                               :message (error-message-string error))))))
    (princ (concat (json-serialize (list :probe name :result result)
                                   :null-object :json-null :false-object :json-false) "\n"))))
(let* ((root (ogent-test--provision-store-directory 'tools))
       (project-a (file-name-as-directory (expand-file-name "project-a" root)))
       (project-b (file-name-as-directory (expand-file-name "project-b" root)))
       (effects '((:kind read :target file :scope workspace :risk low))))
  (make-directory project-a)
  (make-directory project-b)
  (scorerB-context-emit
   "sdk-project-switch-and-future-settings"
   (lambda ()
     (let* ((default-directory project-a)
            (ogent-ledger-file "relative-sdk.org") (ogent-ledger-enabled t)
            (calls 0)
            (spec (list :name 'switch-sdk :description "Switch local fixture context"
                        :args nil :effects effects
                        :function (lambda ()
                                    (cl-incf calls)
                                    (setq default-directory project-b
                                          ogent-ledger-file "future-sdk.org"
                                          ogent-ledger-enabled nil)
                                    "SDK switched")))
            (ogent-tool-registry (list spec))
            (first (ogent-agent-call "switch-sdk" nil))
            (disabled (ogent-agent-call "switch-sdk" nil))
            (disabled-file-exists (file-exists-p (expand-file-name "future-sdk.org" project-b))))
       (setq ogent-ledger-enabled t)
       (let ((future (ogent-agent-call "switch-sdk" nil)))
         (list :calls calls :first first :disabled disabled :future future
               :first_types (scorerB-ledger-types (expand-file-name "relative-sdk.org" project-a))
               :wrong_project_types (scorerB-ledger-types (expand-file-name "relative-sdk.org" project-b))
               :disabled_future_file_exists (if disabled-file-exists t :json-false)
               :future_types (scorerB-ledger-types (expand-file-name "future-sdk.org" project-b))
               :caller_project_is_b (if (equal default-directory project-b) t :json-false)
               :caller_file ogent-ledger-file :caller_enabled_nil (if (null ogent-ledger-enabled) t :json-false))))))
  (scorerB-context-emit
   "json-wrapper-relative-destination-survives-project-switch"
   (lambda ()
     (let* ((default-directory project-a)
            (ogent-ledger-file "relative-json.org") (ogent-ledger-enabled t)
            (spec (list :name 'switch-json :description "JSON local context switch"
                        :args nil :effects effects
                        :function (lambda ()
                                    (setq default-directory project-b
                                          ogent-ledger-file "future-json.org"
                                          ogent-ledger-enabled nil)
                                    "JSON switched")))
            (ogent-tool-registry (list spec))
            (reply (funcall (ogent-tool-execution-wrapper spec 'json))))
       (list :reply reply
             :first_types (scorerB-ledger-types (expand-file-name "relative-json.org" project-a))
             :wrong_project_types (scorerB-ledger-types (expand-file-name "relative-json.org" project-b))
             :future_types (scorerB-ledger-types (expand-file-name "future-json.org" project-b))
             :caller_file ogent-ledger-file :caller_enabled_nil (if (null ogent-ledger-enabled) t :json-false)))))
  (scorerB-context-emit
   "legacy-async-relative-destination-survives-project-switch"
   (lambda ()
     (let* ((default-directory project-a)
            (ogent-ledger-file "relative-legacy.org") (ogent-ledger-enabled t)
            (callbacks 0) terminal
            (spec (list :name 'switch-legacy :description "Legacy local async context switch"
                        :async t :args nil :effects effects
                        :function (lambda (callback)
                                    (setq default-directory project-b
                                          ogent-ledger-file "future-legacy.org"
                                          ogent-ledger-enabled nil)
                                    (funcall callback "legacy switched")
                                    :arbitrary-return)))
            (ogent-tool-registry (list spec)))
       (funcall (ogent-tool-execution-wrapper spec 'text)
                (lambda (result) (cl-incf callbacks) (setq terminal result)))
       (list :callbacks callbacks :terminal terminal
             :first_types (scorerB-ledger-types (expand-file-name "relative-legacy.org" project-a))
             :wrong_project_types (scorerB-ledger-types (expand-file-name "relative-legacy.org" project-b))
             :future_types (scorerB-ledger-types (expand-file-name "future-legacy.org" project-b))
             :caller_file ogent-ledger-file :caller_enabled_nil (if (null ogent-ledger-enabled) t :json-false)))))
  (delete-directory root t))
