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

(provide 'ogent-mcp-tests)
;;; ogent-mcp-tests.el ends here
