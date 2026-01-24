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
          (should (string-match-p "timeout" (alist-get 'message (cdr response)))))))))

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

(provide 'ogent-mcp-tests)
;;; ogent-mcp-tests.el ends here
