;;; ogent-mcp.el --- MCP (Model Context Protocol) client for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Implements an MCP client enabling ogent to connect to MCP servers for
;; extended tool capabilities.  Supports:
;; - Stdio transport (JSON-RPC over stdin/stdout)
;; - Streamable HTTP transport (JSON-RPC POSTs via url.el; messages in
;;   the POST response body are dispatched, SSE streaming out of scope)
;; - Protocol version negotiation during initialization
;; - Server discovery and configuration
;; - Dynamic tool registration from MCP servers
;; - Resource fetching
;; - Prompt discovery and retrieval (prompts/list, prompts/get)
;;
;; MCP Reference: https://modelcontextprotocol.io/
;;
;; Usage:
;;   (ogent-mcp-add-server "filesystem" "npx" '("-y" "@anthropic/mcp-server-filesystem" "/tmp"))
;;   (ogent-mcp-connect "filesystem")
;;   ;; Tools from the server are now available in ogent

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)

;; Forward declaration for ogent-tool-registry
(defvar ogent-tool-registry)

(defgroup ogent-mcp nil
  "MCP (Model Context Protocol) integration for ogent."
  :group 'ogent)

;;; Configuration

(defcustom ogent-mcp-servers nil
  "Alist of MCP server configurations.
Each entry is (NAME . PLIST) where PLIST contains:
  :transport - Transport symbol: `stdio' (default) or `http'
  :command  - The executable to run (string, stdio transport)
  :args     - Command arguments (list of strings, stdio transport)
  :env      - Environment variables (alist of (VAR . VALUE))
  :url      - Endpoint URL (string, http transport)
  :auto-connect - If non-nil, connect on ogent startup

Example:
  ((\"filesystem\" :command \"npx\"
                   :args (\"-y\" \"@anthropic/mcp-server-filesystem\" \"/tmp\")
                   :auto-connect t)
   (\"git\" :command \"uvx\" :args (\"mcp-server-git\"))
   (\"remote\" :transport http :url \"https://example.com/mcp\"))"
  :type '(alist :key-type string
                :value-type (plist :options (:transport :command :args :env
                                             :url :auto-connect)))
  :group 'ogent-mcp)

(defcustom ogent-mcp-protocol-version "2025-03-26"
  "MCP protocol version requested during initialization.
Sent as the preferred version in the initialize request.  When the
server replies with a different version, the replied version is
adopted and stored on the connection (see
`ogent-mcp-connection-protocol-version')."
  :type 'string
  :group 'ogent-mcp)

(defcustom ogent-mcp-client-name "ogent"
  "Client name sent during MCP initialization."
  :type 'string
  :group 'ogent-mcp)

(defcustom ogent-mcp-client-version "0.1.0"
  "Client version sent during MCP initialization."
  :type 'string
  :group 'ogent-mcp)

(defcustom ogent-mcp-default-tool-effects
  '((:kind network :target external :scope unrestricted :risk high))
  "Declared `:effects' attached to every MCP-registered tool.
MCP tools call out to an external server and can do arbitrary work,
so they default to network/high effects, which makes the request
pipeline require approval before running them (see
`ogent-tool-effects-approval-required-p').  Loosen this only for
servers you fully trust."
  :type '(repeat plist)
  :group 'ogent-mcp)

(defcustom ogent-mcp-connect-timeout 30
  "Timeout in seconds for MCP server connection."
  :type 'integer
  :group 'ogent-mcp)

;;; Internal State

(defvar ogent-mcp--connections (make-hash-table :test 'equal)
  "Hash table of server-name -> connection state.")

(defvar ogent-mcp--request-id 0
  "Counter for JSON-RPC request IDs.")

(defvar ogent-mcp--pending-requests (make-hash-table :test 'equal)
  "Hash table of request-id -> callback for pending requests.")

(cl-defstruct ogent-mcp-connection
  "State for an MCP server connection."
  name             ; Server name (string)
  transport        ; Transport symbol: `stdio' (default) or `http'
  url              ; Endpoint URL when transport is `http'
  session-id       ; Mcp-Session-Id assigned by an http server, if any
  process          ; Emacs process object (stdio transport)
  capabilities     ; Server capabilities from initialization
  protocol-version ; Protocol version negotiated with the server
  tools            ; List of available tools
  resources        ; List of available resources
  prompts          ; List of available prompts
  status           ; 'connecting | 'ready | 'error | 'closed
  error            ; Error message if status is 'error
  buffer)          ; Output accumulator buffer

;;; JSON-RPC Protocol

(defun ogent-mcp--next-id ()
  "Generate the next JSON-RPC request ID."
  (cl-incf ogent-mcp--request-id))

(defun ogent-mcp--encode-message (msg)
  "Encode MSG as a JSON-RPC message string with newline delimiter."
  (concat (json-encode msg) "\n"))

(defun ogent-mcp--make-request (method &optional params)
  "Create a JSON-RPC request object for METHOD with PARAMS."
  (let ((req `((jsonrpc . "2.0")
               (id . ,(ogent-mcp--next-id))
               (method . ,method))))
    (when params
      (push (cons 'params params) req))
    req))

(defun ogent-mcp--make-notification (method &optional params)
  "Create a JSON-RPC notification object for METHOD with PARAMS."
  (let ((notif `((jsonrpc . "2.0")
                 (method . ,method))))
    (when params
      (push (cons 'params params) notif))
    notif))

(defun ogent-mcp--parse-message (json-str)
  "Parse JSON-STR as a JSON-RPC message."
  (condition-case err
      (json-read-from-string json-str)
    (error
     (message "ogent-mcp: Failed to parse JSON: %s" (error-message-string err))
     nil)))

(defun ogent-mcp--array-to-list (value)
  "Return JSON array VALUE as a list."
  (cond
   ((vectorp value) (append value nil))
   ((listp value) value)
   ((null value) nil)
   (t (list value))))

(defun ogent-mcp--json-true-p (value)
  "Return non-nil when VALUE is JSON true."
  (eq value t))

;;; Process Management

(defun ogent-mcp--make-process-filter (conn)
  "Create a process filter for MCP connection CONN."
  (lambda (_process output)
    (let ((buf (ogent-mcp-connection-buffer conn)))
      ;; Accumulate output in buffer
      (setf (ogent-mcp-connection-buffer conn)
            (concat buf output))
      ;; Process complete messages (newline-delimited)
      (let ((lines (split-string (ogent-mcp-connection-buffer conn) "\n" t)))
        (when (string-suffix-p "\n" (ogent-mcp-connection-buffer conn))
          ;; All lines are complete
          (setf (ogent-mcp-connection-buffer conn) "")
          (dolist (line lines)
            (when (not (string-empty-p (string-trim line)))
              (ogent-mcp--handle-message conn line))))
        (unless (string-suffix-p "\n" (ogent-mcp-connection-buffer conn))
          ;; Last line is incomplete, keep it in buffer
          (setf (ogent-mcp-connection-buffer conn)
                (car (last lines)))
          (dolist (line (butlast lines))
            (when (not (string-empty-p (string-trim line)))
              (ogent-mcp--handle-message conn line))))))))

(defun ogent-mcp--make-process-sentinel (conn)
  "Create a process sentinel for MCP connection CONN."
  (lambda (_process event)
    (let ((name (ogent-mcp-connection-name conn)))
      (cond
       ((string-match-p "finished\\|exited" event)
        (setf (ogent-mcp-connection-status conn) 'closed)
        (message "ogent-mcp: Server '%s' exited" name))
       ((string-match-p "\\(deleted\\|killed\\)" event)
        (setf (ogent-mcp-connection-status conn) 'closed)
        (message "ogent-mcp: Server '%s' killed" name))
       (t
        (setf (ogent-mcp-connection-status conn) 'error)
        (setf (ogent-mcp-connection-error conn) event)
        (message "ogent-mcp: Server '%s' error: %s" name event))))))

(defun ogent-mcp--handle-message (conn json-str)
  "Handle a JSON-RPC message JSON-STR for connection CONN."
  (let ((msg (ogent-mcp--parse-message json-str)))
    (when msg
      (ogent-mcp--dispatch-message conn msg))))

(defun ogent-mcp--dispatch-message (conn msg)
  "Dispatch a parsed JSON-RPC message MSG for connection CONN."
  (let ((id (alist-get 'id msg))
        (method (alist-get 'method msg))
        (result (alist-get 'result msg))
        (error-obj (alist-get 'error msg)))
    (cond
     ;; Response to a request we made
     (id
      (let ((callback (gethash id ogent-mcp--pending-requests)))
        (when callback
          (remhash id ogent-mcp--pending-requests)
          (if error-obj
              (funcall callback nil error-obj)
            (funcall callback result nil)))))
     ;; Notification from server
     (method
      (ogent-mcp--handle-notification conn method (alist-get 'params msg))))))

(defun ogent-mcp--handle-notification (conn method _params)
  "Handle a notification METHOD with PARAMS from CONN."
  (pcase method
    ("notifications/tools/list_changed"
     ;; Server's tools changed, refresh
     (ogent-mcp--refresh-tools conn))
    ("notifications/resources/list_changed"
     ;; Server's resources changed, refresh
     (ogent-mcp--refresh-resources conn))
    ("notifications/prompts/list_changed"
     ;; Server's prompts changed, refresh
     (ogent-mcp--refresh-prompts conn))
    (_
     ;; Unknown notification, log it
     (message "ogent-mcp: Unknown notification from '%s': %s"
              (ogent-mcp-connection-name conn) method))))

;;; Streamable HTTP Transport
;;
;; Client half of the MCP streamable HTTP transport: every JSON-RPC
;; message is POSTed to the server's endpoint URL, and any messages in
;; the POST response body are dispatched.  Responses may be plain JSON
;; (object or batch array) or a fully-buffered SSE body, in which case
;; each "data:" line is parsed.  Incremental SSE streaming and
;; server-initiated GET streams are out of scope; only POST responses
;; are handled.

(defun ogent-mcp--http-send (conn msg)
  "POST JSON-RPC MSG to the streamable HTTP endpoint of CONN.
The response is handled asynchronously by
`ogent-mcp--http-handle-response'."
  (let* ((url-request-method "POST")
         (url-request-extra-headers
          (append '(("Content-Type" . "application/json")
                    ("Accept" . "application/json, text/event-stream"))
                  (when-let ((session (ogent-mcp-connection-session-id conn)))
                    (list (cons "Mcp-Session-Id" session)))))
         (url-request-data
          (encode-coding-string (json-encode msg) 'utf-8)))
    (url-retrieve (ogent-mcp-connection-url conn)
                  #'ogent-mcp--http-handle-response
                  (list conn)
                  t)))

(defun ogent-mcp--http-header (name)
  "Return the value of response header NAME in the current buffer.
Search only the header section of an HTTP response buffer.  Return
nil when the header is absent."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t)
          (limit (or (bound-and-true-p url-http-end-of-headers)
                     (save-excursion
                       (when (re-search-forward "^\r?$" nil t)
                         (point)))
                     (point-max))))
      (when (re-search-forward
             (concat "^" (regexp-quote name) ":[ \t]*\\(.*\\)$")
             limit t)
        (string-trim (match-string 1))))))

(defun ogent-mcp--http-body-messages (body &optional content-type)
  "Parse BODY of a streamable HTTP response into JSON-RPC messages.
CONTENT-TYPE is the response Content-Type header when known.  Return
a list of parsed message alists: a JSON object yields one message, a
JSON batch array yields one per element, and a fully-buffered SSE
body yields one per \"data:\" line.  Incremental SSE streaming is not
supported."
  (let ((body (string-trim (or body ""))))
    (cond
     ((string-empty-p body) nil)
     ((or (and content-type
               (string-match-p "text/event-stream" content-type))
          (string-match-p "\\`\\(data\\|event\\):" body))
      (let ((messages nil))
        (dolist (line (split-string body "\n" t "[ \t\r]+"))
          (when (string-match "\\`data:[ \t]*\\(.+\\)\\'" line)
            (let ((msg (ogent-mcp--parse-message (match-string 1 line))))
              (when msg
                (push msg messages)))))
        (nreverse messages)))
     (t
      (let ((parsed (ogent-mcp--parse-message body)))
        (cond
         ((vectorp parsed) (append parsed nil))
         (parsed (list parsed))))))))

(defun ogent-mcp--http-handle-response (status conn)
  "Handle a completed HTTP POST response for CONN in the current buffer.
STATUS is the status plist supplied by `url-retrieve'.  Record any
Mcp-Session-Id header on CONN, dispatch every JSON-RPC message found
in the response body, then kill the response buffer."
  (let ((buffer (current-buffer)))
    (unwind-protect
        (let ((err (plist-get status :error)))
          (if err
              (progn
                (when (eq (ogent-mcp-connection-status conn) 'connecting)
                  (setf (ogent-mcp-connection-status conn) 'error)
                  (setf (ogent-mcp-connection-error conn) (format "%s" err)))
                (message "ogent-mcp: HTTP error from '%s': %s"
                         (ogent-mcp-connection-name conn) err))
            (when-let ((session (ogent-mcp--http-header "Mcp-Session-Id")))
              (setf (ogent-mcp-connection-session-id conn) session))
            (let* ((content-type (ogent-mcp--http-header "Content-Type"))
                   (body-start
                    (or (bound-and-true-p url-http-end-of-headers)
                        (save-excursion
                          (goto-char (point-min))
                          (when (re-search-forward "^\r?\n" nil t)
                            (point)))
                        (point-min)))
                   (body (buffer-substring-no-properties
                          body-start (point-max))))
              (dolist (msg (ogent-mcp--http-body-messages body content-type))
                (ogent-mcp--dispatch-message conn msg)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

;;; Connection Lifecycle

(defun ogent-mcp--send (conn msg)
  "Send JSON-RPC MSG to MCP server CONN over its transport."
  (if (eq (ogent-mcp-connection-transport conn) 'http)
      (ogent-mcp--http-send conn msg)
    (let ((proc (ogent-mcp-connection-process conn)))
      (when (and proc (process-live-p proc))
        (process-send-string proc (ogent-mcp--encode-message msg))))))

(defun ogent-mcp--request (conn method params callback)
  "Send a request to CONN with METHOD and PARAMS, calling CALLBACK with result.
CALLBACK is called with (RESULT ERROR) where one is nil."
  (let* ((req (ogent-mcp--make-request method params))
         (id (alist-get 'id req)))
    (puthash id callback ogent-mcp--pending-requests)
    (ogent-mcp--send conn req)
    id))

(defun ogent-mcp--request-sync (conn method params &optional timeout)
  "Send a synchronous request to CONN with METHOD and PARAMS.
Return (RESULT . ERROR) cons cell.  Block for up to TIMEOUT seconds."
  (let ((timeout (or timeout ogent-mcp-connect-timeout))
        (done nil)
        (result nil)
        (error-result nil)
        request-id)
    (setq request-id
          (ogent-mcp--request conn method params
                              (lambda (res err)
                                (setq result res error-result err done t))))
    ;; Wait for response
    (let ((start-time (current-time)))
      (while (and (not done)
                  (< (float-time (time-subtract (current-time) start-time))
                     timeout))
        (accept-process-output nil 0.1)))
    (if done
        (cons result error-result)
      (remhash request-id ogent-mcp--pending-requests)
      (cons nil `((code . -32000) (message . "Request timeout"))))))

(defun ogent-mcp--initialize (conn callback)
  "Send initialization handshake to CONN, calling CALLBACK when complete."
  (let ((params `((protocolVersion . ,ogent-mcp-protocol-version)
                  (capabilities . ((roots . ((listChanged . :json-false)))))
                  (clientInfo . ((name . ,ogent-mcp-client-name)
                                 (version . ,ogent-mcp-client-version))))))
    (ogent-mcp--request conn "initialize" params
                        (lambda (result error-obj)
                          (if error-obj
                              (progn
                                (setf (ogent-mcp-connection-status conn) 'error)
                                (setf (ogent-mcp-connection-error conn)
                                      (alist-get 'message error-obj))
                                (funcall callback nil error-obj))
                            ;; Store capabilities
                            (setf (ogent-mcp-connection-capabilities conn)
                                  (alist-get 'capabilities result))
                            ;; Version negotiation: adopt the version the
                            ;; server replied with, which may differ from
                            ;; the one we requested.
                            (let ((server-version
                                   (alist-get 'protocolVersion result)))
                              (when (and server-version
                                         (not (equal server-version
                                                     ogent-mcp-protocol-version)))
                                (message "ogent-mcp: Server '%s' negotiated protocol version %s (requested %s)"
                                         (ogent-mcp-connection-name conn)
                                         server-version
                                         ogent-mcp-protocol-version))
                              (setf (ogent-mcp-connection-protocol-version conn)
                                    (or server-version
                                        ogent-mcp-protocol-version)))
                            ;; Send initialized notification
                            (ogent-mcp--send conn
                                             (ogent-mcp--make-notification
                                              "notifications/initialized"))
                            ;; Mark as ready
                            (setf (ogent-mcp-connection-status conn) 'ready)
                            (funcall callback result nil))))))

;;; Tool Discovery and Registration

(defun ogent-mcp--refresh-tools (conn)
  "Refresh the tool list from CONN."
  (ogent-mcp--request conn "tools/list" nil
                      (lambda (result error-obj)
                        (if error-obj
                            (message "ogent-mcp: Failed to list tools from '%s': %s"
                                     (ogent-mcp-connection-name conn)
                                     (alist-get 'message error-obj))
                          (let ((tools (ogent-mcp--array-to-list
                                        (alist-get 'tools result))))
                            (setf (ogent-mcp-connection-tools conn) tools)
                            (ogent-mcp--register-tools conn tools))))))

(defun ogent-mcp--schema-to-args (input-schema)
  "Convert MCP INPUT-SCHEMA to ogent tool args format."
  (let ((props (alist-get 'properties input-schema))
        (required (alist-get 'required input-schema))
        (args nil))
    (dolist (prop-entry props)
      (let* ((name (symbol-name (car prop-entry)))
             (spec (cdr prop-entry))
             (type (or (alist-get 'type spec) "string"))
             (desc (or (alist-get 'description spec) ""))
             (is-required (member name (append required nil))))
        (push `(:name ,name
                      :type ,type
                      :description ,desc
                      ,@(unless is-required '(:optional t)))
              args)))
    (nreverse args)))

(defun ogent-mcp--register-tools (conn tools)
  "Register TOOLS from CONN with ogent's tool registry."
  (let ((server-name (ogent-mcp-connection-name conn)))
    (dolist (tool tools)
      (let* ((name (alist-get 'name tool))
             (description (or (alist-get 'description tool) ""))
             (input-schema (alist-get 'inputSchema tool))
             (tool-sym (intern (format "mcp-%s-%s" server-name name)))
             (args (ogent-mcp--schema-to-args input-schema)))
        ;; Create a wrapper function that calls the MCP server
        (fset tool-sym
              (lambda (&rest call-args)
                (ogent-mcp--call-tool conn name call-args)))
        ;; Add to ogent-tool-registry
        (let ((spec `(:name ,tool-sym
                            :function ,tool-sym
                            :description ,(format "[MCP:%s] %s" server-name description)
                            :args ,args
                            :category ,(format "mcp-%s" server-name)
                            ;; External, server-backed capability: gate behind
                            ;; approval by default so it cannot auto-execute.
                            :effects ,(copy-tree ogent-mcp-default-tool-effects))))
          ;; Remove existing entry with same name
          (setq ogent-tool-registry
                (cl-remove-if (lambda (s) (eq (plist-get s :name) tool-sym))
                              ogent-tool-registry))
          (push spec ogent-tool-registry))
        (message "ogent-mcp: Registered tool %s from '%s'" name server-name)))))

(defun ogent-mcp--call-tool (conn tool-name args)
  "Call TOOL-NAME on CONN with ARGS and return result."
  (let* ((params `((name . ,tool-name)
                   (arguments . ,(ogent-mcp--args-to-alist args))))
         (response (ogent-mcp--request-sync conn "tools/call" params)))
    (if (cdr response)
        ;; Error
        (error "MCP tool error: %s" (alist-get 'message (cdr response)))
      ;; Success - extract content
      (let* ((result (car response))
             (content (alist-get 'content result))
             (is-error (alist-get 'isError result)))
        (if (ogent-mcp--json-true-p is-error)
            (error "Tool execution error: %s"
                   (ogent-mcp--extract-text-content content))
          (ogent-mcp--extract-text-content content))))))

(defun ogent-mcp--args-to-alist (args)
  "Convert ARGS plist to alist for JSON encoding."
  (let ((result nil))
    (while args
      (let ((key (car args))
            (val (cadr args)))
        (when (keywordp key)
          (push (cons (intern (substring (symbol-name key) 1)) val) result)))
      (setq args (cddr args)))
    (nreverse result)))

(defun ogent-mcp--extract-text-content (content)
  "Extract text from MCP CONTENT array."
  (let ((texts nil))
    (dolist (item (append content nil))
      (when (string= (alist-get 'type item) "text")
        (push (alist-get 'text item) texts)))
    (string-join (nreverse texts) "\n")))

;;; Resource Discovery

(defun ogent-mcp--refresh-resources (conn)
  "Refresh the resource list from CONN."
  (let ((caps (ogent-mcp-connection-capabilities conn)))
    (when (alist-get 'resources caps)
      (ogent-mcp--request conn "resources/list" nil
                          (lambda (result error-obj)
                            (if error-obj
                                (message "ogent-mcp: Failed to list resources from '%s': %s"
                                         (ogent-mcp-connection-name conn)
                                         (alist-get 'message error-obj))
                              (setf (ogent-mcp-connection-resources conn)
                                    (ogent-mcp--array-to-list
                                     (alist-get 'resources result)))))))))

;;; Prompt Discovery

(defun ogent-mcp--refresh-prompts (conn)
  "Refresh the prompt list from CONN.
Only query the server when its capabilities include prompts."
  (let ((caps (ogent-mcp-connection-capabilities conn)))
    (when (alist-get 'prompts caps)
      (ogent-mcp--request conn "prompts/list" nil
                          (lambda (result error-obj)
                            (if error-obj
                                (message "ogent-mcp: Failed to list prompts from '%s': %s"
                                         (ogent-mcp-connection-name conn)
                                         (alist-get 'message error-obj))
                              (setf (ogent-mcp-connection-prompts conn)
                                    (ogent-mcp--array-to-list
                                     (alist-get 'prompts result)))))))))

;;; Public API

;;;###autoload
(defun ogent-mcp-add-server (name command args &optional env auto-connect)
  "Add an MCP server configuration.
NAME is the server identifier (string).
COMMAND is the executable to run.
ARGS is a list of command arguments.
ENV is an optional alist of environment variables.
AUTO-CONNECT if non-nil connects on ogent startup."
  (setq ogent-mcp-servers
        (cons (cons name `(:command ,command
                                    :args ,args
                                    :env ,env
                                    :auto-connect ,auto-connect))
              (assoc-delete-all name ogent-mcp-servers))))

;;;###autoload
(defun ogent-mcp-add-http-server (name url &optional auto-connect)
  "Add an MCP server configuration using the streamable HTTP transport.
NAME is the server identifier (string).
URL is the endpoint accepting JSON-RPC POST requests.
AUTO-CONNECT if non-nil connects on ogent startup."
  (setq ogent-mcp-servers
        (cons (cons name `(:transport http
                                      :url ,url
                                      :auto-connect ,auto-connect))
              (assoc-delete-all name ogent-mcp-servers))))

;;;###autoload
(defun ogent-mcp-connect (server-name)
  "Connect to the MCP server named SERVER-NAME."
  (interactive
   (list (completing-read "MCP Server: "
                          (mapcar #'car ogent-mcp-servers)
                          nil t)))
  (let ((config (cdr (assoc server-name ogent-mcp-servers))))
    (unless config
      (user-error "Unknown MCP server: %s" server-name))
    ;; Close existing connection if any
    (when (gethash server-name ogent-mcp--connections)
      (ogent-mcp-disconnect server-name))
    ;; Create new connection for the configured transport
    (let* ((transport (or (plist-get config :transport) 'stdio))
           (conn (pcase transport
                   ('stdio (ogent-mcp--connect-stdio server-name config))
                   ('http (ogent-mcp--connect-http server-name config))
                   (_ (user-error "Unknown MCP transport for '%s': %s"
                                  server-name transport)))))
      (puthash server-name conn ogent-mcp--connections)
      ;; Initialize
      (ogent-mcp--initialize conn
                             (lambda (_result error-obj)
                               (if error-obj
                                   (message "ogent-mcp: Failed to initialize '%s': %s"
                                            server-name
                                            (alist-get 'message error-obj))
                                 (message "ogent-mcp: Connected to '%s'" server-name)
                                 ;; Fetch tools
                                 (ogent-mcp--refresh-tools conn)
                                 ;; Fetch resources if supported
                                 (ogent-mcp--refresh-resources conn)
                                 ;; Fetch prompts if supported
                                 (ogent-mcp--refresh-prompts conn))))
      conn)))

(defun ogent-mcp--connect-stdio (server-name config)
  "Create a stdio transport connection to SERVER-NAME from CONFIG.
Start the server process described by CONFIG and return the new
connection object."
  (let* ((command (plist-get config :command))
         (args (plist-get config :args))
         (env (plist-get config :env))
         (conn (make-ogent-mcp-connection
                :name server-name
                :transport 'stdio
                :status 'connecting
                :buffer ""))
         (process-environment
          (append (mapcar (lambda (e) (format "%s=%s" (car e) (cdr e))) env)
                  process-environment)))
    (setf (ogent-mcp-connection-process conn)
          (make-process
           :name (format "ogent-mcp-%s" server-name)
           :command (cons command args)
           :connection-type 'pipe
           :noquery t
           :filter (ogent-mcp--make-process-filter conn)
           :sentinel (ogent-mcp--make-process-sentinel conn)))
    conn))

(defun ogent-mcp--connect-http (server-name config)
  "Create a streamable HTTP transport connection to SERVER-NAME from CONFIG.
Signal a `user-error' when CONFIG lacks a :url entry.  Return the new
connection object; no request is sent until initialization."
  (let ((url (plist-get config :url)))
    (unless url
      (user-error "MCP server '%s' uses the http transport but has no :url"
                  server-name))
    (make-ogent-mcp-connection
     :name server-name
     :transport 'http
     :url url
     :status 'connecting
     :buffer "")))

;;;###autoload
(defun ogent-mcp-disconnect (server-name)
  "Disconnect from the MCP server named SERVER-NAME."
  (interactive
   (list (completing-read "MCP Server: "
                          (hash-table-keys ogent-mcp--connections)
                          nil t)))
  (when-let ((conn (gethash server-name ogent-mcp--connections)))
    (let ((proc (ogent-mcp-connection-process conn)))
      (when (and proc (process-live-p proc))
        (delete-process proc)))
    (remhash server-name ogent-mcp--connections)
    ;; Remove registered tools
    (let ((prefix (format "mcp-%s-" server-name)))
      (setq ogent-tool-registry
            (cl-remove-if (lambda (spec)
                            (string-prefix-p prefix
                                             (symbol-name (plist-get spec :name))))
                          ogent-tool-registry)))
    (message "ogent-mcp: Disconnected from '%s'" server-name)))

;;;###autoload
(defun ogent-mcp-list-connections ()
  "List all MCP server connections and their status."
  (interactive)
  (if (hash-table-empty-p ogent-mcp--connections)
      (message "No MCP servers connected")
    (with-help-window "*ogent-mcp-connections*"
      (princ "MCP Server Connections\n")
      (princ "======================\n\n")
      (maphash
       (lambda (name conn)
         (princ (format "Server: %s\n" name))
         (princ (format "  Status: %s\n" (ogent-mcp-connection-status conn)))
         (when (eq (ogent-mcp-connection-status conn) 'error)
           (princ (format "  Error: %s\n" (ogent-mcp-connection-error conn))))
         (when-let ((tools (ogent-mcp-connection-tools conn)))
           (princ (format "  Tools: %d\n" (length tools)))
           (dolist (tool tools)
             (princ (format "    - %s\n" (alist-get 'name tool)))))
         (when-let ((resources (ogent-mcp-connection-resources conn)))
           (princ (format "  Resources: %d\n" (length resources))))
         (when-let ((prompts (ogent-mcp-connection-prompts conn)))
           (princ (format "  Prompts: %d\n" (length prompts))))
         (princ "\n"))
       ogent-mcp--connections))))

;;;###autoload
(defun ogent-mcp-connect-all ()
  "Connect to all MCP servers marked with :auto-connect."
  (interactive)
  (dolist (entry ogent-mcp-servers)
    (when (plist-get (cdr entry) :auto-connect)
      (ogent-mcp-connect (car entry)))))

;;; Resource Reading

;;;###autoload
(defun ogent-mcp-read-resource (server-name uri)
  "Read resource URI from SERVER-NAME."
  (let ((conn (gethash server-name ogent-mcp--connections)))
    (unless conn
      (user-error "Not connected to MCP server: %s" server-name))
    (unless (eq (ogent-mcp-connection-status conn) 'ready)
      (user-error "MCP server '%s' is not ready" server-name))
    (let* ((params `((uri . ,uri)))
           (response (ogent-mcp--request-sync conn "resources/read" params)))
      (if (cdr response)
          (error "MCP resource error: %s" (alist-get 'message (cdr response)))
        (let* ((result (car response))
               (contents (ogent-mcp--array-to-list
                          (alist-get 'contents result))))
          ;; Return first content item
          (when contents
            (let ((item (car contents)))
              (or (alist-get 'text item)
                  (alist-get 'blob item)))))))))

;;; Prompt Retrieval

;;;###autoload
(defun ogent-mcp-get-prompt (server-name prompt-name &optional arguments)
  "Get prompt PROMPT-NAME from SERVER-NAME and return its messages.
ARGUMENTS is an optional alist of (NAME . VALUE) pairs used to fill
the prompt's template arguments.  Return the list of resolved prompt
messages from the server's prompts/get response."
  (let ((conn (gethash server-name ogent-mcp--connections)))
    (unless conn
      (user-error "Not connected to MCP server: %s" server-name))
    (unless (eq (ogent-mcp-connection-status conn) 'ready)
      (user-error "MCP server '%s' is not ready" server-name))
    (let* ((params `((name . ,prompt-name)
                     ,@(when arguments
                         `((arguments . ,arguments)))))
           (response (ogent-mcp--request-sync conn "prompts/get" params)))
      (if (cdr response)
          (error "MCP prompt error: %s" (alist-get 'message (cdr response)))
        (ogent-mcp--array-to-list
         (alist-get 'messages (car response)))))))

;;; Setup

(defun ogent-mcp-setup ()
  "Set up MCP integration.
Called automatically when ogent-mcp is loaded."
  ;; Connect to auto-connect servers after a short delay
  ;; to allow ogent to fully initialize first
  (run-with-timer 1 nil #'ogent-mcp-connect-all))

;; Auto-setup when loaded with ogent
(with-eval-after-load 'ogent
  (ogent-mcp-setup))

(provide 'ogent-mcp)

;;; ogent-mcp.el ends here
