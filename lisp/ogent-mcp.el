;;; ogent-mcp.el --- MCP (Model Context Protocol) client for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Implements an MCP client enabling ogent to connect to MCP servers for
;; extended tool capabilities.  Supports:
;; - Stdio transport (JSON-RPC over stdin/stdout)
;; - Streamable HTTP transport (JSON-RPC POSTs with incremental SSE
;;   streaming and an optional server GET event stream via a curl
;;   subprocess; buffered url.el POSTs when curl is absent)
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
  streams          ; Live curl stream processes (http transport)
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
;; Client half of the MCP streamable HTTP transport.  When curl is
;; available every JSON-RPC message is POSTed through a curl
;; subprocess whose filter sniffs the response headers: a
;; text/event-stream body is parsed incrementally frame by frame,
;; while a JSON body is buffered and parsed once curl exits.  After
;; initialization the optional long-lived server GET event stream is
;; opened; a 405 there means the server offers none.  Without curl,
;; POSTs fall back to buffered `url-retrieve' (which cannot stream).

(defun ogent-mcp--http-send (conn msg)
  "Send JSON-RPC MSG to the streamable HTTP endpoint of CONN.
Stream the POST through a curl subprocess when curl is available so
SSE responses dispatch incrementally; fall back to a fully-buffered
`url-retrieve' POST otherwise."
  (if (executable-find "curl")
      (ogent-mcp--http-curl-stream conn "POST" (json-encode msg))
    (ogent-mcp--http-send-url conn msg)))

