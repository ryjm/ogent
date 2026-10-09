;;; gptel-encoding.el --- Offline actual transport serialization -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'jka-compr)
(setq load-suffixes (remove ".elc" load-suffixes))
(dolist (directory (directory-files (getenv "REFRESH_ELPA") t "^[^.].*"))
  (when (file-directory-p directory) (add-to-list 'load-path directory)))
(add-to-list 'load-path "/tmp/gptel-minimum")
(load-file "/tmp/gptel-minimum/gptel.el")
(require 'gptel-request)
(require 'gptel-openai)
(load-file "/work/test/ogent-test-helper.el")
(require 'ogent-tools)
(require 'ogent-agent)
(let* ((root (ogent-test--provision-store-directory 'tools))
       (file (expand-file-name "café.txt" root))
       (ogent-tools-project-root root) (ogent-ledger-enabled nil)
       (ogent-tool-registry (copy-tree ogent-tools-default-registry))
       (ogent--tools-registered nil) (ogent--tool-specs-registered nil)
       (ogent--tool-formats-registered nil) (gptel--known-tools nil)
       (ogent-tools-result-format 'json)
       (backend (gptel-make-openai "offline-encoding-check"
                                 :host "offline.invalid" :key "unused-local-fixture"
                                 :models '(offline-model))))
  (unwind-protect
      (progn
        (with-temp-file file (insert "alpha λ 😀\n"))
        (let* ((tool (ogent-tool-get "read_file"))
               (result (funcall (gptel-tool-function tool) file 1 1))
               (call (list :id "offline-call-1" :name "read-file" :args (list :file_path file)))
               ;; A second pending call prevents FSM advancement/HTTP dispatch.
               (pending (list :id "offline-not-executed" :name "read-file"))
               (fsm (gptel-make-fsm :info (list :backend backend :tool-use (list call pending))))
               (coding-system-for-write 'utf-8-unix))
          (gptel--process-tool-call fsm tool call result)
          (let* ((content (plist-get call :result))
                 (prompts (gptel--parse-tool-results backend (list call)))
                 (record
                  (condition-case err
                      (let* ((request-json (gptel--json-encode
                                            (list :model "offline-model" :messages (vconcat prompts))))
                             (parsed (json-parse-string request-json :object-type 'plist))
                             (transport-content (plist-get (aref (plist-get parsed :messages) 0) :content)))
                        (list :status "encoded" :content_preserved (equal transport-content content)))
                    (error (list :status "error" :condition (symbol-name (car err))
                                 ;; Avoid serializing the invalid raw-string payload of ERR.
                                 :condition_type (if (symbolp (cadr err)) (symbol-name (cadr err)) "other"))))))
            (princ (json-serialize
                    (list :probe "actual-gptel-offline-tool-result-request-encoding"
                          :emacs emacs-version :tool_source (symbol-file 'ogent-tool-execution-json)
                          :constructor_source (symbol-file 'gptel-make-tool)
                          :tool_result_multibyte (if (multibyte-string-p result) t :json-false)
                          :gptel_content_multibyte (if (multibyte-string-p content) t :json-false)
                          :same_object_after_process_tool_call (eq result content)
                          :actual_serializer record :provider_requests 0)
                    :false-object :json-false))
            (terpri))))
    (delete-directory root t)))
