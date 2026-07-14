;;; ogent-mcp-tests.el --- Tests for ogent-mcp -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the MCP (Model Context Protocol) client implementation.
;; Focuses on:
;; - JSON-RPC message creation and parsing
;; - Tool registration and schema conversion
;; - Server configuration management
;; - Connection state management

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-mcp)
(require 'ogent-models)
(require 'ogent-tool-effects)

;;; JSON-RPC Protocol Tests

(ert-deftest ogent-mcp--next-id-increments ()
  "ogent-mcp--next-id should return incrementing IDs."
  (let ((ogent-mcp--request-id 0))
    (should (= 1 (ogent-mcp--next-id)))
    (should (= 2 (ogent-mcp--next-id)))
    (should (= 3 (ogent-mcp--next-id)))))

(ert-deftest ogent-mcp--next-id-starts-from-current ()
  "ogent-mcp--next-id should increment from current value."
  (let ((ogent-mcp--request-id 100))
    (should (= 101 (ogent-mcp--next-id)))
    (should (= 102 (ogent-mcp--next-id)))))

(ert-deftest ogent-mcp--encode-message-produces-json ()
  "ogent-mcp--encode-message should produce valid JSON with newline."
  (let ((msg '((jsonrpc . "2.0") (method . "test"))))
    (let ((encoded (ogent-mcp--encode-message msg)))
      (should (stringp encoded))
      (should (string-suffix-p "\n" encoded))
      ;; Should be parseable JSON
      (let ((parsed (json-read-from-string (string-trim encoded))))
        (should (equal "2.0" (alist-get 'jsonrpc parsed)))
        (should (equal "test" (alist-get 'method parsed)))))))

(ert-deftest ogent-mcp--encode-message-handles-nested-objects ()
  "ogent-mcp--encode-message should handle nested structures."
  (let ((msg '((jsonrpc . "2.0")
               (params . ((name . "test")
                          (options . ((debug . t))))))))
    (let* ((encoded (ogent-mcp--encode-message msg))
           (parsed (json-read-from-string (string-trim encoded))))
      (should (equal "test" (alist-get 'name (alist-get 'params parsed)))))))

(ert-deftest ogent-mcp--make-request-creates-valid-structure ()
  "ogent-mcp--make-request should create proper JSON-RPC request."
  (let ((ogent-mcp--request-id 0))
    (let ((req (ogent-mcp--make-request "tools/list")))
      (should (equal "2.0" (alist-get 'jsonrpc req)))
      (should (equal "tools/list" (alist-get 'method req)))
      (should (numberp (alist-get 'id req)))
      (should (= 1 (alist-get 'id req))))))

(ert-deftest ogent-mcp--make-request-includes-params ()
  "ogent-mcp--make-request should include params when provided."
  (let ((ogent-mcp--request-id 0))
    (let ((req (ogent-mcp--make-request "tools/call"
                                        '((name . "read_file")
                                          (path . "/tmp/test")))))
      (should (alist-get 'params req))
      (should (equal "read_file" (alist-get 'name (alist-get 'params req)))))))

(ert-deftest ogent-mcp--make-request-omits-params-when-nil ()
  "ogent-mcp--make-request should omit params when nil."
  (let ((ogent-mcp--request-id 0))
    (let ((req (ogent-mcp--make-request "ping" nil)))
      (should-not (assq 'params req)))))

(ert-deftest ogent-mcp--make-notification-creates-valid-structure ()
  "ogent-mcp--make-notification should create proper JSON-RPC notification."
  (let ((notif (ogent-mcp--make-notification "notifications/initialized")))
    (should (equal "2.0" (alist-get 'jsonrpc notif)))
    (should (equal "notifications/initialized" (alist-get 'method notif)))
    ;; Notifications should NOT have an id
    (should-not (assq 'id notif))))

(ert-deftest ogent-mcp--make-notification-includes-params ()
  "ogent-mcp--make-notification should include params when provided."
  (let ((notif (ogent-mcp--make-notification "notifications/message"
                                             '((level . "info")
                                               (message . "Hello")))))
    (should (alist-get 'params notif))
    (should (equal "info" (alist-get 'level (alist-get 'params notif))))))

(ert-deftest ogent-mcp--parse-message-parses-valid-json ()
  "ogent-mcp--parse-message should parse valid JSON."
  (let ((result (ogent-mcp--parse-message "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}")))
    (should result)
    (should (equal "2.0" (alist-get 'jsonrpc result)))
    (should (= 1 (alist-get 'id result)))))

(ert-deftest ogent-mcp--parse-message-returns-nil-on-invalid-json ()
  "ogent-mcp--parse-message should return nil for invalid JSON."
  (let ((message-log nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-log (apply #'format fmt args)))))
      (should-not (ogent-mcp--parse-message "not valid json"))
      (should (string-match-p "Failed to parse" message-log)))))

(ert-deftest ogent-mcp--parse-message-handles-empty-string ()
  "ogent-mcp--parse-message should handle empty string."
  (cl-letf (((symbol-function 'message) #'ignore))
    (should-not (ogent-mcp--parse-message ""))))

(ert-deftest ogent-mcp--parse-message-handles-complex-result ()
  "ogent-mcp--parse-message should handle complex nested results."
  (let* ((json-str "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[{\"name\":\"read\",\"description\":\"Read file\"}]}}")
         (result (ogent-mcp--parse-message json-str)))
    (should result)
    (let* ((tools-result (alist-get 'result result))
           (tools (alist-get 'tools tools-result)))
      (should (vectorp tools))
      (should (= 1 (length tools)))
      (should (equal "read" (alist-get 'name (aref tools 0)))))))

(ert-deftest ogent-mcp--array-to-list-converts-json-vectors ()
  "JSON arrays decoded as vectors are normalized to lists."
  (should (equal '("a" "b") (ogent-mcp--array-to-list ["a" "b"])))
  (should (equal '("a") (ogent-mcp--array-to-list '("a"))))
  (should-not (ogent-mcp--array-to-list nil)))

(ert-deftest ogent-mcp--json-true-p-rejects-json-false ()
  "JSON false is not treated as truthy."
  (should (ogent-mcp--json-true-p t))
  (should-not (ogent-mcp--json-true-p :json-false))
  (should-not (ogent-mcp--json-true-p nil)))

;;; Schema Conversion Tests

(ert-deftest ogent-mcp--schema-to-args-converts-properties ()
  "ogent-mcp--schema-to-args should convert properties to args format."
  (let ((schema '((type . "object")
                  (properties . ((path . ((type . "string")
                                          (description . "File path")))
                                 (encoding . ((type . "string")
                                              (description . "Encoding")))))
                  (required . ["path"]))))
    (let ((args (ogent-mcp--schema-to-args schema)))
      (should (= 2 (length args)))
      ;; Find path arg
      (let ((path-arg (cl-find-if (lambda (a) (equal "path" (plist-get a :name))) args)))
        (should path-arg)
        (should (equal "string" (plist-get path-arg :type)))
        (should (equal "File path" (plist-get path-arg :description)))
        (should-not (plist-get path-arg :optional)))
      ;; Find encoding arg (optional)
      (let ((enc-arg (cl-find-if (lambda (a) (equal "encoding" (plist-get a :name))) args)))
        (should enc-arg)
        (should (plist-get enc-arg :optional))))))

(ert-deftest ogent-mcp--schema-to-args-handles-empty-schema ()
  "ogent-mcp--schema-to-args should handle schema with no properties."
  (let ((schema '((type . "object"))))
    (should (null (ogent-mcp--schema-to-args schema)))))

(ert-deftest ogent-mcp--schema-to-args-handles-nil-schema ()
  "ogent-mcp--schema-to-args should handle nil schema."
  (should (null (ogent-mcp--schema-to-args nil))))

(ert-deftest ogent-mcp--schema-to-args-uses-string-as-default-type ()
  "ogent-mcp--schema-to-args should use 'string' as default type."
  (let ((schema '((properties . ((name . ((description . "Name"))))))))
    (let ((args (ogent-mcp--schema-to-args schema)))
      (should (= 1 (length args)))
      (should (equal "string" (plist-get (car args) :type))))))

(ert-deftest ogent-mcp--schema-to-args-handles-array-types ()
  "ogent-mcp--schema-to-args should handle array types."
  (let ((schema '((properties . ((files . ((type . "array")
                                           (description . "List of files"))))))))
    (let ((args (ogent-mcp--schema-to-args schema)))
      (should (= 1 (length args)))
      (should (equal "array" (plist-get (car args) :type))))))

;;; Argument Conversion Tests

(ert-deftest ogent-mcp--args-to-alist-converts-plist ()
  "ogent-mcp--args-to-alist should convert plist to alist."
  (let ((args '(:path "/tmp/test" :encoding "utf-8")))
    (let ((result (ogent-mcp--args-to-alist args)))
      (should (= 2 (length result)))
      (should (equal "/tmp/test" (alist-get 'path result)))
      (should (equal "utf-8" (alist-get 'encoding result))))))

(ert-deftest ogent-mcp--args-to-alist-handles-empty ()
  "ogent-mcp--args-to-alist should handle empty args."
  (should (null (ogent-mcp--args-to-alist nil))))

(ert-deftest ogent-mcp--args-to-alist-handles-single-pair ()
  "ogent-mcp--args-to-alist should handle single key-value pair."
  (let ((result (ogent-mcp--args-to-alist '(:name "test"))))
    (should (= 1 (length result)))
    (should (equal "test" (alist-get 'name result)))))

(ert-deftest ogent-mcp--args-to-alist-skips-non-keywords ()
  "ogent-mcp--args-to-alist should skip non-keyword keys."
  (let ((result (ogent-mcp--args-to-alist '(:valid "yes" "invalid" "no"))))
    (should (= 1 (length result)))
    (should (equal "yes" (alist-get 'valid result)))))

(ert-deftest ogent-mcp--args-to-alist-preserves-order ()
  "ogent-mcp--args-to-alist should preserve argument order."
  (let ((result (ogent-mcp--args-to-alist '(:a 1 :b 2 :c 3))))
    (should (= 3 (length result)))
    (should (equal '((a . 1) (b . 2) (c . 3)) result))))

;;; Content Extraction Tests

(ert-deftest ogent-mcp--extract-text-content-extracts-text ()
  "ogent-mcp--extract-text-content should extract text from content array."
  (let ((content [((type . "text") (text . "Hello world"))]))
    (should (equal "Hello world" (ogent-mcp--extract-text-content content)))))

(ert-deftest ogent-mcp--extract-text-content-joins-multiple ()
  "ogent-mcp--extract-text-content should join multiple text items."
  (let ((content [((type . "text") (text . "Line 1"))
                  ((type . "text") (text . "Line 2"))]))
    (should (equal "Line 1\nLine 2" (ogent-mcp--extract-text-content content)))))

(ert-deftest ogent-mcp--extract-text-content-ignores-non-text ()
  "ogent-mcp--extract-text-content should ignore non-text content."
  (let ((content [((type . "image") (data . "base64data"))
                  ((type . "text") (text . "Caption"))]))
    (should (equal "Caption" (ogent-mcp--extract-text-content content)))))

(ert-deftest ogent-mcp--extract-text-content-handles-empty ()
  "ogent-mcp--extract-text-content should handle empty array."
  (should (equal "" (ogent-mcp--extract-text-content []))))

(ert-deftest ogent-mcp--extract-text-content-handles-nil ()
  "ogent-mcp--extract-text-content should handle nil."
  (should (equal "" (ogent-mcp--extract-text-content nil))))

;;; Server Configuration Tests

(ert-deftest ogent-mcp-add-server-adds-to-list ()
  "ogent-mcp-add-server should add server configuration."
  (let ((ogent-mcp-servers nil))
    (ogent-mcp-add-server "test-server" "node" '("server.js"))
    (should (= 1 (length ogent-mcp-servers)))
    (let ((config (cdr (assoc "test-server" ogent-mcp-servers))))
      (should (equal "node" (plist-get config :command)))
      (should (equal '("server.js") (plist-get config :args))))))

(ert-deftest ogent-mcp-add-server-includes-env ()
  "ogent-mcp-add-server should include environment variables."
  (let ((ogent-mcp-servers nil))
    (ogent-mcp-add-server "test" "cmd" '() '(("DEBUG" . "1")))
    (let ((config (cdr (assoc "test" ogent-mcp-servers))))
      (should (equal '(("DEBUG" . "1")) (plist-get config :env))))))

(ert-deftest ogent-mcp-add-server-includes-auto-connect ()
  "ogent-mcp-add-server should include auto-connect flag."
  (let ((ogent-mcp-servers nil))
    (ogent-mcp-add-server "test" "cmd" '() nil t)
    (let ((config (cdr (assoc "test" ogent-mcp-servers))))
      (should (eq t (plist-get config :auto-connect))))))

(ert-deftest ogent-mcp-add-server-replaces-existing ()
  "ogent-mcp-add-server should replace existing server with same name."
  (let ((ogent-mcp-servers '(("test" :command "old" :args ("old.js")))))
    (ogent-mcp-add-server "test" "new" '("new.js"))
    (should (= 1 (length ogent-mcp-servers)))
    (let ((config (cdr (assoc "test" ogent-mcp-servers))))
      (should (equal "new" (plist-get config :command)))
      (should (equal '("new.js") (plist-get config :args))))))

(ert-deftest ogent-mcp-add-server-preserves-others ()
  "ogent-mcp-add-server should preserve other server configs."
  (let ((ogent-mcp-servers '(("server1" :command "cmd1" :args ()))))
    (ogent-mcp-add-server "server2" "cmd2" '())
    (should (= 2 (length ogent-mcp-servers)))
    (should (assoc "server1" ogent-mcp-servers))
    (should (assoc "server2" ogent-mcp-servers))))

;;; Connection Structure Tests

(ert-deftest ogent-mcp-connection-struct-fields ()
  "ogent-mcp-connection struct should have expected fields."
  (let ((conn (make-ogent-mcp-connection
               :name "test"
               :status 'connecting
               :buffer "")))
    (should (equal "test" (ogent-mcp-connection-name conn)))
    (should (eq 'connecting (ogent-mcp-connection-status conn)))
    (should (equal "" (ogent-mcp-connection-buffer conn)))
    ;; Unset fields should be nil
    (should-not (ogent-mcp-connection-process conn))
    (should-not (ogent-mcp-connection-capabilities conn))
    (should-not (ogent-mcp-connection-tools conn))))

(ert-deftest ogent-mcp-connection-struct-mutable ()
  "ogent-mcp-connection fields should be mutable."
  (let ((conn (make-ogent-mcp-connection :status 'connecting)))
    (setf (ogent-mcp-connection-status conn) 'ready)
    (should (eq 'ready (ogent-mcp-connection-status conn)))
    (setf (ogent-mcp-connection-tools conn) '(tool1 tool2))
    (should (equal '(tool1 tool2) (ogent-mcp-connection-tools conn)))))

;;; Message Handling Tests

(ert-deftest ogent-mcp--handle-message-calls-callback-on-response ()
  "ogent-mcp--handle-message should call pending callback for responses."
  (let ((ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (callback-result nil)
        (callback-error nil))
    (puthash 1 (lambda (result error)
                 (setq callback-result result
                       callback-error error))
             ogent-mcp--pending-requests)
    (let ((conn (make-ogent-mcp-connection :name "test")))
      (ogent-mcp--handle-message conn "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"success\":true}}")
      (should callback-result)
      (should (alist-get 'success callback-result))
      (should-not callback-error)
      ;; Callback should be removed from pending
      (should-not (gethash 1 ogent-mcp--pending-requests)))))

(ert-deftest ogent-mcp--handle-message-passes-error-to-callback ()
  "ogent-mcp--handle-message should pass error to callback."
  (let ((ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (callback-result nil)
        (callback-error nil))
    (puthash 2 (lambda (result error)
                 (setq callback-result result
                       callback-error error))
             ogent-mcp--pending-requests)
    (let ((conn (make-ogent-mcp-connection :name "test")))
      (ogent-mcp--handle-message conn "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}")
      (should-not callback-result)
      (should callback-error)
      (should (equal "Invalid Request" (alist-get 'message callback-error))))))

(ert-deftest ogent-mcp--handle-message-ignores-unknown-id ()
  "ogent-mcp--handle-message should ignore responses with unknown ID."
  (let ((ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection :name "test")))
      ;; Should not error even with no pending request for id 999
      (ogent-mcp--handle-message conn "{\"jsonrpc\":\"2.0\",\"id\":999,\"result\":{}}"))))

;;; Notification Handling Tests

(ert-deftest ogent-mcp--handle-notification-logs-unknown ()
  "ogent-mcp--handle-notification should log unknown notifications."
  (let ((message-log nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-log (apply #'format fmt args)))))
      (let ((conn (make-ogent-mcp-connection :name "test-server")))
        (ogent-mcp--handle-notification conn "notifications/unknown" nil)
        (should (string-match-p "Unknown notification" message-log))
        (should (string-match-p "test-server" message-log))
        (should (string-match-p "unknown" message-log))))))

(ert-deftest ogent-mcp--handle-notification-refreshes-tools-on-change ()
  "ogent-mcp--handle-notification should refresh tools on list_changed."
  (let ((refresh-called nil))
    (cl-letf (((symbol-function 'ogent-mcp--refresh-tools)
               (lambda (conn)
                 (setq refresh-called conn))))
      (let ((conn (make-ogent-mcp-connection :name "test")))
        (ogent-mcp--handle-notification conn "notifications/tools/list_changed" nil)
        (should (eq refresh-called conn))))))

(ert-deftest ogent-mcp--handle-notification-refreshes-resources-on-change ()
  "ogent-mcp--handle-notification should refresh resources on list_changed."
  (let ((refresh-called nil))
    (cl-letf (((symbol-function 'ogent-mcp--refresh-resources)
               (lambda (conn)
                 (setq refresh-called conn))))
      (let ((conn (make-ogent-mcp-connection :name "test")))
        (ogent-mcp--handle-notification conn "notifications/resources/list_changed" nil)
        (should (eq refresh-called conn))))))

;;; Process Filter Tests

(ert-deftest ogent-mcp--make-process-filter-accumulates-output ()
  "Process filter should accumulate incomplete output."
  (let ((conn (make-ogent-mcp-connection :name "test" :buffer "")))
    (cl-letf (((symbol-function 'ogent-mcp--handle-message) #'ignore))
      (let ((filter (ogent-mcp--make-process-filter conn)))
        ;; Send incomplete message
        (funcall filter nil "{\"partial\":")
        (should (equal "{\"partial\":" (ogent-mcp-connection-buffer conn)))))))

(ert-deftest ogent-mcp--make-process-filter-processes-complete-messages ()
  "Process filter should process complete messages."
  (let ((conn (make-ogent-mcp-connection :name "test" :buffer ""))
        (handled-messages nil))
    (cl-letf (((symbol-function 'ogent-mcp--handle-message)
               (lambda (_conn msg)
                 (push msg handled-messages))))
      (let ((filter (ogent-mcp--make-process-filter conn)))
        ;; Send complete message
        (funcall filter nil "{\"complete\":true}\n")
        ;; Message should be processed (may be called multiple times due to filter logic)
        (should (>= (length handled-messages) 1))
        (should (member "{\"complete\":true}" handled-messages))))))

(ert-deftest ogent-mcp--make-process-filter-handles-multiple-messages ()
  "Process filter should handle multiple messages in one chunk."
  (let ((conn (make-ogent-mcp-connection :name "test" :buffer ""))
        (handled-messages nil))
    (cl-letf (((symbol-function 'ogent-mcp--handle-message)
               (lambda (_conn msg)
                 (push msg handled-messages))))
      (let ((filter (ogent-mcp--make-process-filter conn)))
        (funcall filter nil "{\"msg\":1}\n{\"msg\":2}\n")
        ;; Both messages should be processed
        (should (member "{\"msg\":1}" handled-messages))
        (should (member "{\"msg\":2}" handled-messages))))))

;;; Process Sentinel Tests

(ert-deftest ogent-mcp--make-process-sentinel-handles-exit ()
  "Process sentinel should handle normal exit."
  (let ((conn (make-ogent-mcp-connection :name "test-server" :status 'ready))
        (message-log nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-log (apply #'format fmt args)))))
      (let ((sentinel (ogent-mcp--make-process-sentinel conn)))
        (funcall sentinel nil "finished\n")
        (should (eq 'closed (ogent-mcp-connection-status conn)))
        (should (string-match-p "exited" message-log))))))

(ert-deftest ogent-mcp--make-process-sentinel-handles-kill ()
  "Process sentinel should handle killed process."
  (let ((conn (make-ogent-mcp-connection :name "test" :status 'ready)))
    (cl-letf (((symbol-function 'message) #'ignore))
      (let ((sentinel (ogent-mcp--make-process-sentinel conn)))
        (funcall sentinel nil "killed\n")
        (should (eq 'closed (ogent-mcp-connection-status conn)))))))

(ert-deftest ogent-mcp--make-process-sentinel-handles-error ()
  "Process sentinel should handle connection error."
  (let ((conn (make-ogent-mcp-connection :name "test" :status 'ready)))
    (cl-letf (((symbol-function 'message) #'ignore))
      (let ((sentinel (ogent-mcp--make-process-sentinel conn)))
        (funcall sentinel nil "connection broken\n")
        (should (eq 'error (ogent-mcp-connection-status conn)))
        (should (string-match-p "connection broken" (ogent-mcp-connection-error conn)))))))

;;; Connection State Tests

(ert-deftest ogent-mcp--connections-hash-table-operations ()
  "Connection hash table should support standard operations."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal)))
    ;; Add connection
    (let ((conn (make-ogent-mcp-connection :name "server1" :status 'ready)))
      (puthash "server1" conn ogent-mcp--connections)
      (should (= 1 (hash-table-count ogent-mcp--connections)))
      (should (eq conn (gethash "server1" ogent-mcp--connections))))
    ;; Remove connection
    (remhash "server1" ogent-mcp--connections)
    (should (= 0 (hash-table-count ogent-mcp--connections)))))

;;; Synchronous Request Tests

(ert-deftest ogent-mcp--request-sync-returns-result ()
  "ogent-mcp--request-sync should return result on success."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection :name "test")))
      ;; Mock send to immediately call the callback
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (callback (gethash id ogent-mcp--pending-requests)))
                     (when callback
                       (funcall callback '((success . t)) nil))))))
        (let ((response (ogent-mcp--request-sync conn "test/method" nil 1)))
          (should (car response))
          (should (alist-get 'success (car response)))
          (should-not (cdr response)))))))

(ert-deftest ogent-mcp--request-sync-returns-error ()
  "ogent-mcp--request-sync should return error on failure."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection :name "test")))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (callback (gethash id ogent-mcp--pending-requests)))
                     (when callback
                       (funcall callback nil '((code . -32600) (message . "Error"))))))))
        (let ((response (ogent-mcp--request-sync conn "test/method" nil 1)))
          (should-not (car response))
          (should (cdr response))
          (should (equal "Error" (alist-get 'message (cdr response)))))))))

(ert-deftest ogent-mcp--request-sync-returns-timeout ()
  "ogent-mcp--request-sync should return timeout error when no response."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection :name "test")))
      ;; Mock send to do nothing (no callback)
      (cl-letf (((symbol-function 'ogent-mcp--send) #'ignore)
                ;; Speed up test by making accept-process-output instant
                ((symbol-function 'accept-process-output) #'ignore))
        (let ((response (ogent-mcp--request-sync conn "test/method" nil 0.1)))
          (should-not (car response))
          (should (cdr response))
          (should (string-match-p "timeout" (alist-get 'message (cdr response))))
          (should (= 0 (hash-table-count ogent-mcp--pending-requests))))))))

;;; Protocol Version Tests

(ert-deftest ogent-mcp-protocol-version-default ()
  "Protocol version should have sensible default."
  (should (stringp ogent-mcp-protocol-version))
  (should (string-match-p "^20[0-9][0-9]-" ogent-mcp-protocol-version)))

(ert-deftest ogent-mcp-client-info-defaults ()
  "Client info should have sensible defaults."
  (should (stringp ogent-mcp-client-name))
  (should (equal "ogent" ogent-mcp-client-name))
  (should (stringp ogent-mcp-client-version))
  (should (string-match-p "^[0-9]+\\." ogent-mcp-client-version)))

;;; Tool Registration Integration Tests

;; Ensure ogent-tool-registry is defined for tests
(defvar ogent-tool-registry nil
  "Test stub for tool registry.")

(ert-deftest ogent-mcp--register-tools-creates-functions ()
  "ogent-mcp--register-tools should create wrapper functions."
  (let ((ogent-tool-registry nil)
        (conn (make-ogent-mcp-connection :name "test-server")))
    (ogent-mcp--register-tools conn
                               '(((name . "read_file")
                                  (description . "Read a file")
                                  (inputSchema . ((type . "object")
                                                  (properties . ((path . ((type . "string")
                                                                          (description . "File path")))))
                                                  (required . ["path"]))))))
    ;; Check tool was registered
    (should (= 1 (length ogent-tool-registry)))
    (let ((spec (car ogent-tool-registry)))
      (should (eq 'mcp-test-server-read_file (plist-get spec :name)))
      (should (string-match-p "\\[MCP:test-server\\]" (plist-get spec :description)))
      (should (equal "mcp-test-server" (plist-get spec :category))))
    ;; Check function was created
    (should (fboundp 'mcp-test-server-read_file))))

(ert-deftest ogent-mcp--register-tools-replaces-existing ()
  "ogent-mcp--register-tools should replace existing tool registration."
  (let ((ogent-tool-registry '((:name mcp-test-server-old_tool :function ignore)))
        (conn (make-ogent-mcp-connection :name "test-server")))
    (ogent-mcp--register-tools conn
                               '(((name . "old_tool")
                                  (description . "Updated description"))))
    (should (= 1 (length ogent-tool-registry)))
    (should (string-match-p "Updated" (plist-get (car ogent-tool-registry) :description)))))

;;; Send Tests

(ert-deftest ogent-mcp--send-calls-process-send-string ()
  "ogent-mcp--send sends encoded message to process."
  (let* ((sent-data nil)
         (mock-proc 'mock-process)
         (conn (make-ogent-mcp-connection :name "test" :process mock-proc)))
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (_p) t))
              ((symbol-function 'process-send-string)
               (lambda (_proc data)
                 (setq sent-data data))))
      (ogent-mcp--send conn '((jsonrpc . "2.0") (method . "ping")))
      (should sent-data)
      (should (string-suffix-p "\n" sent-data))
      ;; Should be valid JSON
      (let ((parsed (json-read-from-string (string-trim sent-data))))
        (should (equal "ping" (alist-get 'method parsed)))))))

(ert-deftest ogent-mcp--send-noop-when-process-dead ()
  "ogent-mcp--send does nothing when process is not live."
  (let* ((sent nil)
         (mock-proc 'mock-process)
         (conn (make-ogent-mcp-connection :name "test" :process mock-proc)))
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (_p) nil))
              ((symbol-function 'process-send-string)
               (lambda (_proc _data)
                 (setq sent t))))
      (ogent-mcp--send conn '((method . "ping")))
      (should-not sent))))

(ert-deftest ogent-mcp--send-noop-when-no-process ()
  "ogent-mcp--send does nothing when process is nil."
  (let ((conn (make-ogent-mcp-connection :name "test" :process nil)))
    ;; Should not error
    (ogent-mcp--send conn '((method . "ping")))))

;;; Request Tests

(ert-deftest ogent-mcp--request-stores-callback ()
  "ogent-mcp--request stores callback in pending requests."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (conn (make-ogent-mcp-connection :name "test")))
    (cl-letf (((symbol-function 'ogent-mcp--send) #'ignore))
      (let ((id (ogent-mcp--request conn "test/method" nil #'ignore)))
        (should (numberp id))
        (should (gethash id ogent-mcp--pending-requests))))))

(ert-deftest ogent-mcp--request-sends-message ()
  "ogent-mcp--request sends the request via ogent-mcp--send."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (sent-msg nil)
        (conn (make-ogent-mcp-connection :name "test")))
    (cl-letf (((symbol-function 'ogent-mcp--send)
               (lambda (_conn msg)
                 (setq sent-msg msg))))
      (ogent-mcp--request conn "tools/list" '((cursor . nil)) #'ignore)
      (should sent-msg)
      (should (equal "tools/list" (alist-get 'method sent-msg)))
      (should (alist-get 'id sent-msg)))))

;;; Initialize Tests

(ert-deftest ogent-mcp--initialize-sends-handshake ()
  "ogent-mcp--initialize sends initialize request with client info."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (sent-method nil)
        (sent-params nil))
    (let ((conn (make-ogent-mcp-connection :name "test" :status 'connecting)))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (setq sent-method (alist-get 'method msg)
                         sent-params (alist-get 'params msg)))))
        (ogent-mcp--initialize conn #'ignore)
        (should (equal "initialize" sent-method))
        (should (alist-get 'protocolVersion sent-params))
        (should (alist-get 'clientInfo sent-params))
        (let ((client-info (alist-get 'clientInfo sent-params)))
          (should (equal "ogent" (alist-get 'name client-info))))))))

(ert-deftest ogent-mcp--initialize-sets-ready-on-success ()
  "ogent-mcp--initialize sets status to ready on success."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (callback-called nil))
    (let ((conn (make-ogent-mcp-connection :name "test" :status 'connecting)))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   ;; Immediately call the callback with a success result
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb '((capabilities . ((tools . t)))) nil))))))
        (ogent-mcp--initialize conn
                               (lambda (result _err)
                                 (setq callback-called result)))
        (should (eq 'ready (ogent-mcp-connection-status conn)))
        (should callback-called)))))

(ert-deftest ogent-mcp--initialize-sets-error-on-failure ()
  "ogent-mcp--initialize sets status to error on failure."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (callback-error nil))
    (let ((conn (make-ogent-mcp-connection :name "test" :status 'connecting)))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb nil '((code . -32600) (message . "Init failed"))))))))
        (ogent-mcp--initialize conn
                               (lambda (_result err)
                                 (setq callback-error err)))
        (should (eq 'error (ogent-mcp-connection-status conn)))
        (should (equal "Init failed" (ogent-mcp-connection-error conn)))
        (should callback-error)))))

;;; Refresh Tools Tests

(ert-deftest ogent-mcp--refresh-tools-updates-connection ()
  "ogent-mcp--refresh-tools stores tools on connection."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (ogent-tool-registry nil))
    (let ((conn (make-ogent-mcp-connection :name "test-server" :status 'ready)))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb '((tools . [((name . "read")
                                                (description . "Read file"))]))
                                nil))))))
        (ogent-mcp--refresh-tools conn)
        (should (ogent-mcp-connection-tools conn))
        (should (listp (ogent-mcp-connection-tools conn)))
        (should (= 1 (length (ogent-mcp-connection-tools conn))))))))

(ert-deftest ogent-mcp--refresh-tools-logs-error ()
  "ogent-mcp--refresh-tools logs error message on failure."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (message-log nil))
    (let ((conn (make-ogent-mcp-connection :name "test-srv" :status 'ready)))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb nil '((message . "tool list error")))))))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq message-log (apply #'format fmt args)))))
        (ogent-mcp--refresh-tools conn)
        (should (string-match-p "Failed to list tools" message-log))
        (should (string-match-p "test-srv" message-log))))))

;;; Call Tool Tests

(ert-deftest ogent-mcp--call-tool-returns-text-content ()
  "ogent-mcp--call-tool returns text content on success."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection :name "test" :status 'ready)))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb '((content . [((type . "text") (text . "file contents"))]))
                                nil)))))
                ((symbol-function 'accept-process-output) #'ignore))
        (let ((result (ogent-mcp--call-tool conn "read_file" '(:path "/tmp/test"))))
          (should (equal "file contents" result)))))))

(ert-deftest ogent-mcp--call-tool-allows-json-false-is-error ()
  "MCP tool results with isError=false are successful."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection :name "test" :status 'ready)))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb '((content . [((type . "text")
                                                  (text . "ok"))])
                                     (isError . :json-false))
                                nil)))))
                ((symbol-function 'accept-process-output) #'ignore))
        (let ((result (ogent-mcp--call-tool conn "read_file" '(:path "/tmp/test"))))
          (should (equal "ok" result)))))))

(ert-deftest ogent-mcp--call-tool-errors-on-failure ()
  "ogent-mcp--call-tool signals error on MCP error response."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection :name "test" :status 'ready)))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb nil '((code . -32000) (message . "Not found")))))))
                ((symbol-function 'accept-process-output) #'ignore))
        (should-error (ogent-mcp--call-tool conn "missing_tool" nil))))))

;;; Refresh Resources Tests

(ert-deftest ogent-mcp--refresh-resources-updates-connection ()
  "ogent-mcp--refresh-resources stores resources on connection."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection
                 :name "test" :status 'ready
                 :capabilities '((resources . t)))))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb '((resources . [((uri . "file:///tmp") (name . "tmp"))])) nil))))))
        (ogent-mcp--refresh-resources conn)
        (should (ogent-mcp-connection-resources conn))
        (should (listp (ogent-mcp-connection-resources conn)))))))

(ert-deftest ogent-mcp--refresh-resources-skips-without-capability ()
  "ogent-mcp--refresh-resources does nothing without resources capability."
  (let ((ogent-mcp--request-id 0)
        (send-called nil))
    (let ((conn (make-ogent-mcp-connection
                 :name "test" :status 'ready
                 :capabilities nil)))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn _msg)
                   (setq send-called t))))
        (ogent-mcp--refresh-resources conn)
        (should-not send-called)))))

;;; Connect Tests

(ert-deftest ogent-mcp-connect-errors-for-unknown-server ()
  "ogent-mcp-connect signals error for unknown server name."
  (let ((ogent-mcp-servers nil))
    (should-error (ogent-mcp-connect "nonexistent") :type 'user-error)))

;;; Disconnect Tests

(ert-deftest ogent-mcp-disconnect-removes-connection ()
  "ogent-mcp-disconnect removes connection and registered tools."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal))
        (ogent-tool-registry
         (list '(:name mcp-srv-read :function ignore)
               '(:name mcp-srv-write :function ignore)
               '(:name other-tool :function ignore))))
    (let ((conn (make-ogent-mcp-connection
                 :name "srv" :status 'ready :process nil)))
      (puthash "srv" conn ogent-mcp--connections)
      (cl-letf (((symbol-function 'message) #'ignore))
        (ogent-mcp-disconnect "srv"))
      ;; Connection should be removed
      (should-not (gethash "srv" ogent-mcp--connections))
      ;; MCP tools should be removed, others preserved
      (should (= 1 (length ogent-tool-registry)))
      (should (eq 'other-tool (plist-get (car ogent-tool-registry) :name))))))

(ert-deftest ogent-mcp-disconnect-kills-live-process ()
  "ogent-mcp-disconnect kills a live process."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal))
        (ogent-tool-registry nil)
        (deleted-proc nil)
        (mock-proc 'mock-process))
    (let ((conn (make-ogent-mcp-connection
                 :name "srv" :status 'ready :process mock-proc)))
      (puthash "srv" conn ogent-mcp--connections)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_p) t))
                ((symbol-function 'delete-process)
                 (lambda (p) (setq deleted-proc p)))
                ((symbol-function 'message) #'ignore))
        (ogent-mcp-disconnect "srv")
        (should (eq deleted-proc mock-proc))))))

;;; List Connections Tests

(ert-deftest ogent-mcp-list-connections-empty ()
  "ogent-mcp-list-connections messages when no connections."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal))
        (message-log nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-log (apply #'format fmt args)))))
      (ogent-mcp-list-connections)
      (should (string-match-p "No MCP servers" message-log)))))

;;; Connect All Tests

(ert-deftest ogent-mcp-connect-all-connects-auto-connect-servers ()
  "ogent-mcp-connect-all connects servers marked auto-connect."
  (let ((ogent-mcp-servers
         '(("auto-srv" :command "cmd" :args () :auto-connect t)
           ("manual-srv" :command "cmd" :args ())))
        (connected-servers nil))
    (cl-letf (((symbol-function 'ogent-mcp-connect)
               (lambda (name) (push name connected-servers))))
      (ogent-mcp-connect-all)
      (should (member "auto-srv" connected-servers))
      (should-not (member "manual-srv" connected-servers)))))

(ert-deftest ogent-mcp-connect-all-noop-when-none-auto ()
  "ogent-mcp-connect-all does nothing when no auto-connect servers."
  (let ((ogent-mcp-servers
         '(("srv1" :command "cmd" :args ())
           ("srv2" :command "cmd" :args ())))
        (connected nil))
    (cl-letf (((symbol-function 'ogent-mcp-connect)
               (lambda (_name) (setq connected t))))
      (ogent-mcp-connect-all)
      (should-not connected))))

;;; Read Resource Tests

(ert-deftest ogent-mcp-read-resource-errors-when-not-connected ()
  "ogent-mcp-read-resource errors when server is not connected."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal)))
    (should-error (ogent-mcp-read-resource "unknown" "file:///tmp")
                  :type 'user-error)))

(ert-deftest ogent-mcp-read-resource-errors-when-not-ready ()
  "ogent-mcp-read-resource errors when server is not ready."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection
                 :name "srv" :status 'connecting)))
      (puthash "srv" conn ogent-mcp--connections)
      (should-error (ogent-mcp-read-resource "srv" "file:///tmp")
                    :type 'user-error))))

;;; Setup Tests

(ert-deftest ogent-mcp-setup-schedules-connect-all ()
  "ogent-mcp-setup schedules ogent-mcp-connect-all with timer."
  (let ((timer-args nil))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (secs _repeat fn &rest args)
                 (setq timer-args (list secs fn args)))))
      (ogent-mcp-setup)
      (should timer-args)
      (should (= 1 (nth 0 timer-args)))
      (should (eq #'ogent-mcp-connect-all (nth 1 timer-args))))))

;;; Coverage Expansion Tests for ogent-mcp.el

(ert-deftest ogent-mcp--call-tool-errors-on-isError ()
  "ogent-mcp--call-tool signals error when isError is set."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection :name "test" :status 'ready)))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb '((content . [((type . "text") (text . "Error detail"))])
                                     (isError . t))
                                nil)))))
                ((symbol-function 'accept-process-output) #'ignore))
        (should-error (ogent-mcp--call-tool conn "failing_tool" nil))))))

(ert-deftest ogent-mcp-read-resource-success ()
  "ogent-mcp-read-resource returns text content on success."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal))
        (ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection
                 :name "res-srv" :status 'ready)))
      (puthash "res-srv" conn ogent-mcp--connections)
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb '((contents . [((text . "resource content")
                                                   (uri . "file:///tmp/test"))])) nil)))))
                ((symbol-function 'accept-process-output) #'ignore))
        (let ((result (ogent-mcp-read-resource "res-srv" "file:///tmp/test")))
          (should (string= result "resource content")))))))

(ert-deftest ogent-mcp-read-resource-error-response ()
  "ogent-mcp-read-resource signals error on MCP error."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal))
        (ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection
                 :name "err-srv" :status 'ready)))
      (puthash "err-srv" conn ogent-mcp--connections)
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb nil '((code . -32000) (message . "Not found")))))))
                ((symbol-function 'accept-process-output) #'ignore))
        (should-error (ogent-mcp-read-resource "err-srv" "file:///missing"))))))

(ert-deftest ogent-mcp-list-connections-with-data ()
  "ogent-mcp-list-connections shows connection details."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection
                 :name "my-srv" :status 'ready
                 :tools '(((name . "tool1")) ((name . "tool2")))
                 :resources '(((uri . "file:///tmp"))))))
      (puthash "my-srv" conn ogent-mcp--connections)
      (cl-letf (((symbol-function 'with-help-window)
                 (lambda (_name &rest body)
                   ;; Execute body to test it doesn't error
                   (with-temp-buffer
                     (eval `(progn ,@body))))))
        ;; Should not error
        (ogent-mcp-list-connections)))))

(ert-deftest ogent-mcp-list-connections-with-error-status ()
  "ogent-mcp-list-connections shows error details."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection
                 :name "err-srv" :status 'error
                 :error "Connection refused")))
      (puthash "err-srv" conn ogent-mcp--connections)
      (cl-letf (((symbol-function 'with-help-window)
                 (lambda (_name &rest body)
                   (with-temp-buffer
                     (eval `(progn ,@body))))))
        ;; Should not error
        (ogent-mcp-list-connections)))))

(ert-deftest ogent-mcp--handle-message-dispatches-notification ()
  "ogent-mcp--handle-message dispatches notifications (no id)."
  (let ((notification-received nil))
    (cl-letf (((symbol-function 'ogent-mcp--handle-notification)
               (lambda (_conn method _params)
                 (setq notification-received method))))
      (let ((conn (make-ogent-mcp-connection :name "test")))
        (ogent-mcp--handle-message
         conn "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/test\",\"params\":{}}")
        (should (string= notification-received "notifications/test"))))))

(ert-deftest ogent-mcp--handle-message-invalid-json ()
  "ogent-mcp--handle-message handles invalid JSON gracefully."
  (let ((conn (make-ogent-mcp-connection :name "test")))
    (cl-letf (((symbol-function 'message) #'ignore))
      ;; Should not error
      (ogent-mcp--handle-message conn "not json at all"))))

(ert-deftest ogent-mcp-disconnect-no-process ()
  "ogent-mcp-disconnect handles connection with nil process."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal))
        (ogent-tool-registry nil))
    (let ((conn (make-ogent-mcp-connection
                 :name "no-proc" :status 'ready :process nil)))
      (puthash "no-proc" conn ogent-mcp--connections)
      (cl-letf (((symbol-function 'message) #'ignore))
        ;; Should not error
        (ogent-mcp-disconnect "no-proc")
        (should-not (gethash "no-proc" ogent-mcp--connections))))))

(ert-deftest ogent-mcp-disconnect-nonexistent ()
  "ogent-mcp-disconnect is a no-op for non-existent server."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'message) #'ignore))
      ;; Should not error
      (ogent-mcp-disconnect "nonexistent"))))

(ert-deftest ogent-mcp--refresh-resources-logs-error ()
  "ogent-mcp--refresh-resources logs error on failure."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (message-log nil))
    (let ((conn (make-ogent-mcp-connection
                 :name "res-fail" :status 'ready
                 :capabilities '((resources . t)))))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb nil '((message . "resource error")))))))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq message-log (apply #'format fmt args)))))
        (ogent-mcp--refresh-resources conn)
        (should (string-match-p "Failed to list resources" message-log))
        (should (string-match-p "res-fail" message-log))))))

(ert-deftest ogent-mcp--make-process-filter-partial-then-complete ()
  "Process filter accumulates partial messages then processes when complete."
  (let ((conn (make-ogent-mcp-connection :name "test" :buffer ""))
        (handled-messages nil))
    (cl-letf (((symbol-function 'ogent-mcp--handle-message)
               (lambda (_conn msg)
                 (push msg handled-messages))))
      (let ((filter (ogent-mcp--make-process-filter conn)))
        ;; Send partial message
        (funcall filter nil "{\"partial\":")
        (should (string= (ogent-mcp-connection-buffer conn) "{\"partial\":"))
        ;; Complete the message
        (funcall filter nil "true}\n")
        ;; Should have processed the complete message
        (should (member "{\"partial\":true}" handled-messages))))))

(ert-deftest ogent-mcp--args-to-alist-handles-boolean-values ()
  "ogent-mcp--args-to-alist handles boolean values."
  (let ((result (ogent-mcp--args-to-alist '(:recursive t :verbose nil))))
    (should (= 2 (length result)))
    (should (eq t (alist-get 'recursive result)))
    (should (eq nil (alist-get 'verbose result)))))

(ert-deftest ogent-mcp--extract-text-content-multiple-types ()
  "ogent-mcp--extract-text-content extracts only text, not images."
  (let ((content [((type . "image") (data . "base64"))
                  ((type . "text") (text . "First text"))
                  ((type . "resource") (uri . "file:///tmp"))
                  ((type . "text") (text . "Second text"))]))
    (should (equal "First text\nSecond text"
                   (ogent-mcp--extract-text-content content)))))

(ert-deftest ogent-mcp-connection-struct-all-fields ()
  "ogent-mcp-connection struct supports all expected fields."
  (let ((conn (make-ogent-mcp-connection
               :name "full"
               :process nil
               :capabilities '((tools . t))
               :tools '(tool1)
               :resources '(res1)
               :prompts '(prompt1)
               :status 'ready
               :error nil
               :buffer "buf")))
    (should (equal "full" (ogent-mcp-connection-name conn)))
    (should (equal '((tools . t)) (ogent-mcp-connection-capabilities conn)))
    (should (equal '(tool1) (ogent-mcp-connection-tools conn)))
    (should (equal '(res1) (ogent-mcp-connection-resources conn)))
    (should (equal '(prompt1) (ogent-mcp-connection-prompts conn)))
    (should (eq 'ready (ogent-mcp-connection-status conn)))
    (should-not (ogent-mcp-connection-error conn))
    (should (equal "buf" (ogent-mcp-connection-buffer conn)))))

(ert-deftest ogent-mcp-add-server-with-all-args ()
  "ogent-mcp-add-server correctly stores all arguments."
  (let ((ogent-mcp-servers nil))
    (ogent-mcp-add-server "full-srv" "node" '("srv.js" "--debug")
                          '(("API_KEY" . "secret") ("PORT" . "3000"))
                          t)
    (let ((config (cdr (assoc "full-srv" ogent-mcp-servers))))
      (should (equal "node" (plist-get config :command)))
      (should (equal '("srv.js" "--debug") (plist-get config :args)))
      (should (equal '(("API_KEY" . "secret") ("PORT" . "3000"))
                     (plist-get config :env)))
      (should (eq t (plist-get config :auto-connect))))))

(ert-deftest ogent-mcp--registered-tool-declares-effects-and-requires-approval ()
  "MCP-registered tools carry default effects that gate them behind approval."
  (let ((ogent-tool-registry nil)
        (conn (make-ogent-mcp-connection :name "demo" :status 'ready)))
    (cl-letf (((symbol-function 'message) #'ignore))
      (ogent-mcp--register-tools
       conn '(((name . "search") (description . "Search docs")
               (inputSchema . ((type . "object") (properties . nil)))))))
    (let ((spec (car ogent-tool-registry)))
      (should spec)
      (should (plist-get spec :effects))
      ;; network/high effects -> approval required, and ogent forwards a
      ;; confirm flag to gptel (closes the MCP auto-execution bypass).
      (should (ogent-tool-effects-approval-required-p (plist-get spec :effects)))
      (should (ogent-tool-spec-confirm-p spec)))))

;;; Protocol Version Negotiation Tests

(ert-deftest ogent-mcp-protocol-version-default-is-2025-03-26 ()
  "Default requested protocol version is the 2025-03-26 revision."
  (should (equal "2025-03-26" (default-value 'ogent-mcp-protocol-version))))

(ert-deftest ogent-mcp--initialize-stores-negotiated-protocol-version ()
  "ogent-mcp--initialize adopts the server's replied protocolVersion."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection :name "test" :status 'connecting)))
      (cl-letf (((symbol-function 'message) #'ignore)
                ((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb '((protocolVersion . "2024-11-05")
                                     (capabilities . ((tools . t))))
                                nil))))))
        (ogent-mcp--initialize conn #'ignore)
        (should (equal "2024-11-05"
                       (ogent-mcp-connection-protocol-version conn)))
        (should (eq 'ready (ogent-mcp-connection-status conn)))))))

(ert-deftest ogent-mcp--initialize-defaults-version-when-server-omits ()
  "ogent-mcp--initialize falls back to our version when reply omits it."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection :name "test" :status 'connecting)))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb '((capabilities . ((tools . t)))) nil))))))
        (ogent-mcp--initialize conn #'ignore)
        (should (equal ogent-mcp-protocol-version
                       (ogent-mcp-connection-protocol-version conn)))))))

(ert-deftest ogent-mcp--initialize-sends-configured-protocol-version ()
  "ogent-mcp--initialize sends the customized protocol version."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (ogent-mcp-protocol-version "9999-12-31")
        (sent-version nil))
    (let ((conn (make-ogent-mcp-connection :name "test" :status 'connecting)))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (when (equal "initialize" (alist-get 'method msg))
                     (setq sent-version
                           (alist-get 'protocolVersion
                                      (alist-get 'params msg)))))))
        (ogent-mcp--initialize conn #'ignore)
        (should (equal "9999-12-31" sent-version))))))

;;; Prompt Discovery Tests

(ert-deftest ogent-mcp--refresh-prompts-updates-connection ()
  "ogent-mcp--refresh-prompts stores prompts from prompts/list."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (sent-method nil))
    (let ((conn (make-ogent-mcp-connection
                 :name "test" :status 'ready
                 :capabilities '((prompts . t)))))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (setq sent-method (alist-get 'method msg))
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb '((prompts . [((name . "code_review")
                                                  (description . "Review code"))]))
                                nil))))))
        (ogent-mcp--refresh-prompts conn)
        (should (equal "prompts/list" sent-method))
        (should (listp (ogent-mcp-connection-prompts conn)))
        (should (= 1 (length (ogent-mcp-connection-prompts conn))))
        (should (equal "code_review"
                       (alist-get 'name
                                  (car (ogent-mcp-connection-prompts conn)))))))))

(ert-deftest ogent-mcp--refresh-prompts-skips-without-capability ()
  "ogent-mcp--refresh-prompts does nothing without prompts capability."
  (let ((send-called nil))
    (let ((conn (make-ogent-mcp-connection
                 :name "test" :status 'ready :capabilities nil)))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn _msg) (setq send-called t))))
        (ogent-mcp--refresh-prompts conn)
        (should-not send-called)))))

(ert-deftest ogent-mcp--refresh-prompts-logs-error ()
  "ogent-mcp--refresh-prompts logs error message on failure."
  (let ((ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (message-log nil))
    (let ((conn (make-ogent-mcp-connection
                 :name "prompt-fail" :status 'ready
                 :capabilities '((prompts . t)))))
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb nil '((message . "prompt error")))))))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq message-log (apply #'format fmt args)))))
        (ogent-mcp--refresh-prompts conn)
        (should (string-match-p "Failed to list prompts" message-log))
        (should (string-match-p "prompt-fail" message-log))))))

(ert-deftest ogent-mcp--handle-notification-refreshes-prompts-on-change ()
  "ogent-mcp--handle-notification refreshes prompts on list_changed."
  (let ((refresh-called nil))
    (cl-letf (((symbol-function 'ogent-mcp--refresh-prompts)
               (lambda (conn) (setq refresh-called conn))))
      (let ((conn (make-ogent-mcp-connection :name "test")))
        (ogent-mcp--handle-notification
         conn "notifications/prompts/list_changed" nil)
        (should (eq refresh-called conn))))))

(ert-deftest ogent-mcp-get-prompt-returns-messages ()
  "ogent-mcp-get-prompt returns resolved messages from prompts/get."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal))
        (ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (sent-method nil)
        (sent-params nil))
    (let ((conn (make-ogent-mcp-connection :name "srv" :status 'ready)))
      (puthash "srv" conn ogent-mcp--connections)
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (setq sent-method (alist-get 'method msg)
                         sent-params (alist-get 'params msg))
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb '((messages . [((role . "user")
                                                   (content . ((type . "text")
                                                               (text . "Review this"))))]))
                                nil)))))
                ((symbol-function 'accept-process-output) #'ignore))
        (let ((messages (ogent-mcp-get-prompt "srv" "code_review"
                                              '((language . "elisp")))))
          (should (equal "prompts/get" sent-method))
          (should (equal "code_review" (alist-get 'name sent-params)))
          (should (equal "elisp"
                         (alist-get 'language
                                    (alist-get 'arguments sent-params))))
          (should (listp messages))
          (should (= 1 (length messages)))
          (should (equal "user" (alist-get 'role (car messages)))))))))

(ert-deftest ogent-mcp-get-prompt-omits-arguments-when-nil ()
  "ogent-mcp-get-prompt omits the arguments param when nil."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal))
        (ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (sent-params nil))
    (let ((conn (make-ogent-mcp-connection :name "srv" :status 'ready)))
      (puthash "srv" conn ogent-mcp--connections)
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (setq sent-params (alist-get 'params msg))
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb '((messages . [])) nil)))))
                ((symbol-function 'accept-process-output) #'ignore))
        (ogent-mcp-get-prompt "srv" "plain")
        (should (equal "plain" (alist-get 'name sent-params)))
        (should-not (assq 'arguments sent-params))))))

(ert-deftest ogent-mcp-get-prompt-errors-when-not-connected ()
  "ogent-mcp-get-prompt signals user-error for unknown server."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal)))
    (should-error (ogent-mcp-get-prompt "unknown" "p") :type 'user-error)))

(ert-deftest ogent-mcp-get-prompt-errors-when-not-ready ()
  "ogent-mcp-get-prompt signals user-error when server is not ready."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal)))
    (puthash "srv" (make-ogent-mcp-connection :name "srv" :status 'connecting)
             ogent-mcp--connections)
    (should-error (ogent-mcp-get-prompt "srv" "p") :type 'user-error)))

(ert-deftest ogent-mcp-get-prompt-errors-on-mcp-error ()
  "ogent-mcp-get-prompt signals error on MCP error response."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal))
        (ogent-mcp--request-id 0)
        (ogent-mcp--pending-requests (make-hash-table :test 'equal)))
    (let ((conn (make-ogent-mcp-connection :name "srv" :status 'ready)))
      (puthash "srv" conn ogent-mcp--connections)
      (cl-letf (((symbol-function 'ogent-mcp--send)
                 (lambda (_conn msg)
                   (let* ((id (alist-get 'id msg))
                          (cb (gethash id ogent-mcp--pending-requests)))
                     (when cb
                       (remhash id ogent-mcp--pending-requests)
                       (funcall cb nil '((code . -32602)
                                         (message . "Unknown prompt")))))))
                ((symbol-function 'accept-process-output) #'ignore))
        (should-error (ogent-mcp-get-prompt "srv" "missing"))))))

(ert-deftest ogent-mcp-connect-http-refreshes-prompts ()
  "ogent-mcp-connect refreshes prompts after initialization."
  (let ((ogent-mcp-servers
         '(("web" :transport http :url "https://example.com/mcp")))
        (ogent-mcp--connections (make-hash-table :test 'equal))
        (refreshed nil))
    (cl-letf (((symbol-function 'ogent-mcp--initialize)
               (lambda (_conn callback)
                 (funcall callback '((capabilities . ((prompts . t)))) nil)))
              ((symbol-function 'ogent-mcp--refresh-tools) #'ignore)
              ((symbol-function 'ogent-mcp--refresh-resources) #'ignore)
              ((symbol-function 'ogent-mcp--refresh-prompts)
               (lambda (conn) (setq refreshed conn)))
              ((symbol-function 'message) #'ignore))
      (let ((conn (ogent-mcp-connect "web")))
        (should (eq refreshed conn))))))

;;; Streamable HTTP Transport Tests

(ert-deftest ogent-mcp-add-http-server-stores-config ()
  "ogent-mcp-add-http-server stores an http transport config."
  (let ((ogent-mcp-servers nil))
    (ogent-mcp-add-http-server "web" "https://example.com/mcp" t)
    (let ((config (cdr (assoc "web" ogent-mcp-servers))))
      (should (eq 'http (plist-get config :transport)))
      (should (equal "https://example.com/mcp" (plist-get config :url)))
      (should (eq t (plist-get config :auto-connect))))))

(ert-deftest ogent-mcp-connect-http-creates-http-connection ()
  "ogent-mcp-connect builds an http connection from :transport config."
  (let ((ogent-mcp-servers
         '(("web" :transport http :url "https://example.com/mcp")))
        (ogent-mcp--connections (make-hash-table :test 'equal))
        (initialized nil))
    (cl-letf (((symbol-function 'ogent-mcp--initialize)
               (lambda (conn _callback) (setq initialized conn))))
      (let ((conn (ogent-mcp-connect "web")))
        (should (eq 'http (ogent-mcp-connection-transport conn)))
        (should (equal "https://example.com/mcp"
                       (ogent-mcp-connection-url conn)))
        (should-not (ogent-mcp-connection-process conn))
        (should (eq conn (gethash "web" ogent-mcp--connections)))
        (should (eq initialized conn))))))

(ert-deftest ogent-mcp-connect-http-requires-url ()
  "ogent-mcp-connect signals user-error for http config without :url."
  (let ((ogent-mcp-servers '(("web" :transport http)))
        (ogent-mcp--connections (make-hash-table :test 'equal)))
    (should-error (ogent-mcp-connect "web") :type 'user-error)))

(ert-deftest ogent-mcp--http-send-posts-json-rpc ()
  "ogent-mcp--http-send POSTs via url-retrieve when curl is absent."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready))
        (captured-url nil)
        (captured-callback nil)
        (captured-cbargs nil)
        (captured-method nil)
        (captured-headers nil)
        (captured-data nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_program) nil))
              ((symbol-function 'url-retrieve)
               (lambda (url callback &optional cbargs _silent &rest _)
                 (setq captured-url url
                       captured-callback callback
                       captured-cbargs cbargs
                       captured-method url-request-method
                       captured-headers url-request-extra-headers
                       captured-data url-request-data)
                 nil)))
      (ogent-mcp--http-send conn '((jsonrpc . "2.0")
                                   (id . 7)
                                   (method . "tools/list")))
      (should (equal "https://example.com/mcp" captured-url))
      (should (eq #'ogent-mcp--http-handle-response captured-callback))
      (should (equal (list conn) captured-cbargs))
      (should (equal "POST" captured-method))
      (should (equal "application/json"
                     (cdr (assoc "Content-Type" captured-headers))))
      (should (string-match-p "application/json"
                              (cdr (assoc "Accept" captured-headers))))
      (should (string-match-p "text/event-stream"
                              (cdr (assoc "Accept" captured-headers))))
      ;; No session header before the server assigns one
      (should-not (assoc "Mcp-Session-Id" captured-headers))
      (let ((parsed (json-read-from-string captured-data)))
        (should (equal "tools/list" (alist-get 'method parsed)))
        (should (= 7 (alist-get 'id parsed)))))))

(ert-deftest ogent-mcp--http-send-includes-session-id ()
  "The url-retrieve fallback sends the assigned Mcp-Session-Id header."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp"
               :session-id "sess-42" :status 'ready))
        (captured-headers nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_program) nil))
              ((symbol-function 'url-retrieve)
               (lambda (_url _callback &optional _cbargs _silent &rest _)
                 (setq captured-headers url-request-extra-headers)
                 nil)))
      (ogent-mcp--http-send conn '((jsonrpc . "2.0") (method . "ping")))
      (should (equal "sess-42"
                     (cdr (assoc "Mcp-Session-Id" captured-headers)))))))

(ert-deftest ogent-mcp--send-routes-http-transport ()
  "ogent-mcp--send dispatches to the http sender for http connections."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready))
        (http-sent nil))
    (cl-letf (((symbol-function 'ogent-mcp--http-send)
               (lambda (_conn msg) (setq http-sent msg)))
              ((symbol-function 'process-send-string)
               (lambda (&rest _) (error "Stdio path must not run"))))
      (ogent-mcp--send conn '((method . "ping")))
      (should (equal "ping" (alist-get 'method http-sent))))))

(ert-deftest ogent-mcp--http-body-messages-parses-single-object ()
  "A plain JSON object body yields one message."
  (let ((messages (ogent-mcp--http-body-messages
                   "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"
                   "application/json")))
    (should (= 1 (length messages)))
    (should (= 1 (alist-get 'id (car messages))))))

(ert-deftest ogent-mcp--http-body-messages-parses-batch-array ()
  "A JSON array body yields one message per element."
  (let ((messages (ogent-mcp--http-body-messages
                   "[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}},{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}]"
                   "application/json")))
    (should (= 2 (length messages)))
    (should (= 1 (alist-get 'id (nth 0 messages))))
    (should (= 2 (alist-get 'id (nth 1 messages))))))

(ert-deftest ogent-mcp--http-body-messages-parses-sse-data-lines ()
  "A buffered SSE body yields one message per data: line."
  (let ((messages (ogent-mcp--http-body-messages
                   "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/x\"}\n"
                   "text/event-stream")))
    (should (= 2 (length messages)))
    (should (= 1 (alist-get 'id (nth 0 messages))))
    (should (equal "notifications/x" (alist-get 'method (nth 1 messages))))))

(ert-deftest ogent-mcp--http-body-messages-detects-sse-heuristically ()
  "An SSE-shaped body is parsed as SSE without a content type."
  (let ((messages (ogent-mcp--http-body-messages
                   "data: {\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}\n")))
    (should (= 1 (length messages)))
    (should (= 9 (alist-get 'id (car messages))))))

(ert-deftest ogent-mcp--http-body-messages-handles-empty-body ()
  "An empty body (202 Accepted for notifications) yields no messages."
  (should-not (ogent-mcp--http-body-messages "" "application/json"))
  (should-not (ogent-mcp--http-body-messages nil))
  (should-not (ogent-mcp--http-body-messages "  \n" "application/json")))

(ert-deftest ogent-mcp--http-handle-response-dispatches-and-stores-session ()
  "The response handler dispatches body messages and records the session id."
  (let ((ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (callback-result nil)
        (conn (make-ogent-mcp-connection
               :name "web" :transport 'http :status 'ready)))
    (puthash 5 (lambda (result _err) (setq callback-result result))
             ogent-mcp--pending-requests)
    (let ((buf (generate-new-buffer " *ogent-mcp-http-test*")))
      (with-current-buffer buf
        (insert "HTTP/1.1 200 OK\r\n"
                "Content-Type: application/json\r\n"
                "Mcp-Session-Id: sess-123\r\n"
                "\r\n"
                "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"ok\":true}}")
        (ogent-mcp--http-handle-response nil conn))
      (should callback-result)
      (should (eq t (alist-get 'ok callback-result)))
      (should (equal "sess-123" (ogent-mcp-connection-session-id conn)))
      ;; Handler cleans up the response buffer
      (should-not (buffer-live-p buf)))))

(ert-deftest ogent-mcp--http-handle-response-parses-sse-response ()
  "The response handler dispatches messages from a buffered SSE body."
  (let ((ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (callback-result nil)
        (conn (make-ogent-mcp-connection
               :name "web" :transport 'http :status 'ready)))
    (puthash 6 (lambda (result _err) (setq callback-result result))
             ogent-mcp--pending-requests)
    (let ((buf (generate-new-buffer " *ogent-mcp-http-test*")))
      (with-current-buffer buf
        (insert "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/event-stream\r\n"
                "\r\n"
                "event: message\n"
                "data: {\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{\"ok\":true}}\n")
        (ogent-mcp--http-handle-response nil conn))
      (should callback-result)
      (should (eq t (alist-get 'ok callback-result))))))

(ert-deftest ogent-mcp--http-handle-response-error-while-connecting ()
  "An HTTP error during connect marks the connection as errored."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http :status 'connecting))
        (message-log nil))
    (let ((buf (generate-new-buffer " *ogent-mcp-http-test*")))
      (with-current-buffer buf
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (setq message-log (apply #'format fmt args)))))
          (ogent-mcp--http-handle-response
           '(:error (error http 500)) conn)))
      (should (eq 'error (ogent-mcp-connection-status conn)))
      (should (ogent-mcp-connection-error conn))
      (should (string-match-p "HTTP error" message-log))
      (should-not (buffer-live-p buf)))))

(ert-deftest ogent-mcp--http-handle-response-error-keeps-ready-status ()
  "A transient HTTP error does not close a ready connection."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http :status 'ready)))
    (let ((buf (generate-new-buffer " *ogent-mcp-http-test*")))
      (with-current-buffer buf
        (cl-letf (((symbol-function 'message) #'ignore))
          (ogent-mcp--http-handle-response
           '(:error (error http 503)) conn)))
      (should (eq 'ready (ogent-mcp-connection-status conn)))
      (should-not (buffer-live-p buf)))))

;;; Streaming HTTP (curl) Tests

(ert-deftest ogent-mcp--sse-take-lines-splits-mixed-terminators ()
  "ogent-mcp--sse-take-lines splits LF, CRLF, and lone CR lines."
  (let ((split (ogent-mcp--sse-take-lines "a\nb\r\nc\rd")))
    (should (equal '("a" "b" "c") (car split)))
    (should (equal "d" (cdr split)))))

(ert-deftest ogent-mcp--sse-take-lines-holds-trailing-cr ()
  "ogent-mcp--sse-take-lines keeps a trailing CR in the remainder."
  (let ((split (ogent-mcp--sse-take-lines "a\r")))
    (should-not (car split))
    (should (equal "a\r" (cdr split))))
  ;; The held-back CR pairs with the LF of the next chunk
  (let ((split (ogent-mcp--sse-take-lines "a\r\nb")))
    (should (equal '("a") (car split)))
    (should (equal "b" (cdr split)))))

(ert-deftest ogent-mcp--http-send-streams-via-curl-when-available ()
  "ogent-mcp--http-send POSTs through a streaming curl subprocess."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready))
        (captured-command nil)
        (sent nil)
        (eof nil)
        (fake-proc (list 'fake-curl)))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_program) "/usr/bin/curl"))
              ((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq captured-command (plist-get args :command))
                 fake-proc))
              ((symbol-function 'process-send-string)
               (lambda (_proc data) (setq sent data)))
              ((symbol-function 'process-send-eof)
               (lambda (_proc) (setq eof t)))
              ((symbol-function 'url-retrieve)
               (lambda (&rest _) (error "url.el path must not run"))))
      (ogent-mcp--http-send conn '((jsonrpc . "2.0")
                                   (id . 7)
                                   (method . "tools/list")))
      (should (equal "curl" (car captured-command)))
      (should (member "-i" captured-command))
      (should (member "-X" captured-command))
      (should (member "POST" captured-command))
      (should (member "Content-Type: application/json" captured-command))
      (should (member "Accept: application/json, text/event-stream"
                      captured-command))
      ;; No session header before the server assigns one
      (should-not (cl-find "Mcp-Session-Id" captured-command
                           :test #'string-prefix-p))
      (should (equal "https://example.com/mcp"
                     (car (last captured-command))))
      ;; The body travels over curl's stdin
      (should (member "@-" captured-command))
      (should eof)
      (let ((parsed (json-read-from-string sent)))
        (should (equal "tools/list" (alist-get 'method parsed)))
        (should (= 7 (alist-get 'id parsed))))
      ;; The stream is registered for disconnect cleanup
      (should (equal (list fake-proc)
                     (ogent-mcp-connection-streams conn))))))

(ert-deftest ogent-mcp--http-send-falls-back-without-curl ()
  "ogent-mcp--http-send uses url-retrieve when curl is absent."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready))
        (retrieved nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_program) nil))
              ((symbol-function 'make-process)
               (lambda (&rest _) (error "curl path must not run")))
              ((symbol-function 'url-retrieve)
               (lambda (url &rest _) (setq retrieved url) nil)))
      (ogent-mcp--http-send conn '((jsonrpc . "2.0") (method . "ping")))
      (should (equal "https://example.com/mcp" retrieved)))))

(ert-deftest ogent-mcp--http-curl-stream-sends-session-header ()
  "ogent-mcp--http-curl-stream includes the assigned Mcp-Session-Id."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp"
               :session-id "sess-42" :status 'ready))
        (captured-command nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq captured-command (plist-get args :command))
                 (list 'fake-curl)))
              ((symbol-function 'process-send-string) #'ignore)
              ((symbol-function 'process-send-eof) #'ignore))
      (ogent-mcp--http-curl-stream conn "POST" "{}")
      (should (member "Mcp-Session-Id: sess-42" captured-command)))))

(ert-deftest ogent-mcp--http-curl-stream-get-requests-event-stream ()
  "A GET stream asks only for text/event-stream and sends no body."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready))
        (captured-command nil)
        (sent nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq captured-command (plist-get args :command))
                 (list 'fake-curl)))
              ((symbol-function 'process-send-string)
               (lambda (&rest _) (setq sent t))))
      (ogent-mcp--http-curl-stream conn "GET")
      (should (member "GET" captured-command))
      (should (member "Accept: text/event-stream" captured-command))
      (should-not (member "Content-Type: application/json"
                          captured-command))
      (should-not (member "--data-binary" captured-command))
      (should-not sent))))

(ert-deftest ogent-mcp--http-curl-filter-dispatches-sse-incrementally ()
  "The curl filter dispatches each SSE frame as soon as it completes."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready))
        (dispatched nil)
        (filter nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq filter (plist-get args :filter))
                 (list 'fake-curl)))
              ((symbol-function 'process-send-string) #'ignore)
              ((symbol-function 'process-send-eof) #'ignore)
              ((symbol-function 'ogent-mcp--dispatch-message)
               (lambda (_conn msg) (push msg dispatched))))
      (ogent-mcp--http-curl-stream conn "POST" "{}")
      ;; Headers arrive first; the session id is recorded from them
      (funcall filter nil (concat "HTTP/1.1 200 OK\r\n"
                                  "Content-Type: text/event-stream\r\n"
                                  "Mcp-Session-Id: sess-9\r\n"
                                  "\r\n"))
      (should (equal "sess-9" (ogent-mcp-connection-session-id conn)))
      (should-not dispatched)
      ;; A frame split mid-line dispatches only once complete
      (funcall filter nil "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"res")
      (should-not dispatched)
      (funcall filter nil "ult\":{}}\n")
      (should-not dispatched)
      (funcall filter nil "\n")
      (should (= 1 (length dispatched)))
      (should (= 1 (alist-get 'id (car dispatched))))
      ;; The stream stays open: later frames dispatch as they arrive
      (funcall
       filter nil
       "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/x\"}\n\n")
      (should (= 2 (length dispatched)))
      (should (equal "notifications/x"
                     (alist-get 'method (car dispatched)))))))

(ert-deftest ogent-mcp--http-curl-filter-joins-multi-data-frames ()
  "Multiple data: lines of one SSE frame are joined with newlines."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready))
        (dispatched nil)
        (filter nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq filter (plist-get args :filter))
                 (list 'fake-curl)))
              ((symbol-function 'process-send-string) #'ignore)
              ((symbol-function 'process-send-eof) #'ignore)
              ((symbol-function 'ogent-mcp--dispatch-message)
               (lambda (_conn msg) (push msg dispatched))))
      (ogent-mcp--http-curl-stream conn "POST" "{}")
      (funcall filter nil (concat "HTTP/1.1 200 OK\r\n"
                                  "Content-Type: text/event-stream\r\n"
                                  "\r\n"))
      (funcall filter nil (concat "data: {\"jsonrpc\":\"2.0\",\n"
                                  "data: \"id\":2,\"result\":"
                                  "{\"ok\":true}}\n\n"))
      (should (= 1 (length dispatched)))
      (should (= 2 (alist-get 'id (car dispatched))))
      (should (eq t (alist-get 'ok
                               (alist-get 'result (car dispatched))))))))

(ert-deftest ogent-mcp--http-curl-filter-ignores-comments-and-heartbeats ()
  "Comment lines and dataless SSE frames never dispatch."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready))
        (dispatched nil)
        (filter nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq filter (plist-get args :filter))
                 (list 'fake-curl)))
              ((symbol-function 'process-send-string) #'ignore)
              ((symbol-function 'process-send-eof) #'ignore)
              ((symbol-function 'ogent-mcp--dispatch-message)
               (lambda (_conn msg) (push msg dispatched))))
      (ogent-mcp--http-curl-stream conn "POST" "{}")
      (funcall filter nil (concat "HTTP/1.1 200 OK\r\n"
                                  "Content-Type: text/event-stream\r\n"
                                  "\r\n"))
      (funcall filter nil ": keep-alive\n\n")
      (funcall filter nil "event: ping\nid: 3\nretry: 1000\n\n")
      (should-not dispatched)
      ;; Data mixed with comments still dispatches
      (funcall filter nil (concat ": hb\ndata: {\"jsonrpc\":\"2.0\","
                                  "\"id\":4,\"result\":{}}\n\n"))
      (should (= 1 (length dispatched)))
      (should (= 4 (alist-get 'id (car dispatched)))))))

(ert-deftest ogent-mcp--http-curl-filter-handles-crlf-frames ()
  "CRLF-terminated SSE frames dispatch, even split inside a CRLF."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready))
        (dispatched nil)
        (filter nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq filter (plist-get args :filter))
                 (list 'fake-curl)))
              ((symbol-function 'process-send-string) #'ignore)
              ((symbol-function 'process-send-eof) #'ignore)
              ((symbol-function 'ogent-mcp--dispatch-message)
               (lambda (_conn msg) (push msg dispatched))))
      (ogent-mcp--http-curl-stream conn "POST" "{}")
      (funcall filter nil (concat "HTTP/1.1 200 OK\r\n"
                                  "Content-Type: text/event-stream\r\n"
                                  "\r\n"))
      ;; The chunk boundary falls between the CR and LF of a CRLF
      (funcall filter nil
               "data: {\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{}}\r")
      (should-not dispatched)
      (funcall filter nil "\n\r\n")
      (should (= 1 (length dispatched)))
      (should (= 5 (alist-get 'id (car dispatched)))))))

(ert-deftest ogent-mcp--http-curl-filter-skips-interim-responses ()
  "A 1xx interim header block does not end header parsing."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready))
        (dispatched nil)
        (filter nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq filter (plist-get args :filter))
                 (list 'fake-curl)))
              ((symbol-function 'process-send-string) #'ignore)
              ((symbol-function 'process-send-eof) #'ignore)
              ((symbol-function 'ogent-mcp--dispatch-message)
               (lambda (_conn msg) (push msg dispatched))))
      (ogent-mcp--http-curl-stream conn "POST" "{}")
      (funcall filter nil
               (concat "HTTP/1.1 100 Continue\r\n\r\n"
                       "HTTP/1.1 200 OK\r\n"
                       "Content-Type: text/event-stream\r\n\r\n"
                       "data: {\"jsonrpc\":\"2.0\",\"id\":6,"
                       "\"result\":{}}\n\n"))
      (should (= 1 (length dispatched)))
      (should (= 6 (alist-get 'id (car dispatched)))))))

(ert-deftest ogent-mcp--http-curl-json-response-dispatches-on-exit ()
  "A JSON (non-SSE) curl response is parsed once curl finishes."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready))
        (dispatched nil)
        (filter nil)
        (sentinel nil)
        (fake-proc (list 'fake-curl)))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq filter (plist-get args :filter)
                       sentinel (plist-get args :sentinel))
                 fake-proc))
              ((symbol-function 'process-send-string) #'ignore)
              ((symbol-function 'process-send-eof) #'ignore)
              ((symbol-function 'ogent-mcp--dispatch-message)
               (lambda (_conn msg) (push msg dispatched))))
      (ogent-mcp--http-curl-stream conn "POST" "{}")
      (funcall filter fake-proc (concat "HTTP/1.1 200 OK\r\n"
                                        "Content-Type: application/json"
                                        "\r\n\r\n"))
      (funcall filter fake-proc "{\"jsonrpc\":\"2.0\",\"id\":7,")
      (funcall filter fake-proc "\"result\":{\"ok\":true}}")
      ;; The body only parses once curl exits
      (should-not dispatched)
      (funcall sentinel fake-proc "finished\n")
      (should (= 1 (length dispatched)))
      (should (= 7 (alist-get 'id (car dispatched))))
      ;; The finished stream is deregistered
      (should-not (ogent-mcp-connection-streams conn)))))

(ert-deftest ogent-mcp--http-curl-get-405-stays-silent ()
  "A 405 on the GET stream means \"not offered\" and logs nothing."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready))
        (messages nil)
        (dispatched nil)
        (filter nil)
        (sentinel nil)
        (fake-proc (list 'fake-curl)))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq filter (plist-get args :filter)
                       sentinel (plist-get args :sentinel))
                 fake-proc))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages)))
              ((symbol-function 'ogent-mcp--dispatch-message)
               (lambda (_conn msg) (push msg dispatched))))
      (ogent-mcp--http-curl-stream conn "GET")
      (funcall filter fake-proc (concat "HTTP/1.1 405 Method Not Allowed"
                                        "\r\nAllow: POST\r\n\r\n"))
      (funcall sentinel fake-proc "finished\n")
      (should-not messages)
      (should-not dispatched)
      (should (eq 'ready (ogent-mcp-connection-status conn))))))

(ert-deftest ogent-mcp--http-curl-get-stream-dispatches-server-messages ()
  "Server-initiated messages on the GET stream reach the dispatcher."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready))
        (refreshed nil)
        (filter nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq filter (plist-get args :filter))
                 (list 'fake-curl)))
              ((symbol-function 'ogent-mcp--refresh-tools)
               (lambda (c) (setq refreshed c))))
      (ogent-mcp--http-curl-stream conn "GET")
      (funcall filter nil (concat "HTTP/1.1 200 OK\r\n"
                                  "Content-Type: text/event-stream\r\n"
                                  "\r\n"))
      (funcall filter nil
               (concat "data: {\"jsonrpc\":\"2.0\",\"method\":"
                       "\"notifications/tools/list_changed\"}\n\n"))
      (should (eq conn refreshed)))))

(ert-deftest ogent-mcp--http-curl-post-error-marks-connecting-error ()
  "An HTTP error status during initialization marks the connection."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'connecting))
        (dispatched nil)
        (filter nil)
        (sentinel nil)
        (fake-proc (list 'fake-curl)))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq filter (plist-get args :filter)
                       sentinel (plist-get args :sentinel))
                 fake-proc))
              ((symbol-function 'process-send-string) #'ignore)
              ((symbol-function 'process-send-eof) #'ignore)
              ((symbol-function 'message) #'ignore)
              ((symbol-function 'ogent-mcp--dispatch-message)
               (lambda (_conn msg) (push msg dispatched))))
      (ogent-mcp--http-curl-stream conn "POST" "{}")
      (funcall filter fake-proc
               "HTTP/1.1 500 Internal Server Error\r\n\r\n")
      (should (eq 'error (ogent-mcp-connection-status conn)))
      (should (ogent-mcp-connection-error conn))
      ;; The body of a failed response is never dispatched
      (funcall filter fake-proc
               "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{}}")
      (funcall sentinel fake-proc "finished\n")
      (should-not dispatched))))

(ert-deftest ogent-mcp--initialize-opens-get-stream-for-http ()
  "Initialization on an http connection opens the server GET stream."
  (let ((ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (ogent-mcp--request-id 0)
        (conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'connecting))
        (sent nil)
        (opened nil))
    (cl-letf (((symbol-function 'ogent-mcp--send)
               (lambda (_conn msg) (push msg sent)))
              ((symbol-function 'ogent-mcp--http-open-get-stream)
               (lambda (c) (setq opened c)))
              ((symbol-function 'message) #'ignore))
      (ogent-mcp--initialize conn #'ignore)
      (should-not opened)
      ;; Deliver the server's initialize result
      (let ((id (alist-get 'id (car (last sent)))))
        (ogent-mcp--dispatch-message
         conn `((id . ,id)
                (result . ((protocolVersion . "2025-03-26")
                           (capabilities . ()))))))
      (should (eq conn opened))
      (should (eq 'ready (ogent-mcp-connection-status conn))))))

(ert-deftest ogent-mcp--initialize-skips-get-stream-for-stdio ()
  "Initialization on a stdio connection opens no GET stream."
  (let ((ogent-mcp--pending-requests (make-hash-table :test 'equal))
        (ogent-mcp--request-id 0)
        (conn (make-ogent-mcp-connection
               :name "srv" :transport 'stdio :status 'connecting))
        (sent nil)
        (opened nil))
    (cl-letf (((symbol-function 'ogent-mcp--send)
               (lambda (_conn msg) (push msg sent)))
              ((symbol-function 'ogent-mcp--http-open-get-stream)
               (lambda (c) (setq opened c)))
              ((symbol-function 'message) #'ignore))
      (ogent-mcp--initialize conn #'ignore)
      (let ((id (alist-get 'id (car (last sent)))))
        (ogent-mcp--dispatch-message
         conn `((id . ,id)
                (result . ((protocolVersion . "2025-03-26")
                           (capabilities . ()))))))
      (should-not opened)
      (should (eq 'ready (ogent-mcp-connection-status conn))))))

(ert-deftest ogent-mcp--http-open-get-stream-noop-without-curl ()
  "The GET stream is skipped when curl is unavailable."
  (let ((conn (make-ogent-mcp-connection
               :name "web" :transport 'http
               :url "https://example.com/mcp" :status 'ready)))
    (cl-letf (((symbol-function 'executable-find) (lambda (_program) nil))
              ((symbol-function 'make-process)
               (lambda (&rest _) (error "curl must not spawn"))))
      (should-not (ogent-mcp--http-open-get-stream conn))
      (should-not (ogent-mcp-connection-streams conn)))))

(ert-deftest ogent-mcp-disconnect-ends-http-session ()
  "Disconnect DELETEs the http session and kills live curl streams."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal))
        (ogent-tool-registry nil)
        (stream (list 'fake-curl))
        (deleted nil)
        (delete-command nil))
    (let ((conn (make-ogent-mcp-connection
                 :name "web" :transport 'http
                 :url "https://example.com/mcp"
                 :session-id "sess-42" :status 'ready)))
      (setf (ogent-mcp-connection-streams conn) (list stream))
      (puthash "web" conn ogent-mcp--connections)
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (_program) "/usr/bin/curl"))
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (setq delete-command (plist-get args :command))
                   (list 'fake-delete)))
                ((symbol-function 'process-live-p)
                 (lambda (proc) (eq proc stream)))
                ((symbol-function 'delete-process)
                 (lambda (proc) (push proc deleted)))
                ((symbol-function 'message) #'ignore))
        (ogent-mcp-disconnect "web"))
      (should (member "DELETE" delete-command))
      (should (member "Mcp-Session-Id: sess-42" delete-command))
      (should (equal "https://example.com/mcp"
                     (car (last delete-command))))
      (should (equal (list stream) deleted))
      (should-not (ogent-mcp-connection-streams conn))
      (should-not (gethash "web" ogent-mcp--connections)))))

(ert-deftest ogent-mcp-disconnect-http-without-session-skips-delete ()
  "Disconnect sends no DELETE when the server assigned no session."
  (let ((ogent-mcp--connections (make-hash-table :test 'equal))
        (ogent-tool-registry nil))
    (let ((conn (make-ogent-mcp-connection
                 :name "web" :transport 'http
                 :url "https://example.com/mcp" :status 'ready)))
      (puthash "web" conn ogent-mcp--connections)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (error "DELETE must not be sent")))
                ((symbol-function 'url-retrieve)
                 (lambda (&rest _) (error "DELETE must not be sent")))
                ((symbol-function 'message) #'ignore))
        (ogent-mcp-disconnect "web"))
      (should-not (gethash "web" ogent-mcp--connections)))))

(provide 'ogent-mcp-tests)
;;; ogent-mcp-tests.el ends here