(defun ogent-mcp--http-send-url (conn msg)
  "POST JSON-RPC MSG to the endpoint of CONN via `url-retrieve'.
Fallback transport used when curl is absent.  The response is
handled, fully buffered, by `ogent-mcp--http-handle-response'."
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
body yields one per \"data:\" line.  Incremental SSE parsing is done
by `ogent-mcp--http-curl-callbacks' instead."
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

(defun ogent-mcp--http-header-value (headers name)
  "Return the value of header NAME within HEADERS, or nil when absent.
HEADERS is the raw header block of an HTTP response as a string."
  (let ((case-fold-search t))
    (when (string-match
           (concat "^" (regexp-quote name) ":[ \t]*\\([^\r\n]*\\)")
           headers)
      (string-trim (match-string 1 headers)))))

(defun ogent-mcp--sse-take-lines (text)
  "Split TEXT into complete SSE lines and an unterminated remainder.
Recognize LF, CRLF, and lone CR line terminators.  Hold a trailing CR
back in the remainder: it may be half of a CRLF split across chunks.
Return a cons cell (LINES . REST)."
  (let ((lines nil)
        (start 0))
    (while (and (string-match "\r\n\\|[\r\n]" text start)
                (not (and (equal "\r" (match-string 0 text))
                          (= (match-end 0) (length text)))))
      (push (substring text start (match-beginning 0)) lines)
      (setq start (match-end 0)))
    (cons (nreverse lines) (substring text start))))

(defun ogent-mcp--sse-dispatch-frame (conn data-lines)
  "Dispatch the SSE frame accumulated in DATA-LINES for CONN.
DATA-LINES is the reversed list of \"data:\" payloads of one frame;
join them with newlines per the SSE spec and dispatch the resulting
JSON-RPC message.  Ignore frames without data (heartbeats)."
  (when data-lines
    (when-let ((msg (ogent-mcp--parse-message
                     (string-join (nreverse data-lines) "\n"))))
      (ogent-mcp--dispatch-message conn msg))))

(defun ogent-mcp--http-curl-report-failure (conn method detail)
  "Report a failed curl request of kind METHOD for CONN.
DETAIL is an HTTP status code or a process event description.  Keep
a GET status of 405 silent: the server merely offers no event
stream.  Mark CONN as errored when the failure interrupts
initialization."
  (if (equal method "GET")
      (unless (eql detail 405)
        (message "ogent-mcp: HTTP GET stream error from '%s': %s"
                 (ogent-mcp-connection-name conn) detail))
    (when (eq (ogent-mcp-connection-status conn) 'connecting)
      (setf (ogent-mcp-connection-status conn) 'error)
      (setf (ogent-mcp-connection-error conn) (format "HTTP %s" detail)))
    (message "ogent-mcp: HTTP error from '%s': %s"
             (ogent-mcp-connection-name conn) detail)))

(defun ogent-mcp--http-curl-callbacks (conn method)
  "Create filter and sentinel closures for a curl stream of CONN.
METHOD is the HTTP method string of the request.  The filter parses
the response headers produced by curl -i, records any Mcp-Session-Id,
then either dispatches SSE frames incrementally as they complete or
buffers a JSON body that the sentinel parses once curl exits.  Return
a cons cell (FILTER . SENTINEL); the closures share parser state."
  (let ((pending "")        ; raw output not yet consumed
        (headers-done nil)  ; non-nil once the final header block is read
        (failed nil)        ; non-nil when the response status is >= 400
        (sse nil)           ; non-nil when the body is text/event-stream
        (content-type nil)  ; response Content-Type header
        (body "")           ; accumulated body in JSON mode
        (data-lines nil))   ; data: payloads of the current SSE frame
    (cons
     (lambda (_process chunk)
       (setq pending (concat pending chunk))
       ;; Consume header blocks; interim 1xx responses are skipped.
       (while (and (not headers-done)
                   (string-match "\r?\n\r?\n" pending))
         (let ((headers (substring pending 0 (match-beginning 0)))
               (status nil))
           (setq pending (substring pending (match-end 0)))
           (when (string-match "\\`HTTP/[0-9.]+ +\\([0-9]+\\)" headers)
             (setq status (string-to-number (match-string 1 headers))))
           (unless (and status (<= 100 status 199))
             (setq headers-done t)
             (when-let ((session (ogent-mcp--http-header-value
                                  headers "Mcp-Session-Id")))
               (setf (ogent-mcp-connection-session-id conn) session))
             (setq content-type (ogent-mcp--http-header-value
                                 headers "Content-Type"))
             (setq sse (and content-type
                            (string-match-p "text/event-stream"
                                            content-type)))
             (when (and status (>= status 400))
               (setq failed t)
               (ogent-mcp--http-curl-report-failure conn method status)))))
       (when headers-done
         (cond
          (failed (setq pending ""))
          (sse
           (let ((split (ogent-mcp--sse-take-lines pending)))
             (setq pending (cdr split))
             (dolist (line (car split))
               (cond
                ((string-empty-p line)
                 (ogent-mcp--sse-dispatch-frame conn data-lines)
                 (setq data-lines nil))
                ((string-prefix-p ":" line)) ; comment / heartbeat
                ((string-match "\\`data\\(?:: ?\\(.*\\)\\)?\\'" line)
                 (push (or (match-string 1 line) "") data-lines))))))
          (t
           (setq body (concat body pending))
           (setq pending "")))))
     (lambda (process event)
       (setf (ogent-mcp-connection-streams conn)
             (delq process (ogent-mcp-connection-streams conn)))
       (cond
        (failed nil) ; already reported when the headers arrived
        ((and headers-done (not sse) (string-match-p "finished" event))
         (dolist (msg (ogent-mcp--http-body-messages body content-type))
           (ogent-mcp--dispatch-message conn msg)))
        ((and (not headers-done)
              (not (string-match-p "finished\\|deleted\\|killed" event)))
         (ogent-mcp--http-curl-report-failure conn method
                                              (string-trim event))))))))

(defun ogent-mcp--http-curl-stream (conn method &optional data)
  "Start a streaming curl METHOD request to the endpoint of CONN.
DATA is the request body for POST, sent on curl's stdin.  The process
filter sniffs the response Content-Type: a text/event-stream body is
parsed incrementally, dispatching each complete SSE frame as it
arrives; any other body is buffered and dispatched when curl exits.
Register the process on CONN so disconnect can kill it; return it."
  (let* ((callbacks (ogent-mcp--http-curl-callbacks conn method))
         (args
          `("-sN" "--no-buffer" "-i" "-X" ,method
            ,@(when data '("-H" "Content-Type: application/json"))
            "-H" ,(if (equal method "GET")
                      "Accept: text/event-stream"
                    "Accept: application/json, text/event-stream")
            ,@(when-let ((session (ogent-mcp-connection-session-id conn)))
                (list "-H" (concat "Mcp-Session-Id: " session)))
            ,@(when data '("--data-binary" "@-"))
            ,(ogent-mcp-connection-url conn)))
         (proc (make-process
                :name (format "ogent-mcp-curl-%s"
                              (ogent-mcp-connection-name conn))
                :command (cons "curl" args)
                :connection-type 'pipe
                :noquery t
                :coding 'utf-8
                :filter (car callbacks)
                :sentinel (cdr callbacks))))
    (push proc (ogent-mcp-connection-streams conn))
    (when data
      (process-send-string proc data)
      (process-send-eof proc))
    proc))

(defun ogent-mcp--http-open-get-stream (conn)
  "Open the optional server event stream of CONN with a GET request.
The MCP streamable HTTP transport lets servers push requests and
notifications over a long-lived GET SSE stream; a 405 response means
the server offers none and stays silent.  No-op when curl is absent,
since `url-retrieve' cannot stream."
  (when (executable-find "curl")
    (ogent-mcp--http-curl-stream conn "GET")))

(defun ogent-mcp--http-delete-session (conn)
  "Send a fire-and-forget DELETE ending the HTTP session of CONN.
Do nothing when CONN has no session id.  Ignore failures: the server
may not support explicit session termination."
  (when-let ((session (ogent-mcp-connection-session-id conn)))
    (let ((url (ogent-mcp-connection-url conn)))
      (if (executable-find "curl")
          (make-process
           :name (format "ogent-mcp-curl-delete-%s"
                         (ogent-mcp-connection-name conn))
           :command (list "curl" "-s" "-X" "DELETE"
                          "-H" (concat "Mcp-Session-Id: " session)
                          url)
           :connection-type 'pipe
           :noquery t
           :sentinel #'ignore)
        (let ((url-request-method "DELETE")
              (url-request-extra-headers
               (list (cons "Mcp-Session-Id" session))))
          (ignore-errors
            (url-retrieve url
                          (lambda (&rest _) (kill-buffer (current-buffer)))
                          nil t)))))))

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
                            ;; Open the optional server event stream
                            (when (eq (ogent-mcp-connection-transport conn)
                                      'http)
                              (ogent-mcp--http-open-get-stream conn))
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
    ;; End the http session, then kill any live curl streams
    (when (eq (ogent-mcp-connection-transport conn) 'http)
      (ogent-mcp--http-delete-session conn))
    (dolist (stream (ogent-mcp-connection-streams conn))
      (when (process-live-p stream)
        (delete-process stream)))
    (setf (ogent-mcp-connection-streams conn) nil)
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
